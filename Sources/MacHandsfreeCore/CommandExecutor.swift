package protocol CommandExecutor: Sendable {
  func preview(command: CommandSpec, input: JSONValue) async throws -> CommandPreview
  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue
  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue
}

package struct CommandPreview: Sendable {
  /// Exact guard data stored for execution.
  package let execution: JSONValue
  /// User-facing plan details; it may omit implementation-only guard values.
  package let presentation: JSONValue

  package init(execution: JSONValue, presentation: JSONValue) {
    self.execution = execution
    self.presentation = presentation
  }
}
