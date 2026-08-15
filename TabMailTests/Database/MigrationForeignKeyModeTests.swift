/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The invariant `foreignKeyChecks: .immediate` must not break.
///
/// The range from `v68` **to the top of the chain** used to run on the wrapper's
/// `.deferred` default, which made GRDB append a whole-database
/// `PRAGMA foreign_key_check` to EVERY migration in it — measured at 69–74% of
/// the entire upgrade's wall clock, and at 70% of it (19,312 ms of 27,601 ms) on
/// the owner's real device. They ALL declare `.immediate` instead now, which
/// enforces foreign keys LIVE on the writes the body actually makes and runs no
/// trailing scan.
///
/// ⚠️ **THE RANGE IS AN OPEN INTERVAL AND IS RE-DERIVED, NEVER RESTATED
/// (`MIS-031`, `IOS-DOC-002`).** This paragraph read *"`v68…v83` … EVERY one of
/// the 16 migrations … ALL SIXTEEN now declare `.immediate`"* until R17b-B3, and
/// before that *"Fifteen of them"* between the two flips (`v82`'s gate outlived
/// `v71`'s by one commit). Both were exact when written and both went stale the
/// moment a migration was appended — R17-6 corrected the same sentence in five
/// places in `AppDatabase.swift` and left this file's copies plus three test
/// display names standing, which is the whole reason a display name counts as a
/// describing sentence. Re-derive with predicates this comment cannot satisfy
/// (`MIS-033`), rather than trusting any integer here:
/// ```
/// rg -c --pcre2 '^(?!\s*(///|//)).*foreignKeyChecks: \.immediate' \
///    TabMail/Services/AppDatabase.swift                                    → 18
/// rg -o '"v([0-9]+)_[A-Za-z0-9_]+"' -r '$1' \
///    TabMail/Services/AppDatabase.swift | sort -n -u | awk '$1>=68' | wc -l → 18
/// ```
/// Equal counts are the invariant: every migration from `v68` up runs
/// `.immediate`, none below `v68` does, and `everyLiveForeignKeyCascades` below
/// checks the premise that licenses it. The top of the chain is now `v85`
/// and the two counts are 18; at 85 registered migrations that leaves 67 still
/// running the whole-database check (66 on the GRDB default plus `v2`, the only
/// explicit `.deferred` left).
///
/// 🚨 **THE PROPERTY PINNED HERE IS THE END STATE, NOT THE MODE TABLE.** A test
/// that asserted "v72 is `.immediate`" would pass on a chain that leaves the
/// database referentially broken, and would fail on a future migration that is
/// correctly re-adjudicated — it would pin the fix's mechanism instead of the
/// system property the mechanism exists to preserve. What matters is that a
/// populated, FK-bearing database that walks the whole chain comes out with zero
/// foreign-key violations.
///
/// The third test is what makes the first non-vacuous. `v82` DROPS and RECREATES
/// `userLabel` and `messageUserLabel` while foreign keys are enforced live, and
/// the failure mode that matters is INVISIBLE TO AN FK-VIOLATION COUNT: a rebuild
/// that repopulates the join table from the wrong source leaves it EMPTY, and an
/// empty child table violates nothing. The end state is perfectly consistent and
/// perfectly empty, every user label chip in the app is gone, and the first test
/// stays green. So the third test asserts the CONTENTS survive and are re-pointed
/// per account — as a total mapping of the pre-migration set, not a row count.
///
/// The fourth test pins the PREMISE the retirement rests on rather than its
/// consequence: every foreign key in the migrated schema is `ON DELETE CASCADE`,
/// read from `PRAGMA foreign_key_list` rather than from a grep of `AppDatabase.swift`
/// (which counts dead DDL, and counted its own recording — `MIS-033`).
///
/// RED EVIDENCE (2026-08-06, `MIS-015`): pointing `v82` step 5 at the live
/// `messageUserLabel` instead of its `_v82_legacy` snapshot fails this test with
/// *"Expected 14, got 0"* while the FK-violation test above it still PASSES.
///
/// ⚠️ WHAT THIS TEST IS **NOT** RED AGAINST, recorded because the comment it
/// replaces claimed otherwise (`MIS-019`). Swapping `v82`'s two `db.drop` calls so
/// the PARENT goes first — the classic implicit-`DELETE FROM` cascade hazard — was
/// built and run: all three tests then present still pass and all 14 memberships
/// survive. The
/// cascade is harmless there because step 2 snapshots both tables BEFORE either
/// drop and nothing afterwards reads the live table. The drop order is the `v2`
/// house pattern, not a safety mechanism; step 2 is the safety mechanism.
///
/// ⚠️ The second test used to assert the OPPOSITE of what it asserts now. It read
/// *"A pre-existing orphan still FAILS the chain, at the v71 whole-database
/// gate"*, and its message said *"v71 is the single whole-database FK gate in
/// this range; if it stopped being `.deferred`, nothing catches a pre-existing
/// orphan at all"*. **Both gates were deliberately retired on 2026-08-06**, so
/// "nothing catches a pre-existing orphan" is now the intended state, and the
/// test asserts the accepted end state instead: the chain COMPLETES, and the
/// orphan is left exactly as found rather than silently swept. The two gates cost
/// 12,083 ms and 7,228 ms of the owner's 27,601 ms device upgrade, guarding
/// bodies that measured 1 ms and 7 ms; the orphan class they ran early to catch
/// is the one `v82` repairs itself. Read the two registration comments in
/// `AppDatabase.swift` for the full argument.
///
/// ⚠️ RETIRED DISPLAY NAME, recorded verbatim so existing citations still grep
/// (`b87804055`'s convention): this suite was
/// **"Migration foreign-key modes (v68…v83)"** until R17b-B3. Only the name
/// changed — no assertion was added, removed or weakened.
@Suite("Migration foreign-key modes (v68 to the top of the chain)")
struct MigrationForeignKeyModeTests {

