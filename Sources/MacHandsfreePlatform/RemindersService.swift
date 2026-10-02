import Foundation
import MacHandsfreeCore

#if os(macOS)
  import CoreGraphics
  import EventKit

  extension ReminderSnapshot {
    fileprivate init(_ reminder: EKReminder) throws {
      let startComponents = reminder.startDateComponents
      let dueComponents = reminder.dueDateComponents
      let alarms = try (reminder.alarms ?? []).map { try EventKitMutationSnapshot.alarmPresentation($0) }
      let start = reminderDateFromComponents(startComponents)
      let due = reminderDateFromComponents(dueComponents)
      self.init(
        id: reminder.calendarItemIdentifier,
        listID: reminder.calendar.calendarIdentifier,
        title: reminder.title ?? "",
        notes: reminder.notes,
        url: reminder.url?.absoluteString,
        recurrence: try reminder.recurrenceRules.map { rules in
          .array(try rules.map(EventKitMutationSnapshot.recurrence))
        },
        completed: reminder.isCompleted,
        completionDate: reminder.completionDate,
        alarms: alarms,
        startComponents: startComponents,
        start: start,
        dueComponents: dueComponents,
        due: due,
        priority: reminder.priority
      )
    }
  }

  private struct ReminderReadPage: Sendable {
    let reminders: [ReminderSnapshot]
    let truncated: Bool
  }

  private struct ReminderReadCandidate {
    let reminder: EKReminder
    let id: String
    let listID: String
    let title: String
    let notes: String?
    let url: String?
    let completed: Bool
    let completionDate: Date?
    // Serialize alarm presentation only after this candidate survives bounded selection.
    let alarms: [EKAlarm]
    let matchedAlarmDate: Date?
    let startComponents: DateComponents?
    let start: Date?
    let dueComponents: DateComponents?
    let due: Date?
    let priority: Int

    init(_ reminder: EKReminder, alarmStart: Date?, alarmEnd: Date?) {
      self.reminder = reminder
      id = reminder.calendarItemIdentifier
      listID = reminder.calendar.calendarIdentifier
      title = reminder.title ?? ""
      notes = reminder.notes
      url = reminder.url?.absoluteString
      completed = reminder.isCompleted
      completionDate = reminder.completionDate
      let reminderAlarms = reminder.alarms ?? []
      alarms = reminderAlarms
      if alarmStart != nil || alarmEnd != nil {
        matchedAlarmDate = reminderAlarms.lazy
          .compactMap(\.absoluteDate)
          .filter { date in
            if let alarmStart, date < alarmStart { return false }
            if let alarmEnd, date >= alarmEnd { return false }
            return true
          }
          .min()
      } else {
        matchedAlarmDate = nil
      }
      startComponents = reminder.startDateComponents
      start = reminderDateFromComponents(startComponents)
      dueComponents = reminder.dueDateComponents
      due = reminderDateFromComponents(dueComponents)
      priority = reminder.priority
    }

    func snapshot() throws -> ReminderSnapshot {
      let alarmValues = try alarms.map { try EventKitMutationSnapshot.alarmPresentation($0) }
      let recurrence: JSONValue? = try reminder.recurrenceRules.map { rules in
        .array(try rules.map(EventKitMutationSnapshot.recurrence))
      }
      return ReminderSnapshot(
        id: id,
        listID: listID,
        title: title,
        notes: notes,
        url: url,
        recurrence: recurrence,
        completed: completed,
        completionDate: completionDate,
        alarms: alarmValues,
        startComponents: startComponents,
        start: start,
        dueComponents: dueComponents,
        due: due,
        priority: priority
      )
    }

    static func precedes(_ lhs: ReminderReadCandidate, _ rhs: ReminderReadCandidate) -> Bool {
      let leftDue = lhs.due ?? .distantFuture
      let rightDue = rhs.due ?? .distantFuture
      if leftDue == rightDue { return lhs.id < rhs.id }
      return leftDue < rightDue
    }

  }
#endif

