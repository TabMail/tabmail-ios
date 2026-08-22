/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The exact Microsoft Graph message fields requested by one HTTP call.
///
/// Production call sites carry this value from request construction into
/// response parsing. Exact-URL and parsed-result integration tests pin that
/// handoff; the type itself cannot prove that an arbitrary caller passed the
/// selection that produced a payload.
/// Membership is token-based rather than substring-based because Graph field
/// names are discrete comma-separated identifiers.
struct GraphMessageSelection: Sendable {
    let fields: [String]

    var fieldList: String {
        fields.joined(separator: ",")
    }

    var queryParameter: String {
        "$select=\(fieldList)"
    }

    func contains(_ field: String) -> Bool {
        fields.contains(field)
    }

    func appending(_ fields: String...) -> GraphMessageSelection {
        GraphMessageSelection(fields: self.fields + fields)
    }
}

// =============================================================================
// KEEP — LIVE SHARED OUTLOOK NSE SURFACE. DO NOT DELETE AS "DEAD CODE".
// =============================================================================
// `OutlookNSEClient` calls `messageMetadata` and `messageFull` in production.
// The main-app `ExchangeProvider` still owns its inline `request(path:)`, while
// sharing this file's field selections and strict path-segment encoder.
//
// Round-3 dead-code audit (commit d1437c3) deleted this file because it had
// "zero callers" in main-app code. That was wrong: the consumer is the NSE
// target, which is why a main-app-only census missed it. This shared provider
// API layer is intentional architecture (LOCKED 2026-04-12).
//
// This banner exists to prevent the same mistake. If you're tempted to delete
// a method here, census every target separately: the surface mixes live NSE
// entry points with narrower helpers that may not have a production caller.
// =============================================================================

/// Pure Microsoft Graph REST API calls for Outlook/Exchange accounts.
/// Mirror of `GmailAPI` using the shared `AuthedHTTP` path.
enum GraphAPI {
    private static let baseURL = "https://graph.microsoft.com/v1.0/me"

    // MARK: - $select field lists (single source of truth)
    //
    // Every `?$select=...` URL in main-app `ExchangeProvider` + this NSE-
    // owned API module composes from these constants so a field added here
    // lands in both call sites at once. Prior-art: the parallel inline copies
    // in ExchangeProvider drifted from the NSE URL's inline copy and nobody
    // noticed — same class of bug that produced the 2026-04-19 iCloud
    // duplicate-row fix's cousin risk on Graph.
    //
    // Graph does not care about $select field ordering.

    /// Core header fields (no body, no parentFolderId). Baseline for
    /// paginated header-list fetches where the client already knows the
    /// folder context.
    static let headerOnlySelection = GraphMessageSelection(fields: [
        "id", "subject", "from", "toRecipients", "ccRecipients", "bccRecipients", "replyTo",
        "receivedDateTime", "isRead", "flag", "hasAttachments", "internetMessageId",
        "conversationId", "categories", "bodyPreview"
    ])

    /// Header fields + `parentFolderId`. Used for single-message metadata
    /// fetches (NSE push + main-app delta sync that needs to assign the
    /// message to its server-side folder).
    static let metadataSelection = headerOnlySelection.appending("parentFolderId")

    /// Header fields + `body` (no `parentFolderId`). Used by unified
    /// backfill that grabs headers and body in one API round-trip within
    /// a known folder context.
    static let backfillSelection = headerOnlySelection.appending("body")

    /// Everything — headers + body + `parentFolderId`. Used for single-
    /// message full fetches (main-app `fetchMessage`, NSE `messageFull`).
    static let fullSelection = headerOnlySelection.appending("body", "parentFolderId")

    // MARK: - Path-segment encoding (single source of truth for BOTH targets)

