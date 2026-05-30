/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

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
    for addr in parseAddressList(msg.to) {
        let bare = extractEmailAddress(addr).lowercased()
        if isValidEmailAddress(bare), seen.insert(bare).inserted { toEmails.append(bare) }
    }

    var ccEmails: [String] = []
    for addr in parseAddressList(msg.cc) {
        let bare = extractEmailAddress(addr).lowercased()
        if isValidEmailAddress(bare), seen.insert(bare).inserted { ccEmails.append(bare) }
    }

    return (toEmails, ccEmails)
}

/// Check whether a string looks like a valid email address (has `@` with non-empty local and domain parts).
/// Filters out entries like `undisclosed-recipients:;`, group syntax, and other non-address header artifacts.
func isValidEmailAddress(_ address: String) -> Bool {
    let parts = address.split(separator: "@", maxSplits: 1)
    return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
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

/// Parse a comma-separated address header into individual address strings,
/// respecting quoted display names that may contain commas (e.g., `"Doe, John" <j@x.com>`).
func parseAddressList(_ raw: String) -> [String] {
    guard !raw.isEmpty else { return [] }
    var results: [String] = []
    var current = ""
    var inQuotes = false
    for ch in raw {
        if ch == "\"" {
            inQuotes.toggle()
            current.append(ch)
        } else if ch == "," && !inQuotes {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { results.append(trimmed) }
            current = ""
        } else {
            current.append(ch)
        }
    }
    let trimmed = current.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { results.append(trimmed) }
    return results
}
