import MacHandsfreeSQLite

struct StoredPlanRecord: Sendable {
  let id: String
  let command: String
  let inputJSON: String
  let previewJSON: String
  let expiresAt: Double
  let consumedAt: Double?

  init?(row: [String: SQLiteValue]) {
    guard let id = row["id"]?.text,
      let command = row["command"]?.text,
      let inputJSON = row["input_json"]?.text,
      let previewJSON = row["preview_json"]?.text,
      let expiresAt = row["expires_at"]?.number, expiresAt.isFinite
    else { return nil }
    self.id = id
    self.command = command
    self.inputJSON = inputJSON
    self.previewJSON = previewJSON
    self.expiresAt = expiresAt
    self.consumedAt = row["consumed_at"]?.number
  }
}

enum ExecutionRecordStatus: String, Sendable {
  case running, succeeded, failed, uncertain
}

struct StoredExecutionRecord: Sendable {
  let command: String
  let inputHash: String
  private let rawStatus: String
  // Unknown stored values remain invalid records, never an absent execution eligible for retry.
  var status: ExecutionRecordStatus? { ExecutionRecordStatus(rawValue: rawStatus) }
  let resultJSON: String?

  init?(row: [String: SQLiteValue]) {
    guard let command = row["command"]?.text,
      let inputHash = row["input_hash"]?.text,
      let status = row["status"]?.text
    else { return nil }
    self.command = command
    self.inputHash = inputHash
    self.rawStatus = status
    self.resultJSON = row["result_json"]?.text
  }
}
