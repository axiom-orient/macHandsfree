package import Foundation

package indirect enum JSONSchema: Sendable {
  case any(description: String? = nil)
  case null(description: String? = nil)
  case boolean(description: String? = nil)
  case integer(minimum: Int? = nil, maximum: Int? = nil, description: String? = nil)
  case number(minimum: Double? = nil, maximum: Double? = nil, description: String? = nil)
  case string(
    minLength: Int? = nil, maxLength: Int? = nil, values: [String]? = nil, format: String? = nil,
    description: String? = nil)
  case array(
    items: JSONSchema, minItems: Int? = nil, maxItems: Int? = nil, description: String? = nil)
  case anyOf([JSONSchema], description: String? = nil)
  case object(
    properties: [String: JSONSchema], required: Set<String> = [],
    additionalProperties: Bool = false, description: String? = nil)

  package func validate(_ value: JSONValue, path: String = "$") throws {
    switch self {
    case .any:
      return
    case .null:
      guard value == .null else { throw typeError("null", path: path) }
    case .boolean:
      guard case .bool = value else { throw typeError("boolean", path: path) }
    case .integer(let minimum, let maximum, _):
      guard let number = value.intValue else { throw typeError("integer", path: path) }
      if let minimum, number < minimum { throw rangeError(path, "must be >= \(minimum)") }
      if let maximum, number > maximum { throw rangeError(path, "must be <= \(maximum)") }
    case .number(let minimum, let maximum, _):
      let number: Double
      switch value {
      case .integer(let value): number = Double(value)
      case .number(let value): number = value
      default: throw typeError("number", path: path)
      }
      guard number.isFinite else { throw rangeError(path, "must be finite") }
      if let minimum, number < minimum { throw rangeError(path, "must be >= \(minimum)") }
      if let maximum, number > maximum { throw rangeError(path, "must be <= \(maximum)") }
    case .string(let minLength, let maxLength, let values, let format, _):
      guard case .string(let string) = value else { throw typeError("string", path: path) }
      if let minLength, string.count < minLength {
        throw rangeError(path, "length must be >= \(minLength)")
      }
      if let maxLength, string.count > maxLength {
        throw rangeError(path, "length must be <= \(maxLength)")
      }
      if let values, !values.contains(string) {
        throw AgentError.invalid(
          "Value is not in the allowed set",
          details: ["path": .string(path), "allowed": .array(values.map(JSONValue.string))])
      }
      if let format { try Self.validateFormat(format, string: string, path: path) }
    case .array(let items, let minItems, let maxItems, _):
      guard case .array(let array) = value else { throw typeError("array", path: path) }
      if let minItems, array.count < minItems {
        throw rangeError(path, "must have at least \(minItems) items")
      }
      if let maxItems, array.count > maxItems {
        throw rangeError(path, "must have at most \(maxItems) items")
      }
      for (index, item) in array.enumerated() {
        try items.validate(item, path: "\(path)[\(index)]")
      }
    case .anyOf(let schemas, _):
      for schema in schemas {
        do {
          try schema.validate(value, path: path)
          return
        } catch let error as AgentError where error.code == "invalid_input" {
          continue
        }
      }
      throw AgentError.invalid(
        "Value does not match any allowed schema",
        details: ["path": .string(path)]
      )
    case .object(let properties, let required, let additionalProperties, _):
      guard case .object(let object) = value else { throw typeError("object", path: path) }
      for key in required where object[key] == nil {
        throw AgentError.invalid(
          "Missing required property", details: ["path": .string("\(path).\(key)")])
      }
      if !additionalProperties {
        let unknown = Set(object.keys).subtracting(properties.keys).sorted()
        if !unknown.isEmpty {
          throw AgentError.invalid(
            "Unknown properties are not allowed",
            details: ["path": .string(path), "properties": .array(unknown.map(JSONValue.string))])
        }
      }
      for (key, item) in object {
        if let schema = properties[key] { try schema.validate(item, path: "\(path).\(key)") }
      }
    }
  }

  package var json: JSONValue {
    func withDescription(_ object: [String: JSONValue], _ description: String?) -> JSONValue {
      var result = object
      if let description { result["description"] = .string(description) }
      return .object(result)
    }
    switch self {
    case .any(let description): return withDescription([:], description)
    case .null(let description): return withDescription(["type": "null"], description)
    case .boolean(let description): return withDescription(["type": "boolean"], description)
    case .integer(let minimum, let maximum, let description):
      var result: [String: JSONValue] = ["type": "integer"]
      if let minimum { result["minimum"] = .integer(Int64(minimum)) }
      if let maximum { result["maximum"] = .integer(Int64(maximum)) }
      return withDescription(result, description)
    case .number(let minimum, let maximum, let description):
      var result: [String: JSONValue] = ["type": "number"]
      if let minimum { result["minimum"] = .number(minimum) }
      if let maximum { result["maximum"] = .number(maximum) }
      return withDescription(result, description)
    case .string(let minLength, let maxLength, let values, let format, let description):
      var result: [String: JSONValue] = ["type": "string"]
      if let minLength { result["minLength"] = .integer(Int64(minLength)) }
      if let maxLength { result["maxLength"] = .integer(Int64(maxLength)) }
      if let values { result["enum"] = .array(values.map(JSONValue.string)) }
      if let format { result["format"] = .string(format) }
      return withDescription(result, description)
    case .array(let items, let minItems, let maxItems, let description):
      var result: [String: JSONValue] = ["type": "array", "items": items.json]
      if let minItems { result["minItems"] = .integer(Int64(minItems)) }
      if let maxItems { result["maxItems"] = .integer(Int64(maxItems)) }
      return withDescription(result, description)
    case .anyOf(let schemas, let description):
      return withDescription(["anyOf": .array(schemas.map(\.json))], description)
    case .object(let properties, let required, let additionalProperties, let description):
      var result: [String: JSONValue] = [
        "type": "object",
        "properties": .object(properties.mapValues(\.json)),
        "additionalProperties": .bool(additionalProperties),
      ]
      if !required.isEmpty { result["required"] = .array(required.sorted().map(JSONValue.string)) }
      return withDescription(result, description)
    }
  }

  private func typeError(_ expected: String, path: String) -> AgentError {
    AgentError.invalid(
      "Type mismatch", details: ["path": .string(path), "expected": .string(expected)])
  }

  private func rangeError(_ path: String, _ constraint: String) -> AgentError {
    AgentError.invalid(
      "Value is outside the allowed range",
      details: ["path": .string(path), "constraint": .string(constraint)])
  }

  private static func validateFormat(_ format: String, string: String, path: String) throws {
    let valid: Bool
    switch format {
    case "date-time": valid = parseRFC3339(string) != nil
    case "date": valid = parseDateOnly(string) != nil
    case "absolute-path": valid = string.hasPrefix("/") || string.hasPrefix("~/")
    case "email":
      valid = string.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    case "uri": valid = URL(string: string)?.scheme != nil
    case "identifier": valid = !string.isEmpty && string.count <= 2048 && !string.contains("\0")
    case "hex-color":
      valid = string.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil
    default:
      throw AgentError(
        code: "unsupported_schema_format",
        message: "Schema uses an unsupported string format",
        details: ["format": .string(format)],
        exitCode: 5
      )
    }
    if !valid {
      throw AgentError.invalid(
        "String has an invalid format", details: ["path": .string(path), "format": .string(format)])
    }
  }

  package static func parseRFC3339(_ value: String) -> Date? {
    let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#
    guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
  }

  package static func parseDateOnly(_ value: String) -> Date? {
    let pattern = #"^\d{4}-\d{2}-\d{2}$"#
    guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
      return nil
    }
    return date
  }
}
