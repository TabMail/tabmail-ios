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

    /// Splits each text with SwiftMail's address-list parser, the parser every
    /// send uses. A group contributes its members; an empty group, such as
    /// `undisclosed-recipients:;`, names nobody and is dropped. An address
    /// already listed (in any case) is not repeated.
    init(_ texts: [String]) {
        var leftovers: [String] = []
        var seen = Set<String>()
        for text in texts {
            for entry in AddressParser.parseAddressList(Self.commaSeparated(text)) {
                switch entry {
                case .mailbox(let mailbox):
                    add(mailbox, seen: &seen, leftovers: &leftovers)
                case .group(_, let members):
                    for member in members { add(member, seen: &seen, leftovers: &leftovers) }
                case .invalid(let invalid):
                    let trimmed = invalid.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { leftovers.append(trimmed) }
                }
            }
        }
        unparsed = leftovers.joined(separator: ", ")
    }

    init(_ text: String) {
        self.init([text])
    }

    /// The address-list parser splits on commas only, but people separate
    /// addresses with `;` (as Outlook does) or put one per line. A line break,
    /// or a `;` outside quotes, angle brackets, comments and groups, becomes a
    /// comma; the `;` that ends a group (`Team: a@example.com;`) is kept, followed
    /// by a comma so whatever follows the group is read as its own entry.
    private static func commaSeparated(_ text: String) -> String {
        var result = ""
        var inQuote = false
        var escaped = false
        var angleDepth = 0
        var commentDepth = 0
        var inGroup = false
        for character in text {
            if escaped {
                escaped = false
            } else if inQuote || commentDepth > 0, character == "\\" {
                escaped = true
            } else if inQuote {
                if character == "\"" { inQuote = false }
            } else if commentDepth > 0 {
                if character == "(" { commentDepth += 1 } else if character == ")" { commentDepth -= 1 }
            } else if character.isNewline {
                result.append(",")
                continue
            } else {
                switch character {
                case "\"": inQuote = true
                case "(": commentDepth += 1
                case "<": angleDepth += 1
                case ">": angleDepth = max(0, angleDepth - 1)
                case ":" where angleDepth == 0: inGroup = true
                case ";" where angleDepth == 0:
                    if inGroup {
                        inGroup = false
                        result.append(";,")
                        continue
                    } else {
                        result.append(",")
                        continue
                    }
                default: break
                }
            }
            result.append(character)
        }
        return result
    }

    var addresses: [String] { recipients.map(\.address) }

    /// A mailbox SwiftMail reads but TabMail cannot send to (such as
    /// `local@localhost`) is kept as text, like any other piece that is not an address.
    private mutating func add(
        _ mailbox: SwiftMail.EmailAddress, seen: inout Set<String>, leftovers: inout [String]
    ) {
        guard isValidEmailAddress(mailbox.address) else {
            leftovers.append(mailbox.name.map { "\($0) <\(mailbox.address)>" } ?? mailbox.address)
            return
        }
        guard seen.insert(mailbox.address.lowercased()).inserted else { return }
        recipients.append(Recipient(address: mailbox.address, name: mailbox.name))
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
