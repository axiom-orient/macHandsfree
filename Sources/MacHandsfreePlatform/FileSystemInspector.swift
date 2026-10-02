import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct FileTransferInspection {
  let source: URL
  let destination: URL
  let destinationInfo: stat?
  let overwrite: Bool
  let parents: [URL]
}

struct FileSystemInspector {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func inspectTransfer(_ object: [String: JSONValue]) throws -> FileTransferInspection {
    let source = try LocalPathPolicy.expandedURL(object.requiredString("source"))
    let destination = try LocalPathPolicy.expandedURL(object.requiredString("destination"))
    let sourceInfo = try itemInfo(source)
    try requireSupportedTransferSource(sourceInfo, path: source.path)
    try validateTransfer(source: source, sourceInfo: sourceInfo, destination: destination)
    try rejectFinalSymlink(destination)
    let parents = try plannedParents(
      for: destination.deletingLastPathComponent(), create: object.optionalBool("create_parents"))

    let destinationInfo = try optionalItemInfo(destination)
    if let destinationInfo, sameItem(sourceInfo, destinationInfo) {
      throw AgentError(
        code: "source_destination_same_item",
        message: "Source and destination refer to the same filesystem item",
        exitCode: 6
      )
    }
    let overwrite = object.optionalBool("overwrite")
    if destinationInfo != nil, !overwrite {
      throw AgentError(
        code: "target_exists",
        message: "Destination exists and overwrite is false",
        details: ["path": .string(destination.path)],
        exitCode: 6
      )
    }
    if let destinationInfo, isDirectory(sourceInfo) || isDirectory(destinationInfo) {
      throw AgentError(
        code: "directory_overwrite_not_supported",
        message: "Replacing an existing directory is not atomic; delete it explicitly first",
        details: ["path": .string(destination.path)],
        exitCode: 6
      )
    }
    return FileTransferInspection(
      source: source,
      destination: destination,
      destinationInfo: destinationInfo,
      overwrite: overwrite,
      parents: parents
    )
  }

  func requireCopyableTree(_ root: URL) throws {
    var pending = [root]
    var inspectedCount = 0
    while let current = pending.popLast() {
      guard !Task.isCancelled else {
        throw AgentError(
          code: "operation_cancelled",
          message: "Copy source validation was cancelled",
          exitCode: 6
        )
      }
      inspectedCount += 1
      guard inspectedCount <= 100_000 else {
        throw AgentError(
          code: "file_tree_too_large",
          message: "Copy source exceeds the 100,000-entry validation limit",
          details: ["path": .string(root.path), "maximum_entries": 100_000],
          exitCode: 6
        )
      }

      let info = try itemInfo(current)
      let type = info.st_mode & mode_t(S_IFMT)
      if type == mode_t(S_IFREG) || type == mode_t(S_IFLNK) { continue }
      guard type == mode_t(S_IFDIR) else {
        throw AgentError(
          code: "unsupported_source_type",
          message:
            "Copy sources may contain only regular files, directories, and symbolic links",
          details: [
            "path": .string(current.path),
            "mode": .string(String(format: "%o", info.st_mode)),
          ],
          exitCode: 6
        )
      }

      let children: [URL]
      do {
        children = try fileManager.contentsOfDirectory(
          at: current,
          includingPropertiesForKeys: nil,
          options: []
        )
      } catch {
        throw AgentError(
          code: "path_inspection_failed",
          message: "Could not enumerate a directory in the copy source",
          details: [
            "path": .string(current.path),
            "reason": .string(String(describing: error)),
          ],
          exitCode: 5
        )
      }
      pending.append(
        contentsOf: children.map {
          current.appendingPathComponent($0.lastPathComponent, isDirectory: false)
        })
    }
  }

