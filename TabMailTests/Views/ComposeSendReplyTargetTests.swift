/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Fixture

/// Real temp-file `DatabasePool` registered as `AppDatabase.shared`, mirroring
/// `makeOutboxTestDatabase` in `OutboxDoubleSendTests` — `persistQueuedSend`
/// reaches for `AppDatabase.dbPool` internally, so the pool has to be the shared
/// one. Seeds the account and INBOX the insert paths' foreign keys expect.
@MainActor
private func makeReplyTargetTestDatabase() throws
    -> (dir: URL, pool: DatabasePool, previous: AppDatabase?) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var config = Configuration()
    config.journalMode = .wal
    config.busyMode = .timeout(5)
    config.foreignKeysEnabled = true
    config.maximumReaderCount = 64
    let pool = try DatabasePool(
        path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
    let appDb = try AppDatabase(dbPool: pool)   // runs schema migrations
    let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
        let prev = current
        current = appDb
        return prev
    }
    try pool.writeWithoutTransaction { db in
        var acc = Account(
            emailAddress: "user@example.com", displayName: "Test", provider: .imap)
        acc.id = "acc1"
        try acc.insert(db)
        try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
    }
    return (dir, pool, previous)
}

private func insertFolder(
    _ pool: DatabasePool, name: String, path: String, role: FolderRole
) async throws {
    try await pool.write { db in
        try Folder(name: name, path: path, role: role, accountId: "acc1").insert(db)
    }
}

@discardableResult
private func insertHeader(
    _ pool: DatabasePool,
    folderPath: String = "INBOX",
    uid: String,
    rfc822MessageId: String?,
    references: [String] = [],
    observedUidValidity: Int? = nil,
    subject: String = "Original subject",
    actionTag: ActionTag? = nil
) async throws -> MessageHeader {
    var header = MessageHeader(
        messageId: uid,
        subject: subject,
        from: "sender@example.com",
        fromAddress: "sender@example.com",
        to: "user@example.com",
        date: Date(),
        snippet: "snippet",
        folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: folderPath),
        accountId: "acc1",
        folderPath: folderPath,
        isInInbox: folderPath == "INBOX"
    )
    header.rfc822MessageId = rfc822MessageId
    header.referencesJSON = MessageHeader.encodeReferences(references)
    header.observedUidValidity = observedUidValidity
    if let actionTag { header.setActionTag(actionTag) }
    // Immutable copy for the escaping write closure (a captured `var` is a
    // concurrency hazard, not merely a style point).
    let toInsert = header
    try await pool.write { db in try toInsert.insert(db) }
    return toInsert
}

private let authoredBody = "the words the user actually typed and must never lose"

@discardableResult
private func insertDraft(
    _ pool: DatabasePool,
    id: String,
    replyToId: String?,
    stampProviderMessageId: String? = nil,
    stampUidValidity: Int? = nil,
    isForward: Bool = false,
    epoch: String
) async throws -> Draft {
    var draft = Draft(
        id: id, accountId: "acc1",
        toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
        subject: "Re: Original subject", body: authoredBody,
        replyToId: replyToId, isForward: isForward, editHistoryJSON: nil,
        createdAt: Date().timeIntervalSince1970,
        updatedAt: Date().timeIntervalSince1970)
    draft.replyToProviderMessageId = stampProviderMessageId
    draft.replyToUidValidity = stampUidValidity
    draft.instanceEpoch = epoch
    let toInsert = draft
    try await pool.write { db in try toInsert.insert(db) }
    return toInsert
}

// MARK: - Production sequence, reproduced through the production seams

