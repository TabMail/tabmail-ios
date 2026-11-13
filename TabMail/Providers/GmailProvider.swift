/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

/// Actor-owned ordering state for Gmail's `/labels` catalog. Kept as a small
/// value type so out-of-order response handling can be tested deterministically
/// without reproducing URLSession scheduling.
///
/// PORT — `v2final:TabMail/Providers/GmailProvider.swift`
/// `GmailUserLabelCatalogState` (commit `a75196398`), taken whole. The three
/// pieces are load-bearing together and none may be dropped:
///
///  - `knownUserLabelIds` is a POSITIVE allowlist. Gmail user labels carry
///    opaque ids (`Label_42`) drawn from the same namespace Gmail assigns to
///    its own auto-created labels, so a message's `labelIds` array cannot be
///    classified from the id alone. Only a complete `/labels` response — which
///    carries the DISPLAY NAMES — can say which opaque ids are user labels.
///  - `mutationRevision` is the guard that keeps the allowlist from going
///    stale: a `/labels` listing that was issued BEFORE a `createLabel` /
///    `findLabelByName` discovery must not replace the newer knowledge, so a
///    response whose recorded revision no longer matches unions instead of
///    replacing. An allowlist without this is a stale allowlist that silently
///    forgets a label the user just created.
///  - `isAuthoritative` distinguishes "the provider reports no user labels" from
///    "the catalog has not loaded yet". Before the first complete catalog the
///    extracted set is empty for the SECOND reason, and any consumer that
///    treats an empty remote set as an exact remote truth must fail closed.
struct GmailUserLabelCatalogState: Sendable {
    struct Request: Sendable, Equatable {
        fileprivate let generation: Int
        fileprivate let mutationRevision: Int
    }

    private(set) var knownUserLabelIds: Set<String> = []
    private(set) var legacyTmLabelIds: Set<String> = []
    private(set) var isAuthoritative = false
    private var mutationRevision = 0
    private var nextRequestGeneration = 0
    private var latestAppliedRequestGeneration = 0

    mutating func beginRequest() -> Request {
        nextRequestGeneration &+= 1
        return Request(
            generation: nextRequestGeneration,
            mutationRevision: mutationRevision
        )
    }

    mutating func apply(
        userLabelIds: Set<String>,
        legacyTmLabelIds: Set<String>,
        request: Request
    ) {
        guard request.generation > latestAppliedRequestGeneration else { return }
        if mutationRevision == request.mutationRevision {
            knownUserLabelIds = userLabelIds
        } else {
            knownUserLabelIds.formUnion(userLabelIds)
        }
        self.legacyTmLabelIds = legacyTmLabelIds
        isAuthoritative = true
        latestAppliedRequestGeneration = request.generation
    }

    mutating func recordKnownUserLabel(_ labelId: String) {
        knownUserLabelIds.insert(labelId)
        mutationRevision &+= 1
    }

    /// Extract user label IDs from a Gmail message's `labelIds`, keeping only
    /// ids the catalog has POSITIVELY confirmed are user labels and dropping
    /// legacy `tm_*` ids (ADR-IOS-036 decay — otherwise messages still tagged
    /// server-side from pre-ADR installs round-trip the id into
    /// `MessageUserLabel` junction rows until `move()`'s inbox-exit cleanup
    /// strips them).
    ///
    /// This REPLACES the v3 base's negative `!UserLabelStore.isGmailSystemLabel(id:)`
    /// predicate, which was handed the bare label id as BOTH the id and the
    /// name — so `UserLabelStore.shouldExcludeLabel`'s `Label_N` name pattern
    /// matched every GENUINE Gmail user label as well as the auto-created ones
    /// it was aimed at, and Gmail user-label membership never reached GRDB at
    /// all. Only a complete `/labels` response carries the display names that
    /// separate the two, which is exactly what this allowlist is built from.
    func extractUserLabelIds(from labelIds: [String]?) -> [String] {
        (labelIds ?? []).filter { labelId in
            !legacyTmLabelIds.contains(labelId) && knownUserLabelIds.contains(labelId)
        }
    }
}

