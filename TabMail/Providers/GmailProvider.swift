/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

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
///    `findLabelIdByName` discovery must not replace the newer knowledge, so a
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
    static let allMailExclusionQuery = "-in:inbox -in:sent -in:trash -in:spam -in:draft"
    private static let draftResourceLookupPageSize = 500

    private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let userEmail: String
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
                    let msgData = try await self.request(path: "/messages/\(ref.id)\(GmailAPI.metadataQuery)")
                    let msg = try JSONDecoder().decode(GmailMessage.self, from: msgData)
                    return (ref.id, await self.parseGmailMessage(msg))
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
            if DebugModeManager.isLoggingEnabled() { print("[Gmail] Failed to fetch backfill \(id): \(error)") }
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
            if DebugModeManager.isLoggingEnabled() { print("[Gmail] Body extraction failed for \(id): \(error) — header preserved") }
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
        // instead, same translation as fetchMessages/listBackfillMessageIds.
        if folder == GmailProvider.archivePath {
            q += " " + GmailProvider.allMailExclusionQuery
        }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        // Scope to folder using labelIds parameter (works for both system and custom labels)
        let labelParam = (folder.isEmpty || folder == GmailProvider.archivePath) ? "" : "&labelIds=\(folder)"
        let data = try await request(path: "/messages?q=\(encoded)&maxResults=20\(labelParam)")
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

    /// THE PER-MEMBER BOUNDARY for every Gmail label mutation.
    ///
    /// Gmail's `messages.modify` addresses ONE message per request, so this loop
    /// is the only place in the system that can attribute a not-found answer to a
    /// specific member. It therefore owns the per-member interpretation: a member
    /// the server AUTHORITATIVELY reports gone is dispositioned and recorded, the
    /// loop continues, and the surviving members are still processed. Reported
    /// afterwards as `ProviderMembersDispositioned`, which
    /// `AccountManager.executeOperation` converts into a complete outcome naming
    /// those members.
    ///
    /// 🚨 THIS IS WHAT REPLACES THE DRAIN'S BATCH SPLIT. The scheduler used to
    /// respond to a batch not-found by writing one replacement `PendingOperation`
    /// per member and deleting the parent, purely to discover which member was
    /// gone. The discovery belongs here, where the request is actually addressed;
    /// the durable row keeps its id and is never re-shaped.
    ///
    /// ⚠ ONLY A STRUCTURAL, MEMBER-ADDRESSED NOT-FOUND IS ABSORBED. Everything
    /// else — a 5xx, a 429, a timeout, an auth failure, a cancellation — is
    /// rethrown immediately with the remaining members untouched, so the whole
    /// operation stays queued and retries. Re-running the already-successful
    /// members on that retry is accepted: `messages.modify` add/remove label is
    /// idempotent and does not change the message id.
    ///
    /// 🚨 IT STOPS ON `ProviderMemberLoopBudget` AND REPORTS THE PREFIX IT
    /// FINISHED. Without that, a batch whose members cost more wall time in total
    /// than `SyncConfig.pendingOperationTimeoutSeconds` is cancelled mid-loop,
    /// `withTimeout` has ALREADY resumed the drain with `TimeoutError`, and every
    /// member this loop settled is discarded with the abandoned task — so the row
    /// is requeued unchanged and the next attempt repeats the same prefix into the
    /// same deadline, forever. The last member's intention never reaches Gmail.
    /// That is the wedge corollary, and it is why the budget is checked BETWEEN
    /// members: at least one member is always attempted, so every attempt makes
    /// strict progress and a batch of any size converges.
    private func modifyEachMessage(
        ids: [String],
        addLabelIds: [String] = [],
        removeLabelIds: [String] = [],
        moveTraceLabel: String? = nil
    ) async throws {
        var absent: [String] = []
        var dispositioned: [String] = []
        let deadline = ProviderMemberLoopBudget.deadlineFromNow()
        for id in ids {
            // Never before the first member: an attempt that settles nothing is
            // an attempt that cannot converge.
            if !dispositioned.isEmpty, ContinuousClock.now >= deadline {
                if DebugModeManager.isLoggingEnabled() {
                    print("[Gmail] modifyEachMessage: budget spent after \(dispositioned.count)/\(ids.count) member(s) — reporting the finished prefix so the operation narrows instead of repeating it")
                }
                break
            }
            do {
                try await modifyMessage(
                    id: id, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
                dispositioned.append(id)
                if let moveTraceLabel, DebugModeManager.isLoggingEnabled() {
                    print("[MoveTrace] \(moveTraceLabel) — modifyMessage completed for \(id)")
                }
            } catch {
                guard ProviderMemberAbsence.isAuthoritative(error) else { throw error }
                absent.append(id)
                dispositioned.append(id)
                if DebugModeManager.isLoggingEnabled() {
                    print("[Gmail] modifyMessage \(id): the server reports THIS message gone — the member is dispositioned and the remaining members are still processed")
                }
            }
        }
        // Silence is "every member, mutated": the only outcome the `Void`-returning
        // protocol can express on its own. Anything else has to be reported.
        if !absent.isEmpty || dispositioned.count != ids.count {
            throw ProviderMembersDispositioned(
                dispositionedMemberIds: dispositioned, absentMemberIds: absent)
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

    func move(ids: [String], from source: String, to destination: String) async throws {
        // source and destination are label IDs (path). Filter out empty/synthetic paths
        // that aren't valid Gmail API label IDs — e.g., "" or "__GMAIL_ALL_MAIL__" from
        // undo-archive, where only adding the destination label is needed.
        var remove = (source.isEmpty || source == GmailProvider.archivePath) ? [] : [source]
        // Archive = just remove source label (message stays in All Mail implicitly)
        let add = (destination == GmailProvider.archivePath) ? [] : [destination]
        // Legacy-label decay (ADR-IOS-036): when moving OUT of the inbox, also
        // strip any leftover tm_* labels the account picked up from pre-ADR
        // TabMail versions. Batched into the same messages.modify call — zero
        // extra round-trip. Only runs on inbox-exit so we don't disturb labels
        // on messages that stay in other folders.
        if source == "INBOX" && !userLabelCatalog.legacyTmLabelIds.isEmpty {
            remove.append(contentsOf: userLabelCatalog.legacyTmLabelIds)
        }
        // No-op: both source and destination resolve to no label changes (e.g., move from
        // All Mail to All Mail). Skip the API call — Gmail rejects empty modify bodies.
        guard !remove.isEmpty || !add.isEmpty else {
            if DebugModeManager.isLoggingEnabled() { print("[MoveTrace] GmailProvider.move — no-op (no label changes): ids=\(ids) source=\(source) dest=\(destination)") }
            return
        }
        if DebugModeManager.isLoggingEnabled() { print("[MoveTrace] GmailProvider.move — ids=\(ids) addLabels=\(add) removeLabels=\(remove)") }
        // A Gmail move is a label mutation, so it goes through the same
        // per-member boundary as the setters: one gone member does not strand
        // the rest, and the id is stable across it (no address churn to re-learn).
        try await modifyEachMessage(
            ids: ids, addLabelIds: add, removeLabelIds: remove,
            moveTraceLabel: "GmailProvider.move")
    }

    func send(draft: DraftMessage) async throws {
        let body = buildSendBody(draft: draft)
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let _ = try await request(path: "/messages/send", method: "POST", body: jsonData)
    }

    /// Build the `users.messages.send` request body. Includes `threadId` when the
    /// draft carries one (reply/forward), so Gmail files the message into the
    /// existing conversation instead of starting a new thread. Gmail also requires
    /// the raw message to carry RFC-compliant References/In-Reply-To and a matching
    /// Subject — all set by the centralized ComposeView callsite. See ADR-IOS-043.
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
    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool {
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
        let base64 = buildUrlSafeBase64(draft: draft)
        let messagePayload: [String: Any] = ["raw": base64]

        // Log exactly what we're sending — base64 body length + first chars of
        // plain body + recipients. Helps diagnose "remote shows stale" reports:
        // if this log's bodyPrefix matches the user's fresh edit, the push
        // content is correct and any server-side staleness is on Gmail's side.
        if DebugModeManager.isLoggingEnabled() {
            let bodyPreview = String(draft.body.prefix(120))
            print("[Gmail] saveDraft REQUEST: existingId=\(existingDraftId ?? "nil") subject=\(String(draft.subject.prefix(60))) to=\(draft.to) bodyLen=\(draft.body.count) bodyPrefix=\(bodyPreview) rawB64Len=\(base64.count)")
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
                if DebugModeManager.isLoggingEnabled() { print("[Gmail] saveDraft UPDATE RESPONSE: draftId=\(draftId) messageId=\(msgId ?? "nil") responseSnippet=\(String(msgSnippet.prefix(120)))") }
                return .created(.gmail(resourceId: draftId, containedMessageId: msgId))
            }
            if DebugModeManager.isLoggingEnabled() { print("[Gmail] saveDraft UPDATE RESPONSE: failed to parse JSON — returning existingId=\(existingId)") }
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
            if DebugModeManager.isLoggingEnabled() { print("[Gmail] saveDraft CREATE RESPONSE: draftId=\(draftId) messageId=\(msgId ?? "nil") responseSnippet=\(String(msgSnippet.prefix(120)))") }
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
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var encodedItems: [URLQueryItem] = []
        for item in queryItems {
            guard let name = item.name.addingPercentEncoding(withAllowedCharacters: unreserved),
                  let value = item.value.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                throw ProviderError.invalidURL("Gmail draft resource lookup")
            }
            encodedItems.append(URLQueryItem(name: name, value: value))
        }
        var components = URLComponents()
        components.path = path
        components.percentEncodedQueryItems = encodedItems
        guard let result = components.string else {
            throw ProviderError.invalidURL("Gmail draft resource lookup")
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
            if DebugModeManager.isLoggingEnabled() { print("[Gmail] deleteDraft: \(messageId) already deleted") }
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

    /// Fetch older messages within a date range that aren't already known locally.
    /// Uses Gmail API pagination with `after:` epoch filter and `nextPageToken`.
    /// Checks Task.isCancelled between pages for cooperative cancellation (ADR-IOS-002).
    /// LIST phase: find all message IDs in a date range via pagination.
    /// Returns lightweight string IDs — no message content fetched.
    /// `pageSize` and `interPageDelay` are power-aware via BackfillProfile.
    func listBackfillMessageIds(
        folder: String,
        since: Date,
        before: Date? = nil,
        pageSize: Int = 500,
        interPageDelay: TimeInterval = 0.3,
        maxIds: Int = SyncConfig.gmailBackfillIdCap
    ) async throws -> [String] {
        let sinceEpoch = Int(since.timeIntervalSince1970)
        var pageToken: String? = nil
        var allIds: [String] = []

        repeat {
            try Task.checkCancellation()

            var query = "after:\(sinceEpoch)"
            if let before { query += " before:\(Int(before.timeIntervalSince1970))" }
            if folder == GmailProvider.archivePath {
                query += " " + GmailProvider.allMailExclusionQuery
            }
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            var path: String
            if folder == GmailProvider.archivePath {
                path = "/messages?maxResults=\(pageSize)&q=\(encodedQuery)"
            } else {
                path = "/messages?labelIds=\(folder)&maxResults=\(pageSize)&q=\(encodedQuery)"
            }
            if let token = pageToken {
                path += "&pageToken=\(token)"
            }

            let data = try await request(path: path)
            let listResponse = try JSONDecoder().decode(GmailMessageListResponse.self, from: data)

            guard let messageRefs = listResponse.messages else { break }
            allIds.append(contentsOf: messageRefs.map(\.id))

            // Safety cap: stop pagination if we've accumulated enough IDs.
            // Remaining messages are picked up on next backfill cycle via date windowing.
            if allIds.count >= maxIds {
                if DebugModeManager.isLoggingEnabled() { print("[Gmail] WARNING: listBackfillMessageIds hit \(maxIds) ID cap — stopping pagination. This folder has an unusually large number of messages.") }
                break
            }

            pageToken = listResponse.nextPageToken
            if pageToken != nil {
                try await Task.sleep(for: .seconds(interPageDelay))
            }
        } while pageToken != nil

        return allIds
    }

    /// FETCH phase: fetch message headers for specific Gmail message IDs.
    /// Called after existence checks have filtered to only missing IDs.
    /// `concurrency` > 1 enables parallel API calls via TaskGroup (dramatically faster for backfill).
    /// `interBatchDelay` controls throttle between batches (power-aware via BackfillProfile).
    func fetchMessageHeaders(ids: [String], batchSize: Int = 50, interBatchDelay: TimeInterval = 0.5, concurrency: Int = 1) async throws -> [MessageHeaderInfo] {
        guard !ids.isEmpty else { return [] }
        let metadataPath = GmailAPI.metadataQuery

        var allHeaders: [MessageHeaderInfo] = []

        // Process in batches, with optional concurrency within each batch
        for batchStart in stride(from: 0, to: ids.count, by: batchSize) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + batchSize, ids.count)
            let batch = Array(ids[batchStart..<batchEnd])

            if concurrency <= 1 {
                // Sequential (original behavior)
                for id in batch {
                    try Task.checkCancellation()
                    let msgData = try await request(path: "/messages/\(id)\(metadataPath)")
                    let msg = try JSONDecoder().decode(GmailMessage.self, from: msgData)
                    if let header = parseGmailMessage(msg) {
                        allHeaders.append(header)
                    }
                }
            } else {
                // Concurrent — multiple HTTP calls in flight simultaneously.
                // Collect raw API responses in parallel, then parse on actor (parseGmailMessage
                // accesses actor state). The HTTP round-trips are the bottleneck, not parsing.
                // Individual task errors are caught so one failure doesn't kill the batch.
                // Auth errors are re-thrown to cancel everything (all requests would fail anyway).
                let rawResponses = try await withThrowingTaskGroup(of: Data?.self) { group in
                    var results: [Data] = []
                    var iter = batch.makeIterator()

                    // Seed initial concurrent tasks
                    for _ in 0..<min(concurrency, batch.count) {
                        if let id = iter.next() {
                            group.addTask {
                                do {
                                    return try await self.request(path: "/messages/\(id)\(metadataPath)")
                                } catch {
                                    if case ProviderError.authenticationFailed = error { throw error }
                                    if DebugModeManager.isLoggingEnabled() { print("[Gmail] Failed to fetch header \(id): \(error)") }
                                    return nil
                                }
                            }
                        }
                    }

                    // As each completes, start the next
                    for try await data in group {
                        if let data { results.append(data) }
                        if let id = iter.next() {
                            group.addTask {
                                do {
                                    return try await self.request(path: "/messages/\(id)\(metadataPath)")
                                } catch {
                                    if case ProviderError.authenticationFailed = error { throw error }
                                    if DebugModeManager.isLoggingEnabled() { print("[Gmail] Failed to fetch header \(id): \(error)") }
                                    return nil
                                }
                            }
                        }
                    }

                    return results
                }
                // Parse on actor (synchronous, fast — no actor-isolated state to read)
                for data in rawResponses {
                    if let msg = try? JSONDecoder().decode(GmailMessage.self, from: data),
                       let header = parseGmailMessage(msg) {
                        allHeaders.append(header)
                    }
                }
            }

            // Yield between batches
            if batchStart + batchSize < ids.count, interBatchDelay > 0 {
                try await Task.sleep(for: .seconds(interBatchDelay))
            }
        }
        return allHeaders
    }

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

    /// Single-page listing for cursor-based backfill. Returns one page of message IDs
    /// plus the nextPageToken for resuming. No date filter — walks the entire label listing
    /// newest→oldest. Archive path uses exclusion query.
    func listMessageIdsPage(
        folder: String,
        pageToken: String? = nil,
        pageSize: Int = 500
    ) async throws -> (ids: [String], nextPageToken: String?) {
        try Task.checkCancellation()

        var path: String
        if folder == GmailProvider.archivePath {
            let q = GmailProvider.allMailExclusionQuery
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            path = "/messages?maxResults=\(pageSize)&q=\(encoded)"
        } else {
            path = "/messages?labelIds=\(folder)&maxResults=\(pageSize)"
        }
        if let token = pageToken {
            path += "&pageToken=\(token)"
        }

        let data = try await request(path: path)
        let listResponse = try JSONDecoder().decode(GmailMessageListResponse.self, from: data)
        let ids = listResponse.messages?.map(\.id) ?? []
        return (ids: ids, nextPageToken: listResponse.nextPageToken)
    }

    func fetchOlderMessages(folder: String, before: Date, limit: Int) async throws -> [MessageHeaderInfo] {
        try await fetchOlderMessagesWithCoverage(folder: folder, before: before, limit: limit).messages
    }

    /// Infinite-scroll page plus what the SERVER covered for it. The paging
    /// consumer's continuation signal is a coverage question, and the loop below
    /// drops records `parseGmailMessage` refuses — see `FetchCoverage`.
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
            let msgData = try await request(path: "/messages/\(ref.id)\(GmailAPI.metadataQuery)")
            let msg = try JSONDecoder().decode(GmailMessage.self, from: msgData)
            if let header = parseGmailMessage(msg) {
                headers.append(header)
            } else {
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
        // and NSE. 404 (historyId expired) surfaces as nil so callers fall back
        // to full sync, matching legacy behavior.
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
            if DebugModeManager.isLoggingEnabled() { print("[Gmail] History expired (historyId: \(historyId)) — need full sync") }
            BackgroundSyncLogger.log("gmail.fetchHistory: 404 history expired")
            return nil
        }

        BackgroundSyncLogger.log("gmail.fetchHistory: decoded newHid=\(delta.cursor) adds=\(delta.added.count) dels=\(delta.removed.count) labAdds=\(delta.labelsAdded.count) labRms=\(delta.labelsRemoved.count)")

        // Convert shared HistoryDelta → main-app HistoryResponse at the boundary.
        let added = delta.added.map { HistoryMessageRef(messageId: $0.providerMessageId, labelIds: $0.providerLabels) }
        let deleted = delta.removed.map { HistoryMessageRef(messageId: $0.providerMessageId, labelIds: $0.providerLabels) }
        let labelsAdded = delta.labelsAdded.map { HistoryLabelChange(messageId: $0.providerMessageId, labelIds: $0.labelIds) }
        let labelsRemoved = delta.labelsRemoved.map { HistoryLabelChange(messageId: $0.providerMessageId, labelIds: $0.labelIds) }

        if DebugModeManager.isLoggingEnabled() { print("[Gmail] History: +\(added.count) added, -\(deleted.count) deleted, \(labelsAdded.count) label adds, \(labelsRemoved.count) label removes") }

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

    /// Fetch message details including label IDs for delta sync folder assignment.
    func fetchMessageDetails(ids: [String]) async throws -> [GmailMessageDetail] {
        var results: [GmailMessageDetail] = []
        for id in ids {
            do {
                let msgData = try await request(path: "/messages/\(id)\(GmailAPI.metadataQuery)")
                let msg = try JSONDecoder().decode(GmailMessage.self, from: msgData)
                if let header = parseGmailMessage(msg) {
                    results.append(GmailMessageDetail(header: header, labelIds: msg.labelIds ?? []))
                }
            } catch {
                // Message deleted between history listing and detail fetch — skip.
                // Normal for Gmail: history reports the messageId but the message
                // is gone by fetch time. Skipping lets historyId advance instead
                // of looping forever on the same 404.
                if DebugModeManager.isLoggingEnabled() { print("[Gmail] fetchMessageDetails: skipping \(id) — \(error)") }
            }
        }
        return results
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

    /// Route all Gmail REST traffic through `Shared/HTTP/AuthedHTTP`. Previous
    /// inline 401-retry + rate-limit logic deleted — that's the shared
    /// `AuthedHTTP` path now.
    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        // Boundary guard: TabMail's synthetic "All Mail" path is not a real Gmail
        // label ID. Callers must translate it (query exclusions, no labelIds) before
        // building a request — Gmail returns HTTP 400 "Invalid label" otherwise.
        // Mirrors the syntheticPlaceholderId guard in fetchMessagesBatch.
        if path.contains(GmailProvider.archivePath) {
            if DebugModeManager.isLoggingEnabled() { print("[Gmail] ERROR: synthetic folder path leaked into API path: \(path)") }
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
    /// resolves an identity by search), leaving `modifyMessage`'s POST as the
    /// only body-classifying call site on this tree. A `GET` arm here would be
    /// unreachable code, and its absence cannot silently mis-route anything:
    /// the `default` arm below traps at the callsite rather than quietly
    /// downgrading to the bodyless path.
    ///
    /// `method` and `body` are deliberately NOT defaulted (the reference
    /// defaults them to `"GET"` / `nil`): on this tree `GET` hits the
    /// `default` trap, so a default that reaches it would be a latent crash
    /// rather than a convenience.
    private func requestPreservingBadRequestBody(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Data {
        if path.contains(GmailProvider.archivePath) {
            if DebugModeManager.isLoggingEnabled() { print("[Gmail] ERROR: synthetic folder path leaked into API path: \(path)") }
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

    /// The `(reason, message)` pair of a Gmail `400` whose STRUCTURED body we
    /// actually parsed, or `nil` for every other error — including a `400` whose
    /// body is absent, unparseable, or shaped differently. Factored out of
    /// `isGmailInvalidIdError` so the queue's terminal classifier and this
    /// provider's own stale-no-op arm read the SAME bytes the SAME way; two
    /// independent decoders of one wire shape is how a half-port drops a guard.
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

    /// True only when Gmail's own structured `400` body PROVES this request can
    /// never succeed, whatever we do — the sole `400` shape that may retire a
    /// durable `PendingOperation` (exit 2: a provider-authoritative no-op).
    ///
    /// 🚨 THE NEGATIVE CASE IS THE POINT. A `400` with no body, an unparseable
    /// body, a body whose `reason` is not `invalidArgument`, or a recognised
    /// reason with an unrecognised message all return **false** and keep the
    /// operation retryable. "The server rejected it and did not say why" is an
    /// absence of evidence; treating it as authority is the clause-2 conflation
    /// `Companion/Rules/Active/never-drop-user-intention.md` names as the single
    /// most repeated defect in this codebase's history, and
    /// `AccountManager.isPermanentlyInvalidError` committed it for EVERY
    /// `400` — bare status codes included — until this classifier replaced it.
    ///
    /// The two recognised messages are Gmail's own literal wordings, both of
    /// which name something structurally impossible rather than something that
    /// might work later:
    ///   * `"Invalid id value"` — the message id is malformed; no retry resolves
    ///     it (this is also the arm `modifyMessage` absorbs locally, and the
    ///     mirror of Exchange's `ErrorInvalidIdMalformed`);
    ///   * `"Invalid label"` — the label named cannot be modified on this
    ///     message, e.g. the system `DRAFT` label. This is the case the queue's
    ///     terminal arm was originally written for; before the body survived to
    ///     be read, it could only be guessed at from the status line.
    nonisolated static func isAuthoritativeActionRejection(_ error: Error) -> Bool {
        guard let rejection = structuredBadRequestRejection(error),
              rejection.reason == "invalidArgument" else { return false }
        return rejection.message.hasPrefix("Invalid id value")
            || rejection.message.hasPrefix("Invalid label")
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
    /// v3 has no `persistentActionFailure` case and no demote lane
    /// (`AccountManagerQueue` says so at the `.actionIdentityResolutionFailed`
    /// arm: "machinery this tree does not have (F2b L4)"). Adding the wrapper
    /// without the lane would be strictly WORSE than not porting it: an
    /// unrecognized case falls through to the queue's generic transient branch
    /// and retries forever — the exact wedge the reference's arm exists to
    /// prevent. Rethrowing unchanged sends the unclassified `400` to the queue's
    /// generic transient branch.
    ///
    /// ⚠ CORRECTED (audit round 1, finding B-3). This paragraph used to end
    /// "Rethrowing unchanged keeps v3's shipped terminal disposition for a Gmail
    /// action `400` (`AccountManager.isPermanentlyInvalidError` → drop the
    /// op)". That disposition was itself the defect: the matcher bound the body
    /// to `_` and retired the op on the bare STATUS, so an unrecognised `400`
    /// destroyed the user's action rather than wedging. It no longer does —
    /// `isPermanentlyInvalidError` now delegates to
    /// `isAuthoritativeActionRejection`, and an unclassified `400` retries.
    ///
    /// **The wedge the reference's demote lane prevents is therefore REAL on v3
    /// and remains unaddressed**: a chain whose head takes an unrecognised
    /// permanent-shaped `400` blocks its lane on every drain. That is a bounded,
    /// visible, retryable park rather than a silent discard, which is the trade
    /// the never-drop rule explicitly prefers — but it is a known gap, not a
    /// solved problem, and closing it needs the demote lane (F2b L4), not a
    /// widened terminal matcher.
    ///
    /// SUBTRACT — the reference also handles `isGmailInvalidLabelError` here
    /// (invalid/gone label → stale no-op). Not ported as a local `return`,
    /// because `isAuthoritativeActionRejection` recognises that exact body on
    /// the queue side: the `400` reaches the queue and retires the op there, the
    /// same end state the reference reaches by returning. ⚑ Note the brief's
    /// stated premise for dropping it — "it only ever classified failures of the
    /// deleted RFC search" — is FALSE: the reference calls it from
    /// `modifyMessage` too. The drop is justified by the equivalent end state
    /// above, not by that premise.
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
                    print("[Gmail] modifyMessage \(id): invalid-id 400 confirmed stale — treating as no-op")
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
    internal func parseGmailMessage(_ msg: GmailMessage) -> MessageHeaderInfo? {
        // Serialize the decoded GmailMessage back to a [String: Any] JSON dict
        // for the shared parser. Cheap — we already decoded once.
        guard let encoded = try? JSONEncoder().encode(msg),
              let json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let metadata = GmailParse.parseMessage(json) else {
            if DebugModeManager.isLoggingEnabled() { print("[Gmail] Missing/invalid internalDate for message \(msg.id) — treating as fetch failure, will retry") }
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
            subject: metadata.subject.isEmpty ? "(no subject)" : metadata.subject,
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
            userLabelIds: userLabelCatalog.extractUserLabelIds(from: metadata.providerLabels),
            userLabelIdsAreAuthoritative: userLabelCatalog.isAuthoritative
        )
    }

    /// Look up a Gmail label ID by display name. Returns nil if not found.
    /// Used when createLabel returns 409 Conflict (label already exists on server).
    func findLabelIdByName(_ name: String) async throws -> String? {
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
        // Even when this response lost an out-of-order catalog race, the exact
        // match is provider-confirmed and must survive any older request still
        // in flight until a later uncontended catalog replaces the cache.
        userLabelCatalog.recordKnownUserLabel(match.id)
        return match.id
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
                            print("[Gmail] Failed to parse \(DebugModeManager.escapedForLogLine(part.filename ?? "?.eml")) as RFC 822 — rendering as plain attachment")
                        }
                    }
                } catch {
                    if DebugModeManager.isLoggingEnabled() {
                        // `error` can carry a server-supplied string as well.
                        print("[Gmail] Failed to fetch bytes for \(DebugModeManager.escapedForLogLine(part.filename ?? "?")): \(DebugModeManager.escapedForLogLine(String(describing: error)))")
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
                        print("[Gmail] Failed to list nested attachments in \(DebugModeManager.escapedForLogLine(part.filename ?? "?.eml")): \(DebugModeManager.escapedForLogLine(String(describing: error)))")
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
                    print("[Gmail] Failed to fetch inline image \(DebugModeManager.escapedForLogLine(item.contentId)): \(DebugModeManager.escapedForLogLine(String(describing: error)))")
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

    nonisolated func buildRFC822(draft: DraftMessage) -> String {
        var lines: [String] = []
        // Include Message-ID so Gmail preserves our rfc822MessageId. Without this,
        // Gmail assigns its own, breaking rfc822MessageId-based UID remap detection
        // when the sync replaces our optimistic header with the real server header.
        if let messageId = draft.messageId, !messageId.isEmpty {
            let bracketed = messageId.hasPrefix("<") ? messageId : "<\(messageId)>"
            lines.append("Message-ID: \(bracketed)")
        }
        lines.append("To: \(draft.to.joined(separator: ", "))")
        if !draft.cc.isEmpty { lines.append("Cc: \(draft.cc.joined(separator: ", "))") }
        lines.append("Subject: \(RFC2047.encodeHeaderValue(draft.subject))")
        if let replyTo = draft.inReplyTo, !replyTo.isEmpty {
            lines.append("In-Reply-To: \(replyTo.hasPrefix("<") ? replyTo : "<\(replyTo)>")")
        }
        if !draft.references.isEmpty {
            lines.append("References: \(draft.references.map { $0.hasPrefix("<") ? $0 : "<\($0)>" }.joined(separator: " "))")
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
        message += "To: \(draft.to.joined(separator: ", "))\r\n"
        if !draft.cc.isEmpty { message += "Cc: \(draft.cc.joined(separator: ", "))\r\n" }
        message += "Subject: \(RFC2047.encodeHeaderValue(draft.subject))\r\n"
        if let replyTo = draft.inReplyTo, !replyTo.isEmpty {
            message += "In-Reply-To: \(replyTo.hasPrefix("<") ? replyTo : "<\(replyTo)>")\r\n"
        }
        if !draft.references.isEmpty {
            message += "References: \(draft.references.map { $0.hasPrefix("<") ? $0 : "<\($0)>" }.joined(separator: " "))\r\n"
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
