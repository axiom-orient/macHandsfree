import MacHandsfreeCore

struct ServiceRouter: CommandExecutor {
  private let services: [String: ServiceRegistration]

  init(registry: CommandRegistry, services: [ServiceRegistration]) throws {
    let grouped = Dictionary(grouping: services, by: \.name)
    let duplicates = grouped.filter { $0.value.count > 1 }.keys.sorted()
    guard duplicates.isEmpty else {
      throw AgentError(
        code: "duplicate_service", message: "Multiple services have the same name",
        details: ["services": .array(duplicates.map(JSONValue.string))], exitCode: 5)
    }

    let registered = Set(grouped.keys)
    let required = Set(registry.commands.map(\.service))
    let missing = required.subtracting(registered).sorted()
    let unexpected = registered.subtracting(required).sorted()
    guard missing.isEmpty, unexpected.isEmpty else {
      throw AgentError(
        code: "invalid_service_matrix",
        message: "Registered services do not match the canonical command registry",
        details: [
          "missing": .array(missing.map(JSONValue.string)),
          "unexpected": .array(unexpected.map(JSONValue.string)),
        ],
        exitCode: 5
      )
    }

    let mutationServices = Set(
      registry.commands.lazy.filter { $0.kind == .mutation }.map(\.service))
    let invalidPolicies = services.compactMap { service -> JSONValue? in
      let hasMutations = mutationServices.contains(service.name)
      let valid =
        hasMutations
        ? service.mutationPolicy != .notApplicable
        : service.mutationPolicy == .notApplicable
      guard !valid else { return nil }
      return .object([
        "service": .string(service.name),
        "policy": .string(service.mutationPolicy.rawValue),
        "has_mutations": .bool(hasMutations),
      ])
    }
    guard invalidPolicies.isEmpty else {
      throw AgentError(
        code: "invalid_mutation_policy_matrix",
        message: "Service mutation policies do not match the canonical command registry",
        details: ["services": .array(invalidPolicies)],
        exitCode: 5
      )
    }

    self.services = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> CommandPreview {
    let exactPreview = try await service(for: command).preview(command: command, input: input)
    return CommandPreview(
      execution: exactPreview,
      presentation: FileTreeGuardPresentation.publicValue(exactPreview)
    )
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    try await service(for: command).execute(command: command, input: input)
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    try await service(for: command).executeMutation(
      command: command, input: input, plannedPreview: plannedPreview)
  }

  private func service(for command: CommandSpec) throws -> ServiceRegistration {
    guard let service = services[command.service] else {
      throw AgentError(
        code: "service_unavailable", message: "No service is registered for this command",
        details: ["service": .string(command.service)], exitCode: 5)
    }
    return service
  }
}
