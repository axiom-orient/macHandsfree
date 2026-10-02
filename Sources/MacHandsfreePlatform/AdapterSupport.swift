import Foundation
import MacHandsfreeCore

extension JSONValue {
  func requiredObject() throws -> [String: JSONValue] {
    guard let objectValue else { throw AgentError.invalid("Input must be a JSON object") }
    return objectValue
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  func requiredString(_ key: String) throws -> String {
    guard let value = self[key]?.stringValue else {
      throw AgentError.invalid("Missing required string", details: ["property": .string(key)])
    }
    return value
  }

  func optionalString(_ key: String) -> String? { self[key]?.stringValue }
  func optionalBool(_ key: String, default defaultValue: Bool = false) -> Bool {
    self[key]?.boolValue ?? defaultValue
  }
  func optionalInt(_ key: String, default defaultValue: Int? = nil) -> Int? {
    self[key]?.intValue ?? defaultValue
  }
  func stringArray(_ key: String) -> [String] {
    self[key]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  func optionalSelectionIDs(_ key: String) throws -> [String]? {
    guard let value = self[key] else { return nil }
    guard let values = value.arrayValue else {
      throw AgentError.invalid(
        "Selection must be an array of identifiers", details: ["property": .string(key)])
    }
    guard !values.isEmpty else {
      throw AgentError.invalid(
        "An ID selection must be non-empty; use the full-scope flag to include all items",
        details: ["property": .string(key)])
    }
    let identifiers = values.compactMap(\.stringValue)
    guard identifiers.count == values.count else {
      throw AgentError.invalid(
        "Selection must contain only identifiers", details: ["property": .string(key)])
    }
    return identifiers
  }

  func selectedReadScopeIDs(_ key: String, includeAllKey: String) throws -> [String]? {
    let includeAll: Bool
    if let value = self[includeAllKey] {
      guard let boolean = value.boolValue else {
        throw AgentError.invalid(
          "Full-scope selector must be a boolean",
          details: ["property": .string(includeAllKey)])
      }
      includeAll = boolean
    } else {
      includeAll = false
    }

    if includeAll {
      guard self[key] == nil else {
        throw AgentError.invalid(
          "Full-scope selector cannot be combined with exact identifiers",
          details: ["property": .string(includeAllKey)])
      }
      return nil
    }
    guard let identifiers = try optionalSelectionIDs(key) else {
      throw AgentError.invalid(
        "Provide exact identifiers or explicitly request the full read scope",
        details: [
          "property": .string(key), "full_scope_property": .string(includeAllKey),
        ])
    }
    return identifiers
  }
}

func effect(_ action: String, _ target: String, details: [String: JSONValue] = [:]) -> JSONValue {
  .object(["action": .string(action), "target": .string(target), "details": .object(details)])
}

func effects(_ values: [JSONValue]) -> JSONValue {
  .object(["effects": .array(values)])
}

func nullableURLUpdate(_ value: JSONValue?, property: String) throws -> URL?? {
  guard let value else { return nil }
  switch value {
  case .null: return .some(nil)
  case .string(let string):
    guard let url = URL(string: string), url.scheme != nil else {
      throw AgentError.invalid(
        "Property must be an absolute URL", details: ["property": .string(property)])
    }
    return .some(url)
  default:
    throw AgentError.invalid(
      "Property must be a URL string or null", details: ["property": .string(property)])
  }
}
