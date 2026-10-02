import Foundation
import Testing
import MacHandsfreeCore
@testable import MacHandsfreePlatform

struct WorkspaceToolTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SEMI-workspace-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
  @Test func patchRejectsAmbiguousOverlappingMatchWithoutWriting() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    try Data("aaa".utf8).write(to: file)
    do {
      _ = try FilePatch.prepare(.object(["path": .string(file.path), "edits": .array([
        .object(["before": "aa", "after": "b"]),
      ])]))
      Issue.record("Overlapping before matches must be ambiguous")
    } catch let error as AgentError { #expect(error.code == "patch_match_not_unique") }
    #expect(try Data(contentsOf: file) == Data("aaa".utf8))
  }
  @Test func patchPreservesExactUnicodeBytesAndShowsTheirChange() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    let original = "e\u{301}\nsecond line\n"
    let replacement = "\u{e9}"
    try Data(original.utf8).write(to: file)
    let patch = try FilePatch.prepare(.object(["path": .string(file.path), "edits": .array([
      .object(["before": .string("e\u{301}"), "after": .string(replacement)]),
    ])]))
    #expect(Data((patch.writeInput["content"]?.stringValue ?? "").utf8) == Data((replacement + "\nsecond line\n").utf8))
    #expect(patch.diff.utf8.count > 0)
    #expect(try Data(contentsOf: file) == Data(original.utf8))
  }
  @Test func approvedPatchRejectsConcurrentHumanEdit() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    try Data("before\n".utf8).write(to: file)
    let registry = try CommandRegistry()
    let command = try #require(registry.command(id: "files.patch"))
    let service = FileService(processRunner: NeverRunProcess())
    let input: JSONValue = .object(["path": .string(file.path), "edits": .array([
      .object(["before": "before", "after": "after"]),
    ])])
    let preview = try await service.preview(command: command, input: input)
    #expect(preview["diff"]?.stringValue?.contains("-before\n+after") == true)
    #expect(try Data(contentsOf: file) == Data("before\n".utf8))
    try Data("human edit\n".utf8).write(to: file)
    do {
      _ = try await service.executeMutation(command: command, input: input, plannedPreview: preview)
      Issue.record("A changed file must not be patched by an old approval")
    } catch let error as AgentError { #expect(error.code == "plan_state_changed") }
    #expect(try Data(contentsOf: file) == Data("human edit\n".utf8))
  }
  @Test func searchReportsSkippedLargeFileAndExcludesDependencyTree() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("needle".utf8).write(to: directory.appendingPathComponent("small.txt"))
    try Data(repeating: 97, count: WorkspaceToolPolicy.Search.maximumFileBytes + 1)
      .write(to: directory.appendingPathComponent("large.txt"))
    let dependency = directory.appendingPathComponent("node_modules")
    try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: false)
    try Data("needle".utf8).write(to: dependency.appendingPathComponent("dependency.txt"))
    let result = try FileSearch.search(["path": .string(directory.path), "query": "needle", "kind": "content"])
    #expect(result["matches"]?.arrayValue?.count == 1)
    #expect(result["skipped_count"]?.intValue == 1)
    #expect(result["search_incomplete"]?.boolValue == true)
  }
  #if os(macOS)
  @Test func processRejectsExecutableRedirectAfterApproval() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("program")
    try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/echo")
    let service = ProcessService(processRunner: NeverRunProcess())
    let command = try #require(CommandRegistry().command(id: "process.run"))
    let input: JSONValue = .object(["executable": .string(executable.path), "cwd": .string(directory.path), "arguments": .array([])])
    let preview = try await service.preview(command: command, input: input)
    try FileManager.default.removeItem(at: executable)
    try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/ls")
    do {
      _ = try await service.executeMutation(command: command, input: input, plannedPreview: preview)
      Issue.record("An executable redirect must invalidate the approved command")
    } catch let error as AgentError { #expect(error.code == "plan_state_changed") }
  }
  #endif
}

private struct NeverRunProcess: ProcessRunning {
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    Issue.record("A rejected plan must never launch a process")
    throw AgentError.invalid("Unexpected process dispatch")
  }
}
