import Foundation
import MacHandsfreeCore

#if os(macOS)
  import AppKit
  import ApplicationServices
#endif

struct AccessibilityService: CurrentStateValidatedCommandService {
  let name = "accessibility"
  private let permissions: any PermissionAuthorizing
  #if os(macOS)
  private let operations = AccessibilityOperations()
  #endif

  init(permissions: any PermissionAuthorizing = MacOSPermissionAdapter()) {
    self.permissions = permissions
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      guard command.kind == .mutation else {
        throw AgentError(
          code: "preview_not_supported", message: "Accessibility reads do not prepare mutations",
          exitCode: 5)
      }
      try await requestAccessibilityIfNeeded()
      let request = try AccessibilityActionRequest(command: command, input: input)
      let target = try await operations.targetSnapshot(for: request)
      let targetTitle = target["element"]?["title"]?.stringValue
        ?? target["window"]?["title"]?.stringValue
        ?? request.target.bundleID
      let operation = request.action == .press ? "press_accessibility_element" : "set_accessibility_value"
      var preview = try effects([
        effect(
          operation, targetTitle,
          details: [
            "target": target,
            "value": request.value.map(JSONValue.string) ?? .null,
          ])
      ]).requiredObject()
      preview["guard_version"] = .integer(1)
      preview["target_snapshot"] = target
      return .object(preview)
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      guard command.kind == .read else {
        throw AgentError(
          code: "mutation_requires_plan",
          message: "Accessibility actions must use plan and execute",
          exitCode: 5)
      }
      try await requestAccessibilityIfNeeded()
      let object = try input.requiredObject()
      let target = try AccessibilityApplicationTarget(object: object)
      switch command.id {
      case "accessibility.windows.list":
        return try await operations.listWindows(target)
      case "accessibility.tree.read":
        let request = try AccessibilityTreeRequest(object: object)
        return try await operations.readTree(request)
      default:
        throw AgentError.unsupported(command.id)
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
      guard command.id == "accessibility.elements.press"
        || command.id == "accessibility.elements.set_value"
      else {
        return try await execute(command: command, input: input)
      }
      guard plannedPreview["guard_version"]?.intValue == 1,
        let expectedTarget = plannedPreview["target_snapshot"]
      else {
        throw AgentError(
          code: "plan_state_changed",
          message: "The Accessibility plan does not include a current target guard",
          details: ["reason_code": .string("plan_guard_missing")],
          exitCode: 6)
      }
      guard (await permissions.status(for: .accessibility)).isGranted else {
        throw Self.accessibilityPermissionRequired()
      }
      let request = try AccessibilityActionRequest(command: command, input: input)
      return try await operations.apply(request, expectedTarget: expectedTarget)
    #else
      _ = plannedPreview
      return try await execute(command: command, input: input)
    #endif
  }

  private func requestAccessibilityIfNeeded() async throws {
    let status = try await permissions.requestAccessIfNeeded(for: .accessibility)
    guard status.isGranted else {
      #if os(macOS)
        throw Self.accessibilityPermissionRequired()
      #else
        throw AgentError.unsupported("accessibility")
      #endif
    }
  }

  #if os(macOS)
    private static func accessibilityPermissionRequired() -> AgentError {
      AgentError(
        code: "accessibility_permission_required",
        message: "Grant Accessibility permission before reading or controlling application UI",
        details: ["settings_url": .string(PrivacyOnboardingArea.accessibility.settingsURL)],
        exitCode: 3)
    }
  #endif
}

#if os(macOS)
struct AccessibilityChildrenRead {
  let elements: [AXUIElement]
  let truncated: Bool
}

struct AccessibilityDispatchResult {
  let requestDispatched: Bool
  let error: AXError
}

/// One bounded native mechanism boundary shared by FaceTime and generic app UI.
enum AccessibilityElementAccess {
  static let defaultMessagingTimeout: Float = 3

