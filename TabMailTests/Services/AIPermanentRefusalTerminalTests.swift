/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing

@testable import TabMail

/// `IOS-AI-002` / `IOS-AI-003` — **the COST of a correct refusal, never the refusal.**
///
/// `6b689890d` made `AIWriteTarget.resolveCurrentHeader` refuse an AI write-back it
/// cannot attribute, which is right: admitting one would bind message X's summary to
/// message Y (C3 misattribution). Its commit body called the refusal *recoverable*.
/// For one reachable state it is not — and `MIS-IOS-008` records exactly how that
/// claim came to be written. The state, every clause verified against the code:
///
///  - an IMAP/iCloud row with **no** `rfc822MessageId`, so arm 6's content witness
///    cannot carry it;
///  - in a folder whose `lastKnownUidValidity` is nil and **can never become
///    non-nil** — blind bootstrap (`SyncEngine.bootstrapFolderUidValidity`) carries
///    `AND NOT EXISTS (SELECT 1 FROM messageHeader WHERE folderId = :folderId)` and
///    so refuses a folder that already holds rows, while the verified door
///    (`SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch`) samples through
///    `sampleUidsForEpochVerification`, whose SQL excludes RFC-less rows, and returns
///    `.unobservable` on an all-RFC-less population *before issuing any FETCH*.
///
/// The consumer then made that permanent refusal **expensive** rather than inert:
/// `ActiveAIQueue.readJobOutcome` saw the target field still nil and returned
/// `.needsRetry`, the job was re-queued at `maxRetries: .max` with a 30-second backoff
/// cap, `repopulateOnDrain` re-enqueued it every drain, and `MessageAICache` could not
/// short-circuit because it keys by `rfc822MessageId` — which these rows do not have.
/// Summary, action and reply each re-ran a **paid** model call indefinitely.
///
/// ## What this suite pins, and what it deliberately does not
///
/// The invariant is **the number of paid model calls a structurally-unattributable
/// row can cost is zero, however many times the queue re-drives it** — a system
/// property, not a flag. `ActiveAIQueue` reaches its model call only through
/// `AIService.shared` behind a dispatch path that requires connectivity, a session,
/// consent and an active subscription, and it writes through the app's own
/// `AppDatabase.syncPool`, so the real drain loop is not reachable from a unit test.
/// What IS reachable is the production decision that gates every model call:
/// `ActiveAIQueue.writeAdmission`, evaluated exactly as `executeJob` evaluates it —
/// on a target captured from the live row in the same read. The counting tests below
/// re-run that decision once per simulated drain cycle and count how many cycles
/// would have reached the model, then assert the DATABASE end state (did any AI field
/// land, and on which row). Accepted limitation, stated plainly: the dispatch/drain
/// plumbing between `writeAdmission` and `AIService` is covered by the compiler and by
/// review, not by these tests.
///
/// Both non-vacuity controls are two-sided on purpose. A fix that simply stopped
/// retrying would pass test 1 and fail tests 2 and 3.
@Suite("IOS-AI-002 / IOS-AI-003 - a structurally permanent AI refusal is terminal, not retried")
struct AIPermanentRefusalTerminalTests {

    private static let accountId = "acc-ai-terminal"
    private static let folderPath = "INBOX"
    private static let uid = "77"

    private static var folderId: String {
        MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
    }