/// Reproduces `ComposeView.loadDraftOrPrepopulate`'s reply-target step: read the
/// persisted row (absent ⇒ `nil`, the only state in which the `replyTo` parameter
/// is the send's authority), run the GUARDED resolver over the row's OWN stored
/// claim, and map the outcome through the production predicate.
private func loadClaim(
    _ pool: DatabasePool, draftId: String
) async throws -> ComposeDraftGuards.PersistedReplyTargetClaim? {
    guard let row = try await pool.read({ db in try Draft.fetchOne(db, key: draftId) })
    else { return nil }
    let claimsTarget = row.isReplyOrForward
    let replyToId = row.replyToId
    let isForward = row.isForward
    let stampProviderMessageId = row.replyToProviderMessageId
    let stampUidValidity = row.replyToUidValidity
    let quote: Draft.ReplyQuote? = try await pool.read { db in
        try Draft.resolveReplyQuote(
            draftKey: draftId, replyToId: replyToId, isForward: isForward,
            expectedProviderMessageId: stampProviderMessageId,
            expectedUidValidity: stampUidValidity, db: db)
    }
    return ComposeDraftGuards.persistedReplyTargetClaim(
        rowClaimsTarget: claimsTarget, resolved: quote?.header)
}

/// Reproduces `ComposeView.send()`'s reply-target decision and the two consumers
/// it feeds — `ThreadUtils.outgoingThreadHeaders` and
/// `AccountManager.persistQueuedSend`'s `replyToHeaderId`. A BLOCKED send
/// returns before the outbox is touched at all, exactly as `send()` does.
private func driveSend(
    pool: DatabasePool,
    draftId: String,
    composeParameter: MessageHeader?,
    claim: ComposeDraftGuards.PersistedReplyTargetClaim?,
    subject: String = "Re: Original subject",
    isForward: Bool = false,
    instanceEpoch: String
) async throws -> (blocked: Bool, outboxId: String?) {
    let target: MessageHeader?
    switch ComposeDraftGuards.sendReplyTarget(
        composeParameter: composeParameter, persistedRowClaim: claim) {
    case .blocked:
        return (true, nil)
    case .send(let header):
        target = header
    }
    let threadHeaders = ThreadUtils.outgoingThreadHeaders(
        replyTo: target, sendAccountId: "acc1", sendSubject: subject, providerKind: .imap)
    let outbound = DraftMessage(
        to: ["recipient@example.com"], subject: subject, body: authoredBody,
        inReplyTo: threadHeaders.inReplyTo, references: threadHeaders.references,
        threadId: threadHeaders.threadId)
    let result = try await AccountManager.persistQueuedSend(
        draft: outbound, accountId: "acc1", replyToHeaderId: target?.id,
        isForward: isForward, serverDraftId: nil,
        draftId: draftId, instanceEpoch: instanceEpoch)
    return (false, result.outboxId)
}

// MARK: - The send's reply/forward parent

/// The SEND's reply/forward parent is the persisted `Draft` row's own GUARDED
/// resolution; the `replyTo` parameter is authority only when there is no row.
///
/// Every assertion here is an END STATE — what is in the outbox, what headers the
/// queued message carries, whether the parent was marked replied, whether the
/// draft survived. None of them asserts that a particular flag is set.
@Suite("Compose send reply-target", .serialized, .processGlobalState)
@MainActor
struct ComposeSendReplyTargetTests {

