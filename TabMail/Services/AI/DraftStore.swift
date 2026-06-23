/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Persistent draft storage for compose sessions.
/// Saves/loads/deletes drafts and their associated chat turns.
actor DraftStore {
    static let shared = DraftStore()

    // MARK: - Save

    /// Save or update a draft. Creates if not exists, updates if exists.
    /// Marks serverPushStatus as "dirty" if the draft was previously pushed.
    ///
    /// Nonisolated: the body doesn't touch any actor-local state (DraftStore
    /// itself is a stateless namespace). This lets sync call sites like
    /// ComposeView.send() persist the draft without an async hop, while
    /// existing `await DraftStore.shared.save(...)` call sites keep working
    /// (await on a nonisolated throwing func is a no-op).
    nonisolated func save(_ draft: Draft) throws {
        try AppDatabase.dbPool.write { db in try Self.applySave(draft, db: db) }
        print("[DraftStore] Saved draft id=\(draft.id)")
    }

    /// Async sibling of `save` — routes through the ASYNC `dbPool.write` overload
    /// so a `@MainActor` caller (ComposeView.send / saveDraftAndDismiss) is
    /// suspended, not blocked, while the single serialized writer is busy. Same
    /// transaction body as `save` (shared via `applySave`). See the compose-dismiss
    /// freeze note in PROJECT_MEMORY ("Foreground-return UI freeze").
    nonisolated func saveAsync(_ draft: Draft) async throws {
        try await AppDatabase.dbPool.write { db in try Self.applySave(draft, db: db) }
        print("[DraftStore] Saved draft (async) id=\(draft.id)")
    }

    /// The save transaction body, shared by the sync + async overloads so they
    /// can never drift. Marks the draft dirty if it was previously pushed.
    private static func applySave(_ draft: Draft, db: Database) throws {
        var d = draft
        // Mark dirty if previously pushed (needs re-push to server)
        if d.serverPushStatus == "pushed" {
            d.serverPushStatus = "dirty"
        }
        try d.save(db)
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
    nonisolated func delete(id: String) throws {
        try AppDatabase.dbPool.write { db in try Self.applyDelete(id: id, db: db) }
        // Also clean up attachments on disk if any were saved under draftId.
        DraftAttachmentStorage.deleteAttachments(dirName: id)
        print("[DraftStore] Deleted draft + turns for id=\(id)")
    }

    /// Async sibling of `delete` — routes through the ASYNC `dbPool.write` overload
    /// so a `@MainActor` caller (ComposeView discard/close) is suspended, not
    /// blocked, while the single serialized writer is busy. Same transaction body
    /// as `delete` (shared via `applyDelete`).
    nonisolated func deleteAsync(id: String) async throws {
        try await AppDatabase.dbPool.write { db in try Self.applyDelete(id: id, db: db) }
        DraftAttachmentStorage.deleteAttachments(dirName: id)
        print("[DraftStore] Deleted draft + turns (async) for id=\(id)")
    }

    /// The delete transaction body, shared by the sync + async overloads.
    private static func applyDelete(id: String, db: Database) throws {
        // Delete the draft record
        _ = try Draft.deleteOne(db, key: id)
        // Delete associated chat turns (sessionId = "compose:{draftKey}")
        let sessionId = "compose:\(id)"
        _ = try ChatTurn.filter(Column("sessionId") == sessionId).deleteAll(db)
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
    func pushDraftToServer(draftId: String, provider: any EmailProvider, draftsFolderPath: String) async throws {
        guard var draft = try load(id: draftId) else {
            print("[DraftStore] pushDraftToServer: draft \(draftId) not found — skipping")
            return
        }
        guard draft.serverPushStatus == nil || draft.serverPushStatus == "dirty" else {
            print("[DraftStore] pushDraftToServer: skipping \(draftId) — serverPushStatus=\(draft.serverPushStatus ?? "nil") (must be nil or 'dirty')")
            return
        }
        if DebugModeManager.isLoggingEnabled() { print("[DraftStore] pushDraftToServer: BEGIN id=\(draftId) status=\(draft.serverPushStatus ?? "nil") serverDraftId=\(draft.serverDraftId ?? "nil") subjectPrefix=\(String(draft.subject.prefix(60))) bodyPrefix=\(String(draft.body.prefix(80)))") }

        // Generate a FRESH Message-ID on every push.
        //
        // WHY: Gmail treats same-Message-ID as duplicate. Quoting Google's docs
        // (https://developers.google.com/workspace/gmail/api/guides/drafts):
        //   "Because messages cannot be updated, the message contained in the
        //    draft is destroyed and replaced by the new MIME message supplied
        //    in the update request."
        // Each update should mint a new message.id on Gmail's side. If we
        // send the same Message-ID header repeatedly, Gmail dedupes — keeps
        // the old message, returns the same message.id, and the update is a
        // no-op (confirmed via the "messageId=... unchanged across saves"
        // pattern in logmain.log + responseSnippet showing old content).
        //
        // A fresh Message-ID every push is safe for all providers:
        //  - IMAP saveDraft APPENDs and finds the new UID via Message-ID
        //    search — any unique Message-ID works.
        //  - Our sync-dedup (rfc822-based) keys off the current
        //    Draft.rfc822MessageId, which we persist below after the push.
        //    The post-push migration uses the OLD rfc822 (captured here as
        //    `previousRfc822`) to locate local MessageHeaders that still
        //    carry the prior Message-ID, then rewrites both their PK and
        //    rfc822 to the new values.
        let domain = draft.accountId.contains("@") ? String(draft.accountId.split(separator: "@").last ?? "tabmail.local") : "tabmail.local"
        let previousRfc822 = draft.rfc822MessageId
        let freshRfc822 = "draft-\(UUID().uuidString)@\(domain)"
        draft.rfc822MessageId = freshRfc822
        print("[DraftStore] pushDraftToServer: rotating Message-ID \(previousRfc822 ?? "nil") → \(freshRfc822)")

        // Build DraftMessage from local Draft state.
        // Draft body is plain text (from TextEditor) — convert to HTML for IMAP storage.
        // HTML is the standard format for email drafts and what other clients expect.
        let htmlBody = MessageBody.plainTextToHTML(draft.body)
        var draftMessage = DraftMessage(
            to: draft.toArray,
            cc: draft.ccArray,
            bcc: draft.bccArray,
            subject: draft.subject,
            body: htmlBody,
            isHTML: true,
            inReplyTo: nil,
            attachments: []
        )
        draftMessage.messageId = draft.rfc822MessageId

        // Load attachments from disk if present
        if let dirName = draft.attachmentsDirName {
            let attachments = DraftAttachmentStorage.loadAttachments(dirName: dirName)
            draftMessage.attachments = attachments
        }

        // Push to server
        let result = try await provider.saveDraft(draftMessage, existingDraftId: draft.serverDraftId, draftsFolderPath: draftsFolderPath)

        // Update ONLY the server-sync columns — NOT user content (subject/body/editHistory).
        // The user may have edited the draft during the network await. A full save() would
        // overwrite those edits with the stale snapshot captured before the push.
        let rfc822 = draft.rfc822MessageId
        let draftIdForUpdate = draft.id
        let accountId = draft.accountId
        // FTS ops collected inside the write, applied after commit (SearchIndex is
        // a separate actor/DB). A draft placeholder header's id is folder+messageId
        // based; migrating it to the server id re-keys the GRDB row, so FTS must
        // follow or the entry orphans. (No-ops harmlessly if the draft was never indexed.)
        let draftFtsOps: (removals: [String], rekeys: [(oldId: String, newId: String, newMessageId: String?)])
        draftFtsOps = try await AppDatabase.dbPool.write { db in
            var draftFtsRemovals: [String] = []
            var draftFtsRekeys: [(oldId: String, newId: String, newMessageId: String?)] = []
            try db.execute(
                sql: """
                    UPDATE draft SET serverDraftId = ?, serverPushStatus = ?, rfc822MessageId = ?
                    WHERE id = ?
                    """,
                arguments: [result.serverId, "pushed", rfc822, draftIdForUpdate]
            )

            // If the server returned a real messageId (Gmail/IMAP: message.id
            // may differ from the draft resource id), migrate any local
            // MessageHeader pointing at this draft to the new messageId-based
            // PK so sync's stale-check doesn't delete it as "onlyLocal".
            //
            // Strategy: match by PREVIOUS rfc822MessageId (what local headers
            // still carry). We just rotated Draft.rfc822MessageId above to a
            // fresh value for the push; local headers still have the OLD
            // rfc822 until this migration rewrites it. Update BOTH the PK
            // (to new messageId) and the rfc822 (to fresh) on migrated
            // headers so subsequent queueDraftSave rfc822 lookups resolve to
            // the right row.
            //
            // Covers all cases:
            //   - optimistic placeholder (messageId = "draft-<uuid>",
            //     rfc822 = previousRfc822)
            //   - server-synced header from a previous push (messageId =
            //     previous Gmail message.id / IMAP UID, rfc822 = previousRfc822)
            if let realMessageId = result.messageId {
                let folderId = "\(accountId):\(draftsFolderPath)"
                let newHeaderId = "\(accountId):\(draftsFolderPath):\(realMessageId)"

                // Collect candidate local headers to migrate. Prioritize
                // match-by-previousRfc822 (precise). If previousRfc822 is nil
                // (first push for a brand-new draft), fall back to match-by-
                // current-Draft-rfc822 (the fresh one, which matches the
                // placeholder queueDraftSave just created).
                var headers: [MessageHeader] = []
                if let prev = previousRfc822, !prev.isEmpty {
                    headers = try MessageHeader
                        .filter(Column("folderId") == folderId && Column("rfc822MessageId") == prev)
                        .fetchAll(db)
                }
                if headers.isEmpty {
                    headers = try MessageHeader
                        .filter(Column("folderId") == folderId && Column("rfc822MessageId") == freshRfc822)
                        .fetchAll(db)
                }
                print("[DraftStore] pushDraftToServer migration: found \(headers.count) header(s) matching rfc822=\(previousRfc822 ?? freshRfc822) in folder \(draftsFolderPath). Target messageId=\(realMessageId), new rfc822=\(freshRfc822)")

                for header in headers {
                    guard header.id != newHeaderId else {
                        // Already at target PK — just refresh rfc822 to the new one.
                        var same = header
                        same.rfc822MessageId = freshRfc822
                        try same.update(db)
                        print("[DraftStore] Migration: header \(header.id) already at target PK — refreshed rfc822 to \(freshRfc822)")
                        continue
                    }

                    // If a header at the target PK already exists (sync raced
                    // ahead and inserted the new server row from Gmail's
                    // drafts.list BEFORE our push completed), MERGE:
                    //   - keep target's PK / messageId (matches server)
                    //   - overwrite content from our row (user's fresh save
                    //     always wins; Gmail's drafts.list snippet can lag)
                    //   - overwrite rfc822 with freshRfc822 so the row reflects
                    //     the Message-ID we just sent (subsequent syncs and
                    //     local queueDraftSave will find it via the fresh id).
                    if let existingTarget = try MessageHeader.fetchOne(db, key: newHeaderId) {
                        var merged = existingTarget
                        merged.subject = header.subject
                        merged.to = header.to
                        merged.cc = header.cc
                        merged.bcc = header.bcc
                        merged.snippet = header.snippet
                        merged.date = header.date
                        merged.rfc822MessageId = freshRfc822
                        try merged.update(db)

                        // Body too: user's fresh body wins over sync's lagged copy.
                        if let freshBody = try MessageBody.fetchOne(db, key: header.id) {
                            _ = try? MessageBody.deleteOne(db, key: newHeaderId)
                            var newBody = freshBody
                            newBody.id = newHeaderId
                            try newBody.insert(db)
                        }
                        _ = try? MessageBody.deleteOne(db, key: header.id)
                        draftFtsRemovals.append(header.id)
                        try header.delete(db)
                        if DebugModeManager.isLoggingEnabled() { print("[DraftStore] Migration: MERGED fresh content from \(header.id) onto existing \(newHeaderId) (snippet=\(String(header.snippet.prefix(60))))") }
                        continue
                    }

                    draftFtsRekeys.append((oldId: header.id, newId: newHeaderId, newMessageId: realMessageId))
                    try header.delete(db)
                    var migrated = header
                    migrated.id = newHeaderId
                    migrated.messageId = realMessageId
                    // Bump rfc822 to the fresh Message-ID we just pushed so
                    // local lookups (sync dedup, queueDraftSave) resolve the
                    // updated identity on the next save cycle.
                    migrated.rfc822MessageId = freshRfc822
                    try migrated.insert(db)
                    if var body = try MessageBody.fetchOne(db, key: header.id) {
                        try body.delete(db)
                        body.id = newHeaderId
                        try body.insert(db)
                    }
                    print("[DraftStore] Migrated header \(header.id) → \(newHeaderId) (messageId \(header.messageId) → \(realMessageId), rfc822 \(header.rfc822MessageId ?? "nil") → \(freshRfc822))")
                }
            }
            return (draftFtsRemovals, draftFtsRekeys)
        }
        // Keep FTS aligned with the migrated GRDB ids: re-key migrated placeholders
        // (preserves the indexed body), remove merged-away ones. After the write.
        if !draftFtsOps.removals.isEmpty {
            try? await SearchIndex.shared.removeMessages(headerIds: draftFtsOps.removals)
        }
        if !draftFtsOps.rekeys.isEmpty {
            try? await SearchIndex.shared.rekeyHeaders(draftFtsOps.rekeys)
        }
        // Notify list to reload after header migration so the snapshot PK is current.
        // Without this, the list has the old placeholder PK which no longer resolves.
        if result.messageId != nil {
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        print("[DraftStore] Pushed draft \(draftId) to server, serverDraftId=\(result.serverId)\(result.messageId.map { " messageId=\($0)" } ?? "")")
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
    nonisolated func evictSync(dbPool: DatabasePool, limit: Int) throws -> Int {
        try Self.evictImpl(dbPool: dbPool, limit: limit)
    }

    private static func evictImpl(dbPool: DatabasePool, limit: Int) throws -> Int {
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
                    let sessionId = "compose:\(draft.id)"
                    _ = try ChatTurn.filter(Column("sessionId") == sessionId).deleteAll(db)
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
