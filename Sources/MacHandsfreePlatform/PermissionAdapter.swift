import Foundation

#if os(macOS)
  import ApplicationServices
  import Contacts
  import EventKit
#endif

/// The protected macOS capabilities that mac-handsfree can inspect or request.
///
/// This intentionally models only permissions that have a native, promptable API.
/// Automation and Full Disk Access remain effect-time or settings-only boundaries.
package enum PermissionCapability: String, Sendable, Hashable {
  case calendar
  case reminders
  case contacts
  case accessibility
}

/// A capability's effective authorization, normalized across Apple frameworks.
package enum PermissionAuthorization: Sendable, Equatable {
  case granted
  case notDetermined
  case denied
  case restricted
  case limited
  case unsupportedHost
  case unknown

  package var isGranted: Bool { self == .granted }

  var doctorStatus: String {
    switch self {
    case .granted: return "pass"
    case .notDetermined: return "permission-required"
    case .denied, .restricted: return "permission-denied"
    case .limited: return "limited"
    case .unsupportedHost: return "unsupported-host"
    case .unknown: return "unknown"
    }
  }
}

/// Boundary for querying and explicitly requesting system privacy permissions.
///
/// Callers keep policy local: they decide which capability is necessary for their
/// command and how to report denial. The adapter owns framework status conversion,
/// request APIs, and the framework stores used solely to display a system prompt.
package protocol PermissionAuthorizing: Sendable {
  func status(for capability: PermissionCapability) async -> PermissionAuthorization
  func requestAccessIfNeeded(for capability: PermissionCapability) async throws
    -> PermissionAuthorization
  func requestAccessibilityPrompt() async -> PermissionAuthorization
}

/// Native macOS permission adapter. Its stores are lazy so discovery, schema
/// validation, and diagnostics do not start an EventKit or Contacts effect.
package actor MacOSPermissionAdapter: PermissionAuthorizing {
  #if os(macOS)
    private lazy var eventStore = EKEventStore()
    private lazy var contactsStore = CNContactStore()
  #endif

  package init() {}

  package func status(for capability: PermissionCapability) async -> PermissionAuthorization {
    #if os(macOS)
      switch capability {
      case .calendar:
        return eventKitStatus(for: .event)
      case .reminders:
        return eventKitStatus(for: .reminder)
      case .contacts:
        return contactsStatus()
      case .accessibility:
        return AXIsProcessTrusted() ? .granted : .notDetermined
      }
    #else
      _ = capability
      return .unsupportedHost
    #endif
  }

  package func requestAccessIfNeeded(for capability: PermissionCapability) async throws
    -> PermissionAuthorization
  {
    let current = await status(for: capability)
    // Calendar read commands cannot use EventKit's write-only authorization.
    // A user who previously granted write-only access must be able to request full access.
    let needsRequest =
      current == .notDetermined || (capability == .calendar && current == .limited)
    guard needsRequest else { return current }

    #if os(macOS)
      switch capability {
      case .calendar:
        _ = try await eventStore.requestFullAccessToEvents()
      case .reminders:
        _ = try await eventStore.requestFullAccessToReminders()
      case .contacts:
        _ = try await requestContactsAccess()
      case .accessibility:
        return await requestAccessibilityPrompt()
      }
      return await status(for: capability)
    #else
      return .unsupportedHost
    #endif
  }

  package func requestAccessibilityPrompt() async -> PermissionAuthorization {
    #if os(macOS)
      let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
      return await status(for: .accessibility)
    #else
      return .unsupportedHost
    #endif
  }

  #if os(macOS)
    private func eventKitStatus(for entityType: EKEntityType) -> PermissionAuthorization {
      switch EKEventStore.authorizationStatus(for: entityType) {
      case .fullAccess: return .granted
      case .writeOnly: return .limited
      case .notDetermined: return .notDetermined
      case .denied: return .denied
      case .restricted: return .restricted
      @unknown default: return .unknown
      }
    }

    private func contactsStatus() -> PermissionAuthorization {
      switch CNContactStore.authorizationStatus(for: .contacts) {
      case .authorized: return .granted
      case .notDetermined: return .notDetermined
      case .denied: return .denied
      case .restricted: return .restricted
      @unknown default: return .unknown
      }
    }

    private func requestContactsAccess() async throws -> Bool {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Bool, any Error>) in
        contactsStore.requestAccess(for: .contacts) { granted, error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: granted)
          }
        }
      }
    }
  #endif
}
