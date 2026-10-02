import Foundation
import MacHandsfreeCore

#if os(macOS)
  import AppKit
#endif

actor ClipboardService: CurrentStateValidatedCommandService {
  let name = "clipboard"
  private let pathGuard = LocalPathMutationGuard()

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    let object = try input.requiredObject()
    if command.id == "clipboard.text.write" {
      return effects([
        effect(
          "replace_clipboard_text",
          "clipboard",
          details: ["characters": .integer(Int64(try object.requiredString("text").count))]
        )
      ])
    }
    let paths = try object.stringArray("paths").map(LocalPathPolicy.requireExisting)
    let preview = effects([
      effect(
        "replace_clipboard_files",
        "clipboard",
        details: [
          "count": .integer(Int64(paths.count)),
          "paths": .array(paths.map { .string($0.path) }),
        ]
      )
    ])
    return try pathGuard.attaching(pathGuardSpecs(command: command, input: input), to: preview)
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      let pasteboard = NSPasteboard.general
      switch command.id {
      case "clipboard.text.read":
        return .object([
          "text": pasteboard.string(forType: .string).map(JSONValue.string) ?? .null
        ])
      case "clipboard.text.write":
        let text = try input.requiredObject().requiredString("text")
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
          throw AgentError(
            code: "clipboard_write_failed",
            message: "Could not write text to clipboard after clearing the prior contents",
            exitCode: 5,
            outcomeUncertain: true
          )
        }
        return .object([
          "written": .bool(true),
          "characters": .integer(Int64(text.count)),
        ])
      case "clipboard.files.read":
        let urls =
          pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
          ) as? [URL] ?? []
        return .object(["paths": .array(urls.map { .string($0.path) })])
      case "clipboard.files.write":
        return try writeFiles(input)
      default:
        throw AgentError(
          code: "unsupported_clipboard_command",
          message: "Clipboard service does not support command",
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
    let specs = try pathGuardSpecs(command: command, input: input)
    try pathGuard.validate(plannedPreview, specs: specs)
    if command.id == "clipboard.files.write" {
      return try writeFiles(input) {
        try pathGuard.validate(plannedPreview, specs: specs)
      }
    }
    return try await execute(command: command, input: input)
  }

  private func writeFiles(
    _ input: JSONValue,
    validateBeforeWrite: () throws -> Void = {}
  ) throws -> JSONValue {
    #if os(macOS)
      let urls = try input.requiredObject().stringArray("paths").map(
        LocalPathPolicy.requireExisting
      )
      try validateBeforeWrite()
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard pasteboard.writeObjects(urls as [NSURL]) else {
        throw AgentError(
          code: "clipboard_write_failed",
          message: "Could not write file URLs to clipboard after clearing the prior contents",
          exitCode: 5,
          outcomeUncertain: true
        )
      }
      return .object([
        "written": .bool(true),
        "count": .integer(Int64(urls.count)),
      ])
    #else
      _ = input
      _ = validateBeforeWrite
      throw AgentError.unsupported("clipboard.files.write")
    #endif
  }

  private func pathGuardSpecs(command: CommandSpec, input: JSONValue) throws
    -> [LocalPathGuardSpec]
  {
    guard command.id == "clipboard.files.write" else { return [] }
    let paths = try input.requiredObject().stringArray("paths")
    return try paths.enumerated().map { index, path in
      LocalPathGuardSpec(
        role: "clipboard_path_\(index)",
        url: try LocalPathPolicy.expandedURL(path),
        trackChanges: false
      )
    }
  }

}
