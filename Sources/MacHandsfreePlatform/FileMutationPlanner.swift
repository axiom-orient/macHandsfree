import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct FileMutationPlanner {
  private static let guardVersion = 3

  private let fileManager: FileManager
  private let inspection: FileSystemInspector

  init(fileManager: FileManager, inspection: FileSystemInspector) {
    self.fileManager = fileManager
    self.inspection = inspection
  }

  func preview(command: CommandSpec, input: JSONValue) throws -> JSONValue {
    let object = try input.requiredObject()
    switch command.id {
    case "files.patch":
      let target = try LocalPathPolicy.requireRegularFile(object.requiredString("path"))
      let before = try inspection.pathGuard(role: "patch_source", url: target)
      let patch = try FilePatch.prepare(input)
      var result = try preview(command: FilePatch.writeCommand(), input: patch.writeInput).requiredObject()
      guard before == (try inspection.pathGuard(role: "patch_source", url: target)) else {
        throw AgentError(code: "plan_state_changed", message: "File changed while preparing its diff", exitCode: 6)
      }
      result["diff"] = .string(patch.diff)
      return .object(result)
    case "files.write":
      let target = try LocalPathPolicy.expandedURL(object.requiredString("path"))
      try inspection.rejectFinalSymlink(target)
      let createParents = object.optionalBool("create_parents")
      let overwrite = object.optionalBool("overwrite")
      let parents = try inspection.plannedParents(
        for: target.deletingLastPathComponent(), create: createParents)
      let existingInfo = try inspection.optionalItemInfo(target)
      if existingInfo != nil, !overwrite {
        throw AgentError(
          code: "target_exists", message: "Target exists and overwrite is false",
          details: ["path": .string(target.path)], exitCode: 6)
      }
      if let existingInfo, (existingInfo.st_mode & mode_t(S_IFMT)) != mode_t(S_IFREG) {
        throw AgentError(
          code: "target_not_regular_file",
          message: "An existing write target must be a regular file",
          details: ["path": .string(target.path)],
          exitCode: 6
        )
      }
      let anchor = parents.first?.deletingLastPathComponent() ?? target.deletingLastPathComponent()
      return guardedEffects(
        parents.map { effect("create_directory", $0.path) } + [
          effect("write_file", target.path, details: ["overwrite": .bool(overwrite)])
        ],
        guards: [
          try inspection.pathGuard(role: "target", url: target),
          try inspection.pathGuard(role: "parent_anchor", url: anchor, includeChanges: false),
        ])
    case "files.mkdir":
      let target = try LocalPathPolicy.expandedURL(object.requiredString("path"))
      try inspection.rejectFinalSymlink(target)
      if fileManager.fileExists(atPath: target.path) {
        throw AgentError(
          code: "target_exists", message: "Directory target already exists",
          details: ["path": .string(target.path)], exitCode: 6)
      }
      let parents = object.optionalBool("parents")
      let missing = try inspection.plannedDirectoryChain(to: target, createParents: parents)
      let anchor = missing.first?.deletingLastPathComponent() ?? target.deletingLastPathComponent()
      return guardedEffects(
        missing.map { effect("create_directory", $0.path) },
        guards: [
          try inspection.pathGuard(role: "target", url: target),
          try inspection.pathGuard(role: "parent_anchor", url: anchor, includeChanges: false),
        ])
    case "files.copy", "files.move":
      let transfer = try inspection.inspectTransfer(object)
      if command.id == "files.copy" { try inspection.requireCopyableTree(transfer.source) }
      let action = command.id == "files.copy" ? "copy" : "move"
      let anchor =
        transfer.parents.first?.deletingLastPathComponent()
        ?? transfer.destination.deletingLastPathComponent()
      return guardedEffects(
        transfer.parents.map { effect("create_directory", $0.path) } + [
          effect(
            action, transfer.source.path,
            details: [
              "destination": .string(transfer.destination.path),
              "overwrite": .bool(transfer.overwrite),
            ])
        ],
        guards: [
          try inspection.pathGuard(role: "source", url: transfer.source),
          try inspection.pathGuard(role: "destination", url: transfer.destination),
          try inspection.pathGuard(
            role: "destination_parent_anchor", url: anchor, includeChanges: false),
        ])
    case "files.delete":
      let target = try LocalPathPolicy.expandedURL(object.requiredString("path"))
      let targetInfo = try inspection.itemInfo(target)
      let recursive = object.optionalBool("recursive")
      if (targetInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), !recursive {
        let contents = try fileManager.contentsOfDirectory(atPath: target.path)
        guard contents.isEmpty else {
          throw AgentError(
            code: "directory_not_empty",
            message: "Directory is not empty and recursive is false",
            exitCode: 6
          )
        }
      }
      return guardedEffects(
        [
          effect(
            "delete", target.path,
            details: ["recursive": .bool(recursive)])
        ],
        guards: [
          try inspection.pathGuard(role: "target", url: target),
          try inspection.pathGuard(
            role: "parent", url: target.deletingLastPathComponent(), includeChanges: false),
        ])
    default:
      throw AgentError(
        code: "preview_not_supported", message: "This file command is read-only", exitCode: 5)
    }
  }

  func validate(
    plannedPreview: JSONValue,
    command: CommandSpec,
    input: JSONValue
  ) throws {
    guard plannedPreview["guard_version"]?.intValue == Self.guardVersion else {
      throw planStateChanged(
        planned: plannedPreview["guards"],
        current: nil,
        reasonCode: "plan_guard_missing"
      )
    }

    let currentPreview: JSONValue
    do {
      currentPreview = try preview(command: command, input: input)
    } catch let error as AgentError {
      throw planStateChanged(
        planned: plannedPreview["guards"],
        current: nil,
        reasonCode: error.code
      )
    }

    guard currentPreview["guard_version"]?.intValue == Self.guardVersion,
      currentPreview["guards"] == plannedPreview["guards"]
    else {
      throw planStateChanged(
        planned: plannedPreview["guards"],
        current: currentPreview["guards"],
        reasonCode: nil
      )
    }
  }

  /// Rechecks only the immutable guard set captured by the plan. Unlike `validate`, this
  /// remains valid after intentional preparatory effects such as creating planned parents.
  func validateCurrentGuards(plannedPreview: JSONValue) throws {
    guard plannedPreview["guard_version"]?.intValue == Self.guardVersion,
      let plannedGuards = plannedPreview["guards"]?.arrayValue
    else {
      throw planStateChanged(
        planned: plannedPreview["guards"],
        current: nil,
        reasonCode: "plan_guard_missing"
      )
    }

    var currentGuards: [JSONValue] = []
    currentGuards.reserveCapacity(plannedGuards.count)
    do {
      for guardValue in plannedGuards {
        guard let guardObject = guardValue.objectValue,
          let role = guardObject["role"]?.stringValue,
          let path = guardObject["path"]?.stringValue,
          let trackChanges = guardObject["track_changes"]?.boolValue
        else {
          throw planStateChanged(
            planned: .array(plannedGuards),
            current: nil,
            reasonCode: "plan_guard_malformed"
          )
        }
        currentGuards.append(
          try inspection.pathGuard(
            role: role,
            url: URL(fileURLWithPath: path),
            includeChanges: trackChanges
          ))
      }
    } catch let error as AgentError where error.code == "plan_state_changed" {
      throw error
    } catch let error as AgentError {
      throw planStateChanged(
        planned: .array(plannedGuards),
        current: .array(currentGuards),
        reasonCode: error.code
      )
    }

    guard currentGuards == plannedGuards else {
      throw planStateChanged(
        planned: .array(plannedGuards),
        current: .array(currentGuards),
        reasonCode: nil
      )
    }
  }

  func validateStagedCopy(plannedPreview: JSONValue, stagedURL: URL) throws {
    guard let guards = plannedPreview["guards"]?.arrayValue,
      let source = guards.first(where: { $0["role"]?.stringValue == "source" }),
      let plannedDigest = source["tree_content_sha256"]?.stringValue
    else {
      throw planStateChanged(
        planned: plannedPreview["guards"],
        current: nil,
        reasonCode: "plan_guard_missing"
      )
    }
    let staged = try inspection.pathGuard(role: "staged_copy", url: stagedURL)
    guard staged["tree_content_sha256"]?.stringValue == plannedDigest else {
      throw planStateChanged(
        planned: source,
        current: staged,
        reasonCode: "staged_copy_mismatch"
      )
    }
  }

  func validateRelocatedGuard(
    plannedPreview: JSONValue,
    role: String,
    currentURL: URL
  ) throws {
    guard let guards = plannedPreview["guards"]?.arrayValue,
      let planned = guards.first(where: { $0["role"]?.stringValue == role }),
      let trackChanges = planned["track_changes"]?.boolValue
    else {
      throw planStateChanged(
        planned: plannedPreview["guards"],
        current: nil,
        reasonCode: "plan_guard_missing"
      )
    }
    let current: JSONValue
    do {
      current = try inspection.pathGuard(
        role: role,
        url: currentURL,
        includeChanges: trackChanges
      )
    } catch let error as AgentError {
      throw planStateChanged(
        planned: planned,
        current: nil,
        reasonCode: error.code
      )
    }
    guard RelocatedPathGuard.comparable(planned) == RelocatedPathGuard.comparable(current) else {
      throw planStateChanged(
        planned: planned,
        current: current,
        reasonCode: "relocated_path_mismatch"
      )
    }
  }

  private func guardedEffects(_ values: [JSONValue], guards: [JSONValue]) -> JSONValue {
    .object([
      "effects": .array(values),
      "guard_version": .integer(Int64(Self.guardVersion)),
      "guards": .array(guards),
    ])
  }

  private func planStateChanged(
    planned: JSONValue?,
    current: JSONValue?,
    reasonCode: String?
  ) -> AgentError {
    var details: [String: JSONValue] = [:]
    if let planned { details["planned_guards"] = FileTreeGuardPresentation.publicValue(planned) }
    if let current { details["current_guards"] = FileTreeGuardPresentation.publicValue(current) }
    if let reasonCode { details["reason_code"] = .string(reasonCode) }
    return AgentError(
      code: "plan_state_changed",
      message: "The file mutation target changed after the plan was created",
      details: details,
      exitCode: 6
    )
  }
}
