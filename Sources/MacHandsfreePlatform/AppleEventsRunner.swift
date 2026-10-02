import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

protocol AppleEventsRunning: Sendable {
  func run(script: String, operation: String, input: JSONValue, mutation: Bool) async throws
    -> JSONValue
  func run(
    script: String,
    operation: String,
    input: JSONValue,
    mutation: Bool,
    validateBeforeLaunch: @escaping @Sendable () throws -> Void
  ) async throws -> JSONValue
}

extension AppleEventsRunning {
  func run(
    script: String,
    operation: String,
    input: JSONValue,
    mutation: Bool,
    validateBeforeLaunch: @escaping @Sendable () throws -> Void
  ) async throws -> JSONValue {
    try validateBeforeLaunch()
    return try await run(script: script, operation: operation, input: input, mutation: mutation)
  }
}

enum AppleEventsResultInterpreter {
  static func interpret(
    result: ProcessResult,
    operation: String,
    mutation: Bool
  ) throws -> JSONValue {
    if result.timedOut {
      throw AgentError(
        code: "apple_event_timeout", message: "Apple Events command timed out",
        details: ["operation": .string(operation)], exitCode: 5, outcomeUncertain: mutation)
    }
    if result.outputLimitExceeded {
      throw AgentError(
        code: "apple_event_output_limit",
        message: "Apple Events command exceeded the output limit",
        details: ["operation": .string(operation)], exitCode: 5, outcomeUncertain: mutation)
    }
    guard result.exitCode == 0 else {
      throw AgentError(
        code: "apple_event_failed", message: "Apple Events command failed",
        details: [
          "operation": .string(operation),
          "exit_code": .integer(Int64(result.exitCode)),
          "stderr": .string(result.stderrString ?? "<non-UTF8 stderr>"),
        ], exitCode: 5, outcomeUncertain: mutation)
    }
    guard let text = result.stdoutString?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      throw AgentError(
        code: "apple_event_invalid_output",
        message: "Apple Events command returned non-UTF8 output", exitCode: 5,
        outcomeUncertain: mutation)
    }
    let envelope: JSONValue
    do {
      envelope = try JSONValue.parse(Data(text.utf8))
    } catch {
      throw AgentError(
        code: "apple_event_invalid_output",
        message: "Apple Events command returned invalid JSON",
        details: [
          "operation": .string(operation),
          "reason": .string(String(describing: error)),
        ],
        exitCode: 5,
        outcomeUncertain: mutation
      )
    }
    guard let object = envelope.objectValue, let ok = object["ok"]?.boolValue else {
      throw AgentError(
        code: "apple_event_invalid_output",
        message: "Apple Events command returned an invalid envelope", exitCode: 5,
        outcomeUncertain: mutation)
    }
    if ok {
      return object["data"] ?? .null
    }
    let errorObject = object["error"]?.objectValue ?? [:]
    if let details = errorObject["details"], details.objectValue == nil {
      throw AgentError(
        code: "apple_event_invalid_output", message: "Apple Events returned malformed error evidence",
        details: ["operation": .string(operation)], exitCode: 5, outcomeUncertain: mutation)
    }
    var details = errorObject["details"]?.objectValue ?? [:]
    details["operation"] = .string(operation)
    let providerCode = errorObject["code"]?.stringValue ?? "apple_event_failed"
    let providerMessage = errorObject["message"]?.stringValue ?? "Apple Events command failed"
    if providerMessage.contains("(-1743)") {
      details["provider_code"] = .string(providerCode)
      details["provider_message"] = .string(providerMessage)
      let eventOutcomeUncertain =
        details["effect_started"]?.boolValue == true
        || (errorObject["outcome_uncertain"]?.boolValue ?? mutation)
      throw AgentError(
        code: "apple_event_permission_denied",
        message: "macOS denied automation access to the target application",
        details: details,
        exitCode: 3,
        outcomeUncertain: eventOutcomeUncertain
      )
    }
    let reportedExitCode = errorObject["exit_code"]?.intValue.flatMap(Int32.init(exactly:)) ?? 5
    let reportedOutcome = errorObject["outcome_uncertain"]?.boolValue ?? mutation
    throw AgentError(
      code: providerCode,
      message: providerMessage,
      details: details,
      exitCode: reportedExitCode,
      outcomeUncertain: reportedOutcome
    )
  }
}

