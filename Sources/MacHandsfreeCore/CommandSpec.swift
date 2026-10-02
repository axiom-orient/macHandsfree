package enum CommandKind: String, Sendable {
  case read
  case mutation
}

package enum CommandRisk: String, Sendable {
  case low
  case medium
  case high
}

package struct CommandSpec: Sendable {
  package let id: String
  let path: [String]
  package let summary: String
  package let kind: CommandKind
  package let risk: CommandRisk
  package let service: String
  package let permissions: [String]
  package let inputSchema: JSONSchema

  init(
    id: String,
    path: [String],
    summary: String,
    kind: CommandKind,
    risk: CommandRisk,
    service: String,
    permissions: [String] = [],
    inputSchema: JSONSchema
  ) {
    self.id = id
    self.path = path
    self.summary = summary
    self.kind = kind
    self.risk = risk
    self.service = service
    self.permissions = permissions
    self.inputSchema = inputSchema
  }

  var cli: String { path.joined(separator: " ") }
  package var mcpName: String { id.replacingOccurrences(of: ".", with: "_") }

  package var json: JSONValue {
    .object([
      "id": .string(id),
      "cli": .string(cli),
      "summary": .string(summary),
      "kind": .string(kind.rawValue),
      "risk": .string(risk.rawValue),
      "service": .string(service),
      "permissions": .array(permissions.map(JSONValue.string)),
      "input_schema": inputSchema.json,
    ])
  }
}

package enum InvocationMode: Sendable, Equatable {
  case read
  case plan
  case execute
}

package struct ResolvedCommand: Sendable {
  package let spec: CommandSpec
  package let mode: InvocationMode
  package init(spec: CommandSpec, mode: InvocationMode) {
    self.spec = spec
    self.mode = mode
  }
}

/// The canonical invocation grammar shared by CLI resolution and MCP projection.
package struct CommandInvocation: Sendable {
  package let arguments: [String]
  package let mcpName: String
  package let resolved: ResolvedCommand
}
