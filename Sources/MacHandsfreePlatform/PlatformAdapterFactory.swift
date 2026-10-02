package import Foundation
package import MacHandsfreeCore

package enum PlatformAdapterFactory {
  package static func makeExecutor(
    registry: CommandRegistry,
    stateDirectoryURL: URL,
    mcpProtocols: [String],
    environment: [String: String]
  ) throws -> any CommandExecutor {
    try ServiceRouter(
      registry: registry,
      services: makeServices(
        registry: registry,
        stateDirectoryURL: stateDirectoryURL,
        mcpProtocols: mcpProtocols,
        environment: environment
      )
    )
  }

  static func makeServices(
    registry: CommandRegistry,
    stateDirectoryURL: URL,
    mcpProtocols: [String],
    environment: [String: String]
  ) -> [ServiceRegistration] {
    let processRunner = SubprocessProcessRunner()
    let appleEvents = AppleEventsRunner(processRunner: processRunner)
    let permissions = MacOSPermissionAdapter()
    return [
      .readOnly(
        CoreService(
          registry: registry, stateDirectoryURL: stateDirectoryURL, mcpProtocols: mcpProtocols, permissions: permissions)),
      .currentStateValidated(CalendarService(permissions: permissions)),
      .currentStateValidated(RemindersService(permissions: permissions)),
      .currentStateValidated(NotesService(runner: appleEvents)),
      .currentStateValidated(
        MailService(
          runner: appleEvents,
          indexReader: MailIndexReader(environment: environment, processRunner: processRunner)
        )),
      .currentStateValidated(ContactsService(permissions: permissions)),
      .currentStateValidated(SafariService(runner: appleEvents)),
      .currentStateValidated(
        MessagesService(
          database: MessagesDatabaseReader(environment: environment), runner: appleEvents)),
      .currentStateValidated(AccessibilityService(permissions: permissions)),
      .plannedInput(
        CallService(
          processRunner: processRunner,
          confirmer: FaceTimeAccessibilityAdapter(permissions: permissions),
          ender: FaceTimeAccessibilityAdapter(permissions: permissions)
        )),
      .currentStateValidated(FileService(processRunner: processRunner)),
      .currentStateValidated(ProcessService(processRunner: processRunner)),
      .currentStateValidated(SystemService(runner: appleEvents, processRunner: processRunner)),
      .currentStateValidated(AppService(processRunner: processRunner)),
      .currentStateValidated(ClipboardService()),
      .currentStateValidated(ShortcutsService(processRunner: processRunner)),
      .currentStateValidated(FinderService(runner: appleEvents, processRunner: processRunner)),
      .readOnly(SpotlightService(processRunner: processRunner)),
      .plannedInput(OnboardingService(processRunner: processRunner)),
    ]
  }
}
