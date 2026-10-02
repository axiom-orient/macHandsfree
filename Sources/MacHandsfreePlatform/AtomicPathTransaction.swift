import CPlatformSupport
import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// A path transaction uses kernel atomic rename primitives, then validates the objects that moved.
/// A failed post-move validation is rolled back before the error is returned.
enum AtomicPathTransaction {
  struct RollbackFailure: Error {
    let error: AgentError
  }

  static func exchange(
    _ first: URL,
    _ second: URL,
    validateBeforeCommit: () throws -> Void = {},
    validateAfterExchange: () throws -> Void = {}
  ) throws {
    let firstIdentity = try identity(at: first)
    let secondIdentity = try identity(at: second)
    try validateBeforeCommit()

    guard mac_handsfree_rename_exchange(first.path, second.path) == 0 else {
      throw exchangeFailure(first: first, second: second, errorNumber: errno)
    }

    do {
      guard try identity(at: first) == secondIdentity,
        try identity(at: second) == firstIdentity
      else {
        throw AgentError(
          code: "plan_state_changed",
          message: "A filesystem item changed at the atomic exchange boundary",
          details: [
            "first": .string(first.path),
            "second": .string(second.path),
          ],
          exitCode: 6
        )
      }
      try validateAfterExchange()
    } catch {
      try rollbackExchange(
        first,
        second,
        originalFirstIdentity: firstIdentity,
        originalSecondIdentity: secondIdentity,
        originalError: error
      )
      throw error
    }
  }

  static func detach(
    _ source: URL,
    to destination: URL,
    validateBeforeCommit: () throws -> Void = {},
    validateAfterDetach: () throws -> Void = {}
  ) throws {
    let sourceIdentity = try identity(at: source)
    try validateBeforeCommit()

    guard mac_handsfree_rename_noreplace(source.path, destination.path) == 0 else {
      throw detachFailure(source: source, destination: destination, errorNumber: errno)
    }

    do {
      guard try identity(at: destination) == sourceIdentity else {
        throw AgentError(
          code: "plan_state_changed",
          message: "A filesystem item changed at the atomic detach boundary",
          details: [
            "source": .string(source.path),
            "destination": .string(destination.path),
          ],
          exitCode: 6
        )
      }
      try validateAfterDetach()
    } catch {
      try rollbackDetach(
        source: source,
        destination: destination,
        originalSourceIdentity: sourceIdentity,
        originalError: error
      )
      throw error
    }
  }

  private static func rollbackExchange(
    _ first: URL,
    _ second: URL,
    originalFirstIdentity: PathIdentity,
    originalSecondIdentity: PathIdentity,
    originalError: any Error
  ) throws {
    do {
      guard try identity(at: first) == originalSecondIdentity,
        try identity(at: second) == originalFirstIdentity
      else {
        throw rollbackStateChanged(
          operation: "exchange-precondition",
          first: first,
          second: second
        )
      }
    } catch {
      throw RollbackFailure(
        error: rollbackFailure(
          operation: "exchange-precondition",
          first: first,
          second: second,
          originalError: originalError,
          reason: error
        ))
    }

    guard mac_handsfree_rename_exchange(first.path, second.path) == 0 else {
      throw RollbackFailure(
        error: rollbackFailure(
          operation: "exchange",
          first: first,
          second: second,
          originalError: originalError,
          errorNumber: errno
        ))
    }

    do {
      guard try identity(at: first) == originalFirstIdentity,
        try identity(at: second) == originalSecondIdentity
      else {
        throw rollbackStateChanged(
          operation: "exchange-postcondition",
          first: first,
          second: second
        )
      }
      try syncParents(of: [first, second])
    } catch {
      throw RollbackFailure(
        error: rollbackFailure(
          operation: "exchange-postcondition",
          first: first,
          second: second,
          originalError: originalError,
          reason: error
        ))
    }
  }

  private static func rollbackDetach(
    source: URL,
    destination: URL,
    originalSourceIdentity: PathIdentity,
    originalError: any Error
  ) throws {
    do {
      guard try isAbsent(source),
        try identity(at: destination) == originalSourceIdentity
      else {
        throw rollbackStateChanged(
          operation: "detach-precondition",
          first: source,
          second: destination
        )
      }
    } catch {
      throw RollbackFailure(
        error: rollbackFailure(
          operation: "detach-precondition",
          first: source,
          second: destination,
          originalError: originalError,
          reason: error
        ))
    }

    guard mac_handsfree_rename_noreplace(destination.path, source.path) == 0 else {
      throw RollbackFailure(
        error: rollbackFailure(
          operation: "detach",
          first: source,
          second: destination,
          originalError: originalError,
          errorNumber: errno
        ))
    }

    do {
      guard try identity(at: source) == originalSourceIdentity,
        try isAbsent(destination)
      else {
        throw rollbackStateChanged(
          operation: "detach-postcondition",
          first: source,
          second: destination
        )
      }
      try syncParents(of: [source, destination])
    } catch {
      throw RollbackFailure(
        error: rollbackFailure(
          operation: "detach-postcondition",
          first: source,
          second: destination,
          originalError: originalError,
          reason: error
        ))
    }
  }

