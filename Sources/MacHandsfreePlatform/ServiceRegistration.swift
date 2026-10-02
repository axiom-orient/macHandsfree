import MacHandsfreeCore

protocol CommandService: Sendable {
  var name: String { get }
  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue
  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue
}

protocol CurrentStateValidatedCommandService: CommandService {
  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue
}

enum MutationExecutionPolicy: String, Sendable {
  case notApplicable
  case plannedInput
  case currentStateValidated
}

struct ServiceRegistration: Sendable {
  let name: String
  let mutationPolicy: MutationExecutionPolicy
  private let previewOperation: @Sendable (CommandSpec, JSONValue) async throws -> JSONValue
  private let executeOperation: @Sendable (CommandSpec, JSONValue) async throws -> JSONValue
  private let executeMutationOperation:
    @Sendable (CommandSpec, JSONValue, JSONValue) async throws -> JSONValue

  private init<Service: CommandService>(
    service: Service,
    mutationPolicy: MutationExecutionPolicy,
    executeMutation:
      @escaping @Sendable (CommandSpec, JSONValue, JSONValue) async throws -> JSONValue
  ) {
    self.name = service.name
    self.mutationPolicy = mutationPolicy
    self.previewOperation = { command, input in
      try await service.preview(command: command, input: input)
    }
    self.executeOperation = { command, input in
      try await service.execute(command: command, input: input)
    }
    self.executeMutationOperation = executeMutation
  }

  static func readOnly<Service: CommandService>(_ service: Service) -> Self {
    Self(service: service, mutationPolicy: .notApplicable) { command, _, _ in
      throw AgentError(
        code: "invalid_mutation_route",
        message: "A read-only service received a mutation execution request",
        details: ["command": .string(command.id), "service": .string(service.name)],
        exitCode: 5
      )
    }
  }

  static func plannedInput<Service: CommandService>(_ service: Service) -> Self {
    Self(service: service, mutationPolicy: .plannedInput) { command, input, _ in
      try await service.execute(command: command, input: input)
    }
  }

  static func currentStateValidated<Service: CurrentStateValidatedCommandService>(
    _ service: Service
  ) -> Self {
    Self(service: service, mutationPolicy: .currentStateValidated) {
      command, input, plannedPreview in
      try await service.executeMutation(
        command: command, input: input, plannedPreview: plannedPreview)
    }
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    try await previewOperation(command, input)
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    try await executeOperation(command, input)
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    try await executeMutationOperation(command, input, plannedPreview)
  }
}
