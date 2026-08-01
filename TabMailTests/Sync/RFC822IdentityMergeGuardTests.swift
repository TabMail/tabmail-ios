/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// **THE INVARIANT: C3 — a sync pass never mutates the wrong message, and never
/// destroys the user's moved message to make room for another.**
///
/// Every assertion below is on the SYSTEM PROPERTY — which message still exists,
/// what identity it still carries, whose body is attached to it — never on the
/// mechanism that delivers it ("`classifyRFC822Merge` returned `.collision`").
/// A mechanism-pinning test inherits a wrong spec's error and stays green on a
/// broken system; that exact shape produced two regressions in this project's
/// audit train (2026-07-16), so it is deliberately avoided here.
///
/// ## Why `(folderId, messageId)` equality is not an identity proof
///
/// `MessageHeader.stableId` returns `rfc822MessageId` iff the messageId parses
/// as a `UInt32` and the RFC id is non-empty, else the bare `messageId` — so on
/// IMAP the durable identity is the RFC id and the UID is only an ADDRESS.
/// `optimisticMoveToFolder` writes `folderId`/`folderPath`/`isInInbox` but
/// leaves BOTH the primary key and the `messageId` column holding the SOURCE
/// folder's UID. IMAP UID spaces are PER FOLDER, so INBOX UID 500 and Archive
/// UID 500 are routinely two different messages **with no UIDVALIDITY reset
/// involved at all** — which is what makes the canonicalizer case below
/// reachable on an ordinary account.
///
/// ## Why these tests drive the REAL `runSyncMessages`
///
/// `SyncEngineRunSyncTests` replicates the merge loop against a
/// `DatabaseQueue` (`simulateRunSyncMessages`), and a suite that re-implements
/// the code under test is structurally blind to the code under test. These
/// cases therefore call the production entry point against a real
/// `AppDatabase`-backed `DatabasePool`, exactly as `StaleProtectionTests` and
/// `UidValidityTurnoverDeletionGuardTests` do, and assert on durable rows read
/// back afterwards.
///
/// `.serialized, .processGlobalState` — swaps the `AppDatabase.shared` singleton.
///
/// ⚑ R0 (`v2final`, tag `7904961ded`): the guards under test are ported from
/// `SyncEngine.classifyRFC822Merge` + the §5 arms in
/// `v2final:TabMail/Services/Sync/SyncEngineFullSync.swift` (origin commits
/// `4d34ee864` ADR-IOS-061 §5 / R15-F1, and `711dc68cb` R14-F1). What does NOT
/// transfer is the reference's epoch-mismatch arm, which fires a
/// purge-and-resync reaction v3 does not have (plan item T4.S6); under
/// constraint C6 it collapses into the plain refusal, which these tests pin.
@Suite("§5 RFC822 identity merge guards — C3, never mutate the wrong message",
       .serialized, .processGlobalState)
struct RFC822IdentityMergeGuardTests {

    // MARK: - Fixtures

