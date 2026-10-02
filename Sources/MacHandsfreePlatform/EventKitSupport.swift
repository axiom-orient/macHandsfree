import Foundation
import MacHandsfreeCore

#if os(macOS)
  import EventKit

  /// Shared field projection only. Callers retain their own identity/refresh/error checks.
  func eventKitSourceJSON(_ source: EKSource) -> JSONValue {
    .object([
      "id": .string(source.sourceIdentifier), "title": .string(source.title),
      "type": .integer(Int64(source.sourceType.rawValue)), "delegate": .bool(source.isDelegate),
    ])
  }

  func eventJSON(_ event: EKEvent) -> JSONValue {
    let identifier: JSONValue = event.eventIdentifier.map(JSONValue.string) ?? .null
    let start: JSONValue =
      event.startDate.map {
        .string(ISO8601DateFormatter.agentString(from: $0))
      } ?? .null
    let end: JSONValue =
      event.endDate.map {
        .string(ISO8601DateFormatter.agentString(from: $0))
      } ?? .null
    let location: JSONValue = event.location.map(JSONValue.string) ?? .null
    let notes: JSONValue = event.notes.map(JSONValue.string) ?? .null
    let url: JSONValue = event.url.map { .string($0.absoluteString) } ?? .null
    let alarms = JSONValue.array(
      (event.alarms ?? []).map { alarm in
        JSONValue.object([
          "relative_offset_seconds": .number(alarm.relativeOffset),
          "absolute_date": alarm.absoluteDate.map {
            .string(ISO8601DateFormatter.agentString(from: $0))
          } ?? .null,
        ])
      })
    return .object([
      "id": identifier,
      "calendar_item_id": .string(event.calendarItemIdentifier),
      "external_id": event.calendarItemExternalIdentifier.map(JSONValue.string) ?? .null,
      "calendar_id": event.calendar.map { .string($0.calendarIdentifier) } ?? .null,
      "title": .string(event.title ?? ""),
      "start": start,
      // This selector is the current start returned by this lookup, including for detached events.
      "occurrence_start": start,
      "original_occurrence": event.occurrenceDate.map {
        .string(ISO8601DateFormatter.agentString(from: $0))
      } ?? .null,
      "detached": .bool(event.isDetached),
      "end": end,
      "all_day": .bool(event.isAllDay),
      "time_zone": event.timeZone.map { .string($0.identifier) } ?? .null,
      "location": location,
      "notes": notes,
      "url": url,
      "status": .string(eventStatus(event.status)),
      "availability": .string(eventAvailability(event.availability)),
      "recurring": .bool(event.hasRecurrenceRules),
      "alarms": alarms,
    ])
  }

  private let eventStatusLabels: [Int: String] = [
    Int(EKEventStatus.none.rawValue): "none", Int(EKEventStatus.confirmed.rawValue): "confirmed",
    Int(EKEventStatus.tentative.rawValue): "tentative", Int(EKEventStatus.canceled.rawValue): "canceled",
  ]
  private let eventAvailabilityLabels: [Int: String] = [
    Int(EKEventAvailability.notSupported.rawValue): "not_supported",
    Int(EKEventAvailability.busy.rawValue): "busy", Int(EKEventAvailability.free.rawValue): "free",
    Int(EKEventAvailability.tentative.rawValue): "tentative",
    Int(EKEventAvailability.unavailable.rawValue): "unavailable",
  ]

  func eventStatus(_ status: EKEventStatus) -> String {
    guard let raw = Int(exactly: status.rawValue) else { return "unknown" }
    return eventStatus(raw)
  }
  func eventStatus(_ raw: Int) -> String { eventStatusLabels[raw] ?? "unknown" }

  func eventAvailability(_ value: EKEventAvailability) -> String {
    guard let raw = Int(exactly: value.rawValue) else { return "unknown" }
    return eventAvailability(raw)
  }
  func eventAvailability(_ raw: Int) -> String { eventAvailabilityLabels[raw] ?? "unknown" }

  func parseAvailability(_ value: String) throws -> EKEventAvailability {
    switch value {
    case "not_supported": .notSupported
    case "busy": .busy
    case "free": .free
    case "tentative": .tentative
    case "unavailable": .unavailable
    default: throw AgentError.invalid("Unknown event availability")
    }
  }
  func span(_ value: String?) -> EKSpan { value == "future" ? .futureEvents : .thisEvent }
#endif
