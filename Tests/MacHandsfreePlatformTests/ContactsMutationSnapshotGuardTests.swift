import Testing
import MacHandsfreeCore
@testable import MacHandsfreePlatform

struct ContactsMutationSnapshotGuardTests {
  @Test func knownReadbackFailureAfterSaveStillRequiresEffectConfirmation() {
    let result = ContactsPostSaveOutcomePolicy.failure(
      AgentError.invalid("Readback failed"), contactID: "contact-1")
    #expect(result.code == "contacts_post_save_read_failed")
    #expect(result.outcomeUncertain)
    #expect(result.details["contact_id"]?.stringValue == "contact-1")
    #expect(result.details["original_code"]?.stringValue == "invalid_input")
  }

  @Test func alreadyUncertainSaveFailureKeepsItsOriginalEvidence() {
    let original = AgentError(
      code: "native_effect_unconfirmed", message: "Check the original contact",
      details: ["receipt": .string("original-evidence")], exitCode: 7, outcomeUncertain: true)
    let result = ContactsPostSaveOutcomePolicy.failure(original, contactID: "contact-1")
    #expect(result.code == original.code)
    #expect(result.message == original.message)
    #expect(result.details == original.details)
    #expect(result.exitCode == original.exitCode)
    #expect(result.outcomeUncertain)
  }

  @Test func createPlanHasAGuardButNoExistingContactSnapshot() throws {
    let preview = planPreview(
      action: "contacts.items.create",
      details: ["given_name": .string("Ada")]
    )
    let expected = try ContactsMutationSnapshotGuard.expectedContact(
      commandID: "contacts.items.create",
      object: ["given_name": .string("Ada")],
      preview: preview
    )
    #expect(expected == nil)
  }

  @Test func updatePlanReturnsOnlyTheSnapshotForItsExactContactID() throws {
    let snapshot: JSONValue = ["id": "contact-1", "given_name": "Ada"]
    let preview = planPreview(
      action: "contacts.items.update",
      details: ["contact": snapshot, "job_title": .string("Engineer")]
    )
    let expected = try ContactsMutationSnapshotGuard.expectedContact(
      commandID: "contacts.items.update",
      object: ["contact_id": .string("contact-1"), "job_title": .string("Engineer")],
      preview: preview
    )
    #expect(expected == snapshot)
  }

  @Test func rejectsSnapshotlessOrMismatchedPlans() {
    let oldPreview: JSONValue = [
      "effects": [[
        "action": "contacts.items.delete",
        "target": "Ada",
        "details": .object([:]),
      ]]
    ]
    let updatePreview = planPreview(
      action: "contacts.items.update",
      details: ["contact": ["id": "contact-2"]]
    )
    let cases: [(String, [String: JSONValue], JSONValue, String)] = [
      (
        "contacts.items.delete",
        ["contact_id": .string("contact-1")],
        oldPreview,
        "plan_state_changed"
      ),
      (
        "contacts.items.update",
        ["contact_id": .string("contact-1")],
        updatePreview,
        "plan_preview_invalid"
      ),
    ]

    for (commandID, object, preview, expectedCode) in cases {
      do {
        _ = try ContactsMutationSnapshotGuard.expectedContact(
          commandID: commandID,
          object: object,
          preview: preview
        )
        Issue.record("A missing or mismatched Contacts snapshot must be rejected")
      } catch let error as AgentError {
        #expect(error.code == expectedCode)
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }
  }

  @Test func acceptsUnchangedContactProjection() throws {
    let snapshot: JSONValue = [
      "id": "contact-1",
      "given_name": "Ada",
      "emails": ["ada@example.test"],
    ]

    try ContactsMutationSnapshotGuard.validate(
      expected: snapshot,
      actual: snapshot,
      contactID: "contact-1"
    )
  }

  @Test func rejectsChangedContactProjection() {
    let expected: JSONValue = [
      "id": "contact-1",
      "given_name": "Ada",
      "emails": ["old@example.test"],
    ]
    let current: JSONValue = [
      "id": "contact-1",
      "given_name": "Ada",
      "emails": ["new@example.test"],
    ]

    do {
      try ContactsMutationSnapshotGuard.validate(
        expected: expected,
        actual: current,
        contactID: "contact-1"
      )
      Issue.record("A changed Contacts projection must invalidate the approved plan")
    } catch let error as AgentError {
      #expect(error.code == "plan_state_changed")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  private func planPreview(action: String, details: [String: JSONValue]) -> JSONValue {
    [
      "guard_version": 1,
      "effects": [[
        "action": .string(action),
        "target": .string("Ada"),
        "details": .object(details),
      ]],
    ]
  }
}
