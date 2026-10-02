import Foundation
import MacHandsfreeCore

func parseDateTime(_ value: String, property: String) throws -> Date {
  guard let date = JSONSchema.parseRFC3339(value) else {
    throw AgentError.invalid(
      "Invalid RFC3339 date-time",
      details: ["property": .string(property), "value": .string(value)])
  }
  return date
}

#if os(macOS)
  struct ReminderDateValue: Sendable {
    let components: DateComponents
    let date: Date
  }

  func parseReminderDate(_ value: String, property: String) throws -> ReminderDateValue {
    if let date = JSONSchema.parseRFC3339(value) {
      let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
      return ReminderDateValue(components: components, date: date)
    }
    guard JSONSchema.parseDateOnly(value) != nil else {
      throw AgentError.invalid(
        "Reminder \(property) must be an RFC3339 date-time or YYYY-MM-DD date",
        details: ["property": .string(property), "value": .string(value)])
    }
    let fields = value.split(separator: "-").compactMap { Int($0) }
    guard fields.count == 3 else {
      throw AgentError.invalid("Reminder \(property) date-only value must use YYYY-MM-DD")
    }
    // Keep hour/minute/second absent and the component zone floating for an all-day reminder date.
    let (calendar, components) = dateOnlyComponents(
      year: fields[0], month: fields[1], day: fields[2], timeZone: .current)
    guard let date = calendar.date(from: components) else {
      throw AgentError.invalid(
        "Reminder \(property) date-only value is not a valid local calendar date",
        details: ["property": .string(property), "value": .string(value)])
    }
    return ReminderDateValue(components: components, date: date)
  }

  func reminderDateFromComponents(_ components: DateComponents?) -> Date? {
    guard let components else { return nil }
    var calendar = components.calendar ?? Calendar(identifier: .gregorian)
    if let timeZone = components.timeZone { calendar.timeZone = timeZone }
    return calendar.date(from: components)
  }

  func parseCalendarBoundary(
    _ value: String, property: String, allDay: Bool, timeZone: TimeZone
  ) throws -> Date {
    if let date = JSONSchema.parseRFC3339(value) { return date }
    guard allDay, JSONSchema.parseDateOnly(value) != nil else {
      throw AgentError.invalid(
        "Calendar boundary must be an RFC3339 date-time; YYYY-MM-DD requires all_day=true",
        details: ["property": .string(property), "value": .string(value)])
    }
    let fields = value.split(separator: "-").compactMap { Int($0) }
    guard fields.count == 3 else {
      throw AgentError.invalid("Calendar all-day date must use YYYY-MM-DD")
    }
    let (calendar, components) = dateOnlyComponents(
      year: fields[0], month: fields[1], day: fields[2], timeZone: timeZone)
    guard let date = calendar.date(from: components) else {
      throw AgentError.invalid(
        "Calendar all-day date is not valid in the event time zone",
        details: ["property": .string(property), "value": .string(value)])
    }
    return date
  }

  private func dateOnlyComponents(
    year: Int, month: Int, day: Int, timeZone: TimeZone
  ) -> (calendar: Calendar, components: DateComponents) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var components = DateComponents()
    components.calendar = calendar
    components.year = year
    components.month = month
    components.day = day
    return (calendar, components)
  }
#endif
