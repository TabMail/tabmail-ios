/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Pure, GRDB-free, main-app-independent JSON parsing for Gmail REST responses.
/// Compiled into both the main app and the NSE via the Shared/ glob.
/// Callers on each side build their own DTO (MessageHeaderInfo / NSEMessageMetadata)
/// by reading fields from the canonical MessageMetadata returned here.
enum GmailParse {
    /// Parse a Gmail `users.messages.get` JSON response into the canonical
    /// `MessageMetadata`. Returns nil if `internalDate` is missing/invalid
    /// (match main-app behavior — treat as a fetch failure so the caller retries).
    static func parseMessage(_ json: [String: Any]) -> MessageMetadata? {
        guard let id = json["id"] as? String else { return nil }
        guard let internalDateStr = json["internalDate"] as? String,
              let internalDateMs = Int64(internalDateStr),
              internalDateMs > 0 else {
            return nil
        }
        let date = Date(timeIntervalSince1970: TimeInterval(internalDateMs) / 1000)

        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []

        func header(_ name: String) -> String? {
            for h in headers {
                if let n = h["name"] as? String, n.caseInsensitiveCompare(name) == .orderedSame {
                    return h["value"] as? String
                }
            }
            return nil
        }

        let subject = header("Subject") ?? ""
        let fromRaw = header("From") ?? ""
        let toRaw = header("To") ?? ""
        let ccRaw = header("Cc") ?? ""
        let bccRaw = header("Bcc") ?? ""
        let replyToRaw = header("Reply-To")
        let rfc822 = header("Message-Id").map { EmailFilter.normalizeMessageId($0) }
        let inReplyTo = header("In-Reply-To").flatMap { EmailFilter.extractFirstMessageId($0) }
        let references: [String] = {
            guard let raw = header("References") else { return [] }
            return raw.components(separatedBy: .whitespacesAndNewlines)
                .compactMap { EmailFilter.extractFirstMessageId($0) }
        }()

        let from = EmailAddress.parse(fromRaw)
        let to = splitAddressList(toRaw).map { EmailAddress.parse($0) }
        let cc = splitAddressList(ccRaw).map { EmailAddress.parse($0) }
        let bcc = splitAddressList(bccRaw).map { EmailAddress.parse($0) }
        let replyTo = replyToRaw.map { EmailAddress.parse($0) }

        let labelIds = json["labelIds"] as? [String] ?? []
        let snippet = json["snippet"] as? String ?? ""
        let threadId = json["threadId"] as? String

        return MessageMetadata(
            providerMessageId: id,
            threadId: threadId,
            rfc822MessageId: rfc822,
            inReplyTo: inReplyTo,
            references: references,
            from: from,
            to: to, cc: cc, bcc: bcc,
            replyTo: replyTo,
            subject: subject,
            date: date,
            snippet: snippet,
            isRead: !labelIds.contains("UNREAD"),
            isFlagged: labelIds.contains("STARRED"),
            hasAttachments: hasAttachments(payload),
            providerLabels: labelIds,
            // Gmail pushes always arrive into the INBOX system label — NSE
            // uses this as folderPath so MessageHeader.id matches what the
            // main-app sync layer produces for the same message. Nil for
            // non-inbox messages (merge layer decides folder).
            folderPath: labelIds.contains("INBOX") ? "INBOX" : nil
        )
    }

