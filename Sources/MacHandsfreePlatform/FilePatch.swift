import Foundation
import MacHandsfreeCore

/// Exact edits produce a normal guarded atomic write; there is no second mutation mechanism.
enum FilePatch {
  private typealias Policy = WorkspaceToolPolicy.Patch
  struct Prepared {
    let writeInput: JSONValue
    let diff: String
  }
  static func writeCommand() throws -> CommandSpec {
    guard let command = try CommandRegistry().command(id: "files.write") else {
      throw AgentError.invalid("The canonical files.write command is missing")
    }
    return command
  }
  static func prepare(_ input: JSONValue) throws -> Prepared {
    let object = try input.requiredObject()
    let path = try object.requiredString("path")
    let file = try FileReadOperations().readBytes(path: path, maximumBytes: Policy.maximumFileBytes)
    guard let original = String(data: file.data, encoding: .utf8), !original.contains("\0"),
          let edits = object["edits"]?.arrayValue, !edits.isEmpty else {
      throw AgentError.invalid("Patch requires an existing UTF-8 text file and exact edits")
    }
    var text = original
    for (index, edit) in edits.enumerated() {
      try Task.checkCancellation()
      let values = try edit.requiredObject()
      let before = try values.requiredString("before")
      let after = try values.requiredString("after")
      guard !before.isEmpty, !after.contains("\0"), !before.utf8.elementsEqual(after.utf8),
            let range = text.range(of: before, options: .literal),
            text.range(of: before, options: .literal, range: text.index(after: range.lowerBound)..<text.endIndex) == nil else {
        throw AgentError(code: "patch_match_not_unique", message: "Each before text must match exactly once and produce a change",
                         details: ["path": .string(path), "edit_index": .integer(Int64(index))], exitCode: 6)
      }
      text.replaceSubrange(range, with: after)
      guard text.utf8.count <= Policy.maximumFileBytes else { throw AgentError.invalid("Patched file exceeds its size limit") }
    }
    guard !text.utf8.elementsEqual(original.utf8) else { throw AgentError.invalid("The patch has no net change") }
    let diff = unifiedDiff(before: original, after: text, path: file.path)
    guard diff.utf8.count <= Policy.maximumPreviewBytes else {
      throw AgentError.invalid("Exact diff exceeds the approval preview limit; use a smaller edit")
    }
    return Prepared(writeInput: .object([
      "path": .string(file.path), "content": .string(text), "encoding": .string("utf8"),
      "overwrite": .bool(true), "create_parents": .bool(false),
    ]), diff: diff)
  }
  private static func unifiedDiff(before: String, after: String, path: String) -> String {
    func lines(_ text: String) -> [String] {
      if text.isEmpty { return [] }
      var values = text.components(separatedBy: "\n")
      if text.hasSuffix("\n") { values.removeLast() }
      return values
    }
    func equal(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
    let old = lines(before), new = lines(after)
    var prefix = 0
    while prefix < min(old.count, new.count), equal(old[prefix], new[prefix]) { prefix += 1 }
    if old.count == new.count && zip(old, new).allSatisfy({ equal($0.0, $0.1) }) { prefix = max(0, prefix - 1) }
    var suffix = 0
    while suffix < min(old.count, new.count) - prefix,
          equal(old[old.count - 1 - suffix], new[new.count - 1 - suffix]) { suffix += 1 }
    let start = max(0, prefix - 3)
    let context = min(3, suffix)
    let oldEnd = old.count - suffix, newEnd = new.count - suffix
    let oldCount = oldEnd + context - start, newCount = newEnd + context - start
    var output = "--- \(path)\n+++ \(path)\n@@ -\(oldCount == 0 ? start : start + 1),\(oldCount) +\(newCount == 0 ? start : start + 1),\(newCount) @@\n"
    func append(_ line: String, mark: String, last: Bool, newline: Bool) {
      output += mark + line + "\n"
      if last && !newline { output += "\\ No newline at end of file\n" }
    }
    for i in start..<prefix { append(old[i], mark: " ", last: i == old.count - 1, newline: before.hasSuffix("\n")) }
    for i in prefix..<oldEnd { append(old[i], mark: "-", last: i == old.count - 1, newline: before.hasSuffix("\n")) }
    for i in prefix..<newEnd { append(new[i], mark: "+", last: i == new.count - 1, newline: after.hasSuffix("\n")) }
    for i in 0..<context { append(old[oldEnd + i], mark: " ", last: oldEnd + i == old.count - 1, newline: before.hasSuffix("\n")) }
    return output
  }
}
