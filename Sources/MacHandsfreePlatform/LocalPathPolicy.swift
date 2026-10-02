import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct ValidatedOutputFile: Sendable {
  let url: URL
  let existed: Bool
  let replacementPermissions: mode_t?
}

enum LocalPathPolicy {
  static func expandedURL(_ raw: String) throws -> URL {
    let expanded = NSString(string: raw).expandingTildeInPath
    guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
      throw AgentError.invalid(
        "Path must be absolute or start with ~/",
        details: ["path": .string(raw)]
      )
    }
    return URL(fileURLWithPath: expanded).standardizedFileURL
  }

  static func requireExisting(_ raw: String) throws -> URL {
    let url = try expandedURL(raw)
    _ = try itemInfo(url)
    return url
  }

  static func requireRegularFile(_ raw: String) throws -> URL {
    let url = try expandedURL(raw)
    let info = try itemInfo(url)
    guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
      throw AgentError(
        code: "not_regular_file",
        message: "Path is not a regular file or is a symbolic link",
        details: ["path": .string(url.path)],
        exitCode: 5
      )
    }
    return url
  }

  static func validateOutputFile(_ raw: String, overwrite: Bool) throws -> ValidatedOutputFile {
    let url = try expandedURL(raw)
    let parent = url.deletingLastPathComponent()
    let parentAttributes = try attributes(parent)
    guard parentAttributes[.type] as? FileAttributeType == .typeDirectory else {
      throw AgentError(
        code: "parent_not_directory",
        message: "Output parent is not a directory",
        details: ["path": .string(parent.path)],
        exitCode: 6
      )
    }

    var targetInfo = stat()
    let existed: Bool
    let replacementPermissions: mode_t?
    if lstat(url.path, &targetInfo) == 0 {
      existed = true
      replacementPermissions = targetInfo.st_mode & 0o777
      let type = targetInfo.st_mode & mode_t(S_IFMT)
      guard type != mode_t(S_IFLNK) else {
        throw AgentError(
          code: "target_symbolic_link_not_allowed",
          message: "Output target must not be a symbolic link",
          details: ["path": .string(url.path)],
          exitCode: 6
        )
      }
      guard type == mode_t(S_IFREG) else {
        throw AgentError(
          code: "output_target_not_file",
          message: "Output target exists and is not a regular file",
          details: ["path": .string(url.path)],
          exitCode: 6
        )
      }
      guard overwrite else {
        throw AgentError(
          code: "target_exists",
          message: "Output target exists and overwrite is false",
          details: ["path": .string(url.path)],
          exitCode: 6
        )
      }
    } else if errno == ENOENT {
      existed = false
      replacementPermissions = nil
    } else {
      throw AgentError(
        code: "path_inspection_failed",
        message: "Output target could not be inspected",
        details: ["path": .string(url.path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
    return ValidatedOutputFile(
      url: url,
      existed: existed,
      replacementPermissions: replacementPermissions
    )
  }

  static func replacingPath(_ input: JSONValue, key: String, with url: URL) throws -> JSONValue {
    var object = try input.requiredObject()
    object[key] = .string(url.path)
    return .object(object)
  }

  static func replacingPaths(_ input: JSONValue, key: String, with urls: [URL]) throws -> JSONValue
  {
    var object = try input.requiredObject()
    object[key] = .array(urls.map { .string($0.path) })
    return .object(object)
  }

  private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any] {
    do {
      return try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
      throw AgentError(
        code: "path_not_found",
        message: "Path does not exist or cannot be inspected",
        details: ["path": .string(url.path), "reason": .string(String(describing: error))],
        exitCode: 5
      )
    }
  }

  private static func itemInfo(_ url: URL) throws -> stat {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw AgentError(
        code: "path_not_found",
        message: "Path does not exist or cannot be inspected",
        details: ["path": .string(url.path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
    return info
  }
}
