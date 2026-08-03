/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// T5.3 — the observed-epoch mirror's CONTRACT, asserted against the real
/// `FakeIMAPServer` so every claim is a claim about the bytes `IMAPProvider`
/// actually sends and about the state it actually holds afterwards.
///
/// **THE SYSTEM PROPERTY, stated once.**
/// `IMAPProvider.lastObservedUidValidity(folderPath:)` answers *what did the
/// most recent SELECT of this folder report* — **whichever call issued that
/// SELECT**. Before T5.3 it answered the narrower *what did the most recent
/// TRACKED SELECT report*, and twelve `server.selectMailbox` call sites sat
/// outside the chokepoint. Each of those could observe a UIDVALIDITY turnover ON
/// THE WIRE and discard it, leaving the mirror asserting an epoch the server had
/// already replaced. The consumer that reads it —
/// `SyncEngine.runBackfill`'s per-chunk `epochStillAgrees`, which is
/// `provider.lastObservedUidValidity(folderPath:) == walkEpoch` — would then
/// AGREE with a stale value: a false MATCH, in the one direction that admits
/// work across a turnover instead of refusing it (C3).
///
/// **These tests pin that property, not the mechanism.** They never assert that
/// a particular helper was called, that a mirror write happened at a particular
/// point, or that any specific function name appears. They assert only what a
/// consumer can observe: after operation X of folder F, the mirror describes the
/// epoch the server reported to X's own SELECT.
///
/// ⚠ **`selectMailboxTracked` on v3 carries NO refusal**, unlike its
/// same-named `v2final` counterpart (which throws
/// `ProviderError.uidValidityChanged` on a stored/observed disagreement and
/// fires `onUidValidityObserved`). So none of these tests may claim that routing
/// a site through it makes that site refuse anything — the refusals on v3 are
/// the consumers' own (`IMAPProvider.requireUidValidity` against the queue's
/// admitted epoch; `SyncEngine.crawlEpochGate` and `epochStillAgrees` on the
/// sync path). What is asserted here is the INPUT those consumers read.
///
/// `.serialized` — the fake binds a listening socket; parallel tests would
/// contend on ephemeral port allocation.
@Suite("IMAP SELECT epoch mirror", .serialized)
struct IMAPSelectEpochMirrorTests {

    /// Arbitrary distinct non-zero epochs (RFC 3501 §2.3.1.1 types UIDVALIDITY
    /// as `nz-number`, and `requireUidValidity` rejects 0 on either side, so
    /// every fixture must report a real one). Each sweep step below moves the
    /// mailbox to its OWN epoch so that step is independently red: a site that
    /// still discards its observation leaves the mirror on the PREVIOUS step's
    /// value, which no later expectation can accidentally satisfy.
    private static let e0: UInt32 = 96_100
    private static let e1: UInt32 = 96_101
    private static let e2: UInt32 = 96_102
    private static let e3: UInt32 = 96_103
    private static let e4: UInt32 = 96_104
    private static let e5: UInt32 = 96_105
    private static let e6: UInt32 = 96_106
    private static let e7: UInt32 = 96_107
    private static let e8: UInt32 = 96_108
    private static let e9: UInt32 = 96_109
    private static let e10: UInt32 = 96_110

    private static let rfc = "select-mirror@example.com"

