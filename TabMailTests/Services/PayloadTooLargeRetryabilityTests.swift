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

    /// "Not retired": the row is still `headerComplete` with no body and no
    /// confirmed-empty stamp, which is what keeps it visible to
    /// `SyncEngineFTS.selfHealBackfillFTSMembership` and reachable by a retry.
    ///
    /// ⚠️ This is deliberately NOT the body queues' admission predicate any more. Both
    /// `repopulateFromDatabase`s (and both `repopulateOnDrain`s) additionally require
    /// `bodyMetadataOversized = 0`; the FTS self-heal scope does not, because a
    /// quarantined row's HEADER is healthy and must stay searchable. These tests are
    /// about what `BodyFetchProcessor` does to the ROW on a `PayloadTooLargeError`, so
    /// the un-flagged shape above is the right question here — the admission side is
    /// pinned against the real production queries in
    /// `OversizedBodyQuarantineDatabaseTests`.
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
    @Test("Payload-too-large fetch leaves the message unfetched, un-retired, and not confirmed empty")
    func payloadTooLargeLeavesMessageRetryable() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }

        let provider = MockEmailProvider()
        await provider.setFetchMessageThrows(StubPayloadTooLargeError())

        // The production entry point for this branch: the user-open path calls
        // `fetchAndProcess` (see `AccountManagerFetch.fetchBody`).
        let result = await BodyFetchProcessor.fetchAndProcess(
            item: makeItem(header), provider: provider, enableAI: false
        )
        #expect(result == .payloadTooLarge)

        // The mark is DISPATCHED onto `ActiveBodyQueue`'s serialized durable-write chain,
        // not written inline. Without this drain the read below can beat the write, so a
        // NEGATIVE assertion would be satisfied by timing rather than by the guard it
        // names — green for the wrong reason under exactly the mutation it must catch.
        // (Found by audit.)
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()

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
        #expect(eligible, "the row must stay honestly incomplete — headerComplete, bodyless, not confirmed empty — so nothing has been retired; admission is separately gated on the oversized flag")
    }

    /// 🚨 THE USER-OPEN PATH RECORDS ITS OBSERVATION TOO.
    ///
    /// This branch is the SOONEST the app can learn a message overflows the parser — it
    /// runs on the very first open, before any background queue has reached the row. It
    /// used to throw that knowledge away, and the comment here asserted the omission was
    /// harmless because "that path performs no retry loop". It does loop: `loadBody` ends
    /// with `if messageBody == nil { startBodyPoll() }`, and that poll re-fetches every
    /// 2 seconds indefinitely, each attempt paying a full TCP + TLS + LOGIN + SELECT
    /// because the overflow marks the folder connection unhealthy.
    ///
    /// The property: after a user-open overflow the row is quarantined, by the same
    /// definition every other consumer uses (`MessageHeader.isBodyQuarantined`) — which
    /// is what lets the poll's own gate stop the loop on its next tick.
    @Test("A user-open payload-too-large records the observation, so the poll behind it can stop")
    func payloadTooLargeOnTheOpenPathQuarantinesTheRow() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }

        let provider = MockEmailProvider()
        await provider.setFetchMessageThrows(StubPayloadTooLargeError())

        let result = await BodyFetchProcessor.fetchAndProcess(
            item: makeItem(header), provider: provider, enableAI: false
        )
        #expect(result == .payloadTooLarge, "precondition — the overflow branch ran")

        // The mark is enqueued on `ActiveBodyQueue`'s serialized durable-write chain — the
        // same chain the UIDVALIDITY reset's clear uses, so the two cannot commit out of
        // order. Drain it, or this reads before the write runs.
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()

        let stored = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(stored.isBodyQuarantined,
                "the one path that detects the overflow first must not discard what it learned — otherwise the flag's population is whatever a background queue happened to reach, and the poll behind this failure spins forever")
        // Recorded, NOT retired: every assertion in `payloadTooLargeLeavesMessageRetryable`
        // still holds, and pull-to-refresh is still a genuine wire attempt.
        #expect(stored.bodyEmptyConfirmed == false)
        #expect(stored.bodyComplete == false)
        #expect(stored.emptyFetchCount == 0)
        #expect(stored.missFetchCount == 0)
    }

    /// NON-VACUITY for the mark above. A fetch that fails for any OTHER reason must not
    /// quarantine anything — the flag names one specific, upstream-fixable failure mode,
    /// and a mark that fired on every error would take ordinary transient failures out of
    /// background admission permanently.
    @Test("CONTROL: an ordinary fetch failure does NOT quarantine the row")
    func ordinaryFetchFailureDoesNotQuarantine() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }

        let provider = MockEmailProvider()
        await provider.setFetchMessageThrows(ProviderError.messageNotFound)

        _ = await BodyFetchProcessor.fetchAndProcess(
            item: makeItem(header), provider: provider, enableAI: false
        )

        // The mark is DISPATCHED onto `ActiveBodyQueue`'s serialized durable-write chain,
        // not written inline. Without this drain the read below can beat the write, so a
        // NEGATIVE assertion would be satisfied by timing rather than by the guard it
        // names — green for the wrong reason under exactly the mutation it must catch.
        // (Found by audit.)
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()

        let stored = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(stored.isBodyQuarantined == false,
                "only a parser overflow may set this flag — a transient failure that got quarantined would never be retried by any background queue again")
    }

    /// The write-side guard, on this path too: a body that landed between the overflow
    /// and the write means the row must not be quarantined at all.
    @Test("A row that already has a body is not quarantined by a payload-too-large")
    func payloadTooLargeSkipsARowThatAlreadyHasABody() async throws {
        let (header, restore) = try makeTestDB()
        defer { restore() }

        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                           arguments: [header.id])
        }

        let provider = MockEmailProvider()
        await provider.setFetchMessageThrows(StubPayloadTooLargeError())
        _ = await BodyFetchProcessor.fetchAndProcess(
            item: makeItem(header), provider: provider, enableAI: false
        )

        // The mark is DISPATCHED onto `ActiveBodyQueue`'s serialized durable-write chain,
        // not written inline. Without this drain the read below can beat the write, so a
        // NEGATIVE assertion would be satisfied by timing rather than by the guard it
        // names — green for the wrong reason under exactly the mutation it must catch.
        // (Found by audit.)
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()

        let stored = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        })
        #expect(stored.bodyMetadataOversized == false,
                "the mark carries `AND bodyComplete = 0` — minting a stale flag on a completed row is exactly what the detail view's fail-safe exists to survive, and must not be done deliberately")
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
            hasUnresolvedICS: false,
            // Row was never moved (its key encodes its own folder) and carries no rfc822
            // id, so `BodyAddressGate` has nothing to refuse here.
            fetchedRfc822MessageId: nil
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
