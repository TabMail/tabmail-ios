/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// PLAN_INBOX_UNIFIED_READ.md §5A.3 — thin shell integration tests for
/// `InboxListReader` against a REAL temp-file GRDB pool (no mocks — the
/// no-mock import-contract lesson). Only what the pure scenario tests can't
/// see: the D/P/resolution gather SQL, the fetch/fetchSync parity, and the
/// §5A.3 contract-parity check between the scenario harness's pure identity
/// mirror (`SimIdentityMirror`) and the real `DurableIdentityLookup.find`.
///
/// `.serialized`: tests swap `AppDatabase.shared` and touch the
/// `AccountManager.shared` overlay + `NSEDataBridge.latestStagedRows`
/// process-wide globals (mirrors `InboxListBehaviorPinningTests`).
@Suite("InboxListReader integration (PLAN_INBOX_UNIFIED_READ §5A.3)", .serialized)
@MainActor
struct InboxListReaderIntegrationTests {

    // MARK: - Harness (mirrors InboxListBehaviorPinningTests)

    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
            var acc2 = Account(emailAddress: "other@example.com", displayName: "Other", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
        }
        return (pool, inbox, archive, dir, previous)
    }

    private func makeStagedRow(
        accountId: String = "acc1",
        folderPath: String = "INBOX",
        messageId: String,
        rfc822MessageId: String? = nil,
        date: Date = Date(),
        isRead: Bool = false,
        actionTag: String? = nil,
        summaryBlurb: String? = nil
    ) -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: messageId,
            rfc822MessageId: rfc822MessageId, threadId: nil, inReplyTo: nil, references: [],
            subject: "Subj \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: date,
            isRead: isRead, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: actionTag, summaryBlurb: summaryBlurb
        )
    }

    private func makeDurableHeader(
        folder: Folder,
        messageId: String,
        rfc822MessageId: String? = nil,
        date: Date = Date(),
        isRead: Bool = false,
        headerComplete: Bool = true,
        actionTag: ActionTag? = nil,
        summaryBlurb: String? = nil,
        isInInbox: Bool = true
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: date, snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: isInInbox
        )
        h.rfc822MessageId = rfc822MessageId
        h.headerComplete = headerComplete
        h.isRead = isRead
        h.actionTag = actionTag
        h.tagSortOrder = actionTag?.sortOrder ?? 99
        h.summaryBlurb = summaryBlurb
        return h
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    private func resetStagedGlobal() {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
    }

    private func query(
        folders: [Folder],
        filterUnread: Bool = false,
        filterLabelIds: Set<String> = [],
        mode: InboxMode = .normal,
        targetCount: Int = 50,
        beforeDate: Date? = nil
    ) -> InboxListQuery {
        InboxListQuery(
            displayedFolderIds: Set(folders.map(\.id)), filterUnread: filterUnread,
            filterLabelIds: filterLabelIds, mode: mode, targetCount: targetCount, beforeDate: beforeDate
        )
    }

    // MARK: - (a) staged-only row appears via BOTH fetch variants

    @Test("a staged-only row (no durable header anywhere) appears via fetch AND fetchSync")
    func stagedOnlyRowAppearsInBothVariants() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let row = makeStagedRow(messageId: "m-staged-only", actionTag: ActionTag.reply.rawValue)
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        let q = query(folders: [inbox])

        let asyncResult = await InboxListReader.fetch(folders: [inbox], query: q)
        #expect(asyncResult.count == 1)
        #expect(asyncResult.first?.messageId == "m-staged-only")
        #expect(asyncResult.first?.actionTag == .reply)

        let syncResult = InboxListReader.fetchSync(folders: [inbox], query: q)
        #expect(syncResult.count == 1)
        #expect(syncResult.first?.messageId == "m-staged-only")
        #expect(syncResult == asyncResult, "fetch and fetchSync diverged for the same inputs")
    }

    // MARK: - (b) durable-only rows appear, sorted and limited

    @Test("durable-only rows appear sorted by date desc and trimmed to targetCount, via both variants")
    func durableRowsSortedAndLimited() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let now = Date()
        let headers = (0..<5).map { i in
            makeDurableHeader(
                folder: inbox, messageId: "m-\(i)",
                date: now.addingTimeInterval(-60 * Double(i))
            )
        }
        try await pool.writeWithoutTransaction { db in
            for h in headers { try h.insert(db) }
        }
        let q = query(folders: [inbox], targetCount: 3)

        let asyncResult = await InboxListReader.fetch(folders: [inbox], query: q)
        #expect(asyncResult.count == 3)
        guard asyncResult.count == 3 else { return }
        #expect(asyncResult[0].messageId == "m-0")
        #expect(asyncResult[1].messageId == "m-1")
        #expect(asyncResult[2].messageId == "m-2")

        let syncResult = InboxListReader.fetchSync(folders: [inbox], query: q)
        #expect(syncResult == asyncResult, "fetch and fetchSync diverged for the same inputs")
    }

    // MARK: - (c) UID-remapped archived durable suppresses the staged INBOX row (485a4d1, read-side)

    @Test("a UID-remapped durable copy in Archive (different messageId, same rfc822) suppresses the staged INBOX row via BOTH variants")
    func uidRemappedArchivedDurableSuppressesStagedRow() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // Durable copy: server-side MOVE remapped UID 101 → 9101, Archive.
        let remapped = makeDurableHeader(
            folder: archive, messageId: "9101",
            rfc822MessageId: "rfc-remap@example.com", isInInbox: false
        )
        try await pool.writeWithoutTransaction { db in try remapped.insert(db) }

        // Stale staged row under push-time truth: OLD uid, INBOX folder.
        let staged = makeStagedRow(messageId: "101", rfc822MessageId: "rfc-remap@example.com")
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        let q = query(folders: [inbox])

        let asyncResult = await InboxListReader.fetch(folders: [inbox], query: q)
        #expect(asyncResult.isEmpty, "stale staged row resurrected despite the rfc822-linked archived durable copy (async)")

        let syncResult = InboxListReader.fetchSync(folders: [inbox], query: q)
        #expect(syncResult.isEmpty, "stale staged row resurrected despite the rfc822-linked archived durable copy (sync)")
    }

    // MARK: - (d) P-step: archived durable + overlay folderId→inbox (the undo shape)

    @Test("P-step: an archived durable row with an overlay folderId back into the inbox appears in the result — the undo shape Phase 3 turns on")
    func pinnedStepRestoresUndoneRow() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let archived = makeDurableHeader(folder: archive, messageId: "m-undo", isInInbox: false)
        try await pool.writeWithoutTransaction { db in try archived.insert(db) }

        // Mirror UndoService.undo()'s .move case: overlay registered, DB
        // restore write still deferred (header physically in Archive).
        AccountManager.shared.registerMutation(id: archived.id, mutation: .init(
            folderId: inbox.id, folderPath: inbox.path, isInInbox: true
        ))
        let q = query(folders: [inbox])

        let asyncResult = await InboxListReader.fetch(folders: [inbox], query: q)
        #expect(asyncResult.count == 1, "undone row missing from fetch — P-step did not pin it")
        #expect(asyncResult.first?.id == archived.id)
        #expect(asyncResult.first?.isInInbox == true, "overlay isInInbox not applied to the pinned row")

        let syncResult = InboxListReader.fetchSync(folders: [inbox], query: q)
        #expect(syncResult == asyncResult, "fetch and fetchSync diverged for the undo shape")
    }

    // MARK: - (g) label filter: a genuinely-labeled durable row survives
    // (audit round 4: compose step 6's D/P/S uniform label filter has
    // negative-path coverage — unlabeledExcludesUnlabeledStagedRowEverywhere/
    // labelFilterDropsStagedRows — but no positive path proving a REAL label
    // makes it through the reader's D query + UserLabelStore batch load.)

    @Test("label filter: a genuinely-labeled durable row survives an active label filter via BOTH fetch variants, with userLabels populated; an unlabeled durable sibling drops")
    func labeledDurableRowSurvivesLabelFilter() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let labeled = makeDurableHeader(folder: inbox, messageId: "m-labeled")
        let unlabeled = makeDurableHeader(folder: inbox, messageId: "m-unlabeled")
        try await pool.writeWithoutTransaction { db in
            let l = labeled; try l.insert(db)
            let u = unlabeled; try u.insert(db)
            try UserLabel(id: "label-x", accountId: "acc1", name: "Filtered", isSystem: false).insert(db)
            try MessageUserLabel(messageId: labeled.id, userLabelId: "label-x").insert(db)
        }
        let q = query(folders: [inbox], filterLabelIds: ["label-x"])

        let asyncResult = await InboxListReader.fetch(folders: [inbox], query: q)
        #expect(asyncResult.count == 1, "expected exactly the labeled row to survive the label filter (async)")
        guard asyncResult.count == 1 else { return }
        #expect(asyncResult.first?.id == labeled.id)
        #expect(
            asyncResult.first?.userLabels.map(\.id) == ["label-x"],
            "userLabels not populated on the surviving durable snapshot (async)"
        )
        #expect(!asyncResult.contains { $0.id == unlabeled.id }, "unlabeled durable sibling leaked through the label filter")

        let syncResult = InboxListReader.fetchSync(folders: [inbox], query: q)
        #expect(syncResult == asyncResult, "fetch and fetchSync diverged for the durable label filter")
        #expect(
            syncResult.first?.userLabels.map(\.id) == ["label-x"],
            "userLabels not populated on the surviving durable snapshot (sync)"
        )
    }

    // MARK: - (h) label filter: a genuinely-labeled overlay-pinned (undo-shape) row survives

    @Test("label filter: a genuinely-labeled overlay-pinned (undo-shape) row survives an active label filter via BOTH fetch variants, with userLabels populated; an unlabeled archived+pinned sibling drops")
    func labeledPinnedRowSurvivesLabelFilter() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        let labeled = makeDurableHeader(folder: archive, messageId: "m-undo-labeled", isInInbox: false)
        let unlabeled = makeDurableHeader(folder: archive, messageId: "m-undo-unlabeled", isInInbox: false)
        try await pool.writeWithoutTransaction { db in
            let l = labeled; try l.insert(db)
            let u = unlabeled; try u.insert(db)
            try UserLabel(id: "label-x", accountId: "acc1", name: "Filtered", isSystem: false).insert(db)
            try MessageUserLabel(messageId: labeled.id, userLabelId: "label-x").insert(db)
        }

        // Mirror UndoService.undo()'s .move case for BOTH messages — overlay
        // registered, deferred DB restore write NOT landed yet (the "undo
        // shape" pinnedStepRestoresUndoneRow above exercises unlabeled).
        AccountManager.shared.registerMutation(id: labeled.id, mutation: .init(
            folderId: inbox.id, folderPath: inbox.path, isInInbox: true
        ))
        AccountManager.shared.registerMutation(id: unlabeled.id, mutation: .init(
            folderId: inbox.id, folderPath: inbox.path, isInInbox: true
        ))
        let q = query(folders: [inbox], filterLabelIds: ["label-x"])

        let asyncResult = await InboxListReader.fetch(folders: [inbox], query: q)
        #expect(asyncResult.count == 1, "expected exactly the labeled pinned row to survive the label filter (async)")
        guard asyncResult.count == 1 else { return }
        #expect(asyncResult.first?.id == labeled.id)
        #expect(asyncResult.first?.isInInbox == true, "overlay isInInbox not applied to the surviving pinned row")
        #expect(
            asyncResult.first?.userLabels.map(\.id) == ["label-x"],
            "userLabels not populated on the surviving pinned snapshot (async)"
        )
        #expect(
            !asyncResult.contains { $0.id == unlabeled.id },
            "unlabeled archived+pinned sibling leaked through the label filter"
        )

        let syncResult = InboxListReader.fetchSync(folders: [inbox], query: q)
        #expect(syncResult == asyncResult, "fetch and fetchSync diverged for the pinned label filter")
        #expect(
            syncResult.first?.userLabels.map(\.id) == ["label-x"],
            "userLabels not populated on the surviving pinned snapshot (sync)"
        )
    }

    // MARK: - (e) §5A.3 contract parity: pure identity mirror vs DurableIdentityLookup

    @Test("contract parity: the scenario harness's pure identity mirror agrees with DurableIdentityLookup.find over a fixture set (primary hit / rfc822 fallback / absent / other-account)")
    func identityMirrorMatchesDurableIdentityLookup() throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // Fixture headers in the REAL DB.
        let primary = makeDurableHeader(folder: inbox, messageId: "m-primary", rfc822MessageId: "rfc-p@example.com")
        let remapped = makeDurableHeader(
            folder: archive, messageId: "999", rfc822MessageId: "rfc-f@example.com", isInInbox: false
        )
        var other = MessageHeader(
            messageId: "m-shared", subject: "Subj", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: "acc2:INBOX", accountId: "acc2", folderPath: "INBOX", isInInbox: true
        )
        other.headerComplete = true
        try pool.writeWithoutTransaction { db in
            let p = primary; try p.insert(db)
            let r = remapped; try r.insert(db)
            let o = other; try o.insert(db)
        }

        // The same rows as the mirror's value shape.
        let mirrorRows = [primary, remapped, other].map { h in
            SimDurableRow(
                id: h.id, accountId: h.accountId, messageId: h.messageId,
                rfc822MessageId: h.rfc822MessageId, folderId: h.folderId,
                folderPath: h.folderPath, isInInbox: h.isInInbox
            )
        }

        // Probe set: exact-folder hit, folder-blind hit, rfc822 fallback (UID
        // remap), fallback guards (nil/empty rfc822), absent identity,
        // other-account scoping, and the G3 cross-folder-collision cases.
        let probes: [(accountId: String, folderPath: String, messageId: String, rfc822: String?)] = [
            ("acc1", "INBOX", "m-primary", nil),                       // exact-folder hit
            ("acc1", "INBOX", "m-primary", "rfc-p@example.com"),       // exact-folder hit with rfc822 present
            ("acc1", "Archive", "m-primary", nil),                     // folder-blind hit (queried folder wrong)
            ("acc1", "INBOX", "111", "rfc-f@example.com"),             // rfc822 fallback (UID remap)
            ("acc1", "INBOX", "111", nil),                             // fallback NOT taken (nil rfc822)
            ("acc1", "INBOX", "111", ""),                              // fallback NOT taken (empty rfc822)
            ("acc1", "INBOX", "m-absent", "rfc-absent@example.com"),   // absent identity
            ("acc1", "INBOX", "m-shared", nil),                        // other-account scoping → nil
            ("acc2", "INBOX", "m-shared", nil),                        // other-account own hit
            // G3: cross-folder UID collision (`remapped`, messageId "999",
            // lives in Archive) probed FROM INBOX with a disagreeing rfc822
            // — provable non-match, must reject the folder-blind hit.
            ("acc1", "INBOX", "999", "rfc-different@example.com"),
        ]

        for probe in probes {
            let real = try pool.read { db in
                try DurableIdentityLookup.find(
                    db: db, accountId: probe.accountId, folderPath: probe.folderPath,
                    messageId: probe.messageId, rfc822MessageId: probe.rfc822
                )
            }
            let mirrored = SimIdentityMirror.find(
                rows: mirrorRows, accountId: probe.accountId, folderPath: probe.folderPath,
                messageId: probe.messageId, rfc822MessageId: probe.rfc822
            )
            #expect(
                real == mirrored,
                "identity contract diverged for probe (\(probe.accountId), \(probe.folderPath), \(probe.messageId), \(probe.rfc822 ?? "nil")): real=\(String(describing: real)) mirror=\(String(describing: mirrored))"
            )
        }
    }

    // MARK: - (i) G3 audit: cross-folder UID collision does not suppress a staged row

    @Test("cross-folder UID collision: an unrelated Archive row sharing the UID but with a DIFFERING rfc822 does not suppress the staged INBOX row (G3 exact-folder-first + rfc822-mismatch rejection)")
    func crossFolderUidCollisionDifferingRfc822DoesNotSuppressStagedRow() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // Unrelated durable message in Archive sharing the SAME raw UID as
        // the staged row below — a legitimate per-folder IMAP UID collision,
        // not a move — but with a DIFFERENT rfc822 identity.
        let unrelatedArchive = makeDurableHeader(
            folder: archive, messageId: "101", rfc822MessageId: "rfc-unrelated@example.com", isInInbox: false
        )
        try await pool.writeWithoutTransaction { db in try unrelatedArchive.insert(db) }

        let staged = makeStagedRow(messageId: "101", rfc822MessageId: "rfc-staged@example.com")
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        let q = query(folders: [inbox])

        let asyncResult = await InboxListReader.fetch(folders: [inbox], query: q)
        #expect(asyncResult.count == 1, "unrelated cross-folder UID collision wrongly suppressed the staged row (async)")
        #expect(asyncResult.first?.messageId == "101")

        let syncResult = InboxListReader.fetchSync(folders: [inbox], query: q)
        #expect(syncResult.count == 1, "unrelated cross-folder UID collision wrongly suppressed the staged row (sync)")
        #expect(syncResult == asyncResult, "fetch and fetchSync diverged for the cross-folder collision case")
    }

    // MARK: - (f) the §2.1a window against a real DB

    @Test("headerComplete=false durable + staged row: the staged row still renders (the §2.1a FTS-flush window), via both variants")
    func headerIncompleteWindowStagedStillRenders() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay(); resetStagedGlobal()
        }
        clearOverlay(); resetStagedGlobal()

        // Phase-1 shape: durable header EXISTS but headerComplete=false —
        // invisible to the D query.
        let phase1 = makeDurableHeader(folder: inbox, messageId: "m-window", headerComplete: false)
        try await pool.writeWithoutTransaction { db in try phase1.insert(db) }

        let staged = makeStagedRow(messageId: "m-window", actionTag: ActionTag.reply.rawValue, summaryBlurb: "blurb")
        NSEDataBridge.latestStagedRows.withLock { $0 = [staged] }
        let q = query(folders: [inbox])

        let asyncResult = await InboxListReader.fetch(folders: [inbox], query: q)
        #expect(asyncResult.count == 1, "row vanished in the FTS-flush window (blanket identity-existence suppression — the §2.1a defect)")
        #expect(asyncResult.first?.messageId == "m-window")
        #expect(asyncResult.first?.actionTag == .reply, "staged AI fields missing in the FTS-flush window")

        let syncResult = InboxListReader.fetchSync(folders: [inbox], query: q)
        #expect(syncResult == asyncResult, "fetch and fetchSync diverged inside the FTS-flush window")
    }
}
