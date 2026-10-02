#if os(macOS)
  import CoreGraphics
  import Foundation
  import MacHandsfreeCore
  import PDFKit
  import Vision

struct PDFTextExtraction {
  let text: String
  let pageCount: Int
  let pagesRead: Int
  let pagesWithoutEmbeddedText: [Int]
  let pagesWithoutRecognizedText: [Int]
  let ocrPagesAttempted: [Int]
  let ocrPagesFailed: [Int]
  let ocrPagesNotProcessed: [Int]
  let ocrPerformed: Bool
  let pagesTruncated: Bool
  let textTruncated: Bool
  let ocrIncomplete: Bool

  var json: JSONValue {
    .object([
      "extraction": .string(
        ocrPagesAttempted.isEmpty ? "embedded_text" : "embedded_text_with_vision_ocr"),
      "ocr_performed": .bool(ocrPerformed),
      "ocr_incomplete": .bool(ocrIncomplete),
      "ocr_page_limit": .integer(Int64(PDFTextExtractor.maximumOCRPages)),
      "ocr_max_dimension": .integer(Int64(PDFTextExtractor.maximumOCRDimension)),
      "ocr_pages_attempted": .array(ocrPagesAttempted.map { .integer(Int64($0)) }),
      "ocr_pages_failed": .array(ocrPagesFailed.map { .integer(Int64($0)) }),
      "ocr_pages_not_processed": .array(
        ocrPagesNotProcessed.map { .integer(Int64($0)) }),
      "page_count": .integer(Int64(pageCount)),
      "pages_read": .integer(Int64(pagesRead)),
      "pages_without_embedded_text": .array(
        pagesWithoutEmbeddedText.map { .integer(Int64($0)) }),
      "pages_without_recognized_text": .array(
        pagesWithoutRecognizedText.map { .integer(Int64($0)) }),
      "pages_truncated": .bool(pagesTruncated),
      "text_truncated": .bool(textTruncated),
    ])
  }
}

enum PDFTextExtractor {
  static let headerProbeBytes = 1_028
  static let maximumInputBytes = 8 * 1_024 * 1_024

  private static let maximumPages = 100
  static let maximumOCRPages = 20
  static let maximumOCRDimension = 2_048
  private static let maximumTextBytes = 64 * 1_024
  private static let header = Data("%PDF-".utf8)

  static func recognizes(_ prefix: Data) -> Bool {
    Data(prefix.prefix(headerProbeBytes)).range(of: header) != nil
  }

  static func extract(_ data: Data, path: String) throws -> PDFTextExtraction {
    guard data.count <= maximumInputBytes else {
      throw AgentError(
        code: "file_too_large",
        message: "PDF exceeds the bounded text extraction input limit",
        details: [
          "path": .string(path), "max_bytes": .integer(Int64(maximumInputBytes)),
        ],
        exitCode: 5
      )
    }
    guard let document = PDFDocument(data: data) else {
      throw AgentError(
        code: "invalid_pdf",
        message: "File is not a readable PDF document",
        details: ["path": .string(path)],
        exitCode: 5
      )
    }
    guard !document.isLocked else {
      throw AgentError(
        code: "pdf_password_required",
        message: "PDF is locked; password-protected content was not opened",
        details: ["path": .string(path)],
        exitCode: 5
      )
    }

    let pageCount = document.pageCount
    let pageLimit = min(pageCount, maximumPages)
    var text = ""
    var pagesWithoutEmbeddedText: [Int] = []
    var pagesWithoutRecognizedText: [Int] = []
    var ocrPagesAttempted: [Int] = []
    var ocrPagesFailed: [Int] = []
    var ocrPagesNotProcessed: [Int] = []
    var pagesRead = 0
    var textTruncated = false
    var ocrPerformed = false

    for index in 0..<pageLimit {
      try VisionTextRecognizer.requireNotCancelled(path: path)
      guard let page = document.page(at: index) else {
        throw AgentError(
          code: "invalid_pdf_page",
          message: "PDF page could not be read",
          details: ["path": .string(path), "page": .integer(Int64(index + 1))],
          exitCode: 5
        )
      }

      let pageNumber = index + 1
      let embeddedText = page.string ?? ""
      let pageText: String
      if embeddedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        pagesWithoutEmbeddedText.append(pageNumber)
        guard ocrPagesAttempted.count < maximumOCRPages else {
          ocrPagesNotProcessed.append(pageNumber)
          pagesRead += 1
          continue
        }

        ocrPagesAttempted.append(pageNumber)
        do {
          pageText = try recognizeText(on: page, path: path)
          ocrPerformed = true
        } catch let error as AgentError where error.code == "operation_cancelled" {
          throw error
        } catch {
          ocrPagesFailed.append(pageNumber)
          pagesRead += 1
          continue
        }
        if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          pagesWithoutRecognizedText.append(pageNumber)
          pagesRead += 1
          continue
        }
      } else {
        pageText = embeddedText
      }

