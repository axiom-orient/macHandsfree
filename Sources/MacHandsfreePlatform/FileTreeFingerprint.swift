import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct FileTreeFingerprint: Sendable, Equatable {
  let stateDigest: String
  let relocatedStateDigest: String
  let contentDigest: String
  let payloadDigest: String
  let entryCount: Int
  let regularBytes: Int64
}

enum FileTreeGuardPresentation {
  /// Removes opaque digests only from public presentations, never from stored execution guards.
  private static let internalFingerprintKeys: Set<String> = [
    "tree_state_sha256", "tree_relocated_state_sha256", "tree_content_sha256",
  ]
  private static let internalGuardVersionKeys: Set<String> = [
    "guard_version", "local_path_guard_version",
  ]
  private static let publicPathGuardKeys: Set<String> = [
    "role", "path", "state", "kind", "size", "tree_entry_count", "tree_regular_bytes",
    "symlink_destination",
  ]

  static func publicValue(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object):
      if isPathGuard(object) {
        var result: [String: JSONValue] = [:]
        for key in publicPathGuardKeys {
          if let value = object[key] { result[key] = publicValue(value) }
        }
        return .object(result)
      }
      var result: [String: JSONValue] = [:]
      for (key, child) in object {
        guard !internalFingerprintKeys.contains(key), !internalGuardVersionKeys.contains(key) else {
          continue
        }
        result[key] = publicValue(child)
      }
      return .object(result)
    case .array(let values):
      return .array(values.map(publicValue))
    default:
      return value
    }
  }

  private static func isPathGuard(_ object: [String: JSONValue]) -> Bool {
    object["role"]?.stringValue != nil
      && object["path"]?.stringValue != nil
      && object["state"]?.stringValue != nil
      && object["track_changes"]?.boolValue != nil
  }
}

/// Captures a deterministic, non-following snapshot of a file or directory tree.
/// State identity includes inode and timestamps; copied-content identity excludes them.
enum FileTreeFingerprinter {
  private static let maximumEntries = 100_000

  static func snapshot(_ root: URL, fileManager: FileManager = .default) throws
    -> FileTreeFingerprint
  {
    try requireNotCancelled()
    var entries: [SnapshotEntry] = []
    try collect(root: root, current: root, fileManager: fileManager, entries: &entries)
    try verifyStable(entries)

    var stateHasher = SHA256Hasher()
    var relocatedStateHasher = SHA256Hasher()
    var contentHasher = SHA256Hasher()
    var payloadHasher = SHA256Hasher()
    stateHasher.update(Data("mac-handsfree-tree-state-v2\0".utf8))
    relocatedStateHasher.update(Data("mac-handsfree-tree-relocated-state-v1\0".utf8))
    contentHasher.update(Data("mac-handsfree-tree-content-v1\0".utf8))
    payloadHasher.update(Data("mac-handsfree-tree-payload-v1\0".utf8))
    var regularBytes: Int64 = 0

    for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
      stateHasher.update(try entry.stateJSON.encoded())
      stateHasher.update(Data([0x0A]))
      relocatedStateHasher.update(try entry.relocatedStateJSON.encoded())
      relocatedStateHasher.update(Data([0x0A]))
      contentHasher.update(try entry.contentJSON.encoded())
      contentHasher.update(Data([0x0A]))
      payloadHasher.update(try entry.payloadJSON.encoded())
      payloadHasher.update(Data([0x0A]))
      let nextBytes = regularBytes.addingReportingOverflow(entry.regularBytes)
      guard !nextBytes.overflow else {
        throw AgentError(
          code: "file_tree_too_large",
          message: "File tree byte accounting exceeds supported limits",
          exitCode: 6
        )
      }
      regularBytes = nextBytes.partialValue
    }

