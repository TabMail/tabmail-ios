/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// INVARIANT: creating a Gmail label by a name Gmail already has applies Gmail's
// existing label to the message, under Gmail's spelling of the name, and the
// menu lists that label once. Gmail refuses the second create with HTTP 409
// "Label name exists or conflicts"; the menu then looks the label up by name
// and applies it, rather than failing the gesture. When the lookup finds no such
// label (it was deleted elsewhere in between), the gesture fails and nothing is
// written: no label row, no menu entry, no queued label change. The control case
// shows a free name still creates a new label, so the conflict cannot be
// satisfied by a fake that refuses every create.

@Suite("Gmail label create: a name Gmail already has applies the existing label", .serialized, .processGlobalState)
struct UserLabelCreateExistingNameTests {

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
        let header: MessageHeader
    }

    @MainActor
    private func fixture(accountId: String, listedLabel: UserLabel?) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        var header = MessageHeader(
            messageId: "gmail-msg-1", subject: "Label create", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "label",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX"),
            accountId: accountId, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "label-create@example.com"
        header.headerComplete = true
        let stored = header
        try pool.writeWithoutTransaction { db in
            var account = Account(emailAddress: "\(accountId)@example.com", displayName: "Label", provider: .gmail)
            account.id = accountId
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId).insert(db)
            try stored.insert(db)
            try listedLabel?.insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId, header: stored)
    }

    private func restore(_ fixture: Fixture) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func server() -> StatefulGmailActionServer {
        StatefulGmailActionServer(
            messages: [.init(
                rfc822MessageId: "label-create@example.com",
                providerMessageId: "gmail-msg-1",
                labels: ["INBOX"]
            )],
            userLabels: ["Label_7": "Receipts"],
            createdLabelId: "Label_99"
        )
    }

    private struct Outcome {
        let created: Bool
        /// The account's stored label rows.
        let stored: [UserLabel]
        /// The menu's entries after the gesture.
        let menu: [UserLabel]
        let appliedIds: Set<String>
        /// What Gmail was last asked to add to the message.
        let added: [String]?
        /// How many changes Gmail was asked to make to the message.
        let modifyCalls: Int
        /// The account's operations still queued after the drain.
        let queued: Int
    }

    /// Opens the menu, creates `name` through it, drains the queue, and returns
    /// what the account, the menu and Gmail show afterwards. `listedProviderLabelId`
    /// and `listedName`, when given, put that label in the menu before the gesture.
    @MainActor
    private func createAndApply(_ name: String, accountId: String, listedProviderLabelId: String? = nil, listedName: String? = nil, configure: (StatefulGmailActionServer) -> Void = { _ in }) async throws -> Outcome {
        let listed = listedProviderLabelId.map {
            UserLabel(accountId: accountId, providerLabelId: $0, name: listedName ?? $0, isSystem: false)
        }
        let f = try fixture(accountId: accountId, listedLabel: listed)
        defer { restore(f) }
        let gmail = server()
        defer { gmail.close() }
        configure(gmail)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: gmail.provider())

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: f.header))
        model.loadLabels()
        #expect(model.supportsRemoteUserLabels)
        #expect(model.sortedLabels.map(\.providerLabelId) == (listedProviderLabelId.map { [$0] } ?? []))
        let created = await model.createAndApply(name: name)
        await AccountManager.shared.drainPendingQueue()

        let (stored, queued) = try await f.pool.read { db in
            (try UserLabel.filter(Column("accountId") == f.accountId).fetchAll(db),
             try PendingOperation.filter(Column("accountId") == f.accountId).fetchCount(db))
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: f.accountId)
        return Outcome(created: created, stored: stored, menu: model.sortedLabels,
                       appliedIds: model.appliedIds, added: gmail.modifyLog().last?.addLabelIds,
                       modifyCalls: gmail.modifyLog().count, queued: queued)
    }

    /// The single entry for `providerLabelId` in `labels`, or nil when there is
    /// none or more than one.
    private func only(_ providerLabelId: String, in labels: [UserLabel]) -> UserLabel? {
        let matches = labels.filter { $0.providerLabelId == providerLabelId }
        return matches.count == 1 ? matches[0] : nil
    }

    @Test("A name Gmail already has, in other letter case: Gmail's label is applied under Gmail's name")
    @MainActor
    func existingNameAppliesTheExistingLabel() async throws {
        let result = try await createAndApply("receipts", accountId: "label-409-existing")
        #expect(result.created, "the create gesture failed on Gmail's 409")
        #expect(result.added == ["Label_7"], "Gmail was asked to add \(result.added ?? [])")
        let stored = only("Label_7", in: result.stored)
        #expect(stored?.name == "Receipts", "stored rows: \(result.stored.map { "\($0.providerLabelId)=\($0.name)" })")
        let listed = only("Label_7", in: result.menu)
        #expect(listed?.name == "Receipts", "menu: \(result.menu.map { "\($0.providerLabelId)=\($0.name)" })")
        #expect(listed.map { result.appliedIds.contains($0.id) } == true)
    }

    @Test("A label already in the menu under an old name: Gmail's label is applied, listed once, under Gmail's name")
    @MainActor
    func listedNameIsListedOnce() async throws {
        let result = try await createAndApply("Receipts", accountId: "label-409-listed", listedProviderLabelId: "Label_7", listedName: "Old receipts")
        #expect(result.created, "the create gesture failed on Gmail's 409")
        #expect(result.added == ["Label_7"], "Gmail was asked to add \(result.added ?? [])")
        #expect(result.menu.count == 1, "menu: \(result.menu.map { "\($0.providerLabelId)=\($0.name)" })")
        let listed = only("Label_7", in: result.menu)
        #expect(listed?.name == "Receipts", "menu: \(result.menu.map { "\($0.providerLabelId)=\($0.name)" })")
        #expect(listed.map { result.appliedIds.contains($0.id) } == true)
    }

    @Test("A 409 for a name Gmail no longer lists: the gesture fails and nothing is written")
    @MainActor
    func conflictWithNoListedLabelWritesNothing() async throws {
        let result = try await createAndApply("Invoices", accountId: "label-409-gone") { $0.refuseNextCreateWithConflict() }
        #expect(!result.created, "the gesture reported success with no label to apply")
        #expect(result.stored.isEmpty, "stored rows: \(result.stored.map { "\($0.providerLabelId)=\($0.name)" })")
        #expect(result.menu.isEmpty, "menu: \(result.menu.map { "\($0.providerLabelId)=\($0.name)" })")
        #expect(result.appliedIds.isEmpty)
        #expect(result.queued == 0, "queued operations: \(result.queued)")
        #expect(result.modifyCalls == 0, "Gmail was asked to change the message \(result.modifyCalls) times")
    }

    @Test("A name Gmail does not have: a new label is created and applied")
    @MainActor
    func freeNameCreatesANewLabel() async throws {
        let result = try await createAndApply("Invoices", accountId: "label-409-free")
        #expect(result.created)
        #expect(result.added == ["Label_99"], "Gmail was asked to add \(result.added ?? [])")
        #expect(only("Label_99", in: result.stored)?.name == "Invoices")
        let listed = only("Label_99", in: result.menu)
        #expect(listed?.name == "Invoices")
        #expect(listed.map { result.appliedIds.contains($0.id) } == true)
    }
}
