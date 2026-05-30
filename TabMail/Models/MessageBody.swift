/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

struct MessageBody: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "messageBody"

    var id: String // Same as headerId — 1:1 with MessageHeader
    var htmlContent: String?
    /// JSON-encoded [AttachmentInfo] for attachment metadata
    var attachmentsJSON: String?
    var fetchedAt: Date
    /// Raw ICS text from text/calendar attachment (for "Add to Calendar" action)
    var icsText: String?

    init(headerId: String, htmlContent: String?) {
        self.id = headerId
        self.htmlContent = htmlContent
        self.fetchedAt = Date()
    }

    /// Create a MessageBody, converting plain-text-only emails to basic HTML.
    /// Use this when the provider returns textBody but no htmlBody.
    static func create(headerId: String, htmlBody: String?, textBody: String?) -> MessageBody {
        if let html = htmlBody, !html.isEmpty {
            return MessageBody(headerId: headerId, htmlContent: html)
        } else if let text = textBody, !text.isEmpty {
            return MessageBody(headerId: headerId, htmlContent: plainTextToHTML(text))
        } else {
            return MessageBody(headerId: headerId, htmlContent: nil)
        }
    }

    /// Convert plain text email to HTML for WKWebView rendering.
    /// Uses RFC 3676 format=flowed detection: a trailing space before the line
    /// terminator marks a "soft wrap" (join with next line). No trailing space
    /// means a "hard break" (preserve). This is what Thunderbird and Apple Mail do.
    /// - `>` prefixed lines → `<blockquote>` (for quote collapse detection)
    /// - Empty lines → `<div><br></div>` (paragraph break)
    /// - `white-space: pre-wrap` on container preserves multiple spaces
    /// Forwarding wrapper — implementation lives in `EmailFilter.plainTextToHTML`
    /// (Shared) so it's usable from provider code and Shared helpers.
    static func plainTextToHTML(_ text: String) -> String {
        EmailFilter.plainTextToHTML(text)
    }

    var attachments: [AttachmentInfo] {
        guard let json = attachmentsJSON, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AttachmentInfo].self, from: data)) ?? []
    }
}