  func itemInfo(_ url: URL) throws -> stat {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw AgentError(
        code: "path_not_found",
        message: "Path does not exist",
        details: ["path": .string(url.path)],
        exitCode: 5
      )
    }
    return info
  }

  func optionalItemInfo(_ url: URL) throws -> stat? {
    var info = stat()
    if lstat(url.path, &info) == 0 { return info }
    if errno == ENOENT || errno == ENAMETOOLONG { return nil }
    throw AgentError(
      code: "path_inspection_failed",
      message: "Could not inspect path",
      details: ["path": .string(url.path), "errno": .integer(Int64(errno))],
      exitCode: 5
    )
  }

  func requireExistingWithoutFollowing(_ url: URL) throws {
    _ = try itemInfo(url)
  }

  func rejectFinalSymlink(_ url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
      throw AgentError(
        code: "target_symbolic_link_not_allowed",
        message: "Mutation target must not be a symbolic link",
        details: ["path": .string(url.path)], exitCode: 6)
    }
  }

  func plannedParents(for parent: URL, create: Bool) throws -> [URL] {
    if let info = try optionalItemInfo(parent) {
      try requireDirectoryInfo(info, path: parent.path)
      return []
    }
    guard create else {
      throw AgentError(
        code: "parent_directory_missing",
        message: "Parent directory does not exist",
        details: ["path": .string(parent.path)],
        exitCode: 6
      )
    }
    return try plannedDirectoryChain(to: parent, createParents: true)
  }

  func plannedDirectoryChain(to target: URL, createParents: Bool) throws -> [URL] {
    var missing: [URL] = []
    var cursor = target
    while true {
      if let info = try optionalItemInfo(cursor) {
        try requireDirectoryInfo(info, path: cursor.path)
        break
      }
      missing.append(cursor)
      let parent = cursor.deletingLastPathComponent()
      guard parent.path != cursor.path else { break }
      cursor = parent
    }
    if missing.count > 1, !createParents {
      throw AgentError(
        code: "parent_directory_missing",
        message: "Parent directory does not exist",
        details: ["path": .string(target.deletingLastPathComponent().path)],
        exitCode: 6
      )
    }
    return missing.reversed()
  }

  func pathGuard(role: String, url: URL, includeChanges: Bool = true) throws -> JSONValue {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      if errno == ENOENT {
        return .object([
          "role": .string(role),
          "path": .string(url.path),
          "state": .string("absent"),
          "track_changes": .bool(includeChanges),
        ])
      }
      throw AgentError(
        code: "path_inspection_failed",
        message: "Could not inspect mutation target",
        details: ["path": .string(url.path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }

    let type = info.st_mode & mode_t(S_IFMT)
    let kind: String
    switch type {
    case mode_t(S_IFREG): kind = "file"
    case mode_t(S_IFDIR): kind = "directory"
    case mode_t(S_IFLNK): kind = "symlink"
    default: kind = "other"
    }
    var result: [String: JSONValue] = [
      "role": .string(role),
      "path": .string(url.path),
      "state": .string("present"),
      "track_changes": .bool(includeChanges),
      "kind": .string(kind),
      "device": .string(String(info.st_dev)),
      "inode": .string(String(info.st_ino)),
      "mode": .string(String(format: "%o", info.st_mode)),
      "owner": .string(String(info.st_uid)),
      "group": .string(String(info.st_gid)),
    ]
    if includeChanges {
      let modified = fileModificationTime(info)
      let changed = fileChangeTime(info)
      result["size"] = .integer(Int64(info.st_size))
      result["link_count"] = .integer(Int64(info.st_nlink))
      result["modified_seconds"] = .integer(modified.seconds)
      result["modified_nanoseconds"] = .integer(modified.nanoseconds)
      result["changed_seconds"] = .integer(changed.seconds)
      result["changed_nanoseconds"] = .integer(changed.nanoseconds)
    }
    if includeChanges, kind == "file" || kind == "directory" || kind == "symlink" {
      let fingerprint = try FileTreeFingerprinter.snapshot(url, fileManager: fileManager)
      result["tree_state_sha256"] = .string(fingerprint.stateDigest)
      result["tree_relocated_state_sha256"] = .string(fingerprint.relocatedStateDigest)
      result["tree_content_sha256"] = .string(fingerprint.contentDigest)
      result["tree_entry_count"] = .integer(Int64(fingerprint.entryCount))
      result["tree_regular_bytes"] = .integer(fingerprint.regularBytes)
    }
    if kind == "symlink" {
      result["symlink_destination"] = .string(
        try fileManager.destinationOfSymbolicLink(atPath: url.path))
    }
    return .object(result)
  }

  private func requireSupportedTransferSource(_ info: stat, path: String) throws {
    let type = info.st_mode & mode_t(S_IFMT)
    guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) || type == mode_t(S_IFLNK) else {
      throw AgentError(
        code: "unsupported_source_type",
        message: "Copy and move sources must be a regular file, directory, or symbolic link",
        details: [
          "path": .string(path),
          "mode": .string(String(format: "%o", info.st_mode)),
        ],
        exitCode: 6
      )
    }
  }

  private func validateTransfer(source: URL, sourceInfo: stat, destination: URL) throws {
    guard source.path != destination.path else {
      throw AgentError.invalid("Source and destination resolve to the same path")
    }
    if isDirectory(sourceInfo), destination.path.hasPrefix(source.path + "/") {
      throw AgentError.invalid("A directory cannot be copied or moved inside itself")
    }
  }

  private func isDirectory(_ info: stat) -> Bool {
    (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
  }

  private func sameItem(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
  }

  private func requireDirectoryInfo(_ info: stat, path: String) throws {
    guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
      throw AgentError(
        code: "parent_not_directory",
        message: "A parent path exists but is not a directory",
        details: ["path": .string(path)],
        exitCode: 6
      )
    }
  }
}

func fileModificationTime(_ info: stat) -> (seconds: Int64, nanoseconds: Int64) {
  #if canImport(Darwin)
    return (Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec))
  #else
    return (Int64(info.st_mtim.tv_sec), Int64(info.st_mtim.tv_nsec))
  #endif
}

func fileChangeTime(_ info: stat) -> (seconds: Int64, nanoseconds: Int64) {
  #if canImport(Darwin)
    return (Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec))
  #else
    return (Int64(info.st_ctim.tv_sec), Int64(info.st_ctim.tv_nsec))
  #endif
}
