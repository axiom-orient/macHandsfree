import Foundation
import MacHandsfreeCore

#if os(macOS)
  import AppKit
  import Darwin
#endif

struct MacProcessStartTime: Sendable, Equatable {
  let seconds: Int64
  let microseconds: Int64

  var json: JSONValue {
    .object(["seconds": .integer(seconds), "microseconds": .integer(microseconds)])
  }

  static func parse(_ value: JSONValue) throws -> Self? {
    if case .null = value { return nil }
    guard let object = value.objectValue, object.count == 2,
      let seconds = object["seconds"]?.intValue, seconds >= 0,
      let microseconds = object["microseconds"]?.intValue,
      (0..<1_000_000).contains(microseconds)
    else {
      throw AgentError.invalid(
        "process_start_time must contain exact seconds and microseconds from app.list")
    }
    return Self(seconds: Int64(seconds), microseconds: Int64(microseconds))
  }

  #if os(macOS)
    static func current(for processIdentifier: pid_t) -> Self? {
      guard processIdentifier > 0 else { return nil }
      var info = proc_bsdinfo()
      let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
      let receivedSize = proc_pidinfo(
        processIdentifier, PROC_PIDTBSDINFO, 0, &info, expectedSize)
      guard receivedSize == expectedSize,
        info.pbi_pid == UInt32(processIdentifier),
        info.pbi_start_tvusec < 1_000_000,
        let seconds = Int64(exactly: info.pbi_start_tvsec),
        let microseconds = Int64(exactly: info.pbi_start_tvusec)
      else { return nil }
      return Self(seconds: seconds, microseconds: microseconds)
    }
  #endif
}

struct RunningApplicationIdentity: Sendable, Equatable {
  let processIdentifier: Int64
  let bundleIdentifier: String?
  let bundlePath: String?
  let launchDate: String?
  let processStartTime: MacProcessStartTime?

  var json: JSONValue {
    .object([
      "pid": .integer(processIdentifier),
      "bundle_id": bundleIdentifier.map(JSONValue.string) ?? .null,
      "bundle_path": bundlePath.map(JSONValue.string) ?? .null,
      "launch_date": launchDate.map(JSONValue.string) ?? .null,
      "process_start_time": processStartTime?.json ?? .null,
    ])
  }

  init(
    processIdentifier: Int64, bundleIdentifier: String?, bundlePath: String?, launchDate: String?,
    processStartTime: MacProcessStartTime?
  ) {
    self.processIdentifier = processIdentifier
    self.bundleIdentifier = bundleIdentifier
    self.bundlePath = bundlePath
    self.launchDate = launchDate
    self.processStartTime = processStartTime
  }

  init(plannedPreview: JSONValue) throws {
    guard let object = plannedPreview.objectValue?["target_snapshot"]?.objectValue,
      let processIdentifier = object["pid"]?.intValue.map(Int64.init),
      let launchDateValue = object["launch_date"],
      let processStartTimeValue = object["process_start_time"]
    else {
      throw AgentError(
        code: "invalid_plan_preview",
        message: "Application plan is missing its exact running-process snapshot",
        exitCode: 5
      )
    }
    let launchDate: String?
    switch launchDateValue {
    case .null: launchDate = nil
    case .string(let value): launchDate = value
    default:
      throw AgentError(
        code: "invalid_plan_preview",
        message: "Application plan has an invalid launch-date snapshot",
        exitCode: 5
      )
    }
    let processStartTime = try MacProcessStartTime.parse(processStartTimeValue)
    self.init(
      processIdentifier: processIdentifier,
      bundleIdentifier: object["bundle_id"]?.stringValue,
      bundlePath: object["bundle_path"]?.stringValue,
      launchDate: launchDate,
      processStartTime: processStartTime
    )
  }
}

struct AppService: CurrentStateValidatedCommandService {
  let name = "app"
  private let processRunner: any ProcessRunning
  init(processRunner: any ProcessRunning) { self.processRunner = processRunner }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    let object = try input.requiredObject()
    let target =
      object["bundle_id"]?.stringValue ?? object["name"]?.stringValue ?? object["pid"]?.intValue
      .map(String.init) ?? "application"
    var preview = try effects([effect(command.id, target)]).requiredObject()

