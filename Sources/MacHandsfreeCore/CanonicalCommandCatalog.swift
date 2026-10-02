extension CommandRegistry {
  static let canonicalCommands: [CommandSpec] = [
    CommandSpec(
      id: "version", path: ["version"], summary: "Return product and schema versions.",
      kind: .read, risk: .low, service: "core", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "version")
    ),
    CommandSpec(
      id: "commands.list", path: ["commands", "list"], summary: "List canonical agent commands.",
      kind: .read, risk: .low, service: "core", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "commands.list")
    ),
    CommandSpec(
      id: "commands.describe", path: ["commands", "describe"],
      summary: "Describe one canonical command.",
      kind: .read, risk: .low, service: "core", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "commands.describe")
    ),
    CommandSpec(
      id: "doctor", path: ["doctor"],
      summary: "Inspect runtime dependencies and permission readiness without changing state.",
      kind: .read, risk: .low, service: "core", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "doctor")
    ),
    CommandSpec(
      id: "onboarding.accessibility.open", path: ["onboarding", "accessibility", "open"],
      summary: "Open the macOS Accessibility settings page without changing any permission.",
      kind: .mutation, risk: .low, service: "onboarding", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "onboarding.accessibility.open")
    ),
    CommandSpec(
      id: "onboarding.privacy.open", path: ["onboarding", "privacy", "open"],
      summary: "Open one macOS privacy settings page without changing any permission.",
      kind: .mutation, risk: .low, service: "onboarding", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "onboarding.privacy.open")
    ),
    CommandSpec(
      id: "accessibility.windows.list", path: ["accessibility", "windows", "list"],
      summary: "List windows for one app.list process identity.",
      kind: .read, risk: .low, service: "accessibility", permissions: ["accessibility"],
      inputSchema: SchemaLibrary.schema(for: "accessibility.windows.list")
    ),
    CommandSpec(
      id: "accessibility.tree.read", path: ["accessibility", "tree", "read"],
      summary: "Read a bounded tree from one app.list process and exact window.",
      kind: .read, risk: .low, service: "accessibility", permissions: ["accessibility"],
      inputSchema: SchemaLibrary.schema(for: "accessibility.tree.read")
    ),
    CommandSpec(
      id: "accessibility.elements.set_value", path: ["accessibility", "elements", "set-value"],
      summary: "Set an exact text value in an approved accessibility element.",
      kind: .mutation, risk: .medium, service: "accessibility", permissions: ["accessibility"],
      inputSchema: SchemaLibrary.schema(for: "accessibility.elements.set_value")
    ),
    CommandSpec(
      id: "accessibility.elements.press", path: ["accessibility", "elements", "press"],
      summary: "Press one exact accessibility element after approval.",
      kind: .mutation, risk: .high, service: "accessibility", permissions: ["accessibility"],
      inputSchema: SchemaLibrary.schema(for: "accessibility.elements.press")
    ),
    CommandSpec(
      id: "calendar.calendars.list", path: ["calendar", "calendars", "list"],
      summary: "List calendars.",
      kind: .read, risk: .low, service: "calendar", permissions: ["calendar"],
      inputSchema: SchemaLibrary.schema(for: "calendar.calendars.list")
    ),
    CommandSpec(
      id: "calendar.calendars.get", path: ["calendar", "calendars", "get"],
      summary: "Get one calendar by identifier.",
      kind: .read, risk: .low, service: "calendar", permissions: ["calendar"],
      inputSchema: SchemaLibrary.schema(for: "calendar.calendars.get")
    ),
    CommandSpec(
      id: "calendar.events.list", path: ["calendar", "events", "list"],
      summary: "List events in an exact time range and selected calendar scope.",
      kind: .read, risk: .low, service: "calendar", permissions: ["calendar"],
      inputSchema: SchemaLibrary.schema(for: "calendar.events.list")
    ),
    CommandSpec(
      id: "calendar.events.get", path: ["calendar", "events", "get"],
      summary: "Get one event by identifier.",
      kind: .read, risk: .low, service: "calendar", permissions: ["calendar"],
      inputSchema: SchemaLibrary.schema(for: "calendar.events.get")
    ),
    CommandSpec(
      id: "calendar.events.search", path: ["calendar", "events", "search"],
      summary: "Search events in an exact time range and selected calendar scope.",
      kind: .read, risk: .low, service: "calendar", permissions: ["calendar"],
      inputSchema: SchemaLibrary.schema(for: "calendar.events.search")
    ),
    CommandSpec(
      id: "calendar.events.create", path: ["calendar", "events", "create"],
      summary: "Create a timed or all-day event in an exact calendar.",
      kind: .mutation, risk: .medium, service: "calendar", permissions: ["calendar"],
      inputSchema: SchemaLibrary.schema(for: "calendar.events.create")
    ),
    CommandSpec(
      id: "calendar.events.update", path: ["calendar", "events", "update"],
      summary: "Update an exact event, including its all-day status.",
      kind: .mutation, risk: .medium, service: "calendar", permissions: ["calendar"],
      inputSchema: SchemaLibrary.schema(for: "calendar.events.update")
    ),
    CommandSpec(
      id: "calendar.events.delete", path: ["calendar", "events", "delete"],
      summary: "Delete an exact event.",
      kind: .mutation, risk: .high, service: "calendar", permissions: ["calendar"],
      inputSchema: SchemaLibrary.schema(for: "calendar.events.delete")
    ),
    CommandSpec(
      id: "calendar.events.move", path: ["calendar", "events", "move"],
      summary: "Move an event to an exact calendar.",
      kind: .mutation, risk: .medium, service: "calendar", permissions: ["calendar"],
      inputSchema: SchemaLibrary.schema(for: "calendar.events.move")
    ),
    CommandSpec(
      id: "calendar.availability.find", path: ["calendar", "availability", "find"],
      summary: "Find free intervals in a selected calendar scope.",
      kind: .read, risk: .low, service: "calendar", permissions: ["calendar"],
      inputSchema: SchemaLibrary.schema(for: "calendar.availability.find")
    ),
    CommandSpec(
      id: "reminders.lists.list", path: ["reminders", "lists", "list"],
      summary: "List reminder lists.",
      kind: .read, risk: .low, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.lists.list")
    ),
    CommandSpec(
      id: "reminders.lists.get", path: ["reminders", "lists", "get"],
      summary: "Get one reminder list by identifier.",
      kind: .read, risk: .low, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.lists.get")
    ),
    CommandSpec(
      id: "reminders.lists.create", path: ["reminders", "lists", "create"],
      summary: "Create a reminder list in an exact source.",
      kind: .mutation, risk: .medium, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.lists.create")
    ),
    CommandSpec(
      id: "reminders.lists.update", path: ["reminders", "lists", "update"],
      summary: "Rename an exact reminder list.",
      kind: .mutation, risk: .medium, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.lists.update")
    ),
    CommandSpec(
      id: "reminders.lists.delete", path: ["reminders", "lists", "delete"],
      summary: "Delete an exact reminder list.",
      kind: .mutation, risk: .high, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.lists.delete")
    ),
    CommandSpec(
      id: "reminders.items.list", path: ["reminders", "items", "list"],
      summary: "List selected reminders with optional start, due, and alarm time filters.",
      kind: .read, risk: .low, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.items.list")
    ),
    CommandSpec(
      id: "reminders.items.get", path: ["reminders", "items", "get"],
      summary: "Get one reminder by identifier.",
      kind: .read, risk: .low, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.items.get")
    ),
    CommandSpec(
      id: "reminders.items.search", path: ["reminders", "items", "search"],
      summary: "Search selected reminder lists with optional start, due, and alarm time filters.",
      kind: .read, risk: .low, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.items.search")
    ),
    CommandSpec(
      id: "reminders.items.create", path: ["reminders", "items", "create"],
      summary: "Create an exact-list reminder with optional start, due, absolute alert times, repeat rule, and source URL.",
      kind: .mutation, risk: .medium, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.items.create")
    ),
    CommandSpec(
      id: "reminders.items.update", path: ["reminders", "items", "update"],
      summary: "Update a reminder's start, due, absolute alert times, repeat rule, and source URL.",
      kind: .mutation, risk: .medium, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.items.update")
    ),
    CommandSpec(
      id: "reminders.items.complete", path: ["reminders", "items", "complete"],
      summary: "Mark an exact reminder complete.",
      kind: .mutation, risk: .medium, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.items.complete")
    ),
    CommandSpec(
      id: "reminders.items.reopen", path: ["reminders", "items", "reopen"],
      summary: "Reopen an exact reminder.",
      kind: .mutation, risk: .medium, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.items.reopen")
    ),
    CommandSpec(
      id: "reminders.items.move", path: ["reminders", "items", "move"],
      summary: "Move a reminder to an exact list.",
      kind: .mutation, risk: .medium, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.items.move")
    ),
    CommandSpec(
      id: "reminders.items.delete", path: ["reminders", "items", "delete"],
      summary: "Delete an exact reminder.",
      kind: .mutation, risk: .high, service: "reminders", permissions: ["reminders"],
      inputSchema: SchemaLibrary.schema(for: "reminders.items.delete")
    ),
    CommandSpec(
      id: "notes.accounts.list", path: ["notes", "accounts", "list"],
      summary: "List Notes accounts.",
      kind: .read, risk: .low, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.accounts.list")
    ),
    CommandSpec(
      id: "notes.folders.list", path: ["notes", "folders", "list"], summary: "List Notes folders.",
      kind: .read, risk: .low, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.folders.list")
    ),
    CommandSpec(
      id: "notes.folders.create", path: ["notes", "folders", "create"],
      summary: "Create a Notes folder.",
      kind: .mutation, risk: .medium, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.folders.create")
    ),
    CommandSpec(
      id: "notes.folders.delete", path: ["notes", "folders", "delete"],
      summary:
        "Delete an ordinary Notes folder; preview includes affected subtree counts, sharing impact, and account-dependent recovery.",
      kind: .mutation, risk: .high, service: "notes",
      permissions: ["automation:Notes", "full-disk-access"],
      inputSchema: SchemaLibrary.schema(for: "notes.folders.delete")
    ),
    CommandSpec(
      id: "notes.items.list", path: ["notes", "items", "list"],
      summary: "List Notes in a selected scope or all visible Notes by explicit request.",
      kind: .read, risk: .low, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.items.list")
    ),
    CommandSpec(
      id: "notes.items.get", path: ["notes", "items", "get"],
      summary: "Get one note by identifier.",
      kind: .read, risk: .low, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.items.get")
    ),
    CommandSpec(
      id: "notes.items.search", path: ["notes", "items", "search"],
      summary:
        "Search titles or optional body in one selected Notes scope. " +
        "Results are metadata; check coverage and read exact matches.",
      kind: .read, risk: .low, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.items.search")
    ),
    CommandSpec(
      id: "notes.items.create", path: ["notes", "items", "create"],
      summary: "Create a note in an exact account's default folder or a selected folder.",
      kind: .mutation, risk: .medium, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.items.create")
    ),
    CommandSpec(
      id: "notes.items.update", path: ["notes", "items", "update"],
      summary: "Update an exact note.",
      kind: .mutation, risk: .medium, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.items.update")
    ),
    CommandSpec(
      id: "notes.items.move", path: ["notes", "items", "move"],
      summary: "Move an exact note to an account's default folder or a selected folder.",
      kind: .mutation, risk: .medium, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.items.move")
    ),
    CommandSpec(
      id: "notes.items.delete", path: ["notes", "items", "delete"],
      summary:
        "Delete an exact note outside Recently Deleted; preview warns about shared effects and account-dependent recovery.",
      kind: .mutation, risk: .high, service: "notes",
      permissions: ["automation:Notes", "full-disk-access"],
      inputSchema: SchemaLibrary.schema(for: "notes.items.delete")
    ),
    CommandSpec(
      id: "notes.items.export", path: ["notes", "items", "export"],
      summary: "Export one note to an exact file path.",
      kind: .mutation, risk: .medium, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.items.export")
    ),
    CommandSpec(
      id: "notes.selection.get", path: ["notes", "selection", "get"],
      summary: "Read the current Notes selection when exposed by the app.",
      kind: .read, risk: .low, service: "notes", permissions: ["automation:Notes"],
      inputSchema: SchemaLibrary.schema(for: "notes.selection.get")
    ),
    CommandSpec(
      id: "mail.accounts.list", path: ["mail", "accounts", "list"], summary: "List Mail accounts.",
      kind: .read, risk: .low, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.accounts.list")
    ),
    CommandSpec(
      id: "mail.mailboxes.list", path: ["mail", "mailboxes", "list"],
      summary: "List Mail mailboxes.",
      kind: .read, risk: .low, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.mailboxes.list")
    ),
    CommandSpec(
      id: "mail.index.mailboxes.list", path: ["mail", "index", "mailboxes", "list"],
      summary: "List mailboxes visible in Apple's local Mail index. Requires Full Disk Access.",
      kind: .read, risk: .low, service: "mail", permissions: ["full-disk-access"],
      inputSchema: SchemaLibrary.schema(for: "mail.index.mailboxes.list")
    ),
    CommandSpec(
      id: "mail.index.messages.search", path: ["mail", "index", "messages", "search"],
      summary: "Search downloaded Mail message bodies through the read-only local index. Requires Full Disk Access.",
      kind: .read, risk: .low, service: "mail", permissions: ["full-disk-access"],
      inputSchema: SchemaLibrary.schema(for: "mail.index.messages.search")
    ),
    CommandSpec(
      id: "mail.index.messages.get", path: ["mail", "index", "messages", "get"],
      summary:
        "Read one downloaded Mail message, optionally extracting text from one listed attachment. The index row is read-only.",
      kind: .read, risk: .low, service: "mail", permissions: ["full-disk-access"],
      inputSchema: SchemaLibrary.schema(for: "mail.index.messages.get")
    ),
    CommandSpec(
      id: "mail.messages.list", path: ["mail", "messages", "list"], summary: "List mail messages.",
      kind: .read, risk: .low, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.messages.list")
    ),
    CommandSpec(
      id: "mail.messages.get", path: ["mail", "messages", "get"], summary: "Get one mail message.",
      kind: .read, risk: .low, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.messages.get")
    ),
    CommandSpec(
      id: "mail.messages.search", path: ["mail", "messages", "search"],
      summary: "Search mail messages.",
      kind: .read, risk: .low, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.messages.search")
    ),
    CommandSpec(
      id: "mail.drafts.create", path: ["mail", "drafts", "create"], summary: "Create a Mail draft.",
      kind: .mutation, risk: .medium, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.drafts.create")
    ),
    CommandSpec(
      id: "mail.drafts.get", path: ["mail", "drafts", "get"],
      summary: "Read one existing Mail outgoing draft for review.",
      kind: .read, risk: .low, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.drafts.get")
    ),
    CommandSpec(
      id: "mail.drafts.send", path: ["mail", "drafts", "send"],
      summary: "Send an existing Mail draft after reviewing its exact current contents and recipients.",
      kind: .mutation, risk: .high, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.drafts.send")
    ),
    CommandSpec(
      id: "mail.messages.send", path: ["mail", "messages", "send"],
      summary: "Send a new mail message.",
      kind: .mutation, risk: .high, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.messages.send")
    ),
    CommandSpec(
      id: "mail.messages.reply", path: ["mail", "messages", "reply"],
      summary: "Create a native reply draft; a send request requires subsequent draft review and approved mail.drafts.send.",
      kind: .mutation, risk: .high, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.messages.reply")
    ),
    CommandSpec(
      id: "mail.messages.forward", path: ["mail", "messages", "forward"],
      summary: "Create a native forward draft; a send request requires subsequent draft review and approved mail.drafts.send.",
      kind: .mutation, risk: .high, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.messages.forward")
    ),
    CommandSpec(
      id: "mail.messages.move", path: ["mail", "messages", "move"],
      summary: "Move one mail message to an exact mailbox.",
      kind: .mutation, risk: .medium, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.messages.move")
    ),
    CommandSpec(
      id: "mail.messages.set-read", path: ["mail", "messages", "set-read"],
      summary: "Set the read state of one mail message.",
      kind: .mutation, risk: .medium, service: "mail", permissions: ["automation:Mail"],
      inputSchema: SchemaLibrary.schema(for: "mail.messages.set-read")
    ),
    CommandSpec(
      id: "contacts.items.list", path: ["contacts", "items", "list"], summary: "List contacts.",
      kind: .read, risk: .low, service: "contacts", permissions: ["contacts"],
      inputSchema: SchemaLibrary.schema(for: "contacts.items.list")
    ),
    CommandSpec(
      id: "contacts.items.get", path: ["contacts", "items", "get"],
      summary: "Get one contact by identifier.",
      kind: .read, risk: .low, service: "contacts", permissions: ["contacts"],
      inputSchema: SchemaLibrary.schema(for: "contacts.items.get")
    ),
    CommandSpec(
      id: "contacts.items.search", path: ["contacts", "items", "search"],
      summary: "Search contacts.",
      kind: .read, risk: .low, service: "contacts", permissions: ["contacts"],
      inputSchema: SchemaLibrary.schema(for: "contacts.items.search")
    ),
    CommandSpec(
      id: "contacts.items.create", path: ["contacts", "items", "create"],
      summary: "Create a contact.",
      kind: .mutation, risk: .medium, service: "contacts", permissions: ["contacts"],
      inputSchema: SchemaLibrary.schema(for: "contacts.items.create")
    ),
    CommandSpec(
      id: "contacts.items.update", path: ["contacts", "items", "update"],
      summary: "Update an exact contact.",
      kind: .mutation, risk: .medium, service: "contacts", permissions: ["contacts"],
      inputSchema: SchemaLibrary.schema(for: "contacts.items.update")
    ),
    CommandSpec(
      id: "contacts.items.delete", path: ["contacts", "items", "delete"],
      summary: "Delete an exact contact.",
      kind: .mutation, risk: .high, service: "contacts", permissions: ["contacts"],
      inputSchema: SchemaLibrary.schema(for: "contacts.items.delete")
    ),
    CommandSpec(
      id: "contacts.groups.list", path: ["contacts", "groups", "list"],
      summary: "List contact groups.",
      kind: .read, risk: .low, service: "contacts", permissions: ["contacts"],
      inputSchema: SchemaLibrary.schema(for: "contacts.groups.list")
    ),
    CommandSpec(
      id: "safari.windows.list", path: ["safari", "windows", "list"],
      summary: "List Safari windows.",
      kind: .read, risk: .low, service: "safari", permissions: ["automation:Safari"],
      inputSchema: SchemaLibrary.schema(for: "safari.windows.list")
    ),
    CommandSpec(
      id: "safari.tabs.list", path: ["safari", "tabs", "list"], summary: "List Safari tabs.",
      kind: .read, risk: .low, service: "safari", permissions: ["automation:Safari"],
      inputSchema: SchemaLibrary.schema(for: "safari.tabs.list")
    ),
    CommandSpec(
      id: "safari.tabs.get", path: ["safari", "tabs", "get"], summary: "Get one Safari tab.",
      kind: .read, risk: .low, service: "safari", permissions: ["automation:Safari"],
      inputSchema: SchemaLibrary.schema(for: "safari.tabs.get")
    ),
    CommandSpec(
      id: "safari.tabs.open", path: ["safari", "tabs", "open"], summary: "Open a Safari tab.",
      kind: .mutation, risk: .medium, service: "safari", permissions: ["automation:Safari"],
      inputSchema: SchemaLibrary.schema(for: "safari.tabs.open")
    ),
    CommandSpec(
      id: "safari.tabs.close", path: ["safari", "tabs", "close"],
      summary: "Close a reviewed Safari tab slot in the verified window.",
      kind: .mutation, risk: .medium, service: "safari", permissions: ["automation:Safari"],
      inputSchema: SchemaLibrary.schema(for: "safari.tabs.close")
    ),
    CommandSpec(
      id: "safari.tabs.activate", path: ["safari", "tabs", "activate"],
      summary: "Activate a reviewed Safari tab slot in the verified window.",
      kind: .mutation, risk: .medium, service: "safari", permissions: ["automation:Safari"],
      inputSchema: SchemaLibrary.schema(for: "safari.tabs.activate")
    ),
    CommandSpec(
      id: "safari.reading-list.add", path: ["safari", "reading-list", "add"],
      summary: "Add an URL to Safari Reading List.",
      kind: .mutation, risk: .medium, service: "safari", permissions: ["automation:Safari"],
      inputSchema: SchemaLibrary.schema(for: "safari.reading-list.add")
    ),
    CommandSpec(
      id: "messages.chats.list", path: ["messages", "chats", "list"],
      summary: "List local Messages chats.",
      kind: .read, risk: .low, service: "messages", permissions: ["full-disk-access"],
      inputSchema: SchemaLibrary.schema(for: "messages.chats.list")
    ),
    CommandSpec(
      id: "messages.messages.list", path: ["messages", "messages", "list"],
      summary: "List messages in an exact chat.",
      kind: .read, risk: .low, service: "messages", permissions: ["full-disk-access"],
      inputSchema: SchemaLibrary.schema(for: "messages.messages.list")
    ),
    CommandSpec(
      id: "messages.messages.search", path: ["messages", "messages", "search"],
      summary: "Search normal Messages text with bounded scanning; "
        + "excludes reaction/system rows when schema metadata is available.",
      kind: .read, risk: .low, service: "messages", permissions: ["full-disk-access"],
      inputSchema: SchemaLibrary.schema(for: "messages.messages.search")
    ),
    CommandSpec(
      id: "messages.attachments.list", path: ["messages", "attachments", "list"],
      summary: "List message attachment metadata.",
      kind: .read, risk: .low, service: "messages", permissions: ["full-disk-access"],
      inputSchema: SchemaLibrary.schema(for: "messages.attachments.list")
    ),
    CommandSpec(
      id: "messages.send.text", path: ["messages", "send", "text"],
      summary: "Send text to an exact handle or chat.",
      kind: .mutation, risk: .high, service: "messages", permissions: ["automation:Messages"],
      inputSchema: SchemaLibrary.schema(for: "messages.send.text")
    ),
    CommandSpec(
      id: "messages.send.file", path: ["messages", "send", "file"],
      summary: "Send a file to an exact handle or chat.",
      kind: .mutation, risk: .high, service: "messages", permissions: ["automation:Messages"],
      inputSchema: SchemaLibrary.schema(for: "messages.send.file")
    ),
    CommandSpec(
      id: "calls.video.start", path: ["calls", "video", "start"],
      summary: "Request a FaceTime video call to one exact phone number or email address.",
      kind: .mutation, risk: .high, service: "calls", permissions: ["facetime"],
      inputSchema: SchemaLibrary.schema(for: "calls.video.start")
    ),
    CommandSpec(
      id: "calls.video.confirm", path: ["calls", "video", "confirm"],
      summary: "Confirm one visible FaceTime call only after exact recipient verification.",
      kind: .mutation, risk: .high, service: "calls", permissions: ["facetime", "accessibility"],
      inputSchema: SchemaLibrary.schema(for: "calls.video.confirm")
    ),
    CommandSpec(
      id: "calls.video.end", path: ["calls", "video", "end"],
      summary: "End the one active FaceTime call after explicit plan review.",
      kind: .mutation, risk: .high, service: "calls", permissions: ["facetime", "accessibility"],
      inputSchema: SchemaLibrary.schema(for: "calls.video.end")
    ),
    CommandSpec(
      id: "files.list", path: ["files", "list"], summary: "List directory entries.",
      kind: .read, risk: .low, service: "files", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "files.list")
    ),
    CommandSpec(
      id: "files.stat", path: ["files", "stat"],
      summary: "Read file metadata without following the final symlink.",
      kind: .read, risk: .low, service: "files", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "files.stat")
    ),
    CommandSpec(
      id: "files.read", path: ["files", "read"], summary: "Read a bounded file.",
      kind: .read, risk: .low, service: "files", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "files.read")
    ),
    CommandSpec(
      id: "files.search", path: ["files", "search"],
      summary: "Search local file names or UTF-8 content with bounded coverage; excluded, oversized and unreadable files are reported.",
      kind: .read, risk: .low, service: "files", permissions: ["files"],
      inputSchema: SchemaLibrary.schema(for: "files.search")
    ),
    CommandSpec(
      id: "files.patch", path: ["files", "patch"],
      summary: "Apply exact unique text edits to an existing UTF-8 file after diff approval and content-revision recheck.",
      kind: .mutation, risk: .medium, service: "files", permissions: ["files"],
      inputSchema: SchemaLibrary.schema(for: "files.patch")
    ),
    CommandSpec(
      id: "process.run", path: ["process", "run"],
      summary: "Run an exact executable and arguments in an exact working directory after approval. Unsandboxed: the program can access other files and network with this user's permissions.",
      kind: .mutation, risk: .high, service: "process", permissions: ["files", "process-execution"],
      inputSchema: SchemaLibrary.schema(for: "process.run")
    ),
    CommandSpec(
      id: "files.write", path: ["files", "write"], summary: "Atomically write a file.",
      kind: .mutation, risk: .medium, service: "files", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "files.write")
    ),
    CommandSpec(
      id: "files.mkdir", path: ["files", "mkdir"], summary: "Create a directory.",
      kind: .mutation, risk: .medium, service: "files", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "files.mkdir")
    ),
    CommandSpec(
      id: "files.copy", path: ["files", "copy"], summary: "Copy a file or directory.",
      kind: .mutation, risk: .medium, service: "files", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "files.copy")
    ),
    CommandSpec(
      id: "files.move", path: ["files", "move"], summary: "Move a file or directory.",
      kind: .mutation, risk: .medium, service: "files", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "files.move")
    ),
    CommandSpec(
      id: "files.delete", path: ["files", "delete"], summary: "Delete a file or directory.",
      kind: .mutation, risk: .high, service: "files", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "files.delete")
    ),
    CommandSpec(
      id: "system.info", path: ["system", "info"], summary: "Read macOS system information.",
      kind: .read, risk: .low, service: "system", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "system.info")
    ),
    CommandSpec(
      id: "system.volume.get", path: ["system", "volume", "get"],
      summary: "Read output volume and mute state.",
      kind: .read, risk: .low, service: "system", permissions: ["automation:System Events"],
      inputSchema: SchemaLibrary.schema(for: "system.volume.get")
    ),
    CommandSpec(
      id: "system.volume.set", path: ["system", "volume", "set"], summary: "Set output volume.",
      kind: .mutation, risk: .medium, service: "system", permissions: ["automation:System Events"],
      inputSchema: SchemaLibrary.schema(for: "system.volume.set")
    ),
    CommandSpec(
      id: "system.volume.mute", path: ["system", "volume", "mute"],
      summary: "Set output mute state.",
      kind: .mutation, risk: .medium, service: "system", permissions: ["automation:System Events"],
      inputSchema: SchemaLibrary.schema(for: "system.volume.mute")
    ),
    CommandSpec(
      id: "system.appearance.get", path: ["system", "appearance", "get"],
      summary: "Read light or dark appearance.",
      kind: .read, risk: .low, service: "system", permissions: ["automation:System Events"],
      inputSchema: SchemaLibrary.schema(for: "system.appearance.get")
    ),
    CommandSpec(
      id: "system.appearance.set", path: ["system", "appearance", "set"],
      summary: "Set light or dark appearance.",
      kind: .mutation, risk: .medium, service: "system", permissions: ["automation:System Events"],
      inputSchema: SchemaLibrary.schema(for: "system.appearance.set")
    ),
    CommandSpec(
      id: "system.wallpaper.get", path: ["system", "wallpaper", "get"],
      summary: "Read desktop picture paths.",
      kind: .read, risk: .low, service: "system", permissions: ["automation:System Events"],
      inputSchema: SchemaLibrary.schema(for: "system.wallpaper.get")
    ),
    CommandSpec(
      id: "system.wallpaper.set", path: ["system", "wallpaper", "set"],
      summary: "Set desktop picture.",
      kind: .mutation, risk: .medium, service: "system", permissions: ["automation:System Events"],
      inputSchema: SchemaLibrary.schema(for: "system.wallpaper.set")
    ),
    CommandSpec(
      id: "system.settings.open", path: ["system", "settings", "open"],
      summary: "Open an exact System Settings pane URL.",
      kind: .mutation, risk: .medium, service: "system", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "system.settings.open")
    ),
    CommandSpec(
      id: "system.sleep", path: ["system", "sleep"], summary: "Put the current Mac to sleep.",
      kind: .mutation, risk: .high, service: "system", permissions: ["automation:System Events"],
      inputSchema: SchemaLibrary.schema(for: "system.sleep")
    ),
    CommandSpec(
      id: "system.restart", path: ["system", "restart"], summary: "Restart the current Mac.",
      kind: .mutation, risk: .high, service: "system", permissions: ["automation:System Events"],
      inputSchema: SchemaLibrary.schema(for: "system.restart")
    ),
    CommandSpec(
      id: "system.shutdown", path: ["system", "shutdown"], summary: "Shut down the current Mac.",
      kind: .mutation, risk: .high, service: "system", permissions: ["automation:System Events"],
      inputSchema: SchemaLibrary.schema(for: "system.shutdown")
    ),
    CommandSpec(
      id: "system.locale.get", path: ["system", "locale", "get"],
      summary: "Read locale, timezone, and calendar settings.",
      kind: .read, risk: .low, service: "system", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "system.locale.get")
    ),
    CommandSpec(
      id: "app.list", path: ["app", "list"],
      summary: "List running applications with exact process identity when available.",
      kind: .read, risk: .low, service: "app", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "app.list")
    ),
    CommandSpec(
      id: "app.launch", path: ["app", "launch"],
      summary:
        "Request launch using exactly one bundle_id or name, optionally with app arguments; open success does not confirm readiness.",
      kind: .mutation, risk: .medium, service: "app", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "app.launch")
    ),
    CommandSpec(
      id: "app.activate", path: ["app", "activate"],
      summary: "Activate one app.list process using its bundle_id, pid, launch_date, and process_start_time.",
      kind: .mutation, risk: .medium, service: "app", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "app.activate")
    ),
    CommandSpec(
      id: "app.quit", path: ["app", "quit"],
      summary: "Quit one app.list process using its bundle_id, pid, launch_date, and process_start_time.",
      kind: .mutation, risk: .medium, service: "app", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "app.quit")
    ),
    CommandSpec(
      id: "clipboard.text.read", path: ["clipboard", "text", "read"],
      summary: "Read text from the clipboard.",
      kind: .read, risk: .low, service: "clipboard", permissions: ["pasteboard"],
      inputSchema: SchemaLibrary.schema(for: "clipboard.text.read")
    ),
    CommandSpec(
      id: "clipboard.text.write", path: ["clipboard", "text", "write"],
      summary: "Replace clipboard text.",
      kind: .mutation, risk: .medium, service: "clipboard", permissions: ["pasteboard"],
      inputSchema: SchemaLibrary.schema(for: "clipboard.text.write")
    ),
    CommandSpec(
      id: "clipboard.files.read", path: ["clipboard", "files", "read"],
      summary: "Read file URLs from the clipboard.",
      kind: .read, risk: .low, service: "clipboard", permissions: ["pasteboard"],
      inputSchema: SchemaLibrary.schema(for: "clipboard.files.read")
    ),
    CommandSpec(
      id: "clipboard.files.write", path: ["clipboard", "files", "write"],
      summary: "Replace clipboard file URLs.",
      kind: .mutation, risk: .medium, service: "clipboard", permissions: ["pasteboard"],
      inputSchema: SchemaLibrary.schema(for: "clipboard.files.write")
    ),
    CommandSpec(
      id: "shortcuts.items.list", path: ["shortcuts", "items", "list"],
      summary: "List available shortcut names.",
      kind: .read, risk: .low, service: "shortcuts", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "shortcuts.items.list")
    ),
    CommandSpec(
      id: "shortcuts.items.get", path: ["shortcuts", "items", "get"],
      summary: "Confirm one exact shortcut name is available.",
      kind: .read, risk: .low, service: "shortcuts", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "shortcuts.items.get")
    ),
    CommandSpec(
      id: "shortcuts.items.run", path: ["shortcuts", "items", "run"],
      summary: "Run one exact shortcut; this adapter does not inspect its internal actions.",
      kind: .mutation, risk: .high, service: "shortcuts", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "shortcuts.items.run")
    ),
    CommandSpec(
      id: "finder.selection.list", path: ["finder", "selection", "list"],
      summary: "Read the Finder selection.",
      kind: .read, risk: .low, service: "finder", permissions: ["automation:Finder"],
      inputSchema: SchemaLibrary.schema(for: "finder.selection.list")
    ),
    CommandSpec(
      id: "finder.reveal", path: ["finder", "reveal"], summary: "Reveal an exact path in Finder.",
      kind: .mutation, risk: .medium, service: "finder", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "finder.reveal")
    ),
    CommandSpec(
      id: "spotlight.search", path: ["spotlight", "search"], summary: "Search Spotlight metadata.",
      kind: .read, risk: .low, service: "spotlight", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "spotlight.search")
    ),
    CommandSpec(
      id: "spotlight.metadata.get", path: ["spotlight", "metadata", "get"],
      summary: "Read Spotlight metadata for one path.",
      kind: .read, risk: .low, service: "spotlight", permissions: [],
      inputSchema: SchemaLibrary.schema(for: "spotlight.metadata.get")
    ),
  ]
}
