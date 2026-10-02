#if os(macOS)
  import AppKit

  /// Native no-argument onboarding UI. It reports and requests only the
  /// permissions represented by `PermissionAuthorizing`; settings-only privacy
  /// areas remain explicit navigation actions.
  @MainActor
  package enum PlatformOnboardingWindow {
    private static var controller: OnboardingWindowController?

    package static func show() {
      let application = NSApplication.shared
      application.setActivationPolicy(.regular)
      let controller = OnboardingWindowController()
      self.controller = controller
      application.delegate = controller
      controller.showWindow(nil)
      application.activate(ignoringOtherApps: true)
      application.run()
    }
  }

  @MainActor
  private final class OnboardingWindowController: NSWindowController, NSApplicationDelegate,
    NSWindowDelegate
  {
    private let permissions: any PermissionAuthorizing = MacOSPermissionAdapter()
    private var activeRefreshID: UUID?
    private var permissionRequest: PermissionCapability?
    private let calendarStatus = NSTextField(labelWithString: "")
    private let remindersStatus = NSTextField(labelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let contactsStatus = NSTextField(labelWithString: "")
    private let messagesStatus = NSTextField(labelWithString: "")
    private let requestProblem = NSTextField(wrappingLabelWithString: "")
    private let calendarButton = NSButton(
      title: "전체 캘린더 접근 요청", target: nil, action: nil)
    private let remindersButton = NSButton(
      title: "미리 알림 접근 요청", target: nil, action: nil)
    private let accessibilityButton = NSButton(
      title: "손쉬운 사용 권한 요청", target: nil, action: nil)
    private let contactsButton = NSButton(title: "Contacts 권한 요청", target: nil, action: nil)

    init() {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered, defer: false)
      window.title = "Mac Handsfree 설정 확인"
      window.center()
      super.init(window: window)
      window.delegate = self
      buildContent()
      refresh()
    }

    required init?(coder: NSCoder) { nil }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowWillClose(_ notification: Notification) {
      activeRefreshID = nil
      NSApplication.shared.terminate(nil)
    }

    @objc private func refresh() {
      let refreshID = UUID()
      activeRefreshID = refreshID
      Task { [weak self] in
        guard let self else { return }
        let accessibility = await permissions.status(for: .accessibility)
        let calendar = await permissions.status(for: .calendar)
        let contacts = await permissions.status(for: .contacts)
        let reminders = await permissions.status(for: .reminders)
        guard activeRefreshID == refreshID else { return }
        activeRefreshID = nil
        updatePermissionStatuses(
          accessibility: accessibility, calendar: calendar, contacts: contacts,
          reminders: reminders)
      }
    }

    @objc private func requestCalendar() { request(.calendar) }
    @objc private func requestReminders() { request(.reminders) }
    @objc private func requestContacts() { request(.contacts) }
    @objc private func requestAccessibility() { request(.accessibility) }

    private func request(_ capability: PermissionCapability) {
      guard permissionRequest == nil else { return }
      permissionRequest = capability
      setRequestButtonsEnabled(false)
      clearRequestProblem()
      Task { [weak self] in
        guard let self else { return }
        defer {
          permissionRequest = nil
          setRequestButtonsEnabled(true)
          refresh()
        }
        do {
          _ = try await permissions.requestAccessIfNeeded(for: capability)
        } catch {
          requestProblem.stringValue = "권한 요청을 완료하지 못했습니다: \(error.localizedDescription)"
          requestProblem.isHidden = false
        }
      }
    }

    private func setRequestButtonsEnabled(_ enabled: Bool) {
      for button in [calendarButton, remindersButton, accessibilityButton, contactsButton] {
        button.isEnabled = enabled
      }
    }

    private func updatePermissionStatuses(
      accessibility: PermissionAuthorization, calendar: PermissionAuthorization,
      contacts: PermissionAuthorization, reminders: PermissionAuthorization
    ) {
      accessibilityStatus.stringValue = statusLine(
        name: "손쉬운 사용", status: accessibility, detail: "앱 UI 접근 권한")
      accessibilityButton.isHidden = accessibility.isGranted
      calendarStatus.stringValue = statusLine(
        name: "Calendar", status: calendar, detail: "읽기·쓰기 권한")
      calendarButton.isHidden = !canRequestFullAccess(.calendar, status: calendar)
      remindersStatus.stringValue = statusLine(
        name: "Reminders", status: reminders, detail: "읽기·쓰기 권한")
      remindersButton.isHidden = !canRequestFullAccess(.reminders, status: reminders)
      contactsStatus.stringValue = statusLine(
        name: "Contacts", status: contacts, detail: "연락처 접근 권한")
      contactsButton.isHidden = !canRequestFullAccess(.contacts, status: contacts)

      let messagesDatabase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")
      let messagesReadable = FileManager.default.isReadableFile(atPath: messagesDatabase.path)
      messagesStatus.stringValue = messagesReadable
        ? "✓ Messages 기록: 파일 검사상 chat.db 읽기 가능"
        : "! Messages 기록: chat.db 읽기 미확인 — 파일·권한 주체 확인"
    }

    @objc private func openAccessibility() { open(.accessibility) }
    @objc private func openCalendar() { open(.calendar) }
    @objc private func openContacts() { open(.contacts) }
    @objc private func openFullDiskAccess() { open(.fullDiskAccess) }
    @objc private func openReminders() { open(.reminders) }

    private func open(_ area: PrivacyOnboardingArea) {
      guard let url = URL(string: area.settingsURL) else { return }
      NSWorkspace.shared.open(url)
    }

    private func buildContent() {
      let content = NSView()
      content.translatesAutoresizingMaskIntoConstraints = false
      window?.contentView = content

      let title = NSTextField(labelWithString: "시작 전 권한 확인")
      title.font = .systemFont(ofSize: 22, weight: .bold)
      let explanation = NSTextField(
        wrappingLabelWithString:
          "권한 요청은 macOS가 표시하는 화면에서 직접 결정합니다. 거부된 권한은 System Settings > Privacy & Security에서 변경할 수 있습니다.")
      explanation.textColor = .secondaryLabelColor
      requestProblem.textColor = .systemRed
      requestProblem.isHidden = true
      requestProblem.setAccessibilityIdentifier("onboarding.permissionRequestError")

      let statusStack = NSStackView(views: [
        calendarStatus, remindersStatus, contactsStatus, accessibilityStatus, messagesStatus,
      ])
      statusStack.orientation = .vertical
      statusStack.alignment = .leading
      statusStack.spacing = 10

      let dataSettingsStack = NSStackView(views: [
        button("캘린더 설정 열기", #selector(openCalendar)),
        button("미리 알림 설정 열기", #selector(openReminders)),
        button("연락처 설정 열기", #selector(openContacts)),
      ])
      dataSettingsStack.orientation = .horizontal
      dataSettingsStack.distribution = .fillEqually
      dataSettingsStack.spacing = 8

      let systemSettingsStack = NSStackView(views: [
        button("손쉬운 사용 열기", #selector(openAccessibility)),
        button("전체 디스크 접근 열기", #selector(openFullDiskAccess)),
      ])
      systemSettingsStack.orientation = .horizontal
      systemSettingsStack.distribution = .fillEqually
      systemSettingsStack.spacing = 8

      calendarButton.target = self
      calendarButton.action = #selector(requestCalendar)
      remindersButton.target = self
      remindersButton.action = #selector(requestReminders)
      accessibilityButton.target = self
      accessibilityButton.action = #selector(requestAccessibility)
      contactsButton.target = self
      contactsButton.action = #selector(requestContacts)
      let refreshButton = button("다시 확인", #selector(refresh))
      let eventKitActions = NSStackView(views: [calendarButton, remindersButton])
      eventKitActions.orientation = .horizontal
      eventKitActions.alignment = .centerY
      eventKitActions.spacing = 10
      let otherActions = NSStackView(views: [accessibilityButton, contactsButton, refreshButton])
      otherActions.orientation = .horizontal
      otherActions.alignment = .centerY
      otherActions.spacing = 10

      let cliNote = NSTextField(
        wrappingLabelWithString:
          "자동화에서는 doctor 명령으로 같은 상태를 JSON으로 확인할 수 있습니다. Messages와 FaceTime은 Apple 계정 설정 및 macOS의 현재 권한 주체에 따라 달라질 수 있습니다."
      )
      cliNote.textColor = .secondaryLabelColor
      cliNote.font = .systemFont(ofSize: 12)

      let stack = NSStackView(views: [
        title, explanation, statusStack, requestProblem, eventKitActions, otherActions,
        dataSettingsStack, systemSettingsStack, cliNote,
      ])
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 16
      stack.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
        stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
        stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -28),
        requestProblem.widthAnchor.constraint(equalTo: stack.widthAnchor),
      ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
      let button = NSButton(title: title, target: self, action: action)
      button.bezelStyle = .rounded
      return button
    }

    private func clearRequestProblem() {
      requestProblem.stringValue = ""
      requestProblem.isHidden = true
    }

    private func statusLine(
      name: String, status: PermissionAuthorization, detail: String
    ) -> String {
      "\(status.isGranted ? "✓" : "! ") \(name): \(permissionStateLabel(status)) — \(detail)"
    }

    private func permissionStateLabel(_ status: PermissionAuthorization) -> String {
      switch status {
      case .granted: "허용됨"
      case .notDetermined: "승인 필요"
      case .denied: "System Settings에서 허용 필요"
      case .restricted: "시스템 정책으로 제한됨"
      case .limited: "전체 접근 필요"
      case .unsupportedHost: "지원되지 않는 호스트"
      case .unknown: "상태 확인 실패"
      }
    }

    private func canRequestFullAccess(
      _ capability: PermissionCapability, status: PermissionAuthorization
    ) -> Bool {
      status == .notDetermined || (capability == .calendar && status == .limited)
    }

  }
#endif
