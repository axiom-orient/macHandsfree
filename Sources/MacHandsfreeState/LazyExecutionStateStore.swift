package import Foundation
package import MacHandsfreeCore

package actor LazyExecutionStateStore: ExecutionStateStore {
  private let directory: StateDirectory
  private var store: SQLiteExecutionStateStore?

  package init(directory: StateDirectory) { self.directory = directory }

  package func createPlan(
    command: String, input: JSONValue, preview: JSONValue, lifetime: TimeInterval
  ) async throws -> MutationPlan {
    try await stateStore().createPlan(
      command: command, input: input, preview: preview, lifetime: lifetime)
  }

  package func beginExecution(
    command: String, planToken: String, idempotencyKey: String
  ) async throws -> BeginExecution {
    try await stateStore().beginExecution(
      command: command, planToken: planToken, idempotencyKey: idempotencyKey)
  }

  package func completeSuccess(idempotencyKey: String, result: JSONValue) async throws {
    try await stateStore().completeSuccess(idempotencyKey: idempotencyKey, result: result)
  }

  package func completeFailure(idempotencyKey: String, error: AgentError) async throws {
    try await stateStore().completeFailure(idempotencyKey: idempotencyKey, error: error)
  }

  package func discardPlan(token: String) async throws -> Bool {
    try await stateStore().discardPlan(token: token)
  }

  private func stateStore() throws -> SQLiteExecutionStateStore {
    if let store { return store }
    let created = try SQLiteExecutionStateStore(directory: directory)
    store = created
    return created
  }
}
