import Foundation
@testable import MacHandsfreeCore
import MacHandsfreeSQLite
import MacHandsfreeState
import Testing

struct ExecutionRecoveryTests {
  @Test func reopeningRunningExecutionPreservesUncertaintyAndLedger() async throws {
    let directory = try fixtureDirectory()
    defer { removeFixture(directory) }
    let state = try stateStore(in: directory)
    let input = plannedInput(in: directory)
    let preview = JSONValue.object(["expected_revision": .string("fixture-revision")])
    let plan = try await state.createPlan(
      command: "files.write", input: input, preview: preview, lifetime: 600)
    let key = "running-state-fixture"
    let decision = try await state.beginExecution(
      command: plan.command, planToken: plan.token, idempotencyKey: key)
    #expect(decision == .execute(input: input, preview: preview))
    let before = try executionRow(in: directory, key: key)

    let reopened = try stateStore(in: directory)
    do {
      _ = try await reopened.beginExecution(
        command: plan.command, planToken: plan.token, idempotencyKey: key)
      Issue.record("A persisted running execution must not be dispatched or replayed")
    } catch let error as AgentError {
      #expect(error.code == "operation_in_progress")
      #expect(error.exitCode == 6)
      #expect(error.outcomeUncertain)
    }

    let after = try executionRow(in: directory, key: key)
    #expect(after == before)
    #expect(after["status"]?.text == "running")
    #expect(after["result_json"] == SQLiteValue.null)
  }

  @Test func executingPersistedRunningPlanReportsUncertaintyWithoutAnotherEffect() async throws {
    let directory = try fixtureDirectory()
    defer { removeFixture(directory) }
    let state = try stateStore(in: directory)
    let plan = try await state.createPlan(
      command: "files.write", input: plannedInput(in: directory),
      preview: .object(["expected_revision": .string("fixture-revision")]), lifetime: 600)
    let key = "running-pipeline-fixture"
    _ = try await state.beginExecution(
      command: plan.command, planToken: plan.token, idempotencyKey: key)
    let before = try executionRow(in: directory, key: key)

    let executor = RecordingExecutor(result: .object(["written": .bool(true)]))
    let pipeline = ExecutionPipeline(executor: executor, state: try stateStore(in: directory))
    let resolved = try CommandRegistry().resolve(arguments: ["files", "write", "execute"])
    let response = await pipeline.invoke(
      resolved, input: executionInput(plan: plan, key: key))

    #expect(!response.ok)
    #expect(response.error?.code == "operation_in_progress")
    #expect(response.error?.outcomeUncertain == true)
    #expect(response.json["error"]?["outcome_uncertain"]?.boolValue == true)
    #expect(response.json["meta"]?["replayed"]?.boolValue == false)
    #expect(await executor.mutationCount == 0)
    #expect(try executionRow(in: directory, key: key) == before)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "effect.txt").path))
  }

  @Test func completedExecutionReplaysPersistedResultWithoutAnotherEffect() async throws {
    let directory = try fixtureDirectory()
    defer { removeFixture(directory) }
    let state = try stateStore(in: directory)
    let plan = try await state.createPlan(
      command: "files.write", input: plannedInput(in: directory),
      preview: .object(["expected_revision": .string("fixture-revision")]), lifetime: 600)
    let key = "succeeded-pipeline-fixture"
    let result = JSONValue.object(["written": .bool(true), "revision": .string("new-revision")])
    let executor = RecordingExecutor(result: result)
    let pipeline = ExecutionPipeline(executor: executor, state: state)
    let resolved = try CommandRegistry().resolve(arguments: ["files", "write", "execute"])
    let first = await pipeline.invoke(resolved, input: executionInput(plan: plan, key: key))
    try #require(first.ok)
    #expect(first.json["data"] == result)
    #expect(first.json["meta"]?["replayed"]?.boolValue == false)
    #expect(await executor.mutationCount == 1)
    let before = try executionRow(in: directory, key: key)

    let resumedExecutor = RecordingExecutor(result: .null)
    let resumed = ExecutionPipeline(
      executor: resumedExecutor, state: try stateStore(in: directory))
    let replay = await resumed.invoke(resolved, input: executionInput(plan: plan, key: key))

    #expect(replay.ok)
    #expect(replay.error == nil)
    #expect(replay.json["data"] == result)
    #expect(replay.json["meta"]?["replayed"]?.boolValue == true)
    #expect(await resumedExecutor.mutationCount == 0)
    #expect(try executionRow(in: directory, key: key) == before)
  }

  private func fixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }

  private func stateStore(in directory: URL) throws -> SQLiteExecutionStateStore {
    try SQLiteExecutionStateStore(
      directory: StateDirectory(environment: ["MAC_HANDSFREE_STATE_DIR": directory.path]))
  }

  private func plannedInput(in directory: URL) -> JSONValue {
    .object([
      "path": .string(directory.appending(path: "effect.txt").path),
      "content": .string("fixture content"),
    ])
  }

  private func executionInput(plan: MutationPlan, key: String) -> JSONValue {
    .object(["plan_token": .string(plan.token), "idempotency_key": .string(key)])
  }

  private func executionRow(in directory: URL, key: String) throws -> [String: SQLiteValue] {
    let database = try SQLiteDatabase(path: directory.appending(path: "state.sqlite3").path)
    return try #require(database.query(
      "SELECT * FROM executions WHERE idempotency_key = ?", values: [.text(key)]).first)
  }

  private func removeFixture(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch { Issue.record("Execution recovery fixture cleanup failed: \(error)") }
  }
}

private actor RecordingExecutor: CommandExecutor {
  private let result: JSONValue
  private(set) var mutationCount = 0

  init(result: JSONValue) {
    self.result = result
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> CommandPreview {
    throw AgentError.invalid("This fixture only accepts mutation execution")
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    throw AgentError.invalid("This fixture only accepts mutation execution")
  }

  func executeMutation(
    command: CommandSpec, input: JSONValue, plannedPreview: JSONValue
  ) async throws -> JSONValue {
    mutationCount += 1
    return result
  }
}
