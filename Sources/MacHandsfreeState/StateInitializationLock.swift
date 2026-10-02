import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum StateInitializationLock {
  static func withLock<T>(in directory: URL, _ body: () throws -> T) throws -> T {
    let path = directory.appending(path: ".initialize.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else {
      throw AgentError(
        code: "state_lock_failed", message: "Could not open the state initialization lock",
        details: ["errno": .integer(Int64(errno))], exitCode: 5)
    }
    defer { close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
      info.st_mode & mode_t(0o777) == mode_t(0o600)
    else {
      throw AgentError(
        code: "state_lock_invalid", message: "The state initialization lock is not a regular owned file",
        exitCode: 5)
    }
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw AgentError(
        code: "state_lock_failed", message: "Could not lock execution state initialization",
        details: ["errno": .integer(Int64(errno))], exitCode: 5)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }
}
