import Foundation
import Testing
@testable import MacHandsfreePlatform

#if os(macOS)
struct RealProcessRunnerTests {
  @Test func capturesActualOutputAndExitStatus() async throws {
    let result = try await SubprocessProcessRunner().run(ProcessRequest(
      executable: "/usr/bin/printf", arguments: ["SEMI-process"], timeout: 3,
      maximumOutputBytes: 1_024))
    #expect(result.exitCode == 0)
    #expect(result.stdout == Data("SEMI-process".utf8))
    #expect(!result.timedOut)
    #expect(!result.outputLimitExceeded)
  }

  @Test func timeoutDrainsTheOwnedProcess() async throws {
    let result = try await SubprocessProcessRunner().run(ProcessRequest(
      executable: "/bin/sleep", arguments: ["10"], timeout: 0.05,
      maximumOutputBytes: 1_024))
    #expect(result.timedOut)
    #expect(result.exitCode != 0)
  }
}
#endif
