import MacHandsfreePlatform

#if os(macOS)
  package enum RuntimeOnboarding {
    @MainActor
    package static func show() { PlatformOnboardingWindow.show() }
  }
#endif
