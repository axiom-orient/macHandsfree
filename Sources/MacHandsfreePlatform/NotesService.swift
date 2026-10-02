import Foundation
import MacHandsfreeCore
import MacHandsfreeSQLite

struct NotesService: CurrentStateValidatedCommandService {
  private static let maximumSnapshotBytes = 256 * 1_024
  private static let maximumStructuralEntities = 500
  private static let structuralCommands: Set<String> = [
    "notes.items.move", "notes.items.delete", "notes.folders.delete",
    "notes.items.create", "notes.folders.create",
  ]
  let name = "notes"
  private let runner: any AppleEventsRunning
  private let localPathGuard: LocalPathMutationGuard

  init(
    runner: any AppleEventsRunning,
    localPathGuard: LocalPathMutationGuard = LocalPathMutationGuard()
  ) {
    self.runner = runner
    self.localPathGuard = localPathGuard
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    let normalized = try normalizedInput(command: command, input: input)
    let object = try normalized.requiredObject()
    let preview: JSONValue
    if command.id == "notes.items.export" {
      preview = effects([
        effect(
          "export_note",
          try object.requiredString("path"),
          details: [
            "note_id": .string(try object.requiredString("note_id")),
            "format": .string(try object.requiredString("format")),
            "overwrite": .bool(object.optionalBool("overwrite")),
          ]
        )
      ])
    } else {
      let target =
        object["note_id"]?.stringValue
        ?? object["folder_id"]?.stringValue
        ?? object["account_id"]?.stringValue
        ?? object["path"]?.stringValue
        ?? "Notes"
      var details: [String: JSONValue] = [:]
      if command.id == "notes.items.delete" {
        details["recovery_warning"] = .string(
          "Recovery depends on the Notes account; deletion may be permanent.")
      } else if command.id == "notes.folders.delete" {
        details["recovery_warning"] = .string(
          "Recovery of this folder's notes depends on the Notes account; deletion may be permanent.")
      }
      preview = effects([effect(command.id, target, details: details)])
    }
    let guardedPreview = try localPathGuard.attaching(
      pathGuardSpecs(command: command, input: normalized),
      to: preview
    )
    if Self.structuralCommands.contains(command.id) {
      if command.id == "notes.folders.delete" {
        try validateDeletableNotesFolder(try object.requiredString("folder_id"))
      }
      let request = try structuralSnapshotRequest(commandID: command.id, input: object)
      let fetched = try await runner.run(
        script: "notes",
        operation: request.operation,
        input: request.input,
        mutation: false
      )
      let expectedNotesState = try structuralSnapshot(
        fetched["mutation_snapshot"], commandID: command.id, input: object)
      var previewDetails: [String: JSONValue] = [:]
      if command.id == "notes.folders.delete" {
        guard let target = expectedNotesState.objectValue?["target"]?.objectValue,
          let root = target["root"]?.objectValue,
          let folders = target["folders"]?.arrayValue,
          let notes = target["notes"]?.arrayValue
        else { throw invalidUpdatePreview("The Notes folder delete impact is unavailable") }
        previewDetails["affected_folder_count"] = .integer(Int64(folders.count))
        previewDetails["affected_note_count"] = .integer(Int64(notes.count))
        let hasSharedImpact = root["shared"]?.boolValue == true
          || root["shared_ancestor"]?.boolValue == true
          || folders.contains { $0.objectValue?["shared"]?.boolValue == true }
          || notes.contains { $0.objectValue?["shared"]?.boolValue == true }
        if hasSharedImpact {
          previewDetails["shared_effect_warning"] = .string(
            "The target, its contents, or a parent folder is shared. Deletion may affect collaborators; SEMI cannot determine your sharing role.")
        }
      } else if command.id == "notes.items.delete",
        let target = expectedNotesState.objectValue?["target"]?.objectValue,
        (target["shared_ancestor"]?.boolValue == true
          || target["note"]?["shared"]?.boolValue == true
          || target["source_folder"]?["shared"]?.boolValue == true)
      {
        previewDetails["shared_effect_warning"] = .string(
          "The note or its source folder hierarchy is shared. Deletion may affect collaborators; SEMI cannot determine your sharing role.")
      }
      let previewWithImpact = previewDetails.isEmpty
        ? guardedPreview
        : try addingEffectDetails(previewDetails, to: guardedPreview)
      if command.id == "notes.items.delete" {
        try validateDeletableNotesItem(
          try object.requiredString("note_id"),
          expectedFolderID: try notesItemFolderID(expectedNotesState))
      }
      var result = try previewWithImpact.requiredObject()
      result["expected_notes_state"] = expectedNotesState
      return .object(result)
    }
    if command.id == "notes.items.export" {
      let snapshot = try await readExportSnapshot(object)
      var result = try guardedPreview.requiredObject()
      result["expected_export"] = snapshot
      return .object(result)
    }
    guard command.id == "notes.items.update" else { return guardedPreview }
    let noteID = try object.requiredString("note_id")
    let fetched = try await runner.run(
      script: "notes",
      operation: "notes.items.get",
      input: .object(["note_id": .string(noteID), "snapshot_for_update": .bool(true)]),
      mutation: false
    )
    let snapshot = try updateSnapshot(fetched["update_snapshot"], noteID: noteID)
    var result = try guardedPreview.requiredObject()
    result["expected_note"] = snapshot
    return .object(result)
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    guard command.kind == .read else {
      throw invalidUpdatePreview("This Notes mutation requires the snapshot from a reviewed plan")
    }
    let normalized = try normalizedInput(command: command, input: input)
    return try await runner.run(
      script: "notes",
      operation: command.id,
      input: normalized,
      mutation: false
    )
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    guard command.kind == .mutation else {
      throw AgentError(code: "invalid_mutation_route", message: "A read-only Notes command received mutation execution", exitCode: 5)
    }
    let specs = try pathGuardSpecs(command: command, input: input)
    try localPathGuard.validate(plannedPreview, specs: specs)
    let normalized = try normalizedInput(command: command, input: input)
    if Self.structuralCommands.contains(command.id) {
      var object = try normalized.requiredObject()
      if command.id == "notes.folders.delete" {
        try validateDeletableNotesFolder(try object.requiredString("folder_id"))
      }
      let expectedNotesState = try structuralSnapshot(
        plannedPreview["expected_notes_state"], commandID: command.id, input: object)
      if command.id == "notes.items.delete" {
        try validateDeletableNotesItem(
          try object.requiredString("note_id"),
          expectedFolderID: try notesItemFolderID(expectedNotesState))
      }
      object["expected_notes_state"] = expectedNotesState
      return try await runner.run(script: "notes", operation: command.id, input: .object(object), mutation: true)
    }
    if command.id == "notes.items.update" {
      var object = try normalized.requiredObject()
      let noteID = try object.requiredString("note_id")
      object["expected_note"] = try updateSnapshot(plannedPreview["expected_note"], noteID: noteID)
      return try await runner.run(
        script: "notes",
        operation: command.id,
        input: .object(object),
        mutation: true
      )
    }
    if command.id == "notes.items.export" {
      let object = try normalized.requiredObject()
      let expected = try exportSnapshot(plannedPreview["expected_export"], input: object)
      return try await export(
        normalized,
        expected: expected,
        validateBeforePublish: {
          try requireNotCancelled()
          try localPathGuard.validate(plannedPreview, specs: specs)
        },
        validateReplacedOutput: { relocated in
          try localPathGuard.validateRelocated(
            plannedPreview,
            role: "output",
            currentURL: relocated
          )
        }
      )
    }
    throw AgentError(code: "unsupported_notes_mutation",
      message: "This Notes mutation has no reviewed execution route", exitCode: 5)
  }

