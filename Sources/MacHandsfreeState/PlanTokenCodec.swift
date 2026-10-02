import Foundation
import MacHandsfreeCore

struct PlanTokenCodec: Sendable {
  struct Parsed: Sendable {
    let id: String
    let signature: String
  }

  private let secret: Data

  init(secret: Data) { self.secret = secret }

  func issue(
    id: String, command: String, inputJSON: String, previewJSON: String, expiresAt: Double
  ) throws -> String {
    let signature = SHA256.hmacHex(
      key: secret,
      message: try signingMessage(
        id: id, command: command, inputJSON: inputJSON,
        previewJSON: previewJSON, expiresAt: expiresAt))
    return "v3.\(id).\(signature)"
  }

  func parse(_ token: String) throws -> Parsed {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "v3",
      let identifier = UUID(uuidString: String(parts[1])),
      identifier.uuidString.lowercased() == String(parts[1])
    else {
      throw AgentError(
        code: "plan_token_invalid",
        message: "The plan token is malformed or uses an unsupported version",
        details: ["recovery": .string("Prepare and approve a new plan")],
        exitCode: 6
      )
    }
    let id = String(parts[1])
    return Parsed(id: id, signature: String(parts[2]))
  }

  func verifies(
    _ token: Parsed, command: String, inputJSON: String, previewJSON: String, expiresAt: Double
  ) -> Bool {
    guard let message = try? signingMessage(
      id: token.id, command: command, inputJSON: inputJSON,
      previewJSON: previewJSON, expiresAt: expiresAt)
    else { return false }
    return SHA256.verifyHMACHex(token.signature, key: secret, message: message)
  }

  private func signingMessage(
    id: String, command: String, inputJSON: String, previewJSON: String, expiresAt: Double
  ) throws -> Data {
    let payload = JSONValue.object([
      "version": .integer(3), "id": .string(id), "command": .string(command),
      "input_json": .string(inputJSON), "preview_json": .string(previewJSON),
      "expires_at": .number(expiresAt),
    ])
    return try payload.encoded()
  }
}
