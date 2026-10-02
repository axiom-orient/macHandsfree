import Foundation
import MacHandsfreeCore

struct ReminderSnapshot: Sendable, Equatable {
  let id: String
  let listID: String
  let title: String
  let notes: String?
  let url: String?
  let recurrence: JSONValue?
  let completed: Bool
  let completionDate: Date?
  let alarms: [JSONValue]
  let startComponents: DateComponents?
  let start: Date?
  let dueComponents: DateComponents?
  let due: Date?
  let priority: Int

  var json: JSONValue {
    .object([
      "id": .string(id),
      "list_id": .string(listID),
      "title": .string(title),
      "notes": notes.map(JSONValue.string) ?? .null,
      "url": url.map(JSONValue.string) ?? .null,
      "recurrence": recurrence ?? .null,
      "completed": .bool(completed),
      "completion_date": completionDate.map {
        .string(ISO8601DateFormatter.agentString(from: $0))
      } ?? .null,
      "alarms": .array(alarms),
      "start": start.map { .string(ISO8601DateFormatter.agentString(from: $0)) } ?? .null,
      "start_components": startComponents.map(reminderDateComponentsJSON) ?? .null,
      "start_is_all_day": allDayValue(startComponents),
      "due": due.map { .string(ISO8601DateFormatter.agentString(from: $0)) } ?? .null,
      "due_components": dueComponents.map(reminderDateComponentsJSON) ?? .null,
      "due_is_all_day": allDayValue(dueComponents),
      "priority": .integer(Int64(priority)),
    ])
  }
}

private func allDayValue(_ components: DateComponents?) -> JSONValue {
  components.map { .bool($0.hour == nil && $0.minute == nil && $0.second == nil) } ?? .null
}

private func reminderDateComponentsJSON(_ components: DateComponents) -> JSONValue {
  func integer(_ value: Int?) -> JSONValue { value.map { .integer(Int64($0)) } ?? .null }
  return .object([
    "calendar": .string(String(describing: components.calendar?.identifier ?? .gregorian)),
    "calendar_time_zone": components.calendar.map { .string($0.timeZone.identifier) } ?? .null,
    "time_zone": components.timeZone.map { .string($0.identifier) } ?? .null,
    "year": integer(components.year), "month": integer(components.month), "day": integer(components.day),
    "hour": integer(components.hour), "minute": integer(components.minute),
    "second": integer(components.second), "nanosecond": integer(components.nanosecond),
  ])
}
