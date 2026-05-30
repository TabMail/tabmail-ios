/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

/// Parse raw `.eml` / RFC 822 bytes into the pieces `EmlMarker.build` needs.
/// Shared across IMAPProvider, GmailProvider, and ExchangeProvider so
/// file-uploaded `.eml` attachments (which often carry a generic
/// `application/octet-stream` Content-Type instead of `message/rfc822`)
/// render the same way as server-side-parsed nested messages.
///
/// Source of truth: SwiftMail's `EMLParser.parse(Data) -> Message`, which
/// already handles RFC 2822 headers + multipart MIME decoding. We do not
/// re-parse anything ourselves.
enum EmlParsing {
    struct Parsed {
        let envelope: EmlMarker.Envelope
        /// HTML body ready to go into `EmlMarker.build(bodyHtml:)`. If the
        /// source message had only a text/plain body, it's been converted
        /// via `MessageBody.plainTextToHTML` so the marker render remains
        /// styled/linkified.
        let bodyHtml: String
        /// Metadata for each attachment found inside the parsed `.eml`.
        /// Order is stable for a given byte buffer (SwiftMail preserves
        /// MIME part ordering), so `index` is a sufficient key for later
        /// re-lookup via `nestedBytes(rawBytes:index:)`.
        let nested: [NestedMeta]
    }

    /// Metadata for an attachment nested inside a file-uploaded `.eml`.
    /// Bytes are intentionally absent — providers re-fetch the parent
    /// `.eml` at tap time rather than caching bytes across the session.
    struct NestedMeta: Sendable {
        let filename: String
        let contentType: String
        let size: Int
    }

    /// Section-path marker used by all three providers to encode
    /// `<parent_section>|eml-nested|<index>` in `AttachmentInfo.section`.
    /// Single literal + 3-part split keeps detection unambiguous across
    /// IMAP numeric paths, Gmail attachment IDs, and Graph attachment IDs
    /// (none of which contain `|eml-nested|`).
    static let nestedSeparator = "|eml-nested|"

    /// Parse and return envelope + body HTML + nested attachment metadata.
    /// Returns nil when SwiftMail's parser rejects the bytes as invalid
    /// RFC 822 — caller falls back to rendering as an opaque file.
    static func parse(rawBytes: Data) -> Parsed? {
        guard let message = try? EMLParser.parse(rawBytes) else { return nil }

        let envelope = EmlMarker.Envelope(
            subject: message.subject,
            from: message.from,
            date: message.date,
            to: message.to,
            cc: message.cc
        )

        let bodyHtml: String
        if let html = message.htmlBody, !html.isEmpty {
            bodyHtml = html
        } else if let text = message.textBody, !text.isEmpty {
            bodyHtml = EmailFilter.plainTextToHTML(text)
        } else {
            bodyHtml = ""
        }

        let nested: [NestedMeta] = message.attachments.enumerated().map { (idx, part) in
            NestedMeta(
                filename: part.filename ?? part.suggestedFilename,
                contentType: part.contentType.isEmpty ? "application/octet-stream" : part.contentType,
                size: part.data?.count ?? 0
            )
        }

        return Parsed(envelope: envelope, bodyHtml: bodyHtml, nested: nested)
    }

    /// Extract the decoded bytes of the nth nested attachment from an
    /// already-downloaded `.eml` byte buffer. Pairs with `Parsed.nested`
    /// so the index the UI stored when rendering resolves back to the
    /// correct attachment at tap time, even across process restarts.
    static func nestedBytes(rawBytes: Data, index: Int) -> Data? {
        guard let message = try? EMLParser.parse(rawBytes) else { return nil }
        let attachments = message.attachments
        guard index >= 0, index < attachments.count else { return nil }
        return attachments[index].decodedData() ?? attachments[index].data
    }

    /// Filename-based `.eml` detection. A file with `.eml` extension is
    /// treated as a nested message regardless of Content-Type — Outlook
    /// Web (and some other clients) upload `.eml` files as
    /// `application/octet-stream`, which is valid MIME but not what the
    /// Content-Type-based detection catches.
    static func isEmlFilename(_ filename: String?) -> Bool {
        guard let filename else { return false }
        return filename.lowercased().hasSuffix(".eml")
    }

    /// Split a compound section path encoded by `nestedSeparator`. Returns
    /// nil when the path isn't a nested-.eml reference.
    /// Example: `"2|eml-nested|0"` → `(parent: "2", index: 0)`.
    static func parseNestedSection(_ section: String) -> (parent: String, index: Int)? {
        let parts = section.components(separatedBy: nestedSeparator)
        guard parts.count == 2,
              let idx = Int(parts[1]),
              !parts[0].isEmpty else { return nil }
        return (parent: parts[0], index: idx)
    }

    /// Encode a compound section for a nested attachment.
    static func nestedSection(parent: String, index: Int) -> String {
        "\(parent)\(nestedSeparator)\(index)"
    }
}
