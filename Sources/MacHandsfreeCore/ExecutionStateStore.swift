package import Foundation

package struct MutationPlan: Sendable {
  let token: String
  let command: String
  let input: JSONValue
  let preview: JSONValue
  let expiresAt: Date

  package init(
    token: String,
    command: String,
    input: JSONValue,
    preview: JSONValue,
    expiresAt: Date
  ) {
    self.token = token
    self.command = command
    self.input = input
    self.preview = preview
    self.expiresAt = expiresAt
  }

  func json(presenting preview: JSONValue) -> JSONValue {
    .object([
      "token": .string(token),
      "command": .string(command),
      "input": input,
      "preview": preview,
      "expires_at": .string(ISO8601DateFormatter.agentString(from: expiresAt)),
    ])
  }
}

package enum BeginExecution: Sendable, Equatable {
  case execute(input: JSONValue, preview: JSONValue)
  case replay(result: JSONValue)
}

package protocol ExecutionStateStore: Sendable {
  func createPlan(command: String, input: JSONValue, preview: JSONValue, lifetime: TimeInterval)
    async throws -> MutationPlan
  func discardPlan(token: String) async throws -> Bool
  func beginExecution(command: String, planToken: String, idempotencyKey: String) async throws
    -> BeginExecution
  func completeSuccess(idempotencyKey: String, result: JSONValue) async throws
  func completeFailure(idempotencyKey: String, error: AgentError) async throws
}
