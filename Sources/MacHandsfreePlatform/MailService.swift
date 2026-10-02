import Foundation
import MacHandsfreeCore

struct MailService: CurrentStateValidatedCommandService {
  private static let maximumSnapshotBytes = 256 * 1_024
  private static let mutations: Set<String> = [
    "mail.drafts.create", "mail.drafts.send", "mail.messages.send", "mail.messages.reply",
    "mail.messages.forward", "mail.messages.move", "mail.messages.set-read",
  ]
  let name = "mail"
  private let runner: any AppleEventsRunning
  private let localPathGuard: LocalPathMutationGuard
  private let indexReader: MailIndexReader

  init(
    runner: any AppleEventsRunning,
    localPathGuard: LocalPathMutationGuard = LocalPathMutationGuard(),
    indexReader: MailIndexReader = MailIndexReader()
  ) {
    self.runner = runner
    self.localPathGuard = localPathGuard
    self.indexReader = indexReader
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    guard command.kind == .mutation, Self.mutations.contains(command.id) else {
      throw invalidPreview("This Mail command does not prepare a mutation")
    }
    let normalized = try normalizedInput(command: command, input: input)
    let object = try normalized.requiredObject()
    let captured = try await runner.run(
      script: "mail", operation: "mail.accounts.list",
      input: .object(["mutation_preview": .object(["command": .string(command.id), "input": normalized])]),
      mutation: false)
    let snapshot = try mutationSnapshot(captured["mutation_snapshot"], command: command.id)
    let target =
      object["message_id"]?.stringValue
      ?? object["draft_id"]?.stringValue
      ?? object["mailbox_id"]?.stringValue
      ?? object["subject"]?.stringValue
      ?? "Mail"
    let details = previewDetails(command: command, object: object, snapshot: snapshot)
    var preview = try effects([
      effect(command.id, target, details: details)
    ]).requiredObject()
    preview["mail_snapshot"] = snapshot
    let guarded = try localPathGuard.attaching(
      pathGuardSpecs(command: command, input: normalized, snapshot: snapshot), to: .object(preview))
    guard try guarded.encoded().count <= Self.maximumSnapshotBytes else {
      throw invalidPreview("The complete Mail preview exceeds 256 KiB; it was not truncated")
    }
    return guarded
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    guard command.kind == .read else {
      throw invalidPreview("Mail mutations require the snapshot from a reviewed plan")
    }
    return try await run(command: command, input: input)
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    guard command.kind == .mutation, Self.mutations.contains(command.id) else {
      throw invalidPreview("Unknown Mail mutation")
    }
    let snapshot = try mutationSnapshot(plannedPreview["mail_snapshot"], command: command.id)
    let specs = try pathGuardSpecs(command: command, input: input, snapshot: snapshot)
    try localPathGuard.validate(plannedPreview, specs: specs)
    let normalized = try normalizedInput(command: command, input: input)
    var guarded = try normalized.requiredObject()
    guarded["expected_mail"] = snapshot
    let guardedInput = JSONValue.object(guarded)
    if command.id == "mail.drafts.create" || command.id == "mail.messages.send" {
      return try await runAttachmentMutation(
        command: command,
        input: guardedInput,
        plannedPreview: plannedPreview,
        specs: specs
      )
    }
    return try await runner.run(
      script: "mail",
      operation: command.id,
      input: guardedInput,
      mutation: true,
      validateBeforeLaunch: {
        try localPathGuard.validate(plannedPreview, specs: specs)
      }
    )
  }

