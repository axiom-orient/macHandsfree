package import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Reads a finite request body without first buffering unbounded input.
package enum BoundedInputReader {
  package static func readAll(
    from handle: FileHandle,
    maximumBytes: Int,
    errorCode: String = "input_too_large",
    errorMessage: String = "Input exceeds the configured limit"
  ) throws -> Data {
    precondition(maximumBytes >= 0)
    var result = Data()
    result.reserveCapacity(min(maximumBytes, 64 * 1_024))
    var bytes = [UInt8](repeating: 0, count: 64 * 1_024)

    while true {
      let remaining = maximumBytes - result.count
      // Add the overflow probe byte only after bounding the arithmetic by buffer capacity.
      let requested = remaining >= bytes.count ? bytes.count : remaining + 1
      let count = try readChunk(handle.fileDescriptor, into: &bytes, count: requested)
      if count == 0 { return result }
      guard count <= remaining else {
        throw AgentError(
          code: errorCode,
          message: errorMessage,
          details: ["maximum_bytes": .integer(Int64(maximumBytes))],
          exitCode: 2
        )
      }
      result.append(contentsOf: bytes.prefix(count))
    }
  }

  private static func readChunk(
    _ descriptor: Int32,
    into bytes: inout [UInt8],
    count: Int
  ) throws -> Int {
    while true {
      let value = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
        guard let base = rawBuffer.baseAddress else { return 0 }
        #if canImport(Darwin)
          return Darwin.read(descriptor, base, count)
        #else
          return Glibc.read(descriptor, base, count)
        #endif
      }
      if value >= 0 { return value }
      if errno == EINTR { continue }
      throw AgentError(
        code: "input_read_failed",
        message: "Could not read standard input",
        details: ["errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
  }
}