    return FileTreeFingerprint(
      stateDigest: SHA256.hex(stateHasher.finalize()),
      relocatedStateDigest: SHA256.hex(relocatedStateHasher.finalize()),
      contentDigest: SHA256.hex(contentHasher.finalize()),
      payloadDigest: SHA256.hex(payloadHasher.finalize()),
      entryCount: entries.count,
      regularBytes: regularBytes
    )
  }

  private static func collect(
    root: URL,
    current: URL,
    fileManager: FileManager,
    entries: inout [SnapshotEntry]
  ) throws {
    try requireNotCancelled()
    guard entries.count < maximumEntries else {
      throw AgentError(
        code: "file_tree_too_large",
        message: "File tree exceeds the 100,000-entry mutation guard limit",
        details: ["path": .string(root.path), "maximum_entries": 100_000],
        exitCode: 6
      )
    }
    let info = try lstatValue(current)
    let relative = relativePath(root: root, current: current)
    let type = info.st_mode & mode_t(S_IFMT)

    switch type {
    case mode_t(S_IFREG):
      let digest = try regularFileDigest(current, expected: info)
      entries.append(
        SnapshotEntry(
          url: current,
          relativePath: relative,
          kind: "file",
          info: info,
          symlinkDestination: nil,
          fileDigest: digest
        ))
    case mode_t(S_IFDIR):
      entries.append(
        SnapshotEntry(
          url: current,
          relativePath: relative,
          kind: "directory",
          info: info,
          symlinkDestination: nil,
          fileDigest: nil
        ))
      let children: [URL]
      do {
        children = try fileManager.contentsOfDirectory(
          at: current,
          includingPropertiesForKeys: nil,
          options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
      } catch {
        throw AgentError(
          code: "path_snapshot_failed",
          message: "Could not enumerate a directory while capturing mutation state",
          details: [
            "path": .string(current.path),
            "reason": .string(String(describing: error)),
          ],
          exitCode: 5
        )
      }
      for child in children {
        try requireNotCancelled()
        try collect(root: root, current: child, fileManager: fileManager, entries: &entries)
      }
    case mode_t(S_IFLNK):
      let destination: String
      do {
        destination = try fileManager.destinationOfSymbolicLink(atPath: current.path)
      } catch {
        throw AgentError(
          code: "path_snapshot_failed",
          message: "Could not read a symbolic link while capturing mutation state",
          details: [
            "path": .string(current.path),
            "reason": .string(String(describing: error)),
          ],
          exitCode: 5
        )
      }
      entries.append(
        SnapshotEntry(
          url: current,
          relativePath: relative,
          kind: "symlink",
          info: info,
          symlinkDestination: destination,
          fileDigest: nil
        ))
    default:
      entries.append(
        SnapshotEntry(
          url: current,
          relativePath: relative,
          kind: "other",
          info: info,
          symlinkDestination: nil,
          fileDigest: nil
        ))
    }
  }

  private static func regularFileDigest(_ url: URL, expected: stat) throws -> String {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw snapshotFailure(
        message: "Could not open a file while capturing mutation state",
        path: url.path
      )
    }
    var descriptorIsOpen = true

    do {
      var before = stat()
      guard fstat(descriptor, &before) == 0,
        isSameItem(before, expected),
        (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
      else {
        throw changedDuringSnapshot(url.path)
      }

      var hasher = SHA256Hasher()
      var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
      var byteCount: Int64 = 0
      while true {
        try requireNotCancelled()
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
          guard let base = raw.baseAddress else { return 0 }
          return read(descriptor, base, raw.count)
        }
        if count > 0 {
          let nextCount = byteCount.addingReportingOverflow(Int64(count))
          guard !nextCount.overflow else {
            throw AgentError(
              code: "file_tree_too_large",
              message: "Regular file byte accounting exceeds supported limits",
              details: ["path": .string(url.path)],
              exitCode: 6
            )
          }
          byteCount = nextCount.partialValue
          hasher.update(Data(buffer.prefix(count)))
          continue
        }
        if count == 0 { break }
        if errno == EINTR { continue }
        throw snapshotFailure(
          message: "Could not read a file while capturing mutation state",
          path: url.path
        )
      }

      var after = stat()
      guard fstat(descriptor, &after) == 0,
        stable(before, after),
        byteCount == Int64(after.st_size)
      else {
        throw changedDuringSnapshot(url.path)
      }
      let digest = SHA256.hex(hasher.finalize())
      descriptorIsOpen = false
      guard close(descriptor) == 0 else {
        throw snapshotCleanupFailure(
          path: url.path,
          originalError: nil,
          errorNumber: errno
        )
      }
      return digest
    } catch {
      let originalError = error
      guard descriptorIsOpen else { throw originalError }
      descriptorIsOpen = false
      guard close(descriptor) == 0 else {
        throw snapshotCleanupFailure(
          path: url.path,
          originalError: originalError,
          errorNumber: errno
        )
      }
      throw originalError
    }
  }

  private static func verifyStable(_ entries: [SnapshotEntry]) throws {
    for entry in entries {
      try requireNotCancelled()
      let current = try lstatValue(entry.url)
      guard stable(entry.info, current) else {
        throw changedDuringSnapshot(entry.url.path)
      }
      if let expected = entry.symlinkDestination {
        let currentDestination: String
        do {
          currentDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: entry.url.path)
        } catch {
          throw changedDuringSnapshot(entry.url.path)
        }
        guard currentDestination == expected else {
          throw changedDuringSnapshot(entry.url.path)
        }
      }
    }
  }

  private static func requireNotCancelled() throws {
    guard !Task.isCancelled else {
      throw AgentError(
        code: "operation_cancelled",
        message: "File tree snapshot was cancelled",
        exitCode: 6
      )
    }
  }

  private static func lstatValue(_ url: URL) throws -> stat {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw snapshotFailure(
        message: "Could not inspect a path while capturing mutation state",
        path: url.path
      )
    }
    return info
  }

  private static func relativePath(root: URL, current: URL) -> String {
    guard current.path != root.path else { return "." }
    return String(current.path.dropFirst(root.path.count + 1))
  }

  private static func stable(_ left: stat, _ right: stat) -> Bool {
    isSameItem(left, right)
      && left.st_mode == right.st_mode
      && left.st_nlink == right.st_nlink
      && left.st_size == right.st_size
      && fileModificationTime(left) == fileModificationTime(right)
      && fileChangeTime(left) == fileChangeTime(right)
  }

  private static func isSameItem(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
  }

  private static func changedDuringSnapshot(_ path: String) -> AgentError {
    AgentError(
      code: "path_changed_during_snapshot",
      message: "A path changed while its mutation state was being captured",
      details: ["path": .string(path)],
      exitCode: 6
    )
  }

  private static func snapshotCleanupFailure(
    path: String,
    originalError: (any Error)?,
    errorNumber: Int32
  ) -> AgentError {
    var details: [String: JSONValue] = [
      "path": .string(path),
      "errno": .integer(Int64(errorNumber)),
    ]
    if let originalError {
      details["original_error"] = .string(String(describing: originalError))
    }
    return AgentError(
      code: "path_snapshot_cleanup_failed",
      message: "Could not close a file after capturing mutation state",
      details: details,
      exitCode: 5
    )
  }

  private static func snapshotFailure(message: String, path: String) -> AgentError {
    AgentError(
      code: "path_snapshot_failed",
      message: message,
      details: ["path": .string(path), "errno": .integer(Int64(errno))],
      exitCode: 5
    )
  }

}

