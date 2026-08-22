/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// =============================================================================
// KEEP — LIVE SHARED OUTLOOK PARSER SURFACE. DO NOT DELETE AS "DEAD CODE".
// =============================================================================
// `parseMessage`, `extractBody`, and the attachment extractors are live through
// `OutlookNSEClient`'s production calls to `GraphAPI.messageMetadata` and
// `GraphAPI.messageFull`; `ExchangeProvider` also uses `parseMessage`. The
// delta parser is owned by `GraphAPI.deltaWalk`, whose production caller census
// is separate. Do not trim this shared surface from a main-app-only census.
//
// Round-3 audit (commit a49f6cd) removed those methods for that reason;
// they've been restored. Same KEEP policy as `Shared/API/GraphAPI.swift`.
// =============================================================================

/// Pure JSON parsing for Microsoft Graph (Outlook) REST responses.
/// Compiled into both main app and NSE via the Shared/ glob.
/// Mirror of `GmailParse` for Graph's shape (`from.emailAddress.address`,
/// `toRecipients[]`, `receivedDateTime`, `$delta` pagination, etc.).
enum GraphParse {
    /// True when a caller that ASKED Graph for `parentFolderId` did not get it
    /// back. That — and only that — is evidence of schema drift; a caller whose
    /// `$select` omits the field is describing its own request, not the server.
    ///
    /// The firing condition lives here, once, so it can be tested on both
    /// sides. Its sole consumer is the `#if DEBUG` diagnostic in `parseMessage`.
    static func parentFolderIdDriftDetected(
        parentFolderId: String?,
        selection: GraphMessageSelection
    ) -> Bool {
        selection.contains("parentFolderId") && parentFolderId == nil
    }

    /// Parse a Graph `/me/messages/{id}` JSON response into canonical `MessageMetadata`.
    /// Returns nil if `receivedDateTime` is missing/unparseable (fetch-failure semantics).
    ///
    /// - Parameter selection: the field selection the caller says produced
    ///   `json`. There is no default Boolean premise; production request/parse
    ///   handoffs are pinned by provider integration tests.
    static func parseMessage(
        _ json: [String: Any],
        selection: GraphMessageSelection
    ) -> MessageMetadata? {
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
        // The `messageMetadata` / `messageFull` URLs in `GraphAPI` and the
        // main-app `fetchMessage` / `fetchMessageDetails` routes $select the
        // field, so absence there is a signal that Graph's schema drifted.
        // The five main-app known-folder routes — `fetchMessages`,
        // `fetchSingleBackfill`, `search`, `fetchMessageHeaders`, and
        // `fetchOlderMessages` — omit it because they already know their folder
        // context. Their absent field is not evidence of anything. NSE
        // `fetchSingleMessage` refuses to stage without the selected field;
        // the main-app list/backfill routes store their own folder context.
        let parentFolderId = json["parentFolderId"] as? String
        // Surfacing this in console makes a silent Graph schema change
        // discoverable before users start reporting duplicate rows. Debug
        // builds only: on device `stdout` is discarded, so this was never a
        // production channel. `#if DEBUG` rather than `DebugModeManager`
        // because `Shared/` also compiles into the NSE, where that type
        // does not exist.
        #if DEBUG
        if parentFolderIdDriftDetected(
            parentFolderId: parentFolderId,
            selection: selection
        ) {
            print("[GraphParse] messageMetadata \(id): missing parentFolderId in response — check $select")
        }
        #endif

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