  private func validateDeletableNotesFolder(_ folderID: String) throws {
    guard let reference = NotesStoreReference(folderID, entityName: "ICFolder") else {
      throw notesFolderTypeUnavailable(folderID)
    }
    do {
      let database = try SQLiteDatabase(path: Self.notesStorePath, readOnly: true)
      let rows = try database.query(
        """
        SELECT m.Z_UUID AS store_uuid, f.ZFOLDERTYPE AS folder_type,
               f.ZMARKEDFORDELETION AS marked_for_deletion, f.ZIDENTIFIER AS identifier
        FROM Z_METADATA m
        JOIN Z_PRIMARYKEY p ON p.Z_NAME = ?
        JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_ENT = p.Z_ENT AND f.Z_PK = ?
        LIMIT 2
        """,
        values: [.text("ICFolder"), .integer(reference.primaryKey)])
      guard rows.count == 1,
        let storeUUID = rows[0]["store_uuid"]?.text,
        NotesStoreReference.normalizedUUID(storeUUID) == reference.storeUUID,
        let folderType = rows[0]["folder_type"]?.integer,
        let identifier = rows[0]["identifier"]?.text, !identifier.isEmpty
      else { throw notesFolderTypeUnavailable(folderID) }
      let normalizedIdentifier = identifier.lowercased()
      guard folderType == 0,
        !normalizedIdentifier.hasPrefix("trashfolder"),
        !normalizedIdentifier.hasPrefix("defaultfolder")
      else {
        throw AgentError(
          code: "notes_folder_not_deletable",
          message: "Only ordinary, non-default Notes folders may be deleted through SEMI.",
          details: ["folder_id": .string(folderID)], exitCode: 6)
      }
      guard (rows[0]["marked_for_deletion"]?.integer ?? 0) == 0 else {
        throw notesFolderTypeUnavailable(folderID)
      }
    } catch let error as AgentError where error.code == "notes_folder_not_deletable" {
      throw error
    } catch {
      throw notesFolderTypeUnavailable(folderID)
    }
  }