    /// Parse a Gmail `users.history.list` JSON response into the canonical
    /// `HistoryDelta`. Extracts added/removed/label-changed entries plus the
    /// forward cursor.
    static func parseHistory(_ json: [String: Any]) -> HistoryDelta {
        let cursor = json["historyId"] as? String ?? ""
        let history = json["history"] as? [[String: Any]] ?? []

        var added: [DeltaMessageRef] = []
        var removed: [DeltaMessageRef] = []
        var labelsAdded: [DeltaLabelChange] = []
        var labelsRemoved: [DeltaLabelChange] = []

        for record in history {
            if let arr = record["messagesAdded"] as? [[String: Any]] {
                for item in arr {
                    if let msg = item["message"] as? [String: Any],
                       let id = msg["id"] as? String {
                        let labels = msg["labelIds"] as? [String] ?? []
                        added.append(DeltaMessageRef(providerMessageId: id, providerLabels: labels))
                    }
                }
            }
            if let arr = record["messagesDeleted"] as? [[String: Any]] {
                for item in arr {
                    if let msg = item["message"] as? [String: Any],
                       let id = msg["id"] as? String {
                        let labels = msg["labelIds"] as? [String] ?? []
                        removed.append(DeltaMessageRef(providerMessageId: id, providerLabels: labels))
                    }
                }
            }
            if let arr = record["labelsAdded"] as? [[String: Any]] {
                for item in arr {
                    if let msg = item["message"] as? [String: Any],
                       let id = msg["id"] as? String,
                       let addedLabels = item["labelIds"] as? [String] {
                        let current = msg["labelIds"] as? [String] ?? []
                        labelsAdded.append(DeltaLabelChange(
                            providerMessageId: id, labelIds: addedLabels, currentLabels: current
                        ))
                    }
                }
            }
            if let arr = record["labelsRemoved"] as? [[String: Any]] {
                for item in arr {
                    if let msg = item["message"] as? [String: Any],
                       let id = msg["id"] as? String,
                       let removedLabels = item["labelIds"] as? [String] {
                        let current = msg["labelIds"] as? [String] ?? []
                        labelsRemoved.append(DeltaLabelChange(
                            providerMessageId: id, labelIds: removedLabels, currentLabels: current
                        ))
                    }
                }
            }
        }

        return HistoryDelta(
            cursor: cursor, added: added, removed: removed,
            labelsAdded: labelsAdded, labelsRemoved: labelsRemoved
        )
    }

    /// Extract raw HTML body from a Gmail payload JSON (walks multipart).
    static func extractHTML(from json: [String: Any]) -> String? {
        guard let payload = json["payload"] as? [String: Any] else { return nil }
        return findPartBody(payload, wantedMime: "text/html")
    }

    /// Extract raw plain-text body from a Gmail payload JSON (walks multipart).
    static func extractTextPlain(from json: [String: Any]) -> String? {
        guard let payload = json["payload"] as? [String: Any] else { return nil }
        return findPartBody(payload, wantedMime: "text/plain")
    }

    /// Inline-image metadata extracted from a Gmail payload JSON. Parity with
    /// main-app `GmailProvider.extractInlineImageMeta`: a part is considered
    /// inline if it has a non-empty Content-ID header AND its MIME type
    /// starts with `image/`. Either the body data is inline (small images)
    /// or an `attachmentId` is returned so the caller can fetch the bytes
    /// via `users.messages.attachments.get`.
    ///
    /// Matches the canonical MessageDetail view's CID resolution — without
    /// this the NSE-staged Gmail body keeps `hasUnresolvedCIDs = true` for
    /// any HTML email with embedded graphics, and the main app has to
    /// re-fetch the whole body on first open.
    struct InlineImageRefMeta: Sendable {
        let contentId: String
        let contentType: String
        /// Base64url-encoded bytes when Gmail returns them inline on the
        /// part body (typical for very small images).
        let inlineBase64URL: String?
        /// Gmail attachment id — use for `users.messages.attachments.get`
        /// when `inlineBase64URL` is nil.
        let attachmentId: String?
    }

    static func extractInlineImageRefs(from json: [String: Any]) -> [InlineImageRefMeta] {
        guard let payload = json["payload"] as? [String: Any] else { return [] }
        var out: [InlineImageRefMeta] = []
        walkParts(payload) { part in
            let mime = (part["mimeType"] as? String ?? "").lowercased()
            guard mime.hasPrefix("image/") else { return }
            let headers = part["headers"] as? [[String: Any]] ?? []
            guard let cidHeader = headers.first(where: {
                ($0["name"] as? String)?.lowercased() == "content-id"
            }), let rawCid = cidHeader["value"] as? String else { return }
            let contentId = rawCid.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contentId.isEmpty else { return }
            let body = part["body"] as? [String: Any]
            out.append(InlineImageRefMeta(
                contentId: contentId,
                contentType: mime,
                inlineBase64URL: body?["data"] as? String,
                attachmentId: body?["attachmentId"] as? String
            ))
        }
        return out
    }