    /// THE CORE INVARIANT. A reply whose CLAIMED parent cannot be resolved to
    /// exactly one message never leaves as an unthreaded message, and the draft
    /// survives so the user keeps their text.
    ///
    /// Before this change `ComposeView.loadDraftOrPrepopulate` computed exactly
    /// this refusal and only LOGGED it: `send()` then threaded from its own
    /// `replyTo` parameter, so the reply went out with no `In-Reply-To` and no
    /// `References`, `persistQueuedSend`'s `guard let originalId` short-circuited
    /// (no `isReplied`, no Reply action-tag clear), compose dismissed, and the
    /// draft became deletable on delivery.
    ///
    /// RED PROOF (recorded): with `ComposeDraftGuards.sendReplyTarget` inverted to
    /// always return `.send(composeParameter)`, this fails at `outcome.blocked`
    /// and at `outbox == 0` — the message is queued, unthreaded.
    @Test("A reply whose claimed parent resolves to nothing is never sent unthreaded, and its draft survives")
    func unresolvableClaimedParentNeverLeavesUnthreadedAndKeepsItsDraft() async throws {
        let (dir, pool, previous) = try makeReplyTargetTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try await insertFolder(pool, name: "Archive", path: "Archive", role: .archive)
        // ONE message, two folder copies: the Strategy-2 cardinality refusal.
        try await insertHeader(
            pool, folderPath: "INBOX", uid: "42",
            rfc822MessageId: "shared@example.com", observedUidValidity: 100)
        try await insertHeader(
            pool, folderPath: "Archive", uid: "77",
            rfc822MessageId: "shared@example.com", observedUidValidity: 900)

        // Strategy 1 cannot answer: the PK the row names no longer exists, which is
        // precisely when Strategy 2 runs.
        let draftId = "reply:acc1:shared@example.com"
        try await insertDraft(
            pool, id: draftId, replyToId: "acc1:INBOX:999", epoch: "E1")

        // NON-VACUITY: both copies really are present, so the refusal below is the
        // cardinality guard firing and not an empty-database trivial miss.
        let candidates = try await pool.read { db in
            try MessageHeader
                .filter(Column("accountId") == "acc1"
                        && Column("rfc822MessageId") == "shared@example.com")
                .fetchCount(db)
        }
        #expect(candidates == 2)

        let claim = try await loadClaim(pool, draftId: draftId)
        let outcome = try await driveSend(
            pool: pool, draftId: draftId,
            composeParameter: nil, claim: claim, instanceEpoch: "E1")

        #expect(outcome.blocked, "an unresolvable claimed parent must block the send")
        let state = try await pool.read { db -> (outbox: Int, draft: Draft?, replied: Int) in
            (try OutboxMessage.fetchCount(db),
             try Draft.fetchOne(db, key: draftId),
             try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messageHeader WHERE isReplied = 1") ?? -1)
        }
        #expect(state.outbox == 0, "nothing may be queued when the parent is unproven")
        #expect(state.replied == 0, "no message may be marked replied when none is proven")
        #expect(state.draft != nil, "the draft must survive a refused send")
        #expect(state.draft?.body == authoredBody, "the authored text must be untouched")
        #expect(state.draft?.replyToId == "acc1:INBOX:999",
                "the row's own claim must be untouched by the refusal")
    }

