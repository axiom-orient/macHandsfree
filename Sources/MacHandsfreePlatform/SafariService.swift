import Foundation
import MacHandsfreeCore

#if os(macOS)
  import AppKit
#endif

struct SafariService: CurrentStateValidatedCommandService {
  let name = "safari"
  private let runner: any AppleEventsRunning
  private let applicationIdentity: @Sendable () throws -> RunningApplicationIdentity
  private static let bundleID = "com.apple.Safari"
  private static let guardVersion: Int64 = 2

  init(
    runner: any AppleEventsRunning,
    applicationIdentity: @escaping @Sendable () throws -> RunningApplicationIdentity = {
      try SafariService.currentApplicationIdentity()
    }
  ) {
    self.runner = runner
    self.applicationIdentity = applicationIdentity
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    let object = try input.requiredObject()
    switch command.id {
    case "safari.tabs.close", "safari.tabs.activate":
      let before = try currentIdentity()
      var snapshotInput = object
      snapshotInput["snapshot_for_mutation"] = .bool(true)
      let current = try await runner.run(
        script: "safari", operation: "safari.tabs.get", input: .object(snapshotInput), mutation: false)
      try requireCurrentIdentity(before)
      let tab = try exactTab(current["tab_target"], input: object)
      let target = tab["url"]?.stringValue ?? tab["name"]?.stringValue ?? "Safari tab"
      return .object([
        "effects": .array([
          effect(command.id, target, details: ["tab": .object(tab)])
        ]),
        "guard_version": .integer(Self.guardVersion),
        "target_snapshot": before.json,
      ])
    default:
      let target = object["url"]?.stringValue ?? "Safari"
      return effects([effect(command.id, target)])
    }
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    guard command.id == "safari.tabs.close" || command.id == "safari.tabs.activate" else {
      return try await execute(command: command, input: input)
    }
    guard command.kind == .mutation else {
      throw invalidPreview("A read-only command cannot dispatch a Safari tab mutation")
    }
    guard plannedPreview["guard_version"] == .integer(Self.guardVersion) else {
      throw AgentError(
        code: "plan_state_changed",
        message: "The Safari plan does not include a current target guard",
        details: ["command": .string(command.id), "reason_code": .string("plan_guard_missing")],
        exitCode: 6
      )
    }
    guard let effects = plannedPreview["effects"]?.arrayValue, effects.count == 1,
      effects[0]["action"]?.stringValue == command.id
    else {
      throw AgentError(
        code: "plan_preview_invalid",
        message: "The stored Safari plan preview is incomplete",
        details: ["command": .string(command.id)],
        exitCode: 5
      )
    }
    var object = try input.requiredObject()
    let tab = try exactTab(effects[0]["details"]?["tab"], input: object)
    let identity = try expectedIdentity(plannedPreview)
    try requireCurrentIdentity(identity)
    object["expected_tab"] = .object(tab)
    object["expected_application"] = identity.json
    return try await runner.run(
      script: "safari", operation: command.id, input: .object(object), mutation: true,
      validateBeforeLaunch: { try requireCurrentIdentity(identity) })
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    guard command.id != "safari.tabs.close", command.id != "safari.tabs.activate" else {
      throw invalidPreview("Safari tab mutations require the native target and application snapshot from a reviewed plan")
    }
    return try await runner.run(
      script: "safari", operation: command.id, input: input, mutation: command.kind == .mutation)
  }

  private func exactTab(_ value: JSONValue?, input: [String: JSONValue]) throws
    -> [String: JSONValue]
  {
    guard let tab = value?.objectValue,
      Set(tab.keys) == Set(["window_id", "native_window_id", "index", "name", "url"]),
      let windowID = tab["window_id"]?.intValue, windowID > 0,
      let nativeWindowID = tab["native_window_id"]?.intValue, nativeWindowID > 0,
      nativeWindowID <= 9_007_199_254_740_991,
      let index = tab["index"]?.intValue, index > 0,
      input["window_id"]?.intValue == windowID, input["tab_index"]?.intValue == index,
      let name = tab["name"]?.stringValue,
      let url = tab["url"]?.stringValue
    else {
      throw invalidPreview("The Safari tab snapshot is missing its exact native window identity or selector")
    }
    return [
      "window_id": .integer(Int64(windowID)),
      "native_window_id": .integer(Int64(nativeWindowID)),
      "index": .integer(Int64(index)),
      "name": .string(name),
      "url": .string(url),
    ]
  }

  private func expectedIdentity(_ preview: JSONValue) throws -> RunningApplicationIdentity {
    guard let fields = preview["target_snapshot"]?.objectValue,
      Set(fields.keys) == Set(["pid", "bundle_id", "bundle_path", "launch_date", "process_start_time"])
    else { throw invalidPreview("The Safari plan is missing its exact running-application snapshot") }
    do {
      let identity = try RunningApplicationIdentity(plannedPreview: preview)
      try Self.validateIdentity(identity)
      return identity
    } catch {
      throw invalidPreview("The Safari running-application snapshot is malformed")
    }
  }

  private func currentIdentity() throws -> RunningApplicationIdentity {
    let identity = try applicationIdentity()
    try Self.validateIdentity(identity)
    return identity
  }

  private func requireCurrentIdentity(_ expected: RunningApplicationIdentity) throws {
    let current: RunningApplicationIdentity
    do { current = try currentIdentity() }
    catch {
      throw AgentError(code: "plan_state_changed", message: "The reviewed Safari application is no longer available", exitCode: 6)
    }
    guard current == expected else {
      throw AgentError(code: "plan_state_changed", message: "Safari restarted or its running-application identity changed after review", exitCode: 6)
    }
  }

  private static func validateIdentity(_ identity: RunningApplicationIdentity) throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard identity.bundleIdentifier == bundleID,
      identity.processIdentifier > 0, Int32(exactly: identity.processIdentifier) != nil,
      let path = identity.bundlePath, path.hasPrefix("/"), !path.contains("\0"),
      let launchDate = identity.launchDate, formatter.date(from: launchDate) != nil
    else {
      throw AgentError(code: "application_identity_unavailable", message: "Safari requires a readable running-process identity and launch date", exitCode: 6)
    }
  }

  private static func currentApplicationIdentity() throws -> RunningApplicationIdentity {
    #if os(macOS)
      let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { !$0.isTerminated }
      guard applications.count == 1, let app = applications.first else {
        throw AgentError(code: "application_identity_unavailable", message: "One running Safari application is required for an exact tab mutation", exitCode: 6)
      }
      return RunningApplicationIdentity(
        processIdentifier: Int64(app.processIdentifier), bundleIdentifier: app.bundleIdentifier,
        bundlePath: app.bundleURL?.standardizedFileURL.path,
        launchDate: app.launchDate.map { ISO8601DateFormatter.agentString(from: $0) },
        processStartTime: MacProcessStartTime.current(for: app.processIdentifier))
    #else
      throw AgentError.unsupported("safari")
    #endif
  }

  private func invalidPreview(_ message: String) -> AgentError {
    AgentError(code: "plan_preview_invalid", message: message, exitCode: 6)
  }
}
