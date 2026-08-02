/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Persistent draft storage for compose sessions.
/// Saves/loads/deletes drafts and their associated chat turns.
actor DraftStore {
    static let shared = DraftStore()

    enum SaveResult: Sendable, Equatable {
        case applied
        case notApplied
    }

    enum PushDisposition: Sendable, Equatable {
        case completed
        /// The provider threw after Stage A, so the attempt may have landed.
        /// The producer is deliberately retired once; sync reconciles.
        case terminalUnconfirmed
        /// A replacement/edit won the exact Stage A/B CAS. This producer is stale.
        case notApplied
    }

    enum DraftEpochAdmissionError: Error, LocalizedError {
        case staleOrReserved

        var errorDescription: String? {
            "This draft was changed by another compose session and can't be saved from here."
        }
    }

    // MARK: - Save

    /// PORT — v2final observed-predecessor generation CAS (3f2cc4c34).
    @discardableResult
    static func admitSave(
        _ draft: Draft,
        newEpoch: String,
        expectedPredecessor: String?,
        db: Database
    ) throws -> SaveResult {
        let observed = try Draft.fetchOne(db, key: draft.id)
        guard let observed else {
            guard expectedPredecessor == nil else {
                throw DraftEpochAdmissionError.staleOrReserved
            }
            var inserted = draft
            inserted.instanceEpoch = newEpoch
            return try applySave(inserted, db: db)
        }
        if observed.instanceEpoch != newEpoch {
            guard observed.instanceEpoch == expectedPredecessor else {
                throw DraftEpochAdmissionError.staleOrReserved
            }
        }
        var admitted = draft
        admitted.instanceEpoch = newEpoch
        let result = try applySave(admitted, db: db)
        if result == .applied {
            try db.execute(
                sql: "UPDATE draft SET instanceEpoch = ? WHERE id = ?",
                arguments: [newEpoch, draft.id])
        }
        return result
    }

    @discardableResult
    nonisolated func save(
        _ draft: Draft,
        epoch newEpoch: String,
        expectedPredecessor: String?
    ) throws -> SaveResult {
        try AppDatabase.dbPool.write {
            try Self.admitSave(
                draft, newEpoch: newEpoch,
                expectedPredecessor: expectedPredecessor, db: $0)
        }
    }

    @discardableResult
    nonisolated func saveAsync(
        _ draft: Draft,
        epoch newEpoch: String,
        expectedPredecessor: String?
    ) async throws -> SaveResult {
        try await AppDatabase.dbPool.write {
            try Self.admitSave(
                draft, newEpoch: newEpoch,
                expectedPredecessor: expectedPredecessor, db: $0)
        }
    }

    /// PORT — merge authored fields only and bump the Stage A/B conflict version.
    @discardableResult
    static func applySave(_ draft: Draft, db: Database) throws -> SaveResult {
        guard let current = try Draft.fetchOne(db, key: draft.id) else {
            var inserted = draft
            if inserted.serverPushStatus == "pushed" { inserted.serverPushStatus = "dirty" }
            try inserted.insert(db)
            return .applied
        }
        guard draft.updatedAt >= current.updatedAt else { return .notApplied }
        var merged = current
        merged.toJSON = draft.toJSON
        merged.ccJSON = draft.ccJSON
        merged.bccJSON = draft.bccJSON
        merged.subject = draft.subject
        merged.body = draft.body
        merged.editHistoryJSON = draft.editHistoryJSON
        merged.updatedAt = draft.updatedAt
        merged.attachmentsDirName = draft.attachmentsDirName
        merged.pushAttemptVersion = current.pushAttemptVersion + 1
        if current.serverPushStatus == "pushed" || current.serverPushStatus == "pushing"
            || current.serverPushStatus == "unconfirmed" {
            merged.serverPushStatus = "dirty"
        }
        try merged.update(db)
        return .applied
    }

    // MARK: - Load

    /// Load a draft by its key.
    /// Nonisolated: body doesn't touch actor-local state — lets sync call
    /// sites (e.g. PendingSendService.undo) avoid an actor hop.
    nonisolated func load(id: String) throws -> Draft? {
        try AppDatabase.dbPool.read { db in
            try Draft.fetchOne(db, key: id)
        }
    }

    // MARK: - Delete

    /// Delete a draft and its associated chat turns.
    /// Nonisolated: same rationale as `save` and `load`.
    /// PORT — generation-owned delete. A stale compose instance cannot erase a
    /// successor that has taken the same logical draft key.
    @discardableResult
    nonisolated func deleteAsync(
        id: String,
        expectedInstanceEpoch: String
    ) async throws -> Bool {
        let deleted = try await AppDatabase.dbPool.write { db -> Bool in
            guard let current = try Draft.fetchOne(db, key: id),
                  current.instanceEpoch == expectedInstanceEpoch else {
                return false
            }
            try Self.applyDelete(
                id: id, expectedInstanceEpoch: expectedInstanceEpoch, db: db)
            return true
        }
        if deleted {
            DraftAttachmentStorage.deleteAttachments(dirName: id)
            print("[DraftStore] Deleted owned draft + turns (async) for id=\(id)")
        }
        return deleted
    }

    /// The delete transaction body, shared by the sync + async overloads.
    static func applyDelete(
        id: String,
        expectedInstanceEpoch: String,
        db: Database
    ) throws {
        guard let current = try Draft.fetchOne(db, key: id),
              current.instanceEpoch == expectedInstanceEpoch else {
            throw DraftEpochAdmissionError.staleOrReserved
        }
        // Delete the draft record
        _ = try Draft.deleteOne(db, key: id)
        let sessionIds = ["compose:\(id)", "demo:compose:\(id)"]
        _ = try ChatTurn.filter(sessionIds.contains(Column("sessionId"))).deleteAll(db)
    }

    /// Delete a draft by its key (without deleting chat turns).
    func deleteDraftOnly(id: String) throws {
        _ = try AppDatabase.dbPool.write { db in
            try Draft.deleteOne(db, key: id)
        }
    }

    // MARK: - Query

    /// Check if a draft exists for a given key.
    func exists(id: String) throws -> Bool {
        try AppDatabase.dbPool.read { db in
            try Draft.fetchOne(db, key: id) != nil
        }
    }

    /// Load all drafts ordered by updatedAt DESC.
    func loadAll() throws -> [Draft] {
        try AppDatabase.dbPool.read { db in
            try Draft.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    // MARK: - Server Push

    /// Push a local draft to the server's Drafts folder.
    /// Builds a DraftMessage from the local Draft, calls provider.saveDraft(),
    /// and stores the returned server draft ID.
    struct StageAContext: Sendable {
        let draftId: String
        let accountId: String
        let instanceEpoch: String
        let postAPushAttemptVersion: Int
        let freshRfc: String
        let previousIdentity: DraftDeleteIdentity?
    }

    private struct HeaderMigration: Sendable {
        let oldHeaderId: String
        let newHeaderId: String
        let newMessageId: String
    }

    /// PORT — reduced v2final `PushCompletion.advanced` plus its independent
    /// migration payload. A successful completion may legitimately have no
    /// header to migrate; a rejected Stage-B CAS is a different outcome.
    private struct PushCompletion: Sendable {
        let applied: Bool
        let migration: HeaderMigration?
    }

    /// PORT — reduced v2final DraftStoreStageAB.performStageA.
    static func performStageA(
        initialDraft: Draft,
        expectedInstanceEpoch: String,
        previousIdentity: DraftDeleteIdentity?,
        freshRfc: String,
        db: Database
    ) throws -> StageAContext? {
        guard var current = try Draft.fetchOne(db, key: initialDraft.id),
              current.accountId == initialDraft.accountId,
              current.instanceEpoch == expectedInstanceEpoch,
              current.serverPushStatus == nil || current.serverPushStatus == "dirty",
              current.pushAttemptVersion == initialDraft.pushAttemptVersion else {
            return nil
        }
        let postAVersion = current.pushAttemptVersion + 1
        current.rfc822MessageId = freshRfc
        current.serverPushStatus = "pushing"
        current.pushAttemptVersion = postAVersion
        try current.update(db)
        return StageAContext(
            draftId: current.id,
            accountId: current.accountId,
            instanceEpoch: expectedInstanceEpoch,
            postAPushAttemptVersion: postAVersion,
            freshRfc: freshRfc,
            previousIdentity: previousIdentity)
    }

    private static func priorIdentity(
        for draft: Draft,
        runtimeKind: DraftRuntimeIdentityKind
    ) -> DraftDeleteIdentity? {
        guard let serverId = draft.serverDraftId, !serverId.isEmpty else {
            return nil
        }
        switch runtimeKind {
        case .gmail:
            return .gmail(resourceId: serverId)
        case .outlook:
            return .outlook(graphId: serverId)
        case .demo:
            return .demo(localId: serverId)
        case .imap:
            guard let folder = draft.serverDraftFolderPath,
                  let epoch = draft.serverDraftUidValidity,
                  let uid = Int(serverId), uid > 0 else { return nil }
            return .imap(folder: folder, uidValidity: epoch, uid: uid)
        case .unknown:
            return nil
        }
    }

    /// PORT — reduced normal-completion arm of v2final applyPushCompletion.
    /// SUBTRACT: lineage, receipts, recovery, ghost, S3 and redrive.
    private static func applyPushCompletion(
        context: StageAContext,
        outcome: DraftSaveOutcome,
        runtimeKind: DraftRuntimeIdentityKind,
        draftsFolderPath: String,
        db: Database
    ) throws -> PushCompletion {
        guard var draft = try Draft.fetchOne(db, key: context.draftId),
              draft.accountId == context.accountId,
              draft.instanceEpoch == context.instanceEpoch,
              draft.pushAttemptVersion == context.postAPushAttemptVersion,
              draft.serverPushStatus == "pushing",
              draft.rfc822MessageId == context.freshRfc else {
            return PushCompletion(applied: false, migration: nil)
        }

        switch outcome {
        case .unaddressable:
            // Terminal for this attempt, without persistent lifecycle state.
            draft.serverDraftId = nil
            draft.serverDraftUidValidity = nil
            draft.serverDraftFolderPath = nil
            draft.serverPushStatus = nil
            try draft.update(db)
            return PushCompletion(applied: true, migration: nil)

        case .created(let address):
            let realMessageId: String?
            switch (runtimeKind, address) {
            case (.gmail, .gmail(let resourceId, let containedMessageId)):
                draft.serverDraftId = resourceId
                draft.serverDraftUidValidity = nil
                draft.serverDraftFolderPath = nil
                // SUBTRACT — the contained MESSAGE id is display bookkeeping,
                // not Draft mutation authority. If Gmail did not return it for
                // this exact attempt, let sync create the provider header.
                realMessageId = containedMessageId
            case (.outlook, .outlook(let graphId)):
                draft.serverDraftId = graphId
                draft.serverDraftUidValidity = nil
                draft.serverDraftFolderPath = nil
                realMessageId = graphId
            case (.imap, .imap(let folder, let uidValidity, let uid)):
                guard folder == draftsFolderPath else {
                    throw ProviderError.actionIdentityResolutionFailed(
                        "IMAP draft address returned for a different mailbox")
                }
                draft.serverDraftId = String(uid)
                draft.serverDraftUidValidity = uidValidity
                draft.serverDraftFolderPath = folder
                realMessageId = String(uid)
            case (.demo, .demo(let localId)):
                draft.serverDraftId = localId
                draft.serverDraftUidValidity = nil
                draft.serverDraftFolderPath = nil
                realMessageId = localId
            default:
                throw ProviderError.actionIdentityResolutionFailed(
                    "draft provider returned an address from the wrong namespace")
            }
            draft.serverPushStatus = "pushed"
            try draft.update(db)

            guard let realMessageId else {
                return PushCompletion(applied: true, migration: nil)
            }
            let oldHeaderId = PendingOperation.draftPlaceholderHeaderPK(
                accountId: context.accountId,
                draftsFolderPath: draftsFolderPath,
                draftId: context.draftId,
                instanceEpoch: context.instanceEpoch)
            return PushCompletion(
                applied: true,
                migration: HeaderMigration(
                    oldHeaderId: oldHeaderId,
                    newHeaderId: "\(context.accountId):\(draftsFolderPath):\(realMessageId)",
                    newMessageId: realMessageId))
        }
    }

    /// SUBTRACT — no v2final recovery/ghost/redrive machinery. A provider throw
    /// is terminalized only when the exact Stage A attempt still owns the row.
    /// Authored fields and the prior provider-native linkage stay untouched;
    /// `unconfirmed` grants no new mutation authority and a later authored save
    /// moves it to `dirty` for a fresh producer.
    @discardableResult
    private static func applyTerminalPushFailure(
        context: StageAContext,
        db: Database
    ) throws -> Bool {
        guard var draft = try Draft.fetchOne(db, key: context.draftId),
              draft.accountId == context.accountId,
              draft.instanceEpoch == context.instanceEpoch,
              draft.pushAttemptVersion == context.postAPushAttemptVersion,
              draft.serverPushStatus == "pushing",
              draft.rfc822MessageId == context.freshRfc else {
            return false
        }
        draft.serverPushStatus = "unconfirmed"
        try draft.update(db)
        return true
    }

    private static func migrateExactPlaceholder(
        _ migration: HeaderMigration,
        freshRfc: String,
        db: Database
    ) throws -> Bool {
        guard var placeholder = try MessageHeader.fetchOne(db, key: migration.oldHeaderId) else {
            return false
        }
        if try MessageHeader.fetchOne(db, key: migration.newHeaderId) != nil {
            _ = try MessageBody.deleteOne(db, key: ContentKey(rawValue: placeholder.id))
            try placeholder.delete(db)
            return false
        }
        try placeholder.delete(db)
        placeholder.id = migration.newHeaderId
        placeholder.messageId = migration.newMessageId
        placeholder.rfc822MessageId = freshRfc
        try placeholder.insert(db)
        if var body = try MessageBody.fetchOne(db, key: ContentKey(rawValue: migration.oldHeaderId)) {
            try body.delete(db)
            body.id = ContentKey(rawValue: migration.newHeaderId)
            try body.insert(db)
        }
        return true
    }

    /// PORT — exact pre-A initialDraft/payload + StageAContext shape. Stage A
    /// revalidates generation/version/status before provider I/O; Stage B applies
    /// only the exact post-A version/status/generation/fresh-RFC completion.
    func pushDraftToServer(
        draftId: String,
        expectedInstanceEpoch: String,
        provider: any EmailProvider,
        runtimeKind: DraftRuntimeIdentityKind,
        draftsFolderPath: String
    ) async throws -> PushDisposition {
        guard runtimeKind != .unknown,
              let initialDraft = try load(id: draftId),
              initialDraft.instanceEpoch == expectedInstanceEpoch,
              initialDraft.serverPushStatus == nil || initialDraft.serverPushStatus == "dirty" else {
            return .notApplied
        }

        let domain = initialDraft.accountId.contains("@")
            ? String(initialDraft.accountId.split(separator: "@").last ?? "tabmail.local")
            : "tabmail.local"
        let freshRfc = "draft-\(UUID().uuidString)@\(domain)"

        // Build every provider payload field from the exact pre-A snapshot.
        var payload = DraftMessage(
            to: initialDraft.toArray,
            cc: initialDraft.ccArray,
            bcc: initialDraft.bccArray,
            subject: initialDraft.subject,
            body: MessageBody.plainTextToHTML(initialDraft.body),
            isHTML: true,
            inReplyTo: nil,
            attachments: initialDraft.attachmentsDirName.map {
                DraftAttachmentStorage.loadAttachments(dirName: $0)
            } ?? [])
        payload.messageId = freshRfc

        guard let context = try await AppDatabase.dbPool.write({ db in
            try Self.performStageA(
                initialDraft: initialDraft,
                expectedInstanceEpoch: expectedInstanceEpoch,
                previousIdentity: Self.priorIdentity(
                    for: initialDraft, runtimeKind: runtimeKind),
                freshRfc: freshRfc,
                db: db)
        }) else {
            return .notApplied
        }

        let outcome: DraftSaveOutcome
        do {
            outcome = try await provider.saveDraft(
                payload,
                existingIdentity: context.previousIdentity,
                draftsFolderPath: draftsFolderPath)
        } catch {
            let terminalized = try await AppDatabase.dbPool.write { db in
                try Self.applyTerminalPushFailure(context: context, db: db)
            }
            return terminalized ? .terminalUnconfirmed : .notApplied
        }

        let completion = try await AppDatabase.dbPool.write { db in
            try Self.applyPushCompletion(
                context: context,
                outcome: outcome,
                runtimeKind: runtimeKind,
                draftsFolderPath: draftsFolderPath,
                db: db)
        }

        guard completion.applied else { return .notApplied }

        if let migration = completion.migration {
            let rekeyed = try await AppDatabase.dbPool.write { db in
                try Self.migrateExactPlaceholder(
                    migration, freshRfc: context.freshRfc, db: db)
            }
            if rekeyed {
                try? await SearchIndex.shared.rekeyHeaders([(
                    oldKey: ContentKey(rawValue: migration.oldHeaderId),
                    newKey: ContentKey(rawValue: migration.newHeaderId),
                    newMessageId: migration.newMessageId)])
            } else {
                await MessageContentStore.releaseUnowned(
                    [ContentKey(rawValue: migration.oldHeaderId)],
                    stores: [.searchIndex, .body])
            }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        return .completed
    }
    /// Update serverPushStatus to "dirty" (needs re-push) for a draft.
    func markDirty(id: String) throws {
        try AppDatabase.dbPool.write { db in
            _ = try Draft.filter(Column("id") == id)
                .updateAll(db, Column("serverPushStatus").set(to: "dirty"))
        }
    }

    /// Look up the Drafts folder path for an account.
    func draftsFolderPath(accountId: String) throws -> String {
        try AppDatabase.dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.drafts.rawValue)
                .fetchOne(db)?.path ?? "Drafts"
        }
    }


    // MARK: - Eviction

    /// Evict old compose drafts beyond the limit.
    /// Drafts tied to inbox messages (reply/forward where message isInInbox) are exempt.
    /// Returns the number of evicted drafts.
    @discardableResult
    func evict(limit: Int) throws -> Int {
        try Self.evictImpl(dbPool: AppDatabase.dbPool, limit: limit)
    }

    /// Nonisolated eviction for background maintenance thread.
    nonisolated func evictSync(dbPool: PrioritizedDatabase, limit: Int) throws -> Int {
        try Self.evictImpl(dbPool: dbPool, limit: limit)
    }

    private static func evictImpl(dbPool: PrioritizedDatabase, limit: Int) throws -> Int {
        // Collect attachment dirs to delete outside the DB transaction (file I/O outside transaction)
        var attachmentDirsToDelete: [String] = []

        let evictedCount: Int = try dbPool.write { db in
            // Also clean orphaned compose sessions (chatTurn with no matching draft)
            let orphanedSessions = try Row.fetchAll(db, sql: """
                SELECT DISTINCT ct.sessionId
                FROM chatTurn ct
                LEFT JOIN draft d ON d.id = SUBSTR(ct.sessionId, 9)
                WHERE ct.sessionId LIKE 'compose:%' AND d.id IS NULL
            """)
            var orphanEvicted = 0
            for row in orphanedSessions {
                let sid: String = row["sessionId"]
                _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(db)
                orphanEvicted += 1
            }
            if orphanEvicted > 0 {
                print("[DraftStore] Cleaned \(orphanEvicted) orphaned compose sessions")
            }

            // Evict oldest drafts beyond limit
            let allDrafts = try Draft.order(Column("updatedAt").desc).fetchAll(db)

            var kept = 0
            var evicted = 0
            for draft in allDrafts {
                // Exempt: reply/forward drafts where the original message is still in inbox.
                // Strategy 1: lookup by GRDB PK (replyToId).
                // Strategy 2: if PK stale (IMAP MOVE), extract stableId from draft key
                //             and search by rfc822MessageId.
                if let replyToId = draft.replyToId {
                    if let header = try MessageHeader.fetchOne(db, key: replyToId), header.isInInbox {
                        continue
                    }
                    // Fallback: extract stableId from draft.id.
                    // Format: "reply:{accountId}:{stableId}" or "forward:{accountId}:{stableId}".
                    // Drop the prefix ("reply:" or "forward:"), then find first ":" to separate
                    // accountId from stableId. This handles stableIds containing colons
                    // (rare but valid in rfc822MessageId local-parts).
                    let afterPrefix: Substring
                    if draft.id.hasPrefix("reply:") {
                        afterPrefix = draft.id.dropFirst(6) // "reply:".count
                    } else if draft.id.hasPrefix("forward:") {
                        afterPrefix = draft.id.dropFirst(8) // "forward:".count
                    } else {
                        afterPrefix = ""
                    }
                    if let colonIdx = afterPrefix.firstIndex(of: ":") {
                        let stableId = String(afterPrefix[afterPrefix.index(after: colonIdx)...])
                        let normalizedStableId = EmailFilter.normalizeMessageId(stableId)
                        if !normalizedStableId.isEmpty,
                           let header = try MessageHeader
                            .filter(Column("rfc822MessageId") == normalizedStableId)
                            .fetchOne(db), header.isInInbox {
                            continue
                        }
                    }
                }

                kept += 1
                if kept > limit {
                    if let dirName = draft.attachmentsDirName {
                        attachmentDirsToDelete.append(dirName)
                    }
                    // Both plain and demo-prefixed variants (see applyDelete).
                    let sessionIds = ["compose:\(draft.id)", "demo:compose:\(draft.id)"]
                    _ = try ChatTurn.filter(sessionIds.contains(Column("sessionId"))).deleteAll(db)
                    try draft.delete(db)
                    evicted += 1
                }
            }

            if evicted > 0 {
                print("[DraftStore] Evicted \(evicted) drafts (limit=\(limit))")
            }
            return evicted + orphanEvicted
        }

        // Delete attachment files outside DB transaction
        for dirName in attachmentDirsToDelete {
            DraftAttachmentStorage.deleteAttachments(dirName: dirName)
        }

        return evictedCount
    }
}
