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
    /// header.
    ///
    /// ⚠ WHAT THE TYPE ACTUALLY BUYS — corrected 2026-08-05. This doc used to claim
    /// the type meant *"a `messageHeader.id` cannot be handed to
    /// `MessageBody.fetchOne(db, key:)` … without saying so."* **That is false, and
    /// believing it is worse than not having the type.** GRDB's `key:` parameter is
    /// generic over `DatabaseValueConvertible`, and `String` conforms — so a bare
    /// `messageHeader.id` compiles at a `key:` lookup with no cast, no warning and no
    /// diagnostic. Census over `TabMail` + `TabMailTests` + `Shared`: **57**
    /// `MessageBody.<method>(db, key:)` sites, of which **22** wrap in
    /// `ContentKey(...)` and **35** pass something unwrapped — most of them a genuine
    /// bare `String` (`header.id`, `message.id`, string literals;
    /// `MessageHeader.id` is declared `var id: String`).
    ///
    /// What the type DOES enforce is the **stored column and the construction path**:
    /// `init(contentKey:)` and `create(contentKey:)` cannot be reached with a
    /// `messageHeader.id` unless someone writes `ContentKey(rawValue:)` explicitly, so
    /// every *mint* of a body's key is visible at the callsite. Lookups are not
    /// covered; only construction is.
    ///
    /// This has **zero behavioural effect today** — the two key spaces are
    /// byte-identical, so an unwrapped crossing resolves to the same row. It becomes
    /// real at Stage E1, when the content key's tail moves off the provider id and the
    /// two strings diverge. ⚑ The 35 unwrapped sites are DELIBERATELY left unwrapped:
    /// wrapping them would paper over exactly the crossings this paragraph exists to
    /// make searchable, and the `rg` above is currently the only way to enumerate
    /// them. Wrap them when E1 lands, as part of E1 — not before.
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