  private func validateDeletableNotesItem(_ noteID: String, expectedFolderID: String) throws {
    guard let note = NotesStoreReference(noteID, entityName: "ICNote"),
      let expectedFolder = NotesStoreReference(expectedFolderID, entityName: "ICFolder"),
      note.storeUUID == expectedFolder.storeUUID
    else { throw notesItemStateUnavailable(noteID) }

    do {
      let database = try SQLiteDatabase(path: Self.notesStorePath, readOnly: true)
      let rows = try database.query(
        """
        SELECT m.Z_UUID AS store_uuid, n.ZMARKEDFORDELETION AS note_marked_for_deletion,
               f.Z_PK AS folder_primary_key, f.ZFOLDERTYPE AS folder_type,
               f.ZMARKEDFORDELETION AS folder_marked_for_deletion,
               f.ZIDENTIFIER AS folder_identifier
        FROM Z_METADATA m
        JOIN Z_PRIMARYKEY note_entity ON note_entity.Z_NAME = ?
        JOIN ZICCLOUDSYNCINGOBJECT n
          ON n.Z_ENT = note_entity.Z_ENT AND n.Z_PK = ?
        JOIN Z_PRIMARYKEY folder_entity ON folder_entity.Z_NAME = ?
        JOIN ZICCLOUDSYNCINGOBJECT f
          ON f.Z_ENT = folder_entity.Z_ENT AND f.Z_PK = n.ZFOLDER
        LIMIT 2
        """,
        values: [
          .text("ICNote"), .integer(note.primaryKey), .text("ICFolder"),
        ])
      guard rows.count == 1,
        let storeUUID = rows[0]["store_uuid"]?.text,
        NotesStoreReference.normalizedUUID(storeUUID) == note.storeUUID,
        let folderType = rows[0]["folder_type"]?.integer
      else { throw notesItemStateUnavailable(noteID) }
      let isTrash = folderType == 1
        || rows[0]["folder_identifier"]?.text?.lowercased().hasPrefix("trashfolder") == true
      if isTrash {
        throw AgentError(
          code: "notes_note_in_trash",
          message: "A note in Recently Deleted cannot be deleted again through SEMI.",
          details: ["note_id": .string(noteID)], exitCode: 6)
      }
      guard folderType == 0,
        let folderIdentifier = rows[0]["folder_identifier"]?.text, !folderIdentifier.isEmpty,
        (rows[0]["note_marked_for_deletion"]?.integer ?? 0) == 0,
        rows[0]["folder_primary_key"]?.integer == expectedFolder.primaryKey,
        (rows[0]["folder_marked_for_deletion"]?.integer ?? 0) == 0
      else { throw notesItemStateUnavailable(noteID) }
    } catch let error as AgentError
      where error.code == "notes_note_in_trash" || error.code == "notes_note_state_unavailable"
    {
      throw error
    } catch {
      throw notesItemStateUnavailable(noteID)
    }
  }

