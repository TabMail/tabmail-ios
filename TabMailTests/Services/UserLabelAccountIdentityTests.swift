/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// D10 / `IOS-LABEL-001` — `userLabel` identity is ACCOUNT-SCOPED, and the value
/// that goes on the wire is a SEPARATE column.
///
/// The defect: `v33_userLabelSupport` made the provider's own label id the primary
/// key, but a provider label id is unique only WITHIN an account. Two accounts with
/// a `Receipts` Gmail label, or two IMAP accounts using a `work` keyword, shared one
/// row — so the row's owner flapped, a cascade crossed the account boundary, and a
/// message in account B rendered account A's label name.
///
/// Every test here asserts a SYSTEM PROPERTY — which rows survive, which name is
/// displayed, what reaches the wire — never the mechanism that produced it. In
/// particular nothing below asserts "the id has a colon in it": that is the fix's
/// mechanism, and a test written that way would stay green on a system whose
/// accounts still collide.
@Suite("UserLabel account-scoped identity (D10 / IOS-LABEL-001)")
struct UserLabelAccountIdentityTests {

    // MARK: - Fixture

    /// Two accounts, one INBOX message each. Nothing here is IMAP-specific; the
    /// collision is a property of the key, not of a provider.
    private func twoAccountDatabase() throws -> (db: DatabaseQueue, a: MessageHeader, b: MessageHeader) {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "accA", email: "a@example.com")
        try TestDatabase.insertAccount(db, id: "accB", email: "b@example.com")
        try TestDatabase.insertFolder(db, accountId: "accA")
        try TestDatabase.insertFolder(db, accountId: "accB")
        let a = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "accA:INBOX", accountId: "accA")
        let b = try TestDatabase.insertMessageHeader(
            db, messageId: "2", folderId: "accB:INBOX", accountId: "accB")
        return (db, a, b)
    }

    // MARK: - 1. The collision itself

    @Test("Two accounts using the SAME provider label name keep two distinct rows, each owned by its own account")
    func twoAccountsSharingALabelNameKeepDistinctRows() throws {
        let (db, _, _) = try twoAccountDatabase()

        try db.write { db in
            try UserLabel(accountId: "accA", providerLabelId: "Receipts", name: "Receipts", isSystem: false)
                .insert(db)
            try UserLabel(accountId: "accB", providerLabelId: "Receipts", name: "Receipts", isSystem: false)
                .insert(db)
        }

        let rows = try db.read { db in
            try UserLabel.order(Column("accountId")).fetchAll(db)
        }
        #expect(rows.count == 2, "one shared row means the two accounts collided again")
        guard rows.count == 2 else { return }
        #expect(rows[0].accountId == "accA")
        #expect(rows[1].accountId == "accB")
        // Both still know the provider value they must put on the wire.
        #expect(rows[0].providerLabelId == "Receipts")
        #expect(rows[1].providerLabelId == "Receipts")

        // And each account's own catalogue sees exactly its own row.
        let (aLabels, bLabels) = try db.read { db in
            (try UserLabelStore.allLabels(accountId: "accA", in: db),
             try UserLabelStore.allLabels(accountId: "accB", in: db))
        }
        #expect(aLabels.count == 1)
        #expect(bLabels.count == 1)
        #expect(aLabels.first?.accountId == "accA")
        #expect(bLabels.first?.accountId == "accB")
    }

    // MARK: - 2. The cascade must not cross the account boundary

    /// Consequence (2) of `IOS-LABEL-001`, and the most damaging one: account A
    /// removing a label server-side deleted the single shared row, and
    /// `messageUserLabel.userLabelId`'s `onDelete: .cascade` took every association
    /// row for account B's messages with it.
    ///
    /// The property is stated at the SCHEMA level — delete A's label row by its own
    /// primary key, the most basic form of the deletion the sweep performs — so it
    /// holds no matter how the sweep's SQL is later written. The end-to-end form is
    /// `gmailStaleLabelSweep…` below.
    @Test("Deleting account A's label leaves EVERY account B association intact")
    func deletingOneAccountsLabelLeavesTheOtherAccountsAssociationsIntact() throws {
        let (db, a, b) = try twoAccountDatabase()

        let labelA = UserLabel(accountId: "accA", providerLabelId: "Receipts", name: "Receipts", isSystem: false)
        let labelB = UserLabel(accountId: "accB", providerLabelId: "Receipts", name: "Receipts", isSystem: false)
        try db.write { db in
            try labelA.insert(db)
            try labelB.insert(db)
            try MessageUserLabel(messageId: a.id, userLabelId: labelA.id).insert(db)
            try MessageUserLabel(messageId: b.id, userLabelId: labelB.id).insert(db)
        }
        // NON-VACUITY: both associations really existed before the deletion, so a
        // surviving B row cannot be one that was never written.
        #expect(try db.read { try MessageUserLabel.fetchCount($0) } == 2)

        try db.write { db in _ = try labelA.delete(db) }

        let surviving = try db.read { db in try MessageUserLabel.fetchAll(db) }
        #expect(surviving.count == 1, "the cascade crossed the account boundary")
        guard let only = surviving.first else { return }
        #expect(only.messageId == b.id, "account B's association was destroyed by account A's removal")
        // And B's label is still displayable — the row itself survived too.
        let bChips = try db.read { db in try UserLabelStore.labelsForMessage(b.id, in: db) }
        #expect(bChips.map(\.name) == ["Receipts"])
        // Non-vacuity on the other side: A's own association really did go.
        let aChips = try db.read { db in try UserLabelStore.labelsForMessage(a.id, in: db) }
        #expect(aChips.isEmpty)
    }

    // MARK: - 3. The owner must not flap

    /// Consequence (1). The Gmail arm writes with `.save(db)` (an upsert), so
    /// whichever account synced last used to overwrite `accountId`/`name`/`isSystem`
    /// on the shared row.
    @Test("A Gmail-style upsert from account A cannot alter account B's row")
    func gmailStyleUpsertFromOneAccountCannotAlterTheOther() throws {
        let (db, _, _) = try twoAccountDatabase()

        try db.write { db in
            try UserLabel(accountId: "accB", providerLabelId: "Receipts", name: "B's Receipts", isSystem: false)
                .save(db)
        }
        // Account A now syncs the same provider label id, with its OWN name.
        try db.write { db in
            try UserLabel(accountId: "accA", providerLabelId: "Receipts", name: "A's Receipts", isSystem: true)
                .save(db)
        }

        let bRow = try db.read { db in
            try UserLabel.filter(Column("accountId") == "accB").fetchOne(db)
        }
        #expect(bRow?.name == "B's Receipts", "account A's upsert overwrote account B's label name")
        #expect(bRow?.isSystem == false, "account A's upsert overwrote account B's isSystem flag")
        #expect(bRow?.accountId == "accB", "account A's upsert stole ownership of account B's row")
    }

    /// The other half of consequence (1). The IMAP/keyword arms write with
    /// `insert(db, onConflict: .ignore)`, so the FIRST writer used to win forever and
    /// every later account silently bound to a row naming somebody else's account.
    @Test("An IMAP-style ignore-insert from account A cannot prevent account B's row existing")
    func imapStyleIgnoreInsertFromOneAccountCannotSuppressTheOther() throws {
        let (db, _, _) = try twoAccountDatabase()

        try db.write { db in
            try UserLabel(accountId: "accA", providerLabelId: "work", name: "work", isSystem: false)
                .insert(db, onConflict: .ignore)
        }
        try db.write { db in
            try UserLabel(accountId: "accB", providerLabelId: "work", name: "work", isSystem: false)
                .insert(db, onConflict: .ignore)
        }

        let bRow = try db.read { db in
            try UserLabel.filter(Column("accountId") == "accB").fetchOne(db)
        }
        #expect(bRow != nil, "account B's keyword was swallowed by account A's earlier insert")
        #expect(bRow?.providerLabelId == "work")
    }

    // MARK: - 5. The display path

    /// Consequence (3): `labelsForMessage` and `loadLabels` join by id alone, so a
    /// message in account B used to render whatever name the shared row currently
    /// carried. There is deliberately still no `accountId` predicate on either — the
    /// unified inbox batches messages from every account into one `loadLabels` call —
    /// so the id itself has to carry the account, and this test is what proves it does.
    @Test("A message in account B renders account B's label name, never account A's")
    func displayPathRendersTheOwningAccountsName() throws {
        let (db, a, b) = try twoAccountDatabase()

        let labelA = UserLabel(accountId: "accA", providerLabelId: "Receipts", name: "A's Receipts", isSystem: false)
        let labelB = UserLabel(accountId: "accB", providerLabelId: "Receipts", name: "B's Receipts", isSystem: false)
        try db.write { db in
            try labelA.insert(db)
            try labelB.insert(db)
            try MessageUserLabel(messageId: a.id, userLabelId: labelA.id).insert(db)
            try MessageUserLabel(messageId: b.id, userLabelId: labelB.id).insert(db)
        }

        let bChips = try db.read { db in try UserLabelStore.labelsForMessage(b.id, in: db) }
        #expect(bChips.map(\.name) == ["B's Receipts"])
        let aChips = try db.read { db in try UserLabelStore.labelsForMessage(a.id, in: db) }
        #expect(aChips.map(\.name) == ["A's Receipts"])

        // The batch reader is the one the unified inbox actually uses, and it sees
        // BOTH accounts in a single call — the exact shape that made the collision
        // visible on screen.
        let batch = try db.read { db in try UserLabelStore.loadLabels(for: [a.id, b.id], in: db) }
        #expect(batch[a.id]?.map(\.name) == ["A's Receipts"])
        #expect(batch[b.id]?.map(\.name) == ["B's Receipts"])
    }

    /// The exclusion filter reads the BARE provider value, not the surrogate. Handing
    /// it the surrogate makes every id-branch test (`excludedNames`, the `[imap]` /
    /// `[gmail]` / `category_` prefixes) silently stop matching, so Gmail category
    /// pseudo-labels would leak into the chips.
    @Test("Display filtering still excludes a provider label id that only the ID branch can catch")
    func displayFilteringStillReadsTheBareProviderValue() throws {
        let (db, a, _) = try twoAccountDatabase()

        // `CATEGORY_PROMOTIONS` is caught by the `category_` prefix test on the ID.
        // Its NAME here is an innocuous one the name branch cannot reject, so only
        // the id branch can exclude it.
        let promo = UserLabel(
            accountId: "accA", providerLabelId: "CATEGORY_PROMOTIONS",
            name: "Promotions", isSystem: false)
        let real = UserLabel(accountId: "accA", providerLabelId: "Receipts", name: "Receipts", isSystem: false)
        try db.write { db in
            try promo.insert(db)
            try real.insert(db)
            try MessageUserLabel(messageId: a.id, userLabelId: promo.id).insert(db)
            try MessageUserLabel(messageId: a.id, userLabelId: real.id).insert(db)
        }

        let chips = try db.read { db in try UserLabelStore.labelsForMessage(a.id, in: db) }
        #expect(chips.map(\.name) == ["Receipts"], "a Gmail category pseudo-label leaked into the chips")
        let catalogue = try db.read { db in try UserLabelStore.allLabels(accountId: "accA", in: db) }
        #expect(catalogue.map(\.name) == ["Receipts"])
    }

    // MARK: - 8. Non-vacuity — the ordinary single-account user is unchanged

    /// Two-sided: the single-account path must still LOAD, RENDER and DELETE exactly
    /// as before. A fix that scoped everything by making nothing reachable would pass
    /// tests 1–5 and fail here.
    @Test("A single-account user's labels still load, render, and delete exactly as before")
    func singleAccountBehaviourIsUnchanged() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db)

        let work = UserLabel(accountId: "acc1", providerLabelId: "L1", name: "Work", isSystem: false)
        let play = UserLabel(accountId: "acc1", providerLabelId: "L2", name: "Play", isSystem: false)
        try db.write { db in
            try work.insert(db)
            try play.insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: work.id).insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: play.id).insert(db)
        }

        // LOAD — the catalogue and the menu both see both labels.
        #expect(try db.read { try UserLabelStore.allLabels(accountId: "acc1", in: $0) }.map(\.name)
                == ["Play", "Work"])
        let menu = try db.read { db in
            try UserLabelStore.labelsSortedForMenu(
                accountId: "acc1", messageId: msg.id, inboxFolderIds: ["acc1:INBOX"], in: db)
        }
        #expect(menu.count == 2)
        let everyMenuRowIsChecked = menu.allSatisfy { $0.isApplied }
        #expect(everyMenuRowIsChecked, "an applied label lost its checkmark")

        // RENDER — the chips, both singly and through the batch reader.
        #expect(try db.read { try UserLabelStore.labelsForMessage(msg.id, in: $0) }.map(\.name)
                == ["Play", "Work"])
        #expect(try db.read { try UserLabelStore.loadLabels(for: [msg.id], in: $0) }[msg.id]?.map(\.name)
                == ["Play", "Work"])

        // Case-insensitive lookup by name still resolves to the same row.
        let found = try db.read { try UserLabelStore.findByName("work", accountId: "acc1", in: $0) }
        #expect(found?.id == work.id)
        #expect(found?.providerLabelId == "L1")

        // DELETE — removing the label still cascades its association away, and
        // leaves the other one alone.
        try db.write { db in _ = try work.delete(db) }
        #expect(try db.read { try UserLabelStore.labelsForMessage(msg.id, in: $0) }.map(\.name) == ["Play"])
        #expect(try db.read { try UserLabel.fetchCount($0) } == 1)
    }
}

