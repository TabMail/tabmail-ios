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

    /// Build a MessageBody from already-rendered DISPLAY html. Body conversion —
    /// including the single plain-text→HTML pass — is owned by `BodyRenderer` (the
    /// single conversion authority), so this factory never re-converts. That
    /// structurally removes the historic double-escape site (`plainTextToHTML`
    /// applied to content that was already HTML). Pass the `RenderedBody.htmlContent`
    /// produced by `BodyRenderer`.
    static func create(headerId: String, htmlBody: String?) -> MessageBody {
        if let html = htmlBody, !html.isEmpty {
            return MessageBody(headerId: headerId, htmlContent: html)
        }
        return MessageBody(headerId: headerId, htmlContent: nil)
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

    /// Merge identity-proven duplicate body rows without letting one whole-record
    /// "winner" discard complementary content from another materialization.
    ///
    /// Attachment JSON is user-visible cached metadata. A malformed nonempty payload
    /// throws so the surrounding GRDB transaction rolls back and preserves every source
    /// row; silently treating it as `[]` would cascade-delete opaque metadata.
    static func merged(
        _ bodies: [MessageBody],
        headerId: String
    ) throws -> MessageBody? {
        guard !bodies.isEmpty else { return nil }
        let ordered = bodies.sorted { $0.id < $1.id }

        func richestText(_ value: (MessageBody) -> String?) -> String? {
            let nonempty = ordered.compactMap { body -> (String, Date, String)? in
                guard let text = value(body), !text.isEmpty else { return nil }
                return (text, body.fetchedAt, body.id)
            }
            if let richest = nonempty.max(by: { lhs, rhs in
                if lhs.0.count != rhs.0.count { return lhs.0.count < rhs.0.count }
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2 > rhs.2
            }) {
                return richest.0
            }
            return ordered
                .filter { value($0) != nil }
                .max(by: { $0.fetchedAt < $1.fetchedAt })
                .flatMap(value)
        }

        var attachmentByKey: [String: AttachmentInfo] = [:]
        var sawAttachmentJSON = false
        let decoder = JSONDecoder()
        for body in ordered {
            guard let json = body.attachmentsJSON, !json.isEmpty else { continue }
            sawAttachmentJSON = true
            guard let data = json.data(using: .utf8) else {
                throw MessageBodyMergeError.invalidAttachmentsJSON(headerId: body.id)
            }
            let attachments: [AttachmentInfo]
            do {
                attachments = try decoder.decode([AttachmentInfo].self, from: data)
            } catch {
                throw MessageBodyMergeError.invalidAttachmentsJSON(headerId: body.id)
            }
            for attachment in attachments {
                attachmentByKey[Self.attachmentMergeKey(attachment)] = attachment
            }
        }

        var merged = MessageBody(
            headerId: headerId,
            htmlContent: richestText(\.htmlContent)
        )
        merged.fetchedAt = ordered.map(\.fetchedAt).max() ?? merged.fetchedAt
        merged.icsText = richestText(\.icsText)
        if sawAttachmentJSON {
            let attachments = attachmentByKey.keys.sorted().compactMap {
                attachmentByKey[$0]
            }
            let data = try JSONEncoder().encode(attachments)
            merged.attachmentsJSON = String(data: data, encoding: .utf8)
        }
        return merged
    }

    private static func attachmentMergeKey(_ attachment: AttachmentInfo) -> String {
        [
            attachment.parentEmlSection ?? "",
            attachment.section,
            attachment.filename,
            attachment.contentType,
            String(attachment.size),
            attachment.encoding ?? "",
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

enum MessageBodyMergeError: Error, Equatable {
    case invalidAttachmentsJSON(headerId: String)
}
