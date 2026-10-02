package import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum FileReadOutcome: Sendable {
  case response(JSONValue)
  case textDocument(data: Data, path: String, format: String)
}

struct FileReadOperations {
  static let maximumAttachmentBytes = 8 * 1_024 * 1_024
  private static let maximumAttachmentTextBytes = 64 * 1_024
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func list(_ object: [String: JSONValue]) throws -> JSONValue {
    let root = try LocalPathPolicy.expandedURL(object.requiredString("path"))
    var rootInfo = stat()
    guard lstat(root.path, &rootInfo) == 0,
      (rootInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    else {
      throw AgentError(
        code: "directory_not_found",
        message: "Directory does not exist or is a symbolic link",
        details: ["path": .string(root.path)],
        exitCode: 5
      )
    }
    let limit = object.optionalInt("limit", default: 200) ?? 200
    let urls = try FileTreeLister(fileManager: fileManager).list(
      root: root,
      recursive: object.optionalBool("recursive"),
      includeHidden: object.optionalBool("include_hidden"),
      maximumCount: limit + 1
    )
    let truncated = urls.count > limit
    let entries = try urls.prefix(limit).map(metadata)
    return .object([
      "root": .string(root.path), "entries": .array(entries), "truncated": .bool(truncated),
    ])
  }

  func metadata(_ object: [String: JSONValue]) throws -> JSONValue {
    try metadata(try LocalPathPolicy.expandedURL(object.requiredString("path")))
  }

  func read(_ object: [String: JSONValue]) throws -> FileReadOutcome {
    let encoding = object.optionalString("encoding") ?? "utf8"
    if encoding == "base64" {
      let file = try readBytes(
        path: object.requiredString("path"),
        maximumBytes: object.optionalInt("max_bytes", default: 1_024 * 1_024) ?? 1_024 * 1_024
      )
      return .response(.object([
        "path": .string(file.path), "encoding": .string("base64"),
        "bytes": .integer(Int64(file.data.count)),
        "content": .string(file.data.base64EncodedString()),
      ]))
    }

    let url = try LocalPathPolicy.expandedURL(object.requiredString("path"))
    let maximum = object.optionalInt("max_bytes", default: 1_024 * 1_024) ?? 1_024 * 1_024
    guard maximum >= 0, maximum < Int.max else {
      throw AgentError.invalid("max_bytes exceeds the supported range")
    }
    let fileContent = try withStableRegularFile(url) { descriptor, opened in
      #if os(macOS)
        var isPDF = false
        var isImage = false
        var documentFormat: String?
        var effectiveMaximum = maximum
        let probeLimit = min(
          maximum + 1,
          max(PDFTextExtractor.headerProbeBytes, ImageTextExtractor.headerProbeBytes))
        let probe = try readAtMost(probeLimit, descriptor: descriptor, path: url.path)
        isPDF = PDFTextExtractor.recognizes(probe)
          || url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
        isImage = !isPDF
          && ImageTextExtractor.recognizes(probe, pathExtension: url.pathExtension)
        if !isPDF && !isImage {
          documentFormat = TextDocumentTextExtractor.format(
            forPathExtension: url.pathExtension)
        }
        try seekToStart(descriptor, path: url.path)

        if isPDF {
          effectiveMaximum = min(maximum, PDFTextExtractor.maximumInputBytes)
          guard opened.st_size <= Int64(effectiveMaximum) else {
            throw AgentError(
              code: "file_too_large",
              message: "PDF exceeds the bounded text extraction input limit",
              details: [
                "path": .string(url.path),
                "bytes": .integer(Int64(opened.st_size)),
                "max_bytes": .integer(Int64(effectiveMaximum)),
                "pdf_input_limit_bytes": .integer(
                  Int64(PDFTextExtractor.maximumInputBytes)),
              ],
              exitCode: 5
            )
          }
        } else if isImage {
          effectiveMaximum = min(maximum, ImageTextExtractor.maximumInputBytes)
          guard opened.st_size <= Int64(effectiveMaximum) else {
            throw AgentError(
              code: "file_too_large",
              message: "Image exceeds the bounded text extraction input limit",
              details: [
                "path": .string(url.path),
                "bytes": .integer(Int64(opened.st_size)),
                "max_bytes": .integer(Int64(effectiveMaximum)),
                "image_input_limit_bytes": .integer(
                  Int64(ImageTextExtractor.maximumInputBytes)),
              ],
              exitCode: 5
            )
          }
        } else if documentFormat != nil {
          effectiveMaximum = min(maximum, TextDocumentTextExtractor.maximumInputBytes)
          guard opened.st_size <= Int64(effectiveMaximum) else {
            throw AgentError(
              code: "file_too_large",
              message: "Document exceeds the bounded text extraction input limit",
              details: [
                "path": .string(url.path),
                "bytes": .integer(Int64(opened.st_size)),
                "max_bytes": .integer(Int64(effectiveMaximum)),
                "document_input_limit_bytes": .integer(
                  Int64(TextDocumentTextExtractor.maximumInputBytes)),
              ],
              exitCode: 5
            )
          }
        }
      #else
        let isPDF = false
        let isImage = false
        let documentFormat: String? = nil
        let effectiveMaximum = maximum
      #endif

      let data = try readAtMost(effectiveMaximum + 1, descriptor: descriptor, path: url.path)
      return (
        data: data,
        isPDF: isPDF,
        isImage: isImage,
        documentFormat: documentFormat,
        effectiveMaximum: effectiveMaximum
      )
    }
    let data = fileContent.data
    let effectiveMaximum = fileContent.effectiveMaximum
    guard data.count <= effectiveMaximum else {
      var details: [String: JSONValue] = [
        "path": .string(url.path), "max_bytes": .integer(Int64(effectiveMaximum)),
      ]
      if fileContent.isPDF {
        details["pdf_input_limit_bytes"] = .integer(
          Int64(PDFTextExtractor.maximumInputBytes))
      } else if fileContent.isImage {
        details["image_input_limit_bytes"] = .integer(
          Int64(ImageTextExtractor.maximumInputBytes))
      } else if let documentFormat = fileContent.documentFormat {
        details["document_format"] = .string(documentFormat)
        details["document_input_limit_bytes"] = .integer(
          Int64(TextDocumentTextExtractor.maximumInputBytes))
      }
      throw AgentError(
        code: "file_too_large",
        message: fileContent.isPDF || fileContent.isImage || fileContent.documentFormat != nil
          ? "File exceeds the bounded text extraction input limit" : "File exceeds max_bytes",
        details: details,
        exitCode: 5
      )
    }
    return try extract(
      data,
      path: url.path,
      isPDF: fileContent.isPDF,
      isImage: fileContent.isImage,
      documentFormat: fileContent.documentFormat,
      maximumTextBytes: nil
    )
  }

  func readBytes(path: String, maximumBytes: Int) throws -> (path: String, data: Data) {
    guard maximumBytes >= 0, maximumBytes < Int.max else {
      throw AgentError.invalid("max_bytes exceeds the supported range")
    }
    let url = try LocalPathPolicy.expandedURL(path)
    let data = try withStableRegularFile(url) { descriptor, _ in
      try readAtMost(maximumBytes + 1, descriptor: descriptor, path: url.path)
    }
    guard data.count <= maximumBytes else {
      throw AgentError(
        code: "file_too_large",
        message: "File exceeds max_bytes",
        details: [
          "path": .string(url.path), "max_bytes": .integer(Int64(maximumBytes)),
        ],
        exitCode: 5
      )
    }
    return (url.path, data)
  }

  func readAttachmentData(
    _ data: Data,
    path: String,
    pathExtension: String
  ) throws -> FileReadOutcome {
    guard data.count <= Self.maximumAttachmentBytes else {
      throw AgentError(
        code: "mail_index_attachment_too_large",
        message: "The decoded Mail attachment exceeds the bounded read size",
        details: [
          "bytes": .integer(Int64(data.count)),
          "maximum_bytes": .integer(Int64(Self.maximumAttachmentBytes)),
        ],
        exitCode: 5
      )
    }

    #if os(macOS)
      let isPDF = PDFTextExtractor.recognizes(data)
        || pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
      let isImage = !isPDF && ImageTextExtractor.recognizes(data, pathExtension: pathExtension)
      let documentFormat = !isPDF && !isImage
        ? TextDocumentTextExtractor.format(forPathExtension: pathExtension)
        : nil
    #else
      let isPDF = false
      let isImage = false
      let documentFormat: String? = nil
    #endif
    return try extract(
      data,
      path: path,
      isPDF: isPDF,
      isImage: isImage,
      documentFormat: documentFormat,
      maximumTextBytes: Self.maximumAttachmentTextBytes
    )
  }

  private func extract(
    _ data: Data,
    path: String,
    isPDF: Bool,
    isImage: Bool,
    documentFormat: String?,
    maximumTextBytes: Int?
  ) throws -> FileReadOutcome {
    #if os(macOS)
      if isPDF {
        let extraction = try PDFTextExtractor.extract(data, path: path)
        return .response(.object([
          "path": .string(path), "encoding": .string("utf8"),
          "bytes": .integer(Int64(data.count)), "content": .string(extraction.text),
          "content_type": .string("application/pdf"), "pdf": extraction.json,
        ]))
      }
      if isImage {
        let extraction = try ImageTextExtractor.extract(data, path: path)
        return .response(.object([
          "path": .string(path), "encoding": .string("utf8"),
          "bytes": .integer(Int64(data.count)), "content": .string(extraction.text),
          "content_type": .string(extraction.contentType), "image": extraction.json,
        ]))
      }
      if let documentFormat {
        return .textDocument(data: data, path: path, format: documentFormat)
      }
    #endif

    guard let text = String(data: data, encoding: .utf8) else {
      throw AgentError(
        code: maximumTextBytes == nil ? "invalid_utf8" : "mail_index_attachment_not_text",
        message: maximumTextBytes == nil
          ? "File is not valid UTF-8; use base64 encoding"
          : "This Mail attachment format has no local text extractor",
        details: ["path": .string(path)],
        exitCode: 5
      )
    }
    var response: [String: JSONValue] = [
      "path": .string(path), "encoding": .string("utf8"),
      "bytes": .integer(Int64(data.count)),
    ]
    if let maximumTextBytes {
      let bounded = Self.utf8Prefix(text, maximumBytes: maximumTextBytes)
      response["content"] = .string(bounded.text)
      response["text_truncated"] = .bool(bounded.truncated)
    } else {
      response["content"] = .string(text)
    }
    return .response(.object(response))
  }

  private static func utf8Prefix(
    _ text: String,
    maximumBytes: Int
  ) -> (text: String, truncated: Bool) {
    var index = text.unicodeScalars.startIndex
    var byteCount = 0
    while index != text.unicodeScalars.endIndex {
      let scalar = text.unicodeScalars[index]
      let scalarBytes = scalar.utf8.count
      guard scalarBytes <= maximumBytes - byteCount else { break }
      byteCount += scalarBytes
      index = text.unicodeScalars.index(after: index)
    }
    return (String(text[..<index]), index != text.unicodeScalars.endIndex)
  }

  private func seekToStart(_ descriptor: Int32, path: String) throws {
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw AgentError(
        code: "file_read_failed",
        message: "Could not restart the bounded file read",
        details: ["path": .string(path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
  }

  private func metadata(_ url: URL) throws -> JSONValue {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw AgentError(
        code: "path_not_found", message: "Path does not exist",
        details: ["path": .string(url.path), "errno": .integer(Int64(errno))], exitCode: 5)
    }
    let type = info.st_mode & mode_t(S_IFMT)
    let kind: String
    if type == mode_t(S_IFREG) {
      kind = "file"
    } else if type == mode_t(S_IFDIR) {
      kind = "directory"
    } else if type == mode_t(S_IFLNK) {
      kind = "symlink"
    } else {
      kind = "other"
    }
    var result: [String: JSONValue] = [
      "path": .string(url.path), "kind": .string(kind), "size": .integer(Int64(info.st_size)),
      "mode": .string(String(format: "%04o", info.st_mode & 0o7777)),
      "modified_at": .string(
        ISO8601DateFormatter.agentString(
          from: Date(timeIntervalSince1970: TimeInterval(fileModificationTime(info).seconds)))),
    ]
    if kind == "symlink" {
      let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
      result["symlink_destination"] = .string(destination)
    }
    return .object(result)
  }

  private func withStableRegularFile<T>(
    _ url: URL,
    body: (Int32, stat) throws -> T
  ) throws -> T {
    var expected = stat()
    guard lstat(url.path, &expected) == 0,
      (expected.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    else {
      throw notRegularFile(url.path)
    }

    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw notRegularFile(url.path, errnoValue: errno)
    }

    var descriptorIsOpen = true
    do {
      var opened = stat()
      guard fstat(descriptor, &opened) == 0,
        sameStableFile(expected, opened)
      else {
        throw AgentError(
          code: "path_changed_during_read",
          message: "File changed while it was being opened",
          details: ["path": .string(url.path)],
          exitCode: 6
        )
      }

      let value = try body(descriptor, opened)
      var after = stat()
      guard fstat(descriptor, &after) == 0, sameStableFile(opened, after) else {
        throw AgentError(
          code: "path_changed_during_read",
          message: "File changed while it was being read",
          details: ["path": .string(url.path)],
          exitCode: 6
        )
      }
      descriptorIsOpen = false
      guard close(descriptor) == 0 else {
        throw AgentError(
          code: "file_read_cleanup_failed",
          message: "Could not close the file after reading",
          details: ["path": .string(url.path), "errno": .integer(Int64(errno))],
          exitCode: 5
        )
      }
      return value
    } catch {
      let originalError = error
      guard descriptorIsOpen else { throw originalError }
      descriptorIsOpen = false
      guard close(descriptor) == 0 else {
        throw AgentError(
          code: "file_read_cleanup_failed",
          message: "File read failed and its descriptor could not be closed",
          details: [
            "path": .string(url.path),
            "errno": .integer(Int64(errno)),
            "original_error": .string(String(describing: originalError)),
          ],
          exitCode: 5
        )
      }
      throw originalError
    }
  }

  private func readAtMost(_ maximum: Int, descriptor: Int32, path: String) throws -> Data {
    var data = Data()
    data.reserveCapacity(min(maximum, 1_024 * 1_024))
    var buffer = [UInt8](repeating: 0, count: min(maximum, 64 * 1_024))
    while data.count < maximum {
      try requireNotCancelled()
      let requested = min(buffer.count, maximum - data.count)
      let count = try readChunk(descriptor, into: &buffer, count: requested, path: path)
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }

  private func readChunk(
    _ descriptor: Int32,
    into buffer: inout [UInt8],
    count: Int,
    path: String
  ) throws -> Int {
    while true {
      let result = buffer.withUnsafeMutableBytes { raw -> Int in
        guard let base = raw.baseAddress else { return 0 }
        #if canImport(Darwin)
          return Darwin.read(descriptor, base, count)
        #else
          return Glibc.read(descriptor, base, count)
        #endif
      }
      if result >= 0 { return result }
      if errno == EINTR { continue }
      throw AgentError(
        code: "file_read_failed",
        message: "Could not read file content",
        details: ["path": .string(path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
  }

  private func sameStableFile(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev
      && left.st_ino == right.st_ino
      && (right.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
      && left.st_mode == right.st_mode
      && left.st_size == right.st_size
      && fileModificationTime(left) == fileModificationTime(right)
      && fileChangeTime(left) == fileChangeTime(right)
  }

  private func notRegularFile(_ path: String, errnoValue: Int32? = nil) -> AgentError {
    var details: [String: JSONValue] = ["path": .string(path)]
    if let errnoValue { details["errno"] = .integer(Int64(errnoValue)) }
    return AgentError(
      code: "not_regular_file",
      message: "Path is not a regular file or is a symbolic link",
      details: details,
      exitCode: 5
    )
  }

  private func requireNotCancelled() throws {
    guard !Task.isCancelled else {
      throw AgentError(
        code: "operation_cancelled",
        message: "File read was cancelled",
        exitCode: 6
      )
    }
  }
}

package func readStableFileBytes(
  path: String,
  maximumBytes: Int
) throws -> (path: String, data: Data) {
  try FileReadOperations().readBytes(path: path, maximumBytes: maximumBytes)
}