    #if os(macOS)
      if command.id == "app.activate" || command.id == "app.quit" {
        preview["target_snapshot"] = identity(for: try exactApplication(matching: object)).json
      }
    #endif
    return .object(preview)
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      let object = try input.requiredObject()
      switch command.id {
      case "app.list":
        let apps = NSWorkspace.shared.runningApplications.sorted {
          ($0.localizedName ?? "") < ($1.localizedName ?? "")
        }.map { app in
          JSONValue.object([
            "pid": .integer(Int64(app.processIdentifier)),
            "bundle_id": app.bundleIdentifier.map(JSONValue.string) ?? .null,
            "launch_date": app.launchDate.map {
              .string(ISO8601DateFormatter.agentString(from: $0))
            } ?? .null,
            "process_start_time": MacProcessStartTime.current(for: app.processIdentifier)?.json
              ?? .null,
            "name": app.localizedName.map(JSONValue.string) ?? .null,
            "active": .bool(app.isActive),
            "hidden": .bool(app.isHidden),
            "terminated": .bool(app.isTerminated),
          ])
        }
        return .object(["applications": .array(apps)])
      case "app.launch":
        let bundleID = object.optionalString("bundle_id")
        let appName = object.optionalString("name")
        guard (bundleID == nil) != (appName == nil) else {
          throw AgentError.invalid("Provide exactly one of bundle_id or name")
        }
        let selectorArguments: [String]
        if let bundleID {
          selectorArguments = ["-b", bundleID]
        } else if let appName {
          selectorArguments = ["-a", appName]
        } else {
          throw AgentError.invalid("Provide exactly one of bundle_id or name")
        }
        var arguments = selectorArguments
        let appArguments = object.stringArray("arguments")
        if !appArguments.isEmpty { arguments += ["--args"] + appArguments }
        try await runOpen(arguments, command: command.id)
        return .object([
          "launched": .bool(true), "bundle_id": bundleID.map(JSONValue.string) ?? .null,
          "name": appName.map(JSONValue.string) ?? .null,
        ])
      case "app.activate", "app.quit":
        return try await perform(command: command, on: exactApplication(matching: object))
      default:
        throw AgentError(
          code: "unsupported_app_command", message: "App service does not support the command",
          exitCode: 5)
      }
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    #if os(macOS)
      guard command.id == "app.activate" || command.id == "app.quit" else {
        return try await execute(command: command, input: input)
      }
      let object = try input.requiredObject()
      let app = try exactApplication(matching: object)
      let plannedIdentity = try RunningApplicationIdentity(plannedPreview: plannedPreview)
      let currentIdentity = identity(for: app)
      guard currentIdentity == plannedIdentity else {
        throw AgentError(
          code: "plan_state_changed",
          message: "The exact running application changed after the plan was reviewed",
          details: [
            "planned": plannedIdentity.json,
            "current": currentIdentity.json,
          ],
          exitCode: 6
        )
      }
      return try await perform(command: command, on: app)
    #else
      _ = plannedPreview
      return try await execute(command: command, input: input)
    #endif
  }

  #if os(macOS)
    private func exactApplication(
      matching object: [String: JSONValue]
    ) throws -> NSRunningApplication {
      guard let bundleID = object.optionalString("bundle_id"),
        let pid = object.optionalInt("pid"), let processIdentifier = Int32(exactly: pid)
      else {
        throw AgentError.invalid("Application control requires bundle_id and a valid pid")
      }
      guard let app = NSRunningApplication(processIdentifier: pid_t(processIdentifier)),
        !app.isTerminated
      else {
        throw AgentError(
          code: "application_not_found",
          message: "Application process is not running",
          exitCode: 6
        )
      }
      guard app.bundleIdentifier == bundleID else {
        throw AgentError(
          code: "application_identity_changed",
          message: "The running process does not match the requested bundle_id",
          details: [
            "requested_bundle_id": .string(bundleID),
            "current_bundle_id": app.bundleIdentifier.map(JSONValue.string) ?? .null,
            "pid": .integer(Int64(app.processIdentifier)),
          ],
          exitCode: 6
        )
      }
      guard let processStartTimeValue = object["process_start_time"] else {
        throw AgentError.invalid("Copy process_start_time from the same app.list row")
      }
      let requestedProcessStartTime = try MacProcessStartTime.parse(processStartTimeValue)
      guard let launchDateValue = object["launch_date"] else {
        throw AgentError.invalid("Copy launch_date from the same app.list row, including null")
      }
      let requestedLaunchDate: String?
      switch launchDateValue {
      case .null: requestedLaunchDate = nil
      case .string(let value): requestedLaunchDate = value
      default: throw AgentError.invalid("launch_date must be a string or null")
      }
      guard requestedProcessStartTime != nil || requestedLaunchDate != nil else {
        throw AgentError(
          code: "application_identity_unavailable",
          message: "The app.list row has no process start identity; refusing app control",
          details: ["pid": .integer(Int64(app.processIdentifier))],
          exitCode: 6)
      }
      let currentProcessStartTime = MacProcessStartTime.current(for: app.processIdentifier)
      guard requestedProcessStartTime == currentProcessStartTime else {
        throw AgentError(
          code: "application_identity_changed",
          message: "The running process does not match the requested process_start_time",
          details: [
            "requested_process_start_time": requestedProcessStartTime?.json ?? .null,
            "current_process_start_time": currentProcessStartTime?.json ?? .null,
            "pid": .integer(Int64(app.processIdentifier)),
          ],
          exitCode: 6
        )
      }
      let currentLaunchDate = app.launchDate.map {
        ISO8601DateFormatter.agentString(from: $0)
      }
      guard requestedLaunchDate == currentLaunchDate else {
        throw AgentError(
          code: "application_identity_changed",
          message: "The running process does not match the requested launch_date",
          details: [
            "requested_launch_date": requestedLaunchDate.map(JSONValue.string) ?? .null,
            "current_launch_date": currentLaunchDate.map(JSONValue.string) ?? .null,
            "pid": .integer(Int64(app.processIdentifier)),
          ],
          exitCode: 6
        )
      }
      return app
    }

    private func identity(for app: NSRunningApplication) -> RunningApplicationIdentity {
      RunningApplicationIdentity(
        processIdentifier: Int64(app.processIdentifier),
        bundleIdentifier: app.bundleIdentifier,
        bundlePath: app.bundleURL?.standardizedFileURL.path,
        launchDate: app.launchDate.map { ISO8601DateFormatter.agentString(from: $0) },
        processStartTime: MacProcessStartTime.current(for: app.processIdentifier)
      )
    }

    private func perform(
      command: CommandSpec,
      on app: NSRunningApplication
    ) async throws -> JSONValue {
      if command.id == "app.activate" {
        try await activate(app)
        return .object(["activated": .bool(true), "pid": .integer(Int64(app.processIdentifier))])
      }
      guard command.id == "app.quit" else {
        throw AgentError(
          code: "unsupported_app_command", message: "App service does not support the command",
          exitCode: 5)
      }
      guard app.terminate() else {
        throw AgentError(
          code: "application_quit_failed", message: "Could not request application termination",
          exitCode: 5, outcomeUncertain: true)
      }
      return .object([
        "quit_requested": .bool(true), "pid": .integer(Int64(app.processIdentifier)),
      ])
    }

    private func runOpen(_ arguments: [String], command: String) async throws {
      let result = try await processRunner.run(
        ProcessRequest(executable: "/usr/bin/open", arguments: arguments, timeout: 30))
      guard result.exitCode == 0, !result.timedOut, !result.outputLimitExceeded else {
        throw AgentError(
          code: "application_launch_failed", message: "open failed to launch the application",
          details: ["stderr": .string(result.stderrString ?? ""), "command": .string(command)],
          exitCode: 5, outcomeUncertain: true)
      }
    }

    private func activate(_ app: NSRunningApplication) async throws {
      guard let bundleURL = app.bundleURL else {
        throw AgentError(
          code: "application_activate_failed", message: "Running application has no bundle URL",
          exitCode: 5)
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      configuration.addsToRecentItems = false
      configuration.promptsUserIfNeeded = false
      let _: NSRunningApplication = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<NSRunningApplication, any Error>) in
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) {
          runningApplication, error in
          guard error == nil, let runningApplication else {
            continuation.resume(
              throwing: AgentError(
                code: "application_activate_failed", message: "Could not activate application",
                exitCode: 5, outcomeUncertain: true))
            return
          }
          continuation.resume(returning: runningApplication)
        }
      }
    }
  #endif
}
