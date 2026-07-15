/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Microsoft Graph API-based provider for Exchange/Outlook accounts.
/// Mirrors `GmailProvider` actor pattern — same `accessToken` closure, same retry logic.
/// Uses Microsoft Graph Mail REST API for all operations.
actor ExchangeProvider: EmailProvider {
    nonisolated let messageFieldScope: MessageFieldScope = .account

    private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let userEmail: String
    private let baseURL = "https://graph.microsoft.com/v1.0/me"

    /// Well-known folder IDs resolved during fetchFolders (used for archive/delete).
    private var archiveFolderId: String?
    private var deletedItemsFolderId: String?
    private var inboxFolderId: String?

    /// Test-only session override. Production call sites omit; tests register
    /// `FakeHTTP` URLProtocol on this session to intercept Graph API calls.
    private let testSession: URLSession?

    init(
        userEmail: String,
        accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
        session: URLSession? = nil
    ) {
        self.userEmail = userEmail
        self.accessToken = accessToken
        self.testSession = session
    }

    func connect() async throws {
        // Validate token by fetching profile
        let _ = try await request(path: "")
    }

    func disconnect() async throws {
        // No persistent connection — each request uses an ephemeral session.
    }

    // MARK: - Folders

    func fetchFolders() async throws -> [FolderInfo] {
        // v1.0 mailFolder resource does NOT include wellKnownName property.
        // Resolve well-known folder IDs by addressing them by name (e.g., GET /mailFolders/inbox).
        let knownFolderSpecs: [(name: String, role: FolderRole)] = [
            ("inbox", .inbox),
            ("sentitems", .sent),
            ("drafts", .drafts),
            ("deleteditems", .trash),
            ("junkemail", .spam),
            ("archive", .archive),
        ]
        var knownFolderIds: [String: FolderRole] = [:]
        for (name, role) in knownFolderSpecs {
            do {
                let d = try await request(path: "/mailFolders/\(name)?$select=id,displayName")
                let f = try JSONDecoder().decode(GraphFolder.self, from: d)
                knownFolderIds[f.id] = role
                // Cache well-known folder IDs for actions
                switch name {
                case "archive": archiveFolderId = f.id
                case "deleteditems": deletedItemsFolderId = f.id
                case "inbox": inboxFolderId = f.id
                default: break
                }
            } catch {
                // Folder may not exist (e.g., some accounts lack an archive folder)
                print("[Exchange] well-known folder '\(name)' not found: \(error)")
            }
        }

        // Now list all folders and assign roles by matching IDs
        let data = try await request(path: "/mailFolders?\(selectFolderFields)&\(topParam(100))&includeHiddenFolders=true")
        let response = try JSONDecoder().decode(GraphFolderListResponse.self, from: data)

        var folders: [FolderInfo] = []

        for folder in response.value {
            let role = knownFolderIds[folder.id]
            print("[Exchange] folder: \(folder.displayName) role=\(String(describing: role)) id=\(folder.id)")

            folders.append(FolderInfo(
                name: folder.displayName,
                path: folder.id,
                role: role ?? .custom,
                unreadCount: folder.unreadItemCount ?? 0,
                totalCount: folder.totalItemCount ?? 0
            ))

            // Also fetch child folders
            if (folder.childFolderCount ?? 0) > 0 {
                let childFolders = try await fetchChildFolders(parentId: folder.id, knownFolderIds: knownFolderIds)
                folders.append(contentsOf: childFolders)
            }
        }

        print("[Exchange] fetchFolders returning \(folders.count) folders: \(folders.map { "\($0.name)(\($0.role))" })")
        return folders
    }

    private func fetchChildFolders(parentId: String, knownFolderIds: [String: FolderRole]) async throws -> [FolderInfo] {
        let data = try await request(path: "/mailFolders/\(parentId)/childFolders?\(selectFolderFields)&\(topParam(50))")
        let response = try JSONDecoder().decode(GraphFolderListResponse.self, from: data)
        return response.value.map { folder in
            FolderInfo(
                name: folder.displayName,
                path: folder.id,
                role: knownFolderIds[folder.id] ?? .custom,
                unreadCount: folder.unreadItemCount ?? 0,
                totalCount: folder.totalItemCount ?? 0
            )
        }
    }

    // MARK: - Messages

    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] {
        let fields = selectMessageHeaderFields
        var path = "/mailFolders/\(folder)/messages?\(fields)&\(topParam(limit))&\(orderByReceived)"
        if offset > 0 {
            path += "&$skip=\(offset)"
        }
        let data = try await request(path: path)
        let response = try JSONDecoder().decode(GraphMessageListResponse.self, from: data)
        return response.value.compactMap { parseGraphMessage($0) }
    }

    func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo {
        let data = try await request(path: "/messages/\(id)?\(selectFullMessageFields)")
        let msg = try JSONDecoder().decode(GraphMessage.self, from: data)

        guard let header = parseGraphMessage(msg) else {
            throw ProviderError.messageNotFound
        }

        var htmlBody: String? = msg.body?.contentType == "html" ? msg.body?.content : nil
        let textBody: String? = msg.body?.contentType == "text" ? msg.body?.content : nil

        // Always fetch attachments — Graph API's hasAttachments does NOT include
        // inline attachments (MS docs: "This property doesn't include inline attachments").
        // The /attachments endpoint returns both inline and regular attachments regardless
        // of hasAttachments. One extra HTTP call per message is negligible vs missing
        // inline images (CID refs), ICS calendar invites, or signature images.
        var attachments: [AttachmentInfo] = []
        var inlineImages: [InlineImage] = []
        // Don't use $select here — contentId is a property of fileAttachment subtype,
        // not the base attachment type, so $select rejects it with HTTP 400.
        // Without $select, the API returns all properties including contentId.
        let attData = try await request(path: "/messages/\(id)/attachments")
        let attResponse = try JSONDecoder().decode(GraphAttachmentListResponse.self, from: attData)
        let hasCidRefs = htmlBody?.range(of: "cid:", options: .caseInsensitive) != nil
        for att in attResponse.value {
            if att.isInline == true, let rawCid = att.contentId,
               let ct = att.contentType, ct.lowercased().hasPrefix("image/") {
                let cid = rawCid.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cid.isEmpty, hasCidRefs else { continue }
                guard inlineImages.count < SyncConfig.maxInlineImages else { continue }
                do {
                    let data = try await fetchAttachment(messageId: id, attachmentId: att.id)
                    inlineImages.append(InlineImage(contentId: cid, contentType: ct, data: data))
                } catch {
                    print("[Exchange] Failed to fetch inline image \(cid): \(error)")
                }
                continue
            }

            let isItemAttachment = (att.odataType ?? "").lowercased().contains("itemattachment")
            if isItemAttachment {
                // Nested email (.eml equivalent). Expand to get its envelope, body, and
                // child attachments, then inline it as a `<div class="tm-eml-section">`
                // marker so the main message render + `EmlAttachmentPreview` both work
                // without a second round-trip.
                do {
                    let (markerHtml, nestedAttachments) = try await fetchExpandedItemAttachment(
                        messageId: id, itemAttachmentId: att.id, fallbackName: att.name
                    )
                    htmlBody = (htmlBody ?? "") + markerHtml
                    // Top-level itemAttachment chip still appears in the list
                    // (filtered by parentEmlSection == nil), same as IMAP/Gmail.
                    attachments.append(AttachmentInfo(
                        filename: att.name ?? "attached-email.eml",
                        contentType: att.contentType ?? "message/rfc822",
                        section: att.id,
                        size: att.size ?? 0,
                        encoding: nil
                    ))
                    attachments.append(contentsOf: nestedAttachments)
                } catch {
                    // Fall back to surfacing the itemAttachment as an unexpandable chip.
                    // User won't be able to preview inline, but at least sees it exists.
                    print("[Exchange] Failed to expand itemAttachment \(att.id): \(error)")
                    attachments.append(AttachmentInfo(
                        filename: att.name ?? "attached-email.eml",
                        contentType: att.contentType ?? "message/rfc822",
                        section: att.id,
                        size: att.size ?? 0,
                        encoding: nil
                    ))
                }
                continue
            }

            if let name = att.name, !name.isEmpty {
                attachments.append(AttachmentInfo(
                    filename: name,
                    contentType: att.contentType ?? "application/octet-stream",
                    section: att.id,
                    size: att.size ?? 0,
                    encoding: nil
                ))

                // File-uploaded `.eml` (non-itemAttachment): download raw bytes
                // and parse in-process. Outlook Web uploads `.eml` as
                // `#microsoft.graph.fileAttachment` with a generic content-type,
                // so itemAttachment detection above misses it. Nested attachments
                // inside the .eml are surfaced with `parentEmlSection = att.id`;
                // their bytes resolve at tap time through `fetchAttachment`
                // compound-section handling.
                if EmlParsing.isEmlFilename(name) {
                    do {
                        let raw = try await fetchAttachment(messageId: id, attachmentId: att.id)
                        if let parsed = EmlParsing.parse(rawBytes: raw) {
                            let markerHtml = EmlMarker.build(
                                filename: name,
                                partSection: att.id,
                                envelope: parsed.envelope,
                                bodyHtml: parsed.bodyHtml
                            )
                            htmlBody = (htmlBody ?? "") + markerHtml
                            for (index, meta) in parsed.nested.enumerated() {
                                attachments.append(AttachmentInfo(
                                    filename: meta.filename,
                                    contentType: meta.contentType,
                                    section: EmlParsing.nestedSection(parent: att.id, index: index),
                                    size: meta.size,
                                    encoding: nil,
                                    parentEmlSection: att.id
                                ))
                            }
                        } else {
                            print("[Exchange] Failed to parse \(name) as RFC 822 — rendering as plain attachment")
                        }
                    } catch {
                        print("[Exchange] Failed to fetch bytes for \(name): \(error)")
                    }
                }
            }
        }

        return FullMessageInfo(header: header, htmlBody: htmlBody, textBody: textBody, attachments: attachments, inlineImages: inlineImages)
    }

    /// Fetch a `#microsoft.graph.itemAttachment` with its nested `item` (envelope
    /// + body), then separately list the item's own attachments, and convert to
    /// (`<div class="tm-eml-section">` marker HTML, nested `[AttachmentInfo]`).
    ///
    /// Graph's nested `$expand` for the item's own attachments is documented as
    /// NOT reliably returning them — the only supported `$expand` is the outer
    /// `microsoft.graph.itemattachment/item`. We therefore make a second call
    /// to `.../microsoft.graph.itemattachment/item/attachments` when the nested
    /// item reports `hasAttachments == true`.
    /// Sources:
    /// - learn.microsoft.com/en-us/graph/api/attachment-get (supported $expand)
    /// - learn.microsoft.com/en-us/answers/questions/1013332/ (double-expand limit)
    ///
    /// Nested attachments' `section` is encoded as `"<outerAttId>\(Self.nestedSeparator)<innerAttId>"`
    /// so `fetchAttachment` knows to route the download via the compound path.
    /// They are tagged `parentEmlSection = outerAttId` so `AttachmentListView`
    /// hides them from the top-level list and `EmlAttachmentPreview` surfaces
    /// them inside the `.eml` sheet.
    private func fetchExpandedItemAttachment(
        messageId: String,
        itemAttachmentId: String,
        fallbackName: String?
    ) async throws -> (markerHtml: String, nestedAttachments: [AttachmentInfo]) {
        let expand = "microsoft.graph.itemattachment/item"
        let path = "/messages/\(messageId)/attachments/\(itemAttachmentId)?$expand=\(expand)"
        let data = try await request(path: path)
        let expanded = try JSONDecoder().decode(GraphItemAttachmentExpanded.self, from: data)
        let filename = expanded.name ?? fallbackName ?? "attached-email.eml"

        var envelope = EmlMarker.Envelope()
        var nestedBodyHtml = ""
        var nestedAtts: [AttachmentInfo] = []

        if let item = expanded.item {
            envelope.subject = item.subject
            envelope.from = Self.formatRecipient(item.from)
            envelope.date = item.receivedDateTime.flatMap { Date.fromISO8601($0) }
            envelope.to = (item.toRecipients ?? []).compactMap(Self.formatRecipient)
            envelope.cc = (item.ccRecipients ?? []).compactMap(Self.formatRecipient)

            if item.body?.contentType == "html", let content = item.body?.content {
                nestedBodyHtml = content
            } else if item.body?.contentType == "text", let content = item.body?.content {
                nestedBodyHtml = MessageBody.plainTextToHTML(content)
            }

            // List the nested message's attachments explicitly — the outer
            // $expand does not include them. Do nothing when hasAttachments is
            // false (common case, skips a round-trip).
            if item.hasAttachments == true {
                let childList: [GraphAttachmentMeta]
                do {
                    childList = try await listItemAttachmentChildren(
                        messageId: messageId,
                        itemAttachmentId: itemAttachmentId
                    )
                } catch {
                    // Marker still renders without children — the envelope/body
                    // is useful on its own.
                    print("[Exchange] Failed to list nested attachments for \(itemAttachmentId): \(error)")
                    childList = []
                }
                for childAtt in childList {
                    // Skip inline images — rendered inside the .eml body via CID.
                    if childAtt.isInline == true { continue }
                    guard let childName = childAtt.name, !childName.isEmpty else { continue }
                    nestedAtts.append(AttachmentInfo(
                        filename: childName,
                        contentType: childAtt.contentType ?? "application/octet-stream",
                        section: "\(itemAttachmentId)\(Self.nestedSeparator)\(childAtt.id)",
                        size: childAtt.size ?? 0,
                        encoding: nil,
                        parentEmlSection: itemAttachmentId
                    ))
                }
            }
        }

        let markerHtml = EmlMarker.build(
            filename: filename,
            partSection: itemAttachmentId,
            envelope: envelope,
            bodyHtml: nestedBodyHtml
        )
        return (markerHtml, nestedAtts)
    }

    /// List the attachments of an itemAttachment's nested `item`.
    /// URL segment `microsoft.graph.itemattachment/item/attachments` is the
    /// documented path for retrieving nested-message attachments when the
    /// item's nested-attachment `$expand` is not supported.
    /// Source: learn.microsoft.com/en-us/graph/api/attachment-list
    private func listItemAttachmentChildren(
        messageId: String,
        itemAttachmentId: String
    ) async throws -> [GraphAttachmentMeta] {
        let path = "/messages/\(messageId)/attachments/\(itemAttachmentId)/microsoft.graph.itemattachment/item/attachments"
        let data = try await request(path: path)
        let response = try JSONDecoder().decode(GraphAttachmentListResponse.self, from: data)
        return response.value
    }

    /// Separator between outer itemAttachment id and inner file attachment id in
    /// the `section` field, used only for Exchange nested-attachment downloads.
    static let nestedSeparator = "|"

    /// Format a Graph recipient as `"Name" <address>` when both fields exist, or
    /// just `address` / `name` when only one is present.
    private static func formatRecipient(_ r: GraphRecipient?) -> String? {
        guard let email = r?.emailAddress else { return nil }
        switch (email.name, email.address) {
        case let (name?, address?) where !name.isEmpty && !address.isEmpty:
            return "\"\(name)\" <\(address)>"
        case let (_, address?) where !address.isEmpty:
            return address
        case let (name?, _) where !name.isEmpty:
            return name
        default:
            return nil
        }
    }

    /// Combined header+body fetch for unified backfill. Adds `body` to existing header $select fields
    /// so one API call returns both header metadata and body content.
    /// Yields results as they complete — caller writes GRDB headers + FTS bodies while more fetches are in flight.
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

    /// Fetch a single message's header + body in one API call.
    /// Uses header fields + body in a single $select.
    private func fetchSingleBackfill(id: String) async -> BackfillResult {
        do {
            let data = try await request(path: "/messages/\(id)?\(selectBackfillFields)")
            let msg = try JSONDecoder().decode(GraphMessage.self, from: data)
            let header = parseGraphMessage(msg)
            let htmlBody = msg.body?.contentType == "html" ? msg.body?.content : nil
            let textBody = msg.body?.contentType == "text" ? msg.body?.content : nil
            return BackfillResult(id: id, header: header, htmlBody: htmlBody, textBody: textBody, error: nil)
        } catch {
            print("[Exchange] Failed to fetch backfill \(id): \(error)")
            return BackfillResult(id: id, header: nil, htmlBody: nil, textBody: nil, error: error)
        }
    }

    /// Streaming body-only fetch for FTS indexing.
    /// Yields results as they complete — caller can write FTS while more fetches are in flight.
    func fetchTextBodiesStream(ids: [String], concurrency: Int) async -> AsyncStream<TextBodyFetchResult> {
        let capturedIds = ids
        let capturedConcurrency = concurrency
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
    private func fetchSingleTextBody(id: String) async -> TextBodyFetchResult {
        do {
            let data = try await request(path: "/messages/\(id)?$select=id,body")
            let msg = try JSONDecoder().decode(GraphMessage.self, from: data)
            let htmlBody = msg.body?.contentType == "html" ? msg.body?.content : nil
            let textBody = msg.body?.contentType == "text" ? msg.body?.content : nil
            return TextBodyFetchResult(id: id, htmlBody: htmlBody, textBody: textBody, error: nil)
        } catch {
            return TextBodyFetchResult(id: id, htmlBody: nil, textBody: nil, error: error)
        }
    }

    func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] {
        var results: [TextBodyFetchResult] = []
        // Provider-owned concurrency: Exchange Graph API ~16 qps with backoff
        let concurrency = BackfillProfile.normal.gmailBodyConcurrency
        let stream = await fetchTextBodiesStream(ids: ids, concurrency: concurrency)
        for await result in stream {
            results.append(result)
        }
        return results
    }

    func search(query: String, folder: String, after: Date?, before: Date?, from: String? = nil, to: String? = nil) async throws -> [MessageHeaderInfo] {
        let queryParts = ["\(selectMessageHeaderFields)", "$search=\"\(query)\"", topParam(20)]

        // Scope to folder via Graph API mailFolders endpoint when folder ID is available
        let basePath = folder.isEmpty ? "/messages" : "/mailFolders/\(folder)/messages"
        let data = try await request(path: "\(basePath)?\(queryParts.joined(separator: "&"))")
        let response = try JSONDecoder().decode(GraphMessageListResponse.self, from: data)
        var results = response.value.compactMap { parseGraphMessage($0) }

        // Client-side date filtering since Graph $search doesn't support $filter
        if let after {
            results = results.filter { $0.date >= after }
        }
        if let before {
            results = results.filter { $0.date <= before }
        }

        return results
    }

    // MARK: - Actions

    func markRead(ids: [String], folder: String) async throws {
        let resolvedIds = try await resolveActionMessageIds(ids, folder: folder)
        for id in resolvedIds {
            try await patchMessage(id: id, body: ["isRead": true])
        }
    }

    func markUnread(ids: [String], folder: String) async throws {
        let resolvedIds = try await resolveActionMessageIds(ids, folder: folder)
        for id in resolvedIds {
            try await patchMessage(id: id, body: ["isRead": false])
        }
    }

    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {
        let flagBody: [String: Any] = ["flag": ["flagStatus": flagged ? "flagged" : "notFlagged"]]
        let resolvedIds = try await resolveActionMessageIds(ids, folder: folder)
        for id in resolvedIds {
            try await patchMessage(id: id, body: flagBody)
        }
    }

    func move(ids: [String], from source: String, to destination: String) async throws {
        let resolvedIds = try await resolveActionMessageIds(ids, folder: source)
        for id in resolvedIds {
            if DebugModeManager.isLoggingEnabled() {
                print("[MoveTrace] ExchangeProvider.move — rfcIds=\(ids) resolvedId=\(id) to=\(destination)")
            }
            // Legacy-label decay (ADR-IOS-036): on inbox-exit, strip residual
            // tm_* Graph categories so pre-ADR pollution fades naturally as
            // the user triages. Best-effort — a strip failure must NOT
            // block the move.
            if source == inboxFolderId {
                do {
                    try await stripLegacyCategories(id: id)
                } catch {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[Exchange] Legacy tm_* strip failed for \(id) (continuing): \(error)")
                    }
                }
            }
            try await moveMessage(id: id, destinationId: destination)
        }
    }

    /// Resolve the entire durable RFC batch before the first provider mutation.
    /// Transient Graph IDs are ordered-deduplicated and never escape this adapter.
    private func resolveActionMessageIds(_ ids: [String], folder: String) async throws -> [String] {
        var resolved: [String] = []
        var seen = Set<String>()
        for id in ids {
            guard let providerId = try await resolveActionMessageId(id, folder: folder),
                  seen.insert(providerId).inserted
            else { continue }
            resolved.append(providerId)
        }
        return resolved
    }

    /// Upgrade one released durable row that still carries a transient Graph
    /// resource id. The exact resource lookup is finite: a gone resource or one
    /// outside both recorded folders is authoritative stale state, while malformed
    /// metadata and every non-gone request failure remain retryable uncertainty.
    func resolveLegacyMessageActionIdentity(
        providerMessageId: String,
        sourceFolder: String,
        destinationFolder: String?
    ) async throws -> LegacyMessageActionIdentityResolution {
        let trimmedProviderId = providerMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceFolder = sourceFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidFolderCharacters = CharacterSet.controlCharacters
        let destinationIsValid = destinationFolder.map {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && trimmed == $0
                && $0.rangeOfCharacter(from: invalidFolderCharacters) == nil
        } ?? true
        guard !trimmedProviderId.isEmpty,
              trimmedProviderId == providerMessageId,
              providerMessageId.rangeOfCharacter(
                  from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
              ) == nil,
              !trimmedSourceFolder.isEmpty,
              trimmedSourceFolder == sourceFolder,
              sourceFolder.rangeOfCharacter(from: invalidFolderCharacters) == nil,
              destinationIsValid
        else {
            throw ProviderError.actionIdentityResolutionFailed(providerMessageId)
        }
        var scopedFolders = Set([sourceFolder])
        if let destinationFolder {
            scopedFolders.insert(destinationFolder)
        }

        let unreserved = Self.graphPathSegmentAllowed
        let encodedProviderId = try Self.encodedGraphPathSegment(
            providerMessageId,
            context: "Graph legacy action identity"
        )
        let queryItems = [(name: "$select", value: "id,parentFolderId,internetMessageId")]
        var encodedQueryItems: [URLQueryItem] = []
        for item in queryItems {
            guard let name = item.name.addingPercentEncoding(withAllowedCharacters: unreserved),
                  let value = item.value.addingPercentEncoding(withAllowedCharacters: unreserved)
            else {
                throw ProviderError.invalidURL("Graph legacy action identity")
            }
            encodedQueryItems.append(URLQueryItem(name: name, value: value))
        }
        var components = URLComponents()
        components.percentEncodedPath = "/messages/\(encodedProviderId)"
        components.percentEncodedQueryItems = encodedQueryItems
        guard let path = components.string else {
            throw ProviderError.invalidURL("Graph legacy action identity")
        }

        let metadata: Data
        do {
            metadata = try await request(path: path)
        } catch let error where isGraphNotFound(error) {
            return .staleOrAmbiguous
        }

        let message = try JSONDecoder().decode(GraphMessage.self, from: metadata)
        let trimmedParentFolderId = message.parentFolderId?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard message.id == providerMessageId,
              let parentFolderId = message.parentFolderId,
              let trimmedParentFolderId,
              !trimmedParentFolderId.isEmpty,
              trimmedParentFolderId == parentFolderId,
              parentFolderId.rangeOfCharacter(from: invalidFolderCharacters) == nil,
              let rfc822MessageId = MessageIdentity.durableActionRFC822MessageId(
                  message.internetMessageId
              )
        else {
            throw ProviderError.actionIdentityResolutionFailed(providerMessageId)
        }
        guard scopedFolders.contains(parentFolderId) else {
            return .staleOrAmbiguous
        }
        return .resolved(rfc822MessageId: rfc822MessageId)
    }

    /// Graph's default message resource ID changes on move. Durable actions use
    /// RFC Message-ID and resolve exactly one current resource inside the recorded
    /// source folder; zero/multiple are terminal no-ops and incomplete lookups throw.
    private func resolveActionMessageId(_ rawRFC822MessageId: String, folder: String) async throws -> String? {
        guard let rfc822MessageId = MessageIdentity.durableActionRFC822MessageId(
            rawRFC822MessageId
        ) else { return nil }
        guard !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let wireId = "<\(rfc822MessageId)>"
        let escapedWireId = wireId.replacingOccurrences(of: "'", with: "''")
        let allowed = Self.graphPathSegmentAllowed
        let encodedFolder = try Self.encodedGraphPathSegment(
            folder,
            context: "Graph action source folder"
        )
        let queryItems = [
            (name: "$select", value: "id,parentFolderId,internetMessageId"),
            (name: "$filter", value: "internetMessageId eq '\(escapedWireId)'"),
            (name: "$top", value: "2"),
        ]
        var encodedQueryItems: [URLQueryItem] = []
        for item in queryItems {
            guard let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed),
                  let value = item.value.addingPercentEncoding(withAllowedCharacters: allowed)
            else {
                throw ProviderError.invalidURL("Graph action lookup")
            }
            encodedQueryItems.append(URLQueryItem(name: name, value: value))
        }
        var components = URLComponents()
        components.percentEncodedPath = "/mailFolders/\(encodedFolder)/messages"
        components.percentEncodedQueryItems = encodedQueryItems
        guard let firstPath = components.string else {
            throw ProviderError.invalidURL("Graph action lookup")
        }

        var nextLink: String?
        var firstPage = true
        var seenLinks = Set<String>()
        var matches: [String] = []
        repeat {
            let data: Data
            if firstPage {
                do {
                    data = try await request(path: firstPath)
                } catch let error where isGraphNotFound(error) {
                    // A folder-scoped collection 404/410 proves the recorded source
                    // folder is gone; that is authoritative stale state.
                    return nil
                }
                firstPage = false
            } else {
                guard let link = nextLink,
                      seenLinks.insert(link).inserted,
                      let linkComponents = URLComponents(string: link),
                      linkComponents.scheme == "https",
                      linkComponents.host?.lowercased() == "graph.microsoft.com",
                      linkComponents.user == nil,
                      linkComponents.password == nil,
                      linkComponents.port == nil || linkComponents.port == 443
                else {
                    throw ProviderError.invalidURL("Graph action pagination")
                }
                data = try await requestAbsolute(url: link)
            }

            let response = try JSONDecoder().decode(GraphMessageListResponse.self, from: data)
            for message in response.value {
                let trimmedId = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedId.isEmpty,
                      trimmedId == message.id,
                      let returnedRFC822MessageId = MessageIdentity.durableActionRFC822MessageId(
                          message.internetMessageId
                      ),
                      returnedRFC822MessageId == rfc822MessageId,
                      message.parentFolderId == folder
                else {
                    throw ProviderError.actionIdentityResolutionFailed(rfc822MessageId)
                }
                matches.append(message.id)
            }
            if matches.count > 1 { return nil }
            nextLink = response.odataNextLink
            if let nextLink, nextLink.isEmpty {
                throw ProviderError.invalidURL("Graph action pagination")
            }
        } while nextLink != nil

        return matches.first
    }

    /// Remove any residual `tm_*` categories from a message. PATCH replaces
    /// the categories array in Graph, so we read-filter-write to preserve
    /// user-created categories. Skips the PATCH if no tm_* entries exist.
    private func stripLegacyCategories(id: String) async throws {
        let encodedId = try Self.encodedGraphPathSegment(id, context: "Graph message id")
        let data = try await request(path: "/messages/\(encodedId)?$select=categories")
        let msg = try JSONDecoder().decode(GraphMessage.self, from: data)
        let existing = msg.categories ?? []
        let filtered = existing.filter { !$0.lowercased().hasPrefix("tm_") }
        guard filtered.count != existing.count else { return }
        try await patchMessage(id: id, body: ["categories": filtered])
    }

    // MARK: - Sending

    func send(draft: DraftMessage) async throws {
        let message = buildGraphSendPayload(draft: draft)
        let jsonData = try JSONSerialization.data(withJSONObject: ["message": message])
        let _ = try await request(path: "/sendMail", method: "POST", body: jsonData)
    }

    /// Exchange/Graph API auto-saves sent messages to Sent Items — no explicit append needed.
    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool {
        return true
    }

    // MARK: - Drafts

    func saveDraft(_ draft: DraftMessage, existingDraftId: String?, draftsFolderPath: String) async throws -> DraftSaveResult {
        let message = buildGraphSendPayload(draft: draft)

        if let existingId = existingDraftId {
            // Update existing draft via PATCH
            let jsonData = try JSONSerialization.data(withJSONObject: message)
            do {
                let response = try await request(path: "/messages/\(existingId)", method: "PATCH", body: jsonData)
                if let dict = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                   let msgId = dict["id"] as? String {
                    return DraftSaveResult(serverId: msgId)
                }
                return DraftSaveResult(serverId: existingId)
            } catch let error where isGraphNotFound(error) {
                // The server-side draft is authoritatively gone (404/410) —
                // deleted directly, or auto-deleted after the underlying
                // message was sent. The user's intention is "save this
                // draft"; never drop it and never wedge the queue retrying an
                // update that can never succeed. Fall through to CREATE.
                print("[Exchange] saveDraft UPDATE: draft \(existingId) confirmed gone (404/410) — creating a new draft instead")
            }
        }
        // Create new draft in Drafts folder — reached both when there is no
        // existing draft and when the recorded existing draft was confirmed
        // gone above.
        let jsonData = try JSONSerialization.data(withJSONObject: message)
        let response = try await request(path: "/mailFolders/drafts/messages", method: "POST", body: jsonData)
        guard let dict = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let msgId = dict["id"] as? String else {
            throw NSError(domain: "ExchangeProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "No message ID in draft response"])
        }
        return DraftSaveResult(serverId: msgId)
    }

    func deleteDraft(draftId: String, draftsFolderPath: String) async throws {
        // Exchange may auto-delete drafts after send. A 404 means already gone — treat as success.
        let token = try await accessToken(false)
        let result = try await performHTTPRequestWithRetry(
            url: baseURL + "/messages/\(draftId)", method: "DELETE", body: nil, token: token,
            retryableStatusCodes: [429], logLabel: "Exchange"
        )
        if result.statusCode == 404 {
            print("[Exchange] deleteDraft: draft \(draftId) already deleted (404) — treating as success")
            return
        }
        if result.data != nil { return }
        if result.statusCode == 401 {
            let freshToken = try await accessToken(true)
            let retry = try await performHTTPRequest(url: baseURL + "/messages/\(draftId)", method: "DELETE", body: nil, token: freshToken)
            if retry.statusCode == 404 || retry.data != nil { return }
            throw ProviderError.networkError(underlying: NSError(domain: "Exchange", code: retry.statusCode))
        }
        throw ProviderError.networkError(underlying: NSError(domain: "Exchange", code: result.statusCode))
    }

    // MARK: - Action Tags (Categories)

    /// Action tags are local-only (see ADR-IOS-036). No Graph category write.
    func setActionTag(messageId: String, tag: ActionTag?) async throws {
        _ = messageId
        _ = tag
    }

    // MARK: - Attachments

    /// Fetch a single attachment's raw data.
    ///
    /// Handles two ID forms:
    /// - Plain `<attId>` → top-level attachment at `/messages/{msgId}/attachments/{attId}`.
    /// - Compound `<outerItemAttId>|<innerAttId>` → file attachment nested inside
    ///   an `itemAttachment`. Graph requires a cast in the URL segment:
    ///   `/messages/{msgId}/attachments/{outerItemAttId}/microsoft.graph.itemattachment/item/attachments/{innerAttId}`.
    ///   Source: learn.microsoft.com/en-us/graph/api/attachment-get.
    func fetchAttachment(messageId: String, attachmentId: String) async throws -> Data {
        // Nested attachment inside a file-uploaded `.eml`: re-fetch parent
        // `.eml` bytes and resolve via EmlParsing. Checked BEFORE the
        // `|` itemAttachment split because `|eml-nested|` contains `|`.
        if let nested = EmlParsing.parseNestedSection(attachmentId) {
            let parentBytes = try await fetchAttachment(messageId: messageId, attachmentId: nested.parent)
            guard let bytes = EmlParsing.nestedBytes(rawBytes: parentBytes, index: nested.index) else {
                throw ProviderError.messageNotFound
            }
            return bytes
        }

        let path: String
        if let sepRange = attachmentId.range(of: Self.nestedSeparator) {
            let outer = String(attachmentId[..<sepRange.lowerBound])
            let inner = String(attachmentId[sepRange.upperBound...])
            path = "/messages/\(messageId)/attachments/\(outer)/microsoft.graph.itemattachment/item/attachments/\(inner)"
        } else {
            path = "/messages/\(messageId)/attachments/\(attachmentId)"
        }
        let data = try await request(path: path)
        let attachment = try JSONDecoder().decode(GraphAttachmentDetail.self, from: data)
        guard let base64Content = attachment.contentBytes,
              let decoded = Data(base64Encoded: base64Content) else {
            throw ProviderError.messageNotFound
        }
        return decoded
    }

    // MARK: - Backfill

    /// LIST phase: fetch message IDs in a date range for backfill.
    func listBackfillMessageIds(
        folder: String,
        since: Date,
        before: Date? = nil,
        pageSize: Int = 500,
        interPageDelay: TimeInterval = 0.3,
        maxIds: Int = SyncConfig.gmailBackfillIdCap
    ) async throws -> [String] {
        var filter = "receivedDateTime ge \(iso8601DateTime(since))"
        if let before { filter += " and receivedDateTime lt \(iso8601DateTime(before))" }
        var allIds: [String] = []
        var nextLink: String? = "/mailFolders/\(folder)/messages?$select=id&$filter=\(filter)&\(topParam(pageSize))&\(orderByReceived)"

        repeat {
            try Task.checkCancellation()

            let data: Data
            if let link = nextLink, link.hasPrefix("http") {
                // Absolute URL from @odata.nextLink
                data = try await requestAbsolute(url: link)
            } else {
                data = try await request(path: nextLink!)
            }

            let response = try JSONDecoder().decode(GraphMessageIdListResponse.self, from: data)
            allIds.append(contentsOf: response.value.map(\.id))

            if allIds.count >= maxIds {
                print("[Exchange] WARNING: listBackfillMessageIds hit \(maxIds) ID cap — stopping pagination.")
                break
            }

            nextLink = response.odataNextLink
            if nextLink != nil {
                try await Task.sleep(for: .seconds(interPageDelay))
            }
        } while nextLink != nil

        return allIds
    }

    /// FETCH phase: fetch message headers for specific IDs.
    func fetchMessageHeaders(ids: [String], batchSize: Int = 50, interBatchDelay: TimeInterval = 0.5) async throws -> [MessageHeaderInfo] {
        var allHeaders: [MessageHeaderInfo] = []
        for (i, id) in ids.enumerated() {
            try Task.checkCancellation()
            do {
                let data = try await request(path: "/messages/\(id)?\(selectMessageHeaderFields)")
                let msg = try JSONDecoder().decode(GraphMessage.self, from: data)
                if let header = parseGraphMessage(msg) {
                    allHeaders.append(header)
                }
            } catch {
                // Message may have been deleted between list and fetch — skip
                print("[Exchange] fetchMessageHeaders: skipping \(id) — \(error)")
            }
            if (i + 1) % batchSize == 0, i + 1 < ids.count {
                try await Task.sleep(for: .seconds(interBatchDelay))
            }
        }
        return allHeaders
    }

    /// Single-page listing for cursor-based backfill. Returns one page of message IDs
    /// plus the nextLink for resuming. First call builds OData query with $orderby=receivedDateTime desc.
    /// Subsequent calls use pageToken as the @odata.nextLink URL.
    func listMessageIdsPage(
        folder: String,
        pageToken: String? = nil,
        pageSize: Int = 500
    ) async throws -> (ids: [String], nextPageToken: String?) {
        try Task.checkCancellation()

        let data: Data
        if let token = pageToken, token.hasPrefix("http") {
            // Subsequent call: use absolute @odata.nextLink URL
            data = try await requestAbsolute(url: token)
        } else {
            // First call: build OData query
            let path = "/mailFolders/\(folder)/messages?$select=id&\(topParam(pageSize))&\(orderByReceived)"
            data = try await request(path: path)
        }

        let response = try JSONDecoder().decode(GraphMessageIdListResponse.self, from: data)
        let ids = response.value.map(\.id)
        return (ids: ids, nextPageToken: response.odataNextLink)
    }

    /// Fetch older messages before a given date for infinite scroll.
    func fetchOlderMessages(folder: String, before: Date, limit: Int) async throws -> [MessageHeaderInfo] {
        let filter = "receivedDateTime lt \(iso8601DateTime(before))"
        let path = "/mailFolders/\(folder)/messages?\(selectMessageHeaderFields)&$filter=\(filter)&\(topParam(limit))&\(orderByReceived)"
        let data = try await request(path: path)
        let response = try JSONDecoder().decode(GraphMessageListResponse.self, from: data)
        return response.value.compactMap { parseGraphMessage($0) }
    }

    // MARK: - Incremental Sync (Delta)

    func fetchHistory(since historyId: String) async throws -> HistoryResponse? {
        // historyId is the deltaLink URL for Exchange
        guard !historyId.isEmpty else {
            BackgroundSyncLogger.log("exchange.fetchHistory: empty deltaToken")
            return nil
        }

        BackgroundSyncLogger.log("exchange.fetchHistory: START email=\(userEmail)")
        var added: [HistoryMessageRef] = []
        var deleted: [HistoryMessageRef] = []
        var nextLink: String? = historyId
        var finalDeltaLink: String?

        // Paginate through all delta pages
        while let link = nextLink {
            let data: Data
            do {
                data = try await requestAbsolute(url: link)
            } catch {
                if link == historyId {
                    // First request failed — delta link expired
                    print("[Exchange] Delta link expired — need full sync")
                    BackgroundSyncLogger.log("exchange.fetchHistory: delta link expired (first request failed: \(error.localizedDescription))")
                    return nil
                }
                BackgroundSyncLogger.log("exchange.fetchHistory: page request failed: \(error.localizedDescription)")
                throw error
            }

            let response = try JSONDecoder().decode(GraphDeltaResponse.self, from: data)

            for msg in response.value {
                if msg.removed != nil {
                    deleted.append(HistoryMessageRef(messageId: msg.id, labelIds: []))
                } else {
                    added.append(HistoryMessageRef(messageId: msg.id, labelIds: []))
                }
            }

            if let deltaLink = response.odataDeltaLink {
                finalDeltaLink = deltaLink
                nextLink = nil // Done — got final delta link
            } else {
                nextLink = response.odataNextLink // More pages
            }
        }

        let newDeltaLink = finalDeltaLink ?? historyId

        BackgroundSyncLogger.log("exchange.fetchHistory: done +\(added.count) -\(deleted.count) newToken=\(finalDeltaLink != nil)")
        print("[Exchange] Delta: +\(added.count) added/changed, -\(deleted.count) deleted")

        return HistoryResponse(
            newHistoryId: newDeltaLink,
            messagesAdded: added,
            messagesDeleted: deleted,
            labelsAdded: [],
            labelsRemoved: []
        )
    }

    /// Protocol-required: fetch message headers by ID (non-batched version for delta sync).
    func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] {
        try await fetchMessageHeaders(ids: ids, batchSize: 50, interBatchDelay: 0.5)
    }

    /// Fetch message details including parent folder for delta sync folder assignment.
    func fetchMessageDetails(ids: [String]) async throws -> [ExchangeMessageDetail] {
        var results: [ExchangeMessageDetail] = []
        for id in ids {
            do {
                let data = try await request(path: "/messages/\(id)?\(selectMessageDetailFields)")
                let msg = try JSONDecoder().decode(GraphMessage.self, from: data)
                if let header = parseGraphMessage(msg) {
                    results.append(ExchangeMessageDetail(header: header, parentFolderId: msg.parentFolderId ?? ""))
                }
            } catch {
                // Message may have been deleted between delta list and detail fetch — skip
                print("[Exchange] fetchMessageDetails: skipping \(id) — \(error)")
            }
        }
        return results
    }

    /// Get the current delta link for a folder (used to initialize the incremental sync cursor).
    func getCurrentDeltaLink(folderId: String) async throws -> String? {
        // Request delta with no changes to get the current delta link
        var nextLink: String? = "/mailFolders/\(folderId)/messages/delta?$select=id&\(topParam(1))"
        var deltaLink: String?

        // Walk through all pages to get the final deltaLink
        while let link = nextLink {
            let data: Data
            if link.hasPrefix("http") {
                data = try await requestAbsolute(url: link)
            } else {
                data = try await request(path: link)
            }
            let response = try JSONDecoder().decode(GraphDeltaResponse.self, from: data)
            deltaLink = response.odataDeltaLink
            nextLink = response.odataNextLink
        }

        return deltaLink
    }

    // MARK: - HTTP

    /// Lazily-built `AuthedHTTP` for Exchange/Graph. Shared 401-retry via
    /// `AccountAuthSource`; rate-limit policy `.graph` = 429 only.
    private var authedHTTPCached: AuthedHTTP?
    private var authedHTTP: AuthedHTTP {
        if let cached = authedHTTPCached { return cached }
        let built = AuthedHTTP(
            auth: AccountAuthSource(accountId: userEmail, accessToken: accessToken),
            retry: .graph, logLabel: "Exchange", session: testSession
        )
        authedHTTPCached = built
        return built
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let url = baseURL + path
        do {
            switch method {
            case "GET": return try await authedHTTP.get(url)
            case "POST": return try await authedHTTP.post(url, body: body ?? Data())
            case "PATCH": return try await authedHTTP.patch(url, body: body ?? Data())
            case "DELETE": return try await authedHTTP.delete(url)
            default: return try await authedHTTP.get(url)
            }
        } catch let e as HTTPError {
            throw ProviderError.networkError(underlying: e)
        }
    }

    /// Used by delta pagination — the next/delta links are absolute URLs.
    private func requestAbsolute(url: String) async throws -> Data {
        do {
            return try await authedHTTP.get(url)
        } catch let e as HTTPError {
            throw ProviderError.networkError(underlying: e)
        }
    }

    /// Same as `request(...)` but preserves the raw body of a `400` failure
    /// instead of throwing the bodyless `.networkError`, so it can be parsed
    /// for Graph's structured error shape (see `isGraphInvalidIdMalformed`)
    /// rather than guessed from the status code alone. Every other failure
    /// status still throws the ordinary `.networkError` — same as `request(...)`.
    private func requestPreservingBadRequestBody(path: String, method: String, body: Data?) async throws -> Data {
        let url = baseURL + path
        do {
            return try await authedHTTP.requestPreservingBadRequestBody(url: url, method: method, body: body ?? Data())
        } catch let e as HTTPError {
            throw ProviderError.networkError(underlying: e)
        }
    }

    /// Graph's structured JSON error body shape:
    /// `{"error":{"code":"ErrorInvalidIdMalformed","message":"Id is malformed."}}`.
    /// https://learn.microsoft.com/en-us/graph/errors
    private struct GraphAPIErrorBody: Decodable {
        struct ErrorObject: Decodable {
            let code: String?
            let message: String?
        }
        let error: ErrorObject
    }

    /// True only when Graph's structured `400` error body proves the id could
    /// never be valid — `code == "ErrorInvalidIdMalformed"`. This is distinct
    /// from "not found" (already 404/410 via `isGraphNotFound`): a malformed
    /// id can never succeed on retry, so Law 4 treats it as an authoritative
    /// stale no-op. Any other `400` shape is uncertainty and must keep
    /// throwing.
    private func isGraphInvalidIdMalformed(_ error: Error) -> Bool {
        guard case ProviderError.networkError(let underlying) = error,
              case HTTPError.networkErrorWithBody(let statusCode, let body) = underlying,
              statusCode == 400,
              let decoded = try? JSONDecoder().decode(GraphAPIErrorBody.self, from: body)
        else { return false }
        return decoded.error.code == "ErrorInvalidIdMalformed"
    }

    // MARK: - Helpers

    /// Graph resource IDs are opaque. Encode them as one strict RFC 3986 path
    /// segment before composing any resource URL so `/`, `?`, `#`, `+`, and `=`
    /// cannot alter the route selected by the server.
    private static let graphPathSegmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encodedGraphPathSegment(
        _ value: String,
        context: String
    ) throws -> String {
        guard let encoded = value.addingPercentEncoding(
            withAllowedCharacters: graphPathSegmentAllowed
        ) else {
            throw ProviderError.invalidURL(context)
        }
        return encoded
    }

    private func patchMessage(id: String, body: [String: Any]) async throws {
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let encodedId = try Self.encodedGraphPathSegment(id, context: "Graph message id")
        do {
            _ = try await request(path: "/messages/\(encodedId)", method: "PATCH", body: jsonData)
        } catch let error where isGraphNotFound(error) {
            return
        }
    }

    private func moveMessage(id: String, destinationId: String) async throws {
        let body = ["destinationId": destinationId]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let encodedId = try Self.encodedGraphPathSegment(id, context: "Graph message id")
        do {
            _ = try await requestPreservingBadRequestBody(
                path: "/messages/\(encodedId)/move",
                method: "POST",
                body: jsonData
            )
        } catch let error where isGraphNotFound(error) || isGraphInvalidIdMalformed(error) {
            // Authoritative stale (Law 4): either the resource is confirmed
            // gone (404/410) or the destination id could never be valid
            // (`ErrorInvalidIdMalformed` 400 — a never-valid folder id, not
            // merely "not found"). Normal return; the queue treats this as a
            // completed no-op.
            return
        }
    }

    private func isGraphNotFound(_ error: Error) -> Bool {
        guard case ProviderError.networkError(let underlying) = error else { return false }
        if case HTTPError.networkError(let statusCode) = underlying {
            return statusCode == 404 || statusCode == 410
        }
        let statusCode = (underlying as NSError).code
        return statusCode == 404 || statusCode == 410
    }


    // MARK: - Parsing

    /// Parse a Graph message into main-app `MessageHeaderInfo`.
    ///
    /// Delegates JSON → canonical `MessageMetadata` to `Shared/Parse/GraphParse`.
    /// Main-app-specific resolution (ActionTag via category map, conversationId
    /// as threadId, comma-joined recipient strings) applied at the boundary.
    internal func parseGraphMessage(_ msg: GraphMessage) -> MessageHeaderInfo? {
        // Round-trip through JSON so the shared parser is the single source of
        // truth. Cheap — we already decoded once on the way in.
        guard let encoded = try? JSONEncoder().encode(msg),
              let json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let metadata = GraphParse.parseMessage(json) else {
            print("[Exchange] Missing/invalid receivedDateTime for message \(msg.id) — treating as fetch failure, will retry")
            return nil
        }

        // Action tags are local-only (ADR-IOS-036). No resolution from
        // Graph categories — MessageAICache + Device Sync probe provide
        // cross-device state. Legacy tm_* categories on server are ignored.

        return MessageHeaderInfo(
            messageId: metadata.providerMessageId,
            rfc822MessageId: metadata.rfc822MessageId,
            inReplyTo: metadata.inReplyTo,
            references: metadata.references,
            threadId: metadata.threadId,
            subject: metadata.subject.isEmpty ? "(no subject)" : metadata.subject,
            from: metadata.from.name,
            fromAddress: metadata.from.email,
            to: metadata.to.map { $0.email }.joined(separator: ", "),
            cc: metadata.cc.map { $0.email }.joined(separator: ", "),
            bcc: metadata.bcc.map { $0.email }.joined(separator: ", "),
            replyTo: metadata.replyTo?.email,
            date: metadata.date,
            snippet: "",
            isRead: metadata.isRead,
            isFlagged: metadata.isFlagged,
            hasAttachments: metadata.hasAttachments,
            isReplied: false,
            isForwarded: false,
            actionTag: nil,
            userLabelIds: []  // Exchange category support is future work.
        )
    }

    private func iso8601DateTime(_ date: Date) -> String {
        date.iso8601String()
    }

    // MARK: - Sending Helpers

    nonisolated func buildGraphSendPayload(draft: DraftMessage) -> [String: Any] {
        var message: [String: Any] = [:]

        message["subject"] = draft.subject

        // Body
        message["body"] = [
            "contentType": draft.isHTML ? "html" : "text",
            "content": draft.body,
        ]

        // Recipients
        message["toRecipients"] = draft.to.map { email in
            ["emailAddress": ["address": email]]
        }
        if !draft.cc.isEmpty {
            message["ccRecipients"] = draft.cc.map { email in
                ["emailAddress": ["address": email]]
            }
        }
        if !draft.bcc.isEmpty {
            message["bccRecipients"] = draft.bcc.map { email in
                ["emailAddress": ["address": email]]
            }
        }

        // Threading headers (RFC 2822 requires angle brackets around message IDs)
        var customHeaders: [[String: String]] = []
        if let inReplyTo = draft.inReplyTo, !inReplyTo.isEmpty {
            let bracketed = inReplyTo.hasPrefix("<") ? inReplyTo : "<\(inReplyTo)>"
            customHeaders.append(["name": "In-Reply-To", "value": bracketed])
        }
        if !draft.references.isEmpty {
            let bracketed = draft.references.map { $0.hasPrefix("<") ? $0 : "<\($0)>" }.joined(separator: " ")
            customHeaders.append(["name": "References", "value": bracketed])
        }
        if !customHeaders.isEmpty {
            message["internetMessageHeaders"] = customHeaders
        }

        // Attachments
        if !draft.attachments.isEmpty {
            message["attachments"] = draft.attachments.map { att in
                [
                    "@odata.type": "#microsoft.graph.fileAttachment",
                    "name": att.filename,
                    "contentType": att.mimeType,
                    "contentBytes": att.data.base64EncodedString(),
                ] as [String: Any]
            }
        }

        return message
    }

    // MARK: - Query Helpers

    private var selectFolderFields: String {
        "$select=id,displayName,unreadItemCount,totalItemCount,childFolderCount"
    }

    // Compose all `$select=...` lists from `GraphAPI`'s single source of
    // truth. Keeps NSE's `GraphAPI.messageMetadata` + `messageFull` URLs and
    // main-app's inline fetches in lockstep — adding a field in GraphAPI
    // propagates to every caller. Prior art: these were hardcoded here and
    // drifted silently from the NSE-side URL; see the class of bug the
    // 2026-04-19 IMAP fix was written to prevent.

    private var selectMessageHeaderFields: String {
        "$select=\(GraphAPI.headerOnlyFields)"
    }

    /// Header fields + parentFolderId for delta sync folder assignment.
    private var selectMessageDetailFields: String {
        "$select=\(GraphAPI.metadataSelectFields)"
    }

    /// Header fields + body for unified backfill (headers AND body in one API call).
    private var selectBackfillFields: String {
        "$select=\(GraphAPI.backfillSelectFields)"
    }

    private var selectFullMessageFields: String {
        "$select=\(GraphAPI.fullSelectFields)"
    }

    private func topParam(_ n: Int) -> String { "$top=\(n)" }

    private var orderByReceived: String { "$orderby=receivedDateTime desc" }
}

