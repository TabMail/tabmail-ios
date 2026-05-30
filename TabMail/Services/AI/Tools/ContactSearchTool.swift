/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Contacts

/// Client-side `contacts_search` tool matching TB addon's `contacts_search.js`.
/// Searches device contacts by name or email, returns formatted text with `contact_id`
/// for use by `contacts_edit` and `contacts_delete`.
struct ContactSearchTool: AgentTool, Sendable {
    let name = "contacts_search"

    private enum Config {
        static let defaultLimit = 25
        static let maxLimit = 50
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard case .string(let query) = arguments["query"],
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "missing query"}"#
        }

        var limit = Config.defaultLimit
        if case .int(let n) = arguments["limit"] { limit = n }
        else if case .double(let d) = arguments["limit"] { limit = Int(d) }
        else if case .string(let s) = arguments["limit"], let n = Int(s) { limit = n }
        limit = min(max(limit, 1), Config.maxLimit)

        guard await CNContactStoreHelper.requestAccess() else {
            return #"{"error": "contacts access not granted"}"#
        }

        let contacts: [CNContact]
        do {
            contacts = try CNContactStoreHelper.search(
                query: query.trimmingCharacters(in: .whitespaces),
                limit: limit
            )
        } catch {
            return ToolJSON.string(from: ["error": "search failed: \(error.localizedDescription)"])
        }

        if contacts.isEmpty {
            return "No contacts found matching '\(query.trimmingCharacters(in: .whitespaces))'."
        }

        // Format matching TB's output: name, email, first_name, last_name, nick_name, contact_id, addressbook_id
        let blocks: [String] = contacts.map { contact in
            let contactName = CNContactStoreHelper.displayName(contact)
            let primary = CNContactStoreHelper.primaryEmail(contact)
            let allEmails = contact.emailAddresses.map { $0.value as String }
            let otherEmails = allEmails.filter { $0.lowercased() != primary.lowercased() }
            let containerId = CNContactStoreHelper.containerIdentifier(forContactIdentifier: contact.identifier) ?? ""

            return [
                "name: \(contactName.isEmpty ? "(No name)" : contactName)",
                "email: \(primary)",
                "primary: \(primary)",
                "other_emails: \(otherEmails.joined(separator: ", "))",
                "first_name: \(contact.givenName)",
                "last_name: \(contact.familyName)",
                "nick_name: \(contact.nickname)",
                "contact_id: \(contact.identifier)",
                "addressbook_id: \(containerId)",
            ].joined(separator: "\n")
        }

        let result = blocks.joined(separator: "\n-----\n")
        print("[ContactSearchTool] Returning \(contacts.count) contacts for query='\(query)'")
        return result
    }
}
