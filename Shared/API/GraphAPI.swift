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

    /// The state of a message, without its header fields: what the change
    /// reader's message delta selects for every folder but the Inbox. Applying a
    /// change to a message the phone holds needs nothing else (read state, flag);
    /// `receivedDateTime` tells a new or moved-in message apart from a bare
    /// update, and the headers of a message the phone does not hold are fetched
    /// separately (`metadataSelection`). A delta round keeps the `$select` it
    /// started with, so this is chosen when a folder's round chain starts.
    static let stateSelection = GraphMessageSelection(fields: [
        "id", "isRead", "flag", "receivedDateTime", "categories"
    ])

    /// Graph JSON batching endpoint. Each request in a batch names its URL
    /// relative to the version root, so a mailbox request starts with
    /// `batchItemPathPrefix`.
    static let batchURL = "https://graph.microsoft.com/v1.0/$batch"
    static let batchItemPathPrefix = "/me"

    /// Attachment metadata, without the bytes. Listed without `$select`, Graph
    /// returns every file attachment's bytes (`contentBytes`, base64) with the
    /// list; learn.microsoft.com/graph/outlook-large-attachments (Step 4) asks
    /// for a `$select` that leaves `contentBytes` out. `contentId` belongs to the
    /// derived `fileAttachment` type, and Graph refuses it unqualified in a
    /// `$select` on the base attachment type (400), so an inline image's content
    /// id comes with its bytes from that attachment's own GET. Used by main-app
    /// `fetchMessage` and NSE `messageFull`.
    static let attachmentMetadataQuery = "$select=id,name,contentType,size,isInline"

    /// Pages of one message's attachment list read before giving up. Graph caps a
    /// message at 150 MB, so a real list ends long before; the cap only stops a
    /// list that never does.
    static let maxAttachmentListPages = 50

    /// Whether a page link (`@odata.nextLink`) is one this client may send its
    /// token to: https on graph.microsoft.com, default port, no user info. A link
    /// that is not is refused before any request.
    static func isGraphPageLink(_ url: String) -> Bool {
        guard let components = URLComponents(string: url) else { return false }
        return components.scheme == "https"
            && components.host?.lowercased() == "graph.microsoft.com"
            && components.user == nil
            && components.password == nil
            && (components.port == nil || components.port == 443)
    }

    // MARK: - Path-segment encoding (single source of truth for BOTH targets)

    /// Percent-encode `value` as one strict path segment, or `nil` if it cannot
    /// be encoded.
    ///
    /// Graph resource ids (message ids, attachment ids, folder ids) are opaque
    /// server-minted strings. Interpolating one raw into a URL lets `/`, `?`,
    /// `#`, `+` or `=` inside it change which **route** the server selects, so
    /// every id is encoded as exactly one path segment, leaving only the RFC
    /// 3986 unreserved characters bare (`StrictPercentEncoding`, the single
    /// definition of that set for the app and the extension).
    ///
    /// **Returns an optional rather than throwing, deliberately.** The main app
    /// surfaces this failure as `ProviderError.invalidURL(context)`, and
    /// `ProviderError` is declared in the main-app target
    /// (`TabMail/Providers/EmailProvider.swift`) — it is not visible from
    /// `Shared`, which the NSE also links. Handing each caller the `nil` lets
    /// both keep their own error domain unchanged while the allowed set is
    /// defined once. (`ExchangeProvider`'s `$search` value is encoded with the
    /// same set.)
    static func encodedGraphPathSegment(_ value: String) -> String? {
        StrictPercentEncoding.component(value)
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
    /// Attachments are listed as metadata only (`attachmentMetadataQuery`). When
    /// the body has a `cid:` reference, the listed inline images' bytes are
    /// fetched once each (`fetchInlineImages`); no other attachment's bytes are
    /// fetched. A failed listing fails the call, so no body is staged without
    /// its attachment list.
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
        let url = "\(baseURL)/messages/\(encodedId)?\(selection.queryParameter)"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = GraphParse.parseMessage(json, selection: selection) else {
            throw HTTPError.networkError(statusCode: 0)
        }
        let (rawHtml, rawText) = GraphParse.extractBody(from: json)
        let listed = try await attachmentList(http: http, encodedMessageId: encodedId)
        let attachments = GraphParse.extractAttachmentRefs(from: listed)
        let inlineImages = await fetchInlineImages(http: http, messageId: id, listed: listed, html: rawHtml)
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

    /// One attachment of a message, as Graph returns it: a file attachment
    /// carries its `contentId`, `isInline` and bytes (`contentBytes`).
    static func attachment(
        http: AuthedHTTP, messageId: String, attachmentId: String
    ) async throws -> [String: Any] {
        guard let encodedMessageId = encodedGraphPathSegment(messageId) else {
            throw HTTPError.invalidURL("Graph message id")
        }
        guard let encodedAttachmentId = encodedGraphPathSegment(attachmentId) else {
            throw HTTPError.invalidURL("Graph attachment id")
        }
        let url = "\(baseURL)/messages/\(encodedMessageId)/attachments/\(encodedAttachmentId)"
        let data = try await http.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.networkError(statusCode: 0)
        }
        return json
    }

    /// A message's attachments, metadata only (`attachmentMetadataQuery`), every
    /// page. A list that does not end within `maxAttachmentListPages` pages, or
    /// whose next link is not a Graph page link, throws rather than return part
    /// of it.
    private static func attachmentList(
        http: AuthedHTTP, encodedMessageId: String
    ) async throws -> [[String: Any]] {
        var next: String? = "\(baseURL)/messages/\(encodedMessageId)/attachments?\(attachmentMetadataQuery)"
        var listed: [[String: Any]] = []
        var pages = 0
        while let url = next {
            guard pages < maxAttachmentListPages else { throw HTTPError.networkError(statusCode: 0) }
            guard isGraphPageLink(url) else { throw HTTPError.invalidURL("Graph pagination") }
            let data = try await http.get(url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = json["value"] as? [[String: Any]] else {
                throw HTTPError.networkError(statusCode: 0)
            }
            listed += value
            next = json["@odata.nextLink"] as? String
            pages += 1
        }
        return listed
    }

    /// The listed inline images (`isInline`, `image/*`), each fetched once by id
    /// when the HTML body has a `cid:` reference (case-insensitive), until
    /// `BodyRenderer.maxInlineImages` are resolved (the main app's
    /// `ExchangeProvider.readMessage` applies the same rule). The list cannot
    /// carry a content id, so which image a `cid:` names is known only after its
    /// GET. An image that fails to fetch, or comes back without bytes or a
    /// content id, is left out, so a `cid:` naming it stays unresolved and the
    /// main app fetches the body again.
    private static func fetchInlineImages(
        http: AuthedHTTP, messageId: String, listed: [[String: Any]], html: String?
    ) async -> [InlineImageRef] {
        guard html?.range(of: "cid:", options: .caseInsensitive) != nil else { return [] }
        var images: [InlineImageRef] = []
        for entry in listed where images.count < BodyRenderer.maxInlineImages {
            guard (entry["isInline"] as? Bool) == true,
                  let contentType = entry["contentType"] as? String,
                  contentType.lowercased().hasPrefix("image/"),
                  let id = entry["id"] as? String else { continue }
            do {
                let attachment = try await attachment(http: http, messageId: messageId, attachmentId: id)
                if let image = GraphParse.extractInlineImageRefs(from: [attachment]).first {
                    images.append(image)
                }
            } catch {
                // Debug-gated with `#if DEBUG`: `Shared/` also builds into the
                // notification service extension, which has no `DebugModeManager`.
                #if DEBUG
                print("[GraphAPI] Inline image fetch failed: \(error)")
                #endif
            }
        }
        return images
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