/// Gmail API-based provider for Google accounts.
/// Uses Gmail REST API for all operations — strictly better than IMAP for Gmail.
actor GmailProvider: EmailProvider {
    /// Synthetic folder path for Gmail's "All Mail" (archive). Gmail has no real archive label.
    static let archivePath = "__GMAIL_ALL_MAIL__"

    /// Query-exclusion translation of the synthetic All Mail folder: messages not
    /// in inbox, sent, trash, spam, or drafts. Every folder-scoped method MUST use
    /// this (and omit `labelIds`) when `folder == archivePath` — the synthetic path
    /// is not a real Gmail label ID and the API rejects it with 400 "Invalid label".
    static let allMailExclusionQuery = allMailExcludedLabelIds.map { "-in:\($0.lowercased())" }.joined(separator: " ")

    /// The system labels whose presence keeps a message OUT of the synthetic All
    /// Mail folder. The single source of All Mail membership: the listing query
    /// above is built from it, and the history delta asks
    /// `folder(_:containsMessageWithLabels:)`, so listing and delta apply one rule.
    nonisolated static let allMailExcludedLabelIds = ["INBOX", "SENT", "TRASH", "SPAM", "DRAFT"]

    /// The folders whose own windowed list asks Gmail for Spam and Trash mail
    /// (`messageListPath`).
    nonisolated static let spamTrashFolderIds: Set<String> = ["TRASH", "SPAM"]

    /// Whether a message carrying `labelIds` belongs in the local folder `path`:
    /// All Mail holds every message without an excluded label; every other
    /// folder is the Gmail label of the same id.
    nonisolated static func folder(_ path: String, containsMessageWithLabels labelIds: [String]) -> Bool {
        path == archivePath ? !labelIds.contains(where: allMailExcludedLabelIds.contains) : labelIds.contains(path)
    }
    private static let draftResourceLookupPageSize = 500

    private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    /// Internal so the change reader (`GmailProviderChanges.swift`) can name the account in its logs.
    let userEmail: String
    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    /// Legacy `tm_*` Gmail label IDs observed on the account during the most
    /// recent `fetchFolders` call. We no longer create these labels — they
    /// only exist as residue on accounts that ran prior TabMail versions.
    /// Used in `move()` to strip the label from the message being moved out
    /// of the inbox, so the legacy pollution decays naturally as the user
    /// triages. Never read for ActionTag resolution (see ADR-IOS-036).
    /// Gmail user labels use opaque IDs such as `Label_42`, which are
    /// indistinguishable from Gmail's reserved ID namespace without the
    /// display names returned by `/labels`. Message parsing therefore trusts
    /// only IDs learned from a complete successful catalog response.
    private var userLabelCatalog = GmailUserLabelCatalogState()

    /// Test-only session override. Production call sites omit; tests register
    /// `FakeHTTP` URLProtocol on this session to intercept Gmail API calls.
    private let testSession: URLSession?

    /// Concurrency gate for Gmail HTTP requests (ADR-free; see `GmailAPI.maxConcurrentRequests`).
    /// Gmail caps concurrent requests PER USER, and internal fan-outs (a whole
    /// `messages.list` page of metadata fetches) bypass the per-account
    /// `ProviderWorkQueue` because they call `request()` directly from inside the
    /// provider. So `request()` self-limits: at most `maxConcurrentRequests` HTTP
    /// calls are in flight at once; the rest wait FIFO. Actor isolation provides
    /// the synchronization (no lock needed) — these are only touched inside the
    /// actor's `acquireRequestSlot` / `releaseRequestSlot`.
    private var inFlightRequests = 0
    private var requestSlotWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        userEmail: String,
        accessToken: @Sendable @escaping (_ forceRefresh: Bool) async throws -> String,
        session: URLSession? = nil
    ) {
        self.userEmail = userEmail
        self.accessToken = accessToken
        self.testSession = session
    }

    func connect() async throws {
        // Validate token by fetching profile
        let _ = try await request(path: "/profile")
    }

    func disconnect() async throws {
        // No persistent connection — each request uses an ephemeral session.
    }

    func fetchFolders() async throws -> [FolderInfo] {
        let catalogRequest = userLabelCatalog.beginRequest()
        let data = try await request(path: "/labels")
        let response = try JSONDecoder().decode(GmailLabelsResponse.self, from: data)

        // System labels we explicitly skip (internal Gmail labels, not user-visible)
        let hiddenSystemLabels: Set<String> = [
            "UNREAD", "IMPORTANT",
            "CHAT", "CATEGORY_PERSONAL", "CATEGORY_SOCIAL",
            "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS"
        ]

        var folders: [FolderInfo] = []
        var discoveredLegacyTmLabelIds: Set<String> = []
        var discoveredUserLabelIds: Set<String> = []

        for label in response.labels {
            if label.type == "system" {
                if hiddenSystemLabels.contains(label.id) { continue }

                if let role = gmailLabelRole(label.id) {
                    folders.append(FolderInfo(
                        name: Self.gmailDisplayName(label.name),
                        path: label.id,
                        role: role,
                        unreadCount: label.messagesUnread ?? 0,
                        totalCount: label.messagesTotal ?? 0
                    ))
                }
            } else if label.type == "user" {
                // Legacy tm_* labels (from prior TabMail versions) — hide from
                // folder list, record the ID so `move()` can strip it from
                // messages exiting the inbox (natural decay, ADR-IOS-036).
                if label.name.lowercased().hasPrefix("tm_") {
                    discoveredLegacyTmLabelIds.insert(label.id)
                }
                if UserLabelStore.shouldExcludeLabel(id: label.id, name: label.name) {
                    continue
                }
                discoveredUserLabelIds.insert(label.id)
                // User-created labels → custom folders
                folders.append(FolderInfo(
                    name: label.name,
                    path: label.id,
                    role: .custom,
                    unreadCount: label.messagesUnread ?? 0,
                    totalCount: label.messagesTotal ?? 0
                ))
            }
        }

        userLabelCatalog.apply(
            userLabelIds: discoveredUserLabelIds,
            legacyTmLabelIds: discoveredLegacyTmLabelIds,
            request: catalogRequest
        )

        // Gmail has no explicit archive label — add synthetic "All Mail" folder with .archive role.
        // Gmail's archive = removing INBOX label; "All Mail" is the closest equivalent folder.
        if !folders.contains(where: { $0.role == .archive }) {
            folders.append(FolderInfo(
                name: "All Mail",
                path: GmailProvider.archivePath,
                role: .archive,
                unreadCount: 0,
                totalCount: 0
            ))
        }

        return folders
    }

    /// Maps Gmail UPPERCASE system label names to friendlier display names
    static func gmailDisplayName(_ name: String) -> String {
        switch name {
        case "INBOX": return "Inbox"
        case "SENT": return "Sent"
        case "DRAFT": return "Drafts"
        case "TRASH": return "Trash"
        case "SPAM": return "Spam"
        case "STARRED": return "Starred"
        default: return name
        }
    }

    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] {
        try await fetchMessagesWithObservedEpoch(folder: folder, limit: limit, offset: offset).messages
    }

    /// Gmail has no UIDVALIDITY, so `observedEpoch` is nil forever (matching the
    /// `EmailProvider` default). What this override exists for is `coverage`: the
    /// `messages.list` page size is the only honest statement of what the SERVER
    /// covered, and the task group below discards nils, so the returned array's
    /// count is a survivor count. See `FetchCoverage`.
    func fetchMessagesWithObservedEpoch(
        folder: String, limit: Int, offset: Int
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?, coverage: FetchCoverage) {
        var path: String
        if folder == GmailProvider.archivePath {
            // "All Mail" archive: messages not in inbox, sent, trash, spam, or drafts
            let q = GmailProvider.allMailExclusionQuery
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            path = "/messages?q=\(encoded)&maxResults=\(limit)"
        } else {
            // folder is the label ID (path), passed directly
            path = "/messages?labelIds=\(folder)&maxResults=\(limit)"
        }

        let data = try await request(path: path)
        let listResponse = try JSONDecoder().decode(GmailMessageListResponse.self, from: data)

        guard let messageRefs = listResponse.messages else {
            // The list call itself returned nothing: the server covered zero
            // records, and it covered the whole (empty) result set doing so.
            return ([], nil, FetchCoverage(
                serverRecordCount: 0, spansEntireFolder: true, unmaterialisedIds: []))
        }

        // Fetch headers concurrently — messages.list only returns IDs,
        // so each message needs a separate messages.get call. Running them
        // in parallel cuts per-folder time from ~20s (50 × 400ms serial) to ~2-3s.
        // The group yields `(id, header?)` rather than `header?` so a record the
        // parser refuses is still NAMED — it is a message the server holds, and
        // dropping its id would let the merge read it as gone.
        let page = try await withThrowingTaskGroup(of: (id: String, header: MessageHeaderInfo?).self) { group in
            for ref in messageRefs {
                group.addTask {
                    do {
                        let msgData = try await self.request(path: "/messages/\(ref.id)\(GmailAPI.metadataQuery)")
                        let msg = try JSONDecoder().decode(GmailMessage.self, from: msgData)
                        return (ref.id, await self.parseGmailMessage(msg))
                    } catch where Self.isUnreadableAnswerForOneMessage(error) {
                        // The server answered for this one message and the answer
                        // is unusable. The message stays NAMED (unmaterialised), so
                        // its row is kept, and the rest of the folder still syncs:
                        // one message that keeps failing must not stop the full
                        // sync (the change reader's rule too, `fetchMessageDetails`).
                        if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] fetchMessages: \(ref.id) unreadable (\(error)) — kept as unmaterialised") }
                        return (ref.id, nil)
                    }
                }
            }
            var result: [MessageHeaderInfo] = []
            var unmaterialised = Set<String>()
            for try await entry in group {
                if let header = entry.header { result.append(header) } else { unmaterialised.insert(entry.id) }
            }
            return (headers: result, unmaterialised: unmaterialised)
        }

        // COVERAGE is `messageRefs.count` — what `messages.list` returned for the
        // window we asked about. A short page means the label held no more; the
        // materialised count means only that some of them parsed. `nextPageToken`
        // is the server's own "there is more", so both terms are required: Gmail
        // documents `maxResults` as approximate, and the token is authoritative.
        return (page.headers, nil, FetchCoverage(
            serverRecordCount: messageRefs.count,
            spansEntireFolder: messageRefs.count < limit && listResponse.nextPageToken == nil,
            unmaterialisedIds: page.unmaterialised))
    }

    func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo {
        let data = try await request(path: "/messages/\(id)\(GmailAPI.fullQuery)")
        let msg = try JSONDecoder().decode(GmailMessage.self, from: data)

        guard let header = parseGmailMessage(msg) else {
            throw ProviderError.messageNotFound
        }

        // Try inline body first, then fetch via attachments API for large bodies
        let htmlBody = try await extractBodyWithFallback(from: msg, mimeType: "text/html")
        let textBody = try await extractBodyWithFallback(from: msg, mimeType: "text/plain")

        // Extract attachment metadata. Walk from the TOP-LEVEL payload, not just
        // `payload.parts`: a single-part message — e.g. a DMARC aggregate report that
        // IS one `application/zip` with no text body — carries its attachment on the
        // payload node itself, so `payload.parts` is nil. The shared NSE parser
        // (`GmailParse.walkParts`) already visits the payload node (which is why the
        // inbox `hasAttachments` paperclip is correct), but this body-fetch path did
        // not — so the attachment came back as 0 AND the body as empty, the message
        // looked completely blank, and it got stranded in the body/AI retry pipeline
        // (confirmed-empty → reply job re-enqueued forever). Mirror walkParts here.
        let parts = msg.payload?.parts ?? []
        let attachmentRoots: [GmailPart]
        if let payload = msg.payload {
            attachmentRoots = [GmailPart(
                mimeType: payload.mimeType, filename: payload.filename,
                headers: payload.headers, body: payload.body, parts: payload.parts
            )]
        } else {
            attachmentRoots = []
        }
        var attachments = extractAttachments(from: attachmentRoots)

        // Surface attachments nested inside file-uploaded `.eml` parts — these
        // are opaque to the Gmail MIME tree (the server saw the upload as a
        // generic file), so we fetch + parse the .eml bytes ourselves.
        // Note: Gmail's server sometimes ALSO re-extracts .eml children to
        // the top level. We do NOT dedup — matches Gmail Web behavior where
        // the same file appears both at the top and inside the preview.
        let fileEmlNested = await extractNestedFromFileUploadedEmls(messageId: id, parts: parts)
        attachments.append(contentsOf: fileEmlNested)

        // Fetch CID inline images (only if HTML body references cid:)
        let inlineImages: [InlineImage]
        if let html = htmlBody, html.range(of: "cid:", options: .caseInsensitive) != nil {
            inlineImages = await fetchInlineImages(messageId: id, from: parts)
        } else {
            inlineImages = []
        }

        return FullMessageInfo(header: header, htmlBody: htmlBody, textBody: textBody, attachments: attachments, inlineImages: inlineImages)
    }

    /// Combined header+body fetch for unified backfill. Uses format=full to get headers AND body
    /// in a single API call (50% fewer API calls vs separate metadata+body fetches).
    /// Yields results as they complete — caller writes GRDB headers + FTS bodies while more fetches are in flight.
    /// Maintains exactly `concurrency` in-flight requests at all times.
    func fetchBackfillBatch(ids: [String], concurrency: Int) async -> AsyncStream<BackfillResult> {
        let capturedIds = ids
        let capturedConcurrency = concurrency
        let provider = self
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: BackfillResult.self) { group in
                    var active = 0
                    var idIterator = capturedIds.makeIterator()

                    while active < capturedConcurrency, let id = idIterator.next() {
                        group.addTask { await provider.fetchSingleBackfill(id: id) }
                        active += 1
                    }

                    for await result in group {
                        continuation.yield(result)
                        if let id = idIterator.next() {
                            group.addTask { await provider.fetchSingleBackfill(id: id) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fetch a single message's header + body in one API call (format=full).
    /// Reuses parseGmailMessage for header extraction and extractBodyWithFallback for body.
    private func fetchSingleBackfill(id: String) async -> BackfillResult {
        // Parse header and body separately so a body-extraction failure
        // (e.g. fetchAttachmentBody network error) doesn't lose the header.
        // The header is the critical piece — losing it means permanent message loss
        // because the page token has already advanced past this page.
        let data: Data
        let msg: GmailMessage
        do {
            data = try await request(path: "/messages/\(id)\(GmailAPI.fullQuery)")
            msg = try JSONDecoder().decode(GmailMessage.self, from: data)
        } catch {
            if case ProviderError.authenticationFailed = error {
                return BackfillResult(id: id, header: nil, htmlBody: nil, textBody: nil, error: error)
            }
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] Failed to fetch backfill \(id): \(error)") }
            return BackfillResult(id: id, header: nil, htmlBody: nil, textBody: nil, error: error)
        }

        let header = parseGmailMessage(msg)

        // Body extraction can throw (attachment fetch over network) — don't lose the header
        var htmlBody: String?
        var textBody: String?
        do {
            htmlBody = try await extractBodyWithFallback(from: msg, mimeType: "text/html")
            textBody = try await extractBodyWithFallback(from: msg, mimeType: "text/plain")
        } catch {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] Body extraction failed for \(id): \(error) — header preserved") }
        }

        return BackfillResult(id: id, header: header, htmlBody: htmlBody, textBody: textBody, error: nil)
    }

    /// Streaming body-only fetch for FTS indexing.
    /// Yields results as they complete — caller can write FTS while more fetches are in flight.
    /// Maintains exactly `concurrency` in-flight requests at all times.
    func fetchTextBodiesStream(ids: [String], concurrency: Int) async -> AsyncStream<TextBodyFetchResult> {
        let capturedIds = ids
        let capturedConcurrency = concurrency
        // Capture self reference inside actor isolation before returning stream
        let provider = self
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: TextBodyFetchResult.self) { group in
                    var active = 0
                    var idIterator = capturedIds.makeIterator()

                    while active < capturedConcurrency, let id = idIterator.next() {
                        group.addTask { await provider.fetchSingleTextBody(id: id) }
                        active += 1
                    }

                    for await result in group {
                        continuation.yield(result)
                        if let id = idIterator.next() {
                            group.addTask { await provider.fetchSingleTextBody(id: id) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fetch a single message's text body only (no header parse, no attachments, no inline images).
    /// Uses fields=id,payload to skip threadId/labelIds/snippet/historyId/internalDate/sizeEstimate.
    private func fetchSingleTextBody(id: String) async -> TextBodyFetchResult {
        do {
            let data = try await request(path: "/messages/\(id)?format=full&fields=id,payload")
            let msg = try JSONDecoder().decode(GmailMessage.self, from: data)
            let htmlBody = try await extractBodyWithFallback(from: msg, mimeType: "text/html")
            let textBody = try await extractBodyWithFallback(from: msg, mimeType: "text/plain")
            return TextBodyFetchResult(id: id, htmlBody: htmlBody, textBody: textBody, error: nil)
        } catch {
            return TextBodyFetchResult(id: id, htmlBody: nil, textBody: nil, error: error)
        }
    }

    func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] {
        var results: [TextBodyFetchResult] = []
        // Provider-owned concurrency: Gmail API allows high parallelism (250 qps, 5 units each)
        let concurrency = BackfillProfile.normal.gmailBodyConcurrency
        let stream = await fetchTextBodiesStream(ids: ids, concurrency: concurrency)
        for await result in stream {
            results.append(result)
        }
        return results
    }

    func search(query: String, folder: String, after: Date? = nil, before: Date? = nil, from: String? = nil, to: String? = nil) async throws -> [MessageHeaderInfo] {
        var q = query
        if let from, !from.isEmpty { q += " from:\(from)" }
        if let to, !to.isEmpty { q += " to:\(to)" }
        if let after {
            let epoch = Int(after.timeIntervalSince1970)
            q += " after:\(epoch)"
        }
        if let before {
            let epoch = Int(before.timeIntervalSince1970)
            q += " before:\(epoch)"
        }
        // Synthetic "All Mail" folder is NOT a valid Gmail label ID — passing it as
        // labelIds returns HTTP 400 "Invalid label". Scope via query exclusions
        // instead, same translation as fetchMessages/listOlderMessageIds.
        if folder == GmailProvider.archivePath {
            q += " " + GmailProvider.allMailExclusionQuery
        }
        // `q` carries the user's search text, so it is encoded as one query
        // component: `&`, `=` and `+` would otherwise split the parameter or
        // read as a space.
        var queryItems: [(name: String, value: String)] = [("q", q), ("maxResults", "20")]
        // Scope to folder using labelIds parameter (works for both system and custom labels)
        if !folder.isEmpty && folder != GmailProvider.archivePath {
            queryItems.append(("labelIds", folder))
        }
        let data = try await request(path: try Self.strictEncodedPath("/messages", queryItems: queryItems))
        let listResponse = try JSONDecoder().decode(GmailMessageListResponse.self, from: data)

        guard let messageRefs = listResponse.messages else { return [] }

        // Fetch headers concurrently — same pattern as fetchMessages. Sequential
        // gets (20 × ~400ms) approached the search UI's per-account timeout.
        let headers: [MessageHeaderInfo] = try await withThrowingTaskGroup(of: MessageHeaderInfo?.self) { group in
            for ref in messageRefs {
                group.addTask {
                    let msgData = try await self.request(path: "/messages/\(ref.id)\(GmailAPI.metadataQuery)")
                    let msg = try JSONDecoder().decode(GmailMessage.self, from: msgData)
                    return await self.parseGmailMessage(msg)
                }
            }
            var result: [MessageHeaderInfo] = []
            for try await header in group {
                if let header { result.append(header) }
            }
            return result
        }

        return headers
    }

    /// THE PER-MEMBER BOUNDARY for every Gmail label mutation, and it settles
    /// EXACTLY ONE MEMBER PER ATTEMPT.
    ///
    /// Gmail's `messages.modify` addresses ONE message per request, so this is the
    /// only place in the system that can attribute a not-found answer to a
    /// specific member. It therefore owns the per-member interpretation: the
    /// member is mutated, or the server AUTHORITATIVELY reports it gone, and
    /// either way it is dispositioned and named in a `ProviderMembersDispositioned`
    /// report that `AccountManager.executeOperation` converts into a complete
    /// outcome. The members behind it are untouched and stay owed under the SAME
    /// durable row, which `retirePartiallyCompletedOp` narrows to them.
    ///
    /// 🚨 THIS IS WHAT REPLACES THE DRAIN'S BATCH SPLIT. The scheduler used to
    /// respond to a batch not-found by writing one replacement `PendingOperation`
    /// per member and deleting the parent, purely to discover which member was
    /// gone. The discovery belongs here, where the request is actually addressed;
    /// the durable row keeps its id and is never re-shaped.
    ///
    /// ⚠ ONLY A STRUCTURAL, MEMBER-ADDRESSED NOT-FOUND IS ABSORBED. Everything
    /// else — a 5xx, a 429, a timeout, an auth failure, a cancellation — is
    /// rethrown with the remaining members untouched, so the whole operation stays
    /// queued and retries.
    ///
    /// 🚨 WHY ONE MEMBER AND NOT A TIME BUDGET. `AccountManager.executeSingleOp`
    /// wraps this call in `withTimeout(SyncConfig.pendingOperationTimeoutSeconds)`,
    /// and `withTimeout` resumes the drain with `TimeoutError` FIRST and cancels
    /// the operation task second — so everything a loop is still holding at the
    /// deadline is discarded with the abandoned task, `requeueOrRetain` resets the
    /// row with its membership unchanged, and the next attempt repeats the same
    /// prefix into the same deadline forever. The last member's intention never
    /// reaches Gmail: persistent retry starvation, the wedge corollary that
    /// `never-drop-user-intention.md` puts on the non-recoverable list.
    ///
    /// A margin measured in ELAPSED TIME cannot close that, and an earlier fix
    /// that reserved a fixed fraction of the deadline was itself insufficient for
    /// exactly this reason (`MIS-IOS-022`): the check happens BETWEEN members, so
    /// it bounds what has already been spent and says nothing about the duration
    /// of the request it is about to start. Members that each fit the operation
    /// deadline comfortably can still straddle it two at a time. Settling ONE
    /// member makes an attempt's exposure equal to one request's, which is the
    /// only quantity the deadline actually bounds.
    ///
    /// ⚠ THE COST IS DELIBERATE AND ACCEPTED: a healthy N-member operation now
    /// converges in N attempts rather than one, narrowing the same row each time.
    /// Monotonic progress is the property being bought; do not reintroduce
    /// batching to recover the old convergence rate.
    private func modifyEachMessage(
        ids: [String],
        addLabelIds: [String] = [],
        removeLabelIds: [String] = [],
        moveTraceLabel: String? = nil
    ) async throws {
        try await settleEachMessage(ids: ids, moveTraceLabel: moveTraceLabel) { id in
            try await self.modifyMessage(
                id: id, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        }
    }

    /// The per-member boundary described above, for any single-message request:
    /// `messages.modify`, and `messages.trash` / `messages.untrash` for a move
    /// between Trash and a label Gmail keeps itself (`move`).
    private func settleEachMessage(
        ids: [String],
        moveTraceLabel: String? = nil,
        settleOne: (String) async throws -> Void
    ) async throws {
        // An empty request has nothing to settle and nothing to report; silence
        // is the truthful answer, exactly as it was for a request whose every
        // member was mutated.
        guard let id = ids.first else { return }
        var absent: [String] = []
        do {
            try await settleOne(id)
            if let moveTraceLabel, DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[MoveTrace] \(moveTraceLabel) — request completed for \(id)")
            }
        } catch {
            guard ProviderMemberAbsence.isAuthoritative(error) else { throw error }
            absent.append(id)
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[Gmail] message \(id): the server reports THIS message gone — the member is dispositioned and the operation narrows to the members still owed")
            }
        }
        // Silence is "every member, mutated": the only outcome the `Void`-returning
        // protocol can express on its own, and it stays available to the
        // single-member request that settled its one member. Anything else — a
        // member the server reported gone, or members this attempt never
        // addressed — has to be reported.
        if !absent.isEmpty || ids.count != 1 {
            throw ProviderMembersDispositioned(
                dispositionedMemberIds: [id], absentMemberIds: absent)
        }
    }

    func performMessageAction(_ action: ProviderMessageAction, at source: ProviderMessageSource) async throws -> ProviderActionOutcome {
        do {
            switch action {
            case .move(let destination):
                try await move(ids: source.memberIds, from: source.folderPath, to: destination)
            case .read(let read):
                if read {
                    try await markRead(ids: source.memberIds, folder: source.folderPath)
                } else {
                    try await markUnread(ids: source.memberIds, folder: source.folderPath)
                }
            case .flagged(let flagged):
                try await markFlagged(ids: source.memberIds, flagged: flagged, folder: source.folderPath)
            case .replied, .forwarded:
                // These flags have no remote representation; local state is preserved by sync.
                break
            case .userLabel(let id, let add):
                if let member = source.memberIds.first {
                    try await modifyMessage(id: member, addLabelIds: add ? [id] : [], removeLabelIds: add ? [] : [id])
                }
                return ProviderActionOutcome(dispositionedMemberIds: Array(source.memberIds.prefix(1)))
            }
            return ProviderActionOutcome(dispositionedMemberIds: source.memberIds)
        } catch let disposition as ProviderMembersDispositioned {
            return ProviderActionOutcome(disposition: disposition)
        }
    }

    func markRead(ids: [String], folder: String) async throws {
        try await modifyEachMessage(ids: ids, removeLabelIds: ["UNREAD"])
    }

    func markUnread(ids: [String], folder: String) async throws {
        try await modifyEachMessage(ids: ids, addLabelIds: ["UNREAD"])
    }

    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {
        if flagged {
            try await modifyEachMessage(ids: ids, addLabelIds: ["STARRED"])
        } else {
            try await modifyEachMessage(ids: ids, removeLabelIds: ["STARRED"])
        }
    }

    /// The labels Gmail keeps itself. Its labels guide marks `SENT` and `DRAFT`
    /// as not manually applicable, and a `messages.modify` that adds or removes
    /// either is refused with `400 "Invalid label"`. A message keeps them
    /// wherever it is moved, so no request ever names them: a sent message moved
    /// out of Sent stays in Sent as well, as it does in Gmail itself. A user move
    /// INTO Sent or Drafts is refused before it is queued
    /// (`AccountManager.move`, `MoveFolderPicker`).
    nonisolated static let gmailMaintainedLabelIds: Set<String> = ["SENT", "DRAFT"]

    func move(ids: [String], from source: String, to destination: String) async throws {
        let maintained = GmailProvider.gmailMaintainedLabelIds
        // Between Trash and a label Gmail keeps (a delete from Sent or Drafts,
        // and its Undo) the only change is Trash itself. That is Gmail's own
        // `messages.trash` / `messages.untrash`, which also take a draft's
        // message, where labels cannot be applied.
        if maintained.contains(source) && destination == "TRASH" {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[MoveTrace] GmailProvider.move — trash ids=\(ids) source=\(source)") }
            try await settleEachMessage(ids: ids, moveTraceLabel: "GmailProvider.move") { id in
                try await self.trashOrUntrashMessage(id: id, verb: "trash")
            }
            return
        }
        if source == "TRASH" && maintained.contains(destination) {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[MoveTrace] GmailProvider.move — untrash ids=\(ids) destination=\(destination)") }
            try await settleEachMessage(ids: ids, moveTraceLabel: "GmailProvider.move") { id in
                try await self.trashOrUntrashMessage(id: id, verb: "untrash")
            }
            return
        }
        // source and destination are label IDs (path). Filter out empty/synthetic paths
        // that aren't valid Gmail API label IDs — e.g., "" or "__GMAIL_ALL_MAIL__" from
        // undo-archive, where only adding the destination label is needed — and the
        // labels Gmail keeps itself.
        var remove = (source.isEmpty || source == GmailProvider.archivePath || maintained.contains(source)) ? [] : [source]
        // Archive = just remove source label (message stays in All Mail implicitly)
        let add = (destination == GmailProvider.archivePath || maintained.contains(destination)) ? [] : [destination]
        // Legacy-label decay (ADR-IOS-036): when moving OUT of the inbox, also
        // strip any leftover tm_* labels the account picked up from pre-ADR
        // TabMail versions. Batched into the same messages.modify call — zero
        // extra round-trip. Only runs on inbox-exit so we don't disturb labels
        // on messages that stay in other folders.
        if source == "INBOX" && !userLabelCatalog.legacyTmLabelIds.isEmpty {
            remove.append(contentsOf: userLabelCatalog.legacyTmLabelIds)
        }
        // No-op: both source and destination resolve to no label changes (e.g., move from
        // All Mail to All Mail, or a sent message archived out of Sent, which Gmail keeps
        // in Sent, and its Undo). Skip the API call — Gmail rejects empty modify bodies.
        guard !remove.isEmpty || !add.isEmpty else {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[MoveTrace] GmailProvider.move — no-op (no label changes): ids=\(ids) source=\(source) dest=\(destination)") }
            return
        }
        if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[MoveTrace] GmailProvider.move — ids=\(ids) addLabels=\(add) removeLabels=\(remove)") }
        // A Gmail move is a label mutation, so it goes through the same
        // per-member boundary as the setters: one gone member does not strand
        // the rest, and the id is stable across it (no address churn to re-learn).
        try await modifyEachMessage(
            ids: ids, addLabelIds: add, removeLabelIds: remove,
            moveTraceLabel: "GmailProvider.move")
    }

    /// A recipient that names no mailbox, or holds text that is not one, fails
    /// the send as `SMTPError.invalidEmailAddress`, which the outbox treats as
    /// fatal, as an IMAP send does; a draft keeps whatever the user typed. A
    /// recipient naming several mailboxes (a send queued by an earlier version)
    /// is written as each of them (`IMAPProvider.recipientsFieldBody`).
    func send(draft: DraftMessage) async throws {
        _ = try IMAPProvider.sendableRecipients(draft.to + draft.cc + draft.bcc)
        let body = buildSendBody(draft: draft)
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let _ = try await request(path: "/messages/send", method: "POST", body: jsonData)
    }

    /// Build the `users.messages.send` request body, which is also the `message`
    /// resource `saveDraft` uploads. Includes `threadId` when the draft carries
    /// one, so Gmail files the message into the existing conversation instead of
    /// starting a new thread. Gmail also requires the raw message to carry
    /// RFC-compliant References/In-Reply-To and a matching Subject. Send
    /// (`ComposeView.send`) and the reply-draft upload
    /// (`DraftStore.uploadThreadHeaders`) both set these through
    /// `ThreadUtils.outgoingThreadHeaders`. See ADR-IOS-043.
    /// Extracted from `send()` so the threadId wiring is unit-testable.
    /// `nonisolated` (pure — derives only from `draft`) so it returns the
    /// non-Sendable `[String: Any]` without crossing the actor boundary.
    nonisolated func buildSendBody(draft: DraftMessage) -> [String: Any] {
        let base64 = buildUrlSafeBase64(draft: draft)
        var body: [String: Any] = ["raw": base64]
        if let threadId = draft.threadId, !threadId.isEmpty {
            body["threadId"] = threadId
        }
        return body
    }

    /// Build URL-safe base64-encoded RFC822/MIME message for Gmail API.
    /// Shared between send() and saveDraft() to avoid MIME building duplication.
    nonisolated private func buildUrlSafeBase64(draft: DraftMessage) -> String {
        let rawData: Data
        if draft.attachments.isEmpty {
            rawData = buildRFC822(draft: draft).data(using: .utf8)!
        } else {
            rawData = buildMIMEMessage(draft: draft)
        }
        return rawData
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Gmail API auto-saves sent messages to the Sent label — no explicit append needed.
    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String?, messageId: String) async throws -> Bool {
        return true
    }

    // MARK: - Drafts

    func saveDraft(
        _ draft: DraftMessage,
        existingIdentity: DraftDeleteIdentity?,
        draftsFolderPath: String
    ) async throws -> DraftSaveOutcome {
        let existingDraftId: String?
        switch existingIdentity {
        case .gmail(let resourceId): existingDraftId = resourceId
        case nil: existingDraftId = nil
        default:
            throw ProviderError.actionIdentityResolutionFailed(
                "GmailProvider received a non-Gmail prior draft identity")
        }
        // The draft's `message` resource is the same one Send posts: the raw
        // message, plus `threadId` when the draft carries one, so Gmail files a
        // reply draft in its conversation (threads guide: the threadId, RFC 2822
        // References/In-Reply-To and a matching Subject; #431).
        let messagePayload = buildSendBody(draft: draft)

        // Log exactly what we're sending — base64 body length + first chars of
        // plain body + recipients. Helps diagnose "remote shows stale" reports:
        // if this log's bodyPrefix matches the user's fresh edit, the push
        // content is correct and any server-side staleness is on Gmail's side.
        if DebugModeManager.isLoggingEnabled() {
            let bodyPreview = String(draft.body.prefix(120))
            BackgroundSyncLogger.logDebug("[Gmail] saveDraft REQUEST: existingId=\(existingDraftId ?? "nil") subject=\(String(draft.subject.prefix(60))) to=\(draft.to) bodyLen=\(draft.body.count) bodyPrefix=\(bodyPreview) rawB64Len=\((messagePayload["raw"] as? String)?.count ?? 0) threadId=\(draft.threadId ?? "nil")")
        }

        if let existingId = existingDraftId {
            // Update existing draft
            let body: [String: Any] = ["message": messagePayload]
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let response = try await request(path: "/drafts/\(existingId)", method: "PUT", body: jsonData)
            if let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] {
                let draftId = json["id"] as? String ?? existingId
                let msgId = (json["message"] as? [String: Any])?["id"] as? String
                let msgSnippet = (json["message"] as? [String: Any])?["snippet"] as? String ?? "<none>"
                if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] saveDraft UPDATE RESPONSE: draftId=\(draftId) messageId=\(msgId ?? "nil") responseSnippet=\(String(msgSnippet.prefix(120)))") }
                return .created(.gmail(resourceId: draftId, containedMessageId: msgId))
            }
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] saveDraft UPDATE RESPONSE: failed to parse JSON — returning existingId=\(existingId)") }
            return .created(.gmail(resourceId: existingId, containedMessageId: nil))
        } else {
            // Create new draft
            let body: [String: Any] = ["message": messagePayload]
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let response = try await request(path: "/drafts", method: "POST", body: jsonData)
            guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any], let draftId = json["id"] as? String else {
                throw NSError(domain: "GmailProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "No draft ID in response"])
            }
            let msgId = (json["message"] as? [String: Any])?["id"] as? String
            let msgSnippet = (json["message"] as? [String: Any])?["snippet"] as? String ?? "<none>"
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] saveDraft CREATE RESPONSE: draftId=\(draftId) messageId=\(msgId ?? "nil") responseSnippet=\(String(msgSnippet.prefix(120)))") }
            return .created(.gmail(resourceId: draftId, containedMessageId: msgId))
        }
    }

    /// PORT — v2final `GmailProvider.resolveDraftResource` and its fully-
    /// paginated `drafts.list` join. This route never searches RFC headers,
    /// subjects, or local rows: the selected contained MESSAGE id is the sole
    /// input and exactly one RESOURCE wrapper is required.
    func resolveDraftResource(
        containedMessageId: String,
        draftsFolderPath: String
    ) async throws -> DraftCreatedAddress? {
        _ = draftsFolderPath
        let trimmed = containedMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == containedMessageId,
              !isSyntheticPlaceholderId(containedMessageId) else {
            throw ProviderError.actionIdentityResolutionFailed(
                "resolveDraftResource: unusable containedMessageId")
        }

        let matches = try await draftResources(wrapping: containedMessageId)
        guard matches.count == 1, let match = matches.first else { return nil }
        return .gmail(
            resourceId: match.resourceId,
            containedMessageId: match.containedMessageId)
    }

    /// #217: the draft resource's current copy, or nil on 404 (deleted elsewhere).
    func fetchDraftCopy(identity: DraftDeleteIdentity) async throws -> FullMessageInfo? {
        guard case .gmail(let resourceId) = identity else {
            throw ProviderError.actionIdentityResolutionFailed(
                "GmailProvider received a non-Gmail draft identity")
        }
        guard let messageId = try await currentDraftMessageId(resourceId: resourceId) else {
            return nil
        }
        return try await readDraftMessage(id: messageId)
    }

    /// #217: the draft itself, not a render of it. The copy replaces the local
    /// draft, so it holds only the draft and all of it:
    /// - the body is the draft's own text/plain and text/html parts in order, as
    ///   one body (`DraftBodyPiece.body`), joined when split around an inline part;
    ///   a `multipart/alternative` gives the pieces of one representation only, its
    ///   last that has any (RFC 2046 section 5.1.4), though its images and files are
    ///   still read (#272); an attached
    ///   message (`message/rfc822`) is an attachment and is never opened, so its
    ///   text never joins the body (the render's `tm-eml-section` marker);
    /// - a part with `Content-Disposition: attachment`, or a file name and no
    ///   `inline` disposition, is a file under its own name, even with a Content-ID
    ///   (Gmail web gives every attachment one); the IMAP reader's rule;
    /// - every other image with a Content-ID is an inline image, whether or not the
    ///   body references it; every other leaf that is not body text is a file;
    /// - a file whose bytes came inline is carried with them (`attachmentData`);
    /// - a file that is a container with no bytes of its own is refused
    ///   (`DraftCopyUnsupportedAttachment`); only an empty LEAF reads as empty;
    /// - a part whose bytes cannot be read throws, never drops out.
    /// Iterative, so a deeply nested copy cannot exhaust the stack.
    private func readDraftMessage(id: String) async throws -> FullMessageInfo {
        let data = try await request(path: "/messages/\(id)\(GmailAPI.fullQuery)")
        let msg = try JSONDecoder().decode(GmailMessage.self, from: data)
        guard let header = parseGmailMessage(msg, keepEmptySubject: true) else {
            throw ProviderError.messageNotFound
        }
        guard let payload = msg.payload else {
            return FullMessageInfo(header: header, htmlBody: nil, textBody: nil)
        }
        var pieces: [DraftBodyPiece] = []
        var attachments: [AttachmentInfo] = []
        var inlineImages: [InlineImage] = []
        var carried: [String: Data] = [:]
        // `inBody`: false under an alternative that is not the one read, whose text
        // is another version of the body.
        var stack = [(part: GmailPart(
            mimeType: payload.mimeType, filename: payload.filename,
            headers: payload.headers, body: payload.body, parts: payload.parts), inBody: true)]
        while let (part, inBody) = stack.popLast() {
            let mimeType = (part.mimeType ?? "").lowercased()
            let filename = part.filename ?? ""
            let role = Self.draftPartRole(part)
            let isMessage = mimeType.hasPrefix("message/rfc822")
            var isFile = false
            if case .file = role { isFile = true }
            if case .inlineImage(let contentId) = role {
                inlineImages.append(InlineImage(
                    contentId: contentId, contentType: mimeType,
                    data: try await draftPartBytes(part, messageId: id)))
                continue
            }
            if case .bodyText = role {
                guard inBody else { continue }
                let bytes = try await draftPartBytes(part, messageId: id)
                // Decoded in the part's declared charset as the IMAP draft read
                // decodes it (`draftTextContent`); text it cannot decode throws,
                // never reads as an empty draft or as a guessed charset.
                let declared = part.headers?.first { $0.name.lowercased() == "content-type" }?.value ?? mimeType
                guard let text = MessagePart(sectionString: "1", contentType: declared, data: bytes).draftTextContent else {
                    throw GmailDraftCopyIncomplete(mimeType: mimeType)
                }
                // A body split around an inline part (text, image, text) is one
                // body: its pieces are joined in order.
                pieces.append(mimeType == "text/plain"
                    ? .text(EmailFilter.decodeFormatFlowed(text, contentType: declared))
                    : .html(text))
                continue
            }
            if case .container(let children) = role {
                let read = mimeType == "multipart/alternative"
                    ? children.lastIndex { Self.draftPartHasBodyText($0) }
                    : nil
                for (index, child) in children.enumerated().reversed() {
                    stack.append((child, inBody && (read == nil || index == read)))
                }
                continue
            }
            // A leaf Gmail reports as empty holds nothing to carry.
            if !isFile, part.body?.attachmentId == nil, (part.body?.size ?? 0) == 0,
               (part.body?.data ?? "").isEmpty { continue }
            // Every file is read here, whole (`draftPartBytes`), and carried under its
            // attachment id, or a key of its own when its bytes came in the part.
            let section = part.body?.attachmentId ?? "inline-part-\(carried.count)"
            carried[section] = try await draftPartBytes(part, messageId: id)
            attachments.append(AttachmentInfo(
                filename: filename.isEmpty
                    ? (isMessage ? "attached-email.eml" : DraftReadConfig.unnamedAttachmentFilename)
                    : filename,
                contentType: part.mimeType ?? "application/octet-stream",
                section: section,
                size: part.body?.size ?? 0,
                encoding: nil))
        }
        let body = DraftBodyPiece.body(of: pieces)
        return FullMessageInfo(
            header: header, htmlBody: body.html, textBody: body.text,
            attachments: attachments, inlineImages: inlineImages,
            attachmentData: carried.isEmpty ? nil : carried)
    }

    /// How `readDraftMessage` takes a draft part.
    private enum DraftPartRole {
        /// An attachment, under its own name or a default one.
        case file
        case inlineImage(contentId: String)
        /// A text/plain or text/html part of the body.
        case bodyText
        case container([GmailPart])
        /// Any other leaf, also a file unless it holds nothing.
        case otherLeaf
    }

    private static func draftPartRole(_ part: GmailPart) -> DraftPartRole {
        let mimeType = (part.mimeType ?? "").lowercased()
        let filename = part.filename ?? ""
        func headerValue(_ name: String) -> String {
            (part.headers?.first { $0.name.lowercased() == name }?.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let disposition = headerValue("content-disposition")
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        let contentId = headerValue("content-id")
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isMessage = mimeType.hasPrefix("message/rfc822")
        if isMessage || disposition == "attachment" || (!filename.isEmpty && disposition != "inline") { return .file }
        if mimeType.hasPrefix("image/"), !contentId.isEmpty { return .inlineImage(contentId: contentId) }
        if mimeType == "text/plain" || mimeType == "text/html", filename.isEmpty { return .bodyText }
        if let children = part.parts { return .container(children) }
        return .otherLeaf
    }

    /// Whether `part` holds a body part `readDraftMessage` reads, outside any file.
    /// Iterative, like the read.
    private static func draftPartHasBodyText(_ part: GmailPart) -> Bool {
        var stack = [part]
        while let next = stack.popLast() {
            switch draftPartRole(next) {
            case .bodyText: return true
            case .container(let children): stack.append(contentsOf: children)
            case .file, .inlineImage, .otherLeaf: continue
            }
        }
        return false
    }

    /// A draft part's bytes, whole: inline in the part, else through the attachments
    /// API. Gmail may send empty `data` for a part whose bytes are stored apart,
    /// under its `attachmentId`, so only non-empty `data` is the part's bytes.
    /// `body.size` counts the decoded bytes; fewer, by either route, never arrived
    /// whole.
    private func draftPartBytes(_ part: GmailPart, messageId: String) async throws -> Data {
        let bytes: Data
        if let inline = part.body?.data, !inline.isEmpty {
            guard let decoded = decodeBase64URLToData(inline) else {
                throw GmailDraftCopyIncomplete(mimeType: part.mimeType ?? "")
            }
            bytes = decoded
        } else if let attachmentId = part.body?.attachmentId {
            bytes = try await fetchAttachment(messageId: messageId, attachmentId: attachmentId)
        } else {
            // A file part with children and neither (an attached message Gmail lists
            // as its parts, which may report size 0) cannot be carried as one file:
            // refused like an Outlook item attachment (#241), never read as empty.
            guard (part.parts ?? []).isEmpty else { throw DraftCopyUnsupportedAttachment() }
            bytes = Data()
        }
        guard part.body?.size.map({ bytes.count >= $0 }) ?? true else {
            throw GmailDraftCopyIncomplete(mimeType: part.mimeType ?? "")
        }
        return bytes
    }

    /// The message a draft resource currently wraps (it changes on every update),
    /// or nil on 404.
    private func currentDraftMessageId(resourceId: String) async throws -> String? {
        let path = try Self.strictEncodedPath(
            "/drafts/\(resourceId)",
            queryItems: [(name: "format", value: "minimal"), (name: "fields", value: "message/id")])
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        let result = try await authedHTTP.requestAllowing404(url: baseURL + path)
        if result.statusCode == 404 { return nil }
        guard let data = result.data else {
            throw ProviderError.networkError(underlying: HTTPError.networkError(statusCode: result.statusCode))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = (json["message"] as? [String: Any])?["id"] as? String,
              !messageId.isEmpty else {
            throw ProviderError.networkError(underlying: HTTPError.networkError(statusCode: result.statusCode))
        }
        return messageId
    }

    private func draftResources(
        wrapping containedMessageId: String
    ) async throws -> [(resourceId: String, containedMessageId: String)] {
        var matches: [(resourceId: String, containedMessageId: String)] = []
        var pageToken: String?
        repeat {
            try Task.checkCancellation()
            var queryItems: [(name: String, value: String)] = [
                (name: "maxResults", value: String(Self.draftResourceLookupPageSize)),
                (name: "fields", value: "drafts(id,message/id),nextPageToken"),
            ]
            if let pageToken {
                queryItems.append((name: "pageToken", value: pageToken))
            }
            let path = try Self.strictEncodedPath("/drafts", queryItems: queryItems)
            let data = try await request(path: path)
            try Task.checkCancellation()
            let response = try JSONDecoder().decode(GmailDraftListResponse.self, from: data)
            if let drafts = response.drafts {
                for draft in drafts where draft.message?.id == containedMessageId {
                    matches.append((draft.id, containedMessageId))
                }
            }
            pageToken = response.nextPageToken
        } while pageToken != nil
        return matches
    }

    nonisolated private static func strictEncodedPath(
        _ path: String,
        queryItems: [(name: String, value: String)]
    ) throws -> String {
        var encodedItems: [URLQueryItem] = []
        for item in queryItems {
            guard let name = StrictPercentEncoding.component(item.name),
                  let value = StrictPercentEncoding.component(item.value) else {
                throw ProviderError.invalidURL("Gmail request query")
            }
            encodedItems.append(URLQueryItem(name: name, value: value))
        }
        var components = URLComponents()
        components.path = path
        components.percentEncodedQueryItems = encodedItems
        guard let result = components.string else {
            throw ProviderError.invalidURL("Gmail request query")
        }
        return result
    }

    func deleteDraft(identity: DraftDeleteIdentity) async throws {
        let draftId: String
        let containedMessageOnly: Bool
        switch identity {
        case .gmail(let resourceId):
            draftId = resourceId
            containedMessageOnly = false
        case .gmailContainedMessage(let messageId):
            draftId = messageId
            containedMessageOnly = true
        default:
            throw ProviderError.actionIdentityResolutionFailed("GmailProvider received a non-Gmail draft identity")
        }
        if containedMessageOnly {
            let token = try await accessToken(false)
            try await trashContainedDraftMessage(
                messageId: draftId, token: token, session: testSession)
            return
        }
        // A resource identity stays in the resource namespace. A 404 means this exact
        // draft resource is absent; it is never reinterpreted as a contained MESSAGE id.
        var token = try await accessToken(false)
        // No logLabel — 404 is expected when the exact resource is already absent.
        let result = try await performHTTPRequestWithRetry(
            url: baseURL + "/drafts/\(draftId)", method: "DELETE", body: nil, token: token,
            retryableStatusCodes: [429, 403], session: testSession
        )
        if result.data != nil { return }
        if result.statusCode == 401 {
            token = try await accessToken(true)
            let retry = try await performHTTPRequest(url: baseURL + "/drafts/\(draftId)", method: "DELETE", body: nil, token: token, session: testSession)
            if retry.data != nil { return }
            if retry.statusCode != 404 {
                throw ProviderError.networkError(underlying: NSError(domain: "Gmail", code: retry.statusCode))
            }
        }
        if result.statusCode == 404 || result.statusCode == 401 {
            // A resource identity is never reinterpreted in the contained-message
            // namespace. 404 is authoritative absence for this exact resource.
            return
        }
        throw ProviderError.networkError(underlying: NSError(domain: "Gmail", code: result.statusCode))
    }

    /// PORT — `v2final:GmailProvider.trashContainedDraftMessage`
    /// (`3486e18a8`). Exact contained-message deletion when the caller already
    /// knows that address namespace. 404 is idempotent success; 401 refreshes
    /// once, and both requests use the caller's injected session.
    private func trashContainedDraftMessage(
        messageId: String,
        token: String,
        session: URLSession?
    ) async throws {
        let trashResult = try await performHTTPRequestWithRetry(
            url: baseURL + "/messages/\(messageId)/trash", method: "POST", body: nil, token: token,
            retryableStatusCodes: [429, 403], session: session
        )
        if trashResult.data != nil { return }
        if trashResult.statusCode == 404 {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] deleteDraft: \(messageId) already deleted") }
            return
        }
        if trashResult.statusCode == 401 {
            let freshToken = try await accessToken(true)
            let retry = try await performHTTPRequest(
                url: baseURL + "/messages/\(messageId)/trash", method: "POST", body: nil,
                token: freshToken, session: session
            )
            if retry.statusCode == 404 || retry.data != nil { return }
            throw ProviderError.networkError(
                underlying: NSError(domain: "Gmail", code: retry.statusCode))
        }
        throw ProviderError.networkError(
            underlying: NSError(domain: "Gmail", code: trashResult.statusCode))
    }

    // MARK: - Backfill

    /// Fetch older messages before a given date for infinite scroll.
    /// Returns up to `limit` messages, newest-first from the older batch.
    /// Lightweight listing of message IDs older than `before` (1 API call, no header fetch).
    /// Used by backfill to dedup against DB before fetching only missing headers.
    func listOlderMessageIds(folder: String, before: Date, limit: Int) async throws -> [String] {
        let beforeEpoch = Int(before.timeIntervalSince1970)
        let requestPath: String
        if folder == GmailProvider.archivePath {
            let q = GmailProvider.allMailExclusionQuery + " before:\(beforeEpoch)"
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            requestPath = "/messages?maxResults=\(limit)&q=\(encoded)"
        } else {
            let encodedQuery = "before:\(beforeEpoch)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "before:\(beforeEpoch)"
            requestPath = "/messages?labelIds=\(folder)&maxResults=\(limit)&q=\(encodedQuery)"
        }
        let data = try await request(path: requestPath)
        let listResponse = try JSONDecoder().decode(GmailMessageListResponse.self, from: data)
        return listResponse.messages?.map(\.id) ?? []
    }

    /// A provider-date window for a list request, in whole epoch seconds, sent as
    /// `after:<after> before:<before>` (Gmail evaluates both against `internalDate`,
    /// i.e. `MessageHeader.providerDate`).
    struct ListWindow: Sendable, Equatable {
        let after: Int
        let before: Int

        var query: String { "after:\(after) before:\(before)" }
    }

    /// Single-page listing for cursor-based backfill. Returns one page of message IDs
    /// plus the nextPageToken for resuming. With no `window`, no date filter — walks
    /// the entire label listing newest→oldest. Archive path uses exclusion query.
    /// With a `window` (the catch-up, ADR-IOS-107), only messages whose
    /// `internalDate` lies in it; the Spam and Trash folders' own lists send
    /// `includeSpamTrash`, so they list their own mail, and every other folder
    /// lists what its walk lists (no Spam or Trash mail); a `400` then keeps its body,
    /// so the catch-up can log its reason (`badRequestReason`).
    func listMessageIdsPage(
        folder: String,
        pageToken: String? = nil,
        pageSize: Int = 500,
        window: ListWindow? = nil
    ) async throws -> (ids: [String], nextPageToken: String?) {
        try Task.checkCancellation()
        let path = Self.messageListPath(folder: folder, window: window, pageToken: pageToken, pageSize: pageSize)
        return try await listMessageIds(path: path, preservingBadRequestBody: window != nil)
    }

    /// One page of the ids of ALL the account's messages matching `search`
    /// (for example `is:unread`) whose `internalDate` lies in `window`, Spam and
    /// Trash included. Not scoped to a folder: a message moved between this and
    /// another request is still answered for. A `400` keeps its body, so the
    /// catch-up can log its reason (`badRequestReason`).
    func listAccountMessageIdsPage(
        search: String, window: ListWindow, pageToken: String?, pageSize: Int
    ) async throws -> (ids: [String], nextPageToken: String?) {
        try Task.checkCancellation()
        let path = Self.accountMessageListPath(search: search, window: window, pageToken: pageToken, pageSize: pageSize)
        return try await listMessageIds(path: path, preservingBadRequestBody: true)
    }

    /// One message's label ids (`format=minimal`), or nil when Gmail answers that
    /// it is gone (404/410). Any other failure throws.
    func fetchMessageLabelIds(id: String) async throws -> [String]? {
        let data: Data
        do {
            data = try await request(path: "/messages/\(id)\(GmailAPI.minimalQuery)")
        } catch where isHttpGoneStatus(error) {
            return nil
        }
        return try JSONDecoder().decode(GmailMessage.self, from: data).labelIds ?? []
    }

    private func listMessageIds(
        path: String, preservingBadRequestBody: Bool
    ) async throws -> (ids: [String], nextPageToken: String?) {
        let data = preservingBadRequestBody
            ? try await requestPreservingBadRequestBody(path: path, method: "GET", body: nil)
            : try await request(path: path)
        let listResponse = try JSONDecoder().decode(GmailMessageListResponse.self, from: data)
        let ids = listResponse.messages?.map(\.id) ?? []
        return (ids: ids, nextPageToken: listResponse.nextPageToken)
    }

    /// The `messages.list` path for one folder. All Mail is the exclusion query and
    /// never a label id; a `window` adds its bounds to the query.
    nonisolated static func messageListPath(
        folder: String, window: ListWindow?, pageToken: String?, pageSize: Int
    ) -> String {
        var path: String
        if folder == GmailProvider.archivePath {
            let q = [GmailProvider.allMailExclusionQuery, window?.query].compactMap { $0 }.joined(separator: " ")
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            path = "/messages?maxResults=\(pageSize)&q=\(encoded)"
        } else {
            path = "/messages?labelIds=\(folder)&maxResults=\(pageSize)"
            if let q = window?.query {
                path += "&q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)"
            }
        }
        // What this relies on: a search (`q`) list and a list of any label
        // other than SPAM or TRASH leave Spam and Trash mail out unless
        // `includeSpamTrash` is sent (unsent = false), while a list by
        // `labelIds=TRASH` or `SPAM` returns that folder's mail without it (the
        // Spam and Trash walks list that way). Google's reference documents
        // the flag but not how it combines with `labelIds`. A folder's windowed
        // list asks for it only for the Spam and Trash folders themselves, so
        // every other folder's check lists what its own walk lists: a message
        // in a label that is also in Trash or Spam is not missing there (#540).
        if window != nil, spamTrashFolderIds.contains(folder) { path += "&includeSpamTrash=true" }
        if let token = pageToken {
            path += "&pageToken=\(token)"
        }
        return path
    }

    /// The account-wide `messages.list` path for `search` within `window`.
    nonisolated static func accountMessageListPath(
        search: String, window: ListWindow, pageToken: String?, pageSize: Int
    ) -> String {
        let q = "\(search) \(window.query)"
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        var path = "/messages?maxResults=\(pageSize)&q=\(encoded)&includeSpamTrash=true"
        if let token = pageToken {
            path += "&pageToken=\(token)"
        }
        return path
    }

    func fetchOlderMessages(folder: String, before: Date, limit: Int) async throws -> [MessageHeaderInfo] {
        try await fetchOlderMessagesWithCoverage(folder: folder, before: before, limit: limit).messages
    }

    /// Infinite-scroll page plus what the SERVER covered for it. The paging
    /// consumer's continuation signal is a coverage question, and the loop below
    /// names, without loading, the records `parseGmailMessage` refuses and the
    /// messages whose answer is unusable — see `FetchCoverage`.
    func fetchOlderMessagesWithCoverage(
        folder: String, before: Date, limit: Int
    ) async throws -> (messages: [MessageHeaderInfo], coverage: FetchCoverage) {
        let beforeEpoch = Int(before.timeIntervalSince1970)
        let requestPath: String
        if folder == GmailProvider.archivePath {
            let q = GmailProvider.allMailExclusionQuery + " before:\(beforeEpoch)"
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            requestPath = "/messages?maxResults=\(limit)&q=\(encoded)"
        } else {
            let encodedQuery = "before:\(beforeEpoch)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "before:\(beforeEpoch)"
            requestPath = "/messages?labelIds=\(folder)&maxResults=\(limit)&q=\(encodedQuery)"
        }
        let data = try await request(path: requestPath)
        let listResponse = try JSONDecoder().decode(GmailMessageListResponse.self, from: data)

        guard let messageRefs = listResponse.messages else {
            return ([], FetchCoverage(serverRecordCount: 0, spansEntireFolder: true, unmaterialisedIds: []))
        }

        var headers: [MessageHeaderInfo] = []
        var unmaterialised = Set<String>()
        for ref in messageRefs {
            do {
                let msgData = try await request(path: "/messages/\(ref.id)\(GmailAPI.metadataQuery)")
                let msg = try JSONDecoder().decode(GmailMessage.self, from: msgData)
                if let header = parseGmailMessage(msg) {
                    headers.append(header)
                } else {
                    unmaterialised.insert(ref.id)
                }
            } catch where Self.isUnreadableAnswerForOneMessage(error) {
                // The folder page's rule (`fetchMessagesWithObservedEpoch`):
                // the server answered for this one message and the answer is
                // unusable, a gone message included. It stays named but not
                // loaded and the rest of the page still loads, so one message
                // that keeps failing never stops older mail from paging in.
                // Once an older message on this page loads, no later page asks
                // for it again (the cursor follows the oldest local row); the
                // backfill walk loads it when it reaches it.
                if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] fetchOlderMessages: \(ref.id) unreadable (\(error)) — not loaded") }
                unmaterialised.insert(ref.id)
            }
        }

        return (headers, FetchCoverage(
            serverRecordCount: messageRefs.count,
            spansEntireFolder: messageRefs.count < limit && listResponse.nextPageToken == nil,
            unmaterialisedIds: unmaterialised))
    }

    // MARK: - Incremental Sync

    func fetchHistory(since historyId: String) async throws -> HistoryResponse? {
        BackgroundSyncLogger.log("gmail.fetchHistory: START hid=\(historyId) email=\(userEmail)")

        // Route through Shared/API/GmailAPI — single implementation for main app
        // and NSE. 404 (historyId expired), and history over
        // `GmailAPI.historyMaxChanges` records or changed messages or
        // `GmailAPI.historyMaxPages` pages, surface as nil so callers fall
        // back to full sync.
        let http = AuthedHTTP(
            auth: AccountAuthSource(accountId: userEmail, accessToken: accessToken),
            retry: .gmail, logLabel: "Gmail", session: testSession
        )

        let delta: HistoryDelta?
        do {
            delta = try await GmailAPI.historyList(
                http: http,
                startHistoryId: historyId,
                historyTypes: ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"],
                labelId: nil
            )
        } catch {
            BackgroundSyncLogger.log("gmail.fetchHistory: ERROR \(error)")
            throw ProviderError.networkError(underlying: error)
        }
        guard let delta else {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] History expired or too long (historyId: \(historyId)) — need full sync") }
            BackgroundSyncLogger.log("gmail.fetchHistory: history expired or too long")
            return nil
        }

        BackgroundSyncLogger.log("gmail.fetchHistory: decoded newHid=\(delta.cursor) adds=\(delta.added.count) dels=\(delta.removed.count) labAdds=\(delta.labelsAdded.count) labRms=\(delta.labelsRemoved.count)")

        // Convert shared HistoryDelta → main-app HistoryResponse at the boundary.
        let added = delta.added.map { HistoryMessageRef(messageId: $0.providerMessageId, labelIds: $0.providerLabels) }
        let deleted = delta.removed.map { HistoryMessageRef(messageId: $0.providerMessageId, labelIds: $0.providerLabels) }
        let labelsAdded = delta.labelsAdded.map { HistoryLabelChange(messageId: $0.providerMessageId, labelIds: $0.labelIds) }
        let labelsRemoved = delta.labelsRemoved.map { HistoryLabelChange(messageId: $0.providerMessageId, labelIds: $0.labelIds) }

        if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] History: +\(added.count) added, -\(deleted.count) deleted, \(labelsAdded.count) label adds, \(labelsRemoved.count) label removes") }

        return HistoryResponse(
            newHistoryId: delta.cursor,
            messagesAdded: added,
            messagesDeleted: deleted,
            labelsAdded: labelsAdded,
            labelsRemoved: labelsRemoved
        )
    }

    func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] {
        var headers: [MessageHeaderInfo] = []
        for id in ids {
            let msgData = try await request(path: "/messages/\(id)\(GmailAPI.metadataQuery)")
            let msg = try JSONDecoder().decode(GmailMessage.self, from: msgData)
            if let header = parseGmailMessage(msg) {
                headers.append(header)
            }
        }
        return headers
    }

    /// Fetch message details including label IDs for the change reader's folder
    /// assignment (ADR-IOS-111).
    ///
    /// A message Gmail answers is gone (404/410) is left out: it was deleted
    /// between the history listing and this fetch, which is normal. A message
    /// whose own answer cannot be used (`isUnreadableAnswerForOneMessage`: a
    /// 5xx, a 4xx such as a 429 past the retry budget, an unreadable body, a
    /// record `parseGmailMessage` refuses) is named in `unreadable` and the
    /// rest of the batch still loads, the folder page's rule
    /// (`fetchMessagesWithObservedEpoch`): the reader asks for it again on the
    /// next pass, so one message that keeps failing never holds back the
    /// account's other changes. Anything else (a dropped connection, a 401
    /// after the token refresh, cancellation) is about the account, not the
    /// message, and throws, so the pass fails and keeps its bookmark.
    ///
    /// The gets run concurrently, `GmailAPI.maxConcurrentRequests` at a time,
    /// so a delta naming a few dozen messages fits the background sync's
    /// per-account deadline instead of timing out and repeating on every push.
    /// The window is the size of the `request()` gate rather than the whole
    /// batch: the gate queues FIFO, so adding every id at once would put a
    /// large delta's whole batch ahead of any later request on this account.
    /// A throw ends the call; the gets still running are cancelled. Results
    /// are in no particular order, as the callers pass a set's ids.
    func fetchMessageDetails(ids: [String]) async throws -> GmailDetailBatch {
        try await withThrowingTaskGroup(of: DetailAnswer.self) { group in
            var pending = ids.makeIterator()
            for _ in 0..<GmailAPI.maxConcurrentRequests {
                guard let id = pending.next() else { break }
                group.addTask { try await self.detailAnswer(id: id) }
            }
            var batch = GmailDetailBatch()
            for try await answer in group {
                switch answer {
                case .read(let detail): batch.details.append(detail)
                case .gone: break
                case .unreadable(let id): batch.unreadable.append(id)
                }
                if let id = pending.next() {
                    group.addTask { try await self.detailAnswer(id: id) }
                }
            }
            // A cancelled fetch never returns as if complete, even when every
            // get it started had already answered.
            try Task.checkCancellation()
            return batch
        }
    }

    private enum DetailAnswer: Sendable {
        case read(GmailMessageDetail)
        case gone
        case unreadable(String)
    }

    private func detailAnswer(id: String) async throws -> DetailAnswer {
        do {
            return try await fetchMessageDetail(id: id).map(DetailAnswer.read) ?? .gone
        } catch where Self.isUnreadableAnswerForOneMessage(error) {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] fetchMessageDetails: \(id) unreadable (\(error)), read again next pass") }
            return .unreadable(id)
        }
    }

    /// One message for `fetchMessageDetails`: nil when Gmail answers that it
    /// is gone (404/410), and a throw for any other failure, classified by
    /// `detailAnswer`.
    private func fetchMessageDetail(id: String) async throws -> GmailMessageDetail? {
        let msgData: Data
        do {
            msgData = try await request(path: "/messages/\(id)\(GmailAPI.metadataQuery)")
        } catch where isHttpGoneStatus(error) {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] fetchMessageDetails: skipping \(id) — gone (\(error))") }
            return nil
        }
        let msg = try JSONDecoder().decode(GmailMessage.self, from: msgData)
        // A record the parser refuses (no usable date) is a failed fetch,
        // not a gone message: it says nothing about deletion and is often
        // transient, so it is unreadable like a body that does not decode.
        guard let header = parseGmailMessage(msg) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "Gmail message \(id) has no usable header"))
        }
        return GmailMessageDetail(header: header, labelIds: msg.labelIds ?? [])
    }

    /// True when the server answered for ONE message and that answer cannot be
    /// used: an HTTP error status for the message, or a body that does not
    /// decode. A status reaching here comes after `AuthedHTTP`'s own retries
    /// and token refresh, so it is taken as the server's answer for that
    /// message, even one that may be about the server (5xx, 429). On the folder
    /// page, counting it unmaterialised only keeps the row; on the older-mail
    /// page it lets paging pass the message, which the backfill walk loads
    /// later (see `fetchOlderMessagesWithCoverage`). 401 is the exception: after the
    /// refresh it means the credentials are bad, and the folder must fail.
    /// A dropped connection, cancellation or any other error is not an answer
    /// and returns false.
    nonisolated static func isUnreadableAnswerForOneMessage(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        guard case ProviderError.networkError(let underlying) = error,
              case HTTPError.networkError(let statusCode) = underlying else { return false }
        return statusCode != 401
    }

    /// Get the current historyId for this account (needed to initialize the incremental sync cursor)
    func getCurrentHistoryId() async throws -> String? {
        let data = try await request(path: "/profile")
        let profile = try JSONDecoder().decode(GmailProfile.self, from: data)
        return profile.historyId
    }

    /// Total message count in the mailbox (deduplicated across labels).
    func getMessagesTotal() async throws -> Int {
        let data = try await request(path: "/profile")
        let profile = try JSONDecoder().decode(GmailProfile.self, from: data)
        return profile.messagesTotal ?? 0
    }

    // MARK: - HTTP

    /// Lazily-built `AuthedHTTP` for Gmail. Shared 401-retry + rate-limit policy;
    /// auth via `AccountAuthSource` wrapping the existing closure.
    private var authedHTTPCached: AuthedHTTP?
    private var authedHTTP: AuthedHTTP {
        if let cached = authedHTTPCached { return cached }
        let built = AuthedHTTP(
            auth: AccountAuthSource(accountId: userEmail, accessToken: accessToken),
            retry: .gmail, logLabel: "Gmail", session: testSession
        )
        authedHTTPCached = built
        return built
    }

    /// Whether `path` names the synthetic All Mail folder where Gmail reads a
    /// folder: in the path itself, or in any query parameter but the search
    /// text `q`, which holds what the user typed and is never a label.
    nonisolated static func leaksSyntheticFolder(_ path: String) -> Bool {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        if parts[0].contains(archivePath) { return true }
        guard parts.count == 2 else { return false }
        return parts[1].split(separator: "&").contains { !$0.hasPrefix("q=") && $0.contains(archivePath) }
    }

    /// Route all Gmail REST traffic through `Shared/HTTP/AuthedHTTP`. Previous
    /// inline 401-retry + rate-limit logic deleted — that's the shared
    /// `AuthedHTTP` path now.
    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        // Boundary guard: TabMail's synthetic "All Mail" path is not a real Gmail
        // label ID. Callers must translate it (query exclusions, no labelIds) before
        // building a request — Gmail returns HTTP 400 "Invalid label" otherwise.
        // Mirrors the syntheticPlaceholderId guard in fetchMessagesBatch.
        if Self.leaksSyntheticFolder(path) {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] ERROR: synthetic folder path leaked into API path: \(path)") }
            throw ProviderError.syntheticFolderPath(path)
        }
        let url = baseURL + path
        // Bound total in-flight Gmail HTTP concurrency per account — Gmail returns
        // 429 "Too many concurrent requests for user" when an internal fan-out
        // (e.g. a whole messages.list page of metadata.get) exceeds the per-user
        // cap. Holding the slot across the call (incl. the HTTP layer's own 429
        // backoff) keeps the cap honored under retry too.
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        do {
            switch method {
            case "GET": return try await authedHTTP.get(url)
            case "POST": return try await authedHTTP.post(url, body: body ?? Data())
            case "PUT": return try await authedHTTP.put(url, body: body ?? Data())
            case "PATCH": return try await authedHTTP.patch(url, body: body ?? Data())
            case "DELETE": return try await authedHTTP.delete(url)
            default: fatalError("GmailProvider.request: unsupported HTTP method \(method)")
            }
        } catch let e as HTTPError {
            throw ProviderError.networkError(underlying: e)
        }
    }

    /// Same as `request(...)` but for the action-path call site that must
    /// structurally classify a `400` response (`modifyMessage`): preserves the
    /// raw response body of a `400` failure instead of throwing the bodyless
    /// `.networkError`, so it can be parsed for Gmail's error shape (see
    /// `isGmailInvalidIdError`) rather than guessed from the status code
    /// alone. Every other failure status still throws the ordinary
    /// `.networkError` — same as `request(...)`.
    ///
    /// PORT — `v2final:TabMail/Providers/GmailProvider.swift`
    /// `GmailProvider.requestPreservingBadRequestBody(path:method:body:)`
    /// (commit `a75196398`). SUBTRACT: the reference declares a `"GET"` arm for
    /// `resolveActionMessageId`'s / `resolveTokenMember`'s list and metadata
    /// calls. Both of those methods are RFC-search machinery that v3 does not
    /// have (D4: durable ops key on Gmail's native `message.id`, so nothing
    /// resolves an identity by search). On this tree the call sites are
    /// `modifyMessage`'s and `trashOrUntrashMessage`'s POSTs, and the `GET` of
    /// the catch-up's own list requests (`listMessageIds` with
    /// `preservingBadRequestBody`, ADR-IOS-107), which reads a `400`'s reason
    /// (`badRequestReason`). Any other method hits the `default` arm,
    /// which traps at the call site rather than quietly downgrading to the
    /// bodyless path.
    ///
    /// `method` and `body` are deliberately NOT defaulted (the reference
    /// defaults them to `"GET"` / `nil`), so every call site names what it sends.
    private func requestPreservingBadRequestBody(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Data {
        if Self.leaksSyntheticFolder(path) {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] ERROR: synthetic folder path leaked into API path: \(path)") }
            throw ProviderError.syntheticFolderPath(path)
        }
        let url = baseURL + path
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        do {
            switch method {
            case "POST":
                return try await authedHTTP.requestPreservingBadRequestBody(
                    url: url, method: "POST", body: body ?? Data()
                )
            case "GET":
                return try await authedHTTP.requestPreservingBadRequestBody(
                    url: url, method: "GET", body: nil
                )
            default:
                fatalError("GmailProvider.requestPreservingBadRequestBody: unsupported HTTP method \(method)")
            }
        } catch let e as HTTPError {
            throw ProviderError.networkError(underlying: e)
        }
    }

    /// Acquire one of `GmailAPI.maxConcurrentRequests` HTTP slots, suspending FIFO
    /// when the cap is reached. Actor-isolated, so the counter/waiter mutations are
    /// race-free without a lock.
    private func acquireRequestSlot() async {
        if inFlightRequests < GmailAPI.maxConcurrentRequests {
            inFlightRequests += 1
            return
        }
        await withCheckedContinuation { requestSlotWaiters.append($0) }
    }

    /// Release an HTTP slot. If a caller is waiting, hand the slot straight to it
    /// (count unchanged); otherwise decrement. Synchronous, so it runs from `defer`.
    private func releaseRequestSlot() {
        if !requestSlotWaiters.isEmpty {
            requestSlotWaiters.removeFirst().resume()
        } else {
            inFlightRequests = max(0, inFlightRequests - 1)
        }
    }

    /// Create a Gmail label and return its ID.
    /// Used for user-created labels (visible in Gmail UI by default).
    func createLabel(name: String, visible: Bool = true) async throws -> String {
        var body: [String: Any] = ["name": name]
        if !visible {
            body["labelListVisibility"] = "labelHide"
            body["messageListVisibility"] = "hide"
        }
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let data = try await request(path: "/labels", method: "POST", body: jsonData)
        let label = try JSONDecoder().decode(GmailLabel.self, from: data)
        userLabelCatalog.recordKnownUserLabel(label.id)
        return label.id
    }

    /// Action tags are local-only (see ADR-IOS-036). No server write.
    func setActionTag(messageId: String, tag: ActionTag?) async throws {
        _ = messageId
        _ = tag
    }

    /// Gmail's structured JSON error body shape (used across the v1 REST API):
    /// `{"error":{"code":400,"message":"...","errors":[{"domain":"global","reason":"invalidArgument","message":"..."}]}}`.
    /// https://developers.google.com/workspace/gmail/api/guides/handle-errors
    ///
    /// PORT — `v2final:TabMail/Providers/GmailProvider.swift`
    /// `GmailProvider.GmailAPIErrorBody` (commit `a75196398`).
    private struct GmailAPIErrorBody: Decodable {
        struct Detail: Decodable {
            let domain: String?
            let reason: String?
            let message: String?
        }
        struct ErrorObject: Decodable {
            let code: Int?
            let message: String?
            let errors: [Detail]?
        }
        let error: ErrorObject
    }

    /// True only when Gmail's structured `400` error body PROVES the exact
    /// id could never resolve — `reason == "invalidArgument"` AND Gmail's own
    /// literal wording `"Invalid id value"` (a malformed message id). This is
    /// the Gmail mirror of Exchange's `ErrorInvalidIdMalformed` handling
    /// (`ExchangeProvider.isGraphInvalidIdMalformed` in the reference): an id
    /// Gmail itself rejects as invalid can never resolve on retry, so it is an
    /// authoritative stale no-op (C3-G2 — failing closed on the mutation is
    /// always acceptable). Any other `400` shape is uncertainty and must keep
    /// throwing; a bare status code is never enough to conclude staleness.
    ///
    /// PORT — `v2final:TabMail/Providers/GmailProvider.swift`
    /// `GmailProvider.isGmailInvalidIdError(_:)` (commit `a75196398`), taken
    /// verbatim.
    private func isGmailInvalidIdError(_ error: Error) -> Bool {
        guard let rejection = Self.structuredBadRequestRejection(error) else { return false }
        return rejection.reason == "invalidArgument"
            && rejection.message.hasPrefix("Invalid id value")
    }

    /// For an HTTP `400` answer, its structured error reason (`errors[0].reason`),
    /// or `"unparsed"` when the body has none; `nil` for any other error. Gmail
    /// answers an invalid supplied value with `400` (`badRequest`; Google's
    /// `INVALID_ARGUMENT`) and documents no wording for a page token it no longer
    /// accepts (https://developers.google.com/workspace/gmail/api/guides/handle-errors,
    /// https://google.aip.dev/158), so the catch-up's own listings treat any `400`
    /// to a request carrying a saved token as that, and restart the list once. The
    /// reason is only logged.
    nonisolated static func badRequestReason(_ error: Error) -> String? {
        guard case ProviderError.networkError(let underlying) = error,
              case HTTPError.networkErrorWithBody(let statusCode, let body) = underlying,
              statusCode == 400
        else { return nil }
        let decoded = try? JSONDecoder().decode(GmailAPIErrorBody.self, from: body)
        return decoded?.error.errors?.first?.reason ?? "unparsed"
    }

    /// The `(reason, message)` pair of a Gmail `400` whose STRUCTURED body we
    /// actually parsed, or `nil` for every other error — including a `400` whose
    /// body is absent, unparseable, or shaped differently. The only reader is
    /// `isGmailInvalidIdError`, which both per-member stale-no-op arms
    /// (`modifyMessage`, `trashOrUntrashMessage`) use, so the queue never sees
    /// this shape as a terminal classification of its own.
    private static func structuredBadRequestRejection(
        _ error: Error
    ) -> (reason: String, message: String)? {
        guard case ProviderError.networkError(let underlying) = error,
              case HTTPError.networkErrorWithBody(let statusCode, let body) = underlying,
              statusCode == 400,
              let decoded = try? JSONDecoder().decode(GmailAPIErrorBody.self, from: body)
        else { return nil }
        let detail = decoded.error.errors?.first
        return (
            reason: detail?.reason ?? "",
            message: detail?.message ?? decoded.error.message ?? ""
        )
    }

    /// Apply a label add/remove batch to one Gmail message by its native
    /// `message.id` (D4: the durable op records that id, so no resolution step
    /// stands between the op and the wire).
    ///
    /// The `400` handling is deliberately two-outcome:
    ///  - Gmail's proven `"Invalid id value"` `400` is an AUTHORITATIVE stale
    ///    no-op: return normally, and the queue retires the op as completed.
    ///  - Every other `400` keeps throwing, so the classification decision
    ///    stays with the queue rather than being pre-empted here by a guess.
    ///
    /// SUBTRACT — the reference's `classifyUnrecognizedActionBadRequest(_:)`
    /// arm, which rewraps an unclassified `400` as
    /// `ProviderError.persistentActionFailure` so the generic queue DEMOTES
    /// the failing chain to the queue tail rather than blocking the FIFO.
    /// v3 has no `persistentActionFailure` case, and the wrapper is still not
    /// ported — but the DEMOTION it existed to trigger is now unconditional, so
    /// there is nothing left for the wrapper to buy. Every retryable failure in
    /// `AccountManager.executeSingleOp` — including the unclassified `400`'s
    /// generic transient arm — runs `deferRelatedChainToTail`, which moves the
    /// failing op AND its transitively related chain to the tail of the durable
    /// `queuePosition` order and records the chain in
    /// `DrainContext.deferredOperationIds` for the rest of the drain.
    /// Rethrowing unchanged therefore reaches exactly the disposition the
    /// reference's wrapper was reaching for.
    ///
    /// ⚠ CORRECTED (audit round 1, finding B-3). This paragraph used to end
    /// "Rethrowing unchanged keeps v3's shipped terminal disposition for a Gmail
    /// action `400` (`AccountManager.isPermanentlyInvalidError` → drop the
    /// op)". That disposition was itself the defect: the matcher bound the body
    /// to `_` and retired the op on the bare STATUS, so an unrecognised `400`
    /// destroyed the user's action rather than wedging. It no longer does —
    /// the queue has no `400` classifier at all: the invalid-id shape is settled
    /// per member here, and every other `400` retries.
    ///
    /// ⚠️ CORRECTED AGAIN when the global single-operation FIFO executor landed.
    /// This paragraph used to read "**The wedge the reference's demote lane
    /// prevents is therefore REAL on v3 and remains unaddressed**: a chain whose
    /// head takes an unrecognised permanent-shaped `400` blocks its lane on
    /// every drain." **That is no longer true, and the gap is closed.** A chain
    /// whose head takes an unrecognised `400` is moved to the TAIL of the
    /// `queuePosition` order and deferred for the remainder of the drain, so the
    /// executor keeps claiming the live front row and every unrelated intention
    /// on the same account — and every later intention on any account — executes
    /// in that same drain, ahead of the retrying chain. The disposition is still
    /// a bounded, visible, retrying park rather than a silent discard, which is
    /// the trade the never-drop rule explicitly prefers; what changed is that
    /// the park no longer costs anything behind it.
    ///
    /// SUBTRACT — the reference also handles `isGmailInvalidLabelError` here
    /// (invalid/gone label → stale no-op). Not ported: an `"Invalid label"`
    /// refusal is not evidence that the action is done, so it reaches the queue
    /// as a counted failure.
    ///
    /// SUBTRACT — the reference's leading `guard !isHttpGoneStatus(error)`.
    /// A `404`/`410` is not a `400`, so `requestPreservingBadRequestBody`
    /// leaves it as the bodyless `.networkError` exactly as `request()` did;
    /// v3 routes it to `AccountManager.isMessageNotFoundError` /
    /// `isConfirmedGoneError`, which is the pre-existing v3 behavior for this
    /// method and is untouched by this change.
    func modifyMessage(id: String, addLabelIds: [String] = [], removeLabelIds: [String] = []) async throws {
        var body: [String: Any] = [:]
        if !addLabelIds.isEmpty { body["addLabelIds"] = addLabelIds }
        if !removeLabelIds.isEmpty { body["removeLabelIds"] = removeLabelIds }
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await requestPreservingBadRequestBody(
                path: "/messages/\(id)/modify", method: "POST", body: jsonData
            )
        } catch {
            guard !isGmailInvalidIdError(error) else {
                // Authoritative stale: Gmail itself rejects this exact id as
                // invalid — it can never resolve on retry. Normal return; the
                // queue treats this as a completed no-op.
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[Gmail] modifyMessage \(id): invalid-id 400 confirmed stale — treating as no-op")
                }
                return
            }
            throw error
        }
    }

    /// `messages.trash` or `messages.untrash` for one message, with the same
    /// error handling as `modifyMessage`: Gmail's structured invalid-id `400`
    /// proves this exact id can never resolve, so it settles THIS member as a
    /// stale no-op here, inside the per-member boundary. Thrown instead, it
    /// would fail the whole operation as a counted provider failure, although
    /// only this one member can never resolve.
    private func trashOrUntrashMessage(id: String, verb: String) async throws {
        do {
            _ = try await requestPreservingBadRequestBody(
                path: "/messages/\(id)/\(verb)", method: "POST", body: nil)
        } catch {
            guard !isGmailInvalidIdError(error) else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[Gmail] \(verb) \(id): invalid-id 400 confirmed stale — treating as no-op")
                }
                return
            }
            throw error
        }
    }

    // MARK: - Parsing

    /// Visible to tests via @testable import.
    /// Parse a Gmail message into main-app `MessageHeaderInfo`.
    ///
    /// Delegates JSON → canonical `MessageMetadata` to `Shared/Parse/GmailParse`.
    /// Adds main-app-specific resolution:
    ///  - `userLabelIds` filtered via `UserLabelStore`.
    ///  - `to`/`cc`/`bcc` preserved as raw RFC 2822 header values (legacy
    ///    GRDB-storage format — downstream code / UI parses them as needed).
    ///
    /// ActionTag is NOT resolved from provider labels — action tags are
    /// local-only (MessageAICache + Device Sync probe). See ADR-IOS-036.
    /// `keepEmptySubject`: a draft copy's subject is the draft's own, so an empty
    /// one stays empty rather than becoming the "(no subject)" a list shows (#217).
    internal func parseGmailMessage(_ msg: GmailMessage, keepEmptySubject: Bool = false) -> MessageHeaderInfo? {
        // Serialize the decoded GmailMessage back to a [String: Any] JSON dict
        // for the shared parser. Cheap — we already decoded once.
        guard let encoded = try? JSONEncoder().encode(msg),
              let json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let metadata = GmailParse.parseMessage(json) else {
            if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[Gmail] Missing/invalid internalDate for message \(msg.id) — treating as fetch failure, will retry") }
            return nil
        }

        // Raw header preservation (legacy behavior — downstream GRDB columns
        // and UI expect the unsplit RFC 2822 strings, not parsed email lists).
        let rawTo = GmailParse.rawHeader(json, name: "To") ?? ""
        let rawCc = GmailParse.rawHeader(json, name: "Cc") ?? ""
        let rawBcc = GmailParse.rawHeader(json, name: "Bcc") ?? ""
        let rawReplyTo = GmailParse.rawHeader(json, name: "Reply-To")

        return MessageHeaderInfo(
            messageId: metadata.providerMessageId,
            rfc822MessageId: metadata.rfc822MessageId,
            inReplyTo: metadata.inReplyTo,
            references: metadata.references,
            threadId: metadata.threadId,
            subject: metadata.subject.isEmpty && !keepEmptySubject ? "(no subject)" : metadata.subject,
            from: metadata.from.name,
            fromAddress: metadata.from.email,
            to: rawTo,
            cc: rawCc,
            bcc: rawBcc,
            replyTo: rawReplyTo,
            date: metadata.date,
            snippet: "",  // Always derived from body text downstream (uniform formatting).
            isRead: metadata.isRead,
            isFlagged: metadata.isFlagged,
            hasAttachments: metadata.hasAttachments,
            isReplied: false,
            isForwarded: false,
            actionTag: nil,
            providerDate: metadata.providerDate,
            userLabelIds: userLabelCatalog.extractUserLabelIds(from: metadata.providerLabels),
            userLabelIdsAreAuthoritative: userLabelCatalog.isAuthoritative
        )
    }

    /// Look up a Gmail user label by display name, compared without case.
    /// Returns its id and Gmail's own spelling of the name, or nil if not found.
    /// Used when createLabel returns 409 Conflict (label already exists on server).
    func findLabelByName(_ name: String) async throws -> (id: String, name: String)? {
        let catalogRequest = userLabelCatalog.beginRequest()
        let data = try await request(path: "/labels")
        let response = try JSONDecoder().decode(GmailLabelsResponse.self, from: data)
        let userLabels = response.labels.filter {
            $0.type == "user" && !UserLabelStore.shouldExcludeLabel(id: $0.id, name: $0.name)
        }
        let discoveredUserLabelIds = Set(userLabels.map(\.id))
        let discoveredLegacyTmLabelIds: Set<String> = Set(response.labels.compactMap { label in
            guard label.type == "user", label.name.lowercased().hasPrefix("tm_") else {
                return nil
            }
            return label.id
        })
        userLabelCatalog.apply(
            userLabelIds: discoveredUserLabelIds,
            legacyTmLabelIds: discoveredLegacyTmLabelIds,
            request: catalogRequest
        )
        guard let match = userLabels.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return nil
        }
        // Even when this response lost an out-of-order catalog race, the match
        // (compared without case) is provider-confirmed and must survive any older request still
        // in flight until a later uncontended catalog replaces the cache.
        userLabelCatalog.recordKnownUserLabel(match.id)
        return (match.id, match.name)
    }

    /// Recursively check all MIME parts for attachments.
    /// Matches IMAP logic: explicit attachment disposition, files not inline, or text/calendar.
    static func hasAttachmentParts(_ parts: [GmailPart]?) -> Bool {
        guard let parts else { return false }
        for part in parts {
            let mime = part.mimeType?.lowercased() ?? ""
            let hasFilename = part.filename != nil && !part.filename!.isEmpty
            if hasFilename || mime.hasPrefix("text/calendar") {
                return true
            }
            if hasAttachmentParts(part.parts) {
                return true
            }
        }
        return false
    }

    /// Delegates to shared `EmailAddress.parse` — single source of truth for
    /// From-header parsing across Gmail/Graph/IMAP/NSE. Kept as static on
    /// GmailProvider so existing tests (GmailProviderHelpersTests,
    /// GmailProviderExtendedTests, GmailProviderParsingTests) compile unchanged.
    static func parseFromHeader(_ from: String) -> (displayName: String, address: String) {
        let parsed = EmailAddress.parse(from)
        return (parsed.name, parsed.email)
    }

    /// Extracts body content, falling back to the attachments API for large messages
    /// where Gmail omits inline body data and provides an attachmentId instead.
    private func extractBodyWithFallback(from msg: GmailMessage, mimeType: String) async throws -> String? {
        guard let payload = msg.payload else { return nil }

        // Top-level payload may itself be the target mime type (single-part message).
        if payload.mimeType == mimeType {
            if let data = payload.body?.data {
                return decodeBase64URL(data)
            }
            if let attachmentId = payload.body?.attachmentId {
                return try await fetchAttachmentBody(messageId: msg.id, attachmentId: attachmentId)
            }
        }

        // Multipart: walk the tree. For HTML mode, append `.tm-eml-section` markers
        // for each `message/rfc822` part so `.eml` attachments render inline (same
        // shape as IMAP). For plain text, interleave header blocks like IMAP does.
        if let parts = payload.parts {
            return try await extractBodyAndEmlMarkers(
                parts: parts,
                messageId: msg.id,
                mimeType: mimeType,
                insideRfc822: false
            )
        }
        return nil
    }

    /// Walk a Gmail MIME part tree and return a unified body string for `mimeType`.
    ///
    /// - For text/html: returns top-level HTML body concatenated with one
    ///   `<div class="tm-eml-section">` marker per `message/rfc822` part
    ///   encountered (built via `EmlMarker.build`). Nested `.eml` bodies fall back
    ///   to plain-text converted to HTML when no text/html is present inside.
    /// - For text/plain: returns top-level plain text concatenated with the
    ///   historical IMAP-style plain-text header blocks.
    ///
    /// `insideRfc822` prevents a nested `.eml`'s body from being promoted to the
    /// top-level output (the .eml's body goes only into its marker).
    private func extractBodyAndEmlMarkers(
        parts: [GmailPart],
        messageId: String,
        mimeType: String,
        insideRfc822: Bool
    ) async throws -> String? {
        var topLevel: String? = nil
        var tail: String = ""   // markers (html mode) or header blocks + nested body (plain mode)

        for part in parts {
            let pmt = (part.mimeType ?? "").lowercased()

            if pmt.hasPrefix("message/rfc822") {
                // Nested email — don't let its body become the top-level body.
                if mimeType == "text/html" {
                    let envelope = Self.envelopeFromHeaders(part.headers ?? [])
                    // Prefer text/html inside the nested email; fall back to text/plain.
                    let nestedHtml: String
                    if let html = try await extractFirstBody(parts: part.parts ?? [], messageId: messageId, mimeType: "text/html") {
                        nestedHtml = html
                    } else if let plain = try await extractFirstBody(parts: part.parts ?? [], messageId: messageId, mimeType: "text/plain") {
                        nestedHtml = MessageBody.plainTextToHTML(plain)
                    } else {
                        nestedHtml = ""
                    }
                    let partSection = part.body?.attachmentId ?? "gmail-rfc822-\(tail.count)"
                    let filename = part.filename.flatMap { $0.isEmpty ? nil : $0 } ?? "attached-email.eml"
                    tail += EmlMarker.build(
                        filename: filename,
                        partSection: partSection,
                        envelope: envelope,
                        bodyHtml: nestedHtml
                    )
                } else {
                    // text/plain: emit plain-text header block + nested plain body
                    let envelope = Self.envelopeFromHeaders(part.headers ?? [])
                    tail += EmlMarker.embeddedHeadersPlainText(envelope: envelope, filename: part.filename)
                    if let plain = try await extractFirstBody(parts: part.parts ?? [], messageId: messageId, mimeType: "text/plain") {
                        tail += plain
                    }
                }
                continue
            }

            // File-uploaded `.eml` (filename suffix, non-rfc822 content-type).
            // Gmail sometimes preserves user uploads as `application/octet-stream`
            // or similar — server-side re-parse depends on the original MIME.
            // Only emit in HTML mode; plain-text mode stays minimal for FTS.
            if mimeType == "text/html",
               EmlParsing.isEmlFilename(part.filename),
               let attId = part.body?.attachmentId {
                do {
                    let raw = try await fetchAttachment(messageId: messageId, attachmentId: attId)
                    if let parsed = EmlParsing.parse(rawBytes: raw) {
                        let filename = part.filename ?? "attached-email.eml"
                        tail += EmlMarker.build(
                            filename: filename,
                            partSection: attId,
                            envelope: parsed.envelope,
                            bodyHtml: parsed.bodyHtml
                        )
                    } else {
                        // Gated in the BODY, not in the `else` condition: a gate in
                        // a branch condition lets a debug unlock decide which branch
                        // runs, so debug and release stop sharing one control-flow
                        // graph. `Companion/Memory/Current/105-a-print-is-not-production-observability-on-ios.md`
                        // §3 records the sibling where that happened.
                        //
                        // `part.filename` is the sender's raw MIME `filename`
                        // parameter and `print` is a line-oriented sink, so it is
                        // escaped: see `DebugModeManager.escapedForLogLine`.
                        if DebugModeManager.isLoggingEnabled() {
                            BackgroundSyncLogger.logDebug("[Gmail] Failed to parse \(DebugModeManager.escapedForLogLine(part.filename ?? "?.eml")) as RFC 822 — rendering as plain attachment")
                        }
                    }
                } catch {
                    if DebugModeManager.isLoggingEnabled() {
                        // `error` can carry a server-supplied string as well.
                        BackgroundSyncLogger.logDebug("[Gmail] Failed to fetch bytes for \(DebugModeManager.escapedForLogLine(part.filename ?? "?")): \(DebugModeManager.escapedForLogLine(String(describing: error)))")
                    }
                }
                continue
            }

            // Regular part: capture top-level body once (not from inside an rfc822).
            if !insideRfc822, pmt == mimeType, topLevel == nil {
                if let data = part.body?.data {
                    topLevel = decodeBase64URL(data)
                } else if let attachmentId = part.body?.attachmentId {
                    topLevel = try await fetchAttachmentBody(messageId: messageId, attachmentId: attachmentId)
                }
            }

            // Recurse. `multipart/alternative` and `multipart/related` wrappers let us
            // find the real body a level down.
            if let nested = part.parts {
                if let more = try await extractBodyAndEmlMarkers(
                    parts: nested, messageId: messageId, mimeType: mimeType, insideRfc822: insideRfc822
                ) {
                    if topLevel == nil {
                        topLevel = more
                    } else {
                        tail = more + tail // append any markers found deeper
                    }
                }
            }
        }

        let combined = (topLevel ?? "") + tail
        return combined.isEmpty ? nil : combined
    }

    /// Find the first body matching `mimeType` inside a subtree. Used only for the
    /// contents of a `message/rfc822` part — never exposed to the outer top-level
    /// extraction, so no marker embedding here.
    private func extractFirstBody(parts: [GmailPart], messageId: String, mimeType: String) async throws -> String? {
        for part in parts {
            let pmt = (part.mimeType ?? "").lowercased()
            if pmt == mimeType {
                if let data = part.body?.data {
                    return decodeBase64URL(data)
                }
                if let attId = part.body?.attachmentId {
                    return try await fetchAttachmentBody(messageId: messageId, attachmentId: attId)
                }
            }
            if let nested = part.parts,
               let result = try await extractFirstBody(parts: nested, messageId: messageId, mimeType: mimeType) {
                return result
            }
        }
        return nil
    }

    /// Build an `EmlMarker.Envelope` from the part-level headers of a `message/rfc822`
    /// part. Gmail's API gives us the nested email's From/Subject/Date/To/Cc directly
    /// on the part — no need to re-parse the raw MIME.
    static func envelopeFromHeaders(_ headers: [GmailHeader]) -> EmlMarker.Envelope {
        func value(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        func split(_ name: String) -> [String] {
            guard let v = value(name), !v.isEmpty else { return [] }
            return v.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let date: Date? = value("Date").flatMap { EmailDateParsing.rfc2822.date(from: $0) }
        return EmlMarker.Envelope(
            subject: value("Subject"),
            from: value("From"),
            date: date,
            to: split("To"),
            cc: split("Cc")
        )
    }

    /// Fetch a single attachment's data by Gmail attachment ID.
    /// Compound IDs of the form `<parent_att_id>|eml-nested|<index>` resolve
    /// to the nth attachment inside a file-uploaded `.eml` — we re-fetch the
    /// parent bytes and extract via `EmlParsing.nestedBytes`.
    func fetchAttachment(messageId: String, attachmentId: String) async throws -> Data {
        if let nested = EmlParsing.parseNestedSection(attachmentId) {
            let parentBytes = try await fetchAttachment(messageId: messageId, attachmentId: nested.parent)
            guard let bytes = EmlParsing.nestedBytes(rawBytes: parentBytes, index: nested.index) else {
                throw ProviderError.messageNotFound
            }
            return bytes
        }
        let data = try await request(path: "/messages/\(messageId)/attachments/\(attachmentId)")
        let attachment = try JSONDecoder().decode(GmailAttachment.self, from: data)
        guard let base64Data = attachment.data,
              let decoded = decodeBase64URLToData(base64Data) else {
            throw ProviderError.messageNotFound
        }
        return decoded
    }

    // MARK: - Attachment Extraction

    /// Walk Gmail MIME parts fetching and parsing each file-uploaded `.eml`
    /// (filename-based detection, non-`message/rfc822` content-type). Returns
    /// `AttachmentInfo` for every nested attachment found inside, tagged with
    /// `parentEmlSection` so `AttachmentListView` hides them from the main
    /// list and `EmlAttachmentPreview` surfaces them inside the `.eml` sheet.
    /// One extra HTTP round-trip per `.eml` at fetchMessage time; tap-time
    /// resolution goes through `fetchAttachment` compound-section handling.
    private func extractNestedFromFileUploadedEmls(
        messageId: String,
        parts: [GmailPart]
    ) async -> [AttachmentInfo] {
        var results: [AttachmentInfo] = []
        for part in parts {
            let pmt = (part.mimeType ?? "").lowercased()
            if EmlParsing.isEmlFilename(part.filename),
               !pmt.hasPrefix("message/rfc822"),
               let attId = part.body?.attachmentId {
                do {
                    let raw = try await fetchAttachment(messageId: messageId, attachmentId: attId)
                    if let parsed = EmlParsing.parse(rawBytes: raw) {
                        for (index, meta) in parsed.nested.enumerated() {
                            results.append(AttachmentInfo(
                                filename: meta.filename,
                                contentType: meta.contentType,
                                section: EmlParsing.nestedSection(parent: attId, index: index),
                                size: meta.size,
                                encoding: nil,
                                parentEmlSection: attId
                            ))
                        }
                    }
                } catch {
                    // Same class as the two sites in `extractBodyAndEmlMarkers`:
                    // debug-gated per rule 12, sender-authored `filename` and the
                    // error description both escaped for a line-oriented sink.
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[Gmail] Failed to list nested attachments in \(DebugModeManager.escapedForLogLine(part.filename ?? "?.eml")): \(DebugModeManager.escapedForLogLine(String(describing: error)))")
                    }
                }
            }
            if let nested = part.parts {
                let deeper = await extractNestedFromFileUploadedEmls(messageId: messageId, parts: nested)
                results.append(contentsOf: deeper)
            }
        }
        return results
    }

    /// Recursively extract attachment metadata from Gmail MIME parts.
    ///
    /// `parentEmlSection` tracks whether the current walk is inside a
    /// `message/rfc822` subtree. When a part of type `message/rfc822` with a
    /// filename is encountered, we recurse into its children with
    /// `parentEmlSection = thatRfc822'sAttachmentId` so nested attachments are
    /// marked as "inside the .eml" — `AttachmentListView` filters them out of
    /// the top-level list and `EmlAttachmentPreview` surfaces them inside the
    /// .eml's preview, matching the IMAP path.
    private func extractAttachments(from parts: [GmailPart], parentEmlSection: String? = nil) -> [AttachmentInfo] {
        var attachments: [AttachmentInfo] = []
        for part in parts {
            if let filename = part.filename, !filename.isEmpty,
               let mimeType = part.mimeType,
               let body = part.body,
               let attachmentId = body.attachmentId {
                attachments.append(AttachmentInfo(
                    filename: filename,
                    contentType: mimeType,
                    section: attachmentId,
                    size: body.size ?? 0,
                    encoding: nil,
                    parentEmlSection: parentEmlSection
                ))
            }
            if let nested = part.parts {
                // If this part is a message/rfc822 with a filename (a .eml attachment),
                // attachments deeper in the tree are "nested inside" it. Otherwise
                // (e.g. multipart/mixed wrapper, multipart/alternative), just pass
                // parentEmlSection through unchanged.
                let childParent: String?
                if let mt = part.mimeType, mt.lowercased().hasPrefix("message/rfc822"),
                   let attId = part.body?.attachmentId, part.filename?.isEmpty == false {
                    childParent = attId
                } else {
                    childParent = parentEmlSection
                }
                attachments.append(contentsOf: extractAttachments(from: nested, parentEmlSection: childParent))
            }
        }
        return attachments
    }

    /// Recursively extract inline image metadata (parts with Content-ID) from Gmail MIME parts.
    private func extractInlineImageMeta(from parts: [GmailPart]) -> [(contentId: String, mimeType: String, attachmentId: String?, inlineData: String?)] {
        var results: [(contentId: String, mimeType: String, attachmentId: String?, inlineData: String?)] = []
        for part in parts {
            if let headers = part.headers,
               let cidHeader = headers.first(where: { $0.name.lowercased() == "content-id" }),
               let mimeType = part.mimeType, mimeType.lowercased().hasPrefix("image/") {
                // Strip angle brackets + whitespace: "< image001@host >" → "image001@host"
                let contentId = cidHeader.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !contentId.isEmpty {
                    results.append((contentId: contentId, mimeType: mimeType,
                                    attachmentId: part.body?.attachmentId, inlineData: part.body?.data))
                }
            }
            if let nested = part.parts {
                results.append(contentsOf: extractInlineImageMeta(from: nested))
            }
        }
        return results
    }

    /// Fetch inline image data for CID resolution.
    private func fetchInlineImages(messageId: String, from parts: [GmailPart]) async -> [InlineImage] {
        let meta = extractInlineImageMeta(from: parts).prefix(SyncConfig.maxInlineImages)
        var images: [InlineImage] = []
        for item in meta {
            // Try inline body data first (small images)
            if let inlineData = item.inlineData, let decoded = decodeBase64URLToData(inlineData) {
                images.append(InlineImage(contentId: item.contentId, contentType: item.mimeType, data: decoded))
                continue
            }
            // Fetch via attachments API
            guard let attachmentId = item.attachmentId else { continue }
            do {
                let data = try await fetchAttachment(messageId: messageId, attachmentId: attachmentId)
                images.append(InlineImage(contentId: item.contentId, contentType: item.mimeType, data: data))
            } catch {
                // `item.contentId` is the sender's `Content-ID` header value —
                // the same sender-authored MIME-header class as `filename`, and
                // NOT in the brief this fix came from; found by the source scan
                // in `RenderPathLogSinkTests`, which is the point of having it.
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[Gmail] Failed to fetch inline image \(DebugModeManager.escapedForLogLine(item.contentId)): \(DebugModeManager.escapedForLogLine(String(describing: error)))")
                }
            }
        }
        return images
    }

    /// Fetches body content stored as an attachment (for large messages)
    private func fetchAttachmentBody(messageId: String, attachmentId: String) async throws -> String? {
        let data = try await request(path: "/messages/\(messageId)/attachments/\(attachmentId)")
        let attachment = try JSONDecoder().decode(GmailAttachment.self, from: data)
        guard let bodyData = attachment.data else { return nil }
        return decodeBase64URL(bodyData)
    }

    private func decodeBase64URL(_ str: String) -> String? {
        guard let data = decodeBase64URLToData(str) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeBase64URLToData(_ str: String) -> Data? {
        var base64 = str
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private func gmailLabelRole(_ labelId: String) -> FolderRole? {
        switch labelId {
        case "INBOX": return .inbox
        case "SENT": return .sent
        case "DRAFT": return .drafts
        case "TRASH": return .trash
        case "SPAM": return .spam
        case "STARRED": return .custom // Starred is a custom folder for our purposes
        default: return nil
        }
    }

    /// An `In-Reply-To` or `References` field, folded as the IMAP path folds it
    /// (`IMAPProvider.foldedFieldBody`). `ids` must already be bracketed `<id>`s
    /// (`IMAPProvider.threadingMessageIDs`).
    nonisolated static func messageIDField(_ name: String, _ ids: [String]) -> String {
        "\(name):" + IMAPProvider.foldedFieldBody(name, ids)
    }

    nonisolated func buildRFC822(draft: DraftMessage) -> String {
        var lines: [String] = []
        // Include Message-ID so Gmail preserves our rfc822MessageId. Without this,
        // Gmail assigns its own, breaking rfc822MessageId-based UID remap detection
        // when the sync replaces our optimistic header with the real server header.
        if let messageId = draft.messageId, !messageId.isEmpty {
            let bracketed = messageId.hasPrefix("<") ? messageId : "<\(messageId)>"
            lines.append("Message-ID: \(bracketed)")
        }
        lines.append("To:\(IMAPProvider.recipientsFieldBody("To", draft.to))")
        if !draft.cc.isEmpty { lines.append("Cc:\(IMAPProvider.recipientsFieldBody("Cc", draft.cc))") }
        // Gmail delivers to the Bcc header's recipients (documented for
        // users.messages.send). Leaving the header out of the delivered copies
        // while a draft and the Sent copy keep it is observed, not documented.
        if !draft.bcc.isEmpty { lines.append("Bcc:\(IMAPProvider.recipientsFieldBody("Bcc", draft.bcc))") }
        lines.append("Subject: \(RFC2047.encodeHeaderValue(draft.subject))")
        if let replyTo = IMAPProvider.threadingMessageIDs(draft.inReplyTo.map { [$0] } ?? []).first {
            lines.append(Self.messageIDField("In-Reply-To", [replyTo]))
        }
        let references = IMAPProvider.threadingMessageIDs(draft.references)
        if !references.isEmpty {
            lines.append(Self.messageIDField("References", references))
        }
        lines.append("MIME-Version: 1.0")
        if draft.isHTML {
            let boundary = "TabMail-Boundary-\(UUID().uuidString)"
            lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("")
            lines.append(EmailFilter.htmlToPlainText(draft.body))
            lines.append("")
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/html; charset=utf-8")
            lines.append("")
            lines.append(draft.body)
            lines.append("")
            lines.append("--\(boundary)--")
        } else {
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("")
            lines.append(draft.body)
        }
        return lines.joined(separator: "\r\n")
    }

    /// Build a MIME multipart message with attachments for Gmail API.
    /// Calendar invitations (isAlternative=true) use multipart/alternative structure
    /// so Gmail/Outlook render Accept/Decline buttons instead of a generic .ics attachment.
    nonisolated func buildMIMEMessage(draft: DraftMessage) -> Data {
        let boundary = "TabMail-Boundary-\(UUID().uuidString)"
        let hasAlternative = draft.attachments.contains { $0.isAlternative }
        let regularAttachments = draft.attachments.filter { !$0.isAlternative }
        let alternativeAttachments = draft.attachments.filter { $0.isAlternative }
        var message = ""

        // Headers
        if let messageId = draft.messageId, !messageId.isEmpty {
            let bracketed = messageId.hasPrefix("<") ? messageId : "<\(messageId)>"
            message += "Message-ID: \(bracketed)\r\n"
        }
        message += "To:\(IMAPProvider.recipientsFieldBody("To", draft.to))\r\n"
        if !draft.cc.isEmpty { message += "Cc:\(IMAPProvider.recipientsFieldBody("Cc", draft.cc))\r\n" }
        // See buildRFC822: Gmail delivers to Bcc recipients and, as observed,
        // leaves the header out of the delivered copies.
        if !draft.bcc.isEmpty { message += "Bcc:\(IMAPProvider.recipientsFieldBody("Bcc", draft.bcc))\r\n" }
        message += "Subject: \(RFC2047.encodeHeaderValue(draft.subject))\r\n"
        if let replyTo = IMAPProvider.threadingMessageIDs(draft.inReplyTo.map { [$0] } ?? []).first {
            message += Self.messageIDField("In-Reply-To", [replyTo]) + "\r\n"
        }
        let references = IMAPProvider.threadingMessageIDs(draft.references)
        if !references.isEmpty {
            message += Self.messageIDField("References", references) + "\r\n"
        }
        message += "MIME-Version: 1.0\r\n"

        if hasAlternative && regularAttachments.isEmpty {
            // Pure calendar invitation: multipart/alternative (HTML + ICS)
            message += "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n"
        } else {
            message += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n"
        }
        message += "\r\n"

        // Body part(s) — for HTML drafts, include both text/plain and text/html
        if draft.isHTML {
            let altBoundary = "TabMail-Alt-\(UUID().uuidString)"
            message += "--\(boundary)\r\n"
            message += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n"
            message += "\r\n"
            // text/plain alternative derived from HTML
            message += "--\(altBoundary)\r\n"
            message += "Content-Type: text/plain; charset=utf-8\r\n"
            message += "Content-Transfer-Encoding: 8bit\r\n"
            message += "\r\n"
            message += EmailFilter.htmlToPlainText(draft.body)
            message += "\r\n\r\n"
            // text/html part
            message += "--\(altBoundary)\r\n"
            message += "Content-Type: text/html; charset=utf-8\r\n"
            message += "Content-Transfer-Encoding: 8bit\r\n"
            message += "\r\n"
            message += draft.body
            message += "\r\n\r\n"
            message += "--\(altBoundary)--\r\n\r\n"
        } else {
            message += "--\(boundary)\r\n"
            message += "Content-Type: text/plain; charset=utf-8\r\n"
            message += "Content-Transfer-Encoding: 8bit\r\n"
            message += "\r\n"
            message += draft.body
            message += "\r\n\r\n"
        }

        var data = Data(message.utf8)

        // Alternative parts (calendar invitations) — inline, no Content-Disposition
        for alt in alternativeAttachments {
            var partHeader = "--\(boundary)\r\n"
            partHeader += "Content-Type: \(alt.mimeType)\r\n"
            partHeader += "Content-Transfer-Encoding: base64\r\n"
            partHeader += "\r\n"
            data.append(Data(partHeader.utf8))

            let base64 = alt.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
            data.append(Data(base64.utf8))
            data.append(Data("\r\n\r\n".utf8))
        }

        // Regular attachment parts
        for attachment in regularAttachments {
            var partHeader = "--\(boundary)\r\n"
            partHeader += "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n"
            partHeader += "Content-Transfer-Encoding: base64\r\n"
            partHeader += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n"
            partHeader += "\r\n"
            data.append(Data(partHeader.utf8))

            let base64 = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
            data.append(Data(base64.utf8))
            data.append(Data("\r\n\r\n".utf8))
        }

        // Closing boundary
        data.append(Data("--\(boundary)--\r\n".utf8))

        return data
    }
}

/// Message header with Gmail label IDs — used by delta sync for folder assignment.
struct GmailMessageDetail: Sendable {
    let header: MessageHeaderInfo
    let labelIds: [String]
}

/// What `GmailProvider.fetchMessageDetails` read: the messages it loaded, and
/// the ids whose own answer could not be used this time.
struct GmailDetailBatch: Sendable {
    var details: [GmailMessageDetail] = []
    var unreadable: [String] = []
}

// MARK: - Gmail API Response Models

private struct GmailLabelsResponse: Decodable {
    let labels: [GmailLabel]
}

private struct GmailLabel: Decodable {
    let id: String
    let name: String
    let type: String?
    let messagesTotal: Int?
    let messagesUnread: Int?
}

private struct GmailMessageListResponse: Decodable {
    let messages: [GmailMessageRef]?
    let nextPageToken: String?
}

private struct GmailDraftListResponse: Decodable {
    let drafts: [GmailDraftRef]?
    let nextPageToken: String?
}

private struct GmailDraftRef: Decodable {
    let id: String
    let message: GmailDraftMessageRef?
}

private struct GmailDraftMessageRef: Decodable {
    let id: String
}

private struct GmailMessageRef: Decodable {
    let id: String
    let threadId: String
}

// Visible to tests via @testable import. Fields match Gmail REST API response schema.
// Codable (not just Decodable) so GmailProvider.parseGmailMessage can re-
// serialize and hand off to Shared/Parse/GmailParse.parseMessage. Runtime
// cost is one JSON round-trip per message — small, and it lets the shared
// parser be the single source of truth.
struct GmailMessage: Codable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let payload: GmailPayload?
}

