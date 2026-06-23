/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

struct DraftAttachment: Sendable {
    let filename: String
    let mimeType: String
    let data: Data
    /// When true, this attachment is rendered as a multipart/alternative part
    /// instead of a regular attachment. Used for ICS calendar invitations so
    /// that Gmail/Outlook render Accept/Decline buttons instead of showing
    /// a generic .ics file attachment.
    var isAlternative: Bool = false
}

struct DraftMessage: Sendable {
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String
    var isHTML: Bool
    var inReplyTo: String?
    var references: [String]
    var attachments: [DraftAttachment]
    /// Pre-generated RFC822 Message-ID. When set, providers MUST use this instead of
    /// generating a new one — ensures SMTP send and IMAP Sent append share the same ID.
    var messageId: String?
    /// Gmail native conversation id of the source message, for reply/forward.
    /// Only the Gmail REST send consumes it (to file the message into the existing
    /// thread); IMAP/Exchange thread purely via the In-Reply-To/References headers.
    /// `nil` for new compositions and non-Gmail providers. See ADR-IOS-043.
    var threadId: String?

    init(
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "",
        body: String = "",
        isHTML: Bool = false,
        inReplyTo: String? = nil,
        references: [String] = [],
        attachments: [DraftAttachment] = [],
        threadId: String? = nil
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.isHTML = isHTML
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.threadId = threadId
    }
}