private struct SnapshotEntry {
  let url: URL
  let relativePath: String
  let kind: String
  let info: stat
  let symlinkDestination: String?
  let fileDigest: String?

  var regularBytes: Int64 { kind == "file" ? Int64(info.st_size) : 0 }

  var stateJSON: JSONValue {
    var value = stateFields
    let changed = fileChangeTime(info)
    value["changed_seconds"] = .integer(changed.seconds)
    value["changed_nanoseconds"] = .integer(changed.nanoseconds)
    return .object(value)
  }

  /// Renaming the root updates its ctime, while descendants retain their metadata.
  /// Excluding only the root ctime keeps relocation validation sensitive to nested drift.
  var relocatedStateJSON: JSONValue {
    var value = stateFields
    if relativePath != "." {
      let changed = fileChangeTime(info)
      value["changed_seconds"] = .integer(changed.seconds)
      value["changed_nanoseconds"] = .integer(changed.nanoseconds)
    }
    return .object(value)
  }

  var contentJSON: JSONValue {
    var value: [String: JSONValue] = [
      "path": .string(relativePath),
      "kind": .string(kind),
      "mode": .string(String(format: "%o", info.st_mode & 0o7777)),
    ]
    if kind == "file" { value["size"] = .integer(Int64(info.st_size)) }
    if let symlinkDestination {
      value["symlink_destination"] = .string(symlinkDestination)
    }
    if let fileDigest { value["sha256"] = .string(fileDigest) }
    return .object(value)
  }

  /// Content identity independent of ownership, timestamps, inode, and permissions.
  var payloadJSON: JSONValue {
    var value: [String: JSONValue] = [
      "path": .string(relativePath),
      "kind": .string(kind),
    ]
    if kind == "file" { value["size"] = .integer(Int64(info.st_size)) }
    if let symlinkDestination {
      value["symlink_destination"] = .string(symlinkDestination)
    }
    if let fileDigest { value["sha256"] = .string(fileDigest) }
    return .object(value)
  }

  private var stateFields: [String: JSONValue] {
    var value = commonJSON
    value["device"] = .string(String(info.st_dev))
    value["inode"] = .string(String(info.st_ino))
    value["owner"] = .string(String(info.st_uid))
    value["group"] = .string(String(info.st_gid))
    value["link_count"] = .integer(Int64(info.st_nlink))
    let modified = fileModificationTime(info)
    value["modified_seconds"] = .integer(modified.seconds)
    value["modified_nanoseconds"] = .integer(modified.nanoseconds)
    return value
  }

  private var commonJSON: [String: JSONValue] {
    var value: [String: JSONValue] = [
      "path": .string(relativePath),
      "kind": .string(kind),
      "mode": .string(String(format: "%o", info.st_mode & 0o7777)),
      "size": .integer(Int64(info.st_size)),
    ]
    if let symlinkDestination {
      value["symlink_destination"] = .string(symlinkDestination)
    }
    if let fileDigest {
      value["sha256"] = .string(fileDigest)
    }
    return value
  }
}