    /// NON-REGRESSION (b): the ordinary reopen of a resolvable reply still sends,
    /// and sends THREADED. A guard that refused everything would pass the test
    /// above and fail this one.
    @Test("A resolvable reply still sends with In-Reply-To and References intact")
    func resolvableReplyStillSendsThreaded() async throws {
        let (dir, pool, previous) = try makeReplyTargetTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let parent = try await insertHeader(
            pool, uid: "42", rfc822MessageId: "orig@example.com",
            references: ["root@example.com"], observedUidValidity: 100)
        let draftId = "reply:acc1:orig@example.com"
        try await insertDraft(
            pool, id: draftId, replyToId: parent.id,
            stampProviderMessageId: "42", stampUidValidity: 100, epoch: "E1")

        let claim = try await loadClaim(pool, draftId: draftId)
        // The ordinary reopen shape: `DraftComposePresenter` resolves the parent and
        // hands it to `ComposeView(replyTo:)`, so BOTH sources agree here.
        let outcome = try await driveSend(
            pool: pool, draftId: draftId,
            composeParameter: parent, claim: claim, instanceEpoch: "E1")

        #expect(!outcome.blocked, "a reply whose parent resolves must still send")
        let state = try await pool.read { db -> (outbox: [OutboxMessage], parent: MessageHeader?) in
            (try OutboxMessage.fetchAll(db), try MessageHeader.fetchOne(db, key: parent.id))
        }
        #expect(state.outbox.count == 1)
        guard state.outbox.count == 1 else { return }
        #expect(state.outbox[0].inReplyTo == "orig@example.com")
        #expect(state.outbox[0].references == ["root@example.com", "orig@example.com"])
        #expect(state.parent?.isReplied == true,
                "the parent must be marked replied by the queued send")
    }

    /// NON-REGRESSION (a): a fresh compose with no persisted row and no parent
    /// still sends — an unthreaded new message is a legitimate end state, not an
    /// unknown one, and must never be blocked.
    @Test("A fresh compose with no reply parent still sends")
    func freshComposeStillSends() async throws {
        let (dir, pool, previous) = try makeReplyTargetTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let draftId = UUID().uuidString
        // Load time: no row exists yet, so the compose parameter is the authority —
        // and on a fresh compose there is no parameter either.
        let claim = try await loadClaim(pool, draftId: draftId)
        #expect(claim == nil, "no persisted row means no row claim")
        // `send()` writes the row (save-before-send) before it reaches `queueSend`.
        try await insertDraft(pool, id: draftId, replyToId: nil, epoch: "E1")

        let outcome = try await driveSend(
            pool: pool, draftId: draftId, composeParameter: nil, claim: claim,
            subject: "Brand new message", instanceEpoch: "E1")

        #expect(!outcome.blocked, "a new message with no parent must never be blocked")
        let outbox = try await pool.read { db in try OutboxMessage.fetchAll(db) }
        #expect(outbox.count == 1)
        guard outbox.count == 1 else { return }
        #expect(outbox[0].inReplyTo == nil)
        #expect(outbox[0].references.isEmpty)
    }

    /// NON-REGRESSION (c) AND the F2 positive, in one end state.
    ///
    /// `UndoReopenCompose.composeView(for:)` builds
    /// `ComposeView(account:prefillDraftId:retainedDraftAuthority:)` and passes NO
    /// `replyTo`, while the retained row still carries `replyToId`. So this path
    /// must (c) still be sendable — a discriminator keyed on "the row claims a
    /// parent but the parameter is nil" would dead-end every undo-then-resend of a
    /// reply — and it must now send THREADED, which it never did before.
    ///
    /// RED PROOF (recorded): with `ComposeDraftGuards.sendReplyTarget` inverted to
    /// always return `.send(composeParameter)`, this fails at `inReplyTo` and at
    /// `parent.isReplied` — the resend leaves as a brand-new message.
    @Test("The Undo-Send reopen of a reply sends, and now sends threaded")
    func undoSendReopenSendsAndThreads() async throws {
        let (dir, pool, previous) = try makeReplyTargetTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let parent = try await insertHeader(
            pool, uid: "42", rfc822MessageId: "orig@example.com",
            references: ["root@example.com"], observedUidValidity: 100)
        let draftId = "reply:acc1:orig@example.com"
        try await insertDraft(
            pool, id: draftId, replyToId: parent.id,
            stampProviderMessageId: "42", stampUidValidity: 100, epoch: "E1")

        // NON-VACUITY / the superseded end state: the compose parameter is what the
        // pre-fix send threaded from, and on this path there is none.
        let supersededHeaders = ThreadUtils.outgoingThreadHeaders(
            replyTo: nil, sendAccountId: "acc1",
            sendSubject: "Re: Original subject", providerKind: .imap)
        #expect(supersededHeaders.inReplyTo == nil)
        #expect(supersededHeaders.references.isEmpty)

        let claim = try await loadClaim(pool, draftId: draftId)
        let outcome = try await driveSend(
            pool: pool, draftId: draftId,
            composeParameter: nil, claim: claim, instanceEpoch: "E1")

        #expect(!outcome.blocked, "undo-then-resend of a reply must never dead-end")
        let state = try await pool.read { db -> (outbox: [OutboxMessage], parent: MessageHeader?) in
            (try OutboxMessage.fetchAll(db), try MessageHeader.fetchOne(db, key: parent.id))
        }
        #expect(state.outbox.count == 1)
        guard state.outbox.count == 1 else { return }
        #expect(state.outbox[0].inReplyTo == "orig@example.com",
                "the resend must thread against the row's resolved parent")
        #expect(state.outbox[0].references == ["root@example.com", "orig@example.com"])
        #expect(state.parent?.isReplied == true,
                "the parent bookkeeping this path used to skip must now happen")
    }

    /// THE `IOS-OUTBOX-004` INVARIANT: a forward that is undone and re-sent is
    /// recorded as a FORWARD — locally and, through `OutboxMessage.isForward`, on
    /// the wire. Never as a reply.
    ///
    /// Driven through the PRODUCTION reopen function itself
    /// (`UndoReopenCompose.composeView(for:)`), not through a reproduction of it, so
    /// the test cannot pass merely by agreeing with a copy of the code under test.
    /// Every assertion is an END STATE — what the queued send says it is, and what
    /// the parent message ends up recorded as. None asserts that a particular
    /// argument is passed.
    ///
    /// Why the end state and not the flag: `OutboxMessage.isForward` is what
    /// `AccountManager.deleteCompletedSendAtomic` reads on delivery to queue
    /// `.markForwarded` rather than `.markReplied`, and `IMAPProvider.markReplied`
    /// STOREs `\Answered` — a server-side flag the user has no in-app way to clear,
    /// which sync then re-asserts over the locally-correct forwarded badge.
    ///
    /// RED PROOF (recorded): with the `isForward:` argument removed from
    /// `UndoReopenCompose.composeView(for:)` — the pre-fix source — this fails at
    /// `outbox[0].isForward`, at `parent.isForwarded`, at `parent.isReplied` and at
    /// the surviving Reply action tag.
    @Test("A forward reopened through Undo-Send is re-sent as a forward, not a reply")
    func forwardReopenedThroughUndoIsResentAsAForward() async throws {
        let (dir, pool, previous) = try makeReplyTargetTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let parent = try await insertHeader(
            pool, uid: "42", rfc822MessageId: "orig@example.com",
            references: ["root@example.com"], observedUidValidity: 100,
            actionTag: .reply)
        // A FORWARD draft: `forward:`-keyed and `isForward` on the row, which is what
        // `PendingSendService.undo()` retains when the user taps Undo on the toast.
        let draftId = "forward:acc1:orig@example.com"
        try await insertDraft(
            pool, id: draftId, replyToId: parent.id,
            stampProviderMessageId: "42", stampUidValidity: 100,
            isForward: true, epoch: "E1")

        // NON-VACUITY: the parent starts flagged neither way and still carries a Reply
        // action tag the user never acted on, so every assertion below is a state THIS
        // send produced — not a seeded value the test read back.
        let before = try await pool.read { db in try MessageHeader.fetchOne(db, key: parent.id) }
        #expect(before?.isForwarded == false)
        #expect(before?.isReplied == false)
        #expect(before?.actionTag == .reply)

        // THE PRODUCTION REOPEN. `PendingSendService.undo()` RETAINS the Draft row and
        // returns this snapshot; `RootView` presents `UndoReopenCompose` with it.
        let snapshot = PendingSendService.ReopenSnapshot(
            id: "outbox-undo-1",
            authority: PendingSendService.RetainedDraftAuthority(
                draftId: draftId, accountId: "acc1", instanceEpoch: "E1"))
        let reopened = UndoReopenCompose.composeView(for: snapshot)

        // The user taps Send again. `ComposeView.send` captures the VIEW's mode into
        // `AuthoredSendSnapshot.isForward`, and that snapshot is what both durable
        // consumers read — so the reopened view's own mode is the input here.
        let claim = try await loadClaim(pool, draftId: draftId)
        let outcome = try await driveSend(
            pool: pool, draftId: draftId, composeParameter: nil, claim: claim,
            subject: "Fwd: Original subject",
            isForward: reopened.isForward, instanceEpoch: "E1")

        #expect(!outcome.blocked, "undo-then-resend of a forward must never dead-end")
        let state = try await pool.read { db -> (outbox: [OutboxMessage], parent: MessageHeader?) in
            (try OutboxMessage.fetchAll(db), try MessageHeader.fetchOne(db, key: parent.id))
        }
        #expect(state.outbox.count == 1)
        guard state.outbox.count == 1 else { return }
        #expect(state.outbox[0].isForward,
                "the queued send must be recorded as a forward — delivery reads this to choose \\$Forwarded over \\Answered")
        #expect(state.parent?.isForwarded == true,
                "the parent must end up recorded as forwarded")
        #expect(state.parent?.isReplied == false,
                "a forward must never record its parent as replied-to")
        #expect(state.parent?.actionTag == .reply,
                "a forward must not clear a Reply action tag the user never acted on")
    }
}

