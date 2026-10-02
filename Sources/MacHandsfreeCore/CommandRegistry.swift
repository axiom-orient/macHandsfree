package struct CommandRegistry: Sendable {
  package let commands: [CommandSpec]
  private let byID: [String: CommandSpec]
  private let byArguments: [[String]: ResolvedCommand]

  package init() throws {
    try self.init(commands: Self.canonicalCommands)
  }

  init(commands: [CommandSpec]) throws {
    let duplicateIDs = Dictionary(grouping: commands, by: \.id).filter { $0.value.count > 1 }.keys
      .sorted()
    let invalidCommands = commands.filter { command in
      command.path.isEmpty
        || command.path.contains(where: { $0.isEmpty || $0.hasPrefix("-") || $0.contains("\0") })
        || (command.id != command.path.joined(separator: ".")
          && command.id != command.path.map { $0.replacingOccurrences(of: "-", with: "_") }.joined(separator: "."))
        || command.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || command.service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || command.permissions.contains(where: \.isEmpty)
        || Set(command.permissions).count != command.permissions.count
    }.map(\.id).sorted()

    let invocations = commands.flatMap(Self.invocations)
    let duplicateCLIPaths = Dictionary(grouping: invocations, by: \.arguments)
      .filter { $0.value.count > 1 }.keys.sorted { $0.lexicographicallyPrecedes($1) }
    let duplicateMCPTools = Dictionary(grouping: invocations, by: \.mcpName)
      .filter { $0.value.count > 1 }.keys.sorted()

    guard duplicateIDs.isEmpty, invalidCommands.isEmpty, duplicateCLIPaths.isEmpty,
      duplicateMCPTools.isEmpty
    else {
      throw AgentError(
        code: "invalid_command_registry",
        message: "Command registry contains invalid or conflicting command definitions",
        details: [
          "duplicate_ids": .array(duplicateIDs.map(JSONValue.string)),
          "duplicate_cli_paths": .array(
            duplicateCLIPaths.map { .array($0.map(JSONValue.string)) }
          ),
          "duplicate_mcp_tools": .array(duplicateMCPTools.map(JSONValue.string)),
          "invalid_commands": .array(invalidCommands.map(JSONValue.string)),
        ],
        exitCode: 5
      )
    }

    self.commands = commands.sorted { $0.id < $1.id }
    self.byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
    self.byArguments = Dictionary(
      uniqueKeysWithValues: invocations.map { ($0.arguments, $0.resolved) }
    )
  }

  package var invocations: [CommandInvocation] { commands.flatMap(Self.invocations) }

  package func command(id: String) -> CommandSpec? { byID[id] }

  package func resolve(arguments: [String]) throws -> ResolvedCommand {
    guard !arguments.isEmpty else { throw AgentError.invalid("A command path is required") }
    if let option = arguments.first(where: { $0.hasPrefix("-") }) {
      throw AgentError.invalid(
        "Options are not supported; use an exact command path",
        details: ["argument": .string(option)])
    }
    guard let resolved = byArguments[arguments] else {
      throw AgentError.invalid(
        "Unknown or incomplete command path",
        details: ["arguments": .array(arguments.map(JSONValue.string))])
    }
    return resolved
  }

  private static func invocations(for command: CommandSpec)
    -> [CommandInvocation]
  {
    switch command.kind {
    case .read:
      return [.init(arguments: command.path, mcpName: command.mcpName,
                    resolved: ResolvedCommand(spec: command, mode: .read))]
    case .mutation:
      return [
        .init(arguments: command.path + ["plan"], mcpName: command.mcpName + "_plan",
              resolved: ResolvedCommand(spec: command, mode: .plan)),
        .init(arguments: command.path + ["execute"], mcpName: command.mcpName + "_execute",
              resolved: ResolvedCommand(spec: command, mode: .execute)),
      ]
    }
  }

}