// Visible to tests via @testable import.
struct GmailPayload: Codable {
    let mimeType: String?
    /// Attachment filename when the payload node IS itself an attachment — i.e. a
    /// single-part message whose whole body is one file (e.g. a DMARC aggregate
    /// report = one `application/zip`, no text body, no `parts`). Gmail populates
    /// this on the top-level `payload` MessagePart in that case.
    let filename: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPart]?

    // Explicit memberwise init with `filename` defaulted so existing call sites
    // that don't set it keep compiling. Codable's synthesized `init(from:)` still
    // decodes the JSON `filename` key independently of this init.
    init(mimeType: String?, filename: String? = nil, headers: [GmailHeader]?, body: GmailBody?, parts: [GmailPart]?) {
        self.mimeType = mimeType
        self.filename = filename
        self.headers = headers
        self.body = body
        self.parts = parts
    }
}

struct GmailHeader: Codable {
    let name: String
    let value: String
}

struct GmailBody: Codable {
    let data: String?
    let size: Int?
    let attachmentId: String?
}

struct GmailPart: Codable {
    let mimeType: String?
    let filename: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPart]?
}

private struct GmailAttachment: Decodable {
    let data: String?
    let size: Int?
}

private struct GmailProfile: Decodable {
    let emailAddress: String
    let historyId: String
    let messagesTotal: Int?
}

// MARK: - Gmail History API Response Models

private struct GmailHistoryListResponse: Decodable {
    let history: [GmailHistoryRecord]?
    let historyId: String
    let nextPageToken: String?
}

private struct GmailHistoryRecord: Decodable {
    let id: String
    let messagesAdded: [GmailHistoryMessageAdded]?
    let messagesDeleted: [GmailHistoryMessageDeleted]?
    let labelsAdded: [GmailHistoryLabelAdded]?
    let labelsRemoved: [GmailHistoryLabelRemoved]?
}

private struct GmailHistoryMessageAdded: Decodable {
    let message: GmailHistoryMessage
}

private struct GmailHistoryMessageDeleted: Decodable {
    let message: GmailHistoryMessage
}

private struct GmailHistoryLabelAdded: Decodable {
    let message: GmailHistoryMessage
    let labelIds: [String]
}

private struct GmailHistoryLabelRemoved: Decodable {
    let message: GmailHistoryMessage
    let labelIds: [String]
}

private struct GmailHistoryMessage: Decodable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
}

/// A Gmail draft-copy part that came back without readable bytes. Retryable;
/// never "gone" (#217).
struct GmailDraftCopyIncomplete: Error { let mimeType: String }
