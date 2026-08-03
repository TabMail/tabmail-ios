/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

// MARK: - Fixture

/// The MOVED-IN IMPOSTOR, and why it exists at all.
///
/// `AccountManager.optimisticMoveToFolder` rewrites `folderId`, `folderPath`
/// and `isInInbox` to the DESTINATION folder but deliberately keeps the row's
/// original primary key — `SyncEngine.canonicalizeLocalRows`'s doc comment
/// states this outright ("updates folderId/folderPath but keeps the original PK
/// `accountId:<oldPath>:<messageId>`") and notes the stale PK can survive
/// indefinitely on stable-id providers.
///
/// So a message optimistically moved INTO the inbox claims inbox membership
/// while still carrying its SOURCE folder's message id (an IMAP UID is
/// folder-scoped and small, so collisions are ordinary — **no UIDVALIDITY reset
/// is required to reach this state**). Address is not identity: at a coinciding
/// id such a row becomes an address match for a notification that was never
/// about it, and — when the notification's real target has not landed in GRDB
/// yet — the UNIQUE one.
///
/// The invariant these suites pin is C3: **no action may mutate or misattribute
/// a message the user never tapped**. They assert the SYSTEM END STATE (which
/// row moved, which row's `isRead` flipped, whether the intention survived), not
/// the shape of any resolver's return value — a fix that renames a result but
/// still dispatches against the impostor does not turn them green.
private enum MovedInImpostorFixture {

    struct Env {
        let pool: DatabasePool
        let inbox: Folder
        let archive: Folder
        let trash: Folder
        let dir: URL
        let previous: AppDatabase?
    }

    /// Mirrors `NotificationActionRouterTests.makeTestDB` — one account, the
    /// three role folders the notification-action paths resolve against.
    static func make() throws -> Env {
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
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
            let t = trash; try t.insert(db)
        }
        return Env(pool: pool, inbox: inbox, archive: archive, trash: trash, dir: dir, previous: previous)
    }

    /// Same teardown contract as `NotificationActionRouterTests.restoreTestDB`:
    /// production paths driven here fire unstructured background Tasks, so the
    /// fixture is retained until process exit rather than unlinked immediately.
    static func finish(_ env: Env) {
        InstalledTestDatabaseLifetime.finish(
            previous: env.previous,
            pool: env.pool,
            directory: env.dir
        )
    }

    /// A genuine, folder-native inbox row: `id == MessageIdentity.headerId(
    /// accountId, inboxPath, messageId)` — exactly what the NSE and sync mint.
    static func nativeInboxHeader(inbox: Folder, messageId: String) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Genuine \(messageId)", from: "Sender",
            fromAddress: "sender@example.com", to: "me@example.com", date: Date(),
            snippet: "genuine", folderId: inbox.id, accountId: inbox.accountId,
            folderPath: inbox.path, isInInbox: true
        )
        h.headerComplete = true
        return h
    }

    /// The impostor: minted native to `source`, then given exactly the column
    /// rewrite `AccountManager.optimisticMoveToFolder` performs when the
    /// destination is the inbox (folderId / folderPath / isInInbox /
    /// observedUidValidity), with the primary key deliberately left pointing at
    /// `source`.
    static func movedInImpostor(source: Folder, inbox: Folder, messageId: String) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Impostor \(messageId)", from: "Other",
            fromAddress: "other@example.com", to: "me@example.com", date: Date(),
            snippet: "impostor", folderId: source.id, accountId: source.accountId,
            folderPath: source.path, isInInbox: false
        )
        // The PK is now "acc1:<source.path>:<messageId>" and STAYS that way —
        // that is the whole point. Only the location columns move.
        h.folderId = inbox.id
        h.folderPath = inbox.path
        h.isInInbox = true
        h.observedUidValidity = nil
        h.headerComplete = true
        return h
    }

    /// Cold/absent paths must not resolve through a leftover staged row from
    /// another suite (mirrors `NotificationActionRouterTests.resetStagedGlobal`).
    static func resetStagedGlobal() {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
    }
}

// MARK: - Site 1: the notification ACTION dispatch (AppDelegate)

/// `NotificationActionRouter.resolveDurableInboxHeader` seeds ARCHIVE / DELETE /
/// MARK_READ — a durable mutation. Before the folder-native guard its lookup was
/// `WHERE messageId = ? AND accountId = ? AND folderId != '' AND isInInbox = 1
/// LIMIT 1`, with no folder predicate at all, so a moved-in impostor could be
/// the row it dispatched against.
///
/// `.serialized`: these drive `AccountManager.shared`'s write paths and swap
/// `AppDatabase.shared` — same reason as `NotificationActionRouterTests`.
@Suite("Notification action dispatch — folder-native identity guard", .serialized, .processGlobalState)
struct NotificationActionFolderNativeIdentityTests {

