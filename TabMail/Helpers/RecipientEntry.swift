/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

/// Recipient text split into the addresses it names (ADR-IOS-092). A compose
/// field holds a list of addresses, never free text: whatever fills it (typing,
/// a paste, a contact, a mailto link, the AI, a reopened draft, a reply) goes
/// through here, so "a@example.com, b@example.com" becomes two recipients.
/// Text that names no address TabMail can send to never becomes a recipient;
/// it is kept, as written, as one of the field's rejected entries.
struct RecipientEntry: Equatable, Sendable {
    struct Recipient: Equatable, Sendable {
        let address: String
        let name: String?
    }

    private(set) var recipients: [Recipient] = []
    /// The entries that name no sendable address, each exactly as it was
    /// written (only the whitespace around it trimmed).
    private(set) var leftovers: [String] = []

    /// Splits each text into entries first, and only then reads each entry
    /// with SwiftMail's address-list parser, the parser every send uses. An
    /// entry becomes recipients only when everything in it is a mailbox
    /// TabMail can send to (a group contributes its members). Any other entry,
    /// such as the empty group `undisclosed-recipients:;`, a lone comment, or a
    /// mailbox at `localhost`, is kept as the text that was written, never as
    /// a decoded or rewritten form of it, so nothing typed silently disappears
    /// and kept text never reads as an address later. An address already
    /// listed (in any case) is not repeated.
    init(_ texts: [String]) {
        var seen = Set<String>()
        for text in texts {
            for piece in Self.entries(text) {
                let written = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !written.isEmpty else { continue }
                var mailboxes: [SwiftMail.EmailAddress] = []
                var readable = true
                for entry in AddressParser.parseAddressList(piece) {
                    switch entry {
                    case .mailbox(let mailbox): mailboxes.append(mailbox)
                    case .group(_, let members): mailboxes += members
                    case .invalid: readable = false
                    }
                }
                guard readable, !mailboxes.isEmpty,
                      mailboxes.allSatisfy({ isValidEmailAddress($0.address) }) else {
                    leftovers.append(written)
                    continue
                }
                for mailbox in mailboxes where seen.insert(mailbox.address.lowercased()).inserted {
                    recipients.append(Recipient(address: mailbox.address, name: mailbox.name))
                }
            }
        }
    }

    init(_ text: String) {
        self.init([text])
    }

    /// The entries of a text. The address-list parser splits on commas only,
    /// but people separate addresses with `;` (as Outlook does), put one per
    /// line, or paste a column a single-line text field has already turned into
    /// spaces. Outside quotes, angle brackets and comments, each of these ends
    /// an entry, as a comma does (inside a group they become the commas between
    /// its members):
    /// - a line break;
    /// - a `;`, except the one that ends a group (`Team: a@example.com;`),
    ///   which is kept and followed by a comma so what follows is its own entry;
    /// - spaces or tabs after an address (a word holding an `@`, or a closing
    ///   `>`), unless a comment follows. An unquoted `@` cannot be part of a
    ///   display name (RFC 5322 3.2.3), so `a@example.com b@example.com` and
    ///   `Ann <a@example.com> Bob <b@example.com>` split, while
    ///   `Ann Lee <a@example.com>` and `a@example.com (work)` stay one mailbox.
    ///   A comment after an address belongs to it, and spaces after that
    ///   comment end the entry, as they would after the address.
    private static func entries(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        var angleDepth = 0
        var commentDepth = 0
        var inGroup = false
        var wordHasAt = false
        var afterAngle = false
        var gap = ""
        var gapEndsAddress = false
        // A comment that began right after an address: when it closes, the
        // address has ended, so spaces after it end the entry.
        var commentEndsAddress = false
        func separate() {
            if inGroup || angleDepth > 0 {
                current.append(",")
            } else {
                pieces.append(current)
                current = ""
            }
        }
        for character in text {
            if escaped {
                escaped = false
                current.append(character)
                continue
            }
            if inQuote || commentDepth > 0 {
                if character == "\\" {
                    escaped = true
                } else if inQuote {
                    if character == "\"" { inQuote = false }
                } else if character == "(" {
                    commentDepth += 1
                } else if character == ")" {
                    commentDepth -= 1
                    if commentDepth == 0, commentEndsAddress {
                        commentEndsAddress = false
                        afterAngle = true
                    }
                }
                current.append(character)
                continue
            }
            if character == " " || character == "\t" {
                if gap.isEmpty { gapEndsAddress = angleDepth == 0 && (wordHasAt || afterAngle) }
                gap.append(character)
                wordHasAt = false
                afterAngle = false
                continue
            }
            let addressEnded = angleDepth == 0 && (gap.isEmpty ? (wordHasAt || afterAngle) : gapEndsAddress)
            if !gap.isEmpty {
                if gapEndsAddress, !character.isNewline, !"(,;".contains(character) { separate() }
                current += gap
                gap = ""
            }
            afterAngle = false
            if character.isNewline {
                separate()
                wordHasAt = false
                continue
            }
            switch character {
            case "\"": inQuote = true
            case "(":
                commentDepth += 1
                commentEndsAddress = addressEnded
            case "<": angleDepth += 1
            case ">":
                angleDepth = max(0, angleDepth - 1)
                afterAngle = angleDepth == 0
            case "@" where angleDepth == 0: wordHasAt = true
            case ",":
                wordHasAt = false
                separate()
                continue
            case ":" where angleDepth == 0: inGroup = true
            case ";" where angleDepth == 0:
                wordHasAt = false
                if inGroup {
                    current.append(";")
                    inGroup = false
                }
                separate()
                continue
            default: break
            }
            current.append(character)
        }
        return pieces + [current + gap]
    }

