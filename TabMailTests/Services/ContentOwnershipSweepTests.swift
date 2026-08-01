/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Stage C — `MessageContentStore` and the generalized orphan sweeps.
///
/// Every test here pins a SYSTEM PROPERTY ("the user's indexed body still
/// exists", "the surviving row's content was not evicted", "content nothing owns
/// is still reclaimed"), never a mechanism ("`removeMessages` was not called").
/// A mechanism-pinning test inherits a wrong spec's error and stays green on a
/// broken system.
///
/// Uses the production `AppDatabase.dbPool` and `SearchIndex.shared` singletons —
/// the things the sweeps actually operate on — scoped by a per-test account id
/// prefix, and cleans both up afterwards. `BodyAssetStore` is redirected to a
/// per-test temporary container + in-memory manifest.
@Suite("Stage C — content ownership gate on the orphan sweeps", .serialized, .processGlobalState)
struct ContentOwnershipSweepTests {

    // MARK: - Fixture

    private static func makeAssetEnvironment() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("contentOwnershipTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BodyAssetStore._setTestEnvironment(containerURL: dir, queue: try BodyAssetStore._makeTestQueue())
        return dir
    }

    private static func teardownAssets(_ dir: URL) {
        BodyAssetStore._resetForTesting()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Insert an account + folder. `quarantined` arms `uidValidityResetPendingAt`,
    /// the flag the `UIDVALIDITY` reset reaction sets while a folder's rows are
    /// being purged and re-synced.
    @discardableResult
    private func seedScope(
        accountId: String, folderPath: String, provider: AccountProvider,
        quarantined: Bool = false
    ) async throws -> String {
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        try await AppDatabase.dbPool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(
                    emailAddress: "\(accountId)@example.com", displayName: "Test", provider: provider)
                account.id = accountId
                try account.insert(db)
            }
            if try Folder.fetchOne(db, key: folderId) == nil {
                var folder = Folder(name: folderPath, path: folderPath, role: .inbox, accountId: accountId)
                folder.uidValidityResetPendingAt = quarantined ? Date() : nil
                try folder.insert(db)
            } else if var folder = try Folder.fetchOne(db, key: folderId) {
                folder.uidValidityResetPendingAt = quarantined ? Date() : nil
                try folder.update(db)
            }
        }
        return folderId
    }

    @discardableResult
    private func seedHeader(
        accountId: String, folderPath: String, messageId: String, rfc822: String? = nil
    ) async throws -> MessageHeader {
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        var header = MessageHeader(
            messageId: messageId,
            subject: "stage C fixture", from: "a", fromAddress: "a@example.com", to: "b@example.com",
            date: Date(), snippet: "",
            folderId: folderId, accountId: accountId, folderPath: folderPath,
            isInInbox: false
        )
        header.rfc822MessageId = rfc822
        let inserted = header
        try await AppDatabase.dbPool.write { db in try inserted.insert(db) }
        return inserted
    }

    /// Index an FTS row under `key` with real body text, WITHOUT a `messageHeader`
    /// row — the exact shape both sweeps classify as an orphan.
    private func seedFTSRow(
        key: ContentKey, messageId: String, folderId: String, body: String
    ) async throws {
        _ = try await SearchIndex.shared.indexHeaders([
            FTSHeaderRecord(
                contentKey: key, headerId: key.rawValue, messageId: messageId,
                subject: "stage C fixture", from: "a <a@example.com>",
                to: "b@example.com", cc: "", bcc: "",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000), folderId: folderId
            )
        ])
        try await SearchIndex.shared.updateBody(contentKey: key, body: body)
    }

    private func ftsBody(_ key: ContentKey) async -> String? {
        try? await SearchIndex.shared.bodyText(contentKey: key)
    }

    private func ftsRowid(_ key: ContentKey) async -> Int64? {
        try? await SearchIndex.shared.testRowidForHeader(key)
    }

    private func manifestKeys() -> Set<ContentKey> {
        BodyAssetStore.allManifestContentKeys()
    }

    private func cleanup(accountId: String, keys: [ContentKey]) async {
        try? await SearchIndex.shared.removeMessages(contentKeys: keys)
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE accountId = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM folder WHERE accountId = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
        }
    }

    // MARK: - R8: the sweeps do not mass-delete

    /// RED against the un-generalized sweep: before the quarantine term existed,
    /// this FTS row was not a `messageHeader.id`, so it was deleted outright and
    /// the user's indexed body was gone.
    ///
    /// The `UIDVALIDITY` reset reaction purges a folder's headers, re-stamps its
    /// epoch and re-syncs — and every abort leg deliberately leaves
    /// `uidValidityResetPendingAt` SET. So "headers purged, quarantine still armed"
    /// is a REACHABLE steady state, and it is exactly the window in which the
    /// relationship between a folder's content keys and its header ids is mid-flight.
    @Test("Quarantined folder: the FTS orphan sweep must not delete its indexed bodies")
    func quarantinedFolderSurvivesTheFTSSweep() async throws {
        let accountId = "stageC-fts-quarantine"
        let folderId = try await seedScope(
            accountId: accountId, folderPath: "INBOX", provider: .imap, quarantined: true)
        let key = ContentKey(rawValue: "\(accountId):INBOX:9001")
        try await seedFTSRow(key: key, messageId: "9001", folderId: folderId, body: "quarantined body text")

        let engine = SyncEngine()
        _ = try await engine.pruneFTSOrphans(scopePrefix: "\(accountId):")

        #expect(await ftsRowid(key) != nil,
                "a quarantined folder's FTS row must survive the orphan sweep")
        #expect(await ftsBody(key)?.contains("quarantined body text") == true,
                "the indexed body must be preserved, not merely the row")
        await cleanup(accountId: accountId, keys: [key])
    }

    /// RED against the un-generalized sweep, same reason, on the asset side.
    @Test("Quarantined folder: the asset orphan sweep must not delete its cached attachments")
    func quarantinedFolderSurvivesTheAssetSweep() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "stageC-asset-quarantine"
        try await seedScope(
            accountId: accountId, folderPath: "INBOX", provider: .imap, quarantined: true)
        let key = ContentKey(rawValue: "\(accountId):INBOX:9002")
        #expect(BodyAssetStore.writeAttachment(
            contentKey: key, section: "2", contentType: "application/pdf",
            data: Data(repeating: 7, count: 64)) != nil)

        await BodyAssetMaintenance.pruneOrphans()

        #expect(manifestKeys().contains(key),
                "a quarantined folder's cached attachments must survive the orphan sweep")
        await cleanup(accountId: accountId, keys: [key])
    }

    /// THE OVER-REFUSAL CONTROL. Without this, "never delete anything" would pass
    /// every other test in this suite. Content that genuinely has no owner — no
    /// header, no quarantine, no recovery — must STILL be reclaimed by both sweeps.
    @Test("Over-refusal control: genuinely unowned content is still released by both sweeps")
    func genuinelyDeadContentIsStillReleased() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "stageC-dead"
        let folderId = try await seedScope(
            accountId: accountId, folderPath: "INBOX", provider: .imap, quarantined: false)
        let key = ContentKey(rawValue: "\(accountId):INBOX:9003")
        try await seedFTSRow(key: key, messageId: "9003", folderId: folderId, body: "dead body text")
        #expect(BodyAssetStore.writeAttachment(
            contentKey: key, section: "2", contentType: "application/pdf",
            data: Data(repeating: 3, count: 32)) != nil)

        let engine = SyncEngine()
        _ = try await engine.pruneFTSOrphans(scopePrefix: "\(accountId):")
        await BodyAssetMaintenance.pruneOrphans()

        #expect(await ftsRowid(key) == nil, "unowned FTS row must still be pruned")
        #expect(!manifestKeys().contains(key), "unowned asset rows must still be pruned")
        await cleanup(accountId: accountId, keys: [key])
    }

    // MARK: - #43: a colon-bearing folder path defeated the recovery leg

    /// RED against `recoverMovedHeaderId`'s `components(separatedBy: ":")` +
    /// `guard parts.count == 3`. A folder path may legitimately contain a `':'`
    /// (RFC 3501 permits any hierarchy delimiter; Gmail/Outlook label names can
    /// contain one too), which made the key four components, failed the guard, and
    /// deleted the row instead of re-keying it — losing the indexed body AND the
    /// `messages_vec` embedding that rides on the same rowid.
    ///
    /// The rowid assertion is what proves the embedding survived: `rekeyHeaders`
    /// moves the key in place and keeps the rowid; delete-then-reinsert would not.
    @Test("#43 — a moved message in a ':'-bearing folder path is re-keyed, not deleted")
    func movedMessageInColonBearingFolderIsRekeyed() async throws {
        let accountId = "stageC-colon"
        let oldFolderPath = "Label:Sub"
        let newFolderPath = "Archive"
        let oldFolderId = try await seedScope(
            accountId: accountId, folderPath: oldFolderPath, provider: .gmail)
        try await seedScope(accountId: accountId, folderPath: newFolderPath, provider: .gmail)

        let providerMessageId = "msgABC"
        let oldKey = ContentKey(rawValue: "\(accountId):\(oldFolderPath):\(providerMessageId)")
        let newKey = ContentKey(rawValue: "\(accountId):\(newFolderPath):\(providerMessageId)")
        try await seedFTSRow(
            key: oldKey, messageId: providerMessageId, folderId: oldFolderId,
            body: "colon folder body text")
        let rowidBefore = await ftsRowid(oldKey)
        #expect(rowidBefore != nil, "precondition: the orphan is indexed")

        // The message MOVED: its header now lives under the new folder's key.
        try await seedHeader(
            accountId: accountId, folderPath: newFolderPath, messageId: providerMessageId)

        let engine = SyncEngine()
        _ = try await engine.pruneFTSOrphans(scopePrefix: "\(accountId):")

        #expect(await ftsRowid(oldKey) == nil, "the stale key must not remain")
        #expect(await ftsRowid(newKey) == rowidBefore,
                "the row must be RE-KEYED in place — an identical rowid is what proves the embedding survived")
        #expect(await ftsBody(newKey)?.contains("colon folder body text") == true,
                "the indexed body must ride along with the re-key")
        await cleanup(accountId: accountId, keys: [oldKey, newKey])
    }

    /// RED against HEAD: the asset sweep had NO recovery leg at all — it went
    /// straight from `subtracting` to `deleteAllAssets`. A moved message's cached
    /// inline images and attachments were deleted and re-downloaded.
    @Test("A moved message's cached assets are re-keyed, not deleted")
    func movedMessagesAssetsAreRekeyed() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "stageC-asset-move"
        try await seedScope(accountId: accountId, folderPath: "Label:Sub", provider: .gmail)
        try await seedScope(accountId: accountId, folderPath: "Archive", provider: .gmail)

        let providerMessageId = "msgMOVED"
        let oldKey = ContentKey(rawValue: "\(accountId):Label:Sub:\(providerMessageId)")
        let newKey = ContentKey(rawValue: "\(accountId):Archive:\(providerMessageId)")
        let assetId = BodyAssetStore.writeAttachment(
            contentKey: oldKey, section: "2", contentType: "application/pdf",
            data: Data(repeating: 9, count: 128))
        #expect(assetId != nil)
        try await seedHeader(
            accountId: accountId, folderPath: "Archive", messageId: providerMessageId)

        await BodyAssetMaintenance.pruneOrphans()

        let keys = manifestKeys()
        #expect(!keys.contains(oldKey), "the stale key must not remain in the manifest")
        #expect(keys.contains(newKey),
                "the moved message's cached attachment must be RE-KEYED, not deleted")
        // The bytes must still be readable through the row's own id — the files are
        // deliberately not moved, which is why every deletion path derives its
        // directory from `substr(id, …)` rather than re-hashing the key.
        if let assetId {
            #expect(BodyAssetStore.read(assetId: assetId) != nil,
                    "the cached bytes must survive the re-key")
        }
        await cleanup(accountId: accountId, keys: [oldKey, newKey])
    }

    // MARK: - R3: the ordering contract

    /// The ordering contract, pinned DIRECTLY rather than by outcome: the SAME key
    /// and the SAME scope must produce opposite verdicts either side of the header
    /// delete. A helper called before the commit sees an owner and can never
    /// release — a permanent, silent no-op that an outcome-only assertion would not
    /// catch, because the `messageBody` FK cascade satisfies it either way.
    @Test("Ordering contract — releaseUnowned refuses before the header delete and releases after")
    func releaseUnownedRefusesBeforeTheDeleteAndReleasesAfter() async throws {
        let accountId = "stageC-ordering"
        let folderId = try await seedScope(
            accountId: accountId, folderPath: "INBOX", provider: .gmail)
        let header = try await seedHeader(
            accountId: accountId, folderPath: "INBOX", messageId: "ord1")
        let key = ContentKey(rawValue: header.id)
        try await seedFTSRow(key: key, messageId: "ord1", folderId: folderId, body: "ordering body")

        let scope = MessageContentStore.ContentKeyScope(
            accountId: accountId, folderPath: "INBOX", space: .stableProviderId)

        // BEFORE the delete — one owner, so nothing may be released.
        let ownersBefore = try await AppDatabase.dbPool.read { db in
            try MessageContentStore.owners(of: key, scope: scope, db: db)
        }
        #expect(ownersBefore == [header.id], "the live header must be reported as the owner")
        let releasedBefore = await MessageContentStore.releaseUnowned(
            key, scope: scope, stores: .searchIndex)
        #expect(releasedBefore == false, "an owned key must never be released")
        #expect(await ftsRowid(key) != nil, "and its content must be untouched")

        // AFTER the delete — no owner, so the content is released.
        try await AppDatabase.dbPool.write { db in
            _ = try MessageHeader.deleteOne(db, key: header.id)
        }
        let ownersAfter = try await AppDatabase.dbPool.read { db in
            try MessageContentStore.owners(of: key, scope: scope, db: db)
        }
        #expect(ownersAfter.isEmpty, "the deleted header must no longer be an owner")
        let releasedAfter = await MessageContentStore.releaseUnowned(
            key, scope: scope, stores: .searchIndex)
        #expect(releasedAfter == true, "an unowned key must be released")
        #expect(await ftsRowid(key) == nil)

        await cleanup(accountId: accountId, keys: [key])
    }

    /// The same contract through a ROUTED CALLER, where the ordering is a property
    /// of the production code rather than of the test. Inverting
    /// `deleteConfirmedGoneHeader` to release before its delete transaction commits
    /// leaves this FTS row in place and turns the assertion red — the FTS index is
    /// a separate database, so no foreign-key cascade can satisfy it.
    @Test("Ordering contract — deleteConfirmedGoneHeader releases the search row it orphaned")
    @MainActor
    func deleteConfirmedGoneHeaderReleasesTheSearchRow() async throws {
        let accountId = "stageC-gone"
        let folderId = try await seedScope(
            accountId: accountId, folderPath: "INBOX", provider: .gmail)
        let header = try await seedHeader(
            accountId: accountId, folderPath: "INBOX", messageId: "gone1")
        let key = ContentKey(rawValue: header.id)
        try await seedFTSRow(key: key, messageId: "gone1", folderId: folderId, body: "gone body")
        #expect(await ftsRowid(key) != nil, "precondition: indexed")

        await AccountManager.shared.deleteConfirmedGoneHeader(
            headerId: header.id, reason: "stage-C test")

        let stillThere = try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id) != nil
        }
        #expect(stillThere == false, "precondition: the header was deleted")
        #expect(await ftsRowid(key) == nil,
                "the orphaned search row must be released — only possible if owners were counted AFTER the commit")

        await cleanup(accountId: accountId, keys: [key])
    }

    // MARK: - R2: releasing one of N must not evict the rest

    /// `DraftStore.pushDraftToServer`'s merge branch writes the SAME fresh
    /// `rfc822MessageId` onto BOTH the merged-away row and the surviving target row
    /// and then deletes the merged-away one. At Stage E1 both rows mint ONE content
    /// key, so releasing the merged-away key must not evict the survivor's content.
    ///
    /// Today the two keys are still distinct, so what this pins is the property that
    /// survives the flip: a release is scoped to the key it was asked about and is
    /// gated on that key's own owner set — never on "a header went away".
    @Test("Releasing a merged-away draft row does not evict the surviving row's content")
    func releasingMergedAwayRowDoesNotEvictTheSurvivor() async throws {
        let accountId = "stageC-merge"
        let folderId = try await seedScope(
            accountId: accountId, folderPath: "Drafts", provider: .gmail)
        let freshRfc = "fresh-draft@example.com"

        // The surviving target row (server-synced) and the merged-away placeholder.
        let survivor = try await seedHeader(
            accountId: accountId, folderPath: "Drafts", messageId: "realDraftId", rfc822: freshRfc)
        let mergedAway = try await seedHeader(
            accountId: accountId, folderPath: "Drafts", messageId: "draft-placeholder", rfc822: freshRfc)
        let survivorKey = ContentKey(rawValue: survivor.id)
        let mergedKey = ContentKey(rawValue: mergedAway.id)
        try await seedFTSRow(
            key: survivorKey, messageId: "realDraftId", folderId: folderId, body: "survivor body")
        try await seedFTSRow(
            key: mergedKey, messageId: "draft-placeholder", folderId: folderId, body: "merged body")

        // The merge: the placeholder header is deleted, the target survives.
        try await AppDatabase.dbPool.write { db in
            _ = try MessageHeader.deleteOne(db, key: mergedAway.id)
        }
        let released = await MessageContentStore.releaseUnowned(
            [mergedKey], stores: .searchIndex)

        #expect(released == 1, "the merged-away key had no owner and must be released")
        #expect(await ftsRowid(mergedKey) == nil)
        #expect(await ftsRowid(survivorKey) != nil,
                "the surviving row's content must NOT be evicted")
        #expect(await ftsBody(survivorKey)?.contains("survivor body") == true,
                "and its indexed body must be intact")

        await cleanup(accountId: accountId, keys: [survivorKey, mergedKey])
    }

    /// The exact-recomputation leg of `owners(of:scope:)`, which is what stops the
    /// index-backed SUPERSET from over-reporting ownership. A header whose
    /// `rfc822MessageId` equals the key's tail matches the superset predicate but
    /// does NOT mint that key, and counting it as an owner would leak the content
    /// forever.
    ///
    /// Two-sided on purpose: an `owners()` that simply always returned `[]` would
    /// satisfy the exclusion and every "must not delete" test in this suite, so the
    /// positive case is asserted against the SAME predicate in the same test.
    @Test("owners() excludes a superset match that mints a different key, and includes the real one")
    func ownersExcludesSupersetMatchThatMintsADifferentKey() async throws {
        let accountId = "stageC-superset"
        try await seedScope(accountId: accountId, folderPath: "INBOX", provider: .gmail)
        // This header's rfc822 IS the tail of the key under test — so it MATCHES the
        // index-backed superset predicate — but its own content key is
        // `…:INBOX:otherProviderId`, so it must not be counted as an owner.
        try await seedHeader(
            accountId: accountId, folderPath: "INBOX", messageId: "otherProviderId",
            rfc822: "decoy")
        let key = ContentKey(rawValue: "\(accountId):INBOX:decoy")
        let scope = MessageContentStore.ContentKeyScope(
            accountId: accountId, folderPath: "INBOX", space: .stableProviderId)

        let owners = try await AppDatabase.dbPool.read { db in
            try MessageContentStore.owners(of: key, scope: scope, db: db)
        }
        #expect(owners.isEmpty,
                "a row that matches the superset but mints a different key is NOT an owner")

        // NON-VACUITY: the row that genuinely mints this key IS reported.
        let realOwner = try await seedHeader(
            accountId: accountId, folderPath: "INBOX", messageId: "decoy")
        let ownersNow = try await AppDatabase.dbPool.read { db in
            try MessageContentStore.owners(of: key, scope: scope, db: db)
        }
        #expect(ownersNow == [realOwner.id],
                "the row that mints this key must be reported as its owner")

        await cleanup(accountId: accountId, keys: [key])
    }

    // MARK: - F4: a nil → rfc transition at steady state

    /// `rfc822MessageId` is MUTATED on live rows — an orchestrator census over
    /// `SET rfc822MessageId` plus `.rfc822MessageId = ` finds 33 production lines
    /// across 16 files. A nil → value transition moves a live row between key spaces
    /// at STEADY STATE, not only during a migration, which is why "offer to recovery
    /// before deleting" is a forever-invariant rather than a one-time condition.
    ///
    /// Pins the property that must hold across such a transition: the row's content
    /// is neither deleted nor stranded — it is still owned, and still found.
    @Test("F4 — a nil → rfc822 transition on a live row does not strand or delete its content")
    func rfcTransitionOnALiveRowDoesNotStrandContent() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "stageC-f4"
        let folderId = try await seedScope(
            accountId: accountId, folderPath: "INBOX", provider: .imap)
        let header = try await seedHeader(
            accountId: accountId, folderPath: "INBOX", messageId: "77", rfc822: nil)
        let key = ContentKey(rawValue: header.id)
        try await seedFTSRow(key: key, messageId: "77", folderId: folderId, body: "f4 body text")
        #expect(BodyAssetStore.writeAttachment(
            contentKey: key, section: "2", contentType: "application/pdf",
            data: Data(repeating: 5, count: 48)) != nil)

        // The steady-state transition: sync learns the RFC 822 Message-ID.
        try await AppDatabase.dbPool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET rfc822MessageId = ? WHERE id = ?",
                arguments: ["late-arrival@example.com", header.id])
        }

        let scope = MessageContentStore.ContentKeyScope(
            accountId: accountId, folderPath: "INBOX", space: .uidAddressed)
        let owners = try await AppDatabase.dbPool.read { db in
            try MessageContentStore.owners(of: key, scope: scope, db: db)
        }
        #expect(owners == [header.id],
                "the row must still own its content key across the transition")

        let engine = SyncEngine()
        _ = try await engine.pruneFTSOrphans(scopePrefix: "\(accountId):")
        await BodyAssetMaintenance.pruneOrphans()

        #expect(await ftsRowid(key) != nil, "the indexed body must survive the transition")
        #expect(await ftsBody(key)?.contains("f4 body text") == true)
        #expect(manifestKeys().contains(key), "the cached attachment must survive too")

        await cleanup(accountId: accountId, keys: [key])
    }

    // MARK: - #45: the third sweep must still terminate

    /// Purge everything a previous run may have left behind. These two tests seed a
    /// `messageHeader` and FTS rows that SURVIVE on purpose, so an aborted run (a
    /// red-proof, a cancelled suite) would otherwise collide on `messageHeader.id` or
    /// leave an already-backfilled FTS row behind.
    ///
    /// The `folderId = ''` sweep is GLOBAL — it pages over every such row in the
    /// index, not just this account's — so these tests must own that ENTIRE set. One
    /// protected row left behind by anyone else would be paged in first, correctly
    /// stop the sweep before it ever reached this fixture, and make the outcome depend
    /// on run history. Any row still carrying an empty folderId when this suite starts
    /// is abandoned by construction: every suite that seeds one holds the same
    /// process-global lock and cleans up after itself.
    private func purge(accountId: String) async {
        try? await SearchIndex.shared.removeMessagesForAccount(accountId: accountId)
        let strayEmptyFolderIdRows =
            (try? await SearchIndex.shared.contentKeysWithEmptyFolderId(limit: 100_000)) ?? []
        if !strayEmptyFolderIdRows.isEmpty {
            try? await SearchIndex.shared.removeMessages(contentKeys: strayEmptyFolderIdRows)
        }
        await cleanup(accountId: accountId, keys: [])
    }

    /// RED against HEAD. `backfillFolderIdsIfNeeded` is a `while true` whose only
    /// non-error exit is "no rows left with `folderId = ''`", and the query behind it
    /// is an UNCURSORED `SELECT … WHERE folderId = '' LIMIT ?`. Before the protection
    /// gate, every row of a page left that set on every pass, so the set shrank
    /// monotonically and the loop ended. The gate added a THIRD outcome — a protected
    /// orphan is neither given a folderId nor removed — so once the remaining rows are
    /// all protected the same page is returned forever and the loop spins at 10 Hz for
    /// the life of the process, with a fresh spinner launched after every account sync.
    ///
    /// It is a durable steady state, not a blip: `uidValidityResetPendingAt` is a
    /// PERSISTED column whose failure paths deliberately leave it armed for re-drive.
    ///
    /// Pins the END STATE, never the mechanism: the sweep RETURNS, the protected rows
    /// are still there with their bodies intact, and everything the sweep can
    /// legitimately do is still done. The bounded `withTimeout` is deliberate — a
    /// hung test that never returns would take the whole run down with it, which is
    /// strictly worse than a red one.
    @Test("#45 — the folderId backfill sweep terminates when the rows left are protected")
    func backfillFolderIdsTerminatesOnProtectedOrphans() async throws {
        let accountId = "stageC-backfill-term"
        await purge(accountId: accountId)
        // Quarantined: these orphans can be neither backfilled (no header mints them)
        // nor removed (protected) — exactly the third outcome that broke termination.
        try await seedScope(
            accountId: accountId, folderPath: "INBOX", provider: .imap, quarantined: true)
        let liveFolderId = try await seedScope(
            accountId: accountId, folderPath: "Archive", provider: .imap, quarantined: false)

        let protectedA = ContentKey(rawValue: "\(accountId):INBOX:4501")
        let protectedB = ContentKey(rawValue: "\(accountId):INBOX:4502")
        try await seedFTSRow(
            key: protectedA, messageId: "4501", folderId: "", body: "protectedbackfilltokenA body")
        try await seedFTSRow(
            key: protectedB, messageId: "4502", folderId: "", body: "protectedbackfilltokenB body")

        // NON-VACUITY, side 1: an orphan nothing owns must STILL be reclaimed. A loop
        // that simply exited on its first pass would pass every assertion above.
        let deadKey = ContentKey(rawValue: "\(accountId):Archive:4503")
        try await seedFTSRow(
            key: deadKey, messageId: "4503", folderId: "", body: "deadbackfilltoken body")

        // NON-VACUITY, side 2: a row a live header mints must STILL get its folderId.
        let liveHeader = try await seedHeader(
            accountId: accountId, folderPath: "Archive", messageId: "4504")
        let liveKey = ContentKey(rawValue: liveHeader.id)
        try await seedFTSRow(
            key: liveKey, messageId: "4504", folderId: "", body: "livebackfilltoken body")

        let engine = SyncEngine()
        let sweep = await engine.backfillFolderIdsIfNeeded()
        // THE INVARIANT. Pre-fix this never resolves and the timeout is what turns an
        // unterminating sweep into a test failure instead of a hung suite.
        try await withTimeout(seconds: 20) { await sweep.value }

        let stillEmpty = Set(try await SearchIndex.shared.contentKeysWithEmptyFolderId(limit: 500))

        // The protected rows are kept, still unassigned, and their content is intact —
        // the sweep stopped instead of deleting what it could not decide about.
        #expect(stillEmpty.contains(protectedA),
                "a protected orphan must keep its row rather than be forced out of the set")
        #expect(stillEmpty.contains(protectedB))
        #expect(await ftsRowid(protectedA) != nil,
                "a quarantined folder's FTS row must survive the backfill sweep")
        #expect(await ftsBody(protectedA)?.contains("protectedbackfilltokenA") == true,
                "the indexed body must be preserved, not merely the row")
        #expect(await ftsRowid(protectedB) != nil)

        // …and the work it CAN do was done: the unowned orphan is gone.
        #expect(await ftsRowid(deadKey) == nil,
                "an orphan nothing owns must still be reclaimed by the backfill sweep")
        #expect(!stillEmpty.contains(deadKey))

        // …and the live row left the set by being BACKFILLED, not by being deleted.
        #expect(await ftsRowid(liveKey) != nil, "the live header's FTS row must not be deleted")
        #expect(!stillEmpty.contains(liveKey),
                "a row whose header is alive must be given its folderId")
        let scoped = try await SearchIndex.shared.keywordSearch(
            query: "livebackfilltoken", folderIds: [liveFolderId])
        #expect(scoped.count == 1,
                "and the folderId written must be the header's own folder, not just any non-empty value")

        await cleanup(accountId: accountId, keys: [protectedA, protectedB, deadKey, liveKey])
    }

    /// The case that separates a MEASURED loop variant from a page-comparison one: a
    /// protected set LARGER than one page. `contentKeysWithEmptyFolderId` has no
    /// `ORDER BY`, so nothing guarantees the same subset comes back twice — "the page
    /// repeated" is therefore not a sound stop condition, while "the set did not
    /// shrink" is, whichever rows the query happens to hand over.
    ///
    /// Two-sided non-vacuity for the sweep's productive legs lives in the test above.
    /// What this one adds is that the exit does not depend on WHICH rows are paged in,
    /// and that termination is never bought by deleting protected content.
    ///
    /// It also pins a deliberate behaviour: when a whole page is protected the sweep
    /// STOPS rather than paging past it. That costs nothing — the pre-fix loop never
    /// got past such a page either, because the page is uncursored; it just spun on it
    /// forever instead of returning.
    @Test("#45 — the sweep terminates even when the protected set is larger than one page")
    func backfillFolderIdsTerminatesWhenProtectedSetExceedsOnePage() async throws {
        let accountId = "stageC-backfill-page"
        await purge(accountId: accountId)
        try await seedScope(
            accountId: accountId, folderPath: "INBOX", provider: .imap, quarantined: true)

        // Strictly more than one page, so no single page can hold the whole set.
        let overflow = SyncConfig.backfillChunkSize + 100
        let keys = (0..<overflow).map { ContentKey(rawValue: "\(accountId):INBOX:\(46000 + $0)") }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let indexed = try await SearchIndex.shared.indexHeaders(
            keys.enumerated().map { index, key in
                FTSHeaderRecord(
                    contentKey: key, headerId: key.rawValue, messageId: "\(46000 + index)",
                    subject: "stage C fixture", from: "a <a@example.com>",
                    to: "b@example.com", cc: "", bcc: "", dateMs: nowMs, folderId: "")
            })
        #expect(indexed == overflow, "precondition: the whole oversized set is indexed")

        let engine = SyncEngine()
        let sweep = await engine.backfillFolderIdsIfNeeded()
        // THE INVARIANT, with no assumption about which rows a page contains.
        try await withTimeout(seconds: 30) { await sweep.value }

        let stillEmpty = Set(try await SearchIndex.shared.contentKeysWithEmptyFolderId(
            limit: overflow + 500))
        #expect(keys.filter { stillEmpty.contains($0) }.count == overflow,
                "no protected row may be forced out of the set to make the loop terminate")
        if let first = keys.first { #expect(await ftsRowid(first) != nil) }
        if let last = keys.last { #expect(await ftsRowid(last) != nil) }

        await cleanup(accountId: accountId, keys: keys)
    }
}
