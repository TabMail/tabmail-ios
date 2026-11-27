/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

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
    /// The DISPLAY and sort date: when the receiving server accepted the
    /// message. IMAP `INTERNALDATE`, Graph `receivedDateTime`, and on Gmail
    /// the top `Received:` header's timestamp (see `providerDate`).
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
    /// The key the PROVIDER orders and windows by, when it differs from
    /// `date`. Gmail lists, pages, `after:`/`before:`-filters and history by
    /// `internalDate`, which is NOT the arrival time for Google-generated or
    /// Google-relayed mail — measured: a list message can carry an `internalDate`
    /// eight weeks before the day the mailbox accepted it. `date` therefore comes from
    /// the top `Received:` header while THIS carries `internalDate`, so sync
    /// arithmetic (stale windows, backfill cutoffs) keeps using the provider's
    /// own order. Nil means "same as `date`" — true for IMAP and Graph, whose
    /// receipt field IS their order key.
    var providerDate: Date? = nil
}

struct EmailAddress: Sendable, Equatable {
    let name: String
    let email: String

    init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// The sender a message is listed under: the first mailbox of its From
    /// field, by display name (its address when it has none). A From with no
    /// valid mailbox is listed under its text with no address, so a malformed
    /// sender still shows what the sender wrote. `nil` for a message with no From.
    ///
    /// IMAP gets the entries from SwiftMail's parse of the server's ENVELOPE
    /// (`MessageInfo.fromAddresses`, never by re-parsing its `from` string,
    /// which is header text that joins every author); Gmail and raw RFC 5322
    /// headers parse the field value with `AddressParser.parseAddressList`.
    /// That parser reads the whole field's structure first (quoted-strings,
    /// comments, angle-addrs, list commas) and decodes an encoded-word only as a
    /// display-name word after that, so no text inside a name, quoted or encoded,
    /// is ever read as an address or as a list separator.
    static func sender(of entries: [AddressListEntry]) -> EmailAddress? {
        if let mailbox = entries.mailboxes.first {
            return EmailAddress(name: mailbox.name ?? mailbox.address, email: mailbox.address)
        }
        let text = entries.compactMap { entry -> String? in
            switch entry {
                case .invalid(let text): return text
                case .group(let name, _): return name
                case .mailbox: return nil
            }
        }.joined(separator: ", ")
        return text.isEmpty ? nil : EmailAddress(name: text, email: "")
    }

    /// Every mailbox of an address field, in order, by display name (its
    /// address when it has none). A group contributes its members.
    static func mailboxes(of entries: [AddressListEntry]) -> [EmailAddress] {
        entries.mailboxes.map { EmailAddress(name: $0.name ?? $0.address, email: $0.address) }
    }
}