    @Test("ARCHIVE from a notification acts on the folder-native inbox row, never on a same-id row that was optimistically moved into the inbox (which keeps its source folder's primary key)")
    func archiveActsOnNativeRowAndLeavesTheMovedInImpostorAlone() async throws {
        let env = try MovedInImpostorFixture.make()
        defer { MovedInImpostorFixture.finish(env); MovedInImpostorFixture.resetStagedGlobal() }
        MovedInImpostorFixture.resetStagedGlobal()

        // The impostor is inserted FIRST (lower rowid): an unguarded `LIMIT 1`
        // with no ORDER BY surfaces rows in insertion order, so this ordering is
        // the one most likely to expose the missing folder predicate.
        let impostor = MovedInImpostorFixture.movedInImpostor(
            source: env.archive, inbox: env.inbox, messageId: "collide-7"
        )
        let genuine = MovedInImpostorFixture.nativeInboxHeader(inbox: env.inbox, messageId: "collide-7")
        #expect(impostor.id != genuine.id, "the two rows must be distinct targets — headerId embeds folderPath")
        #expect(impostor.isInInbox, "the impostor claims inbox membership; only its PK betrays it")
        try await env.pool.writeWithoutTransaction { db in
            try impostor.insert(db)
            try genuine.insert(db)
        }

        await NotificationActionRouter.execute(actionId: "ARCHIVE", messageId: "collide-7", accountId: "acc1")

        // (ii) the genuine target still gets archived — the guard did not simply
        // reject everything.
        let finalGenuine = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: genuine.id) }
        #expect(finalGenuine?.folderPath == env.archive.path, "the folder-native inbox row must be the one archived")
        #expect(finalGenuine?.folderId == env.archive.id)

        // (i)/(iii) the impostor was never mutated: still where it was, still
        // inbox-visible, still unread.
        let finalImpostor = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: impostor.id) }
        #expect(finalImpostor?.folderPath == env.inbox.path, "the moved-in impostor must not be archived")
        #expect(finalImpostor?.folderId == env.inbox.id)
        #expect(finalImpostor?.isInInbox == true)
        #expect(finalImpostor?.isRead == false)

        let ops = try await env.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "exactly one remote move — only the genuine row was ever acted on")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == env.inbox.path)
        #expect(ops[0].destinationPath == env.archive.path)
        #expect(ops[0].messageIds == ["collide-7"])
    }

    @Test("when a moved-in impostor is the ONLY row matching the notification's id, ARCHIVE mutates nothing and the tap survives as a cold inbox-addressed .move operation")
    func archiveWithOnlyTheImpostorPresentMutatesNothingAndStillRetainsTheIntention() async throws {
        let env = try MovedInImpostorFixture.make()
        defer { MovedInImpostorFixture.finish(env); MovedInImpostorFixture.resetStagedGlobal() }
        MovedInImpostorFixture.resetStagedGlobal()

        // The push's real target has not been written to GRDB yet, so the
        // impostor is the UNIQUE address match — the shape where the pre-guard
        // lookup could not even be saved by a second candidate.
        let impostor = MovedInImpostorFixture.movedInImpostor(
            source: env.archive, inbox: env.inbox, messageId: "collide-8"
        )
        try await env.pool.writeWithoutTransaction { db in try impostor.insert(db) }

        await NotificationActionRouter.execute(actionId: "ARCHIVE", messageId: "collide-8", accountId: "acc1")

        // C3: nothing landed on the message the user never tapped.
        let finalImpostor = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: impostor.id) }
        #expect(finalImpostor?.folderPath == env.inbox.path, "an unresolvable identity must not become a mutation")
        #expect(finalImpostor?.folderId == env.inbox.id)
        #expect(finalImpostor?.isInInbox == true)
        #expect(finalImpostor?.isRead == false)

        // NEVER DROP USER INTENTION: the guard's rejection lands on the existing
        // clean-miss cold path, addressed at the mailbox the push was FOR.
        let ops = try await env.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "the tap must survive as exactly one durable operation")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == env.inbox.path, "the cold op addresses the canonical inbox, not the impostor's PK folder")
        #expect(ops[0].destinationPath == env.archive.path)
        #expect(ops[0].messageIds == ["collide-8"])
    }

    @Test("MARK_READ never flips isRead on a moved-in impostor that merely collides on message id — the read intention is retained as a cold .markRead instead")
    func markReadNeverMarksTheMovedInImpostorRead() async throws {
        let env = try MovedInImpostorFixture.make()
        defer { MovedInImpostorFixture.finish(env); MovedInImpostorFixture.resetStagedGlobal() }
        MovedInImpostorFixture.resetStagedGlobal()

        let impostor = MovedInImpostorFixture.movedInImpostor(
            source: env.archive, inbox: env.inbox, messageId: "collide-9"
        )
        #expect(impostor.isRead == false, "the impostor starts unread — a mark-read on it would be visible")
        try await env.pool.writeWithoutTransaction { db in try impostor.insert(db) }

        await NotificationActionRouter.execute(actionId: "MARK_READ", messageId: "collide-9", accountId: "acc1")

        let finalImpostor = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: impostor.id) }
        #expect(finalImpostor?.isRead == false, "a message the user never tapped must not be marked read")
        #expect(finalImpostor?.folderPath == env.inbox.path)

        let ops = try await env.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "the read intention must survive")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .markRead)
        #expect(ops[0].folderPath == env.inbox.path)
        #expect(ops[0].messageIds == ["collide-9"])
    }
}