    /// Decode Gmail's URL-safe base64 (no padding) to raw bytes.
    static func decodeBase64URLToData(_ b64url: String) -> Data? {
        var base64 = b64url.replacingOccurrences(of: "-", with: "+")
                           .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    /// Enumerate attachment references from a Gmail payload JSON.
    /// Section = part's Gmail attachmentId (for later attachment fetch) or partId.
    static func extractAttachmentRefs(from json: [String: Any]) -> [AttachmentRef] {
        guard let payload = json["payload"] as? [String: Any] else { return [] }
        var out: [AttachmentRef] = []
        walkParts(payload) { part in
            let filename = part["filename"] as? String ?? ""
            let mime = (part["mimeType"] as? String ?? "").lowercased()
            let body = part["body"] as? [String: Any]
            let size = body?["size"] as? Int ?? 0
            let attId = body?["attachmentId"] as? String ?? (part["partId"] as? String ?? "")
            // Include if it has a filename OR is text/calendar (ICS, typically no filename).
            guard !filename.isEmpty || mime.contains("text/calendar") else { return }
            out.append(AttachmentRef(
                filename: filename, contentType: mime,
                section: attId, size: size, encoding: nil
            ))
        }
        return out
    }

    // MARK: - Helpers

    /// Matches the legacy `GmailProvider.hasAttachmentParts` semantics:
    /// true if ANY part (recursively) has a non-empty filename OR has
    /// `text/calendar` mime type. Gmail attaches `attachmentId` to many
    /// parts (including large bodies), so checking attachmentId is too
    /// aggressive — we keep the original filename-or-calendar rule.
    private static func hasAttachments(_ payload: [String: Any]) -> Bool {
        var found = false
        walkParts(payload) { part in
            if found { return }
            let filename = part["filename"] as? String ?? ""
            let mime = (part["mimeType"] as? String ?? "").lowercased()
            if !filename.isEmpty || mime.hasPrefix("text/calendar") {
                found = true
            }
        }
        return found
    }

    /// Read a raw header value directly from the Gmail message JSON.
    /// Callers that need the raw RFC 2822 header (e.g. GmailProvider storing
    /// `to`/`cc`/`bcc` verbatim) use this to bypass the parsed EmailAddress list.
    static func rawHeader(_ json: [String: Any], name: String) -> String? {
        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []
        for h in headers {
            if let n = h["name"] as? String, n.caseInsensitiveCompare(name) == .orderedSame {
                return h["value"] as? String
            }
        }
        return nil
    }

    private static func findPartBody(_ part: [String: Any], wantedMime: String) -> String? {
        if let mime = part["mimeType"] as? String, mime == wantedMime,
           let body = part["body"] as? [String: Any],
           let b64 = body["data"] as? String {
            return decodeBase64URL(b64)
        }
        if let parts = part["parts"] as? [[String: Any]] {
            for p in parts {
                if let found = findPartBody(p, wantedMime: wantedMime) { return found }
            }
        }
        return nil
    }

    private static func walkParts(_ part: [String: Any], visit: ([String: Any]) -> Void) {
        visit(part)
        if let parts = part["parts"] as? [[String: Any]] {
            for p in parts { walkParts(p, visit: visit) }
        }
    }

    /// Decode Gmail's URL-safe base64 (no padding) to a UTF-8 string.
    static func decodeBase64URL(_ b64url: String) -> String? {
        var base64 = b64url.replacingOccurrences(of: "-", with: "+")
                           .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Split an RFC 2822 address list into individual address tokens.
    /// Handles commas inside quoted display names.
    private static func splitAddressList(_ s: String) -> [String] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for c in trimmed {
            if c == "\"" { inQuotes.toggle(); current.append(c); continue }
            if c == "," && !inQuotes {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                current = ""
                continue
            }
            current.append(c)
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }
}
