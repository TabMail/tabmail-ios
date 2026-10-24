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
                let written = piece.written.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !written.isEmpty else { continue }
                var mailboxes: [SwiftMail.EmailAddress] = []
                var readable = true
                for entry in AddressParser.parseAddressList(piece.parsed) {
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
    ///   which stays with its group;
    /// - spaces or tabs after an address (a word holding an `@`, or a closing
    ///   `>`), unless a comment follows. An unquoted `@` cannot be part of a
    ///   display name (RFC 5322 3.2.3), so `a@example.com b@example.com` and
    ///   `Ann <a@example.com> Bob <b@example.com>` split, while
    ///   `Ann Lee <a@example.com>` and `a@example.com (work)` stay one mailbox.
    ///   A comment after an address belongs to it, and spaces after that
    ///   comment end the entry, as they would after the address.
    ///
    /// Each entry comes back twice: `written`, exactly the text it was cut
    /// from, which is what is kept when the entry names no sendable address;
    /// and `parsed`, what the parser reads, where a separator inside a group or
    /// angle brackets is a comma. The text is read one Unicode scalar at a
    /// time, so a quote or separator followed by a combining mark (which Swift
    /// joins into one `Character` with it) is still seen.
    private static func entries(_ text: String) -> [(written: String, parsed: String)] {
        let scalars = text.unicodeScalars
        var pieces: [(written: String, parsed: String)] = []
        var start = scalars.startIndex
        var current = String.UnicodeScalarView()
        var inQuote = false
        var escaped = false
        var angleDepth = 0
        var commentDepth = 0
        var inGroup = false
        var wordHasAt = false
        var afterAngle = false
        var gap = String.UnicodeScalarView()
        var gapEndsAddress = false
        // A comment that began right after an address: when it closes, the
        // address has ended, so spaces after it end the entry.
        var commentEndsAddress = false
        // Ends the entry before `end`; the next one starts at `next`. Inside a
        // group or angle brackets the separator is a comma between members.
        func separate(before end: String.Index, next: String.Index) {
            if inGroup || angleDepth > 0 {
                let soFar = String(current).trimmingCharacters(in: .whitespaces)
                if !soFar.hasSuffix(","), !soFar.hasSuffix(":") { current.append(",") }
            } else {
                pieces.append((String(scalars[start..<end]), String(current)))
                current = String.UnicodeScalarView()
                start = next
            }
        }
        for index in scalars.indices {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            if escaped {
                escaped = false
                current.append(scalar)
                continue
            }
            if inQuote || commentDepth > 0 {
                if scalar == "\\" {
                    escaped = true
                } else if inQuote {
                    if scalar == "\"" { inQuote = false }
                } else if scalar == "(" {
                    commentDepth += 1
                } else if scalar == ")" {
                    commentDepth -= 1
                    if commentDepth == 0, commentEndsAddress {
                        commentEndsAddress = false
                        afterAngle = true
                    }
                }
                current.append(scalar)
                continue
            }
            if scalar == " " || scalar == "\t" {
                if gap.isEmpty { gapEndsAddress = angleDepth == 0 && (wordHasAt || afterAngle) }
                gap.append(scalar)
                wordHasAt = false
                afterAngle = false
                continue
            }
            let isNewline = CharacterSet.newlines.contains(scalar)
            let addressEnded = angleDepth == 0 && (gap.isEmpty ? (wordHasAt || afterAngle) : gapEndsAddress)
            if !gap.isEmpty {
                if gapEndsAddress, !isNewline, scalar != "(", scalar != ",", scalar != ";" {
                    separate(before: index, next: index)
                }
                current.append(contentsOf: gap)
                gap = String.UnicodeScalarView()
            }
            afterAngle = false
            if isNewline {
                separate(before: index, next: next)
                wordHasAt = false
                continue
            }
            switch scalar {
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
                separate(before: index, next: next)
                continue
            case ":" where angleDepth == 0: inGroup = true
            case ";" where angleDepth == 0:
                wordHasAt = false
                if inGroup {
                    current.append(scalar)
                    inGroup = false
                    separate(before: next, next: next)
                } else {
                    separate(before: index, next: next)
                }
                continue
            default: break
            }
            current.append(scalar)
        }
        current.append(contentsOf: gap)
        return pieces + [(String(scalars[start...]), String(current))]
    }

    /// A text cut after its last finished entry: `finished` runs through its
    /// last `,`, `;` or line break outside quotes, angle brackets, comments and
    /// a group (the `;` ending a group counts), and `rest` is the entry still
    /// being typed. A separator inside any of those is part of the entry being
    /// typed (`"Doe, J`), so it never ends one. Read one Unicode scalar at a
    /// time, as `entries` reads. Nil when the text has no such separator.
    static func splitAtLastSeparator(_ text: String) -> (finished: String, rest: String)? {
        let scalars = text.unicodeScalars
        var last: String.Index?
        var inQuote = false
        var escaped = false
        var angleDepth = 0
        var commentDepth = 0
        var inGroup = false
        for index in scalars.indices {
            let scalar = scalars[index]
            if escaped {
                escaped = false
            } else if inQuote || commentDepth > 0 {
                if scalar == "\\" {
                    escaped = true
                } else if inQuote {
                    if scalar == "\"" { inQuote = false }
                } else if scalar == "(" {
                    commentDepth += 1
                } else if scalar == ")" {
                    commentDepth -= 1
                }
            } else if CharacterSet.newlines.contains(scalar) {
                if angleDepth == 0, !inGroup { last = index }
            } else {
                switch scalar {
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
        guard let last else { return nil }
        let end = scalars.index(after: last)
        return (String(scalars[..<end]), String(scalars[end...]))
    }

    var addresses: [String] { recipients.map(\.address) }

    /// The recipients as one header line that reads back as exactly these
    /// recipients. Rejected entries are left out: joined into one line, two of
    /// them could read as an address neither of them named.
    var headerText: String {
        recipients.map { Self.text(name: $0.name, address: $0.address) }.joined(separator: ", ")
    }

    /// What a draft stores for this text: each recipient as text that reads back
    /// as itself, then each rejected entry as written, one element each.
    var draftEntries: [String] {
        recipients.map { Self.text(name: $0.name, address: $0.address) } + leftovers
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
