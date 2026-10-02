import Foundation
import MacHandsfreeCore

actor ProcessService: CurrentStateValidatedCommandService {
  let name = "process"
  private let processRunner: any ProcessRunning
  private typealias Policy = WorkspaceToolPolicy.Process
  init(processRunner: any ProcessRunning) { self.processRunner = processRunner }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    try Self.prepare(input)
  }
  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    throw AgentError.invalid("Process execution requires its approved stored plan")
  }
  func executeMutation(command: CommandSpec, input: JSONValue, plannedPreview: JSONValue) async throws -> JSONValue {
    let current = try Self.prepare(input)
    guard current == plannedPreview else {
      throw AgentError(code: "plan_state_changed", message: "Executable or working directory changed after approval", exitCode: 6)
    }
    let object = try input.requiredObject()
    let executable = try current.requiredObject().requiredString("executable")
    let cwd = try current.requiredObject().requiredString("cwd")
    let result = try await processRunner.run(ProcessRequest(
      executable: executable, arguments: object.stringArray("arguments"), workingDirectory: cwd,
      timeout: TimeInterval(object.optionalInt("timeout_seconds", default: Policy.timeout) ?? Policy.timeout),
      maximumOutputBytes: object.optionalInt("max_output_bytes", default: Policy.defaultOutputBytes) ?? Policy.defaultOutputBytes,
      validateBeforeLaunch: {
        guard try Self.prepare(input) == plannedPreview else {
          throw AgentError(code: "plan_state_changed", message: "The approved process target changed before launch", exitCode: 6)
        }
      }))
    let details: [String: JSONValue] = [
      "executable": .string(executable), "cwd": .string(cwd),
      "arguments": input["arguments"] ?? .array([]), "exit_code": .integer(Int64(result.exitCode)),
      "termination_signal": result.terminationSignal.map { .integer(Int64($0)) } ?? .null,
      "stdout": .string(String(decoding: result.stdout, as: UTF8.self)),
      "stderr": .string(String(decoding: result.stderr, as: UTF8.self)),
      "stdout_is_utf8": .bool(String(data: result.stdout, encoding: .utf8) != nil),
      "stderr_is_utf8": .bool(String(data: result.stderr, encoding: .utf8) != nil),
      "stdout_base64": .string(result.stdout.base64EncodedString()),
      "stderr_base64": .string(result.stderr.base64EncodedString()),
      "timed_out": .bool(result.timedOut), "output_limit_exceeded": .bool(result.outputLimitExceeded),
      "sandboxed": .bool(false), "business_effects_verified": .bool(false),
      "effects_may_have_occurred": .bool(true),
    ]
    if result.timedOut || result.outputLimitExceeded || result.terminationSignal != nil {
      throw AgentError(code: "process_interrupted", message: "Process was interrupted; partial effects may remain. Do not automatically retry.",
                       details: details, exitCode: 6, outcomeUncertain: true)
    }
    guard result.exitCode == 0 else {
      throw AgentError(code: "process_exited_nonzero", message: "Process exited with a nonzero status; inspect the output and current files before another run.", details: details, exitCode: 5)
    }
    return .object(details)
  }

  nonisolated private static func prepare(_ input: JSONValue) throws -> JSONValue {
    let object = try input.requiredObject()
    guard object.stringArray("arguments").allSatisfy({ !$0.contains("\0") }) else {
      throw AgentError.invalid("Process arguments must not contain NUL bytes")
    }
    let executable = try LocalPathPolicy.requireRegularFile(LocalPathPolicy.expandedURL(object.requiredString("executable")).resolvingSymlinksInPath().path)
    let cwd = try LocalPathPolicy.requireExisting(object.requiredString("cwd")).resolvingSymlinksInPath()
    let inspection = FileSystemInspector()
    let executableGuard = try inspection.pathGuard(role: "executable", url: executable)
    let directoryGuard = try inspection.pathGuard(role: "cwd", url: cwd, includeChanges: false)
    guard directoryGuard["kind"]?.stringValue == "directory", FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw AgentError.invalid("cwd must be a directory and executable must be executable")
    }
    return .object([
      "executable": .string(executable.path), "cwd": .string(cwd.path),
      "arguments": input["arguments"] ?? .array([]),
      "timeout_seconds": .integer(Int64(object.optionalInt("timeout_seconds", default: Policy.timeout) ?? Policy.timeout)),
      "max_output_bytes": .integer(Int64(object.optionalInt("max_output_bytes", default: Policy.defaultOutputBytes) ?? Policy.defaultOutputBytes)),
      "guards": .array([executableGuard, directoryGuard]),
      "execution_scope": .string("Not sandboxed. The command may change files outside cwd, use the network, and invoke other programs with this user's permissions. Working-tree and script contents are not frozen. Cancellation does not undo effects."),
    ])
  }
}
