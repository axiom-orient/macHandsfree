import Foundation
import MacHandsfreeCore

struct FinderService: CurrentStateValidatedCommandService {
  let name = "finder"
  private let runner: any AppleEventsRunning
  private let processRunner: any ProcessRunning
  private let pathGuard = LocalPathMutationGuard()

  init(runner: any AppleEventsRunning, processRunner: any ProcessRunning) {
    self.runner = runner
    self.processRunner = processRunner
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    let path = try LocalPathPolicy.requireExisting(input.requiredObject().requiredString("path"))
    let preview = effects([effect("reveal", path.path)])
    return try pathGuard.attaching(pathGuardSpecs(command: command, input: input), to: preview)
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    switch command.id {
    case "finder.selection.list":
      return try await runner.run(
        script: "system", operation: command.id, input: input, mutation: false)
    case "finder.reveal":
      return try await reveal(input)
    default:
      throw AgentError(
        code: "unsupported_finder_command", message: "Finder service does not support command",
        exitCode: 5)
    }
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    let specs = try pathGuardSpecs(command: command, input: input)
    try pathGuard.validate(plannedPreview, specs: specs)
    guard command.id == "finder.reveal" else {
      throw AgentError(
        code: "invalid_mutation_route",
        message: "A read-only Finder command received mutation execution",
        details: ["command": .string(command.id)],
        exitCode: 5
      )
    }
    return try await reveal(input) {
      try pathGuard.validate(plannedPreview, specs: specs)
    }
  }

  private func reveal(
    _ input: JSONValue,
    validateBeforeLaunch: @escaping @Sendable () throws -> Void = {}
  ) async throws -> JSONValue {
    #if os(macOS)
      let path = try LocalPathPolicy.requireExisting(
        input.requiredObject().requiredString("path"))
      let result = try await processRunner.run(
        ProcessRequest(
          executable: "/usr/bin/open",
          arguments: ["-R", path.path],
          timeout: 30,
          validateBeforeLaunch: validateBeforeLaunch
        )
      )
      guard result.exitCode == 0, !result.timedOut, !result.outputLimitExceeded else {
        throw AgentError(
          code: "finder_reveal_failed",
          message: "Finder reveal failed",
          details: ["stderr": .string(result.stderrString ?? "")],
          exitCode: 5,
          outcomeUncertain: true
        )
      }
      return .object(["revealed": .bool(true), "path": .string(path.path)])
    #else
      _ = input
      _ = validateBeforeLaunch
      throw AgentError.unsupported("finder.reveal")
    #endif
  }

  private func pathGuardSpecs(command: CommandSpec, input: JSONValue) throws
    -> [LocalPathGuardSpec]
  {
    guard command.id == "finder.reveal" else { return [] }
    let path = try input.requiredObject().requiredString("path")
    return [
      LocalPathGuardSpec(
        role: "revealed_path",
        url: try LocalPathPolicy.expandedURL(path),
        trackChanges: false
      )
    ]
  }
}
