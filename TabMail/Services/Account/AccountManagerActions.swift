/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension AccountManager {

    // MARK: - Actions (optimistic UI + persistent queue)
    //
    // All actions update GRDB state immediately (optimistic UI) then queue the
    // remote operation for async execution. The queue drains when:
    // - NetworkMonitor detects connection restored
    // - Foreground return (SyncScheduler.startForegroundPolling)
    // - After each successful sync poll
    // - On app launch (reconcilePendingOperations → drainPendingQueue)
    //
    // If the server state changed after queueing (message moved/deleted remotely),
    // the queued operation is dropped (conflict detection in drainPendingQueue).

    /// ADR-IOS-049: before an optimistic action writes GRDB, ensure every target
    /// message is durably in GRDB. A row surfaced in-memory via `.messagesStaged`
    /// (`InboxViewModel.insertStagedRows`) isn't in GRDB yet, so the optimistic UPDATE
    /// would hit 0 rows and the NSE merge would later resurrect it as inbox. Draining
    /// the merge first makes the row real so optimistic-state wins. Cheap indexed
    /// existence read on the action path (NOT the render path); no-op + zero
    /// coordinator hop for the ~all case where every target is already durable.
    func ensureDurable(_ messages: [MessageHeader]) async {
        let anyMissing = (try? await dbPool.read { db -> Bool in
            for m in messages {
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messageHeader WHERE id = ?)", arguments: [m.id]) ?? false
                if !exists { return true }
            }
            return false
        }) ?? false
        guard anyMissing else { return }
        await NSEMergeCoordinator.shared.merge()
    }

    /// Off-main `MessageHeader` resolution for use INSIDE queued write closures
    /// (`enqueueWrite`) — never on the MainActor gesture path. Mirrors
    /// `InboxViewModel.lookupMessage`'s exact two-step lookup (durable GRDB row,
    /// else the ADR-IOS-049 staged-row synthesis from `NSEDataBridge.latestStagedRows`)
    /// so a gesture on a just-pushed row not yet durable in GRDB still resolves
    /// once its closure runs — one implementation shared by both call sites
    /// instead of a second copy of the two-step logic.
    ///
    /// Ids that resolve to nothing (row genuinely vanished — e.g. deleted by an
    /// earlier queued op) are silently dropped. Callers gate on the returned
    /// array being smaller than `ids` and must not strand any optimistic
    /// overlay entry registered for a dropped id.
    func resolveHeadersForAction(ids: [String]) async -> [MessageHeader] {
        guard !ids.isEmpty else { return [] }
        let durable = (try? await dbPool.read { db -> [MessageHeader] in
            try MessageHeader.filter(ids.contains(Column("id"))).fetchAll(db)
        }) ?? []
        var byId = Dictionary(uniqueKeysWithValues: durable.map { ($0.id, $0) })
        let missingIds = ids.filter { byId[$0] == nil }
        if !missingIds.isEmpty {
            let missingSet = Set(missingIds)
            let staged = NSEDataBridge.latestStagedRows.withLock { rows in
                rows.filter { missingSet.contains($0.headerId) }
            }
            for row in staged { byId[row.headerId] = row.toMessageHeader() }
        }
        // Preserve caller's id order; ids that resolved to nothing are dropped.
        return ids.compactMap { byId[$0] }
    }

    /// Singular convenience over `resolveHeadersForAction(ids:)` for single-message actions.
    func resolveHeaderForAction(id: String) async -> MessageHeader? {
        await resolveHeadersForAction(ids: [id]).first
    }

    // MARK: - T1.3 — an unknown folder epoch fails CLOSED for new gestures

    /// Whether a NEW user gesture against `folderPath` must be REFUSED because that
    /// folder's UIDVALIDITY epoch is not yet known. Callers must treat `true` as a
    /// **silent no-op** (owner decision §9 D6(a)): no op row, no local mutation, no
    /// error surfaced to the user.
    ///
    /// ⚑ NO REFERENCE — INVENTED.
    /// The `v2final` reference deliberately does the OPPOSITE. Its
    /// `observedUidValidityStampForTokenAdmission`
    /// (`v2final:TabMail/Services/Account/AccountManagerQueue.swift:837`) returns a
    /// nil stamp on an unobserved epoch, which then skips the claim-time check, the
    /// in-flight slot publish and the ledger compare — it fails **OPEN**, and records
    /// that as an accepted residual: *"virgin-folder fail-open is bounded by
    /// seed-write latency"* (`v2final:Companion/Decisions/Active/adr-ios-061.md:38`).
    /// That was only tenable because v2 carried an epoch ledger plus a purge-and-
    /// resync reaction. v3 has neither, so v3 is deliberately stronger and refuses.
    ///
    /// **This deliberately drops one user intention, which this repo's core
    /// philosophy otherwise forbids. Do NOT "fix" it back to fail-open.** The owner
    /// authorised the trade (§9 D6, 2026-07-30): failing closed is always acceptable,
    /// and constraint C3 — *never mutate the wrong message* — is the one hard
    /// invariant. `MessageHeader.stableId` falls back to the bare numeric UID for any
    /// header with no `rfc822MessageId`, and `IMAPProvider.resolveUID` treats a
    /// numeric id as a literal UID. Admitting against a folder whose epoch is unknown
    /// can therefore resolve that UID under a DIFFERENT epoch and STORE/COPY over an
    /// unrelated message — exactly C3.
    ///
    /// What makes the trade acceptable is that the window is **BOUNDED to the first
    /// sync of a folder**. T1.2b (`7c71f6c7b`) persists the epoch from the
    /// `Mailbox.Selection` of SELECTs the sync and folder-open paths already perform,
    /// and `OK [UIDVALIDITY n]` is core IMAP4rev1 — NOT a UIDPLUS extension — so even
    /// a server that never answers a UIDVALIDITY STATUS still reports one on SELECT.
    /// So nil means "the first sync has not finished yet", never "this server does not
    /// do UIDVALIDITY". Recorded for users as `IOS-EPOCH-001` in `KNOWN_ISSUES.md`.
    /// ⛔ A synthesized/fake epoch was PROPOSED AND REJECTED by the owner (2026-07-30):
    /// it would disable the check globally to paper over a case SELECT already covers.
    ///
    /// 🚨 **PROVIDER-SCOPED ON PURPOSE — never widen this to "the column is nil".**
    /// `Folder.lastKnownUidValidity` is nil FOREVER on Gmail and Exchange: UIDVALIDITY
    /// is an IMAP concept, and neither the Gmail nor the Graph provider ever populates
    /// `FolderInfo.uidValidity`, so nothing ever writes that column for their folders.
    /// Keying the refusal off the column alone would silently no-op every action on
    /// every Gmail and Exchange account permanently — a bricked app, not a bounded
    /// window. The partition below mirrors `EmailProvider.staleWindowMode` (`.uid` for
    /// IMAP, `.date` for Gmail/Exchange), expressed against the `Account` row because
    /// admission runs inside a write transaction with no provider instance in hand.
    /// `.icloud` IS an IMAP account and MUST stay in the set — several sync sites test
    /// `.imap` alone and wrongly exclude it; do not copy those.
    ///
    /// 🚨 **THE PROVIDER COLUMN IS A PROXY FOR "IS THIS ACCOUNT IMAP-BACKED", AND THE
    /// DEMO ACCOUNT BREAKS IT.** `DemoSeed.seedAccount` stores `provider: .imap`, but
    /// the account is served by `DemoProvider` — pure GRDB, no network, no SELECT, so
    /// nothing can EVER stamp `lastKnownUidValidity` on a demo folder. Without the
    /// exclusion below, every guarded gesture in Demo Mode is refused forever: archive,
    /// delete, move, mark read/unread, flag and all three label paths become silent
    /// no-ops. That is a permanent brick, not a bounded first-sync window — the exact
    /// shape the Gmail/Exchange scoping above exists to prevent, reached through a
    /// different door. The exclusion is placed HERE rather than papered over by seeding
    /// a synthetic epoch in `DemoSeed`: this predicate's one idea is *"does this
    /// account address messages by epoch-scoped UID?"*, and `DemoProvider` does not, so
    /// excluding it CORRECTS the proxy instead of feeding it a value that would make
    /// `Folder.lastKnownUidValidity` (documented as "the UIDVALIDITY the server last
    /// reported") lie for an account that has no server. A seeded epoch would also
    /// silently re-brick the moment demo seeding changed. Comparing against
    /// `DemoSeed.demoAccountId` is this repo's established idiom for the demo carve-out
    /// — `AccountManager.setupOAuthAccount`, `AccountManager.addIMAPAccount` and
    /// `AccountManager.addICloudAccount` each guard on `acct.id != DemoSeed.demoAccountId`,
    /// and so do all three in `v2final`. (Those three live in the FILE
    /// `AccountManagerSetup.swift`, which is an `extension AccountManager`; there is
    /// no `AccountManagerSetup` type to cite.)
    ///
    /// The COMPLETE class this exclusion closes — every `Account` construction site was
    /// enumerated, not sampled. Only two of the five providers are in the predicate at
    /// all (`.imap`, `.icloud`), so the class is "stored as IMAP-family but not backed
    /// by a live `IMAPProvider`": `setupOAuthAccount` (`.gmail`/`.outlook` — excluded by
    /// provider), `addIMAPAccount` (`.imap`, real IMAP — the intended bounded window),
    /// `addICloudAccount` (`.icloud`, real IMAP — same), `addCalDAVAccount` (`.caldav`,
    /// `calendarOnly` — NOT in the predicate, and it owns no mail folders, so it is
    /// doubly exempt), the two `CalendarSetupView` sites (`.gmail`/`.outlook`,
    /// `calendarOnly` — excluded by provider), `PreviewMocks` (`.imap`, but SwiftUI
    /// previews only; never inserted into the shared database) and `DemoSeed`
    /// (`.imap`, `DemoProvider` — the one real member, closed below).
    ///
    /// A MISSING `Folder` ROW FAILS **CLOSED** for the IMAP family. It is not a benign
    /// unknown: `SyncEngine.fullSync` deletes a vanished folder's row while RETAINING
    /// its headers (there is no foreign key — see the NOTE above its `folder.delete(db)`
    /// in the FILE `SyncEngineFullSync.swift`, which is an `extension SyncEngine`; there
    /// is no `SyncEngineFullSync` type to cite),
    /// so an orphaned header keeps a `folderId`/`folderPath` with no metadata, and a
    /// later re-appearance of the same path re-adopts it under a brand-new row whose
    /// epoch is nil. Admitting a gesture on such a header writes a bare UID from the OLD
    /// epoch into a durable op — precisely C3. Orphans are reachable by real gestures
    /// (the notification path queries `messageHeader` without joining `folder`).
    /// This does NOT brick the two callers that used to justify the fail-open, because
    /// neither reaches this function with a guessed path any more:
    /// `UserLabelMenuView.resolvedFolderPath()` now returns `nil` instead of guessing
    /// `"INBOX"` and its callers abort, and the draft sites only consult this guard when
    /// the op will actually resolve an existing UID (see `queueDraftSave`), which cannot
    /// be true on an account that has no drafts-role row to have synced through.
    ///
    /// Every remaining unknown still fails **OPEN** (returns `false` = admit): a missing
    /// account row and a non-IMAP-family provider.
    nonisolated static func newGestureRefusedForUnknownEpoch(
        accountId: String,
        folderPath: String,
        db: Database
    ) throws -> Bool {
        guard let account = try Account.fetchOne(db, key: accountId) else { return false }
        // Account-side mirror of `staleWindowMode == .uid`. `.icloud` is IMAP.
        guard account.provider == .imap || account.provider == .icloud else { return false }
        // Stored as `.imap`, served by `DemoProvider` — no server, no epoch, ever.
        guard accountId != DemoSeed.demoAccountId else { return false }
        guard let folder = try Folder.fetchOne(db, key: "\(accountId):\(folderPath)") else {
            if DebugModeManager.isLoggingEnabled() {
                print("[Queue] T1.3 refusing new gesture — no folder row for '\(folderPath)' (orphaned header? account \(accountId.prefix(8)))")
            }
            return true
        }
        guard folder.lastKnownUidValidity == nil else { return false }
        if DebugModeManager.isLoggingEnabled() {
            print("[Queue] T1.3 refusing new gesture — folder '\(folderPath)' has no known UIDVALIDITY epoch yet (account \(accountId.prefix(8)))")
        }
        return true
    }

    func markRead(_ messages: [MessageHeader]) async {
        await ensureDurable(messages)

        let affectedFolderIds: Set<String>
        do {
            affectedFolderIds = try await dbPool.write { db in
                let expanded = try Self.expandWithSiblingsByRfc822(messages: messages, db: db)
                let grouped = Dictionary(grouping: expanded) { "\($0.accountId)|\($0.folderPath)" }
                var folderIds: Set<String> = []
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    // T1.3 — refuse before ANY mutation so the local flip and the op
                    // row are precluded together, atomically.
                    if try Self.newGestureRefusedForUnknownEpoch(accountId: accountId, folderPath: folderPath, db: db) { continue }
                    let stableIds = msgs.map(\.stableId)
                    let msgIds = msgs.map(\.id)
                    let folderId = msgs[0].folderId
                    folderIds.insert(folderId)
                    let newlyRead = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
                    try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db, Column("isRead").set(to: true))
                    if newlyRead > 0 {
                        try db.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [newlyRead, folderId])
                    }
                    try PendingOperation(type: .markRead, messageIds: stableIds, accountId: accountId, folderPath: folderPath).insert(db)
                }
                return folderIds
            }
        } catch {
            print("[Queue] ERROR: markRead write failed: \(error)")
            affectedFolderIds = []
        }
        // Clear delivered notifications for messages the user just read
        for msg in messages {
            NSEDataBridge.clearNotification(accountId: msg.accountId, messageId: msg.messageId)
        }
        // Post immediately from actor for responsive sidebar badges, then async recount for accuracy
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        // notifyImmediately: the optimistic write above already decremented
        // folder.unreadCount, so the app-icon badge can update NOW (bg-task
        // protected) — without it, a read→immediate-background leaves the badge
        // stale until the next foreground recount.
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds, notifyImmediately: true) }
        Task { await drainPendingQueue() }
    }

    func markUnread(_ messages: [MessageHeader]) async {
        await ensureDurable(messages)

        let affectedFolderIds: Set<String>
        do {
            affectedFolderIds = try await dbPool.write { db in
                // Mirror of markRead: expand to sibling rows in other folders so an
                // unread mark on the inbox copy of a self-send also flips the Sent copy.
                let expanded = try Self.expandWithSiblingsByRfc822(messages: messages, db: db)
                let grouped = Dictionary(grouping: expanded) { "\($0.accountId)|\($0.folderPath)" }
                var folderIds: Set<String> = []
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    // T1.3 — refuse before ANY mutation (see markRead).
                    if try Self.newGestureRefusedForUnknownEpoch(accountId: accountId, folderPath: folderPath, db: db) { continue }
                    let stableIds = msgs.map(\.stableId)
                    let msgIds = msgs.map(\.id)
                    // Count unread BEFORE marking unread — fresh DB read to compute delta
                    let folderId = msgs[0].folderId
                    folderIds.insert(folderId)
                    let alreadyUnread = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
                    let newlyUnread = msgIds.count - alreadyUnread
                    try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db, Column("isRead").set(to: false))
                    if newlyUnread > 0 {
                        try db.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [newlyUnread, folderId])
                    }
                    try PendingOperation(type: .markUnread, messageIds: stableIds, accountId: accountId, folderPath: folderPath).insert(db)
                }
                return folderIds
            }
        } catch {
            print("[Queue] ERROR: markUnread write failed: \(error)")
            affectedFolderIds = []
        }
        // Post immediately from actor for responsive sidebar badges, then async recount for accuracy
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        // notifyImmediately: optimistic write already adjusted folder.unreadCount,
        // so the badge updates NOW (bg-task protected) and survives a quick background.
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds, notifyImmediately: true) }
        Task { await drainPendingQueue() }
    }

    // MARK: - Unread Count Helpers

    /// Count currently-unread messages from the DB inside an active transaction.
    /// Always re-reads from DB to avoid stale-snapshot races (e.g., markRead + move
    /// firing as concurrent Tasks — the second write must see the first's committed state).
    private nonisolated static func countCurrentlyUnread(msgIds: [String], db: Database) throws -> Int {
        guard !msgIds.isEmpty else { return 0 }
        let placeholders = msgIds.map { _ in "?" }.joined(separator: ",")
        return try Int.fetchOne(db, sql:
            "SELECT COUNT(*) FROM messageHeader WHERE id IN (\(placeholders)) AND isRead = 0",
            arguments: StatementArguments(msgIds)) ?? 0
    }

    /// Expand a list of messages to also include sibling rows that share the same
    /// `(accountId, rfc822MessageId)` but live in a different folder.
    ///
    /// Why: Gmail (and any IMAP server with shared message storage) represents a
    /// "send to self" as one underlying message that lives in both INBOX and Sent.
    /// On iOS we materialize that as two `MessageHeader` rows (keyed by folderId).
    /// When the user marks one row read, the other row should optimistically flip
    /// too — otherwise the Sent copy looks unread until the next delta sync.
    ///
    /// This is also correct for non-Gmail IMAP servers where self-send creates two
    /// independent UIDs: each sibling becomes its own per-folder group, so the
    /// caller's grouping logic emits a separate `PendingOperation` per folder, and
    /// the drain loop issues the appropriate STORE / API call against each.
    ///
    /// Sync acts as the safety net — if a sibling is missed (e.g., null or stale
    /// `rfc822MessageId`), the next delta sync reconciles it.
    nonisolated static func expandWithSiblingsByRfc822(
        messages: [MessageHeader],
        db: Database
    ) throws -> [MessageHeader] {
        // Group rfc822MessageIds by accountId (sibling lookups never cross accounts).
        var lookups: [String: Set<String>] = [:]
        for msg in messages {
            guard let rfc = msg.rfc822MessageId, !rfc.isEmpty else { continue }
            lookups[msg.accountId, default: []].insert(rfc)
        }
        if lookups.isEmpty { return messages }

        var seenIds = Set(messages.map(\.id))
        var result = messages
        for (accountId, rfcSet) in lookups {
            let rfcArray = Array(rfcSet)
            let placeholders = rfcArray.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [accountId]
            args.append(contentsOf: rfcArray)
            let siblings = try MessageHeader.fetchAll(
                db,
                sql: "SELECT * FROM messageHeader WHERE accountId = ? AND rfc822MessageId IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
            for sibling in siblings where !seenIds.contains(sibling.id) {
                result.append(sibling)
                seenIds.insert(sibling.id)
            }
        }
        return result
    }

    // MARK: - Optimistic Move (shared by archive, delete, move)

    /// Core optimistic move: reassigns messages to the destination folder in GRDB,
    /// queues tag removal if leaving inbox, and queues the PendingOperation.
    /// Unread counts are adjusted inline (same transaction) for immediate UI feedback.
    /// UnreadCountManager async recount serves as safety net.
    /// Post-drain sync reconciles UIDs via stale detection + UID remap.
    ///
    /// Gmail-specific: archive destination is the synthetic "__GMAIL_ALL_MAIL__" folder;
    /// the provider-level archive just removes the INBOX label. The optimistic folder
    /// assignment works the same regardless.
    /// Returns the set of affected folder IDs (source + destination) for unread recount.
    @discardableResult
    private nonisolated static func optimisticMoveToFolder(
        msgs: [MessageHeader],
        accountId: String,
        folderPath: String,
        destinationPath: String,
        opType: OperationType,
        removeTagsIfLeavingInbox: Bool,
        db: Database
    ) throws -> Set<String> {
        // Self-move is a no-op — don't create PendingOperation or touch local state.
        // Happens when archiving from All Mail on Gmail (source=dest=__GMAIL_ALL_MAIL__).
        guard folderPath != destinationPath else {
            print("[Queue] Skipping no-op move (source==dest): \(folderPath)")
            return []
        }
        // T1.3 — refuse before ANY mutation. This is the single chokepoint for
        // archive/delete/move from every surface, so the guard covers them all.
        // Scoped to the SOURCE folder: UID resolution for a move happens in the
        // source mailbox (`withActionConnection(folder: source)`), so an unknown
        // DESTINATION epoch is irrelevant and must not refuse the gesture.
        if try Self.newGestureRefusedForUnknownEpoch(accountId: accountId, folderPath: folderPath, db: db) {
            return []
        }
        let stableIds = msgs.map(\.stableId)
        let leavingInbox = msgs[0].isInInbox

        // Optimistic local update — move to destination folder immediately.
        // Message appears in destination right away; post-drain sync reconciles UIDs.
        let destFolderId = "\(accountId):\(destinationPath)"
        let destFolder = try Folder.fetchOne(db, key: destFolderId)
        let destIsInbox = destFolder?.role == .inbox

        let msgIds = msgs.map(\.id)
        // Tags are local-only (ADR-IOS-036) — there is no server-side keyword
        // to remove, so leaving the inbox clears `actionTag` in THIS write
        // (same statement as the folder move) instead of queuing a
        // PendingOperation. `tagSortOrder = 99` mirrors the "no tag" sentinel
        // `sweepStaleActionTags` writes (SyncEngineMaintenance.swift) and the
        // `MessageHeader.tagSortOrder` column default — same value, same
        // meaning, so a message that leaves the inbox and one the periodic
        // sweep later catches converge on identical local state.
        if removeTagsIfLeavingInbox && leavingInbox {
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db,
                Column("folderId").set(to: destFolderId),
                Column("folderPath").set(to: destinationPath),
                Column("isInInbox").set(to: destIsInbox),
                Column("actionTag").set(to: nil as String?),
                Column("tagSortOrder").set(to: 99)
            )
        } else {
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db,
                Column("folderId").set(to: destFolderId),
                Column("folderPath").set(to: destinationPath),
                Column("isInInbox").set(to: destIsInbox)
            )
        }

        // Inline unread count update — fresh DB read, not stale snapshot.
        // Re-read isRead from DB to avoid double-decrement when markRead + move race.
        let unreadMoving = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
        if unreadMoving > 0 {
            let sourceFolderId = msgs[0].folderId
            try db.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadMoving, sourceFolderId])
            try db.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadMoving, destFolderId])
        }

        try PendingOperation(type: opType, messageIds: stableIds, accountId: accountId, folderPath: folderPath, destinationPath: destinationPath).insert(db)
        print("[Queue] Queued \(opType.rawValue) for \(stableIds.count) msgs: \(folderPath) → \(destinationPath) (account: \(accountId))")
        return [msgs[0].folderId, destFolderId]
    }

    func move(_ messages: [MessageHeader], to destinationPath: String) async {
        // Re-resolve fresh headers by id — the single choke point for every
        // surface (swipe, detail view, agent tools, settings bulk-archive).
        // Gesture paths capture `lookupMessage` snapshots at tap time and pass
        // them into queued closures; a second destination-changing gesture on
        // the same message before the first closure commits would otherwise
        // record a PendingOperation against the STALE source folderPath (on
        // IMAP the drain then SEARCHes the wrong folder, uidResolutionFailed,
        // and the destination-check wrongly confirms it stale and drops it).
        // The write acts on row truth at execution time — same doctrine as
        // `performCoordinatedRoleMove`'s in-closure re-resolve, which stays
        // as-is (its double resolve is harmless). Ids that no longer resolve
        // (vanished rows) are dropped from the batch — correct, per
        // `resolveHeadersForAction`'s documented contract.
        let fresh = await resolveHeadersForAction(ids: messages.map(\.id))
        // Observability (audit round 5): resolveHeadersForAction swallows read
        // errors (`try?` → []), so an empty result for a NON-empty input is
        // either all-rows-vanished (legit) or a genuine read failure — in the
        // latter case this drop is the only trace the gesture ever existed.
        // Distinguishing the two needs a throwing resolve variant — recorded
        // as a phase-2 consideration in PLAN_OVERLAY_CALLSITE_AUDIT.md §6.
        if fresh.isEmpty, !messages.isEmpty {
            print("[Queue] WARNING: move(to: \(destinationPath)) resolved 0 of \(messages.count) ids — vanished rows or read failure; nothing queued")
        }
        // Same-folder move is a no-op. Drop those messages here — using FRESH
        // data so a stale caller snapshot whose row already sits at the
        // destination (e.g. an earlier queued move already landed it there)
        // is correctly filtered instead of queuing a pointless/incorrect
        // PendingOperation whose server-side MOVE has provider-dependent
        // effects (e.g. archive-from-Archive).
        let movable = fresh.filter { $0.folderPath != destinationPath }
        guard !movable.isEmpty else { return }
        await ensureDurable(movable)

        let grouped = Dictionary(grouping: movable) { "\($0.accountId)|\($0.folderPath)" }
        let affectedFolderIds: Set<String>
        do {
            affectedFolderIds = try await dbPool.write { db in
                var folderIds: Set<String> = []
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    let moved = try Self.optimisticMoveToFolder(msgs: msgs, accountId: accountId, folderPath: folderPath, destinationPath: destinationPath, opType: .move, removeTagsIfLeavingInbox: true, db: db)
                    folderIds.formUnion(moved)
                }
                return folderIds
            }
        } catch {
            print("[Queue] ERROR: move write failed: \(error)")
            affectedFolderIds = []
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds) }
        Task { await drainPendingQueue() }
    }

    func markFlagged(_ messages: [MessageHeader], flagged: Bool) async {
        await ensureDurable(messages)

        let grouped = Dictionary(grouping: messages) { "\($0.accountId)|\($0.folderPath)" }
        do {
            try await dbPool.write { db in
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    // T1.3 — refuse before ANY mutation (see markRead).
                    if try Self.newGestureRefusedForUnknownEpoch(accountId: accountId, folderPath: folderPath, db: db) { continue }
                    let stableIds = msgs.map(\.stableId)
                    for msg in msgs {
                        try db.execute(sql: "UPDATE messageHeader SET isFlagged = ? WHERE id = ?", arguments: [flagged, msg.id])
                    }
                    let opType: OperationType = flagged ? .markFlagged : .markUnflagged
                    try PendingOperation(type: opType, messageIds: stableIds, accountId: accountId, folderPath: folderPath).insert(db)
                }
            }
        } catch {
            print("[Queue] ERROR: markFlagged write failed: \(error)")
        }
        Task { @MainActor in NotificationCenter.default.post(name: .inboxDataDidChange, object: nil) }
        Task { await drainPendingQueue() }
    }

    /// Drop messages whose CURRENT folder already has `role` — same-role moves
    /// (archive-from-Archive, delete-from-Trash) are no-ops. Accounts can carry
    /// more than one folder per role (e.g. iCloud "Trash" + "Deleted Messages"),
    /// so the path-equality filter in `move()` alone can't catch these: the
    /// canonical `fetchOne` destination may be the OTHER same-role folder.
    private func messagesNotInRole(_ messages: [MessageHeader], role: FolderRole) async -> [MessageHeader] {
        let folderIds = Set(messages.map(\.folderId))
        let roleFolderIds: Set<String> = (try? await dbPool.read { db in
            let rows = try Folder
                .filter(folderIds.contains(Column("id")) && Column("role") == role.rawValue)
                .fetchAll(db)
            return Set(rows.map(\.id))
        }) ?? []
        guard !roleFolderIds.isEmpty else { return messages }
        return messages.filter { !roleFolderIds.contains($0.folderId) }
    }

    func archive(_ messages: [MessageHeader]) async {
        let movable = await messagesNotInRole(messages, role: .archive)
        await moveToRoleFolderPerAccount(movable, role: .archive)
    }

    func delete(_ messages: [MessageHeader]) async {
        guard let first = messages.first else { return }
        AccountManager.logDeleteTrace(accountId: first.accountId, messages: messages, callSite: "AccountManager.delete")
        let movable = await messagesNotInRole(messages, role: .trash)
        await moveToRoleFolderPerAccount(movable, role: .trash)
    }

    /// Resolve the role folder PER ACCOUNT and move each account's messages to
    /// ITS OWN path. The previous implementation resolved the path from only
    /// `movable.first`'s account and applied it to every account in the batch —
    /// a cross-account batch (agent tools and the notification router accept
    /// ids spanning accounts) mis-filed every non-first account's messages
    /// into a folder path that doesn't exist for that account: the row got an
    /// optimistic folderId no real folder backs (message vanishes from that
    /// account's views until the next sync heals it) and a PendingOperation
    /// whose destinationPath is meaningless to that provider (self-heal drop —
    /// the archive/delete never happens server-side). Follow-up-session audit
    /// round 6; pre-existing, reachable via EmailArchiveTool/EmailDeleteTool.
    private func moveToRoleFolderPerAccount(_ movable: [MessageHeader], role: FolderRole) async {
        guard !movable.isEmpty else { return }
        let byAccount = Dictionary(grouping: movable, by: \.accountId)
        for (accountId, accountMessages) in byAccount {
            let path: String? = try? await dbPool.read { db in
                try Folder.filter(Column("accountId") == accountId && Column("role") == role.rawValue)
                    .fetchOne(db)?.path
            }
            guard let path else {
                print("[Queue] ERROR: no \(role.rawValue) folder found for account \(accountId) — \(accountMessages.count) message(s) skipped")
                continue
            }
            await move(accountMessages, to: path)
        }
    }

    // MARK: - Coordinated Tool Actions (agent tools, ADR-IOS-057 vicinity)

    /// Archive/delete via the same overlay + FIFO write-queue lifecycle as gesture
    /// actions, for agent tools (`EmailArchiveTool`/`EmailDeleteTool`). Tools resolve
    /// headers BEFORE an unbounded user-confirmation wait (for the confirmation card
    /// display) — that snapshot can go stale while the user waits, so a later
    /// user move/delete must not be silently reversed by an action that blindly
    /// trusts it. This helper takes ids (never a pre-resolved header) and
    /// re-resolves fresh headers INSIDE the queued closure, so the write acts on
    /// row truth at EXECUTION time — and participates in the same optimistic
    /// overlay + FIFO ordering as gesture-driven archive/delete. Awaits durable
    /// completion (the local GRDB write + `PendingOperation` insert have landed)
    /// before returning.
    ///
    /// Retain/release audit: one `retainOverlayEntry` per actionable id below,
    /// BEFORE its `registerMutation` call (ADR-IOS-057 ordering — the overlay
    /// entry must not be removable by a sibling op's release before this id's
    /// own retain lands). The queued closure releases every retained id on
    /// every exit: ids dropped by the closure's own fresh re-resolve (vanished
    /// row, or already moved into the role folder by an earlier queued op) are
    /// released as soon as the drop is detected; the remaining (fresh) ids are
    /// released once, after the `archive()`/`delete()` write completes (or is
    /// skipped on the defensive unsupported-role branch, unreachable in
    /// practice — the guard at the top of this function only lets `.archive`/
    /// `.trash` reach the retain loop at all). There is exactly one path
    /// through the closure body — no early returns — so the two release loops
    /// together cover every id this call ever retained.
    func performCoordinatedRoleMove(ids: [String], role: FolderRole) async {
        guard !ids.isEmpty else { return }
        guard role == .archive || role == .trash else {
            BackgroundSyncLogger.logInbox("[AccountManager] performCoordinatedRoleMove — unsupported role \(role.rawValue), no-op")
            return
        }

        // Pre-resolve fresh headers to drop ids that no longer exist or are
        // already in the target role folder, and to look up each account's
        // destination folder for the overlay's display-only folderId. This
        // snapshot is intentionally re-taken again INSIDE the queued closure
        // below — the actual write never trusts this one.
        let preResolved = await resolveHeadersForAction(ids: ids)
        let movable = await messagesNotInRole(preResolved, role: role)
        guard !movable.isEmpty else {
            // Observability (audit round 5): callers (agent tools, notification
            // router) report success unconditionally after this await — a silent
            // return here on a read failure (resolveHeadersForAction swallows
            // errors to []) would leave no trace anywhere. Vanished/already-in-
            // role ids are legit no-ops; the log is the only failure correlate.
            print("[Queue] performCoordinatedRoleMove(\(role.rawValue)): 0 of \(ids.count) ids actionable after resolve/role filter — nothing to do")
            return
        }

        let accountIds = Set(movable.map(\.accountId))
        let destFolderIdByAccount: [String: String] = (try? await dbPool.read { db -> [String: String] in
            var result: [String: String] = [:]
            for accountId in accountIds {
                if let folder = try Folder
                    .filter(Column("accountId") == accountId && Column("role") == role.rawValue)
                    .fetchOne(db) {
                    result[accountId] = folder.id
                }
            }
            return result
        }) ?? [:]

        // Skip ids whose account has no folder for this role — mirrors
        // archive()/delete()'s own "no archive/trash folder for account" skip
        // (including its ERROR log convention — audit round 5).
        let actionable = movable.filter { destFolderIdByAccount[$0.accountId] != nil }
        guard !actionable.isEmpty else {
            print("[Queue] ERROR: performCoordinatedRoleMove(\(role.rawValue)) — no \(role.rawValue) folder resolved for account(s) \(accountIds.sorted().joined(separator: ",")); \(movable.count) message(s) skipped")
            return
        }
        let actionableIds = Set(actionable.map(\.id))

        for msg in actionable {
            guard let destFolderId = destFolderIdByAccount[msg.accountId] else { continue }
            retainOverlayEntry(id: msg.id)
            registerMutation(id: msg.id, mutation: PendingMutation(
                folderId: destFolderId,
                // Tag clears locally the moment the message LEAVES the inbox —
                // mirrors the DB-side clear semantics (F6): archive/trash
                // destinations are never the inbox, so for this helper's two
                // supported roles "isInInbox on the pre-resolved snapshot"
                // IS "leaving the inbox".
                actionTag: msg.isInInbox ? .some(nil) : nil
            ))
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            enqueueWrite {
                // Re-resolve INSIDE the queued closure: acts on row truth at
                // EXECUTION time, not the confirmation-time snapshot above —
                // the staleness bug this helper exists to close.
                let fresh = await self.resolveHeadersForAction(ids: Array(actionableIds))
                let freshMovable = await self.messagesNotInRole(fresh, role: role)
                let freshIds = Set(freshMovable.map(\.id))

                // Ids dropped by the fresh resolve (vanished row, or already
                // in the role folder — e.g. an earlier queued op moved it
                // there first) get no write; release their retain now.
                for id in actionableIds.subtracting(freshIds) {
                    self.releaseOverlayEntry(id: id)
                }

                switch role {
                case .archive:
                    await self.archive(freshMovable)
                case .trash:
                    await self.delete(freshMovable)
                default:
                    // Unreachable — the guard at the top of this function
                    // only lets .archive/.trash reach the retain loop.
                    BackgroundSyncLogger.logInbox("[AccountManager] performCoordinatedRoleMove — unexpected role \(role.rawValue) reached queued closure")
                }

                for id in freshIds {
                    self.releaseOverlayEntry(id: id)
                }
                cont.resume()
            }
        }
    }

    /// Diagnostic-only: log the trash-folder lookup result and the message(s) being deleted
    /// so we can correlate a delete action with the destinationPath that ends up on the
    /// PendingOperation. Includes every role=.trash candidate to surface duplicate or
    /// cross-account contamination.
    /// `callSite` identifies the entry point (multiple code paths queue a delete).
    static nonisolated func logDeleteTrace(accountId: String, messages: [MessageHeader], callSite: String) {
        let allTrash: [Folder] = (try? AppDatabase.dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.trash.rawValue)
                .fetchAll(db)
        }) ?? []
        let trashFolder = allTrash.first
        print("[DeleteTrace] \(callSite) — accountId=\(accountId) msgCount=\(messages.count) resolvedTrash=\(trashFolder.map { "id=\($0.id) name=\($0.name) path=\($0.path) role=\($0.role.rawValue)" } ?? "<nil>") trashCandidates=\(allTrash.count)")
        for f in allTrash {
            print("[DeleteTrace] trashCandidate: id=\(f.id) name=\(f.name) path=\(f.path)")
        }
        for m in messages {
            print("[DeleteTrace] msg: id=\(m.id) folderPath=\(m.folderPath) accountId=\(m.accountId) messageId=\(m.messageId) rfc822=\(m.rfc822MessageId ?? "<nil>") stableId=\(m.stableId)")
        }
    }

    // MARK: - Search

    func search(query: String, account: Account, folder: String, after: Date? = nil, before: Date? = nil, from: String? = nil, to: String? = nil) async throws -> [MessageHeaderInfo] {
        guard let queue = workQueues[account.id] else { throw ProviderError.notConnected }
        return try await queue.execute(priority: .userAction) {
            try await queue.provider.search(query: query, folder: folder, after: after, before: before, from: from, to: to)
        }
    }

    // MARK: - Undo Support

    /// Unified undo for archive, delete, and move. Cancels queued ops if still pending,
    /// otherwise queues a move-back. Restores messages to original folder and adjusts
    /// unread counts on both source (current) and destination (original) folders.
    func undoDestructiveAction(
        _ messages: [MessageHeader],
        accountId: String,
        originalOpType: OperationType,
        fromFolderPath: String,
        toFolderPath: String,
        toFolderId: String
    ) async {
        let ids = messages.map(\.messageId)
        let idsSet = Set(ids)
        let stableIdsSet = Set(messages.map(\.stableId))
        let label = originalOpType.rawValue
        print("[UndoStack] undo\(label) ENTER — msgIds=\(ids) from=\(fromFolderPath) restoreTo=\(toFolderPath) restoreFolderId=\(toFolderId)")
        do {
            try await dbPool.write { db in
                let queuedOps = try PendingOperation
                    .filter(Column("accountId") == accountId)
                    .filter(Column("status") == PendingStatus.queued.rawValue)
                    .fetchAll(db)
                print("[UndoStack] undo\(label) — found \(queuedOps.count) queued ops for account")
                for op in queuedOps {
                    print("[UndoStack] undo\(label) — queued op: id=\(op.id.prefix(8)) type=\(op.type.rawValue) msgIds=\(op.messageIds) status=\(op.status)")
                }

                let inFlightOps = try PendingOperation
                    .filter(Column("accountId") == accountId)
                    .filter(Column("status") == PendingStatus.inFlight.rawValue)
                    .fetchAll(db)
                if !inFlightOps.isEmpty {
                    print("[UndoStack] undo\(label) — WARNING: \(inFlightOps.count) inFlight ops:")
                    for op in inFlightOps {
                        print("[UndoStack]   inFlight: id=\(op.id.prefix(8)) type=\(op.type.rawValue) msgIds=\(op.messageIds)")
                    }
                }

                var cancelledOriginal = false
                for op in queuedOps {
                    let opMsgIds = Set(op.messageIds)
                    // Match by both numeric UIDs and stable IDs (rfc822MessageId)
                    // since pending ops may contain either format.
                    if (!opMsgIds.isDisjoint(with: idsSet) || !opMsgIds.isDisjoint(with: stableIdsSet)) &&
                       (op.type == originalOpType || op.type == .removeTag) {
                        var cancelled = op
                        cancelled.status = PendingStatus.cancelled.rawValue
                        try cancelled.save(db)
                        print("[UndoStack] undo\(label) — CANCELLED op id=\(op.id.prefix(8)) type=\(op.type.rawValue)")
                        if op.type == originalOpType { cancelledOriginal = true }
                    }
                }

                // Restore messages — use save() (upsert) in case drain cleanup already deleted the row.
                // The snapshot's folderPath/isInInbox are from the original source folder — save() restores all columns.
                for msg in messages {
                    let existing = try MessageHeader.fetchOne(db, key: msg.id)
                    print("[UndoStack] undo\(label) — restore msg id=\(msg.id) existing=\(existing == nil ? "nil(deleted)" : "folderId=\(existing!.folderId)") → setting folderId=\(toFolderId)")
                    var restored = msg
                    restored.folderId = toFolderId
                    try restored.save(db)
                }

                // Inline unread count update — fresh DB read after restore.
                // Messages were just restored via save(db) above, so re-read their
                // current isRead state from DB rather than trusting the caller snapshot.
                let restoredMsgIds = messages.map(\.id)
                let unreadRestored = try Self.countCurrentlyUnread(msgIds: restoredMsgIds, db: db)
                if unreadRestored > 0 {
                    let fromFolderId = "\(accountId):\(fromFolderPath)"
                    if !fromFolderPath.isEmpty {
                        try db.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadRestored, fromFolderId])
                    }
                    try db.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadRestored, toFolderId])
                }

                if !cancelledOriginal {
                    // IMAP MOVE changes UIDs — use rfc822MessageId for move-back so resolveUID
                    // does a Message-ID header search in the destination folder (finds correct UID).
                    // Gmail/Exchange use stable IDs that don't change on move.
                    let account = try Account.fetchOne(db, key: accountId)
                    let moveBackIds: [String]
                    if account?.provider == .imap || account?.provider == .icloud {
                        moveBackIds = messages.compactMap(\.rfc822MessageId)
                        if moveBackIds.count != messages.count {
                            print("[UndoStack] undo\(label) — WARNING: \(messages.count - moveBackIds.count) messages missing rfc822MessageId for move-back")
                        }
                    } else {
                        moveBackIds = ids
                    }
                    if !moveBackIds.isEmpty {
                        let moveBack = PendingOperation(type: .move, messageIds: moveBackIds, accountId: accountId, folderPath: fromFolderPath, destinationPath: toFolderPath)
                        try moveBack.insert(db)
                        print("[UndoStack] undo\(label) — original already executed/inFlight, queued MOVE-BACK id=\(moveBack.id.prefix(8)) from=\(fromFolderPath) to=\(toFolderPath) moveBackIds=\(moveBackIds)")
                    } else {
                        print("[UndoStack] undo\(label) — ERROR: no valid IDs for move-back (missing rfc822MessageId)")
                    }
                } else {
                    print("[UndoStack] undo\(label) — CANCELLED original \(label) op, no move-back needed")
                }
            }
        } catch {
            print("[UndoStack] ERROR: undo\(label) write failed: \(error)")
        }
        // Undo-restored messages are protected by their PendingOp(move-back) in the sync engine.
        // No separate undoProtectedIds needed — the pending-op check handles it.
        let fromFolderId = "\(accountId):\(fromFolderPath)"
        var affectedFolderIds: Set<String> = [toFolderId]
        if !fromFolderPath.isEmpty { affectedFolderIds.insert(fromFolderId) }
        // Post immediately from actor for responsive sidebar badges, then async recount for accuracy
        Task { @MainActor in NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil) }
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds) }
        Task {
            print("[UndoStack] undo\(label) — triggering drainPendingQueue (isDraining=\(isDraining))")
            await drainPendingQueue()
        }
    }

    // MARK: - Draft Queue (persistent save/delete)

    /// Look up the Drafts folder path for an account.
    func draftsFolderPath(accountId: String) async throws -> String {
        try await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.drafts.rawValue)
                .fetchOne(db)?.path ?? "Drafts"
        }
    }

    /// Queue a draft save to the server's Drafts folder via PendingOperation.
    /// Creates/updates an optimistic MessageHeader in the Drafts folder so the draft
    /// appears immediately in the UI (before IMAP APPEND completes).
    func queueDraftSave(draftId: String, accountId: String) async {
        do {
            let folderPath = try await draftsFolderPath(accountId: accountId)

            // Write transaction returns FTS data for post-transaction indexing.
            let ftsInfo: (record: FTSHeaderRecord, bodyText: String)? = try await dbPool.write { db -> (FTSHeaderRecord, String)? in
                // Optimistic MessageHeader — draft appears in Drafts folder immediately.
                // Uses rfc822MessageId for dedup when sync brings in the real IMAP UID.
                guard let draft = try Draft.fetchOne(db, key: draftId) else {
                    print("[Queue] WARNING: Draft \(draftId) not found in DB, skipping queueDraftSave")
                    return nil
                }

                // T1.3 — a draft save IS epoch-sensitive whenever it will resolve an
                // EXISTING UID. The original census exempted this site wholesale as
                // "APPEND-shaped, resolves no existing UID"; that is wrong for the
                // normal case. `IMAPProvider.saveDraft` runs a delete-then-APPEND, and
                // its `existingDraftId` branch does `store(flags: [.deleted])` +
                // `expunge()` on `MessageIdentifierSet<UID>(UID(uid))` — a LITERAL UID,
                // both calls `try?`-swallowed, so a wrong-message expunge is silent.
                // `saveDraft` itself returns `DraftSaveResult(serverId: String(uid))`,
                // so `Draft.serverDraftId` IS the IMAP UID and the numeric branch is the
                // normal path for every save after the first. Byte-for-byte the same
                // shape already acknowledged as a C3 vector for `queueDraftDelete`.
                //
                // Classified by what the provider DOES with the id, not by the op's
                // name — the three cases are distinct and only one is a hazard:
                //   • `serverDraftId == nil`  → pure APPEND, no id to resolve → admit.
                //     (This is the ONLY case the old census description actually fit.)
                //   • non-numeric             → Message-ID SEARCH, epoch-IMMUNE → admit.
                //   • numeric                 → literal UID STORE+EXPUNGE → GUARD.
                // Scoping to the numeric case is also what makes the missing-`Folder`-row
                // refusal safe here: `draftsFolderPath` falls back to a guessed "Drafts"
                // only when the account has no drafts-role row, and such an account can
                // never have produced a numeric `serverDraftId` in the first place — so
                // the guessed path never reaches the guard, and draft saving cannot brick.
                if let existingId = draft.serverDraftId, UInt32(existingId) != nil,
                   try Self.newGestureRefusedForUnknownEpoch(accountId: accountId, folderPath: folderPath, db: db) {
                    return nil
                }

                let folderId = "\(accountId):\(folderPath)"
                var rfc822 = draft.rfc822MessageId

                // Adopt the server-synced header if present. This catches the
                // ServerDraftCompose case: a draft was created by server sync
                // with its own rfc822MessageId (from the IMAP/Gmail header)
                // and a server-assigned messageId. Draft.rfc822MessageId on
                // the matched local Draft row is nil, so a naive
                // "generate new rfc822 + create optimistic header" path
                // produces an orphan next to the server-synced header. The
                // sync stale-check then deletes our optimistic orphan, the
                // list reverts to the pre-edit server-synced header, and the
                // user sees stale content.
                //
                // Resolution: if the draft has serverDraftId, find the
                // existing server-synced MessageHeader by its PK and adopt
                // its rfc822MessageId for the Draft row. The update branch
                // below then finds that same header and updates it in place.
                if rfc822 == nil, let sid = draft.serverDraftId {
                    let serverHeaderId = "\(accountId):\(folderPath):\(sid)"
                    if let serverHeader = try MessageHeader.fetchOne(db, key: serverHeaderId),
                       let serverRfc822 = serverHeader.rfc822MessageId,
                       !serverRfc822.isEmpty {
                        rfc822 = serverRfc822
                        try db.execute(
                            sql: "UPDATE draft SET rfc822MessageId = ? WHERE id = ?",
                            arguments: [rfc822, draftId]
                        )
                        print("[Queue] queueDraftSave: adopted rfc822 from server header \(serverHeaderId) → \(serverRfc822)")
                    } else {
                        print("[Queue] queueDraftSave: no server header found for serverDraftId=\(sid) — will generate fresh rfc822")
                    }
                }

                // Generate stable rfc822MessageId if still not assigned (fresh local draft).
                if rfc822 == nil {
                    let domain = accountId.contains("@") ? String(accountId.split(separator: "@").last ?? "tabmail.local") : "tabmail.local"
                    rfc822 = "draft-\(UUID().uuidString)@\(domain)"
                    // Persist to Draft table so pushDraftToServer reuses it
                    try db.execute(sql: "UPDATE draft SET rfc822MessageId = ? WHERE id = ?", arguments: [rfc822, draftId])
                }
                // Placeholder messageId — will be replaced by real IMAP UID via rfc822MessageId dedup in sync
                let placeholderMsgId = "draft-\(draftId)"
                let headerId = "\(accountId):\(folderPath):\(placeholderMsgId)"
                let senderAccount = try Account.fetchOne(db, key: accountId)
                let senderEmail = senderAccount?.emailAddress ?? accountId
                let senderDisplayName = senderAccount?.displayName ?? senderEmail
                let snippet = EmailFilter.snippetFromPlainText(draft.body)
                let dateMs = Int64(draft.updatedAt * 1000)

                var capturedHeaderId: String
                var capturedMessageId: String

                // Lookup strategy:
                //   1. By rfc822MessageId — the primary dedup key across sync/optimistic paths.
                //   2. By serverDraftId (constructed PK) — catches the ServerDraftCompose
                //      case where a local Draft row exists but its rfc822MessageId wasn't
                //      adopted above (e.g. server header was deleted but Draft persisted).
                var lookedUp = try MessageHeader
                    .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                    .fetchOne(db)
                if lookedUp == nil, let sid = draft.serverDraftId {
                    lookedUp = try MessageHeader.fetchOne(
                        db, key: "\(accountId):\(folderPath):\(sid)"
                    )
                }
                if var existing = lookedUp {
                    // Update existing header (either optimistic or server-synced) in place —
                    // this is the snippet/subject/recipient refresh path. No orphan created.
                    print("[Queue] queueDraftSave: updating existing header id=\(existing.id) msgId=\(existing.messageId) rfc822=\(existing.rfc822MessageId ?? "nil") → newSnippet=\(String(snippet.prefix(60)))")
                    existing.subject = draft.subject
                    existing.to = draft.toArray.joined(separator: ", ")
                    existing.snippet = snippet
                    existing.date = Date(timeIntervalSince1970: draft.updatedAt)
                    // Ensure rfc822MessageId is populated so subsequent syncs can dedup.
                    if existing.rfc822MessageId == nil || existing.rfc822MessageId?.isEmpty == true {
                        existing.rfc822MessageId = rfc822
                    }
                    try existing.update(db)
                    // Update body so draft content is viewable immediately
                    let htmlBody = MessageBody.plainTextToHTML(draft.body)
                    let body = MessageBody(headerId: existing.id, htmlContent: htmlBody)
                    try body.save(db)
                    capturedHeaderId = existing.id
                    capturedMessageId = existing.messageId
                } else {
                    print("[Queue] queueDraftSave: no existing header found — creating optimistic with placeholder=\(placeholderMsgId) rfc822=\(rfc822 ?? "nil") serverDraftId=\(draft.serverDraftId ?? "nil")")
                    var header = MessageHeader(
                        messageId: placeholderMsgId,
                        subject: draft.subject,
                        from: senderDisplayName,
                        fromAddress: senderEmail,
                        to: draft.toArray.joined(separator: ", "),
                        date: Date(timeIntervalSince1970: draft.updatedAt),
                        snippet: snippet,
                        folderId: folderId,
                        accountId: accountId,
                        folderPath: folderPath,
                        isInInbox: false
                    )
                    header.rfc822MessageId = rfc822
                    header.cc = draft.ccArray.joined(separator: ", ")
                    header.bcc = draft.bccArray.joined(separator: ", ")
                    header.isRead = true // Drafts are always read
                    try header.insert(db)

                    // Also create MessageBody so draft content is viewable
                    let htmlBody = MessageBody.plainTextToHTML(draft.body)
                    let body = MessageBody(headerId: headerId, htmlContent: htmlBody)
                    try body.save(db)
                    capturedHeaderId = headerId
                    capturedMessageId = placeholderMsgId
                }

                // Include both draftId (for drain execution) and placeholder messageId
                // (for pendingAllIds protection). The stale check uses pendingAllIds to
                // protect optimistic headers from deletion while the push is pending.
                // This is critical for offline support — the drain can't run until
                // back online, but sync might try to clean up the placeholder.
                let opPlaceholder = "draft-\(draftId)"
                var opMsgIds = [draftId, opPlaceholder]
                // Also include rfc822MessageId for rfc822-based protection matching
                // (rfc822 is guaranteed non-nil here — either from draft or freshly generated)
                if let rfc822Id = rfc822 {
                    opMsgIds.append(rfc822Id)
                }
                try PendingOperation(
                    type: .saveDraft,
                    messageIds: opMsgIds,
                    accountId: accountId,
                    folderPath: folderPath
                ).insert(db)

                return (FTSHeaderRecord(
                    headerId: capturedHeaderId,
                    messageId: capturedMessageId,
                    subject: draft.subject,
                    from: "\(senderDisplayName) <\(senderEmail)>",
                    to: draft.toArray.joined(separator: ", "),
                    cc: draft.ccArray.joined(separator: ", "),
                    bcc: draft.bccArray.joined(separator: ", "),
                    dateMs: dateMs,
                    folderId: folderId
                ), draft.body)
            }

            // FTS indexing + headerComplete — runs after GRDB write succeeds.
            // Each step is independently caught so a failure in one doesn't block the others.
            // Priority: headerComplete=1 (visibility) > FTS body (searchability) > FTS header.
            if let ftsInfo {
                do {
                    _ = try await SearchIndex.shared.indexHeaders([ftsInfo.record])
                    if !ftsInfo.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try await SearchIndex.shared.updateBodies([(headerId: ftsInfo.record.headerId, body: ftsInfo.bodyText)])
                    }
                } catch {
                    print("[Queue] WARNING: FTS indexing failed for draft \(ftsInfo.record.headerId): \(error)")
                }
                // Always set headerComplete=1 so the draft appears in folder queries,
                // regardless of whether FTS succeeded. Caught separately so notification
                // still fires even if this write fails (draft stays at headerComplete=0
                // but user gets the reload signal).
                do {
                    try await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                            arguments: [ftsInfo.record.headerId]
                        )
                    }
                } catch {
                    print("[Queue] WARNING: headerComplete write failed for draft \(ftsInfo.record.headerId): \(error)")
                }
            }

            // Always post reload notification — even if FTS or headerComplete failed,
            // the GRDB header + body exist and may become visible on retry.
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        } catch {
            print("[Queue] ERROR: queueDraftSave failed: \(error)")
        }
        Task { await drainPendingQueue() }
    }

    /// Queue a draft delete from the server's Drafts folder via PendingOperation.
    /// Optimistically removes the MessageHeader from the Drafts folder immediately.
    /// Requires the serverDraftId (IMAP UID / Gmail ID) from the Draft record.
    /// Pass rfc822MessageId to also remove optimistic headers (which use placeholder messageIds).
    func queueDraftDelete(serverDraftId: String, accountId: String, rfc822MessageId: String? = nil) async {
        do {
            let folderPath = try await draftsFolderPath(accountId: accountId)
            try await dbPool.write { db in
                // T1.3 — same classification as `queueDraftSave`, by what the provider
                // DOES with the id rather than by the op's name. `.deleteDraft` drains to
                // `IMAPProvider.deleteDraft`, which calls `resolveUID(draftId)`: a numeric
                // id short-circuits straight to `UIDSet(UID(uidValue))` with no SEARCH, so
                // the following `store(flags: [.deleted])` + `expunge()` is addressed by a
                // LITERAL UID and mutates whatever occupies it in the CURRENT epoch. A
                // non-numeric id goes to `searchByMessageId` and is epoch-immune.
                // This was already acknowledged as a residual C3 vector; it is now guarded.
                if UInt32(serverDraftId) != nil,
                   try Self.newGestureRefusedForUnknownEpoch(accountId: accountId, folderPath: folderPath, db: db) {
                    return
                }
                // Optimistic removal — draft disappears from UI immediately
                let folderId = "\(accountId):\(folderPath)"
                // Remove by server UID (synced header)
                let serverId = "\(accountId):\(folderPath):\(serverDraftId)"
                if try MessageHeader.deleteOne(db, key: serverId) {
                    _ = try? MessageBody.deleteOne(db, key: serverId)
                }
                // Also remove optimistic header by rfc822MessageId (placeholder UID)
                if let rfc822 = rfc822MessageId {
                    let optimistic = try MessageHeader
                        .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                        .fetchAll(db)
                    for header in optimistic {
                        _ = try? MessageBody.deleteOne(db, key: header.id)
                        try header.delete(db)
                    }
                }

                // Include rfc822MessageId in the PendingOperation messageIds so
                // sync protection (pendingAllIds) prevents re-inserting a stale draft
                // from the server during the brief window before .deleteDraft drains.
                // Matches the protection pattern in queueDraftSave.
                var opMsgIds = [serverDraftId]
                if let rfc822 = rfc822MessageId {
                    opMsgIds.append(rfc822)
                }
                try PendingOperation(
                    type: .deleteDraft,
                    messageIds: opMsgIds,
                    accountId: accountId,
                    folderPath: folderPath
                ).insert(db)
            }
            // Refresh UI so the optimistic removal is visible immediately.
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        } catch {
            print("[Queue] ERROR: queueDraftDelete failed: \(error)")
        }
        Task { await drainPendingQueue() }
    }

    /// Remove optimistic draft MessageHeader (no server op needed — draft was never pushed).
    func removeOptimisticDraftHeader(accountId: String, rfc822MessageId: String) async {
        do {
            let folderPath = try await draftsFolderPath(accountId: accountId)
            let folderId = "\(accountId):\(folderPath)"
            try await dbPool.write { db in
                let headers = try MessageHeader
                    .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822MessageId)
                    .fetchAll(db)
                for header in headers {
                    _ = try? MessageBody.deleteOne(db, key: header.id)
                    try header.delete(db)
                }
            }
        } catch {
            print("[Queue] ERROR: removeOptimisticDraftHeader failed: \(error)")
        }
    }

}