  static func setMessagingTimeout(
    _ element: AXUIElement, seconds: Float = defaultMessagingTimeout
  ) -> AXError {
    AXUIElementSetMessagingTimeout(element, seconds)
  }

  static func stringAttribute(
    _ element: AXUIElement, _ name: String, timeout: Float = defaultMessagingTimeout
  ) -> String? {
    guard setMessagingTimeout(element, seconds: timeout) == .success else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  static func childElements(
    _ element: AXUIElement, attributeName: String, maximum: Int,
    timeout: Float = defaultMessagingTimeout
  ) -> AccessibilityChildrenRead? {
    guard maximum > 0, setMessagingTimeout(element, seconds: timeout) == .success else { return nil }
    var total = CFIndex(0)
    let countResult = AXUIElementGetAttributeValueCount(
      element, attributeName as CFString, &total)
    if countResult == .noValue { return AccessibilityChildrenRead(elements: [], truncated: false) }
    guard countResult == .success, total >= 0 else { return nil }
    let count = min(total, CFIndex(maximum))
    guard count > 0 else { return AccessibilityChildrenRead(elements: [], truncated: false) }
    var values: CFArray?
    guard AXUIElementCopyAttributeValues(
      element, attributeName as CFString, 0, count, &values) == .success,
      let children = values as? [AXUIElement]
    else { return nil }
    return AccessibilityChildrenRead(
      elements: children,
      truncated: total > count || CFIndex(children.count) != count)
  }

  static func multipleAttributeValues(
    _ element: AXUIElement, names: [String], timeout: Float = defaultMessagingTimeout
  ) -> [Any]? {
    guard !names.isEmpty, setMessagingTimeout(element, seconds: timeout) == .success else { return nil }
    var values: CFArray?
    let attributes = names.map { $0 as CFString } as CFArray
    guard AXUIElementCopyMultipleAttributeValues(
      element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
      let result = values as? [Any], result.count == names.count
    else { return nil }
    return result
  }

  static func isAttributeSettable(
    _ element: AXUIElement, name: String, timeout: Float = defaultMessagingTimeout
  ) -> Bool {
    guard setMessagingTimeout(element, seconds: timeout) == .success else { return false }
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
      && settable.boolValue
  }

  static func actionNames(
    _ element: AXUIElement, timeout: Float = defaultMessagingTimeout
  ) -> [String]? {
    guard setMessagingTimeout(element, seconds: timeout) == .success else { return nil }
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return nil }
    return names as? [String]
  }

  static func performAction(
    _ element: AXUIElement, _ name: String, timeout: Float = defaultMessagingTimeout
  ) -> AccessibilityDispatchResult {
    let timeoutResult = setMessagingTimeout(element, seconds: timeout)
    guard timeoutResult == .success else {
      return AccessibilityDispatchResult(requestDispatched: false, error: timeoutResult)
    }
    return AccessibilityDispatchResult(
      requestDispatched: true,
      error: AXUIElementPerformAction(element, name as CFString))
  }

  static func setStringValue(
    _ element: AXUIElement, _ name: String, value: String,
    timeout: Float = defaultMessagingTimeout
  ) -> AccessibilityDispatchResult {
    let timeoutResult = setMessagingTimeout(element, seconds: timeout)
    guard timeoutResult == .success else {
      return AccessibilityDispatchResult(requestDispatched: false, error: timeoutResult)
    }
    return AccessibilityDispatchResult(
      requestDispatched: true,
      error: AXUIElementSetAttributeValue(element, name as CFString, value as CFString))
  }
}

private struct AccessibilityTargetObservation {
  let snapshot: JSONValue
  let element: AXUIElement
}

private actor AccessibilityOperations {
  private static let axMessageTimeout: Float = 0.2
  private static let maximumWindows = 64
  private static let maximumElements = 256
  private static let maximumElementBytes = 4 * 1_024
  private static let maximumTreeBytes = 2 * 1_024 * 1_024
  private static let treeDeadlineSeconds: TimeInterval = 8
  private static let windowsDeadlineSeconds: TimeInterval = 5
  private static let textInputRoles: Set<String> = [
    "AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox",
  ]

  func listWindows(_ target: AccessibilityApplicationTarget) throws -> JSONValue {
    let deadline = ProcessInfo.processInfo.systemUptime + Self.windowsDeadlineSeconds
    let (application, windows, windowsTruncated) = try applicationWindows(target)
    var output: [JSONValue] = []
    var timeLimitReached = false
    for (index, window) in windows.prefix(Self.maximumWindows).enumerated() {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        timeLimitReached = true
        break
      }
      output.append(try windowSnapshot(window, id: index).json)
    }
    return .object([
      "application": application.json,
      "windows": .array(output),
      "truncated": .bool(windowsTruncated || windows.count > output.count),
      "time_limit_reached": .bool(timeLimitReached),
    ])
  }

