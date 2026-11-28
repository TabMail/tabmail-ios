/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

/// How every provider reads the recipients a send or a draft hands it: each
/// stored recipient (`"Sam Lee" <sam@example.com>`, or a bare address) read
/// with SwiftMail's address parser, so the name and the address stay apart.
/// IMAP and Gmail write the mailboxes into their headers; Outlook sends them as
/// Graph recipient objects (#1031). Provider-neutral: no provider type here.
enum OutgoingRecipients {
    /// The mailboxes each recipient names. Compose hands over one address per
    /// recipient (ADR-IOS-092), but a send queued by an earlier version can hold a
    /// typed list such as `a@example.com, b@example.com` in one recipient; it goes
    /// to every mailbox it names. Throws on the first recipient that names no
    /// mailbox or holds text that is not one (an empty group included). Each mailbox is written again by
    /// SwiftMail, never copied as text, so no recipient can add a header line.
    static func sendableRecipients(_ recipients: [String]) throws -> [SwiftMail.EmailAddress] {
        try recipients.flatMap { recipient in
            var mailboxes: [SwiftMail.EmailAddress] = []
            for entry in AddressParser.parseAddressList(recipient) {
                switch entry {
                case .mailbox(let mailbox): mailboxes.append(mailbox)
                case .group(_, let members):
                    // A group naming nobody is not an address: beside other
                    // recipients it fails the send too, never silently dropped.
                    guard !members.isEmpty else { throw SMTPError.invalidEmailAddress(recipient) }
                    mailboxes += members
                case .invalid:
                    // Any entry that is not a mailbox fails the whole send, even
                    // one whose decoded text is empty (`""`): nothing is dropped.
                    throw SMTPError.invalidEmailAddress(recipient)
                }
            }
            guard !mailboxes.isEmpty else { throw SMTPError.invalidEmailAddress(recipient) }
            return mailboxes
        }
    }

    /// Each recipient as the mailboxes it names (`sendableRecipients`), or, when
    /// it is not a mailbox list, as an address holding its text: how a draft is
    /// written, since a draft may hold an address the user has not finished and
    /// saving it must not fail. Also how Graph's recipient objects are read
    /// (`ExchangeProvider.graphRecipients`).
    static func draftRecipients(_ recipients: [String]) -> [SwiftMail.EmailAddress] {
        recipients.flatMap { recipient in
            (try? sendableRecipients([recipient])) ?? [SwiftMail.EmailAddress(address: recipient)]
        }
    }
}
