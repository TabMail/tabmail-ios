/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Contacts

/// Client-side `contacts_edit` tool matching TB addon's `contacts_edit.js`.
/// Edits an existing contact by `contact_id`. Shows confirmation card before executing
/// (iOS-specific — TB edits without confirmation). Follows ADR-IOS-024.
struct ContactEditTool: AgentTool, Sendable {
    let name = "contacts_edit"
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
            print("[ContactEditTool] Resolved numeric id \(numericId) → \(realId.prefix(40))...")
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

        // Build human-readable change descriptions for the confirmation card
        var changes: [String] = []
        if let v = stringArgOpt(arguments, "first_name"), v != existing.givenName {
            changes.append("first name → \(v)")
        }
        if let v = stringArgOpt(arguments, "last_name"), v != existing.familyName {
            changes.append("last name → \(v)")
        }
        if let v = stringArgOpt(arguments, "name"), stringArgOpt(arguments, "first_name") == nil, stringArgOpt(arguments, "last_name") == nil {
            changes.append("name → \(v)")
        }
        if let v = stringArgOpt(arguments, "nickname"), v != existing.nickname {
            changes.append("nickname → \(v)")
        }
        if let v = stringArgOpt(arguments, "email"), v.lowercased() != contactEmail.lowercased() {
            changes.append("email → \(v)")
        }
        if case .array(let arr) = arguments["other_emails"] {
            let emails = arr.compactMap { v -> String? in
                if case .string(let s) = v { return s.trimmingCharacters(in: .whitespaces) }
                return nil
            }.filter { !$0.isEmpty }
            if !emails.isEmpty {
                changes.append("other emails → \(emails.joined(separator: ", "))")
            }
        }

        // ADR-IOS-024: Show confirmation card and await user response
        let (confirmed, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .contactEdit,
            contacts: [.init(
                contactId: contactId,
                name: contactName.isEmpty ? "(No name)" : contactName,
                email: contactEmail,
                changes: changes
            )],
            via: invocation.uiSink
        )

        guard confirmed else {
            print("[ContactEditTool] User declined edit for contact_id=\(contactId)")
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to edit this contact.",
            ] as [String: Any]))
        }

        // Re-fetch to get latest version (contact may have been modified during confirmation wait)
        let fresh: CNContact
        do {
            fresh = try CNContactStoreHelper.fetchContact(identifier: contactId)
        } catch {
            return ToolJSON.string(from: ["error": "contact no longer exists: \(error.localizedDescription)"])
        }

        // Merge fields onto mutable copy (matching TB's merge semantics — preserve unmodified)
        let mutable = fresh.mutableCopy() as! CNMutableContact

        if let v = stringArgOpt(arguments, "first_name") { mutable.givenName = v }
        if let v = stringArgOpt(arguments, "last_name") { mutable.familyName = v }
        if let v = stringArgOpt(arguments, "nickname") { mutable.nickname = v }

        // Handle display name → first/last split if name arg provided but not first/last
        if let displayName = stringArgOpt(arguments, "name"),
           stringArgOpt(arguments, "first_name") == nil,
           stringArgOpt(arguments, "last_name") == nil {
            let parts = displayName.split(separator: " ", maxSplits: 1)
            mutable.givenName = String(parts.first ?? "")
            mutable.familyName = parts.count > 1 ? String(parts[1]) : ""
        }

        // Handle email changes — primary and other_emails are independent (matching TB)
        var emailsModified = false
        var emails = Array(mutable.emailAddresses)
        if let newEmail = stringArgOpt(arguments, "email") {
            emailsModified = true
            if emails.isEmpty {
                emails.append(CNLabeledValue(label: CNLabelHome, value: newEmail as NSString))
            } else {
                emails[0] = CNLabeledValue(label: emails[0].label, value: newEmail as NSString)
            }
        }
        if case .array(let arr) = arguments["other_emails"] {
            emailsModified = true
            // Dedup against primary and within the array itself (matching TB)
            var seen = Set<String>()
            if let primaryLower = (emails.first?.value as String?)?.lowercased(), !primaryLower.isEmpty {
                seen.insert(primaryLower)
            }
            let others = arr.compactMap { v -> String? in
                if case .string(let s) = v { return s.trimmingCharacters(in: .whitespaces) }
                return nil
            }.filter {
                let lower = $0.lowercased()
                guard !lower.isEmpty, !seen.contains(lower) else { return false }
                seen.insert(lower)
                return true
            }
            let primary = emails.first
            emails = primary.map { [$0] } ?? []
            for other in others {
                emails.append(CNLabeledValue(label: CNLabelOther, value: other as NSString))
            }
        }
        if emailsModified {
            mutable.emailAddresses = emails
        }

        do {
            try CNContactStoreHelper.updateContact(mutable)
            let updatedName = CNContactStoreHelper.displayName(mutable as CNContact)
            print("[ContactEditTool] Updated contact_id=\(contactId)")
            // Return contact_id so processToolOutputForLLM keeps the numeric mapping fresh
            return [
                "Contact updated successfully.",
                "name: \(updatedName)",
                "contact_id: \(contactId)",
            ].joined(separator: "\n")
        } catch {
            return ToolJSON.string(from: ["error": "Failed to update: \(error.localizedDescription)"])
        }
    }

    private func stringArgOpt(_ args: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s) = args[key] { return s.trimmingCharacters(in: .whitespaces) }
        return nil
    }
}