// MARK: - A thrown resolver read is not an absent reply target

/// The DELETED non-`db` overload's body, verbatim — the control half of the proof
/// below, kept because without it "the `db`-scoped resolver throws" says nothing
/// about whether the throw was ever distinguishable from a refusal. Deliberately a
/// NON-async function: `PrioritizedDatabase` has both a sync and an async `read`,
/// and only a non-async context selects the sync one the deleted overload used.
private func swallowingResolveReplyToHeader(
    draftKey: String,
    replyToId: String?,
    isForward: Bool,
    expectedProviderMessageId: String?,
    expectedUidValidity: Int?
) -> MessageHeader? {
    try? AppDatabase.dbPool.read { db in
        try Draft.resolveReplyToHeader(
            draftKey: draftKey, replyToId: replyToId, isForward: isForward,
            expectedProviderMessageId: expectedProviderMessageId,
            expectedUidValidity: expectedUidValidity, db: db)
    }
}

/// `ComposeView.loadDraftOrPrepopulate`'s reply-target read as it stood BEFORE the
/// `IOS-DRAFT-010` fix, verbatim. The control half of
/// `thrownReplyTargetReadIsRetryableNotAnIdentityRefusal`: without it, "the guarded
/// shape reports `.error`" says nothing about what the swallowing shape reported
/// instead, and the conflation is invisible. Same job `swallowingResolveReplyToHeader`
/// does above for the presenter's deleted overload.
private func swallowingResolveReplyQuote(
    draftKey: String,
    replyToId: String?,
    isForward: Bool,
    expectedProviderMessageId: String?,
    expectedUidValidity: Int?
) async -> Draft.ReplyQuote? {
    try? await AppDatabase.dbPool.read { db in
        try Draft.resolveReplyQuote(
            draftKey: draftKey, replyToId: replyToId, isForward: isForward,
            expectedProviderMessageId: expectedProviderMessageId,
            expectedUidValidity: expectedUidValidity, db: db)
    }
}

