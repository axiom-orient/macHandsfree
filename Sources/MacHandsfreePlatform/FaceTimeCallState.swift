import Foundation

struct FaceTimeAXSnapshot: Sendable, Equatable {
  let identifier: String?
  let role: String?
  let title: String?
  let description: String?
  let value: String?
  let enabled: Bool?

  var strings: [String] {
    [identifier, role, title, description, value].compactMap { $0 }
  }
}

enum FaceTimeCallState: Equatable {
  case ready(buttonIndex: Int)
  case callAlreadyActive
  case activeCallRecipientUnverified
  case recipientMismatch
  case recipientUnavailable
  case uiUnrecognized
}

enum FaceTimeCallStateClassifier {
  static func classify(nodes: [FaceTimeAXSnapshot], handle: String) -> FaceTimeCallState {
    let targetVisible = isTargetVisible(nodes: nodes, handle: handle)
    if nodes.contains(where: { $0.identifier == "leaveButton" }) {
      return targetVisible ? .callAlreadyActive : .activeCallRecipientUnverified
    }
    let callButtons = nodes.enumerated().filter {
      $0.element.identifier == "joinButton" && $0.element.role == "AXButton"
        && $0.element.enabled != false
    }
    guard callButtons.count == 1 else {
      return nodes.contains(where: { $0.identifier == "joinButton" })
        ? .recipientUnavailable : .uiUnrecognized
    }
    guard targetVisible else { return .recipientMismatch }
    return .ready(buttonIndex: callButtons[0].offset)
  }

  private static func isTargetVisible(nodes: [FaceTimeAXSnapshot], handle: String) -> Bool {
    let visibleStrings = nodes.flatMap(\.strings)
    guard !visibleStrings.contains(handle), handle.hasPrefix("+") else {
      return visibleStrings.contains(handle)
    }
    let expectedDigits = phoneDigits(handle)
    return !expectedDigits.isEmpty
      && visibleStrings.contains {
        phoneDigits($0) == expectedDigits
      }
  }

  private static func phoneDigits(_ value: String) -> String {
    value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(String.init)
      .joined()
  }
}

enum FaceTimeCallConfirmationRejectionClassifier {
  static func isRejected(nodes: [FaceTimeAXSnapshot]) -> Bool {
    nodes.contains { ["AXAlert", "AXDialog", "AXSheet"].contains($0.role ?? "") }
  }
}

enum FaceTimeCallEndState: Equatable {
  case ready(buttonIndex: Int)
  case noActiveCall
  case unavailable
}

enum FaceTimeCallEndStateClassifier {
  static func classify(nodes: [FaceTimeAXSnapshot]) -> FaceTimeCallEndState {
    let leaveButtons = nodes.enumerated().filter {
      $0.element.identifier == "leaveButton" && $0.element.role == "AXButton"
        && $0.element.enabled != false
    }
    if leaveButtons.count == 1 { return .ready(buttonIndex: leaveButtons[0].offset) }
    return nodes.contains(where: { $0.identifier == "leaveButton" }) ? .unavailable : .noActiveCall
  }
}