    /// Where a text's last finished entry ends: its last `,`, `;` or line break
    /// outside quotes, angle brackets, comments and a group. A separator
    /// inside any of those is still part of the entry being typed (`"Doe, J`),
    /// so it never ends one. Nil when the text has no such separator.
    static func lastSeparator(in text: String) -> String.Index? {
        var last: String.Index?
        var inQuote = false
        var escaped = false
        var angleDepth = 0
        var commentDepth = 0
        var inGroup = false
        for index in text.indices {
            let character = text[index]
            if escaped {
                escaped = false
            } else if inQuote || commentDepth > 0 {
                if character == "\\" {
                    escaped = true
                } else if inQuote {
                    if character == "\"" { inQuote = false }
                } else if character == "(" {
                    commentDepth += 1
                } else if character == ")" {
                    commentDepth -= 1
                }
            } else if character.isNewline {
                if angleDepth == 0 { inGroup = false; last = index }
            } else {
                switch character {
                case "\"": inQuote = true
                case "(": commentDepth += 1
                case "<": angleDepth += 1
                case ">": angleDepth = max(0, angleDepth - 1)
                case ":" where angleDepth == 0: inGroup = true
                case "," where angleDepth == 0 && !inGroup: last = index
                case ";" where angleDepth == 0:
                    inGroup = false
                    last = index
                default: break
                }
            }
        }
        return last
    }

    var addresses: [String] { recipients.map(\.address) }

    /// A mailbox as text that reads back as the same mailbox: the name quoted,
    /// as sync stores it (`IMAPFetchMapping.mailboxText`), so a comma or an
    /// address inside a display name never becomes a recipient of its own.
    static func text(name: String?, address: String) -> String {
        guard let name, !name.isEmpty else { return address }
        return IMAPFetchMapping.mailboxText(name: name, address: address)
    }

    /// Who a reply goes to: every mailbox the message's Reply-To names (Gmail
    /// keeps the raw header, which can name several), or its sender, under the
    /// sender's name, when it has no Reply-To.
    static func reply(to msg: MessageHeader) -> RecipientEntry {
        if let replyTo = msg.replyTo { return RecipientEntry(replyTo) }
        var entry = RecipientEntry(msg.fromAddress)
        if entry.recipients.count == 1, entry.recipients[0].name == nil, !msg.from.isEmpty {
            entry.recipients[0] = Recipient(address: entry.recipients[0].address, name: msg.from)
        }
        return entry
    }
}
