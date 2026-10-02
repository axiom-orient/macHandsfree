package import Foundation
import Crypto

package struct SHA256Hasher: Sendable {
  private var hasher = Crypto.SHA256()

  package init() {}

  package mutating func update(_ data: Data) {
    hasher.update(data: data)
  }

  package mutating func finalize() -> Data {
    let digest = hasher.finalize()
    return digest.withUnsafeBytes { Data($0) }
  }

  /// Encodes the digest already produced by this stream; it does not hash it again.
  package mutating func finalizeHex() -> String {
    finalize().map { String(format: "%02x", $0) }.joined()
  }
}

package enum SHA256 {
  static func digest(_ data: Data) -> Data {
    let digest = Crypto.SHA256.hash(data: data)
    return digest.withUnsafeBytes { Data($0) }
  }

  package static func hex(_ data: Data) -> String {
    digest(data).map { String(format: "%02x", $0) }.joined()
  }

  static func hmac(key: Data, message: Data) -> Data {
    let key = SymmetricKey(data: key)
    let code = HMAC<Crypto.SHA256>.authenticationCode(for: message, using: key)
    return code.withUnsafeBytes { Data($0) }
  }

  package static func hmacHex(key: Data, message: Data) -> String {
    hmac(key: key, message: message).map { String(format: "%02x", $0) }.joined()
  }

  package static func verifyHMACHex(_ signature: String, key: Data, message: Data) -> Bool {
    guard let code = decodeHMACHex(signature) else { return false }
    return HMAC<Crypto.SHA256>.isValidAuthenticationCode(
      code,
      authenticating: message,
      using: SymmetricKey(data: key)
    )
  }

  private static func decodeHMACHex(_ signature: String) -> Data? {
    let bytes = Array(signature.utf8)
    guard bytes.count == 64 else { return nil }
    var decoded = Data()
    decoded.reserveCapacity(32)
    for offset in stride(from: 0, to: bytes.count, by: 2) {
      guard let high = hexNibble(bytes[offset]), let low = hexNibble(bytes[offset + 1]) else {
        return nil
      }
      decoded.append((high << 4) | low)
    }
    return decoded
  }

  private static func hexNibble(_ byte: UInt8) -> UInt8? {
    return switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
  }
}
