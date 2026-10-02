import Testing
@testable import MacHandsfreeCore

struct CommandRegistryTests {
  @Test func dashedCLIPathPreservesUnderscoredCapabilityID() throws {
    let registry = try CommandRegistry()
    let command = try #require(registry.command(id: "accessibility.elements.set_value"))
    #expect(command.path == ["accessibility", "elements", "set-value"])
    let invocation = try registry.resolve(arguments: command.path + ["plan"])
    #expect(invocation.spec.id == command.id)
    #expect(invocation.mode == .plan)
    #expect(registry.command(id: "accessibility.elements.set-value") == nil)
  }
  @Test func reminderMutationRequiresSeparatePlanAndExecuteCommands() throws {
    let registry = try CommandRegistry()

    let plan = try registry.resolve(arguments: ["reminders", "items", "create", "plan"])
    let execute = try registry.resolve(arguments: ["reminders", "items", "create", "execute"])

    #expect(plan.spec.id == "reminders.items.create")
    #expect(plan.mode == .plan)
    #expect(execute.spec.id == plan.spec.id)
    #expect(execute.mode == .execute)

    do {
      _ = try registry.resolve(arguments: ["reminders", "items", "create"])
      Issue.record("A mutation must not resolve without an explicit phase")
    } catch {}
  }
}
