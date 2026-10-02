import Foundation
import MacHandsfreeCore

enum CallOperation: String, Sendable, Equatable {
  case start = "calls.video.start"
  case confirm = "calls.video.confirm"
  case end = "calls.video.end"
}

enum CallExecutionState: Sendable, Equatable {
  case idle
  case running(id: UUID, operation: CallOperation)
}

enum CallExecutionEvent: Sendable, Equatable {
  case begin(id: UUID, operation: CallOperation)
  case finish(id: UUID)
}

enum CallExecutionTransition: Sendable, Equatable {
  case accepted(CallExecutionState)
  case rejected(active: CallOperation, requested: CallOperation)
  case ignored(CallExecutionState)
}

enum CallExecutionReducer {
  static func reduce(
    state: CallExecutionState,
    event: CallExecutionEvent
  ) -> CallExecutionTransition {
    switch (state, event) {
    case (.idle, .begin(let id, let operation)):
      return .accepted(.running(id: id, operation: operation))
    case (.running(_, let active), .begin(_, let requested)):
      return .rejected(active: active, requested: requested)
    case (.running(let activeID, _), .finish(let finishedID)) where activeID == finishedID:
      return .accepted(.idle)
    case (_, .finish):
      return .ignored(state)
    }
  }
}

actor CallService: CommandService {
  nonisolated let name = "calls"
  private let processRunner: any ProcessRunning
  private let confirmer: any FaceTimeCallConfirming
  private let ender: any FaceTimeCallEnding
  private var executionState: CallExecutionState = .idle

  init(
    processRunner: any ProcessRunning,
    confirmer: any FaceTimeCallConfirming = FaceTimeAccessibilityAdapter(),
    ender: any FaceTimeCallEnding = FaceTimeAccessibilityAdapter()
  ) {
    self.processRunner = processRunner
    self.confirmer = confirmer
    self.ender = ender
  }

  nonisolated func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    if command.id == CallOperation.end.rawValue {
      return effects([effect("end_active_video_call", "active FaceTime call")])
    }
    let handle = try input.requiredObject().requiredString("handle")
    let target = try Self.videoCallURL(handle: handle)
    let action =
      command.id == CallOperation.confirm.rawValue ? "confirm_video_call" : "start_video_call"
    return effects([effect(action, handle, details: ["url": .string(target)])])
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      let operation = try Self.operation(for: command.id)
      let executionID = UUID()
      try begin(executionID: executionID, operation: operation)
      defer { finish(executionID: executionID) }

      switch operation {
      case .end:
        try await ender.endActiveCall()
        return .object([
          "call_end_clicked": .bool(true),
          "connection_verified": .bool(false),
        ])
      case .confirm:
        let handle = try input.requiredObject().requiredString("handle")
        _ = try Self.videoCallURL(handle: handle)
        try await confirmer.confirm(handle: handle)
        return .object([
          "confirmation_clicked": .bool(true),
          "connection_verified": .bool(false),
          "handle": .string(handle),
        ])
      case .start:
        let handle = try input.requiredObject().requiredString("handle")
        let url = try Self.videoCallURL(handle: handle)
        let result = try await processRunner.run(
          ProcessRequest(executable: "/usr/bin/open", arguments: [url], timeout: 30)
        )
        guard result.exitCode == 0, !result.timedOut, !result.outputLimitExceeded else {
          throw AgentError(
            code: "video_call_launch_failed",
            message: "Could not request a FaceTime video call",
            details: ["stderr": .string(result.stderrString ?? "")],
            exitCode: 5,
            outcomeUncertain: true
          )
        }
        return .object([
          "call_requested": .bool(true),
          "confirmation_required": .bool(true),
          "confirmation_app": .string("FaceTime"),
          "next_action": .string(
            "Confirm the call in the FaceTime UI. An accessibility-enabled UI adapter may do this only after explicit user approval; this response does not prove it connected."
          ),
          "handle": .string(handle),
          "url": .string(url),
        ])
      }
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  private func begin(executionID: UUID, operation: CallOperation) throws {
    switch CallExecutionReducer.reduce(
      state: executionState,
      event: .begin(id: executionID, operation: operation)
    ) {
    case .accepted(let nextState):
      executionState = nextState
    case .rejected(let active, let requested):
      throw AgentError(
        code: "facetime_operation_in_progress",
        message: "Another FaceTime operation is already in progress",
        details: [
          "active_command": .string(active.rawValue),
          "requested_command": .string(requested.rawValue),
        ],
        exitCode: 6
      )
    case .ignored:
      preconditionFailure("A begin event cannot be ignored")
    }
  }

  private func finish(executionID: UUID) {
    switch CallExecutionReducer.reduce(state: executionState, event: .finish(id: executionID)) {
    case .accepted(let nextState), .ignored(let nextState):
      executionState = nextState
    case .rejected:
      preconditionFailure("A finish event cannot be rejected")
    }
  }

  private static func operation(for commandID: String) throws -> CallOperation {
    guard let operation = CallOperation(rawValue: commandID) else {
      throw AgentError(
        code: "unsupported_calls_command",
        message: "Calls service does not support command",
        details: ["command": .string(commandID)],
        exitCode: 5
      )
    }
    return operation
  }

  nonisolated static func videoCallURL(handle: String) throws -> String {
    let normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    let phone = normalized.range(of: #"^\+[1-9][0-9]{5,14}$"#, options: .regularExpression) != nil
    let email =
      normalized.range(
        of: #"^[A-Za-z0-9.!#$&'*+_=^`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#,
        options: .regularExpression
      ) != nil
    guard phone || email else {
      throw AgentError.invalid(
        "handle must be an E.164 phone number or email address",
        details: ["property": .string("handle")]
      )
    }
    let allowed = CharacterSet(
      charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@"
    )
    guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw AgentError.invalid(
        "handle could not be encoded as a FaceTime URL",
        details: ["property": .string("handle")]
      )
    }
    return "facetime://\(encoded)"
  }
}
