import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Persists a staged copy before its atomic rename makes it externally visible.
enum StagedTreeSynchronizer {
  static func sync(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw failure(path: url.path, operation: "inspect", errnoValue: errno)
    }
    let type = info.st_mode & mode_t(S_IFMT)
    if type == mode_t(S_IFLNK) { return }
    if type == mode_t(S_IFDIR) {
      let children: [URL]
      do {
        children = try FileManager.default.contentsOfDirectory(
          at: url, includingPropertiesForKeys: nil
        ).sorted { $0.path < $1.path }
      } catch {
        throw AgentError(
          code: "file_copy_failed",
          message: "Could not enumerate staged directory before publish",
          details: ["path": .string(url.path), "reason": .string(String(describing: error))],
          exitCode: 5
        )
      }
      for child in children { try sync(child) }
      try syncDescriptor(at: url, expected: info, operation: "sync directory")
      return
    }
    if type == mode_t(S_IFREG) {
      try syncDescriptor(at: url, expected: info, operation: "sync file")
    }
  }

  private static func syncDescriptor(
    at url: URL,
    expected: stat,
    operation: String
  ) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw failure(path: url.path, operation: "open", errnoValue: errno)
    }

    var current = stat()
    let statStatus = fstat(descriptor, &current)
    let statErrno = errno
    let sameItem =
      statStatus == 0
      && current.st_dev == expected.st_dev
      && current.st_ino == expected.st_ino
      && (current.st_mode & mode_t(S_IFMT)) == (expected.st_mode & mode_t(S_IFMT))

    var syncStatus: Int32 = -1
    var syncErrno: Int32 = 0
    if sameItem {
      repeat {
        syncStatus = fsync(descriptor)
      } while syncStatus != 0 && errno == EINTR
      syncErrno = errno
    }

    let closeStatus = close(descriptor)
    let closeErrno = errno

    guard sameItem else {
      var details: [String: JSONValue] = [:]
      if statStatus != 0 {
        details["stat_errno"] = .integer(Int64(statErrno))
      } else {
        details["reason"] = .string("staged_path_changed_before_sync")
      }
      if closeStatus != 0 { details["close_errno"] = .integer(Int64(closeErrno)) }
      throw failure(path: url.path, operation: "verify opened item", details: details)
    }

    guard syncStatus == 0, closeStatus == 0 else {
      var details: [String: JSONValue] = [:]
      if syncStatus != 0 { details["sync_errno"] = .integer(Int64(syncErrno)) }
      if closeStatus != 0 { details["close_errno"] = .integer(Int64(closeErrno)) }
      throw failure(path: url.path, operation: operation, details: details)
    }
  }

  private static func failure(
    path: String,
    operation: String,
    errnoValue: Int32? = nil,
    details extraDetails: [String: JSONValue] = [:]
  ) -> AgentError {
    var details = extraDetails
    details["path"] = .string(path)
    details["operation"] = .string(operation)
    if let errnoValue { details["errno"] = .integer(Int64(errnoValue)) }
    return AgentError(
      code: "file_copy_failed",
      message: "Could not persist staged copy before publish",
      details: details,
      exitCode: 5
    )
  }
}
