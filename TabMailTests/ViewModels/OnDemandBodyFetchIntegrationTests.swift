/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Helpers

/// Creates a temp file-backed DatabasePool with all migrations applied.
/// DatabasePool requires WAL mode (not available with :memory:).
private func makeTestPool() throws -> (pool: DatabasePool, dir: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("test.sqlite").path
    var config = Configuration()
    config.foreignKeysEnabled = true
    let pool = try DatabasePool(path: path, configuration: config)
    try AppDatabase.runMigrations(on: pool)
    // Message-detail work can outlive the assertion that launched it. Keep the
    // pool alive through the test-host boundary, then close before unlinking.
    TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir)
    return (pool, dir)
}

/// Insert standard test fixtures into a DatabasePool.
private func insertFixtures(_ pool: DatabasePool, messageId: String, isRead: Bool = true) async throws -> MessageHeader {
    try await pool.write { db in
        var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
        acc.id = "acc1"
        try acc.insert(db)

        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try folder.insert(db)

        var header = MessageHeader(
            messageId: messageId,
            subject: "Test Subject",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "to@example.com",
            date: Date(),
            snippet: "test snippet",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.isRead = isRead
        header.headerComplete = true
        try header.insert(db)
        return header
    }
}

// MARK: - Suite 1: loadBody with Real GRDB

@Suite("On-Demand Body Fetch Integration - Real GRDB")
struct OnDemandBodyFetchGRDBTests {

    @Test("loadBody finds body in GRDB when already cached")
    @MainActor
    func loadBodyFindsExistingBody() async throws {
        let (pool, _) = try makeTestPool()

        let header = try await insertFixtures(pool, messageId: "odf_cached_\(Int(Date().timeIntervalSince1970))")

        // Pre-insert a body
        try await pool.write { db in
            let body = MessageBody(headerId: header.id, htmlContent: "<p>Already cached body</p>")
            try body.insert(db)
        }

        var fetchBodyCalled = false
        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in fetchBodyCalled = true }
        )

        await vm.loadBody()

        // Body should be loaded from DB -- fetchBody override should NOT be called
        #expect(vm.messageBody != nil, "Body should be loaded from GRDB cache")
        #expect(vm.messageBody?.htmlContent == "<p>Already cached body</p>")
        #expect(vm.isLoading == false)
        #expect(!fetchBodyCalled, "fetchBody should not be called when body is already cached")
    }

    @Test("startBodyPoll renders an already-cached body immediately (no 2s floor)")
    @MainActor
    func startBodyPollImmediateCacheHit() async throws {
        let (pool, _) = try makeTestPool()

        let header = try await insertFixtures(pool, messageId: "odf_poll_\(Int(Date().timeIntervalSince1970))")

        // Body is ALREADY cached — mirrors the notification-tap path, where the
        // deep-link's own NSE merge wrote the body before loadBody's task got
        // cancelled (by the inbox-reload/nav churn) and deferred to the poll.
        try await pool.write { db in
            let body = MessageBody(headerId: header.id, htmlContent: "<p>cached before poll</p>")
            try body.insert(db)
        }

        var fetchBodyCalled = false
        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in fetchBodyCalled = true }
        )
        #expect(vm.messageBody == nil)

        // Drive the deferral directly (what loadBody does on CancellationError).
        vm.startBodyPoll()

        // The immediate cache check (before the first 2s sleep) must render the body
        // WELL under the 2s poll floor. Poll up to 1s; with the fix it's ~ms, without
        // it the body stays nil until the 2s tick → this assertion fails.
        var waited = 0
        while vm.messageBody == nil && waited < 20 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }

        #expect(vm.messageBody != nil, "immediate cache check should render before the 2s floor")
        #expect(vm.messageBody?.htmlContent == "<p>cached before poll</p>")
        #expect(vm.isLoading == false)
        #expect(!fetchBodyCalled, "immediate check is a pure DB read — must not server-fetch")
    }

    @Test("loadBody calls fetchBody when body is NOT cached and NOT in queue")
    @MainActor
    func loadBodyFetchesWhenNotCached() async throws {
        let (pool, _) = try makeTestPool()

        let header = try await insertFixtures(pool, messageId: "odf_fetch_\(Int(Date().timeIntervalSince1970))")

        // No body pre-inserted -- fetchBody should be called
        var fetchBodyCalled = false
        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { msg in
                fetchBodyCalled = true
                // Simulate successful fetch by writing body to DB
                let body = MessageBody(headerId: msg.id, htmlContent: "<p>Fetched from server</p>")
                try await pool.write { try body.insert($0) }
            }
        )

        await vm.loadBody()

        #expect(fetchBodyCalled, "fetchBody should be called when body is not cached")
        // After fetchBody succeeds, loadBody re-reads from DB
        #expect(vm.messageBody != nil, "Body should be available after fetch")
        #expect(vm.messageBody?.htmlContent == "<p>Fetched from server</p>")
        #expect(vm.isLoading == false)
    }

    @Test("loadBody handles message not found in DB")
    @MainActor
    func loadBodyMessageNotFound() async throws {
        let (pool, _) = try makeTestPool()

        // Insert account/folder but no message
        try await pool.write { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            try folder.insert(db)
        }

        // Use a non-existent message ID
        let fakeId = "acc1:INBOX:nonexistent_\(Int(Date().timeIntervalSince1970))"

        let vm = MessageDetailViewModel(
            messageId: fakeId,
            dbPool: pool,
            fetchBodyOverride: { _ in
                throw ProviderError.messageNotFound
            }
        )

        await vm.loadBody()

        #expect(vm.isLoading == false)
        #expect(vm.messageNotFound == true, "Should set messageNotFound when message doesn't exist")
        #expect(vm.messageBody == nil)
    }
}

