/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// =============================================================================
// KEEP — PHASE-B SCAFFOLDING (Outlook NSE). DO NOT DELETE AS "DEAD CODE".
// =============================================================================
// Shared Microsoft Graph REST surface consumed by both the main-app
// `ExchangeProvider` AND the (not-yet-implemented) `OutlookNSEClient`. The main
// app currently still uses its own inline `request(path:)`; piecewise migration
// will route it through these functions, same pattern as Gmail did in commits
// 2b2249a / a281ce9.
//
// Round-3 dead-code audit (commit d1437c3) deleted this file because it had
// "zero callers" in main-app code. That was wrong — callers don't exist yet
// because the NSE side hasn't been built. Infra lands first so the NSE is a
// thin orchestrator, not a re-implementation. This shared provider API layer
// is intentional architecture (LOCKED 2026-04-12).
//
// This banner exists to prevent the same mistake. If you're tempted to delete
// methods here because they have no callers today, check whether a phase-B
// NSE consumer will need them before removing.
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
    static let headerOnlyFields =
        "id,subject,from,toRecipients,ccRecipients,bccRecipients,replyTo,"
        + "receivedDateTime,isRead,flag,hasAttachments,internetMessageId,"
        + "conversationId,categories,bodyPreview"

    /// Header fields + `parentFolderId`. Used for single-message metadata
    /// fetches (NSE push + main-app delta sync that needs to assign the
    /// message to its server-side folder).
    static let metadataSelectFields = "\(headerOnlyFields),parentFolderId"

    /// Header fields + `body` (no `parentFolderId`). Used by unified
    /// backfill that grabs headers and body in one API round-trip within
    /// a known folder context.
    static let backfillSelectFields = "\(headerOnlyFields),body"

    /// Everything — headers + body + `parentFolderId`. Used for single-
    /// message full fetches (main-app `fetchMessage`, NSE `messageFull`).
    static let fullSelectFields = "\(headerOnlyFields),body,parentFolderId"

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
        let url = "\(baseURL)/messages/\(id)?$select=\(metadataSelectFields)"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = GraphParse.parseMessage(json) else {
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
        let url = "\(baseURL)/messages/\(id)?$select=\(fullSelectFields)&$expand=attachments"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = GraphParse.parseMessage(json) else {
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
        let url = "\(baseURL)/messages/\(messageId)/attachments/\(attachmentId)"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["contentBytes"] as? String,
              let bytes = Data(base64Encoded: b64) else {
            throw HTTPError.networkError(statusCode: 0)
        }
        return bytes
    }

    /// PATCH a message — used for isRead flip, category add/remove, flag set.
    static func patch(http: AuthedHTTP, messageId: String, body: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await http.patch("\(baseURL)/messages/\(messageId)", body: data)
    }

    /// Move a message to a different folder.
    static func move(http: AuthedHTTP, messageId: String, destinationFolderId: String) async throws {
        let body: [String: Any] = ["destinationId": destinationFolderId]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await http.post("\(baseURL)/messages/\(messageId)/move", body: data)
    }
}
