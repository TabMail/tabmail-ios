/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

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
    private var legacyTmLabelIds: Set<String> = []

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
        let data = try await request(path: "/labels")
        let response = try JSONDecoder().decode(GmailLabelsResponse.self, from: data)

        // System labels we explicitly skip (internal Gmail labels, not user-visible)
        let hiddenSystemLabels: Set<String> = [
            "UNREAD", "IMPORTANT",
            "CHAT", "CATEGORY_PERSONAL", "CATEGORY_SOCIAL",
            "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS"
        ]

        var folders: [FolderInfo] = []

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
                    legacyTmLabelIds.insert(label.id)
                }
                if UserLabelStore.shouldExcludeLabel(id: label.id, name: label.name) {
                    continue
                }
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

        guard let messageRefs = listResponse.messages else { return [] }

        // Fetch headers concurrently — messages.list only returns IDs,
        // so each message needs a separate messages.get call. Running them
        // in parallel cuts per-folder time from ~20s (50 × 400ms serial) to ~2-3s.
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
            print("[Gmail] Failed to fetch backfill \(id): \(error)")
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
            print("[Gmail] Body extraction failed for \(id): \(error) — header preserved")
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

    func markRead(ids: [String], folder: String) async throws {
        for id in ids {
            try await modifyMessage(id: id, removeLabelIds: ["UNREAD"])
        }
    }

    func markUnread(ids: [String], folder: String) async throws {
        for id in ids {
            try await modifyMessage(id: id, addLabelIds: ["UNREAD"])
        }
    }

    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {
        for id in ids {
            if flagged {
                try await modifyMessage(id: id, addLabelIds: ["STARRED"])
            } else {
                try await modifyMessage(id: id, removeLabelIds: ["STARRED"])
            }
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
        if source == "INBOX" && !legacyTmLabelIds.isEmpty {
            remove.append(contentsOf: legacyTmLabelIds)
        }
        // No-op: both source and destination resolve to no label changes (e.g., move from
        // All Mail to All Mail). Skip the API call — Gmail rejects empty modify bodies.
        guard !remove.isEmpty || !add.isEmpty else {
            print("[MoveTrace] GmailProvider.move — no-op (no label changes): ids=\(ids) source=\(source) dest=\(destination)")
            return
        }
        print("[MoveTrace] GmailProvider.move — ids=\(ids) addLabels=\(add) removeLabels=\(remove)")
        for id in ids {
            try await modifyMessage(id: id, addLabelIds: add, removeLabelIds: remove)
            print("[MoveTrace] GmailProvider.move — modifyMessage completed for \(id)")
        }
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
            print("[Gmail] saveDraft UPDATE RESPONSE: failed to parse JSON — returning existingId=\(existingId)")
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
            print("[Gmail] deleteDraft: \(messageId) already deleted")
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
                print("[Gmail] WARNING: listBackfillMessageIds hit \(maxIds) ID cap — stopping pagination. This folder has an unusually large number of messages.")
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
                                    print("[Gmail] Failed to fetch header \(id): \(error)")
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
                                    print("[Gmail] Failed to fetch header \(id): \(error)")
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

        guard let messageRefs = listResponse.messages else { return [] }

        var headers: [MessageHeaderInfo] = []
        for ref in messageRefs {
            let msgData = try await request(path: "/messages/\(ref.id)\(GmailAPI.metadataQuery)")
            let msg = try JSONDecoder().decode(GmailMessage.self, from: msgData)
            if let header = parseGmailMessage(msg) {
                headers.append(header)
            }
        }

        return headers
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
            print("[Gmail] History expired (historyId: \(historyId)) — need full sync")
            BackgroundSyncLogger.log("gmail.fetchHistory: 404 history expired")
            return nil
        }

        BackgroundSyncLogger.log("gmail.fetchHistory: decoded newHid=\(delta.cursor) adds=\(delta.added.count) dels=\(delta.removed.count) labAdds=\(delta.labelsAdded.count) labRms=\(delta.labelsRemoved.count)")

        // Convert shared HistoryDelta → main-app HistoryResponse at the boundary.
        let added = delta.added.map { HistoryMessageRef(messageId: $0.providerMessageId, labelIds: $0.providerLabels) }
        let deleted = delta.removed.map { HistoryMessageRef(messageId: $0.providerMessageId, labelIds: $0.providerLabels) }
        let labelsAdded = delta.labelsAdded.map { HistoryLabelChange(messageId: $0.providerMessageId, labelIds: $0.labelIds) }
        let labelsRemoved = delta.labelsRemoved.map { HistoryLabelChange(messageId: $0.providerMessageId, labelIds: $0.labelIds) }

        print("[Gmail] History: +\(added.count) added, -\(deleted.count) deleted, \(labelsAdded.count) label adds, \(labelsRemoved.count) label removes")

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
                print("[Gmail] fetchMessageDetails: skipping \(id) — \(error)")
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
            print("[Gmail] ERROR: synthetic folder path leaked into API path: \(path)")
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
        return label.id
    }

    /// Action tags are local-only (see ADR-IOS-036). No server write.
    func setActionTag(messageId: String, tag: ActionTag?) async throws {
        _ = messageId
        _ = tag
    }

    func modifyMessage(id: String, addLabelIds: [String] = [], removeLabelIds: [String] = []) async throws {
        var body: [String: Any] = [:]
        if !addLabelIds.isEmpty { body["addLabelIds"] = addLabelIds }
        if !removeLabelIds.isEmpty { body["removeLabelIds"] = removeLabelIds }
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let _ = try await request(path: "/messages/\(id)/modify", method: "POST", body: jsonData)
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
            print("[Gmail] Missing/invalid internalDate for message \(msg.id) — treating as fetch failure, will retry")
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
            userLabelIds: extractUserLabelIds(from: metadata.providerLabels)
        )
    }

    /// Extract user label IDs from a Gmail message's labelIds, filtering out:
    /// - Legacy `tm_*` labels (IDs observed in `fetchFolders`, see `legacyTmLabelIds`).
    ///   Without this filter, messages still tagged server-side from pre-ADR-IOS-036
    ///   installs would round-trip the ID into `MessageUserLabel` junction rows until
    ///   `move()`'s inbox-exit cleanup strips them.
    /// - Gmail system labels (INBOX, SENT, STARRED, CATEGORY_*, Label_N, etc.)
    /// Returns only user-created label IDs suitable for UserLabel/MessageUserLabel storage.
    private func extractUserLabelIds(from labelIds: [String]?) -> [String] {
        let ids = labelIds ?? []
        return ids.filter { labelId in
            !legacyTmLabelIds.contains(labelId) && !UserLabelStore.isGmailSystemLabel(id: labelId)
        }
    }

    /// Look up a Gmail label ID by display name. Returns nil if not found.
    /// Used when createLabel returns 409 Conflict (label already exists on server).
    func findLabelIdByName(_ name: String) async throws -> String? {
        let data = try await request(path: "/labels")
        let response = try JSONDecoder().decode(GmailLabelsResponse.self, from: data)
        return response.labels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
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
                        print("[Gmail] Failed to parse \(part.filename ?? "?.eml") as RFC 822 — rendering as plain attachment")
                    }
                } catch {
                    print("[Gmail] Failed to fetch bytes for \(part.filename ?? "?"): \(error)")
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
                    print("[Gmail] Failed to list nested attachments in \(part.filename ?? "?.eml"): \(error)")
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
                print("[Gmail] Failed to fetch inline image \(item.contentId): \(error)")
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
