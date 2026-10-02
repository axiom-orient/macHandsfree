import Foundation
import MacHandsfreeCore

#if os(macOS)
  import CoreGraphics
  import EventKit

  /// Values observed for a reviewed mutation, not a replacement for EventKit's data store.
  enum RemindersMutationSnapshot {
    static let maximumBytes = 256 * 1_024
    static let maximumListItems = 500

    static func bounded(_ value: JSONValue) throws -> JSONValue {
      guard try value.encoded().count <= maximumBytes else {
        throw AgentError(
          code: "reminders_snapshot_too_large",
          message: "The reviewed Reminders state exceeds the snapshot limit; it was not truncated",
          details: ["maximum_bytes": .integer(Int64(maximumBytes))], exitCode: 6)
      }
      return value
    }

    static func source(_ source: EKSource) throws -> JSONValue {
      guard !source.sourceIdentifier.isEmpty else { throw unreadable("source_id") }
      return eventKitSourceJSON(source)
    }

    static func list(_ list: EKCalendar) throws -> JSONValue {
      guard !list.calendarIdentifier.isEmpty, let source = list.source else {
        throw unreadable("list_or_source")
      }
      let color: JSONValue
      if let nativeColor = list.cgColor {
        color = .object([
          "space": nativeColor.colorSpace?.name.map { .string($0 as String) } ?? .null,
          "components": try nativeColor.components.map { .array(try $0.map { try number(Double($0)) }) }
            ?? .null,
        ])
      } else {
        color = .null
      }
      return .object([
        "id": .string(list.calendarIdentifier), "name": .string(list.title),
        "source": try Self.source(source), "type": .integer(Int64(list.type.rawValue)),
        "editable": .bool(list.allowsContentModifications), "immutable": .bool(list.isImmutable),
        "subscribed": .bool(list.isSubscribed), "color": color,
        "entity_types": .integer(Int64(list.allowedEntityTypes.rawValue)),
      ])
    }

    static func item(_ reminder: EKReminder) throws -> JSONValue {
      let before = try bounded(itemFields(reminder))
      // Cached property getters alone cannot observe a change between two lastModifiedDate reads.
      guard !reminder.hasChanges, reminder.refresh() else { throw unreadable("reminder_refresh") }
      let current = try bounded(itemFields(reminder))
      guard try before.encoded() == current.encoded() else {
        throw AgentError(code: "plan_state_changed", message: "The reminder changed while being observed", exitCode: 6)
      }
      return current
    }

    private static func itemFields(_ reminder: EKReminder) throws -> JSONValue {
      let modified = reminder.lastModifiedDate
      guard !reminder.calendarItemIdentifier.isEmpty, let list = reminder.calendar else {
        throw unreadable("reminder_or_list")
      }
      let value: JSONValue = .object([
        "id": .string(reminder.calendarItemIdentifier),
        "external_id": string(reminder.calendarItemExternalIdentifier),
        "list_id": .string(list.calendarIdentifier), "title": string(reminder.title),
        "notes": string(reminder.notes), "location": string(reminder.location),
        "url": string(reminder.url?.absoluteString), "time_zone": string(reminder.timeZone?.identifier),
        "created_at": try date(reminder.creationDate), "modified_at": try date(modified),
        "completed": .bool(reminder.isCompleted), "completion_date": try date(reminder.completionDate),
        "priority": .integer(Int64(reminder.priority)),
        "start_components": components(reminder.startDateComponents),
        "due_components": components(reminder.dueDateComponents),
        "has_alarms": .bool(reminder.hasAlarms),
        "alarms": try reminder.alarms.map { .array(try $0.map(EventKitMutationSnapshot.alarm)) } ?? .null,
        "has_recurrence": .bool(reminder.hasRecurrenceRules),
        "recurrence": try reminder.recurrenceRules.map { .array(try $0.map(EventKitMutationSnapshot.recurrence)) } ?? .null,
        "has_attendees": .bool(reminder.hasAttendees),
        "attendees": reminder.attendees.map { .array($0.map(EventKitMutationSnapshot.participant)) } ?? .null,
      ])
      guard reminder.lastModifiedDate == modified else {
        throw AgentError(code: "plan_state_changed", message: "The reminder changed while being observed", exitCode: 6)
      }
      return value
    }

    static func members(_ reminders: [EKReminder]?, listID: String) throws -> [JSONValue] {
      guard let reminders else { throw unreadable("list_members") }
      guard reminders.count <= maximumListItems else {
        throw AgentError(
          code: "reminders_snapshot_too_large",
          message: "The list has too many reminders for a reviewed deletion; none were omitted",
          details: ["maximum_items": .integer(Int64(maximumListItems))], exitCode: 6)
      }
      var ids = Set<String>()
      var values: [JSONValue] = []
      var encodedBytes = 2 // The surrounding array brackets.
      for reminder in reminders {
        let value = try item(reminder)
        guard value["list_id"]?.stringValue == listID,
          ids.insert(reminder.calendarItemIdentifier).inserted
        else { throw unreadable("list_membership") }
        encodedBytes += try value.encoded().count + (values.isEmpty ? 0 : 1)
        guard encodedBytes <= maximumBytes else {
          throw AgentError(
            code: "reminders_snapshot_too_large",
            message: "The list contents exceed the reviewed snapshot limit; none were omitted",
            details: ["maximum_bytes": .integer(Int64(maximumBytes))], exitCode: 6)
        }
        values.append(value)
      }
      return values.sorted { ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "") }
    }

    private static func components(_ value: DateComponents?) -> JSONValue {
      guard let value else { return .null }
      return .object([
        "calendar": value.calendar.map { calendar in
          .object([
            "identifier": .string(String(describing: calendar.identifier)),
            "time_zone": .string(calendar.timeZone.identifier), "locale": string(calendar.locale?.identifier),
            "first_weekday": .integer(Int64(calendar.firstWeekday)),
            "minimum_days_in_first_week": .integer(Int64(calendar.minimumDaysInFirstWeek)),
          ])
        } ?? .null,
        "time_zone": string(value.timeZone?.identifier), "era": integer(value.era),
        "year": integer(value.year), "month": integer(value.month), "day": integer(value.day),
        "hour": integer(value.hour), "minute": integer(value.minute), "second": integer(value.second),
        "nanosecond": integer(value.nanosecond), "weekday": integer(value.weekday),
        "weekday_ordinal": integer(value.weekdayOrdinal), "quarter": integer(value.quarter),
        "week_of_month": integer(value.weekOfMonth), "week_of_year": integer(value.weekOfYear),
        "year_for_week_of_year": integer(value.yearForWeekOfYear),
        "leap_month": value.isLeapMonth.map(JSONValue.bool) ?? .null,
      ])
    }

    private static func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    private static func integer(_ value: Int?) -> JSONValue { value.map { .integer(Int64($0)) } ?? .null }
    private static func date(_ value: Date?) throws -> JSONValue {
      try value.map { try number($0.timeIntervalSinceReferenceDate) } ?? .null
    }
    private static func number(_ value: Double) throws -> JSONValue {
      guard value.isFinite else { throw unreadable("non_finite_number") }
      // Strings preserve precision and survive JSONValue's integer/number decode distinction.
      return .string(String(value))
    }
    private static func unreadable(_ field: String) -> AgentError {
      AgentError(code: "reminders_snapshot_unavailable", message: "The Reminders state could not be captured",
        details: ["field": .string(field)], exitCode: 6)
    }
  }
#endif
