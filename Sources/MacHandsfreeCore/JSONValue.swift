package import Foundation

package enum JSONValue: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  package init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  package var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  package var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  package var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  package var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  package var intValue: Int? {
    switch self {
    case .integer(let value): return Int(exactly: value)
    case .number(let value) where value.rounded() == value: return Int(exactly: value)
    default: return nil
    }
  }

  package subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  package static func parse(_ data: Data) throws -> JSONValue {
    do {
      return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw AgentError(
        code: "invalid_json", message: "Input is not valid JSON",
        details: ["reason": .string(String(describing: error))], exitCode: 2)
    }
  }

  package func encoded(pretty: Bool = false) throws -> Data {
    let encoder = JSONEncoder()
    if pretty {
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    } else {
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }
    let encoded = try encoder.encode(self)
    guard let text = String(data: encoded, encoding: .utf8) else {
      throw AgentError(
        code: "json_encoding_failed", message: "Could not encode JSON as UTF-8", exitCode: 5)
    }
    return Data(
      text
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        .utf8
    )
  }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  package init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
  package init(integerLiteral value: Int64) { self = .integer(value) }
}
extension JSONValue: ExpressibleByStringLiteral {
  package init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByArrayLiteral {
  package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
  package init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
}