// MARK: - Suite 2: Body Arrives Between Queue Check and Fetch

@Suite("On-Demand Body Fetch Integration - Race Between Check and Fetch")
struct OnDemandBodyFetchRaceTests {

    @Test("Body appears in GRDB before loadBody — found immediately without fetch")
    @MainActor
    func bodyArrivesBeforeFetch() async throws {
        let (pool, _) = try makeTestPool()

        let header = try await insertFixtures(pool, messageId: "odf_race_\(Int(Date().timeIntervalSince1970))")

        var fetchBodyCalled = false
        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { msg in
                fetchBodyCalled = true
                // Real code checks hasBody first and returns early if present.
                // We simulate the race: body was written just before fetch.
                let exists = try await pool.read { try MessageBody.fetchOne($0, key: msg.id) != nil }
                if !exists {
                    let body = MessageBody(headerId: msg.id, htmlContent: "<p>Background wrote this</p>")
                    try await pool.write { try body.insert($0) }
                }
            }
        )

        // Simulate: background writes body just before loadBody
        try await pool.write { db in
            let body = MessageBody(headerId: header.id, htmlContent: "<p>Background wrote this</p>")
            try body.insert(db)
        }

        await vm.loadBody()

        // Should find the body that was already written
        #expect(vm.messageBody != nil, "Should find body written by background path")
        #expect(vm.messageBody?.htmlContent == "<p>Background wrote this</p>")
        #expect(vm.isLoading == false)
        // fetchBody should NOT be called because existing body path returns early
        #expect(!fetchBodyCalled, "fetchBody should not be called when body already exists")
    }
}

// MARK: - Suite 3: fetchBody Error Handling

@Suite("On-Demand Body Fetch Integration - Error States")
struct OnDemandBodyFetchErrorTests {