  private func notesItemFolderID(_ snapshot: JSONValue) throws -> String {
    guard let target = snapshot.objectValue?["target"]?.objectValue,
      let note = target["note"]?.objectValue,
      let content = note["content"]?.objectValue,
      let folderID = content["folder_id"]?.stringValue
    else { throw invalidUpdatePreview("The Notes delete snapshot has no exact source folder") }
    return folderID
  }

  private func addingEffectDetails(
    _ additions: [String: JSONValue], to preview: JSONValue
  ) throws -> JSONValue {
    guard var result = preview.objectValue,
      var values = result["effects"]?.arrayValue,
      let first = values.first,
      var effect = first.objectValue,
      var details = effect["details"]?.objectValue
    else { throw invalidUpdatePreview("The Notes effect preview is missing") }
    additions.forEach { details[$0.key] = $0.value }
    effect["details"] = .object(details)
    values[0] = .object(effect)
    result["effects"] = .array(values)
    return .object(result)
  }

  private static var notesStorePath: String {
    NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
  }

  private func notesFolderTypeUnavailable(_ folderID: String) -> AgentError {
    AgentError(
      code: "notes_folder_type_unavailable",
      message:
        "Could not verify the Notes folder type. Check Full Disk Access and the NoteStore schema; " +
        "nothing was deleted.",
      details: ["folder_id": .string(folderID)], exitCode: 6)
  }

  private func notesItemStateUnavailable(_ noteID: String) -> AgentError {
    AgentError(
      code: "notes_note_state_unavailable",
      message:
        "Could not match NoteStore state to the exact Notes folder snapshot; delete was refused.",
      details: ["note_id": .string(noteID)], exitCode: 6)
  }

  private func structuralSnapshotRequest(commandID: String, input: [String: JSONValue]) throws
    -> (operation: String, input: JSONValue)
  {
    var selectors: [String: JSONValue] = ["snapshot_for_mutation": .string(commandID)]
    switch commandID {
    case "notes.items.move", "notes.items.delete":
      selectors["note_id"] = .string(try input.requiredString("note_id"))
      if commandID == "notes.items.move" {
        if let accountID = input["account_id"]?.stringValue {
          selectors["account_id"] = .string(accountID)
        } else {
          selectors["folder_id"] = .string(try input.requiredString("folder_id"))
        }
      }
      return ("notes.items.get", .object(selectors))
    case "notes.items.create":
      if let accountID = input["account_id"]?.stringValue {
        selectors["account_id"] = .string(accountID)
      } else {
        selectors["folder_id"] = .string(try input.requiredString("folder_id"))
      }
      return ("notes.folders.list", .object(selectors))
    case "notes.folders.delete":
      selectors["folder_id"] = .string(try input.requiredString("folder_id"))
      return ("notes.folders.list", .object(selectors))
    case "notes.folders.create":
      selectors["account_id"] = .string(try input.requiredString("account_id"))
      if let parent = input["parent_folder_id"] { selectors["parent_folder_id"] = parent }
    default:
      throw invalidUpdatePreview("Unknown Notes snapshot request")
    }
    return ("notes.folders.list", .object(selectors))
  }