/// The same read as the production call site classifies it now: the outcome is
/// CARRIED as a `Result` so a throw stays a throw all the way to
/// `ComposeDraftGuards.readState`, instead of being flattened into the nil a genuine
/// refusal returns.
private func guardedResolveReplyQuote(
    draftKey: String,
    replyToId: String?,
    isForward: Bool,
    expectedProviderMessageId: String?,
    expectedUidValidity: Int?
) async -> Result<Draft.ReplyQuote?, Error> {
    do {
        return .success(try await AppDatabase.dbPool.read { db in
            try Draft.resolveReplyQuote(
                draftKey: draftKey, replyToId: replyToId, isForward: isForward,
                expectedProviderMessageId: expectedProviderMessageId,
                expectedUidValidity: expectedUidValidity, db: db)
        })
    } catch {
        return .failure(error)
    }
}

/// `DraftComposePresenter` used to resolve the reply target through
/// `Draft.resolveReplyToHeader`'s non-`db` overload, whose whole body was
/// `try? AppDatabase.dbPool.read { … }`. A busy or suspended database returned nil
/// and the presenter still returned `.loaded(draft:replyTo: nil, account:)` — "we
/// could not look" presented as the authoritative "there is no reply parent",
/// which is the never-drop clause-2 error, in the very function whose
/// `.loadFailed` arm documents that a thrown read is not absence.
///
/// That overload has since been DELETED — the presenter was its last caller, so it
/// was dead code carrying a live hazard — and its body now lives here as
/// `swallowingResolveReplyToHeader`, above, so the two-sided proof survives it.
@Suite("Reply-target resolver: a thrown read is not an absence", .serialized, .processGlobalState)
@MainActor
struct ReplyTargetThrownReadTests {