  func readTree(_ request: AccessibilityTreeRequest) throws -> JSONValue {
    let deadline = ProcessInfo.processInfo.systemUptime + Self.treeDeadlineSeconds
    let (application, windows, _) = try applicationWindows(request.target)
    guard windows.indices.contains(request.windowID) else {
      throw AgentError(
        code: "accessibility_window_not_found",
        message: "The selected window is no longer present in the application",
        details: ["window_id": .integer(Int64(request.windowID))],
        exitCode: 6)
    }
    let window = windows[request.windowID]
    let selectedWindow = try windowSnapshot(window, id: request.windowID)
    var elements: [JSONValue] = []
    var elementBytes = 0
    var elementLimitReached = false
    var byteLimitReached = false
    var depthLimitReached = false
    var childLimitReached = false
    var timeLimitReached = false
    var unavailableSubtrees = 0

    func append(_ element: AXUIElement, path: [Int], depth: Int) throws {
      if Task.isCancelled { throw CancellationError() }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        timeLimitReached = true
        return
      }
      guard elements.count < request.maxElements else {
        elementLimitReached = true
        return
      }
      let snapshot = try elementSnapshot(
        element, path: path, includeValue: true, includeActions: false,
        valueLimit: Self.maximumElementBytes)
      if !snapshot.attributesAvailable { unavailableSubtrees += 1 }
      let json = snapshot.json
      let encodedSize = try json.encoded().count
      guard elementBytes + encodedSize <= Self.maximumTreeBytes else {
        byteLimitReached = true
        return
      }
      elementBytes += encodedSize
      elements.append(json)
      if depth >= request.maxDepth {
        depthLimitReached = true
        return
      }
      guard let children = AccessibilityElementAccess.childElements(
        element, attributeName: kAXChildrenAttribute as String,
        maximum: Self.maximumElements, timeout: Self.axMessageTimeout)
      else {
        unavailableSubtrees += 1
        return
      }
      childLimitReached = childLimitReached || children.truncated
      for (index, child) in children.elements.enumerated() {
        guard elements.count < request.maxElements else {
          elementLimitReached = true
          break
        }
        if byteLimitReached || timeLimitReached { break }
        try append(child, path: path + [index], depth: depth + 1)
      }
    }

    try append(window, path: [], depth: 0)
    let complete = !elementLimitReached && !byteLimitReached && !depthLimitReached
      && !childLimitReached && !timeLimitReached && unavailableSubtrees == 0
      && selectedWindow.truncatedAttributes.isEmpty
    return .object([
      "application": application.json,
      "window": selectedWindow.json,
      "elements": .array(elements),
      "coverage": .object([
        "complete": .bool(complete),
        "element_limit_reached": .bool(elementLimitReached),
        "byte_limit_reached": .bool(byteLimitReached),
        "depth_limit_reached": .bool(depthLimitReached),
        "child_limit_reached": .bool(childLimitReached),
        "time_limit_reached": .bool(timeLimitReached),
        "unavailable_subtrees": .integer(Int64(unavailableSubtrees)),
        "window_truncated_attributes": .array(selectedWindow.truncatedAttributes.map(JSONValue.string)),
      ]),
    ])
  }

