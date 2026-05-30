/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Contacts

@MainActor
@Observable
final class ContactSearchService {
    private let store = CNContactStore()
    private var authorized = false
    /// In-memory snapshot of every contact that has at least one email. Built
    /// once on `requestAccess()` so search can do case-insensitive substring
    /// matching on names AND email local parts — `CNContact.predicateForContacts`
    /// supports only exact email match, which is why e.g. "jdoe2" used to
    /// miss "jdoe23@example.com".
    private var cache: [CachedContact] = []
    private var cacheLoaded = false

    private struct CachedContact: Sendable {
        let name: String
        let emails: [String]
    }

    func requestAccess() {
        // Skip in screenshot mode to avoid permission dialog on erased simulator
        guard !ScreenshotMode.isActive else { return }
        Task {
            authorized = (try? await store.requestAccess(for: .contacts)) ?? false
            if authorized { await loadCache() }
        }
    }

    private func loadCache() async {
        let loaded = await Task.detached { () -> [CachedContact] in
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]
            let req = CNContactFetchRequest(keysToFetch: keys)
            var out: [CachedContact] = []
            do {
                try store.enumerateContacts(with: req) { contact, _ in
                    let emails = contact.emailAddresses.map { $0.value as String }
                    guard !emails.isEmpty else { return }
                    let name = [contact.givenName, contact.familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    out.append(CachedContact(name: name, emails: emails))
                }
            } catch {
                return []
            }
            return out
        }.value
        self.cache = loaded
        self.cacheLoaded = true
    }

    func search(_ query: String) -> [ContactResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard authorized, !trimmed.isEmpty, cacheLoaded else { return [] }
        let terms = trimmed.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        var results: [ContactResult] = []
        var seenEmails: Set<String> = []
        for c in cache {
            let nameLower = c.name.lowercased()
            for email in c.emails {
                let emailLower = email.lowercased()
                // Every whitespace-separated term in the query must appear as a
                // case-insensitive substring in either the name or the email.
                let allMatch = terms.allSatisfy { term in
                    nameLower.contains(term) || emailLower.contains(term)
                }
                guard allMatch else { continue }
                guard seenEmails.insert(emailLower).inserted else { continue }
                results.append(ContactResult(name: c.name, email: email))
            }
        }
        return results
    }
}

struct ContactResult: Identifiable, Hashable {
    let name: String
    let email: String
    var id: String { email }

    var displayString: String {
        name.isEmpty ? email : "\(name) <\(email)>"
    }
}
