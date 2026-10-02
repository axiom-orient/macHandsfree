package import Foundation
import MacHandsfreeCore

package struct CLIResult: Sendable {
  package let output: Data
  package let exitCode: Int32
}

package struct CLIApplication: Sendable {
  private let runtime: AgentRuntime
  package init(runtime: AgentRuntime) { self.runtime = runtime }

  package func run(arguments: [String], input: Data) async -> CLIResult {
    let response: ResponseEnvelope
    var invocation: ResolvedCommand? = nil
    do {
      guard input.count <= ProductInfo.maximumRequestBytes else {
        throw AgentError(code: "input_too_large", message: "Input exceeds 8 MiB", exitCode: 2)
      }
      let value =
        input.trimmingASCIIWhitespace().isEmpty ? JSONValue.object([:]) : try JSONValue.parse(input)
      let resolved = try runtime.registry.resolve(arguments: arguments)
      invocation = resolved
      response = await runtime.pipeline.invoke(resolved, input: value)
    } catch let error as AgentError { response = .failure(command: nil, error: error) } catch {
      response = .failure(
        command: nil,
        error: AgentError(
          code: "internal_error", message: "Unexpected internal error",
          details: ["reason": .string(String(describing: error))], exitCode: 5))
    }
    return CLIResponseEncoder.encode(response, invocation: invocation)
  }
}

extension Data {
  func trimmingASCIIWhitespace() -> Data {
    let whitespace: Set<UInt8> = [9, 10, 13, 32]
    var start = startIndex
    var end = endIndex
    while start < end, whitespace.contains(self[start]) { formIndex(after: &start) }
    while start < end {
      let previous = index(before: end)
      if whitespace.contains(self[previous]) { end = previous } else { break }
    }
    return self[start..<end]
  }
}
