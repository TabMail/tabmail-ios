/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// The label menu lists up to three labels the user applied most recently in this app,
// newest first, then every label A to Z (#1386, ADR-IOS-118). It no longer ranks labels by
// how many inbox messages carry each, which read every inbox message and its label rows
// each time the menu opened.

private func label(_ providerLabelId: String, _ name: String, account: String = "acc1", system: Bool = false) -> UserLabel {
    UserLabel(accountId: account, providerLabelId: providerLabelId, name: name, isSystem: system)
}

private func hoursAgo(_ hours: Double) -> Date {
    Date().addingTimeInterval(-hours * 3600)
}

@Suite("Label menu: recent labels above every label A to Z (UserLabelStore.menu)")
struct UserLabelMenuReadTests {

    private func menu(_ db: DatabaseQueue, messageId: String, accountId: String = "acc1") throws -> UserLabelStore.Menu {
        try db.read { try UserLabelStore.menu(accountId: accountId, messageId: messageId, in: $0) }
    }

    @Test("With no label used here, the menu is every label A to Z and nothing above it, however many inbox messages carry a label")
    func noTimesMeansTheAToZListAlone() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let target = try TestDatabase.insertMessageHeader(db, messageId: "100")
        let others = try (200..<205).map { try TestDatabase.insertMessageHeader(db, messageId: String($0)) }
        let zeta = label("L1", "Zeta"), alpha = label("L2", "alpha"), beta = label("L3", "Beta")
        try db.write { db in
            for row in [zeta, alpha, beta] { try row.insert(db) }
            try MessageUserLabel(messageId: target.id, userLabelId: beta.id).insert(db)
            // The old menu put the label on the most inbox messages first.
            for header in others { try MessageUserLabel(messageId: header.id, userLabelId: zeta.id).insert(db) }
        }

        let result = try menu(db, messageId: target.id)
        let names = result.all.map(\.name)
        #expect(result.recent.isEmpty, "a label with no time here was listed above the A-to-Z list")
        #expect(names == ["alpha", "Beta", "Zeta"], "the list is not every label A to Z: \(names)")
        #expect(result.appliedIds == [beta.id])
    }

    @Test("The three most recently applied labels come first, newest first, and every label is still in the A-to-Z list")
    func threeNewestFirst() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let target = try TestDatabase.insertMessageHeader(db)
        let a = label("A", "Apple"), b = label("B", "Birch"), c = label("C", "Cedar"), d = label("D", "Dogwood"), e = label("E", "Elm")
        try db.write { db in
            for row in [a, b, c, d, e] { try row.insert(db) }
            try UserLabelStore.recordUse(of: a.id, at: hoursAgo(4), in: db)
            try UserLabelStore.recordUse(of: c.id, at: hoursAgo(2), in: db)
            try UserLabelStore.recordUse(of: d.id, at: hoursAgo(1), in: db)
            try UserLabelStore.recordUse(of: b.id, at: hoursAgo(3), in: db)
        }

        let result = try menu(db, messageId: target.id)
        let recent = result.recent.map(\.name)
        let all = result.all.map(\.name)
        #expect(recent == ["Dogwood", "Cedar", "Birch"], "recent: \(recent)")
        #expect(all == ["Apple", "Birch", "Cedar", "Dogwood", "Elm"], "all: \(all)")
        #expect(result.appliedIds.isEmpty)
    }

    @Test("Applying a label again moves it to the top; each label keeps one time")
    func reuseMovesToTheTop() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let target = try TestDatabase.insertMessageHeader(db)
        let a = label("A", "Apple"), b = label("B", "Birch")
        try db.write { db in
            try a.insert(db)
            try b.insert(db)
            try UserLabelStore.recordUse(of: a.id, at: hoursAgo(2), in: db)
            try UserLabelStore.recordUse(of: b.id, at: hoursAgo(1), in: db)
            try UserLabelStore.recordUse(of: a.id, at: Date(), in: db)
        }

        let recent = try menu(db, messageId: target.id).recent.map(\.name)
        let rows = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM userLabelLastUsed") }
        #expect(recent == ["Apple", "Birch"], "recent: \(recent)")
        #expect(rows == 2)
    }

    @Test("A time on a label the menu does not list never reaches the top, and its checkmark is not reported")
    func onlyListedLabelsReachTheTop() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertAccount(db, id: "acc2", email: "other@example.com")
        try TestDatabase.insertFolder(db)
        let target = try TestDatabase.insertMessageHeader(db)
        let work = label("Work", "Work")
        let otherAccount = label("Travel", "Travel", account: "acc2")
        let system = label("SYS", "Updates", system: true)
        let keyword = label("$junk", "$Junk")
        try db.write { db in
            for row in [work, otherAccount, system, keyword] { try row.insert(db) }
            try UserLabelStore.recordUse(of: work.id, at: hoursAgo(5), in: db)
            try UserLabelStore.recordUse(of: otherAccount.id, at: hoursAgo(1), in: db)
            try UserLabelStore.recordUse(of: system.id, at: hoursAgo(2), in: db)
            try UserLabelStore.recordUse(of: keyword.id, at: hoursAgo(3), in: db)
            try MessageUserLabel(messageId: target.id, userLabelId: work.id).insert(db)
            try MessageUserLabel(messageId: target.id, userLabelId: system.id).insert(db)
        }

        let result = try menu(db, messageId: target.id)
        let recent = result.recent.map(\.id)
        let all = result.all.map(\.id)
        #expect(recent == [work.id], "recent: \(recent)")
        #expect(all == [work.id], "all: \(all)")
        #expect(result.appliedIds == [work.id], "a label the menu does not list was reported checked")
    }

    @Test("A label sync's rewrite of a label keeps its time; removing the label or its account removes it")
    func timeLivesExactlyAsLongAsTheLabel() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertAccount(db, id: "acc2", email: "other@example.com")
        try TestDatabase.insertFolder(db)
        let target = try TestDatabase.insertMessageHeader(db)
        let work = label("Work", "Work")
        let travel = label("Travel", "Travel", account: "acc2")
        try db.write { db in
            try work.insert(db)
            try travel.insert(db)
            try UserLabelStore.recordUse(of: work.id, at: hoursAgo(1), in: db)
            try UserLabelStore.recordUse(of: travel.id, at: hoursAgo(1), in: db)
            // The catalog sync's upsert (SyncEngineFullSync) and the sync arms' insert.
            try label("Work", "Projects").save(db)
            try label("Work", "Work").insert(db, onConflict: .ignore)
        }
        let renamed = try menu(db, messageId: target.id).recent.map(\.name)
        #expect(renamed == ["Projects"], "a label sync's rewrite lost the label's time: \(renamed)")

        let remaining = try db.write { db -> [String] in
            _ = try UserLabel.deleteOne(db, key: work.id)
            _ = try Account.deleteOne(db, key: "acc2")
            return try String.fetchAll(db, sql: "SELECT userLabelId FROM userLabelLastUsed")
        }
        #expect(remaining.isEmpty, "a time outlived its label: \(remaining)")
    }
}

