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
/// it is kept, unchanged in meaning, for the field's input line.
struct RecipientEntry: Equatable {
    struct Recipient: Equatable {
        let address: String
        let name: String?
    }

    private(set) var recipients: [Recipient] = []
    /// The text that names no sendable address, joined by ", ". Empty when
    /// every piece was an address.
    private(set) var unparsed = ""

    /// Splits each text into entries and reads each with SwiftMail's
    /// address-list parser, the parser every send uses. A group contributes its
    /// members. An entry that names nobody, such as the empty group
    /// `undisclosed-recipients:;` or a lone comment, is kept as text, so nothing
    /// typed silently disappears. An address already listed (in any case) is
    /// not repeated.
    init(_ texts: [String]) {
        var leftovers: [String] = []
        var seen = Set<String>()
        for text in texts {
            for piece in Self.entries(text) {
                var named = false
                for entry in AddressParser.parseAddressList(piece) {
                    switch entry {
                    case .mailbox(let mailbox):
                        named = true
                        add(mailbox, seen: &seen, leftovers: &leftovers)
                    case .group(_, let members):
                        for member in members {
                            named = true
                            add(member, seen: &seen, leftovers: &leftovers)
                        }
                    case .invalid(let invalid):
                        let trimmed = invalid.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            named = true
                            leftovers.append(trimmed)
                        }
                    }
                }
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !named, !trimmed.isEmpty { leftovers.append(trimmed) }
            }
        }
        unparsed = leftovers.joined(separator: ", ")
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
            case "(": commentDepth += 1
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

    var addresses: [String] { recipients.map(\.address) }

    /// A mailbox SwiftMail reads but TabMail cannot send to (such as
    /// `local@localhost`) is kept as text, like any other piece that is not an address.
    private mutating func add(
        _ mailbox: SwiftMail.EmailAddress, seen: inout Set<String>, leftovers: inout [String]
    ) {
        guard isValidEmailAddress(mailbox.address) else {
            leftovers.append(Self.text(name: mailbox.name, address: mailbox.address))
            return
        }
        guard seen.insert(mailbox.address.lowercased()).inserted else { return }
        recipients.append(Recipient(address: mailbox.address, name: mailbox.name))
    }

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