/// Message header with Exchange parent folder ID — used by delta sync for folder assignment.
struct ExchangeMessageDetail: Sendable {
    let header: MessageHeaderInfo
    let parentFolderId: String
}

// MARK: - Microsoft Graph API Response Models

private struct GraphFolderListResponse: Decodable {
    let value: [GraphFolder]
}

private struct GraphFolder: Decodable {
    let id: String
    let displayName: String
    let unreadItemCount: Int?
    let totalItemCount: Int?
    let childFolderCount: Int?
}

private struct GraphMessageListResponse: Decodable {
    let value: [GraphMessage]
    let odataNextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case odataNextLink = "@odata.nextLink"
    }
}

private struct GraphMessageIdListResponse: Decodable {
    let value: [GraphMessageRef]
    let odataNextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case odataNextLink = "@odata.nextLink"
    }
}

private struct GraphMessageRef: Decodable {
    let id: String
}

// Visible to tests via @testable import. Fields match Microsoft Graph API response schema.
// Codable (not just Decodable) so ExchangeProvider.parseGraphMessage can
// re-serialize and hand off to Shared/Parse/GraphParse.parseMessage.
// One JSON round-trip per message — small, and lets the shared parser be
// the single source of truth for both main-app and any future NSE Outlook.
struct GraphMessage: Codable {
    let id: String
    let subject: String?
    let from: GraphRecipient?
    let toRecipients: [GraphRecipient]?
    let ccRecipients: [GraphRecipient]?
    let bccRecipients: [GraphRecipient]?
    let replyTo: [GraphRecipient]?
    let receivedDateTime: String?
    let isRead: Bool?
    let flag: GraphFlag?
    let hasAttachments: Bool?
    let internetMessageId: String?
    let conversationId: String?
    let categories: [String]?
    let bodyPreview: String?
    let body: GraphBody?
    let parentFolderId: String?
}

