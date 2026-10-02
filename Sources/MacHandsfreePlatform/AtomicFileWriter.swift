import CPlatformSupport
import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum AtomicFileWriter {
  static func write(
    _ data: Data,
    to destination: URL,
    replacingExisting: Bool,
    replacementPermissions: mode_t? = nil,
    validateBeforePublish: () throws -> Void = {},
    validateReplacedItem: (URL) throws -> Void = { _ in }
  ) throws {
    let parent = destination.deletingLastPathComponent()
    let temporary = parent.appendingPathComponent(
      ".mac-handsfree-\(UUID().uuidString).tmp",
      isDirectory: false
    )
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw AgentError(
        code: "file_write_failed",
        message: "Could not create an atomic temporary file",
        details: ["errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }

    var descriptorIsOpen = true
    do {
      let persisted = try persist(
        data,
        descriptor: descriptor,
        replacementPermissions: replacementPermissions
      )
      let expectedDigest = SHA256.hex(data)
      descriptorIsOpen = false
      guard close(descriptor) == 0 else {
        throw AgentError(
          code: "file_write_failed",
          message: "Could not close the persisted temporary file",
          details: ["errno": .integer(Int64(errno))],
          exitCode: 5
        )
      }

      try publish(
        temporary,
        to: destination,
        replacingExisting: replacingExisting,
        validateBeforeCommit: validateBeforePublish,
        validateReplacedItem: validateReplacedItem,
        validatePublishedItem: { published in
          try validatePersistedRegularFile(
            published,
            expected: persisted,
            expectedDigest: expectedDigest
          )
        }
      )
    } catch let rollback as AtomicPathTransaction.RollbackFailure {
      if descriptorIsOpen { _ = close(descriptor) }
      throw rollback.error
    } catch {
      let originalError = error
      try cleanupTemporary(
        temporary,
        descriptor: descriptorIsOpen ? descriptor : nil,
        originalError: originalError
      )
      throw originalError
    }

    try syncDirectory(parent)
  }

  private static func persist(
    _ data: Data,
    descriptor: Int32,
    replacementPermissions: mode_t?
  ) throws -> stat {
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else {
        guard raw.isEmpty else {
          throw AgentError(
            code: "file_write_failed",
            message: "Could not access file content for atomic persistence",
            exitCode: 5
          )
        }
        return
      }
      var offset = 0
      while offset < raw.count {
        let result = platformWrite(descriptor, base.advanced(by: offset), raw.count - offset)
        if result > 0 {
          offset += result
          continue
        }
        if result < 0, errno == EINTR { continue }
        let writeErrno = result < 0 ? errno : EIO
        throw AgentError(
          code: "file_write_failed",
          message: "Could not persist file content",
          details: ["errno": .integer(Int64(writeErrno))],
          exitCode: 5
        )
      }
    }
    if let replacementPermissions {
      var status: Int32
      repeat {
        status = fchmod(descriptor, replacementPermissions & 0o777)
      } while status != 0 && errno == EINTR
      guard status == 0 else {
        throw AgentError(
          code: "file_write_failed",
          message: "Could not preserve output file permissions",
          details: ["errno": .integer(Int64(errno))],
          exitCode: 5
        )
      }
    }
    while fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      throw AgentError(
        code: "file_write_failed",
        message: "Could not sync persisted file content",
        details: ["errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }

    var persisted = stat()
    let expectedSize = Int64(data.count)
    guard fstat(descriptor, &persisted) == 0,
      (persisted.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      persisted.st_uid == getuid(),
      persisted.st_nlink == 1,
      Int64(persisted.st_size) == expectedSize
    else {
      throw AgentError(
        code: "file_write_failed",
        message: "Persisted file state did not match the requested output",
        details: ["expected_bytes": .integer(expectedSize)],
        exitCode: 5
      )
    }
    return persisted
  }

  private static func validatePersistedRegularFile(
    _ published: URL,
    expected: stat,
    expectedDigest: String
  ) throws {
    let descriptor = open(
      published.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
      throw publicationChanged(
        published,
        message: "Could not open the published file for exact verification",
        errorNumber: errno
      )
    }

    var descriptorIsOpen = true
    do {
      var before = stat()
      guard fstat(descriptor, &before) == 0,
        samePersistedFile(before, expected)
      else {
        throw publicationChanged(
          published,
          message: "Published file metadata did not match the persisted output"
        )
      }

      var hasher = SHA256Hasher()
      var byteCount: Int64 = 0
      var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
      while true {
        guard !Task.isCancelled else {
          throw AgentError(
            code: "operation_cancelled",
            message: "Atomic file publication verification was cancelled",
            exitCode: 6
          )
        }
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
          guard let base = raw.baseAddress else { return 0 }
          return platformRead(descriptor, base, raw.count)
        }
        if count > 0 {
          let next = byteCount.addingReportingOverflow(Int64(count))
          guard !next.overflow else {
            throw publicationChanged(
              published,
              message: "Published file size exceeded the supported range"
            )
          }
          byteCount = next.partialValue
          hasher.update(Data(buffer.prefix(count)))
          continue
        }
        if count == 0 { break }
        if errno == EINTR { continue }
        throw publicationChanged(
          published,
          message: "Could not read the published file for exact verification",
          errorNumber: errno
        )
      }

      var after = stat()
      let actualDigest = hasher.finalizeHex()
      guard fstat(descriptor, &after) == 0,
        stableDuringVerification(before, after),
        byteCount == Int64(after.st_size),
        actualDigest == expectedDigest
      else {
        throw publicationChanged(
          published,
          message: "Published file content changed at the atomic commit boundary"
        )
      }

      descriptorIsOpen = false
      guard close(descriptor) == 0 else {
        throw AgentError(
          code: "file_publication_verification_failed",
          message: "Could not close the published file after exact verification",
          details: [
            "path": .string(published.path),
            "errno": .integer(Int64(errno)),
          ],
          exitCode: 5
        )
      }
    } catch {
      let originalError = error
      guard descriptorIsOpen else { throw originalError }
      descriptorIsOpen = false
      guard close(descriptor) == 0 else {
        throw AgentError(
          code: "file_publication_verification_cleanup_failed",
          message: "Published file verification failed and its descriptor could not be closed",
          details: [
            "path": .string(published.path),
            "original_error": .string(String(describing: originalError)),
            "errno": .integer(Int64(errno)),
          ],
          exitCode: 5
        )
      }
      throw originalError
    }
  }

  private static func samePersistedFile(_ current: stat, _ expected: stat) -> Bool {
    (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
      && current.st_dev == expected.st_dev
      && current.st_ino == expected.st_ino
      && current.st_uid == expected.st_uid
      && current.st_gid == expected.st_gid
      && current.st_nlink == expected.st_nlink
      && current.st_nlink == 1
      && current.st_size == expected.st_size
      && current.st_mode == expected.st_mode
      && fileModificationTime(current) == fileModificationTime(expected)
  }

  private static func stableDuringVerification(_ before: stat, _ after: stat) -> Bool {
    before.st_dev == after.st_dev
      && before.st_ino == after.st_ino
      && before.st_uid == after.st_uid
      && before.st_gid == after.st_gid
      && before.st_nlink == after.st_nlink
      && before.st_size == after.st_size
      && before.st_mode == after.st_mode
      && fileModificationTime(before) == fileModificationTime(after)
      && fileChangeTime(before) == fileChangeTime(after)
  }

  private static func publicationChanged(
    _ published: URL,
    message: String,
    errorNumber: Int32? = nil
  ) -> AgentError {
    var details: [String: JSONValue] = ["path": .string(published.path)]
    if let errorNumber { details["errno"] = .integer(Int64(errorNumber)) }
    return AgentError(
      code: "plan_state_changed",
      message: message,
      details: details,
      exitCode: 6
    )
  }

  static func publish(
    _ temporary: URL,
    to destination: URL,
    replacingExisting: Bool,
    validateBeforeCommit: () throws -> Void = {},
    validateReplacedItem: (URL) throws -> Void = { _ in },
    validatePublishedItem: (URL) throws -> Void = { _ in }
  ) throws {
    if replacingExisting {
      try AtomicPathTransaction.exchange(
        temporary,
        destination,
        validateBeforeCommit: validateBeforeCommit
      ) {
        try validateReplacedItem(temporary)
        try validatePublishedItem(destination)
      }
      var status: Int32
      repeat {
        status = unlink(temporary.path)
      } while status != 0 && errno == EINTR
      guard status == 0 else {
        throw AgentError(
          code: "file_replacement_cleanup_failed",
          message: "Output was replaced, but the displaced file could not be removed",
          details: [
            "path": .string(destination.path),
            "displaced_path": .string(temporary.path),
            "errno": .integer(Int64(errno)),
          ],
          exitCode: 5,
          outcomeUncertain: true
        )
      }
      return
    }
    do {
      try AtomicPathTransaction.detach(
        temporary,
        to: destination,
        validateBeforeCommit: validateBeforeCommit
      ) {
        try validatePublishedItem(destination)
      }
    } catch let error as AgentError {
      guard error.code == "atomic_rename_failed" else { throw error }
      throw AgentError(
        code: "file_write_failed",
        message: "Could not atomically publish the output file",
        details: error.details,
        exitCode: 5,
        outcomeUncertain: error.outcomeUncertain
      )
    }
  }

  private static func cleanupTemporary(
    _ temporary: URL,
    descriptor: Int32?,
    originalError: any Error
  ) throws {
    var failures: [JSONValue] = []
    if let descriptor, close(descriptor) != 0 {
      failures.append(
        .object([
          "operation": .string("close"),
          "errno": .integer(Int64(errno)),
        ]))
    }
    if unlink(temporary.path) != 0, errno != ENOENT {
      failures.append(
        .object([
          "operation": .string("unlink"),
          "errno": .integer(Int64(errno)),
        ]))
    }
    guard failures.isEmpty else {
      throw AgentError(
        code: "file_staging_cleanup_failed",
        message: "Atomic file publication failed and its temporary file could not be cleaned up",
        details: [
          "path": .string(temporary.path),
          "original_error": .string(String(describing: originalError)),
          "cleanup_failures": .array(failures),
        ],
        exitCode: 5,
        outcomeUncertain: (originalError as? AgentError)?.outcomeUncertain == true
      )
    }
  }

  static func syncDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw AgentError(
        code: "directory_sync_failed",
        message: "Output was published but its parent directory could not be opened for sync",
        details: ["path": .string(directory.path), "errno": .integer(Int64(errno))],
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
      var details: [String: JSONValue] = ["path": .string(directory.path)]
      if syncStatus != 0 { details["sync_errno"] = .integer(Int64(syncErrno)) }
      if closeStatus != 0 { details["close_errno"] = .integer(Int64(closeErrno)) }
      throw AgentError(
        code: "directory_sync_failed",
        message: "Output was published but its parent directory durability could not be confirmed",
        details: details,
        exitCode: 5,
        outcomeUncertain: true
      )
    }
  }
}

func platformRead(
  _ descriptor: Int32,
  _ buffer: UnsafeMutableRawPointer,
  _ count: Int
) -> Int {
  #if canImport(Darwin)
    return Darwin.read(descriptor, buffer, count)
  #else
    return Glibc.read(descriptor, buffer, count)
  #endif
}

private func platformWrite(
  _ descriptor: Int32,
  _ buffer: UnsafeRawPointer,
  _ count: Int
) -> Int {
  #if canImport(Darwin)
    return Darwin.write(descriptor, buffer, count)
  #else
    return Glibc.write(descriptor, buffer, count)
  #endif
}
