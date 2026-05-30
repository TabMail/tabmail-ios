/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import Contacts

/// Stateless helper wrapping `CNContactStore` CRUD operations for agent tools.
/// Each method creates a local `CNContactStore()` instance — thread-safe per Apple docs,
/// no stored state needed. The enum is inherently `Sendable`.
///
/// Does NOT replace `ContactSearchService` (which serves compose autocomplete).
enum CNContactStoreHelper {
    /// UserDefaults key for the user's preferred contact container identifier.
    /// `nil` / empty = use iOS default container (Settings → Contacts → Default Account).
    static let preferredContainerKey = "contacts_preferred_container_id"

    private static let searchKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    private static let editKeys: [CNKeyDescriptor] = searchKeys + [
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]

    static func requestAccess() async -> Bool {
        let store = CNContactStore()
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            print("[CNContactStoreHelper] requestAccess failed: \(error)")
            return false
        }
    }

    /// Search contacts by name and email, deduplicated, sorted by name length (matching TB).
    /// Filters out contacts with no email addresses (matching TB behavior).
    static func search(query: String, limit: Int = 25) throws -> [CNContact] {
        let store = CNContactStore()
        var contacts: [CNContact] = []
        var seen = Set<String>()

        // Search by name
        let byName = try store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: query),
            keysToFetch: searchKeys
        )
        for c in byName where !seen.contains(c.identifier) && !c.emailAddresses.isEmpty {
            seen.insert(c.identifier)
            contacts.append(c)
        }

        // Search by email (exact match API)
        // This may throw if query is not a valid email format — that's OK, name search above
        // already captured results. Catch and ignore only this secondary search.
        if let byEmail = try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingEmailAddress: query),
            keysToFetch: searchKeys
        ) {
            for c in byEmail where !seen.contains(c.identifier) && !c.emailAddresses.isEmpty {
                seen.insert(c.identifier)
                contacts.append(c)
            }
        }

        // Sort by name length descending (prefer longer/more complete names, matching TB)
        contacts.sort { displayName($0).count > displayName($1).count }
        return Array(contacts.prefix(limit))
    }

    /// Fetch a single contact by identifier (for edit/delete).
    static func fetchContact(identifier: String) throws -> CNContact {
        let store = CNContactStore()
        return try store.unifiedContact(
            withIdentifier: identifier,
            keysToFetch: editKeys
        )
    }

    static func addContact(_ contact: CNMutableContact, toContainerWithIdentifier explicitContainerId: String? = nil) throws {
        let store = CNContactStore()
        let request = CNSaveRequest()

        // Priority: explicit param (from tool) → user preference → system default
        let resolvedId: String?
        if let explicitContainerId, !explicitContainerId.isEmpty {
            resolvedId = explicitContainerId
        } else {
            let preferred = UserDefaults.standard.string(forKey: preferredContainerKey)
            resolvedId = (preferred?.isEmpty == false) ? preferred : nil
        }

        // Validate container still exists; fall back to system default if stale.
        if let resolvedId {
            let exists = (try? store.containers(matching: CNContainer.predicateForContainers(withIdentifiers: [resolvedId])))?.isEmpty == false
            if !exists {
                print("[CNContactStoreHelper] Container \(resolvedId) no longer exists — falling back to default")
                if explicitContainerId == nil {
                    UserDefaults.standard.removeObject(forKey: preferredContainerKey)
                }
                request.add(contact, toContainerWithIdentifier: nil)
                try store.execute(request)
                return
            }
        }
        request.add(contact, toContainerWithIdentifier: resolvedId)
        try store.execute(request)
    }

    static func updateContact(_ contact: CNMutableContact) throws {
        let store = CNContactStore()
        let request = CNSaveRequest()
        request.update(contact)
        try store.execute(request)
    }

    static func deleteContact(_ contact: CNMutableContact) throws {
        let store = CNContactStore()
        let request = CNSaveRequest()
        request.delete(contact)
        try store.execute(request)
    }

    static func displayName(_ contact: CNContact) -> String {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? contact.nickname : name
    }

    static func primaryEmail(_ contact: CNContact) -> String {
        (contact.emailAddresses.first?.value as String?) ?? ""
    }

    /// Look up the container identifier for a contact.
    /// Returns nil if not found (e.g., contact not in any known container).
    static func containerIdentifier(forContactIdentifier contactId: String) -> String? {
        let store = CNContactStore()
        let predicate = CNContainer.predicateForContainerOfContact(withIdentifier: contactId)
        do {
            let containers = try store.containers(matching: predicate)
            return containers.first?.identifier
        } catch {
            print("[CNContactStoreHelper] containerIdentifier lookup failed: \(error)")
            return nil
        }
    }

    // MARK: - Container Enumeration

    struct ContactContainer: Identifiable, Sendable {
        let id: String           // CNContainer.identifier
        let name: String         // CNContainer.name
        let type: CNContainerType
        let isDefault: Bool

        var typeLabel: String {
            switch type {
            case .local: return "Local"
            case .exchange: return "Exchange"
            case .cardDAV: return "CardDAV"
            case .unassigned: return "Unassigned"
            @unknown default: return "Other"
            }
        }

        var displayName: String {
            name.isEmpty ? typeLabel : name
        }
    }

    /// List all available contact containers with their display names and types.
    static func availableContainers() throws -> [ContactContainer] {
        let store = CNContactStore()
        let defaultId = store.defaultContainerIdentifier()
        let containers = try store.containers(matching: nil)
        return containers.map { c in
            ContactContainer(
                id: c.identifier,
                name: c.name,
                type: c.type,
                isDefault: c.identifier == defaultId
            )
        }
    }
}
