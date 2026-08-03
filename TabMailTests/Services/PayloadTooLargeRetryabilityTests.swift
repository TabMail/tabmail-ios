/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Mirrors how SwiftNIO's oversize failure reaches `BodyFetchProcessor.fetch`:
/// production classifies it textually, via
/// `"\(error)".contains("PayloadTooLargeError")`, so the stub only has to render
/// that substring. `CustomStringConvertible` makes the interpolation exact rather
/// than relying on `NSError`'s composite description.
private struct StubPayloadTooLargeError: Error, CustomStringConvertible {
    var description: String { "PayloadTooLargeError: body exceeds the fixed NIO buffer" }
}

/// `BodyFetchProcessor`'s payload-too-large path must leave the message RETRYABLE.
///
/// Data-integrity rule 1 ("NEVER mark unfetched content as fetched") allows
/// exactly one exception: a *verified permanent* error where the content is
/// confirmed GONE. A `PayloadTooLargeError` is the opposite of that — the body
/// demonstrably EXISTS and merely overflowed the fixed per-binary NIO buffer — so
/// the row must stay honestly incomplete instead of being stamped
/// `bodyEmptyConfirmed`, whose documented meaning is "server confirmed this
/// message has no body content … permanently excluded from body fetch queues".
///
/// **The suite is deliberately TWO-SIDED.** "Too-large never confirms empty" would
/// pass vacuously against a build that never confirms empty at ALL, so the
/// genuinely-empty side is pinned in the same suite. This codebase's
/// "verified permanent, content confirmed gone" mechanism for bodies is
/// `BodyFetchProcessor.process`'s empty-fetch budget: after the configured number
/// of consecutive empty responses the message is confirmed empty for good. That
/// side must keep working.
///
/// **The property asserted is the SYSTEM STATE, not the fix's mechanism** — the
/// row is still marked as having no body AND is still selected by the body
/// queues' candidate predicate. Nothing here asserts that a particular UPDATE
/// statement is absent; a re-implementation that reached the same end state by
/// other means would pass, and any implementation that retires the message would
/// fail.
///
/// `.serialized, .processGlobalState`: `BodyFetchProcessor` writes through the
/// process-wide `AppDatabase.shared`, which these tests swap for a temp
/// file-backed pool (same recipe as `WriteTierRoutingTests`).
@Suite("Payload-too-large leaves the body retryable (data-integrity rule 1)", .serialized, .processGlobalState)
struct PayloadTooLargeRetryabilityTests {

    // MARK: - Fixture

    /// Temp file-backed `DatabasePool` with all migrations applied (`DatabasePool`
    /// requires WAL, unavailable with `:memory:`) — same recipe as
    /// `WriteTierRoutingTests.makeTestPool`.
    private func makeTestPool() throws -> (pool: DatabasePool, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        try AppDatabase.runMigrations(on: pool)
        return (pool, dir)
    }