    @Test("loadBody sets error when fetchBody throws non-connection error")
    @MainActor
    func fetchBodyThrowsNonConnectionError() async throws {
        let (pool, _) = try makeTestPool()

        let header = try await insertFixtures(pool, messageId: "odf_err_\(Int(Date().timeIntervalSince1970))")

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in
                throw ProviderError.messageNotFound
            }
        )

        await vm.loadBody()

        #expect(vm.isLoading == false)
        #expect(vm.messageBody == nil, "No body should be loaded on error")
        // Error should be set for non-connection errors
        #expect(vm.error != nil, "Error should be set for messageNotFound")
    }

    @Test("loadBody with nil body after fetch -- message set, body nil (poll-ready state)")
    @MainActor
    func bodyNilAfterAllAttemptsTriggersPoll() async throws {
        let (pool, _) = try makeTestPool()

        let header = try await insertFixtures(pool, messageId: "odf_poll_\(Int(Date().timeIntervalSince1970))")

        // fetchBody "succeeds" but doesn't write body (simulates partial failure)
        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in
                // Do nothing -- no body written to DB
            }
        )

        await vm.loadBody()

        // After loadBody, body is still nil -- the real code starts bodyPoll
        #expect(vm.messageBody == nil, "Body should be nil (fetch didn't write)")
        #expect(vm.isLoading == false)
        // Verify the state is correct for poll to work
        #expect(vm.message != nil, "Message header should be set for poll to work")
    }
}

// MARK: - Suite 4: Mark-read-on-open (independent of loadBody)

@Suite("Mark-Read on Open — Independent of loadBody", .processGlobalState)
struct MarkReadOnOpenTests {

    @Test("markReadOnOpenIfNeeded flips unread message's optimistic isRead flag")
    @MainActor
    func flipsUnreadMessage() async throws {
        let (pool, _) = try makeTestPool()
        let header = try await insertFixtures(pool, messageId: "mro_unread_\(Int(Date().timeIntervalSince1970))", isRead: false)

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        // Zero-I/O init: the durable row is NOT resolved at construction, so
        // this exercises markReadOnOpen's async-resolve fallback path.
        #expect(vm.message == nil, "Precondition: zero-I/O init leaves message unresolved")

        await vm.markReadOnOpenIfNeeded()

        #expect(vm.message?.isRead == true, "Optimistic in-memory flip should apply after call")
    }

    @Test("markReadOnOpenIfNeeded is a no-op for already-read messages")
    @MainActor
    func noopForRead() async throws {
        let (pool, _) = try makeTestPool()
        let header = try await insertFixtures(pool, messageId: "mro_read_\(Int(Date().timeIntervalSince1970))", isRead: true)

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        // Seed the resolved message (zero-I/O init) to exercise the fast path's
        // already-read guard.
        vm._testSeedMessage(header)

        await vm.markReadOnOpenIfNeeded()

        #expect(vm.message?.isRead == true, "Already-read stays read; no spurious mutation")
    }

    @Test("markReadOnOpenIfNeeded idempotency latch prevents double-invocation")
    @MainActor
    func idempotent() async throws {
        let (pool, _) = try makeTestPool()
        let header = try await insertFixtures(pool, messageId: "mro_idem_\(Int(Date().timeIntervalSince1970))", isRead: false)

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )

        await vm.markReadOnOpenIfNeeded()
        await vm.markReadOnOpenIfNeeded()  // second call is a no-op

        // No crash, no re-flip (state is idempotent).
        #expect(vm.message?.isRead == true)
    }

    @Test("loadBody alone no longer marks as read — decoupled from body-load path")
    @MainActor
    func loadBodyDoesNotMarkAsRead() async throws {
        let (pool, _) = try makeTestPool()
        let header = try await insertFixtures(pool, messageId: "mro_decoupled_\(Int(Date().timeIntervalSince1970))", isRead: false)

        // Pre-insert body so loadBody takes the cached-body path (no fetchBody call).
        try await pool.write { db in
            let body = MessageBody(headerId: header.id, htmlContent: "<p>body</p>")
            try body.insert(db)
        }

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )

        await vm.loadBody()  // previously would flip isRead; must NOT now

        #expect(vm.messageBody != nil, "Body should be loaded")
        #expect(vm.message?.isRead == false, "loadBody must not mutate isRead — mark-read lives on separate path")
    }
}

