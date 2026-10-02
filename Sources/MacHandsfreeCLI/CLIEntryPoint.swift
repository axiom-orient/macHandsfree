import Foundation
import MacHandsfreeCore
import MacHandsfreeRuntime

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@main
enum Main {
  static func main() async {
    CLIOutputWriter.prepareProcess()
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      #if os(macOS)
        if arguments.isEmpty {
          RuntimeOnboarding.show()
          return
        }
      #endif
      if arguments == ["mcp", "serve"] {
        do {
          let runtime = try RuntimeFactory.make()
          try await MacHandsfreeMCPHost(runtime: runtime).serve()
        } catch let error as AgentError {
          terminateMCP(with: error)
        } catch {
          terminateMCP(
            with: AgentError(
              code: "startup_failed",
              message: "mac-handsfree MCP server could not start",
              details: ["reason": .string(String(describing: error))],
              exitCode: 5
            )
          )
        }
        return
      }
      let runtime = try RuntimeFactory.make()
      let input = try BoundedInputReader.readAll(
        from: .standardInput,
        maximumBytes: ProductInfo.maximumRequestBytes,
        errorMessage: "Input exceeds 8 MiB"
      )
      let result = await CLIApplication(runtime: runtime).run(arguments: arguments, input: input)
      do {
        try CLIOutputWriter.write(result.output, to: STDOUT_FILENO)
      } catch {
        CLIOutputWriter.writeDiagnostic(
          "mac-handsfree could not write its response: \(String(describing: error))\n")
        exit(5)
      }
      exit(result.exitCode)
    } catch let error as AgentError {
      terminate(with: error)
    } catch {
      terminate(
        with: AgentError(
          code: "startup_failed",
          message: "mac-handsfree could not start",
          details: ["reason": .string(String(describing: error))],
          exitCode: 5
        )
      )
    }
  }

  private static func terminateMCP(with error: AgentError) -> Never {
    let diagnostic: JSONValue = .object([
      "error": .object([
        "code": .string(error.code),
        "message": .string(error.message),
        "details": .object(error.details),
        "outcome_uncertain": .bool(error.outcomeUncertain),
      ]),
      "product": .string(ProductInfo.name),
      "transport": .string("stdio"),
    ])
    if let output = try? diagnostic.encoded() + Data([0x0A]) {
      try? CLIOutputWriter.write(output, to: STDERR_FILENO)
    }
    exit(error.exitCode)
  }

  private static func terminate(with error: AgentError) -> Never {
    let output: Data
    do {
      output =
        try ResponseEnvelope.failure(command: nil, error: error).json.encoded() + Data([0x0A])
    } catch {
      CLIOutputWriter.writeDiagnostic(
        "mac-handsfree could not encode its structured failure: \(String(describing: error))\n")
      exit(5)
    }

    do {
      try CLIOutputWriter.write(output, to: STDOUT_FILENO)
    } catch {
      CLIOutputWriter.writeDiagnostic(
        "mac-handsfree could not write its structured failure: \(String(describing: error))\n")
      exit(errorCodeForOutputFailure(original: error))
    }
    exit(error.exitCode)
  }

  private static func errorCodeForOutputFailure(original: any Error) -> Int32 {
    if let agentError = original as? AgentError { return agentError.exitCode }
    return 5
  }
}

private enum CLIOutputWriter {
  static func prepareProcess() {
    _ = signal(SIGPIPE, SIG_IGN)
  }

  static func write(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written: Int
        #if canImport(Darwin)
          written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
        #else
          written = Glibc.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
        #endif
        if written > 0 {
          offset += written
          continue
        }
        if written < 0, errno == EINTR { continue }

        let currentErrno = written < 0 ? errno : EIO
        throw AgentError(
          code: currentErrno == EPIPE ? "output_closed" : "output_write_failed",
          message:
            currentErrno == EPIPE
            ? "The output consumer closed the stream"
            : "Could not write the command response",
          details: ["errno": .integer(Int64(currentErrno))],
          exitCode: 5
        )
      }
    }
  }

  static func writeDiagnostic(_ message: String) {
    try? write(Data(message.utf8), to: STDERR_FILENO)
  }
}