  func targetSnapshot(for request: AccessibilityActionRequest) throws -> JSONValue {
    try targetObservation(for: request).snapshot
  }

  private func targetObservation(
    for request: AccessibilityActionRequest
  ) throws -> AccessibilityTargetObservation {
    let (application, windows, _) = try applicationWindows(request.target)
    guard windows.indices.contains(request.windowID) else {
      throw AgentError(
        code: "accessibility_window_not_found", message: "The selected window is not available",
        details: ["window_id": .integer(Int64(request.windowID))], exitCode: 6)
    }
    let window = windows[request.windowID]
    let element = try resolve(request.path, from: window)
    let state = try elementSnapshot(
      element, path: request.path, includeValue: request.action == .setValue,
      includeActions: request.action == .press,
      valueLimit: 65_536)
    guard state.attributesAvailable else {
      throw AgentError(
        code: "accessibility_target_unavailable",
        message: "The selected element does not expose enough attributes for exact approval",
        exitCode: 6)
    }
    guard state.role != nil else {
      throw AgentError(
        code: "accessibility_target_unidentified",
        message: "The selected element has no readable accessibility role",
      exitCode: 6)
    }
    guard state.enabled == true else {
      throw AgentError(
        code: "accessibility_element_disabled",
        message: "The selected accessibility element is not confirmed enabled",
        exitCode: 6)
    }
    if request.action == .setValue, !Self.textInputRoles.contains(state.role ?? "") {
      throw AgentError(
        code: "accessibility_text_role_unsupported",
        message: "set_value is limited to known text-input accessibility roles",
        details: ["role": state.role.map(JSONValue.string) ?? .null],
        exitCode: 6)
    }
    guard state.truncatedAttributes.isEmpty else {
      throw AgentError(
        code: "accessibility_target_unbounded",
        message: "Target attributes exceed the snapshot bound and cannot be approved exactly",
        details: ["truncated_attributes": .array(state.truncatedAttributes.map(JSONValue.string))],
        exitCode: 6)
    }
    guard !state.isSecure else {
      throw AgentError(
        code: "accessibility_secure_element_blocked",
        message: "Secure input elements cannot be read or changed through accessibility commands",
        exitCode: 6)
    }
    if request.action == .press, !state.actions.contains("AXPress") {
      throw AgentError(
        code: "accessibility_action_unavailable",
        message: "The selected element does not expose AXPress",
        details: ["path": .array(request.path.map { .integer(Int64($0)) })],
        exitCode: 6)
    }
    if request.action == .setValue {
      guard state.value != nil else {
        throw AgentError(
          code: "accessibility_value_unavailable",
          message: "The current text value is not available for an exact target snapshot",
          exitCode: 6)
      }
      guard isValueSettable(element)
      else {
        throw AgentError(
          code: "accessibility_value_not_settable",
          message: "The selected element does not allow AXValue changes",
          exitCode: 6)
      }
    }
    let windowState = try windowSnapshot(window, id: request.windowID)
    guard windowState.truncatedAttributes.isEmpty else {
      throw AgentError(
        code: "accessibility_window_unbounded",
        message: "The selected window identity exceeds the snapshot bound",
        details: ["truncated_attributes": .array(windowState.truncatedAttributes.map(JSONValue.string))],
        exitCode: 6)
    }
    return AccessibilityTargetObservation(
      snapshot: .object([
        "application": application.json,
        "window": windowState.json,
        "element": state.json,
      ]),
      element: element)
  }

