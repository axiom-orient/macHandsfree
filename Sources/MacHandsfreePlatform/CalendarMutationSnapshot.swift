import Foundation
import MacHandsfreeCore

#if os(macOS)
  import EventKit

  /// Public EventKit state for one selected occurrence, not a revision for every series exception.
  enum CalendarMutationSnapshot {
    static let maximumBytes = 256 * 1_024
    static let maximumOccurrenceCandidates = 512

    static func bounded(_ value: JSONValue) throws -> JSONValue {
      guard try value.encoded().count <= maximumBytes else {
        throw AgentError(code: "calendar_snapshot_too_large",
          message: "The reviewed Calendar state exceeds the snapshot limit; it was not truncated",
          details: ["maximum_bytes": .integer(Int64(maximumBytes))], exitCode: 6)
      }
      return value
    }

    static func calendar(_ calendar: EKCalendar) throws -> JSONValue {
      guard !calendar.calendarIdentifier.isEmpty, let source = calendar.source,
        !source.sourceIdentifier.isEmpty
      else { throw unavailable("calendar_or_source") }
      return .object([
        "id": .string(calendar.calendarIdentifier), "title": .string(calendar.title),
        "type": .integer(Int64(calendar.type.rawValue)),
        "source": eventKitSourceJSON(source),
        "editable": .bool(calendar.allowsContentModifications),
        "subscribed": .bool(calendar.isSubscribed),
        "entity_types": .integer(Int64(calendar.allowedEntityTypes.rawValue)),
        "supported_availabilities": .integer(Int64(calendar.supportedEventAvailabilities.rawValue)),
      ])
    }

    static func event(_ event: EKEvent) throws -> JSONValue {
      let before = try bounded(eventFields(event))
      guard !event.hasChanges, event.refresh() else { throw unavailable("event_refresh") }
      let current = try bounded(eventFields(event))
      guard try before.encoded() == current.encoded() else {
        throw AgentError(code: "plan_state_changed", message: "The selected event changed while being observed", exitCode: 6)
      }
      return current
    }

    /// Produce the existing result shape from the captured values, without another native read.
    static func presentation(_ snapshot: JSONValue) throws -> JSONValue {
      guard let value = snapshot.objectValue,
        let status = value["status"]?.intValue, let availability = value["availability"]?.intValue
      else { throw unavailable("event_result") }
      let alarms = try (value["alarms"]?.arrayValue ?? []).map { alarm -> JSONValue in
        guard let raw = alarm["relative_offset"]?.stringValue, let offset = Double(raw), offset.isFinite else {
          throw unavailable("alarm_result")
        }
        return .object([
          "relative_offset_seconds": .number(offset),
          "absolute_date": try displayedDate(alarm["absolute_date"]),
        ])
      }
      return .object([
        "id": value["id"] ?? .null, "calendar_item_id": value["calendar_item_id"] ?? .null,
        "external_id": value["external_id"] ?? .null, "calendar_id": value["calendar_id"] ?? .null,
        "title": .string(value["title"]?.stringValue ?? ""),
        "start": try displayedDate(value["start"]), "end": try displayedDate(value["end"]),
        "occurrence_start": value["occurrence_start"] ?? .null,
        "original_occurrence": try displayedDate(value["original_occurrence"]),
        "detached": value["detached"] ?? .null, "all_day": value["all_day"] ?? .null,
        "time_zone": value["time_zone"] ?? .null,
        "location": value["location"] ?? .null, "notes": value["notes"] ?? .null,
        "url": value["url"] ?? .null,
        "status": .string(eventStatus(status)),
        "availability": .string(eventAvailability(availability)),
        "recurring": value["has_recurrence"] ?? .null, "alarms": .array(alarms),
      ])
    }

    private static func displayedDate(_ value: JSONValue?) throws -> JSONValue {
      guard let value, value != .null else { return .null }
      guard let text = value.stringValue, let seconds = Double(text), seconds.isFinite else {
        throw unavailable("date_result")
      }
      return .string(ISO8601DateFormatter.agentString(from: Date(timeIntervalSinceReferenceDate: seconds)))
    }

    private static func eventFields(_ event: EKEvent) throws -> JSONValue {
      guard let id = event.eventIdentifier, !id.isEmpty,
        !event.calendarItemIdentifier.isEmpty, let calendar = event.calendar,
        let start = event.startDate, let end = event.endDate
      else { throw unavailable("event_identity_or_dates") }
      return .object([
        "id": .string(id), "calendar_item_id": .string(event.calendarItemIdentifier),
        "external_id": EventKitMutationSnapshot.string(event.calendarItemExternalIdentifier),
        "calendar_id": .string(calendar.calendarIdentifier),
        "start": try EventKitMutationSnapshot.date(start), "end": try EventKitMutationSnapshot.date(end),
        "occurrence_start": .string(ISO8601DateFormatter.agentString(from: start)),
        "original_occurrence": try EventKitMutationSnapshot.date(event.occurrenceDate),
        "detached": .bool(event.isDetached), "all_day": .bool(event.isAllDay),
        "time_zone": EventKitMutationSnapshot.string(event.timeZone?.identifier),
        "title": EventKitMutationSnapshot.string(event.title),
        "location": EventKitMutationSnapshot.string(event.location),
        "structured_location": try event.structuredLocation.map(EventKitMutationSnapshot.structuredLocation) ?? .null,
        "notes": EventKitMutationSnapshot.string(event.notes),
        "url": EventKitMutationSnapshot.string(event.url?.absoluteString),
        "created_at": try EventKitMutationSnapshot.date(event.creationDate),
        "modified_at": try EventKitMutationSnapshot.date(event.lastModifiedDate),
        "status": .integer(Int64(event.status.rawValue)),
        "availability": .integer(Int64(event.availability.rawValue)),
        "has_alarms": .bool(event.hasAlarms),
        "alarms": try event.alarms.map { .array(try $0.map(EventKitMutationSnapshot.alarm)) } ?? .null,
        "has_recurrence": .bool(event.hasRecurrenceRules),
        "recurrence": try event.recurrenceRules.map { .array(try $0.map(EventKitMutationSnapshot.recurrence)) } ?? .null,
        "has_attendees": .bool(event.hasAttendees),
        "attendees": event.attendees.map { .array($0.map(EventKitMutationSnapshot.participant)) } ?? .null,
        "organizer": event.organizer.map(EventKitMutationSnapshot.participant) ?? .null,
      ])
    }

    private static func unavailable(_ field: String) -> AgentError {
      AgentError(code: "calendar_snapshot_unavailable", message: "The Calendar state could not be captured",
        details: ["field": .string(field)], exitCode: 6)
    }
  }
#endif