  private func structuralSnapshot(_ value: JSONValue?, commandID: String, input: [String: JSONValue]) throws -> JSONValue {
    let expectedVersion: Int64
    switch commandID {
    case "notes.folders.delete": expectedVersion = 3
    case "notes.items.delete": expectedVersion = 2
    default: expectedVersion = 1
    }
    guard let value, let snapshot = value.objectValue,
      Set(snapshot.keys) == Set(["version", "command", "target"]),
      snapshot["version"] == .integer(Int64(expectedVersion)),
      snapshot["command"]?.stringValue == commandID,
      let target = snapshot["target"]?.objectValue
    else { throw invalidUpdatePreview("The Notes mutation snapshot is missing or malformed") }
    if commandID == "notes.items.create" {
      guard let accountID = target["account"]?["account_id"]?.stringValue, !accountID.isEmpty,
        let destinationFolder = target["destination_folder"]?.objectValue,
        let destinationFolderID = destinationFolder["folder_id"]?.stringValue,
        !destinationFolderID.isEmpty,
        destinationFolder["account_id"]?.stringValue == accountID
      else { throw invalidUpdatePreview("The Notes creation destination is missing or inconsistent") }
      if let selectedAccount = input["account_id"]?.stringValue {
        guard selectedAccount == accountID,
          target["destination_is_default"]?.boolValue == true,
          destinationFolder["container_id"]?.stringValue == accountID
        else { throw invalidUpdatePreview("The Notes default-folder destination does not match the selected account") }
      } else {
        guard destinationFolderID == input["folder_id"]?.stringValue else {
          throw invalidUpdatePreview("The Notes creation folder does not match the selected destination")
        }
        guard target["destination_is_default"] != .bool(true) else {
          throw invalidUpdatePreview("The Notes folder destination has an unexpected default-folder marker")
        }
      }
    } else if commandID == "notes.folders.create" {
      guard target["account"]?["account_id"]?.stringValue == input["account_id"]?.stringValue else {
        throw invalidUpdatePreview("The Notes folder creation account does not match")
      }
      if let parentID = input["parent_folder_id"]?.stringValue {
        guard target["parent_folder"]?["folder_id"]?.stringValue == parentID,
          target["parent_folder"]?["account_id"]?.stringValue == input["account_id"]?.stringValue
        else { throw invalidUpdatePreview("The Notes parent folder does not match") }
      } else if target["parent_folder"] != .null {
        throw invalidUpdatePreview("The Notes folder plan unexpectedly selects a parent folder")
      }
    } else if commandID == "notes.folders.delete" {
      guard let root = target["root"]?.objectValue,
        root["folder_id"]?.stringValue == input["folder_id"]?.stringValue,
        root["shared"]?.boolValue != nil,
        let isDefaultFolder = root["is_default_folder"]?.boolValue,
        root["shared_ancestor"]?.boolValue != nil,
        let folders = target["folders"]?.arrayValue,
        let notes = target["notes"]?.arrayValue,
        folders.allSatisfy({ $0.objectValue?["shared"]?.boolValue != nil }),
        notes.allSatisfy({ $0.objectValue?["shared"]?.boolValue != nil })
      else {
        throw invalidUpdatePreview("The Notes folder delete snapshot is incomplete")
      }
      guard !isDefaultFolder else {
        throw AgentError(
          code: "notes_folder_not_deletable",
          message: "The account's default Notes folder cannot be deleted through SEMI.",
          details: ["folder_id": .string(try input.requiredString("folder_id"))], exitCode: 6)
      }
      guard !folders.isEmpty,
        folders.count + notes.count <= Self.maximumStructuralEntities
      else { throw invalidUpdatePreview("The Notes folder snapshot is incomplete or oversized") }
    } else {
      guard target["note"]?["content"]?["note_id"]?.stringValue == input["note_id"]?.stringValue,
        target["source_folder"]?["folder_id"]?.stringValue
          == target["note"]?["content"]?["folder_id"]?.stringValue,
        target["source_folder"]?.objectValue != nil
      else { throw invalidUpdatePreview("The Notes item snapshot does not match the requested target") }
      guard let note = target["note"]?.objectValue,
        let attachments = note["attachments"]?.arrayValue,
        attachments.count + 1 <= Self.maximumStructuralEntities
      else { throw invalidUpdatePreview("The Notes item snapshot is incomplete or oversized") }
      if commandID == "notes.items.delete" {
        guard target["shared_ancestor"]?.boolValue != nil,
          target["note"]?["shared"]?.boolValue != nil,
          target["source_folder"]?["shared"]?.boolValue != nil
        else { throw invalidUpdatePreview("The Notes delete sharing impact is missing") }
      }
      if commandID == "notes.items.move" {
        if let accountID = input["account_id"]?.stringValue {
          guard target["destination_is_default"]?.boolValue == true,
            target["destination_folder"]?["account_id"]?.stringValue == accountID,
            target["destination_folder"]?["container_id"]?.stringValue == accountID
          else {
            throw invalidUpdatePreview("The Notes default-folder destination does not match the selected account")
          }
        } else {
          guard target["destination_folder"]?["folder_id"]?.stringValue == input["folder_id"]?.stringValue else {
            throw invalidUpdatePreview("The Notes destination snapshot does not match the requested folder")
          }
          guard target["destination_is_default"] != .bool(true) else {
            throw invalidUpdatePreview("The Notes folder destination has an unexpected default-folder marker")
          }
        }
      } else if target["destination_folder"] != .null {
        throw invalidUpdatePreview("The Notes delete snapshot unexpectedly has a destination")
      }
    }
    guard try value.encoded().count <= Self.maximumSnapshotBytes else {
      throw AgentError(code: "notes_mutation_snapshot_too_large",
        message: "The Notes mutation snapshot exceeds its limit; it was not truncated",
        details: ["maximum_bytes": .integer(Int64(Self.maximumSnapshotBytes))], exitCode: 6)
    }
    return value
  }

