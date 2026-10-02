import Foundation
import MacHandsfreeCore
import Subprocess

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct ProcessRequest: Sendable {
  let executable: String
  let arguments: [String]
  let workingDirectory: String?
  let environment: [String: String]
  let input: Data?
  let timeout: TimeInterval
  let maximumOutputBytes: Int
  let validateBeforeLaunch: (@Sendable () throws -> Void)?

  init(
    executable: String,
    arguments: [String] = [],
    workingDirectory: String? = nil,
    environment: [String: String] = [:],
    input: Data? = nil,
    timeout: TimeInterval = 30,
    maximumOutputBytes: Int = 4 * 1_024 * 1_024,
    validateBeforeLaunch: (@Sendable () throws -> Void)? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.input = input
    self.timeout = timeout
    self.maximumOutputBytes = maximumOutputBytes
    self.validateBeforeLaunch = validateBeforeLaunch
  }
}

struct ProcessResult: Sendable, Equatable {
  let exitCode: Int32
  let terminationSignal: Int32?
  let stdout: Data
  let stderr: Data
  let timedOut: Bool
  let outputLimitExceeded: Bool

  var stdoutString: String? { String(data: stdout, encoding: .utf8) }
  var stderrString: String? { String(data: stderr, encoding: .utf8) }
}

protocol ProcessRunning: Sendable {
  func run(_ request: ProcessRequest) async throws -> ProcessResult
}

private enum ProcessOutputStream: Sendable {
  case stdout
  case stderr
}

private struct ProcessOutputSnapshot: Sendable {
  let stdout: Data
  let stderr: Data
  let timedOut: Bool
  let outputLimitExceeded: Bool
  let didLaunch: Bool
}

private actor ProcessOutputCollector {
  private let maximumBytes: Int
  private var stdout = Data()
  private var stderr = Data()
  private var timedOut = false
  private var outputLimitExceeded = false
  private var outputLimitTerminationRequested = false
  private var didLaunch = false

  init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

  func markLaunched() { didLaunch = true }

  func markTimedOut() { timedOut = true }

  func hasExceededLimit() -> Bool { outputLimitExceeded }

  func snapshot() -> ProcessOutputSnapshot {
    ProcessOutputSnapshot(
      stdout: stdout,
      stderr: stderr,
      timedOut: timedOut,
      outputLimitExceeded: outputLimitExceeded,
      didLaunch: didLaunch
    )
  }

  func append(_ bytes: Data, to stream: ProcessOutputStream) -> Bool {
    let usedBytes = stdout.count + stderr.count
    let remainingBytes = max(0, maximumBytes - usedBytes)
    if remainingBytes > 0 {
      switch stream {
      case .stdout: stdout.append(contentsOf: bytes.prefix(remainingBytes))
      case .stderr: stderr.append(contentsOf: bytes.prefix(remainingBytes))
      }
    }
    guard bytes.count > remainingBytes else { return false }
    outputLimitExceeded = true
    guard !outputLimitTerminationRequested else { return false }
    outputLimitTerminationRequested = true
    return true
  }
}

private actor ProcessTerminationCoordinator {
  private var terminationStarted = false

  func hasStarted() -> Bool { terminationStarted }

  func terminate(using operation: @Sendable () async -> Void) async {
    guard !terminationStarted else { return }
    terminationStarted = true
    await operation()
  }
}

struct SubprocessProcessRunner: ProcessRunning {
  private static let shutdownGracePeriod: Duration = .milliseconds(100)
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    try Self.validate(request)
    try Self.requireNotCancelled(outcomeUncertain: false)

