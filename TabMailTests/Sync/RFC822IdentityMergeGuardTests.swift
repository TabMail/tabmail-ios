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
/// mechanism that delivers it.
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
/// ⚑ R0 (`v2final`, tag `7904961ded`): the fail-closed control-flow under test
/// is ported from `SyncEngine.canonicalizeLocalRows` + the §5 arms in
/// `v2final:TabMail/Services/Sync/SyncEngineFullSync.swift` (origin commits
/// `4d34ee864` ADR-IOS-061 §5 / R15-F1, and `711dc68cb` R14-F1). The reference's
/// RFC discriminator is SUBTRACTED; provider-address proof is the minimum
/// ⚑ NO REFERENCE — INVENTED replacement.
@Suite("Provider-address ownership guards — C3, never mutate the wrong message",
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
        bodyHTML: String? = nil,
        observedUidValidity: Int? = nil
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
        header.observedUidValidity = observedUidValidity
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

    private func mock(
        _ messages: [MessageHeaderInfo], observedUidValidity: UInt32? = nil,
        folderPath: String? = nil
    ) async -> MockEmailProvider {
        let provider = MockEmailProvider(staleWindowMode: .uid)
        if let folderPath {
            await provider.setMockedBoundFetchEpoch(observedUidValidity, folderPath: folderPath)
        }
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

    private func headers(_ pool: DatabasePool, rfc822: String) throws -> [MessageHeader] {
        try pool.read { try MessageHeader.filter(Column("rfc822MessageId") == rfc822).fetchAll($0) }
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

    /// RFC Message-ID equality is not provider-address ownership. The moved-in
    /// row carries an INBOX UID in Archive's folder membership, while the
    /// canonical row carries Archive's own UID and the exact epoch observed by
    /// the FETCH serving this pass. Only the latter may be merged into.
    @Test("A colliding optimistic row is not merged or deleted")
    func collidingOptimisticRowIsNotMergedOrDeleted() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let movedId = try insertHeader(
            pool, messageId: "501", rfc822: "same@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive",
            subject: "The user's optimistic move", bodyHTML: "<p>authored state</p>")
        let nativeId = try insertHeader(
            pool, messageId: "501", rfc822: "same@example.com",
            pkFolderPath: "Archive", folderPath: "Archive",
            subject: "Archive's provider-native occupant", observedUidValidity: 202)

        let provider = await mock(
            [headerInfo(messageId: "501", rfc822: "same@example.com")],
            observedUidValidity: 202, folderPath: "Archive")
        let result = try await sync(pool, folderId: "acc1:Archive", provider: provider)

        #expect(try header(pool, id: movedId) != nil,
                "RFC equality cannot authorize deleting the moved foreign-address row")
        #expect(try bodyHTML(pool, id: movedId) == "<p>authored state</p>")
        #expect(!result.staleIds.contains(movedId))
        #expect(try header(pool, id: nativeId)?.observedUidValidity == 202,
                "the direct canonical row keeps the epoch bound to the serving FETCH")
        let rows = try headers(pool, messageId: "501")
        #expect(rows.count == 2,
                "provider-address ownership proves which row may update; it does not make the foreign row a duplicate")
    }

    /// The mirror-image check for the gate: two rows at one provider address
    /// whose source observations are both proven still merge. RFC equality is
    /// deliberately irrelevant to the admission decision.
    @Test("Two provider-proven rows at one address are still merged")
    func providerProvenDuplicatesStillMerge() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let remnantId = try insertHeader(
            pool, messageId: "500", rfc822: "same@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive",
            observedUidValidity: 202)
        let canonicalId = try insertHeader(
            pool, messageId: "500", rfc822: "same@example.com",
            pkFolderPath: "Archive", folderPath: "Archive",
            observedUidValidity: 202)

        let provider = await mock(
            [headerInfo(messageId: "500", rfc822: "same@example.com")],
            observedUidValidity: 202, folderPath: "Archive")
        _ = try await sync(pool, folderId: "acc1:Archive", provider: provider)

        let rows = try headers(pool, messageId: "500")
        #expect(rows.count == 1, "identity-proven duplicates must still converge to one row")
        guard rows.count == 1 else { return }
        #expect(rows[0].id == canonicalId, "the folder-native canonical PK wins")
        #expect(try header(pool, id: remnantId) == nil)
    }

    // MARK: - D4 — the refusal must not swallow the incoming message

    /// **THE SYSTEM PROPERTY: a message the server reports in a folder, and that
    /// has no local row anywhere, ends up present locally.**
    ///
    /// The assertion is deliberately on presence-and-content of the SERVER's
    /// message, never on what `canonicalizeLocalRows` returns — a
    /// mechanism-pinning test inherits a wrong spec's error and stays green on a
    /// broken system.
    ///
    /// Reachability, with no UIDVALIDITY reset anywhere: the user archives INBOX
    /// UID 500 on a server whose `COPYUID` evidence never arrives (no UIDPLUS),
    /// so `MessageHeaderRekey.finishMove`'s G4 arm leaves the row in Archive
    /// still carrying the INBOX UID in its `messageId` column and a nil epoch
    /// stamp. Archive's OWN UID 500 is a different message that is not local
    /// yet. Pre-fix the refusal returned that remnant, the caller's
    /// `sourceAddressProven` arm `continue`d before the insert, and nothing else
    /// ever re-offered the message: `selectStaleHeaders` cannot reach the
    /// remnant (UID 500 is in `remoteIds`) and `SyncEngine`'s
    /// `missingUIDs` is keyed on (folderId, messageId), so the remnant answers
    /// for UID 500 and the deep crawl filters the real message out. The user has
    /// no reason to connect a message they can see to a different one they
    /// cannot, so "delete the remnant and the UID frees up" is a path, not a
    /// recovery (`MIS-IOS-008`).
    @Test("A server message absent locally becomes present even when a foreign remnant occupies its UID")
    func serverMessageAbsentLocallyBecomesPresentDespiteForeignRemnantAtItsUid() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        // The user's archived message: still keyed by the INBOX UID it was
        // addressed under, sitting in Archive, epoch stamp cleared by the move.
        let movedId = try insertHeader(
            pool, messageId: "500", rfc822: "moved@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive",
            subject: "The user's archived message", bodyHTML: "<p>the user's body</p>")
        #expect(movedId == "acc1:INBOX:500")
        // Archive's OWN UID 500 is a DIFFERENT message and has no local row.
        #expect(try headers(pool, messageId: "500").count == 1,
                "precondition: the server's message is absent locally")

        let provider = await mock(
            [headerInfo(messageId: "500", rfc822: "native@example.com",
                        subject: "Archive's own message")],
            observedUidValidity: 202, folderPath: "Archive")
        _ = try await sync(pool, folderId: "acc1:Archive", provider: provider)

        // THE INVARIANT.
        let landed = try headers(pool, rfc822: "native@example.com")
        #expect(landed.count == 1,
                "the server reported this message in Archive and nothing local could be it — it must exist locally")
        guard landed.count == 1 else { return }
        #expect(landed[0].folderId == "acc1:Archive", "and it must be in the folder the server reported it in")
        #expect(landed[0].subject == "Archive's own message")
        #expect(landed[0].observedUidValidity == 202,
                "it carries the epoch bound to the serving FETCH, which is what makes it gesture-addressable")

        // The mirror image this admission must NOT produce: the user's moved
        // message is still here, unmerged, with its own identity and body.
        let moved = try header(pool, id: movedId)
        #expect(moved != nil, "the user's archived message must not be traded away for the incoming one")
        #expect(moved?.rfc822MessageId == "moved@example.com")
        #expect(moved?.folderPath == "Archive", "its optimistic move must not be undone")
        #expect(moved?.observedUidValidity == nil,
                "and it stays epoch-less, so `admittedOrdinaryActionTargets` keeps refusing gestures on it")
        #expect(try bodyHTML(pool, id: movedId) == "<p>the user's body</p>")
        #expect(try header(pool, id: movedId)?.subject == "The user's archived message",
                "its content must not be overwritten by the incoming message's")
    }

    /// The deliberately-held other side: without POSITIVE evidence that the
    /// retained row is a different message, the refusal stands. A remnant that
    /// carries no RFC identity might BE the incoming message, so admitting an
    /// insert there would risk a genuine duplicate — and, on the inbox, would
    /// hand the row to the pre-sync reclaim whose R15-F1 gate cannot exclude a
    /// nil stored identity, which deletes the user's moved row outright.
    /// Failing closed here costs visibility of one message; the alternative
    /// costs the user's message.
    @Test("An identity-less remnant keeps the refusal — no insert, and the remnant is untouched")
    func identitylessRemnantKeepsTheRefusal() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let movedId = try insertHeader(
            pool, messageId: "502", rfc822: nil,
            pkFolderPath: "INBOX", folderPath: "Archive",
            subject: "The user's archived message", bodyHTML: "<p>the user's body</p>")

        let provider = await mock(
            [headerInfo(messageId: "502", rfc822: "native@example.com",
                        subject: "Archive's own message")],
            observedUidValidity: 202, folderPath: "Archive")
        _ = try await sync(pool, folderId: "acc1:Archive", provider: provider)

        let rows = try headers(pool, messageId: "502")
        #expect(rows.count == 1,
                "no positive evidence of non-identity — the incoming message must not be admitted as a second row")
        #expect(try header(pool, id: movedId) != nil,
                "and the user's moved message must survive the refusal")
        #expect(try header(pool, id: movedId)?.subject == "The user's archived message")
        #expect(try bodyHTML(pool, id: movedId) == "<p>the user's body</p>")
    }

    /// The same hold from the other ambiguous direction: an incoming envelope
    /// with no Message-ID cannot prove non-identity either.
    @Test("An identity-less incoming envelope keeps the refusal")
    func identitylessIncomingEnvelopeKeepsTheRefusal() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let movedId = try insertHeader(
            pool, messageId: "503", rfc822: "moved@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive",
            subject: "The user's archived message")

        let provider = await mock(
            [headerInfo(messageId: "503", rfc822: nil, subject: "Archive's own message")],
            observedUidValidity: 202, folderPath: "Archive")
        _ = try await sync(pool, folderId: "acc1:Archive", provider: provider)

        let rows = try headers(pool, messageId: "503")
        #expect(rows.count == 1, "a nil incoming identity proves nothing — the refusal stands")
        #expect(try header(pool, id: movedId)?.rfc822MessageId == "moved@example.com")
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

        let provider = await mock(
            [headerInfo(messageId: "700", rfc822: nil)],
            observedUidValidity: 202, folderPath: "INBOX")
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        let row = try header(pool, id: id)
        #expect(row?.stableId == "durable@example.com",
                "an rfc-less fetch must not demote the row to a bare-UID stableId — that re-admits bare-UID gestures")
        #expect(row?.rfc822MessageId == "durable@example.com")
    }

    /// A provider-proven address owns the row even when RFC metadata changes.
    /// RFC is corroboration/metadata only and cannot veto the provider id.
    @Test("A provider-proven address accepts changed RFC metadata")
    func providerProvenAddressAcceptsChangedRfcMetadata() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let id = try insertHeader(
            pool, messageId: "800", rfc822: "stored@example.com",
            pkFolderPath: "INBOX", folderPath: "INBOX", subject: "Original subject")

        let provider = await mock(
            [headerInfo(messageId: "800", rfc822: "different@example.com", subject: "Server subject")],
            observedUidValidity: 202, folderPath: "INBOX")
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        let row = try header(pool, id: id)
        #expect(row?.rfc822MessageId == "different@example.com")
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

        let provider = await mock(
            [headerInfo(messageId: "810", rfc822: "enriched@example.com")],
            observedUidValidity: 202, folderPath: "INBOX")
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

    /// RFC agreement is not enough to reclaim an IMAP row whose membership
    /// proves it belongs to another mailbox. Fail closed and let sync heal it.
    @Test("An RFC-matching IMAP orphan is not reclaimed without provider-address proof")
    func sameRfcOrphanIsNotReclaimed() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let orphanId = try insertHeader(
            pool, messageId: "950", rfc822: "sameorphan@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive")

        let provider = await mock([headerInfo(messageId: "950", rfc822: "sameorphan@example.com")])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        let reclaimed = try header(pool, id: orphanId)
        #expect(reclaimed?.folderPath == "Archive")
        #expect(reclaimed?.folderId == "acc1:Archive")
    }

    /// A nil RFC supplies no substitute for provider-address proof either; the
    /// parked survivor stays untouched and retains its metadata.
    @Test("An rfc-less fetch cannot reclaim an unproven survivor")
    func nilRfcCannotReclaimUnprovenSurvivor() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try seedAccountAndFolders(pool)

        let orphanId = try insertHeader(
            pool, messageId: "960", rfc822: "keepme@example.com",
            pkFolderPath: "INBOX", folderPath: "Archive")

        let provider = await mock([headerInfo(messageId: "960", rfc822: nil)])
        _ = try await sync(pool, folderId: "acc1:INBOX", provider: provider)

        let reclaimed = try header(pool, id: orphanId)
        #expect(reclaimed?.folderPath == "Archive")
        #expect(reclaimed?.stableId == "keepme@example.com")
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
        // Failing closed may defer the incoming occupant until sync vacates the
        // ambiguous address; it must never cannibalise the moved-in row.
    }
}
