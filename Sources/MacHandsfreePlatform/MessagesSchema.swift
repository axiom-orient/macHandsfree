import MacHandsfreeCore
import MacHandsfreeSQLite

struct MessagesSchema: Sendable {
  let hasCachedAttachmentFlag: Bool
  let hasStickerFlag: Bool
  let hasAttributedBody: Bool
  let hasAssociatedMessageGUID: Bool
  let hasAssociatedMessageType: Bool
  let hasAssociatedMessageEmoji: Bool
  let hasItemType: Bool

  var reactionMetadataAvailable: Bool {
    hasAssociatedMessageGUID && hasAssociatedMessageType
  }

  var messageKindMetadataAvailable: Bool {
    reactionMetadataAvailable && hasItemType
  }

  var reactionColumnsSQL: String {
    [
      hasAssociatedMessageGUID
        ? "m.associated_message_guid AS associated_message_guid"
        : "NULL AS associated_message_guid",
      hasAssociatedMessageType
        ? "m.associated_message_type AS associated_message_type"
        : "NULL AS associated_message_type",
      hasAssociatedMessageEmoji
        ? "m.associated_message_emoji AS associated_message_emoji"
        : "NULL AS associated_message_emoji",
    ].joined(separator: ", ")
  }

  var itemTypeSQL: String {
    hasItemType ? "m.item_type AS item_type" : "NULL AS item_type"
  }

  var ordinaryMessageConditions: [String] {
    var conditions: [String] = []
    if hasAssociatedMessageType {
      conditions.append(
        "(m.associated_message_type IS NULL OR m.associated_message_type = 0)")
    }
    if hasAssociatedMessageGUID {
      conditions.append(
        "(m.associated_message_guid IS NULL OR m.associated_message_guid = '')")
    }
    if hasAssociatedMessageEmoji {
      conditions.append(
        "(m.associated_message_emoji IS NULL OR m.associated_message_emoji = '')")
    }
    if hasItemType {
      conditions.append("(m.item_type IS NULL OR m.item_type = 0)")
    }
    return conditions
  }

  var messageAttachmentFlagSQL: String {
    if hasCachedAttachmentFlag { return "m.cache_has_attachments AS has_attachments" }
    return """
      EXISTS(SELECT 1 FROM message_attachment_join maj WHERE maj.message_id = m.ROWID)
      AS has_attachments
      """
  }

  var attachmentStickerFlagSQL: String {
    hasStickerFlag ? "a.is_sticker AS is_sticker" : "0 AS is_sticker"
  }

  var attributedBodySizeSQL: String {
    if hasAttributedBody { return "length(m.attributedBody) AS attributed_body_bytes" }
    return "NULL AS attributed_body_bytes"
  }
}

enum MessagesSchemaInspector {
  static func inspect(_ database: SQLiteDatabase) throws -> MessagesSchema {
    let requirements: [String: Set<String>] = [
      "chat": ["guid", "chat_identifier", "display_name", "service_name"],
      "message": [
        "guid", "text", "date", "is_from_me", "service", "handle_id",
      ],
      "chat_message_join": ["chat_id", "message_id"],
      "handle": ["id"],
      "attachment": [
        "guid", "filename", "transfer_name", "mime_type", "total_bytes",
      ],
      "message_attachment_join": ["message_id", "attachment_id"],
    ]
    var columnsByTable: [String: Set<String>] = [:]
    var missing: [String] = []
    for (table, columns) in requirements {
      let found = Set(
        try database.query("PRAGMA table_info(\(table))").compactMap { $0["name"]?.text })
      columnsByTable[table] = found
      for column in columns where !found.contains(column) { missing.append("\(table).\(column)") }
    }
    guard missing.isEmpty else {
      throw AgentError(
        code: "messages_schema_unsupported",
        message: "Messages database schema is missing required fields",
        details: ["missing": .array(missing.sorted().map(JSONValue.string))], exitCode: 5)
    }
    return MessagesSchema(
      hasCachedAttachmentFlag: columnsByTable["message"]?.contains("cache_has_attachments")
        ?? false,
      hasStickerFlag: columnsByTable["attachment"]?.contains("is_sticker") ?? false,
      hasAttributedBody: columnsByTable["message"]?.contains("attributedBody") ?? false,
      hasAssociatedMessageGUID: columnsByTable["message"]?.contains("associated_message_guid")
        ?? false,
      hasAssociatedMessageType: columnsByTable["message"]?.contains("associated_message_type")
        ?? false,
      hasAssociatedMessageEmoji: columnsByTable["message"]?.contains("associated_message_emoji")
        ?? false,
      hasItemType: columnsByTable["message"]?.contains("item_type") ?? false
    )
  }
}
