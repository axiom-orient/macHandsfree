import Foundation
import MacHandsfreeCore
import ZIPFoundation

struct TextDocumentExtraction: Sendable {
  let text: String
  let contentType: String
  let format: String
  let textTruncated: Bool

  var json: JSONValue {
    .object([
      "format": .string(format),
      "text_truncated": .bool(textTruncated),
    ])
  }
}

enum TextDocumentTextExtractor {
  static let maximumInputBytes = 8 * 1_024 * 1_024
  private static let maximumTextBytes = 64 * 1_024
  private static let maximumDiagnosticBytes = 4 * 1_024
  private static let maximumOfficeArchiveEntries = 10_000
  private static let maximumOfficeArchiveExpandedBytes = 32 * 1_024 * 1_024
  private static let officeArchiveReadBufferBytes = 32 * 1_024
  private static let timeout: TimeInterval = 30

  static func format(forPathExtension pathExtension: String) -> String? {
    return switch pathExtension.lowercased() {
    case "doc": "doc"
    case "docx": "docx"
    case "odt": "odt"
    case "rtf": "rtf"
    default: nil
    }
  }

  static func extract(
    _ data: Data,
    path: String,
    format: String,
    processRunner: any ProcessRunning
  ) async throws -> TextDocumentExtraction {
    guard data.count <= maximumInputBytes else {
      throw AgentError(
        code: "file_too_large",
        message: "Document exceeds the bounded text extraction input limit",
        details: [
          "path": .string(path),
          "bytes": .integer(Int64(data.count)),
          "document_input_limit_bytes": .integer(Int64(maximumInputBytes)),
        ],
        exitCode: 5
      )
    }
    guard let contentType = contentType(for: format) else {
      throw AgentError.invalid("Unsupported text document format")
    }
    if format == "docx" || format == "odt" {
      try validateOfficeArchive(data, path: path, format: format)
    }

    let result: ProcessResult
    do {
      result = try await processRunner.run(
        ProcessRequest(
          executable: "/usr/bin/textutil",
          arguments: [
            "-convert", "txt", "-format", format, "-stdin", "-stdout", "-encoding", "UTF-8",
          ],
          input: data,
          timeout: timeout,
          maximumOutputBytes: maximumTextBytes + 4 + maximumDiagnosticBytes
        ))
    } catch let error as AgentError {
      throw AgentError(
        code: error.code,
        message: error.message,
        details: error.details,
        exitCode: error.exitCode
      )
    } catch {
      throw extractionFailed(path: path, format: format)
    }

    guard !result.timedOut else {
      throw AgentError(
        code: "text_document_timeout",
        message: "Document text extraction exceeded its time limit",
        details: ["path": .string(path), "timeout_seconds": .integer(Int64(timeout))],
        exitCode: 5
      )
    }
    if result.outputLimitExceeded {
      guard result.stdout.count >= maximumTextBytes + 4,
        result.stderr.count <= maximumDiagnosticBytes
      else {
        throw extractionFailed(path: path, format: format)
      }
    } else if result.exitCode != 0 {
      throw extractionFailed(path: path, format: format)
    }

    let decodeByteCount = min(result.stdout.count, maximumTextBytes + 4)
    guard let text = decodeUTF8Prefix(result.stdout, byteCount: decodeByteCount) else {
      throw AgentError(
        code: "text_document_invalid_output",
        message: "Document text extractor returned invalid UTF-8",
        details: ["path": .string(path), "format": .string(format)],
        exitCode: 5
      )
    }
    let bounded = VisionTextRecognizer.prefix(text, maximumBytes: maximumTextBytes)
    return TextDocumentExtraction(
      text: bounded.text,
      contentType: contentType,
      format: format,
      textTruncated: bounded.truncated || result.outputLimitExceeded
    )
  }

