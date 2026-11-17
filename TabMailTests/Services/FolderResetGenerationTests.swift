/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// The invariant: no mutating IMAP command reaches the email re-seated at an id
/// when the user's view of that id was read before the folder's UIDVALIDITY
/// reset. A view read after the reset acts normally.
///
/// The reset is the REAL reaction (`runUidValidityResetReaction`) against a fake
/// IMAP server whose new epoch puts a DIFFERENT email at the shown row's UID, so
/// the resync re-seats it at the same header id with the new epoch, which the
/// epoch check alone admits. The wire oracle is registered on the email the user
/// SAW, so any command that touches the replacement is a recorded violation.
@Suite("Folder reset generation", .serialized, .processGlobalState)
@MainActor
struct FolderResetGenerationTests {

    private static let oldEpoch = 810_001
    private static let newEpoch = 810_002
    nonisolated private static let uid = 101
    private static let shownRfc = "shown-101@example.com"
    private static let replacementRfc = "replacement-101@example.com"

    private struct Env {
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let server: FakeIMAPServer
        let accountId: String
        var headerId: String {
            MessageIdentity.headerId(
                accountId: accountId, folderPath: "INBOX",
                messageId: String(FolderResetGenerationTests.uid))
        }
        var inboxFolderId: String { MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX") }
    }

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: reset generation fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        reset generation fixture body.\r