actor RemindersService: CurrentStateValidatedCommandService {
  let name = "reminders"
  private let permissions: any PermissionAuthorizing
  #if os(macOS)
    private var mutationGeneration: UInt64 = 0

    private enum MutationTarget {
      case source(EKSource)
      case list(EKCalendar)
      case newItem(EKCalendar)
      case item(EKReminder, destination: EKCalendar?)
    }

    private struct MutationContext {
      let store: EKEventStore
      let target: MutationTarget
      let snapshot: JSONValue
    }
  #endif

  init(permissions: any PermissionAuthorizing = MacOSPermissionAdapter()) {
    self.permissions = permissions
  }
  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      guard command.kind == .mutation else {
        throw AgentError(code: "preview_not_supported", message: "This Reminders command is read-only", exitCode: 5)
      }
      try requireMutationAdmission()
      let object = try input.requiredObject()
      try preflightMutationDates(command: command.id, object: object)
      try await authorize()
      let context = try await captureMutation(command: command, object: object)
      let target = object["reminder_id"]?.stringValue ?? object["list_id"]?.stringValue
        ?? object["source_id"]?.stringValue ?? "Reminders"
      var preview = try effects([effect(command.id, target)]).requiredObject()
      preview["reminders_snapshot"] = context.snapshot
      return try RemindersMutationSnapshot.bounded(.object(preview))
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      guard command.kind == .read else {
        throw AgentError(code: "plan_preview_invalid", message: "Reminders mutations require a reviewed snapshot", exitCode: 6)
      }
      let object = try input.requiredObject()
      let selectedListIDs: [String]?
      switch command.id {
      case "reminders.items.list", "reminders.items.search":
        selectedListIDs = try object.selectedReadScopeIDs(
          "list_ids", includeAllKey: "all_reminder_lists")
      default:
        selectedListIDs = nil
      }
      let startRange: (start: Date?, end: Date?)
      if command.id == "reminders.items.list" || command.id == "reminders.items.search" {
        startRange = try readDateTimeRange(
          object, startKey: "start_date_start", endKey: "start_date_end")
      } else {
        startRange = (start: nil, end: nil)
      }
      let dueRange: (start: Date?, end: Date?)
      if command.id == "reminders.items.list" || command.id == "reminders.items.search" {
        dueRange = try readDateTimeRange(object, startKey: "due_start", endKey: "due_end")
      } else {
        dueRange = (start: nil, end: nil)
      }
      let alarmRange: (start: Date?, end: Date?)
      if command.id == "reminders.items.list" || command.id == "reminders.items.search" {
        alarmRange = try readDateTimeRange(
          object, startKey: "alarm_start", endKey: "alarm_end")
      } else {
        alarmRange = (start: nil, end: nil)
      }
      try await authorize()
      let readStore = EKEventStore()
      defer { withExtendedLifetime(readStore) {} }
      switch command.id {
      case "reminders.lists.list": return listLists(in: readStore)
      case "reminders.lists.get":
        return .object(["list": listJSON(try exactList(try object.requiredString("list_id"), in: readStore))])
      case "reminders.items.list":
        return try await listItems(
          object, listIDs: selectedListIDs, startRange: startRange,
          dueRange: dueRange, alarmRange: alarmRange,
          query: nil, in: readStore)
      case "reminders.items.get":
        return .object([
          "reminder": try reminderJSON(try exactReminder(try object.requiredString("reminder_id"), in: readStore))
        ])
      case "reminders.items.search":
        return try await listItems(
          object,
          listIDs: selectedListIDs,
          startRange: startRange,
          dueRange: dueRange,
          alarmRange: alarmRange,
          query: try object.requiredString("query"),
          in: readStore
        )
      default:
        throw AgentError(
          code: "unsupported_reminders_command",
          message: "Reminders service does not support command", exitCode: 5)
      }
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  func executeMutation(command: CommandSpec, input: JSONValue, plannedPreview: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      guard command.kind == .mutation,
        let expected = plannedPreview["reminders_snapshot"],
        let expectedObject = expected.objectValue,
        Set(expectedObject.keys) == Set(["version", "command", "target", "members", "due_time_zone"]),
        expected["target"]?.objectValue != nil,
        expected["version"] == .integer(1), expected["command"]?.stringValue == command.id
      else {
        throw AgentError(code: "plan_preview_invalid", message: "The reviewed Reminders snapshot is missing or invalid", exitCode: 6)
      }
      _ = try RemindersMutationSnapshot.bounded(plannedPreview)
      try requireMutationAdmission()
      let object = try input.requiredObject()
      try preflightMutationDates(command: command.id, object: object)
      try await authorize()
      let context = try await captureMutation(command: command, object: object)
      guard try context.snapshot.encoded() == expected.encoded() else { throw mutationStateChanged() }
      try requireMutationAdmission()
      // No suspension occurs between this comparison and the native effect below.
      return try commitMutation(command: command.id, object: object, context: context)
    #else
      _ = input
      _ = plannedPreview
      throw AgentError.unsupported(command.id)
    #endif
  }

  #if os(macOS)
    private func requireMutationAdmission(generation: UInt64? = nil) throws {
      guard !Task.isCancelled else {
        throw AgentError(code: "operation_cancelled", message: "Reminders execution was cancelled before its effect", exitCode: 6)
      }
      if let generation, generation != mutationGeneration { throw mutationStateChanged() }
    }

    private func mutationStateChanged() -> AgentError {
      AgentError(code: "plan_state_changed", message: "The Reminders target changed after it was observed", exitCode: 6)
    }

    private func preflightMutationDates(
      command: String, object: [String: JSONValue]
    ) throws {
      guard command == "reminders.items.create" || command == "reminders.items.update" else { return }
      func parsedDate(_ property: String) throws -> ReminderDateValue? {
        switch object[property] {
        case nil, .some(.null): return nil
        case .some(.string(let value)): return try parseReminderDate(value, property: property)
        default:
          throw AgentError.invalid(
            "Reminder \(property) must be an RFC3339 date-time, YYYY-MM-DD date, or null")
        }
      }

      _ = try parsedDate("start")
      let due = try parsedDate("due")
      if let alarmDates = object["alarm_dates"] {
        guard let values = alarmDates.arrayValue, values.count <= 20 else {
          throw AgentError.invalid("alarm_dates must contain at most 20 RFC3339 date-times")
        }
        var seenAlarmDates = Set<Date>()
        for value in values {
          guard let text = value.stringValue else {
            throw AgentError.invalid("alarm_dates must contain only RFC3339 date-times")
          }
          let date = try parseDateTime(text, property: "alarm_dates")
          guard seenAlarmDates.insert(date).inserted else {
            throw AgentError.invalid("alarm_dates cannot contain duplicate instants")
          }
        }
      }
      guard let recurrence = object["recurrence"], recurrence != .null else { return }
      if due == nil,
        command == "reminders.items.create" || object["due"] == .some(.null)
      {
        throw AgentError.invalid("A recurring reminder requires a due date")
      }
      _ = try EventKitRecurrenceRuleFactory.parse(recurrence, after: due?.date)
    }

    private func captureMutation(command: CommandSpec, object: [String: JSONValue]) async throws -> MutationContext {
      try requireMutationAdmission()
      let generation = mutationGeneration
      // Each invocation owns its store; a concurrent operation cannot reset its native objects.
      let mutationStore = EKEventStore()
      let target = try resolveMutationTarget(command.id, object: object, store: mutationStore)
      switch (command.id, target) {
      case ("reminders.items.create", .newItem):
        _ = try ItemChanges(object)
      case ("reminders.items.update", .item(let reminder, nil)):
        _ = try ItemChanges(object, current: reminder)
      default:
        break
      }
      let before = try targetSnapshot(target)
      var members: JSONValue = .null
      if command.id == "reminders.lists.delete", case .list(let list) = target {
        let listID = list.calendarIdentifier
        let predicate = mutationStore.predicateForReminders(in: [list])
        let result = await withCheckedContinuation {
          (continuation: CheckedContinuation<Result<[JSONValue], AgentError>, Never>) in
          mutationStore.fetchReminders(matching: predicate) { reminders in
            do {
              continuation.resume(returning: .success(try RemindersMutationSnapshot.members(reminders, listID: listID)))
            } catch let error as AgentError {
              continuation.resume(returning: .failure(error))
            } catch {
              continuation.resume(returning: .failure(AgentError(
                code: "reminders_snapshot_unavailable", message: "The list contents could not be captured", exitCode: 6)))
            }
          }
        }
        // cancelFetchRequest suppresses its callback: drain this request instead of abandoning the continuation.
        try requireMutationAdmission(generation: generation)
        members = .array(try result.get())
        try refreshUnchanged(list)
        guard let source = list.source else { throw mutationStateChanged() }
        try refreshUnchanged(source)
        guard try targetSnapshot(target).encoded() == before.encoded() else { throw mutationStateChanged() }
      }
      try requireMutationAdmission(generation: generation)
      let snapshot = try RemindersMutationSnapshot.bounded(.object([
        "version": .integer(1), "command": .string(command.id), "target": before,
        "members": members,
        "due_time_zone": object["due"] == nil ? .null : .string(TimeZone.current.identifier),
      ]))
      return MutationContext(store: mutationStore, target: target, snapshot: snapshot)
    }

    private func resolveMutationTarget(_ command: String, object: [String: JSONValue], store: EKEventStore) throws -> MutationTarget {
      switch command {
      case "reminders.lists.create":
        let source = try exactSource(object.requiredString("source_id"), in: store)
        try refreshUnchanged(source)
        return .source(source)
      case "reminders.lists.update", "reminders.lists.delete", "reminders.items.create":
        let list = try exactList(object.requiredString("list_id"), in: store)
        try refreshUnchanged(list)
        if command == "reminders.items.create" {
          try requireEditable(list)
          return .newItem(list)
        }
        guard !list.isImmutable else {
          throw AgentError(code: "reminder_list_read_only", message: "The reminder list cannot be renamed or deleted", exitCode: 6)
        }
        if command == "reminders.lists.delete", list.allowedEntityTypes.contains(.event) {
          throw AgentError(code: "reminders_snapshot_unsupported", message: "A mixed event/reminder calendar cannot be deleted through a reminder-only plan", exitCode: 6)
        }
        return .list(list)
      case "reminders.items.update", "reminders.items.complete", "reminders.items.reopen", "reminders.items.move", "reminders.items.delete":
        let reminder = try exactReminder(object.requiredString("reminder_id"), in: store)
        try refreshUnchanged(reminder)
        guard let sourceList = reminder.calendar else { throw mutationStateChanged() }
        try refreshUnchanged(sourceList)
        try requireEditable(sourceList)
        if command == "reminders.items.move" {
          let destination = try exactList(object.requiredString("list_id"), in: store)
          try refreshUnchanged(destination)
          try requireEditable(destination)
          return .item(reminder, destination: destination)
        }
        return .item(reminder, destination: nil)
      default:
        throw AgentError(code: "unsupported_reminders_command", message: "Unknown Reminders mutation", exitCode: 5)
      }
    }

    private func refreshUnchanged(_ object: EKObject) throws {
      guard !object.hasChanges, object.refresh() else { throw mutationStateChanged() }
    }

    private func targetSnapshot(_ target: MutationTarget) throws -> JSONValue {
      switch target {
      case .source(let source): return .object(["source": try RemindersMutationSnapshot.source(source)])
      case .list(let list), .newItem(let list): return .object(["list": try RemindersMutationSnapshot.list(list)])
      case .item(let reminder, let destination):
        let item = try RemindersMutationSnapshot.item(reminder)
        guard let source = reminder.calendar,
          source.calendarIdentifier == item["list_id"]?.stringValue
        else { throw mutationStateChanged() }
        try refreshUnchanged(source)
        if let destination { try refreshUnchanged(destination) }
        return .object([
          "item": item,
          "source_list": try RemindersMutationSnapshot.list(source),
          "destination_list": try destination.map(RemindersMutationSnapshot.list) ?? .null,
        ])
      }
    }

    private func requireEditable(_ list: EKCalendar) throws {
      guard list.allowsContentModifications, list.allowedEntityTypes.contains(.reminder) else {
        throw AgentError(code: "reminder_list_read_only", message: "The reminder list does not allow modifications", exitCode: 6)
      }
    }

    private func authorize() async throws {
      let status: PermissionAuthorization
      do {
        status = try await permissions.requestAccessIfNeeded(for: .reminders)
      } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        let current = await permissions.status(for: .reminders)
        try Task.checkCancellation()
        throw remindersPermissionError(for: current)
      }
      try Task.checkCancellation()
      guard status.isGranted else { throw remindersPermissionError(for: status) }
    }

    private func remindersPermissionError(for status: PermissionAuthorization) -> AgentError {
      if status == .notDetermined {
        return AgentError(
          code: "reminders_permission_required",
          message: "Full Reminders access still requires user approval",
          exitCode: 3
        )
      }
      return AgentError(
        code: "reminders_permission_denied", message: "Full Reminders access is required",
        exitCode: 3)
    }

    private func listLists(in store: EKEventStore) -> JSONValue {
      let sources = store.sources.sorted {
        if $0.title == $1.title {
          return $0.sourceIdentifier < $1.sourceIdentifier
        }
        return $0.title < $1.title
      }.map { source in
        JSONValue.object([
          "id": .string(source.sourceIdentifier), "title": .string(source.title),
          "type": .integer(Int64(source.sourceType.rawValue)),
        ])
      }
      return .object([
        "sources": .array(sources),
        "lists": .array(
          store.calendars(for: .reminder).sorted {
            if $0.title == $1.title {
              return $0.calendarIdentifier < $1.calendarIdentifier
            }
            return $0.title < $1.title
          }.map(listJSON)),
      ])
    }
    private func listJSON(_ list: EKCalendar) -> JSONValue {
      .object([
        "id": .string(list.calendarIdentifier),
        "name": .string(list.title),
        "source_id": .string(list.source.sourceIdentifier),
        "source_title": .string(list.source.title),
        "editable": .bool(list.allowsContentModifications),
        "color": colorHex(list.cgColor).map(JSONValue.string) ?? .null,
      ])
    }
    private func exactList(_ id: String, in store: EKEventStore) throws -> EKCalendar {
      guard let list = store.calendar(withIdentifier: id),
        list.allowedEntityTypes.contains(.reminder)
      else {
        throw AgentError(
          code: "reminder_list_not_found", message: "Reminder list identifier was not found",
          details: ["list_id": .string(id)], exitCode: 5)
      }
      return list
    }
    private func exactReminder(_ id: String, in store: EKEventStore) throws -> EKReminder {
      guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
        throw AgentError(
          code: "reminder_not_found", message: "Reminder identifier was not found",
          details: ["reminder_id": .string(id)], exitCode: 5)
      }
      return reminder
    }
    private func exactSource(_ id: String, in store: EKEventStore) throws -> EKSource {
      guard let source = store.sources.first(where: { $0.sourceIdentifier == id }) else {
        throw AgentError(
          code: "reminder_source_not_found", message: "Reminder source identifier was not found",
          details: ["source_id": .string(id)], exitCode: 5)
      }
      return source
    }
    private func reminderJSON(_ reminder: EKReminder) throws -> JSONValue {
      try ReminderSnapshot(reminder).json
    }

    private func saveReminderJSON(_ reminder: EKReminder, in store: EKEventStore) throws -> JSONValue {
      let requested = try reminderContent(reminderJSON(reminder)).encoded()
      try store.save(reminder, commit: true)
      let observed = try savedReminderJSON(reminder, in: store)
      guard try reminderContent(observed).encoded() == requested else {
        throw AgentError(
          code: "reminders_post_save_read_failed",
          message: "The observed reminder does not match the requested content",
          details: ["reminder_id": .string(reminder.calendarItemIdentifier)], exitCode: 5)
      }
      return observed
    }

    private func reminderContent(_ value: JSONValue) throws -> JSONValue {
      var content = try value.requiredObject()
      // EventKit assigns identity and completion time. Location names are display metadata.
      for key in ["id", "completion_date", "list_name", "source_title"] {
        content.removeValue(forKey: key)
      }
      // EventKit may represent a cleared note or absent recurrence as nil after saving.
      // These are the same empty states, not permission to normalize authored text or dates.
      if content["notes"] == .string("") { content["notes"] = .null }
      if content["recurrence"] == .array([]) { content["recurrence"] = .null }
      return .object(content)
    }

    /// Called only after a committed save, inside performMutationEffect's uncertainty boundary.
    private func savedReminderJSON(_ saved: EKReminder, in store: EKEventStore) throws -> JSONValue {
      let id = saved.calendarItemIdentifier
      let listID = saved.calendar?.calendarIdentifier
      let completed = saved.isCompleted
      guard !id.isEmpty, let listID, !listID.isEmpty else {
        throw AgentError(
          code: "reminders_post_save_read_failed", message: "Saved reminder identity is unavailable", exitCode: 5)
      }
      // Capture committed values before refresh can mutate the same EventKit object.
      // Identity alone cannot confirm that the reviewed title, dates or notes were saved.
      let savedContent = try reminderJSON(saved).encoded()
      let current = try exactReminder(id, in: store)
      guard !current.hasChanges, current.refresh(), current.calendarItemIdentifier == id,
        current.calendar?.calendarIdentifier == listID, current.isCompleted == completed
      else {
        throw AgentError(
          code: "reminders_post_save_read_failed",
          message: "Saved reminder identity, list or completion state could not be confirmed",
          details: ["reminder_id": .string(id)], exitCode: 5)
      }
      let observed = try reminderJSON(current)
      guard try observed.encoded() == savedContent else {
        throw AgentError(
          code: "reminders_post_save_read_failed",
          message: "Saved reminder content could not be confirmed",
          details: ["reminder_id": .string(id)], exitCode: 5)
      }
      var result = try observed.requiredObject()
      result["list_name"] = .string(current.calendar.title)
      result["source_title"] = .string(current.calendar.source.title)
      return .object(result)
    }

    private func parseColor(_ value: String) throws -> CGColor {
      guard value.count == 7, value.first == "#",
        let rgb = Int(value.dropFirst(), radix: 16)
      else { throw AgentError.invalid("Reminder list color must be #RRGGBB") }
      return CGColor(
        red: CGFloat((rgb >> 16) & 0xFF) / 255,
        green: CGFloat((rgb >> 8) & 0xFF) / 255,
        blue: CGFloat(rgb & 0xFF) / 255,
        alpha: 1
      )
    }

    private func colorHex(_ color: CGColor?) -> String? {
      guard let components = color?.components, !components.isEmpty else { return nil }
      let red: CGFloat
      let green: CGFloat
      let blue: CGFloat
      if components.count >= 3 {
        red = components[0]
        green = components[1]
        blue = components[2]
      } else {
        red = components[0]
        green = components[0]
        blue = components[0]
      }
      func byte(_ component: CGFloat) -> Int {
        min(255, max(0, Int((component * 255).rounded())))
      }
      return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    private func readDateTimeRange(
      _ object: [String: JSONValue], startKey: String, endKey: String
    ) throws -> (start: Date?, end: Date?) {
      func bound(_ key: String) throws -> Date? {
        guard let value = object[key] else { return nil }
        guard let text = value.stringValue else {
          throw AgentError.invalid(
            "Date range bounds must be RFC3339 date-times", details: ["property": .string(key)])
        }
        return try parseDateTime(text, property: key)
      }
      let start = try bound(startKey)
      let end = try bound(endKey)
      if let start, let end, start >= end {
        throw AgentError.invalid("\(startKey) must be earlier than \(endKey)")
      }
      return (start, end)
    }

    private func listItems(
      _ object: [String: JSONValue], listIDs: [String]?, startRange: (start: Date?, end: Date?),
      dueRange: (start: Date?, end: Date?), alarmRange: (start: Date?, end: Date?),
      query: String?, in store: EKEventStore
    ) async throws -> JSONValue
    {
      let lists = try listIDs?.map {
        try exactList($0, in: store)
      }
      let completed = object["completed"]?.boolValue
      let startRangeStart = startRange.start
      let startRangeEnd = startRange.end
      let dueStart = dueRange.start
      let dueEnd = dueRange.end
      let alarmStart = alarmRange.start
      let alarmEnd = alarmRange.end
      let hasStartFilter = startRangeStart != nil || startRangeEnd != nil
      let hasAlarmFilter = alarmRange.start != nil || alarmRange.end != nil
      let limit = object.optionalInt("limit", default: 100) ?? 100
      let predicate: NSPredicate
      if completed == false {
        // Filter completed records before EventKit returns its result array.
        let fetchStart = dueStart?.addingTimeInterval(-1)
        let fetchEnd = dueEnd?.addingTimeInterval(1)
        predicate = store.predicateForIncompleteReminders(
          withDueDateStarting: fetchStart, ending: fetchEnd, calendars: lists)
      } else if completed == true {
        // This predicate ranges completionDate; due filters remain in the exact callback checks.
        predicate = store.predicateForCompletedReminders(
          withCompletionDateStarting: nil, ending: nil, calendars: lists)
      } else {
        predicate = store.predicateForReminders(in: lists)
      }
      try requireMutationAdmission()
      let fetched = await withCheckedContinuation {
        (continuation: CheckedContinuation<Result<ReminderReadPage?, AgentError>, Never>) in
        store.fetchReminders(matching: predicate) { reminders in
          guard let reminders else {
            continuation.resume(returning: .success(nil))
            return
          }
          do {
            // Alarm and start windows define their own result order; otherwise retain due/ID order.
            let precedes: (ReminderReadCandidate, ReminderReadCandidate) -> Bool
            if hasAlarmFilter {
              precedes = { lhs, rhs in
                let leftAlarm = lhs.matchedAlarmDate ?? .distantFuture
                let rightAlarm = rhs.matchedAlarmDate ?? .distantFuture
                if leftAlarm == rightAlarm { return lhs.id < rhs.id }
                return leftAlarm < rightAlarm
              }
            } else if hasStartFilter {
              precedes = { lhs, rhs in
                let leftStart = lhs.start ?? .distantFuture
                let rightStart = rhs.start ?? .distantFuture
                if leftStart == rightStart { return lhs.id < rhs.id }
                return leftStart < rightStart
              }
            } else {
              precedes = ReminderReadCandidate.precedes
            }
            var matches = BoundedReadSelection(limit: limit, by: precedes)
            for reminder in reminders {
              let candidate = ReminderReadCandidate(
                reminder, alarmStart: alarmStart, alarmEnd: alarmEnd)
              if let completed, candidate.completed != completed { continue }
              if let query,
                !candidate.title.localizedCaseInsensitiveContains(query),
                !(candidate.notes ?? "").localizedCaseInsensitiveContains(query)
              {
                continue
              }
              if let startRangeStart, candidate.start.map({ $0 >= startRangeStart }) != true { continue }
              if let startRangeEnd, candidate.start.map({ $0 < startRangeEnd }) != true { continue }
              if let dueStart, candidate.due.map({ $0 >= dueStart }) != true { continue }
              if let dueEnd, candidate.due.map({ $0 < dueEnd }) != true { continue }
              if hasAlarmFilter, candidate.matchedAlarmDate == nil {
                continue
              }
              matches.insert(candidate)
            }
            continuation.resume(
              returning: .success(
                ReminderReadPage(
                  reminders: try matches.page.map { try $0.snapshot() },
                  truncated: matches.truncated
                )))
          } catch let error as AgentError {
            continuation.resume(returning: .failure(error))
          } catch {
            continuation.resume(returning: .failure(AgentError(
              code: "reminders_snapshot_unavailable",
              message: "Reminder values could not be serialized",
              exitCode: 5
            )))
          }
        }
      }
      try requireMutationAdmission()
      guard let page = try fetched.get() else {
        throw AgentError(code: "reminders_fetch_failed", message: "EventKit did not return a reminder result", exitCode: 5)
      }
      return .object([
        "reminders": .array(page.reminders.map(\.json)),
        "truncated": .bool(page.truncated),
      ])
    }

    private struct ItemChanges {
      let title: String?
      let notes: String??
      let url: URL??
      let start: DateComponents??
      let due: DateComponents??
      let recurrence: [EKRecurrenceRule]??
      let alarmDates: [EKAlarm]?
      let priority: Int?

      init(_ object: [String: JSONValue], current: EKReminder? = nil) throws {
        title = object.optionalString("title")
        priority = object["priority"]?.intValue
        var recurrenceAnchor = reminderDateFromComponents(current?.dueDateComponents)
        switch object["notes"] {
        case nil: notes = nil
        case .some(.null): notes = .some(nil)
        case .some(.string(let value)): notes = .some(value)
        default: throw AgentError.invalid("notes must be a string or null")
        }
        url = try nullableURLUpdate(object["url"], property: "url")
        switch object["alarm_dates"] {
        case nil: alarmDates = nil
        case .some(.array(let values)):
          alarmDates = try values.map { value in
            guard let text = value.stringValue else {
              throw AgentError.invalid("alarm_dates must contain only RFC3339 date-times")
            }
            return EKAlarm(absoluteDate: try parseDateTime(text, property: "alarm_dates"))
          }
        default:
          throw AgentError.invalid("alarm_dates must be an array of RFC3339 date-times")
        }
        switch object["start"] {
        case nil: start = nil
        case .some(.null): start = .some(nil)
        case .some(.string(let value)):
          start = .some(try parseReminderDate(value, property: "start").components)
        default: throw AgentError.invalid("start must be an RFC3339 date-time, YYYY-MM-DD date, or null")
        }
        switch object["due"] {
        case nil: due = nil
        case .some(.null):
          due = .some(nil)
          recurrenceAnchor = nil
        case .some(.string(let value)):
          let parsed = try parseReminderDate(value, property: "due")
          due = .some(parsed.components)
          recurrenceAnchor = parsed.date
        default: throw AgentError.invalid("due must be an RFC3339 date-time, YYYY-MM-DD date, or null")
        }
        let recurrenceContinues = object["recurrence"].map { $0 != .null }
          ?? (current?.hasRecurrenceRules ?? false)
        if recurrenceContinues, recurrenceAnchor == nil {
          throw AgentError.invalid("A recurring reminder requires a due date")
        }
        switch object["recurrence"] {
        case nil: recurrence = nil
        case .some(.null): recurrence = .some(nil)
        case .some(let value):
          guard let recurrenceAnchor else {
            throw AgentError.invalid("A recurring reminder requires a due date")
          }
          recurrence = .some(
            try EventKitRecurrenceRuleFactory.parse(value, after: recurrenceAnchor))
        }
      }

      func apply(to reminder: EKReminder) {
        if let title { reminder.title = title }
        if let notes { reminder.notes = notes }
        if let url { reminder.url = url }
        if let start { reminder.startDateComponents = start }
        if let due { reminder.dueDateComponents = due }
        if let alarmDates {
          // Replacing time alerts must not erase geofences or custom alarm actions.
          let retained = (reminder.alarms ?? []).filter { alarm in
            alarm.type.rawValue != EKAlarmType.display.rawValue
              || alarm.proximity.rawValue != EKAlarmProximity.none.rawValue
              || alarm.structuredLocation != nil
          }
          reminder.alarms = retained + alarmDates
        }
        if let recurrence { reminder.recurrenceRules = recurrence }
        if let priority { reminder.priority = priority }
      }
    }

    private func commitMutation(command: String, object: [String: JSONValue], context: MutationContext) throws -> JSONValue {
      let mutationStore = context.store
      switch (command, context.target) {
      case ("reminders.lists.create", .source(let source)):
        let name = try object.requiredString("name")
        let color = try object.optionalString("color").map(parseColor)
        return try performMutationEffect {
          let list = EKCalendar(for: .reminder, eventStore: mutationStore)
          list.source = source
          list.title = name
          if let color { list.cgColor = color }
          try mutationStore.saveCalendar(list, commit: true)
          return .object(["list": listJSON(list)])
        }
      case ("reminders.lists.update", .list(let list)):
        let name = object.optionalString("name")
        let color = try object.optionalString("color").map(parseColor)
        return try performMutationEffect {
          if let name { list.title = name }
          if let color { list.cgColor = color }
          try mutationStore.saveCalendar(list, commit: true)
          return .object(["list": listJSON(list)])
        }
      case ("reminders.lists.delete", .list(let list)):
        let id = list.calendarIdentifier
        return try performMutationEffect {
          try mutationStore.removeCalendar(list, commit: true)
          return .object(["deleted": .bool(true), "list_id": .string(id)])
        }
      case ("reminders.items.create", .newItem(let list)):
        let title = try object.requiredString("title")
        let changes = try ItemChanges(object)
        return try performMutationEffect {
          let reminder = EKReminder(eventStore: mutationStore)
          reminder.calendar = list
          reminder.title = title
          changes.apply(to: reminder)
          return .object(["reminder": try saveReminderJSON(reminder, in: mutationStore)])
        }
      case ("reminders.items.update", .item(let reminder, nil)):
        let changes = try ItemChanges(object, current: reminder)
        return try performMutationEffect {
          changes.apply(to: reminder)
          return .object(["reminder": try saveReminderJSON(reminder, in: mutationStore)])
        }
      case ("reminders.items.complete", .item(let reminder, nil)),
        ("reminders.items.reopen", .item(let reminder, nil)):
        let completed = command == "reminders.items.complete"
        guard reminder.isCompleted != completed else {
          return .object(["reminder": try reminderJSON(reminder), "changed": .bool(false)])
        }
        return try performMutationEffect {
          // EventKit maintains completionDate; repeated completion must not rewrite it.
          reminder.isCompleted = completed
          return .object(["reminder": try saveReminderJSON(reminder, in: mutationStore), "changed": .bool(true)])
        }
      case ("reminders.items.move", .item(let reminder, .some(let destination))):
        return try performMutationEffect {
          reminder.calendar = destination
          return .object(["reminder": try saveReminderJSON(reminder, in: mutationStore)])
        }
      case ("reminders.items.delete", .item(let reminder, nil)):
        let id = reminder.calendarItemIdentifier
        return try performMutationEffect {
          try mutationStore.remove(reminder, commit: true)
          return .object(["deleted": .bool(true), "reminder_id": .string(id)])
        }
      default:
        throw AgentError(code: "plan_preview_invalid", message: "The Reminders mutation target is inconsistent", exitCode: 6)
      }
    }

    private func performMutationEffect(_ effect: () throws -> JSONValue) throws -> JSONValue {
      try requireMutationAdmission()
      mutationGeneration &+= 1
      do {
        return try effect()
      } catch {
        throw AgentError(
          code: "reminders_mutation_uncertain",
          message: "The Reminders mutation began but did not return a confirmed result",
          details: ["reason": .string(String(describing: error))], exitCode: 5,
          outcomeUncertain: true)
      }
    }
  #endif
}