// MARK: - 6. The migration

/// `v82_accountScopedUserLabelIdentity` on a database shaped exactly as every
/// existing device arrives at it.
@Suite("UserLabel identity migration v82 (D10 / IOS-LABEL-001)")
struct UserLabelIdentityMigrationTests {

    /// A database migrated only as far as `v81`, i.e. the pre-`v82` shape.
    private static func makeV81Database() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: "v81_addActionTagSetAt")
        return db
    }

    private static func migrateToHead(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db)
    }

    /// Raw SQL because the `UserLabel` model no longer describes the pre-`v82`
    /// table — it carries `providerLabelId`, which does not exist yet.
    private static func insertLegacyLabel(
        _ db: DatabaseQueue, id: String, accountId: String, name: String, isSystem: Bool = false
    ) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO userLabel (id, accountId, name, isSystem) VALUES (?, ?, ?, ?)",
                arguments: [id, accountId, name, isSystem])
        }
    }

    private static func insertLegacyAssociation(
        _ db: DatabaseQueue, messageId: String, userLabelId: String
    ) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO messageUserLabel (messageId, userLabelId) VALUES (?, ?)",
                arguments: [messageId, userLabelId])
        }
    }

    @discardableResult
    private static func insertAccount(_ db: DatabaseQueue, id: String) throws -> Account {
        var account = Account(emailAddress: "\(id)@example.com", displayName: id, provider: .gmail)
        account.id = id
        let toInsert = account
        try db.write { try toInsert.insert($0) }
        return account
    }

    @discardableResult
    private static func insertHeader(_ db: DatabaseQueue, accountId: String, uid: String) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "v82 fixture", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "v82",
            folderId: "\(accountId):INBOX", accountId: accountId,
            folderPath: "INBOX", isInInbox: true)
        header.headerComplete = true
        // Raw SQL because this fixture deliberately stops at v81 while the
        // current MessageHeader model includes columns introduced later.
        try db.write { connection in
            try connection.execute(sql: """
                INSERT INTO messageHeader
                    (id, folderId, accountId, folderPath, isInInbox, messageId,
                     subject, `from`, fromAddress, `to`, date, snippet, headerComplete)
                VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, 1)
                """, arguments: [
                    header.id, header.folderId, header.accountId, header.folderPath,
                    header.messageId, header.subject, header.from, header.fromAddress,
                    header.to, header.date, header.snippet,
                ])
        }
        return header
    }

    /// THE PROPERTY, stated as an end state: after upgrading, BOTH accounts' label
    /// associations are still there, each pointing at a row its OWN account owns,
    /// every row still knows the bare provider value it must put on the wire, and a
    /// label the user created but never applied is still in their catalogue.
    @Test("v82 repairs a hijacked shared row: both accounts keep their associations, each pointing at its own row")
    func migrationSplitsASharedRowAndRepointsBothAccounts() throws {
        let db = try Self.makeV81Database()
        try Self.insertAccount(db, id: "accA")
        try Self.insertAccount(db, id: "accB")
        let a = try Self.insertHeader(db, accountId: "accA", uid: "1")
        let b = try Self.insertHeader(db, accountId: "accB", uid: "2")

        // The defect's exact shape: ONE row for a label id BOTH accounts use, whose
        // `accountId`/`name` belong to whichever account wrote last (here A), plus a
        // label account B created and never applied to anything.
        try Self.insertLegacyLabel(db, id: "Receipts", accountId: "accA", name: "A's Receipts")
        try Self.insertLegacyLabel(db, id: "Unapplied", accountId: "accB", name: "Never Applied")
        try Self.insertLegacyAssociation(db, messageId: a.id, userLabelId: "Receipts")
        try Self.insertLegacyAssociation(db, messageId: b.id, userLabelId: "Receipts")

        // NON-VACUITY (pre-state): one row really was shared by two accounts.
        let sharedBefore = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM userLabel WHERE id = 'Receipts'")
        }
        #expect(sharedBefore == 1)
        #expect(try db.read { try MessageUserLabel.fetchCount($0) } == 2)

        try Self.migrateToHead(db)

        // Every association survived, and each names a row owned by its own account.
        let chipsA = try db.read { db in try UserLabelStore.labelsForMessage(a.id, in: db) }
        let chipsB = try db.read { db in try UserLabelStore.labelsForMessage(b.id, in: db) }
        #expect(chipsA.count == 1, "account A lost its label association across the upgrade")
        #expect(chipsB.count == 1, "account B lost its label association across the upgrade")
        #expect(chipsA.first?.accountId == "accA")
        #expect(chipsB.first?.accountId == "accB",
                "account B's message is still pointing at the row account A hijacked")

        // The bare provider value survived on both — it is what goes on the wire.
        #expect(chipsA.first?.providerLabelId == "Receipts")
        #expect(chipsB.first?.providerLabelId == "Receipts")

        // The created-but-unapplied label is still in account B's catalogue.
        // Dropping it would have destroyed a label the user made.
        let catalogueB = try db.read { db in try UserLabelStore.allLabels(accountId: "accB", in: db) }
        #expect(Set(catalogueB.map(\.providerLabelId)) == ["Receipts", "Unapplied"])

        // Nothing legacy is left behind: every row is account-owned, and the two
        // accounts no longer share one.
        let rows = try db.read { db in try UserLabel.fetchAll(db) }
        #expect(rows.count == 3, "expected accA:Receipts, accB:Receipts and accB:Unapplied, got \(rows.map(\.id))")
        #expect(Set(rows.map(\.id)).count == rows.count)
        for row in rows {
            #expect(row.id == UserLabel(
                accountId: row.accountId, providerLabelId: row.providerLabelId,
                name: row.name, isSystem: row.isSystem).id,
                    "row \(row.id) was left in the legacy bare-id shape")
        }

        // The cascade can no longer cross accounts — the whole point of the split.
        try db.write { db in
            _ = try UserLabel.filter(Column("accountId") == "accA").deleteAll(db)
        }
        #expect(try db.read { db in try UserLabelStore.labelsForMessage(b.id, in: db) }.count == 1,
                "account A's label removal still destroys account B's association after the upgrade")
    }

    /// The convergence half of Data Integrity rule 5: a FRESH install runs `v33` and
    /// then `v82` over empty tables and must land on the identical schema an upgraded
    /// database reaches. Asserted behaviourally — the same writes and reads work on
    /// both — rather than by string-comparing DDL.
    @Test("A fresh install and an upgraded database converge on the same userLabel behaviour")
    func freshInstallAndUpgradeConverge() throws {
        let upgraded = try Self.makeV81Database()
        try Self.insertAccount(upgraded, id: "acc1")
        try Self.migrateToHead(upgraded)

        let fresh = try TestDatabase.make()
        try TestDatabase.insertAccount(fresh)

        for db in [upgraded, fresh] {
            let label = UserLabel(accountId: "acc1", providerLabelId: "Receipts", name: "Receipts", isSystem: false)
            try db.write { try label.insert($0) }
            let fetched = try db.read { try UserLabel.fetchOne($0, key: label.id) }
            #expect(fetched?.providerLabelId == "Receipts")
            #expect(fetched?.accountId == "acc1")
        }

        // And the column set really is the same on both, so a later migration or a
        // model change cannot diverge silently.
        func columns(_ db: DatabaseQueue) throws -> [String] {
            try db.read { db in try db.columns(in: "userLabel").map(\.name).sorted() }
        }
        #expect(try columns(upgraded) == columns(fresh))
    }

    /// An association whose owning message is gone cannot be re-pointed — the
    /// migration has no account to name it with. It is deleted rather than left to
    /// strand on a bare id, which would fail the closing foreign-key check and brick
    /// launch. The property asserted is that the migration COMPLETES and every
    /// resolvable association survives.
    @Test("v82 completes when an association's owning message is missing, and keeps every resolvable one")
    func migrationSurvivesAnOrphanedAssociation() throws {
        let db = try Self.makeV81Database()
        try Self.insertAccount(db, id: "accA")
        let a = try Self.insertHeader(db, accountId: "accA", uid: "1")

        try Self.insertLegacyLabel(db, id: "Receipts", accountId: "accA", name: "Receipts")
        try Self.insertLegacyAssociation(db, messageId: a.id, userLabelId: "Receipts")
        // Foreign keys are enforced on this connection, so an orphan has to be made
        // the only way one could ever exist: with enforcement off.
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: "INSERT INTO messageUserLabel (messageId, userLabelId) VALUES (?, ?)",
                arguments: ["accA:INBOX:gone", "Receipts"])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        #expect(try db.read { try MessageUserLabel.fetchCount($0) } == 2)

        try Self.migrateToHead(db)

        #expect(try db.read { db in try UserLabelStore.labelsForMessage(a.id, in: db) }.count == 1,
                "the resolvable association was destroyed alongside the orphan")
        #expect(try db.read { try MessageUserLabel.fetchCount($0) } == 1)
    }
}