// MARK: - Site 2: the notification TAP resolve ladder (MessageDetailViewModel)

/// `MessageDetailViewModel.resolveProviderTap`'s durable tier is a mutation seed
/// too: whatever it resolves becomes the VM's `messageId`, and
/// `markReadOnOpenIfNeeded` durably marks THAT row read. Its pre-guard
/// `(messageId, isInInbox, accountId)` filter had no folder predicate either.
///
/// A rejection returns nil, which is the ladder's existing EXHAUSTION path:
/// `loadBody` posts `.notificationTapUnresolved` (MailNavigationView pops to the
/// inbox) and sets `messageNotFound` as a backstop. Nothing is opened, so
/// nothing is marked read.
@Suite("Notification tap resolve — folder-native identity guard", .processGlobalState)
struct NotificationTapFolderNativeIdentityTests {

    @MainActor
    @Test("the tap ladder resolves the folder-native inbox row, never a same-id row optimistically moved into the inbox")
    func tapResolvesTheNativeRowNotTheMovedInImpostor() async throws {
        let env = try MovedInImpostorFixture.make()
        defer { MovedInImpostorFixture.finish(env); MovedInImpostorFixture.resetStagedGlobal() }
        MovedInImpostorFixture.resetStagedGlobal()

        // Impostor first (lower rowid) so an unguarded LIMIT-1 read prefers it.
        let impostor = MovedInImpostorFixture.movedInImpostor(
            source: env.archive, inbox: env.inbox, messageId: "tap-collide-7"
        )
        let genuine = MovedInImpostorFixture.nativeInboxHeader(inbox: env.inbox, messageId: "tap-collide-7")
        try await env.pool.writeWithoutTransaction { db in
            try impostor.insert(db)
            try genuine.insert(db)
        }

        let resolved = await MessageDetailViewModel.resolveProviderTap("tap-collide-7", accountId: "acc1")

        // (ii) the genuine target still opens — the guard is not a blanket refusal.
        #expect(resolved == genuine.id, "the tap must open the folder-native inbox row")
        // (i)/(iii) the impostor is never the resolved identity, so it can never
        // become the row `markReadOnOpenIfNeeded` durably marks read.
        #expect(resolved != impostor.id, "a moved-in impostor must never be the tap's target")
    }

    @Test("when a moved-in impostor is the ONLY row matching the tapped id, the ladder exhausts (nil) rather than opening a message the user never tapped")
    func tapWithOnlyTheImpostorPresentFailsClosed() async throws {
        let env = try MovedInImpostorFixture.make()
        defer { MovedInImpostorFixture.finish(env); MovedInImpostorFixture.resetStagedGlobal() }
        MovedInImpostorFixture.resetStagedGlobal()

        let impostor = MovedInImpostorFixture.movedInImpostor(
            source: env.archive, inbox: env.inbox, messageId: "tap-collide-8"
        )
        try await env.pool.writeWithoutTransaction { db in try impostor.insert(db) }

        // `waitSeconds: 0` skips the bounded poll; the merge-fallback tier still
        // runs, so this exercises the FULL ladder rather than short-circuiting.
        let resolved = await MessageDetailViewModel.resolveProviderTap(
            "tap-collide-8", accountId: "acc1", waitSeconds: 0, pollMs: 1
        )

        #expect(resolved == nil, "an id that matches only a non-native row must fail closed → pop to inbox")
        #expect(resolved != impostor.id)

        // Fail-closed means fail-closed: the ladder is a pure read, so the
        // impostor is byte-identical afterwards.
        let finalImpostor = try await env.pool.read { db in try MessageHeader.fetchOne(db, key: impostor.id) }
        #expect(finalImpostor?.isRead == false)
        #expect(finalImpostor?.folderPath == env.inbox.path)
    }
}
