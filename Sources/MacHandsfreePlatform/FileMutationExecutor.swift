import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct FileMutationExecutor {
  private let fileManager: FileManager
  private let inspection: FileSystemInspector
  private let planner: FileMutationPlanner
  private let transfers: FileTransferExecutor

  init(
    fileManager: FileManager,
    inspection: FileSystemInspector,
    planner: FileMutationPlanner
  ) {
    self.fileManager = fileManager
    self.inspection = inspection
    self.planner = planner
    self.transfers = FileTransferExecutor(
      fileManager: fileManager,
      inspection: inspection,
      planner: planner
    )
  }

  func execute(command: CommandSpec, input: JSONValue) throws -> JSONValue {
    let object = try input.requiredObject()
    switch command.id {
    case "files.patch": return try write(FilePatch.prepare(input).writeInput.requiredObject())
    case "files.write": return try write(object)
    case "files.mkdir": return try mkdir(object)
    case "files.copy": return try transfers.copy(object)
    case "files.move": return try transfers.move(object)
    case "files.delete": return try delete(object)
    default:
      throw AgentError(
        code: "unsupported_file_command",
        message: "File mutation executor does not support the command",
        exitCode: 5
      )
    }
  }

  func executePlanned(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) throws -> JSONValue {
    try planner.validate(
      plannedPreview: plannedPreview,
      command: command,
      input: input
    )
    let validateBeforeCommit = {
      try self.planner.validateCurrentGuards(plannedPreview: plannedPreview)
    }
    let object = try input.requiredObject()
    switch command.id {
    case "files.patch":
      let patch = try FilePatch.prepare(input)
      return try write(patch.writeInput.requiredObject(), plannedPreview: plannedPreview,
                       validateBeforeCommit: validateBeforeCommit)
    case "files.write":
      return try write(
        object,
        plannedPreview: plannedPreview,
        validateBeforeCommit: validateBeforeCommit
      )
    case "files.mkdir":
      return try mkdir(object, validateBeforeCommit: validateBeforeCommit)
    case "files.copy":
      return try transfers.copy(
        object,
        plannedPreview: plannedPreview,
        validateBeforeCommit: validateBeforeCommit
      )
    case "files.move":
      return try transfers.move(
        object,
        plannedPreview: plannedPreview,
        validateBeforeCommit: validateBeforeCommit
      )
    case "files.delete":
      return try delete(
        object,
        plannedPreview: plannedPreview,
        validateBeforeCommit: validateBeforeCommit
      )
    default:
      throw AgentError(
        code: "invalid_mutation_route",
        message: "A read-only file command received mutation execution",
        details: ["command": .string(command.id)],
        exitCode: 5
      )
    }
  }

  private func write(
    _ object: [String: JSONValue],
    plannedPreview: JSONValue? = nil,
    validateBeforeCommit: () throws -> Void = {}
  ) throws -> JSONValue {
    let url = try LocalPathPolicy.expandedURL(object.requiredString("path"))
    try inspection.rejectFinalSymlink(url)
    let overwrite = object.optionalBool("overwrite")
    let createParents = object.optionalBool("create_parents")
    let plannedParents = try inspection.plannedParents(
      for: url.deletingLastPathComponent(), create: createParents)
    let existingInfo = try inspection.optionalItemInfo(url)
    if existingInfo != nil, !overwrite {
      throw AgentError(
        code: "target_exists", message: "Target exists and overwrite is false", exitCode: 6)
    }
    if let existingInfo, (existingInfo.st_mode & mode_t(S_IFMT)) != mode_t(S_IFREG) {
      throw AgentError(
        code: "target_not_regular_file",
        message: "An existing write target must be a regular file",
        details: ["path": .string(url.path)],
        exitCode: 6
      )
    }
    let raw = try object.requiredString("content")
    let encoding = object.optionalString("encoding") ?? "utf8"
    let data: Data
    if encoding == "base64" {
      guard let decoded = Data(base64Encoded: raw) else {
        throw AgentError.invalid("content is not valid base64")
      }
      data = decoded
    } else {
      data = Data(raw.utf8)
    }

    let createdParents = try PlannedDirectories.create(plannedParents)
    do {
      try AtomicFileWriter.write(
        data,
        to: url,
        replacingExisting: existingInfo != nil,
        replacementPermissions: existingInfo.map { $0.st_mode & 0o777 },
        validateBeforePublish: validateBeforeCommit,
        validateReplacedItem: { relocated in
          if let plannedPreview {
            try planner.validateRelocatedGuard(
              plannedPreview: plannedPreview,
              role: "target",
              currentURL: relocated
            )
          }
        }
      )
      try createdParents.syncParents()
    } catch {
      if (error as? AgentError)?.outcomeUncertain != true {
        try createdParents.rollback(after: error)
      }
      throw error
    }
    return .object([
      "path": .string(url.path),
      "bytes": .integer(Int64(data.count)),
      "created": .bool(existingInfo == nil),
      "replaced": .bool(existingInfo != nil),
    ])
  }

  private func mkdir(
    _ object: [String: JSONValue],
    validateBeforeCommit: () throws -> Void = {}
  ) throws -> JSONValue {
    let url = try LocalPathPolicy.expandedURL(object.requiredString("path"))
    try inspection.rejectFinalSymlink(url)
    guard !fileManager.fileExists(atPath: url.path) else {
      throw AgentError(
        code: "target_exists", message: "Directory target already exists", exitCode: 6)
    }
    let parents = object.optionalBool("parents")
    let missing = try inspection.plannedDirectoryChain(to: url, createParents: parents)
    try validateBeforeCommit()
    let created = try PlannedDirectories.create(missing)
    try created.syncParents()
    return .object(["path": .string(url.path), "created": .bool(true)])
  }

  private func delete(
    _ object: [String: JSONValue],
    plannedPreview: JSONValue? = nil,
    validateBeforeCommit: () throws -> Void = {}
  ) throws -> JSONValue {
    let url = try LocalPathPolicy.expandedURL(object.requiredString("path"))
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw AgentError(
        code: "path_not_found", message: "Path does not exist",
        details: ["path": .string(url.path)], exitCode: 5)
    }
    let recursive = object.optionalBool("recursive")
    try AtomicTreeDeleter.remove(
      url,
      info: info,
      recursive: recursive,
      fileManager: fileManager,
      validateBeforeCommit: validateBeforeCommit,
      validateDetachedItem: { relocated in
        if let plannedPreview {
          try planner.validateRelocatedGuard(
            plannedPreview: plannedPreview,
            role: "target",
            currentURL: relocated
          )
        }
      }
    )
    return .object(["path": .string(url.path), "deleted": .bool(true)])
  }

}