    /// Swaps in a fresh `AppDatabase.shared` backed by a temp pool, seeded with one
    /// header that is `headerComplete = 1, bodyComplete = 0, bodyEmptyConfirmed = 0`
    /// — i.e. a message the body queues would legitimately pick up. Returns the
    /// header and a restore closure the caller MUST run in `defer`.
    ///
    /// `emptyFetchCount` is a parameter so the genuinely-empty side can start with
    /// its budget already spent. The date is derived from `Date()`, never hardcoded.
    private func makeTestDB(emptyFetchCount: Int = 0) throws -> (header: MessageHeader, restore: () -> Void) {
        let (pool, dir) = try makeTestPool()
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        var account = Account(emailAddress: "oversize-test@example.com", displayName: "Oversize Test", provider: .gmail)
        account.id = "acc1"
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var header = MessageHeader(
            messageId: "oversize_\(UUID().uuidString)",
            subject: "A message whose body overflows the buffer",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.headerComplete = true
        header.emptyFetchCount = emptyFetchCount
        try pool.write { db in
            try account.insert(db)
            try folder.insert(db)
            try header.insert(db)
        }
        let restore: () -> Void = {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        return (header, restore)
    }

    /// "Still eligible for a later body fetch" IS membership in the body queues'
    /// candidate set. This is the predicate shared by
    /// `ActiveBodyQueue.repopulateFromDatabase`,
    /// `BackfillBodyQueue.repopulateFromDatabase` and the FTS self-heal scope in
    /// `SyncEngineFTS` — a row excluded from it is reachable by no background body
    /// fetch at all.
    private func isEligibleForLaterBodyFetch(headerId: String) async throws -> Bool {
        let found: Int = try await AppDatabase.dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageHeader
                WHERE id = ? AND headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0
                """, arguments: [headerId]) ?? 0
        }
        return found == 1
    }

    private func makeItem(_ header: MessageHeader) -> BodyFetchProcessor.Item {
        BodyFetchProcessor.Item(
            headerId: header.id,
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId,
            isInInbox: header.isInInbox
        )
    }

    // MARK: - Side 1 — oversized body must NOT be treated as confirmed-empty

    /// RED on the pre-fix code: `BodyFetchProcessor.fetch`'s `PayloadTooLargeError`
    /// branch executed `UPDATE messageHeader SET bodyEmptyConfirmed = 1` before
    /// returning `.failure(.payloadTooLarge)`, so `bodyEmptyConfirmed` came back
    /// `true` and the eligibility check came back `false`.
    @Test("Payload-too-large fetch leaves the message unfetched and still eligible for a later body fetch")
    func payloadTooLargeLeavesMessageRetryable() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }

        let provider = MockEmailProvider()
        await provider.setFetchMessageThrows(StubPayloadTooLargeError())

        // The production entry point for this branch: the user-open path calls
        // `fetchAndProcess` (see `AccountManagerFetch.fetchBodyIfNeeded`).
        let result = await BodyFetchProcessor.fetchAndProcess(
            item: makeItem(header), provider: provider, enableAI: false
        )
        #expect(result == .payloadTooLarge)

        let row = try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        let stored = try #require(row, "the header must survive an oversized body fetch")

        // The invariant: the message is still marked as NOT having a body.
        #expect(
            stored.bodyEmptyConfirmed == false,
            "an oversized body is not a confirmed-empty body — the content demonstrably exists, it merely did not fit"
        )
        #expect(stored.bodyComplete == false, "nothing was indexed, so the body is not complete")
        // An oversized fetch must not spend a strike from the empty-confirmation
        // budget either — that budget exists for genuinely empty responses.
        #expect(stored.emptyFetchCount == 0, "a too-large response is not an empty response")

        // ...and therefore the message is still reachable by a later fetch.
        let eligible = try await isEligibleForLaterBodyFetch(headerId: header.id)
        #expect(eligible, "the message must stay in the body queues' candidate set so a later attempt can fetch it")
    }

    // MARK: - Side 2 — a genuinely empty body must STILL confirm empty

    /// The non-vacuity half. Without this, side 1 would also pass against a build
    /// that had lost the ability to confirm empty at all, which would be a
    /// different bug (unbounded retry) wearing side 1's green as a disguise.
    @Test("A genuinely empty body still confirms empty once the empty-fetch budget is spent")
    func genuinelyEmptyBodyStillConfirmsEmpty() async throws {
        // Budget already spent by prior consecutive empty responses — this attempt
        // is the one that permanently confirms.
        let (header, restore) = try makeTestDB(emptyFetchCount: 2)
        defer { restore() }

        // No text, no attachments, no unresolved invite: a genuinely contentless
        // message, which is this codebase's "verified permanent / content confirmed
        // gone" case for bodies.
        let fetchResult = BodyFetchProcessor.FetchResult(
            item: makeItem(header),
            renderedBody: MessageBody.create(contentKey: ContentKey(rawValue: header.id), htmlBody: nil),
            plainText: nil,
            hasAttachments: false,
            hasUnresolvedICS: false
        )
        let (outcome, processed) = await BodyFetchProcessor.process(fetchResult: fetchResult, enableAI: false)
        #expect(outcome == .confirmedEmpty)
        #expect(processed == nil, "a confirmed-empty message contributes no FTS row")

        let row = try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        let stored = try #require(row, "the header must survive a confirmed-empty fetch")
        #expect(
            stored.bodyEmptyConfirmed,
            "the permanent-empty path must still work — otherwise the too-large assertion above is vacuous"
        )
        let eligible = try await isEligibleForLaterBodyFetch(headerId: header.id)
        #expect(eligible == false, "a confirmed-empty message is correctly retired from the body queues")
    }
}
