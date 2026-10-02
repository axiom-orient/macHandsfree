import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Detaches a reviewed item from its public path before cleanup so deletion is externally atomic.
enum AtomicTreeDeleter {
  static func remove(
    _ url: URL,
    info: stat,
    recursive: Bool,
    fileManager: FileManager = .default,
    validateBeforeCommit: () throws -> Void = {},
    validateDetachedItem: (URL) throws -> Void = { _ in }
  ) throws {
    let parent = url.deletingLastPathComponent()
    let staged = parent.appendingPathComponent(
      ".mac-handsfree-\(UUID().uuidString).deleting",
      isDirectory: (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    )
    let type = info.st_mode & mode_t(S_IFMT)

    do {
      try AtomicPathTransaction.detach(
        url,
        to: staged,
        validateBeforeCommit: validateBeforeCommit
      ) {
        try validateDetachedItem(staged)
        if type == mode_t(S_IFDIR), !recursive {
          let children: [String]
          do {
            children = try fileManager.contentsOfDirectory(atPath: staged.path)
          } catch {
            throw AgentError(
              code: "file_delete_failed",
              message: "Could not inspect the detached directory before deletion",
              details: [
                "path": .string(url.path),
                "staged_path": .string(staged.path),
                "reason": .string(String(describing: error)),
              ],
              exitCode: 5
            )
          }
          guard children.isEmpty else {
            throw AgentError(
              code: "directory_not_empty",
              message: "Directory is not empty and recursive is false",
              details: ["path": .string(url.path)],
              exitCode: 6
            )
          }
        }
      }
    } catch let rollback as AtomicPathTransaction.RollbackFailure {
      throw rollback.error
    }

    do {
      try syncDirectory(parent)
    } catch let error as AgentError {
      throw AgentError(
        code: error.code,
        message: "Item was detached, but its parent could not be durably synced",
        details: error.details.merging([
          "original_path": .string(url.path),
          "staged_path": .string(staged.path),
        ]) { current, _ in current },
        exitCode: error.exitCode,
        outcomeUncertain: true
      )
    }

    do {
      if type == mode_t(S_IFDIR) {
        if recursive {
          try fileManager.removeItem(at: staged)
        } else {
          try removeEmptyDirectory(staged)
        }
      } else {
        try unlinkItem(staged)
      }
    } catch let error as AgentError {
      throw AgentError(
        code: error.code,
        message: "Item was detached, but cleanup did not complete",
        details: error.details.merging([
          "original_path": .string(url.path),
          "staged_path": .string(staged.path),
        ]) { current, _ in current },
        exitCode: error.exitCode,
        outcomeUncertain: true
      )
    } catch {
      throw AgentError(
        code: "file_delete_cleanup_failed",
        message: "Item was detached, but recursive cleanup did not complete",
        details: [
          "original_path": .string(url.path),
          "staged_path": .string(staged.path),
          "reason": .string(String(describing: error)),
        ],
        exitCode: 5,
        outcomeUncertain: true
      )
    }

    do {
      try syncDirectory(parent)
    } catch let error as AgentError {
      throw AgentError(
        code: error.code,
        message: "Deletion completed, but its parent could not be durably synced",
        details: error.details.merging(["original_path": .string(url.path)]) { current, _ in
          current
        },
        exitCode: error.exitCode,
        outcomeUncertain: true
      )
    }
  }

  private static func removeEmptyDirectory(_ url: URL) throws {
    while rmdir(url.path) != 0 {
      if errno == EINTR { continue }
      let currentErrno = errno
      if currentErrno == ENOTEMPTY || currentErrno == EEXIST {
        throw AgentError(
          code: "directory_not_empty",
          message: "Directory changed and is no longer empty",
          details: ["path": .string(url.path)],
          exitCode: 6
        )
      }
      throw AgentError(
        code: "file_delete_failed",
        message: "Could not remove the detached empty directory",
        details: ["path": .string(url.path), "errno": .integer(Int64(currentErrno))],
        exitCode: 5
      )
    }
  }

  private static func unlinkItem(_ url: URL) throws {
    while unlink(url.path) != 0 {
      if errno == EINTR { continue }
      throw AgentError(
        code: "file_delete_failed",
        message: "Could not unlink the detached filesystem item",
        details: ["path": .string(url.path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
  }

  private static func syncDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw AgentError(
        code: "directory_sync_failed",
        message: "Could not open a parent directory for sync",
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
        message: "Could not confirm parent directory durability",
        details: details,
        exitCode: 5,
        outcomeUncertain: true
      )
    }
  }
}