  private static func isAbsent(_ url: URL) throws -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return false }
    guard errno == ENOENT else {
      throw AgentError(
        code: "path_inspection_failed",
        message: "Could not inspect a filesystem path during atomic rollback",
        details: [
          "path": .string(url.path),
          "errno": .integer(Int64(errno)),
        ],
        exitCode: 5,
        outcomeUncertain: true
      )
    }
    return true
  }

  private static func rollbackStateChanged(
    operation: String,
    first: URL,
    second: URL
  ) -> AgentError {
    AgentError(
      code: "atomic_path_rollback_state_changed",
      message: "Filesystem paths changed before atomic rollback could be applied safely",
      details: [
        "operation": .string(operation),
        "first": .string(first.path),
        "second": .string(second.path),
      ],
      exitCode: 5,
      outcomeUncertain: true
    )
  }

  private static func identity(at url: URL) throws -> PathIdentity {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw AgentError(
        code: errno == ENOENT ? "plan_state_changed" : "path_inspection_failed",
        message: errno == ENOENT
          ? "A filesystem item disappeared before an atomic path transaction"
          : "Could not inspect a filesystem item before an atomic path transaction",
        details: [
          "path": .string(url.path),
          "errno": .integer(Int64(errno)),
        ],
        exitCode: errno == ENOENT ? 6 : 5
      )
    }
    return PathIdentity(
      device: UInt64(truncatingIfNeeded: info.st_dev),
      inode: UInt64(truncatingIfNeeded: info.st_ino)
    )
  }

  private static func exchangeFailure(first: URL, second: URL, errorNumber: Int32) -> AgentError {
    let unsupported = errorNumber == ENOTSUP || errorNumber == EOPNOTSUPP
    let changed = errorNumber == ENOENT
    let crossDevice = errorNumber == EXDEV
    return AgentError(
      code: unsupported
        ? "atomic_exchange_not_supported"
        : changed
          ? "plan_state_changed"
          : crossDevice ? "cross_device_move_not_supported" : "atomic_exchange_failed",
      message: unsupported
        ? "The destination filesystem does not support safe atomic path exchange"
        : changed
          ? "A filesystem item changed before atomic exchange"
          : crossDevice
            ? "Atomic exchange cannot cross filesystems"
            : "Could not atomically exchange filesystem paths",
      details: [
        "first": .string(first.path),
        "second": .string(second.path),
        "errno": .integer(Int64(errorNumber)),
      ],
      exitCode: unsupported || changed || crossDevice ? 6 : 5
    )
  }

  private static func detachFailure(source: URL, destination: URL, errorNumber: Int32) -> AgentError
  {
    let exists = errorNumber == EEXIST || errorNumber == ENOTEMPTY
    let changed = errorNumber == ENOENT
    let crossDevice = errorNumber == EXDEV
    let unsupported = errorNumber == ENOTSUP || errorNumber == EOPNOTSUPP
    return AgentError(
      code: exists
        ? "target_exists"
        : changed
          ? "plan_state_changed"
          : crossDevice
            ? "cross_device_move_not_supported"
            : unsupported ? "atomic_rename_not_supported" : "atomic_rename_failed",
      message: exists
        ? "Atomic destination was created concurrently"
        : changed
          ? "The source changed before atomic rename"
          : crossDevice
            ? "Atomic rename cannot cross filesystems"
            : unsupported
              ? "The destination filesystem does not support safe atomic rename"
              : "Could not atomically rename a filesystem item",
      details: [
        "source": .string(source.path),
        "destination": .string(destination.path),
        "errno": .integer(Int64(errorNumber)),
      ],
      exitCode: exists || changed || crossDevice || unsupported ? 6 : 5
    )
  }

  private static func rollbackFailure(
    operation: String,
    first: URL,
    second: URL,
    originalError: any Error,
    errorNumber: Int32? = nil,
    reason: (any Error)? = nil
  ) -> AgentError {
    var details: [String: JSONValue] = [
      "operation": .string(operation),
      "first": .string(first.path),
      "second": .string(second.path),
      "original_error": .string(String(describing: originalError)),
    ]
    if let errorNumber { details["errno"] = .integer(Int64(errorNumber)) }
    if let reason { details["rollback_error"] = .string(String(describing: reason)) }
    return AgentError(
      code: "atomic_path_rollback_failed",
      message:
        "Atomic filesystem validation failed and the original path state could not be restored",
      details: details,
      exitCode: 5,
      outcomeUncertain: true
    )
  }

  private static func syncParents(of paths: [URL]) throws {
    var visited = Set<String>()
    for path in paths {
      let parent = path.deletingLastPathComponent()
      guard visited.insert(parent.path).inserted else { continue }
      let descriptor = open(parent.path, O_RDONLY | O_CLOEXEC)
      guard descriptor >= 0 else {
        throw AgentError(
          code: "directory_sync_failed",
          message: "Could not open a rollback parent directory for sync",
          details: ["path": .string(parent.path), "errno": .integer(Int64(errno))],
          exitCode: 5,
          outcomeUncertain: true
        )
      }
      var syncStatus: Int32
      repeat {
        syncStatus = fsync(descriptor)
      } while syncStatus != 0 && errno == EINTR
      let syncErrno = errno
      let closeStatus = close(descriptor)
      let closeErrno = errno
      guard syncStatus == 0, closeStatus == 0 else {
        var details: [String: JSONValue] = ["path": .string(parent.path)]
        if syncStatus != 0 { details["sync_errno"] = .integer(Int64(syncErrno)) }
        if closeStatus != 0 { details["close_errno"] = .integer(Int64(closeErrno)) }
        throw AgentError(
          code: "directory_sync_failed",
          message: "Could not confirm atomic rollback durability",
          details: details,
          exitCode: 5,
          outcomeUncertain: true
        )
      }
    }
  }
}

private struct PathIdentity: Equatable {
  let device: UInt64
  let inode: UInt64
}