// MARK: - 4. The wire value stays bare

/// 🔴 **THE TEST THAT WOULD HAVE CAUGHT V1'S DEFECT.**
///
/// A `UserLabel`'s primary key is now the account-prefixed surrogate, but
/// `PendingOperation.userLabelId` is a RAW PROVIDER ARGUMENT: the drain hands it
/// straight to Gmail as `addLabelIds:` and to IMAP as `STORE +FLAGS (<keyword>)`.
/// Putting the surrogate there would be worse than a loud failure —
///
///  * on **IMAP** it writes a keyword the user never asked for onto the real
///    message, a wrong-VALUE server mutation; and
///  * on **Gmail** the API answers `"Invalid label: …"`, which
///    `GmailProvider.isAuthoritativeActionRejection` classifies as a
///    provider-authoritative no-op — so the operation leaves the queue **as if it
///    had succeeded** and the user's label action is silently discarded. That is
///    a dropped user intention, the cardinal sin of this codebase, arriving with
///    no error anywhere.
///
/// The assertions are therefore made at the WIRE, and the label is armed as
/// remotely-deleted under its surrogate name so a regression cannot merely look
/// different — it triggers Gmail's real 400 and provably fails to land.
///
/// `.serialized, .processGlobalState`: swaps `AppDatabase.shared` and registers
/// providers on the `AccountManager` singleton.
@Suite("UserLabel wire value stays bare (D10 / IOS-LABEL-001)", .serialized, .processGlobalState)
struct UserLabelWireValueTests {

