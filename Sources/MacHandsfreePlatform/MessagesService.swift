import Foundation
import MacHandsfreeCore

struct MessagesService: CurrentStateValidatedCommandService {
  private static let maximumSendSnapshotBytes = 64 * 1_024
  private static let maximumChatParticipants = 256
  let name = "messages"
  private let database: MessagesDatabaseReader
  private let runner: any AppleEventsRunning
  private let localPathGuard: LocalPathMutationGuard

  init(
    database: MessagesDatabaseReader,
    runner: any AppleEventsRunning,
    localPathGuard: LocalPathMutationGuard = LocalPathMutationGuard()
  ) {
    self.database = database
    self.runner = runner
    self.localPathGuard = localPathGuard
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    try requireSendCommand(command)
    let normalized = try normalizedInput(command: command, input: input)
    let object = try normalized.requiredObject()
    let target = object["chat_guid"]?.stringValue ?? object["handle"]?.stringValue ?? "Messages"
    guard target != "Messages" else { throw AgentError.invalid("Provide handle or chat_guid") }
    let details: [String: JSONValue]
    if command.id == "messages.send.file" {
      details = ["path": .string(try object.requiredString("path"))]
    } else {
      details = [:]
    }
    let preview = effects([effect(command.id, target, details: details)])
    let guardedPreview = try localPathGuard.attaching(
      pathGuardSpecs(command: command, input: normalized),
      to: preview
    )
    var selectors = object.filter { ["handle", "chat_guid", "service"].contains($0.key) }
    selectors["snapshot_for_send"] = .bool(true)
    let fetched = try await runner.run(
      script: "messages", operation: command.id, input: .object(selectors), mutation: false)
    var result = try guardedPreview.requiredObject()
    result["messages_send_snapshot"] = try sendSnapshot(
      fetched["send_snapshot"], command: command, input: object)
    return .object(result)
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    let object = try input.requiredObject()
    switch command.id {
    case "messages.chats.list":
      return try await database.chats(limit: object.optionalInt("limit", default: 50) ?? 50)
    case "messages.messages.list":
      guard let chatID = object.optionalInt("chat_id") else {
        throw AgentError.invalid("chat_id is required")
      }
      return try await database.messages(
        chatID: chatID,
        beforeRowID: object.optionalInt("before_row_id"),
        limit: object.optionalInt("limit", default: 100) ?? 100
      )
    case "messages.messages.search":
      return try await database.search(
        query: object.requiredString("query"),
        chatID: object.optionalInt("chat_id"),
        beforeRowID: object.optionalInt("before_row_id"),
        limit: object.optionalInt("limit", default: 100) ?? 100,
        scanLimit: object.optionalInt("scan_limit", default: 200) ?? 200
      )
    case "messages.attachments.list":
      return try await database.attachments(
        chatID: object.optionalInt("chat_id"),
        messageID: object.optionalInt("message_id"),
        limit: object.optionalInt("limit", default: 100) ?? 100
      )
    case "messages.send.text", "messages.send.file":
      throw invalidSendPreview("Messages sends require the route snapshot from a reviewed plan")
    default:
      throw AgentError(
        code: "unsupported_messages_command",
        message: "Messages service does not support command",
        exitCode: 5
      )
    }
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    try requireSendCommand(command)
    let specs = try pathGuardSpecs(command: command, input: input)
    try localPathGuard.validate(plannedPreview, specs: specs)
    let normalized = try normalizedInput(command: command, input: input)
    var object = try normalized.requiredObject()
    object["expected_send_snapshot"] = try sendSnapshot(
      plannedPreview["messages_send_snapshot"], command: command, input: object)
    let reviewedInput = JSONValue.object(object)
    if command.id == "messages.send.file" {
      return try await runFileMutation(
        command: command,
        input: reviewedInput,
        plannedPreview: plannedPreview,
        specs: specs
      )
    }
    return try await runner.run(
      script: "messages",
      operation: command.id,
      input: reviewedInput,
      mutation: true,
      validateBeforeLaunch: {
        try localPathGuard.validate(plannedPreview, specs: specs)
      }
    )
  }

