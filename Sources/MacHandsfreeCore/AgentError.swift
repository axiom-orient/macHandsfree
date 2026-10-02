package struct AgentError: Error, Sendable {
  package let code: String
  package let message: String
  package let details: [String: JSONValue]
  package let exitCode: Int32
  package let outcomeUncertain: Bool

  package init(
    code: String,
    message: String,
    details: [String: JSONValue] = [:],
    exitCode: Int32 = 5,
    outcomeUncertain: Bool = false
  ) {
    self.code = code
    self.message = message
    self.details = details
    self.exitCode = exitCode
    self.outcomeUncertain = outcomeUncertain
  }

  package static func invalid(_ message: String, details: [String: JSONValue] = [:]) -> AgentError {
    AgentError(code: "invalid_input", message: message, details: details, exitCode: 2)
  }

  package static func unsupported(_ capability: String) -> AgentError {
    AgentError(
      code: "platform_unsupported",
      message: "This command requires macOS",
      details: ["capability": .string(capability)],
      exitCode: 4
    )
  }
}