  func apply(_ request: AccessibilityActionRequest, expectedTarget: JSONValue) throws -> JSONValue {
    let observation = try targetObservation(for: request)
    guard observation.snapshot == expectedTarget else {
      throw AgentError(
        code: "plan_state_changed",
        message: "The selected application, window, or accessibility element changed after approval",
        details: ["planned": expectedTarget, "current": observation.snapshot],
        exitCode: 6)
    }
    let element = observation.element
    switch request.action {
    case .press:
      let result = AccessibilityElementAccess.performAction(
        element, "AXPress", timeout: Self.axMessageTimeout)
      guard result.error == .success else {
        let uncertain = result.requestDispatched
        let code = uncertain ? "accessibility_action_uncertain" : "accessibility_action_not_dispatched"
        let message = uncertain
          ? "The AXPress request returned an error after dispatch began"
          : "The AXPress request was not sent because its timeout could not be set"
        throw AgentError(
          code: code,
          message: message,
          details: ["error": .string(String(describing: result.error))],
          exitCode: 6,
          outcomeUncertain: uncertain)
      }
      let after = try? targetSnapshot(for: request)
      return .object([
        "action_sent": .bool(true),
        "business_effect_verified": .bool(false),
        "post_action_target": after?["element"] ?? .null,
        "target_reobserved": .bool(after != nil),
      ])
    case .setValue:
      guard let value = request.value else {
        throw AgentError.invalid("set_value requires a value")
      }
      let result = AccessibilityElementAccess.setStringValue(
        element, kAXValueAttribute as String, value: value, timeout: Self.axMessageTimeout)
      guard result.error == .success else {
        let uncertain = result.requestDispatched
        let code = uncertain ? "accessibility_value_uncertain" : "accessibility_value_not_dispatched"
        let message = uncertain
          ? "The AXValue setter returned an error after dispatch began"
          : "The AXValue setter was not sent because its timeout could not be set"
        throw AgentError(
          code: code,
          message: message,
          details: ["error": .string(String(describing: result.error))],
          exitCode: 6,
          outcomeUncertain: uncertain)
      }
      let observed = AccessibilityElementAccess.stringAttribute(
        element, kAXValueAttribute as String, timeout: Self.axMessageTimeout)
      guard observed == value else {
        throw AgentError(
          code: "accessibility_value_uncertain",
          message: "The value setter returned, but the requested value was not observed afterward",
          details: ["requested_value_observed": .bool(false)],
          exitCode: 6,
          outcomeUncertain: true)
      }
      return .object([
        "action_sent": .bool(true),
        "requested_value_observed": .bool(observed == value),
        "current_value": observed.map(JSONValue.string) ?? .null,
        "business_effect_verified": .bool(false),
      ])
    }
  }

  private func applicationWindows(
    _ target: AccessibilityApplicationTarget
  ) throws -> (application: ApplicationIdentity, windows: [AXUIElement], truncated: Bool) {
    guard let pid = Int32(exactly: target.processID),
      let application = NSRunningApplication(processIdentifier: pid_t(pid)),
      application.bundleIdentifier == target.bundleID,
      !application.isTerminated
    else {
      throw AgentError(
        code: "accessibility_application_changed",
        message: "The exact application process is no longer running",
        details: ["bundle_id": .string(target.bundleID), "pid": .integer(target.processID)],
        exitCode: 6)
    }
    let currentLaunchDate = application.launchDate.map {
      ISO8601DateFormatter.agentString(from: $0)
    }
    let currentProcessStartTime = MacProcessStartTime.current(for: pid_t(pid))
    guard target.processStartTime == currentProcessStartTime else {
      throw AgentError(
        code: "accessibility_application_changed",
        message: "The running application does not match the requested process_start_time",
        details: [
          "bundle_id": .string(target.bundleID), "pid": .integer(target.processID),
          "requested_process_start_time": target.processStartTime?.json ?? .null,
          "current_process_start_time": currentProcessStartTime?.json ?? .null,
        ],
        exitCode: 6)
    }
    guard target.launchDate == currentLaunchDate else {
      throw AgentError(
        code: "accessibility_application_changed",
        message: "The running application does not match the requested launch_date",
        details: [
          "bundle_id": .string(target.bundleID), "pid": .integer(target.processID),
          "requested_launch_date": target.launchDate.map(JSONValue.string) ?? .null,
          "current_launch_date": currentLaunchDate.map(JSONValue.string) ?? .null,
        ],
        exitCode: 6)
    }
    let identity = ApplicationIdentity(
      bundleID: target.bundleID,
      processID: target.processID,
      bundlePath: application.bundleURL?.standardizedFileURL.path,
      launchDate: currentLaunchDate,
      processStartTime: currentProcessStartTime)
    let root = AXUIElementCreateApplication(pid_t(pid))
      guard let windowRead = AccessibilityElementAccess.childElements(
      root, attributeName: kAXWindowsAttribute as String, maximum: 256,
      timeout: Self.axMessageTimeout)
    else {
      throw AgentError(
        code: "accessibility_windows_unavailable",
        message: "The application does not expose a bounded AXWindows list",
        exitCode: 6)
    }
    return (identity, windowRead.elements, windowRead.truncated)
  }