    /// The conflation itself, shown from BOTH sides on ONE unreadable database and
    /// ONE set of inputs: the swallowing `try?` the presenter used to inherit from
    /// the deleted convenience overload answers "there is no reply target", while
    /// the `db`-scoped resolver it uses now answers "I could not look".
    /// Non-vacuous by construction — if the two agreed, there would have been
    /// nothing to fix.
    @Test("An unreadable database answers 'nothing there' through a swallowing try? and THROWS through the resolver the presenter uses")
    func unreadableDatabaseIsAThrowNotAnAbsence() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Make every read the resolver performs fail, the way a suspended or
        // otherwise unreadable database does.
        try await pool.write { db in try db.execute(sql: "DROP TABLE messageHeader") }

        let draftKey = "reply:acc1:orig@example.com"
        let replyToId = "acc1:INBOX:42"

        // The deleted convenience overload's whole body, reproduced verbatim:
        // indistinguishable from a genuine refusal. `try?` flattens the resolver's
        // own `MessageHeader?` result, so a thrown read and a refusal arrive as the
        // SAME nil.
        let swallowed = swallowingResolveReplyToHeader(
            draftKey: draftKey, replyToId: replyToId, isForward: false,
            expectedProviderMessageId: nil, expectedUidValidity: nil)
        #expect(swallowed == nil, "a swallowing try? reports absence for a failed read")

