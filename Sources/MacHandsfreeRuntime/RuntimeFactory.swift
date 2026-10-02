import Foundation
import MCP
import MacHandsfreeCore
import MacHandsfreePlatform
import MacHandsfreeState

package struct AgentRuntime: Sendable {
  let registry: CommandRegistry
  let pipeline: ExecutionPipeline
}

package enum RuntimeFactory {
  package static func make(environment: [String: String]? = nil) throws -> AgentRuntime {
    let environment = environment ?? ProcessInfo.processInfo.environment
    let registry = try CommandRegistry()
    let stateDirectory = try StateDirectory(environment: environment)
    let executor = try PlatformAdapterFactory.makeExecutor(
      registry: registry,
      stateDirectoryURL: stateDirectory.url,
      mcpProtocols: [MCPProtocolVersion.current.rawValue],
      environment: environment
    )
    let state = LazyExecutionStateStore(directory: stateDirectory)
    let pipeline = ExecutionPipeline(executor: executor, state: state)
    return AgentRuntime(registry: registry, pipeline: pipeline)
  }
}
