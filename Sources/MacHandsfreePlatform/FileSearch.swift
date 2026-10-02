import Foundation
import MacHandsfreeCore

/// Bounded literal search, never an implicit whole-computer index.
enum FileSearch {
  private typealias Policy = WorkspaceToolPolicy.Search
  static func search(_ object: [String: JSONValue]) throws -> JSONValue {
    let root = try LocalPathPolicy.requireExisting(object.requiredString("path")).resolvingSymlinksInPath()
    let inspection = FileSystemInspector()
    guard try inspection.pathGuard(role: "root", url: root, includeChanges: false)["kind"]?.stringValue == "directory" else {
      throw AgentError.invalid("Search path must be a directory")
    }
    let query = try object.requiredString("query")
    let kind = object.optionalString("kind") ?? "both"
    let scanLimit = object.optionalInt("scan_limit", default: Policy.defaultScanLimit) ?? Policy.defaultScanLimit
    let resultLimit = object.optionalInt("limit", default: Policy.defaultResultLimit) ?? Policy.defaultResultLimit
    let excluded = object["exclude_directories"] == nil ? Policy.excludedDirectories : Set(object.stringArray("exclude_directories"))
    let urls = try FileTreeLister(fileManager: .default).list(root: root, recursive: true,
      includeHidden: object.optionalBool("include_hidden"), maximumCount: scanLimit + 1, excludingDirectories: excluded)
    let options: String.CompareOptions = object.optionalBool("case_sensitive") ? [.literal] : [.literal, .caseInsensitive]
    var matches: [JSONValue] = []
    var skipped: [JSONValue] = []
    var totalBytes = 0
    var inspected = 0
    var byteLimit = false
    var resultLimitReached = false
    for url in urls.prefix(scanLimit) {
      try Task.checkCancellation()
      inspected += 1
      let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if kind != "content", relative.range(of: query, options: options) != nil {
        matches.append(.object(["path": .string(url.path), "kind": "name"]))
        if matches.count >= resultLimit { resultLimitReached = true; break }
      }
      if kind == "name" { continue }
      let metadata = try inspection.pathGuard(role: "candidate", url: url, includeChanges: false)
      guard metadata["kind"]?.stringValue == "file" else { continue }
      do {
        let size = try inspection.itemInfo(url).st_size
        if size > Int64(Policy.maximumFileBytes) {
          skipped.append(.object(["path": .string(url.path), "reason": "file_too_large"]))
          continue
        }
        let remaining = Policy.maximumTotalBytes - totalBytes
        guard remaining > 0, size <= Int64(remaining) else { byteLimit = true; break }
        let file = try FileReadOperations().readBytes(path: url.path, maximumBytes: min(Policy.maximumFileBytes, remaining))
        totalBytes += file.data.count
        guard let text = String(data: file.data, encoding: .utf8), !text.contains("\0") else {
          skipped.append(.object(["path": .string(url.path), "reason": "not_utf8_text"]))
          continue
        }
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
          try Task.checkCancellation()
          if let match = line.range(of: query, options: options) {
            let start = line.index(match.lowerBound, offsetBy: -80, limitedBy: line.startIndex) ?? line.startIndex
            let end = line.index(start, offsetBy: Policy.excerptCharacters, limitedBy: line.endIndex) ?? line.endIndex
            matches.append(.object(["path": .string(url.path), "kind": "content",
              "line": .integer(Int64(index + 1)), "text": .string(String(line[start..<end])),
              "excerpt_truncated": .bool(start != line.startIndex || end != line.endIndex)]))
            if matches.count >= resultLimit { resultLimitReached = true; break }
          }
        }
        if resultLimitReached { break }
      } catch is CancellationError { throw CancellationError() }
      catch {
        skipped.append(.object(["path": .string(url.path), "reason": .string((error as? AgentError)?.code ?? "read_failed")]))
      }
    }
    try Task.checkCancellation()
    let incomplete = urls.count > scanLimit || resultLimitReached || byteLimit || !skipped.isEmpty
    return .object([
      "root": .string(root.path), "matches": .array(matches),
      "entries_inspected": .integer(Int64(inspected)), "bytes_read": .integer(Int64(totalBytes)),
      "excluded_directories": .array(excluded.sorted().map(JSONValue.string)),
      "include_hidden": .bool(object.optionalBool("include_hidden")),
      "skipped": .array(Array(skipped.prefix(Policy.maximumSkippedDetails))), "skipped_count": .integer(Int64(skipped.count)),
      "scan_limit_reached": .bool(urls.count > scanLimit), "result_limit_reached": .bool(resultLimitReached),
      "byte_limit_reached": .bool(byteLimit), "search_incomplete": .bool(incomplete),
      "atomic_snapshot": .bool(false),
    ])
  }
}