    /// The RFC 3986 **unreserved** set — the only characters that may appear
    /// literally in a Graph path segment.
    ///
    /// Graph resource ids (message ids, attachment ids, folder ids) are opaque
    /// server-minted strings. Interpolating one raw into a URL lets `/`, `?`,
    /// `#`, `+` or `=` inside it change which **route** the server selects, so
    /// every id is encoded as exactly one path segment before composition.
    ///
    /// This set was authored on the main-app side (`ExchangeProvider`) and is
    /// **moved** here, not copied: `Shared` is linked by the app AND the
    /// notification-service extension, and a second copy is precisely how the
    /// `$select` field lists above drifted apart before they were consolidated.
    static let graphPathSegmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Percent-encode `value` as one strict path segment, or `nil` if it cannot
    /// be encoded.
    ///
    /// **Returns an optional rather than throwing, deliberately.** The main app
    /// surfaces this failure as `ProviderError.invalidURL(context)`, and
    /// `ProviderError` is declared in the main-app target
    /// (`TabMail/Providers/EmailProvider.swift`) — it is not visible from
    /// `Shared`, which the NSE also links. Handing each caller the `nil` lets
    /// both keep their own error domain unchanged while the allowed set and the
    /// encoding call itself exist exactly once.
    static func encodedGraphPathSegment(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: graphPathSegmentAllowed)
    }

    /// Walk a `$delta` pagination chain starting from `deltaLink` (or fresh
    /// delta endpoint on first sync) until the final page (carrying
    /// `@odata.deltaLink` = new cursor). Collapses all intermediate pages into
    /// one `HistoryDelta`.
    ///
    /// If the initial fetch fails with 410 Gone (stale delta link), returns nil
    /// so the caller can fall back to full sync.
    static func deltaWalk(
        http: AuthedHTTP,
        startURL: String,
        maxPages: Int = 50
    ) async throws -> HistoryDelta? {
        var nextLink: String? = startURL
        var allAdded: [DeltaMessageRef] = []
        var allRemoved: [DeltaMessageRef] = []
        var finalDeltaLink: String?
        var pagesWalked = 0
        var firstPage = true

        while let link = nextLink, pagesWalked < maxPages {
            let res = try await http.requestAllowing404(url: link)
            // 410 = delta link stale/expired.
            if firstPage, res.statusCode == 410 { return nil }
            if res.statusCode == 404, firstPage { return nil }
            firstPage = false

            guard let data = res.data,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HTTPError.networkError(statusCode: res.statusCode)
            }
            let page = GraphParse.parseDeltaPage(json)
            allAdded.append(contentsOf: page.added)
            allRemoved.append(contentsOf: page.removed)

            if let dLink = page.deltaLink {
                finalDeltaLink = dLink
                nextLink = nil
            } else {
                nextLink = page.nextLink
            }
            pagesWalked += 1
        }

        return HistoryDelta(
            cursor: finalDeltaLink ?? "",
            added: allAdded, removed: allRemoved,
            labelsAdded: [], labelsRemoved: []
        )
    }

    /// Convenience wrapper: fetch inbox delta from a stored deltaLink or fresh
    /// endpoint. Pass `deltaLink` for incremental; pass nil for a fresh anchor.
    static func inboxDelta(
        http: AuthedHTTP,
        deltaLink: String?,
        selectFields: String = "id"
    ) async throws -> HistoryDelta? {
        let startURL: String
        if let link = deltaLink, !link.isEmpty {
            startURL = link
        } else {
            startURL = "\(baseURL)/mailFolders/inbox/messages/delta?$select=\(selectFields)&$top=50"
        }
        return try await deltaWalk(http: http, startURL: startURL)
    }

    /// Fetch a single message's metadata. Graph returns header fields inline on
    /// `/messages/{id}` (no `format=metadata` equivalent needed).
    static func messageMetadata(http: AuthedHTTP, id: String) async throws -> MessageMetadata {
        guard let encodedId = encodedGraphPathSegment(id) else {
            throw HTTPError.invalidURL("Graph message id")
        }
        let selection = metadataSelection
        let url = "\(baseURL)/messages/\(encodedId)?\(selection.queryParameter)"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = GraphParse.parseMessage(json, selection: selection) else {
            throw HTTPError.networkError(statusCode: 0)
        }
        return metadata
    }

    /// Fetch a message with body + metadata. Returns the canonical
    /// (MessageMetadata, RenderedBody) tuple via shared `BodyRenderer`.
    /// Graph's `$expand=attachments` returns attachments inline — efficient for
    /// body rendering without a second round trip.
    static func messageFull(
        http: AuthedHTTP,
        id: String,
        contentKey: ContentKey? = nil,
        attachmentFetcher: BodyRenderer.AttachmentFetcher? = nil,
        icsRenderer: BodyRenderer.ICSRenderer? = nil
    ) async throws -> (MessageMetadata, RenderedBody) {
        guard let encodedId = encodedGraphPathSegment(id) else {
            throw HTTPError.invalidURL("Graph message id")
        }
        let selection = fullSelection
        let url = "\(baseURL)/messages/\(encodedId)?\(selection.queryParameter)&$expand=attachments"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = GraphParse.parseMessage(json, selection: selection) else {
            throw HTTPError.networkError(statusCode: 0)
        }
        let (rawHtml, rawText) = GraphParse.extractBody(from: json)
        let attArray = json["attachments"] as? [[String: Any]]
        let attachments = GraphParse.extractAttachmentRefs(from: attArray)
        // Graph's `$expand=attachments` already inlines `contentBytes` on
        // each FileAttachment, so CID inline images come back in the same
        // messageFull response — no second roundtrip. Cap at the shared
        // `BodyRenderer.maxInlineImages` so both main-app and NSE decode
        // the same subset.
        let inlineImages = Array(
            GraphParse.extractInlineImageRefs(from: attArray).prefix(BodyRenderer.maxInlineImages)
        )
        let ingredients = RawBodyIngredients(
            rawHTML: rawHtml, rawText: rawText,
            attachments: attachments, inlineImages: inlineImages,
            icsData: nil
        )
        // Bind the inline-image writer once per render — same factory that
        // IMAP and Gmail paths use, so behavior is identical across providers
        // *and* across targets (main app + NSE). `contentKey == nil` → data URIs.
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

    /// Fetch raw attachment bytes by attachment id.
    static func attachment(http: AuthedHTTP, messageId: String, attachmentId: String) async throws -> Data {
        guard let encodedMessageId = encodedGraphPathSegment(messageId) else {
            throw HTTPError.invalidURL("Graph message id")
        }
        guard let encodedAttachmentId = encodedGraphPathSegment(attachmentId) else {
            throw HTTPError.invalidURL("Graph attachment id")
        }
        let url = "\(baseURL)/messages/\(encodedMessageId)/attachments/\(encodedAttachmentId)"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["contentBytes"] as? String,
              let bytes = Data(base64Encoded: b64) else {
            throw HTTPError.networkError(statusCode: 0)
        }
        return bytes
    }

    // NOTE — THIS SURFACE IS DELIBERATELY READ-ONLY. It used to carry `patch`
    // (isRead / categories / flag) and `move`. Both had ZERO callers on every
    // target, and they were DELETED rather than encoded, because the NSE has no
    // business mutating the user's mailbox: it enriches a delivered
    // notification, and every provider mutation in this app goes through the
    // durable `PendingOperation` queue in the main app, which the extension
    // process cannot drain. The live NSE consumers call `messageMetadata` and
    // `messageFull`; neither needs mailbox mutation. `inboxDelta` and its
    // `deltaWalk` helper currently have no production caller, but that narrower
    // negative case does not make the live read surface dead. The absence of
    // mutation methods is what makes this shared API read-only rather than
    // merely intended.
    //
    // If a Graph mutation is ever genuinely needed from shared code, it must be
    // reintroduced with `encodedGraphPathSegment` applied to every id, as the
    // read helpers above do.
}
