/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Production-boundary coverage for the Gmail arrival-date split (ADR-IOS-084):
/// the REAL `GmailProvider` against the fake Gmail REST boundary, the REAL
/// `SyncEngine.runSyncMessages` / `fetchOlderMessages`, and the REAL NSE staging
/// writers → decoder → merge. Every fixture deliberately REVERSES display order
/// and provider order (a recent `Received:` with an old `internalDate`), so a
/// reversion to display-date anchors or a dropped `providerDate` assignment is
/// observable at the store, not at a field.
private func wholeSeconds(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
}

/// Captured once per test so a fixture seeded before an `await` and an
/// expectation evaluated after it name the same instant even across a
/// whole-second boundary.
private struct FixtureClock {
    let now = wholeSeconds(Date())
    func daysAgo(_ d: Double) -> Date { wholeSeconds(now.addingTimeInterval(-d * 86_400)) }
}

private func receivedLine(_ at: Date) -> String {
    "from lists.example.org (lists.example.org. [192.0.2.5]) by mx.example.com with ESMTPS id abc; "
        + EmailDateParsing.rfc2822.string(from: at)
}

private func seed(_ id: String, internalDate: Date, received: Date?, labels: Set<String> = ["INBOX"]) -> StatefulGmailActionServer.Seed {
    StatefulGmailActionServer.Seed(
        rfc822MessageId: "\(id)@example.com", providerMessageId: id, labels: labels,
        internalDate: internalDate, received: received.map { [receivedLine($0)] } ?? []
    )
}

@Suite("Gmail arrival date — provider and sync boundaries", .serialized, .processGlobalState)
struct GmailReceivedDateBoundaryTests {

    // MARK: - GmailProvider ↔ REST boundary

    /// The transport contract: the metadata GET must ASK for `Received`, and the
    /// parsed header must carry the Received stamp as `date` and `internalDate`
    /// as `providerDate`. The fake honours `metadataHeaders=` exactly as Gmail
    /// does, so dropping the parameter would make `date` collapse onto
    /// `internalDate` and fail the first expectation — two-sided by the control
    /// message that has NO Received header and must fall back.
    @Test("fetchMessages requests Received and maps it to date, internalDate to providerDate")
    func providerRequestsReceivedAndSplitsTheDates() async throws {
        let clock = FixtureClock()
        let arrival = clock.daysAgo(0.5)
        let authored = clock.daysAgo(55)
        let plain = clock.daysAgo(3)
        let server = StatefulGmailActionServer(messages: [
            seed("list-post", internalDate: authored, received: arrival),
            seed("plain", internalDate: plain, received: nil),
        ])
        defer { server.close() }
        let headers = try await server.provider().fetchMessages(folder: "INBOX", limit: 10, offset: 0)
        let byId = Dictionary(uniqueKeysWithValues: headers.map { ($0.messageId, $0) })
        #expect(headers.count == 2)
        #expect(byId["list-post"]?.date == arrival)
        #expect(byId["list-post"]?.providerDate == authored)
        #expect(byId["list-post"]?.providerOrderDate == authored)
        #expect(byId["plain"]?.date == plain)
        #expect(byId["plain"]?.providerDate == plain)
        let metadataGets = server.http.recordedCalls().filter { $0.method == "GET" && $0.url.contains("/messages/") }
        #expect(metadataGets.count == 2)
        #expect(metadataGets.allSatisfy { $0.url.contains("metadataHeaders=Received") })
    }

    // MARK: - SyncEngine.runSyncMessages (the .date stale window at the STORE)

    private static func makeGmailAccount(pool: DatabasePool, accountId: String) throws -> Folder {
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        return try #require(try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))
    }

    private static func insertLocal(
        pool: DatabasePool, accountId: String, messageId: String, date: Date, providerDate: Date,
        folderId: String? = nil, rfc822: String? = nil
    ) throws {
        try pool.write { db in
            var header = MessageHeader(
                messageId: messageId, subject: "local \(messageId)", from: "Sender",
                fromAddress: "sender@example.com", to: "recipient@example.com", date: date,
                snippet: "", folderId: folderId ?? "\(accountId):INBOX", accountId: accountId,
                folderPath: "INBOX", isInInbox: true, providerDate: providerDate
            )
            header.rfc822MessageId = rfc822 ?? "\(messageId)@example.com"
            try header.insert(db)
        }
    }

