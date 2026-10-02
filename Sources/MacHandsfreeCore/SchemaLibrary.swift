package enum SchemaLibrary {
  private static let id = JSONSchema.string(minLength: 1, maxLength: 2048, format: "identifier")
  private static let text = JSONSchema.string(maxLength: 1_000_000)
  private static let nonEmptyText = JSONSchema.string(minLength: 1, maxLength: 1_000_000)
  private static let shortText = JSONSchema.string(minLength: 1, maxLength: 2_000)
  private static let uri = JSONSchema.string(maxLength: 8_192, format: "uri")
  private static let path = JSONSchema.string(
    minLength: 1, maxLength: 8_192, format: "absolute-path")
  private static let dateTime = JSONSchema.string(format: "date-time")
  private static let allVisibleNotes = JSONSchema.boolean(
    description:
      "Set true only for an explicit request to use the full visible Notes scope. The JXA " +
      "listing does not classify special folder types or independently filter Recently Deleted.")
  private static let allCalendars = JSONSchema.boolean(
    description: "Set true only for an explicit request to read all visible calendars.")
  private static let allReminderLists = JSONSchema.boolean(
    description: "Set true only for an explicit request to read all visible Reminders lists.")
  private static let reminderDueStart = JSONSchema.string(
    format: "date-time", description: "Inclusive lower bound; if due_end is present, it must be earlier.")
  private static let reminderDueEnd = JSONSchema.string(
    format: "date-time", description: "Exclusive upper bound; if due_start is present, it must be later.")
  private static let reminderStartDateStart = JSONSchema.string(
    format: "date-time",
    description:
      "Inclusive lower bound for reminder start date/time; start_date_end must be later when present.")
  private static let reminderStartDateEnd = JSONSchema.string(
    format: "date-time",
    description:
      "Exclusive upper bound for reminder start date/time; start_date_start must be earlier when present.")
  private static let reminderAlarmStart = JSONSchema.string(
    format: "date-time",
    description: "Inclusive lower bound for absolute alarm time; relative alarms are excluded.")
  private static let reminderAlarmEnd = JSONSchema.string(
    format: "date-time",
    description: "Exclusive upper bound for absolute alarm time; alarm_start must be earlier.")
  private static let eventBoundary = JSONSchema.anyOf([
    dateTime,
    .string(format: "date"),
  ], description: "RFC3339 date-time or a date-only boundary for an all-day event; end is exclusive.")
  private static let reminderDate = JSONSchema.anyOf([
    dateTime,
    .string(format: "date"),
  ], description: "RFC3339 date-time or a YYYY-MM-DD all-day date.")
  private static let reminderAlarmDates = JSONSchema.array(
    items: dateTime, maxItems: 20,
    description: "Unique absolute alert times. Replaces time-based display alarms; geofences and custom actions are preserved. [] clears time-based display alarms.")
  private static let limit = JSONSchema.integer(minimum: 1, maximum: 500)
  private static let stringArray = JSONSchema.array(items: .string(maxLength: 8_192), maxItems: 500)
  private static let accessibilityBundleID = JSONSchema.string(
    minLength: 3, maxLength: 256, format: "identifier")
  private static let processIdentifier = JSONSchema.integer(minimum: 1, maximum: 2_147_483_647)
  private static let applicationLaunchDate = JSONSchema.anyOf(
    [dateTime, .null()],
    description: "Copy launch_date, including null, from the same app.list row.")
  private static let applicationProcessStartTime = JSONSchema.anyOf(
    [
      object([
        "seconds": .integer(minimum: 0),
        "microseconds": .integer(minimum: 0, maximum: 999_999),
      ], required: ["seconds", "microseconds"]),
      .null(),
    ],
    description: "Copy process_start_time, including null, from the same app.list row.")
  private static let accessibilityWindowIndex = JSONSchema.integer(minimum: 0, maximum: 63)
  private static let accessibilityPath = JSONSchema.array(
    items: .integer(minimum: 0, maximum: 255), minItems: 1, maxItems: 8)

  static func schema(for id: String) -> JSONSchema {
    switch id {
    case "version", "doctor", "calendar.calendars.list", "reminders.lists.list",
      "notes.accounts.list", "notes.selection.get", "mail.accounts.list",
      "mail.index.mailboxes.list",
      "contacts.groups.list", "safari.windows.list", "app.list",
      "clipboard.text.read", "clipboard.files.read", "shortcuts.items.list",
      "finder.selection.list", "system.info", "system.volume.get",
      "system.appearance.get", "system.wallpaper.get", "system.locale.get",
      "onboarding.accessibility.open":
      return empty()
    case "onboarding.privacy.open":
      return object(
        ["area": .string(values: ["accessibility", "contacts", "full_disk_access"])],
        required: ["area"])
    case "commands.list":
      return object(["domain": .string(minLength: 1, maxLength: 100)], required: [])
    case "commands.describe":
      return object(["id": idSchema()], required: ["id"])
    case "accessibility.windows.list":
      return object(
        [
          "bundle_id": accessibilityBundleID, "pid": processIdentifier,
          "launch_date": applicationLaunchDate,
          "process_start_time": applicationProcessStartTime,
        ],
        required: ["bundle_id", "pid", "launch_date", "process_start_time"])
    case "accessibility.tree.read":
      return object(
        [
          "bundle_id": accessibilityBundleID,
          "pid": processIdentifier,
          "launch_date": applicationLaunchDate,
          "process_start_time": applicationProcessStartTime,
          "window_id": accessibilityWindowIndex,
          "max_depth": .integer(minimum: 1, maximum: 8),
          "max_elements": .integer(minimum: 1, maximum: 256),
        ], required: ["bundle_id", "pid", "launch_date", "process_start_time", "window_id"])
    case "accessibility.elements.set_value":
      return object(
        [
          "bundle_id": accessibilityBundleID,
          "pid": processIdentifier,
          "launch_date": applicationLaunchDate,
          "process_start_time": applicationProcessStartTime,
          "window_id": accessibilityWindowIndex,
          "path": accessibilityPath,
          "value": .string(maxLength: 8_192),
        ], required: [
          "bundle_id", "pid", "launch_date", "process_start_time", "window_id", "path", "value",
        ])
    case "accessibility.elements.press":
      return object(
        [
          "bundle_id": accessibilityBundleID,
          "pid": processIdentifier,
          "launch_date": applicationLaunchDate,
          "process_start_time": applicationProcessStartTime,
          "window_id": accessibilityWindowIndex,
          "path": accessibilityPath,
        ], required: ["bundle_id", "pid", "launch_date", "process_start_time", "window_id", "path"])
    case "calendar.calendars.get": return identifier("calendar_id")
    case "calendar.events.get":
      return object(["event_id": idSchema(), "occurrence_start": dateTime], required: ["event_id"])
    case "calendar.events.list": return eventRange(query: false)
    case "calendar.events.search": return eventRange(query: true)
    case "calendar.events.create":
      return object(
        [
          "calendar_id": idSchema(), "title": shortText, "start": eventBoundary, "end": eventBoundary,
          "all_day": .boolean(
            description: "Set true for a whole-day event; date-only boundaries use the system time zone and exclusive end."),
          "location": .string(maxLength: 10_000), "notes": text,
          "url": uri,
          "availability": .string(values: [
            "not_supported", "busy", "free", "tentative", "unavailable",
          ]),
          "alarm_offsets_minutes": .array(
            items: .integer(minimum: -525_600, maximum: 525_600), maxItems: 20),
          "recurrence": recurrenceSchema(),
        ], required: ["calendar_id", "title", "start", "end"],
        description:
          "start must be earlier than end and both bounds must use the same date/date-time form. For an all-day event, use date-only values for both and set all_day to true.")
    case "calendar.events.update":
      return object(
        [
          "event_id": idSchema(), "occurrence_start": dateTime, "title": shortText, "start": eventBoundary,
          "end": eventBoundary,
          "all_day": .boolean(
            description: "Set true for a whole-day event; date-only boundaries use the existing event time zone and exclusive end."),
          "location": nullable(.string(maxLength: 10_000)),
          "notes": nullable(text),
          "url": nullable(uri),
          "availability": .string(values: [
            "not_supported", "busy", "free", "tentative", "unavailable",
          ]),
          "alarm_offsets_minutes": .array(
            items: .integer(minimum: -525_600, maximum: 525_600), maxItems: 20),
          "recurrence": nullable(recurrenceSchema()),
          "recurrence_scope": .string(values: ["this", "future"]),
        ], required: ["event_id"],
        description:
          "Provide at least one mutable field. If both start and end are supplied, they must use the same date/date-time form and start must be earlier. Date-only boundaries require an all-day event; do not set all_day to false.")
    case "calendar.events.delete":
      return object(
        [
          "event_id": idSchema(), "occurrence_start": dateTime,
          "recurrence_scope": .string(values: ["this", "future"]),
        ],
        required: ["event_id"])
    case "calendar.events.move":
      return object(
        [
          "event_id": idSchema(), "occurrence_start": dateTime, "calendar_id": idSchema(),
          "recurrence_scope": .string(values: ["this", "future"]),
        ], required: ["event_id", "calendar_id"])
    case "calendar.availability.find":
      return object(
        [
          "start": dateTime, "end": dateTime,
          "calendar_ids": .array(items: idSchema(), minItems: 1, maxItems: 100),
          "all_calendars": allCalendars,
          "minimum_minutes": .integer(minimum: 1, maximum: 10_080),
          "limit": limit,
        ], required: ["start", "end", "minimum_minutes"],
        description:
          "start must be earlier than end. Provide non-empty calendar_ids or set all_calendars to true; do not combine them.")

    case "reminders.lists.get": return identifier("list_id")
    case "reminders.lists.create":
      return object(
        ["source_id": idSchema(), "name": shortText, "color": .string(format: "hex-color")],
        required: ["source_id", "name"])
    case "reminders.lists.update":
      return object(
        ["list_id": idSchema(), "name": shortText, "color": .string(format: "hex-color")],
        required: ["list_id"], description: "Provide at least one mutable field: name or color.")
    case "reminders.lists.delete": return identifier("list_id")
    case "reminders.items.list":
      return object(
        [
          "list_ids": .array(items: idSchema(), minItems: 1, maxItems: 100),
          "all_reminder_lists": allReminderLists,
          "completed": .boolean(),
          "start_date_start": reminderStartDateStart, "start_date_end": reminderStartDateEnd,
          "due_start": reminderDueStart, "due_end": reminderDueEnd,
          "alarm_start": reminderAlarmStart, "alarm_end": reminderAlarmEnd,
          "limit": limit,
        ],
        description:
          "Provide non-empty list_ids or set all_reminder_lists to true; do not combine them.")
    case "reminders.items.get": return identifier("reminder_id")
    case "reminders.items.search":
      return object(
        [
          "query": shortText,
          "list_ids": .array(items: idSchema(), minItems: 1, maxItems: 100),
          "all_reminder_lists": allReminderLists,
          "completed": .boolean(),
          "start_date_start": reminderStartDateStart, "start_date_end": reminderStartDateEnd,
          "due_start": reminderDueStart, "due_end": reminderDueEnd,
          "alarm_start": reminderAlarmStart, "alarm_end": reminderAlarmEnd,
          "limit": limit,
        ], required: ["query"],
        description:
          "Provide non-empty list_ids or set all_reminder_lists to true; do not combine them.")
    case "reminders.items.create":
      return reminderMutation(required: ["list_id", "title"], includeID: false)
    case "reminders.items.update":
      return reminderMutation(required: ["reminder_id"], includeID: true)
    case "reminders.items.complete", "reminders.items.reopen", "reminders.items.delete":
      return identifier("reminder_id")
    case "reminders.items.move":
      return object(
        ["reminder_id": idSchema(), "list_id": idSchema()], required: ["reminder_id", "list_id"])

    case "notes.folders.list":
      return object(["account_id": idSchema()])
    case "notes.folders.create":
      return object(
        ["account_id": idSchema(), "parent_folder_id": idSchema(), "name": shortText],
        required: ["account_id", "name"])
    case "notes.folders.delete": return identifier("folder_id")
    case "notes.items.list":
      return object(
        [
          "account_id": idSchema(), "folder_id": idSchema(),
          "all_visible_notes": allVisibleNotes,
          "limit": limit,
        ],
        description:
          "Provide exactly one scope: account_id, folder_id, or all_visible_notes set to true.")
    case "notes.items.get": return identifier("note_id")
    case "notes.items.search":
      return object(
        [
          "query": shortText, "account_id": idSchema(), "folder_id": idSchema(),
          "all_visible_notes": allVisibleNotes,
          "include_body": .boolean(
            description: "Search plaintext body as well as title. Omitted means title-only. " +
              "Results contain metadata only."),
          "limit": limit,
          "scan_limit": .integer(
            minimum: 1, maximum: 2_000,
            description:
              "Inspects recent candidates after enumerating the selected scope; " +
              "addressable IDs are deduplicated. Defaults: 200 for body search, " +
              "2,000 for title-only. It does not limit JXA collection reads or ID " +
              "dedup; reaching it or missing IDs makes search coverage incomplete."),
        ], required: ["query"],
        description:
          "Provide exactly one scope: account_id, folder_id, or all_visible_notes set to true.")
    case "notes.items.create":
      return object(
        [
          "account_id": idSchema(), "folder_id": idSchema(), "title": shortText, "body": text,
          "format": .string(values: ["plaintext", "html"]),
        ],
        required: ["title", "body"],
        description:
          "Provide exactly one destination: account_id selects its default Notes folder; folder_id selects a folder."
      )
    case "notes.items.update":
      return object(
        [
          "note_id": idSchema(), "title": shortText, "body": text,
          "format": .string(values: ["plaintext", "html"]),
        ], required: ["note_id"],
        description: "Provide title or body to change; format is only valid with body.")
    case "notes.items.move":
      return object(
        ["note_id": idSchema(), "account_id": idSchema(), "folder_id": idSchema()],
        required: ["note_id"],
        description:
          "Provide exactly one destination: account_id selects its default Notes folder; folder_id selects a folder."
      )
    case "notes.items.delete": return identifier("note_id")
    case "notes.items.export":
      return object(
        [
          "note_id": idSchema(), "path": path, "format": .string(values: ["html", "plaintext"]),
          "overwrite": .boolean(),
        ], required: ["note_id", "path", "format"])

    case "mail.mailboxes.list": return object(["account_id": idSchema()])
    case "mail.index.messages.search":
      return object(
        [
          "query": shortText,
          "mailbox_url": .string(minLength: 1, maxLength: 2_048),
          "unread_only": .boolean(), "limit": limit,
          "scan_limit": .integer(minimum: 1, maximum: 1_000),
        ], required: ["query"])
    case "mail.index.messages.get":
      return object(
        [
          "mail_index_id": idSchema(),
          "mailbox_url": .string(minLength: 1, maxLength: 2_048),
          "attachment_index": .integer(
            minimum: 0, maximum: 49,
            description: "Optional index from this message get to read one attachment."),
        ], required: ["mail_index_id", "mailbox_url"])
    case "mail.messages.list":
      return object(
        ["mailbox_id": idSchema(), "unread_only": .boolean(), "limit": limit],
        required: ["mailbox_id"])
    case "mail.messages.get": return identifier("message_id")
    case "mail.messages.search":
      return object(
        [
          "query": shortText, "mailbox_id": idSchema(), "unread_only": .boolean(), "limit": limit,
          "scan_limit": .integer(minimum: 1, maximum: 100_000),
        ],
        required: ["query"])
    case "mail.drafts.create", "mail.messages.send": return mailCompose()
    case "mail.drafts.get", "mail.drafts.send": return identifier("draft_id")
    case "mail.messages.reply":
      return object(
        [
          "message_id": idSchema(), "body": text, "reply_all": .boolean(), "send": .boolean(),
          "account_id": idSchema(), "sender_address": .string(minLength: 3, maxLength: 320, format: "email"),
        ],
        required: ["message_id", "body"])
    case "mail.messages.forward":
      return object(
        [
          "message_id": idSchema(), "to": emailArray(minItems: 1), "cc": emailArray(), "body": text,
          "send": .boolean(), "account_id": idSchema(),
          "sender_address": .string(minLength: 3, maxLength: 320, format: "email"),
        ], required: ["message_id", "to"])
    case "mail.messages.move":
      return object(
        ["message_id": idSchema(), "mailbox_id": idSchema()],
        required: ["message_id", "mailbox_id"])
    case "mail.messages.set-read":
      return object(
        ["message_id": idSchema(), "read": .boolean()], required: ["message_id", "read"])

    case "contacts.items.list": return object(["container_id": idSchema(), "limit": limit])
    case "contacts.items.get": return identifier("contact_id")
    case "contacts.items.search":
      return object(["query": shortText, "limit": limit], required: ["query"])
    case "contacts.items.create": return contactMutation(required: ["given_name"])
    case "contacts.items.update":
      var properties = contactProperties()
      properties["contact_id"] = idSchema()
      return object(
        properties, required: ["contact_id"],
        description: "Provide at least one contact field to change in addition to contact_id.")
    case "contacts.items.delete": return identifier("contact_id")

    case "safari.tabs.list": return object(["window_id": .integer(minimum: 1)])
    case "safari.tabs.get": return safariTabIdentifier()
    case "safari.tabs.open":
      return object(
        [
          "url": .string(minLength: 1, maxLength: 8_192, format: "uri"),
          "window_id": .integer(minimum: 1), "activate": .boolean(),
        ], required: ["url"])
    case "safari.tabs.close", "safari.tabs.activate": return safariTabIdentifier()
    case "safari.reading-list.add":
      return object(
        [
          "url": .string(minLength: 1, maxLength: 8_192, format: "uri"),
          "title": .string(maxLength: 2_000), "preview_text": .string(maxLength: 20_000),
        ], required: ["url"])

    case "messages.chats.list": return object(["limit": limit])
    case "messages.messages.list":
      return object(
        ["chat_id": .integer(minimum: 1), "limit": limit, "before_row_id": .integer(minimum: 1)],
        required: ["chat_id"])
    case "messages.messages.search":
      return object(
        [
          "query": shortText, "chat_id": .integer(minimum: 1),
          "before_row_id": .integer(
            minimum: 1,
            description:
              "Resume the previous search at next_before_row_id with the same query and chat scope."),
          "limit": .integer(
            minimum: 1, maximum: 500,
            description:
              "Maximum returned matches; pass next_before_row_id to continue the result page."),
          "scan_limit": .integer(
            minimum: 1, maximum: 1_000,
            description:
              "Maximum local message rows inspected in ROWID descending order across " +
                "message.text and attributedBody search; chat_id filters within each row window. " +
                "Coverage reports when more rows remain."),
        ], required: ["query"])
    case "messages.attachments.list":
      return object([
        "chat_id": .integer(minimum: 1), "message_id": .integer(minimum: 1), "limit": limit,
      ])
    case "messages.send.text":
      return object(
        [
          "handle": shortText, "chat_guid": idSchema(), "text": nonEmptyText,
          "service": .string(values: ["auto", "iMessage", "RCS", "SMS"]),
        ], required: ["text"],
        description: "Provide exactly one destination: handle or chat_guid.")
    case "messages.send.file":
      return object(
        [
          "handle": shortText, "chat_guid": idSchema(), "path": path,
          "service": .string(values: ["auto", "iMessage", "RCS", "SMS"]),
        ], required: ["path"],
        description: "Provide exactly one destination: handle or chat_guid.")

    case "calls.video.start", "calls.video.confirm":
      return object(["handle": shortText], required: ["handle"])
    case "calls.video.end": return empty()

    case "files.list":
      return object(
        ["path": path, "recursive": .boolean(), "include_hidden": .boolean(), "limit": limit],
        required: ["path"])
    case "files.stat": return object(["path": path], required: ["path"])
    case "files.read":
      return object(
        [
          "path": path, "encoding": .string(values: ["utf8", "base64"]),
          "max_bytes": .integer(minimum: 1, maximum: 64 * 1_024 * 1_024),
        ], required: ["path"])
    case "files.search":
      return object([
        "path": path, "query": .string(minLength: 1, maxLength: 512),
        "kind": .string(values: ["name", "content", "both"]),
        "case_sensitive": .boolean(), "include_hidden": .boolean(),
        "exclude_directories": .array(items: .string(minLength: 1, maxLength: 256), maxItems: 32),
        "limit": .integer(minimum: 1, maximum: WorkspaceToolPolicy.Search.maximumResultLimit),
        "scan_limit": .integer(minimum: 1, maximum: WorkspaceToolPolicy.Search.maximumScanLimit),
      ], required: ["path", "query"])
    case "files.patch":
      return object([
        "path": path,
        "edits": .array(items: object([
          "before": .string(minLength: 1, maxLength: WorkspaceToolPolicy.Patch.maximumEditCharacters),
          "after": .string(maxLength: WorkspaceToolPolicy.Patch.maximumEditCharacters),
        ], required: ["before", "after"]), minItems: 1, maxItems: WorkspaceToolPolicy.Patch.maximumEdits),
      ], required: ["path", "edits"])
    case "process.run":
      return object([
        "executable": path, "cwd": path,
        "arguments": .array(items: .string(maxLength: WorkspaceToolPolicy.Process.maximumArgumentCharacters), maxItems: WorkspaceToolPolicy.Process.maximumArguments),
        "timeout_seconds": .integer(minimum: 1, maximum: WorkspaceToolPolicy.Process.maximumTimeout),
        "max_output_bytes": .integer(minimum: 1_024, maximum: WorkspaceToolPolicy.Process.maximumOutputBytes),
      ], required: ["executable", "cwd", "arguments"])
    case "files.write":
      return object(
        [
          "path": path, "content": .string(maxLength: 64 * 1_024 * 1_024),
          "encoding": .string(values: ["utf8", "base64"]), "create_parents": .boolean(),
          "overwrite": .boolean(),
        ], required: ["path", "content"])
    case "files.mkdir":
      return object(["path": path, "parents": .boolean()], required: ["path"])
    case "files.copy", "files.move":
      return object(
        [
          "source": path, "destination": path, "overwrite": .boolean(),
          "create_parents": .boolean(),
        ], required: ["source", "destination"],
        description: "source and destination must be different paths.")
    case "files.delete":
      return object(["path": path, "recursive": .boolean()], required: ["path"])

    case "system.volume.set":
      return object(["value": .integer(minimum: 0, maximum: 100)], required: ["value"])
    case "system.volume.mute": return object(["muted": .boolean()], required: ["muted"])
    case "system.appearance.set":
      return object(["appearance": .string(values: ["light", "dark"])], required: ["appearance"])
    case "system.wallpaper.set":
      return object(["path": path, "display": .integer(minimum: 0)], required: ["path"])
    case "system.settings.open":
      return object(
        ["url": .string(minLength: 1, maxLength: 8_192, format: "uri")], required: ["url"])
    case "system.sleep", "system.restart", "system.shutdown": return empty()

    case "app.launch":
      return object(
        [
          "bundle_id": idSchema(),
          "name": .string(
            minLength: 1, maxLength: 2_000,
            description: "Passed as-is to /usr/bin/open -a; this adapter does not resolve a unique bundle ID."),
          "arguments": stringArray,
        ],
        description:
          "Provide exactly one of bundle_id or name. Optional arguments are passed to the app after --args.")
    case "app.activate", "app.quit":
      return object(
        [
          "bundle_id": idSchema(), "pid": processIdentifier,
          "launch_date": applicationLaunchDate,
          "process_start_time": applicationProcessStartTime,
        ], required: ["bundle_id", "pid", "launch_date", "process_start_time"])
    case "clipboard.text.write": return object(["text": text], required: ["text"])
    case "clipboard.files.write":
      return object(["paths": .array(items: path, minItems: 1, maxItems: 500)], required: ["paths"])
    case "shortcuts.items.get": return object(["name": shortText], required: ["name"])
    case "shortcuts.items.run":
      return object(
        ["name": shortText, "input_path": path, "output_path": path], required: ["name"])
    case "finder.reveal": return object(["path": path], required: ["path"])
    case "spotlight.search":
      return object(["query": shortText, "scope": path, "limit": limit], required: ["query"])
    case "spotlight.metadata.get":
      return object(["path": path, "attributes": stringArray], required: ["path"])
    default:
      preconditionFailure("Missing schema for canonical command: \(id)")
    }
  }

  package static var executeSchema: JSONSchema {
    object(
      [
        "plan_token": .string(minLength: 20, maxLength: 4_096),
        "idempotency_key": .string(minLength: 8, maxLength: 200),
      ], required: ["plan_token", "idempotency_key"])
  }

  private static func nullable(_ schema: JSONSchema) -> JSONSchema {
    .anyOf([schema, .null()])
  }
  private static func empty() -> JSONSchema { object([:]) }
  private static func idSchema() -> JSONSchema { id }
  private static func identifier(_ key: String) -> JSONSchema {
    object([key: idSchema()], required: [key])
  }
  private static func object(
    _ properties: [String: JSONSchema], required: Set<String> = [], description: String? = nil
  ) -> JSONSchema {
    .object(
      properties: properties, required: required, additionalProperties: false,
      description: description)
  }
  private static func eventRange(query: Bool) -> JSONSchema {
    var properties: [String: JSONSchema] = [
      "start": dateTime, "end": dateTime,
      "calendar_ids": .array(items: idSchema(), minItems: 1, maxItems: 100),
      "all_calendars": allCalendars,
      "include_all_day": .boolean(), "limit": limit,
    ]
    var required: Set<String> = ["start", "end"]
    if query {
      properties["query"] = shortText
      required.insert("query")
    }
    return object(
      properties, required: required,
      description:
        "start must be earlier than end. Provide non-empty calendar_ids or set all_calendars to true; do not combine them.")
  }
  private static func recurrenceSchema() -> JSONSchema {
    object(
      [
        "frequency": .string(values: ["daily", "weekly", "monthly", "yearly"]),
        "interval": .integer(minimum: 1, maximum: 999),
        "count": .integer(
          minimum: 1, maximum: 10_000, description: "Occurrence count; do not combine with end."),
        "end": .string(
          format: "date-time", description: "RFC3339 end instant; do not combine with count."),
        "days_of_week": .array(
          items: object(
            [
              "day": .integer(minimum: 1, maximum: 7,
                description: "Sunday is 1; Saturday is 7."),
              "week": .integer(minimum: -53, maximum: 53,
                description: "0 means any week; positive values select an ordinal; negative values count backward."),
            ], required: ["day"]),
          minItems: 1, maxItems: 512,
          description: "Use with weekly, monthly, or yearly frequency; week must be 0 for weekly."),
        "days_of_month": .array(
          items: .integer(minimum: -31, maximum: 31,
            description: "Use a nonzero day; negative values count backward from month end."),
          minItems: 1, maxItems: 62, description: "Only for monthly frequency."),
        "months_of_year": .array(
          items: .integer(minimum: 1, maximum: 12), minItems: 1, maxItems: 12,
          description: "Only for yearly frequency."),
        "weeks_of_year": .array(
          items: .integer(minimum: -53, maximum: 53,
            description: "Use a nonzero week; negative values count backward from year end."),
          minItems: 1, maxItems: 106, description: "Only for yearly frequency."),
        "days_of_year": .array(
          items: .integer(minimum: -366, maximum: 366,
            description: "Use a nonzero day; negative values count backward from year end."),
          minItems: 1, maxItems: 732, description: "Only for yearly frequency."),
        "set_positions": .array(
          items: .integer(minimum: -366, maximum: 366,
            description: "Use a nonzero position to filter occurrences in each frequency interval."),
          minItems: 1, maxItems: 732,
          description: "Only for weekly, monthly, or yearly frequency."),
      ], required: ["frequency"])
  }
  private static func reminderMutation(required: Set<String>, includeID: Bool) -> JSONSchema {
    var properties: [String: JSONSchema] = [
      "list_id": idSchema(),
      "title": shortText,
      "notes": nullable(text),
      "url": nullable(uri),
      "start": nullable(reminderDate),
      "due": nullable(reminderDate),
      "alarm_dates": reminderAlarmDates,
      "recurrence": nullable(recurrenceSchema()),
      "priority": .integer(minimum: 0, maximum: 9),
    ]
    if includeID { properties["reminder_id"] = idSchema() }
    return object(
      properties, required: required,
      description: includeID ? "Provide at least one mutable field besides reminder_id." : nil)
  }
  private static func emailArray(minItems: Int? = nil) -> JSONSchema {
    .array(
      items: .string(minLength: 3, maxLength: 320, format: "email"),
      minItems: minItems, maxItems: 200)
  }
  private static func mailCompose() -> JSONSchema {
    object(
      [
        "to": emailArray(minItems: 1), "cc": emailArray(), "bcc": emailArray(),
        "subject": .string(maxLength: 2_000),
        "body": text, "attachments": .array(items: path, maxItems: 100), "account_id": idSchema(),
        "sender_address": .string(minLength: 3, maxLength: 320, format: "email"),
      ], required: ["to", "subject", "body"])
  }
  private static func contactProperties() -> [String: JSONSchema] {
    [
      "given_name": .string(minLength: 1, maxLength: 1_000),
      "family_name": .string(maxLength: 1_000),
      "organization": .string(maxLength: 2_000), "job_title": .string(maxLength: 2_000),
      "emails": .array(
        items: object(
          ["label": .string(maxLength: 100), "value": .string(maxLength: 320, format: "email")],
          required: ["value"]), maxItems: 100),
      "phones": .array(
        items: object(
          ["label": .string(maxLength: 100), "value": .string(minLength: 1, maxLength: 100)],
          required: ["value"]),
        maxItems: 100),
      "note": nullable(.string(maxLength: 100_000)),
    ]
  }
  private static func contactMutation(required: Set<String>) -> JSONSchema {
    object(contactProperties(), required: required)
  }
  private static func safariTabIdentifier() -> JSONSchema {
    object(
      ["window_id": .integer(minimum: 1), "tab_index": .integer(minimum: 1)],
      required: ["window_id", "tab_index"])
  }
}