// Visible to tests via @testable import.
struct GraphRecipient: Codable {
    let emailAddress: GraphEmailAddress?
}

// Visible to tests via @testable import.
struct GraphEmailAddress: Codable {
    let name: String?
    let address: String?
}

// Visible to tests via @testable import.
struct GraphFlag: Codable {
    let flagStatus: String?
}

// Visible to tests via @testable import (referenced by GraphMessage).
struct GraphBody: Codable {
    let contentType: String?
    let content: String?
}

private struct GraphAttachmentListResponse: Decodable {
    let value: [GraphAttachmentMeta]
}

private struct GraphAttachmentMeta: Decodable {
    let id: String
    let name: String?
    let contentType: String?
    let size: Int?
    let isInline: Bool?
    let contentId: String?
    /// Discriminator for polymorphic Attachment subtypes:
    /// `#microsoft.graph.fileAttachment`, `#microsoft.graph.itemAttachment`,
    /// `#microsoft.graph.referenceAttachment`. itemAttachment represents a
    /// nested message (the `.eml` equivalent) and needs $expand to get its
    /// envelope + body + nested attachments.
    let odataType: String?

    enum CodingKeys: String, CodingKey {
        case id, name, contentType, size, isInline, contentId
        case odataType = "@odata.type"
    }
}

