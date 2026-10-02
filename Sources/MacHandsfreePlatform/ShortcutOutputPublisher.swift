import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum ShortcutOutputPublisher {
  static func publish(
    _ staged: URL,
    to destination: URL,
    validateBeforePublish: () throws -> Void = {}
  ) throws {
    var expected = stat()
    guard lstat(staged.path, &expected) == 0 else {
      throw AgentError(
        code: "shortcut_output_missing",
        message: "Shortcut completed without creating the requested output file",
        details: ["path": .string(staged.path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
    guard (expected.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      expected.st_uid == getuid(),
      expected.st_nlink == 1
    else {
      throw AgentError(
        code: "shortcut_output_invalid",
        message: "Shortcut output must be a private regular file owned by the current user",
        details: [
          "path": .string(staged.path),
          "link_count": .integer(Int64(expected.st_nlink)),
        ],
        exitCode: 5
      )
    }

    let descriptor = open(staged.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw AgentError(
        code: "shortcut_output_invalid",
        message: "Could not open the staged Shortcut output safely",
        details: ["path": .string(staged.path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
    var descriptorIsOpen = true
    do {
      var actual = stat()
      guard fstat(descriptor, &actual) == 0,
        (actual.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        actual.st_uid == getuid(),
        actual.st_nlink == 1,
        actual.st_dev == expected.st_dev,
        actual.st_ino == expected.st_ino
      else {
        throw AgentError(
          code: "shortcut_output_invalid",
          message: "Staged Shortcut output changed while it was being secured",
          details: ["path": .string(staged.path)],
          exitCode: 5
        )
      }
      var permissionStatus: Int32
      repeat {
        permissionStatus = fchmod(descriptor, 0o600)
      } while permissionStatus != 0 && errno == EINTR
      guard permissionStatus == 0 else {
        throw AgentError(
          code: "shortcut_output_invalid",
          message: "Could not secure the staged Shortcut output permissions",
          details: ["path": .string(staged.path), "errno": .integer(Int64(errno))],
          exitCode: 5
        )
      }
      while fsync(descriptor) != 0 {
        if errno == EINTR { continue }
        throw AgentError(
          code: "shortcut_output_sync_failed",
          message: "Could not sync the staged Shortcut output",
          details: ["path": .string(staged.path), "errno": .integer(Int64(errno))],
          exitCode: 5
        )
      }
      let secured = try capture(
        descriptor: descriptor,
        path: staged.path,
        expectedIdentity: actual
      )
      descriptorIsOpen = false
      guard close(descriptor) == 0 else {
        throw AgentError(
          code: "shortcut_output_sync_failed",
          message: "Could not close the staged Shortcut output",
          details: ["path": .string(staged.path), "errno": .integer(Int64(errno))],
          exitCode: 5
        )
      }

      try AtomicFileWriter.publish(
        staged,
        to: destination,
        replacingExisting: false,
        validateBeforeCommit: validateBeforePublish,
        validatePublishedItem: { published in
          try validatePublished(
            published,
            expected: secured.info,
            expectedDigest: secured.digest
          )
        }
      )
    } catch let rollback as AtomicPathTransaction.RollbackFailure {
      if descriptorIsOpen { _ = close(descriptor) }
      throw rollback.error
    } catch {
      if descriptorIsOpen { _ = close(descriptor) }
      throw error
    }
    try AtomicFileWriter.syncDirectory(destination.deletingLastPathComponent())
  }

  private struct SecuredRegularFile {
    let info: stat
    let digest: String
  }

  private static func capture(
    descriptor: Int32,
    path: String,
    expectedIdentity: stat
  ) throws -> SecuredRegularFile {
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
      throw changed(
        path: path,
        message: "Could not rewind the staged Shortcut output for exact verification",
        errorNumber: errno
      )
    }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      before.st_uid == getuid(),
      before.st_nlink == 1,
      before.st_dev == expectedIdentity.st_dev,
      before.st_ino == expectedIdentity.st_ino
    else {
      throw changed(
        path: path,
        message: "Staged Shortcut output changed while it was being persisted"
      )
    }

    var hasher = SHA256Hasher()
    var byteCount: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      guard !Task.isCancelled else {
        throw AgentError(
          code: "operation_cancelled",
          message: "Shortcut output verification was cancelled",
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
          throw changed(
            path: path,
            message: "Shortcut output size exceeded the supported range"
          )
        }
        byteCount = next.partialValue
        hasher.update(Data(buffer.prefix(count)))
        continue
      }
      if count == 0 { break }
      if errno == EINTR { continue }
      throw changed(
        path: path,
        message: "Could not read the staged Shortcut output for exact verification",
        errorNumber: errno
      )
    }

    var after = stat()
    guard fstat(descriptor, &after) == 0,
      stableDuringVerification(before, after),
      byteCount == Int64(after.st_size)
    else {
      throw changed(
        path: path,
        message: "Staged Shortcut output changed during exact verification"
      )
    }
    return SecuredRegularFile(
      info: after,
      digest: SHA256.hex(hasher.finalize())
    )
  }

  private static func validatePublished(
    _ published: URL,
    expected: stat,
    expectedDigest: String
  ) throws {
    let descriptor = open(
      published.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
      throw changed(
        path: published.path,
        message: "Could not open the published Shortcut output for exact verification",
        errorNumber: errno
      )
    }
    var descriptorIsOpen = true
    do {
      let current = try capture(
        descriptor: descriptor,
        path: published.path,
        expectedIdentity: expected
      )
      guard sameFile(current.info, expected), current.digest == expectedDigest else {
        throw changed(
          path: published.path,
          message: "Staged Shortcut output changed at the atomic publication boundary"
        )
      }
      descriptorIsOpen = false
      guard close(descriptor) == 0 else {
        throw AgentError(
          code: "shortcut_output_verification_failed",
          message: "Could not close the published Shortcut output after exact verification",
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
          code: "shortcut_output_verification_cleanup_failed",
          message: "Shortcut output verification failed and its descriptor could not be closed",
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

  private static func sameFile(_ current: stat, _ expected: stat) -> Bool {
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

  private static func changed(
    path: String,
    message: String,
    errorNumber: Int32? = nil
  ) -> AgentError {
    var details: [String: JSONValue] = ["path": .string(path)]
    if let errorNumber { details["errno"] = .integer(Int64(errorNumber)) }
    return AgentError(
      code: "shortcut_output_changed",
      message: message,
      details: details,
      exitCode: 6
    )
  }
}