// MARK: - Suite: Optimistic overlay survives DB re-reads
//
// Regression coverage for the "detail-view unread dot persists" bug:
// every site in `MessageDetailViewModel` that re-reads `MessageHeader`
// from GRDB and assigns it to `self.message` / `self.threadMessages` must
// layer `AccountManager.snapshotOverlay()` on top — otherwise a stale
// DB row clobbers the optimistic `isRead = true` that
// `markReadOnOpenIfNeeded` / `toggleRead` just set, and the dot stays
// visible until the user navigates back to the list.
//
// Mirror of `InboxViewModel.applyOverlay`. Display-only fields
// (`isRead`, `isFlagged`, `actionTag`, `isInInbox`) — `folderId` /
// `folderPath` are intentionally excluded because the detail view's
// fetchBody / processOpenedMessage address the IMAP folder, and an
// optimistic move's overlay points at the destination before the
// message has physically been moved there.

@Suite("MessageDetailViewModel — Overlay survives DB re-reads", .serialized, .processGlobalState)
struct MessageDetailOverlayTests {

    /// AccountManager.shared is a singleton — clear any stragglers between tests.
    /// snapshotOverlay/removeOverlayEntries are nonisolated; no actor hop needed.
    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    @Test("init layers overlay isRead=true on top of a staged seed that has isRead=false")
    @MainActor
    func initAppliesOverlay() async throws {
        // Init is zero-I/O: its ONLY resolve source is the staged snapshot, so
        // that's the assignment site to cover here. The durable-resolve
        // assignments (loadBody / markReadOnOpen fallback) have their own
        // overlay-survival tests below.
        let (pool, _) = try makeTestPool()
        defer {
            clearOverlay()
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        }
        clearOverlay()

        let row = StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: "mdo-init-staged",
            rfc822MessageId: "<mdo-init@x>", threadId: nil, inReplyTo: nil, references: [],
            subject: "Staged", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        AccountManager.shared.registerMutation(id: row.headerId, mutation: .init(isRead: true))

        let vm = MessageDetailViewModel(
            messageId: row.headerId,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )

        #expect(vm.message?.isRead == true,
                "init's staged-snapshot seed must be layered with overlay before assignment")
    }

    @Test("loadBody cached-body path: `message = msg` does not revert overlay isRead")
    @MainActor
    func loadBodyCachedPathPreservesOverlay() async throws {
        let (pool, _) = try makeTestPool()
        defer { clearOverlay() }
        clearOverlay()

        let header = try await insertFixtures(
            pool,
            messageId: "mdo_loadcached_\(Int(Date().timeIntervalSince1970))",
            isRead: false
        )
        // Pre-cache body so loadBody takes the early-return cached-body path,
        // which still runs `message = msg` (the bug's primary entry point) before
        // returning.
        try await pool.write { db in
            try MessageBody(headerId: header.id, htmlContent: "<p>body</p>").insert(db)
        }

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        // Register overlay AFTER init so the test isolates loadBody's behavior
        // (init was already covered by initAppliesOverlay above).
        AccountManager.shared.registerMutation(id: header.id, mutation: .init(isRead: true))

        await vm.loadBody()

        #expect(vm.messageBody != nil, "Body should be loaded from cache")
        #expect(vm.message?.isRead == true,
                "loadBody's `message = msg` must layer overlay — without it, DB isRead=false clobbers optimistic flip")
    }

    @Test("loadBody fetched-body path: post-fetch refetch does not revert overlay isRead")
    @MainActor
    func loadBodyFetchedPathPreservesOverlay() async throws {
        let (pool, _) = try makeTestPool()
        defer { clearOverlay() }
        clearOverlay()

        let header = try await insertFixtures(
            pool,
            messageId: "mdo_loadfetch_\(Int(Date().timeIntervalSince1970))",
            isRead: false
        )
        AccountManager.shared.registerMutation(id: header.id, mutation: .init(isRead: true))

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { msg in
                // Body NOT pre-cached → fetchBodyOverride fires → loadBody's
                // second DB read at end ("Refetch message in case AI processing
                // updated it during body fetch") runs. That read sees DB
                // isRead=false and must layer overlay on top.
                try await pool.write { db in
                    try MessageBody(headerId: msg.id, htmlContent: "<p>fetched</p>").insert(db)
                }
            }
        )

        await vm.loadBody()

        #expect(vm.messageBody != nil, "Body should be available after fetch")
        #expect(vm.message?.isRead == true,
                "Post-fetch refetch in loadBody must layer overlay over DB isRead=false")
    }

    @Test("No overlay registered: DB isRead value is used unchanged")
    @MainActor
    func noOverlayUsesDB() async throws {
        let (pool, _) = try makeTestPool()
        defer { clearOverlay() }
        clearOverlay()

        let header = try await insertFixtures(
            pool,
            messageId: "mdo_noov_\(Int(Date().timeIntervalSince1970))",
            isRead: false
        )
        try await pool.write { db in
            try MessageBody(headerId: header.id, htmlContent: "<p>body</p>").insert(db)
        }

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        await vm.loadBody()

        #expect(vm.message?.isRead == false,
                "Without overlay, loadBody must return DB value — overlay must not invent state")
    }

    @Test("Overlay isFlagged also survives DB re-read (symmetric to isRead)")
    @MainActor
    func loadBodyPreservesFlaggedOverlay() async throws {
        let (pool, _) = try makeTestPool()
        defer { clearOverlay() }
        clearOverlay()

        let header = try await insertFixtures(
            pool,
            messageId: "mdo_flag_\(Int(Date().timeIntervalSince1970))",
            isRead: true
        )
        // DB has isFlagged=false (default). Overlay says user just flagged it.
        try await pool.write { db in
            try MessageBody(headerId: header.id, htmlContent: "<p>body</p>").insert(db)
        }

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        AccountManager.shared.registerMutation(id: header.id, mutation: .init(isFlagged: true))

        await vm.loadBody()

        #expect(vm.message?.isFlagged == true,
                "Overlay isFlagged=true must layer over DB isFlagged=false during loadBody")
    }
}

