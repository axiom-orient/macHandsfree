import Foundation
import MacHandsfreeCore

#if os(macOS)
  import EventKit

  enum EventKitRecurrenceRuleFactory {
    private struct WeekdaySelection: Hashable {
      let day: Int
      let week: Int
    }

    static func parse(_ value: JSONValue, after anchorDate: Date? = nil) throws
      -> [EKRecurrenceRule]?
    {
      if value == .null { return nil }
      guard let recurrence = value.objectValue else {
        throw AgentError.invalid("recurrence must be an object or null")
      }

      let frequency: EKRecurrenceFrequency
      switch recurrence["frequency"]?.stringValue {
      case "daily": frequency = .daily
      case "weekly": frequency = .weekly
      case "monthly": frequency = .monthly
      case "yearly": frequency = .yearly
      default: throw AgentError.invalid("Invalid recurrence frequency")
      }

      let interval = try optionalInteger(recurrence["interval"], property: "interval") ?? 1
      guard (1...999).contains(interval) else {
        throw AgentError.invalid("recurrence.interval must be between 1 and 999")
      }
      let count = try optionalInteger(recurrence["count"], property: "count")
      if let count, !(1...10_000).contains(count) {
        throw AgentError.invalid("recurrence.count must be between 1 and 10000")
      }
      let endText: String?
      switch recurrence["end"] {
      case nil: endText = nil
      case .some(.string(let value)): endText = value
      default: throw AgentError.invalid("recurrence.end must be an RFC3339 date-time")
      }
      guard count == nil || endText == nil else {
        throw AgentError.invalid("recurrence may specify count or end, not both")
      }

      let recurrenceEnd: EKRecurrenceEnd?
      if let count {
        recurrenceEnd = EKRecurrenceEnd(occurrenceCount: count)
      } else if let endText {
        let end = try parseDateTime(endText, property: "recurrence.end")
        if let anchorDate, end <= anchorDate {
          throw AgentError.invalid("recurrence.end must be later than its first occurrence")
        }
        recurrenceEnd = EKRecurrenceEnd(end: end)
      } else {
        recurrenceEnd = nil
      }

      let daysOfWeek = try parseDaysOfWeek(recurrence["days_of_week"], frequency: frequency)
      let daysOfMonth = try parseIntegers(
        recurrence["days_of_month"], property: "days_of_month", range: -31...31,
        maximumCount: 62)
      let monthsOfYear = try parseIntegers(
        recurrence["months_of_year"], property: "months_of_year", range: 1...12,
        maximumCount: 12)
      let weeksOfYear = try parseIntegers(
        recurrence["weeks_of_year"], property: "weeks_of_year", range: -53...53,
        maximumCount: 106)
      let daysOfYear = try parseIntegers(
        recurrence["days_of_year"], property: "days_of_year", range: -366...366,
        maximumCount: 732)
      let setPositions = try parseIntegers(
        recurrence["set_positions"], property: "set_positions", range: -366...366,
        maximumCount: 732)

      if daysOfMonth != nil, frequency != .monthly {
        throw AgentError.invalid("recurrence.days_of_month requires monthly frequency")
      }
      if (monthsOfYear != nil || weeksOfYear != nil || daysOfYear != nil), frequency != .yearly {
        throw AgentError.invalid(
          "months_of_year, weeks_of_year, and days_of_year require yearly frequency")
      }
      if setPositions != nil, frequency == .daily {
        throw AgentError.invalid("recurrence.set_positions does not apply to daily frequency")
      }

      return [
        EKRecurrenceRule(
          recurrenceWith: frequency,
          interval: interval,
          daysOfTheWeek: daysOfWeek,
          daysOfTheMonth: nativeNumbers(daysOfMonth),
          monthsOfTheYear: nativeNumbers(monthsOfYear),
          weeksOfTheYear: nativeNumbers(weeksOfYear),
          daysOfTheYear: nativeNumbers(daysOfYear),
          setPositions: nativeNumbers(setPositions),
          end: recurrenceEnd
        )
      ]
    }

    private static func nativeNumbers(_ values: [Int]?) -> [NSNumber]? {
      values?.map { NSNumber(value: $0) }
    }

    private static func parseDaysOfWeek(
      _ value: JSONValue?, frequency: EKRecurrenceFrequency
    ) throws -> [EKRecurrenceDayOfWeek]? {
      guard let value else { return nil }
      guard let entries = value.arrayValue, !entries.isEmpty, entries.count <= 512 else {
        throw AgentError.invalid("recurrence.days_of_week must contain 1 to 512 entries")
      }
      guard frequency != .daily else {
        throw AgentError.invalid("recurrence.days_of_week does not apply to daily frequency")
      }

      var seen = Set<WeekdaySelection>()
      return try entries.map { entry in
        guard let object = entry.objectValue,
          let day = object["day"]?.intValue, (1...7).contains(day)
        else { throw AgentError.invalid("Each days_of_week entry requires day from 1 to 7") }
        let week = try optionalInteger(object["week"], property: "days_of_week.week") ?? 0
        guard (-53...53).contains(week) else {
          throw AgentError.invalid("days_of_week.week must be between -53 and 53")
        }
        guard frequency != .weekly || week == 0 else {
          throw AgentError.invalid("days_of_week.week must be 0 for weekly frequency")
        }
        guard seen.insert(WeekdaySelection(day: day, week: week)).inserted,
          let weekday = EKWeekday(rawValue: day)
        else {
          throw AgentError.invalid("days_of_week entries must be unique valid weekdays")
        }
        return EKRecurrenceDayOfWeek(dayOfTheWeek: weekday, weekNumber: week)
      }
    }

    private static func parseIntegers(
      _ value: JSONValue?, property: String, range: ClosedRange<Int>, maximumCount: Int
    ) throws -> [Int]? {
      guard let value else { return nil }
      guard let entries = value.arrayValue, !entries.isEmpty, entries.count <= maximumCount else {
        throw AgentError.invalid("recurrence.\(property) has an invalid number of entries")
      }
      var seen = Set<Int>()
      return try entries.map { entry in
        guard let number = entry.intValue, range.contains(number), number != 0,
          seen.insert(number).inserted
        else {
          throw AgentError.invalid(
            "recurrence.\(property) contains an invalid or duplicate value")
        }
        return number
      }
    }

    private static func optionalInteger(_ value: JSONValue?, property: String) throws -> Int? {
      guard let value else { return nil }
      guard let number = value.intValue else {
        throw AgentError.invalid("recurrence.\(property) must be an integer")
      }
      return number
    }
  }
#endif
