/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// =============================================================================
// KEEP — PHASE-B SCAFFOLDING (Outlook NSE). DO NOT DELETE AS "DEAD CODE".
// =============================================================================
// `parseMessage` is used today by main-app `ExchangeProvider`. The other
// methods (`parseDeltaPage`, `extractBody`, `extractAttachmentRefs`) exist
// because `GraphAPI.deltaWalk` + `GraphAPI.messageFull` will consume them
// when `OutlookNSEClient` lands. Do not trim to "just what's called today".
//
// Round-3 audit (commit a49f6cd) removed those methods for that reason;
// they've been restored. Same KEEP policy as `Shared/API/GraphAPI.swift`.
// =============================================================================

/// Pure JSON parsing for Microsoft Graph (Outlook) REST responses.
/// Compiled into both main app and NSE via the Shared/ glob.
/// Mirror of `GmailParse` for Graph's shape (`from.emailAddress.address`,
/// `toRecipients[]`, `receivedDateTime`, `$delta` pagination, etc.).
enum GraphParse {
    /// Parse a Graph `/me/messages/{id}` JSON response into canonical `MessageMetadata`.
    /// Returns nil if `receivedDateTime` is missing/unparseable (fetch-failure semantics).
    static func parseMessage(_ json: [String: Any]) -> MessageMetadata? {
        guard let id = json["id"] as? String else { return nil }
        guard let receivedStr = json["receivedDateTime"] as? String,
              let date = Date.fromISO8601(receivedStr) else {
            return nil
        }

        let subject = json["subject"] as? String ?? ""
        let snippet = json["bodyPreview"] as? String ?? ""
        let threadId = json["conversationId"] as? String
        let internetMessageId = json["internetMessageId"] as? String
        let rfc822 = internetMessageId.map { EmailFilter.normalizeMessageId($0) }
        let isRead = json["isRead"] as? Bool ?? false
        let isFlagged = (json["flag"] as? [String: Any])?["flagStatus"] as? String == "flagged"
        let hasAttachments = json["hasAttachments"] as? Bool ?? false
        let categories = json["categories"] as? [String] ?? []

        let from = parseRecipient(json["from"] as? [String: Any])
        let to = parseRecipients(json["toRecipients"] as? [[String: Any]])
        let cc = parseRecipients(json["ccRecipients"] as? [[String: Any]])
        let bcc = parseRecipients(json["bccRecipients"] as? [[String: Any]])
        let replyToArr = parseRecipients(json["replyTo"] as? [[String: Any]])

        // Graph's `parentFolderId` is the opaque folder ID that the main-app
        // sync stores in `MessageHeader.folderPath`. Propagating it here lets
        // NSE construct a header `id` that matches what sync will produce
        // for the same message (prevents pre-sync vs sync duplicate rows).
        // We $select the field in every messageMetadata / messageFull URL —
        // absence in the response is a signal that Graph's schema drifted
        // and downstream folderPath logic will misbehave. The NSE-side
        // fetchSingleMessage checks for nil and refuses to stage; the
        // main-app sync path ignores folderPath here and stores its own.
        let parentFolderId = json["parentFolderId"] as? String
        if parentFolderId == nil {
            // Surfacing this in console makes a silent Graph schema change
            // discoverable before users start reporting duplicate rows.
            print("[GraphParse] messageMetadata \(id): missing parentFolderId in response — check $select")
        }

        return MessageMetadata(
            providerMessageId: id,
            threadId: threadId,
            rfc822MessageId: rfc822,
            // Graph uses conversationId for threading; In-Reply-To / References require
            // a separate internetMessageHeaders fetch — too expensive for the default path.
            inReplyTo: nil,
            references: [],
            from: from ?? EmailAddress(name: "", email: ""),
            to: to, cc: cc, bcc: bcc,
            replyTo: replyToArr.first,
            subject: subject,
            date: date,
            snippet: snippet,
            isRead: isRead,
            isFlagged: isFlagged,
            hasAttachments: hasAttachments,
            providerLabels: categories,
            folderPath: parentFolderId
        )
    }

