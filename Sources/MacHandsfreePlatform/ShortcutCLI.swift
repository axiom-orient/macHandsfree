import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct ShortcutCLI: Sendable {
  private let processRunner: any ProcessRunning

  init(processRunner: any ProcessRunning) {
    self.processRunner = processRunner
  }

  func listNames() async throws -> [String] {
    let text = try await namesOutput()
    var names: [String] = []
    text.enumerateLines(invoking: { line, _ in
      guard !line.isEmpty else { return }
      names.append(line)
    })
    return names
  }

  func resolveUniqueName(_ name: String) async throws -> String {
    let text = try await namesOutput()
    var match: String?
    var ambiguous = false
    text.enumerateLines(invoking: { line, stop in
      guard !line.isEmpty, line == name else { return }
      guard match == nil else {
        ambiguous = true
        stop = true
        return
      }
      match = line
    })
    guard let match, !ambiguous else {
      throw AgentError(
        code: ambiguous ? "shortcut_ambiguous" : "shortcut_not_found",
        message: "Shortcut name did not resolve exactly once",
        exitCode: 6
      )
    }
    return match
  }

  private func namesOutput() async throws -> String {
    let result = try await processRunner.run(
      ProcessRequest(executable: "/usr/bin/shortcuts", arguments: ["list"], timeout: 60)
    )
    guard !result.timedOut, !result.outputLimitExceeded, result.exitCode == 0,
      let text = result.stdoutString
    else {
      throw AgentError(
        code: "shortcuts_list_failed",
        message: "Could not list shortcuts",
        details: ["stderr": .string(diagnosticText(result.stderr))],
        exitCode: 5
      )
    }
    return text
  }

  func run(
    _ input: JSONValue,
    validateBeforeLaunch: @escaping @Sendable () throws -> Void = {}
  ) async throws -> JSONValue {
    let object = try input.requiredObject()
    let name = try object.requiredString("name")
    let resolvedName = try await resolveUniqueName(name)

    guard let rawInputPath = object.optionalString("input_path") else {
      return try await runResolved(
        input,
        name: resolvedName,
        validateBeforeLaunch: validateBeforeLaunch
      )
    }

    let source = URL(fileURLWithPath: rawInputPath).standardizedFileURL
    let inputWorkspace = try LocalRegularFileSnapshotWorkspace(sources: [source])
    guard let snapshot = inputWorkspace.snapshotURLs.first else {
      throw AgentError(
        code: "local_input_snapshot_corrupt",
        message: "Shortcut input snapshot was not created",
        exitCode: 5
      )
    }
    let snapshottedInput = try LocalPathPolicy.replacingPath(
      input, key: "input_path", with: snapshot)
    let result: JSONValue
    do {
      result = try await runResolved(
        snapshottedInput,
        name: resolvedName,
        validateBeforeLaunch: {
          try validateBeforeLaunch()
          try inputWorkspace.validate()
        }
      )
    } catch {
      let originalError = error
      try inputWorkspace.remove(
        originalError: originalError,
        outcomeUncertain: (originalError as? AgentError)?.outcomeUncertain ?? true
      )
      throw originalError
    }
    try inputWorkspace.remove(originalError: nil, outcomeUncertain: true, observedResult: result)
    return result
  }

  private func runResolved(
    _ input: JSONValue,
    name: String,
    validateBeforeLaunch: @escaping @Sendable () throws -> Void
  ) async throws -> JSONValue {
    let object = try input.requiredObject()
    let requestedOutput = object.optionalString("output_path").map {
      URL(fileURLWithPath: $0).standardizedFileURL
    }
    let workspace: ShortcutOutputWorkspace?
    if let requestedOutput {
      workspace = try ShortcutOutputWorkspace(destination: requestedOutput)
    } else {
      workspace = nil
    }

    var arguments = ["run", name]
    if let path = object.optionalString("input_path") {
      arguments += ["--input-path", path]
    }
    if let workspace {
      arguments += ["--output-path", workspace.stagedOutput.path]
    }

    let result: ProcessResult
    do {
      result = try await processRunner.run(
        ProcessRequest(
          executable: "/usr/bin/shortcuts",
          arguments: arguments,
          timeout: 300,
          maximumOutputBytes: 16 * 1_024 * 1_024,
          validateBeforeLaunch: validateBeforeLaunch
        )
      )
    } catch {
      let originalError = error
      try cleanup(
        workspace,
        originalError: originalError,
        outcomeUncertain: (originalError as? AgentError)?.outcomeUncertain ?? true
      )
      throw originalError
    }

    guard result.exitCode == 0, !result.timedOut, !result.outputLimitExceeded else {
      let executionError = AgentError(
        code: "shortcut_run_failed",
        message: "Shortcut execution failed",
        details: ["stderr": .string(diagnosticText(result.stderr))],
        exitCode: 5,
        outcomeUncertain: true
      )
      try cleanup(workspace, originalError: executionError, outcomeUncertain: true)
      throw executionError
    }

    let standardOutput: String
    if result.stdout.isEmpty {
      standardOutput = ""
    } else if let decoded = result.stdoutString {
      standardOutput = decoded
    } else {
      let encodingError = AgentError(
        code: "shortcut_output_invalid_encoding",
        message:
          "Shortcut completed but stdout was not valid UTF-8; use output_path for binary output",
        details: ["byte_count": .integer(Int64(result.stdout.count))],
        exitCode: 5,
        outcomeUncertain: true
      )
      try cleanup(workspace, originalError: encodingError, outcomeUncertain: true)
      throw encodingError
    }

    if let workspace, let requestedOutput {
      do {
        try ShortcutOutputPublisher.publish(
          workspace.stagedOutput,
          to: requestedOutput,
          validateBeforePublish: validateBeforeLaunch
        )
      } catch {
        let publicationError = uncertain(error)
        if publicationError.code == "atomic_path_rollback_failed" {
          throw publicationError
        }
        try cleanup(workspace, originalError: publicationError, outcomeUncertain: true)
        throw publicationError
      }
      try cleanup(workspace, originalError: nil, outcomeUncertain: true)
    }

    return .object([
      "completed": .bool(true),
      "stdout": .string(standardOutput),
      "output_path": requestedOutput.map { .string($0.path) } ?? .null,
    ])
  }

  private func diagnosticText(_ data: Data) -> String {
    if data.isEmpty { return "" }
    return String(data: data, encoding: .utf8) ?? "<non-UTF8 stderr: \(data.count) bytes>"
  }

  private func cleanup(
    _ workspace: ShortcutOutputWorkspace?,
    originalError: (any Error)?,
    outcomeUncertain: Bool
  ) throws {
    guard let workspace else { return }
    do {
      try workspace.remove()
    } catch {
      var details: [String: JSONValue] = [
        "path": .string(workspace.directory.path),
        "cleanup_error": .string(String(describing: error)),
      ]
      if let originalError {
        details["original_error"] = .string(String(describing: originalError))
      }
      throw AgentError(
        code: "shortcut_workspace_cleanup_failed",
        message: "Could not remove the private Shortcuts output workspace",
        details: details,
        exitCode: 5,
        outcomeUncertain: outcomeUncertain
          || (originalError as? AgentError)?.outcomeUncertain == true
      )
    }
  }

  private func uncertain(_ error: any Error) -> AgentError {
    if let agentError = error as? AgentError {
      return AgentError(
        code: agentError.code,
        message: agentError.message,
        details: agentError.details,
        exitCode: agentError.exitCode,
        outcomeUncertain: true
      )
    }
    return AgentError(
      code: "shortcut_output_publication_failed",
      message: "Shortcut completed but its output could not be published",
      details: ["reason": .string(String(describing: error))],
      exitCode: 5,
      outcomeUncertain: true
    )
  }
}

struct ShortcutOutputWorkspace: Sendable {
  let directory: URL
  let stagedOutput: URL

  init(destination: URL) throws {
    let directory = destination.deletingLastPathComponent().appendingPathComponent(
      ".mac-handsfree-shortcut-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(directory.path, 0o700) == 0 else {
        throw AgentError(
          code: "shortcut_workspace_failed",
          message: "Could not secure the private Shortcuts output workspace",
          details: ["path": .string(directory.path), "errno": .integer(Int64(errno))],
          exitCode: 5
        )
      }
    } catch {
      let originalError = error
      if FileManager.default.fileExists(atPath: directory.path) {
        do {
          try FileManager.default.removeItem(at: directory)
        } catch {
          throw AgentError(
            code: "shortcut_workspace_cleanup_failed",
            message: "Shortcuts workspace setup failed and could not be cleaned up",
            details: [
              "path": .string(directory.path),
              "original_error": .string(String(describing: originalError)),
              "cleanup_error": .string(String(describing: error)),
            ],
            exitCode: 5
          )
        }
      }
      throw originalError
    }
    self.directory = directory
    self.stagedOutput = directory.appendingPathComponent("output", isDirectory: false)
  }

  func remove() throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }
}
