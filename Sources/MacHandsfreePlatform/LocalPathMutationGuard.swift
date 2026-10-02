import Foundation
import MacHandsfreeCore

struct LocalPathGuardSpec: Sendable {
  let role: String
  let url: URL
  let trackChanges: Bool

  init(role: String, url: URL, trackChanges: Bool = true) {
    self.role = role
    self.url = url
    self.trackChanges = trackChanges
  }
}

/// Binds reviewable local paths to the exact filesystem state used by a later mutation.
/// Services declare only the paths they consume; capture and comparison stay centralized.
struct LocalPathMutationGuard: Sendable {
  private static let version = 2

  func attaching(_ specs: [LocalPathGuardSpec], to preview: JSONValue) throws -> JSONValue {
    guard !specs.isEmpty else { return preview }
    var object = try preview.requiredObject()
    object["local_path_guard_version"] = .integer(Int64(Self.version))
    object["local_path_guards"] = .array(try capture(specs))
    return .object(object)
  }

  func validate(_ plannedPreview: JSONValue, specs: [LocalPathGuardSpec]) throws {
    guard !specs.isEmpty else { return }
    guard plannedPreview["local_path_guard_version"]?.intValue == Self.version,
      let planned = plannedPreview["local_path_guards"]?.arrayValue
    else {
      throw stateChanged(
        planned: plannedPreview["local_path_guards"],
        current: nil,
        reasonCode: "plan_guard_missing"
      )
    }

    let current: [JSONValue]
    do {
      current = try capture(specs)
    } catch {
      let reasonCode = (error as? AgentError)?.code ?? "path_guard_capture_failed"
      throw stateChanged(
        planned: .array(planned),
        current: nil,
        reasonCode: reasonCode
      )
    }
    guard current == planned else {
      throw stateChanged(
        planned: .array(planned),
        current: .array(current),
        reasonCode: nil
      )
    }
  }

  func validateRelocated(
    _ plannedPreview: JSONValue,
    role: String,
    currentURL: URL
  ) throws {
    guard plannedPreview["local_path_guard_version"]?.intValue == Self.version,
      let planned = plannedPreview["local_path_guards"]?.arrayValue?.first(where: {
        $0["role"]?.stringValue == role
      }),
      let trackChanges = planned["track_changes"]?.boolValue
    else {
      throw stateChanged(
        planned: plannedPreview["local_path_guards"],
        current: nil,
        reasonCode: "plan_guard_missing"
      )
    }

    let current: JSONValue
    do {
      current = try FileSystemInspector().pathGuard(
        role: role,
        url: currentURL,
        includeChanges: trackChanges
      )
    } catch {
      throw stateChanged(
        planned: planned,
        current: nil,
        reasonCode: (error as? AgentError)?.code ?? "path_guard_capture_failed"
      )
    }
    guard RelocatedPathGuard.comparable(planned) == RelocatedPathGuard.comparable(current) else {
      throw stateChanged(planned: planned, current: current, reasonCode: "relocated_path_mismatch")
    }
  }

  private func capture(_ specs: [LocalPathGuardSpec]) throws -> [JSONValue] {
    var roles = Set<String>()
    var values: [JSONValue] = []
    values.reserveCapacity(specs.count)
    for spec in specs {
      guard roles.insert(spec.role).inserted else {
        throw AgentError(
          code: "duplicate_path_guard_role",
          message: "A local path guard role must be unique within one mutation",
          details: ["role": .string(spec.role)],
          exitCode: 5
        )
      }
      values.append(
        try FileSystemInspector().pathGuard(
          role: spec.role,
          url: spec.url,
          includeChanges: spec.trackChanges
        ))
    }
    return values
  }

  private func stateChanged(
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
      message: "A local path used by the mutation changed after the plan was created",
      details: details,
      exitCode: 6
    )
  }
}

enum RelocatedPathGuard {
  private static let stableFields = [
    "state",
    "track_changes",
    "kind",
    "device",
    "inode",
    "mode",
    "owner",
    "group",
    "size",
    "link_count",
    "modified_seconds",
    "modified_nanoseconds",
    "tree_relocated_state_sha256",
    "tree_content_sha256",
    "tree_entry_count",
    "tree_regular_bytes",
    "symlink_destination",
  ]

  static func comparable(_ guardValue: JSONValue) -> JSONValue {
    guard let object = guardValue.objectValue else { return guardValue }
    return .object(
      Dictionary(
        uniqueKeysWithValues: stableFields.compactMap { key in
          object[key].map { (key, $0) }
        }
      )
    )
  }
}
