import Foundation
import MacHandsfreeCore

#if os(macOS)
  import EventKit
#endif

actor CalendarService: CurrentStateValidatedCommandService {
  private static let maximumReadRangeDays = 4 * 365
  let name = "calendar"
  private let permissions: any PermissionAuthorizing
  #if os(macOS)
    private enum MutationTarget {
      case newEvent(EKCalendar)
      case event(EKEvent, destination: EKCalendar?)
    }

    private struct MutationContext {
      let store: EKEventStore
      let target: MutationTarget
      let snapshot: JSONValue
    }

    private struct ReadCandidate {
      let event: EKEvent
      let startDate: Date
      let eventIdentifier: String

      init(_ event: EKEvent) {
        self.event = event
        startDate = event.startDate
        eventIdentifier = event.eventIdentifier ?? ""
      }

      static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.startDate == rhs.startDate { return lhs.eventIdentifier < rhs.eventIdentifier }
        return lhs.startDate < rhs.startDate
      }
    }
  #endif

  init(permissions: any PermissionAuthorizing = MacOSPermissionAdapter()) {
    self.permissions = permissions
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      guard command.kind == .mutation else {
        throw AgentError(code: "preview_not_supported", message: "Calendar command is read-only", exitCode: 5)
      }
      try requireAdmission()
      let object = try input.requiredObject()
      try preflightRecurrenceInput(command: command.id, object: object)
      try await authorize()
      let context = try captureMutation(command: command.id, object: object)
      let originalPreview: JSONValue
      switch command.id {
      case "calendar.events.create":
        originalPreview = effects([effect("create_event", try object.requiredString("calendar_id"),
          details: ["title": .string(try object.requiredString("title"))])])
      case "calendar.events.update":
        originalPreview = effects([effect("update_event", try object.requiredString("event_id"))])
      case "calendar.events.delete":
        originalPreview = effects([effect("delete_event", try object.requiredString("event_id"),
          details: ["scope": .string(object.optionalString("recurrence_scope") ?? "this")])])
      case "calendar.events.move":
        originalPreview = effects([effect("move_event", try object.requiredString("event_id"),
          details: ["calendar_id": .string(try object.requiredString("calendar_id"))])])
      default:
        throw AgentError(code: "preview_not_supported", message: "Unknown Calendar mutation", exitCode: 5)
      }
      var preview = try originalPreview.requiredObject()
      preview["calendar_snapshot"] = context.snapshot
      return try CalendarMutationSnapshot.bounded(.object(preview))
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      guard command.kind == .read else {
        throw AgentError(code: "plan_preview_invalid", message: "Calendar mutations require a reviewed snapshot", exitCode: 6)
      }
      try requireAdmission()
      let object = try input.requiredObject()
      let selectedCalendarIDs: [String]?
      switch command.id {
      case "calendar.events.list", "calendar.events.search", "calendar.availability.find":
        selectedCalendarIDs = try object.selectedReadScopeIDs(
          "calendar_ids", includeAllKey: "all_calendars")
      default:
        selectedCalendarIDs = nil
      }
      try await authorize()
      try requireAdmission()
      let store = EKEventStore()
      switch command.id {
      case "calendar.calendars.list": return listCalendars(in: store)
      case "calendar.calendars.get":
        return .object([
          "calendar": calendarJSON(try exactCalendar(try object.requiredString("calendar_id"), in: store))
        ])
      case "calendar.events.list":
        return try listEvents(object, calendarIDs: selectedCalendarIDs, search: nil, in: store)
      case "calendar.events.get":
        return .object(["event": eventJSON(try exactEvent(object, in: store))])
      case "calendar.events.search":
        return try listEvents(
          object, calendarIDs: selectedCalendarIDs, search: try object.requiredString("query"), in: store)
      case "calendar.availability.find":
        return try findAvailability(object, calendarIDs: selectedCalendarIDs, in: store)
      default:
        throw AgentError(
          code: "unsupported_calendar_command",
          message: "Calendar service does not support the command", exitCode: 5)
      }
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  func executeMutation(command: CommandSpec, input: JSONValue, plannedPreview: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      guard command.kind == .mutation, let expected = plannedPreview["calendar_snapshot"],
        let fields = expected.objectValue,
        Set(fields.keys) == Set(["version", "command", "target", "span", "default_time_zone", "future_scope"]),
        expected["version"] == .integer(1), expected["command"]?.stringValue == command.id,
        expected["target"]?.objectValue != nil
      else {
        throw AgentError(code: "plan_preview_invalid", message: "The reviewed Calendar snapshot is missing or invalid", exitCode: 6)
      }
      _ = try CalendarMutationSnapshot.bounded(plannedPreview)
      try requireAdmission()
      let object = try input.requiredObject()
      try preflightRecurrenceInput(command: command.id, object: object)
      try await authorize()
      let context = try captureMutation(command: command.id, object: object)
      guard try context.snapshot.encoded() == expected.encoded() else { throw stateChanged() }
      try requireAdmission()
      // These actor-isolated operations never suspend between comparison and native dispatch.
      return try commitMutation(command: command.id, object: object, context: context)
    #else
      _ = input
      _ = plannedPreview
      throw AgentError.unsupported(command.id)
    #endif
  }

  #if os(macOS)
    private func requireAdmission() throws {
      guard !Task.isCancelled else {
        throw AgentError(code: "operation_cancelled", message: "Calendar execution was cancelled before its effect", exitCode: 6)
      }
    }

    private func stateChanged() -> AgentError {
      AgentError(code: "plan_state_changed", message: "The selected Calendar state changed after it was observed", exitCode: 6)
    }

    private func preflightRecurrenceInput(
      command: String, object: [String: JSONValue]
    ) throws {
      guard let recurrence = object["recurrence"], recurrence != .null else { return }
      let anchorDate: Date?
      if command == "calendar.events.create", let start = object["start"]?.stringValue {
        let allDay = object["all_day"]?.boolValue ?? false
        let timeZone = TimeZone(identifier: NSTimeZone.default.identifier) ?? .current
        anchorDate = try parseCalendarBoundary(
          start, property: "start", allDay: allDay, timeZone: timeZone)
      } else {
        anchorDate = nil
      }
      _ = try EventKitRecurrenceRuleFactory.parse(recurrence, after: anchorDate)
    }

    private func captureMutation(command: String, object: [String: JSONValue]) throws -> MutationContext {
      try requireAdmission()
      let store = EKEventStore()
      let target: MutationTarget
      let observed: JSONValue
      if command == "calendar.events.create" {
        let calendar = try exactCalendar(object.requiredString("calendar_id"), in: store)
        try requireEditable(calendar)
        observed = .object(["destination_calendar": try calendarSnapshot(calendar)])
        _ = try eventChanges(object, current: nil)
        target = .newEvent(calendar)
      } else {
        guard ["calendar.events.update", "calendar.events.delete", "calendar.events.move"].contains(command) else {
          throw AgentError(code: "unsupported_calendar_command", message: "Unknown Calendar mutation", exitCode: 5)
        }
        let event = try exactEvent(object, in: store)
        let original = try CalendarMutationSnapshot.event(event)
        // Refreshing a selected occurrence must not silently change which occurrence was selected.
        try requireSelectorStillMatches(event, object: object)
        guard let source = event.calendar else { throw stateChanged() }
        try requireEditable(source)
        let destination: EKCalendar?
        if command == "calendar.events.move" {
          destination = try exactCalendar(object.requiredString("calendar_id"), in: store)
          if let destination { try requireEditable(destination) }
        } else {
          destination = nil
        }
        observed = .object([
          "event": original, "source_calendar": try calendarSnapshot(source),
          "destination_calendar": try destination.map(calendarSnapshot) ?? .null,
        ])
        if command == "calendar.events.update" { _ = try eventChanges(object, current: event) }
        target = .event(event, destination: destination)
      }
      let scope = command == "calendar.events.create" ? "this" : object.optionalString("recurrence_scope") ?? "this"
      let snapshot = try CalendarMutationSnapshot.bounded(.object([
        "version": .integer(1), "command": .string(command), "target": observed,
        "span": .string(scope), "default_time_zone": .string(NSTimeZone.default.identifier),
        "future_scope": scope == "future"
          ? .string("Selected occurrence and future instances. The observed rule and selected occurrence do not form a revision of every future exception.")
          : .null,
      ]))
      try requireAdmission()
      return MutationContext(store: store, target: target, snapshot: snapshot)
    }

    private func calendarSnapshot(_ calendar: EKCalendar) throws -> JSONValue {
      let before = try CalendarMutationSnapshot.calendar(calendar)
      guard !calendar.hasChanges, calendar.refresh(), let source = calendar.source,
        !source.hasChanges, source.refresh()
      else { throw stateChanged() }
      let current = try CalendarMutationSnapshot.calendar(calendar)
      guard try before.encoded() == current.encoded() else { throw stateChanged() }
      return current
    }

    private func requireEditable(_ calendar: EKCalendar) throws {
      guard calendar.allowsContentModifications, calendar.allowedEntityTypes.contains(.event) else {
        throw AgentError(code: "calendar_read_only", message: "Calendar does not allow event modifications", exitCode: 6)
      }
    }

    private func authorize() async throws {
      let status: PermissionAuthorization
      do {
        status = try await permissions.requestAccessIfNeeded(for: .calendar)
      } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        let current = await permissions.status(for: .calendar)
        try Task.checkCancellation()
        throw calendarPermissionError(for: current)
      }
      try Task.checkCancellation()
      guard status.isGranted else {
        throw calendarPermissionError(for: status)
      }
    }

    private func calendarPermissionError(for status: PermissionAuthorization) -> AgentError {
      if status == .notDetermined {
        return AgentError(
          code: "calendar_permission_required",
          message: "Full Calendar access still requires user approval",
          exitCode: 3
        )
      }
      return AgentError(
        code: "calendar_permission_denied", message: "Full Calendar access is required",
        exitCode: 3)
    }

    private func listCalendars(in store: EKEventStore) -> JSONValue {
      .object([
        "calendars": .array(
          store.calendars(for: .event).sorted {
            if $0.title == $1.title {
              return $0.calendarIdentifier < $1.calendarIdentifier
            }
            return $0.title < $1.title
          }.map(calendarJSON))
      ])
    }

    private func calendarJSON(_ calendar: EKCalendar) -> JSONValue {
      .object([
        "id": .string(calendar.calendarIdentifier), "title": .string(calendar.title),
        "source_id": .string(calendar.source.sourceIdentifier),
        "source_title": .string(calendar.source.title),
        "editable": .bool(calendar.allowsContentModifications),
        "subscribed": .bool(calendar.isSubscribed),
      ])
    }

    private func exactCalendar(_ id: String, in store: EKEventStore) throws -> EKCalendar {
      guard let calendar = store.calendar(withIdentifier: id), calendar.allowedEntityTypes.contains(.event) else {
        throw AgentError(
          code: "calendar_not_found", message: "Calendar identifier was not found",
          details: ["calendar_id": .string(id)], exitCode: 5)
      }
      return calendar
    }

    private func exactEvent(_ object: [String: JSONValue], in store: EKEventStore) throws -> EKEvent {
      let id = try object.requiredString("event_id")
      guard let anchor = store.event(withIdentifier: id), !anchor.hasChanges, anchor.refresh(),
        anchor.eventIdentifier == id, let calendar = anchor.calendar, let source = calendar.source
      else {
        throw AgentError(
          code: "event_not_found", message: "Event identifier was not found",
          details: ["event_id": .string(id)], exitCode: 5)
      }
      guard let selector = object.optionalString("occurrence_start") else {
        try requireSelectorStillMatches(anchor, object: object)
        return anchor
      }
      let selectedStart = try parseDateTime(selector, property: "occurrence_start")
      let canonicalStart = ISO8601DateFormatter.agentString(from: selectedStart)
      let calendarID = calendar.calendarIdentifier
      let sourceID = source.sourceIdentifier
      // The window bounds work only. It is not a time tolerance or an external-ID fallback.
      let predicate = store.predicateForEvents(
        withStart: selectedStart.addingTimeInterval(-1), end: selectedStart.addingTimeInterval(1),
        calendars: [calendar])
      var matches: [EKEvent] = []
      var visited = 0
      var exceeded = false
      store.enumerateEvents(matching: predicate) { candidate, stop in
        visited += 1
        if visited > CalendarMutationSnapshot.maximumOccurrenceCandidates {
          exceeded = true
          stop.pointee = true
          return
        }
        guard candidate.eventIdentifier == id, let start = candidate.startDate,
          candidate.calendar?.calendarIdentifier == calendarID,
          candidate.calendar?.source?.sourceIdentifier == sourceID,
          ISO8601DateFormatter.agentString(from: start) == canonicalStart
        else { return }
        matches.append(candidate)
        if matches.count > 1 { stop.pointee = true }
      }
      guard !exceeded else {
        throw AgentError(code: "calendar_occurrence_search_limit",
          message: "The occurrence lookup exceeded its bound; no candidate was selected",
          details: ["maximum_candidates": .integer(Int64(CalendarMutationSnapshot.maximumOccurrenceCandidates))], exitCode: 6)
      }
      guard matches.count == 1, let selected = matches.first else {
        throw AgentError(code: matches.isEmpty ? "event_occurrence_not_found" : "event_occurrence_ambiguous",
          message: "The event ID and occurrence start must identify exactly one occurrence in its original calendar",
          details: ["event_id": .string(id), "occurrence_start": .string(selector)], exitCode: 6)
      }
      guard !selected.hasChanges, selected.refresh(),
        selected.calendar?.calendarIdentifier == calendarID,
        selected.calendar?.source?.sourceIdentifier == sourceID
      else { throw stateChanged() }
      try requireSelectorStillMatches(selected, object: object)
      return selected
    }

    private func requireSelectorStillMatches(_ event: EKEvent, object: [String: JSONValue]) throws {
      guard event.eventIdentifier == object["event_id"]?.stringValue else { throw stateChanged() }
      if let selector = object.optionalString("occurrence_start") {
        let expected = try parseDateTime(selector, property: "occurrence_start")
        guard let start = event.startDate,
          ISO8601DateFormatter.agentString(from: start) == ISO8601DateFormatter.agentString(from: expected)
        else { throw stateChanged() }
      } else if event.hasRecurrenceRules || event.isDetached || event.occurrenceDate != nil {
        throw AgentError(code: "event_occurrence_required",
          message: "Select an occurrence from calendar.events.list/search and supply its occurrence_start",
          details: ["event_id": .string(try object.requiredString("event_id"))], exitCode: 6)
      }
    }

    private func listEvents(
      _ object: [String: JSONValue], calendarIDs: [String]?, search: String?, in store: EKEventStore
    ) throws -> JSONValue {
      let (start, end) = try readRange(object)
      let calendars = try calendarIDs?.map {
        try exactCalendar($0, in: store)
      }
      let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
      let includeAllDay = object.optionalBool("include_all_day", default: true)
      let limit = object.optionalInt("limit", default: 100) ?? 100
      var matches = BoundedReadSelection<ReadCandidate>(limit: limit, by: ReadCandidate.precedes)
      store.enumerateEvents(matching: predicate) { event, _ in
        guard includeAllDay || !event.isAllDay else { return }
        if let search {
          let matchesSearch = event.title?.localizedCaseInsensitiveContains(search) == true
            || event.location?.localizedCaseInsensitiveContains(search) == true
            || event.notes?.localizedCaseInsensitiveContains(search) == true
          guard matchesSearch else { return }
        }
        matches.insert(ReadCandidate(event))
      }
      return .object([
        "events": .array(matches.page.map { eventJSON($0.event) }),
        "truncated": .bool(matches.truncated),
      ])
    }

    private struct EventChanges {
      let title: String?
      let start: Date
      let end: Date
      let allDay: Bool?
      let location: String??
      let notes: String??
      let url: URL??
      let availability: EKEventAvailability?
      let alarms: [EKAlarm]?
      let recurrence: [EKRecurrenceRule]??

      func apply(to event: EKEvent) {
        if let title { event.title = title }
        event.startDate = start
        event.endDate = end
        if let allDay { event.isAllDay = allDay }
        if let location { event.location = location }
        if let notes { event.notes = notes }
        if let url { event.url = url }
        if let availability { event.availability = availability }
        if let alarms { event.alarms = alarms }
        if let recurrence { event.recurrenceRules = recurrence }
      }
    }

    private func eventChanges(_ object: [String: JSONValue], current: EKEvent?) throws -> EventChanges {
      let allDay = object["all_day"]?.boolValue ?? current?.isAllDay ?? false
      let eventTimeZone = current?.timeZone
        ?? TimeZone(identifier: NSTimeZone.default.identifier) ?? .current
      let start: Date? = try object.optionalString("start").map {
        try parseCalendarBoundary($0, property: "start", allDay: allDay, timeZone: eventTimeZone)
      } ?? current?.startDate
      let end: Date? = try object.optionalString("end").map {
        try parseCalendarBoundary($0, property: "end", allDay: allDay, timeZone: eventTimeZone)
      } ?? current?.endDate
      guard let start, let end, start < end else { throw AgentError.invalid("start must be earlier than end") }
      let title = object.optionalString("title")
      if current == nil, title == nil { throw AgentError.invalid("A new event requires a title") }
      if let requestedAllDay = object["all_day"]?.boolValue, let current,
        requestedAllDay != current.isAllDay, object["start"] == nil || object["end"] == nil
      {
        throw AgentError.invalid("Changing an event's all-day state requires explicit start and end boundaries")
      }
      let alarms: [EKAlarm]? = object["alarm_offsets_minutes"].map(alarmValues) ?? (current == nil ? [] : nil)
      return EventChanges(
        title: title, start: start, end: end,
        allDay: object["all_day"]?.boolValue ?? (current == nil ? false : nil),
        location: try nullableStringUpdate(object["location"], property: "location"),
        notes: try nullableStringUpdate(object["notes"], property: "notes"),
        url: try nullableURLUpdate(object["url"], property: "url"),
        availability: try object.optionalString("availability").map(parseAvailability),
        alarms: alarms,
        recurrence: try object["recurrence"].map {
          try EventKitRecurrenceRuleFactory.parse($0, after: start)
        })
    }

    private func commitMutation(command: String, object: [String: JSONValue], context: MutationContext) throws -> JSONValue {
      let store = context.store
      let scope = object.optionalString("recurrence_scope") ?? "this"
      switch (command, context.target) {
      case ("calendar.events.create", .newEvent(let calendar)):
        let changes = try eventChanges(object, current: nil)
        return try performMutationEffect {
          let event = EKEvent(eventStore: store)
          event.calendar = calendar
          changes.apply(to: event)
          try store.save(event, span: .thisEvent, commit: true)
          return try observedResult(event)
        }
      case ("calendar.events.update", .event(let event, nil)):
        let changes = try eventChanges(object, current: event)
        return try performMutationEffect {
          changes.apply(to: event)
          try store.save(event, span: span(scope), commit: true)
          return try observedResult(event)
        }
      case ("calendar.events.move", .event(let event, .some(let destination))):
        return try performMutationEffect {
          event.calendar = destination
          try store.save(event, span: span(scope), commit: true)
          return try observedResult(event)
        }
      case ("calendar.events.delete", .event(let event, nil)):
        guard let id = event.eventIdentifier, let start = event.startDate else { throw stateChanged() }
        let occurrence = ISO8601DateFormatter.agentString(from: start)
        return try performMutationEffect {
          try store.remove(event, span: span(scope), commit: true)
          return .object([
            "deleted": .bool(true), "event_id": .string(id), "occurrence_start": .string(occurrence),
            "recurrence_scope": .string(scope),
          ])
        }
      default:
        throw AgentError(code: "plan_preview_invalid", message: "The Calendar mutation target is inconsistent", exitCode: 6)
      }
    }

    private func observedResult(_ event: EKEvent) throws -> JSONValue {
      // Saving may change an occurrence's identifier/calendar. Observe that same native object.
      let snapshot = try CalendarMutationSnapshot.event(event)
      return .object(["event": try CalendarMutationSnapshot.presentation(snapshot)])
    }

    private func performMutationEffect(_ effect: () throws -> JSONValue) throws -> JSONValue {
      try requireAdmission()
      do {
        return try effect()
      } catch {
        throw AgentError(code: "calendar_mutation_uncertain",
          message: "The Calendar mutation began but did not return a confirmed result",
          details: ["reason": .string(String(describing: error))], exitCode: 5, outcomeUncertain: true)
      }
    }

    private func findAvailability(
      _ object: [String: JSONValue], calendarIDs: [String]?, in store: EKEventStore
    ) throws -> JSONValue {
      let (start, end) = try readRange(object)
      let calendars = try calendarIDs?.map {
        try exactCalendar($0, in: store)
      }
      let events = store.events(
        matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars)
      ).filter { $0.status != .canceled && $0.availability != .free }
      let busy = events.map { TimeIntervalValue(start: $0.startDate, end: $0.endDate) }
      let minimum = TimeInterval((object.optionalInt("minimum_minutes", default: 30) ?? 30) * 60)
      let limit = object.optionalInt("limit", default: 50) ?? 50
      let result = CalendarAlgorithms.freeIntervals(
        range: TimeIntervalValue(start: start, end: end), busy: busy, minimumDuration: minimum,
        limit: limit)
      return .object([
        "intervals": .array(
          result.values.map {
            .object([
              "start": .string(ISO8601DateFormatter.agentString(from: $0.start)),
              "end": .string(ISO8601DateFormatter.agentString(from: $0.end)),
            ])
          }),
        "truncated": .bool(result.truncated),
      ])
    }

    private func readRange(_ object: [String: JSONValue]) throws -> (Date, Date) {
      let start = try parseDateTime(object.requiredString("start"), property: "start")
      let end = try parseDateTime(object.requiredString("end"), property: "end")
      guard start < end else { throw AgentError.invalid("start must be earlier than end") }
      // EventKit silently clips queries beyond four years. Bound requests to four 365-day years.
      guard end.timeIntervalSince(start) <= TimeInterval(Self.maximumReadRangeDays * 24 * 60 * 60) else {
        throw AgentError(code: "calendar_range_too_large",
          message: "Calendar queries must cover at most 1460 days; split longer periods into explicit ranges",
          details: [
            "requested_start": .string(try object.requiredString("start")),
            "requested_end": .string(try object.requiredString("end")),
            "requested_duration_seconds": .number(end.timeIntervalSince(start)),
            "maximum_days": .integer(Int64(Self.maximumReadRangeDays)),
            "maximum_duration_seconds": .integer(Int64(Self.maximumReadRangeDays * 24 * 60 * 60)),
          ], exitCode: 2)
      }
      return (start, end)
    }

    private func alarmValues(_ value: JSONValue?) -> [EKAlarm] {
      value?.arrayValue?.compactMap(\.intValue).map {
        EKAlarm(relativeOffset: TimeInterval($0 * 60))
      } ?? []
    }

    private func nullableStringUpdate(_ value: JSONValue?, property: String) throws -> String?? {
      guard let value else { return nil }
      switch value {
      case .null: return .some(nil)
      case .string(let string): return .some(string)
      default:
        throw AgentError.invalid(
          "Property must be a string or null",
          details: ["property": .string(property)]
        )
      }
    }

  #endif
}
