public import Foundation

public struct MacHandsfreeCommand: Sendable {
  public let id: String
  public let summary: String
  public let service: String
  public let isMutation: Bool
  public let risk: String
  public let permissions: [String]
  public let schemaJSON: String
}

public struct MacHandsfreeFileData: Sendable {
  public let path: String
  public let data: Data
}

public enum MacHandsfreeFileReadResult: Sendable {
  case bytes(MacHandsfreeFileData)
  case failure(MacHandsfreeResult)
}

public struct MacHandsfreePlan: Sendable {
  public let commandID: String
  public let token: String
  public let previewJSON: String
}
public struct MacHandsfreeResult: Sendable {
  public enum Outcome: Sendable, Equatable { case succeeded, failed, uncertain }
  public let outcome: Outcome
  public var succeeded: Bool { outcome == .succeeded }
  public var outcomeUncertain: Bool { outcome == .uncertain }
  public let json: String
}
public struct MacHandsfreeClientError: LocalizedError, Sendable {
  public let code: String
  public let message: String
  public var errorDescription: String? { "\(code): \(message)" }
}