  private func resolve(_ path: [Int], from window: AXUIElement) throws -> AXUIElement {
    var current = window
    for index in path {
      guard let children = AccessibilityElementAccess.childElements(
        current, attributeName: kAXChildrenAttribute as String, maximum: 256,
        timeout: Self.axMessageTimeout),
        children.elements.indices.contains(index)
      else {
        throw AgentError(
          code: "accessibility_element_not_found",
          message: "The accessibility child path no longer resolves",
          details: ["path": .array(path.map { .integer(Int64($0)) })],
          exitCode: 6)
      }
      current = children.elements[index]
    }
    return current
  }

  private func elementSnapshot(
    _ element: AXUIElement,
    path: [Int],
    includeValue: Bool,
    includeActions: Bool,
    valueLimit: Int
  ) throws -> AccessibilityElementSnapshot {
    let attributeNames = [
      kAXRoleAttribute as String, kAXSubroleAttribute as String,
      kAXIdentifierAttribute as String, kAXTitleAttribute as String,
      kAXDescriptionAttribute as String, kAXEnabledAttribute as String,
    ]
    guard let attributes = AccessibilityElementAccess.multipleAttributeValues(
      element, names: attributeNames, timeout: Self.axMessageTimeout)
    else {
      return AccessibilityElementSnapshot.unavailable(path: path)
    }
    let role = attributes[0] as? String
    let subrole = attributes[1] as? String
    let secure = role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String)
    var value: String?
    var truncatedAttributes: [String] = []
    if includeValue, !secure,
      let rawValue = AccessibilityElementAccess.stringAttribute(
        element, kAXValueAttribute as String, timeout: Self.axMessageTimeout)
    {
      if rawValue.utf8.count <= valueLimit {
        value = rawValue
      } else {
        truncatedAttributes.append("AXValue")
      }
    }
    let actions = includeActions
      ? AccessibilityElementAccess.actionNames(element, timeout: Self.axMessageTimeout)
      : []
    let boundedActions = Array((actions ?? []).prefix(32))
    if actions == nil || (actions?.count ?? 0) > boundedActions.count {
      if includeActions { truncatedAttributes.append("AXActions") }
    }
    return AccessibilityElementSnapshot(
      path: path,
      role: boundedLabel(role, name: "AXRole", truncated: &truncatedAttributes),
      subrole: boundedLabel(subrole, name: "AXSubrole", truncated: &truncatedAttributes),
      identifier: boundedLabel(attributes[2] as? String, name: "AXIdentifier", truncated: &truncatedAttributes),
      title: boundedLabel(attributes[3] as? String, name: "AXTitle", truncated: &truncatedAttributes),
      description: boundedLabel(attributes[4] as? String, name: "AXDescription", truncated: &truncatedAttributes),
      enabled: attributes[5] as? Bool,
      isSecure: secure,
      value: value,
      valueTruncated: truncatedAttributes.contains("AXValue"),
      actions: boundedActions,
      truncatedAttributes: truncatedAttributes,
      attributesAvailable: true)
  }

  private func windowSnapshot(_ window: AXUIElement, id: Int) throws -> AccessibilityWindowSnapshot {
    let names = [
      kAXIdentifierAttribute as String, kAXTitleAttribute as String, kAXRoleAttribute as String,
    ]
    guard let attributes = AccessibilityElementAccess.multipleAttributeValues(
      window, names: names, timeout: Self.axMessageTimeout)
    else {
      throw AgentError(
        code: "accessibility_window_unavailable",
        message: "The selected window attributes cannot be read",
        exitCode: 6)
    }
    var truncated: [String] = []
    return AccessibilityWindowSnapshot(
      id: id,
      identifier: boundedLabel(attributes[0] as? String, name: "AXIdentifier", truncated: &truncated),
      title: boundedLabel(attributes[1] as? String, name: "AXTitle", truncated: &truncated),
      role: boundedLabel(attributes[2] as? String, name: "AXRole", truncated: &truncated),
      truncatedAttributes: truncated)
  }

  private func isValueSettable(_ element: AXUIElement) -> Bool {
    AccessibilityElementAccess.isAttributeSettable(
      element, name: kAXValueAttribute as String, timeout: Self.axMessageTimeout)
  }
}

