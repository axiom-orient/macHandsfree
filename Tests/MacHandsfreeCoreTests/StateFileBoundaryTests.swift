import Foundation
import MacHandsfreeCore
import Testing
@testable import MacHandsfreeState

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct StateFileBoundaryTests {
  @Test func secretRejectsFIFOWithoutReplacingIt() throws {
    let directory = try fixtureDirectory()
    defer { removeFixture(directory) }
    let path = directory.appending(path: "plan-secret").path
    try #require(mkfifo(path, 0o600) == 0)
    do {
      _ = try StateSecretStore.loadOrCreate(in: directory)
      Issue.record("A FIFO must not be accepted as a plan secret")
    } catch let error as AgentError {
      #expect(error.code == "plan_secret_unavailable")
    }
    try requireFIFO(at: path)
  }

  @Test func initializationRejectsFIFOWithoutEnteringTheProtectedBody() throws {
    let directory = try fixtureDirectory()
    defer { removeFixture(directory) }
    let path = directory.appending(path: ".initialize.lock").path
    try #require(mkfifo(path, 0o600) == 0)
    do {
      try StateInitializationLock.withLock(in: directory) { () -> Void in
        Issue.record("A FIFO must not admit state initialization")
      }
      Issue.record("A FIFO must not be accepted as an initialization lock")
    } catch let error as AgentError {
      #expect(error.code == "state_lock_invalid" || error.code == "state_lock_failed")
    }
    try requireFIFO(at: path)
  }

  private func fixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }

  private func requireFIFO(at path: String) throws {
    var info = stat()
    try #require(lstat(path, &info) == 0)
    #expect(info.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
  }

  private func removeFixture(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch { Issue.record("State boundary fixture cleanup failed: \(error)") }
  }
}
