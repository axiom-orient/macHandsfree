import Foundation
import MacHandsfreeCore

#if os(macOS)
  import AppKit
  import ApplicationServices
#endif

protocol FaceTimeCallConfirming: Sendable {
  func confirm(handle: String) async throws
}

protocol FaceTimeCallEnding: Sendable {
  func endActiveCall() async throws
}

enum FaceTimeConfirmationOutcomePolicy {
  static func afterSuccessfulPress(_ error: any Error) -> AgentError {
    if let agentError = error as? AgentError, agentError.outcomeUncertain {
      return agentError
    }
    var details: [String: JSONValue] = [:]
    if let agentError = error as? AgentError {
      details["observation_error_code"] = .string(agentError.code)
    } else {
      details["observation_error_type"] = .string(String(reflecting: type(of: error)))
    }
    return AgentError(
      code: "facetime_confirmation_uncertain",
      message: "The FaceTime button was pressed, but the resulting UI state could not be verified",
      details: details,
      exitCode: 6,
      outcomeUncertain: true
    )
  }
}

struct FaceTimeAccessibilityAdapter: FaceTimeCallConfirming, FaceTimeCallEnding {
  private static let confirmationTimeout: TimeInterval = 5
  private static let confirmationPollInterval: TimeInterval = 0.1
  private static let rejectionObservationTimeout: TimeInterval = 1
  private let permissions: any PermissionAuthorizing

  init(permissions: any PermissionAuthorizing = MacOSPermissionAdapter()) {
    self.permissions = permissions
  }

  func confirm(handle: String) async throws {
    #if os(macOS)
      let deadline = ProcessInfo.processInfo.systemUptime + Self.confirmationTimeout
      while true {
        let captured = try await captureFaceTime(until: deadline)
        let state = FaceTimeCallStateClassifier.classify(nodes: captured.snapshots, handle: handle)
        switch state {
        case .ready(let buttonIndex):
          let result = AccessibilityElementAccess.performAction(
            captured.elements[buttonIndex], kAXPressAction as String)
          guard result.error == .success else {
            let uncertain = result.requestDispatched
            let code = uncertain
              ? "facetime_confirmation_uncertain" : "accessibility_timeout_configuration_failed"
            let message = uncertain
              ? "FaceTime did not confirm the call button press"
              : "The FaceTime button press was not sent because its timeout could not be set"
            throw AgentError(
              code: code,
              message: message,
              details: ["error": .string(String(describing: result.error))],
              exitCode: 5,
              outcomeUncertain: uncertain
            )
          }
          do {
            try await rejectImmediateFaceTimeErrorIfPresent()
          } catch {
            throw FaceTimeConfirmationOutcomePolicy.afterSuccessfulPress(error)
          }
          return
        case .recipientUnavailable, .uiUnrecognized:
          guard ProcessInfo.processInfo.systemUptime < deadline else {
            try Self.throwConfirmationFailure(state: state)
          }
          try await Task.sleep(nanoseconds: 100_000_000)
        default:
          try Self.throwConfirmationFailure(state: state)
        }
      }
    #else
      _ = handle
      throw AgentError.unsupported("calls.video.confirm")
    #endif
  }

  func endActiveCall() async throws {
    #if os(macOS)
      let captured = try await captureFaceTime(
        until: ProcessInfo.processInfo.systemUptime + Self.confirmationTimeout)
      switch FaceTimeCallEndStateClassifier.classify(nodes: captured.snapshots) {
      case .ready(let buttonIndex):
        let result = AccessibilityElementAccess.performAction(
          captured.elements[buttonIndex], kAXPressAction as String)
        guard result.error == .success else {
          let uncertain = result.requestDispatched
          let code = uncertain
            ? "facetime_call_end_uncertain" : "accessibility_timeout_configuration_failed"
          let message = uncertain
            ? "FaceTime did not confirm the end-call button press"
            : "The FaceTime end-call press was not sent because its timeout could not be set"
          throw AgentError(
            code: code,
            message: message,
            details: ["error": .string(String(describing: result.error))],
            exitCode: 5,
            outcomeUncertain: uncertain
          )
        }
      case .noActiveCall:
        throw AgentError(
          code: "no_active_video_call", message: "FaceTime has no active call to end", exitCode: 6)
      case .unavailable:
        throw AgentError(
          code: "facetime_call_end_unavailable",
          message: "FaceTime's active-call end button is not safely available", exitCode: 6)
      }
    #else
      throw AgentError.unsupported("calls.video.end")
    #endif
  }