  private func runAttachmentMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue,
    specs: [LocalPathGuardSpec]
  ) async throws -> JSONValue {
    let object = try input.requiredObject()
    let sources = object.stringArray("attachments").map {
      URL(fileURLWithPath: $0).standardizedFileURL
    }
    guard !sources.isEmpty else {
      return try await runner.run(
        script: "mail",
        operation: command.id,
        input: input,
        mutation: true,
        validateBeforeLaunch: {
          try localPathGuard.validate(plannedPreview, specs: specs)
        }
      )
    }

    let workspace = try LocalRegularFileSnapshotWorkspace(sources: sources)
    let stagedInput = try LocalPathPolicy.replacingPaths(
      input,
      key: "attachments",
      with: workspace.snapshotURLs
    )
    let result: JSONValue
    do {
      result = try await runner.run(
        script: "mail",
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
    try workspace.remove(originalError: nil, outcomeUncertain: true, observedResult: result)
    return result
  }

  private func run(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    if command.id.hasPrefix("mail.index.") {
      return try await indexReader.execute(command: command.id, input: input)
    }
    return try await runner.run(
      script: "mail",
      operation: command.id,
      input: input,
      mutation: command.kind == .mutation
    )
  }

  private func pathGuardSpecs(command: CommandSpec, input: JSONValue, snapshot: JSONValue) throws
    -> [LocalPathGuardSpec]
  {
    if command.id == "mail.drafts.send" {
      guard let attachments = snapshot["state"]?["draft"]?["content"]?["attachments"]?.arrayValue else {
        throw invalidPreview("The reviewed Mail draft has no attachment observation")
      }
      return try attachments.enumerated().map { index, attachment in
        guard let path = attachment["path"]?.stringValue else {
          throw invalidPreview("A draft attachment does not expose a local file")
        }
        return LocalPathGuardSpec(role: "draft_attachment_\(index)",
          url: try LocalPathPolicy.requireRegularFile(path))
      }
    }
    guard command.id == "mail.drafts.create" || command.id == "mail.messages.send" else { return [] }
    let object = try input.requiredObject()
    return try object.stringArray("attachments").enumerated().map { index, path in
      LocalPathGuardSpec(
        role: "attachment_\(index)",
        url: try LocalPathPolicy.expandedURL(path)
      )
    }
  }

  private func previewDetails(
    command: CommandSpec,
    object: [String: JSONValue],
    snapshot: JSONValue
  ) -> [String: JSONValue]
  {
    var details: [String: JSONValue] = [:]
    let state = snapshot["state"]?.objectValue ?? [:]
    let candidate = snapshot["candidate"]?.objectValue ?? [:]

    switch command.id {
    case "mail.drafts.create", "mail.messages.send":
      details["to"] = candidate["to"] ?? strings(object.stringArray("to"))
      details["cc"] = candidate["cc"] ?? strings(object.stringArray("cc"))
      details["bcc"] = candidate["bcc"] ?? strings(object.stringArray("bcc"))
      details["subject"] = candidate["subject"] ?? .string(object.optionalString("subject") ?? "")
      details["body"] = candidate["body"] ?? .string(object.optionalString("body") ?? "")
      details["attachments"] = strings(object.stringArray("attachments"))
      addSenderDetails(state["sender"], to: &details)
    case "mail.drafts.send":
      guard let draft = state["draft"]?.objectValue else { break }
      details["draft_id"] = draft["id"]
      details["sender"] = draft["sender"]
      details["sender_address"] = draft["sender_address"]
      details["to"] = draft["to"]
      details["cc"] = draft["cc"]
      details["bcc"] = draft["bcc"]
      details["subject"] = draft["subject"]
      details["body"] = draft["content"]?["text"]
      details["signature"] = draft["signature"]
      details["attachments"] = .array(
        (draft["content"]?["attachments"]?.arrayValue ?? []).compactMap { $0["name"] })
      addSenderDetails(state["sender"], to: &details)
    case "mail.messages.reply":
      details["body"] = candidate["body"] ?? .string(object.optionalString("body") ?? "")
      details["reply_all"] = candidate["reply_all"] ?? .bool(object.optionalBool("reply_all"))
      details["send"] = candidate["send_requested"] ?? .bool(object.optionalBool("send"))
      details["effect"] = .string("Create a native reply draft only. This step does not send it; sending requires a separate reviewed mail.drafts.send plan.")
      details["source_message"] = sourcePreview(state["source_message"])
      addSenderDetails(state["sender"], to: &details)
    case "mail.messages.forward":
      details["to"] = candidate["to"] ?? strings(object.stringArray("to"))
      details["cc"] = candidate["cc"] ?? strings(object.stringArray("cc"))
      details["body"] = candidate["body_prefix"] ?? .string(object.optionalString("body") ?? "")
      details["send"] = candidate["send_requested"] ?? .bool(object.optionalBool("send"))
      details["effect"] = .string("Create a native forwarded draft only. This step does not send it; sending requires a separate reviewed mail.drafts.send plan.")
      details["source_message"] = sourcePreview(state["source_message"])
      addSenderDetails(state["sender"], to: &details)
    case "mail.messages.move":
      details["mailbox_id"] = candidate["mailbox_id"] ?? object["mailbox_id"]
      details["source_message"] = sourcePreview(state["source_message"])
      details["destination_mailbox"] = state["destination_mailbox"]
    case "mail.messages.set-read":
      details["read"] = candidate["read"] ?? .bool(object.optionalBool("read"))
      details["source_message"] = sourcePreview(state["source_message"])
    default:
      break
    }

    return details
  }

  private func addSenderDetails(_ value: JSONValue?, to details: inout [String: JSONValue]) {
    guard let sender = value?.objectValue else { return }
    details["sender_address"] = sender["address"]
    details["account_id"] = sender["account"]?["id"]
  }

  private func sourcePreview(_ value: JSONValue?) -> JSONValue? {
    guard let source = value?.objectValue else { return nil }
    var keys = ["id", "message_id", "subject", "sender", "date_received", "date_sent", "read",
      "mailbox", "mailbox_id", "reply_to"]
    if source["content"] != nil {
      keys.append(contentsOf: ["to", "cc", "bcc", "content", "attachments"])
    }
    return .object(source.filter { keys.contains($0.key) })
  }

  private func normalizedInput(command: CommandSpec, input: JSONValue) throws -> JSONValue {
    guard command.id == "mail.drafts.create" || command.id == "mail.messages.send" else {
      return input
    }
    let object = try input.requiredObject()
    let paths = try object.stringArray("attachments").map(LocalPathPolicy.requireRegularFile)
    return try LocalPathPolicy.replacingPaths(input, key: "attachments", with: paths)
  }

  private func strings(_ values: [String]) -> JSONValue {
    .array(values.map(JSONValue.string))
  }

  private func mutationSnapshot(_ value: JSONValue?, command: String) throws -> JSONValue {
    guard let value, let object = value.objectValue,
      Set(object.keys) == Set(["version", "command", "state", "candidate"]),
      value["version"] == .integer(1), value["command"]?.stringValue == command,
      value["state"]?.objectValue != nil, value["candidate"]?.objectValue != nil,
      try value.encoded().count <= Self.maximumSnapshotBytes
    else { throw invalidPreview("The Mail mutation snapshot is missing, malformed, or exceeds 256 KiB") }
    return value
  }

  private func invalidPreview(_ message: String) -> AgentError {
    AgentError(code: "plan_preview_invalid", message: message, exitCode: 6)
  }
}
