/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Demo Mode email provider — implements `EmailProvider` against the seeded
/// GRDB rows. No network. See ADR-IOS-038.
///
/// Most reads pass through to the existing GRDB tables (the rest of the app
/// already drives off GRDB anyway). Writes update GRDB and synthesize a
/// "success" response — no IMAP/SMTP traffic. Sent messages land in the
/// seeded `SENT` folder so the user can see end-to-end behavior.
actor DemoProvider: EmailProvider {
    private let accountId: String

    init(accountId: String) {
        self.accountId = accountId
    }

    // MARK: - Connection / lifecycle

    func connect() async throws { /* no-op — local */ }
    func disconnect() async throws { /* no-op */ }
    func markDirty() async { /* no-op */ }

    // MARK: - Reads

    func fetchFolders() async throws -> [FolderInfo] {
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return [] }
        return try await db.dbPool.read { conn in
            let folders = try Folder
                .filter(Column("accountId") == self.accountId)
                .fetchAll(conn)
            return folders.map { f in
                FolderInfo(
                    name: f.name,
                    path: f.path,
                    role: f.role,
                    unreadCount: f.unreadCount,
                    totalCount: f.totalCount,
                    uidNext: nil
                )
            }
        }
    }

    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] {
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return [] }
        return try await db.dbPool.read { conn in
            let folderId = "\(self.accountId):\(folder)"
            let headers = try MessageHeader
                .filter(Column("folderId") == folderId)
                .order(Column("date").desc)
                .limit(limit, offset: offset)
                .fetchAll(conn)
            return headers.map { Self.toInfo($0) }
        }
    }

    func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo {
        guard let db = AppDatabase.shared.withLock({ $0 }) else {
            throw DemoError.notInDemo
        }
        let (header, body): (MessageHeader, MessageBody?) = try await db.dbPool.read { conn in
            let folderId = "\(self.accountId):\(folder)"
            let headerId = MessageIdentity.headerId(accountId: self.accountId, folderPath: folder, messageId: id)
            guard let h = try MessageHeader.filter(Column("id") == headerId).fetchOne(conn)
                ?? MessageHeader.filter(Column("messageId") == id && Column("folderId") == folderId).fetchOne(conn) else {
                throw DemoError.startFailed("message not found")
            }
            let b = try MessageBody.filter(Column("id") == h.id).fetchOne(conn)
            return (h, b)
        }
        return FullMessageInfo(
            header: Self.toInfo(header),
            htmlBody: body?.htmlContent,
            textBody: nil,
            attachments: [],
            inlineImages: []
        )
    }

    func search(query: String, folder: String, after: Date?, before: Date?, from: String?, to: String?) async throws -> [MessageHeaderInfo] {
        // Simple substring search over GRDB. The rest of the app uses
        // SearchIndex.shared (FTS) for real search; demo answers basic queries
        // here so direct provider.search() callers keep working.
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return [] }
        return try await db.dbPool.read { conn in
            let folderId = "\(self.accountId):\(folder)"
            var rows = try MessageHeader
                .filter(Column("folderId") == folderId)
                .order(Column("date").desc)
                .fetchAll(conn)
            if !query.isEmpty {
                let q = query.lowercased()
                rows = rows.filter {
                    $0.subject.lowercased().contains(q) ||
                    $0.from.lowercased().contains(q) ||
                    $0.snippet.lowercased().contains(q)
                }
            }
            if let after { rows = rows.filter { $0.date >= after } }
            if let before { rows = rows.filter { $0.date <= before } }
            if let from {
                let f = from.lowercased()
                rows = rows.filter { $0.fromAddress.lowercased().contains(f) }
            }
            if let to {
                let t = to.lowercased()
                rows = rows.filter { $0.to.lowercased().contains(t) }
            }
            return rows.map { Self.toInfo($0) }
        }
    }

    // MARK: - Writes (mutate GRDB, return success)

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
            case .userLabel:
                // Demo has no remote user-label representation.
                break
            }
            return ProviderActionOutcome(dispositionedMemberIds: source.memberIds)
        } catch let disposition as ProviderMembersDispositioned {
            return ProviderActionOutcome(disposition: disposition)
        }
    }

    func markRead(ids: [String], folder: String) async throws {
        try await flagUpdate(ids: ids, folder: folder) { $0.isRead = true }
    }
    func markUnread(ids: [String], folder: String) async throws {
        try await flagUpdate(ids: ids, folder: folder) { $0.isRead = false }
    }
    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {
        try await flagUpdate(ids: ids, folder: folder) { $0.isFlagged = flagged }
    }

    func move(ids: [String], from: String, to: String) async throws {
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return }
        try await db.dbPool.write { conn in
            let toFolderId = "\(self.accountId):\(to)"
            let toIsInbox = to.uppercased() == "INBOX"
            for id in ids {
                let oldHeaderId = MessageIdentity.headerId(accountId: self.accountId, folderPath: from, messageId: id)
                guard let existing = try MessageHeader.filter(Column("id") == oldHeaderId).fetchOne(conn) else { continue }
                let newHeaderId = MessageIdentity.headerId(accountId: self.accountId, folderPath: to, messageId: id)
                var migrated = existing
                migrated.id = newHeaderId
                migrated.folderId = toFolderId
                migrated.folderPath = to
                migrated.isInInbox = toIsInbox
                // 🚨 R17-1 — THE CARRIER IS SHARED, NOT HAND-ROLLED. A demo move is a
                // header PRIMARY-KEY change, so it is a member of the class *"every
                // code path that changes a header's primary key"*. This block used to
                // run its own `delete` → reassign `id` → `insert`, which fires
                // `ON DELETE CASCADE` on both surviving children of `messageHeader`
                // (`messageUserLabel`, `messageReference`) and restored neither, and
                // since `v70_dropMessageBodyHeaderFK` left the `messageBody` row
                // ORPHANED under the old id rather than cascaded away.
                //
                // Demo mode has no server, so nothing re-fetches any of it: the loss
                // is permanent for the life of the demo account, which is why the
                // shared carrier matters here even though the data is synthetic.
                // `apply` carries the body and the labels and rebuilds the references.
                //
                // Its `false` return (the new id is already occupied) leaves the old
                // row deleted and inserts nothing. That is a strict improvement on the
                // previous behaviour, which threw a UNIQUE violation and rolled the
                // whole demo move back.
                try MessageHeaderRekey.apply(from: existing, to: migrated, db: conn)
            }
        }
    }

    func send(draft: DraftMessage) async throws {
        // No network — synthesize a sent message in the seeded SENT folder.
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return }
        try await db.dbPool.write { conn in
            let folderId = "\(self.accountId):SENT"
            let messageId = draft.messageId ?? "demo-sent-\(UUID().uuidString.prefix(8))"
            var header = MessageHeader(
                messageId: messageId,
                subject: draft.subject,
                from: DemoSeed.demoDisplayName,
                fromAddress: DemoSeed.demoEmail,
                to: draft.to.joined(separator: ", "),
                date: Date(),
                snippet: String(Self.stripHTML(draft.body).prefix(160)),
                folderId: folderId,
                accountId: self.accountId,
                folderPath: "SENT",
                isInInbox: false
            )
            header.rfc822MessageId = messageId
            header.isRead = true
            header.headerComplete = true
            header.bodyComplete = true
            try header.insert(conn)
            try MessageBody(contentKey: ContentKey(rawValue: header.id),
                            htmlContent: draft.isHTML ? draft.body : "<pre>\(draft.body)</pre>").insert(conn)
        }
    }

    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool {
        // Already covered by send(); APPEND is a no-op for the demo.
        true
    }

    func saveDraft(
        _ draft: DraftMessage,
        existingIdentity: DraftDeleteIdentity?,
        draftsFolderPath: String
    ) async throws -> DraftSaveOutcome {
        let existingDraftId: String?
        switch existingIdentity {
        case .demo(let localId): existingDraftId = localId
        case nil: existingDraftId = nil
        default:
            throw ProviderError.actionIdentityResolutionFailed(
                "DemoProvider received a non-Demo prior draft identity")
        }
        guard let db = AppDatabase.shared.withLock({ $0 }) else {
            throw DemoError.notInDemo
        }
        let serverId = existingDraftId ?? "demo-draft-\(UUID().uuidString.prefix(8))"
        try await db.dbPool.write { conn in
            let folderId = "\(self.accountId):\(draftsFolderPath)"
            let headerId = MessageIdentity.headerId(accountId: self.accountId, folderPath: draftsFolderPath, messageId: serverId)
            // 🚨 R17b-B1 — RE-MATERIALISE IN PLACE, NEVER DELETE + RE-INSERT.
            //
            // Re-saving a demo draft addresses the SAME primary key: `serverId` is
            // the prior `.demo(localId:)` identity, and the account, folder path and
            // message id that mint `headerId` are all unchanged. So there is no
            // re-key here and nothing to carry — but the old shape still ran
            // `existing.delete(conn)` first, and a `messageHeader` delete fires
            // `ON DELETE CASCADE` on BOTH of that table's surviving children
            // whether or not the key moves:
            //   * `messageUserLabel` (`AppDatabase` `v82`, cascade on `messageId`) —
            //     every label the user applied, with NO rebuild source anywhere in
            //     the database, and demo mode has no server to re-fetch it from;
            //   * `messageReference` (`AppDatabase` `v27`, cascade on
            //     `messageHeaderId`) — the draft's threading edges. A REPLY draft
            //     carries `In-Reply-To`, so the edge to the message being replied to
            //     was destroyed on every autosave.
            // The re-insert restored neither. `MessageHeaderRekey.apply` is the
            // carrier for the case where the key genuinely MOVES; here the smaller
            // and strictly safer answer is not to delete at all, which is the shape
            // `AccountManagerActions`' real (non-demo) draft-placeholder write
            // already uses — fetch-or-create, assign the fields the save changes,
            // then `save`.
            //
            // ⚠️ AND THE DELETE HAD A SECOND CONSEQUENCE THAT ONLY APPEARED AFTER
            // `v70_dropMessageBodyHeaderFK`: `messageBody` is no longer cascaded, so
            // the old body row SURVIVED the header delete and the unconditional
            // `MessageBody(…).insert(conn)` below it hit `UNIQUE constraint failed:
            // messageBody.id` on the second save of any demo draft — the whole write
            // rolled back and the save reported failure. `save` is an upsert, so the
            // body is replaced rather than re-inserted.
            var header = try MessageHeader.fetchOne(conn, key: headerId)
                ?? MessageHeader(
                    messageId: serverId,
                    subject: draft.subject,
                    from: DemoSeed.demoDisplayName,
                    fromAddress: DemoSeed.demoEmail,
                    to: draft.to.joined(separator: ", "),
                    date: Date(),
                    snippet: String(Self.stripHTML(draft.body).prefix(160)),
                    folderId: folderId,
                    accountId: self.accountId,
                    folderPath: draftsFolderPath,
                    isInInbox: false
                )
            header.subject = draft.subject
            header.to = draft.to.joined(separator: ", ")
            header.date = Date()
            header.snippet = String(Self.stripHTML(draft.body).prefix(160))
            header.rfc822MessageId = serverId
            header.headerComplete = true
            try header.save(conn)
            try MessageBody(contentKey: ContentKey(rawValue: header.id), htmlContent: draft.body).save(conn)
        }
        return .created(.demo(localId: serverId))
    }

    func deleteDraft(identity: DraftDeleteIdentity) async throws {
        guard case .demo(let draftId) = identity else {
            throw ProviderError.actionIdentityResolutionFailed("DemoProvider received a non-Demo draft identity")
        }
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return }
        try await db.dbPool.write { conn in
            guard let drafts = try Folder
                .filter(Column("accountId") == self.accountId && Column("role") == FolderRole.drafts.rawValue)
                .fetchOne(conn) else { return }
            let headerId = MessageIdentity.headerId(accountId: self.accountId, folderPath: drafts.path, messageId: draftId)
            try MessageHeader.filter(Column("id") == headerId).deleteAll(conn)
            try MessageBody.filter(Column("id") == headerId).deleteAll(conn)
        }
    }

    // MARK: - Sync stubs

    func fetchHistory(since historyId: String) async throws -> HistoryResponse? {
        // Demo doesn't simulate inbound mail; sync is a no-op.
        nil
    }

    func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] {
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return [] }
        return try await db.dbPool.read { conn in
            try MessageHeader
                .filter(Column("accountId") == self.accountId)
                .filter(ids.contains(Column("messageId")))
                .fetchAll(conn)
                .map { Self.toInfo($0) }
        }
    }

    func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] {
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return [] }
        return try await db.dbPool.read { conn in
            var results: [TextBodyFetchResult] = []
            for id in ids {
                let headerId = MessageIdentity.headerId(accountId: self.accountId, folderPath: folder, messageId: id)
                guard let body = try MessageBody.filter(Column("id") == headerId).fetchOne(conn) else { continue }
                results.append(TextBodyFetchResult(id: id, htmlBody: body.htmlContent, textBody: nil, error: nil))
            }
            return results
        }
    }

    func fetchMessagesBatch(ids: [String], folder: String) async throws -> [String: FullMessageInfo] {
        var out: [String: FullMessageInfo] = [:]
        for id in ids {
            if let msg = try? await fetchMessage(id: id, folder: folder) {
                out[id] = msg
            }
        }
        return out
    }

    // MARK: - Helpers

    private func flagUpdate(ids: [String], folder: String, _ mutate: @Sendable (inout MessageHeader) -> Void) async throws {
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return }
        try await db.dbPool.write { conn in
            for id in ids {
                let headerId = MessageIdentity.headerId(accountId: self.accountId, folderPath: folder, messageId: id)
                guard var h = try MessageHeader.filter(Column("id") == headerId).fetchOne(conn) else { continue }
                mutate(&h)
                try h.update(conn)
            }
        }
    }

    private static func toInfo(_ h: MessageHeader) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: h.messageId,
            rfc822MessageId: h.rfc822MessageId,
            inReplyTo: h.inReplyTo,
            references: h.references,
            threadId: h.threadId,
            subject: h.subject,
            from: h.from,
            fromAddress: h.fromAddress,
            to: h.to,
            cc: h.cc,
            bcc: h.bcc,
            replyTo: h.replyTo,
            date: h.date,
            snippet: h.snippet,
            isRead: h.isRead,
            isFlagged: h.isFlagged,
            hasAttachments: h.hasAttachments,
            isReplied: h.isReplied,
            isForwarded: h.isForwarded,
            actionTag: h.actionTag,
            userLabelIds: []
        )
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