        // The overload the presenter now uses: the failure survives as a failure.
        await #expect(throws: (any Error).self) {
            _ = try await pool.read { db in
                try Draft.resolveReplyToHeader(
                    draftKey: draftKey, replyToId: replyToId, isForward: false,
                    expectedProviderMessageId: nil, expectedUidValidity: nil, db: db)
            }
        }
    }

    /// And the presenter routes on that distinction: a thrown read reaches the
    /// `.loadFailed` retry arm, while a genuine refusal still opens compose with no
    /// reply parent. Two-sided on purpose — a predicate that called everything an
    /// error would over-block every unquoted reply.
    @Test("The presenter's read-state predicate keeps 'could not look' distinct from 'nothing there'")
    func thrownReplyTargetReadRoutesToRetryAndARefusalDoesNot() {
        struct ResolverFailure: Error {}
        let thrown = Result<MessageHeader?, Error>.failure(ResolverFailure())
        let refused = Result<MessageHeader?, Error>.success(nil)
        let resolved = Result<MessageHeader?, Error>.success(
            MessageHeader(
                messageId: "42", subject: "Original subject",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "user@example.com", date: Date(), snippet: "snippet",
                folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"),
                accountId: "acc1", folderPath: "INBOX", isInInbox: true))

        #expect(ComposeDraftGuards.readState(thrown) == .error,
                "a thrown resolver read must reach the retry arm")
        #expect(ComposeDraftGuards.readState(refused) == .notFound,
                "a genuine refusal must still open compose, unquoted")
        #expect(ComposeDraftGuards.readState(resolved) == .loaded)
    }

    /// THE `IOS-DRAFT-010` INVARIANT, at the COMPOSE call site this time (the two
    /// tests above cover the presenter's overload): a reply-target read that THROWS
    /// leaves the draft in the RETRYABLE state, never in the terminal one that tells
    /// the user "the message this draft replies to can no longer be identified" —
    /// an assertion about identity a suspended or busy database never made. That
    /// read now GATES the send, so the clause-2 conflation costs the user their
    /// ability to send a draft whose parent is perfectly resolvable.
    ///
    /// Two-sided on ONE database and ONE set of inputs: readable first (the parent
    /// really does resolve — so the refusal below is the failure firing and not an
    /// empty-fixture trivial miss), then unreadable.
    ///
    /// RED PROOF (recorded): the control is the pre-fix production statement
    /// verbatim, and on the unreadable database it yields `.unresolved` — the
    /// authoritative "no such parent" — where the guarded shape yields `.error`.
    @Test("A thrown reply-target read leaves the draft retryable, not declared unidentifiable")
    func thrownReplyTargetReadIsRetryableNotAnIdentityRefusal() async throws {
        let (dir, pool, previous) = try makeReplyTargetTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let parent = try await insertHeader(
            pool, uid: "42", rfc822MessageId: "orig@example.com",
            references: ["root@example.com"], observedUidValidity: 100)
        let draftId = "reply:acc1:orig@example.com"
        try await insertDraft(
            pool, id: draftId, replyToId: parent.id,
            stampProviderMessageId: "42", stampUidValidity: 100, epoch: "E1")

        // NON-VACUITY / the positive side: while the database is readable this exact
        // draft's parent resolves, so the draft is genuinely sendable.
        let readable = await guardedResolveReplyQuote(
            draftKey: draftId, replyToId: parent.id, isForward: false,
            expectedProviderMessageId: "42", expectedUidValidity: 100)
        #expect(ComposeDraftGuards.readState(readable) == .loaded)
        guard case .success(let resolvedQuote) = readable else {
            Issue.record("the readable half must resolve")
            return
        }
        #expect(resolvedQuote?.header.id == parent.id,
                "the readable half must resolve to the real parent")

        // Make every read the resolver performs fail, the way a suspended or
        // otherwise unreadable database does. The `draft` table is untouched — the
        // row, and the user's authored text, are still there to be recovered.
        try await pool.write { db in try db.execute(sql: "DROP TABLE messageHeader") }

        // CONTROL — the pre-fix statement: `try?` flattens the throw into the same
        // nil a genuine refusal returns, so the row's claim becomes `.unresolved`,
        // Send is disabled, and the user is told the parent can no longer be
        // identified. "We could not look" manufactured into an authoritative verdict.
        let swallowed = await swallowingResolveReplyQuote(
            draftKey: draftId, replyToId: parent.id, isForward: false,
            expectedProviderMessageId: "42", expectedUidValidity: 100)
        let swallowedClaim = ComposeDraftGuards.persistedReplyTargetClaim(
            rowClaimsTarget: true, resolved: swallowed?.header)
        #expect(swallowedClaim == .unresolved,
                "a swallowing try? turns a failed read into an identity refusal")
        #expect(ComposeDraftGuards.sendReplyTarget(
            composeParameter: nil, persistedRowClaim: swallowedClaim) == .blocked,
                "and that refusal is what blocks the send")

        // THE FIX — same read, same inputs, carried as a Result and classified by the
        // SAME guard the draft-row read uses: the failure survives as a failure.
        let guarded = await guardedResolveReplyQuote(
            draftKey: draftId, replyToId: parent.id, isForward: false,
            expectedProviderMessageId: "42", expectedUidValidity: 100)
        let state = ComposeDraftGuards.readState(guarded)
        #expect(state == .error,
                "'we could not look' must never be reported as 'there is no such parent'")

        // END STATE — the retryable one: every mutation fails closed, close dismisses
        // without touching the row, and nothing asserts anything about identity.
        #expect(!ComposeDraftGuards.saveMayMutate(readState: state),
                "no save may overwrite a row read from a database we could not read")
        #expect(!ComposeDraftGuards.discardMayDelete(readState: state),
                "no discard may delete it either")
        // ⚠ This read `== .dismiss` until 2026-08-05 and BLESSED a silent drop of
        // authored edits. The property it means — and the one the sentence beside
        // it always described — is "no Save is offered over a row we could not
        // read", not "the compose vanishes without asking".
        let closeDecision = ComposeDraftGuards.closeAction(
            readState: state, hasContent: true, hasChanges: true)
        #expect(closeDecision != .promptSave,
                "close must not prompt to save over an unknown row")
        #expect(!ComposeDraftGuards.closeActionWrites(closeDecision),
                "and must authorize no write of any kind")
        #expect(closeDecision == .promptDiscardEdits,
                "but it must still ASK before dropping the edits the user authored")

        // THE INTENTION SURVIVES: the draft row is untouched, so one reopen re-runs
        // the read and the send proceeds.
        let surviving = try await pool.read { db in try Draft.fetchOne(db, key: draftId) }
        #expect(surviving?.body == authoredBody, "the authored text must be untouched")
        #expect(surviving?.replyToId == parent.id,
                "the row's own claim must be untouched by a failed read")
    }
}