      let separator = text.isEmpty ? "" : "\n\n"
      let remainingBytes = maximumTextBytes - text.utf8.count
      guard separator.utf8.count <= remainingBytes else {
        textTruncated = true
        break
      }
      text.append(separator)
      let boundedPage = VisionTextRecognizer.prefix(
        pageText, maximumBytes: maximumTextBytes - text.utf8.count)
      text.append(boundedPage.text)
      pagesRead += 1
      if boundedPage.truncated {
        textTruncated = true
        break
      }
    }

    let pagesTruncated = pageCount > pagesRead
    return PDFTextExtraction(
      text: text,
      pageCount: pageCount,
      pagesRead: pagesRead,
      pagesWithoutEmbeddedText: pagesWithoutEmbeddedText,
      pagesWithoutRecognizedText: pagesWithoutRecognizedText,
      ocrPagesAttempted: ocrPagesAttempted,
      ocrPagesFailed: ocrPagesFailed,
      ocrPagesNotProcessed: ocrPagesNotProcessed,
      ocrPerformed: ocrPerformed,
      pagesTruncated: pagesTruncated,
      textTruncated: textTruncated || pagesTruncated
        || !ocrPagesFailed.isEmpty || !ocrPagesNotProcessed.isEmpty,
      ocrIncomplete: !ocrPagesFailed.isEmpty || !ocrPagesNotProcessed.isEmpty
    )
  }

  private static func recognizeText(on page: PDFPage, path: String) throws -> String {
    try VisionTextRecognizer.requireNotCancelled(path: path)
    guard let pdfPage = page.pageRef else {
      throw AgentError(
        code: "pdf_ocr_render_failed",
        message: "PDF page has no renderable Core Graphics page",
        details: ["path": .string(path)],
        exitCode: 5
      )
    }

    let bounds = pdfPage.getBoxRect(.cropBox)
    let longestSide = max(bounds.width, bounds.height)
    guard
      bounds.width.isFinite,
      bounds.height.isFinite,
      bounds.width > 0,
      bounds.height > 0,
      longestSide > 0
    else {
      throw AgentError(
        code: "pdf_ocr_render_failed",
        message: "PDF page has invalid dimensions for OCR",
        details: ["path": .string(path)],
        exitCode: 5
      )
    }

    let scale = min(1, CGFloat(maximumOCRDimension) / longestSide)
    let width = max(1, Int((bounds.width * scale).rounded(.up)))
    let height = max(1, Int((bounds.height * scale).rounded(.up)))
    let destination = CGRect(
      x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw AgentError(
        code: "pdf_ocr_render_failed",
        message: "Could not allocate a bounded PDF page image for OCR",
        details: ["path": .string(path)],
        exitCode: 5
      )
    }

    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(destination)
    context.interpolationQuality = .high
    let transform = pdfPage.getDrawingTransform(
      .cropBox,
      rect: destination,
      rotate: 0,
      preserveAspectRatio: true
    )
    context.concatenate(transform)
    context.drawPDFPage(pdfPage)
    guard let image = context.makeImage() else {
      throw AgentError(
        code: "pdf_ocr_render_failed",
        message: "Could not render a bounded PDF page image for OCR",
        details: ["path": .string(path)],
        exitCode: 5
      )
    }

    return try VisionTextRecognizer.recognize(image, path: path)
  }
}

enum VisionTextRecognizer {
  static func recognize(_ image: CGImage, path: String) throws -> String {
    try requireNotCancelled(path: path)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    request.usesLanguageCorrection = false
    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
      try requireNotCancelled(path: path)
      throw AgentError(
        code: "vision_ocr_failed",
        message: "Vision text recognition failed",
        details: ["path": .string(path)],
        exitCode: 5
      )
    }
    try requireNotCancelled(path: path)
    return (request.results ?? [])
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }

  static func prefix(_ value: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
    var result = ""
    var usedBytes = 0
    for character in value {
      let characterBytes = String(character).utf8.count
      guard characterBytes <= maximumBytes - usedBytes else {
        return (result, true)
      }
      result.append(character)
      usedBytes += characterBytes
    }
    return (result, false)
  }

  static func requireNotCancelled(path: String) throws {
    guard !Task.isCancelled else {
      throw AgentError(
        code: "operation_cancelled",
        message: "Text recognition was cancelled",
        details: ["path": .string(path)],
        exitCode: 6
      )
    }
  }
}
#endif
