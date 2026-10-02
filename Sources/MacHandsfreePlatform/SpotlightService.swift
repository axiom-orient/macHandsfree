import Foundation
import MacHandsfreeCore

struct SpotlightService: CommandService {
  let name = "spotlight"
  private let processRunner: any ProcessRunning
  init(processRunner: any ProcessRunning) { self.processRunner = processRunner }
  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    throw AgentError(
      code: "preview_not_supported", message: "Spotlight commands are read-only", exitCode: 5)
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      let object = try input.requiredObject()
      switch command.id {
      case "spotlight.search":
        var arguments = ["-0"]
        if let scope = object.optionalString("scope") {
          arguments += ["-onlyin", NSString(string: scope).expandingTildeInPath]
        }
        arguments.append(try object.requiredString("query"))
        let result = try await processRunner.run(
          ProcessRequest(
            executable: "/usr/bin/mdfind", arguments: arguments, timeout: 60,
            maximumOutputBytes: 16 * 1_024 * 1_024))
        guard !result.timedOut, !result.outputLimitExceeded, result.exitCode == 0
        else {
          throw AgentError(
            code: "spotlight_search_failed", message: "mdfind failed",
            details: ["stderr": .string(result.stderrString ?? "")], exitCode: 5)
        }
        let limit = object.optionalInt("limit", default: 100) ?? 100
        var paths: [JSONValue] = []
        var truncated = false
        let output = result.stdout
        var start = output.startIndex
        while start < output.endIndex {
          let end = output[start...].firstIndex(of: 0) ?? output.endIndex
          let range = start..<end
          if !range.isEmpty {
            guard paths.count < limit else {
              truncated = true
              break
            }
            guard let path = String(bytes: output[range], encoding: .utf8) else {
              throw AgentError(
                code: "spotlight_search_failed",
                message: "mdfind returned a path that is not valid UTF-8",
                details: ["stderr": .string(result.stderrString ?? "")],
                exitCode: 5
              )
            }
            paths.append(.string(path))
          }
          guard end < output.endIndex else { break }
          start = output.index(after: end)
        }
        return .object([
          "paths": .array(paths),
          "truncated": .bool(truncated),
        ])
      case "spotlight.metadata.get":
        let path = NSString(string: try object.requiredString("path")).expandingTildeInPath
        var arguments = object.stringArray("attributes").flatMap { ["-name", $0] }
        arguments.append(path)
        let result = try await processRunner.run(
          ProcessRequest(executable: "/usr/bin/mdls", arguments: arguments, timeout: 30))
        guard !result.timedOut, !result.outputLimitExceeded, result.exitCode == 0,
          let text = result.stdoutString
        else {
          throw AgentError(
            code: "spotlight_metadata_failed", message: "mdls failed",
            details: ["stderr": .string(result.stderrString ?? "")], exitCode: 5)
        }
        return .object(["path": .string(path), "raw": .string(text)])
      default:
        throw AgentError(
          code: "unsupported_spotlight_command",
          message: "Spotlight service does not support command", exitCode: 5)
      }
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }
}