    // MARK: - Fixture

    private static let v67 = "v67_addUidResolutionRetryCount"

    /// A database migrated only as far as `v67` — the exact shape every existing
    /// device arrives at `v68` on.
    private static func makeV67Database() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: v67)
        return db
    }

    private static func migrateToHead(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db)
    }

    private static func registeredIdentifiers() -> [String] {
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        return migrator.migrations
    }

    private static func appliedIdentifiers(_ db: DatabaseQueue) throws -> Set<String> {
        try db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
    }

    /// Every `(child table, violating rowid, parent table, fk index)` the whole
    /// database still carries. Empty is the invariant.
    private static func foreignKeyViolations(_ db: DatabaseQueue) throws -> [String] {
        try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").map(\.description)
        }
    }

    /// Raw SQL, not the model types: `Draft` carries `lastTouchedSeq` (v79),
    /// `UserLabel` carries `providerLabelId` (v82) and `MessageHeader` carries
    /// `observedUidValidity` (v77) — none of which exist yet at v67, so a model
    /// insert would fail against the very schema this test needs to seed.
    ///
    /// Seeds EVERY foreign-key edge present at v67, on both a provider whose
    /// drafts `v73` rewrites (`imap`) and one it leaves alone (`gmail`):
    /// `account ← {caldavConfig, draft, folder, messageHeader, outboxMessage,
    /// pendingCalendarOperation, userLabel}`, `messageHeader ← {messageBody,
    /// messageReference, messageUserLabel}`, `userLabel ← {messageUserLabel}`.
    private static func seed(_ db: DatabaseQueue) throws {
        try db.write { db in
            for (accountId, provider) in [("acc-imap", "imap"), ("acc-gmail", "gmail")] {
                try db.execute(sql: """
                    INSERT INTO account (id, emailAddress, displayName, provider, createdAt)
                    VALUES (?, ?, 'Test', ?, 1)
                    """, arguments: [accountId, "\(accountId)@example.com", provider])
                try db.execute(sql: """
                    INSERT INTO caldavConfig (id, accountId, serverURL, username, createdAt)
                    VALUES (?, ?, 'https://caldav.example.com', 'user', 1)
                    """, arguments: ["\(accountId):caldav", accountId])
                try db.execute(sql: """
                    INSERT INTO pendingCalendarOperation
                        (id, operationType, accountId, argumentsJSON, createdAt)
                    VALUES (?, 'create', ?, '{}', 1)
                    """, arguments: ["\(accountId):cal-op", accountId])
                try db.execute(sql: """
                    INSERT INTO outboxMessage
                        (id, accountId, toJSON, ccJSON, bccJSON, subject, body, createdAt)
                    VALUES (?, ?, '["to@example.com"]', '[]', '[]', 'subject', 'body', 1)
                    """, arguments: ["\(accountId):outbox", accountId])
                // `pendingOperation` has NO declared FK to `account` at v67 (its
                // `accountId` is a bare TEXT column) — seeded anyway because `v74`
                // deletes every row and `v76`/`v78` alter the table.
                try db.execute(sql: """
                    INSERT INTO pendingOperation
                        (id, type, messageIdsJSON, accountId, folderPath, createdAt)
                    VALUES (?, 'archive', '["1"]', ?, 'INBOX', 1)
                    """, arguments: ["\(accountId):op", accountId])
                // Two drafts: one with a server address (v73 clears it for `imap`
                // accounts only), one purely local.
                try db.execute(sql: """
                    INSERT INTO draft
                        (id, accountId, subject, body, createdAt, updatedAt,
                         serverDraftId, serverPushStatus)
                    VALUES (?, ?, 'draft subject', 'draft body', 1, 2, '42', 'pushed')
                    """, arguments: ["\(accountId):draft-pushed", accountId])
                try db.execute(sql: """
                    INSERT INTO draft
                        (id, accountId, subject, body, createdAt, updatedAt)
                    VALUES (?, ?, 'local draft', 'local body', 1, 2)
                    """, arguments: ["\(accountId):draft-local", accountId])

                // A label that IS applied to messages, and one the user created but
                // never applied — v82 rebuilds `userLabel` and must keep both. These
                // two are per-account and are given distinct ids, so they exercise
                // pure SURVIVAL. The HIJACKED label seeded after this loop exercises
                // the repair itself.
                try db.execute(sql: """
                    INSERT INTO userLabel (id, accountId, name) VALUES (?, ?, 'Applied')
                    """, arguments: ["\(accountId):label-applied", accountId])
                try db.execute(sql: """
                    INSERT INTO userLabel (id, accountId, name) VALUES (?, ?, 'Unapplied')
                    """, arguments: ["\(accountId):label-unapplied", accountId])

                for folderPath in ["INBOX", "Archive"] {
                    let folderId = "\(accountId):\(folderPath)"
                    try db.execute(sql: """
                        INSERT INTO folder (id, accountId, name, path, role)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [
                            folderId, accountId, folderPath, folderPath,
                            folderPath == "INBOX" ? "inbox" : "archive",
                        ])
                    for uid in 1...3 {
                        let headerId = "\(folderId):\(uid)"
                        try db.execute(sql: """
                            INSERT INTO messageHeader
                                (id, folderId, accountId, folderPath, isInInbox, messageId,
                                 rfc822MessageId, subject, `from`, fromAddress, `to`, date,
                                 isRead, actionTag, tagSortOrder)
                            VALUES (?, ?, ?, ?, ?, ?, ?, 'subject',
                                    'sender@example.com', 'sender@example.com',
                                    'recipient@example.com', 1, ?, ?, ?)
                            """, arguments: [
                                headerId, folderId, accountId, folderPath,
                                folderPath == "INBOX", String(uid),
                                "rfc-\(headerId)@example.com",
                                uid == 1, uid == 2 ? "todo" : nil, uid == 2 ? 1 : 99,
                            ])
                        try db.execute(sql: """
                            INSERT INTO messageBody (id, htmlContent, fetchedAt)
                            VALUES (?, '<p>body</p>', 1)
                            """, arguments: [headerId])
                        try db.execute(sql: """
                            INSERT INTO messageReference (messageHeaderId, referencedRfc822Id)
                            VALUES (?, ?)
                            """, arguments: [headerId, "rfc-parent-\(uid)@example.com"])
                        try db.execute(sql: """
                            INSERT INTO messageUserLabel (messageId, userLabelId)
                            VALUES (?, ?)
                            """, arguments: [headerId, "\(accountId):label-applied"])
                    }
                }
            }

            // 🚨 THE HIJACKED LABEL — the defect `v82` exists to repair, seeded so the
            // repair is asserted rather than assumed. At v67 `userLabel.id` is the
            // PRIMARY KEY and is NOT account-scoped, so when two providers hand back
            // the SAME bare label id only ONE row can exist and whichever account
            // synced first owns `accountId`. Here `acc-imap` owns it and `acc-gmail`'s
            // message points at it across the account boundary — which is how the
            // Gmail stale sweep's account-scoped filter could cascade away `acc-imap`'s
            // associations, and how `acc-gmail` rendered `acc-imap`'s name.
            //
            // After `v82` this must become TWO rows, one per account, and each
            // account's membership must point at its own.
            try db.execute(sql: """
                INSERT INTO userLabel (id, accountId, name) VALUES (?, ?, 'Shared')
                """, arguments: ["shared-label", "acc-imap"])
            for accountId in ["acc-imap", "acc-gmail"] {
                try db.execute(sql: """
                    INSERT INTO messageUserLabel (messageId, userLabelId) VALUES (?, ?)
                    """, arguments: ["\(accountId):INBOX:1", "shared-label"])
            }
        }
    }

    // MARK: - 1. The invariant

    /// ⚠️ RETIRED DISPLAY NAME, recorded verbatim (`b87804055`): this test was
    /// **"v68…v83 leave a populated database foreign-key clean"** until R17b-B3.
    /// The body is unchanged — the fixture migrates from `v67` to the top of the
    /// chain, which is what the new name says and what the old name stopped
    /// saying at `v84`.
    @Test("v68 to the top of the chain leaves a populated database foreign-key clean")
    func chainLeavesDatabaseForeignKeyClean() throws {
        let db = try Self.makeV67Database()
        try Self.seed(db)

        // Sanity: the fixture itself is clean, so anything the chain produces is
        // the chain's doing and not the seed's.
        #expect(try Self.foreignKeyViolations(db).isEmpty)

        try Self.migrateToHead(db)

        let violations = try Self.foreignKeyViolations(db)
        #expect(violations.isEmpty, "chain left \(violations.count) FK violation(s): \(violations)")

        let registered = Self.registeredIdentifiers()
        let applied = try Self.appliedIdentifiers(db)
        #expect(applied == Set(registered), "not every registered migration applied")
        #expect(applied.contains("v83_markAllAsReadUnreadSweepIndex"))
    }

    // MARK: - 2. The accepted residual: a pre-existing orphan is walked past

    /// The deliberate END STATE of the 2026-08-06 change, asserted so it is a
    /// decision the tree records rather than an absence a reader has to infer.
    ///
    /// `MIS-026`: **a blessing test and an anchor test are the same artifact seen
    /// from opposite sides, and the way to tell them apart is to ask what breaks if
    /// it goes the other way.** If this ever starts failing because the chain aborts
    /// again, something has re-added a whole-database `PRAGMA foreign_key_check` to
    /// the `.immediate` range — which on the owner's device cost 19,311 ms of a
    /// 27,601 ms upgrade. That is the failure this pins. It does NOT bless orphans: the second
    /// half asserts the orphan is still there afterwards, i.e. the chain walked past
    /// it rather than silently deleting the user's row.
    @Test("A pre-existing orphan no longer aborts the chain, and is left exactly as found")
    func preExistingOrphanIsWalkedPastRatherThanAborting() throws {
        let db = try Self.makeV67Database()
        try Self.seed(db)

        // `messageReference → messageHeader` is the edge to break: it is declared
        // at v27 and NO migration from v68 up rebuilds that table, so nothing in the
        // range repairs it either. (An orphan in `messageBody` would prove nothing —
        // v70 drops the table outright.) Re-derive rather than trust the range:
        //   rg -n 'messageReference' TabMail/Services/AppDatabase.swift
        // → every DDL hit is v27's create; `v84` adds an unrelated column, while
        //   `v85` adds direct-AI columns/index/lifecycle triggers but never rebuilds
        //   or repairs `messageReference`.
        //
        // Foreign keys have to be off to CREATE the orphan, which is the whole
        // point: a real one arrives the same way — written under a schema or a
        // code path that did not enforce the edge.
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: """
                INSERT INTO messageReference (messageHeaderId, referencedRfc822Id)
                VALUES ('acc-imap:INBOX:does-not-exist', 'rfc-orphan@example.com')
                """)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        #expect(try Self.foreignKeyViolations(db).count == 1, "orphan injection did not take")

        var thrown: (any Error)?
        do {
            try Self.migrateToHead(db)
        } catch {
            thrown = error
        }
        #expect(
            thrown == nil,
            """
            the chain aborted on a pre-existing dangling messageReference row: \
            \(String(describing: thrown)). As of 2026-08-06 no migration from v68 up \
            runs a whole-database foreign-key check — both gates were retired because \
            they cost 19,311 ms of the owner's 27,601 ms device upgrade to guard \
            bodies of 1 ms and 7 ms, and their remedy on firing was a launch brick for \
            a condition the next sync repairs. If this failed, a gate came back.
            """)

        let applied = try Self.appliedIdentifiers(db)
        #expect(applied.contains("v83_markAllAsReadUnreadSweepIndex"),
                "the chain must run to completion over the orphan")

        // THE OTHER SIDE, and the reason this is an anchor and not a blessing: the
        // orphan is ACCEPTED, not repaired and not deleted. A chain that silently
        // dropped the row would also pass the assertion above, and would be
        // destroying a row on a schema-upgrade path.
        let remaining = try Self.foreignKeyViolations(db)
        #expect(remaining.count == 1,
                """
                the orphan should survive untouched — it renders nothing, loses \
                nothing, and the next sync re-supplies it. \(remaining.count) \
                violation(s) found: \(remaining)
                """)
        let orphanSurvives = try db.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM messageReference
                    WHERE messageHeaderId = 'acc-imap:INBOX:does-not-exist'
                )
                """) ?? false
        }
        #expect(orphanSurvives, "the chain deleted a row it was only asked to walk past")
    }

    // MARK: - 3. v82 must not lose the user's label memberships

    /// 🚨 **THE SYSTEM PROPERTY, not the mechanism: a schema upgrade may not lose a
    /// single user label membership.** `v82` drops and recreates BOTH `userLabel`
    /// and `messageUserLabel` under `foreignKeyChecks: .immediate`, then repopulates
    /// them from the snapshots step 2 took. If that repopulation goes wrong the join
    /// table comes out EMPTY, and an empty child table is **foreign-key clean** — so
    /// `chainLeavesDatabaseForeignKeyClean` above still passes while every label chip
    /// in the app has silently disappeared. Only contents can catch it.
    ///
    /// RED EVIDENCE (Testing rule 12, `MIS-015` — the invariant, not the mechanism):
    /// with step 5 re-sourced from the live `messageUserLabel` instead of
    /// `messageUserLabel_v82_legacy`, this test fails with *"Expected 14, got 0"*
    /// while the FK-violation test passes. Measured 2026-08-06.
    ///
    /// ⚠️ It is NOT red against swapping the two `db.drop` calls — that was tried and
    /// all three tests then present still pass, because step 2's snapshots make the cascade
    /// harmless. See the suite doc; the previous version of this comment asserted the
    /// opposite on inherited reasoning and was never measured.
    ///
    /// It also pins the REPAIR, which is the reason `v82` exists: two accounts that
    /// share a bare provider label id shared ONE row before v82, and afterwards each
    /// has its own `"<accountId>:<providerLabelId>"` row with its own account.
    @Test("v82 preserves every label membership and re-points it at its own account")
    func v82PreservesLabelMembershipsAcrossTheRebuild() throws {
        let db = try Self.makeV67Database()
        try Self.seed(db)

        // The fixture seeds, per account, one applied label and one the user created
        // but never applied, plus 6 headers each carrying the applied label — and ONE
        // hijacked label owned by `acc-imap` that both accounts' INBOX message 1
        // points at.
        //
        // ANCHOR THE FIXTURE'S CARDINALITY BEFORE THE ACT (`MIS-030`): a seed that
        // silently produced zero memberships would make every "nothing was lost"
        // assertion below pass over an empty set.
        let before: [(messageId: String, userLabelId: String)] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT messageId, userLabelId FROM messageUserLabel
                ORDER BY messageId, userLabelId
                """).map { ($0["messageId"], $0["userLabelId"]) }
        }
        let labelsBefore: [(id: String, accountId: String)] = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, accountId FROM userLabel ORDER BY id")
                .map { ($0["id"], $0["accountId"]) }
        }
        #expect(before.count == 14,
                "fixture cardinality: 2 accounts × 2 folders × 3 headers, + 2 hijacked")
        #expect(labelsBefore.count == 5,
                "fixture cardinality: 2 accounts × (applied + unapplied) + 1 hijacked")
        #expect(before.filter { $0.userLabelId == "shared-label" }.count == 2,
                "the hijacked label must be referenced from BOTH accounts, or the repair is untested")

        try Self.migrateToHead(db)

        // 1. NOTHING WAS LOST, AND EVERY MEMBERSHIP IS RE-POINTED AT ITS OWN
        //    ACCOUNT'S ROW. The rebuilt id is `"<accountId>:<providerLabelId>"` where
        //    the account is the OWNING MESSAGE's — that re-pointing is the
        //    cross-account collision `v82` exists to fix, and it is asserted as a
        //    total mapping of the pre-migration set rather than as a row count.
        let expected = before.map { row -> String in
            let owningAccount = row.messageId.components(separatedBy: ":").first ?? ""
            return "\(row.messageId)|\(owningAccount):\(row.userLabelId)"
        }.sorted()
        let after = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT messageId, userLabelId FROM messageUserLabel
                ORDER BY messageId, userLabelId
                """).map { "\($0["messageId"] as String)|\($0["userLabelId"] as String)" }
        }.sorted()
        #expect(after == expected,
                """
                v82 did not preserve-and-re-point the label memberships. Expected \
                \(expected.count), got \(after.count). A rebuild that loses them leaves \
                a database that is STILL foreign-key clean — an empty join table \
                violates nothing — so the sibling violation-count test in this suite \
                cannot see this failure. That is why the assertion is a total mapping \
                of the pre-migration set and not a violation count.
                """)

        // 2. THE LABEL SET IS EXACTLY THE UNION OF (a) EVERY LEGACY ROW UNDER ITS OWN
        //    ACCOUNT — step 3b, which is why a label the user CREATED BUT NEVER
        //    APPLIED survives at all — and (b) EVERY (owning account, label) PAIR THE
        //    ASSOCIATIONS REFERENCE, step 3a, which is the repair. Derived from the
        //    before-snapshot rather than written out, so it cannot drift from the seed.
        let expectedPairs = Set(
            labelsBefore.map { "\($0.accountId)|\($0.id)" }
                + before.map { "\($0.messageId.components(separatedBy: ":").first ?? "")|\($0.userLabelId)" })
        let labels: [(id: String, accountId: String, providerLabelId: String)] = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, accountId, providerLabelId FROM userLabel ORDER BY id
                """).map { ($0["id"], $0["accountId"], $0["providerLabelId"]) }
        }
        #expect(Set(labels.map { "\($0.accountId)|\($0.providerLabelId)" }) == expectedPairs,
                """
                the rebuilt label set is not the union of the legacy rows and the \
                referenced pairs — expected \(expectedPairs.count) rows, got \(labels.count)
                """)
        for label in labels {
            #expect(label.id == "\(label.accountId):\(label.providerLabelId)",
                    "\(label.id) is not the deterministic account-scoped surrogate")
        }

        // 3. THE HIJACKED LABEL IS SPLIT — the whole reason `v82` exists. One v67 row
        //    owned by `acc-imap`, referenced across the account boundary, must become
        //    one row PER ACCOUNT, each carrying the bare provider value verbatim in
        //    `providerLabelId` (never re-parsed out of the id, which may contain ':').
        let shared = labels.filter { $0.providerLabelId == "shared-label" }
        #expect(Set(shared.map(\.accountId)) == ["acc-imap", "acc-gmail"],
                """
                the shared v67 row was not split per account — v82's entire purpose. \
                Got \(shared.count) row(s): \(shared.map(\.id).sorted())
                """)

        // 4. And the end state is referentially clean, so 1–3 are not describing a
        //    database that merely happens to look right.
        #expect(try Self.foreignKeyViolations(db).isEmpty)
    }

    // MARK: - 4. The premise the retired gates rested on

    /// 🚨 **THE ARGUMENT THAT RETIRED BOTH WHOLE-DATABASE GATES, measured over the
    /// LIVE SCHEMA instead of over the source text.** `v71` and `v82` dropped their
    /// `PRAGMA foreign_key_check` on the grounds that orphans are structurally
    /// prevented: foreign keys are enforced live (`AppDatabase.makeConfiguration`
    /// sets `foreignKeysEnabled = true`) and every declared edge cascades, so
    /// deleting a parent takes its children with it and no application path can
    /// strand one. That premise buys 19,311 ms of the owner's 27,601 ms device
    /// upgrade, and until now it was only ever checked by grepping `AppDatabase.swift`.
    ///
    /// A grep cannot carry it, for two independent reasons. It counts **dead DDL** —
    /// 16 `.references("` declarations for 10 live edges, because `v1`'s
    /// `messageHeader → folder` was dropped by `v2`, `messageBody → messageHeader` is
    /// spelled twice and dropped by `v70`, and `v82`'s rebuild re-spells the three
    /// label edges `v33` created. And it counts **its own recording**: the `v71`
    /// banner quotes the search token, so its "19 lines, 3 of which are prose"
    /// arithmetic was wrong from the day it was written, when the file held 20 and 4
    /// (`MIS-033`). `PRAGMA foreign_key_list` over a migrated database has neither
    /// failure mode.
    ///
    /// The EDGE SET is a staleness tripwire for that banner; the CASCADE is the
    /// invariant. If a migration adds or retargets an edge this fails on the set
    /// first — re-derive the census in `AppDatabase.swift`'s `v71` retirement
    /// comment, then update the roster here.
    @Test("Every foreign key in the migrated schema is ON DELETE CASCADE")
    func everyLiveForeignKeyCascades() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        try Self.migrateToHead(db)

        let edges: [(child: String, parent: String, onDelete: String)] = try db.read { db in
            var found: [(child: String, parent: String, onDelete: String)] = []
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
            for table in tables {
                let rows = try Row.fetchAll(
                    db, sql: "PRAGMA foreign_key_list(\(table.quotedDatabaseIdentifier))")
                for row in rows {
                    let parent: String = row["table"]
                    let onDelete: String = row["on_delete"]
                    found.append((child: table, parent: parent, onDelete: onDelete))
                }
            }
            return found
        }

        // THE INVARIANT.
        let uncascaded = edges.filter { $0.onDelete.uppercased() != "CASCADE" }
        #expect(
            uncascaded.isEmpty,
            """
            \(uncascaded.count) foreign key(s) do not cascade: \
            \(uncascaded.map { "\($0.child) -> \($0.parent) ON DELETE \($0.onDelete)" }.sorted()). \
            v71 and v82 retired their whole-database foreign-key gates on the argument \
            that orphans are structurally impossible. A non-cascading edge makes that \
            argument false: deleting a parent strands a child that nothing now checks for.
            """)

        // THE TRIPWIRE, which is also what makes the assertion above non-vacuous
        // (`MIS-030`): an empty or mis-shaped query would satisfy `uncascaded.isEmpty`
        // while proving nothing about the schema.
        #expect(
            Set(edges.map { "\($0.child) -> \($0.parent)" }) == [
                "caldavConfig -> account",
                "draft -> account",
                "folder -> account",
                "messageHeader -> account",
                "messageReference -> messageHeader",
                "messageUserLabel -> messageHeader",
                "messageUserLabel -> userLabel",
                "outboxMessage -> account",
                "pendingCalendarOperation -> account",
                "userLabel -> account",
            ],
            """
            the live schema declares \(edges.count) foreign key(s), not the 10 the v71 \
            retirement comment enumerates: \(edges.map { "\($0.child) -> \($0.parent)" }.sorted()). \
            Re-derive that census with PRAGMA foreign_key_list, update the comment, then \
            update this roster.
            """)
    }
}