    private static func localRows(pool: DatabasePool, accountId: String) throws -> [String: MessageHeader] {
        try pool.read { db in
            let rows = try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX").fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.messageId, $0) })
        }
    }

    /// INVARIANT at the store: a full-sync page is Gmail's newest-N by
    /// `internalDate`. A local row whose `internalDate` is below that page's
    /// floor is outside the window and must survive however recent its
    /// Received-derived `date` is (the list message). A local row whose
    /// `internalDate` is inside the window and absent from the page is gone
    /// from the server and must be reclaimed. New rows land with the split
    /// dates, and a refreshed existing row keeps `providerDate == internalDate`.
    @Test("runSyncMessages keeps the out-of-window list message, reclaims in-window ghosts, writes split dates")
    func runSyncMessagesWindowsByProviderDate() async throws {
        let clock = FixtureClock()
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-window"
        let folder = try Self.makeGmailAccount(pool: pool, accountId: accountId)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "ARCHIVE", role: .archive, pool: pool)

        // Server: three messages fill the page (limit 3) in internalDate order
        // 1d, 2d, 3d — but their Received stamps (0.75d, 0.5d, 1.5d) are all
        // NEWER than the provider floor, so the display floor (1.5d) is newer
        // than the provider floor (3d). A candidate query cut on the display
        // floor would therefore admit fewer rows (both ghosts sit between 1.5d
        // and 3d on the provider axis) and keep them; any `info.date` written
        // where the provider key belongs changes the stored result. The list post has the OLDEST internalDate
        // but the NEWEST arrival and is never on the page.
        let server = StatefulGmailActionServer(messages: [
            seed("n1", internalDate: clock.daysAgo(1), received: clock.daysAgo(0.75)),
            seed("n2", internalDate: clock.daysAgo(2), received: clock.daysAgo(0.5)),
            seed("n3", internalDate: clock.daysAgo(3), received: clock.daysAgo(1.5)),
            seed("list-post", internalDate: clock.daysAgo(55), received: clock.daysAgo(0.25)),
        ])
        defer { server.close() }

