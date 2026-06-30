/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Provider-agnostic message header returned by shared API/command layers.
/// Main app converts to `MessageHeaderInfo` at the boundary; NSE converts to its
/// staging-DB row shape. Body content is not part of this — see `RenderedBody`.
struct MessageMetadata: Sendable {
    let providerMessageId: String       // Gmail msg id / Graph msg id / IMAP UID as String
    let threadId: String?
    let rfc822MessageId: String?        // normalized, no angle brackets
    let inReplyTo: String?              // normalized
    let references: [String]            // normalized, oldest→newest
    let from: EmailAddress
    let to: [EmailAddress]
    let cc: [EmailAddress]
    let bcc: [EmailAddress]
    let replyTo: EmailAddress?
    let subject: String
    let date: Date
    let snippet: String
    let isRead: Bool
    let isFlagged: Bool
    let hasAttachments: Bool
    /// Gmail labelIds / Graph categories / IMAP keywords.
    /// tm_* tag detection happens in main app at merge time.
    let providerLabels: [String]
    /// Provider-canonical folder path. The exact shape matches what the
    /// main-app sync stores in `MessageHeader.folderPath` so NSE-inserted
    /// rows share an id with sync-inserted rows for the same message:
    ///   - Gmail: a label name, typically `"INBOX"` for pushed arrivals.
    ///   - Graph (Outlook): the opaque folder ID from `parentFolderId`.
    ///   - IMAP: the mailbox path (future).
    /// Optional only because legacy Gmail paths that don't parse it default
    /// to `"INBOX"` at the boundary. NSE callers should pass a value.
    let folderPath: String?
}

struct EmailAddress: Sendable, Equatable {
    let name: String
    let email: String

    init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// Parse "John Smith <john@example.com>" or bare "john@example.com".
    static func parse(_ raw: String) -> EmailAddress {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return EmailAddress(name: "", email: "") }
        // Search for the closing `>` only AFTER the opening `<`. A bare
        // `firstIndex(of: ">")` matches a `>` that appears earlier — e.g. inside
        // a quoted display name like `"a@b.com >> Name" <a@b.com>` — yielding
        // angleEnd < angleStart and a `lowerBound > upperBound` range crash.
        // Mirrors the safe idiom in EmailFilter.extractFirstMessageId.
        if let angleStart = trimmed.firstIndex(of: "<"),
           let angleEnd = trimmed[trimmed.index(after: angleStart)...].firstIndex(of: ">") {
            let name = String(trimmed[trimmed.startIndex..<angleStart])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let email = String(trimmed[trimmed.index(after: angleStart)..<angleEnd])
                .trimmingCharacters(in: .whitespaces)
            return EmailAddress(name: name.isEmpty ? email : name, email: email)
        }
        return EmailAddress(name: trimmed, email: trimmed)
    }
}