// MARK: - Suite: refetchBody confirmedEmpty reset

@Suite("refetchBody — confirmedEmpty reset")
struct RefetchBodyConfirmedEmptyResetTests {

    @Test("Previously confirmedEmpty message: refetch clears empty-fetch state and stub AI fields")
    @MainActor
    func refetchClearsConfirmedEmptyState() async throws {
        let (pool, _) = try makeTestPool()
        let header = try await insertFixtures(pool, messageId: "rb_empty_\(Int(Date().timeIntervalSince1970))")

        // Simulate the post-confirmedEmpty state that BodyFetchProcessor.process writes
        // after 3 consecutive empty fetches (BodyFetchProcessor.swift:171–189): empty
        // MessageBody row + stub summaryBlurb + delete tag + completion flags.
        try await pool.write { db in
            let body = MessageBody(headerId: header.id, htmlContent: nil)
            try body.insert(db)
            try db.execute(
                sql: """
                    UPDATE messageHeader
                    SET bodyComplete = 1,
                        bodyEmptyConfirmed = 1,
                        emptyFetchCount = 3,
                        embeddingComplete = 1,
                        summaryBlurb = 'This message has no content.',
                        actionTag = ?,
                        tagSortOrder = ?
                    WHERE id = ?
                """,
                arguments: [ActionTag.delete.rawValue, ActionTag.delete.sortOrder, header.id]
            )
        }

        // Override simulates a successful fresh fetch by writing real body content.
        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { msg in
                let body = MessageBody(headerId: msg.id, htmlContent: "<p>real content</p>")
                try await pool.write { try body.insert($0) }
            }
        )

        await vm.refetchBody()

