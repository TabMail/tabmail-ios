/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Contacts

/// Client-side `contacts_add` tool matching TB addon's `contacts_add.js`.
/// Creates a new contact in the device's default address book.
struct ContactAddTool: AgentTool, Sendable {
    let name = "contacts_add"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let displayName = stringArg(arguments, "name")
        let email = stringArg(arguments, "email")
        let secondEmail = stringArg(arguments, "second_email")
        let firstName = stringArg(arguments, "first_name")
        let lastName = stringArg(arguments, "last_name")
        let nickname = stringArg(arguments, "nickname")
        let rawAddressbookId = stringArg(arguments, "addressbook_id")

        // LLM sends numeric IDs (translated by processToolOutputForLLM) — resolve back to real container ID
        let addressbookId: String
        if !rawAddressbookId.isEmpty, let numericId = Int(rawAddressbookId),
           let realId = await ctx.translator.toRealId(numericId) {
            addressbookId = realId
            print("[ContactAddTool] Resolved addressbook numeric id \(numericId) → \(realId.prefix(40))...")
        } else {
            addressbookId = rawAddressbookId
        }

        guard !displayName.isEmpty || !email.isEmpty || !firstName.isEmpty || !lastName.isEmpty else {
            return #"{"error": "Provide at least a name or an email to add a contact."}"#
        }

        guard await CNContactStoreHelper.requestAccess() else {
            return #"{"error": "contacts access not granted"}"#
        }

        let contact = CNMutableContact()
        if !firstName.isEmpty { contact.givenName = firstName }
        if !lastName.isEmpty { contact.familyName = lastName }
        if !nickname.isEmpty { contact.nickname = nickname }

        // If no first/last provided, split display name
        if firstName.isEmpty && lastName.isEmpty && !displayName.isEmpty {
            let parts = displayName.split(separator: " ", maxSplits: 1)
            contact.givenName = String(parts.first ?? "")
            if parts.count > 1 { contact.familyName = String(parts[1]) }
        }

        var emails: [CNLabeledValue<NSString>] = []
        if !email.isEmpty {
            emails.append(CNLabeledValue(label: CNLabelHome, value: email as NSString))
        }
        if !secondEmail.isEmpty {
            emails.append(CNLabeledValue(label: CNLabelOther, value: secondEmail as NSString))
        }
        if !emails.isEmpty {
            contact.emailAddresses = emails
        }

        do {
            try CNContactStoreHelper.addContact(contact, toContainerWithIdentifier: addressbookId.isEmpty ? nil : addressbookId)
            let contactName = CNContactStoreHelper.displayName(contact)
            let contactEmail = CNContactStoreHelper.primaryEmail(contact)
            let containerId = CNContactStoreHelper.containerIdentifier(forContactIdentifier: contact.identifier) ?? ""
            print("[ContactAddTool] Created contact: \(contact.givenName) \(contact.familyName) id=\(contact.identifier.prefix(20))")
            // Return contact_id so processToolOutputForLLM creates a numeric mapping for pills
            return [
                "Contact created successfully.",
                "name: \(contactName)",
                "email: \(contactEmail)",
                "contact_id: \(contact.identifier)",
                "addressbook_id: \(containerId)",
            ].joined(separator: "\n")
        } catch {
            return ToolJSON.string(from: ["error": "Failed to create contact: \(error.localizedDescription)"])
        }
    }

    private func stringArg(_ args: [String: JSONValue], _ key: String) -> String {
        if case .string(let s) = args[key] { return s.trimmingCharacters(in: .whitespaces) }
        return ""
    }
}