private func boundedLabel(
  _ value: String?, name: String, truncated: inout [String]
) -> String? {
  guard let value else { return nil }
  guard value.count > 512 else { return value }
  truncated.append(name)
  return String(value.prefix(512))
}

private struct AccessibilityApplicationTarget: Sendable {
  let bundleID: String
  let processID: Int64
  let launchDate: String?
  let processStartTime: MacProcessStartTime?

  init(object: [String: JSONValue]) throws {
    guard let bundleID = object["bundle_id"]?.stringValue,
      let processID = object["pid"]?.intValue,
      processID > 0,
      Int32(exactly: processID) != nil
    else {
      throw AgentError.invalid("Accessibility commands require an exact bundle_id and process pid")
    }
    self.bundleID = bundleID
    self.processID = Int64(processID)
    guard let launchDateValue = object["launch_date"] else {
      throw AgentError.invalid("Copy launch_date from the same app.list row, including null")
    }
    switch launchDateValue {
    case .null: launchDate = nil
    case .string(let value): launchDate = value
    default: throw AgentError.invalid("launch_date must be a string or null")
    }
    guard let processStartTimeValue = object["process_start_time"] else {
      throw AgentError.invalid("Copy process_start_time from the same app.list row")
    }
    processStartTime = try MacProcessStartTime.parse(processStartTimeValue)
    guard launchDate != nil || processStartTime != nil else {
      throw AgentError(
        code: "accessibility_identity_unavailable",
        message: "The app.list row has no process start identity; refusing Accessibility access",
        details: ["bundle_id": .string(bundleID), "pid": .integer(Int64(processID))],
        exitCode: 6)
    }
  }
}

private struct AccessibilityTreeRequest: Sendable {
  let target: AccessibilityApplicationTarget
  let windowID: Int
  let maxDepth: Int
  let maxElements: Int

  init(object: [String: JSONValue]) throws {
    target = try AccessibilityApplicationTarget(object: object)
    windowID = try Self.windowID(in: object)
    maxDepth = try Self.maxDepth(in: object)
    maxElements = try Self.maxElements(in: object)
  }

  static func windowID(in object: [String: JSONValue]) throws -> Int {
    guard let value = object["window_id"]?.intValue, (0...63).contains(value) else {
      throw AgentError.invalid("window_id must select an entry from accessibility.windows.list")
    }
    return value
  }

  static func maxDepth(in object: [String: JSONValue]) throws -> Int {
    let value = object["max_depth"]?.intValue ?? 5
    guard (1...8).contains(value) else { throw AgentError.invalid("max_depth must be 1...8") }
    return value
  }

  static func maxElements(in object: [String: JSONValue]) throws -> Int {
    let value = object["max_elements"]?.intValue ?? 128
    guard (1...256).contains(value) else {
      throw AgentError.invalid("max_elements must be 1...256")
    }
    return value
  }
}

private struct AccessibilityActionRequest: Sendable {
  enum Action: Sendable, Equatable {
    case press
    case setValue
  }

