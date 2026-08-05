/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// `IOS-SEARCH-001`, REMOTE arm — the half the local closure left unwitnessed.
///
/// **The invariant pinned here, as a system property:** *opening a REMOTE search
/// result never durably marks read a message whose identity differs from the record
/// the tapped row was rendered from.*
///
/// ## Why this arm was open while the local one was closed
///
/// The local arm captures its content witness from the header row it rendered.
/// `SearchView.tapOutcome` used to hard-force `provenRfc822MessageId` to `nil` for
/// every remote result, on the stated rationale that *"a remote result carries NO
/// content witness (there was no local row to capture one from)"*. **That premise
/// was false, and the code was correct only if you believed it.** A witness needs no
/// local row: `MessageHeaderInfo.rfc822MessageId` is the SERVER's Message-ID for the
/// very record the row renders, supplied by the same producer that fills a local
/// row's own column, and it was already sitting in the value
/// `SearchView.presentableRemoteResults` maps. The conclusion drawn from the false
/// premise — *"a false proof is worse than none"* — is sound in general and simply
/// did not apply, because the proof was real.
///
/// The omission was SILENT in both directions, which is why it survived a closure
/// round: `SearchResult.capturedRfc822MessageId` is nil-DEFAULTED, so failing to
/// pass it compiled cleanly, and `MessageDetailViewModel.markReadPermitted` is
/// `guard let openIdentity else { return true }` — FAIL OPEN. Nothing anywhere
/// reported that every remote open was travelling unwitnessed.
///
/// ## The window, and why it is a real one
///
/// `SearchView.results` is an in-memory array. `resolveRemoteResultHeaderId`
/// establishes that SOMETHING exists at `(accountId, folderPath, messageId)` — on
/// IMAP that `messageId` is the per-folder UID, an ADDRESS in a numbering space. A
/// `UIDVALIDITY` turnover purges and resyncs the folder, so a different physical
/// message re-seating that exact address is the EXPECTED outcome, and a sync merge
/// can re-seat a canonical address too. The tap then opens the new occupant and
/// `markReadOnOpenIfNeeded` durably mutates it: the user is shown X and Y is
/// silently marked read. C3 names misattribution as squarely as mutation, and
/// nothing recovers it — by construction the user was shown a different message's
/// row text and has no reason to notice.
///
/// ## Severity, as adjudicated — recorded, not relitigated
///
/// REGISTRABLE-HIGH, **not** blocking. Every pre-range path carried NO witness on
/// ANY tap, so the range that introduced the mechanism (`b1ae6e262` authored it,
/// `afa7889ee` authored this remote path) is a strict improvement rather than a
/// regression, and the exposure window is one live on-screen search session, not
/// unbounded. It is fixed here anyway; the classification exists so the fix stays
/// small and additive rather than growing under "C3" pressure.
///
/// ## A1 — the shipped release is not a template
///
/// `git show 07a4bb703:TabMail/Views/Inbox/SearchView.swift` (shipped `v1.6.38`) and
/// `git show e28dd4edb:…` (`v2final`, a SIBLING branch that never shipped): neither
/// contains `capturedRfc822MessageId`, `OpenTarget`, `tapOutcome`, or any content
/// witness on any tap path. Both push a bare address —
/// `navigationPath.append(headerId)` — into
/// `MessageDetailView(messageId:)`, which has no expected-identity parameter at all.
/// The shipped architecture for this problem is **NONEXISTENT** (A1 step 3), so this
/// is new work; there is no shipped property to restore and none to inherit.
///
/// ## What these tests assert
///
/// The SYSTEM END STATE through the real consumer chain — the real
/// `presentableRemoteResults` builds the result from a real `MessageHeaderInfo`, the
/// real `tapOutcome` decides, and a real `MessageDetailViewModel.markReadOnOpenIfNeeded`
/// is what registers (or does not register) the durable `.isRead` intent. A fix that
/// renamed a field but still mutated the impostor would not turn these green.
///
/// `.serialized, .processGlobalState`: the harness swaps `AppDatabase.shared` and
/// reads/writes `AccountManager.shared`'s process-wide overlay, FIFO write queue and
/// intent-cycle register.
@Suite("Remote search result tap — content identity (IOS-SEARCH-001, C3)",
       .serialized, .processGlobalState)
