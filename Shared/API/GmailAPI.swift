/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Pure Gmail REST API calls. Consumed by both the main-app `GmailProvider`
/// (via `AccountAuthSource`) and `GmailNSEClient` (via `NSEAuthSource`).
///
/// No actor isolation, no caching, no GRDB. State only in the caller-supplied
/// `AuthedHTTP` (which holds an `AuthSource`). 401-retry is handled by
/// `AuthedHTTP`; rate-limit retry via `HTTPRetryPolicy.gmail`.
enum GmailAPI {
    private static let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    /// Max concurrent in-flight HTTP requests per Gmail account. Gmail enforces a
    /// per-USER concurrency cap (HTTP 429 "Too many concurrent requests for user",
    /// reason `rateLimitExceeded`, status `RESOURCE_EXHAUSTED`); fanning out a whole
    /// `messages.list` page (~50) of `messages.get?format=metadata` calls at once
    /// blew past it. 6 keeps strong parallelism (~6× over sequential — a 50-message
    /// folder still lands in ~3-4s) while staying well under the cap. Tunable.
    static let maxConcurrentRequests = 6

    /// `?format=metadata&metadataHeaders=...` query for `users.messages.get`.
    /// Single source of truth: both `GmailAPI.messageMetadata` (NSE-owned
    /// fetch path) and every `GmailProvider` call site that assembles the
    /// same URL inline must reference this string. Adding a header here
    /// propagates to every caller — prevents the "NSE has header X but
    /// main-app doesn't (or vice versa)" drift class that produced the
    /// 2026-04-19 duplicate-row bug's cousin risk.
    static let metadataQuery =
        "?format=metadata"
        + "&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Bcc"
        + "&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Reply-To"
        + "&metadataHeaders=Message-Id&metadataHeaders=In-Reply-To&metadataHeaders=References"

    /// `?format=full` query (no metadataHeaders filter — format=full returns
    /// the complete MIME tree). Stored as a constant for symmetry with
    /// `metadataQuery`.
    static let fullQuery = "?format=full"

