import Foundation
import Testing
import MacHandsfreeCore
@testable import MacHandsfreePlatform

struct LocalPathMutationGuardTests {
  @Test func guardRejectsChangedDescendantBeforeFileMutation() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MacHandsfreeGuard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let child = root.appendingPathComponent("source.txt")
    try Data("first".utf8).write(to: child)
    let guardSpec = LocalPathGuardSpec(role: "source", url: root)
    let pathGuard = LocalPathMutationGuard()
    let planned = try pathGuard.attaching([guardSpec], to: .object([:]))

    try Data("other".utf8).write(to: child)

    do {
      try pathGuard.validate(planned, specs: [guardSpec])
      Issue.record("A changed descendant must invalidate the approved filesystem state")
    } catch let error as AgentError {
      #expect(error.code == "plan_state_changed")
    }
  }
}
