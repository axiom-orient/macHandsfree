import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum StateSecretStore {
  static func loadOrCreate(in directory: URL) throws -> Data {
    let path = directory.appending(path: "plan-secret").path
    // Reach the same-handle file check even when the path names a FIFO without a writer.
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if descriptor >= 0 {
      defer { close(descriptor) }
      return try readSecret(descriptor)
    }
    guard errno == ENOENT else { throw secretError("Could not open the plan secret") }

    var generator = SystemRandomNumberGenerator()
    let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    let created = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard created >= 0 else {
      if errno == EEXIST { return try loadOrCreate(in: directory) }
      throw secretError("Could not create the plan secret")
    }
    defer { close(created) }
    try writeAll(secret, to: created)
    guard fsync(created) == 0 else { throw secretError("Could not persist the plan secret") }
    return secret
  }

  private static func readSecret(_ descriptor: Int32) throws -> Data {
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
      info.st_mode & mode_t(0o777) == mode_t(0o600)
    else { throw secretError("The plan secret must be an owned regular file with mode 0600") }

    var bytes = [UInt8](repeating: 0, count: 33)
    var total = 0
    while total < bytes.count {
      let count = bytes.withUnsafeMutableBufferPointer { buffer in
        read(descriptor, buffer.baseAddress?.advanced(by: total), buffer.count - total)
      }
      if count < 0, errno == EINTR { continue }
      // A read failure after 32 bytes is not evidence that the file ended at 32 bytes.
      guard count >= 0 else { throw secretError("Could not read the plan secret") }
      if count == 0 { break }
      total += count
    }
    guard total == 32 else { throw secretError("The plan secret has an invalid length") }
    return Data(bytes.prefix(32))
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw secretError("The plan secret is empty")
      }
      var offset = 0
      while offset < buffer.count {
        let written = write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw secretError("Could not write the plan secret") }
        offset += written
      }
    }
  }

  private static func secretError(_ message: String) -> AgentError {
    AgentError(
      code: "plan_secret_unavailable", message: message,
      details: ["errno": .integer(Int64(errno))], exitCode: 5)
  }
}
