/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// `IOS-SEARCH-001` — the LOCAL half of the search-tap C3, which shipped verbatim
/// in `v1.6.38`.
///
/// **The invariant these tests pin, stated as a system property:** *a tap on a
/// local search result whose captured content identity no longer matches the row
/// at its address opens nothing and registers no read mutation.*
///
/// Why that is C3 and not a render glitch. `SearchResult.headerId` is an ADDRESS
/// (`accountId:folderPath:messageId`, and on IMAP `messageId` IS the per-folder
/// UID). `SearchView.results` is an in-memory array rendered at search time; a
/// `UIDVALIDITY` turnover purges and resyncs the folder, so UIDs restarting — and
/// therefore a DIFFERENT physical message re-seating that exact address — is the
/// EXPECTED outcome, not a coincidence. A sync merge can re-seat a canonical
/// address too. Tapping afterwards used to `navigationPath.append(headerId)`
/// unconditionally, so `MessageDetailView` opened the new occupant and
/// `MessageDetailViewModel.markReadOnOpenIfNeeded` durably marked THAT row read:
/// the user is shown X's subject/sender/snippet and Y is silently mutated. C3
/// names misattribution as well as mutation, and nothing recovers a mark-read the
/// user never asked for — by construction they were shown a different message's
/// row text, so they have no reason to notice.
///
/// **The tests assert the SYSTEM END STATE, not a resolver's return shape.** The
/// harness runs the real consumer chain: the resolver's verdict decides whether a
/// real `MessageDetailViewModel` is constructed for the opened id, and that VM's
/// real `markReadOnOpenIfNeeded` is what registers (or does not register) the
/// `.isRead` gesture intent on `AccountManager.shared`. A fix that renamed a
/// return value but still opened the impostor would not turn these green.
///
/// **Two-sided by construction.** A resolver that refused everything would satisfy
/// the never-open-the-wrong-row half while silently killing search navigation, so
/// `unchangedRowStillOpensAndStillMarksRead` asserts a POSITIVE open AND a
/// POSITIVE read intent through the identical harness — that control is what
/// proves the harness can register an intent at all, which is what makes the red
/// test's "no intent" assertion non-vacuous.
///
/// `.serialized, .processGlobalState`: the harness swaps `AppDatabase.shared` and
/// reads/writes `AccountManager.shared`'s process-wide optimistic overlay, FIFO
/// write queue and intent-cycle register.
@Suite("Local search result tap — content identity (IOS-SEARCH-001, C3)",
       .serialized, .processGlobalState)
struct SearchLocalResultIdentityTests {

    // MARK: - Fixture

    private struct Env {
        let pool: DatabasePool
        let inbox: Folder
        let dir: URL
        let previous: AppDatabase?
    }