struct AppleEventsRunner: AppleEventsRunning {
  private let processRunner: any ProcessRunning

  init(processRunner: any ProcessRunning) { self.processRunner = processRunner }

  func run(script: String, operation: String, input: JSONValue, mutation: Bool) async throws
    -> JSONValue
  {
    try await run(
      script: script,
      operation: operation,
      input: input,
      mutation: mutation,
      validateBeforeLaunch: {}
    )
  }

  func run(
    script: String,
    operation: String,
    input: JSONValue,
    mutation: Bool,
    validateBeforeLaunch: @escaping @Sendable () throws -> Void
  ) async throws -> JSONValue {
    #if os(macOS)
      guard
        let scriptURL = Bundle.module.url(forResource: script, withExtension: "js")
      else {
        throw AgentError(
          code: "script_resource_missing", message: "Bundled Apple Events script is missing",
          details: ["script": .string(script)], exitCode: 5)
      }
      let encodedInput = try input.encoded()
      let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "mac-handsfree-apple-events-\(UUID().uuidString)", isDirectory: true)
      let inputURL = workspace.appendingPathComponent("input.json")
      do {
        try FileManager.default.createDirectory(
          at: workspace,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
        guard chmod(workspace.path, 0o700) == 0 else {
          throw workspaceFailure(
            message: "Could not secure the Apple Events workspace",
            workspace: workspace
          )
        }
        try encodedInput.write(to: inputURL, options: .withoutOverwriting)
        guard chmod(inputURL.path, 0o600) == 0 else {
          throw workspaceFailure(
            message: "Could not secure the Apple Events input file",
            workspace: workspace
          )
        }
      } catch {
        let originalError = error
        try cleanupWorkspace(
          workspace,
          originalError: originalError,
          mutation: false
        )
        throw originalError
      }

      let result: ProcessResult
      do {
        result = try await processRunner.run(
          ProcessRequest(
            executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", scriptURL.path, operation, inputURL.path],
            timeout: 60,
            maximumOutputBytes: 8 * 1_024 * 1_024,
            validateBeforeLaunch: validateBeforeLaunch
          ))
      } catch {
        let originalError = error
        try cleanupWorkspace(
          workspace,
          originalError: originalError,
          mutation: mutation
        )
        throw originalError
      }
      let output: JSONValue
      do {
        output = try AppleEventsResultInterpreter.interpret(
          result: result,
          operation: operation,
          mutation: mutation
        )
      } catch {
        let originalError = error
        try cleanupWorkspace(
          workspace,
          originalError: originalError,
          mutation: mutation
        )
        throw originalError
      }
      try cleanupWorkspace(workspace, originalError: nil, mutation: mutation, observedResult: output)
      return output
    #else
      _ = script
      _ = operation
      _ = input
      _ = mutation
      _ = validateBeforeLaunch
      throw AgentError.unsupported("apple-events")
    #endif
  }

  private func cleanupWorkspace(
    _ workspace: URL,
    originalError: (any Error)?,
    mutation: Bool,
    observedResult: JSONValue? = nil
  ) throws {
    guard FileManager.default.fileExists(atPath: workspace.path) else { return }
    do {
      try FileManager.default.removeItem(at: workspace)
    } catch {
      var details: [String: JSONValue] = [
        "path": .string(workspace.path),
        "cleanup_error": .string(String(describing: error)),
      ]
      if let originalError {
        details["original_error"] = .string(String(describing: originalError))
      }
      if let original = originalError as? AgentError {
        details["original_error_code"] = .string(original.code)
        details["original_error_details"] = .object(original.details)
      }
      if let observedResult { details["observed_result"] = observedResult }
      throw AgentError(
        code: "apple_event_workspace_cleanup_failed",
        message: "Could not remove a private Apple Events workspace",
        details: details,
        exitCode: 5,
        outcomeUncertain: mutation || (originalError as? AgentError)?.outcomeUncertain == true
      )
    }
  }

  private func workspaceFailure(
    message: String,
    workspace: URL
  ) -> AgentError {
    AgentError(
      code: "apple_event_workspace_failed",
      message: message,
      details: ["path": .string(workspace.path), "errno": .integer(Int64(errno))],
      exitCode: 5
    )
  }
}