  private static func validateOfficeArchive(_ data: Data, path: String, format: String) throws {
    let declaredEntryCount = try centralDirectoryEntryCount(in: data, path: path, format: format)
    guard declaredEntryCount <= maximumOfficeArchiveEntries else {
      throw entryLimitExceeded(path: path, format: format, entryCount: declaredEntryCount)
    }

    let archive: Archive
    do {
      archive = try Archive(data: data, accessMode: .read)
    } catch {
      throw extractionFailed(path: path, format: format)
    }

    var entryCount = 0
    var expandedBytes = 0
    do {
      for entry in archive {
        entryCount += 1
        guard entryCount <= maximumOfficeArchiveEntries else {
          throw entryLimitExceeded(path: path, format: format, entryCount: entryCount)
        }

        switch entry.type {
        case .directory:
          guard entry.uncompressedSize == 0, entry.compressedSize == 0 else {
            throw extractionFailed(path: path, format: format)
          }
          continue
        case .symlink:
          throw extractionFailed(path: path, format: format)
        case .file:
          let remainingPackageBytes = maximumOfficeArchiveExpandedBytes - expandedBytes
          guard entry.uncompressedSize <= UInt64(remainingPackageBytes) else {
            throw expansionLimitExceeded(path: path, format: format)
          }

          let expectedEntryBytes = Int(entry.uncompressedSize)
          var entryBytes = 0
          let checksum = try archive.extract(
            entry,
            bufferSize: officeArchiveReadBufferBytes,
            consumer: { chunk in
              guard !Task.isCancelled else { throw cancellationError(path: path) }
              let (nextEntryBytes, entryOverflow) = entryBytes.addingReportingOverflow(chunk.count)
              let (nextExpandedBytes, packageOverflow) = expandedBytes.addingReportingOverflow(chunk.count)
              guard !entryOverflow, !packageOverflow,
                nextEntryBytes <= expectedEntryBytes,
                nextExpandedBytes <= maximumOfficeArchiveExpandedBytes
              else {
                throw expansionLimitExceeded(path: path, format: format)
              }
              entryBytes = nextEntryBytes
              expandedBytes = nextExpandedBytes
            })
          guard entryBytes == expectedEntryBytes, checksum == entry.checksum else {
            throw extractionFailed(path: path, format: format)
          }
        }
      }
      guard entryCount == declaredEntryCount else {
        throw extractionFailed(path: path, format: format)
      }
    } catch let error as AgentError {
      throw error
    } catch {
      throw extractionFailed(path: path, format: format)
    }
  }

  private static func centralDirectoryEntryCount(in data: Data, path: String, format: String) throws
    -> Int
  {
    guard data.count >= 22 else { throw extractionFailed(path: path, format: format) }
    let searchStart = max(0, data.count - 22 - Int(UInt16.max))
    for offset in stride(from: data.count - 22, through: searchStart, by: -1) {
      guard data[offset] == 0x50, data[offset + 1] == 0x4B,
        data[offset + 2] == 0x05, data[offset + 3] == 0x06
      else { continue }
      let commentLength = Int(readLittleEndianUInt16(data, at: offset + 20))
      guard offset + 22 + commentLength == data.count else { continue }
      let disk = readLittleEndianUInt16(data, at: offset + 4)
      let directoryDisk = readLittleEndianUInt16(data, at: offset + 6)
      let diskEntryCount = readLittleEndianUInt16(data, at: offset + 8)
      let entryCount = readLittleEndianUInt16(data, at: offset + 10)
      guard disk == 0, directoryDisk == 0, diskEntryCount == entryCount else {
        throw extractionFailed(path: path, format: format)
      }
      return Int(entryCount)
    }
    throw extractionFailed(path: path, format: format)
  }

  private static func readLittleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func expansionLimitExceeded(path: String, format: String) -> AgentError {
    return AgentError(
      code: "file_too_large",
      message: "Document archive exceeds its bounded expansion limits",
      details: [
        "path": .string(path),
        "format": .string(format),
        "document_archive_expanded_limit_bytes": .integer(
          Int64(maximumOfficeArchiveExpandedBytes)),
      ],
      exitCode: 5
    )
  }

  private static func entryLimitExceeded(path: String, format: String, entryCount: Int) -> AgentError {
    return AgentError(
      code: "file_too_large",
      message: "Document archive contains too many entries",
      details: [
        "path": .string(path),
        "format": .string(format),
        "document_archive_entry_limit": .integer(Int64(maximumOfficeArchiveEntries)),
        "document_archive_entry_count": .integer(Int64(entryCount)),
      ],
      exitCode: 5
    )
  }

  private static func cancellationError(path: String) -> AgentError {
    AgentError(
      code: "operation_cancelled",
      message: "Document archive inspection was cancelled",
      details: ["path": .string(path)],
      exitCode: 6
    )
  }

  private static func decodeUTF8Prefix(_ data: Data, byteCount: Int) -> String? {
    let minimumByteCount = max(0, byteCount - 3)
    for length in stride(from: byteCount, through: minimumByteCount, by: -1) {
      if let value = String(data: Data(data.prefix(length)), encoding: .utf8) {
        return value
      }
    }
    return nil
  }

  private static func contentType(for format: String) -> String? {
    return switch format {
    case "doc": "application/msword"
    case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "odt": "application/vnd.oasis.opendocument.text"
    case "rtf": "text/rtf"
    default: nil
    }
  }

  private static func extractionFailed(path: String, format: String) -> AgentError {
    AgentError(
      code: "text_document_read_failed",
      message: "macOS could not extract text from the document",
      details: ["path": .string(path), "format": .string(format)],
      exitCode: 5
    )
  }
}