    /// Real `DatabasePool`-backed `AppDatabase` (runs all migrations) swapped into
    /// the shared slot so `SyncEngine.runSyncMessages` / `AppDatabase.dbPool` hit
    /// the test DB. Mirrors `StaleProtectionTests.makeAppDB`.
    private func makeAppDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        return (pool, dir, previous)
    }

    private func seedAccountAndFolders(_ pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "U", provider: .imap)
            acc.id = "acc1"
            try acc.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1").insert(db)
        }
    }

    /// Insert a header whose PK is derived from `pkFolderPath` but whose
    /// folder-membership columns say `folderPath` — i.e. the exact durable shape
    /// `optimisticMoveToFolder` leaves behind when `pkFolderPath != folderPath`.
    @discardableResult
    private func insertHeader(
        _ pool: DatabasePool,
        messageId: String,
        rfc822: String?,
        pkFolderPath: String,
        folderPath: String,
        subject: String = "Original subject",
        bodyHTML: String? = nil
    ) throws -> String {
        var header = MessageHeader(
            messageId: messageId,
            subject: subject,
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "user@example.com",
            date: Date(timeIntervalSince1970: 1_750_000_000),
            snippet: "snippet",
            folderId: "acc1:\(pkFolderPath)",
            accountId: "acc1",
            folderPath: pkFolderPath,
            isInInbox: pkFolderPath == "INBOX"
        )
        header.rfc822MessageId = rfc822
        header.headerComplete = true
        try pool.writeWithoutTransaction { db in
            try header.insert(db)
            if pkFolderPath != folderPath {
                // The optimistic move: membership columns move, PK and the
                // `messageId` column (the SOURCE folder's UID) do not.
                try MessageHeader.filter(Column("id") == header.id).updateAll(
                    db,
                    Column("folderId").set(to: "acc1:\(folderPath)"),
                    Column("folderPath").set(to: folderPath),
                    Column("isInInbox").set(to: folderPath == "INBOX")
                )
            }
            if let bodyHTML {
                try MessageBody( contentKey: ContentKey(rawValue: header.id), htmlContent: bodyHTML).insert(db)
            }
        }
        return header.id
    }

    private func headerInfo(
        messageId: String,
        rfc822: String?,
        subject: String = "Server subject"
    ) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: messageId,
            rfc822MessageId: rfc822,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: subject,
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "user@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(timeIntervalSince1970: 1_750_000_000),
            snippet: "snippet",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
    }

    private func mock(_ messages: [MessageHeaderInfo]) async -> MockEmailProvider {
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setFetchMessagesResult(messages)
        return provider
    }

    // GRDB's `read`/`write` resolve to their ASYNC overloads inside an async
    // test body, so every DB touch goes through a non-async accessor here.

    private func folder(_ pool: DatabasePool, id: String) throws -> Folder {
        try pool.read { try Folder.fetchOne($0, key: id)! }
    }

    private func sync(
        _ pool: DatabasePool, folderId: String, provider: MockEmailProvider
    ) async throws -> SyncEngine.SyncMessagesResult {
        try await SyncEngine.runSyncMessages(
            for: try folder(pool, id: folderId), provider: provider,
            limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool, recentlyCompleted: [:])
    }

    private func header(_ pool: DatabasePool, id: String) throws -> MessageHeader? {
        try pool.read { try MessageHeader.fetchOne($0, key: id) }
    }

    private func bodyHTML(_ pool: DatabasePool, id: String) throws -> String? {
        try pool.read { try MessageBody.fetchOne($0, key: id)?.htmlContent }
    }

    private func headers(_ pool: DatabasePool, messageId: String) throws -> [MessageHeader] {
        try pool.read { try MessageHeader.filter(Column("messageId") == messageId).fetchAll($0) }
    }

    private func insertPendingArchive(
        _ pool: DatabasePool, stableId: String, from source: String, to destination: String
    ) throws {
        try pool.writeWithoutTransaction { db in
            try PendingOperation(
                type: .archive, messageIds: [stableId],
                accountId: "acc1", folderPath: source, destinationPath: destination
            ).insert(db)
        }
    }

    // MARK: - D4 — the canonicalizer's identity gate

    /// **The user's archived message survives a destination-folder sync that
    /// fetches a DIFFERENT message at the same UID, while its move op is still
    /// pending.**
    ///
    /// No UIDVALIDITY reset is involved: INBOX UID 500 and Archive UID 500 are
    /// simply two different messages, and the archived row still carries the
    /// INBOX UID in its `messageId` column. `pendingAllIds` protects the row
    /// from the STALE sweep, but `canonicalizeLocalRows` never consulted it —
    /// so pre-fix the row was deleted as a "duplicate" of the folder-native
    /// Archive row, its read/AI state OR-merged onto that unrelated message and
    /// its body cascaded away. Both a never-drop-user-intention violation and a
    /// wrong-message local mutation, inside one epoch.
    @Test("A pending optimistic move survives the destination folder's sync of a different message at the same UID")
    func pendingArchivedMessageSurvivesUidCoincidence() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        // The user's message: archived out of INBOX, still keyed by INBOX UID 500.
        let movedId = try insertHeader(
            pool, messageId: "500", rfc822: "moved@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive",
            subject: "The user's archived message", bodyHTML: "<p>the user's body</p>")
        // Archive's OWN UID 500 — a completely different message.
        let nativeId = try insertHeader(
            pool, messageId: "500", rfc822: "native@example.com",
            pkFolderPath: "Archive", folderPath: "Archive",
            subject: "Archive's own message")
        #expect(movedId == "acc1:INBOX:500")
        #expect(nativeId == "acc1:Archive:500")

        // The move op is still pending — IMAP pending ops key by stableId (rfc822).
        try insertPendingArchive(pool, stableId: "moved@example.com", from: "INBOX", to: "Archive")

        let provider = await mock([headerInfo(messageId: "500", rfc822: "native@example.com")])
        let result = try await sync(pool, folderId: "acc1:Archive", provider: provider)

        let moved = try header(pool, id: movedId)
        #expect(moved != nil,
                "the user's archived message must still exist — a UID coincidence at the destination is not a duplicate")
        #expect(moved?.rfc822MessageId == "moved@example.com",
                "its durable identity must be untouched")
        #expect(moved?.folderPath == "Archive",
                "its optimistic move must not be undone")
        #expect(!result.staleIds.contains(movedId),
                "it must not be swept out of the search index either")
        #expect(try bodyHTML(pool, id: movedId) == "<p>the user's body</p>",
                "its body must not be cascaded away")
        // The folder-native message is untouched too — the gate refuses a merge,
        // it does not refuse the ordinary upsert.
        #expect(try header(pool, id: nativeId)?.rfc822MessageId == "native@example.com")
    }

    /// The mirror-image check for the gate: two rows at one address that DO
    /// share an identity are still merged into one. A guard that refused this
    /// would turn a wrong-merge bug into a permanent-duplicate bug.
    @Test("Two rows at one address that share an identity are still merged")
    func sameIdentityDuplicatesStillMerge() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let remnantId = try insertHeader(
            pool, messageId: "500", rfc822: "same@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive")
        let canonicalId = try insertHeader(
            pool, messageId: "500", rfc822: "same@example.com",
            pkFolderPath: "Archive", folderPath: "Archive")

        let provider = await mock([headerInfo(messageId: "500", rfc822: "same@example.com")])
        _ = try await sync(pool, folderId: "acc1:Archive", provider: provider)

        let rows = try headers(pool, messageId: "500")
        #expect(rows.count == 1, "identity-proven duplicates must still converge to one row")
        guard rows.count == 1 else { return }
        #expect(rows[0].id == canonicalId, "the folder-native canonical PK wins")
        #expect(try header(pool, id: remnantId) == nil)
    }

    // MARK: - D2 — the `existing` merge branch

    /// **A fetch carrying no Message-ID never NULLs a stored identity.**
    ///
    /// `IMAPFetchMapping.rfc822MessageId(from:)` is `info.messageId.map { … }`,
    /// i.e. nil whenever the ENVELOPE carries no Message-ID. The pre-fix
    /// unconditional assign wrote that nil over a durable RFC id, which flips
    /// `MessageHeader.stableId` from the RFC id to the bare UID — and a bare-UID
    /// gesture is admitted by `AccountManager.newGestureRefusedForUnknownEpoch`
    /// the moment the folder carries any epoch stamp at all (that guard is
    /// `folder.lastKnownUidValidity == nil`, and `bootstrapFolderUidValidity`
    /// makes the stamp non-nil inside the very transaction that did the NULLing).
    /// The system property asserted is therefore `stableId`, not the column.
    @Test("A fetch carrying no Message-ID never NULLs a stored identity")
    func nilIncomingIdentityNeverNullsStoredIdentity() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let id = try insertHeader(
            pool, messageId: "700", rfc822: "durable@example.com",
            pkFolderPath: "INBOX", folderPath: "INBOX")

        let provider = await mock([headerInfo(messageId: "700", rfc822: nil)])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        let row = try header(pool, id: id)
        #expect(row?.stableId == "durable@example.com",
                "an rfc-less fetch must not demote the row to a bare-UID stableId — that re-admits bare-UID gestures")
        #expect(row?.rfc822MessageId == "durable@example.com")
    }

    /// **A fetch carrying a DIFFERENT Message-ID never overwrites a stored one
    /// — while non-identity fields still merge.**
    ///
    /// The second half is the mirror-image check: the refusal must be scoped to
    /// the identity fields, not escalated into a blanket abort of the merge.
    @Test("A fetch carrying a different Message-ID never overwrites the stored one, but non-identity fields still merge")
    func collidingIncomingIdentityIsRefusedButOtherFieldsMerge() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let id = try insertHeader(
            pool, messageId: "800", rfc822: "stored@example.com",
            pkFolderPath: "INBOX", folderPath: "INBOX", subject: "Original subject")

        let provider = await mock([
            headerInfo(messageId: "800", rfc822: "different@example.com", subject: "Server subject")
        ])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        let row = try header(pool, id: id)
        #expect(row?.rfc822MessageId == "stored@example.com",
                "a disagreeing incoming identity must never be written over the stored one")
        #expect(row?.from == "Sender",
                "non-identity fields still merge — the refusal is scoped to identity, not a blanket abort")
    }

    /// Enrichment must still land: a row that carries NO identity yet adopts the
    /// one the server offers. Without this, the guard would strand every
    /// rfc-less local row at a bare-UID `stableId` forever.
    @Test("A row with no stored identity still adopts the incoming one")
    func nilStoredIdentityStillAdoptsIncoming() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let id = try insertHeader(
            pool, messageId: "810", rfc822: nil,
            pkFolderPath: "INBOX", folderPath: "INBOX")
        #expect(try header(pool, id: id)?.stableId == "810", "precondition: bare-UID stableId")

        let provider = await mock([headerInfo(messageId: "810", rfc822: "enriched@example.com")])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        #expect(try header(pool, id: id)?.stableId == "enriched@example.com",
                "nil→non-nil is enrichment, not a collision — it must still be adopted")
    }

    // MARK: - D3 — the orphan-reclaim leg

    /// **A survivor whose identity disagrees with the incoming occupant is never
    /// reclaimed.**
    ///
    /// The pre-fix branch guarded only on `orphanIsPending`, then rewrote
    /// `folderId`/`folderPath`/`isInInbox`/`rfc822MessageId` and the whole
    /// content set IN PLACE. `orphaned.id` never changes and no `ftsRekey` is
    /// emitted, so `MessageBody` (PK-keyed), `MessageUserLabel.messageId`,
    /// `MessageReference.messageHeaderId` and the search index all stay attached
    /// to the OLD identity — message B ends up displaying A's body permanently
    /// (`bodyComplete` is untouched, so nothing ever re-fetches).
    @Test("A colliding survivor is never reclaimed — B never inherits A's body")
    func collidingSurvivorIsNeverReclaimed() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        // A: moved to Archive; the drain has COMPLETED, so no pending op remains
        // and the row is invisible to `pendingDestructiveIds`.
        let survivorId = try insertHeader(
            pool, messageId: "900", rfc822: "survivor@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive",
            subject: "A — the user's moved message", bodyHTML: "<p>A's body</p>")
        #expect(survivorId == "acc1:INBOX:900")

        // B now occupies INBOX UID 900.
        let provider = await mock([
            headerInfo(messageId: "900", rfc822: "occupant@example.com", subject: "B — a different message")
        ])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        let survivor = try header(pool, id: survivorId)
        #expect(survivor?.rfc822MessageId == "survivor@example.com",
                "A's identity must not be rewritten to B's")
        #expect(survivor?.folderPath == "Archive",
                "A must not be yanked out of the folder the user moved it to")
        #expect(survivor?.subject == "A — the user's moved message",
                "A's content must not be replaced by B's")
        #expect(try bodyHTML(pool, id: survivorId) == "<p>A's body</p>",
                "A's body must stay attached to A — reclaiming would serve it as B's")
    }

    /// **The refusal is TRANSIENT, not a permanent stall.**
    ///
    /// A refusal whose re-entry condition is durable is a PERMANENT refusal.
    /// This one is not: the survivor lives in its destination folder, where its
    /// `messageId` is a foreign-UID-space value that folder's remote set does
    /// not contain — so it is stale there, and the rfc822-keyed UID remap in
    /// `runSyncMessages` re-keys it to its real UID, vacating the PK. This test
    /// drives that healing with the REAL Archive sync (nothing is hand-vacated)
    /// and then shows the INBOX pass storing B normally.
    @Test("The reclaim refusal is transient — it resolves once the destination sync vacates the PK")
    func reclaimRefusalIsTransient() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let survivorId = try insertHeader(
            pool, messageId: "900", rfc822: "survivor@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive", bodyHTML: "<p>A's body</p>")

        // Pass 1 — INBOX sync refuses the reclaim; B is not stored.
        let inboxProvider = await mock([headerInfo(messageId: "900", rfc822: "occupant@example.com")])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: inboxProvider)
        #expect(try header(pool, id: survivorId)?.folderPath == "Archive")

        // Pass 2 — Archive's own sync finds A at its real Archive UID 1200 and
        // re-keys it there (rfc822-matched UID remap), vacating acc1:INBOX:900.
        let archiveProvider = await mock([headerInfo(messageId: "1200", rfc822: "survivor@example.com")])
        _ = try await sync(pool, folderId: "acc1:Archive", provider: archiveProvider)
        #expect(try header(pool, id: survivorId) == nil,
                "the destination sync must vacate the source-folder PK")
        let rekeyed = try header(pool, id: "acc1:Archive:1200")
        #expect(rekeyed?.rfc822MessageId == "survivor@example.com",
                "A heals into its own folder under its real UID, body and all")
        #expect(try bodyHTML(pool, id: "acc1:Archive:1200") == "<p>A's body</p>")

        // Pass 3 — with the PK vacated, the INBOX pass stores B normally.
        let inboxProvider2 = await mock([headerInfo(messageId: "900", rfc822: "occupant@example.com")])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: inboxProvider2)
        let occupant = try header(pool, id: "acc1:INBOX:900")
        #expect(occupant?.rfc822MessageId == "occupant@example.com",
                "the refusal must not outlive the condition that caused it")
    }

    /// The mirror-image check for the reclaim guard: an orphan of the SAME
    /// message is still reclaimed. A guard that refused this would strand every
    /// no-op optimistic move (e.g. archive from All Mail) in the wrong folder.
    @Test("An orphan of the same message is still reclaimed")
    func sameIdentityOrphanIsStillReclaimed() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let orphanId = try insertHeader(
            pool, messageId: "950", rfc822: "sameorphan@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive")

        let provider = await mock([headerInfo(messageId: "950", rfc822: "sameorphan@example.com")])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        let reclaimed = try header(pool, id: orphanId)
        #expect(reclaimed?.folderPath == "INBOX",
                "a same-identity orphan must still be reclaimed — the guard must not refuse this")
        #expect(reclaimed?.folderId == "acc1:INBOX")
    }

    /// Assign/keep on the reclaim leg: an rfc-less incoming fetch must not NULL
    /// the survivor's identity even when the reclaim itself is admitted.
    @Test("A reclaim driven by an rfc-less fetch never NULLs the survivor's identity")
    func reclaimWithNilIncomingKeepsStoredIdentity() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let orphanId = try insertHeader(
            pool, messageId: "960", rfc822: "keepme@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive")

        let provider = await mock([headerInfo(messageId: "960", rfc822: nil)])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        let reclaimed = try header(pool, id: orphanId)
        #expect(reclaimed?.folderPath == "INBOX", "nil incoming is not a collision — the reclaim proceeds")
        #expect(reclaimed?.stableId == "keepme@example.com",
                "but the rfc-less fetch must not demote it to a bare-UID stableId")
    }

    // MARK: - Pre-sync inbox reclaim (R15-F1 sibling gate)

    /// The pre-sync inbox reclaim matches on bare `(accountId, messageId,
    /// isInInbox)` and then DELETES what it matched. A different message
    /// optimistically moved INTO the inbox, whose source-folder UID coincides,
    /// must not be deleted by it.
    @Test("The pre-sync inbox reclaim never deletes a foreign message at a coinciding UID")
    func preSyncInboxReclaimNeverDeletesForeignIdentity() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        // A message moved Archive → INBOX: `isInInbox` is true, `messageId` is
        // still the Archive UID 600, and the PK is still the Archive one.
        let movedInId = try insertHeader(
            pool, messageId: "600", rfc822: "movedin@example.com",
            pkFolderPath: "Archive", folderPath: "INBOX", bodyHTML: "<p>moved-in body</p>")
        #expect(movedInId == "acc1:Archive:600")

        // INBOX's own UID 600 is an unrelated, not-yet-local message.
        let provider = await mock([headerInfo(messageId: "600", rfc822: "inboxnative@example.com")])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        let movedIn = try header(pool, id: movedInId)
        #expect(movedIn != nil, "the user's moved-in message must not be deleted by the reclaim")
        #expect(movedIn?.rfc822MessageId == "movedin@example.com")
        #expect(try bodyHTML(pool, id: movedInId) == "<p>moved-in body</p>")
        // The incoming message is stored on its own canonical PK, not by
        // cannibalising the moved-in row.
        #expect(try header(pool, id: "acc1:INBOX:600")?.rfc822MessageId == "inboxnative@example.com")
    }
}

