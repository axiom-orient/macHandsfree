package import Foundation

package struct ExecutionPipeline: Sendable {
  private let executor: any CommandExecutor
  private let state: any ExecutionStateStore
  private let planLifetime: TimeInterval

  package init(
    executor: any CommandExecutor,
    state: any ExecutionStateStore,
    planLifetime: TimeInterval = 600
  ) {
    self.executor = executor
    self.state = state
    self.planLifetime = planLifetime
  }

  package func invoke(_ resolved: ResolvedCommand, input: JSONValue) async -> ResponseEnvelope {
    do {
      try requireNotCancelled(outcomeUncertain: false)
      switch resolved.mode {
      case .read:
        try validate(input, for: resolved.spec)
        try requireNotCancelled(outcomeUncertain: false)
        let result = try await executor.execute(command: resolved.spec, input: input)
        return .success(command: resolved.spec.id, data: result)
      case .plan:
        try validate(input, for: resolved.spec)
        try requireNotCancelled(outcomeUncertain: false)
        let preview = try await executor.preview(command: resolved.spec, input: input)
        try requireNotCancelled(outcomeUncertain: false)
        let plan = try await state.createPlan(
          command: resolved.spec.id,
          input: input,
          preview: preview.execution,
          lifetime: planLifetime
        )
        return .success(
          command: resolved.spec.id,
          data: .object(["plan": plan.json(presenting: preview.presentation)])
        )
      case .execute:
        return try await executeMutation(resolved, executionInput: input)
      }
    } catch let error as AgentError {
      return .failure(command: resolved.spec.id, error: error)
    } catch is CancellationError {
      return .failure(
        command: resolved.spec.id,
        error: cancellationError(outcomeUncertain: false)
      )
    } catch {
      return .failure(
        command: resolved.spec.id,
        error: AgentError(
          code: "internal_error",
          message: "Unexpected internal error",
          details: ["reason": .string(String(describing: error))],
          exitCode: 5
        )
      )
    }
  }

  package func discardPlan(token: String) async throws -> Bool {
    try await state.discardPlan(token: token)
  }

  private func executeMutation(
    _ resolved: ResolvedCommand,
    executionInput: JSONValue
  ) async throws -> ResponseEnvelope {
    try SchemaLibrary.executeSchema.validate(executionInput)
    guard let object = executionInput.objectValue,
      let token = object["plan_token"]?.stringValue,
      let key = object["idempotency_key"]?.stringValue
    else {
      throw AgentError.invalid("Execution input is incomplete")
    }

    try requireNotCancelled(outcomeUncertain: false)
    let decision = try await state.beginExecution(
      command: resolved.spec.id,
      planToken: token,
      idempotencyKey: key
    )
    switch decision {
    case .replay(let result):
      return .success(command: resolved.spec.id, data: result, replayed: true)
    case .execute(let plannedInput, let plannedPreview):
      do {
        try requireNotCancelled(outcomeUncertain: false)
      } catch let cancellation as AgentError {
        try await recordFailureOrEscalate(
          idempotencyKey: key,
          executionError: cancellation
        )
        throw cancellation
      }
      do {
        try validate(plannedInput, for: resolved.spec)
      } catch let validationError as AgentError {
        try await recordFailureOrEscalate(idempotencyKey: key, executionError: validationError)
        throw validationError
      } catch {
        let validationError = AgentError(
          code: "stored_plan_invalid",
          message: "The stored execution plan is invalid",
          details: ["reason": .string(String(describing: error))],
          exitCode: 5
        )
        try await recordFailureOrEscalate(idempotencyKey: key, executionError: validationError)
        throw validationError
      }

      let result: JSONValue
      do {
        result = try await executor.executeMutation(
          command: resolved.spec, input: plannedInput, plannedPreview: plannedPreview)
      } catch let executionError as AgentError {
        try await recordFailureOrEscalate(idempotencyKey: key, executionError: executionError)
        throw executionError
      } catch is CancellationError {
        let executionError = cancellationError(outcomeUncertain: true)
        try await recordFailureOrEscalate(idempotencyKey: key, executionError: executionError)
        throw executionError
      } catch {
        let executionError = AgentError(
          code: "execution_failed",
          message: "Command execution failed",
          details: ["reason": .string(String(describing: error))],
          exitCode: 5,
          outcomeUncertain: true
        )
        try await recordFailureOrEscalate(idempotencyKey: key, executionError: executionError)
        throw executionError
      }

      do {
        try await state.completeSuccess(idempotencyKey: key, result: result)
      } catch {
        throw AgentError(
          code: "execution_state_persist_failed",
          message:
            "The command may have completed, but its idempotency result could not be persisted",
          details: [
            "idempotency_key": .string(key),
            "reason": .string(String(describing: error)),
          ],
          exitCode: 5,
          outcomeUncertain: true
        )
      }
      return .success(command: resolved.spec.id, data: result)
    }
  }

  private func validate(_ input: JSONValue, for command: CommandSpec) throws {
    try command.inputSchema.validate(input)
    try CommandInputValidator.validate(command: command, input: input)
  }

  private func requireNotCancelled(outcomeUncertain: Bool) throws {
    guard !Task.isCancelled else {
      throw cancellationError(outcomeUncertain: outcomeUncertain)
    }
  }

  private func cancellationError(outcomeUncertain: Bool) -> AgentError {
    AgentError(
      code: "operation_cancelled",
      message: "Command execution was cancelled",
      exitCode: 6,
      outcomeUncertain: outcomeUncertain
    )
  }

  private func recordFailureOrEscalate(
    idempotencyKey: String,
    executionError: AgentError
  ) async throws {
    do {
      try await state.completeFailure(idempotencyKey: idempotencyKey, error: executionError)
    } catch {
      throw AgentError(
        code: "execution_state_persist_failed",
        message: "The command failed, but its idempotency state could not be persisted",
        details: [
          "execution_error_code": .string(executionError.code),
          "idempotency_key": .string(idempotencyKey),
          "reason": .string(String(describing: error)),
        ],
        exitCode: 5,
        outcomeUncertain: true
      )
    }
  }
}
