/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

struct MessageBody: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "messageBody"

    /// The message's CONTENT key — not its `messageHeader.id`.
    ///
    /// The two are the same string today, and were 1:1 with `MessageHeader` by
    /// construction. They stop being the same string once the content key's tail
    /// moves off the provider id (`ContentKeySpace`): a body belongs to the
    /// *content*, so it survives a `UIDVALIDITY` renumber that re-addresses the
    /// header. Typed so a `messageHeader.id` cannot be handed to
    /// `MessageBody.fetchOne(db, key:)` — or vice versa — without saying so.
    var id: ContentKey
    var htmlContent: String?
    /// JSON-encoded [AttachmentInfo] for attachment metadata
    var attachmentsJSON: String?
    var fetchedAt: Date
    /// Raw ICS text from text/calendar attachment (for "Add to Calendar" action)
    var icsText: String?

    init(contentKey: ContentKey, htmlContent: String?) {
        self.id = contentKey
        self.htmlContent = htmlContent
        self.fetchedAt = Date()
    }

    /// Build a MessageBody from already-rendered DISPLAY html. Body conversion —
    /// including the single plain-text→HTML pass — is owned by `BodyRenderer` (the
    /// single conversion authority), so this factory never re-converts. That
    /// structurally removes the historic double-escape site (`plainTextToHTML`
    /// applied to content that was already HTML). Pass the `RenderedBody.htmlContent`
    /// produced by `BodyRenderer`.
    static func create(contentKey: ContentKey, htmlBody: String?) -> MessageBody {
        if let html = htmlBody, !html.isEmpty {
            return MessageBody(contentKey: contentKey, htmlContent: html)
        }
        return MessageBody(contentKey: contentKey, htmlContent: nil)
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

