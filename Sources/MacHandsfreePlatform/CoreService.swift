import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct CoreService: CommandService {
  let name = "core"
  private let registry: CommandRegistry
  private let stateDirectoryURL: URL
  private let mcpProtocols: [String]
  private let permissions: any PermissionAuthorizing

  init(
    registry: CommandRegistry,
    stateDirectoryURL: URL,
    mcpProtocols: [String],
    permissions: any PermissionAuthorizing = MacOSPermissionAdapter()
  ) {
    self.registry = registry
    self.stateDirectoryURL = stateDirectoryURL
    self.mcpProtocols = mcpProtocols
    self.permissions = permissions
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    throw AgentError(
      code: "preview_not_supported", message: "Core commands are read-only", exitCode: 5)
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    switch command.id {
    case "version":
      return .object([
        "name": .string(ProductInfo.name),
        "version": .string(ProductInfo.version),
        "command_schema_version": .integer(Int64(ProductInfo.commandSchemaVersion)),
        "response_schema_version": .integer(Int64(ProductInfo.responseSchemaVersion)),
        "mcp_protocols": .array(mcpProtocols.map(JSONValue.string)),
      ])
    case "commands.list":
      let domain = try input.requiredObject().optionalString("domain")
      let values = registry.commands.filter {
        domain == nil || $0.id.split(separator: ".").first.map(String.init) == domain
      }
      return .object([
        "command_count": .integer(Int64(values.count)),
        "commands": .array(values.map(\.json)),
      ])
    case "commands.describe":
      let id = try input.requiredObject().requiredString("id")
      guard let spec = registry.command(id: id) else {
        throw AgentError(
          code: "command_not_found", message: "No canonical command has this identifier",
          details: ["id": .string(id)], exitCode: 2)
      }
      return spec.json
    case "doctor":
      return await doctor()
    default:
      throw AgentError(
        code: "unsupported_core_command", message: "Core service does not support the command",
        exitCode: 5)
    }
  }

  private func doctor() async -> JSONValue {
    let requiredBinaries = [
      "/usr/bin/osascript", "/usr/bin/open", "/usr/bin/shortcuts", "/usr/bin/mdfind",
      "/usr/bin/mdls",
    ]
    let checks = requiredBinaries.map { path -> JSONValue in
      .object([
        "name": .string("binary:\(path)"),
        "status": .string(
          FileManager.default.isExecutableFile(atPath: path) ? "pass" : "unavailable"),
      ])
    }
    let stateInspection = inspectStateDirectory()
    #if os(macOS)
      let platform = "pass"
      let accessibilityStatus = await permissions.status(for: .accessibility)
      let calendarStatus = await permissions.status(for: .calendar)
      let contactsStatus = await permissions.status(for: .contacts)
      let remindersStatus = await permissions.status(for: .reminders)
      let privacyChecks: [JSONValue] = [
        .object([
          "name": .string("calendar:access"),
          "status": .string(calendarStatus.doctorStatus),
          "instruction": .string(
            "Grant full Calendar access before Calendar commands; write-only access cannot read existing events."
          ),
          "settings_url": .string(PrivacyOnboardingArea.calendar.settingsURL),
        ]),
        .object([
          "name": .string("reminders:access"),
          "status": .string(remindersStatus.doctorStatus),
          "instruction": .string("Grant Reminders access before Reminders commands."),
          "settings_url": .string(PrivacyOnboardingArea.reminders.settingsURL),
        ]),
        .object([
          "name": .string("accessibility:ui-control"),
          "status": .string(accessibilityStatus.doctorStatus),
          "instruction": .string(
            "Grant Accessibility permission before accessibility.* commands or FaceTime confirmation/end can inspect or control application UI."
          ),
          "settings_url": .string(PrivacyOnboardingArea.accessibility.settingsURL),
        ]),
        .object([
          "name": .string("contacts:access"),
          "status": .string(contactsStatus.doctorStatus),
          "instruction": .string(
            "Grant Contacts Access before Contacts commands can read or change data."),
          "settings_url": .string(PrivacyOnboardingArea.contacts.settingsURL),
        ]),
        .object([
          "name": .string("full-disk-access:messages-read"),
          "status": .string(messagesPrivacyStatus()),
          "instruction": .string(
            "Grant Full Disk Access if Messages read commands cannot access chat.db."),
          "settings_url": .string(PrivacyOnboardingArea.fullDiskAccess.settingsURL),
        ]),
        .object([
          "name": .string("full-disk-access:mail-index-read"),
          "status": .string("not-probed"),
          "instruction": .string(
            "mail.index.* reads the local Mail index and downloaded message files. Access is checked on use; a denial does not fall back to Apple Events."),
          "settings_url": .string(PrivacyOnboardingArea.fullDiskAccess.settingsURL),
        ]),
      ]
    #else
      let platform = "unsupported-host"
      let privacyChecks: [JSONValue] = []
    #endif
    return .object([
      "ready": .bool(
        DoctorReadiness.evaluate(
          platformReady: platform == "pass",
          binaryStatuses: checks.compactMap { $0["status"]?.stringValue },
          stateStatus: stateInspection.status
        )),
      "platform": .string(platform),
      "checks": .array(checks + [stateInspection.value]),
      "privacy_checks": .array(privacyChecks),
      "note": .string(
        "Privacy permissions are enforced by macOS and are verified when each protected command runs."
      ),
    ])
  }

  private func inspectStateDirectory() -> DoctorStateInspection {
    let path = stateDirectoryURL.path
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT {
        return DoctorStateInspection(
          status: .notCreated,
          value: .object([
            "name": .string("state-directory"),
            "status": .string(DoctorStateStatus.notCreated.rawValue),
            "path": .string(path),
          ])
        )
      }
      return DoctorStateInspection(
        status: .invalid,
        value: .object([
          "name": .string("state-directory"),
          "status": .string(DoctorStateStatus.invalid.rawValue),
          "path": .string(path),
          "reason": .string("inspection-failed"),
          "errno": .integer(Int64(errno)),
        ])
      )
    }

    let type = info.st_mode & mode_t(S_IFMT)
    let isDirectory = type == mode_t(S_IFDIR)
    let isCurrentUserOwned = info.st_uid == getuid()
    let status: DoctorStateStatus = isDirectory && isCurrentUserOwned ? .present : .invalid
    var value: [String: JSONValue] = [
      "name": .string("state-directory"),
      "status": .string(status.rawValue),
      "path": .string(path),
    ]
    if !isDirectory {
      value["reason"] = .string(
        type == mode_t(S_IFLNK) ? "symbolic-link-not-allowed" : "not-a-directory")
    } else if !isCurrentUserOwned {
      value["reason"] = .string("wrong-owner")
      value["owner"] = .integer(Int64(info.st_uid))
    }
    return DoctorStateInspection(status: status, value: .object(value))
  }

  #if os(macOS)
    private func messagesPrivacyStatus() -> String {
      let database = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")
      guard FileManager.default.fileExists(atPath: database.path) else {
        return "not-configured"
      }
      return FileManager.default.isReadableFile(atPath: database.path)
        ? "pass" : "permission-required"
    }
  #endif
}

enum DoctorStateStatus: String, Sendable {
  case present
  case notCreated = "not-created"
  case invalid
}

struct DoctorStateInspection: Sendable {
  let status: DoctorStateStatus
  let value: JSONValue
}

enum DoctorReadiness {
  static func evaluate(
    platformReady: Bool,
    binaryStatuses: [String],
    stateStatus: DoctorStateStatus
  ) -> Bool {
    platformReady
      && binaryStatuses.allSatisfy { $0 == "pass" }
      && stateStatus != .invalid
  }
}