    // MARK: Harness (mirrors NeverDropExitClosureTests.fixture / AccountManagerQueueDrainTests.makeTestDB)

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    @MainActor
    private func fixture(
        accountId: String,
        provider: AccountProvider,
        folderEpoch: Int?
    ) throws -> Fixture {
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
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "D10", provider: provider)
            account.id = accountId
            try account.insert(db)
            var folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
            folder.lastKnownUidValidity = folderEpoch
            try folder.insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    /// Synchronous so it is safe in a `defer` that an early `guard … else { return }`
    /// may reach — leaving `AppDatabase.shared` swapped would contaminate every
    /// later suite. Provider deregistration is done inline at the end of the tests
    /// that register one; each test uses a unique account id, so a registration
    /// left behind by an early return is inert.
    private func restore(_ fixture: Fixture) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    @discardableResult
    private func insertHeader(
        _ fixture: Fixture, messageId: String, rfc822: String, epoch: Int?
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "D10 wire", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "wire",
            folderId: MessageIdentity.folderId(accountId: fixture.accountId, folderPath: "INBOX"),
            accountId: fixture.accountId, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = rfc822
        header.headerComplete = true
        header.observedUidValidity = epoch
        let stored = header
        try fixture.pool.writeWithoutTransaction { db in try stored.insert(db) }
        return stored
    }

