import Foundation
import MacHandsfreeCore
import MacHandsfreeSQLite
import MimeFoundation
import SwiftSoup

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

actor MailIndexReader {
  private struct Schema {
    let hasDateReceived: Bool
    let hasDeleted: Bool
    let hasSummary: Bool
    let hasAddressComment: Bool
  }

  private struct ParsedMessage {
    let text: String
    let messageID: String?
    let subject: String?
    let sentAt: Date?
    let isPartial: Bool
    let attachments: [ParsedAttachment]
    let attachmentsTruncated: Bool
  }

  private struct ParsedAttachment {
    let index: Int
    let name: String
    let contentType: String
    let part: MimePart?

    var json: JSONValue {
      .object([
        "attachment_index": .integer(Int64(index)),
        "name": .string(name),
        "content_type": .string(contentType),
        "stream_available": .bool(part?.content != nil),
      ])
    }
  }

  private struct MailFile {
    let url: URL
    let isPartial: Bool
  }

  private static let maximumMailboxRows = 2_000
  private static let maximumScanRows = 1_000
  private static let maximumMessageBytes = 8 * 1_024 * 1_024
  private static let maximumSearchBytes = 64 * 1_024 * 1_024
  private static let maximumBodyCharacters = 500_000
  private static let maximumMailboxResponseBytes = 4 * 1_024 * 1_024
  private static let maximumSearchResultBytes = 4 * 1_024 * 1_024
  private static let maximumDirectoryNodes = 5_000
  private static let maximumDirectoryNodesPerCommand = 20_000
  private static let maximumCachedMessageDirectories = 20_000
  private static let maximumSnippetCharacters = 480
  private static let maximumListedAttachments = 50
  private static let maximumMimeEntitiesVisited = 5_000

  private let mailRoot: URL
  private let fileManager: FileManager
  private let processRunner: any ProcessRunning
  private let fileReader = FileReadOperations()
  private var messageDirectories: [String: [URL]] = [:]
  private var cachedMessageDirectoryCount = 0
  private var directoryNodesVisitedThisCommand = 0

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processRunner: any ProcessRunning = SubprocessProcessRunner()
  ) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    if let override = environment["MAC_HANDSFREE_MAIL_DIR"], !override.isEmpty {
      let expanded = NSString(string: override).expandingTildeInPath
      self.mailRoot = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    } else {
      self.mailRoot = home.appendingPathComponent("Library/Mail", isDirectory: true)
    }
    self.fileManager = .default
    self.processRunner = processRunner
  }

  func execute(command: String, input: JSONValue) async throws -> JSONValue {
    directoryNodesVisitedThisCommand = 0
    // Message folders are rooted under a Mail version directory; keep paths request-local.
    messageDirectories.removeAll(keepingCapacity: true)
    cachedMessageDirectoryCount = 0
    switch command {
    case "mail.index.mailboxes.list":
      return try listMailboxes()
    case "mail.index.messages.search":
      return try search(input: input)
    case "mail.index.messages.get":
      return try await getMessage(input: input)
    default:
      throw AgentError(
        code: "unsupported_mail_index_command",
        message: "Mail index reader does not support this command",
        details: ["command": .string(command)],
        exitCode: 5
      )
    }
  }

  private func listMailboxes() throws -> JSONValue {
    let (db, _, root) = try resolved()
    let readExpression = "SUM(CASE WHEN m.read = 0 AND m.deleted = 0 THEN 1 ELSE 0 END)"
    let rows = try db.query(
      """
      SELECT mb.ROWID AS mailbox_id,
             CASE WHEN length(mb.url) <= 2048 THEN mb.url ELSE '' END AS mailbox_url,
             COUNT(m.ROWID) AS message_count, \(readExpression) AS unread_count
      FROM mailboxes mb
      LEFT JOIN messages m ON m.mailbox = mb.ROWID AND m.deleted = 0
      WHERE mb.url IS NOT NULL AND mb.url != ''
      GROUP BY mb.ROWID, mb.url
      ORDER BY message_count DESC, mb.ROWID DESC
      LIMIT ?
      """,
      values: [.integer(Int64(Self.maximumMailboxRows + 1))]
    )
    var mailboxes: [JSONValue] = []
    var invalidMailboxURLs = 0
    var encodedMailboxBytes = 0
    var responseByteLimitReached = false
    for row in rows.prefix(Self.maximumMailboxRows) {
      let url = row["mailbox_url"]?.text ?? ""
      guard !url.isEmpty else {
        invalidMailboxURLs += 1
        continue
      }
      let mailbox = JSONValue.object([
        "mailbox_url": .string(url),
        "account_id": Self.accountID(from: url).map(JSONValue.string) ?? .null,
        "name": .string(Self.mailboxName(from: url)),
        "message_count": .integer(row["message_count"]?.integer ?? 0),
        "unread_count": .integer(row["unread_count"]?.integer ?? 0),
      ])
      let mailboxBytes = try mailbox.encoded().count
      guard mailboxBytes <= Self.maximumMailboxResponseBytes - encodedMailboxBytes else {
        responseByteLimitReached = true
        break
      }
      encodedMailboxBytes += mailboxBytes
      mailboxes.append(mailbox)
    }
    return .object([
      "source": .string("apple_mail_envelope_index"),
      "mail_root_version": .string(root.lastPathComponent),
      "read_only": .bool(true),
      "mailboxes": .array(mailboxes),
      "truncated": .bool(rows.count > Self.maximumMailboxRows || responseByteLimitReached),
      "unaddressable_mailboxes": .integer(Int64(invalidMailboxURLs)),
      "response_byte_limit_reached": .bool(responseByteLimitReached),
      "index_freshness": .string("not_observed"),
    ])
  }

  private func search(input: JSONValue) throws -> JSONValue {
    let object = try input.requiredObject()
    let query = try object.requiredString("query").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { throw AgentError.invalid("query must contain non-whitespace text") }
    let mailboxURL = object.optionalString("mailbox_url")
    let unreadOnly = object.optionalBool("unread_only")
    let resultLimit = object.optionalInt("limit", default: 20) ?? 20
    let scanLimit = object.optionalInt("scan_limit", default: 200) ?? 200
    guard (1...Self.maximumScanRows).contains(scanLimit), (1...500).contains(resultLimit) else {
      throw AgentError.invalid("Mail index search limits exceed their bounded range")
    }

    let (db, schema, root) = try resolved()
    if let mailboxURL {
      guard try mailboxExists(mailboxURL, database: db) else {
        throw AgentError(
          code: "mail_index_mailbox_not_found",
          message: "The exact mailbox URL is not present in Apple's current Mail index",
          details: ["mailbox_url": .string(mailboxURL)],
          exitCode: 2
        )
      }
    }

    var conditions: [String] = []
    var values: [SQLiteValue] = []
    if schema.hasDeleted { conditions.append("m.deleted = 0") }
    if unreadOnly { conditions.append("m.read = 0") }
    if let mailboxURL {
      conditions.append("mb.url = ?")
      values.append(.text(mailboxURL))
    }
    let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
    let summaryJoin = schema.hasSummary
      ? "LEFT JOIN summaries sm ON m.summary = sm.ROWID"
      : ""
    let summaryExpression = schema.hasSummary ? "COALESCE(sm.summary, '')" : "''"
    let commentExpression = schema.hasAddressComment ? "COALESCE(addr.comment, '')" : "''"
    let dateExpression = schema.hasDateReceived ? "m.date_received" : "NULL"
    let ordering = schema.hasDateReceived ? "m.date_received DESC, m.ROWID DESC" : "m.ROWID DESC"
    let candidates = try db.query(
      """
      SELECT m.ROWID AS mail_index_id,
             substr(COALESCE(addr.address, ''), 1, 320) AS sender_address,
             substr(\(commentExpression), 1, 2_048) AS sender_name,
             substr(COALESCE(subj.subject, ''), 1, 2_048) AS subject,
             \(dateExpression) AS date_received_raw,
             substr(\(summaryExpression), 1, 2_048) AS preview,
             CASE WHEN length(COALESCE(addr.address, '')) > 320
                    OR length(\(commentExpression)) > 2_048
                    OR length(COALESCE(subj.subject, '')) > 2_048
                  THEN 1 ELSE 0 END AS indexed_metadata_truncated,
             m.read AS is_read,
             CASE WHEN length(mb.url) <= 2048 THEN mb.url ELSE '' END AS mailbox_url
      FROM messages m
      LEFT JOIN addresses addr ON m.sender = addr.ROWID
      LEFT JOIN subjects subj ON m.subject = subj.ROWID
      LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
      \(summaryJoin)
      \(whereClause)
      ORDER BY \(ordering)
      LIMIT ?
      """,
      values: values + [.integer(Int64(scanLimit + 1))]
    )

    let scanLimitReached = candidates.count > scanLimit
    let totalMailboxCount: Int
    if mailboxURL == nil {
      totalMailboxCount = try mailboxCount(database: db)
    } else {
      totalMailboxCount = 1
    }
    var results: [JSONValue] = []
    var scanned = 0
    var bodyBytes = 0
    var bodyUnavailable = 0
    var partialBodies = 0
    var indexedMetadataTruncatedRows = 0
    var bodyScanIncomplete = false
    var bodyByteLimitReached = false
    var stoppedForResultLimit = false
    var responseByteLimitReached = false
    var encodedResultBytes = 0
    let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

    for row in candidates.prefix(scanLimit) {
      scanned += 1
      let indexID = row["mail_index_id"]?.integer
      let sourceMailboxURL = row["mailbox_url"]?.text ?? ""
      guard let indexID, !sourceMailboxURL.isEmpty else {
        bodyUnavailable += 1
        bodyScanIncomplete = true
        continue
      }
      let senderAddress = row["sender_address"]?.text ?? ""
      let senderName = row["sender_name"]?.text ?? ""
      let sender = senderName.isEmpty ? senderAddress : "\(senderName) <\(senderAddress)>"
      let indexedSubject = row["subject"]?.text ?? ""
      let preview = row["preview"]?.text ?? ""
      let indexedMetadataTruncated = (row["indexed_metadata_truncated"]?.integer ?? 0) != 0
      if indexedMetadataTruncated {
        indexedMetadataTruncatedRows += 1
        bodyScanIncomplete = true
      }
      let headerMatch = Self.contains(indexedSubject, foldedQuery: foldedQuery)
        || Self.contains(sender, foldedQuery: foldedQuery)
      let previewMatch = Self.contains(preview, foldedQuery: foldedQuery)
      let indexedRead = (row["is_read"]?.integer ?? 0) != 0

      var parsed: ParsedMessage?
      if !headerMatch && !previewMatch {
        guard let file = try messageFile(
          index: indexID,
          mailboxURL: sourceMailboxURL,
          versionRoot: root
        ) else {
          bodyUnavailable += 1
          bodyScanIncomplete = true
          continue
        }
        let fileSize = try regularFileSize(file.url)
        guard fileSize <= Self.maximumMessageBytes else {
          bodyUnavailable += 1
          bodyScanIncomplete = true
          continue
        }
        guard bodyBytes <= Self.maximumSearchBytes - fileSize else {
          bodyUnavailable += 1
          bodyScanIncomplete = true
          bodyByteLimitReached = true
          break
        }
        bodyBytes += fileSize
        do {
          parsed = try parseMessage(
            at: file.url, isPartial: file.isPartial, expectedFileSize: fileSize)
        } catch {
          if Self.isPermissionError(error) { throw permissionDenied(error) }
          bodyUnavailable += 1
          bodyScanIncomplete = true
          continue
        }
        if parsed?.isPartial == true { partialBodies += 1; bodyScanIncomplete = true }
      } else {
        if let file = try messageFile(
          index: indexID,
          mailboxURL: sourceMailboxURL,
          versionRoot: root
        ) {
          let fileSize = try regularFileSize(file.url)
          if fileSize <= Self.maximumMessageBytes,
            bodyBytes <= Self.maximumSearchBytes - fileSize
          {
            bodyBytes += fileSize
            do {
              parsed = try parseMessage(
                at: file.url, isPartial: file.isPartial, expectedFileSize: fileSize)
              if parsed?.isPartial == true { partialBodies += 1; bodyScanIncomplete = true }
            } catch {
              if Self.isPermissionError(error) { throw permissionDenied(error) }
              bodyUnavailable += 1
              bodyScanIncomplete = true
            }
          } else {
            bodyUnavailable += 1
            bodyScanIncomplete = true
            if fileSize <= Self.maximumMessageBytes { bodyByteLimitReached = true }
          }
        } else {
          bodyUnavailable += 1
          bodyScanIncomplete = true
        }
      }

      let body = parsed?.text ?? ""
      let parsedSubject = parsed?.subject ?? ""
      let parsedSubjectMatch = Self.contains(parsedSubject, foldedQuery: foldedQuery)
      let bodyMatch = Self.contains(body, foldedQuery: foldedQuery)
      guard headerMatch || previewMatch || parsedSubjectMatch || bodyMatch else { continue }

      let reference = Self.mailMessageLocator(parsed?.messageID)
      let snippetSource = bodyMatch ? body : (parsedSubjectMatch ? parsedSubject : preview)
      let snippet = Self.snippet(snippetSource, query: query)
      let date = Self.receivedDate(row["date_received_raw"])
      let result = JSONValue.object([
        "mail_index_id": .string(String(indexID)),
        "mailbox_url": .string(sourceMailboxURL),
        "mailbox_name": .string(Self.mailboxName(from: sourceMailboxURL)),
        "sender": .string(sender),
        "subject": .string(String((parsed?.subject ?? indexedSubject).prefix(2_048))),
        "message_id": reference.map(JSONValue.string) ?? .null,
        "date_received": date.iso8601.map(JSONValue.string) ?? .null,
        "date_received_encoding": date.encoding.map(JSONValue.string) ?? .string("unknown"),
        "date_received_raw": Self.rawDate(row["date_received_raw"]).map(JSONValue.string) ?? .null,
        "date_sent": parsed?.sentAt.map { .string(ISO8601DateFormatter.agentString(from: $0)) } ?? .null,
        "is_read": .bool(indexedRead),
        "snippet": .string(snippet),
        "body_available": .bool(parsed != nil),
        "body_partial": .bool(parsed?.isPartial ?? false),
        "indexed_text_truncated": .bool(indexedMetadataTruncated),
        "source": .string("apple_mail_envelope_index+emlx"),
      ])
      if results.count >= resultLimit {
        stoppedForResultLimit = true
        break
      }
      let resultBytes = try result.encoded().count
      guard resultBytes <= Self.maximumSearchResultBytes - encodedResultBytes else {
        responseByteLimitReached = true
        break
      }
      encodedResultBytes += resultBytes
      results.append(result)
    }

    let scope: JSONValue
    if let mailboxURL {
      scope = .object([
        "mode": .string("exact_index_mailbox"),
        "mailbox_url": .string(mailboxURL),
        "mailbox_count": .integer(1),
      ])
    } else {
      scope = .object([
        "mode": .string("all_index_mailboxes"),
        "mailbox_count": .integer(Int64(totalMailboxCount)),
      ])
    }
    let resultTruncated = stoppedForResultLimit || responseByteLimitReached
    return .object([
      "messages": .array(results),
      "query": .string(query),
      "limit": .integer(Int64(resultLimit)),
      "scan_limit": .integer(Int64(scanLimit)),
      "scanned": .integer(Int64(scanned)),
      "scan_limit_reached": .bool(scanLimitReached),
      "results_truncated": .bool(resultTruncated),
      "scan_stopped_for_result_limit": .bool(stoppedForResultLimit),
      "response_byte_limit_reached": .bool(responseByteLimitReached),
      "body_scan_incomplete": .bool(
        bodyScanIncomplete || bodyByteLimitReached || scanLimitReached || stoppedForResultLimit
          || responseByteLimitReached
      ),
      "body_byte_limit_reached": .bool(bodyByteLimitReached),
      "body_files_unavailable": .integer(Int64(bodyUnavailable)),
      "partial_body_files": .integer(Int64(partialBodies)),
      "indexed_metadata_truncated_rows": .integer(Int64(indexedMetadataTruncatedRows)),
      "body_bytes_scanned": .integer(Int64(bodyBytes)),
      "mailbox_scope": scope,
      "index_freshness": .string("not_observed"),
      "read_only": .bool(true),
    ])
  }

  private func getMessage(input: JSONValue) async throws -> JSONValue {
    let object = try input.requiredObject()
    let rawIndexID = try object.requiredString("mail_index_id")
    guard let indexID = Int64(rawIndexID), String(indexID) == rawIndexID else {
      throw AgentError.invalid("mail_index_id must be an exact decimal index identifier")
    }
    let mailboxURL = try object.requiredString("mailbox_url")
    let (db, schema, root) = try resolved()
    guard let row = try messageRow(indexID: indexID, mailboxURL: mailboxURL, database: db, schema: schema) else {
      throw AgentError(
        code: "mail_index_message_not_found",
        message: "The exact message row is no longer present in Apple's Mail index",
        details: ["mail_index_id": .string(rawIndexID), "mailbox_url": .string(mailboxURL)],
        exitCode: 2
      )
    }
    guard let file = try messageFile(index: indexID, mailboxURL: mailboxURL, versionRoot: root) else {
      throw AgentError(
        code: "mail_index_body_unavailable",
        message: "Mail has no downloaded local message file for this index row",
        details: ["mail_index_id": .string(rawIndexID), "mailbox_url": .string(mailboxURL)],
        exitCode: 5
      )
    }
    let size = try regularFileSize(file.url)
    guard size <= Self.maximumMessageBytes else {
      throw AgentError(
        code: "mail_index_message_too_large",
        message: "The local message file exceeds the bounded read size",
        details: ["size_bytes": .integer(Int64(size)), "maximum_bytes": .integer(Int64(Self.maximumMessageBytes))],
        exitCode: 5
      )
    }
    let parsed = try parseMessage(
      at: file.url,
      isPartial: file.isPartial,
      expectedFileSize: size,
      includeAttachments: true
    )
    if let attachmentIndex = object.optionalInt("attachment_index") {
      guard attachmentIndex >= 0,
        let attachment = parsed.attachments.first(where: { $0.index == attachmentIndex })
      else {
        throw AgentError(
          code: "mail_index_attachment_not_found",
          message: "The attachment index is not present in this downloaded Mail message",
          details: [
            "mail_index_id": .string(rawIndexID),
            "mailbox_url": .string(mailboxURL),
            "attachment_index": .integer(Int64(attachmentIndex)),
            "attachments_truncated": .bool(parsed.attachmentsTruncated),
          ],
          exitCode: 2
        )
      }
      return try await readAttachment(
        attachment,
        messageID: Self.mailMessageLocator(parsed.messageID),
        mailIndexID: rawIndexID,
        mailboxURL: mailboxURL,
        isPartial: parsed.isPartial,
        attachmentsTruncated: parsed.attachmentsTruncated
      )
    }
    let body = parsed.text
    let clipped = String(body.prefix(Self.maximumBodyCharacters))
    let senderAddress = row["sender_address"]?.text ?? ""
    let senderName = row["sender_name"]?.text ?? ""
    let sender = senderName.isEmpty ? senderAddress : "\(senderName) <\(senderAddress)>"
    let subject = String((parsed.subject ?? row["subject"]?.text ?? "").prefix(2_048))
    let date = Self.receivedDate(row["date_received_raw"])
    return .object([
      "mail_index_id": .string(rawIndexID),
      "message_id": Self.mailMessageLocator(parsed.messageID).map(JSONValue.string) ?? .null,
      "mailbox_url": .string(mailboxURL),
      "mailbox_name": .string(Self.mailboxName(from: mailboxURL)),
      "sender": .string(sender),
      "subject": .string(subject),
      "date_received": date.iso8601.map(JSONValue.string) ?? .null,
      "date_received_encoding": date.encoding.map(JSONValue.string) ?? .string("unknown"),
      "date_received_raw": Self.rawDate(row["date_received_raw"]).map(JSONValue.string) ?? .null,
      "date_sent": parsed.sentAt.map { .string(ISO8601DateFormatter.agentString(from: $0)) } ?? .null,
      "is_read": .bool((row["is_read"]?.integer ?? 0) != 0),
      "body": .string(clipped),
      "body_truncated": .bool(body.count > clipped.count),
      "body_characters": .integer(Int64(body.count)),
      "body_partial": .bool(parsed.isPartial),
      "attachments": .array(parsed.attachments.map(\.json)),
      "attachments_truncated": .bool(parsed.attachmentsTruncated),
      "source": .string("apple_mail_envelope_index+emlx"),
      "read_only": .bool(true),
    ])
  }

  private func readAttachment(
    _ attachment: ParsedAttachment,
    messageID: String?,
    mailIndexID: String,
    mailboxURL: String,
    isPartial: Bool,
    attachmentsTruncated: Bool
  ) async throws -> JSONValue {
    guard let part = attachment.part, let content = part.content else {
      throw AgentError(
        code: "mail_index_attachment_unavailable",
        message: "This MIME attachment does not expose readable content",
        details: [
          "mail_index_id": .string(mailIndexID),
          "mailbox_url": .string(mailboxURL),
          "attachment": attachment.json,
        ],
        exitCode: 5
      )
    }
    let data = try Self.readDecodedAttachment(content)
    let path = "Mail attachment \(attachment.index) (\(attachment.name))"
    let pathExtension = Self.attachmentPathExtension(
      name: attachment.name, contentType: attachment.contentType)
    let outcome = try fileReader.readAttachmentData(
      data, path: path, pathExtension: pathExtension)

    var fields: [String: JSONValue]
    switch outcome {
    case .response(let response):
      fields = try response.requiredObject()
    case .textDocument(let documentData, let documentPath, let format):
      let extraction = try await TextDocumentTextExtractor.extract(
        documentData,
        path: documentPath,
        format: format,
        processRunner: processRunner
      )
      fields = [
        "encoding": .string("utf8"),
        "bytes": .integer(Int64(documentData.count)),
        "content": .string(extraction.text),
        "content_type": .string(extraction.contentType),
        "document": extraction.json,
      ]
    }
    fields["path"] = nil
    fields["mail_index_id"] = .string(mailIndexID)
    fields["message_id"] = messageID.map(JSONValue.string) ?? .null
    fields["mailbox_url"] = .string(mailboxURL)
    fields["attachment"] = attachment.json
    fields["body_partial"] = .bool(isPartial)
    fields["attachments_truncated"] = .bool(attachmentsTruncated)
    fields["source"] = .string("apple_mail_envelope_index+emlx")
    fields["read_only"] = .bool(true)
    return .object(fields)
  }

  private static func readDecodedAttachment(_ content: MimeContent) throws -> Data {
    let stream = try content.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

    while true {
      let remainingIncludingOverflowByte =
        FileReadOperations.maximumAttachmentBytes + 1 - data.count
      let amount = try stream.read(
        &buffer, offset: 0, count: min(buffer.count, remainingIncludingOverflowByte))
      guard amount > 0 else { break }
      guard amount <= FileReadOperations.maximumAttachmentBytes - data.count else {
        throw AgentError(
          code: "mail_index_attachment_too_large",
          message: "The decoded Mail attachment exceeds the bounded read size",
          details: [
            "maximum_bytes": .integer(Int64(FileReadOperations.maximumAttachmentBytes)),
          ],
          exitCode: 5
        )
      }
      data.append(contentsOf: buffer.prefix(amount))
    }
    return data
  }

  private static func attachmentPathExtension(name: String, contentType: String) -> String {
    let pathExtension = URL(fileURLWithPath: name).pathExtension
    guard pathExtension.isEmpty else { return pathExtension }
    return switch contentType.lowercased() {
    case "application/pdf": "pdf"
    case "application/msword": "doc"
    case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
      "docx"
    case "application/vnd.oasis.opendocument.text": "odt"
    case "application/rtf", "text/rtf": "rtf"
    default: ""
    }
  }

  private func resolved() throws -> (SQLiteDatabase, Schema, URL) {
    // Mail can switch its local Envelope Index version while SEMI stays running.
    guard let rootType = try fileType(at: mailRoot) else {
      throw AgentError(
        code: "mail_index_not_found",
        message: "No local Apple Mail data directory was found",
        details: ["mail_root": .string(mailRoot.path)],
        exitCode: 5
      )
    }
    guard rootType == mode_t(S_IFDIR) else {
      throw AgentError(
        code: "mail_index_path_unsafe",
        message: "The local Apple Mail data path is not a regular directory",
        details: ["mail_root": .string(mailRoot.path)],
        exitCode: 5
      )
    }
    let versions: [URL]
    do {
      let entries = try fileManager.contentsOfDirectory(
        at: mailRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
      )
      versions = try entries.compactMap { url in
        guard url.lastPathComponent.first == "V",
          Int(url.lastPathComponent.dropFirst()) != nil,
          let type = try fileType(at: url), type == mode_t(S_IFDIR)
        else { return nil }
        return url
      }.sorted {
        (Int($0.lastPathComponent.dropFirst()) ?? 0) > (Int($1.lastPathComponent.dropFirst()) ?? 0)
      }
    } catch {
      if Self.isPermissionError(error) { throw permissionDenied(error) }
      throw AgentError(
        code: "mail_index_unavailable",
        message: "Could not enumerate the local Apple Mail data directory",
        details: ["reason": .string(String(describing: error))],
        exitCode: 5
      )
    }
    guard !versions.isEmpty else {
      throw AgentError(
        code: "mail_index_not_found",
        message: "No local Apple Mail data version was found",
        details: ["mail_root": .string(mailRoot.path)],
        exitCode: 5
      )
    }

    for root in versions {
      let dataDirectory = root.appendingPathComponent("MailData", isDirectory: true)
      guard let dataDirectoryType = try fileType(at: dataDirectory) else { continue }
      guard dataDirectoryType == mode_t(S_IFDIR) else {
        throw AgentError(
          code: "mail_index_path_unsafe",
          message: "Apple Mail's local data path is not a regular directory",
          details: ["path": .string(dataDirectory.path)],
          exitCode: 5
        )
      }
      let databaseURL = dataDirectory.appendingPathComponent("Envelope Index", isDirectory: false)
      guard let databaseType = try fileType(at: databaseURL) else { continue }
      guard databaseType == mode_t(S_IFREG) else {
        throw AgentError(
          code: "mail_index_path_unsafe",
          message: "Apple Mail's local index path is not a regular file",
          details: ["path": .string(databaseURL.path)],
          exitCode: 5
        )
      }
      try requireReadableRegularFile(at: databaseURL)
      do {
        let database = try SQLiteDatabase(
          path: databaseURL.path, readOnly: true, canonicalizePath: false)
        try database.execute("PRAGMA query_only = ON")
        let schema = try inspect(database)
        return (database, schema, root)
      } catch let error as AgentError where Self.isPermissionError(error) {
        throw permissionDenied(error)
      } catch let error as AgentError where error.code == "mail_index_schema_unsupported" {
        throw error
      } catch {
        throw AgentError(
          code: "mail_index_open_failed",
          message: "Could not open the newest available Apple Mail local index read-only",
          details: [
            "path": .string(databaseURL.path),
            "reason": .string(String(describing: error)),
          ],
          exitCode: 5
        )
      }
    }
    throw AgentError(
      code: "mail_index_not_found",
      message: "Apple Mail's local Envelope Index was not found",
      details: ["mail_root": .string(mailRoot.path)],
      exitCode: 5
    )
  }

  private func inspect(_ database: SQLiteDatabase) throws -> Schema {
    let tableRows = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
    let tables = Set(tableRows.compactMap { $0["name"]?.text })
    let requiredTables: Set<String> = ["messages", "mailboxes", "addresses", "subjects"]
    guard requiredTables.isSubset(of: tables) else {
      throw unsupportedSchema("Required Mail index tables are missing")
    }
    let messageColumns = try columns("messages", database: database)
    let mailboxColumns = try columns("mailboxes", database: database)
    let addressColumns = try columns("addresses", database: database)
    let subjectColumns = try columns("subjects", database: database)
    let requiredColumns: [String: Set<String>] = [
      "messages": ["mailbox", "sender", "subject", "read", "deleted"],
      "mailboxes": ["url"],
      "addresses": ["address"],
      "subjects": ["subject"],
    ]
    let actual: [String: Set<String>] = [
      "messages": messageColumns,
      "mailboxes": mailboxColumns,
      "addresses": addressColumns,
      "subjects": subjectColumns,
    ]
    for (table, required) in requiredColumns where !required.isSubset(of: actual[table] ?? []) {
      throw unsupportedSchema("Required columns are missing from Mail index table \(table)")
    }
    let hasSummary = try tables.contains("summaries")
      && messageColumns.contains("summary")
      && columns("summaries", database: database).contains("summary")
    return Schema(
      hasDateReceived: messageColumns.contains("date_received"),
      hasDeleted: messageColumns.contains("deleted"),
      hasSummary: hasSummary,
      hasAddressComment: addressColumns.contains("comment")
    )
  }

  private func columns(_ table: String, database: SQLiteDatabase) throws -> Set<String> {
    let rows = try database.query("PRAGMA table_info(\(table))")
    return Set(rows.compactMap { $0["name"]?.text?.lowercased() })
  }

  private func mailboxExists(_ url: String, database: SQLiteDatabase) throws -> Bool {
    let rows = try database.query(
      "SELECT 1 AS present FROM mailboxes WHERE url = ? LIMIT 1",
      values: [.text(url)]
    )
    return !rows.isEmpty
  }

  private func mailboxCount(database: SQLiteDatabase) throws -> Int {
    Int(
      try database.query(
        """
        SELECT COUNT(*) AS count FROM mailboxes
        WHERE url IS NOT NULL AND length(url) BETWEEN 1 AND 2048
        """
      ).first?["count"]?.integer ?? 0
    )
  }

  private func fileType(at url: URL) throws -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      let code = errno
      if code == ENOENT || code == ENOTDIR { return nil }
      let error = AgentError(
        code: "mail_index_path_inspection_failed",
        message: "Could not inspect a local Mail path without following symbolic links",
        details: ["path": .string(url.path), "errno": .integer(Int64(code))],
        exitCode: 5
      )
      if Self.isPermissionError(error) { throw permissionDenied(error) }
      throw error
    }
    return info.st_mode & mode_t(S_IFMT)
  }

  private func requireReadableRegularFile(at url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      let code = errno
      let error = AgentError(
        code: "mail_index_file_open_failed",
        message: "Could not open the local Mail index for read-only access",
        details: ["path": .string(url.path), "errno": .integer(Int64(code))],
        exitCode: 5
      )
      if Self.isPermissionError(error) { throw permissionDenied(error) }
      throw error
    }
    defer { _ = close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else {
      throw AgentError(
        code: "mail_index_path_unsafe",
        message: "The local Mail index did not remain a regular file when opened",
        details: ["path": .string(url.path)],
        exitCode: 5
      )
    }
  }

  private func messageRow(
    indexID: Int64,
    mailboxURL: String,
    database: SQLiteDatabase,
    schema: Schema
  ) throws -> [String: SQLiteValue]? {
    let summaryJoin = schema.hasSummary
      ? "LEFT JOIN summaries sm ON m.summary = sm.ROWID"
      : ""
    let summaryExpression = schema.hasSummary ? "COALESCE(sm.summary, '')" : "''"
    let commentExpression = schema.hasAddressComment ? "COALESCE(addr.comment, '')" : "''"
    let dateExpression = schema.hasDateReceived ? "m.date_received" : "NULL"
    return try database.query(
      """
      SELECT m.ROWID AS mail_index_id,
             substr(COALESCE(addr.address, ''), 1, 320) AS sender_address,
             substr(\(commentExpression), 1, 2_048) AS sender_name,
             substr(COALESCE(subj.subject, ''), 1, 2_048) AS subject,
             \(dateExpression) AS date_received_raw,
             substr(\(summaryExpression), 1, 2_048) AS preview,
             m.read AS is_read,
             mb.url AS mailbox_url
      FROM messages m
      LEFT JOIN addresses addr ON m.sender = addr.ROWID
      LEFT JOIN subjects subj ON m.subject = subj.ROWID
      JOIN mailboxes mb ON m.mailbox = mb.ROWID
      \(summaryJoin)
      WHERE m.ROWID = ? AND mb.url = ? AND m.deleted = 0
      LIMIT 2
      """,
      values: [.integer(indexID), .text(mailboxURL)]
    ).first
  }

  private func messageFile(index: Int64, mailboxURL: String, versionRoot: URL) throws -> MailFile? {
    guard let accountID = Self.accountID(from: mailboxURL),
      !accountID.contains("/"), accountID != ".", accountID != ".."
    else { return nil }
    let directories: [URL]
    if let cached = messageDirectories[accountID] {
      directories = cached
    } else {
      let discovered = try findMessageDirectories(accountID: accountID, versionRoot: versionRoot)
      guard discovered.count <= Self.maximumCachedMessageDirectories - cachedMessageDirectoryCount else {
        throw AgentError(
          code: "mail_index_directory_limit",
          message: "Mail account storage has too many message directories to cache safely",
          details: [
            "maximum_message_directories": .integer(Int64(Self.maximumCachedMessageDirectories))
          ],
          exitCode: 5
        )
      }
      cachedMessageDirectoryCount += discovered.count
      messageDirectories[accountID] = discovered
      directories = discovered
    }
    var matches: [MailFile] = []
    for directory in directories {
      let complete = directory.appendingPathComponent("\(index).emlx", isDirectory: false)
      if try fileType(at: complete) == mode_t(S_IFREG) {
        matches.append(MailFile(url: complete, isPartial: false))
      }
      let partial = directory.appendingPathComponent("\(index).partial.emlx", isDirectory: false)
      if try fileType(at: partial) == mode_t(S_IFREG) {
        matches.append(MailFile(url: partial, isPartial: true))
      }
    }
    if matches.count > 1 {
      let complete = matches.filter { !$0.isPartial }
      if complete.count == 1 { return complete[0] }
      throw AgentError(
        code: "mail_index_body_ambiguous",
        message: "More than one local message file matches this Mail index row",
        details: ["mail_index_id": .string(String(index))],
        exitCode: 5
      )
    }
    return matches.first
  }

  private func findMessageDirectories(accountID: String, versionRoot: URL) throws -> [URL] {
    let accountRoot = versionRoot.appendingPathComponent(accountID, isDirectory: true).standardizedFileURL
    guard accountRoot.path.hasPrefix(versionRoot.standardizedFileURL.path + "/") else {
      throw AgentError.invalid("Mail account index path escapes its version directory")
    }
    guard let accountRootType = try fileType(at: accountRoot) else { return [] }
    guard accountRootType == mode_t(S_IFDIR) else {
      throw AgentError(
        code: "mail_index_path_unsafe",
        message: "The local Mail account path is not a regular directory",
        details: ["path": .string(accountRoot.path)],
        exitCode: 5
      )
    }
    var pending = [accountRoot]
    var offset = 0
    var visited = 0
    var result: [URL] = []
    while offset < pending.count {
      let directory = pending[offset]
      offset += 1
      visited += 1
      directoryNodesVisitedThisCommand += 1
      guard visited <= Self.maximumDirectoryNodes,
        directoryNodesVisitedThisCommand <= Self.maximumDirectoryNodesPerCommand
      else {
        throw AgentError(
          code: "mail_index_directory_limit",
          message: "Mail storage has too many directories to locate bounded message files",
          details: [
            "maximum_directories_per_account": .integer(Int64(Self.maximumDirectoryNodes)),
            "maximum_directories_per_command": .integer(
              Int64(Self.maximumDirectoryNodesPerCommand)
            ),
          ],
          exitCode: 5
        )
      }
      let children: [URL]
      do {
        children = try fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles]
        )
      } catch {
        if Self.isPermissionError(error) { throw permissionDenied(error) }
        throw AgentError(
          code: "mail_index_directory_read_failed",
          message: "Could not enumerate a local Mail account directory",
          details: ["reason": .string(String(describing: error))],
          exitCode: 5
        )
      }
      for child in children {
        guard try fileType(at: child) == mode_t(S_IFDIR) else { continue }
        if child.lastPathComponent == "Messages" {
          result.append(child)
        } else if child.lastPathComponent != "Attachments" {
          pending.append(child)
          guard pending.count + visited <= Self.maximumDirectoryNodes else {
            throw AgentError(
              code: "mail_index_directory_limit",
              message: "Mail account storage has too many directories to locate bounded message files",
              details: ["maximum_directories": .integer(Int64(Self.maximumDirectoryNodes))],
              exitCode: 5
            )
          }
        }
      }
    }
    return result
  }

  private func regularFileSize(_ url: URL) throws -> Int {
    let regular: URL
    let attributes: [FileAttributeKey: Any]
    do {
      regular = try LocalPathPolicy.requireRegularFile(url.path)
      attributes = try fileManager.attributesOfItem(atPath: regular.path)
    } catch {
      if Self.isPermissionError(error) { throw permissionDenied(error) }
      throw error
    }
    guard let size = attributes[.size] as? NSNumber else {
      throw AgentError(
        code: "mail_index_file_unreadable",
        message: "The local Mail message file has no readable size",
        details: ["path": .string(regular.path)],
        exitCode: 5
      )
    }
    let value = size.intValue
    guard value >= 0 else { throw AgentError.invalid("Mail message file size is invalid") }
    return value
  }

  private func readMessageData(at url: URL, expectedFileSize: Int) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      let code = errno
      let error = AgentError(
        code: "mail_index_file_read_failed",
        message: "Could not open a downloaded Mail message for bounded reading",
        details: ["path": .string(url.path), "errno": .integer(Int64(code))],
        exitCode: 5
      )
      if Self.isPermissionError(error) { throw permissionDenied(error) }
      throw error
    }
    defer { _ = close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
      let code = errno
      let error = AgentError(
        code: "mail_index_file_read_failed",
        message: "Could not inspect the opened Mail message file",
        details: ["path": .string(url.path), "errno": .integer(Int64(code))],
        exitCode: 5
      )
      if Self.isPermissionError(error) { throw permissionDenied(error) }
      throw error
    }
    guard (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      let fileSize = Int(exactly: before.st_size),
      fileSize == expectedFileSize,
      fileSize <= Self.maximumMessageBytes
    else {
      throw AgentError(
        code: "mail_index_message_changed",
        message: "The local Mail message file changed size or type while it was being read",
        details: ["path": .string(url.path)],
        exitCode: 6
      )
    }

    var data = Data()
    data.reserveCapacity(fileSize)
    var buffer = Data(count: min(64 * 1_024, max(fileSize, 1)))
    while data.count < fileSize {
      let requestCount = min(buffer.count, fileSize - data.count)
      let amount = buffer.withUnsafeMutableBytes { bytes in
        read(descriptor, bytes.baseAddress, requestCount)
      }
      if amount < 0 {
        let code = errno
        if code == EINTR { continue }
        let error = AgentError(
          code: "mail_index_file_read_failed",
          message: "Could not read the bounded local Mail message file",
          details: ["path": .string(url.path), "errno": .integer(Int64(code))],
          exitCode: 5
        )
        if Self.isPermissionError(error) { throw permissionDenied(error) }
        throw error
      }
      guard amount > 0 else {
        throw AgentError(
          code: "mail_index_message_changed",
          message: "The local Mail message file became shorter while it was being read",
          details: ["path": .string(url.path)],
          exitCode: 6
        )
      }
      data.append(contentsOf: buffer.prefix(amount))
    }

    var after = stat()
    guard fstat(descriptor, &after) == 0, Self.sameFileRevision(before, after) else {
      throw AgentError(
        code: "mail_index_message_changed",
        message: "The local Mail message file changed during the bounded read",
        details: ["path": .string(url.path)],
        exitCode: 6
      )
    }
    return data
  }

  private func parseMessage(
    at url: URL,
    isPartial: Bool,
    expectedFileSize: Int,
    includeAttachments: Bool = false
  ) throws -> ParsedMessage {
    guard expectedFileSize <= Self.maximumMessageBytes else {
      throw AgentError(
        code: "mail_index_message_too_large",
        message: "The downloaded Mail message exceeds the per-message read bound",
        details: ["size_bytes": .integer(Int64(expectedFileSize))],
        exitCode: 5
      )
    }
    let file = try readMessageData(at: url, expectedFileSize: expectedFileSize)
    guard let newline = file.firstIndex(of: 0x0A),
      let lengthText = String(data: file[..<newline], encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines),
      let messageLength = Int(lengthText), messageLength >= 0
    else {
      throw AgentError(
        code: "mail_index_emlx_invalid",
        message: "The local Mail message file has an invalid .emlx byte-count header",
        details: ["path": .string(url.path)],
        exitCode: 5
      )
    }
    let messageStart = file.index(after: newline)
    let messageStartOffset = file.distance(from: file.startIndex, to: messageStart)
    let (messageEndOffset, overflow) = messageStartOffset.addingReportingOverflow(messageLength)
    guard !overflow, messageEndOffset <= file.count else {
      throw AgentError(
        code: "mail_index_emlx_invalid",
        message: "The local Mail message file is shorter than its .emlx byte-count header",
        details: ["path": .string(url.path)],
        exitCode: 5
      )
    }
    let messageData = file.subdata(in: messageStartOffset..<messageEndOffset)
    let message = try MimeMessage.load(MemoryStream(Array(messageData)))
    let htmlText: String
    if let html = message.htmlBody, !html.isEmpty {
      htmlText = try SwiftSoup.parse(html).text()
    } else {
      htmlText = ""
    }
    let plainText = message.textBody ?? ""
    let body: String
    if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      body = htmlText
    } else {
      body = plainText
    }
    let messageID = message.messageId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachmentRead = includeAttachments
      ? Self.attachments(in: message.body)
      : (attachments: [], truncated: false)
    return ParsedMessage(
      text: body,
      messageID: messageID?.isEmpty == false ? messageID : nil,
      subject: message.subject,
      sentAt: message.date?.date,
      isPartial: isPartial,
      attachments: attachmentRead.attachments,
      attachmentsTruncated: attachmentRead.truncated
    )
  }

  private static func attachments(
    in body: MimeEntity?
  ) -> (attachments: [ParsedAttachment], truncated: Bool) {
    var attachments: [ParsedAttachment] = []
    var visited = 0
    var truncated = false

    func visit(_ entity: MimeEntity) {
      guard !truncated else { return }
      visited += 1
      guard visited <= Self.maximumMimeEntitiesVisited else {
        truncated = true
        return
      }

      if entity.contentDisposition?.isAttachment == true {
        guard attachments.count < Self.maximumListedAttachments else {
          truncated = true
          return
        }
        let index = attachments.count
        let part = entity as? MimePart
        attachments.append(
          ParsedAttachment(
            index: index,
            name: Self.attachmentName(part?.fileName ?? entity.contentType.name, index: index),
            contentType: entity.contentType.mimeType,
            part: part
          ))
        return
      }

      guard let multipart = entity as? Multipart else { return }
      for child in multipart {
        visit(child)
        if truncated { return }
      }
    }

    if let body { visit(body) }
    return (attachments, truncated)
  }

  private static func attachmentName(_ suggestedName: String?, index: Int) -> String {
    let lastComponent = suggestedName?.split(whereSeparator: { $0 == "/" || $0 == "\\" })
      .last.map(String.init)
    guard let lastComponent else { return "attachment-\(index)" }
    let name = lastComponent.components(separatedBy: .controlCharacters).joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "attachment-\(index)" : String(name.prefix(255))
  }

  private func unsupportedSchema(_ message: String) -> AgentError {
    AgentError(
      code: "mail_index_schema_unsupported",
      message: message,
      details: ["recovery": .string("Use mail.messages.search or inspect the current Mail schema before retrying.")],
      exitCode: 5
    )
  }

  private func permissionDenied(_ error: any Error) -> AgentError {
    AgentError(
      code: "mail_index_permission_denied",
      message: "Reading Apple's local Mail index requires Full Disk Access",
      details: [
        "area": .string(PrivacyOnboardingArea.fullDiskAccess.rawValue),
        "settings_url": .string(PrivacyOnboardingArea.fullDiskAccess.settingsURL),
        "reason": .string(String(describing: error)),
      ],
      exitCode: 3
    )
  }

  private static func isPermissionError(_ error: any Error) -> Bool {
    if let agentError = error as? AgentError {
      if agentError.code == "mail_index_permission_denied" { return true }
      let reason = agentError.details["reason"]?.stringValue ?? ""
      let code = agentError.details["errno"]?.intValue
      return code == Int(EACCES) || code == Int(EPERM)
        || [
          "authorization denied", "permission denied", "no permission", "operation not permitted",
          "access denied",
        ]
        .contains { reason.localizedCaseInsensitiveContains($0) }
    }
    let value = error as NSError
    if value.code == Int(EACCES) || value.code == Int(EPERM) { return true }
    if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError,
      isPermissionError(underlying)
    {
      return true
    }
    return [
      "authorization denied", "permission denied", "no permission", "operation not permitted",
      "access denied",
    ].contains { value.localizedDescription.localizedCaseInsensitiveContains($0) }
  }

  private static func sameFileRevision(_ lhs: stat, _ rhs: stat) -> Bool {
    #if canImport(Darwin)
      let leftModification = lhs.st_mtimespec
      let rightModification = rhs.st_mtimespec
    #else
      let leftModification = lhs.st_mtim
      let rightModification = rhs.st_mtim
    #endif
    return lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && leftModification.tv_sec == rightModification.tv_sec
      && leftModification.tv_nsec == rightModification.tv_nsec
  }

  private static func accountID(from mailboxURL: String) -> String? {
    guard let components = URLComponents(string: mailboxURL),
      let host = components.host?.removingPercentEncoding,
      !host.isEmpty, !host.contains("/"), !host.contains("\0"), host != ".", host != ".."
    else { return nil }
    return host
  }

  private static func mailboxName(from mailboxURL: String) -> String {
    guard let components = URLComponents(string: mailboxURL) else { return mailboxURL }
    let path = components.path.removingPercentEncoding ?? components.path
    return path.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: ".mbox", with: "") ?? path
  }

  private static func mailMessageLocator(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, Data(value.utf8).count <= 1_500,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      return nil
    }
    let token = Data(value.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "mail-rfcid:v1:\(token)"
  }

  private static func contains(_ text: String, foldedQuery: String) -> Bool {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .contains(foldedQuery)
  }

  private static func snippet(_ text: String, query: String) -> String {
    guard let range = text.range(
      of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current
    ) else {
      return String(text.prefix(maximumSnippetCharacters))
    }
    let before = text.distance(from: text.startIndex, to: range.lowerBound)
    let after = text.distance(from: range.upperBound, to: text.endIndex)
    let start = text.index(range.lowerBound, offsetBy: -min(120, before))
    let end = text.index(range.upperBound, offsetBy: min(300, after))
    let excerpt = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    return String(excerpt.prefix(maximumSnippetCharacters))
  }

  private static func receivedDate(_ rawValue: SQLiteValue?) -> (iso8601: String?, encoding: String?) {
    guard let raw = rawValue?.number, raw.isFinite else { return (nil, nil) }
    let unix = Date(timeIntervalSince1970: raw)
    let cocoa = Date(timeIntervalSinceReferenceDate: raw)
    let lower = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01 UTC
    let upper = Date().addingTimeInterval(366 * 24 * 60 * 60)
    let unixPlausible = unix >= lower && unix <= upper
    let cocoaPlausible = cocoa >= lower && cocoa <= upper
    let selected: (Date, String)?
    switch (unixPlausible, cocoaPlausible) {
    case (true, false): selected = (unix, "inferred_unix_seconds")
    case (false, true): selected = (cocoa, "inferred_cocoa_seconds")
    case (true, true): selected = raw >= 1_000_000_000
      ? (unix, "ambiguous_unix_seconds_heuristic")
      : (cocoa, "ambiguous_cocoa_seconds_heuristic")
    case (false, false): selected = nil
    }
    guard let selected else { return (nil, nil) }
    return (ISO8601DateFormatter.agentString(from: selected.0), selected.1)
  }

  private static func rawDate(_ rawValue: SQLiteValue?) -> String? {
    guard let value = rawValue?.number, value.isFinite else { return nil }
    return String(value)
  }
}
