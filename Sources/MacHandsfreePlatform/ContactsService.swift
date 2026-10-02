import Foundation
import MacHandsfreeCore

#if os(macOS)
  import Contacts
  import Security
#endif

actor ContactsService: CurrentStateValidatedCommandService {
  let name = "contacts"
  private let permissions: any PermissionAuthorizing
  #if os(macOS)
    private lazy var store = CNContactStore()
  #endif

  init(permissions: any PermissionAuthorizing = MacOSPermissionAdapter()) {
    self.permissions = permissions
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      let object = try input.requiredObject()
      guard command.kind == .mutation else {
        throw AgentError(
          code: "invalid_mutation_route",
          message: "Only Contacts mutations can be prepared",
          details: ["command": .string(command.id)],
          exitCode: 5
        )
      }
      try await authorize()
      switch command.id {
      case "contacts.items.create":
        try requireNoteEntitlementIfNeeded(object)
        return mutationPreview(
          command: command,
          object: object,
          target: contactLabel(object)
        )
      case "contacts.items.update", "contacts.items.delete":
        try requireNoteEntitlementIfNeeded(object)
        let contact = try exactContact(try object.requiredString("contact_id"))
        return mutationPreview(
          command: command,
          object: object,
          target: contactLabel(contact),
          contact: try contactSnapshot(contact, commandID: command.id, input: object)
        )
      default:
        throw AgentError(
          code: "invalid_mutation_route",
          message: "Only Contacts mutations can be prepared",
          details: ["command": .string(command.id)],
          exitCode: 5
        )
      }
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    #if os(macOS)
      guard command.kind == .read else {
        throw AgentError(
          code: "invalid_mutation_route",
          message: "Contacts mutations require a state-validated plan",
          details: ["command": .string(command.id)],
          exitCode: 5
        )
      }
      try await authorize()
      let object = try input.requiredObject()
      switch command.id {
      case "contacts.items.list": return try list(object)
      case "contacts.items.get":
        return .object([
          "contact": contactJSON(try exactContact(try object.requiredString("contact_id")))
        ])
      case "contacts.items.search": return try search(object)
      case "contacts.groups.list": return try groups()
      default:
        throw AgentError(
          code: "invalid_mutation_route",
          message: "Contacts mutations require a state-validated plan",
          details: ["command": .string(command.id)],
          exitCode: 5
        )
      }
    #else
      _ = input
      throw AgentError.unsupported(command.id)
    #endif
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    #if os(macOS)
      guard command.kind == .mutation else {
        throw AgentError(
          code: "invalid_mutation_route",
          message: "A Contacts read command cannot use mutation execution",
          details: ["command": .string(command.id)],
          exitCode: 5
        )
      }
      let object = try input.requiredObject()
      let expectedContact = try ContactsMutationSnapshotGuard.expectedContact(
        commandID: command.id,
        object: object,
        preview: plannedPreview
      )
      try await authorize()
      try Task.checkCancellation()
      switch command.id {
      case "contacts.items.create": return try create(object)
      case "contacts.items.update": return try update(object, expectedContact: expectedContact)
      case "contacts.items.delete": return try delete(object, expectedContact: expectedContact)
      default:
        throw AgentError(
          code: "unsupported_contacts_command",
          message: "Contacts service does not support command",
          details: ["command": .string(command.id)],
          exitCode: 5
        )
      }
    #else
      _ = input
      _ = plannedPreview
      throw AgentError.unsupported(command.id)
    #endif
  }

  private func mutationPreview(
    command: CommandSpec,
    object: [String: JSONValue],
    target: String,
    contact: JSONValue? = nil
  ) -> JSONValue {
    var details = object
    details.removeValue(forKey: "contact_id")
    if let contact { details["contact"] = contact }
    var preview = effects([effect(command.id, target, details: details)]).objectValue ?? [:]
    preview["guard_version"] = .integer(1)
    return .object(preview)
  }

  #if os(macOS)
    private func contactLabel(_ object: [String: JSONValue]) -> String {
      let name = [object["given_name"]?.stringValue, object["family_name"]?.stringValue]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      if !name.isEmpty { return name }
      if let organization = object["organization"]?.stringValue, !organization.isEmpty {
        return organization
      }
      return "new contact"
    }

    private func contactLabel(_ contact: CNContact) -> String {
      if let name = CNContactFormatter.string(from: contact, style: .fullName), !name.isEmpty {
        return name
      }
      if !contact.organizationName.isEmpty { return contact.organizationName }
      return contact.identifier
    }
  #endif

  #if os(macOS)
    private var canAccessNotes: Bool {
      guard let task = SecTaskCreateFromSelf(nil),
        let value = SecTaskCopyValueForEntitlement(
          task,
          "com.apple.developer.contacts.notes" as CFString,
          nil
        )
      else {
        return false
      }
      return (value as? Bool) == true
    }

    private var keys: [any CNKeyDescriptor] {
      var values: [any CNKeyDescriptor] = [
        CNContactIdentifierKey as any CNKeyDescriptor,
        CNContactGivenNameKey as any CNKeyDescriptor,
        CNContactFamilyNameKey as any CNKeyDescriptor,
        CNContactOrganizationNameKey as any CNKeyDescriptor,
        CNContactJobTitleKey as any CNKeyDescriptor,
        CNContactEmailAddressesKey as any CNKeyDescriptor,
        CNContactPhoneNumbersKey as any CNKeyDescriptor,
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
      ]
      if canAccessNotes {
        values.append(CNContactNoteKey as any CNKeyDescriptor)
      }
      return values
    }

    private func authorize() async throws {
      let status: PermissionAuthorization
      do {
        status = try await permissions.requestAccessIfNeeded(for: .contacts)
      } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        let current = await permissions.status(for: .contacts)
        try Task.checkCancellation()
        throw contactsPermissionError(for: current)
      }
      try Task.checkCancellation()
      guard status.isGranted else { throw contactsPermissionError(for: status) }
    }

    private func contactsPermissionError(for status: PermissionAuthorization) -> AgentError {
      if status == .notDetermined {
        return AgentError(
          code: "contacts_permission_required",
          message: "Contacts access still requires user approval",
          exitCode: 3
        )
      }
      return AgentError(
        code: "contacts_permission_denied",
        message: "Contacts access is required",
        exitCode: 3
      )
    }

    private func contactJSON(_ contact: CNContact) -> JSONValue {
      let noteAvailable = contact.isKeyAvailable(CNContactNoteKey)
      return .object([
        "id": .string(contact.identifier),
        "given_name": .string(contact.givenName),
        "family_name": .string(contact.familyName),
        "organization": .string(contact.organizationName),
        "job_title": .string(contact.jobTitle),
        "emails": .array(
          contact.emailAddresses.map {
            .object([
              "label": $0.label.map(JSONValue.string) ?? .null,
              "value": .string($0.value as String),
            ])
          }),
        "phones": .array(
          contact.phoneNumbers.map {
            .object([
              "label": $0.label.map(JSONValue.string) ?? .null,
              "value": .string($0.value.stringValue),
            ])
          }),
        "note": noteAvailable ? .string(contact.note) : .null,
        "note_available": .bool(noteAvailable),
      ])
    }

    private func contactSnapshot(
      _ contact: CNContact,
      commandID: String,
      input: [String: JSONValue]
    ) throws -> JSONValue {
      let current = contactJSON(contact).objectValue ?? [:]
      var projection: [String: JSONValue] = [:]
      for key in ["id", "given_name", "family_name", "organization", "emails", "phones"] {
        if let value = current[key] { projection[key] = value }
      }
      if commandID == "contacts.items.update" {
        for key in ["job_title", "note"] where input[key] != nil {
          if key == "note" { try requireNoteEntitlementIfNeeded(input) }
          if let value = current[key] { projection[key] = value }
        }
      }
      let snapshot = JSONValue.object(projection)
      guard try snapshot.encoded().count <= 256 * 1_024 else {
        throw AgentError(
          code: "contacts_snapshot_too_large",
          message: "The Contacts snapshot is too large to include in an approval plan",
          details: ["contact_id": .string(contact.identifier)],
          exitCode: 5
        )
      }
      return snapshot
    }

    private func requireNoteEntitlementIfNeeded(_ object: [String: JSONValue]) throws {
      guard object["note"] != nil, !canAccessNotes else { return }
      throw AgentError(
        code: "contacts_note_entitlement_required",
        message: "Contact notes require the com.apple.developer.contacts.notes entitlement",
        exitCode: 3
      )
    }

    private func exactContact(_ id: String) throws -> CNContact {
      do {
        return try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
      } catch {
        throw AgentError(
          code: "contact_not_found",
          message: "Contact identifier was not found",
          details: ["contact_id": .string(id)],
          exitCode: 5
        )
      }
    }

    private func list(_ object: [String: JSONValue]) throws -> JSONValue {
      let limit = object.optionalInt("limit", default: 100) ?? 100
      let request = CNContactFetchRequest(keysToFetch: keys)
      request.sortOrder = .userDefault
      if let containerID = object.optionalString("container_id") {
        try requireContainer(containerID)
        request.predicate = CNContact.predicateForContactsInContainer(
          withIdentifier: containerID
        )
      }

      var contacts: [CNContact] = []
      try store.enumerateContacts(with: request) { contact, stop in
        contacts.append(contact)
        if contacts.count > limit { stop.pointee = true }
      }
      return .object([
        "contacts": .array(contacts.prefix(limit).map(contactJSON)),
        "truncated": .bool(contacts.count > limit),
      ])
    }

    private func search(_ object: [String: JSONValue]) throws -> JSONValue {
      let query = try object.requiredString("query")
      let predicate = CNContact.predicateForContacts(matchingName: query)
      let limit = object.optionalInt("limit", default: 100) ?? 100
      let request = CNContactFetchRequest(keysToFetch: keys)
      request.predicate = predicate
      request.unifyResults = true
      var matches = BoundedReadSelection<ContactSearchCandidate>(
        limit: limit, by: ContactSearchCandidate.precedes)
      try store.enumerateContacts(with: request) { contact, _ in
        matches.insert(ContactSearchCandidate(contact))
      }
      return .object([
        "contacts": .array(matches.page.map { contactJSON($0.contact) }),
        "truncated": .bool(matches.truncated),
      ])
    }

    private func create(_ object: [String: JSONValue]) throws -> JSONValue {
      let contact = CNMutableContact()
      try apply(object, to: contact)
      let request = CNSaveRequest()
      request.add(contact, toContainerWithIdentifier: nil)
      try store.execute(request)
      return try savedContactResult(contact.identifier)
    }

    private func update(
      _ object: [String: JSONValue],
      expectedContact: JSONValue?
    ) throws -> JSONValue {
      let original = try exactContact(object.requiredString("contact_id"))
      try validateCurrentContact(
        original,
        expected: expectedContact,
        commandID: "contacts.items.update",
        input: object
      )
      guard let contact = original.mutableCopy() as? CNMutableContact else {
        throw AgentError(
          code: "contact_copy_failed",
          message: "Could not create mutable contact",
          exitCode: 5
        )
      }
      try apply(object, to: contact)
      let request = CNSaveRequest()
      request.update(contact)
      try store.execute(request)
      return try savedContactResult(contact.identifier)
    }

    private func savedContactResult(_ contactID: String) throws -> JSONValue {
      do {
        return .object(["contact": contactJSON(try exactContact(contactID))])
      } catch {
        throw ContactsPostSaveOutcomePolicy.failure(error, contactID: contactID)
      }
    }

    private func delete(
      _ object: [String: JSONValue],
      expectedContact: JSONValue?
    ) throws -> JSONValue {
      let id = try object.requiredString("contact_id")
      let original = try exactContact(id)
      try validateCurrentContact(
        original,
        expected: expectedContact,
        commandID: "contacts.items.delete",
        input: object
      )
      guard let contact = original.mutableCopy() as? CNMutableContact else {
        throw AgentError(
          code: "contact_copy_failed",
          message: "Could not create mutable contact",
          exitCode: 5
        )
      }
      let request = CNSaveRequest()
      request.delete(contact)
      try store.execute(request)
      return .object(["deleted": .bool(true), "contact_id": .string(id)])
    }

    private func validateCurrentContact(
      _ contact: CNContact,
      expected: JSONValue?,
      commandID: String,
      input: [String: JSONValue]
    ) throws {
      guard let expected else {
        throw AgentError(
          code: "plan_preview_invalid",
          message: "The Contacts mutation is missing its approved contact snapshot",
          details: ["contact_id": .string(contact.identifier)],
          exitCode: 5
        )
      }
      try ContactsMutationSnapshotGuard.validate(
        expected: expected,
        actual: try contactSnapshot(contact, commandID: commandID, input: input),
        contactID: contact.identifier
      )
    }

    private func apply(_ object: [String: JSONValue], to contact: CNMutableContact) throws {
      if let value = object.optionalString("given_name") { contact.givenName = value }
      if let value = object.optionalString("family_name") { contact.familyName = value }
      if let value = object.optionalString("organization") { contact.organizationName = value }
      if let value = object.optionalString("job_title") { contact.jobTitle = value }
      if let note = object["note"] {
        try requireNoteEntitlementIfNeeded(object)
        switch note {
        case .null: contact.note = ""
        case .string(let value): contact.note = value
        default: throw AgentError.invalid("note must be a string or null")
        }
      }
      if let values = object["emails"]?.arrayValue {
        contact.emailAddresses = values.compactMap { item in
          guard let data = item.objectValue, let value = data["value"]?.stringValue else {
            return nil
          }
          return CNLabeledValue(
            label: data["label"]?.stringValue,
            value: value as NSString
          )
        }
      }
      if let values = object["phones"]?.arrayValue {
        contact.phoneNumbers = values.compactMap { item in
          guard let data = item.objectValue, let value = data["value"]?.stringValue else {
            return nil
          }
          return CNLabeledValue(
            label: data["label"]?.stringValue,
            value: CNPhoneNumber(stringValue: value)
          )
        }
      }
    }

    private func groups() throws -> JSONValue {
      let groups = try store.groups(matching: nil).sorted {
        if $0.name == $1.name { return $0.identifier < $1.identifier }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      return .object([
        "groups": .array(
          groups.map { .object(["id": .string($0.identifier), "name": .string($0.name)]) })
      ])
    }

    private func requireContainer(_ id: String) throws {
      let predicate = CNContainer.predicateForContainers(withIdentifiers: [id])
      guard try store.containers(matching: predicate).count == 1 else {
        throw AgentError(
          code: "contacts_container_not_found",
          message: "Contacts container identifier was not found",
          details: ["container_id": .string(id)],
          exitCode: 5
        )
      }
    }

    private struct ContactSearchCandidate {
      let contact: CNContact
      private let fullName: String
      private let identifier: String

      init(_ contact: CNContact) {
        self.contact = contact
        fullName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        identifier = contact.identifier
      }

      static func precedes(_ left: Self, _ right: Self) -> Bool {
        let comparison = left.fullName.localizedStandardCompare(right.fullName)
        if comparison == .orderedSame { return left.identifier < right.identifier }
        return comparison == .orderedAscending
      }
    }
  #endif
}