/// Pure-function coverage for the classifier the §5 arms above share. These
/// pin the CONTRACT (which of the four shapes is a collision), which is what
/// each call site's assign/keep decision is built on.
@Suite("classifyRFC822Merge — the §5 collision contract")
struct RFC822MergeClassificationTests {

    @Test("Both sides non-nil and different is the only collision")
    func onlyDisagreeingNonNilPairsCollide() {
        #expect(SyncEngine.classifyRFC822Merge(storedNormalized: "a@example.com", incomingNormalized: "b@example.com") == .collision)
        #expect(SyncEngine.classifyRFC822Merge(storedNormalized: "a@example.com", incomingNormalized: "a@example.com") == .notACollision)
        #expect(SyncEngine.classifyRFC822Merge(storedNormalized: nil, incomingNormalized: "b@example.com") == .notACollision)
        #expect(SyncEngine.classifyRFC822Merge(storedNormalized: "a@example.com", incomingNormalized: nil) == .notACollision)
        #expect(SyncEngine.classifyRFC822Merge(storedNormalized: nil, incomingNormalized: nil) == .notACollision)
    }

    @Test("Identity normalization: brackets and whitespace stripped, empty collapses to nil")
    func normalizationCollapsesEmptyAndStripsBrackets() {
        #expect(SyncEngine.normalizedRfc822Identity("<a@example.com>") == "a@example.com")
        #expect(SyncEngine.normalizedRfc822Identity("  a@example.com  ") == "a@example.com")
        #expect(SyncEngine.normalizedRfc822Identity("") == nil)
        #expect(SyncEngine.normalizedRfc822Identity("   ") == nil)
        #expect(SyncEngine.normalizedRfc822Identity(nil) == nil)
        // An angle-bracketed stored value and a bare incoming value are the SAME
        // identity — without normalization every such pair would be a collision.
        #expect(SyncEngine.classifyRFC822Merge(
            storedNormalized: SyncEngine.normalizedRfc822Identity("<x@example.com>"),
            incomingNormalized: SyncEngine.normalizedRfc822Identity("x@example.com")) == .notACollision)
    }
}