  private func readExportSnapshot(_ input: [String: JSONValue]) async throws -> JSONValue {
    try requireNotCancelled()
    let result = try await runner.run(
      script: "notes", operation: "notes.items.get",
      input: .object([
        "note_id": .string(try input.requiredString("note_id")),
        "format": .string(try input.requiredString("format")),
        "snapshot_for_export": .bool(true),
      ]), mutation: false)
    try requireNotCancelled()
    return try exportSnapshot(result["export_snapshot"], input: input)
  }

  private func exportSnapshot(_ value: JSONValue?, input: [String: JSONValue]) throws -> JSONValue {
    guard let value, let snapshot = value.objectValue,
      Set(snapshot.keys) == Set(["version", "note_id", "account_id", "folder_id", "title", "shared", "modified_at", "format", "content"]),
      snapshot["version"] == .integer(1), snapshot["note_id"]?.stringValue == input["note_id"]?.stringValue,
      snapshot["format"]?.stringValue == input["format"]?.stringValue,
      snapshot["title"]?.stringValue != nil, snapshot["content"]?.stringValue != nil,
      snapshot["shared"]?.boolValue != nil,
      ["account_id", "folder_id", "modified_at"].allSatisfy({ snapshot[$0]?.stringValue?.isEmpty == false })
    else { throw invalidUpdatePreview("The Notes export snapshot is missing or malformed") }
    guard try value.encoded().count <= Self.maximumSnapshotBytes else {
      throw AgentError(code: "notes_export_snapshot_too_large",
        message: "The selected Notes export representation exceeds its snapshot limit; it was not truncated",
        details: ["maximum_bytes": .integer(Int64(Self.maximumSnapshotBytes))], exitCode: 6)
    }
    return value
  }

  private func requireNotCancelled() throws {
    guard !Task.isCancelled else {
      throw AgentError(code: "operation_cancelled", message: "Notes export was cancelled before publication", exitCode: 6)
    }
  }

