import Foundation
import Testing
import MacHandsfreeCore
@testable import MacHandsfreePlatform

struct SafariMutationGuardTests {
  @Test func previewCapturesNativeWindowAndTheExistingApplicationIdentity() async throws {
    let fixture = SafariSessionFixture()
    let runner = SafariFixtureRunner()
    let service = SafariService(runner: runner, applicationIdentity: { fixture.current() })
    let preview = try await service.preview(command: command("safari.tabs.close"), input: input)
    #expect(preview["guard_version"] == .integer(2))
    #expect(preview["target_snapshot"] == fixture.current().json)
    #expect(preview["effects"]?.arrayValue?.first?["details"]?["tab"]?["native_window_id"] == .integer(101))
    let requests = await runner.requests
    #expect(requests.count == 1)
    #expect(requests.first?["snapshot_for_mutation"] == .bool(true))
  }

  @Test func directCloseAndActivateCannotBypassTheReviewedGuard() async throws {
    let runner = SafariFixtureRunner()
    let fixture = SafariSessionFixture()
    let service = SafariService(runner: runner, applicationIdentity: { fixture.current() })
    for id in ["safari.tabs.close", "safari.tabs.activate"] {
      do {
        _ = try await service.execute(command: command(id), input: input)
        Issue.record("Direct tab mutation must not reach the runner")
      } catch let error as AgentError {
        #expect(error.code == "plan_preview_invalid")
        #expect(!error.outcomeUncertain)
      }
    }
    let requests = await runner.requests
    #expect(requests.isEmpty)
  }

  @Test func missingMalformedAndOldReviewedSnapshotsRejectBeforeDispatch() async throws {
    let fixture = SafariSessionFixture()
    let runner = SafariFixtureRunner()
    let service = SafariService(runner: runner, applicationIdentity: { fixture.current() })
    let command = try command("safari.tabs.close")
    let valid = try await service.preview(command: command, input: input)
    var missingSession = try valid.requiredObject()
    missingSession.removeValue(forKey: "target_snapshot")
    var old = try valid.requiredObject()
    old["guard_version"] = .integer(1)
    var badSession = try fixture.current().json.requiredObject()
    badSession["launch_date"] = .null
    var invalidSession = try valid.requiredObject()
    invalidSession["target_snapshot"] = .object(badSession)
    var malformedTab = SafariFixtureRunner.target
    malformedTab.removeValue(forKey: "native_window_id")
    let invalidTarget: JSONValue = .object([
      "guard_version": .integer(2), "target_snapshot": fixture.current().json,
      "effects": .array([.object([
        "action": .string(command.id), "target": "Same",
        "details": .object(["tab": .object(malformedTab)]),
      ])]),
    ])
    for snapshot in [.object(missingSession), .object(old), .object(invalidSession), invalidTarget] {
      do {
        _ = try await service.executeMutation(command: command, input: input, plannedPreview: snapshot)
        Issue.record("Incomplete or obsolete snapshots must not reach a mutation")
      } catch let error as AgentError {
        #expect(["plan_preview_invalid", "plan_state_changed"].contains(error.code))
        #expect(!error.outcomeUncertain)
      }
    }
    let mutations = await runner.mutations
    #expect(mutations == 0)
  }

  @Test func processRelaunchAfterReviewRejectsBeforeRunnerDispatch() async throws {
    let fixture = SafariSessionFixture()
    let runner = SafariFixtureRunner()
    let service = SafariService(runner: runner, applicationIdentity: { fixture.current() })
    let command = try command("safari.tabs.close")
    let preview = try await service.preview(command: command, input: input)
    fixture.relaunch()
    do {
      _ = try await service.executeMutation(command: command, input: input, plannedPreview: preview)
      Issue.record("A reused PID with a new process start time must invalidate the plan")
    } catch let error as AgentError {
      #expect(error.code == "plan_state_changed")
      #expect(!error.outcomeUncertain)
    }
    let requests = await runner.requests
    #expect(requests.count == 1)
  }

  @Test func processRelaunchAtTheLaunchBoundaryRejectsBeforeEffect() async throws {
    let fixture = SafariSessionFixture()
    let runner = SafariFixtureRunner(beforeMutationLaunch: { fixture.relaunch() })
    let service = SafariService(runner: runner, applicationIdentity: { fixture.current() })
    let command = try command("safari.tabs.activate")
    let preview = try await service.preview(command: command, input: input)
    do {
      _ = try await service.executeMutation(command: command, input: input, plannedPreview: preview)
      Issue.record("The pre-launch callback must stop a late relaunch")
    } catch let error as AgentError {
      #expect(error.code == "plan_state_changed")
      #expect(!error.outcomeUncertain)
    }
    let mutations = await runner.mutations
    #expect(mutations == 0)
  }

  @Test func validReviewSendsBothPrivateGuardsToTheRunner() async throws {
    let fixture = SafariSessionFixture()
    let runner = SafariFixtureRunner()
    let service = SafariService(runner: runner, applicationIdentity: { fixture.current() })
    let command = try command("safari.tabs.close")
    let preview = try await service.preview(command: command, input: input)
    _ = try await service.executeMutation(command: command, input: input, plannedPreview: preview)
    let requests = await runner.requests
    #expect(requests.last?["expected_application"] == fixture.current().json)
    #expect(requests.last?["expected_tab"]?["native_window_id"] == .integer(101))
    let mutations = await runner.mutations
    #expect(mutations == 1)
  }

  private var input: JSONValue { ["window_id": 1, "tab_index": 1] }
  private func command(_ id: String) throws -> CommandSpec {
    try #require(CommandRegistry().command(id: id))
  }
}

private final class SafariSessionFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var started: Int64 = 100
  func relaunch() { lock.withLock { started += 1 } }
  func current() -> RunningApplicationIdentity {
    lock.withLock {
      RunningApplicationIdentity(
        processIdentifier: 111, bundleIdentifier: "com.apple.Safari", bundlePath: "/Applications/Safari.app",
        launchDate: "2026-10-02T01:02:03.000Z",
        processStartTime: MacProcessStartTime(seconds: started, microseconds: 10))
    }
  }
}

private actor SafariFixtureRunner: AppleEventsRunning {
  static let target: [String: JSONValue] = [
    "window_id": 1, "native_window_id": 101, "index": 1, "name": "Same", "url": "https://example.test",
  ]
  private(set) var requests: [JSONValue] = []
  private(set) var mutations = 0
  private let beforeMutationLaunch: (@Sendable () -> Void)?
  init(beforeMutationLaunch: (@Sendable () -> Void)? = nil) {
    self.beforeMutationLaunch = beforeMutationLaunch
  }
  func run(script: String, operation: String, input: JSONValue, mutation: Bool) async throws -> JSONValue {
    try await run(script: script, operation: operation, input: input, mutation: mutation, validateBeforeLaunch: {})
  }
  func run(
    script: String, operation: String, input: JSONValue, mutation: Bool,
    validateBeforeLaunch: @escaping @Sendable () throws -> Void
  ) async throws -> JSONValue {
    if mutation { beforeMutationLaunch?() }
    try validateBeforeLaunch()
    requests.append(input)
    if mutation { mutations += 1; return ["closed": true] }
    return .object(["tab_target": .object(Self.target)])
  }
}
