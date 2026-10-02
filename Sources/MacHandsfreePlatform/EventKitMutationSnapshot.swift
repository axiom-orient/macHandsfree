import Foundation
import MacHandsfreeCore

#if os(macOS)
  import CoreLocation
  import EventKit

  /// Shared serialization of the same EventKit values; each service owns capture and mutation policy.
  enum EventKitMutationSnapshot {
    static func recurrence(_ rule: EKRecurrenceRule) throws -> JSONValue {
      .object([
        "calendar": .string(rule.calendarIdentifier), "frequency": .integer(Int64(rule.frequency.rawValue)),
        "interval": .integer(Int64(rule.interval)), "first_weekday": .integer(Int64(rule.firstDayOfTheWeek)),
        "days_of_week": rule.daysOfTheWeek.map { .array($0.map {
          .object(["day": .integer(Int64($0.dayOfTheWeek.rawValue)), "week": .integer(Int64($0.weekNumber))])
        }) } ?? .null,
        "days_of_month": numbers(rule.daysOfTheMonth), "days_of_year": numbers(rule.daysOfTheYear),
        "weeks_of_year": numbers(rule.weeksOfTheYear), "months_of_year": numbers(rule.monthsOfTheYear),
        "set_positions": numbers(rule.setPositions),
        "end": try rule.recurrenceEnd.map {
          .object(["date": try date($0.endDate), "count": .integer(Int64($0.occurrenceCount))])
        } ?? .null,
      ])
    }

    static func alarm(_ alarm: EKAlarm) throws -> JSONValue {
      .object([
        "relative_offset": try number(alarm.relativeOffset), "absolute_date": try date(alarm.absoluteDate),
        "proximity": .integer(Int64(alarm.proximity.rawValue)), "type": .integer(Int64(alarm.type.rawValue)),
        "email_address": string(alarm.emailAddress), "sound_name": string(alarm.soundName),
        // Current macOS does not expose the URL of an existing procedure alarm.
        "structured_location": try alarm.structuredLocation.map(structuredLocation) ?? .null,
      ])
    }

    static func alarmPresentation(_ alarm: EKAlarm) throws -> JSONValue {
      let absoluteDate: JSONValue
      if let date = alarm.absoluteDate {
        try requireFiniteSnapshotNumber(date.timeIntervalSinceReferenceDate)
        absoluteDate = .string(ISO8601DateFormatter.agentString(from: date))
      } else {
        absoluteDate = .null
      }
      let location: JSONValue
      if let structuredLocation = alarm.structuredLocation {
        let coordinate = structuredLocation.geoLocation?.coordinate
        location = .object([
          "title": string(structuredLocation.title),
          "radius_meters": try displayNumber(structuredLocation.radius),
          "latitude": try coordinate.map { try displayNumber($0.latitude) } ?? .null,
          "longitude": try coordinate.map { try displayNumber($0.longitude) } ?? .null,
        ])
      } else {
        location = .null
      }
      return .object([
        "relative_offset_seconds": try displayNumber(alarm.relativeOffset),
        "absolute_date": absoluteDate,
        "proximity_code": .integer(Int64(alarm.proximity.rawValue)),
        "type_code": .integer(Int64(alarm.type.rawValue)),
        "email_address": string(alarm.emailAddress), "sound_name": string(alarm.soundName),
        "structured_location": location,
      ])
    }

    static func structuredLocation(_ location: EKStructuredLocation) throws -> JSONValue {
      .object([
        "title": string(location.title), "radius": try number(location.radius),
        "coordinate": try location.geoLocation.map {
          .object(["latitude": try number($0.coordinate.latitude), "longitude": try number($0.coordinate.longitude)])
        } ?? .null,
      ])
    }

    static func participant(_ person: EKParticipant) -> JSONValue {
      .object([
        "url": .string(person.url.absoluteString), "name": string(person.name),
        "role": .integer(Int64(person.participantRole.rawValue)),
        "status": .integer(Int64(person.participantStatus.rawValue)),
        "type": .integer(Int64(person.participantType.rawValue)), "current_user": .bool(person.isCurrentUser),
      ])
    }

    static func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

    static func date(_ value: Date?) throws -> JSONValue {
      try value.map { try number($0.timeIntervalSinceReferenceDate) } ?? .null
    }

    static func number(_ value: Double) throws -> JSONValue {
      try requireFiniteSnapshotNumber(value)
      // Preserve floating-point precision and JSONValue's integer/number round-trip distinction.
      return .string(String(value))
    }

    private static func requireFiniteSnapshotNumber(_ value: Double) throws {
      guard value.isFinite else {
        throw AgentError(code: "eventkit_snapshot_unavailable",
          message: "An EventKit snapshot contains a non-finite number", exitCode: 6)
      }
    }

    private static func displayNumber(_ value: Double) throws -> JSONValue {
      guard value.isFinite else {
        throw AgentError(code: "eventkit_snapshot_unavailable",
          message: "An EventKit alarm contains a non-finite number", exitCode: 6)
      }
      return .number(value)
    }

    private static func numbers(_ values: [NSNumber]?) -> JSONValue {
      values.map { .array($0.map { .integer($0.int64Value) }) } ?? .null
    }
  }
#endif