    let output = ProcessOutputCollector(maximumBytes: request.maximumOutputBytes)
    var platformOptions = PlatformOptions()
    platformOptions.processGroupID = 0
    platformOptions.teardownSequence = [
      .gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: Self.shutdownGracePeriod)
    ]

    #if canImport(Darwin)
      platformOptions.preSpawnProcessConfigurator = { _, _ in
        try Self.requireNotCancelled(outcomeUncertain: false)
        try request.validateBeforeLaunch?()
        try Self.requireNotCancelled(outcomeUncertain: false)
      }
    #else
      try request.validateBeforeLaunch?()
      try Self.requireNotCancelled(outcomeUncertain: false)
    #endif

    let teardownSequence = platformOptions.teardownSequence
    do {
      let result = try await Subprocess.run(
        .path(.init(request.executable)),
        arguments: Arguments(request.arguments),
        environment: .inherit.updating(Self.environmentOverrides(request.environment)),
        workingDirectory: request.workingDirectory.map { .init($0) },
        platformOptions: platformOptions,
        input: .inputWriter,
        output: .sequence,
        error: .sequence
      ) { execution in
        await output.markLaunched()
        let termination = ProcessTerminationCoordinator()
        let terminateGroup: @Sendable () async -> Void = {
          await execution.teardown(using: teardownSequence)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
            try await Self.capture(
              execution.standardOutput,
              to: .stdout,
              processID: execution.processIdentifier.value,
              output: output,
              termination: termination,
              terminateGroup: terminateGroup
            )
          }
          group.addTask {
            try await Self.capture(
              execution.standardError,
              to: .stderr,
              processID: execution.processIdentifier.value,
              output: output,
              termination: termination,
              terminateGroup: terminateGroup
            )
          }
          group.addTask {
            if let input = request.input, !input.isEmpty {
              _ = try await execution.standardInputWriter.write(input)
            }
            try await execution.standardInputWriter.finish()
          }
          group.addTask {
            try await Self.supervise(
              processID: execution.processIdentifier.value,
              timeout: request.timeout,
              output: output,
              termination: termination,
              terminateGroup: terminateGroup
            )
          }
          try await group.waitForAll()
        }

        return await output.snapshot()
      }

      return Self.result(from: result.terminationStatus, output: result.closureResult)
    } catch {
      let output = await output.snapshot()
      if let agentError = error as? AgentError { throw agentError }
      if Task.isCancelled {
        throw Self.cancellationError(outcomeUncertain: output.didLaunch)
      }
      if let subprocessError = error as? SubprocessError {
        var details: [String: JSONValue] = [
          "path": .string(request.executable),
          "reason": .string(String(describing: subprocessError)),
        ]
        if let underlying = subprocessError.underlyingError {
          details["errno"] = .integer(Int64(underlying.rawValue))
        }
        throw AgentError(
          code: output.didLaunch ? "process_execution_failed" : "process_launch_failed",
          message: output.didLaunch ? "Process execution failed" : "Could not launch process",
          details: details,
          exitCode: 5,
          outcomeUncertain: output.didLaunch
        )
      }
      throw AgentError(
        code: output.didLaunch ? "process_execution_failed" : "process_launch_failed",
        message: output.didLaunch ? "Process execution failed" : "Could not launch process",
        details: [
          "path": .string(request.executable),
          "reason": .string(String(describing: error)),
        ],
        exitCode: 5,
        outcomeUncertain: output.didLaunch
      )
    }
  }

  private static func supervise(
    processID: pid_t,
    timeout: TimeInterval,
    output: ProcessOutputCollector,
    termination: ProcessTerminationCoordinator,
    terminateGroup: @escaping @Sendable () async -> Void
  ) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !Task.isCancelled {
      if await output.hasExceededLimit() {
        await termination.terminate(using: terminateGroup)
        return
      }
      if try childHasExitedWithoutReaping(processID) {
        // Keep the leader waitable until descendants are stopped so its process-group ID
        // cannot be reused before the group teardown finishes.
        await termination.terminate(using: terminateGroup)
        return
      }
      if ProcessInfo.processInfo.systemUptime >= deadline {
        await output.markTimedOut()
        await termination.terminate(using: terminateGroup)
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private static func capture(
    _ sequence: SubprocessOutputSequence,
    to stream: ProcessOutputStream,
    processID: pid_t,
    output: ProcessOutputCollector,
    termination: ProcessTerminationCoordinator,
    terminateGroup: @escaping @Sendable () async -> Void
  ) async throws {
    do {
      for try await buffer in sequence {
        let bytes = buffer.withUnsafeBytes { Data($0) }
        if await output.append(bytes, to: stream) {
          await termination.terminate(using: terminateGroup)
        }
      }
    } catch {
      if await termination.hasStarted() { return }
      if try childHasExitedWithoutReaping(processID) {
        await termination.terminate(using: terminateGroup)
        return
      }
      throw error
    }
  }

  private static func childHasExitedWithoutReaping(_ processID: pid_t) throws -> Bool {
    while true {
      var information = siginfo_t()
      let result = waitid(P_PID, id_t(processID), &information, WEXITED | WNOHANG | WNOWAIT)
      if result == 0 { return information.si_pid == processID }
      if errno == EINTR { continue }
      throw AgentError(
        code: "process_wait_failed",
        message: "Could not inspect child process state",
        details: ["pid": .integer(Int64(processID)), "errno": .integer(Int64(errno))],
        exitCode: 5,
        outcomeUncertain: true
      )
    }
  }

  private static func validate(_ request: ProcessRequest) throws {
    guard request.executable.hasPrefix("/") else {
      throw AgentError(
        code: "process_path_not_absolute",
        message: "Executable path must be absolute",
        details: ["path": .string(request.executable)],
        exitCode: 5
      )
    }
    guard request.timeout.isFinite, request.timeout > 0, request.maximumOutputBytes > 0 else {
      throw AgentError(
        code: "invalid_process_limits",
        message: "Process timeout and output limit must be positive and finite",
        exitCode: 5
      )
    }
    if let cwd = request.workingDirectory, !cwd.hasPrefix("/") || cwd.contains("\0") {
      throw AgentError.invalid("Process working directory must be an absolute path without NUL bytes")
    }
    let invalidArgumentIndex = request.arguments.firstIndex(where: { $0.contains("\0") })
    guard !request.executable.contains("\0"), invalidArgumentIndex == nil else {
      var details: [String: JSONValue] = [:]
      if let invalidArgumentIndex {
        details["argument_index"] = .integer(Int64(invalidArgumentIndex))
      } else {
        details["property"] = .string("executable")
      }
      throw AgentError(
        code: "process_argument_invalid",
        message: "Executable paths and arguments must not contain NUL bytes",
        details: details,
        exitCode: 2
      )
    }
    for (key, value) in request.environment {
      guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0") else {
        throw AgentError(
          code: "process_environment_invalid",
          message: "Process environment contains an invalid key or NUL byte",
          details: ["key": .string(key)],
          exitCode: 2
        )
      }
    }
  }

  private static func environmentOverrides(_ values: [String: String]) -> [Environment.Key: String?] {
    var result: [Environment.Key: String?] = [:]
    for (key, value) in values {
      result[Environment.Key(stringLiteral: key)] = .some(value)
    }
    return result
  }

  private static func requireNotCancelled(outcomeUncertain: Bool) throws {
    guard !Task.isCancelled else { throw cancellationError(outcomeUncertain: outcomeUncertain) }
  }

  private static func cancellationError(outcomeUncertain: Bool) -> AgentError {
    AgentError(
      code: "operation_cancelled",
      message: "Process execution was cancelled",
      exitCode: 6,
      outcomeUncertain: outcomeUncertain
    )
  }

  private static func result(
    from status: TerminationStatus,
    output: ProcessOutputSnapshot
  ) -> ProcessResult {
    switch status {
    case .exited(let code):
      return ProcessResult(
        exitCode: Int32(code),
        terminationSignal: nil,
        stdout: output.stdout,
        stderr: output.stderr,
        timedOut: output.timedOut,
        outputLimitExceeded: output.outputLimitExceeded
      )
    case .signaled(let signal):
      let signalValue = Int32(signal)
      return ProcessResult(
        exitCode: 128 + signalValue,
        terminationSignal: signalValue,
        stdout: output.stdout,
        stderr: output.stderr,
        timedOut: output.timedOut,
        outputLimitExceeded: output.outputLimitExceeded
      )
    }
  }
}