struct SearchRemoteResultIdentityTests {

    // MARK: - Fixture

    private struct Env {
        let pool: DatabasePool
        let inbox: Folder
        let dir: URL
        let previous: AppDatabase?
    }

    /// One IMAP account and its INBOX. IMAP on purpose: it is the provider whose
    /// `messageId` is a renumberable per-folder UID, i.e. the address space where a
    /// re-seat is reachable at all.
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

    /// FIFO barrier: every write enqueued before this call has drained when it returns.
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

    /// What the provider hands back for one SEARCH hit. `rfc822MessageId` is the
    /// second field of `MessageHeaderInfo` and is set by the one true producer,
    /// `IMAPProvider.mapMessageInfo` — the same producer that fills a local row's
    /// `rfc822MessageId` column.
    private func remoteInfo(uid: String, rfc: String?, subject: String) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: uid, rfc822MessageId: rfc, inReplyTo: nil, references: [],
            threadId: nil, subject: subject, from: "Sender \(subject)",
            fromAddress: "sender@example.com", to: "user@example.com", cc: "", bcc: "",
            replyTo: nil, date: Date(), snippet: "snippet for \(subject)",
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil
        )
    }

    /// A remote `SearchResult` built the way production builds one — through the
    /// real `presentableRemoteResults`, so the witness POPULATION is exercised here
    /// rather than asserted separately. A test that hand-minted the `SearchResult`
    /// would keep passing if that function stopped carrying the field.
    private func mintRemoteResult(_ info: MessageHeaderInfo) throws -> SearchResult {
        let presented = SearchView.presentableRemoteResults(
            from: [info], accountId: "acc1", accountEmail: "user@example.com",
            folderPath: "INBOX")
        return try #require(presented.first, "fixture must present exactly one remote result")
    }

    /// THE TAP, end to end, modelled on `SearchView.openResult`'s REMOTE branch and
    /// using production code for every step that can mutate:
    ///
    ///  1. `resolveRemoteResultHeaderId` inside one `dbPool.read` — address-scoped,
    ///     unchanged by this work.
    ///  2. `SearchView.tapOutcome`, which decides what the tap does and what proof
    ///     travels with it.
    ///  3. `.navigationDestination(for: SearchView.OpenTarget.self)` →
    ///     `MessageDetailView(messageId:expectedRfc822MessageId:)` → the real
    ///     `MessageDetailViewModel.markReadOnOpenIfNeeded`.
    ///
    /// Returns the id actually navigated to, or `nil` when nothing opened.
    @MainActor
    private func tapRemote(_ result: SearchResult, pool: DatabasePool) async throws -> String? {
        #expect(result.headerId == nil, "fixture must mint a REMOTE result — headerId nil is what makes it remote")
        let resolved = try? await pool.read { db in
            try SearchView.resolveRemoteResultHeaderId(
                accountId: result.accountId, messageId: result.messageId,
                folderPath: result.folderPath, db: db)
        }
        switch SearchView.tapOutcome(for: result, resolvedHeaderId: resolved) {
        case .open(let target):
            let vm = MessageDetailViewModel(
                messageId: target.headerId, dbPool: pool, fetchBodyOverride: { _ in },
                expectedRfc822MessageId: target.provenRfc822MessageId)
            await vm.markReadOnOpenIfNeeded()
            return target.headerId
        case .explainStaleLocalResult, .explainRemoteResultNotOnThisDevice:
            return nil
        }
    }

    /// Every intent-cycle id belonging to this fixture's account. Broader than a
    /// single-id lookup on purpose: a wrong mutation would register against SOME id
    /// in this account, not necessarily the one an assertion happens to name.
    private func fixtureIntentCycleIds() -> [String] {
        AccountManager.shared.pendingIntentCyclesForTesting().keys
            .filter { $0.hasPrefix("acc1:") }
            .sorted()
    }

    // MARK: - (i) THE DEFECT — a re-seated address must not be marked read

    @Test("""
    a REMOTE result whose address has been re-seated onto a different physical message \
    registers NO read mutation — the provider's own Message-ID is the witness, and the \
    row that took over the address is still unread afterwards
    """)
    @MainActor
    func reseatedRemoteAddressMarksNothingRead() async throws {
        let env = try makeEnv()
        defer { finish(env); clearOverlay(); resetStagedGlobal() }
        clearOverlay(); resetStagedGlobal()

        // The record the SERVER returned and whose text the search row renders.
        let result = try mintRemoteResult(
            remoteInfo(uid: "5", rfc: "<rendered@example.com>", subject: "Invoice"))

        // NON-VACUITY (population): the witness really did travel from the provider
        // value onto the result. Without this the test below could pass because the
        // resolve failed rather than because the witness refused.
        #expect(result.capturedRfc822MessageId == "<rendered@example.com>", """
            presentableRemoteResults dropped the provider's Message-ID — the remote result is \
            unwitnessed before the tap even happens.
            """)

        // A UIDVALIDITY turnover purged the folder and the resync seated UID 5 onto
        // a DIFFERENT physical message. Same composite address, same PK.
        let impostor = header(uid: "5", rfc: "<impostor@example.com>", subject: "Salary review", inbox: env.inbox)
        #expect(impostor.id == "acc1:INBOX:5", "fixture must re-seat the address the remote result names")
        try await env.pool.write { db in try impostor.insert(db) }

        // NON-VACUITY (state): the impostor is present, is a different message, and
        // is unread — so a refusal below is a discrimination, not an empty table.
        let seated = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: impostor.id) }
        #expect(seated?.rfc822MessageId == "<impostor@example.com>")
        #expect(seated?.isRead == false)

        // Gate the FIFO write queue so any intent cycle the tap opened is still
        // observable in the register when we assert.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        let opened = try await tapRemote(result, pool: env.pool)

        // (a) IT STILL OPENS. Rendering is deliberately NOT gated — an opened
        //     message is on screen for the user to see, and refusing to render
        //     would be a regression with no C3 payoff. Asserting this keeps the fix
        //     from being "silently refuse remote taps", which would pass (b).
        #expect(opened == impostor.id, """
            the remote tap stopped navigating. The witness gates the durable mark-read ONLY; \
            the resolve is address-scoped and unchanged.
            """)

        // (b) NO READ MUTATION — the C3 half, and the point of the whole change.
        #expect(fixtureIntentCycleIds().isEmpty, """
            a `.isRead` gesture intent was registered for a message the user never selected — \
            markReadOnOpenIfNeeded ran against the row that re-seated the address \
            (C3 misattribution + mutation).
            """)

        gate.finish()
        await drainWriteQueue()

        let after = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: impostor.id) }
        #expect(after?.isRead == false, """
            the re-seated row was durably marked read by a tap that rendered a different message.
            """)
        let ops = try await env.pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(ops == 0, "a refused mark-read must queue no durable operation at all")
    }

    // MARK: - (ii) THE ANCHOR — the mirror-image fix must break this

    /// 🚨 THE MIRROR-IMAGE GUARD (`MIS-005`). The obvious over-correction to (i) is
    /// *"refuse the open, or the mark-read, when no witness is present"*. That would
    /// pass (i) and silently break every message whose provider supplies no
    /// Message-ID — RFC 5322 makes the header a SHOULD, not a MUST — turning a
    /// misattribution bug into a never-marks-read bug for a whole population.
    ///
    /// The population must keep TODAY's behaviour exactly, and it does so with **no
    /// new branch**: `ExpectedMessageIdentity.init?(capturedRfc822MessageId:)`
    /// already returns `nil` for an absent or unnormalizable value, and
    /// `markReadPermitted` is `guard let openIdentity else { return true }`. This
    /// test exists so that a future "tighten the guard" edit cannot land quietly.
    @Test("""
    ANCHOR / non-vacuity: a REMOTE result whose provider supplied NO Message-ID still \
    opens AND still gets durably marked read — the fix adds a refusal only where a real \
    witness disagrees, never where one is merely absent
    """)
    @MainActor
    func remoteResultWithNoProviderWitnessStillOpensAndMarksRead() async throws {
        let env = try makeEnv()
        defer { finish(env); clearOverlay(); resetStagedGlobal() }
        clearOverlay(); resetStagedGlobal()

        // Both shapes of "the provider gave us nothing to compare": absent, and
        // present-but-empty.
        let noneResult = try mintRemoteResult(remoteInfo(uid: "11", rfc: nil, subject: "No message id"))
        let emptyResult = try mintRemoteResult(remoteInfo(uid: "12", rfc: "", subject: "Empty message id"))
        #expect(noneResult.capturedRfc822MessageId == nil)
        #expect(emptyResult.capturedRfc822MessageId == "")

        // The local rows these addresses name. Their own witnesses are irrelevant:
        // with nothing captured there is nothing to compare against.
        let none = header(uid: "11", rfc: nil, subject: "No message id", inbox: env.inbox)
        let empty = header(uid: "12", rfc: "<local-only@example.com>", subject: "Empty message id", inbox: env.inbox)
        try await env.pool.write { db in try none.insert(db); try empty.insert(db) }

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        let openedNone = try await tapRemote(noneResult, pool: env.pool)
        let openedEmpty = try await tapRemote(emptyResult, pool: env.pool)

        #expect(openedNone == none.id, "a remote hit with no provider Message-ID must still open")
        #expect(openedEmpty == empty.id, "an empty Message-ID is no witness either — same population")

        // The SYSTEM property: the open is real all the way to the durable mutation.
        let cycles = AccountManager.shared.pendingIntentCyclesForTesting()
        #expect(cycles[none.id]?.isReadTarget == true, "a witness-less remote open must still register its read intent")
        #expect(cycles[empty.id]?.isReadTarget == true, "an empty-witness remote open must still register its read intent")
        #expect(fixtureIntentCycleIds() == [none.id, empty.id].sorted())

        gate.finish()
        await drainWriteQueue()

        let afterNone = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: none.id) }
        let afterEmpty = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: empty.id) }
        #expect(afterNone?.isRead == true, "opening a witness-less remote hit must still durably mark it read")
        #expect(afterEmpty?.isRead == true, "opening an empty-witness remote hit must still durably mark it read")
    }

    // MARK: - (iii) THE ORDINARY TAP — the guard is a discrimination, not a refusal

    @Test("""
    NON-VACUITY: a REMOTE result whose provider Message-ID still matches the row at its \
    address opens AND gets durably marked read — this is the control that proves the \
    harness can register the mutation case (i) asserts the absence of
    """)
    @MainActor
    func matchingRemoteWitnessStillOpensAndMarksRead() async throws {
        let env = try makeEnv()
        defer { finish(env); clearOverlay(); resetStagedGlobal() }
        clearOverlay(); resetStagedGlobal()

        let result = try mintRemoteResult(
            remoteInfo(uid: "7", rfc: "<ordinary@example.com>", subject: "Ordinary"))
        let row = header(uid: "7", rfc: "<ordinary@example.com>", subject: "Ordinary", inbox: env.inbox)
        try await env.pool.write { db in try row.insert(db) }

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }

        let opened = try await tapRemote(result, pool: env.pool)
        #expect(opened == row.id, "an ordinary remote result MUST still open — never drop the user's tap")

        let cycles = AccountManager.shared.pendingIntentCyclesForTesting()
        #expect(cycles[row.id]?.isReadTarget == true, """
            the ordinary remote open registered no read intent — the harness cannot observe the \
            mutation it is supposed to be excluding in the re-seat case.
            """)
        #expect(fixtureIntentCycleIds() == [row.id])

        gate.finish()
        await drainWriteQueue()

        let after = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: row.id) }
        #expect(after?.isRead == true, "opening an unread message must still durably mark it read")
    }
}