private struct GraphAttachmentDetail: Decodable {
    let contentBytes: String?
}

/// Response to `/messages/{id}/attachments/{attId}?$expand=microsoft.graph.itemattachment/item`.
/// Graph embeds the nested Message's envelope + body directly. The nested
/// message's own attachments are NOT populated by this call (Graph's nested
/// $expand is documented as not reliably returning them) — `attachments` here
/// is nil in practice; listing them requires a separate call to
/// `.../microsoft.graph.itemattachment/item/attachments`.
private struct GraphItemAttachmentExpanded: Decodable {
    let id: String
    let name: String?
    let contentType: String?
    let size: Int?
    let item: GraphExpandedMessageItem?
}

private struct GraphExpandedMessageItem: Decodable {
    let subject: String?
    let from: GraphRecipient?
    let toRecipients: [GraphRecipient]?
    let ccRecipients: [GraphRecipient]?
    let receivedDateTime: String?
    let body: GraphBody?
    let hasAttachments: Bool?
    let attachments: [GraphAttachmentMeta]?
}

private struct GraphDeltaResponse: Decodable {
    let value: [GraphDeltaMessage]
    let odataDeltaLink: String?
    let odataNextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case odataDeltaLink = "@odata.deltaLink"
        case odataNextLink = "@odata.nextLink"
    }
}

private struct GraphDeltaMessage: Decodable {
    let id: String
    let removed: GraphRemoved?

    enum CodingKeys: String, CodingKey {
        case id
        case removed = "@removed"
    }
}

private struct GraphRemoved: Decodable {
    let reason: String?
}