        let updated = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        try #require(updated != nil)
        guard let updated else { return }
        #expect(updated.bodyEmptyConfirmed == false, "bodyEmptyConfirmed must reset on user pull-to-refresh")
        #expect(updated.emptyFetchCount == 0, "emptyFetchCount chain must reset")
        #expect(updated.embeddingComplete == false, "embeddingComplete must reset; queue recomputes after body refresh")
        #expect(updated.bodyComplete == false, "bodyComplete must reset; flushBatch resets it after fresh FTS write")
        #expect(updated.summaryBlurb == nil, "stub summaryBlurb 'This message has no content.' must clear")
        #expect(updated.actionTag == nil, "stub actionTag (.delete) must clear")
        #expect(updated.tagSortOrder == 99, "stub tagSortOrder must reset to 99")
        #expect(vm.messageBody?.htmlContent == "<p>real content</p>", "fresh body should be loaded")
    }

    @Test("Normal message: refetch preserves user-visible summary/tag and only resets fetch flags")
    @MainActor
    func refetchPreservesNonStubAIFields() async throws {
        let (pool, _) = try makeTestPool()
        let header = try await insertFixtures(pool, messageId: "rb_normal_\(Int(Date().timeIntervalSince1970))")

        // Real successful state: real summary, real tag, body present.
        try await pool.write { db in
            let body = MessageBody(headerId: header.id, htmlContent: "<p>old body</p>")
            try body.insert(db)
            try db.execute(
                sql: """
                    UPDATE messageHeader
                    SET bodyComplete = 1,
                        bodyEmptyConfirmed = 0,
                        emptyFetchCount = 0,
                        embeddingComplete = 1,
                        summaryBlurb = 'A real AI-generated summary',
                        actionTag = ?,
                        tagSortOrder = ?
                    WHERE id = ?
                """,
                arguments: [ActionTag.reply.rawValue, ActionTag.reply.sortOrder, header.id]
            )
        }

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { msg in
                let body = MessageBody(headerId: msg.id, htmlContent: "<p>fresh body</p>")
                try await pool.write { try body.insert($0) }
            }
        )

        await vm.refetchBody()

        let updated = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        try #require(updated != nil)
        guard let updated else { return }
        #expect(updated.summaryBlurb == "A real AI-generated summary", "non-stub summary must survive refetch")
        #expect(updated.actionTag == .reply, "non-stub actionTag must survive refetch")
        #expect(updated.tagSortOrder == ActionTag.reply.sortOrder, "non-stub tagSortOrder must survive refetch")
        #expect(updated.bodyEmptyConfirmed == false)
        #expect(updated.emptyFetchCount == 0)
    }

    @Test("User-set delete tag on non-empty message: preserved across refetch")
    @MainActor
    func refetchPreservesUserSetDeleteTag() async throws {
        let (pool, _) = try makeTestPool()
        let header = try await insertFixtures(pool, messageId: "rb_userdel_\(Int(Date().timeIntervalSince1970))")

        // User (or AI) tagged a real, non-empty message as "delete" — must NOT be
        // mistaken for the empty-confirmed stub. Gate is `bodyEmptyConfirmed = 1`.
        try await pool.write { db in
            let body = MessageBody(headerId: header.id, htmlContent: "<p>real content</p>")
            try body.insert(db)
            try db.execute(
                sql: """
                    UPDATE messageHeader
                    SET bodyComplete = 1,
                        bodyEmptyConfirmed = 0,
                        actionTag = ?,
                        tagSortOrder = ?,
                        summaryBlurb = 'User wants to delete this'
                    WHERE id = ?
                """,
                arguments: [ActionTag.delete.rawValue, ActionTag.delete.sortOrder, header.id]
            )
        }

        let vm = MessageDetailViewModel(
            messageId: header.id,
            dbPool: pool,
            fetchBodyOverride: { msg in
                let body = MessageBody(headerId: msg.id, htmlContent: "<p>refetched</p>")
                try await pool.write { try body.insert($0) }
            }
        )

        await vm.refetchBody()

        let updated = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        try #require(updated != nil)
        guard let updated else { return }
        #expect(updated.actionTag == .delete, "user-set delete tag must survive refetch (gate is bodyEmptyConfirmed = 1)")
        #expect(updated.summaryBlurb == "User wants to delete this", "non-stub summary must survive even when actionTag = delete")
    }
}
