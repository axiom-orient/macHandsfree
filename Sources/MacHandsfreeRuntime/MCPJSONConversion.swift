import MacHandsfreeCore
import MCP

enum MacHandsfreeMCPJSON {
  static func toMCP(_ value: JSONValue) throws -> MCPJSONValue {
    switch value {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .integer(let value): return .integer(value)
    case .number(let value): return try .double(value)
    case .string(let value): return .string(value)
    case .array(let values): return .array(try values.map(toMCP))
    case .object(let values): return .object(try values.mapValues(toMCP))
    }
  }

  static func toCommand(_ value: MCPJSONValue) throws -> JSONValue {
    switch value {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .number(let value):
      if let integer = value.int64Value { return .integer(integer) }
      guard let number = value.doubleValue else { throw MCPRPCError.invalidParams }
      return .number(number)
    case .string(let value): return .string(value)
    case .array(let values): return .array(try values.map(toCommand))
    case .object(let values): return .object(try values.mapValues(toCommand))
    }
  }
}
