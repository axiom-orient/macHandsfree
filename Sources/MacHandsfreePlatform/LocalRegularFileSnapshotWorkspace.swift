import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Freezes regular-file inputs before an external process consumes them.
/// The source is snapshotted before and after copy; the private copy is then
/// fingerprinted and revalidated at the actual launch boundary.
struct LocalRegularFileSnapshotWorkspace: Sendable {
  let directory: URL
  let snapshotURLs: [URL]
  private let snapshotFingerprints: [FileTreeFingerprint]

  init(sources: [URL], fileManager: FileManager = .default) throws {
    guard !sources.isEmpty else {
      throw AgentError(
        code: "local_input_snapshot_empty",
        message: "At least one local input file is required for a snapshot workspace",
        exitCode: 5
      )
    }

    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "mac-handsfree-input-\(UUID().uuidString)",
      isDirectory: true
    )
    var snapshots: [URL] = []
    var fingerprints: [FileTreeFingerprint] = []

    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(directory.path, 0o700) == 0 else {
        throw Self.failure(
          code: "local_input_snapshot_setup_failed",
          message: "Could not secure the private local-input workspace",
          path: directory.path,
          errnoValue: errno
        )
      }

      for (index, source) in sources.enumerated() {
        try Self.requireNotCancelled()
        var sourceInfo = stat()
        let sourceStatus = lstat(source.path, &sourceInfo)
        let sourceErrno = errno
        guard sourceStatus == 0,
          (sourceInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
        else {
          throw Self.failure(
            code: "local_input_snapshot_invalid_source",
            message: "A local process input must be one regular file",
            path: source.path,
            errnoValue: sourceStatus == 0 ? nil : sourceErrno
          )
        }
        let sourceBefore = try FileTreeFingerprinter.snapshot(source, fileManager: fileManager)
        guard sourceBefore.entryCount == 1 else {
          throw Self.failure(
            code: "local_input_snapshot_invalid_source",
            message: "A local process input must be one regular file",
            path: source.path
          )
        }

        let itemDirectory = directory.appendingPathComponent(String(index), isDirectory: true)
        try fileManager.createDirectory(
          at: itemDirectory,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
        guard chmod(itemDirectory.path, 0o700) == 0 else {
          throw Self.failure(
            code: "local_input_snapshot_setup_failed",
            message: "Could not secure a private local-input item directory",
            path: itemDirectory.path,
            errnoValue: errno
          )
        }

        let snapshot = itemDirectory.appendingPathComponent(
          source.lastPathComponent,
          isDirectory: false
        )
        try fileManager.copyItem(at: source, to: snapshot)

        let sourceAfter = try FileTreeFingerprinter.snapshot(source, fileManager: fileManager)
        guard sourceAfter == sourceBefore else {
          throw Self.failure(
            code: "local_input_changed_during_snapshot",
            message: "A local process input changed while it was being snapshotted",
            path: source.path
          )
        }

        guard chmod(snapshot.path, 0o400) == 0 else {
          throw Self.failure(
            code: "local_input_snapshot_setup_failed",
            message: "Could not make a private local-input snapshot read-only",
            path: snapshot.path,
            errnoValue: errno
          )
        }
        let securedFingerprint = try FileTreeFingerprinter.snapshot(
          snapshot,
          fileManager: fileManager
        )
        guard securedFingerprint.entryCount == 1,
          securedFingerprint.regularBytes == sourceBefore.regularBytes,
          securedFingerprint.payloadDigest == sourceBefore.payloadDigest
        else {
          throw Self.failure(
            code: "local_input_snapshot_verification_failed",
            message: "A private local-input snapshot did not match its source bytes",
            path: source.path
          )
        }
        snapshots.append(snapshot)
        fingerprints.append(securedFingerprint)
      }
    } catch {
      let originalError = error
      if fileManager.fileExists(atPath: directory.path) {
        do {
          try fileManager.removeItem(at: directory)
        } catch {
          throw AgentError(
            code: "local_input_snapshot_setup_cleanup_failed",
            message: "Local-input snapshot setup failed and its workspace could not be removed",
            details: [
              "path": .string(directory.path),
              "original_error": .string(String(describing: originalError)),
              "cleanup_error": .string(String(describing: error)),
            ],
            exitCode: 5
          )
        }
      }
      throw originalError
    }

    self.directory = directory
    self.snapshotURLs = snapshots
    self.snapshotFingerprints = fingerprints
  }

  func validate(fileManager: FileManager = .default) throws {
    guard snapshotURLs.count == snapshotFingerprints.count else {
      throw AgentError(
        code: "local_input_snapshot_corrupt",
        message: "Local-input snapshot metadata is inconsistent",
        exitCode: 5
      )
    }
    for (url, expected) in zip(snapshotURLs, snapshotFingerprints) {
      let current: FileTreeFingerprint
      do {
        current = try FileTreeFingerprinter.snapshot(url, fileManager: fileManager)
      } catch {
        throw Self.failure(
          code: "local_input_snapshot_changed",
          message: "A private local-input snapshot could not be revalidated",
          path: url.path,
          reason: error
        )
      }
      guard current == expected else {
        throw Self.failure(
          code: "local_input_snapshot_changed",
          message: "A private local-input snapshot changed before process launch",
          path: url.path
        )
      }
    }
  }

  func remove(
    fileManager: FileManager = .default,
    originalError: (any Error)? = nil,
    outcomeUncertain: Bool,
    observedResult: JSONValue? = nil
  ) throws {
    guard fileManager.fileExists(atPath: directory.path) else { return }
    do {
      try fileManager.removeItem(at: directory)
    } catch {
      var details: [String: JSONValue] = [
        "path": .string(directory.path),
        "cleanup_error": .string(String(describing: error)),
      ]
      if let originalError {
        details["original_error"] = .string(String(describing: originalError))
      }
      if let original = originalError as? AgentError {
        details["original_error_code"] = .string(original.code)
        details["original_error_details"] = .object(original.details)
      }
      if let observedResult { details["observed_result"] = observedResult }
      throw AgentError(
        code: "local_input_snapshot_cleanup_failed",
        message: "Could not remove a private local-input snapshot workspace",
        details: details,
        exitCode: 5,
        outcomeUncertain: outcomeUncertain
          || (originalError as? AgentError)?.outcomeUncertain == true
      )
    }
  }

  private static func requireNotCancelled() throws {
    guard !Task.isCancelled else {
      throw AgentError(
        code: "operation_cancelled",
        message: "Local-input snapshot creation was cancelled",
        exitCode: 6
      )
    }
  }

  private static func failure(
    code: String,
    message: String,
    path: String,
    errnoValue: Int32? = nil,
    reason: (any Error)? = nil
  ) -> AgentError {
    var details: [String: JSONValue] = ["path": .string(path)]
    if let errnoValue { details["errno"] = .integer(Int64(errnoValue)) }
    if let reason { details["reason"] = .string(String(describing: reason)) }
    return AgentError(
      code: code,
      message: message,
      details: details,
      exitCode: 5
    )
  }
}