  let target: AccessibilityApplicationTarget
  let windowID: Int
  let path: [Int]
  let action: Action
  let value: String?

  init(command: CommandSpec, input: JSONValue) throws {
    let object = try input.requiredObject()
    target = try AccessibilityApplicationTarget(object: object)
    windowID = try AccessibilityTreeRequest.windowID(in: object)
    guard let pathValue = object["path"]?.arrayValue, (1...8).contains(pathValue.count) else {
      throw AgentError.invalid("path must select 1...8 accessibility child indexes from the window")
    }
    let path = pathValue.compactMap(\.intValue)
    guard path.count == pathValue.count, path.allSatisfy({ (0...255).contains($0) }) else {
      throw AgentError.invalid("path indexes must be integers in 0...255")
    }
    self.path = path
    switch command.id {
    case "accessibility.elements.press":
      action = .press
      value = nil
    case "accessibility.elements.set_value":
      guard let value = object["value"]?.stringValue, value.utf8.count <= 65_536 else {
        throw AgentError.invalid("value must be text no larger than 64 KiB")
      }
      action = .setValue
      self.value = value
    default:
      throw AgentError.unsupported(command.id)
    }
  }
}

#endif

#if os(macOS)
private struct ApplicationIdentity {
  let bundleID: String
  let processID: Int64
  let bundlePath: String?
  let launchDate: String?
  let processStartTime: MacProcessStartTime?

  var json: JSONValue {
    .object([
      "bundle_id": .string(bundleID),
      "pid": .integer(processID),
      "bundle_path": bundlePath.map(JSONValue.string) ?? .null,
      "launch_date": launchDate.map(JSONValue.string) ?? .null,
      "process_start_time": processStartTime?.json ?? .null,
    ])
  }
}

private struct AccessibilityWindowSnapshot {
  let id: Int
  let identifier: String?
  let title: String?
  let role: String?
  let truncatedAttributes: [String]

  var json: JSONValue {
    .object([
      "window_id": .integer(Int64(id)),
      "identifier": identifier.map(JSONValue.string) ?? .null,
      "title": title.map(JSONValue.string) ?? .null,
      "role": role.map(JSONValue.string) ?? .null,
      "truncated_attributes": .array(truncatedAttributes.map(JSONValue.string)),
    ])
  }
}

private struct AccessibilityElementSnapshot {
  let path: [Int]
  let role: String?
  let subrole: String?
  let identifier: String?
  let title: String?
  let description: String?
  let enabled: Bool?
  let isSecure: Bool
  let value: String?
  let valueTruncated: Bool
  let actions: [String]
  let truncatedAttributes: [String]
  let attributesAvailable: Bool

  static func unavailable(path: [Int]) -> Self {
    Self(
      path: path,
      role: nil,
      subrole: nil,
      identifier: nil,
      title: nil,
      description: nil,
      enabled: nil,
      isSecure: false,
      value: nil,
      valueTruncated: false,
      actions: [],
      truncatedAttributes: ["AXAttributes"],
      attributesAvailable: false)
  }

  var json: JSONValue {
    .object([
      "path": .array(path.map { .integer(Int64($0)) }),
      "role": role.map(JSONValue.string) ?? .null,
      "subrole": subrole.map(JSONValue.string) ?? .null,
      "identifier": identifier.map(JSONValue.string) ?? .null,
      "title": title.map(JSONValue.string) ?? .null,
      "description": description.map(JSONValue.string) ?? .null,
      "enabled": enabled.map(JSONValue.bool) ?? .null,
      "attributes_available": .bool(attributesAvailable),
      "secure_value_redacted": .bool(isSecure),
      "value": value.map(JSONValue.string) ?? .null,
      "value_truncated": .bool(valueTruncated),
      "actions": .array(actions.map(JSONValue.string)),
      "truncated_attributes": .array(truncatedAttributes.map(JSONValue.string)),
    ])
  }
}
#endif
