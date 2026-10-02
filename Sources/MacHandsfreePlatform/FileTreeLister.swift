import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Deterministic directory traversal used by the public file-list command.
struct FileTreeLister {
  let fileManager: FileManager

  func list(
    root: URL,
    recursive: Bool,
    includeHidden: Bool,
    maximumCount: Int,
    excludingDirectories: Set<String> = []
  ) throws -> [URL] {
    var result: [URL] = []
    _ = try appendChildren(
      of: root,
      recursive: recursive,
      includeHidden: includeHidden,
      maximumCount: maximumCount,
      excludingDirectories: excludingDirectories,
      into: &result
    )
    return result
  }

  private func appendChildren(
    of directory: URL,
    recursive: Bool,
    includeHidden: Bool,
    maximumCount: Int,
    excludingDirectories: Set<String>,
    into result: inout [URL]
  ) throws -> Bool {
    try Task.checkCancellation()
    let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
    let children: [URL]
    do {
      children = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: options
      ).sorted { $0.path < $1.path }
    } catch {
      throw AgentError(
        code: "directory_enumeration_failed",
        message: "Could not enumerate directory",
        details: [
          "path": .string(directory.path),
          "reason": .string(String(describing: error)),
        ],
        exitCode: 5
      )
    }

    for child in children {
      try Task.checkCancellation()
      if excludingDirectories.contains(child.lastPathComponent), try isDirectoryWithoutFollowingLinks(child) { continue }
      result.append(child)
      if result.count >= maximumCount { return true }
      if recursive, try isDirectoryWithoutFollowingLinks(child) {
        if try appendChildren(
          of: child,
          recursive: true,
          includeHidden: includeHidden,
          maximumCount: maximumCount,
          excludingDirectories: excludingDirectories,
          into: &result
        ) {
          return true
        }
      }
    }
    return false
  }

  private func isDirectoryWithoutFollowingLinks(_ url: URL) throws -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw AgentError(
        code: "path_inspection_failed",
        message: "Could not inspect directory entry",
        details: ["path": .string(url.path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
    return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
  }
}
