package import Foundation

package struct ResponseEnvelope: Sendable {
  package let ok: Bool
  package let error: AgentError?
  package let json: JSONValue

  private init(
    ok: Bool, command: String?, data: JSONValue?, error: AgentError?, replayed: Bool = false,
    timestamp: Date = Date()
  ) {
    self.ok = ok
    self.error = error

    var meta: [String: JSONValue] = [
      "product": .string(ProductInfo.name),
      "version": .string(ProductInfo.version),
      "schema_version": .integer(Int64(ProductInfo.responseSchemaVersion)),
      "timestamp": .string(ISO8601DateFormatter.agentString(from: timestamp)),
      "replayed": .bool(replayed),
    ]
    #if os(macOS)
      meta["platform"] = .string("macos")
    #else
      meta["platform"] = .string("linux")
    #endif

    var object: [String: JSONValue] = ["ok": .bool(ok), "meta": .object(meta)]
    if let command { object["command"] = .string(command) }
    if let data { object["data"] = data }
    if let error {
      object["error"] = .object([
        "code": .string(error.code),
        "message": .string(error.message),
        "details": .object(error.details),
        "outcome_uncertain": .bool(error.outcomeUncertain),
      ])
    }
    self.json = .object(object)
  }

  static func success(command: String, data: JSONValue, replayed: Bool = false)
    -> ResponseEnvelope
  {
    ResponseEnvelope(ok: true, command: command, data: data, error: nil, replayed: replayed)
  }

  package static func failure(command: String?, error: AgentError) -> ResponseEnvelope {
    ResponseEnvelope(ok: false, command: command, data: nil, error: error)
  }
}

extension ISO8601DateFormatter {
  package static func agentString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