    private static func rfc822Text(messageId: String) -> String {
        """
        From: Sender <sender@example.com>\r
        To: Receiver <receiver@example.com>\r
        Subject: d10\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        d10 body\r

        """
    }

    // MARK: 4a — the queued operation

    /// The op is built by the REAL construction site from a REAL prefixed row, so
    /// this cannot pass by a test that mints its own bare `UserLabel`.
    @Test("A label gesture queues the BARE provider id while the local join row keeps the surrogate")
    @MainActor
    func queuedOperationCarriesTheBareProviderId() async throws {
        let f = try fixture(accountId: "d10-queued", provider: .gmail, folderEpoch: nil)
        defer { restore(f) }

        let header = try insertHeader(f, messageId: "gmail-msg-1", rfc822: "queued@example.com", epoch: nil)
        let label = UserLabel(
            accountId: f.accountId, providerLabelId: "Label_42", name: "Receipts", isSystem: false)
        try await f.pool.writeWithoutTransaction { db in try label.insert(db) }

        // No provider is registered, so the inline drain finds nothing to execute
        // and the queued row survives for inspection.
        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        model.supportsRemoteUserLabels = true
        #expect(await model.applyLabel(label), "the gesture must be admitted on Gmail")

        let ops = try await f.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard let op = ops.first else { return }
        #expect(op.userLabelId == "Label_42",
                "the queued wire argument must be the provider's own label id, got \(op.userLabelId ?? "<nil>")")

