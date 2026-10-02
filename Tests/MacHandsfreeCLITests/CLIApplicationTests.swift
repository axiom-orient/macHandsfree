import Foundation
import Testing
@testable import MacHandsfreeCore
@testable import MacHandsfreeRuntime

struct CLIApplicationTests {
  @Test func encodingFailureKeepsAnObservedUncertainOutcome() throws {
    let response = ResponseEnvelope.failure(command: "notes.items.create", error: AgentError(
      code: "effect_unconfirmed", message: "Effect may have happened",
      details: ["invalid_number": .number(.nan)], outcomeUncertain: true))
    let result = CLIResponseEncoder.encode(response, invocation: nil)
    let output = try JSONValue.parse(result.output)
    #expect(result.exitCode == 5)
    #expect(output["error"]?["code"]?.stringValue == "encoding_failed")
    #expect(output["error"]?["outcome_uncertain"]?.boolValue == true)
    #expect(output["command"]?.stringValue == "notes.items.create")
  }

  @Test func encodingFailureAfterSuccessfulMutationExecuteRequiresEffectConfirmation() throws {
    let registry = try CommandRegistry()
    let command = try #require(registry.command(id: "notes.items.create"))
    let response = ResponseEnvelope.success(
      command: command.id, data: .object(["invalid_number": .number(.nan)]))
    let result = CLIResponseEncoder.encode(
      response, invocation: ResolvedCommand(spec: command, mode: .execute))
    let output = try JSONValue.parse(result.output)
    #expect(result.exitCode == 5)
    #expect(output["error"]?["outcome_uncertain"]?.boolValue == true)
  }

  @Test func encodingFailureBeforeMutationExecutionDoesNotInventUncertainty() throws {
    let registry = try CommandRegistry()
    let command = try #require(registry.command(id: "notes.items.create"))
    let response = ResponseEnvelope.success(
      command: command.id, data: .object(["invalid_number": .number(.nan)]))
    let result = CLIResponseEncoder.encode(
      response, invocation: ResolvedCommand(spec: command, mode: .plan))
    let output = try JSONValue.parse(result.output)
    #expect(output["error"]?["outcome_uncertain"]?.boolValue == false)
  }

  @Test func encodingFailureKeepsAKnownMutationFailureWithoutInventingEffects() throws {
    let registry = try CommandRegistry()
    let command = try #require(registry.command(id: "notes.items.create"))
    let response = ResponseEnvelope.failure(command: command.id, error: AgentError(
      code: "precondition_failed", message: "No effect was applied",
      details: ["invalid_number": .number(.nan)]))
    let result = CLIResponseEncoder.encode(
      response, invocation: ResolvedCommand(spec: command, mode: .execute))
    let output = try JSONValue.parse(result.output)
    #expect(output["error"]?["outcome_uncertain"]?.boolValue == false)
  }

  @Test func boundedInputAcceptsAnIntegerMaximumWithoutOverflow() throws {
    let expected = Data("finite request".utf8)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      if FileManager.default.fileExists(atPath: url.path) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Bounded input fixture cleanup failed: \(error)") }
      }
    }
    try expected.write(to: url)
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      do { try handle.close() }
      catch { Issue.record("Bounded input fixture close failed: \(error)") }
    }
    #expect(try BoundedInputReader.readAll(from: handle, maximumBytes: Int.max) == expected)
  }

  @Test func commandListIncludesTaskMemoryCalendarAndMessageCapabilities() async throws {
    let runtime = try RuntimeFactory.make(
      environment: ["MAC_HANDSFREE_STATE_DIR": "/not-created/mac-handsfree-test-state"])
    let application = CLIApplication(runtime: runtime)
    let result = await application.run(arguments: ["commands", "list"], input: Data("{}".utf8))

    #expect(result.exitCode == 0)
    let response = try JSONValue.parse(result.output)
    let commands = response["data"]?["commands"]?.arrayValue ?? []
    let ids = Set(commands.compactMap { $0["id"]?.stringValue })

    #expect(ids.contains("reminders.items.search"))
    #expect(ids.contains("notes.items.search"))
    #expect(ids.contains("calendar.events.list"))
    #expect(ids.contains("messages.messages.search"))
  }
}