    /// Parse a Graph `$delta` response page into `HistoryDelta`.
    /// Graph delta is paginated via `@odata.nextLink`; the final page carries
    /// `@odata.deltaLink` as the forward cursor. Callers drive the pagination.
    static func parseDeltaPage(_ json: [String: Any]) -> GraphDeltaPage {
        let entries = json["value"] as? [[String: Any]] ?? []
        var added: [DeltaMessageRef] = []
        var removed: [DeltaMessageRef] = []
        for entry in entries {
            guard let id = entry["id"] as? String else { continue }
            if entry["@removed"] != nil {
                removed.append(DeltaMessageRef(providerMessageId: id, providerLabels: []))
            } else {
                added.append(DeltaMessageRef(providerMessageId: id, providerLabels: []))
            }
        }
        let nextLink = json["@odata.nextLink"] as? String
        let deltaLink = json["@odata.deltaLink"] as? String
        return GraphDeltaPage(added: added, removed: removed, nextLink: nextLink, deltaLink: deltaLink)
    }

    /// Extract rendered body from a Graph message — `body.contentType` is
    /// "html" or "text", `body.content` is the raw string.
    static func extractBody(from json: [String: Any]) -> (html: String?, text: String?) {
        guard let body = json["body"] as? [String: Any] else { return (nil, nil) }
        let content = body["content"] as? String
        let type = (body["contentType"] as? String ?? "").lowercased()
        if type == "html" { return (content, nil) }
        if type == "text" { return (nil, content) }
        return (nil, nil)
    }

    /// Enumerate attachments from a Graph message's expanded `attachments[]`.
    /// Section = Graph attachment ID (used for per-attachment fetch later).
    static func extractAttachmentRefs(from attachments: [[String: Any]]?) -> [AttachmentRef] {
        guard let atts = attachments else { return [] }
        return atts.compactMap { att in
            guard let id = att["id"] as? String else { return nil }
            let name = att["name"] as? String ?? ""
            let mime = att["contentType"] as? String ?? ""
            let size = att["size"] as? Int ?? 0
            return AttachmentRef(
                filename: name, contentType: mime,
                section: id, size: size, encoding: nil
            )
        }
    }

    /// Decode inline images from a Graph message's expanded `attachments[]`.
    /// `$expand=attachments` on `FileAttachment` includes `contentBytes`
    /// (standard base64) in-line, so there is NO extra network call — the
    /// bytes the `messageFull` response already carries go straight into
    /// `BodyRenderer.ingredients.inlineImages`, and the renderer substitutes
    /// `cid:` refs with `data:` URIs in the rendered HTML.
    ///
    /// Only entries with `isInline=true`, a non-empty `contentId`, and an
    /// `image/*` content type count — matches `ExchangeProvider`'s main-app
    /// CID resolution predicate.
    static func extractInlineImageRefs(from attachments: [[String: Any]]?) -> [InlineImageRef] {
        guard let atts = attachments else { return [] }
        var out: [InlineImageRef] = []
        for att in atts {
            guard (att["isInline"] as? Bool) == true,
                  let contentType = att["contentType"] as? String,
                  contentType.lowercased().hasPrefix("image/"),
                  let rawCid = att["contentId"] as? String,
                  let b64 = att["contentBytes"] as? String
            else { continue }
            let contentId = rawCid.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contentId.isEmpty else { continue }
            guard let data = Data(base64Encoded: b64) else { continue }
            out.append(InlineImageRef(contentId: contentId, contentType: contentType, data: data))
        }
        return out
    }

    // MARK: - Helpers

    /// Graph delta pagination page — callers follow `nextLink` until `deltaLink` appears.
    struct GraphDeltaPage: Sendable {
        let added: [DeltaMessageRef]
        let removed: [DeltaMessageRef]
        let nextLink: String?
        let deltaLink: String?
    }

    private static func parseRecipient(_ dict: [String: Any]?) -> EmailAddress? {
        guard let ea = dict?["emailAddress"] as? [String: Any] else { return nil }
        let name = ea["name"] as? String ?? ""
        let addr = ea["address"] as? String ?? ""
        return EmailAddress(name: name.isEmpty ? addr : name, email: addr)
    }

    private static func parseRecipients(_ arr: [[String: Any]]?) -> [EmailAddress] {
        (arr ?? []).compactMap { parseRecipient($0) }
    }

}
