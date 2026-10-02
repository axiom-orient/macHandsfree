public import Foundation
import MacHandsfreeCore
import MacHandsfreePlatform

/// In-process host facade. It reuses the CLI's registry, validation, signed plans,
/// SQLite idempotency and platform executors; it does not create a second runtime.
public struct MacHandsfreeClient: Sendable {
  private let runtime: AgentRuntime
  public init(stateDirectory: URL) throws {
    guard stateDirectory.isFileURL else {
      throw MacHandsfreeClientError(code: "invalid_state_directory", message: "A local state directory is required.")
    }
    runtime = try RuntimeFactory.make(environment: ["MAC_HANDSFREE_STATE_DIR": stateDirectory.path])
  }

  public func commands() throws -> [MacHandsfreeCommand] {
    try runtime.registry.commands.map {
      MacHandsfreeCommand(id: $0.id, summary: $0.summary, service: $0.service,
        isMutation: $0.kind == .mutation, risk: $0.risk.rawValue, permissions: $0.permissions,
        schemaJSON: try encoded($0.inputSchema.json))
    }
  }

  public func read(commandID: String, inputJSON: String) async throws -> MacHandsfreeResult {
    let command = try command(commandID, kind: .read)
    let response = await runtime.pipeline.invoke(ResolvedCommand(spec: command, mode: .read),
      input: try input(inputJSON))
    return try result(response)
  }

  /// Reads the canonical `files.read` input as bounded bytes without a JSON/base64 round trip.
  @concurrent public func readFileBytes(path: String, maximumBytes: Int) async throws
    -> MacHandsfreeFileReadResult
  {
    let command = try command("files.read", kind: .read)
    let input = JSONValue.object([
      "path": .string(path),
      "encoding": .string("base64"),
      "max_bytes": .integer(Int64(maximumBytes)),
    ])
    do {
      try command.inputSchema.validate(input)
      try CommandInputValidator.validate(command: command, input: input)
      let file = try readStableFileBytes(path: path, maximumBytes: maximumBytes)
      return .bytes(MacHandsfreeFileData(path: file.path, data: file.data))
    } catch let error as AgentError {
      return .failure(try result(.failure(command: command.id, error: error)))
    }
  }

  public func prepare(commandID: String, inputJSON: String) async throws -> MacHandsfreePlan {
    let command = try command(commandID, kind: .mutation)
    let response = await runtime.pipeline.invoke(ResolvedCommand(spec: command, mode: .plan),
      input: try input(inputJSON))
    guard response.ok else { throw failure(response) }
    guard let plan = response.json.objectValue?["data"]?.objectValue?["plan"]?.objectValue,
      let token = plan["token"]?.stringValue else {
      throw MacHandsfreeClientError(code: "invalid_plan", message: "The runtime returned an invalid plan.")
    }
    var visible = plan
    visible.removeValue(forKey: "token")
    return MacHandsfreePlan(commandID: commandID, token: token, previewJSON: try encoded(.object(visible)))
  }

  /// Removes a signed plan that has not started execution. Executed plans remain for replay safety.
  @discardableResult
  public func discard(planToken: String) async throws -> Bool {
    try await runtime.pipeline.discardPlan(token: planToken)
  }

  public func execute(commandID: String, planToken: String, idempotencyKey: String) async throws -> MacHandsfreeResult {
    let command = try command(commandID, kind: .mutation)
    let response = await runtime.pipeline.invoke(ResolvedCommand(spec: command, mode: .execute), input: .object([
      "plan_token": .string(planToken), "idempotency_key": .string(idempotencyKey),
    ]))
    return try result(response)
  }

  private func command(_ id: String, kind: CommandKind) throws -> CommandSpec {
    guard let command = runtime.registry.command(id: id), command.kind == kind else {
      throw MacHandsfreeClientError(code: "invalid_command_kind", message: "Unknown command or wrong invocation mode: \(id)")
    }
    return command
  }
  private func input(_ text: String) throws -> JSONValue {
    guard text.utf8.count <= ProductInfo.maximumRequestBytes else {
      throw MacHandsfreeClientError(code: "input_too_large", message: "Request exceeds the runtime limit.")
    }
    return try JSONValue.parse(Data(text.utf8))
  }
  private func encoded(_ value: JSONValue) throws -> String {
    String(decoding: try value.encoded(), as: UTF8.self)
  }
  private func result(_ response: ResponseEnvelope) throws -> MacHandsfreeResult {
    MacHandsfreeResult(
      outcome: response.ok ? .succeeded : response.error?.outcomeUncertain == true ? .uncertain : .failed,
      json: try encoded(response.json))
  }
  private func failure(_ response: ResponseEnvelope) -> MacHandsfreeClientError {
    MacHandsfreeClientError(code: response.error?.code ?? "command_failed",
      message: response.error?.message ?? "Command preparation failed.")
  }
}
