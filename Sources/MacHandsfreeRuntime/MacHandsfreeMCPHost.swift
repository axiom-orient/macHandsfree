package import Foundation
import MacHandsfreeCore
import MCP
import MCPStdioServer

private typealias MCPToolInvocation =
  @Sendable (ResolvedCommand, JSONValue) async -> ResponseEnvelope

package struct MacHandsfreeMCPHost: Sendable {
  private let registry: CommandRegistry
  private let invokeTool: MCPToolInvocation

  package init(runtime: AgentRuntime) {
    registry = runtime.registry
    invokeTool = { resolved, input in
      await runtime.pipeline.invoke(resolved, input: input)
    }
  }

  package func serve(
    input: FileHandle = .standardInput,
    output: FileHandle = .standardOutput
  ) async throws {
    let catalog = try MCPToolCatalog(registry: registry)
    let inFlightToolCalls = DispatchGroup()
    let implementation = try MCPImplementation(
      name: ProductInfo.name,
      version: ProductInfo.version
    )
    var builder = try MCPServerBuilder(
      implementation: implementation,
      instructions:
        "Read results from structuredContent. Mutations require a plan, user review and approval of its exact preview, then the matching execute tool with a stable idempotency key. Oversized files.read results return mcp_result_too_large."
    )
    builder.setToolResolver { [catalog] name, _ in catalog.tool(named: name) }
    try builder.register(MCPStandardMethods.listTools) { [catalog] _, _ in
      MCPListToolsResult(tools: catalog.tools)
    }
    try builder.register(MCPStandardMethods.callTool) {
      [catalog, invokeTool, inFlightToolCalls] params, context in
      guard let resolved = catalog.resolve(params.name) else {
        throw MCPRPCError.invalidParams
      }
      inFlightToolCalls.enter()
      defer { inFlightToolCalls.leave() }
      let input = try MacHandsfreeMCPJSON.toCommand(.object(params.arguments))
      let response = await invokeTool(resolved, input)
      var result = try Self.toolResult(response)
      if response.ok, resolved.spec.id == "files.read", Self.shouldCheckResponse(result),
        try Self.responseExceedsMCPOutputLimit(result, requestID: context.id)
      {
        let error = AgentError(
          code: "mcp_result_too_large",
          message:
            "File content was read, but its complete response exceeds the MCP output limit and was not forwarded. Use the standalone CLI for the full raw read.",
          details: [
            "maximum_document_bytes": .integer(
              Int64(MCPJSONLimits.default.maximumDocumentBytes))
          ]
        )
        result = try Self.toolResult(.failure(command: resolved.spec.id, error: error))
      }
      return result
    }

    let server = try builder.build()
    var jsonLimits = MCPJSONLimits.default
    jsonLimits.maximumDocumentBytes = ProductInfo.maximumRequestBytes
    let stdioLimits = try MCPStdioLimits(
      maximumFrameBytes: ProductInfo.maximumRequestBytes,
      jsonLimits: jsonLimits
    )
    let configuration = MCPStdioServerConfiguration(
      input: input,
      output: output,
      limits: stdioLimits
    )
    do {
      try await MCPStdioServerRunner(server: server, configuration: configuration).run()
    } catch {
      await Self.drain(inFlightToolCalls)
      throw error
    }
    await Self.drain(inFlightToolCalls)
  }

  /// Keep the process alive until cancelled command handlers finish their pipeline and ledger work.
  private static func drain(_ group: DispatchGroup) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      group.notify(queue: .global()) { continuation.resume() }
    }
  }

  private static func toolResult(_ response: ResponseEnvelope) throws -> MCPCallToolResult {
    let structuredContent = try MacHandsfreeMCPJSON.toMCP(response.json)
    return try MCPCallToolResult(
      content: [],
      structuredContent: structuredContent,
      isError: !response.ok
    )
  }

  private static func shouldCheckResponse(_ result: MCPCallToolResult) -> Bool {
    guard case .object(let envelope)? = result.structuredContent,
      case .object(let data)? = envelope["data"],
      case .string(let content)? = data["content"]
    else { return false }
    // JSON escaping can expand control characters to six bytes each.
    return content.utf8.count > MCPJSONLimits.default.maximumDocumentBytes / 8
  }

  private static func responseExceedsMCPOutputLimit(
    _ result: MCPCallToolResult, requestID: MCPRequestID
  ) throws -> Bool {
    guard case .object(let value) = result.json else { throw MCPJSONError.expectedObject }
    // Preflight the same wire message the stdio writer will encode.
    let message = MCPWireMessage.result(
      MCPWireResult(id: requestID, resultType: result.resultType, value: value))
    do {
      _ = try message.encoded()
      return false
    } catch let error as MCPJSONError {
      switch error {
      case .documentTooLarge(_), .stringTooLarge(_): return true
      default: throw error
      }
    }
  }
}