    private static var headerId: String {
        MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: uid)
    }

    // MARK: - Fixture

    private func makeFixture(
        folderEpoch: Int?,
        resetPendingAt: Date? = nil,
        provider: AccountProvider = .imap
    ) throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        _ = try TestDatabase.insertAccount(
            db, id: Self.accountId, email: "user@example.com", provider: provider)
        var folder = Folder(
            name: "INBOX", path: Self.folderPath, role: .inbox, accountId: Self.accountId)
        folder.lastKnownUidValidity = folderEpoch
        folder.uidValidityResetPendingAt = resetPendingAt
        try db.write { try folder.insert($0) }
        return db
    }

    private func makeHeader(
        subject: String, rfc822: String?, observedEpoch: Int?, uid: String = AIPermanentRefusalTerminalTests.uid
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid,
            subject: subject,
            from: "Sender <sender@example.com>",
            fromAddress: "sender@example.com",
            to: "user@example.com",
            // Dynamic per testing rule 7 — never a literal date.
            date: Date().addingTimeInterval(-7200),
            snippet: "snippet",
            folderId: Self.folderId,
            accountId: Self.accountId,
            folderPath: Self.folderPath,
            isInInbox: true
        )
        header.rfc822MessageId = rfc822
        header.observedUidValidity = observedEpoch
        return header
    }

    /// One simulated drain cycle, shaped exactly like `ActiveAIQueue.executeJob`'s
    /// prologue: re-read the CURRENT row, capture a target from it, and ask the SAME
    /// production function whether the result could be written back.
    private func admissionForOneDrainCycle(_ db: DatabaseQueue) throws -> ActiveAIQueue.WriteAdmission? {
        try db.read { db -> ActiveAIQueue.WriteAdmission? in
            guard let current = try MessageHeader.fetchOne(db, key: Self.headerId),
                  let target = try AIWriteTarget.capture(message: current, db: db) else { return nil }
            return try ActiveAIQueue.writeAdmission(db, target: target)
        }
    }

    /// Run `cycles` drain cycles. Whenever the cycle is admitted, that is a MODEL CALL
    /// — so we count it and then perform the guarded write the model's result would
    /// have produced. Returns the number of model calls the queue would have paid for.
    @discardableResult
    private func runDrainCycles(_ db: DatabaseQueue, _ cycles: Int, blurb: String) throws -> Int {
        var modelCalls = 0
        for _ in 0..<cycles {
            let captured = try db.read { db -> AIWriteTarget? in
                guard let current = try MessageHeader.fetchOne(db, key: Self.headerId),
                      let target = try AIWriteTarget.capture(message: current, db: db) else { return nil }
                return target
            }
            guard let captured else { continue }
            let admission = try db.read { try ActiveAIQueue.writeAdmission($0, target: captured) }
            guard admission == .admissible else { continue }
            modelCalls += 1
            _ = try db.write { db in
                try AccountManager.aiGuardedHeaderWrite(db, target: captured) { msg, db in
                    msg.summaryBlurb = blurb
                    msg.setActionTag(.reply)
                    msg.cachedReply = "precomputed reply"
                    try msg.save(db)
                }
            }
        }
        return modelCalls
    }

    /// NON-VACUITY at value level: the bare pre-guard expression (`fetchOne` + mutate +
    /// `save`) LANDS on this row, so a later refusal is the guard refusing rather than
    /// the row being absent or unwritable. Undone afterwards.
    private func proveBareWriteLandsThenUndo(_ db: DatabaseQueue) throws {
        let landed: Bool = try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: Self.headerId) else { return false }
            bare.summaryBlurb = "pre-guard control write"
            try bare.save(db)
            return true
        }
        #expect(landed, "the row must be present and writable, else a refusal proves nothing")
        try db.write { db in
            guard var bare = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            bare.summaryBlurb = nil
            try bare.save(db)
        }
    }

    private func header(_ db: DatabaseQueue) throws -> MessageHeader? {
        try db.read { try MessageHeader.fetchOne($0, key: Self.headerId) }
    }

    // MARK: - 1. THE INVARIANT — a permanently unattributable row costs zero model calls

    /// The `IOS-AI-003` state, and the property that makes terminating correct: the
    /// refusal is STABLE under re-capture. The queue re-captures the target at the top
    /// of every attempt, so if a fresh capture is refused now, every retry is refused
    /// identically — the model call is pure waste.
    ///
    /// The permanence is asserted against the two recovery doors themselves, not
    /// merely stated: this folder already holds a row (so blind bootstrap's
    /// `NOT EXISTS` term is false) and no row in it carries an RFC 822 Message-ID (so
    /// `sampleUidsForEpochVerification` returns nothing and the verified door reports
    /// `.unobservable` without contacting the server). That is `MIS-IOS-008`'s
    /// countermeasure applied here: the state where recovery does not fire, named.
    @Test("A row whose AI write can never be attributed costs ZERO model calls, however often the queue re-drives it")
    func permanentlyUnattributableRowIsNeverAdmittedToAModelCall() throws {
        let db = try makeFixture(folderEpoch: nil)
        let orphan = makeHeader(subject: "RFC-less orphan", rfc822: nil, observedEpoch: nil)
        try db.write { try orphan.insert($0) }

        try proveBareWriteLandsThenUndo(db)

        // Neither bootstrap door can run from this state — this is WHY the refusal is
        // permanent rather than deferred.
        let folderHoldsRows = try db.read { db in
            try MessageHeader.filter(Column("folderId") == Self.folderId).fetchCount(db)
        }
        #expect(folderHoldsRows > 0,
                "blind bootstrap only stamps an EMPTY folder — a populated one is what makes this permanent")
        let sample = try db.read { db in
            try SyncEngine.sampleUidsForEpochVerification(
                db, folderId: Self.folderId,
                highCount: SyncConfig.uidValidityVerifySampleHighCount,
                lowCount: SyncConfig.uidValidityVerifySampleLowCount)
        }
        #expect(sample.isEmpty,
                "the verified door samples only RFC-bearing rows; an empty sample is its `.unobservable` arm")

        // The classification the queue acts on.
        #expect(try admissionForOneDrainCycle(db) == .structurallyRefused)

        // THE INVARIANT: twenty drain cycles, zero model calls, and no AI field on the
        // row. Pre-fix this was twenty paid calls whose results were all discarded at
        // `aiGuardedHeaderWrite`.
        let modelCalls = try runDrainCycles(db, 20, blurb: "a summary that could never land")
        #expect(modelCalls == 0,
                """
                A structurally unattributable row was admitted to \(modelCalls) model call(s). \
                Every one is billed to the user and every result is discarded by the identity \
                guard — IOS-AI-002 / IOS-AI-003.
                """)
        let after = try header(db)
        #expect(after?.summaryBlurb == nil)
        #expect(after?.actionTag == nil)
        #expect(after?.cachedReply == nil)
    }

    // MARK: - 2. NON-VACUITY CONTROL — a TRANSIENT refusal is not terminal

    /// The one refusal arm that is transient by construction: the folder is mid
    /// purge-and-resync (`uidValidityResetPendingAt`). Classifying it as structural
    /// would silently disable AI for the whole reset window, so it must classify as
    /// transient and the job must still be retried — then succeed once the reaction
    /// finishes and the sync stamps the folder.
    @Test("A folder mid UIDVALIDITY reset is a TRANSIENT refusal — the job keeps retrying and later lands")
    func midResetRefusalIsTransientNotTerminal() throws {
        let db = try makeFixture(folderEpoch: nil, resetPendingAt: Date())
        let row = makeHeader(subject: "Mid-reset", rfc822: nil, observedEpoch: nil)
        try db.write { try row.insert($0) }

        #expect(try admissionForOneDrainCycle(db) == .transientlyRefused,
                "a refusal that ends when the reaction ends must never be marked terminal")
        #expect(try runDrainCycles(db, 3, blurb: "mid-reset summary") == 0)
        #expect(try header(db)?.summaryBlurb == nil)

        // The reaction finishes and the resync stamps folder and row.
        try db.write { db in
            guard var folder = try Folder.fetchOne(db, key: Self.folderId) else { return }
            folder.uidValidityResetPendingAt = nil
            folder.lastKnownUidValidity = 909
            try folder.update(db)
            guard var header = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            header.observedUidValidity = 909
            try header.save(db)
        }

        #expect(try admissionForOneDrainCycle(db) == .admissible)
        #expect(try runDrainCycles(db, 1, blurb: "mid-reset summary") == 1)
        #expect(try header(db)?.summaryBlurb == "mid-reset summary",
                "the message the reset window deferred must receive its AI result afterwards")
    }

    // MARK: - 3. NON-VACUITY CONTROL — an ordinary failure still retries WITHOUT a ceiling

    /// The shipped guarantee this fix must not regress. `07a4bb703` retried every
    /// `.needsRetry` at `maxRetries: .max` because there was no epoch admission at all
    /// then, so `.needsRetry` could only ever mean "the model call failed" — genuinely
    /// transient. That ladder is untouched: an attributable row whose model call fails
    /// is still admitted every cycle, and its queue entry survives an unbounded number
    /// of failures.
    @Test("An ATTRIBUTABLE row whose model call fails is re-admitted every cycle and never retired by a retry ceiling")
    func attributableRowWithAFailingModelCallStillRetriesWithoutBound() throws {
        let db = try makeFixture(folderEpoch: 501)
        let row = makeHeader(subject: "Ordinary", rfc822: "<ordinary@example.com>", observedEpoch: 501)
        try db.write { try row.insert($0) }

        // Admission side: nothing about this row is refused, so every cycle reaches the
        // model. (`runDrainCycles` writes on success, so count admissions separately.)
        for _ in 0..<5 {
            #expect(try admissionForOneDrainCycle(db) == .admissible,
                    "an attributable row must never be classified as structurally refused")
        }
        #expect(try header(db)?.summaryBlurb == nil, "no write happened — only the admission was evaluated")

        // Queue side: the `maxRetries: .max` ladder, verbatim from the shipped release.
        var storage = QueueStorage<ActiveAIQueue.AIJob>()
        let job = ActiveAIQueue.AIJob(
            headerId: Self.headerId, accountId: Self.accountId, jobType: .summary)
        let admitted = storage.enqueue(job)
        #expect(admitted)
        for _ in 0..<10_000 {
            _ = storage.collectCandidates(maxJobs: Int.max)
            storage.incrementActiveJobs()
            _ = storage.jobCompleted(job, shouldRetry: true, maxRetries: .max)
        }
        #expect(storage.queue.contains(job),
                "a transient AI failure must retry without a ceiling — capping it would drop work the shipped release preserved")
        #expect(storage.retryCount(for: job) == 10_000)
    }

    // MARK: - 4. The terminal marking must NOT survive the row becoming attributable

    /// An AI summary is recomputable derived content, so terminating the job is
    /// legitimate — but only if it un-terminates. Two independent doors reopen it, and
    /// each is tested on its own: the row's numbering being observed (arm 8), and the
    /// row gaining an RFC 822 Message-ID (arm 6). In both, the AI result must land on
    /// the RIGHT row.
    @Test("A row that later gains a proven numbering is processed again, and its result lands")
    func rowThatLaterGainsANumberingIsProcessedAgain() throws {
        let db = try makeFixture(folderEpoch: nil)
        let row = makeHeader(subject: "Unstamped", rfc822: nil, observedEpoch: nil)
        try db.write { try row.insert($0) }

        #expect(try runDrainCycles(db, 3, blurb: "late summary") == 0)
        #expect(try header(db)?.summaryBlurb == nil)

        // A later sync SELECTs the folder and stamps both folder and row from the same
        // observation (`SyncEngine.runSyncMessages`).
        try db.write { db in
            guard var folder = try Folder.fetchOne(db, key: Self.folderId) else { return }
            folder.lastKnownUidValidity = 777
            try folder.update(db)
            guard var header = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            header.observedUidValidity = 777
            try header.save(db)
        }

        #expect(try admissionForOneDrainCycle(db) == .admissible,
                "terminal must mean 'not this session', never 'never again'")
        #expect(try runDrainCycles(db, 1, blurb: "late summary") == 1)
        let after = try header(db)
        #expect(after?.summaryBlurb == "late summary")
        #expect(after?.subject == "Unstamped", "the result must land on the row it was computed for")
    }

    @Test("A row that later gains an RFC 822 Message-ID is processed again, and its result lands")
    func rowThatLaterGainsAnRfcIdIsProcessedAgain() throws {
        let db = try makeFixture(folderEpoch: nil)
        let row = makeHeader(subject: "Witnessless", rfc822: nil, observedEpoch: nil)
        try db.write { try row.insert($0) }

        #expect(try runDrainCycles(db, 3, blurb: "witness summary") == 0)

        // A later header fetch fills in the Message-ID the original sync missed.
        try db.write { db in
            guard var header = try MessageHeader.fetchOne(db, key: Self.headerId) else { return }
            header.rfc822MessageId = "<witness@example.com>"
            try header.save(db)
        }

        #expect(try admissionForOneDrainCycle(db) == .admissible,
                "arm 6's content witness must reopen the job even with the folder epoch still unknown")
        #expect(try runDrainCycles(db, 1, blurb: "witness summary") == 1)
        let after = try header(db)
        #expect(after?.summaryBlurb == "witness summary")
        #expect(after?.rfc822MessageId == "<witness@example.com>")
    }

    // MARK: - 5. The memo that breaks the repopulate spin is session-scoped, not durable

    /// `.writeRefused` retires the job through `abandonWithoutCompletion`, which sets
    /// no `recentlyCompleted` marker, so `repopulateOnDrain`'s work-remaining query
    /// would re-enqueue it immediately and spin. The in-memory memo is what breaks
    /// that — and `rearmUnattributableJobs()` is what stops it becoming a poison,
    /// clearing on every launch, foreground return and AI re-enable.
    @Test("A structurally-refused job is refused re-entry to the queue, and re-armed on the next launch/foreground")
    func refusalMemoBlocksRepopulateAndIsClearedOnRearm() async {
        let queue = ActiveAIQueue()
        let summary = ActiveAIQueue.AIJob(
            headerId: Self.headerId, accountId: Self.accountId, jobType: .summary)
        let reply = ActiveAIQueue.AIJob(
            headerId: Self.headerId, accountId: Self.accountId, jobType: .reply)

        await queue.noteUnattributableForTesting(summary)
        await queue.noteUnattributableForTesting(reply)
        await queue.enqueue(headerId: Self.headerId, accountId: Self.accountId)
        let idle = await queue.isIdle
        #expect(idle,
                "a structurally-refused job must not be re-armed by the drain-time repopulate")

        await queue.rearmUnattributableJobs()
        let remaining = await queue.unattributableJobCountForTesting
        #expect(remaining == 0,
                "the refusal is session-scoped — nothing about it is durable")
    }
}
