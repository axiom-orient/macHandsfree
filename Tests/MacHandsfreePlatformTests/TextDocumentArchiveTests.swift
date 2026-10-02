import Foundation
import MacHandsfreeCore
import Testing
import ZIPFoundation
@testable import MacHandsfreePlatform

struct TextDocumentArchiveTests {
  @Test func boundedDocxAndOdtArchivesReachTheExistingTextConverter() async throws {
    let runner = StubTextDocumentProcessRunner()
    for (format, path) in [
      ("docx", "word/document.xml"),
      ("odt", "content.xml"),
    ] {
      let archive = try makeArchive(
        path: path,
        payload: Data("<document>bounded</document>".utf8))
      let result = try await TextDocumentTextExtractor.extract(
        archive,
        path: "attachment.\(format)",
        format: format,
        processRunner: runner)

      #expect(result.format == format)
      #expect(result.text == "converted")
    }
  }

  @Test func oversizedOfficeArchiveIsRejectedBeforeTextConversion() async throws {
    let archive = try makeArchive(
      path: "word/document.xml",
      expandedByteCount: 32 * 1_024 * 1_024 + 1)

    do {
      _ = try await TextDocumentTextExtractor.extract(
        archive,
        path: "attachment.docx",
        format: "docx",
        processRunner: StubTextDocumentProcessRunner())
      Issue.record("An archive over the expanded-byte limit must be rejected before conversion")
    } catch let error as AgentError {
      #expect(error.code == "file_too_large")
    } catch {
      Issue.record("Unexpected archive error: \(error)")
    }
  }

  @Test func rejectsCentralDirectoryCountThatDoesNotMatchParsedEntries() async throws {
    var archive = try makeArchive(
      path: "word/document.xml",
      payload: Data("<document>bounded</document>".utf8))
    let endRecord = archive.count - 22
    archive[endRecord + 8] = 2
    archive[endRecord + 10] = 2

    do {
      _ = try await TextDocumentTextExtractor.extract(
        archive,
        path: "attachment.docx",
        format: "docx",
        processRunner: StubTextDocumentProcessRunner())
      Issue.record("A truncated central directory must not reach text conversion")
    } catch let error as AgentError {
      #expect(error.code == "text_document_read_failed")
    } catch {
      Issue.record("Unexpected archive error: \(error)")
    }
  }

  private func makeArchive(
    path: String,
    payload: Data? = nil,
    expandedByteCount: Int? = nil
  ) throws -> Data {
    let byteCount = expandedByteCount ?? payload?.count ?? 0
    let archive = try Archive(accessMode: .create)
    try archive.addEntry(
      with: path,
      type: .file,
      uncompressedSize: Int64(byteCount),
      compressionMethod: .deflate,
      bufferSize: 32 * 1_024,
      provider: { position, requestedBytes in
        let start = Int(position)
        let count = min(requestedBytes, byteCount - start)
        if let payload {
          return Data(payload[start..<(start + count)])
        }
        return Data(repeating: 0, count: count)
      })
    guard let data = archive.data else { throw FixtureError.archiveUnavailable }
    return data
  }
}

private struct StubTextDocumentProcessRunner: ProcessRunning {
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    #expect(request.executable == "/usr/bin/textutil")
    return ProcessResult(
      exitCode: 0,
      terminationSignal: nil,
      stdout: Data("converted".utf8),
      stderr: Data(),
      timedOut: false,
      outputLimitExceeded: false)
  }
}

private enum FixtureError: Error {
  case archiveUnavailable
}