    /// `users.history.list` — incremental changes since `startHistoryId`.
    /// `historyTypes` filters which events are returned (Gmail default = all four).
    /// `labelId` restricts to a single label (e.g. "INBOX"); pass nil for mailbox-wide.
    ///
    /// Returns nil when Gmail responds 404 — the historyId has expired, callers
    /// must fall back to a full sync. Any other error throws.
    static func historyList(
        http: AuthedHTTP,
        startHistoryId: String,
        historyTypes: [String] = ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"],
        labelId: String? = nil
    ) async throws -> HistoryDelta? {
        var q: [String] = ["startHistoryId=\(startHistoryId)"]
        for t in historyTypes { q.append("historyTypes=\(t)") }
        if let labelId { q.append("labelId=\(labelId)") }
        let url = "\(baseURL)/history?" + q.joined(separator: "&")
        let res = try await http.requestAllowing404(url: url)
        if res.statusCode == 404 { return nil }
        guard let data = res.data,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.networkError(statusCode: res.statusCode)
        }
        return GmailParse.parseHistory(json)
    }

    /// `users.messages.get` with `format=metadata` — headers only, no body.
    /// Fast path for notification scaffolding before body fetch.
    ///
    /// Returns the parsed `MessageMetadata` plus the raw JSON dict so callers
    /// can read headers in their original form. The NSE staging path needs
    /// the raw RFC 2822 recipient strings (`"Name" <addr>, …`) to match the
    /// byte-identical format main-app `GmailProvider.parseGmailMessage`
    /// writes to GRDB — otherwise sync's UPDATE pass over the same row
    /// produces a write delta every push.
    static func messageMetadata(http: AuthedHTTP, id: String) async throws -> (MessageMetadata, [String: Any]) {
        let url = "\(baseURL)/messages/\(id)\(metadataQuery)"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = GmailParse.parseMessage(json) else {
            throw HTTPError.networkError(statusCode: 0)
        }
        return (metadata, json)
    }

    /// `users.messages.get` with `format=full` — both metadata and body.
    /// Uses shared `BodyRenderer` for canonical `RenderedBody`. Caller may supply
    /// an attachment fetcher (main app) or omit it (NSE — CIDs stay unresolved).
    static func messageFull(
        http: AuthedHTTP,
        id: String,
        contentKey: ContentKey? = nil,
        attachmentFetcher: BodyRenderer.AttachmentFetcher? = nil,
        icsRenderer: BodyRenderer.ICSRenderer? = nil
    ) async throws -> (MessageMetadata, RenderedBody) {
        let url = "\(baseURL)/messages/\(id)\(fullQuery)"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = GmailParse.parseMessage(json) else {
            throw HTTPError.networkError(statusCode: 0)
        }

        // Fetch CID inline images referenced in the HTML body. Unlike Graph's
        // `$expand=attachments`, Gmail's `messages.get?format=full` returns
        // inline image metadata on the part tree, but the actual bytes live
        // behind a separate `users.messages.attachments.get` call (unless
        // the part is small enough that Gmail inlines the base64url data
        // on `body.data`). Pre-fetching here gives the NSE-staged body
        // `hasUnresolvedCIDs = false` so `MessageBody` persists and the main
        // app doesn't re-fetch the body on first open. Capped at the shared
        // `BodyRenderer.maxInlineImages`.
        let inlineImages = await fetchInlineImagesIfAny(http: http, messageId: id, json: json)

        // Body parts. `extractHTML`/`extractTextPlain` read only inline `body.data`;
        // Gmail returns LARGE parts as `body.attachmentId` instead. Fetch those —
        // matching main-app `GmailProvider.extractBodyWithFallback` — so a large
        // text/html body isn't dropped and the email staged as plaintext on the push
        // route (the rare "HTML rendered as plaintext" divergence).
        var rawHTML = GmailParse.extractHTML(from: json)
        var rawText = GmailParse.extractTextPlain(from: json)
        if rawHTML == nil, let attId = GmailParse.bodyAttachmentId(from: json, wantedMime: "text/html") {
            // HTML is the display body — propagate on failure (caller returns nil →
            // no degraded body staged → main app refetches). Never fall back to text.
            let bytes = try await attachment(http: http, messageId: id, attachmentId: attId)
            rawHTML = String(data: bytes, encoding: .utf8)
        }
        if rawText == nil, let attId = GmailParse.bodyAttachmentId(from: json, wantedMime: "text/plain") {
            // Plain text is secondary (snippet/FTS) and BodyRenderer can derive it
            // from the HTML, so a miss here is best-effort — don't fail the fetch.
            if let bytes = try? await attachment(http: http, messageId: id, attachmentId: attId) {
                rawText = String(data: bytes, encoding: .utf8)
            }
        }

        let ingredients = RawBodyIngredients(
            rawHTML: rawHTML,
            rawText: rawText,
            attachments: GmailParse.extractAttachmentRefs(from: json),
            inlineImages: inlineImages,
            icsData: nil
        )
        // Bind the inline-image writer once per render — same factory that
        // IMAP and Graph paths use, so behavior is identical across providers
        // *and* across targets (main app + NSE). `contentKey == nil` (compose
        // preview, tooltip, etc.) → no writer → data URIs.
        let inlineImageWriter: BodyRenderer.InlineImageWriter? =
            contentKey.map { BodyAssetStore.makeInlineImageWriter(forContentKey: $0) }
        let rendered = await BodyRenderer.render(
            ingredients: ingredients,
            attachmentFetcher: attachmentFetcher,
            icsRenderer: icsRenderer,
            inlineImageWriter: inlineImageWriter
        )
        return (metadata, rendered)
    }

    /// Fetch raw attachment bytes for a Gmail message. Used during inline
    /// image resolution in `messageFull` — Gmail returns inline image parts
    /// as separate attachments (not inline on the payload JSON).
    static func attachment(http: AuthedHTTP, messageId: String, attachmentId: String) async throws -> Data {
        let url = "\(baseURL)/messages/\(messageId)/attachments/\(attachmentId)"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64url = json["data"] as? String,
              let bytes = GmailParse.decodeBase64URLToData(b64url) else {
            throw HTTPError.networkError(statusCode: 0)
        }
        return bytes
    }

    /// Resolve CID inline images for a parsed Gmail `messages.get?format=full`
    /// response. Mirror of `GmailProvider.fetchInlineImages` — prefers the
    /// inline base64url body when Gmail returned it (small images), else
    /// fetches the attachment bytes. Errors on any single image are logged
    /// and skipped; the renderer will simply leave that `cid:` ref unresolved.
    ///
    /// ⚠️ `4dafe4a32`'s message attributes the sentence above to
    /// `GmailProvider.fetchInlineImages`'s doc ("whose own doc calls this function
    /// the mirror"). That doc is one line and says nothing of the kind — the
    /// sentence is this one. Correcting it here because the commit cannot be
    /// amended and this is where a reader checking the attribution lands.
    private static func fetchInlineImagesIfAny(
        http: AuthedHTTP,
        messageId: String,
        json: [String: Any]
    ) async -> [InlineImageRef] {
        let meta = GmailParse.extractInlineImageRefs(from: json).prefix(BodyRenderer.maxInlineImages)
        guard !meta.isEmpty else { return [] }
        var out: [InlineImageRef] = []
        for item in meta {
            if let b64 = item.inlineBase64URL, let data = GmailParse.decodeBase64URLToData(b64) {
                out.append(InlineImageRef(contentId: item.contentId, contentType: item.contentType, data: data))
                continue
            }
            guard let attId = item.attachmentId else { continue }
            do {
                let bytes = try await attachment(http: http, messageId: messageId, attachmentId: attId)
                out.append(InlineImageRef(contentId: item.contentId, contentType: item.contentType, data: bytes))
            } catch {
                print("[GmailAPI] Inline image fetch failed for \(item.contentId): \(error)")
            }
        }
        return out
    }
}