@Suite("Label menu: v115 adds an empty last-used table")
struct UserLabelLastUsedMigrationTests {

    @Test("No label gets a time from the mail it already carries, and a time is removed with its label")
    func startsEmptyAndCascades() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: "v114_addBodyAssetPendingDelete")

        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)
        let work = label("Work", "Work")
        try db.write { db in
            try work.insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: work.id).insert(db)
        }

        try migrator.migrate(db)

        let rows = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM userLabelLastUsed") }
        #expect(rows == 0, "the migration gave a label a time the user never gave it")
        let keys = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(userLabelLastUsed)")
                .map { "\($0["table"] as String? ?? "")/\($0["from"] as String? ?? "")/\($0["on_delete"] as String? ?? "")" }
        }
        #expect(keys == ["userLabel/userLabelId/CASCADE"], "keys: \(keys)")
    }
}

/// The menu model over an installed database: what the user's gestures write.
@Suite("Label menu: the apply gesture stamps the label", .serialized, .processGlobalState)
struct UserLabelMenuStampTests {

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    @MainActor
    private func fixture(accountId: String, provider: AccountProvider) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
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
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "Labels",
                provider: provider)
            account.id = accountId
            try account.insert(db)
            let folder = Folder(name: "Inbox", path: "Inbox", role: .inbox, accountId: accountId)
            try folder.insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    private func restore(_ fixture: Fixture) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func insertHeader(_ fixture: Fixture, messageId: String) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "Labels", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "labels",
            folderId: MessageIdentity.folderId(accountId: fixture.accountId, folderPath: "Inbox"),
            accountId: fixture.accountId, folderPath: "Inbox", isInInbox: true)
        header.rfc822MessageId = "\(messageId)@example.com"
        header.headerComplete = true
        let stored = header
        try fixture.pool.writeWithoutTransaction { db in try stored.insert(db) }
        return stored
    }

    private func insertLabels(_ fixture: Fixture, _ names: [String]) throws -> [UserLabel] {
        let rows = names.map { UserLabel(accountId: fixture.accountId, providerLabelId: $0, name: $0, isSystem: false) }
        try fixture.pool.writeWithoutTransaction { db in
            for row in rows { try row.insert(db) }
        }
        return rows
    }

    private func times(_ fixture: Fixture) throws -> [String: Date] {
        try fixture.pool.read { db in
            var result: [String: Date] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT userLabelId, lastUsedAt FROM userLabelLastUsed") {
                let id: String = row["userLabelId"]
                let time: Date = row["lastUsedAt"]
                result[id] = time
            }
            return result
        }
    }

    @Test("An admitted apply stamps the label at the gesture; this sheet keeps its order and the next opening lists the label on top")
    @MainActor
    func applyStampsAndTheNextOpeningListsIt() async throws {
        let f = try fixture(accountId: "labels-recent", provider: .outlook)
        defer { restore(f) }
        let header = try insertHeader(f, messageId: "graph-recent-1")
        let labels = try insertLabels(f, ["Gamma", "Alpha", "Beta"])
        let gamma = labels[0]

        let first = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        first.loadLabels()
        #expect(first.recentLabels.isEmpty)
        let before = Date()
        let admitted = await first.applyLabel(gamma)
        let after = Date()
        #expect(admitted)

        let stamped = try times(f)
        #expect(Array(stamped.keys) == [gamma.id], "stamped: \(stamped)")
        let stamp = stamped[gamma.id] ?? .distantPast
        let atTheGesture = stamp >= before.addingTimeInterval(-1) && stamp <= after.addingTimeInterval(1)
        #expect(atTheGesture, "the label's time \(stamp) is not the gesture's")
        #expect(first.recentLabels.isEmpty, "the open sheet re-sorted under the user's finger")

        let next = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        next.loadLabels()
        let recent = next.recentLabels.map(\.name)
        let all = next.sortedLabels.map(\.name)
        #expect(recent == ["Gamma"], "recent: \(recent)")
        #expect(all == ["Alpha", "Beta", "Gamma"], "all: \(all)")
        #expect(next.appliedIds == [gamma.id])
    }

    @Test("Removing a label does not stamp it")
    @MainActor
    func removeDoesNotStamp() async throws {
        let f = try fixture(accountId: "labels-remove", provider: .outlook)
        defer { restore(f) }
        let header = try insertHeader(f, messageId: "graph-remove-1")
        let work = try insertLabels(f, ["Work"])[0]
        let headerId = header.id, workId = work.id
        try await f.pool.write { db in
            try MessageUserLabel(messageId: headerId, userLabelId: workId).insert(db)
        }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        model.loadLabels()
        let admitted = await model.removeLabel(work)
        #expect(admitted)
        let stamped = try times(f)
        #expect(stamped.isEmpty, "a removal stamped the label: \(stamped)")
    }

    @Test("A refused apply stamps nothing: an account with no mail labels, and a message that is gone")
    @MainActor
    func refusedApplyStampsNothing() async throws {
        let caldav = try fixture(accountId: "labels-caldav-recent", provider: .caldav)
        do {
            defer { restore(caldav) }
            let header = try insertHeader(caldav, messageId: "caldav-recent-1")
            let work = try insertLabels(caldav, ["Work"])[0]
            let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
            let admitted = await model.applyLabel(work)
            #expect(admitted == false)
            let stamped = try times(caldav)
            #expect(stamped.isEmpty, "a refused apply stamped the label: \(stamped)")
        }

        let outlook = try fixture(accountId: "labels-gone-recent", provider: .outlook)
        defer { restore(outlook) }
        let header = try insertHeader(outlook, messageId: "graph-gone-1")
        let work = try insertLabels(outlook, ["Work"])[0]
        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        let headerId = header.id
        try await outlook.pool.write { db in _ = try MessageHeader.deleteOne(db, key: headerId) }
        let admitted = await model.applyLabel(work)
        #expect(admitted == false)
        let stamped = try times(outlook)
        #expect(stamped.isEmpty, "an apply to a message that is gone stamped the label: \(stamped)")
    }

    @Test("A label created in the menu goes where it falls A to Z, and is stamped")
    @MainActor
    func createdLabelFallsInOrder() async throws {
        let f = try fixture(accountId: "labels-create-recent", provider: .outlook)
        defer { restore(f) }
        let header = try insertHeader(f, messageId: "graph-create-1")
        _ = try insertLabels(f, ["Alpha", "Gamma"])

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        model.loadLabels()
        let created = await model.createAndApply(name: "Beta")
        #expect(created)
        let names = model.sortedLabels.map(\.name)
        #expect(names == ["Alpha", "Beta", "Gamma"], "names: \(names)")
        let stamped = Array(try times(f).keys)
        #expect(stamped == ["\(f.accountId):Beta"], "stamped: \(stamped)")
    }
}
