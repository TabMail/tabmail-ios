/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail

/// Build To and CC recipients for Reply All, filtering out all of the user's own email addresses.
///
/// The reply target is the one Reply does (`RecipientEntry.reply(to:)`). Text in
/// it that names no sendable address is passed on as text, one element per entry,
/// so compose shows each as a rejected entry of To and Send refuses it, as for
/// Reply (ADR-IOS-092). Entries of
/// the original To and Cc that are not sendable mailboxes are never offered
/// (owner decision 2026-10-03, memory 126).
func buildReplyAllRecipients(
    for msg: MessageHeader,
    allAccounts: [Account]
) -> (to: [String], cc: [String]) {
    // Seed the dedup set with ALL of the user's account emails
    var seen: Set<String> = Set(allAccounts.map { $0.emailAddress.lowercased() })

    var toEmails: [String] = []
    let replyTarget = RecipientEntry.reply(to: msg)
    for address in replyTarget.addresses {
        let bare = address.lowercased()
        if seen.insert(bare).inserted { toEmails.append(bare) }
    }
    // Each entry that names no sendable address stays its own element, as
    // written, so compose shows each as its own rejected entry and never reads
    // two of them joined (ADR-IOS-092).
    toEmails += replyTarget.leftovers
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
