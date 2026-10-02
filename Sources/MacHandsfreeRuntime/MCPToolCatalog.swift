import MacHandsfreeCore
import MCP

/// Projects the canonical command registry into the upstream MCP tool model.
struct MCPToolCatalog: Sendable {
  let tools: [MCPTool]
  private struct Entry: Sendable {
    let command: ResolvedCommand
    let tool: MCPTool
  }
  private let entriesByName: [String: Entry]

  init(registry: CommandRegistry) throws {
    var tools: [MCPTool] = []
    var entries: [String: Entry] = [:]

    for invocation in registry.invocations {
      let spec = invocation.resolved.spec
      let tool: MCPTool
      switch invocation.resolved.mode {
      case .read:
        tool = try Self.tool(
          name: invocation.mcpName, title: spec.summary, description: spec.summary,
          schema: spec.inputSchema.json, readOnly: true, destructive: false, idempotent: true)
      case .plan:
        let title = "Plan: " + spec.summary
        tool = try Self.tool(
          name: invocation.mcpName, title: title, description: title,
          schema: spec.inputSchema.json, readOnly: false, destructive: false, idempotent: false)
      case .execute:
        tool = try Self.tool(
          name: invocation.mcpName, title: "Execute: " + spec.summary,
          description: "Execute a previously signed plan for: " + spec.summary,
          schema: SchemaLibrary.executeSchema.json, readOnly: false,
          destructive: spec.risk == .high, idempotent: true)
      }
      tools.append(tool)
      entries[tool.name] = Entry(command: invocation.resolved, tool: tool)
    }

    self.tools = tools
    entriesByName = entries
  }

  func resolve(_ name: String) -> ResolvedCommand? { entriesByName[name]?.command }

  func tool(named name: String) -> MCPTool? { entriesByName[name]?.tool }

  private static func tool(
    name: String,
    title: String,
    description: String,
    schema: JSONValue,
    readOnly: Bool,
    destructive: Bool,
    idempotent: Bool
  ) throws -> MCPTool {
    guard case .object(let inputSchema) = try MacHandsfreeMCPJSON.toMCP(schema) else {
      throw MCPJSONError.expectedObject
    }
    return try MCPTool(
      name: name,
      title: title,
      description: description,
      inputSchema: inputSchema,
      annotations: [
        "readOnlyHint": .bool(readOnly),
        "destructiveHint": .bool(destructive),
        "idempotentHint": .bool(idempotent),
        "openWorldHint": .bool(false),
      ]
    )
  }
}
