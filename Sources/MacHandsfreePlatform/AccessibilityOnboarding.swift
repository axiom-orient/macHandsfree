import Foundation
import MacHandsfreeCore

/// Settings links never change a privacy switch. CLI commands open them only
/// after plan → execute; the setup window opens them on a direct user click.
enum PrivacyOnboardingArea: String {
  case accessibility
  case calendar
  case contacts
  case fullDiskAccess = "full_disk_access"
  case reminders

  var settingsURL: String {
    switch self {
    case .accessibility:
      return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case .calendar:
      return "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    case .contacts:
      return "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
    case .fullDiskAccess:
      return "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    case .reminders:
      return "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
    }
  }

  var instruction: String {
    switch self {
    case .accessibility:
      return "Enable the effective execution host in Accessibility, then run doctor."
    case .calendar: return "Grant full Calendar access, then retry the Calendar command."
    case .contacts: return "Grant Contacts Access, then retry the Contacts command."
    case .fullDiskAccess:
      return "Grant Full Disk Access, then retry a Messages history or local Mail index read command."
    case .reminders: return "Grant Reminders access, then retry the Reminders command."
    }
  }
}

struct OnboardingService: CommandService {
  let name = "onboarding"
  private let processRunner: any ProcessRunning

  init(processRunner: any ProcessRunning) { self.processRunner = processRunner }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    let area = try privacyArea(command: command, input: input)
    return effects([
      effect(
        command.id == "onboarding.accessibility.open"
          ? "open_accessibility_settings" : "open_privacy_settings", "System Settings",
        details: ["area": .string(area.rawValue), "url": .string(area.settingsURL)])
    ])
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    let area = try privacyArea(command: command, input: input)
    let result = try await processRunner.run(
      ProcessRequest(
        executable: "/usr/bin/open", arguments: [area.settingsURL], timeout: 30)
    )
    guard result.exitCode == 0, !result.timedOut, !result.outputLimitExceeded else {
      throw AgentError(
        code: "accessibility_settings_open_failed",
        message: "Could not open the requested macOS privacy settings page",
        details: ["stderr": .string(result.stderrString ?? "")],
        exitCode: 5,
        outcomeUncertain: true)
    }
    return .object([
      "settings_opened": .bool(true),
      "area": .string(area.rawValue),
      "settings_url": .string(area.settingsURL),
      "next_step": .string(area.instruction),
    ])
  }

  private func privacyArea(command: CommandSpec, input: JSONValue) throws -> PrivacyOnboardingArea {
    switch command.id {
    case "onboarding.accessibility.open": return .accessibility
    case "onboarding.privacy.open":
      let value = try input.requiredObject().requiredString("area")
      guard let area = PrivacyOnboardingArea(rawValue: value) else {
        throw AgentError.invalid("Unsupported privacy settings area")
      }
      return area
    default:
      throw AgentError(
        code: "unsupported_onboarding_command",
        message: "Onboarding service does not support command",
        exitCode: 5)
    }
  }
}
