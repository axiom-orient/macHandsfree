import Foundation
import MacHandsfreeCore
import MacHandsfreeSQLite
import TypedStream

/// Serializes bounded local reads while reopening the database for each command.
actor MessagesDatabaseReader {
  private static let maximumAttributedBodyBytesPerMessage = 256 * 1_024
  private static let maximumAttributedBodyBytesPerRequest = 4 * 1_024 * 1_024
  private static let maximumMessageTextCharactersPerMessage = 4_096
  private static let maximumMessageTextBytesPerMessage = 16 * 1_024
  private static let maximumMessageTextBytesPerRequest = 1 * 1_024 * 1_024
  private static let messageSearchBatchSize = 256
  private static let messageChatIDsColumn =
    "(SELECT group_concat(link.chat_id, ',') FROM chat_message_join link " +
      "WHERE link.message_id = m.ROWID) AS chat_ids"
  private static var boundedMessageTextColumns: String {
    let characterLimit = maximumMessageTextCharactersPerMessage
    let byteLimit = maximumMessageTextBytesPerMessage
    return """
      CASE WHEN length(m.text) <= \(characterLimit)
                AND length(CAST(m.text AS BLOB)) <= \(byteLimit)
           THEN m.text ELSE substr(m.text, 1, \(characterLimit)) END AS text,
      CASE WHEN length(m.text) > \(characterLimit)
                OR length(CAST(m.text AS BLOB)) > \(byteLimit)
           THEN 1 ELSE 0 END AS text_truncated
      """
  }

  private struct TextRead {
    let text: String?
    let source: String?
    let status: String
    let bytesRead: Int
  }

  private struct BoundedText {
    let text: String?
    let bytes: Int
    let truncated: Bool
  }

  private struct SearchCoverage {
    var messagesScanned = 0
    var attributedBodyCandidatesScanned = 0
    var bytesRead = 0
    var oversized = 0
    var decodeFailures = 0
    var unavailable = 0
    var byteLimitReached = false
    var scanLimitReached = false

    var bodySearchIncomplete: Bool {
      byteLimitReached || oversized > 0 || decodeFailures > 0 || unavailable > 0
    }
  }

  private let databasePath: String

  private static func boundedText(_ value: String?, maximumBytes: Int) -> BoundedText {
    guard let value else { return BoundedText(text: nil, bytes: 0, truncated: false) }
    let maximumBytes = max(0, maximumBytes)
    var index = value.unicodeScalars.startIndex
    var byteCount = 0
    while index != value.unicodeScalars.endIndex {
      let scalar = value.unicodeScalars[index]
      let scalarBytes = scalar.utf8.count
      guard scalarBytes <= maximumBytes - byteCount else { break }
      byteCount += scalarBytes
      index = value.unicodeScalars.index(after: index)
    }
    let text = String(value[..<index])
    let truncated = index != value.unicodeScalars.endIndex
    return BoundedText(
      text: truncated && text.isEmpty ? nil : text,
      bytes: byteCount,
      truncated: truncated
    )
  }

  init(environment: [String: String]? = nil) {
    let environment = environment ?? ProcessInfo.processInfo.environment
    if let override = environment["MAC_HANDSFREE_MESSAGES_DB"], !override.isEmpty {
      self.databasePath = NSString(string: override).expandingTildeInPath
    } else {
      self.databasePath = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath
    }
  }

  func chats(limit: Int) throws -> JSONValue {
    let (db, _) = try openCurrentDatabase()
    let rows = try db.query(
      """
      SELECT c.ROWID AS id, c.guid AS guid, c.chat_identifier AS identifier,
             c.display_name AS display_name, c.service_name AS service,
             MAX(m.date) AS last_date
      FROM chat c
      LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      LEFT JOIN message m ON m.ROWID = cmj.message_id
      GROUP BY c.ROWID
      ORDER BY last_date DESC, c.ROWID DESC
      LIMIT ?
      """, values: [.integer(Int64(limit + 1))])
    return .object([
      "chats": .array(
        rows.prefix(limit).map { row in
          .object([
            "id": row["id"]?.integer.map(JSONValue.integer) ?? .null,
            "guid": row["guid"]?.text.map(JSONValue.string) ?? .null,
            "identifier": row["identifier"]?.text.map(JSONValue.string) ?? .null,
            "display_name": row["display_name"]?.text.map(JSONValue.string) ?? .null,
            "service": row["service"]?.text.map(JSONValue.string) ?? .null,
            "last_message_at": row["last_date"]?.integer.flatMap(Self.messageDate).map {
              .string(ISO8601DateFormatter.agentString(from: $0))
            } ?? .null,
          ])
        }),
      "truncated": .bool(rows.count > limit),
    ])
  }

  func messages(chatID: Int, beforeRowID: Int?, limit: Int) throws -> JSONValue {
    let (db, schema) = try openCurrentDatabase()
    var sql = """
      SELECT m.ROWID AS id, \(Self.messageChatIDsColumn), \(schema.reactionColumnsSQL),
             \(schema.itemTypeSQL), m.guid AS guid,
             \(Self.boundedMessageTextColumns), m.date AS date,
             m.is_from_me AS is_from_me, m.service AS service, h.id AS sender,
             \(schema.messageAttachmentFlagSQL), \(schema.attributedBodySizeSQL)
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE cmj.chat_id = ?
      """
    var values: [SQLiteValue] = [.integer(Int64(chatID))]
    if let beforeRowID {
      sql += " AND m.ROWID < ?"
      values.append(.integer(Int64(beforeRowID)))
    }
    sql += " ORDER BY m.ROWID DESC LIMIT ?"
    values.append(.integer(Int64(limit + 1)))
    let rows = try db.query(sql, values: values)
    var bytesRead = 0
    var oversized = 0
    var decodeFailures = 0
    var unavailable = 0
    var byteLimitReached = false
    var textBytesReturned = 0
    var textTruncatedCount = 0
    var textByteLimitReached = false
    var results: [JSONValue] = []
    let visibleRows = Array(rows.prefix(limit))
    for row in visibleRows {
      if Self.isReaction(row) {
        var reactionRow = row
        reactionRow["text"] = .null
        reactionRow["text_source"] = .null
        reactionRow["text_read_status"] = .text("reaction_metadata")
        reactionRow["text_truncated"] = .integer(0)
        results.append(messageJSON(reactionRow, scopedChatID: chatID))
        continue
      }
      let remainingTextBytes = max(
        0, Self.maximumMessageTextBytesPerRequest - textBytesReturned)
      let remainingAttributedBodyBytes = max(
        0, Self.maximumAttributedBodyBytesPerRequest - bytesRead)
      let bodyCouldContainText = schema.hasAttributedBody
        && (row["text"]?.text ?? "").isEmpty
        && (row["attributed_body_bytes"]?.integer ?? 0) > 0
      let read: TextRead
      if remainingTextBytes == 0 && bodyCouldContainText {
        read = TextRead(text: nil, source: nil, status: "text_byte_limit_reached", bytesRead: 0)
      } else {
        read = try messageText(
          row, schema: schema, database: db, remainingBytes: remainingAttributedBodyBytes)
      }
      bytesRead += read.bytesRead
      if read.status == "oversized" { oversized += 1 }
      if read.status == "decode_failed" { decodeFailures += 1 }
      if read.status == "missing" || read.status == "unavailable" || read.status == "changed" {
        unavailable += 1
      }
      if read.status == "byte_limit_reached" { byteLimitReached = true }
      if read.status == "text_byte_limit_reached" { textByteLimitReached = true }
      let bounded = Self.boundedText(
        read.text,
        maximumBytes: min(Self.maximumMessageTextBytesPerMessage, remainingTextBytes))
      textBytesReturned += bounded.bytes
      let sqlTextTruncated = row["text_truncated"]?.integer == 1
      let textTruncated = sqlTextTruncated || read.status == "truncated"
        || read.status == "text_byte_limit_reached" || bounded.truncated
      if textTruncated { textTruncatedCount += 1 }
      if bounded.truncated && remainingTextBytes < Self.maximumMessageTextBytesPerMessage {
        textByteLimitReached = true
      }
      var resultRow = row
      resultRow["text"] = bounded.text.map(SQLiteValue.text) ?? .null
      resultRow["text_source"] = read.source.map(SQLiteValue.text) ?? .null
      resultRow["text_read_status"] = .text(
        read.status == "text_byte_limit_reached"
          || (bounded.truncated && remainingTextBytes < Self.maximumMessageTextBytesPerMessage
            && bounded.text == nil) ? "byte_limit_reached"
          : textTruncated ? "truncated" : read.status)
      resultRow["text_truncated"] = .integer(textTruncated ? 1 : 0)
      results.append(messageJSON(resultRow, scopedChatID: chatID))
    }
    return .object([
      "messages": .array(results),
      "truncated": .bool(rows.count > limit),
      "reaction_metadata_available": .bool(schema.reactionMetadataAvailable),
      "reaction_emoji_available": .bool(schema.hasAssociatedMessageEmoji),
      "message_kind_metadata_available": .bool(schema.messageKindMetadataAvailable),
      "attributed_body_available": .bool(schema.hasAttributedBody),
      "attributed_body_bytes_read": .integer(Int64(bytesRead)),
      "attributed_body_byte_limit_reached": .bool(byteLimitReached),
      "attributed_body_oversized_count": .integer(Int64(oversized)),
      "attributed_body_decode_failures": .integer(Int64(decodeFailures)),
      "attributed_body_unavailable_count": .integer(Int64(unavailable)),
      "attributed_body_incomplete": .bool(
        !schema.hasAttributedBody || byteLimitReached || oversized > 0 || decodeFailures > 0
          || unavailable > 0),
      "text_bytes_returned": .integer(Int64(textBytesReturned)),
      "text_truncated_count": .integer(Int64(textTruncatedCount)),
      "text_byte_limit_reached": .bool(textByteLimitReached),
    ])
  }

  func search(
    query: String, chatID: Int?, beforeRowID: Int?, limit: Int, scanLimit: Int
  ) throws -> JSONValue {
    let (db, schema) = try openCurrentDatabase()
    let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
      of: "%", with: "\\%"
    ).replacingOccurrences(of: "_", with: "\\_")
    let likePattern = "%\(escaped)%"
    var coverage = SearchCoverage()
    var matches: [[String: SQLiteValue]] = []
    var cursor = beforeRowID.map { Int64($0) }
    var byteLimitResumeBeforeRowID: Int64?
    let hasAttributedBody = schema.hasAttributedBody

    // One extra row ID distinguishes an exhausted scope from a reached scan cap.
    while coverage.messagesScanned < scanLimit && matches.count <= limit
      && !coverage.byteLimitReached
    {
      let remaining = scanLimit - coverage.messagesScanned
      let pageLimit = min(Self.messageSearchBatchSize, remaining)
      let requestedCount = pageLimit + 1
      var candidateSQL = "SELECT m.ROWID AS id FROM message m"
      var candidateValues: [SQLiteValue] = []
      var candidateConditions: [String] = []
      if let cursor {
        candidateConditions.append("m.ROWID < ?")
        candidateValues.append(.integer(cursor))
      }
      if !candidateConditions.isEmpty {
        candidateSQL += " WHERE " + candidateConditions.joined(separator: " AND ")
      }
      candidateSQL += " ORDER BY m.ROWID DESC LIMIT ?"
      candidateValues.append(.integer(Int64(requestedCount)))
      let candidateRows = try db.query(candidateSQL, values: candidateValues)
      guard !candidateRows.isEmpty else { break }

      let eligibleRows = Array(candidateRows.prefix(pageLimit))
      if remaining == pageLimit && candidateRows.count > eligibleRows.count {
        coverage.scanLimitReached = true
      }
      guard let lastCandidateID = eligibleRows.last?["id"]?.integer else {
        coverage.unavailable += 1
        break
      }
      cursor = lastCandidateID
      coverage.messagesScanned += eligibleRows.count
      let candidateIDs = eligibleRows.compactMap { $0["id"]?.integer }
      guard candidateIDs.count == eligibleRows.count else {
        coverage.unavailable += 1
        if coverage.scanLimitReached { break }
        continue
      }

      // Keep LIKE inside the bounded page so zero-hit searches do not scan the full database.
      var resultSQL = """
        SELECT DISTINCT m.ROWID AS id, \(Self.messageChatIDsColumn),
               \(schema.reactionColumnsSQL), \(schema.itemTypeSQL), m.guid AS guid,
               \(Self.boundedMessageTextColumns), m.date AS date,
               m.is_from_me AS is_from_me, m.service AS service, h.id AS sender,
               \(schema.messageAttachmentFlagSQL), \(schema.attributedBodySizeSQL),
               CASE WHEN m.text LIKE ? ESCAPE '\\' THEN 1 ELSE 0 END AS text_search_match
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        """
      if chatID != nil {
        resultSQL += " JOIN chat_message_join cmj ON cmj.message_id = m.ROWID"
      }
      let idPlaceholders = Array(repeating: "?", count: candidateIDs.count).joined(separator: ", ")
      resultSQL += " WHERE m.ROWID IN (\(idPlaceholders))"
      var resultValues: [SQLiteValue] = [.text(likePattern)]
      resultValues.append(contentsOf: candidateIDs.map(SQLiteValue.integer))
      var resultConditions = [
        "(m.text LIKE ? ESCAPE '\\'" +
          (hasAttributedBody
            ? " OR ((m.text IS NULL OR m.text = '') AND m.attributedBody IS NOT NULL))"
            : ")"),
      ]
      resultValues.append(.text(likePattern))
      if let chatID {
        resultConditions.append("cmj.chat_id = ?")
        resultValues.append(.integer(Int64(chatID)))
      }
      resultConditions.append(contentsOf: schema.ordinaryMessageConditions)
      resultSQL += " AND " + resultConditions.joined(separator: " AND ")
      resultSQL += " ORDER BY m.ROWID DESC"
      let rows = try db.query(resultSQL, values: resultValues)

      for original in rows {
        if original["text_search_match"]?.integer == 1 {
          var match = original
          match["text_source"] = .text("message.text")
          match["text_read_status"] = .text(
            match["text_truncated"]?.integer == 1 ? "truncated" : "complete")
          matches.append(match)
        } else if hasAttributedBody,
          let messageID = original["id"]?.integer
        {
          coverage.attributedBodyCandidatesScanned += 1
          let body = try attributedBody(
            database: db, messageID: messageID,
            expectedBytes: original["attributed_body_bytes"]?.integer,
            remainingBudget: Self.maximumAttributedBodyBytesPerRequest - coverage.bytesRead)
          coverage.bytesRead += body.bytesRead
          switch body.status {
          case "oversized": coverage.oversized += 1
          case "decode_failed": coverage.decodeFailures += 1
          case "missing", "unavailable", "changed": coverage.unavailable += 1
          case "byte_limit_reached":
            coverage.byteLimitReached = true
            byteLimitResumeBeforeRowID =
              messageID < Int64.max ? messageID + 1 : nil
          default: break
          }
          if coverage.byteLimitReached { break }
          guard let text = body.text,
            text.range(of: query, options: .caseInsensitive) != nil
          else { continue }
          var match = original
          match["text"] = .text(text)
          match["text_source"] = .text("message.attributedBody")
          match["text_read_status"] = .text(text.isEmpty ? "empty" : "complete")
          matches.append(match)
        }
        if matches.count > limit { break }
      }
      if coverage.scanLimitReached { break }
    }

    var textBytesReturned = 0
    var textTruncatedCount = 0
    var textByteLimitReached = false
    let messages = matches.prefix(limit).map { original -> JSONValue in
      var row = original
      let remainingTextBytes = max(
        0, Self.maximumMessageTextBytesPerRequest - textBytesReturned)
      let bounded = Self.boundedText(
        row["text"]?.text,
        maximumBytes: min(Self.maximumMessageTextBytesPerMessage, remainingTextBytes))
      textBytesReturned += bounded.bytes
      let sqlTextTruncated = row["text_truncated"]?.integer == 1
      let textTruncated = sqlTextTruncated || bounded.truncated
      if textTruncated { textTruncatedCount += 1 }
      if bounded.truncated && remainingTextBytes < Self.maximumMessageTextBytesPerMessage {
        textByteLimitReached = true
      }
      row["text"] = bounded.text.map(SQLiteValue.text) ?? .null
      row["text_truncated"] = .integer(textTruncated ? 1 : 0)
      if bounded.truncated {
        row["text_read_status"] = .text(
          bounded.text == nil && remainingTextBytes < Self.maximumMessageTextBytesPerMessage
            ? "byte_limit_reached" : "truncated")
      }
      return messageJSON(row, scopedChatID: chatID)
    }
    let nextBeforeRowID: Int64?
    if matches.count > limit {
      nextBeforeRowID = matches.prefix(limit).last?["id"]?.integer
    } else if coverage.byteLimitReached {
      nextBeforeRowID = byteLimitResumeBeforeRowID
    } else if coverage.scanLimitReached {
      nextBeforeRowID = cursor
    } else {
      nextBeforeRowID = nil
    }
    return .object([
      "messages": .array(messages),
      "truncated": .bool(matches.count > limit),
      "next_before_row_id": nextBeforeRowID.map(JSONValue.integer) ?? .null,
      "attributed_body_available": .bool(schema.hasAttributedBody),
      "reaction_metadata_available": .bool(schema.reactionMetadataAvailable),
      "reaction_emoji_available": .bool(schema.hasAssociatedMessageEmoji),
      "message_scan_limit": .integer(Int64(scanLimit)),
      "messages_scanned": .integer(Int64(coverage.messagesScanned)),
      "message_scan_limit_reached": .bool(coverage.scanLimitReached),
      "attributed_body_candidates_scanned": .integer(
        Int64(coverage.attributedBodyCandidatesScanned)),
      "attributed_body_bytes_read": .integer(Int64(coverage.bytesRead)),
      "attributed_body_byte_limit_reached": .bool(coverage.byteLimitReached),
      "attributed_body_oversized_count": .integer(Int64(coverage.oversized)),
      "attributed_body_decode_failures": .integer(Int64(coverage.decodeFailures)),
      "attributed_body_unavailable_count": .integer(Int64(coverage.unavailable)),
      "body_search_incomplete": .bool(!schema.hasAttributedBody || coverage.bodySearchIncomplete),
      "message_kind_metadata_available": .bool(schema.messageKindMetadataAvailable),
      "search_incomplete": .bool(
        !schema.hasAttributedBody || coverage.bodySearchIncomplete
          || coverage.scanLimitReached || matches.count > limit
          || !schema.messageKindMetadataAvailable),
      "text_bytes_returned": .integer(Int64(textBytesReturned)),
      "text_truncated_count": .integer(Int64(textTruncatedCount)),
      "text_byte_limit_reached": .bool(textByteLimitReached),
    ])
  }

  func attachments(chatID: Int?, messageID: Int?, limit: Int) throws -> JSONValue {
    guard chatID != nil || messageID != nil else {
      throw AgentError.invalid("Provide chat_id or message_id")
    }
    let (db, schema) = try openCurrentDatabase()
    var sql = """
      SELECT DISTINCT a.ROWID AS id, a.guid AS guid, a.filename AS filename,
             a.transfer_name AS transfer_name, a.mime_type AS mime_type,
             a.total_bytes AS total_bytes, \(schema.attachmentStickerFlagSQL),
             maj.message_id AS message_id
      FROM attachment a
      JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
      """
    var conditions: [String] = []
    var values: [SQLiteValue] = []
    if let chatID {
      sql += " JOIN chat_message_join cmj ON cmj.message_id = maj.message_id"
      conditions.append("cmj.chat_id = ?")
      values.append(.integer(Int64(chatID)))
    }
    if let messageID {
      conditions.append("maj.message_id = ?")
      values.append(.integer(Int64(messageID)))
    }
    sql += " WHERE " + conditions.joined(separator: " AND ") + " ORDER BY a.ROWID DESC LIMIT ?"
    values.append(.integer(Int64(limit + 1)))
    let rows = try db.query(sql, values: values)
    return .object([
      "attachments": .array(
        rows.prefix(limit).map { row in
          .object([
            "id": row["id"]?.integer.map(JSONValue.integer) ?? .null,
            "guid": row["guid"]?.text.map(JSONValue.string) ?? .null,
            "message_id": row["message_id"]?.integer.map(JSONValue.integer) ?? .null,
            "filename": row["filename"]?.text.map {
              .string(NSString(string: $0).expandingTildeInPath)
            } ?? .null,
            "transfer_name": row["transfer_name"]?.text.map(JSONValue.string) ?? .null,
            "mime_type": row["mime_type"]?.text.map(JSONValue.string) ?? .null,
            "total_bytes": row["total_bytes"]?.integer.map(JSONValue.integer) ?? .null,
            "is_sticker": .bool((row["is_sticker"]?.integer ?? 0) != 0),
          ])
        }),
      "truncated": .bool(rows.count > limit),
    ])
  }

  // Reopen the path and inspect its schema so resident readers see database replacements.
  private func openCurrentDatabase() throws -> (SQLiteDatabase, MessagesSchema) {
    let databaseURL: URL
    do {
      databaseURL = try LocalPathPolicy.requireRegularFile(databasePath)
    } catch let error as AgentError where error.code == "path_not_found" {
      throw AgentError(
        code: "messages_database_not_found",
        message: "Messages database was not found",
        details: ["path": .string(databasePath)],
        exitCode: 5
      )
    }
    let created: SQLiteDatabase
    do {
      created = try SQLiteDatabase(path: databaseURL.path, readOnly: true)
    } catch let error as AgentError
      where error.code == "sqlite_open_failed"
      && error.details["reason"]?.stringValue?.localizedCaseInsensitiveContains(
        "authorization denied")
        == true
    {
      throw AgentError(
        code: "messages_permission_denied",
        message: "Messages database access requires Full Disk Access",
        exitCode: 3
      )
    }
    let schema = try MessagesSchemaInspector.inspect(created)
    return (created, schema)
  }

  private func messageText(
    _ row: [String: SQLiteValue], schema: MessagesSchema, database: SQLiteDatabase,
    remainingBytes: Int
  ) throws -> TextRead {
    let plainText = row["text"]?.text
    if let plainText, !plainText.isEmpty {
      return TextRead(
        text: plainText,
        source: "message.text",
        status: row["text_truncated"]?.integer == 1 ? "truncated" : "complete",
        bytesRead: 0
      )
    }
    guard schema.hasAttributedBody else {
      return TextRead(
        text: plainText, source: plainText == nil ? nil : "message.text",
        status: plainText == nil ? "not_available" : "empty", bytesRead: 0)
    }
    guard let messageID = row["id"]?.integer,
      let byteCount = row["attributed_body_bytes"]?.integer
    else {
      return TextRead(
        text: plainText, source: plainText == nil ? nil : "message.text",
        status: plainText == nil ? "missing" : "empty", bytesRead: 0)
    }
    let body = try attributedBody(
      database: database,
      messageID: messageID, expectedBytes: byteCount, remainingBudget: remainingBytes)
    if let text = body.text {
      return TextRead(
        text: text, source: "message.attributedBody",
        status: text.isEmpty ? "empty" : "complete", bytesRead: body.bytesRead)
    }
    return TextRead(
      text: plainText, source: plainText == nil ? nil : "message.text",
      status: body.status, bytesRead: body.bytesRead)
  }

  private func attributedBody(
    database: SQLiteDatabase, messageID: Int64, expectedBytes: Int64?,
    remainingBudget: Int
  ) throws -> TextRead {
    guard let expectedBytes, expectedBytes >= 0 else {
      return TextRead(text: nil, source: nil, status: "missing", bytesRead: 0)
    }
    guard expectedBytes <= Int64(Self.maximumAttributedBodyBytesPerMessage) else {
      return TextRead(text: nil, source: nil, status: "oversized", bytesRead: 0)
    }
    guard expectedBytes <= Int64(max(remainingBudget, 0)) else {
      return TextRead(text: nil, source: nil, status: "byte_limit_reached", bytesRead: 0)
    }
    let maximumBytes = min(Self.maximumAttributedBodyBytesPerMessage, remainingBudget)
    guard maximumBytes > 0 else {
      return TextRead(text: nil, source: nil, status: "byte_limit_reached", bytesRead: 0)
    }
    guard let row = try database.query(
      """
      SELECT length(attributedBody) AS byte_count,
             CASE WHEN length(attributedBody) <= ? THEN attributedBody ELSE NULL END AS body
      FROM message WHERE ROWID = ?
      """, values: [.integer(Int64(maximumBytes)), .integer(messageID)]).first,
      let actualBytes = row["byte_count"]?.integer
    else {
      return TextRead(text: nil, source: nil, status: "unavailable", bytesRead: 0)
    }
    guard actualBytes == expectedBytes else {
      return TextRead(text: nil, source: nil, status: "changed", bytesRead: 0)
    }
    guard actualBytes <= Int64(maximumBytes) else {
      return TextRead(
        text: nil, source: nil,
        status: actualBytes > Int64(Self.maximumAttributedBodyBytesPerMessage)
          ? "oversized" : "byte_limit_reached",
        bytesRead: 0)
    }
    if actualBytes == 0 {
      return TextRead(text: "", source: "message.attributedBody", status: "empty", bytesRead: 0)
    }
    guard case .blob(let data)? = row["body"], data.count == Int(actualBytes) else {
      return TextRead(text: nil, source: nil, status: "unavailable", bytesRead: 0)
    }
    guard let text = Self.decodeAttributedBody(data) else {
      return TextRead(text: nil, source: nil, status: "decode_failed", bytesRead: data.count)
    }
    return TextRead(text: text, source: "message.attributedBody", status: "complete", bytesRead: data.count)
  }

  private static func decodeAttributedBody(_ data: Data) -> String? {
    guard !data.isEmpty, let decoded = try? TypedStreamDecoder.decode(data) else { return nil }
    let strings = decoded.compactMap { value -> String? in
      guard case .object(let type, let fields) = value,
        type.name == "NSString" || type.name == "NSMutableString"
      else { return nil }
      return fields.compactMap { field -> String? in
        guard case .string(let text) = field else { return nil }
        return text
      }.first
    }
    guard let first = strings.first else { return nil }
    // NSString data is emitted in stream order. Keep the first body string unconditionally,
    // then omit metadata-like tokens without Madrid's broader substring filter.
    var result = [first]
    for text in strings.dropFirst() where !Self.isAttributedBodyMetadata(text) {
      result.append(text)
    }
    return result.joined()
  }

  private static func isAttributedBodyMetadata(_ text: String) -> Bool {
    guard !text.unicodeScalars.contains(where: {
      CharacterSet.whitespacesAndNewlines.contains($0)
    }) else {
      return false
    }
    return text.hasPrefix("__k") || text.contains("Attribute") || text.contains("NS")
  }

  private static func isReaction(_ row: [String: SQLiteValue]) -> Bool {
    (row["associated_message_type"]?.integer.map { $0 != 0 } ?? false)
      || !(row["associated_message_guid"]?.text ?? "").isEmpty
      || !(row["associated_message_emoji"]?.text ?? "").isEmpty
  }

  private func messageJSON(
    _ row: [String: SQLiteValue], scopedChatID: Int? = nil
  ) -> JSONValue {
    let rawChatIDs = row["chat_ids"]?.text?
      .split(separator: ",")
      .compactMap { Int64(String($0)) } ?? []
    let chatIDs = Array(Set(rawChatIDs)).sorted()
    let messageChatID = scopedChatID.map { Int64($0) }
      ?? (chatIDs.count == 1 ? chatIDs.first : nil)
    let isReaction = Self.isReaction(row)
    let isSystemEvent = (row["item_type"]?.integer ?? 0) != 0
    let messageKind = isReaction ? "reaction" : isSystemEvent ? "system_event" : "message"
    return .object([
      "id": row["id"]?.integer.map(JSONValue.integer) ?? .null,
      "chat_id": messageChatID.map(JSONValue.integer) ?? .null,
      "chat_ids": .array(chatIDs.map(JSONValue.integer)),
      "message_kind": .string(messageKind),
      "associated_message_guid": row["associated_message_guid"]?.text.map(JSONValue.string)
        ?? .null,
      "associated_message_type": row["associated_message_type"]?.integer.map(JSONValue.integer)
        ?? .null,
      "associated_message_emoji": row["associated_message_emoji"]?.text.map(JSONValue.string)
        ?? .null,
      "item_type": row["item_type"]?.integer.map(JSONValue.integer) ?? .null,
      "guid": row["guid"]?.text.map(JSONValue.string) ?? .null,
      "text": isReaction ? .null : (row["text"]?.text.map(JSONValue.string) ?? .null),
      "text_source": row["text_source"]?.text.map(JSONValue.string) ?? .null,
      "text_read_status": row["text_read_status"]?.text.map(JSONValue.string) ?? .string("missing"),
      "text_truncated": .bool((row["text_truncated"]?.integer ?? 0) != 0),
      "created_at": row["date"]?.integer.flatMap(Self.messageDate).map {
        .string(ISO8601DateFormatter.agentString(from: $0))
      } ?? .null,
      "is_from_me": .bool((row["is_from_me"]?.integer ?? 0) != 0),
      "service": row["service"]?.text.map(JSONValue.string) ?? .null,
      "sender": row["sender"]?.text.map(JSONValue.string) ?? .null,
      "has_attachments": .bool((row["has_attachments"]?.integer ?? 0) != 0),
    ])
  }

  private static func messageDate(_ raw: Int64) -> Date? {
    let seconds: Double
    if raw > 10_000_000_000 || raw < -10_000_000_000 {
      seconds = Double(raw) / 1_000_000_000
    } else {
      seconds = Double(raw)
    }
    guard seconds.isFinite else { return nil }
    return Date(timeIntervalSinceReferenceDate: seconds)
  }
}
