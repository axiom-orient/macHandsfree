import MacHandsfreeCore

enum ContactsPostSaveOutcomePolicy {
  static func failure(_ error: any Error, contactID: String) -> AgentError {
    if let agentError = error as? AgentError, agentError.outcomeUncertain {
      return agentError
    }

    var details: [String: JSONValue] = ["contact_id": .string(contactID)]
    if let agentError = error as? AgentError {
      details["original_code"] = .string(agentError.code)
    } else {
      details["original_error"] = .string(String(describing: error))
    }
    return AgentError(
      code: "contacts_post_save_read_failed",
      message: "Contacts saved the mutation, but could not read back the resulting contact",
      details: details,
      exitCode: 5,
      outcomeUncertain: true
    )
  }
}

enum ContactsMutationSnapshotGuard {
  static func expectedContact(
    commandID: String,
    object: [String: JSONValue],
    preview: JSONValue
  ) throws -> JSONValue? {
    guard preview["guard_version"]?.intValue == 1,
      let plannedEffects = preview["effects"]?.arrayValue,
      plannedEffects.count == 1,
      plannedEffects[0]["action"]?.stringValue == commandID
    else {
      throw AgentError(
        code: "plan_state_changed",
        message: "The Contacts plan does not include a current target guard",
        details: ["command": .string(commandID), "reason_code": .string("plan_guard_missing")],
        exitCode: 6
      )
    }

    guard commandID == "contacts.items.update" || commandID == "contacts.items.delete" else {
      guard commandID == "contacts.items.create" else {
        throw AgentError(
          code: "unsupported_contacts_command",
          message: "Contacts service does not support command",
          details: ["command": .string(commandID)],
          exitCode: 5
        )
      }
      return nil
    }

    let contactID = try object.requiredString("contact_id")
    guard let expected = plannedEffects[0]["details"]?["contact"],
      expected["id"]?.stringValue == contactID
    else {
      throw AgentError(
        code: "plan_preview_invalid",
        message: "The Contacts plan does not contain the selected contact snapshot",
        details: ["command": .string(commandID), "contact_id": .string(contactID)],
        exitCode: 5
      )
    }
    return expected
  }

  static func validate(expected: JSONValue, actual: JSONValue, contactID: String) throws {
    guard expected == actual else {
      throw AgentError(
        code: "plan_state_changed",
        message: "The Contacts record changed after the plan was prepared",
        details: ["contact_id": .string(contactID)],
        exitCode: 6
      )
    }
  }
}
