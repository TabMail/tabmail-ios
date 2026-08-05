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
            // Explicit since Stage D: the header delete above no longer cascades to
            // `messageBody`, so without this a suite would leak its own fixtures into
            // the shared production pool and the next run's global sweeps would see
            // them. Prefix-scoped, LIKE-escaped, exactly as `removeAccountRowsTxn`.
            try db.execute(
                sql: #"DELETE FROM messageBody WHERE id LIKE ? ESCAPE '\'"#,
                arguments: [MessageIdentity.escapeForLike(accountId) + ":%"])
            try db.execute(sql: "DELETE FROM folder WHERE accountId = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
        }
    }

    /// Seed a `messageBody` row, optionally backdated past the eviction TTL so
    /// `runEvictStaleBodies` will consider it. No hardcoded dates — the cutoff is
    /// computed from `Date()` exactly as the sweep computes its own.
    private func seedBody(key: ContentKey, html: String, ageHours: Int) async throws {
        let fetchedAt = Calendar.current.date(
            byAdding: .hour, value: -ageHours, to: Date()) ?? Date()
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText)
                VALUES (?, ?, NULL, ?, NULL)
                """, arguments: [key.rawValue, html, fetchedAt])
        }
    }

    private func bodyHTML(_ key: ContentKey) async -> String? {
        let fetched = try? await AppDatabase.dbPool.read { db in
            try MessageBody.fetchOne(db, key: key)
        }
        return fetched?.htmlContent
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
            data: Data(repeating: 7, count: 64),
            identityStamp: "rfc:quarantine-9002@example.com") != nil)

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
            data: Data(repeating: 3, count: 32),
            identityStamp: "rfc:dead-9003@example.com") != nil)

        let engine = SyncEngine()
        _ = try await engine.pruneFTSOrphans(scopePrefix: "\(accountId):")
        await BodyAssetMaintenance.pruneOrphans()

        #expect(await ftsRowid(key) == nil, "unowned FTS row must still be pruned")
        #expect(!manifestKeys().contains(key), "unowned asset rows must still be pruned")
        await cleanup(accountId: accountId, keys: [key])
    }

    // MARK: - #37 Stage D: the FOURTH sweep, and the body store

    /// 🚨 THE FOURTH SWEEP. Stage C's census gated `pruneFTSOrphans`,
    /// `backfillFolderIdsIfNeeded` and `BodyAssetMaintenance.pruneOrphans` and missed
    /// `runEvictStaleBodies`, because it is not an orphan sweep by name — it is a TTL
    /// cache evictor whose orphan branch (`no messageHeader holds this id` → delete)
    /// was unreachable while the `messageBody → messageHeader` FK cascade removed the
    /// row first. `v70_dropMessageBodyHeaderFK` is exactly what makes it reachable,
    /// which is why the gate ships with the migration and not after it.
    ///
    /// Two-sided by construction — an evictor that simply stopped deleting would fail
    /// the second half:
    ///
    /// - a stale orphan in a QUARANTINED folder must be KEPT (red without the gate);
    /// - a stale orphan nothing owns must STILL be evicted;
    /// - a stale orphan whose folder no longer exists must STILL be evicted — the
    ///   deliberate "unresolvable scope is not protected" rule, without which a
    ///   removed account's cached HTML would be a FOREVER leak rather than the
    ///   reclaimed-on-a-later-pass kind the fail-safe direction trades for;
    /// - a body a live header still holds must be KEPT, so the sweep is demonstrably
    ///   still doing its normal job around the new branch.
    ///
    /// The bounded wait is deliberate. `206ec48cf` had to repair a sibling sweep whose
    /// loop stopped terminating when the Stage C gate added a third per-row outcome;
    /// this sweep is cursored (`LIMIT/OFFSET`) and a KEEP counts as a SKIP, so the
    /// offset still advances — asserted here as an OUTCOME (the sweep returns) rather
    /// than by reading the loop.
    @Test("#37 — the stale-body evictor keeps what it cannot prove dead, and still reclaims what is")
    func evictStaleBodiesGatesItsOrphanLegAndStillReclaims() async throws {
        let accountId = "stageD-evict"
        try await seedScope(
            accountId: accountId, folderPath: "INBOX", provider: .imap, quarantined: true)
        try await seedScope(
            accountId: accountId, folderPath: "Archive", provider: .imap, quarantined: false)

        // Older than the TTL by a clear margin, computed from `Date()` — never a
        // hardcoded date.
        let staleHours = SyncConfig.bodyCacheTTLHours + 24

        // KEEP: orphan under a UIDVALIDITY quarantine.
        let quarantinedOrphan = ContentKey(rawValue: "\(accountId):INBOX:3701")
        try await seedBody(key: quarantinedOrphan, html: "<p>quarantined</p>", ageHours: staleHours)
        // EVICT: orphan in a live folder that nothing owns.
        let deadOrphan = ContentKey(rawValue: "\(accountId):Archive:3702")
        try await seedBody(key: deadOrphan, html: "<p>dead</p>", ageHours: staleHours)
        // EVICT: orphan whose folder does not exist at all — scope unresolvable.
        let ghostFolderOrphan = ContentKey(rawValue: "\(accountId):GhostFolder:3704")
        try await seedBody(key: ghostFolderOrphan, html: "<p>ghost</p>", ageHours: staleHours)
        // KEEP: a body a live header still holds.
        let liveHeader = try await seedHeader(
            accountId: accountId, folderPath: "Archive", messageId: "3703")
        let liveKey = ContentKey(rawValue: liveHeader.id)
        try await seedBody(key: liveKey, html: "<p>live</p>", ageHours: staleHours)

        let sweep = Task.detached(priority: .utility) {
            SyncEngine.runEvictStaleBodies(
                dbPool: AppDatabase.dbPool, undoProtectedBodyIds: [])
        }
        do {
            try await withTimeout(seconds: 30) { await sweep.value }
        } catch {
            sweep.cancel()
            throw error
        }

        #expect(await bodyHTML(quarantinedOrphan) == "<p>quarantined</p>",
                "a quarantined folder's cached body must survive the TTL evictor's orphan leg")
        #expect(await bodyHTML(liveKey) == "<p>live</p>",
                "a body a live header still holds must not be evicted")
        #expect(await bodyHTML(deadOrphan) == nil,
                "an orphan nothing owns must STILL be reclaimed")
        #expect(await bodyHTML(ghostFolderOrphan) == nil,
                "an orphan whose folder is gone must still be reclaimed — otherwise it leaks forever")

        await cleanup(
            accountId: accountId,
            keys: [quarantinedOrphan, deadOrphan, ghostFolderOrphan, liveKey])
    }

    /// Part 3 of Stage D: `.body` is no longer implicit. With the FK cascade gone,
    /// a routed site that deletes a header and wants its cached HTML reclaimed must
    /// say so — and must still be refused while the header is alive.
    ///
    /// RED with `.body` dropped from the `stores` set: the cached HTML survives a
    /// header that no longer exists, forever, because nothing else reclaims a key
    /// whose folder still resolves.
    ///
    /// Both directions in one test on purpose: a `releaseUnowned` that released
    /// unconditionally would satisfy the second assertion alone.
    @Test("Stage D — a routed release reclaims the cached body, and only once nothing owns it")
    func routedReleaseReclaimsTheBodyOnlyWhenUnowned() async throws {
        let accountId = "stageD-release"
        try await seedScope(accountId: accountId, folderPath: "INBOX", provider: .gmail)
        let header = try await seedHeader(
            accountId: accountId, folderPath: "INBOX", messageId: "rel1")
        let key = ContentKey(rawValue: header.id)
        try await seedBody(key: key, html: "<p>routed</p>", ageHours: 0)
        let scope = MessageContentStore.ContentKeyScope(
            accountId: accountId, folderPath: "INBOX", space: .stableProviderId)

        let releasedWhileOwned = await MessageContentStore.releaseUnowned(
            key, scope: scope, stores: [.searchIndex, .body])
        #expect(releasedWhileOwned == false, "an owned key must never be released")
        #expect(await bodyHTML(key) == "<p>routed</p>",
                "and its cached body must be untouched")

        try await AppDatabase.dbPool.write { db in
            _ = try MessageHeader.deleteOne(db, key: header.id)
        }
        #expect(await bodyHTML(key) == "<p>routed</p>",
                "precondition: with the v70 cascade gone, the header delete alone leaves the body behind")

        let releasedWhenUnowned = await MessageContentStore.releaseUnowned(
            key, scope: scope, stores: [.searchIndex, .body])
        #expect(releasedWhenUnowned == true, "an unowned key must be released")
        #expect(await bodyHTML(key) == nil,
                "the cached body must be reclaimed by the release — nothing else will")

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
            data: Data(repeating: 9, count: 128),
            identityStamp: "rfc:moved@example.com")
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
    /// release — a permanent, silent no-op that an outcome-only assertion on the
    /// BODY would not have caught while the `messageBody` FK cascade satisfied it
    /// either way. That cascade is gone at Stage D, but the reason to pin the order
    /// directly is not: it is the property, and the FTS store it is asserted on has
    /// never had a cascade to hide behind.
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
        try await seedBody(key: key, html: "<p>gone</p>", ageHours: 0)
        #expect(await ftsRowid(key) != nil, "precondition: indexed")

        await AccountManager.shared.deleteConfirmedGoneHeader(
            headerId: header.id, reason: "stage-C test")

        let stillThere = try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id) != nil
        }
        #expect(stillThere == false, "precondition: the header was deleted")
        #expect(await ftsRowid(key) == nil,
                "the orphaned search row must be released — only possible if owners were counted AFTER the commit")
        // Stage D: the FK cascade no longer reclaims the body either, so this routed
        // caller has to ask for `.body` explicitly. RED if it does not.
        #expect(await bodyHTML(key) == nil,
                "the orphaned cached body must be released too — no cascade does it any more")

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
            data: Data(repeating: 5, count: 48),
            identityStamp: "uid:77") != nil)

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

    // MARK: - The asset sweep's decision set, pinned as a whole

    /// THE SWEEP'S OUTPUT IS AN EXACT SET, and this asserts all four membership
    /// answers in ONE run so no leg can pass by a policy the others contradict.
    /// A manifest holding a live key, a protected-but-dead key, a dead key inside
    /// a resolvable scope and a dead key whose scope resolves to nothing must come
    /// out of `pruneOrphans()` holding exactly the first two.
    ///
    /// ⚑ WHY THIS IS AN INVARIANT TEST AND NOT A MECHANISM ONE (`MIS-015`). It says
    /// nothing about how the sweep decides — not which keys the ownership gate is
    /// asked about, not how many queries it issues, not that any particular helper
    /// was called. Re-implement the decision any way at all and this test still
    /// answers the only question that matters: did the user lose cached content
    /// that something still claims, and did content nothing claims get reclaimed.
    /// That is exactly the property a narrowing of the gate's INPUT must preserve,
    /// and it is why the same assertions hold identically before and after one.
    ///
    /// Sensitivity is not assumed — it is red-provable from both sides: drop
    /// `.subtracting(protected)` and the quarantined key dies; break the live-header
    /// probe and the live key dies; refuse everything and the two dead keys survive.
    @Test("Asset sweep decision set: exactly the dead, unprotected manifest keys are released")
    func assetSweepReleasesExactlyTheDeadUnprotectedKeys() async throws {
        let dir = try Self.makeAssetEnvironment()
        defer { Self.teardownAssets(dir) }
        let accountId = "stageC-asset-decision-set"
        try await seedScope(accountId: accountId, folderPath: "INBOX", provider: .imap)
        try await seedScope(
            accountId: accountId, folderPath: "Resetting", provider: .imap, quarantined: true)

        // 1. LIVE — a header still mints this key.
        let liveHeader = try await seedHeader(
            accountId: accountId, folderPath: "INBOX", messageId: "5001")
        let liveKey = ContentKey(rawValue: liveHeader.id)
        // 2. DEAD but PROTECTED — no header, but its folder is mid-UIDVALIDITY-reset.
        let quarantinedKey = ContentKey(rawValue: "\(accountId):Resetting:5002")
        // 3. DEAD, scope resolves, nothing owns it, no recovery (IMAP is not
        //    recoverable by provider id) — the sweep must reclaim it.
        let deadKey = ContentKey(rawValue: "\(accountId):INBOX:5003")
        // 4. DEAD and UNSCOPED — no `Folder` row claims this prefix. Deliberately
        //    NOT protected: protecting it would make a removed account's assets
        //    permanently unreclaimable.
        let unscopedKey = ContentKey(rawValue: "\(accountId):DeletedFolder:5004")

        for (index, key) in [liveKey, quarantinedKey, deadKey, unscopedKey].enumerated() {
            #expect(BodyAssetStore.writeAttachment(
                contentKey: key, section: "2", contentType: "application/pdf",
                data: Data(repeating: UInt8(index + 1), count: 32),
                identityStamp: "rfc:decision-\(index)@example.com") != nil)
        }
        let seeded = manifestKeys()
        #expect(seeded.contains(liveKey) && seeded.contains(quarantinedKey)
                && seeded.contains(deadKey) && seeded.contains(unscopedKey),
                "precondition: all four keys are in the manifest before the sweep")

        await BodyAssetMaintenance.pruneOrphans()

        let after = manifestKeys()
        #expect(after.contains(liveKey),
                "a key a live header still mints must never be released")
        #expect(after.contains(quarantinedKey),
                "a key whose folder is under a UIDVALIDITY quarantine must never be released")
        #expect(!after.contains(deadKey),
                "a key nothing owns, in a settled folder, must still be reclaimed")
        #expect(!after.contains(unscopedKey),
                "a key no folder claims must still be reclaimable — otherwise a removed account leaks forever")

        await cleanup(
            accountId: accountId,
            keys: [liveKey, quarantinedKey, deadKey, unscopedKey])
    }
    // MARK: - Batched release (2026-08-05 N+1 fix)

    /// An ISOLATED pool, so the two cases that have to break the schema (drop an
    /// index the ownership probe pins) cannot leave the shared production pool in
    /// that state for a peer suite.
    private struct IsolatedPool {
        let pool: DatabasePool
        let directory: URL
    }

    private func makeIsolatedPool() throws -> IsolatedPool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        return IsolatedPool(pool: pool, directory: directory)
    }

    /// ⚑ THE PLAN, NOT THE TIMING. `owners` runs once per key inside sweeps that
    /// hand it whole pages, and its predicate used to be
    /// `folderId = ? AND (rfc822MessageId = ? OR messageId = ?)` — whose plan
    /// collapses to a WALK OF THE WHOLE FOLDER when `sqlite_stat1` is empty, which
    /// is the ordinary state of a fresh install (`ANALYZE` has only ever run inside
    /// migration bodies, against an empty `messageHeader`). The invariant is that
    /// every arm probes on its OWN tail column, in whatever statistics regime: a
    /// plan step that constrains only `folderId=?`, or that SCANs, is the defect.
    ///
    /// Asserted against `MessageContentStore.ownersSQL` — the string the production
    /// path executes — so a rewrite that drops the hints cannot leave this green.
    @Test("The ownership probe is index-anchored on its tail column, with empty statistics")
    func ownershipProbePlanIsIndexAnchoredWithEmptyStatistics() async throws {
        let fixture = try makeIsolatedPool()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }

        let plan: [String] = try await fixture.pool.write { db in
            // The regime the fix is about: no statistics at all, so the planner has
            // nothing but the schema to go on.
            if try db.tableExists("sqlite_stat1") {
                try db.execute(sql: "DELETE FROM sqlite_stat1")
            }
            return try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN " + MessageContentStore.ownersSQL,
                arguments: ["acc:INBOX", "42", "42", "acc:INBOX"]
            ).map { $0["detail"] as String }
        }

        let steps = plan.filter { $0.contains("messageHeader") }
        #expect(steps.count == 2, "both arms must appear as their own step; got \(plan)")
        #expect(!plan.contains { $0.contains("SCAN") }, "no arm may scan the table; got \(plan)")
        #expect(
            steps.contains { $0.contains("messageId=?") },
            "the provider-id arm must probe on messageId; got \(plan)")
        #expect(
            steps.contains { $0.contains("rfc822MessageId=?") },
            "the RFC arm must probe on rfc822MessageId; got \(plan)")
        #expect(
            !steps.contains { step in
                step.contains("(folderId=?)") && !step.contains("messageId=?")
            },
            "an arm constrained only by folderId is a whole-folder walk; got \(plan)")
    }

    /// The batching must decide NOTHING collectively. One key in the page is still
    /// minted by a live header; the other two are not. The owned one must survive
    /// with its indexed body AND its cached body intact, and the other two must
    /// still be reclaimed in the same call.
    @Test("A batch releases the unowned keys and keeps the one a live header still mints")
    func batchReleasesTheUnownedAndKeepsTheOwned() async throws {
        let accountId = "batch-mixed-\(UUID().uuidString.prefix(8))"
        let folderPath = "INBOX"
        let folderId = try await seedScope(accountId: accountId, folderPath: folderPath, provider: .gmail)

        // Owned: a live header mints this key.
        let owned = try await seedHeader(accountId: accountId, folderPath: folderPath, messageId: "500")
        let ownedKey = ContentKey(rawValue: owned.id)
        // Unowned: FTS + body rows whose headers are already gone.
        let deadA = ContentKey(rawValue: "\(folderId):600")
        let deadB = ContentKey(rawValue: "\(folderId):601")

        for (key, body) in [(ownedKey, "owned body"), (deadA, "dead body A"), (deadB, "dead body B")] {
            try await seedFTSRow(key: key, messageId: String(key.rawValue.split(separator: ":").last!),
                                 folderId: folderId, body: body)
            try await seedBody(key: key, html: "<p>\(body)</p>", ageHours: 0)
        }

        let released = await MessageContentStore.releaseUnowned(
            [ownedKey, deadA, deadB], stores: [.searchIndex, .body])

        #expect(released == 2, "exactly the two unowned keys are released; got \(released)")
        #expect(await ftsBody(ownedKey) != nil, "a key a live header still mints must keep its indexed body")
        #expect(await bodyHTML(ownedKey) != nil, "a key a live header still mints must keep its cached body")
        #expect(await ftsBody(deadA) == nil, "an unowned key in the same batch must still be reclaimed")
        #expect(await ftsBody(deadB) == nil, "an unowned key in the same batch must still be reclaimed")
        #expect(await bodyHTML(deadA) == nil, "an unowned key's cached body must be reclaimed too")
        #expect(await bodyHTML(deadB) == nil, "an unowned key's cached body must be reclaimed too")

        await cleanup(accountId: accountId, keys: [ownedKey, deadA, deadB])
    }

    /// 🚨 `undetermined` IS NOT `unowned`, and batching must not blur that. The
    /// ownership probe pins two indexes BY NAME, so dropping one is a reachable way
    /// to make the probe throw; the verdict is then "could not decide", which KEEPS
    /// — which is also the statement that the `INDEXED BY` hints fail SAFE rather
    /// than silently degrading. The per-key semantics here are unchanged by the
    /// batch rewrite; this pins that they survived it. The seam the rewrite DID
    /// change is the roster read — see the sibling test below.
    @Test("A batch whose ownership probe cannot answer keeps every key")
    func batchKeepsEverythingWhenOwnershipCannotBeDecided() async throws {
        let fixture = try makeIsolatedPool()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let pool = PrioritizedDatabase(pool: fixture.pool, priority: .background)
        let accountId = "batch-undetermined"
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX")
        let dead = ContentKey(rawValue: "\(folderId):700")

        try await fixture.pool.write { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "T", provider: .gmail)
            account.id = accountId
            try account.insert(db)
            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
            try folder.insert(db)
            try db.execute(sql: """
                INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText)
                VALUES (?, '<p>keep me</p>', NULL, ?, NULL)
                """, arguments: [dead.rawValue, Date()])
            // Make the ownership probe unanswerable: it pins this index by name.
            try db.execute(sql: "DROP INDEX messageHeader_rfc822MessageId")
        }

        let released = await MessageContentStore.releaseUnowned([dead], stores: .body, pool: pool)
        #expect(released == 0, "an undecidable batch must release nothing; got \(released)")
        let survived = try await fixture.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messageBody WHERE id = ?",
                arguments: [dead.rawValue]) ?? 0
        }
        #expect(survived == 1, "content must be KEPT when ownership could not be decided")

        // And the obligation is not consumed: once the probe can answer again, the
        // same key is reclaimed.
        try await fixture.pool.write { db in
            try db.execute(
                sql: "CREATE INDEX messageHeader_rfc822MessageId ON messageHeader(rfc822MessageId)")
        }
        let releasedAfter = await MessageContentStore.releaseUnowned([dead], stores: .body, pool: pool)
        #expect(releasedAfter == 1, "a decidable pass must still reclaim it; got \(releasedAfter)")
    }
    /// ⚑ THE SEAM THE BATCH REWRITE ACTUALLY CHANGED, and the one place it is not
    /// behaviour-preserving. The old array overload read the folder roster as
    /// `(try? await pool.read { try Self.roster(db) }) ?? []`. An EMPTY roster makes
    /// every key resolve to "no folder claims this key", which is the branch that
    /// releases UNCONDITIONALLY — so a thrown roster read (a suspended or damaged
    /// database) deleted the whole page's content without ever asking the ownership
    /// question. That conflates *"nothing owns it"* with *"we could not ask"*, the
    /// exact distinction `Ownership` exists to keep. It now keeps, and keeping is
    /// recoverable: the sweeps re-run and reclaim on a later pass.
    ///
    /// The fault is injected at the roster read itself (`Folder.fetchAll`), not at
    /// the per-key probe, because that is the read whose failure handling changed.
    @Test("A batch whose folder-roster read fails keeps every key, rather than releasing all")
    func batchKeepsEverythingWhenTheRosterReadFails() async throws {
        let fixture = try makeIsolatedPool()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let pool = PrioritizedDatabase(pool: fixture.pool, priority: .background)
        let accountId = "batch-roster-throw"
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX")
        let dead = ContentKey(rawValue: "\(folderId):800")

        try await fixture.pool.write { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "T", provider: .gmail)
            account.id = accountId
            try account.insert(db)
            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
            try folder.insert(db)
            try db.execute(sql: """
                INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText)
                VALUES (?, '<p>keep me</p>', NULL, ?, NULL)
                """, arguments: [dead.rawValue, Date()])
            // Make the ROSTER read itself unanswerable.
            try db.execute(sql: "DROP TABLE messageHeader")
            try db.execute(sql: "DROP TABLE folder")
        }

        let released = await MessageContentStore.releaseUnowned([dead], stores: .body, pool: pool)
        #expect(released == 0, "a page whose roster could not be read must release nothing; got \(released)")
        let survived = try await fixture.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messageBody WHERE id = ?",
                arguments: [dead.rawValue]) ?? 0
        }
        #expect(survived == 1, "content must be KEPT when the roster could not be read")
    }
}
