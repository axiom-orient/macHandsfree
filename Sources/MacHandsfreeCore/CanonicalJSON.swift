import Foundation

package enum CanonicalJSON {
  package static func string(_ value: JSONValue) throws -> String {
    guard let result = String(data: try value.encoded(), encoding: .utf8) else {
      throw AgentError(
        code: "json_encoding_failed", message: "Could not encode JSON as UTF-8", exitCode: 5)
    }
    return result
  }
}
