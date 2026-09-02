/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Pins the `bodyComplete` ↔ display-cache decoupling (2026-07-02):
///
/// 1. `BodyAssetMaintenance.dropMessage` (asset eviction) deletes the cached
///    `messageBody` row but NEVER touches `bodyComplete` — the old flip
///    re-enqueued every eviction victim into the backfill body queue, which
///    refetched the bodies, refilled the asset cache past its cap, and evicted
///    again (the "indexing goes backwards" loop).
/// 2. `SyncEngine.oneTimeBodyCompleteRestore` heals the rows damaged by the
///    pre-fix flips: pending rows whose FTS body text still exists (and that
///    have no cached HTML) flip back to `bodyComplete = 1` with zero network.
///
/// Tests run against the production `AppDatabase.dbPool` / `SearchIndex.shared`
/// (what the engine reads), with unique account-id prefixes for isolation and
/// row cleanup at the end — same pattern as `ConfirmGoneAtThresholdTests`.
@Suite("bodyComplete restore + eviction decoupling", .serialized, .processGlobalState)
struct BodyCompleteRestoreTests {

    private var index: SearchIndex { SearchIndex.shared }

    // MARK: - Fixtures

    /// Insert account + folder + header into the production pool. Returns headerId.
    private func insertHeader(
        accountId: String,
        messageId: String,
        bodyComplete: Bool,
        bodyEmptyConfirmed: Bool = false,
        bodyMetadataOversized: Bool = false
    ) async throws -> String {
        let folderPath = "Archive"
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        let headerId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: messageId)
        try await AppDatabase.dbPool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(emailAddress: "\(accountId)@example.com", displayName: "Test", provider: .gmail)
                account.id = accountId
                try account.insert(db)
            }
            if try Folder.fetchOne(db, key: folderId) == nil {
                let folder = Folder(name: folderPath, path: folderPath, role: .archive, accountId: accountId)
                try folder.insert(db)
            }
            var header = MessageHeader(
                messageId: messageId,
                subject: "restore test",
                from: "a@x", fromAddress: "a@x", to: "b@x",
                date: Date(), snippet: "",
                folderId: folderId, accountId: accountId, folderPath: folderPath,
                isInInbox: false
            )
            header.headerComplete = true
            header.bodyComplete = bodyComplete
            header.bodyEmptyConfirmed = bodyEmptyConfirmed
            header.bodyMetadataOversized = bodyMetadataOversized
            try header.insert(db)
        }
        return headerId
    }

    /// Index the header in FTS; optionally write real body text for it.
    private func indexInFTS(headerId: String, messageId: String, body: String?) async throws {
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: headerId),
            headerId: headerId,
            messageId: messageId,
            subject: "restore test",
            from: "a@x",
            to: "b@x",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        _ = try await index.indexHeaders([record])
        if let body {
            let written = try await index.updateBodies([(headerId: headerId, body: body)].map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })
            #expect(written.contains(ContentKey(rawValue: headerId)), "test setup: FTS body write must succeed")
        }
    }

    private func oversizedFlag(_ headerId: String) async -> Bool? {
        try? await AppDatabase.dbPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT bodyMetadataOversized FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
    }

    private func bodyCompleteFlag(_ headerId: String) async -> Bool? {
        try? await AppDatabase.dbPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
    }

    private func cleanup(headerId: String) async {
        try? await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
        try? await index.removeMessages( contentKeys: [headerId].map(ContentKey.init(rawValue:)))
    }

    /// Fresh, isolated defaults suite so the one-time gate never leaks across
    /// tests or into the real app defaults. Callers construct a NEW
    /// `UserDefaults(suiteName:)` instance per use — `UserDefaults` isn't
    /// `Sendable`, so a retained instance can't be sent into the SyncEngine
    /// actor and then reused (Swift 6 region isolation).
    private func makeDefaultsSuite() -> String {
        "test.bodyCompleteRestore.\(UUID().uuidString)"
    }

    private func engine() async -> SyncEngine {
        await AccountManager.shared.syncEngine
    }

    // MARK: - Restore heal

    @Test("Eviction victim (FTS body present, no cached HTML) is healed to bodyComplete=1")
    func evictionVictimHealed() async throws {
        let acct = "bcr-heal-\(UUID().uuidString.prefix(8))"
        let headerId = try await insertHeader(accountId: acct, messageId: "m1", bodyComplete: false)
        try await indexInFTS(headerId: headerId, messageId: "m1", body: "the full indexed body text of this message")

        let suite = makeDefaultsSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await engine().oneTimeBodyCompleteRestore(defaults: UserDefaults(suiteName: suite)!, scopePrefix: acct)

        #expect(await bodyCompleteFlag(headerId) == true, "FTS-backed pending row must be healed without refetch")
        #expect(UserDefaults(suiteName: suite)!.bool(forKey: SyncEngine.bodyCompleteRestoreDoneKey), "gate must be set after a clean pass")
        await cleanup(headerId: headerId)
    }

    /// 🚨 THE FIFTH CLEAR SITE. `oneTimeBodyCompleteRestore` is the only one of the five
    /// enumerated `bodyMetadataOversized` clearers that is not a body-fetch success write,
    /// and until this test it had NO coverage: deleting `, bodyMetadataOversized = 0` from
    /// its `UPDATE` left the whole suite green.
    ///
    /// Why it must clear: this row's body IS in FTS, so the restore is proving the message
    /// was fetched successfully at some point. Leaving the quarantine flag on it would
    /// contradict the row it just healed — `bodyComplete = 1` with the flag still set is
    /// precisely the state `isBodyQuarantined`'s `&& !bodyComplete` fail-safe exists to
    /// absorb, and relying on a fail-safe to cover a writer that could simply be correct is
    /// how a fail-safe stops being a fail-safe.
    ///
    /// Two-sided by construction: the SECOND row is a cached-HTML row, which the restore
    /// deliberately skips. It must KEEP its flag — a blanket clear would release every
    /// quarantined row in the account on a pass that healed none of them.
    @Test("The restore releases the oversized quarantine on the rows it heals — and only those")
    func restoreClearsTheOversizedFlagOnHealedRowsOnly() async throws {
        let acct = "bcr-oversized-\(UUID().uuidString.prefix(8))"
        let healed = try await insertHeader(
            accountId: acct, messageId: "m1", bodyComplete: false, bodyMetadataOversized: true)
        try await indexInFTS(headerId: healed, messageId: "m1", body: "the full indexed body text of this message")

        // Skipped by the restore: a cached `messageBody` row means this is a re-render
        // state, not an eviction victim.
        let skipped = try await insertHeader(
            accountId: acct, messageId: "m2", bodyComplete: false, bodyMetadataOversized: true)
        try await indexInFTS(headerId: skipped, messageId: "m2", body: "another indexed body")
        try await AppDatabase.dbPool.write { db in
            let body = MessageBody( contentKey: ContentKey(rawValue: skipped), htmlContent: "<p>cached</p>")
            try body.insert(db)
        }

        let suite = makeDefaultsSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await engine().oneTimeBodyCompleteRestore(defaults: UserDefaults(suiteName: suite)!, scopePrefix: acct)

        #expect(await bodyCompleteFlag(healed) == true, "fixture check: the eviction victim must be healed")
        #expect(await oversizedFlag(healed) == false,
                "a row the restore proves was fetched must lose the quarantine — otherwise the heal leaves a self-contradicting row that only the read-side fail-safe rescues")

        #expect(await bodyCompleteFlag(skipped) == false, "fixture check: the cached-HTML row must be skipped")
        #expect(await oversizedFlag(skipped) == true,
                "…and the clear must be scoped to the healed set: a blanket clear would release rows this pass proved nothing about")

        await cleanup(headerId: healed)
        await cleanup(headerId: skipped)
    }

    @Test("Row with cached HTML (messageBody present) is NOT healed — re-render states stay refetchable")
    func cachedHTMLSkipped() async throws {
        let acct = "bcr-cached-\(UUID().uuidString.prefix(8))"
        let headerId = try await insertHeader(accountId: acct, messageId: "m1", bodyComplete: false)
        try await indexInFTS(headerId: headerId, messageId: "m1", body: "indexed body text")
        try await AppDatabase.dbPool.write { db in
            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>cached</p>")
            try body.insert(db)
        }

        let suite = makeDefaultsSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await engine().oneTimeBodyCompleteRestore(defaults: UserDefaults(suiteName: suite)!, scopePrefix: acct)

        #expect(await bodyCompleteFlag(headerId) == false, "cache-present rows must be left for the queue to refetch")
        await cleanup(headerId: headerId)
    }

    @Test("Header-only FTS entry (no body text) is NOT healed")
    func headerOnlyFTSSkipped() async throws {
        let acct = "bcr-hdr-\(UUID().uuidString.prefix(8))"
        let headerId = try await insertHeader(accountId: acct, messageId: "m1", bodyComplete: false)
        try await indexInFTS(headerId: headerId, messageId: "m1", body: nil)

        let suite = makeDefaultsSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await engine().oneTimeBodyCompleteRestore(defaults: UserDefaults(suiteName: suite)!, scopePrefix: acct)

        #expect(await bodyCompleteFlag(headerId) == false, "no FTS body text → body genuinely still needs fetching")
        await cleanup(headerId: headerId)
    }

    @Test("bodyEmptyConfirmed rows are not candidates")
    func emptyConfirmedSkipped() async throws {
        let acct = "bcr-empty-\(UUID().uuidString.prefix(8))"
        let headerId = try await insertHeader(
            accountId: acct, messageId: "m1", bodyComplete: false, bodyEmptyConfirmed: true
        )
        try await indexInFTS(headerId: headerId, messageId: "m1", body: "text that should not matter")

        let suite = makeDefaultsSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await engine().oneTimeBodyCompleteRestore(defaults: UserDefaults(suiteName: suite)!, scopePrefix: acct)

        #expect(await bodyCompleteFlag(headerId) == false, "confirmed-empty rows are outside the pending population")
        await cleanup(headerId: headerId)
    }

    @Test("One-time gate: a second run is a no-op")
    func gateBlocksSecondRun() async throws {
        let acct = "bcr-gate-\(UUID().uuidString.prefix(8))"
        let headerId = try await insertHeader(accountId: acct, messageId: "m1", bodyComplete: false)
        try await indexInFTS(headerId: headerId, messageId: "m1", body: "indexed body text")

        let suite = makeDefaultsSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await engine().oneTimeBodyCompleteRestore(defaults: UserDefaults(suiteName: suite)!, scopePrefix: acct)
        #expect(await bodyCompleteFlag(headerId) == true)

        // Regress the row; the gated second run must NOT heal it again.
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyComplete = 0 WHERE id = ?", arguments: [headerId])
        }
        await engine().oneTimeBodyCompleteRestore(defaults: UserDefaults(suiteName: suite)!, scopePrefix: acct)
        #expect(await bodyCompleteFlag(headerId) == false, "gate set → second run must be a no-op")
        await cleanup(headerId: headerId)
    }

    @Test("contentKeysWithFTSBody: body-present vs header-only vs unindexed")
    func ftsBodyProbe() async throws {
        let acct = "bcr-probe-\(UUID().uuidString.prefix(8))"
        let withBody = try await insertHeader(accountId: acct, messageId: "b1", bodyComplete: false)
        let headerOnly = try await insertHeader(accountId: acct, messageId: "b2", bodyComplete: false)
        let unindexed = try await insertHeader(accountId: acct, messageId: "b3", bodyComplete: false)
        try await indexInFTS(headerId: withBody, messageId: "b1", body: "real body content here")
        try await indexInFTS(headerId: headerOnly, messageId: "b2", body: nil)

        let present = try await index.contentKeysWithFTSBody([withBody, headerOnly, unindexed].map(ContentKey.init(rawValue:)))
        #expect(present == [ContentKey(rawValue: withBody)])

        for id in [withBody, headerOnly, unindexed] { await cleanup(headerId: id) }
    }

    // MARK: - Eviction decoupling

    @Test("Asset eviction drops the cached messageBody row but NEVER touches bodyComplete")
    func evictionPreservesBodyComplete() async throws {
        let acct = "bcr-evict-\(UUID().uuidString.prefix(8))"
        let headerId = try await insertHeader(accountId: acct, messageId: "m1", bodyComplete: true)
        try await AppDatabase.dbPool.write { db in
            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>cached html with images</p>")
            try body.insert(db)
        }

        _ = await BodyAssetMaintenance.dropMessage( contentKey: ContentKey(rawValue: headerId), inlineCount: 1)

        let bodyRow: Bool = (try? await AppDatabase.dbPool.read { db in
            try MessageBody.fetchOne(db, key: headerId) != nil
        }) ?? true
        #expect(bodyRow == false, "cached HTML row must be dropped with its assets")
        #expect(await bodyCompleteFlag(headerId) == true,
                "eviction must NOT reset bodyComplete — that re-enqueues the row into the backfill body queue (the refetch loop)")
        await cleanup(headerId: headerId)
    }
}
