import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct PlannedDirectories {
  private let urls: [URL]

  static func create(_ directories: [URL]) throws -> PlannedDirectories {
    var created: [URL] = []
    do {
      for directory in directories {
        guard !Task.isCancelled else {
          throw AgentError(
            code: "operation_cancelled",
            message: "Directory creation was cancelled before completion",
            exitCode: 6
          )
        }
        var status: Int32
        repeat {
          status = platformMkdir(directory.path, 0o755)
        } while status != 0 && errno == EINTR
        guard status == 0 else {
          let currentErrno = errno
          throw AgentError(
            code: currentErrno == EEXIST ? "target_exists" : "directory_creation_failed",
            message:
              currentErrno == EEXIST
              ? "A planned directory was created concurrently"
              : "Could not create a planned directory",
            details: [
              "path": .string(directory.path),
              "errno": .integer(Int64(currentErrno)),
            ],
            exitCode: currentErrno == EEXIST ? 6 : 5
          )
        }
        created.append(directory)
      }
      return PlannedDirectories(urls: created)
    } catch {
      try PlannedDirectories(urls: created).rollback(after: error)
      throw error
    }
  }

  func rollback(after originalError: any Error) throws {
    guard !urls.isEmpty else { return }
    var failures: [JSONValue] = []
    for directory in urls.reversed() {
      var status: Int32
      repeat {
        status = rmdir(directory.path)
      } while status != 0 && errno == EINTR

      if status != 0 {
        let currentErrno = errno
        if currentErrno != ENOENT {
          failures.append(
            .object([
              "operation": .string("remove_directory"),
              "path": .string(directory.path),
              "errno": .integer(Int64(currentErrno)),
            ]))
        }
        continue
      }

      do {
        try DirectorySync.sync(directory.deletingLastPathComponent())
      } catch {
        failures.append(
          .object([
            "operation": .string("sync_parent"),
            "path": .string(directory.deletingLastPathComponent().path),
            "reason": .string(String(describing: error)),
          ]))
      }
    }
    guard failures.isEmpty else {
      throw AgentError(
        code: "file_parent_cleanup_failed",
        message: "A failed file mutation left or could not durably remove planned directories",
        details: [
          "original_error": .string(String(describing: originalError)),
          "cleanup_failures": .array(failures),
        ],
        exitCode: 5,
        outcomeUncertain: true
      )
    }
  }

  func syncParents() throws {
    for directory in urls.reversed() {
      try DirectorySync.sync(directory.deletingLastPathComponent())
    }
  }
}

enum DirectorySync {
  static func sync(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw AgentError(
        code: "directory_sync_failed",
        message: "Could not open parent directory for sync",
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
      var details: [String: JSONValue] = ["path": .string(url.path)]
      if syncStatus != 0 { details["sync_errno"] = .integer(Int64(syncErrno)) }
      if closeStatus != 0 { details["close_errno"] = .integer(Int64(closeErrno)) }
      throw AgentError(
        code: "directory_sync_failed",
        message: "Could not sync parent directory",
        details: details,
        exitCode: 5,
        outcomeUncertain: true
      )
    }
  }
}

private func platformMkdir(_ path: String, _ mode: mode_t) -> Int32 {
  #if canImport(Darwin)
    return Darwin.mkdir(path, mode)
  #else
    return Glibc.mkdir(path, mode)
  #endif
}
