/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail

/// Build To and CC recipients for Reply All, filtering out all of the user's own email addresses.
func buildReplyAllRecipients(
    for msg: MessageHeader,
    allAccounts: [Account]
) -> (to: [String], cc: [String]) {
    // Seed the dedup set with ALL of the user's account emails
    var seen: Set<String> = Set(allAccounts.map { $0.emailAddress.lowercased() })

    let senderEmail = extractEmailAddress(msg.replyTo ?? msg.fromAddress).lowercased()

    var toEmails: [String] = []
    if isValidEmailAddress(senderEmail), seen.insert(senderEmail).inserted {
        toEmails.append(senderEmail)
    }
    // Read with SwiftMail's parser, which honours quoted-pairs: an address inside
    // a quoted display name is part of the name, never a recipient.
    for mailbox in AddressParser.parseAddressList(msg.to).flatMap(\.mailboxes) {
        let bare = mailbox.address.lowercased()
        if isValidEmailAddress(bare), seen.insert(bare).inserted { toEmails.append(bare) }
    }

    var ccEmails: [String] = []
    for mailbox in AddressParser.parseAddressList(msg.cc).flatMap(\.mailboxes) {
        let bare = mailbox.address.lowercased()
        if isValidEmailAddress(bare), seen.insert(bare).inserted { ccEmails.append(bare) }
    }

    return (toEmails, ccEmails)
}

/// Check whether a string looks like a valid email address (has `@` with non-empty local and domain parts)
/// that SwiftMail reads as a single mailbox — the parser that sends it (`IMAPProvider.buildEmail`).
/// Filters out entries like `undisclosed-recipients:;`, group syntax, and other non-address header artifacts,
/// including the invalid entries an IMAP address field keeps for display (`IMAPFetchMapping.addressStrings`).
func isValidEmailAddress(_ address: String) -> Bool {
    let parts = address.split(separator: "@", maxSplits: 1)
    guard parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") else { return false }
    guard case .mailbox? = AddressListEntry(address) else { return false }
    return true
}

/// Extract the bare email address from a potentially formatted address like `"John Doe" <john@example.com>`.
func extractEmailAddress(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let angleStart = trimmed.firstIndex(of: "<"),
       let angleEnd = trimmed.firstIndex(of: ">"),
       angleEnd > angleStart {
        return String(trimmed[trimmed.index(after: angleStart)..<angleEnd])
    }
    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}