        // …while the LOCAL association is keyed by the surrogate, which is what
        // makes the display path account-safe. Both halves, one gesture.
        let joins = try await f.pool.read { db in try MessageUserLabel.fetchAll(db) }
        #expect(joins.map(\.userLabelId) == [label.id])
        let chips = try await f.pool.read { db in try UserLabelStore.labelsForMessage(header.id, in: db) }
        #expect(chips.map(\.name) == ["Receipts"])
    }

    // MARK: 4b — the Gmail executor arm

    @Test("A Gmail label gesture reaches messages.modify with the bare provider label id")
    @MainActor
    func gmailExecutorArmReceivesTheBareProviderId() async throws {
        let f = try fixture(accountId: "d10-gmail", provider: .gmail, folderEpoch: nil)
        let header = try insertHeader(f, messageId: "gmail-msg-1", rfc822: "gmail@example.com", epoch: nil)

        let server = StatefulGmailActionServer(
            messages: [.init(
                rfc822MessageId: "gmail@example.com",
                providerMessageId: "gmail-msg-1",
                labels: ["INBOX"]
            )],
            userLabels: ["Label_42": "Receipts"]
        )
        defer { server.close() }
        // ARMED: if this ever regresses to `UserLabel.id`, Gmail answers its real
        // `"Invalid label"` 400 — which the adapter reads as an AUTHORITATIVE
        // no-op, quietly retiring the op. The wire assertions below are what
        // distinguish that silent discard from a success.
        server.markLabelDeleted("\(f.accountId):Label_42")

        defer { restore(f) }
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())

        let label = UserLabel(
            accountId: f.accountId, providerLabelId: "Label_42", name: "Receipts", isSystem: false)
        try await f.pool.writeWithoutTransaction { db in try label.insert(db) }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        model.supportsRemoteUserLabels = true
        #expect(await model.applyLabel(label))
        await AccountManager.shared.drainPendingQueue()

        // WIRE, not queue: what the provider was actually asked to do.
        #expect(server.modifyLog().count == 1, "expected exactly one modify: \(server.modifyLog())")
        #expect(server.modifyLog().last?.addLabelIds == ["Label_42"],
                "Gmail received \(server.modifyLog().last?.addLabelIds ?? []) instead of the bare label id")
        #expect(server.snapshot(providerMessageId: "gmail-msg-1")?.labels.contains("Label_42") == true,
                "the label never landed on the message")
        // And the intention completed rather than being retired as a no-op.
        let remainingOps = try await f.pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(remainingOps == 0)

        await AccountManager.shared.unregisterProviderForTesting(accountId: f.accountId)
    }

    // MARK: 4c — the IMAP executor arm

    @Test("An IMAP label gesture stores the bare keyword, never the account-prefixed surrogate")
    @MainActor
    func imapExecutorArmReceivesTheBareKeyword() async throws {
        let target = "d10-imap@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [FakeIMAPServer.makeMessage(uid: 44, rfc822Text: Self.rfc822Text(messageId: target))]
        ])
        server.setUidValidity(10, for: "INBOX")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }

        let f = try fixture(accountId: "d10-imap", provider: .imap, folderEpoch: 10)
        let header = try insertHeader(f, messageId: "44", rfc822: target, epoch: 10)

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { restore(f) }
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: provider)

        let label = UserLabel(
            accountId: f.accountId, providerLabelId: "urgent", name: "Urgent", isSystem: false)
        try await f.pool.writeWithoutTransaction { db in try label.insert(db) }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        model.supportsRemoteUserLabels = true
        #expect(await model.applyLabel(label))
        await AccountManager.shared.drainPendingQueue()

        let flags = server.flags(in: "INBOX", uid: 44)
        #expect(flags.contains("urgent"), "the keyword never reached the server: \(flags)")
        #expect(!flags.contains("\(f.accountId):urgent"),
                "the account-prefixed surrogate was written to the real message as a keyword: \(flags)")
        #expect(server.wrongMessageViolations().isEmpty)
        let remainingOps = try await f.pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(remainingOps == 0)

        try? await provider.disconnect()
        await AccountManager.shared.unregisterProviderForTesting(accountId: f.accountId)
    }
}

