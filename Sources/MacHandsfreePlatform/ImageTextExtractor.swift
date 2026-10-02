#if os(macOS)
  import CoreGraphics
  import Foundation
  import ImageIO
  import MacHandsfreeCore
  import UniformTypeIdentifiers

struct ImageTextExtraction {
  let text: String
  let contentType: String
  let width: Int64
  let height: Int64
  let frameCount: Int
  let textTruncated: Bool

  var json: JSONValue {
    .object([
      "extraction": .string("vision_ocr"),
      "ocr_performed": .bool(true),
      "ocr_incomplete": .bool(frameCount > 1),
      "ocr_max_dimension": .integer(Int64(ImageTextExtractor.maximumOCRDimension)),
      "source_width": .integer(width),
      "source_height": .integer(height),
      "frame_count": .integer(Int64(frameCount)),
      "frames_processed": .integer(1),
      "frames_not_processed": .integer(Int64(frameCount - 1)),
      "text_recognized": .bool(!text.isEmpty),
      "text_truncated": .bool(textTruncated),
    ])
  }
}

enum ImageTextExtractor {
  static let headerProbeBytes = 4 * 1_024
  static let maximumInputBytes = 16 * 1_024 * 1_024
  static let maximumOCRDimension = 2_048

  private static let maximumPixelCount: Int64 = 24 * 1_024 * 1_024
  private static let maximumTextBytes = 64 * 1_024

  static func recognizes(_ prefix: Data, pathExtension: String) -> Bool {
    if let source = CGImageSourceCreateWithData(
      prefix as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    {
      return imageType(of: source) != nil
    }
    guard let type = UTType(filenameExtension: pathExtension) else { return false }
    return type.conforms(to: .image)
  }

  static func extract(_ data: Data, path: String) throws -> ImageTextExtraction {
    guard data.count <= maximumInputBytes else {
      throw AgentError(
        code: "file_too_large",
        message: "Image exceeds the bounded text extraction input limit",
        details: [
          "path": .string(path), "max_bytes": .integer(Int64(maximumInputBytes)),
        ],
        exitCode: 5
      )
    }
    guard let source = CGImageSourceCreateWithData(
      data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else {
      throw invalidImage(path)
    }
    guard let imageType = imageType(of: source) else { throw invalidImage(path) }

    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 0 else { throw invalidImage(path) }
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [String: Any],
      let widthValue = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
      let heightValue = properties[kCGImagePropertyPixelHeight as String] as? NSNumber
    else {
      throw invalidImage(path)
    }
    let width = widthValue.int64Value
    let height = heightValue.int64Value
    guard width > 0, height > 0, width <= maximumPixelCount / height else {
      throw AgentError(
        code: "image_too_large",
        message: "Image exceeds the bounded pixel count for local OCR",
        details: [
          "path": .string(path), "max_pixels": .integer(maximumPixelCount),
        ],
        exitCode: 5
      )
    }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumOCRDimension,
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
      source, 0, options as CFDictionary)
    else {
      throw invalidImage(path)
    }

    let recognizedText = try VisionTextRecognizer.recognize(thumbnail, path: path)
    let boundedText = VisionTextRecognizer.prefix(
      recognizedText, maximumBytes: maximumTextBytes)
    let contentType = imageType.preferredMIMEType ?? "application/octet-stream"
    return ImageTextExtraction(
      text: boundedText.text,
      contentType: contentType,
      width: width,
      height: height,
      frameCount: frameCount,
      textTruncated: boundedText.truncated
    )
  }

  private static func invalidImage(_ path: String) -> AgentError {
    AgentError(
      code: "invalid_image",
      message: "File is not a readable, supported image",
      details: ["path": .string(path)],
      exitCode: 5
    )
  }

  private static func imageType(of source: CGImageSource) -> UTType? {
    guard let typeIdentifier = CGImageSourceGetType(source) as String?,
      let type = UTType(typeIdentifier), type.conforms(to: .image)
    else {
      return nil
    }
    return type
  }
}
#endif