  #if os(macOS)
    private func requireAccessibility() async throws {
      guard (await permissions.status(for: .accessibility)).isGranted else {
        throw AgentError(
          code: "accessibility_permission_required",
          message: "mac-handsfree needs Accessibility permission to control FaceTime UI",
          exitCode: 3
        )
      }
    }

    private static func throwConfirmationFailure(state: FaceTimeCallState) throws -> Never {
      switch state {
      case .ready:
        throw AgentError(
          code: "facetime_ui_unrecognized",
          message: "FaceTime confirmation UI changed before the call button could be pressed",
          exitCode: 6)
      case .callAlreadyActive:
        throw AgentError(
          code: "call_already_active", message: "A FaceTime call to this handle is already active",
          exitCode: 6)
      case .activeCallRecipientUnverified:
        throw AgentError(
          code: "active_call_in_progress",
          message: "A FaceTime call is active and its recipient cannot be verified safely",
          exitCode: 6)
      case .recipientMismatch:
        throw AgentError(
          code: "facetime_recipient_mismatch",
          message: "FaceTime does not visibly show the requested recipient", exitCode: 6)
      case .recipientUnavailable:
        throw AgentError(
          code: "facetime_recipient_unavailable",
          message: "FaceTime has no enabled call button for the requested recipient", exitCode: 6)
      case .uiUnrecognized:
        throw AgentError(
          code: "facetime_ui_timeout",
          message: "FaceTime did not reach a recognized confirmation state before the timeout",
          exitCode: 6)
      }
    }

    private func rejectImmediateFaceTimeErrorIfPresent() async throws {
      let deadline = ProcessInfo.processInfo.systemUptime + Self.rejectionObservationTimeout
      repeat {
        let captured = try await captureFaceTime(until: deadline)
        if FaceTimeCallConfirmationRejectionClassifier.isRejected(nodes: captured.snapshots) {
          throw AgentError(
            code: "facetime_confirmation_rejected",
            message: "FaceTime displayed an error after the call button was pressed",
            exitCode: 6,
            outcomeUncertain: true)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      } while ProcessInfo.processInfo.systemUptime < deadline
    }

    private func captureFaceTime(until deadline: TimeInterval) async throws -> (
      snapshots: [FaceTimeAXSnapshot], elements: [AXUIElement]
    ) {
      try await requireAccessibility()
      let applications = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.FaceTime")
      guard applications.count == 1, let application = applications.first else {
        throw AgentError(
          code: applications.isEmpty ? "facetime_not_running" : "facetime_process_changed",
          message: applications.isEmpty
            ? "FaceTime is not running" : "More than one FaceTime process is running",
          exitCode: 6
        )
      }
      return try Self.capture(
        AXUIElementCreateApplication(application.processIdentifier), until: deadline)
    }

    private static func capture(_ root: AXUIElement, until deadline: TimeInterval) throws -> (
      snapshots: [FaceTimeAXSnapshot], elements: [AXUIElement]
    ) {
      var snapshots: [FaceTimeAXSnapshot] = []
      var elements: [AXUIElement] = []
      var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
      while !queue.isEmpty, snapshots.count < 128 {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
          throw AgentError(
            code: "facetime_ui_timeout",
            message: "FaceTime accessibility capture exceeded its observation deadline",
            exitCode: 6)
        }
        let current = queue.removeFirst()
        guard let attributes = AccessibilityElementAccess.multipleAttributeValues(
          current.element,
          names: [
            kAXIdentifierAttribute as String, kAXRoleAttribute as String,
            kAXTitleAttribute as String, kAXDescriptionAttribute as String,
            kAXValueAttribute as String, kAXEnabledAttribute as String,
          ], timeout: 0.2),
          attributes.count == 6
        else {
          throw AgentError(
            code: "facetime_accessibility_read_failed",
            message: "FaceTime accessibility attributes could not be read safely",
            exitCode: 6)
        }
        snapshots.append(
          FaceTimeAXSnapshot(
            identifier: attributes[0] as? String,
            role: attributes[1] as? String,
            title: attributes[2] as? String,
            description: attributes[3] as? String,
            value: attributes[4] as? String,
            enabled: attributes[5] as? Bool
          ))
        elements.append(current.element)
        if current.depth < 8 {
          guard let children = AccessibilityElementAccess.childElements(
            current.element, attributeName: kAXChildrenAttribute as String,
            maximum: 128, timeout: 0.2)
          else {
            throw AgentError(
              code: "facetime_accessibility_read_failed",
              message: "FaceTime accessibility children could not be read safely",
              exitCode: 6)
          }
          let remaining = max(0, 128 - snapshots.count - queue.count)
          queue.append(contentsOf: children.elements.prefix(remaining).map { ($0, current.depth + 1) })
        }
      }
      return (snapshots, elements)
    }
  #endif
}
