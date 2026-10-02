import CSQLite3
import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

package final class SQLiteDatabase {
  private var handle: OpaquePointer?

  package init(path: String, readOnly: Bool = false, canonicalizePath: Bool = true) throws {
    guard !path.utf8.contains(0) else {
      throw AgentError(
        code: "sqlite_open_failed", message: "SQLite database path contains a null byte",
        details: ["path": .string(path)], exitCode: 5)
    }
    if !readOnly { try Self.createFileIfMissing(path) }
    try Self.validateDatabasePath(path)
    let databasePath = canonicalizePath ? Self.canonicalPath(path) : path
    let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    let status = sqlite3_open_v2(
      databasePath,
      &handle,
      flags | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
      nil
    )
    guard status == SQLITE_OK, handle != nil else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
      if let handle { sqlite3_close(handle) }
      self.handle = nil
      throw AgentError(
        code: "sqlite_open_failed", message: "Could not open SQLite database",
        details: ["path": .string(path), "reason": .string(message)], exitCode: 5)
    }
    sqlite3_busy_timeout(handle, 5_000)
  }

  deinit { if let handle { sqlite3_close(handle) } }

  private static func createFileIfMissing(_ path: String) throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    if descriptor >= 0 {
      guard close(descriptor) == 0 else {
        throw AgentError(
          code: "sqlite_open_failed",
          message: "Could not close the newly created SQLite database file",
          details: ["path": .string(path), "errno": .integer(Int64(errno))],
          exitCode: 5
        )
      }
      return
    }
    guard errno == EEXIST else {
      throw AgentError(
        code: "sqlite_open_failed",
        message: "Could not create SQLite database file",
        details: ["path": .string(path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
  }

  private static func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private static func validateDatabasePath(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT { return }
      throw AgentError(
        code: "sqlite_open_failed",
        message: "Could not inspect SQLite database path",
        details: ["path": .string(path), "errno": .integer(Int64(errno))],
        exitCode: 5
      )
    }
    let type = info.st_mode & mode_t(S_IFMT)
    guard type != mode_t(S_IFLNK) else {
      throw AgentError(
        code: "sqlite_symbolic_link_not_allowed",
        message: "SQLite database path must not be a symbolic link",
        details: ["path": .string(path)],
        exitCode: 5
      )
    }
    guard type == mode_t(S_IFREG) else {
      throw AgentError(
        code: "sqlite_invalid_file_type",
        message: "SQLite database path must be a regular file",
        details: ["path": .string(path), "mode": .integer(Int64(info.st_mode))],
        exitCode: 5
      )
    }
  }

  package func execute(_ sql: String, values: [SQLiteValue] = []) throws {
    try withStatement(sql, values: values) { statement in
      while true {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return }
        if status == SQLITE_ROW { continue }
        throw failure("sqlite_execute_failed")
      }
    }
  }

  package func query(_ sql: String, values: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
    try withStatement(sql, values: values) { statement in
      var rows: [[String: SQLiteValue]] = []
      while true {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return rows }
        guard status == SQLITE_ROW else { throw failure("sqlite_query_failed") }
        var row: [String: SQLiteValue] = [:]
        for index in 0..<sqlite3_column_count(statement) {
          guard let rawName = sqlite3_column_name(statement, index) else {
            throw failure("sqlite_query_failed")
          }
          let name = String(cString: rawName)
          row[name] = try columnValue(statement, index: index, name: name)
        }
        rows.append(row)
      }
    }
  }

  /// Copies values while the statement remains on its current row; pointers never escape this scope.
  private func columnValue(
    _ statement: OpaquePointer, index: Int32, name: String
  ) throws -> SQLiteValue {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_INTEGER:
      return .integer(sqlite3_column_int64(statement, index))
    case SQLITE_FLOAT:
      return .number(sqlite3_column_double(statement, index))
    case SQLITE_TEXT:
      guard let text = sqlite3_column_text(statement, index) else {
        try requireColumnMemory()
        return .null
      }
      let count = Int(sqlite3_column_bytes(statement, index))
      if count == 0 { try requireColumnMemory() }
      let data = Data(bytes: text, count: count)
      guard let string = String(data: data, encoding: .utf8) else {
        throw AgentError(
          code: "sqlite_invalid_text", message: "SQLite returned invalid UTF-8 text",
          details: ["column": .string(name)], exitCode: 5)
      }
      return .text(string)
    case SQLITE_BLOB:
      let bytes = sqlite3_column_blob(statement, index)
      if bytes == nil { try requireColumnMemory() }
      let count = Int(sqlite3_column_bytes(statement, index))
      if count == 0 { try requireColumnMemory() }
      if let bytes { return .blob(Data(bytes: bytes, count: count)) }
      guard count == 0 else { throw failure("sqlite_query_failed") }
      return .blob(Data())
    default:
      return .null
    }
  }

  /// SQLite requires this check before another column API can replace a conversion error.
  private func requireColumnMemory() throws {
    if sqlite3_errcode(handle) == SQLITE_NOMEM { throw failure("sqlite_query_failed") }
  }

  package var changedRowCount: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }

  package func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")

    let result: T
    do {
      result = try body()
    } catch {
      try rollbackIfActive(after: error, phase: "body")
    }

    do {
      try execute("COMMIT")
      return result
    } catch {
      let commitError = error
      guard isTransactionActive else {
        throw AgentError(
          code: "sqlite_commit_outcome_uncertain",
          message: "SQLite reported a commit failure after the transaction ended",
          details: ["commit_error": .string(String(describing: commitError))],
          exitCode: 5,
          outcomeUncertain: true
        )
      }
      try rollbackIfActive(after: commitError, phase: "commit")
    }
  }

  private var isTransactionActive: Bool {
    guard let handle else { return false }
    return sqlite3_get_autocommit(handle) == 0
  }

  private func rollbackIfActive(after originalError: any Error, phase: String) throws -> Never {
    guard isTransactionActive else { throw originalError }
    do {
      try execute("ROLLBACK")
    } catch {
      throw AgentError(
        code: "sqlite_rollback_failed",
        message: "SQLite transaction failed and could not be rolled back",
        details: [
          "phase": .string(phase),
          "original_error": .string(String(describing: originalError)),
          "rollback_error": .string(String(describing: error)),
          "transaction_active": .bool(isTransactionActive),
        ],
        exitCode: 5,
        outcomeUncertain: true
      )
    }
    throw originalError
  }

  private func withStatement<Result>(
    _ sql: String, values: [SQLiteValue], _ body: (OpaquePointer) throws -> Result
  ) throws -> Result {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement)
    return try body(statement)
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    guard let handle else {
      throw AgentError(code: "sqlite_closed", message: "SQLite database is closed", exitCode: 5)
    }
    guard !sql.utf8.contains(0) else {
      throw AgentError(
        code: "sqlite_prepare_failed", message: "SQLite statement contains a null byte", exitCode: 5)
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw failure("sqlite_prepare_failed")
    }
    return statement
  }

  private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
    let expected = Int(sqlite3_bind_parameter_count(statement))
    guard expected == values.count else {
      throw AgentError(
        code: "sqlite_binding_count_mismatch",
        message: "SQLite binding count does not match the statement",
        details: ["expected": .integer(Int64(expected)), "actual": .integer(Int64(values.count))],
        exitCode: 5)
    }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let status: Int32
      switch value {
      case .null: status = sqlite3_bind_null(statement, index)
      case .integer(let value): status = sqlite3_bind_int64(statement, index, value)
      case .number(let value): status = sqlite3_bind_double(statement, index, value)
      case .text(let value):
        let bytes = value.utf8CString
        guard bytes.count - 1 <= Int(Int32.max) else {
          throw AgentError(
            code: "sqlite_value_too_large",
            message: "SQLite text binding exceeds the supported size",
            exitCode: 5
          )
        }
        status = bytes.withUnsafeBufferPointer { buffer in
          sqlite3_bind_text(
            statement,
            index,
            buffer.baseAddress,
            Int32(buffer.count - 1),
            sqliteTransient
          )
        }
      case .blob(let value):
        guard value.count <= Int(Int32.max) else {
          throw AgentError(
            code: "sqlite_value_too_large",
            message: "SQLite blob binding exceeds the supported size",
            exitCode: 5
          )
        }
        if value.isEmpty {
          status = sqlite3_bind_zeroblob(statement, index, 0)
        } else {
          status = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient)
          }
        }
      }
      guard status == SQLITE_OK else { throw failure("sqlite_bind_failed") }
    }
  }

  private func failure(_ code: String) -> AgentError {
    guard let handle else {
      return AgentError(
        code: code,
        message: "SQLite operation failed",
        details: ["reason": .string("database is closed")],
        exitCode: 5
      )
    }
    let sqliteCode = sqlite3_errcode(handle)
    let extendedCode = sqlite3_extended_errcode(handle)
    let reason = String(cString: sqlite3_errmsg(handle))
    return AgentError(
      code: code,
      message: "SQLite operation failed",
      details: [
        "reason": .string(reason),
        "sqlite_code": .integer(Int64(sqliteCode)),
        "sqlite_extended_code": .integer(Int64(extendedCode)),
      ],
      exitCode: 5
    )
  }
}
