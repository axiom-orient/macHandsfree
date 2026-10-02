import Foundation
import MacHandsfreeCore

enum ExecutionResumePolicy {
  static func existing(
    _ record: StoredExecutionRecord, command: String, inputHash: String
  ) throws -> BeginExecution {
    guard record.command == command, record.inputHash == inputHash else {
      throw AgentError(
        code: "idempotency_conflict",
        message: "The idempotency key is already bound to different input",
        exitCode: 6)
    }

    switch record.status {
    case .succeeded?:
      guard let result = record.resultJSON else { throw malformedRecord() }
      return .replay(result: try JSONValue.parse(Data(result.utf8)))
    case .running?:
      // A durable running row cannot distinguish ongoing work from an unconfirmed effect.
      throw AgentError(
        code: "operation_in_progress",
        message: "An execution with this idempotency key is already in progress", exitCode: 6,
        outcomeUncertain: true)
    case .failed?:
      throw storedError(record.resultJSON, uncertain: false)
    case .uncertain?:
      throw storedError(record.resultJSON, uncertain: true)
    case nil:
      throw malformedRecord()
    }
  }

  private static func storedError(_ json: String?, uncertain: Bool) -> AgentError {
    guard let json, let value = try? JSONValue.parse(Data(json.utf8)),
      let object = value.objectValue, let code = object["code"]?.stringValue,
      let message = object["message"]?.stringValue
    else {
      return AgentError(
        code: uncertain ? "outcome_uncertain" : "execution_failed",
        message: uncertain ? "The previous execution outcome is uncertain" : "The previous execution failed",
        exitCode: 5, outcomeUncertain: uncertain)
    }
    let details = object["details"]?.objectValue ?? [:]
    let storedExitCode = object["exit_code"]?.intValue
    let exitCode = storedExitCode.flatMap { Int32(exactly: $0) } ?? 5
    let recordedUncertain = object["outcome_uncertain"]?.boolValue ?? uncertain
    return AgentError(
      code: code, message: message, details: details,
      exitCode: exitCode, outcomeUncertain: uncertain || recordedUncertain)
  }

  private static func malformedRecord() -> AgentError {
    AgentError(
      code: "execution_state_invalid",
      message: "The saved execution state is malformed", exitCode: 5)
  }
}
