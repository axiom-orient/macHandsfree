import Foundation
import MacHandsfreeCore

enum SystemProfilerOutputInterpreter {
  static func parse(_ data: Data) throws -> JSONValue {
    do {
      return try JSONValue.parse(data)
    } catch {
      throw AgentError(
        code: "system_profiler_invalid_output",
        message: "system_profiler returned invalid JSON",
        exitCode: 5
      )
    }
  }
}

struct SystemService: CurrentStateValidatedCommandService {
  let name = "system"
  private let runner: any AppleEventsRunning
  private let processRunner: any ProcessRunning
  private let pathGuard = LocalPathMutationGuard()

  init(runner: any AppleEventsRunning, processRunner: any ProcessRunning) {
    self.runner = runner
    self.processRunner = processRunner
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    let normalized = try normalizedInput(command: command, input: input)
    let object = try normalized.requiredObject()
    let target = object["path"]?.stringValue ?? object["url"]?.stringValue ?? "this Mac"
    let preview = effects([effect(command.id, target)])
    return try pathGuard.attaching(pathGuardSpecs(command: command, input: input), to: preview)
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    switch command.id {
    case "system.info":
      return try await info()
    case "system.locale.get":
      return .object([
        "locale": .string(Locale.current.identifier),
        "timezone": .string(TimeZone.current.identifier),
        "calendar": .string(Calendar.current.identifier.debugDescription),
      ])
    case "system.settings.open":
      #if os(macOS)
        let url = try input.requiredObject().requiredString("url")
        guard url.hasPrefix("x-apple.systempreferences:") else {
          throw AgentError.invalid("System Settings URL must use x-apple.systempreferences")
        }
        return try await runOfficial(
          "/usr/bin/open",
          arguments: [url],
          command: command.id,
          mutation: true
        )
      #else
        throw AgentError.unsupported(command.id)
      #endif
    default:
      let normalized = try normalizedInput(command: command, input: input)
      return try await runAppleEvent(command: command, input: normalized)
    }
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    let specs = try pathGuardSpecs(command: command, input: input)
    try pathGuard.validate(plannedPreview, specs: specs)
    guard command.id == "system.wallpaper.set" else {
      return try await execute(command: command, input: input)
    }
    let normalized = try normalizedInput(command: command, input: input)
    return try await runAppleEvent(command: command, input: normalized) {
      try pathGuard.validate(plannedPreview, specs: specs)
    }
  }

  private func runAppleEvent(
    command: CommandSpec,
    input: JSONValue,
    validateBeforeLaunch: @escaping @Sendable () throws -> Void = {}
  ) async throws -> JSONValue {
    try await runner.run(
      script: "system",
      operation: command.id,
      input: input,
      mutation: command.kind == .mutation,
      validateBeforeLaunch: validateBeforeLaunch
    )
  }

  private func pathGuardSpecs(command: CommandSpec, input: JSONValue) throws
    -> [LocalPathGuardSpec]
  {
    guard command.id == "system.wallpaper.set" else { return [] }
    let path = try input.requiredObject().requiredString("path")
    return [
      LocalPathGuardSpec(role: "wallpaper", url: try LocalPathPolicy.expandedURL(path))
    ]
  }

  private func normalizedInput(command: CommandSpec, input: JSONValue) throws -> JSONValue {
    guard command.id == "system.wallpaper.set" else { return input }
    let object = try input.requiredObject()
    let path = try LocalPathPolicy.requireRegularFile(object.requiredString("path"))
    return try LocalPathPolicy.replacingPath(input, key: "path", with: path)
  }

  private func info() async throws -> JSONValue {
    #if os(macOS)
      let result = try await processRunner.run(
        ProcessRequest(
          executable: "/usr/sbin/system_profiler",
          arguments: ["SPSoftwareDataType", "SPHardwareDataType", "-json"],
          timeout: 60,
          maximumOutputBytes: 16 * 1_024 * 1_024
        )
      )
      guard !result.timedOut, !result.outputLimitExceeded, result.exitCode == 0,
        let text = result.stdoutString
      else {
        throw AgentError(
          code: "system_profiler_failed",
          message: "system_profiler failed",
          details: ["stderr": .string(result.stderrString ?? "")],
          exitCode: 5
        )
      }
      return try SystemProfilerOutputInterpreter.parse(Data(text.utf8))
    #else
      throw AgentError.unsupported("system.info")
    #endif
  }

  private func runOfficial(
    _ executable: String,
    arguments: [String],
    command: String,
    mutation: Bool
  ) async throws -> JSONValue {
    let result = try await processRunner.run(
      ProcessRequest(executable: executable, arguments: arguments, timeout: 30)
    )
    guard !result.timedOut, !result.outputLimitExceeded, result.exitCode == 0 else {
      throw AgentError(
        code: "official_command_failed",
        message: "Official macOS command failed",
        details: [
          "command": .string(command),
          "stderr": .string(result.stderrString ?? ""),
        ],
        exitCode: 5,
        outcomeUncertain: mutation
      )
    }
    return .object(["completed": .bool(true)])
  }
}
