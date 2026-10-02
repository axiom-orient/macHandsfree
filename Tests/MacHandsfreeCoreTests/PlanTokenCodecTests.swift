import Foundation
import Testing
@testable import MacHandsfreeState

struct PlanTokenCodecTests {
  @Test func tokenBindsTheExactApprovedPlanAndRejectsLegacyVersion() throws {
    let codec = PlanTokenCodec(secret: Data("test-only secret".utf8))
    let id = UUID().uuidString.lowercased()
    let command = "reminders.items.create"
    let input = #"{"list_id":"work","title":"Call Sam"}"#
    let preview = #"{"target":"work","title":"Call Sam"}"#
    let expiry = 1_800_000_000.0
    let token = try codec.issue(
      id: id, command: command, inputJSON: input, previewJSON: preview, expiresAt: expiry)
    let parsed = try codec.parse(token)

    #expect(
      codec.verifies(
        parsed, command: command, inputJSON: input, previewJSON: preview, expiresAt: expiry))
    #expect(
      !codec.verifies(
        parsed, command: command, inputJSON: "{}", previewJSON: preview, expiresAt: expiry))
    #expect(
      !codec.verifies(
        parsed, command: "notes.items.create", inputJSON: input,
        previewJSON: preview, expiresAt: expiry))
    #expect(
      !codec.verifies(
        parsed, command: command, inputJSON: input, previewJSON: "{}", expiresAt: expiry))
    #expect(
      !codec.verifies(
        parsed, command: command, inputJSON: input, previewJSON: preview, expiresAt: expiry + 1))

    let parts = token.split(separator: ".")
    guard parts.count == 3 else {
      Issue.record("A plan token must contain a version, identifier, and signature")
      return
    }
    let legacyToken = "v2.\(parts[1]).\(parts[2])"
    do {
      _ = try codec.parse(legacyToken)
      Issue.record("Legacy plan-token versions must not be accepted")
    } catch {}
  }
}