  private func updateSnapshot(_ value: JSONValue?, noteID: String) throws -> JSONValue {
    guard let value, let snapshot = value.objectValue,
      Set(snapshot.keys) == Set([
        "version", "note_id", "account_id", "folder_id", "title", "body", "modified_at",
      ]),
      snapshot["version"] == .integer(1),
      snapshot["note_id"]?.stringValue == noteID,
      snapshot["title"]?.stringValue != nil,
      snapshot["body"]?.stringValue != nil,
      ["account_id", "folder_id", "modified_at"].allSatisfy({
        snapshot[$0]?.stringValue?.isEmpty == false
      })
    else {
      throw invalidUpdatePreview("The Notes update snapshot is missing or malformed")
    }
    guard try value.encoded().count <= Self.maximumSnapshotBytes else {
      throw AgentError(
        code: "notes_update_snapshot_too_large",
        message: "The note is too large for a reviewed update; its snapshot was not truncated",
        details: ["maximum_bytes": .integer(Int64(Self.maximumSnapshotBytes))],
        exitCode: 6
      )
    }
    return value
  }

  private func invalidUpdatePreview(_ message: String) -> AgentError {
    AgentError(code: "plan_preview_invalid", message: message, exitCode: 6)
  }

  private func export(
    _ input: JSONValue,
    expected: JSONValue,
    validateBeforePublish: () throws -> Void,
    validateReplacedOutput: (URL) throws -> Void
  ) async throws -> JSONValue {
    let object = try input.requiredObject()
    let output = try LocalPathPolicy.validateOutputFile(
      object.requiredString("path"),
      overwrite: object.optionalBool("overwrite")
    )
    let current = try await readExportSnapshot(object)
    // Swift String equality folds canonically equivalent Unicode; approved export bytes must not.
    guard try current.encoded() == expected.encoded() else {
      throw AgentError(code: "plan_state_changed", message: "The selected Notes export content changed after preparation", exitCode: 6)
    }
    let format = try object.requiredString("format")
    let content = try current.requiredObject().requiredString("content")
    let data = Data(content.utf8)
    try requireNotCancelled()
    try AtomicFileWriter.write(
      data,
      to: output.url,
      replacingExisting: output.existed,
      replacementPermissions: output.replacementPermissions,
      validateBeforePublish: validateBeforePublish,
      validateReplacedItem: validateReplacedOutput
    )
    return .object([
      "path": .string(output.url.path),
      "bytes": .integer(Int64(data.count)),
      "format": .string(format),
    ])
  }

  private func pathGuardSpecs(command: CommandSpec, input: JSONValue) throws
    -> [LocalPathGuardSpec]
  {
    guard command.id == "notes.items.export" else { return [] }
    let rawPath = try input.requiredObject().requiredString("path")
    let output = try LocalPathPolicy.expandedURL(rawPath)
    return [
      LocalPathGuardSpec(role: "output", url: output),
      LocalPathGuardSpec(
        role: "output_parent",
        url: output.deletingLastPathComponent(),
        trackChanges: false
      ),
    ]
  }

  private func normalizedInput(command: CommandSpec, input: JSONValue) throws -> JSONValue {
    guard command.id == "notes.items.export" else { return input }
    let object = try input.requiredObject()
    let output = try LocalPathPolicy.validateOutputFile(
      object.requiredString("path"),
      overwrite: object.optionalBool("overwrite")
    )
    return try LocalPathPolicy.replacingPath(input, key: "path", with: output.url)
  }

  private struct NotesStoreReference {
    let storeUUID: String
    let primaryKey: Int64

    init?(_ value: String, entityName: String) {
      let prefix = "x-coredata://"
      guard value.hasPrefix(prefix) else { return nil }
      let components = String(value.dropFirst(prefix.count)).split(
        separator: "/", omittingEmptySubsequences: false)
      guard components.count == 3, components[1] == entityName,
        components[2].first == "p",
        let primaryKey = Int64(String(components[2].dropFirst())), primaryKey > 0,
        let storeUUID = Self.normalizedUUID(String(components[0]))
      else { return nil }
      self.storeUUID = storeUUID
      self.primaryKey = primaryKey
    }

    fileprivate static func normalizedUUID(_ value: String) -> String? {
      let value = value.replacingOccurrences(of: "-", with: "").lowercased()
      guard value.utf8.count == 32,
        value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
      else { return nil }
      return value
    }
  }
}
