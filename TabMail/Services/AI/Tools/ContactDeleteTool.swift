/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Contacts

/// Client-side `contacts_delete` tool matching TB addon's `contacts_delete.js`.
/// Deletes a contact by `contact_id` after user confirmation. Follows ADR-IOS-024.
struct ContactDeleteTool: AgentTool, Sendable {
    let name = "contacts_delete"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments, invocation: .noninteractive)
    }

    /// ADR-IOS-053: real entry point — delivers the confirmation card to the
    /// invoking session via `invocation.uiSink` (nil sink → declined fast-fail).
    func execute(arguments: [String: JSONValue], invocation: ToolInvocation) async throws -> String {
        // Demo boundary (ADR-IOS-038): device contacts / real app settings
        // are outside the demo sandbox — block with a relayable error.
        if DemoModeStore.isDemoActive { return DemoToolGuard.blockedMessage }
        guard case .string(let rawContactId) = arguments["contact_id"],
              !rawContactId.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "missing contact_id — use contacts_search to look up the contact first"}"#
        }

        // LLM sends numeric IDs (translated by processToolOutputForLLM) — resolve back to real contact ID
        let contactId: String
        if let numericId = Int(rawContactId), let realId = await ctx.translator.toRealId(numericId) {
            contactId = realId
            print("[ContactDeleteTool] Resolved numeric id \(numericId) → \(realId.prefix(40))...")
        } else {
            contactId = rawContactId.trimmingCharacters(in: .whitespaces)
        }

        guard await CNContactStoreHelper.requestAccess() else {
            return #"{"error": "contacts access not granted"}"#
        }

        let existing: CNContact
        do {
            existing = try CNContactStoreHelper.fetchContact(identifier: contactId)
        } catch {
            return ToolJSON.string(from: ["error": "contact not found: \(error.localizedDescription)"])
        }

        let contactName = CNContactStoreHelper.displayName(existing)
        let contactEmail = CNContactStoreHelper.primaryEmail(existing)

        // ADR-IOS-024: Show confirmation card and await user response
        let (confirmed, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .contactDelete,
            contacts: [.init(
                contactId: contactId,
                name: contactName.isEmpty ? "(No name)" : contactName,
                email: contactEmail
            )],
            via: invocation.uiSink
        )

        guard confirmed else {
            print("[ContactDeleteTool] User declined delete for contact_id=\(contactId)")
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to delete this contact.",
            ] as [String: Any]))
        }

        // Re-fetch to get latest version (contact may have been deleted during confirmation wait)
        let fresh: CNContact
        do {
            fresh = try CNContactStoreHelper.fetchContact(identifier: contactId)
        } catch {
            return ToolJSON.string(from: ["error": "contact no longer exists: \(error.localizedDescription)"])
        }

        let mutable = fresh.mutableCopy() as! CNMutableContact
        do {
            try CNContactStoreHelper.deleteContact(mutable)
            print("[ContactDeleteTool] Deleted contact_id=\(contactId)")
            // Return contact_id so processToolOutputForLLM keeps the numeric mapping
            return [
                "Contact deleted successfully.",
                "contact_id: \(contactId)",
            ].joined(separator: "\n")
        } catch {
            return ToolJSON.string(from: ["error": "Failed to delete: \(error.localizedDescription)"])
        }
    }
}
