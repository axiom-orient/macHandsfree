import Foundation
import MacHandsfreeCore

struct ShortcutsService: CurrentStateValidatedCommandService {
  let name = "shortcuts"
  private let cli: ShortcutCLI
  private let localPathGuard: LocalPathMutationGuard

  init(
    processRunner: any ProcessRunning,
    localPathGuard: LocalPathMutationGuard = LocalPathMutationGuard()
  ) {
    self.cli = ShortcutCLI(processRunner: processRunner)
    self.localPathGuard = localPathGuard
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      let normalized = try normalizedInput(command: command, input: input)
      let object = try normalized.requiredObject()
      let name = try await cli.resolveUniqueName(object.requiredString("name"))
      var details: [String: JSONValue] = [:]
      details["actions_inspected"] = .bool(false)
      if let path = object.optionalString("input_path") { details["input_path"] = .string(path) }
      if let path = object.optionalString("output_path") { details["output_path"] = .string(path) }
      let preview = effects([
        effect("run_shortcut", name, details: details)
      ])
      return try localPathGuard.attaching(
        pathGuardSpecs(command: command, input: normalized),
        to: preview
      )
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      switch command.id {
      case "shortcuts.items.list":
        let names = try await cli.listNames()
        return .object(["shortcuts": .array(names.map { .object(["name": .string($0)]) })])
      case "shortcuts.items.get":
        let name = try input.requiredObject().requiredString("name")
        let resolved = try await cli.resolveUniqueName(name)
        return .object(["shortcut": .object(["name": .string(resolved)])])
      case "shortcuts.items.run":
        let normalized = try normalizedInput(command: command, input: input)
        return try await cli.run(normalized)
      default:
        throw AgentError(
          code: "unsupported_shortcuts_command",
          message: "Shortcuts service does not support command",
          exitCode: 5
        )
      }
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    guard command.id == "shortcuts.items.run" else {
      throw AgentError(
        code: "invalid_mutation_route",
        message: "A read-only Shortcuts command received mutation execution",
        details: ["command": .string(command.id)],
        exitCode: 5
      )
    }
    let specs = try pathGuardSpecs(command: command, input: input)
    try localPathGuard.validate(plannedPreview, specs: specs)
    let normalized = try normalizedInput(command: command, input: input)
    #if os(macOS)
      return try await cli.run(normalized) {
        try localPathGuard.validate(plannedPreview, specs: specs)
      }
    #else
      _ = normalized
      throw AgentError.unsupported(command.id)
    #endif
  }

  private func pathGuardSpecs(command: CommandSpec, input: JSONValue) throws
    -> [LocalPathGuardSpec]
  {
    guard command.id == "shortcuts.items.run" else { return [] }
    let object = try input.requiredObject()
    var specs: [LocalPathGuardSpec] = []
    if let raw = object.optionalString("input_path") {
      specs.append(
        LocalPathGuardSpec(role: "input", url: try LocalPathPolicy.expandedURL(raw)))
    }
    if let raw = object.optionalString("output_path") {
      let output = try LocalPathPolicy.expandedURL(raw)
      specs.append(LocalPathGuardSpec(role: "output", url: output))
      specs.append(
        LocalPathGuardSpec(
          role: "output_parent",
          url: output.deletingLastPathComponent(),
          trackChanges: false
        ))
    }
    return specs
  }

  private func normalizedInput(command: CommandSpec, input: JSONValue) throws -> JSONValue {
    guard command.id == "shortcuts.items.run" else { return input }
    var normalized = input
    let object = try input.requiredObject()
    if let raw = object.optionalString("input_path") {
      let path = try LocalPathPolicy.requireExisting(raw)
      normalized = try LocalPathPolicy.replacingPath(normalized, key: "input_path", with: path)
    }
    if let raw = object.optionalString("output_path") {
      let output = try LocalPathPolicy.validateOutputFile(raw, overwrite: false)
      normalized = try LocalPathPolicy.replacingPath(
        normalized, key: "output_path", with: output.url)
    }
    return normalized
  }

}