  private func runFileMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue,
    specs: [LocalPathGuardSpec]
  ) async throws -> JSONValue {
    let source = URL(
      fileURLWithPath: try input.requiredObject().requiredString("path")
    ).standardizedFileURL
    let workspace = try LocalRegularFileSnapshotWorkspace(sources: [source])
    guard let snapshot = workspace.snapshotURLs.first else {
      throw AgentError(
        code: "local_input_snapshot_corrupt",
        message: "Messages attachment snapshot was not created",
        exitCode: 5
      )
    }
    let stagedInput = try LocalPathPolicy.replacingPath(input, key: "path", with: snapshot)
    let result: JSONValue
    do {
      result = try await runner.run(
        script: "messages",
        operation: command.id,
        input: stagedInput,
        mutation: true,
        validateBeforeLaunch: {
          try localPathGuard.validate(plannedPreview, specs: specs)
          try workspace.validate()
        }
      )
    } catch {
      let originalError = error
      try workspace.remove(
        originalError: originalError,
        outcomeUncertain: (originalError as? AgentError)?.outcomeUncertain ?? true
      )
      throw originalError
    }
    let publicResult = fileSendResult(result, source: source)
    try workspace.remove(
      originalError: nil,
      outcomeUncertain: true,
      observedResult: publicResult
    )
    return publicResult
  }

  private func fileSendResult(_ value: JSONValue, source: URL) -> JSONValue {
    guard var result = value.objectValue else { return value }
    result.removeValue(forKey: "path")
    result["source_path"] = .string(source.path)
    result["attachment_snapshot_used"] = .bool(true)
    return .object(result)
  }

  private func requireSendCommand(_ command: CommandSpec) throws {
    guard command.kind == .mutation,
      command.id == "messages.send.text" || command.id == "messages.send.file"
    else {
      throw AgentError(
        code: "invalid_mutation_route",
        message: "A read-only Messages command received mutation execution",
        details: ["command": .string(command.id)],
        exitCode: 5
      )
    }
  }

  private func sendSnapshot(
    _ value: JSONValue?, command: CommandSpec, input: [String: JSONValue]
  ) throws -> JSONValue {
    guard let value, let snapshot = value.objectValue,
      Set(snapshot.keys) == Set(["version", "command", "selector", "account", "recipient"]),
      snapshot["version"] == .integer(1), snapshot["command"]?.stringValue == command.id,
      let account = snapshot["account"]?.objectValue,
      Set(account.keys) == Set(["id", "description", "service", "enabled", "connection_status"]),
      let accountID = account["id"]?.stringValue, !accountID.isEmpty,
      account["description"]?.stringValue != nil, account["enabled"] == .bool(true),
      let service = account["service"]?.stringValue, ["iMessage", "RCS", "SMS"].contains(service),
      let status = account["connection_status"]?.stringValue,
      ["connected", "connecting", "disconnected", "disconnecting"].contains(status),
      let recipient = snapshot["recipient"]?.objectValue,
      recipient["account_id"]?.stringValue == accountID
    else { throw invalidSendPreview("The Messages route snapshot is missing or malformed") }
    let kind: String
    let selectorValue: String
    if let chat = input["chat_guid"]?.stringValue, input["handle"] == nil {
      kind = "chat"
      selectorValue = chat
      guard Set(recipient.keys) == Set(["kind", "id", "name", "account_id", "participants"]),
        recipient["id"]?.stringValue == chat, recipient["name"]?.stringValue != nil,
        let participants = recipient["participants"]?.arrayValue, !participants.isEmpty,
        participants.count <= Self.maximumChatParticipants
      else { throw invalidSendPreview("The Messages chat snapshot is incomplete") }
      var ids = Set<String>()
      for participant in participants {
        guard let fields = participant.objectValue,
          validParticipant(fields, accountID: accountID),
          let id = fields["id"]?.stringValue, ids.insert(id).inserted
        else { throw invalidSendPreview("The Messages participant set is incomplete or ambiguous") }
      }
    } else if let handle = input["handle"]?.stringValue, input["chat_guid"] == nil {
      kind = "participant"
      selectorValue = handle
      guard Set(recipient.keys) == Set(["kind", "lookup", "id", "handle", "name", "account_id"]),
        recipient["handle"]?.stringValue == handle,
        let lookup = recipient["lookup"]?.stringValue, ["listed_id", "named_handle"].contains(lookup),
        validParticipant(recipient.filter { !["kind", "lookup"].contains($0.key) }, accountID: accountID)
      else { throw invalidSendPreview("The Messages participant snapshot does not match the requested handle") }
    } else {
      throw invalidSendPreview("Messages requires exactly one handle or chat selector")
    }
    let requestedService = input["service"]?.stringValue ?? "auto"
    guard recipient["kind"]?.stringValue == kind,
      snapshot["selector"] == .object([
        "kind": .string(kind), "value": .string(selectorValue), "service": .string(requestedService),
      ]), requestedService == "auto" || requestedService == service
    else { throw invalidSendPreview("The Messages route snapshot does not match the requested service or target") }
    guard try value.encoded().count <= Self.maximumSendSnapshotBytes else {
      throw AgentError(code: "messages_snapshot_too_large",
        message: "The Messages route snapshot exceeds its limit; it was not truncated",
        details: ["maximum_bytes": .integer(Int64(Self.maximumSendSnapshotBytes))], exitCode: 6)
    }
    return value
  }

  private func validParticipant(_ value: [String: JSONValue], accountID: String) -> Bool {
    Set(value.keys) == Set(["id", "handle", "name", "account_id"])
      && value["id"]?.stringValue?.isEmpty == false
      && value["handle"]?.stringValue?.isEmpty == false
      && value["name"]?.stringValue != nil
      && value["account_id"]?.stringValue == accountID
  }

  private func invalidSendPreview(_ message: String) -> AgentError {
    AgentError(code: "plan_preview_invalid", message: message, exitCode: 6)
  }

  private func pathGuardSpecs(command: CommandSpec, input: JSONValue) throws
    -> [LocalPathGuardSpec]
  {
    guard command.id == "messages.send.file" else { return [] }
    let path = try input.requiredObject().requiredString("path")
    return [
      LocalPathGuardSpec(role: "attachment", url: try LocalPathPolicy.expandedURL(path))
    ]
  }

  private func normalizedInput(command: CommandSpec, input: JSONValue) throws -> JSONValue {
    guard command.id == "messages.send.file" else { return input }
    let object = try input.requiredObject()
    let path = try LocalPathPolicy.requireRegularFile(object.requiredString("path"))
    return try LocalPathPolicy.replacingPath(input, key: "path", with: path)
  }
}