    private static func message(_ uid: Int, _ id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: select mirror\r
        Message-ID: <\(id)>\r
        Content-Type: text/plain\r
        \r
        body\r

        """)
    }

    private static func provider(_ server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    private static func fixture() -> FakeIMAPServer {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(1, Self.rfc)],
        ])
        server.setUidValidity(Int(Self.e0), for: "INBOX")
        return server
    }

    /// The `\Seen` STORE specifically, so a `tm_*` keyword strip can never be
    /// mistaken for it.
    private static func seenStores(_ server: FakeIMAPServer) -> [String] {
        server.recordedCommands().filter { command in
            let upper = command.uppercased()
            return upper.contains("UID STORE") && upper.contains("\\SEEN")
        }
    }

    // MARK: - (iii) every SELECT reaches the mirror

    /// THE CENSUS SWEEP. Each step moves the mailbox to a fresh epoch and then
    /// drives ONE operation whose SELECT used to be bare. The expectation after
    /// each step is the same single sentence: the mirror now describes THIS
    /// step's SELECT.
    ///
    /// **RED-first, pre-T5.3:** step 1 arms the mirror at `e0` through
    /// `fetchMessages`, whose SELECT was already tracked. Every later step then
    /// finds the mirror still holding the PREVIOUS step's epoch, because the
    /// bare `server.selectMailbox` observed the new one and threw it away — so
    /// each of the eleven expectations below fails with the prior step's value.
    /// Swift Testing continues past a failed `#expect`, so the pre-fix run
    /// reports every site individually rather than stopping at the first.
    ///
    /// **`try?` on three of the drivers is deliberate and is NOT a weakening.**
    /// `fetchMessage`, `fetchMessagesBatch` and `fetchAttachment` fetch MIME
    /// part bodies, which `FakeIMAPServer` only serves for messages registered
    /// with `partBodies` (see `IMAPProviderMockSmokeTests`' own note about the
    /// fake's BODYSTRUCTURE builder), so against a flat text fixture their
    /// TAIL may fail. That is irrelevant to the property under test: in all
    /// three, the SELECT is the FIRST wire command of the operation and
    /// precedes everything that could throw, and the assertion is on the mirror
    /// rather than on the call's return value. A stale mirror is not excused by
    /// a later failure — if anything the throw makes the property harder to
    /// satisfy, not easier. The non-vacuity companion below drives the
    /// full-success side on the operations the fake serves completely.
    @Test("Every folder SELECT the provider issues is recorded in the observed-epoch mirror")
    func everySelectIsRecordedInTheMirror() async throws {
        let server = Self.fixture()
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // Step 1 — the already-tracked baseline. If this one is wrong, nothing
        // below means anything, so it is stated as the sweep's precondition.
        _ = try await provider.fetchMessages(
            folder: "INBOX", limit: SyncConfig.syncMessageLimit, offset: 0)
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e0,
                "precondition: the sync SELECT was already tracked before T5.3 and must record its epoch")

        // Step 2 — `flushServerState`'s INBOX SELECT.
        server.setUidValidity(Int(Self.e1), for: "INBOX")
        try await provider.flushServerState()
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e1,
                "the INBOX SELECT that flushes server state observed \(Self.e1) and the mirror must say so, not \(Self.e0)")

        // Step 3 — the date-window backfill SEARCH's SELECT.
        server.setUidValidity(Int(Self.e2), for: "INBOX")
        let since = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        _ = try await provider.searchBackfillUIDs(folder: "INBOX", since: since, before: Date())
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e2,
                "the windowed backfill SEARCH's SELECT observed \(Self.e2) and the mirror must say so, not \(Self.e1)")

        // Step 4 — the unbounded-start backfill SEARCH's SELECT (a different
        // function from step 3, reached only when `since` is nil).
        server.setUidValidity(Int(Self.e3), for: "INBOX")
        _ = try await provider.searchBackfillUIDs(folder: "INBOX", since: nil, before: Date())
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e3,
                "the unbounded backfill SEARCH's SELECT observed \(Self.e3) and the mirror must say so, not \(Self.e2)")

        // Step 5 — the deletion-reconcile existence probe's SELECT. This one
        // also RETURNS its epoch; both must describe the same SELECT.
        server.setUidValidity(Int(Self.e4), for: "INBOX")
        let existence = try await provider.searchExistingUIDs(folder: "INBOX", uids: [1])
        #expect(existence.uidValidity == Self.e4,
                "the existence probe must return the epoch of its OWN SELECT")
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e4,
                "the existence probe's SELECT observed \(Self.e4) and the mirror must say so, not \(Self.e3)")

        // Step 6 — the rfc822 UID re-resolution probe's SELECT.
        server.setUidValidity(Int(Self.e5), for: "INBOX")
        _ = try await provider.currentUIDs(rfc822MessageId: Self.rfc, folderPath: "INBOX")
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e5,
                "the UID re-resolution SELECT observed \(Self.e5) and the mirror must say so, not \(Self.e4)")

        // Step 7 — the user-facing SEARCH's SELECT (action connection).
        server.setUidValidity(Int(Self.e6), for: "INBOX")
        _ = try await provider.search(query: "select mirror", folder: "INBOX")
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e6,
                "the user SEARCH's SELECT observed \(Self.e6) and the mirror must say so, not \(Self.e5)")

        // Step 8 — the FTS body-batch SELECT. This is the one that genuinely
        // races the backfill walk on the SAME folder path.
        server.setUidValidity(Int(Self.e7), for: "INBOX")
        _ = try await provider.fetchTextBodies(ids: ["1"], folder: "INBOX")
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e7,
                "the FTS body-batch SELECT observed \(Self.e7) and the mirror must say so, not \(Self.e6)")

        // Step 9 — the single-message FETCH's re-SELECT on the action
        // connection. `try?` — see this test's doc comment.
        server.setUidValidity(Int(Self.e8), for: "INBOX")
        _ = try? await provider.fetchMessage(id: "1", folder: "INBOX")
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e8,
                "the single-message FETCH's re-SELECT observed \(Self.e8) and the mirror must say so, not \(Self.e7)")

        // Step 10 — the batch full-message FETCH's re-SELECT (body queue hot
        // path, folder-pinned connection). `try?` — see this test's doc comment.
        server.setUidValidity(Int(Self.e9), for: "INBOX")
        _ = try? await provider.fetchMessagesBatch(ids: ["1"], folder: "INBOX")
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e9,
                "the batch FETCH's re-SELECT observed \(Self.e9) and the mirror must say so, not \(Self.e8)")

        // Step 11 — the attachment fetch's re-SELECT. `e10`, never `e0`: on the
        // pre-fix code the mirror sits on `e0` for the whole sweep (step 1 is
        // the only tracked SELECT), so an expectation of `e0` here would pass
        // vacuously against exactly the behaviour this test exists to catch.
        // `try?` — see this test's doc comment.
        server.setUidValidity(Int(Self.e10), for: "INBOX")
        _ = try? await provider.fetchAttachment(
            messageId: "1", folder: "INBOX", section: "1", encoding: nil)
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e10,
                "the attachment fetch's re-SELECT observed \(Self.e10) and the mirror must say so, not \(Self.e9)")
    }

    // MARK: - (i) a changed epoch does not proceed to mutate

    /// The action wrapper's OWN SELECT, in isolation, on the path where it is
    /// the ONLY SELECT the operation performs.
    ///
    /// A queued flag change carries the epoch it was admitted under. When the
    /// mailbox has since turned over, `requireUidValidity` refuses on the
    /// wrapper's selection and the operation never reaches its second SELECT or
    /// its STORE. That refusal is asserted here as an END STATE — no `\Seen`
    /// STORE on the wire, and the message's flags unchanged — never as "the
    /// guard ran".
    ///
    /// The mirror half is the T5.3 part: even on this refused path, the SELECT
    /// the wrapper performed is a real observation of the live epoch and must
    /// reach the mirror.
    ///
    /// **RED-first, pre-T5.3:** the wrapper's SELECT was bare, so it observed
    /// the turnover and discarded it. The mutation refusal already held (T3.1),
    /// so the two flag expectations pass on the pre-fix code — it is the mirror
    /// expectation that fails, reporting `nil` (no tracked SELECT of INBOX had
    /// happened on this provider at all).
    @Test("A refused action still records the epoch its own SELECT observed")
    func aRefusedActionStillRecordsItsObservedEpoch() async throws {
        let server = Self.fixture()
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // The op was admitted under `e0`; the mailbox has since been re-created
        // and now reports `e1`.
        server.setUidValidity(Int(Self.e1), for: "INBOX")

        // An action admitted under a superseded epoch must not complete.
        // `ProviderError.self` rather than a specific case: the property is
        // "it refused", not "it refused with this payload" — the payload is the
        // mechanism, and pinning it would inherit `requireUidValidity`'s own
        // spec if that spec were wrong.
        await #expect(throws: ProviderError.self) {
            try await provider.markRead(
                ids: ["1"], folder: "INBOX", admittedUidValidity: Self.e0)
        }

        #expect(Self.seenStores(server).isEmpty,
                "the refused action reached the wire with a \\Seen STORE under a numbering it never observed: \(Self.seenStores(server))")
        #expect(!server.flags(in: "INBOX", uid: 1).contains("\\Seen"),
                "the refused action mutated UID 1 under the new numbering")
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e1,
                "the wrapper SELECT that produced the refusal observed \(Self.e1); discarding that observation is what let a later mirror read agree with a superseded epoch")
    }

    /// The false-MATCH this whole item exists to close, expressed exactly as
    /// its consumer expresses it.
    ///
    /// `SyncEngine.runBackfill`'s per-chunk guard is literally
    /// `imapProvider.lastObservedUidValidity(folderPath:) == walkEpoch`. A
    /// concurrent body-queue batch on the SAME folder is the realistic
    /// interleaving: it re-SELECTs while the crawl is between its own SELECT and
    /// its own read. Once that batch's SELECT sees the mailbox re-created, the
    /// crawl's comparison must STOP agreeing — otherwise the walk confirms a
    /// range, and inserts headers, under numbering it never observed.
    ///
    /// **RED-first, pre-T5.3:** the body-queue SELECT was bare, so after the
    /// turnover the mirror still held `walkEpoch` and the comparison below
    /// evaluated to `true` — the false match. Post-fix it evaluates to `false`
    /// and the crawl refuses.
    @Test("A turnover seen by a concurrent batch stops the crawl's epoch comparison from agreeing")
    func aTurnoverSeenByAConcurrentBatchStopsTheCrawlComparison() async throws {
        let server = Self.fixture()
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // The crawl captured its epoch at walk start, from its own SELECT.
        _ = try await provider.fetchMessages(
            folder: "INBOX", limit: SyncConfig.syncMessageLimit, offset: 0)
        let walkEpoch = provider.lastObservedUidValidity(folderPath: "INBOX")
        #expect(walkEpoch == Self.e0, "precondition: the walk starts accounted in \(Self.e0)")
        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == walkEpoch,
                "precondition: with nothing else running, the crawl's comparison agrees")

        // The mailbox is re-created, and a concurrent FTS body batch for the
        // SAME folder is the next thing to SELECT it.
        server.setUidValidity(Int(Self.e1), for: "INBOX")
        _ = try await provider.fetchTextBodies(ids: ["1"], folder: "INBOX")

        // The crawl's guard, written the way `SyncEngine.runBackfill` writes it.
        let epochStillAgrees = provider.lastObservedUidValidity(folderPath: "INBOX") == walkEpoch
        #expect(epochStillAgrees == false,
                "the crawl's per-chunk comparison still agreed with \(String(describing: walkEpoch)) after the mailbox turned over to \(Self.e1) — a false MATCH, which admits a range under numbering the walk never observed")
    }

    // MARK: - (ii) non-vacuity — an unchanged epoch completes normally

    /// The other side. A converter that simply refused, or that clobbered the
    /// mirror with nil, would satisfy every expectation above and fail every
    /// one here.
    ///
    /// Nothing in this test changes the mailbox's epoch, and every operation
    /// must produce its normal result while the mirror holds that one epoch
    /// throughout. The action leg is driven with the CORRECT admitted epoch, so
    /// it must reach the wire and actually set `\Seen`.
    ///
    /// This test is GREEN both before and after T5.3 except for its mirror
    /// expectations, which is the point: it proves the sweep above is not
    /// passing by refusing everything.
    @Test("An unchanged epoch leaves every converted SELECT's operation completing normally")
    func anUnchangedEpochCompletesEveryOperationNormally() async throws {
        let server = Self.fixture()
        server.expectMutation(rfc822MessageId: Self.rfc)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let fetched = try await provider.fetchMessages(
            folder: "INBOX", limit: SyncConfig.syncMessageLimit, offset: 0)
        #expect(fetched.count == 1, "the fixture holds exactly one message")
        guard fetched.count == 1 else { return }
        #expect(fetched[0].messageId == "1")

        try await provider.flushServerState()

        let backfillUIDs = try await provider.searchBackfillUIDs(
            folder: "INBOX", since: Date().addingTimeInterval(-30 * 24 * 60 * 60), before: Date())
        #expect(backfillUIDs == [1], "the windowed backfill SEARCH still returns the folder's UID")

        let unboundedUIDs = try await provider.searchBackfillUIDs(
            folder: "INBOX", since: nil, before: Date())
        #expect(unboundedUIDs == [1], "the unbounded backfill SEARCH still returns the folder's UID")

        let existence = try await provider.searchExistingUIDs(folder: "INBOX", uids: [1])
        #expect(existence.found == [1], "the existence probe still finds the UID that is there")
        #expect(existence.uidValidity == Self.e0, "and still reports its own SELECT's epoch")

        let resolved = try await provider.currentUIDs(
            rfc822MessageId: Self.rfc, folderPath: "INBOX")
        #expect(resolved == ["1"], "the rfc822 probe still resolves to the live UID")

        let searched = try await provider.search(query: "select mirror", folder: "INBOX")
        #expect(searched.count == 1, "the user SEARCH still returns the message")

        let bodies = try await provider.fetchTextBodies(ids: ["1"], folder: "INBOX")
        #expect(bodies.count == 1, "the FTS body batch still returns one result per requested id")

        // The action leg, admitted under the epoch the mailbox still holds.
        try await provider.markRead(
            ids: ["1"], folder: "INBOX", admittedUidValidity: Self.e0)
        #expect(Self.seenStores(server).count == 1,
                "an action whose admitted epoch still matches must reach the wire exactly once")
        #expect(server.flags(in: "INBOX", uid: 1).contains("\\Seen"),
                "and must actually mark the message read")
        #expect(server.wrongMessageViolations().isEmpty,
                "a mutation landed on a message the gesture never targeted: \(server.wrongMessageViolations())")

        #expect(provider.lastObservedUidValidity(folderPath: "INBOX") == Self.e0,
                "the mirror must still describe the one epoch every SELECT in this test reported")
    }
}
