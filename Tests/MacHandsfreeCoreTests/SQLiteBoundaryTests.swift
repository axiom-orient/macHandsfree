import Foundation
import MacHandsfreeCore
import MacHandsfreeSQLite
import Testing

struct SQLiteBoundaryTests {
  @Test func queryPreservesDistinctNullEmptyAndNumericValues() throws {
    let directory = try fixtureDirectory()
    defer { removeFixture(directory) }
    let database = try SQLiteDatabase(path: directory.appending(path: "state.sqlite3").path)
    let rows = try database.query(
      "SELECT NULL AS null_value, '' AS text_value, zeroblob(0) AS blob_value, 42 AS int_value, 1.25 AS real_value")
    let row = try #require(rows.first)
    #expect(row["null_value"] == SQLiteValue.null)
    #expect(row["text_value"]?.text == "")
    #expect(row["blob_value"] == SQLiteValue.blob(Data()))
    #expect(row["int_value"]?.integer == 42)
    #expect(row["real_value"]?.number == 1.25)
  }

  @Test func queryRejectsInvalidUTF8InsteadOfReplacingIt() throws {
    let directory = try fixtureDirectory()
    defer { removeFixture(directory) }
    let database = try SQLiteDatabase(path: directory.appending(path: "state.sqlite3").path)
    do {
      _ = try database.query("SELECT CAST(X'80' AS TEXT) AS invalid_text")
      Issue.record("Invalid UTF-8 must not be replaced with a string or null")
    } catch let error as AgentError {
      #expect(error.code == "sqlite_invalid_text")
      #expect(error.details["column"]?.stringValue == "invalid_text")
    }
  }

  @Test func nullBytePathDoesNotCreateTheTruncatedDatabase() throws {
    let directory = try fixtureDirectory()
    defer { removeFixture(directory) }
    let path = directory.appending(path: "state.sqlite3").path
    do {
      _ = try SQLiteDatabase(path: path + "\0suffix")
      Issue.record("A null-byte path must not open a truncated database path")
    } catch let error as AgentError {
      #expect(error.code == "sqlite_open_failed")
    }
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test func nullByteSQLDoesNotExecuteItsValidPrefix() throws {
    let directory = try fixtureDirectory()
    defer { removeFixture(directory) }
    let database = try SQLiteDatabase(path: directory.appending(path: "state.sqlite3").path)
    try database.execute("CREATE TABLE effects (value INTEGER NOT NULL)")
    do {
      try database.execute("INSERT INTO effects (value) VALUES (1)\0ignored")
      Issue.record("A null-byte statement must not execute its valid prefix")
    } catch let error as AgentError {
      #expect(error.code == "sqlite_prepare_failed")
    }
    let rows = try database.query("SELECT COUNT(*) AS count FROM effects")
    #expect(rows.first?["count"]?.integer == 0)
  }

  @Test func nullBytesRemainValidInsideBoundTextAndBlobValues() throws {
    let directory = try fixtureDirectory()
    defer { removeFixture(directory) }
    let database = try SQLiteDatabase(path: directory.appending(path: "state.sqlite3").path)
    try database.execute("CREATE TABLE values_table (text_value TEXT, blob_value BLOB)")
    let text = "before\0after"
    let bytes = Data([0, 1, 0, 255])
    try database.execute(
      "INSERT INTO values_table (text_value, blob_value) VALUES (?, ?)",
      values: [.text(text), .blob(bytes)])
    let rows = try database.query("SELECT text_value, blob_value FROM values_table")
    #expect(rows.first?["text_value"]?.text == text)
    #expect(rows.first?["blob_value"] == SQLiteValue.blob(bytes))
  }

  private func fixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }

  private func removeFixture(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch { Issue.record("SQLite boundary fixture cleanup failed: \(error)") }
  }
}