        """
    }

    /// One IMAP account; INBOX holds the shown email at UID 101 under the old
    /// epoch, and the server's new epoch holds a different email at UID 101.
    /// `shownHasRfc == false` is the shown row without a Message-ID, which the
    /// content witness (`ExpectedMessageIdentity`) cannot check.
    /// Fails the next write transaction once, at BEGIN, as a busy database does:
    /// another connection holds the write lock with no busy wait, and the first
    /// write that meets it releases it, so every later write succeeds.
    final class OneShotWriteFailure: @unchecked Sendable {
        private let holder = Mutex<DatabaseQueue?>(nil)
        func arm(path: String) throws {
            var config = Configuration()
            config.allowsUnsafeTransactions = true
            let queue = try DatabaseQueue(path: path, configuration: config)
            try queue.inDatabase { try $0.execute(sql: "BEGIN IMMEDIATE") }
            holder.withLock { $0 = queue }
        }
        /// Busy callback: refuse this attempt and release the lock.
        func onBusy() -> Bool {
            if let queue = holder.withLock({ q -> DatabaseQueue? in defer { q = nil }; return q }) {
                try? queue.inDatabase { try $0.execute(sql: "ROLLBACK") }
                try? queue.close()
            }
            return false
        }
    }

    private func makeEnv(
        accountId: String, shownHasRfc: Bool = true, writeFailure: OneShotWriteFailure? = nil
    ) throws -> Env {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [FakeIMAPServer.makeMessage(uid: Self.uid, rfc822Text: Self.rfc822(messageId: Self.replacementRfc))],
            "Archive": [],
            "Trash": [],
        ])
        for path in ["INBOX", "Archive", "Trash"] { server.setUidValidity(Self.newEpoch, for: path) }
        try server.start()

        let (pool, dir, previous): (DatabasePool, URL, AppDatabase?)
        if let writeFailure {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var config = Configuration()
            config.foreignKeysEnabled = true
            config.busyMode = .callback { _ in writeFailure.onBusy() }
            let failingPool = try DatabasePool(path: directory.appendingPathComponent("t.sqlite").path, configuration: config)
            let appDb = try AppDatabase(dbPool: failingPool)
            let prior = AppDatabase.shared.withLock { current -> AppDatabase? in
                let prev = current; current = appDb; return prev
            }
            (pool, dir, previous) = (failingPool, directory, prior)
        } else {
            (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        }
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            totalCount: 1, lastKnownUidNext: Self.uid + 1, lastKnownUidValidity: Self.oldEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool, lastKnownUidValidity: Self.newEpoch)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Trash", role: .trash, pool: pool, lastKnownUidValidity: Self.newEpoch)
        try pool.write { db in
            var header = MessageHeader(
                messageId: String(Self.uid), subject: "shown", from: "Sender",
                fromAddress: "sender@example.com", to: "recipient@example.com",
                date: Date(), snippet: "shown",
                folderId: "\(accountId):INBOX", accountId: accountId, folderPath: "INBOX",
                isInInbox: true)
            header.rfc822MessageId = shownHasRfc ? "<\(Self.shownRfc)>" : nil
            header.headerComplete = true
            header.observedUidValidity = Self.oldEpoch
            try header.insert(db)
        }
        return Env(pool: pool, dir: dir, previous: previous, server: server, accountId: accountId)
    }

    private func finish(_ env: Env) async {
        await AccountManager.shared.unregisterProviderForTesting(accountId: env.accountId)
        env.server.stop()
        InstalledTestDatabaseLifetime.finish(previous: env.previous, pool: env.pool, directory: env.dir)
        clearOverlay()
        UndoService.shared.dismissAll()
        UserDefaults.standard.removeObject(forKey: AccountManager.markReadOnArchiveDeleteKey)
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    private func connectedProvider(_ env: Env) async throws -> IMAPProvider {
        let provider = IMAPProvider(
            host: "127.0.0.1", port: env.server.port,
            username: env.server.username, password: env.server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        return provider
    }

    /// The real reaction, with a connected provider for the account.
    private func runReset(_ env: Env) async throws {
        let provider = try await connectedProvider(env)
        await TestProviderRegistry.withRegisteredProvider(accountId: env.accountId, provider: provider) {
            await AccountManager.shared.runUidValidityResetReaction(accountId: env.accountId, folderPath: "INBOX")
        }
        try? await provider.disconnect()
    }

    /// Drains the local write queue and then the durable queue to the fake
    /// server, so an admitted move reaches the wire.
    private func drainToWire(_ env: Env) async throws {
        await AccountManager.shared.awaitWriteQueueDrain()
        let provider = try await connectedProvider(env)
        await AccountManager.shared.registerProviderForTesting(accountId: env.accountId, provider: provider)
        // A drain already running (started by the action itself) makes this call
        // return at once, so drain until no operation is left (bounded).
        for _ in 0..<100 {
            await AccountManager.shared.drainPendingQueue()
            if try await ops(env).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try? await provider.disconnect()
    }

    private func row(_ env: Env) async throws -> MessageHeader? {
        try await env.pool.read { try MessageHeader.fetchOne($0, key: env.headerId) }
    }

    private func ops(_ env: Env) async throws -> [PendingOperation] {
        try await env.pool.read { try PendingOperation.fetchAll($0) }
    }

    /// Non-vacuity of every refusal: the reset really re-seated a different
    /// email at the shown id, under the new epoch the epoch check accepts.
    private func expectReseated(_ env: Env) async throws {
        let reseated = try #require(try await row(env), "the resync did not re-seat UID \(Self.uid)")
        #expect(reseated.rfc822MessageId?.contains(Self.replacementRfc) == true,
                "fixture: the row at the shown id is not the replacement")
        let live = try await env.pool.read { try Folder.fetchOne($0, key: env.inboxFolderId)?.lastKnownUidValidity }
        #expect(live != nil && live != Self.oldEpoch, "fixture: the reset did not stamp a new epoch")
        #expect(reseated.observedUidValidity == live,
                "fixture: the replacement does not carry the live epoch, so the epoch check alone would refuse it")
    }

    private func inboxUids(_ env: Env) -> [Int] {
        env.server.snapshotMessagesWithFlags(in: "INBOX").map(\.message.uid)
    }

    // MARK: - The AI confirmation card

    /// A confirmation sink that models the hazard: the card is on screen while
    /// the folder's UIDVALIDITY reset runs to completion, then the user confirms.
    @MainActor
    private final class ResettingConfirmSink: AgentUISink {
        let reset: @MainActor () async -> Void
        nonisolated init(reset: @escaping @MainActor () async -> Void) { self.reset = reset }
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            Task { @MainActor in
                await reset()
                confirmation.onRespond(true)
            }
        }
    }

    /// Confirms at once.
    @MainActor
    private final class ConfirmSink: AgentUISink {
        nonisolated init() {}
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            confirmation.onRespond(true)
        }
    }

    enum CardAction: String, CaseIterable, CustomStringConvertible {
        case archive, delete
        var description: String { rawValue }
    }

    @Test("""
    An AI archive or delete card shown before a UIDVALIDITY reset and confirmed after it never \
    moves the email re-seated at the shown id; a card shown after the reset moves it
    """, arguments: CardAction.allCases, [true, false])
    func aiCardConfirmedAcrossAResetNeverMutatesTheReplacement(action: CardAction, shownBeforeReset: Bool) async throws {
        // The shown row has no Message-ID, so the content witness the card already
        // carries is blind and only the reset itself can tell the rows apart.
        let env = try makeEnv(accountId: "frg-card-\(action)-\(shownBeforeReset)", shownHasRfc: false)
        UserDefaults.standard.set(false, forKey: AccountManager.markReadOnArchiveDeleteKey)
        clearOverlay()

        if !shownBeforeReset {
            try await runReset(env)
            try await expectReseated(env)
        }
        let translator = MockChatIdTranslator()
        await translator.seed(31, realId: env.headerId)
        let context = ToolContext(db: env.pool, translator: translator)
        let sink: any AgentUISink = shownBeforeReset
            ? ResettingConfirmSink(reset: { try? await self.runReset(env) })
            : ConfirmSink()
        let invocation = ToolInvocation(uiSink: sink, sessionKey: "frg-card-\(action)-\(shownBeforeReset)")
        let arguments: [String: JSONValue] = ["unique_ids": .array([.int(31)])]
        // The oracle names the email the user saw on the card, for the whole
        // action interval.
        env.server.expectMutation(rfc822MessageId: shownBeforeReset ? Self.shownRfc : Self.replacementRfc)
        let output: String
        switch action {
        case .archive:
            output = try await EmailArchiveTool(context: context).execute(arguments: arguments, invocation: invocation)
        case .delete:
            output = try await EmailDeleteTool(context: context).execute(arguments: arguments, invocation: invocation)
        }
        if shownBeforeReset { try await expectReseated(env) }

        try await drainToWire(env)

        let after = try await row(env)
        if shownBeforeReset {
            #expect(env.server.wrongMessageViolations().isEmpty,
                    "\(action): a card shown before the reset mutated the replacement: \(env.server.wrongMessageViolations())")
            #expect(inboxUids(env).contains(Self.uid), "\(action): the replacement left INBOX on the server")
            #expect(after?.folderPath == "INBOX", "\(action): the replacement was moved locally")
            #expect(try await ops(env).isEmpty, "\(action): a durable operation was queued for the replacement")
            #expect(!output.contains("\"success\":true") && !output.contains("\"success\": true"),
                    "\(action): the tool reported success for a refused move: \(output)")
            // Terminal, never pending: a retry under the same id would act on the
            // replacement, so the agent must not be told the work is outstanding.
            #expect(output.contains("failed_ids") && !output.contains("pending_ids"),
                    "\(action): the refusal was not reported as a terminal failure: \(output)")
        } else {
            // Control: the same card on the replacement, shown after the reset,
            // reaches the wire, so an empty violation list above is not a drain
            // that never ran.
            #expect(env.server.wrongMessageViolations().isEmpty)
            #expect(!inboxUids(env).contains(Self.uid),
                    "control: \(action) of the replacement, shown after the reset, never reached the server: \(output)")
        }
        await finish(env)
    }

    @Test("""
    The card's stamp is taken before the headers it shows are read: a reset that completes \
    after the shown email's read, while the card is still being built, refuses the move
    """, arguments: CardAction.allCases)
    func aiCardStampPrecedesTheHeaderRead(action: CardAction) async throws {
        let env = try makeEnv(accountId: "frg-card-read-\(action)", shownHasRfc: false)
        UserDefaults.standard.set(false, forKey: AccountManager.markReadOnArchiveDeleteKey)
        clearOverlay()
        let translator = MockChatIdTranslator()
        await translator.seed(env.headerId, as: 31)
        // The first lookup (id 31) answers and its header is read; the reset runs
        // at the second lookup (id 32, unknown), before the card is shown.
        await translator.setOnResolve { [translator] in
            await translator.setOnResolve { @MainActor in try? await self.runReset(env) }
        }
        env.server.expectMutation(rfc822MessageId: Self.shownRfc)
        let context = ToolContext(db: env.pool, translator: translator)
        let arguments: [String: JSONValue] = ["unique_ids": .array([.int(31), .int(32)])]
        let invocation = ToolInvocation(uiSink: ConfirmSink(), sessionKey: "frg-card-read-\(action)")
        let output: String
        switch action {
        case .archive:
            output = try await EmailArchiveTool(context: context).execute(arguments: arguments, invocation: invocation)
        case .delete:
            output = try await EmailDeleteTool(context: context).execute(arguments: arguments, invocation: invocation)
        }
        try await expectReseated(env)
        try await drainToWire(env)
        #expect(env.server.wrongMessageViolations().isEmpty,
                "a card whose header was read before the reset mutated the replacement: \(output)")
        #expect(inboxUids(env).contains(Self.uid), "the replacement left INBOX on the server")
        #expect(try await ops(env).isEmpty, "a durable operation was queued for the replacement")
        await finish(env)
    }

    // MARK: - Manual tags

    @Test("""
    A tag intent stamped before the folder's reset never tags the email re-seated at its id; \
    stamped after it, the replacement is tagged
    The same holds when the tag's own write fails once before it runs: no cache or teaching \
    work is attributed to the replacement
    """, arguments: [true, false], [false, true])
    func queuedTagAcrossAResetNeverTagsTheReplacement(stampedBeforeReset: Bool, tagWriteFails: Bool) async throws {
        let failure = tagWriteFails ? OneShotWriteFailure() : nil
        let env = try makeEnv(accountId: "frg-tag-\(stampedBeforeReset)-\(tagWriteFails)", writeFailure: failure)
        clearOverlay()
        let preResetStamp = FolderResetGeneration.current()
        try await runReset(env)
        try await expectReseated(env)
        if let failure { try failure.arm(path: env.pool.path) }
        let stamp = stampedBeforeReset ? preResetStamp : FolderResetGeneration.current()
        FolderResetGeneration.$gestureStamp.withValue(stamp) {
            AccountManager.shared.registerGestureIntent(id: env.headerId, .actionTag(target: .reply, baseline: nil))
        }
        await AccountManager.shared.awaitWriteQueueDrain()
        // The cache and teaching steps run in their own task; wait for them on
        // the control arm (bounded), and give the refused arm the same time.
        func sideEffects() async throws -> (cache: Int, refine: Int) {
            try await env.pool.read { db in
                (try MessageAICache.fetchCount(db), try PendingAIRefinement.fetchCount(db))
            }
        }
        for _ in 0..<200 {
            let effects = try await sideEffects()
            if effects.cache > 0 && effects.refine > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let after = try #require(try await row(env))
        let effects = try await sideEffects()
        if stampedBeforeReset {
            #expect(after.actionTag == nil, "a tag taken before the reset was applied to the replacement")
            #expect(effects.cache == 0 && effects.refine == 0,
                    "a tag taken before the reset was cached or taught for the replacement: \(effects)")
        } else {
            if !tagWriteFails {
                #expect(after.actionTag == .reply, "control: a tag taken after the reset was refused")
            }
            #expect(effects.cache > 0 && effects.refine > 0,
                    "control: the cache or teaching step never ran, so the refused arm's zero proves nothing: \(effects)")
        }
        await finish(env)
    }

    // MARK: - The outbox finalize is not a gesture

    @Test("""
    A completed reply finalized from a task carrying a pre-reset stamp still flags the original \
    it was read against after the reset
    """)
    func outboxFinalizeIgnoresAnInheritedResetStamp() async throws {
        let env = try makeEnv(accountId: "frg-outbox")
        let preResetStamp = FolderResetGeneration.current()
        try await runReset(env)
        try await expectReseated(env)
        var outbox = OutboxMessage(
            accountId: env.accountId,
            draft: DraftMessage(
                to: ["sender@example.com"], subject: "Re: reset generation fixture", body: "reply",
                inReplyTo: "<\(Self.replacementRfc)>"),
            originalMessageHeaderId: env.headerId,
            isForward: false)
        outbox.status = OutboxStatus.sending.rawValue
        outbox.sentAt = Date()
        outbox.appendedToSent = true
        let sent = outbox
        try await env.pool.writeWithoutTransaction { db in try sent.insert(db) }
        _ = try await FolderResetGeneration.$gestureStamp.withValue(preResetStamp) {
            try await env.pool.write { db in
                try AccountManager.deleteCompletedSendAtomic(outboxId: sent.id, db: db)
            }
        }
        let replied = try await ops(env).filter { $0.type == .markReplied }
        #expect(replied.count == 1, "an inherited stamp refused the reply flag of an original read after the reset")
        #expect(try await row(env)?.isReplied == true)
        await finish(env)
    }

    // MARK: - The write queue stamps work when it is enqueued

    @Test("""
    An inbox archive enqueued before the folder's reset is recorded and run after it is refused, \
    reported as a refused move, and leaves no durable operation; enqueued after it, it is admitted
    """, arguments: [true, false])
    func queuedListArchiveStampedBeforeTheResetIsRefused(enqueuedBeforeReset: Bool) async throws {
        let env = try makeEnv(accountId: "frg-queued-\(enqueuedBeforeReset)")
        UserDefaults.standard.set(false, forKey: AccountManager.markReadOnArchiveDeleteKey)
        clearOverlay()
        try await runReset(env)
        try await expectReseated(env)

        let refused = Mutex<[String]>([])
        let observer = NotificationCenter.default.addObserver(
            forName: .messageMovesRefused, object: nil, queue: nil
        ) { note in
            refused.withLock { $0.append(contentsOf: note.object as? [String] ?? []) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Hold the queue so the gesture's closure runs only after the bump below.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        // Hold the gesture's actor hop open too, so the bump below lands
        // between the gesture and the hop that appends it.
        // Every throwing step comes before the hold is installed, and the
        // hold is always cleared and released on the way out.
        let vm = InboxViewModel(folders: [try #require(try await env.pool.read {
            try Folder.fetchOne($0, key: env.inboxFolderId) })])
        let (hopStream, hopGate) = AsyncStream<Void>.makeStream()
        AccountManager.shared.enqueueHopHoldForTesting.withLock { hold in
            hold = { var iterator = hopStream.makeAsyncIterator(); _ = await iterator.next() }
        }
        defer {
            AccountManager.shared.enqueueHopHoldForTesting.withLock { $0 = nil }
            hopGate.finish()
            gate.finish()
        }
        let folderId = env.inboxFolderId
        if !enqueuedBeforeReset { FolderResetGeneration.recordReset(folderId: folderId) }
        #expect(vm.archive(env.headerId), "fixture: the inbox did not record the gesture")
        if enqueuedBeforeReset { FolderResetGeneration.recordReset(folderId: folderId) }
        AccountManager.shared.enqueueHopHoldForTesting.withLock { $0 = nil }
        hopGate.finish()
        gate.finish()
        await AccountManager.shared.awaitWriteQueueDrain()
        // The refusal report hops to the main actor.
        for _ in 0..<200 where enqueuedBeforeReset && !refused.withLock({ $0.contains(env.headerId) }) {
            await Task.yield()
        }

        let moves = try await ops(env).filter { $0.type == .move }
        if enqueuedBeforeReset {
            #expect(moves.isEmpty, "work stamped before the reset queued a move for the replacement")
            #expect(try await row(env)?.folderPath == "INBOX")
            #expect(refused.withLock { $0.contains(env.headerId) },
                    "the refused move was not reported, so its hidden row never returns")
        } else {
            #expect(!moves.isEmpty, "control: work stamped after the reset was refused")
        }
        await finish(env)
    }

    @Test("""
    Work queued behind an earlier admission is stamped when it is requested, not when the wait \
    ends: a reset during the wait refuses it; requested after the reset, it is admitted
    """, arguments: [true, false])
    func workWaitingBehindAnAdmissionKeepsItsRequestStamp(resetDuringWait: Bool) async throws {
        let env = try makeEnv(accountId: "frg-wait-\(resetDuringWait)")
        UserDefaults.standard.set(false, forKey: AccountManager.markReadOnArchiveDeleteKey)
        clearOverlay()
        try await runReset(env)
        try await expectReseated(env)
        if !resetDuringWait { FolderResetGeneration.recordReset(folderId: env.inboxFolderId) }

        let token = AccountManager.shared.holdWriteAdmissionForTesting()
        let headerId = env.headerId
        let pool = env.pool
        let request = Task {
            await AccountManager.shared.enqueueWriteAfterPriorAdmissions {
                guard let header = try? await pool.read({ try MessageHeader.fetchOne($0, key: headerId) }) else { return }
                await AccountManager.shared.move([header], to: "Archive")
            }
        }
        while AccountManager.shared.writeAdmissionWaitersForTesting() == 0 { await Task.yield() }
        if resetDuringWait { FolderResetGeneration.recordReset(folderId: env.inboxFolderId) }
        AccountManager.shared.releaseWriteAdmissionForTesting(token)
        await request.value
        await AccountManager.shared.awaitWriteQueueDrain()

        let moves = try await ops(env).filter { $0.type == .move }
        if resetDuringWait {
            #expect(moves.isEmpty, "work requested before the reset was re-stamped after its wait and admitted")
        } else {
            #expect(!moves.isEmpty, "control: work requested after the reset was refused")
        }
        await finish(env)
    }

    // MARK: - Intent cycles keep the oldest stamp

    enum CycleOrder: String, CaseIterable, CustomStringConvertible {
        /// A post-reset intent opens the cycle and a pre-reset one joins it.
        case oldJoinsNew
        /// A pre-reset intent opens the cycle and a post-reset one joins it.
        case newJoinsOld
        /// Both intents are post-reset (control).
        case bothNew
        var description: String { rawValue }
    }

    @Test("A cycle holding any pre-reset intent is refused whichever joined first; two post-reset intents apply",
          arguments: CycleOrder.allCases)
    func intentCycleKeepsTheOldestStamp(order: CycleOrder) async throws {
        let env = try makeEnv(accountId: "frg-cycle-\(order)")
        clearOverlay()
        let preResetStamp = FolderResetGeneration.current()
        try await runReset(env)
        try await expectReseated(env)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let fresh = FolderResetGeneration.current()
        FolderResetGeneration.$gestureStamp.withValue(order == .newJoinsOld ? preResetStamp : fresh) {
            AccountManager.shared.registerGestureIntent(id: env.headerId, .isRead(target: true, baseline: false))
        }
        FolderResetGeneration.$gestureStamp.withValue(order == .oldJoinsNew ? preResetStamp : fresh) {
            AccountManager.shared.registerGestureIntent(id: env.headerId, .isFlagged(target: true, baseline: false))
        }
        gate.finish()
        await AccountManager.shared.awaitWriteQueueDrain()

        let after = try #require(try await row(env))
        let flagOps = try await ops(env).filter { $0.type == .markRead || $0.type == .markFlagged }
        if order != .bothNew {
            #expect(flagOps.isEmpty, "a cycle joined by an intent from before the reset queued \(flagOps.map(\.type))")
            #expect(!after.isFlagged, "a cycle joined by an intent from before the reset flagged the replacement")
        } else {
            #expect(after.isRead && after.isFlagged, "control: two post-reset intents were refused")
        }
        await finish(env)
    }

    // MARK: - Mechanism pins

    @Test("The stamp is visible inside a GRDB write transaction (the admission reads it there)")
    func stampIsVisibleInsideTheWriteTransaction() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }
        let seen = try await FolderResetGeneration.$gestureStamp.withValue(424_242) {
            try await pool.write { _ in FolderResetGeneration.gestureStamp }
        }
        #expect(seen == 424_242)
    }

    @Test("A reset refuses only earlier stamps, only for its own folder, never unstamped work; the real reaction bumps once and a re-drive does not bump again")
    func generationScopeAndReDrive() async throws {
        let before = FolderResetGeneration.current()
        FolderResetGeneration.recordReset(folderId: "frg-scope:INBOX")
        let after = FolderResetGeneration.current()
        #expect(after > before)
        FolderResetGeneration.$gestureStamp.withValue(before) {
            #expect(FolderResetGeneration.refuses(folderId: "frg-scope:INBOX"))
            #expect(!FolderResetGeneration.refuses(folderId: "frg-scope:Archive"), "a reset refused another folder")
        }
        FolderResetGeneration.$gestureStamp.withValue(after) {
            #expect(!FolderResetGeneration.refuses(folderId: "frg-scope:INBOX"), "a post-reset gesture was refused")
        }
        #expect(!FolderResetGeneration.refuses(folderId: "frg-scope:INBOX"), "unstamped work was refused")

        let env = try makeEnv(accountId: "frg-redrive")
        let beforeReset = FolderResetGeneration.current()
        try await runReset(env)
        let afterReset = FolderResetGeneration.current()
        #expect(afterReset > beforeReset, "the real reaction did not bump the folder's generation")
        FolderResetGeneration.$gestureStamp.withValue(beforeReset) {
            #expect(FolderResetGeneration.refuses(folderId: env.inboxFolderId))
        }
        // The idempotent re-drive of step 5 (flag already cleared, epoch already
        // fresh) must not bump: gestures taken after the real reset stay admissible.
        let stamped = await AccountManager.shared.uidValidityResetStampFreshEpoch(
            accountId: env.accountId, folderPath: "INBOX", folderId: env.inboxFolderId,
            fresh: UInt32(Self.newEpoch))
        #expect(stamped, "fixture: the re-drive's stamp step did not succeed")
        #expect(FolderResetGeneration.current() == afterReset, "an idempotent re-drive bumped the generation again")
        await finish(env)
    }
}