        // Local rows:
        //  list-post   — providerDate below the page floor (3d): must SURVIVE.
        //  ghost       — providerDate 2.5d: inside the provider window (floor 3d),
        //                OUTSIDE a display-floor window (1.5d); absent from the
        //                page: reclaimed (a display-floor cutoff would keep it).
        //  ghost-old   — display date far OUTSIDE the window, providerDate inside
        //                it, absent from the page: reclaimed (a display-date floor
        //                or column would keep it).
        //  n2          — stale copy to refresh: both dates rewritten.
        //  n1          — an orphan of the same canonical id parked under the
        //                ARCHIVE folderId (a no-op optimistic move): reclaimed in
        //                place with the fetched split dates.
        try Self.insertLocal(pool: pool, accountId: accountId, messageId: "list-post", date: clock.daysAgo(0.25), providerDate: clock.daysAgo(55))
        try Self.insertLocal(pool: pool, accountId: accountId, messageId: "ghost", date: clock.daysAgo(2.5), providerDate: clock.daysAgo(2.5))
        try Self.insertLocal(pool: pool, accountId: accountId, messageId: "ghost-old", date: clock.daysAgo(40), providerDate: clock.daysAgo(2.5))
        try Self.insertLocal(pool: pool, accountId: accountId, messageId: "n2", date: clock.daysAgo(9), providerDate: clock.daysAgo(9))
        try Self.insertLocal(pool: pool, accountId: accountId, messageId: "n1", date: clock.daysAgo(20), providerDate: clock.daysAgo(20),
                             folderId: "\(accountId):ARCHIVE")

        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: server.provider(), limit: 3, dbPool: PrioritizedDatabase(pool: pool))

        let rows = try Self.localRows(pool: pool, accountId: accountId)
        #expect(rows["list-post"] != nil, "the list message (internalDate below the page floor) must survive the .date window")
        #expect(rows["ghost"] == nil, "a row inside the internalDate window that the page did not return is reclaimed")
        #expect(rows["ghost-old"] == nil, "the window is keyed on providerDate: an old display date does not shelter an in-window ghost")
        #expect(rows["n1"]?.date == clock.daysAgo(0.75), "orphan reclaimed into INBOX with the Received-derived date")
        #expect(rows["n1"]?.providerDate == clock.daysAgo(1), "orphan reclaimed with internalDate as the provider key")
        #expect(rows["n2"]?.date == clock.daysAgo(0.5), "refresh rewrites the display date from Received")
        #expect(rows["n2"]?.providerDate == clock.daysAgo(2), "refresh rewrites providerDate from internalDate")
        #expect(rows["n3"]?.date == clock.daysAgo(1.5), "new row: display date from Received")
        #expect(rows["n3"]?.providerDate == clock.daysAgo(3), "new row: provider key from internalDate")
        let total = try await pool.read { try MessageHeader.filter(Column("accountId") == accountId).fetchCount($0) }
        #expect(total == 4, "n1, n2, n3 and the list post; no duplicate for the reclaimed orphan")
    }

    /// The RFC-ID row-reuse writer (`MessageHeaderRekey.apply` via the UID-remap
    /// arm of `runSyncMessages`): a stale local row whose RFC Message-ID
    /// matches a NEW provider id on the page is migrated in place rather than
    /// deleted, and the migrated row must take the fetched split dates. The
    /// fetched pair is reversed (display 0.5d, provider 2d) against the stale
    /// row's own pair (10d/10d), so copying `info.date` into either column, or
    /// keeping the old row's dates, is observable.
    @Test("runSyncMessages RFC-ID remap migrates the row with the fetched split dates")
    func runSyncMessagesRfcRemapCarriesSplitDates() async throws {
        let clock = FixtureClock()
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-remap"
        let folder = try Self.makeGmailAccount(pool: pool, accountId: accountId)
        let rfc = "remapped@example.com"
        // Old provider id, inside the window (so stale selection sees it), absent from the page.
        try Self.insertLocal(pool: pool, accountId: accountId, messageId: "old-id", date: clock.daysAgo(10), providerDate: clock.daysAgo(10), rfc822: rfc)
        try Self.insertLocal(pool: pool, accountId: accountId, messageId: "control", date: clock.daysAgo(11), providerDate: clock.daysAgo(11))
        let server = StatefulGmailActionServer(messages: [
            StatefulGmailActionServer.Seed(
                rfc822MessageId: rfc, providerMessageId: "new-id", labels: ["INBOX"],
                internalDate: clock.daysAgo(2), received: [receivedLine(clock.daysAgo(0.5))]),
            seed("control", internalDate: clock.daysAgo(11), received: clock.daysAgo(11)),
            seed("floor", internalDate: clock.daysAgo(12), received: clock.daysAgo(12)),
        ])
        defer { server.close() }

        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: server.provider(), limit: 3, dbPool: PrioritizedDatabase(pool: pool))

        let rows = try Self.localRows(pool: pool, accountId: accountId)
        #expect(rows["old-id"] == nil, "the old provider id is retired by the remap")
        #expect(rows["new-id"]?.rfc822MessageId == rfc)
        #expect(rows["new-id"]?.date == clock.daysAgo(0.5), "migrated row: display date from the fetched Received")
        #expect(rows["new-id"]?.providerDate == clock.daysAgo(2), "migrated row: provider key from the fetched internalDate")
        #expect(rows["control"]?.date == clock.daysAgo(11))
        #expect(rows["control"]?.providerDate == clock.daysAgo(11))
        #expect(rows.count == 3, "new-id, control, floor — exactly one row for the remapped identity")
    }

    // MARK: - SyncEngine.fetchOlderMessages (the Gmail before: cutoff)

    /// The `before:` cutoff is Gmail's own key. Two local anchors with OPPOSITE
    /// orders: A is oldest by display date (30d) but recent by internalDate (2d);
    /// B is recent by display date (1d) but oldest by internalDate (8d). The
    /// cutoff must be B's providerDate (8d): the server's older message
    /// (internalDate 10d) is returned under that cutoff and NOT under A's
    /// display date (30d), so an ORDER BY on the wrong column leaves the folder
    /// looking exhausted.
    @Test("fetchOlderMessages anchors before: on the oldest providerDate and persists split dates")
    func fetchOlderMessagesAnchorsOnProviderDate() async throws {
        let clock = FixtureClock()
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-older"
        let folder = try Self.makeGmailAccount(pool: pool, accountId: accountId)
        try Self.insertLocal(pool: pool, accountId: accountId, messageId: "anchor-a", date: clock.daysAgo(30), providerDate: clock.daysAgo(2))
        try Self.insertLocal(pool: pool, accountId: accountId, messageId: "anchor-b", date: clock.daysAgo(1), providerDate: clock.daysAgo(8))

        let server = StatefulGmailActionServer(messages: [
            seed("anchor-a", internalDate: clock.daysAgo(2), received: clock.daysAgo(30)),
            seed("anchor-b", internalDate: clock.daysAgo(8), received: clock.daysAgo(1)),
            seed("older", internalDate: clock.daysAgo(10), received: clock.daysAgo(0.5)),
        ])
        defer { server.close() }
        let provider = server.provider()
        let engine = await Self.registeredEngine(accountId: accountId, provider: provider)

        let result = try await engine.fetchOlderMessages(folders: [folder])
        #expect(result.inserted == 1)
        let rows = try Self.localRows(pool: pool, accountId: accountId)
        #expect(rows["older"]?.date == clock.daysAgo(0.5))
        #expect(rows["older"]?.providerDate == clock.daysAgo(10))
        let lists = server.http.recordedCalls().filter { $0.method == "GET" && $0.url.contains("before") }
        #expect(lists.count == 1)
        let cutoff = Int(clock.daysAgo(8).timeIntervalSince1970)
        #expect(lists.first?.url.contains("before%3A\(cutoff)") == true || lists.first?.url.contains("before:\(cutoff)") == true,
                "cutoff is the oldest providerDate (anchor-b), not the oldest display date (anchor-a)")
    }

    // MARK: - SyncEngine.runBackfill (page walk + insertBackfillBatchGuardable)

    private static func registeredEngine(accountId: String, provider: GmailProvider) async -> SyncEngine {
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
        return engine
    }

    /// The Gmail backfill walk: a page of ids → `insertBackfillBatchGuardable`
    /// (rows must land with the split dates) → `oldestSyncedDate` anchored on
    /// the oldest PROVIDER key of the fetched page. Display order is reversed
    /// against provider order, so an anchor taken from `date` would land on a
    /// different message. The second account exercises the all-existing arm
    /// (`min(providerDate)` over the page's ids) the same way.
    @Test("runBackfill inserts split dates and anchors oldestSyncedDate on provider order")
    func runBackfillAnchorsOnProviderOrder() async throws {
        let clock = FixtureClock()
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let server = StatefulGmailActionServer(messages: [
            seed("m1", internalDate: clock.daysAgo(20), received: clock.daysAgo(1)),
            seed("m2", internalDate: clock.daysAgo(5), received: clock.daysAgo(30)),
            seed("m3", internalDate: clock.daysAgo(10), received: clock.daysAgo(10)),
        ])
        defer { server.close() }
        let provider = server.provider()

        // Fresh folder: every id is missing → the fetched-chunk insert path.
        let freshId = "gm-backfill-fresh"
        let freshAccount = try FolderEpochTestFixture.makeAccount(id: freshId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: freshId, path: "INBOX", role: .inbox, pool: pool)
        let freshEngine = await Self.registeredEngine(accountId: freshId, provider: provider)
        _ = await freshEngine.runBackfill(account: freshAccount)

        let rows = try Self.localRows(pool: pool, accountId: freshId)
        #expect(rows.count == 3)
        #expect(rows["m1"]?.date == clock.daysAgo(1))
        #expect(rows["m1"]?.providerDate == clock.daysAgo(20))
        #expect(rows["m2"]?.date == clock.daysAgo(30))
        #expect(rows["m2"]?.providerDate == clock.daysAgo(5))
        let freshFolder = try #require(try FolderEpochTestFixture.readFolder(accountId: freshId, path: "INBOX", pool: pool))
        #expect(freshFolder.oldestSyncedDate == clock.daysAgo(20), "anchor is the oldest internalDate on the page, not the oldest Received")
        #expect(freshFolder.backfillComplete)

        // Pre-populated folder: every id already exists → the all-existing arm.
        let existingId = "gm-backfill-existing"
        let existingAccount = try FolderEpochTestFixture.makeAccount(id: existingId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: existingId, path: "INBOX", role: .inbox, pool: pool)
        try Self.insertLocal(pool: pool, accountId: existingId, messageId: "m1", date: clock.daysAgo(1), providerDate: clock.daysAgo(20))
        try Self.insertLocal(pool: pool, accountId: existingId, messageId: "m2", date: clock.daysAgo(30), providerDate: clock.daysAgo(5))
        try Self.insertLocal(pool: pool, accountId: existingId, messageId: "m3", date: clock.daysAgo(10), providerDate: clock.daysAgo(10))
        let existingEngine = await Self.registeredEngine(accountId: existingId, provider: provider)
        _ = await existingEngine.runBackfill(account: existingAccount)
        let existingFolder = try #require(try FolderEpochTestFixture.readFolder(accountId: existingId, path: "INBOX", pool: pool))
        #expect(existingFolder.oldestSyncedDate == clock.daysAgo(20))
        #expect(existingFolder.backfillComplete)
    }

    // MARK: - SyncEngine.fullSync (initial oldestSyncedDate anchor)

    /// `fullSync` anchors a folder's `oldestSyncedDate` on the Nth most recent
    /// row in PROVIDER order (N = `SyncConfig.syncMessageLimit`). Seed N+1
    /// messages whose Received order is the reverse of their internalDate
    /// order: the page is the N newest by internalDate, and the anchor must be
    /// the Nth internalDate, not the Nth Received stamp. The fake serves the
    /// INBOX system label so folder reconciliation keeps the seeded folder.
    @Test("fullSync anchors the initial oldestSyncedDate on the Nth providerDate")
    func fullSyncAnchorsOldestSyncedDateOnProviderOrder() async throws {
        let clock = FixtureClock()
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let n = SyncConfig.syncMessageLimit
        let seeds = (1...(n + 1)).map { i in
            seed("m\(i)", internalDate: clock.daysAgo(Double(i)), received: clock.daysAgo(Double(n + 10 - i)))
        }
        let server = StatefulGmailActionServer(messages: seeds, systemLabels: ["INBOX"])
        defer { server.close() }
        let provider = server.provider()
        let accountId = "gm-fullsync"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        let engine = await Self.registeredEngine(accountId: accountId, provider: provider)
        try await engine.fullSync(account: account, provider: provider)

        let rows = try Self.localRows(pool: pool, accountId: accountId)
        #expect(rows.count == n, "the page is the N newest by internalDate")
        #expect(rows["m\(n + 1)"] == nil, "the oldest internalDate (newest Received) is off the page")
        #expect(rows["m1"]?.date == clock.daysAgo(Double(n + 9)))
        #expect(rows["m1"]?.providerDate == clock.daysAgo(1))
        let folder = try #require(try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))
        #expect(folder.oldestSyncedDate == clock.daysAgo(Double(n)), "Nth providerDate, not the Nth Received stamp")
    }

    // MARK: - SyncEngine.gmailDeltaSync (history → new row)

    /// The delta arm's own `MessageHeader` constructor: a `messagesAdded`
    /// history record for a message whose Received stamp is recent and whose
    /// internalDate is old must land with both keys split.
    @Test("gmailDeltaSync materializes a history-added row with split dates")
    func gmailDeltaSyncNewRowCarriesSplitDates() async throws {
        let clock = FixtureClock()
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "gm-delta"
        var account = Account(emailAddress: "\(accountId)@example.com", displayName: "delta fixture", provider: .gmail)
        account.id = accountId
        account.lastHistoryId = "1000"
        let toInsert = account
        try await pool.write { db in try toInsert.insert(db) }
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "ARCHIVE", role: .archive, pool: pool)
        // An orphan of the INBOX canonical id parked under the ARCHIVE folderId
        // (a no-op optimistic move): the delta arm's orphan-reclaim writer must
        // update it in place with the fetched split dates, not its own 20d/20d.
        try Self.insertLocal(pool: pool, accountId: accountId, messageId: "orphan", date: clock.daysAgo(20), providerDate: clock.daysAgo(20),
                             folderId: "\(accountId):ARCHIVE")

        let server = StatefulGmailActionServer(messages: [
            seed("pushed", internalDate: clock.daysAgo(30), received: clock.daysAgo(0.5)),
            seed("orphan", internalDate: clock.daysAgo(3), received: clock.daysAgo(0.75)),
        ])
        defer { server.close() }
        server.http.register(path: "/history", method: "GET", response: .json(raw: """
            { "historyId": "1001", "history": [
                { "messagesAdded": [ { "message": { "id": "pushed" } } ] },
                { "messagesAdded": [ { "message": { "id": "orphan" } } ] }
            ] }
            """))

        let outcome = try await SyncEngine().performDeltaSync(account: account, provider: server.provider())
        #expect(outcome.succeeded)
        let rows = try Self.localRows(pool: pool, accountId: accountId)
        #expect(rows["pushed"]?.date == clock.daysAgo(0.5), "new row: display date from Received")
        #expect(rows["pushed"]?.providerDate == clock.daysAgo(30), "new row: provider key from internalDate")
        #expect(rows["orphan"]?.date == clock.daysAgo(0.75), "reclaimed orphan: display date from Received")
        #expect(rows["orphan"]?.providerDate == clock.daysAgo(3), "reclaimed orphan: provider key from internalDate")
        let total = try await pool.read { try MessageHeader.filter(Column("accountId") == accountId).fetchCount($0) }
        #expect(total == 2, "the orphan was reclaimed in place, not duplicated")
    }

    // MARK: - GmailNSEClient.fetchSingleMessage (the NSE adapter)

    /// The real NSE adapter over the fake REST boundary: `NSEMessageMetadata`
    /// must carry the Received-derived `date` and `internalDate` as
    /// `providerDate`, and the two must survive the staging writer + decoder.
    @Test("GmailNSEClient.fetchSingleMessage carries providerDate into staging")
    func nseAdapterCarriesProviderDate() async throws {
        let clock = FixtureClock()
        let accountId = "nse-received-" + UUID().uuidString
        let store = ProviderCredentialStore.shared
        _ = try store.install(accountId: accountId, tokens: .init(
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
            expiresAt: clock.now.addingTimeInterval(3_600)))
        defer { try? store.remove(accountId: accountId) }
        let arrival = clock.daysAgo(0.25)
        let authored = clock.daysAgo(55)
        let server = StatefulGmailActionServer(messages: [
            seed("push-1", internalDate: authored, received: arrival),
        ])
        defer { server.close() }

        let meta = await AuthedHTTP.$sessionOverride.withValue(server.http.session) {
            await GmailNSEClient.fetchSingleMessage(
                messageId: "push-1", accessToken: "", refreshToken: nil, accountId: accountId)
        }
        let staged = try #require(meta)
        #expect(staged.date == arrival)
        #expect(staged.providerDate == authored)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        #expect(AppDatabase.createNSEStagingDB(atPath: path))
        let queue = try DatabaseQueue(path: path)
        NSEStagingDB.ensureObservedUidValidityColumn(db: queue)
        NSEStagingDB.ensureProviderDateColumn(db: queue)
        NSEStagingDB.stageHeader(db: queue, accountId: accountId, accountEmail: "user@example.com", provider: "gmail", message: staged, historyId: "1")
        let row = try Self.decodeStaged(queue, id: "\(accountId):push-1")
        #expect(row.date == arrival.timeIntervalSince1970)
        #expect(row.providerDate == authored.timeIntervalSince1970)
    }

    // MARK: - NSE staging round trip

    private static func stagedMetadata(messageId: String, date: Date, providerDate: Date?) -> NSEMessageMetadata {
        var meta = NSEMessageMetadata(
            messageId: messageId, threadId: "t-\(messageId)", rfc822MessageId: "\(messageId)@example.com",
            senderName: "Sender", senderEmail: "sender@example.com",
            to: "recipient@example.com", cc: "", bcc: "", replyTo: nil,
            inReplyTo: nil, references: [], subject: "staged \(messageId)", snippet: "s",
            dateString: "", date: date, isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, providerLabels: ["INBOX"], folderPath: "INBOX"
        )
        meta.providerDate = providerDate
        return meta
    }

    private static func decodeStaged(_ queue: DatabaseQueue, id: String) throws -> NSEDataBridge.StagedMessage {
        let row = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM nse_processed_message WHERE id = ?", arguments: [id])
        })
        return NSEDataBridge.StagedMessage(row: row)
    }

    /// The whole NSE handoff: `stageHeader` (INSERT … ON CONFLICT), a second
    /// `stageHeader` (the UPSERT arm), `persistProcessedMessage` (REPLACE),
    /// `StagedMessage(row:)` decoding and `insertNewHeaderFromStaging`. The
    /// unequal dates must survive every write and land in `MessageHeader`.
    /// A legacy row staged before the column carried a value decodes to nil and
    /// merges with `providerDate == date`.
    @Test("NSE staging writers, decoder and merge carry providerDate end to end")
    func nseStagingRoundTripCarriesProviderDate() throws {
        let clock = FixtureClock()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        #expect(AppDatabase.createNSEStagingDB(atPath: path))
        let queue = try DatabaseQueue(path: path)
        // Rewind to the schema the BASE app shipped (no `providerDate`) and
        // leave a row behind, so the NSE's open-time upgrade step
        // (`NSEStagingDB.open`) has to ADD the column, not merely find it.
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE nse_processed_message DROP COLUMN providerDate")
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId, folderPath,
                     subject, senderName, senderEmail, snippet, date, processedAt, aiCompleted, notified, populated)
                VALUES ('acc1:legacy', 'acc1', 'user@example.com', 'gmail', 'legacy', 'legacy@example.com', 'INBOX',
                        'legacy', 'Sender', 'sender@example.com', '', ?, ?, 0, 0, 1)
                """, arguments: [clock.daysAgo(4).timeIntervalSince1970, clock.now.timeIntervalSince1970])
        }
        func columns() throws -> Set<String> {
            try queue.read { db in
                Set(try Row.fetchAll(db, sql: "PRAGMA table_info(nse_processed_message)").map { $0["name"] as String })
            }
        }
        #expect(!(try columns()).contains("providerDate"), "precondition: the base schema has no providerDate")
        NSEStagingDB.ensureObservedUidValidityColumn(db: queue)
        NSEStagingDB.ensureProviderDateColumn(db: queue)
        #expect((try columns()).contains("providerDate"))
        #expect((try columns()).contains("observedUidValidity"))
        // Idempotent on a second open.
        NSEStagingDB.ensureProviderDateColumn(db: queue)
        #expect((try columns()).contains("providerDate"))

        let arrival = clock.daysAgo(0.25)
        let authored = clock.daysAgo(55)
        let meta = Self.stagedMetadata(messageId: "push-1", date: arrival, providerDate: authored)
        NSEStagingDB.stageHeader(db: queue, accountId: "acc1", accountEmail: "user@example.com", provider: "gmail", message: meta, historyId: "1")
        var staged = try Self.decodeStaged(queue, id: "acc1:push-1")
        #expect(staged.date == arrival.timeIntervalSince1970)
        #expect(staged.providerDate == authored.timeIntervalSince1970)

        // UPSERT arm: a re-stage with a moved provider key must overwrite it.
        let reMeta = Self.stagedMetadata(messageId: "push-1", date: arrival, providerDate: clock.daysAgo(54))
        NSEStagingDB.stageHeader(db: queue, accountId: "acc1", accountEmail: "user@example.com", provider: "gmail", message: reMeta, historyId: "2")
        staged = try Self.decodeStaged(queue, id: "acc1:push-1")
        #expect(staged.providerDate == clock.daysAgo(54).timeIntervalSince1970)

        // Terminal REPLACE keeps the split.
        let persisted = NSEStagingDB.persistProcessedMessage(
            db: queue, accountId: "acc1", accountEmail: "user@example.com", provider: "gmail",
            message: meta, renderedBody: nil, summaryBlurb: "sum", summaryTodos: nil, actionTag: nil,
            reminderDate: nil, reminderTime: nil, reminderContent: nil, historyId: "3",
            aiCompleted: true, notified: true)
        #expect(persisted)
        staged = try Self.decodeStaged(queue, id: "acc1:push-1")
        #expect(staged.date == arrival.timeIntervalSince1970)
        #expect(staged.providerDate == authored.timeIntervalSince1970)

        // Merge into the main store.
        let main = try TestDatabase.make()
        try TestDatabase.insertAccount(main, id: "acc1", email: "user@example.com")
        try TestDatabase.insertFolder(main, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var fts: [NSEDataBridge.NSEFTSBodyItem] = []
        let mergedStaged = staged
        try main.write { db in
            _ = try NSEDataBridge.insertNewHeaderFromStaging(mergedStaged, db: db, ftsBatch: &fts)
        }
        let headerId = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "push-1")
        let header = try #require(try main.read { try MessageHeader.fetchOne($0, key: headerId) })
        #expect(header.date == arrival)
        #expect(header.providerDate == authored)

        // Legacy row: staged before the column existed → NULL → same as date.
        let legacy = try Self.decodeStaged(queue, id: "acc1:legacy")
        #expect(legacy.providerDate == nil)
        try main.write { db in
            _ = try NSEDataBridge.insertNewHeaderFromStaging(legacy, db: db, ftsBatch: &fts)
        }
        let legacyId = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "legacy")
        let legacyHeader = try #require(try main.read { try MessageHeader.fetchOne($0, key: legacyId) })
        #expect(legacyHeader.providerDate == legacyHeader.date)
        #expect(legacyHeader.date == clock.daysAgo(4))
    }

    // MARK: - IMAP / Graph parity: the receipt field IS the order key

    @Test("Graph metadata carries no separate provider key; header and info fall back to date")
    func graphAndDefaultsMirrorDate() throws {
        let clock = FixtureClock()
        let received = clock.daysAgo(1)
        let iso = ISO8601DateFormatter().string(from: received)
        let json: [String: Any] = [
            "id": "g1", "receivedDateTime": iso, "subject": "s",
            "from": ["emailAddress": ["name": "Sender", "address": "sender@example.com"]],
            "toRecipients": [], "ccRecipients": [], "bccRecipients": [],
            "isRead": false, "hasAttachments": false, "parentFolderId": "inbox-id",
        ]
        let meta = try #require(GraphParse.parseMessage(json, selection: GraphAPI.headerOnlySelection))
        #expect(meta.providerDate == nil)
        #expect(meta.date == received)
        let info = MessageHeaderInfo(
            messageId: "g1", rfc822MessageId: nil, inReplyTo: nil, references: [], threadId: nil,
            subject: "s", from: "Sender", fromAddress: "sender@example.com", to: "", cc: "", bcc: "",
            replyTo: nil, date: received, snippet: "", isRead: false, isFlagged: false,
            hasAttachments: false, isReplied: false, isForwarded: false, actionTag: nil)
        #expect(info.providerOrderDate == received)
        let header = MessageHeader(
            messageId: "g1", subject: "s", from: "Sender", fromAddress: "sender@example.com", to: "",
            date: received, snippet: "", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX",
            isInInbox: true)
        #expect(header.providerDate == received)
    }
}