// MARK: - 7. The Gmail stale-label sweep

/// Consequence (2), end to end through the code that actually performs the
/// deletion. `SyncEngineFullSync`'s sweep deletes every local label row the
/// account's remote folder list no longer mentions; under the shared-row schema
/// the row it deleted could be one another account's messages were pointing at,
/// and `messageUserLabel`'s `onDelete: .cascade` took their associations too.
@Suite("Gmail stale-label sweep is account-scoped (D10 / IOS-LABEL-001)", .serialized, .processGlobalState)
struct GmailStaleLabelSweepScopeTests {

    @Test("Account A's stale-label sweep deletes only A's rows and leaves account B's association intact")
    func staleLabelSweepDoesNotReachTheOtherAccount() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let accountA = try FolderEpochTestFixture.makeAccount(id: "d10-sweep-a", provider: .gmail, pool: pool)
        _ = try FolderEpochTestFixture.makeAccount(id: "d10-sweep-b", provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountA.id, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: "d10-sweep-b", path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertHeaders(
            accountId: "d10-sweep-b", path: "INBOX", uids: [7], pool: pool)

        // BOTH accounts have a label whose provider id is `Label_9`. Account A
        // also has `Label_8`, which its remote list still carries — the control
        // that proves the sweep is selective rather than simply inert.
        let staleForA = UserLabel(
            accountId: accountA.id, providerLabelId: "Label_9", name: "Receipts", isSystem: false)
        let keptByA = UserLabel(
            accountId: accountA.id, providerLabelId: "Label_8", name: "Travel", isSystem: false)
        let ownedByB = UserLabel(
            accountId: "d10-sweep-b", providerLabelId: "Label_9", name: "Receipts", isSystem: false)
        try await pool.write { db in
            try staleForA.insert(db)
            try keptByA.insert(db)
            try ownedByB.insert(db)
            try MessageUserLabel(
                messageId: "d10-sweep-b:INBOX:7", userLabelId: ownedByB.id).insert(db)
        }
        // NON-VACUITY (pre-state): account B really does have an association on a
        // label id account A is about to declare stale.
        let associationsBefore = try await pool.read { try MessageUserLabel.fetchCount($0) }
        #expect(associationsBefore == 1)

        // Account A's remote list drops `Label_9` and retains `Label_8`.
        let mock = MockEmailProvider()
        await mock.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0,
                       totalCount: 0, uidNext: nil, uidValidity: nil),
            FolderInfo(name: "Travel", path: "Label_8", role: .custom, unreadCount: 0,
                       totalCount: 0, uidNext: nil, uidValidity: nil),
        ])
        await mock.setFetchMessagesResult([])

        try await SyncEngine().fullSync(account: accountA, provider: mock)

        let remaining = try await pool.read { db in try UserLabel.fetchAll(db) }
        let remainingIds = Set(remaining.map(\.id))
        // NON-VACUITY (post-state): the sweep really did delete something.
        #expect(!remainingIds.contains(staleForA.id), "the sweep failed to remove account A's stale label")
        // …and it was selective.
        #expect(remainingIds.contains(keptByA.id), "the sweep removed a label account A's remote list still carries")
        // THE PROPERTY: account B is untouched — the row AND the association.
        #expect(remainingIds.contains(ownedByB.id),
                "account A's sweep deleted account B's label row")
        let bChips = try await pool.read { db in
            try UserLabelStore.labelsForMessage("d10-sweep-b:INBOX:7", in: db)
        }
        #expect(bChips.map(\.name) == ["Receipts"],
                "account A's sweep cascaded away account B's label association")
    }
}
