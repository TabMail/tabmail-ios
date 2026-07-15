/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Shared body fetch + render logic used by both ActiveBodyQueue (forward/inbox)
/// and BackfillBodyQueue (backward/all folders).
///
/// Two-phase pipeline per message:
/// 1. **Fetch** (provider-bound): provider.fetchMessage → render body (CID, ICS)
///    Provider owns concurrency — IMAP pool, Gmail/Exchange HTTP limits.
/// 2. **Process** (DB-bound): write MessageBody + FTS + snippet + flags + queue AI/embedding
///
/// Queues pipeline these: while processing result N, fetch N+1 is already in flight.
enum BodyFetchProcessor {

    struct Item: Sendable {
        let headerId: String
        let accountId: String
        let folderPath: String
        let messageId: String
        let isInInbox: Bool
    }

    enum Result: Sendable, Error {
        case success
        case confirmedEmpty
        case retry
        case payloadTooLarge
    }

    /// Fetch phase: provider.fetchMessage + render body. Provider-bound (network I/O).
    /// Returns the rendered MessageBody and extracted plain text, or an error result.
    struct FetchResult: Sendable {
        let item: Item
        let renderedBody: MessageBody
        let plainText: String?
        let hasAttachments: Bool
        /// True when the message carries a `text/calendar` (invite) part whose ICS
        /// bytes this render had to fetch on demand but couldn't get this attempt
        /// (transient). `process` routes this to retry instead of caching an empty
        /// attachment-only body. See `RenderedBody.hasUnresolvedICS`.
        let hasUnresolvedICS: Bool
    }

