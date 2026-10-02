import Foundation

package enum CommandInputValidator {
  package static func validate(command: CommandSpec, input: JSONValue) throws {
    guard let object = input.objectValue else {
      throw AgentError.invalid("Input must be a JSON object")
    }

    switch command.id {
    case "messages.send.text", "messages.send.file":
      try requireExactlyOne(object, keys: ["handle", "chat_guid"])
    case "app.launch":
      try requireExactlyOne(object, keys: ["bundle_id", "name"])
    case "calendar.events.list", "calendar.events.search", "calendar.availability.find":
      try requireIncreasingRange(object, startKey: "start", endKey: "end")
    case "calendar.events.create":
      try requireIncreasingRange(object, startKey: "start", endKey: "end")
      try validateAllDayBoundaries(object, creating: true)
      try validateRecurrence(object["recurrence"])
    case "reminders.items.list", "reminders.items.search":
      try requireIncreasingRangeIfPresent(object, startKey: "start_date_start", endKey: "start_date_end")
      try requireIncreasingRangeIfPresent(object, startKey: "due_start", endKey: "due_end")
      try requireIncreasingRangeIfPresent(object, startKey: "alarm_start", endKey: "alarm_end")
    case "notes.items.create", "notes.items.move":
      try requireExactlyOne(object, keys: ["account_id", "folder_id"])
    case "calendar.events.update":
      try requireMutationField(object, excluding: ["event_id", "occurrence_start", "recurrence_scope"])
      try validateRecurrence(object["recurrence"])
      try requireIncreasingRangeIfPresent(object, startKey: "start", endKey: "end")
      try validateAllDayBoundaries(object, creating: false)
    case "reminders.lists.update":
      try requireMutationField(object, excluding: ["list_id"])
    case "reminders.items.update":
      try requireMutationField(object, excluding: ["reminder_id"])
    case "notes.items.update":
      try requireMutationField(object, excluding: ["note_id", "format"])
      if object["format"] != nil, object["body"] == nil {
        throw AgentError.invalid("format is only valid when body is provided")
      }
    case "contacts.items.update":
      try requireMutationField(object, excluding: ["contact_id"])
    case "files.copy", "files.move":
      if object["source"]?.stringValue == object["destination"]?.stringValue {
        throw AgentError.invalid("source and destination must be different paths")
      }
    default:
      break
    }

  }

  private static func requireExactlyOne(_ object: [String: JSONValue], keys: [String]) throws {
    let present = keys.filter { object[$0] != nil }
    guard present.count == 1 else {
      throw AgentError.invalid(
        "Provide exactly one selector",
        details: [
          "allowed": .array(keys.map(JSONValue.string)),
          "present": .array(present.map(JSONValue.string)),
        ]
      )
    }
  }

  private static func requireMutationField(_ object: [String: JSONValue], excluding: Set<String>)
    throws
  {
    guard object.keys.contains(where: { !excluding.contains($0) }) else {
      throw AgentError.invalid("Update command does not contain any mutable field")
    }
  }

  private static func requireIncreasingRange(
    _ object: [String: JSONValue],
    startKey: String,
    endKey: String
  ) throws {
    guard let startText = object[startKey]?.stringValue,
      let endText = object[endKey]?.stringValue,
      let start = rangeDate(startText), let end = rangeDate(endText)
    else {
      return
    }
    guard start.isDateOnly == end.isDateOnly else {
      throw AgentError.invalid(
        "Start and end must both be date-only or both be date-time",
        details: ["start_property": .string(startKey), "end_property": .string(endKey)])
    }
    guard start.date < end.date else {
      throw AgentError.invalid(
        "Start must be earlier than end",
        details: ["start_property": .string(startKey), "end_property": .string(endKey)]
      )
    }
  }

  private static func rangeDate(_ value: String) -> (date: Date, isDateOnly: Bool)? {
    if let date = JSONSchema.parseRFC3339(value) { return (date, false) }
    if let date = JSONSchema.parseDateOnly(value) { return (date, true) }
    return nil
  }

  private static func validateAllDayBoundaries(
    _ object: [String: JSONValue], creating: Bool
  ) throws {
    let startIsDateOnly = object["start"]?.stringValue.flatMap(JSONSchema.parseDateOnly) != nil
    let endIsDateOnly = object["end"]?.stringValue.flatMap(JSONSchema.parseDateOnly) != nil
    guard startIsDateOnly || endIsDateOnly else { return }
    if creating {
      guard startIsDateOnly, endIsDateOnly, object["all_day"]?.boolValue == true else {
        throw AgentError.invalid(
          "Date-only calendar boundaries require all_day=true and both start/end dates")
      }
    } else if object["all_day"]?.boolValue == false {
      throw AgentError.invalid(
        "Date-only calendar boundaries require an all-day event")
    }
  }

  private static func requireIncreasingRangeIfPresent(
    _ object: [String: JSONValue],
    startKey: String,
    endKey: String
  ) throws {
    guard object[startKey] != nil, object[endKey] != nil else { return }
    try requireIncreasingRange(object, startKey: startKey, endKey: endKey)
  }

  private static func validateRecurrence(_ value: JSONValue?) throws {
    guard let object = value?.objectValue else { return }
    if object["count"] != nil, object["end"] != nil {
      throw AgentError.invalid("Recurrence must use either count or end, not both")
    }
  }
}