    /// One IMAP account and its INBOX. IMAP on purpose: it is the provider whose
    /// `messageId` is a renumberable per-folder UID, i.e. the address space where
    /// a re-seat is reachable.
    private func makeEnv() throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "User", provider: .imap)
            acc.id = "acc1"
            try acc.insert(db)
        }
        var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        inbox.lastKnownUidValidity = 1000
        try pool.writeWithoutTransaction { db in let f = inbox; try f.insert(db) }
        return Env(pool: pool, inbox: inbox, dir: dir, previous: previous)
    }

    private func finish(_ env: Env) {
        InstalledTestDatabaseLifetime.finish(previous: env.previous, pool: env.pool, directory: env.dir)
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    private func resetStagedGlobal() {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
    }

    /// FIFO barrier: every write enqueued before this call has drained when it
    /// returns.
    private func drainWriteQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
        }
    }

    private func header(
        uid: String, rfc: String?, subject: String, inbox: Folder, isRead: Bool = false
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: uid, subject: subject, from: "Sender \(subject)",
            fromAddress: "sender@example.com", to: "user@example.com", date: Date(),
            snippet: "snippet for \(subject)", folderId: inbox.id, accountId: inbox.accountId,
            folderPath: inbox.path, isInInbox: true
        )
        h.rfc822MessageId = rfc
        h.isRead = isRead
        h.headerComplete = true
        h.observedUidValidity = 1000
        return h
    }

    /// Exactly what `SearchView.legacyLocalSearch` / `ftsResultsToSearchResults`
    /// mint from a header row — including the content witness, taken from the same
    /// row every other rendered field comes from.
    private func mintLocalResult(from h: MessageHeader) -> SearchResult {
        SearchResult(
            source: .local, accountId: h.accountId, accountEmail: "user@example.com",
            messageId: h.messageId, folderPath: h.folderPath, subject: h.subject,
            from: h.from, fromAddress: h.fromAddress, date: h.date, snippet: h.snippet,
            isRead: h.isRead, isFlagged: h.isFlagged, headerId: h.id,
            capturedRfc822MessageId: h.rfc822MessageId
        )
    }

    /// THE TAP, end to end, modelled on the production call chain and using
    /// production code for every step that can mutate:
    ///
    ///  1. `SearchView.openResult`'s local branch → `resolveLocalResultHeaderId`
    ///     inside one `dbPool.read`, appending to `navigationPath` only on a
    ///     non-nil verdict.
    ///  2. `.navigationDestination(for: String.self) { MessageDetailView(messageId:) }`
    ///     → `MessageDetailViewModel`, whose `markReadOnOpenIfNeeded` is the real
    ///     code that registers the durable `.isRead` gesture intent.
    ///
    /// Returns the id actually navigated to, or `nil` when nothing opened.
    ///
    /// `reseatBeforeOpening` runs BETWEEN the tap-time proof and the detail view's
    /// own resolve — the window `SearchView.OpenTarget` exists to survive. Default
    /// no-op, so every existing caller is unchanged.
    @MainActor
    private func tap(
        _ result: SearchResult,
        pool: DatabasePool,
        reseatBeforeOpening: () async throws -> Void = {}
    ) async throws -> String? {
        let headerId = try #require(result.headerId, "fixture must mint a LOCAL result")
        let resolved = try? await pool.read { db in
            try SearchView.resolveLocalResultHeaderId(
                headerId: headerId,
                capturedRfc822MessageId: result.capturedRfc822MessageId,
                db: db
            )
        }
        guard let opened = resolved else { return nil }
        try await reseatBeforeOpening()
        // Production step 2: `.navigationDestination(for: SearchView.OpenTarget.self)`
        // → `MessageDetailView(messageId:expectedRfc822MessageId:)` → this VM. The
        // witness travels WITH the address, exactly as `openResult` appends it.
        let target = SearchView.OpenTarget(
            headerId: opened, provenRfc822MessageId: result.capturedRfc822MessageId)
        let vm = MessageDetailViewModel(
            messageId: target.headerId, dbPool: pool, fetchBodyOverride: { _ in },
            expectedRfc822MessageId: target.provenRfc822MessageId)
        await vm.markReadOnOpenIfNeeded()
        return opened
    }

    /// Every intent-cycle id belonging to this fixture's account. Broader than a
    /// single-id lookup on purpose: a wrong-open would register against SOME id in
    /// this account, not necessarily the one the assertion happens to name.
    private func fixtureIntentCycleIds() -> [String] {
        AccountManager.shared.pendingIntentCyclesForTesting().keys
            .filter { $0.hasPrefix("acc1:") }
            .sorted()
    }

    // MARK: - (i) THE C3 CASE — a re-seated address opens nothing and mutates nothing

    @Test("""
    a local result whose captured content identity no longer matches the row at its \
    address opens NOTHING and registers NO read mutation — the row that re-seated \
    the address is never navigated to and is still unread afterwards
    """)
    @MainActor
    func staleAddressOpensNothingAndMarksNothingRead() async throws {
        let env = try makeEnv()
        defer { finish(env); clearOverlay(); resetStagedGlobal() }
        clearOverlay(); resetStagedGlobal()

        // The message the user searched for and whose row text the result renders.
        let rendered = header(uid: "5", rfc: "<rendered@example.com>", subject: "Invoice", inbox: env.inbox)
        try await env.pool.write { db in try rendered.insert(db) }
        let result = mintLocalResult(from: rendered)

        // A UIDVALIDITY turnover purges the folder and the resync re-seats UID 5
        // onto a DIFFERENT physical message. Same composite address, same PK.
        let impostor = header(uid: "5", rfc: "<impostor@example.com>", subject: "Salary review", inbox: env.inbox)
        #expect(impostor.id == rendered.id, "fixture must re-seat the SAME address, or the test proves nothing")
        try await env.pool.write { db in
            try rendered.delete(db)
            try impostor.insert(db)
        }

        // NON-VACUITY: the impostor really is present, really is a different
        // message, and really is unread — so a refusal below is a discrimination,
        // not an empty table.
        let seated = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: impostor.id) }
        #expect(seated?.rfc822MessageId == "<impostor@example.com>")
        #expect(seated?.isRead == false)

        // Gate the FIFO write queue so any intent cycle the tap opened would still
        // be observable in the register when we assert (the executor drains it).
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        let opened = try await tap(result, pool: env.pool)

        // (a) NO NAVIGATION.
        #expect(opened == nil, """
            the tap navigated to a row that is not the message it rendered. The user taps "Invoice" \
            and lands on "Salary review".
            """)
        #expect(opened != impostor.id, "the re-seated row must never be the tap's target")

        // (b) NO READ MUTATION — the C3 half, and the one that matters. Nothing
        //     opened, so nothing registered a durable read intent.
        #expect(fixtureIntentCycleIds().isEmpty, """
            a `.isRead` gesture intent was registered for a message the user never selected — \
            markReadOnOpenIfNeeded ran against the re-seated row (C3 misattribution + mutation).
            """)

        gate.finish()
        await drainWriteQueue()

        // End state: fail-closed means fail-closed. The impostor is byte-identical.
        let after = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: impostor.id) }
        #expect(after?.isRead == false, "the re-seated row was durably marked read by a tap that never named it")
        #expect(after?.rfc822MessageId == "<impostor@example.com>")
        let ops = try await env.pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(ops == 0, "a refused tap must queue no durable operation at all")
    }

    // MARK: - (ii) NON-VACUITY CONTROL — the ordinary tap still works

    @Test("""
    NON-VACUITY: an unchanged row still opens and still gets marked read — the guard \
    is a discrimination, not a blanket refusal that would silently kill search navigation
    """)
    @MainActor
    func unchangedRowStillOpensAndStillMarksRead() async throws {
        let env = try makeEnv()
        defer { finish(env); clearOverlay(); resetStagedGlobal() }
        clearOverlay(); resetStagedGlobal()

        let row = header(uid: "7", rfc: "<ordinary@example.com>", subject: "Ordinary", inbox: env.inbox)
        try await env.pool.write { db in try row.insert(db) }
        let result = mintLocalResult(from: row)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        let opened = try await tap(result, pool: env.pool)

        #expect(opened == row.id, "an ordinary local result MUST still open — never drop the user's tap")

        // The harness CAN register an intent. This is what makes case (i)'s
        // "no intent" assertion evidence rather than a vacuous pass.
        let cycles = AccountManager.shared.pendingIntentCyclesForTesting()
        #expect(cycles[row.id]?.isReadTarget == true, """
            the ordinary open registered no read intent — the harness cannot observe the mutation it \
            is supposed to be excluding in the stale case.
            """)
        #expect(fixtureIntentCycleIds() == [row.id])

        gate.finish()
        await drainWriteQueue()

        let after = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: row.id) }
        #expect(after?.isRead == true, "opening an unread message must still durably mark it read")
    }

    // MARK: - (iii) The witness-less population — a POSITIVE control, and a named residual

    /// 🚨 ADJUDICATION (2026-08-04). The predecessor of this test was called
    /// `rfcLessResultKeepsTodaysBehaviour` and it asserted, on the resolver's
    /// RETURN VALUE alone, that `resolveLocalResultHeaderId` hands back the
    /// headerId for a row with no usable RFC witness. A reviewer graded it a
    /// BLESSING TEST. **It is REWRITTEN, not deleted, and the distinction is the
    /// whole point:**
    ///
    ///  - A blessing test asserts that the DEFECTIVE OUTCOME is correct. The one
    ///    this repo had to DELETE outright (`7c26989b9`) asserted that a
    ///    nil-accountId notification tap SHOULD durably mark a globally-matched
    ///    row read — the wrong-message mutation WAS the assertion's subject, so
    ///    no rewrite could preserve it.
    ///  - This test's subject is different: *an ordinary, un-re-seated,
    ///    witness-less row still opens and still gets marked read*. That property
    ///    is TRUE and REQUIRED — it is the never-drop half, and a guard that
    ///    refused this population would silently kill search navigation for every
    ///    message that carries no `Message-ID` header (RFC 5322 makes it a SHOULD,
    ///    not a MUST) and for every older row whose column was never populated.
    ///
    /// What was genuinely wrong with the predecessor, and is fixed here: (a) it
    /// pinned the fix's MECHANISM (a return value) rather than the system
    /// property, which global Testing rule 12 forbids — a resolver that returned
    /// the right id and a consumer that then opened the wrong row would have left
    /// it green; (b) it framed an UNCLOSED residual as desired behaviour, with no
    /// register row and nothing marking the limit of what it proves.
    ///
    /// **What this population does NOT get, stated plainly:** with no witness
    /// there is nothing to compare, so a re-seated address IS still opened and
    /// marked read for these rows. That is the accepted residual, registered as
    /// `IOS-IDENTITY-001`, and it is the reference's own decision — `v2final`'s
    /// `ExpectedMessageIdentity.map` excludes rfc-nil rows from the identity map
    /// entirely so no refusal is possible (ADR-IOS-061 item E). Both substitutes
    /// anyone reached for are BANNED: a `date` witness (authored and removed in
    /// the reference as unsound in both directions) and a
    /// `(fromAddress, subject, date)` witness (`94fac3e79`, reverted `3bd9f0bac`).
    @Test("""
    NON-VACUITY / residual control: a witness-less row (no Message-ID at all, or an \
    empty one) still opens through the real consumer chain AND still gets durably marked \
    read — the guard never becomes a blanket refusal for mail that carries no Message-ID
    """)
    @MainActor
    func witnessLessRowStillOpensAndStillMarksRead() async throws {
        let env = try makeEnv()
        defer { finish(env); clearOverlay(); resetStagedGlobal() }
        clearOverlay(); resetStagedGlobal()

        // Both shapes of "no usable witness": absent, and present-but-empty.
        let none = header(uid: "11", rfc: nil, subject: "No message id", inbox: env.inbox)
        let empty = header(uid: "12", rfc: "", subject: "Empty message id", inbox: env.inbox)
        try await env.pool.write { db in try none.insert(db); try empty.insert(db) }

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // The REAL chain, not the resolver in isolation: tap → resolve → detail
        // VM → markReadOnOpenIfNeeded.
        let openedNone = try await tap(mintLocalResult(from: none), pool: env.pool)
        let openedEmpty = try await tap(mintLocalResult(from: empty), pool: env.pool)

        #expect(openedNone == none.id, "a witness-less row must keep today's behaviour, not be refused")
        #expect(openedEmpty == empty.id, "an empty Message-ID is no witness either — same residual")

        // The SYSTEM property, which the predecessor never reached: the open is
        // real all the way to the durable mutation.
        let cycles = AccountManager.shared.pendingIntentCyclesForTesting()
        #expect(cycles[none.id]?.isReadTarget == true, "a witness-less open must still register its read intent")
        #expect(cycles[empty.id]?.isReadTarget == true, "an empty-witness open must still register its read intent")
        #expect(fixtureIntentCycleIds() == [none.id, empty.id].sorted())

        gate.finish()
        await drainWriteQueue()

        let afterNone = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: none.id) }
        let afterEmpty = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: empty.id) }
        #expect(afterNone?.isRead == true, "opening a witness-less message must still durably mark it read")
        #expect(afterEmpty?.isRead == true, "opening an empty-witness message must still durably mark it read")
    }

    // MARK: - (iv) The witness is COMPARED through the tree's normalizer

    @Test("""
    a captured witness that differs from the stored one only in RFC 5322 bracket/whitespace \
    formatting still opens — the comparison runs through MessageIdentity.comparableRfc822Identity, \
    so formatting noise never refuses a legitimate message
    """)
    @MainActor
    func formattingOnlyDifferenceStillOpens() async throws {
        let env = try makeEnv()
        defer { finish(env); clearOverlay(); resetStagedGlobal() }
        clearOverlay(); resetStagedGlobal()

        let row = header(uid: "21", rfc: "<same@example.com>", subject: "Bracketed", inbox: env.inbox)
        try await env.pool.write { db in try row.insert(db) }

        // Same identity, different surface form — exactly what
        // `comparableRfc822Identity` exists to collapse.
        let resolved = try await env.pool.read { db in
            try SearchView.resolveLocalResultHeaderId(
                headerId: row.id, capturedRfc822MessageId: "  same@example.com  ", db: db)
        }
        #expect(resolved == row.id, "bracket/whitespace normalization must not cost the user an open")

        // …and the discrimination is still real: a genuinely different id refuses.
        let refused = try await env.pool.read { db in
            try SearchView.resolveLocalResultHeaderId(
                headerId: row.id, capturedRfc822MessageId: "<other@example.com>", db: db)
        }
        #expect(refused == nil, "a different Message-ID at the same address is a different message")
    }

    // MARK: - (v) The address no longer names a row at all

    @Test("""
    a witness-bearing result whose row has vanished from its address opens nothing — \
    fail closed; re-running the search rebuilds the results from live rows
    """)
    @MainActor
    func vanishedRowFailsClosed() async throws {
        let env = try makeEnv()
        defer { finish(env); clearOverlay(); resetStagedGlobal() }
        clearOverlay(); resetStagedGlobal()

        let row = header(uid: "31", rfc: "<vanishing@example.com>", subject: "Vanishing", inbox: env.inbox)
        try await env.pool.write { db in try row.insert(db) }
        let result = mintLocalResult(from: row)
        try await env.pool.write { db in _ = try row.delete(db) }

        let opened = try await tap(result, pool: env.pool)

        #expect(opened == nil, "no row at the captured address ⇒ nothing to prove identity against ⇒ open nothing")
        #expect(fixtureIntentCycleIds().isEmpty, "a refused tap registers no read intent")
    }

    // MARK: - (vi) THE GAP AFTER THE PROOF — a re-seat BETWEEN the tap and the open

    /// **The invariant, as a system property:** *no durable mark-read lands on a
    /// message whose identity differs from the one the user's tap was proved
    /// against — including when the address is re-seated AFTER that proof and
    /// BEFORE the detail view resolves it.*
    ///
    /// WHY THIS IS A SEPARATE DEFECT FROM `staleAddressOpensNothingAndMarksNothingRead`.
    /// That test re-seats the address BEFORE the tap, so `resolveLocalResultHeaderId`
    /// sees the impostor and refuses; the proof does its job. This one re-seats it
    /// AFTER — the proof PASSES, is correct at the instant it is taken, and is then
    /// discarded by `navigationPath.append`, which used to carry only the composite
    /// ADDRESS. `MessageDetailViewModel` re-resolves that address by primary key and
    /// `markReadOnOpenIfNeeded` durably marks whatever it finds. The window is real:
    /// the mark-read is deliberately independent of the body-load path's timing, and
    /// a UIDVALIDITY purge-and-resync (or a sync merge seating a canonical address)
    /// runs on its own schedule. A fix that only hardened the resolver leaves this
    /// green-looking and broken; only carrying the witness closes it.
    @Test("""
    a UIDVALIDITY re-seat landing AFTER the tap's identity proof and BEFORE the detail \
    view resolves the address registers NO read mutation — the proof travels with the \
    address, so the impostor is still unread afterwards
    """)
    @MainActor
    func reseatAfterTheProofMarksNothingRead() async throws {
        let env = try makeEnv()
        defer { finish(env); clearOverlay(); resetStagedGlobal() }
        clearOverlay(); resetStagedGlobal()

        let rendered = header(uid: "41", rfc: "<rendered-41@example.com>", subject: "Invoice", inbox: env.inbox)
        try await env.pool.write { db in try rendered.insert(db) }
        let result = mintLocalResult(from: rendered)

        let impostor = header(uid: "41", rfc: "<impostor-41@example.com>", subject: "Salary review", inbox: env.inbox)
        #expect(impostor.id == rendered.id, "fixture must re-seat the SAME address, or the test proves nothing")

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        // The proof PASSES (the rendered row is still there when the tap resolves),
        // and only then does the folder turn over.
        let opened = try await tap(result, pool: env.pool) {
            try await env.pool.write { db in
                try rendered.delete(db)
                try impostor.insert(db)
            }
        }

        // The navigation itself is legitimate — the proof was true when taken. What
        // must NOT happen is the durable mutation on the row that replaced it.
        #expect(opened == rendered.id, "the tap's own proof was valid at the time it was taken")

        // NON-VACUITY: the impostor really is seated, really is a different message,
        // and really is unread — so "no intent" is a discrimination, not an empty table.
        let seated = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: impostor.id) }
        #expect(seated?.rfc822MessageId == "<impostor-41@example.com>")
        #expect(seated?.isRead == false)

        #expect(fixtureIntentCycleIds().isEmpty, """
            a `.isRead` gesture intent was registered for a message the user never selected — \
            the tap's identity proof was discarded at the navigation boundary and \
            markReadOnOpenIfNeeded ran against the row that re-seated the address (C3).
            """)

        gate.finish()
        await drainWriteQueue()

        let after = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: impostor.id) }
        #expect(after?.isRead == false, "the re-seated row was durably marked read by an open that never named it")
        let ops = try await env.pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(ops == 0, "a refused mark-read must queue no durable operation at all")
    }

    /// NON-VACUITY PARTNER for the test above, through the IDENTICAL harness
    /// including the mid-flight hook: the hook fires but changes nothing about the
    /// message's identity, and the read still lands. Without this, a
    /// `markReadPermitted` that returned `false` unconditionally — or a harness
    /// whose `reseatBeforeOpening` broke the VM outright — would look like a pass.
    @Test("""
    NON-VACUITY: a mid-flight write that does NOT change the message's identity still \
    lets the open mark it read — the witness discriminates on identity, not on "something \
    happened between the tap and the open"
    """)
    @MainActor
    func identityPreservingMidFlightWriteStillMarksRead() async throws {
        let env = try makeEnv()
        defer { finish(env); clearOverlay(); resetStagedGlobal() }
        clearOverlay(); resetStagedGlobal()

        let row = header(uid: "42", rfc: "<stable-42@example.com>", subject: "Ordinary", inbox: env.inbox)
        try await env.pool.write { db in try row.insert(db) }
        let result = mintLocalResult(from: row)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        let opened = try await tap(result, pool: env.pool) {
            // Same address, SAME Message-ID — a perfectly ordinary re-write (a
            // flag toggle arriving from sync, say). Identity is unchanged.
            try await env.pool.write { db in
                _ = try MessageHeader
                    .filter(Column("id") == row.id)
                    .updateAll(db, Column("isFlagged").set(to: true))
            }
        }

        #expect(opened == row.id, "an identity-preserving change must never cost the user the open")
        let cycles = AccountManager.shared.pendingIntentCyclesForTesting()
        #expect(cycles[row.id]?.isReadTarget == true, """
            the witness refused an open whose message never changed — that is a blanket \
            refusal, and it would silently stop search opens from marking mail read.
            """)

        gate.finish()
        await drainWriteQueue()

        let after = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: row.id) }
        #expect(after?.isRead == true, "opening an unread message must still durably mark it read")
        #expect(after?.isFlagged == true, "non-vacuity: the mid-flight write really did land")
    }
}
