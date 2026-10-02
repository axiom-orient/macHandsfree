package import Foundation
package import MacHandsfreeCore
import MacHandsfreeSQLite

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

package actor SQLiteExecutionStateStore: ExecutionStateStore {
  private let database: SQLiteDatabase
  private let tokenCodec: PlanTokenCodec

  package init(directory: StateDirectory) throws {
    try Self.prepareDirectory(directory.url)
    let (database, secret) = try StateInitializationLock.withLock(in: directory.url) {
      let secret = try StateSecretStore.loadOrCreate(in: directory.url)
      let path = directory.url.appending(path: "state.sqlite3").path
      try Self.secureExistingDatabase(at: path)
      let database = try SQLiteDatabase(path: path)
      try database.execute("PRAGMA journal_mode = WAL")
      try database.execute("PRAGMA synchronous = FULL")
      try database.execute("""
        CREATE TABLE IF NOT EXISTS plans (
          id TEXT PRIMARY KEY,
          command TEXT NOT NULL,
          input_json TEXT NOT NULL,
          preview_json TEXT NOT NULL,
          expires_at REAL NOT NULL,
          consumed_at REAL
        )
        """)
      try database.execute("""
        CREATE TABLE IF NOT EXISTS executions (
          idempotency_key TEXT PRIMARY KEY,
          command TEXT NOT NULL,
          input_hash TEXT NOT NULL,
          status TEXT NOT NULL,
          result_json TEXT,
          updated_at REAL NOT NULL
        )
        """)
      return (database, secret)
    }
    self.database = database
    tokenCodec = PlanTokenCodec(secret: secret)
    try Self.clearExpiredUnusedPlanPayloads(database: database, before: Date().timeIntervalSince1970)
  }

  package func createPlan(
    command: String, input: JSONValue, preview: JSONValue, lifetime: TimeInterval
  ) async throws -> MutationPlan {
    guard lifetime.isFinite, lifetime > 0 else {
      throw AgentError.invalid("Plan lifetime must be finite and positive")
    }
    let now = Date()
    let expiresAt = now.addingTimeInterval(lifetime)
    guard expiresAt.timeIntervalSince1970.isFinite else {
      throw AgentError.invalid("Plan expiry is outside the supported time range")
    }
    let id = UUID().uuidString.lowercased()
    let inputJSON = try CanonicalJSON.string(input)
    let previewJSON = try CanonicalJSON.string(preview)
    let token = try tokenCodec.issue(
      id: id, command: command, inputJSON: inputJSON, previewJSON: previewJSON,
      expiresAt: expiresAt.timeIntervalSince1970)
    try Self.clearExpiredUnusedPlanPayloads(database: database, before: now.timeIntervalSince1970)
    try database.transaction {
      try database.execute(
        "INSERT INTO plans (id, command, input_json, preview_json, expires_at, consumed_at) VALUES (?, ?, ?, ?, ?, NULL)",
        values: [.text(id), .text(command), .text(inputJSON), .text(previewJSON), .number(expiresAt.timeIntervalSince1970)])
    }
    return MutationPlan(
      token: token, command: command, input: input, preview: preview, expiresAt: expiresAt)
  }

  package func discardPlan(token: String) async throws -> Bool {
    let parsedToken = try tokenCodec.parse(token)
    return try database.transaction {
      guard let plan = try storedPlan(id: parsedToken.id) else { return false }
      guard plan.consumedAt == nil else { return false }
      if plan.expiresAt < Date().timeIntervalSince1970,
        plan.inputJSON.isEmpty, plan.previewJSON.isEmpty
      {
        return false
      }
      try requireValidSignature(parsedToken, for: plan)
      try database.execute(
        "DELETE FROM plans WHERE id = ? AND consumed_at IS NULL",
        values: [.text(parsedToken.id)])
      return database.changedRowCount == 1
    }
  }

  package func beginExecution(
    command: String, planToken: String, idempotencyKey: String
  ) async throws -> BeginExecution {
    guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 200 else {
      throw AgentError.invalid("Idempotency key is empty or too long")
    }
    try Self.clearExpiredUnusedPlanPayloads(database: database, before: Date().timeIntervalSince1970)
    let token = try tokenCodec.parse(planToken)
    guard let plan = try storedPlan(id: token.id) else {
      throw AgentError(code: "plan_not_found", message: "The execution plan does not exist", exitCode: 2)
    }
    guard plan.command == command else {
      throw AgentError(
        code: "plan_command_mismatch", message: "The plan belongs to a different command", exitCode: 6)
    }
    let now = Date().timeIntervalSince1970
    let expiredUnusedPlan = plan.consumedAt == nil && now > plan.expiresAt
    let expiredError = AgentError(
      code: "plan_expired", message: "The execution plan has expired", exitCode: 2)
    // An expired tombstone has no signed payload left and can only fail closed.
    if expiredUnusedPlan, plan.inputJSON.isEmpty, plan.previewJSON.isEmpty {
      throw expiredError
    }
    try requireValidSignature(token, for: plan)
    if expiredUnusedPlan {
      try Self.clearExpiredUnusedPlanPayloads(database: database, before: now)
      throw expiredError
    }

    let input = try JSONValue.parse(Data(plan.inputJSON.utf8))
    let preview = try JSONValue.parse(Data(plan.previewJSON.utf8))
    let inputHash = SHA256.hex(Data(plan.inputJSON.utf8))
    return try database.transaction {
      if let existingRow = try database.query(
        "SELECT command, input_hash, status, result_json FROM executions WHERE idempotency_key = ?",
        values: [.text(idempotencyKey)]).first {
        guard let existing = StoredExecutionRecord(row: existingRow) else {
          throw AgentError(
            code: "execution_state_invalid", message: "The saved execution state is malformed", exitCode: 5)
        }
        return try ExecutionResumePolicy.existing(existing, command: command, inputHash: inputHash)
      }

      let executionStartedAt = Date().timeIntervalSince1970
      guard executionStartedAt <= plan.expiresAt else {
        throw AgentError(code: "plan_expired", message: "The execution plan has expired", exitCode: 2)
      }
      guard plan.consumedAt == nil else {
        throw AgentError(code: "plan_consumed", message: "The execution plan has already been used", exitCode: 6)
      }
      try database.execute(
        "UPDATE plans SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL",
        values: [.number(executionStartedAt), .text(token.id)])
      guard database.changedRowCount == 1 else {
        throw AgentError(code: "plan_consumed", message: "The execution plan has already been used", exitCode: 6)
      }
      try database.execute(
        "INSERT INTO executions (idempotency_key, command, input_hash, status, result_json, updated_at) VALUES (?, ?, ?, ?, NULL, ?)",
        values: [.text(idempotencyKey), .text(command), .text(inputHash),
                 .text(ExecutionRecordStatus.running.rawValue), .number(executionStartedAt)])
      return .execute(input: input, preview: preview)
    }
  }

  package func completeSuccess(idempotencyKey: String, result: JSONValue) async throws {
    let json = try CanonicalJSON.string(result)
    guard try updateRunningExecution(
      idempotencyKey: idempotencyKey, status: .succeeded, resultJSON: json)
    else {
      throw AgentError(
        code: "execution_state_invalid", message: "The execution state could not be completed", exitCode: 5)
    }
  }

  package func completeFailure(idempotencyKey: String, error: AgentError) async throws {
    let status: ExecutionRecordStatus = error.outcomeUncertain ? .uncertain : .failed
    let result = JSONValue.object([
      "code": .string(error.code), "message": .string(error.message),
      "details": .object(error.details), "exit_code": .integer(Int64(error.exitCode)),
      "outcome_uncertain": .bool(error.outcomeUncertain),
    ])
    let json = try CanonicalJSON.string(result)
    guard try updateRunningExecution(
      idempotencyKey: idempotencyKey, status: status, resultJSON: json)
    else {
      throw AgentError(
        code: "execution_state_invalid", message: "The execution failure could not be recorded", exitCode: 5,
        outcomeUncertain: true)
    }
  }

  private func storedPlan(id: String) throws -> StoredPlanRecord? {
    guard let row = try database.query(
      "SELECT id, command, input_json, preview_json, expires_at, consumed_at FROM plans WHERE id = ?",
      values: [.text(id)]).first
    else { return nil }
    return StoredPlanRecord(row: row)
  }

  private func requireValidSignature(
    _ token: PlanTokenCodec.Parsed, for plan: StoredPlanRecord
  ) throws {
    guard tokenCodec.verifies(
      token, command: plan.command, inputJSON: plan.inputJSON,
      previewJSON: plan.previewJSON, expiresAt: plan.expiresAt)
    else {
      throw AgentError(
        code: "plan_signature_invalid", message: "The plan token signature is invalid",
        details: ["plan_id": .string(token.id)], exitCode: 6)
    }
  }

  private func updateRunningExecution(
    idempotencyKey: String, status: ExecutionRecordStatus, resultJSON: String
  ) throws -> Bool {
    try database.execute(
      "UPDATE executions SET status = ?, result_json = ?, updated_at = ? WHERE idempotency_key = ? AND status = ?",
      values: [.text(status.rawValue), .text(resultJSON), .number(Date().timeIntervalSince1970),
               .text(idempotencyKey), .text(ExecutionRecordStatus.running.rawValue)])
    return database.changedRowCount == 1
  }

  private static func clearExpiredUnusedPlanPayloads(database: SQLiteDatabase, before timestamp: Double) throws {
    try database.transaction {
      try database.execute(
        "UPDATE plans SET input_json = '', preview_json = '' WHERE consumed_at IS NULL AND expires_at < ? AND (input_json != '' OR preview_json != '')",
        values: [.number(timestamp)])
    }
  }

  private static func prepareDirectory(_ directory: URL) throws {
    var info = stat()
    if lstat(directory.path, &info) != 0, errno == ENOENT {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    guard lstat(directory.path, &info) == 0,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid()
    else {
      throw AgentError(
        code: "state_directory_invalid", message: "Execution state must use an owned regular directory", exitCode: 5)
    }
    guard info.st_mode & mode_t(0o777) == mode_t(0o700) else {
      throw AgentError(
        code: "state_directory_invalid", message: "Execution state directory must have mode 0700",
        exitCode: 5)
    }
  }

  private static func secureExistingDatabase(at path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT { return }
      throw AgentError(
        code: "state_database_invalid", message: "Could not inspect execution state database",
        details: ["errno": .integer(Int64(errno))], exitCode: 5)
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
      info.st_mode & mode_t(0o777) == mode_t(0o600)
    else {
      throw AgentError(
        code: "state_database_invalid", message: "Execution state database must be an owned regular file with mode 0600",
        exitCode: 5)
    }
  }
}