    /// Fetch + render a single message. Provider gates concurrency.
    /// Call from a Task — the provider's pool/throttle serializes as needed.
    static func fetch(
        item: Item,
        provider: any EmailProvider
    ) async -> Swift.Result<FetchResult, Result> {
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let fullMessage = try await provider.fetchMessage(id: item.messageId, folder: item.folderPath)
            let fetchMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if fetchMs > 500 {
                print("[BodyFetch] Single fetch slow: \(item.messageId) took \(fetchMs)ms")
            }

            // Diagnostic: log raw provider output when the fetch comes back without
            // any text body. This lets us distinguish a server-side empty (provider
            // returned nothing) from a parser drop (renderer/EmailFilter ate real
            // content) before BodyFetchProcessor.process flips bodyEmptyConfirmed.
            let rawHtmlLen = fullMessage.htmlBody?.count ?? 0
            let rawTextLen = fullMessage.textBody?.count ?? 0
            if rawHtmlLen == 0 && rawTextLen == 0 {
                print("[BodyFetch] RAW empty \(item.messageId) folder=\(item.folderPath) attachments=\(fullMessage.attachments.count) inline=\(fullMessage.inlineImages.count) ics=\(fullMessage.icsData != nil) tookMs=\(fetchMs)")
            }

            let fetchAttachment = buildAttachmentFetcher(
                accountId: item.accountId, messageId: item.messageId, folderPath: item.folderPath
            )
            let (renderedBody, plainText, hasUnresolvedICS) = await renderBody(
                headerId: item.headerId,
                fullMessage: fullMessage,
                fetchAttachment: fetchAttachment
            )

            // Diagnostic: parser dropped raw content. If we got bytes from the
            // provider but extractPlainText returned nil/empty, the renderer or
            // EmailFilter is eating real content (e.g., unusual MIME shape, charset
            // decode failure, all-tags HTML). Log a sample so we can reproduce.
            if (rawHtmlLen > 0 || rawTextLen > 0) && (plainText?.isEmpty ?? true) && DebugModeManager.isLoggingEnabled() {
                let renderedLen = renderedBody.htmlContent?.count ?? 0
                let htmlSample = String((fullMessage.htmlBody ?? "").prefix(200))
                let textSample = String((fullMessage.textBody ?? "").prefix(200))
                print("[BodyFetch] PARSER DROPPED \(item.messageId) folder=\(item.folderPath) rawHtmlLen=\(rawHtmlLen) rawTextLen=\(rawTextLen) renderedHtmlLen=\(renderedLen) htmlSample=\(htmlSample.debugDescription) textSample=\(textSample.debugDescription)")
            }

            return .success(FetchResult(
                item: item,
                renderedBody: renderedBody,
                plainText: plainText,
                hasAttachments: !fullMessage.attachments.isEmpty,
                hasUnresolvedICS: hasUnresolvedICS
            ))
        } catch {
            let desc = "\(error)"
            if desc.contains("PayloadTooLargeError") {
                print("[BodyFetch] Body too large for \(item.messageId) — exceeds buffer")
                do {
                    try await AppDatabase.dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET bodyEmptyConfirmed = 1 WHERE id = ?",
                            arguments: [item.headerId]
                        )
                    }
                } catch {
                    // ADR-IOS-046: a suspension abort here is expected + retryable —
                    // don't log it as a failure (BodyFetchProcessor writes run on
                    // background backfill paths that can suspend mid-flight).
                    if !error.isDatabaseSuspensionAbort {
                        print("[BodyFetch] Failed to flag payload-too-large \(item.headerId.prefix(30)): \(error)")
                    }
                }
                return .failure(.payloadTooLarge)
            } else {
                print("[BodyFetch] Fetch failed for \(item.messageId): \(error)")
                return .failure(.retry)
            }
        }
    }

    /// Data returned from process for batched FTS writes.
    struct ProcessedItem: Sendable {
        let headerId: String
        let accountId: String
        let isInInbox: Bool
        let body: String
        let snippet: String
    }

    /// Process phase: write MessageBody to GRDB, return data for batched FTS write.
    /// FTS writes are deferred to the caller for batching (avoids per-item FTS overhead).
    ///
    /// MessageBody is only written when content exists (text or attachments).
    /// Empty fetches require three consecutive attempts before confirming — a single
    /// empty IMAP response can be a partial result (connection drop, BGTask
    /// cancellation, server delay) and must not permanently mark a message as empty.
    static func process(
        fetchResult: FetchResult,
        enableAI: Bool
    ) async -> (Result, ProcessedItem?) {
        let item = fetchResult.item
        let dbPool = AppDatabase.dbPool
        let bodyToInsert = fetchResult.renderedBody

        // Branch on content — only write MessageBody when we have actual content.
        if let plainText = fetchResult.plainText, !plainText.isEmpty {
            // Has text content — write body and return data for FTS batching.
            do {
                try await dbPool.write { db in
                    try bodyToInsert.insert(db, onConflict: .ignore)
                }
            } catch {
                // ADR-IOS-046: suspension aborts are expected + retryable (bodyComplete
                // stays 0 → re-fetched next wake); only log genuine failures.
                if !error.isDatabaseSuspensionAbort {
                    print("[BodyFetch] MessageBody insert failed for \(item.headerId.prefix(30)): \(error)")
                }
            }
            let snippet = EmailFilter.snippetFromPlainText(plainText)
            let processed = ProcessedItem(
                headerId: item.headerId,
                accountId: item.accountId,
                isInInbox: item.isInInbox,
                body: plainText,
                snippet: snippet
            )
            return (.success, processed)

        } else if fetchResult.hasAttachments && !fetchResult.hasUnresolvedICS {
            // No text but has attachments — write body (attachment metadata) and route
            // through flushBatch so FTS gets a placeholder entry and bodyComplete is
            // only set after FTS membership is confirmed (writtenToFts gate).
            // Setting bodyComplete=1 without an FTS row leaves the message permanently
            // stuck in the AI queue (drops with notInFtsIndex).
            //
            // `!hasUnresolvedICS` guard: a calendar invite's text/calendar part is
            // itself an attachment, so `hasAttachments` is true for invites. If its
            // ICS bytes failed to resolve this attempt, falling in here would persist
            // an attachment-only body with empty HTML — the detail view then shows
            // "This message has no content." permanently. Instead let it fall to the
            // retry path below (bounded by emptyFetchCount) so a later fetch renders
            // the invite. (Invites that ALSO carry a text/HTML body have non-empty
            // plainText and were already handled by the first branch.)
            do {
                try await dbPool.write { db in
                    try bodyToInsert.insert(db, onConflict: .ignore)
                }
            } catch {
                if !error.isDatabaseSuspensionAbort {
                    print("[BodyFetch] Attachment-only MessageBody insert failed for \(item.headerId.prefix(30)): \(error)")
                }
            }
            let placeholder = "[attachment]"
            let processed = ProcessedItem(
                headerId: item.headerId,
                accountId: item.accountId,
                isInInbox: item.isInInbox,
                body: placeholder,
                snippet: placeholder
            )
            return (.success, processed)

        } else {
            // No usable text/HTML body. Two cases land here:
            //  (a) a genuinely empty message (no text, no attachments), or
            //  (b) a calendar invite whose ICS bytes we couldn't resolve this attempt
            //      (`hasUnresolvedICS`) — see the guard on the branch above.
            // BOTH are treated as retryable: guard against false empties (partial IMAP
            // response, BGTask cancellation, transient ICS attachment-fetch failure) by
            // incrementing emptyFetchCount and only confirming empty after 2+ misses.
            // bodyComplete stays 0 so the background queue re-enqueues for retry. We
            // must NEVER persist an empty/attachment-only body for an unresolved invite.
            if fetchResult.hasUnresolvedICS && DebugModeManager.isLoggingEnabled() {
                print("[BodyFetch] Unresolved ICS for \(item.headerId.prefix(30)) — retrying, will not cache empty body")
            }
            let currentCount = (try? await dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT emptyFetchCount FROM messageHeader WHERE id = ?", arguments: [item.headerId])
            }) ?? 0

            if currentCount >= 2 {
                // Third+ empty fetch — confirmed empty. Write empty body for UI and set flags.
                do {
                    try await dbPool.write { db in
                        try bodyToInsert.insert(db, onConflict: .ignore)
                        try db.execute(
                            sql: """
                                UPDATE messageHeader
                                SET bodyEmptyConfirmed = 1,
                                    bodyComplete = 1,
                                    emptyFetchCount = emptyFetchCount + 1,
                                    summaryBlurb = 'This message has no content.',
                                    actionTag = ?,
                                    tagSortOrder = ?,
                                    actionTagSetAt = ?,
                                    embeddingComplete = 1
                                WHERE id = ?
                            """,
                            arguments: [ActionTag.delete.rawValue, ActionTag.delete.sortOrder, Date(), item.headerId]
                        )
                    }
                } catch {
                    if !error.isDatabaseSuspensionAbort {
                        print("[BodyFetch] Confirmed-empty flag write failed for \(item.headerId.prefix(30)): \(error)")
                    }
                }
                return (.confirmedEmpty, nil)
            } else {
                // First empty fetch — increment counter but leave bodyComplete = 0
                // so the background queue re-enqueues for retry on next cycle.
                // Don't write empty body or set bodyEmptyConfirmed.
                print("[BodyFetch] First empty fetch for \(item.headerId.prefix(30)) — will confirm on next attempt")
                do {
                    try await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET emptyFetchCount = emptyFetchCount + 1 WHERE id = ?",
                            arguments: [item.headerId]
                        )
                    }
                } catch {
                    if !error.isDatabaseSuspensionAbort {
                        print("[BodyFetch] emptyFetchCount increment failed for \(item.headerId.prefix(30)): \(error)")
                    }
                }
                return (.retry, nil)
            }
        }
    }

    /// Flush a batch of processed items to FTS + GRDB flags in one go.
    /// Batching FTS writes avoids per-item FTS5 index maintenance overhead.
    static func flushBatch(_ items: [ProcessedItem], enableAI: Bool) async {
        guard !items.isEmpty else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let dbPool = AppDatabase.dbPool

        // 1. Batch FTS write — returns which headerIds were actually written.
        // Items not yet in FTS index are skipped (bodyComplete stays 0 for retry).
        let tFts = CFAbsoluteTimeGetCurrent()
        let ftsBuffer = items.map { (headerId: $0.headerId, body: $0.body) }
        let writtenToFts: Set<String>
        do {
            writtenToFts = try await SearchIndex.shared.updateBodies(ftsBuffer)
        } catch {
            // ADR-IOS-046: a suspension abort is expected + benign here — bodyComplete
            // stays 0, the next wake's repopulate retries. Only log real failures.
            if !error.isDatabaseSuspensionAbort {
                print("[BodyFetch] Batch FTS write failed (\(items.count) items): \(error)")
            }
            // Items already have MessageBody in GRDB. bodyComplete stays 0.
            // Next repopulate will retry.
            return
        }
        let ftsMs = Int((CFAbsoluteTimeGetCurrent() - tFts) * 1000)

        let skippedCount = items.count - writtenToFts.count
        if skippedCount > 0 {
            let skippedItems = items.filter { !writtenToFts.contains($0.headerId) }
            let accountIds = Set(skippedItems.map(\.accountId)).sorted().joined(separator: ",")
            print("[BodyFetch] flushBatch: \(skippedCount)/\(items.count) items not in FTS yet — bodyComplete deferred (accounts=[\(accountIds)])")
        }

        // 2. Batch GRDB flag update (snippets + bodyComplete) — ONLY for items written to FTS.
        // Items skipped by FTS keep bodyComplete=0 so body fetch queue retries them.
        let tDb = CFAbsoluteTimeGetCurrent()
        let confirmedItems = items.filter { writtenToFts.contains($0.headerId) }
        do {
            try await dbPool.write { db in
                for item in confirmedItems {
                    // Reset missFetchCount=0 on success: a prior run may have accumulated
                    // misses against this header (e.g. IMAP flap). Now that we have real
                    // content, the miss chain is broken — start counting fresh next time.
                    try db.execute(
                        sql: "UPDATE messageHeader SET snippet = ?, bodyComplete = 1, missFetchCount = 0 WHERE id = ?",
                        arguments: [item.snippet, item.headerId]
                    )
                }
            }
        } catch {
            if !error.isDatabaseSuspensionAbort {
                print("[BodyFetch] flushBatch snippet/bodyComplete write failed (\(confirmedItems.count) items): \(error)")
            }
        }
        let dbMs = Int((CFAbsoluteTimeGetCurrent() - tDb) * 1000)

        // 3. Enqueue downstream processing — only for items actually written to FTS.
        for item in confirmedItems {
            if enableAI && item.isInInbox {
                await ActiveAIQueue.shared.enqueue(headerId: item.headerId, accountId: item.accountId)
            }
            if enableAI {
                await ActiveEmbeddingQueue.shared.enqueue(headerId: item.headerId)
            } else {
                await BackfillEmbeddingQueue.shared.enqueue(headerId: item.headerId)
            }
        }

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[BodyFetch] flushBatch: \(items.count) items (\(writtenToFts.count) written) in \(totalMs)ms (fts=\(ftsMs)ms, db=\(dbMs)ms)")
    }

    /// Render a pre-fetched FullMessageInfo into a FetchResult.
    /// Used by batch fetch path — the provider fetch already happened in bulk.
    /// Handles CID resolution, ICS calendar parsing, plain text extraction.
    static func renderFetched(
        item: Item,
        fullMessage: FullMessageInfo
    ) async -> Swift.Result<FetchResult, Result> {
        let t0 = CFAbsoluteTimeGetCurrent()

        let fetchAttachment = buildAttachmentFetcher(
            accountId: item.accountId, messageId: item.messageId, folderPath: item.folderPath
        )
        let (renderedBody, plainText, hasUnresolvedICS) = await renderBody(
            headerId: item.headerId,
            fullMessage: fullMessage,
            fetchAttachment: fetchAttachment
        )

        let renderMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if renderMs > 200 {
            print("[BodyFetch] renderFetched: \(item.messageId) slow render: \(renderMs)ms")
        }

        return .success(FetchResult(
            item: item,
            renderedBody: renderedBody,
            plainText: plainText,
            hasAttachments: !fullMessage.attachments.isEmpty,
            hasUnresolvedICS: hasUnresolvedICS
        ))
    }

    /// Combined fetch + process for single-item callers (user-open path).
    /// Flushes FTS immediately (no batching needed for single items).
    static func fetchAndProcess(
        item: Item,
        provider: any EmailProvider,
        enableAI: Bool
    ) async -> Result {
        let fetchResult = await fetch(item: item, provider: provider)
        switch fetchResult {
        case .success(let result):
            let (outcome, processed) = await process(fetchResult: result, enableAI: enableAI)
            if let processed {
                await flushBatch([processed], enableAI: enableAI)
            }
            return outcome
        case .failure(let result):
            return result
        }
    }

    // MARK: - Body Rendering

    /// Render a FullMessageInfo into a MessageBody.
    /// Delegates to the shared `BodyRenderer` — single source of truth for CID
    /// resolution, ICS handling, and plain-text extraction. Main app supplies an
    /// `ICSBuilder`-backed icsRenderer and the provider-specific attachment fetcher.
    static func renderBody(
        headerId: String,
        fullMessage: FullMessageInfo,
        fetchAttachment: (@Sendable (String, String?) async throws -> Data)? = nil
    ) async -> (body: MessageBody, plainText: String?, hasUnresolvedICS: Bool) {
        // Convert main-app FullMessageInfo → shared RawBodyIngredients.
        let sharedAttachments = fullMessage.attachments.map {
            AttachmentRef(
                filename: $0.filename, contentType: $0.contentType,
                section: $0.section, size: $0.size, encoding: $0.encoding
            )
        }
        let sharedInlineImages = fullMessage.inlineImages.map {
            InlineImageRef(contentId: $0.contentId, contentType: $0.contentType, data: $0.data)
        }
        let ingredients = RawBodyIngredients(
            rawHTML: fullMessage.htmlBody, rawText: fullMessage.textBody,
            attachments: sharedAttachments, inlineImages: sharedInlineImages,
            icsData: fullMessage.icsData
        )

        // Main-app ICS renderer: parse + build invite HTML via ICSBuilder.
        let icsRenderer: BodyRenderer.ICSRenderer = { icsText in
            guard let invite = ICSBuilder.parseIncoming(icsText) else { return nil }
            return ICSBuilder.buildIncomingInviteBody(invite)
        }

        // Single source of the writer — same factory the NSE clients use.
        // Both targets call `BodyAssetStore.makeInlineImageWriter(forHeaderId:)`,
        // so persisted assets land at the same paths and the rendered HTML
        // references identical `tabmail-asset://` URLs across targets.
        let inlineImageWriter = BodyAssetStore.makeInlineImageWriter(forHeaderId: headerId)
        let rendered = await BodyRenderer.render(
            ingredients: ingredients,
            attachmentFetcher: fetchAttachment,
            icsRenderer: icsRenderer,
            inlineImageWriter: inlineImageWriter
        )

        // `rendered.htmlContent` is already display-ready (BodyRenderer is the single
        // conversion authority — plain-text bodies were converted to HTML there), so
        // create() just stores it: no re-conversion, no double-escape. The canonical
        // plain text for snippet/FTS is `rendered.textContent`, returned to the caller
        // (NOT re-derived from htmlContent, which would round-trip plain→HTML→plain).
        var body = MessageBody.create(headerId: headerId, htmlBody: rendered.htmlContent)
        // Diagnostic (debug-gated, no-op in prod): flag if a double-escaped body ever
        // reaches storage. Captured in body_render.log (DebugMenu › Logs).
        BackgroundSyncLogger.diagnoseStoredBody(source: "BodyFetch", headerId: headerId, htmlContent: body.htmlContent)
        if !fullMessage.attachments.isEmpty {
            body.attachmentsJSON = String(data: (try? JSONEncoder().encode(fullMessage.attachments)) ?? Data(), encoding: .utf8)
        }
        body.icsText = rendered.icsText
        return (body, rendered.textContent, rendered.hasUnresolvedICS)
    }

    // MARK: - Helpers

    private static func buildAttachmentFetcher(
        accountId: String, messageId: String, folderPath: String
    ) -> @Sendable (String, String?) async throws -> Data {
        return { section, encoding in
            let queue = await AccountManager.shared.workQueues[accountId]
            guard let queue else { throw ProviderError.notConnected }
            let provider = queue.provider

            return try await queue.execute(priority: .bodyFetch) {
                if let imap = provider as? IMAPProvider {
                    return try await imap.fetchAttachment(messageId: messageId, folder: folderPath, section: section, encoding: encoding)
                } else if let gmail = provider as? GmailProvider {
                    return try await gmail.fetchAttachment(messageId: messageId, attachmentId: section)
                } else if let exchange = provider as? ExchangeProvider {
                    return try await exchange.fetchAttachment(messageId: messageId, attachmentId: section)
                }
                throw ProviderError.notConnected
            }
        }
    }
}
