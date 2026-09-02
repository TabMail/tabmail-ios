/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Everything but the comments.
///
/// The one content assertion left in this file — `assertScanOrder`'s check that
/// production still issues the SQL these tests replay — must not be satisfiable
/// from a comment. `// was "SELECT id, emailAddress, calendarOnly FROM account"`
/// is exactly what someone changing that query writes, and against the raw file
/// it satisfied the pin while production had already moved on.
private func code(_ source: String) -> String {
    source.components(separatedBy: "\n").map { line -> String in
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return "" }
        var search = line.startIndex
        while let marker = line.range(of: "//", range: search..<line.endIndex) {
            // A `://` scheme is not a comment marker; keep looking past it.
            if marker.lowerBound > line.startIndex,
               line[line.index(before: marker.lowerBound)] == ":" {
                search = marker.upperBound
                continue
            }
            return String(line[..<marker.lowerBound])
        }
        return line
    }.joined(separator: "\n")
}

/// Invariant: **an account that exists in the database is resolvable through
/// the shared identity mirrors.**
///
/// The notification extension cannot read the main database. `nse.accountMap`
/// (address → account id) and `nse.imapAccounts` (account id → host/port/
/// username) are the only way it can turn a push into an account, so an
/// account missing from either mirror is invisible to it: the IMAP reconnect
/// handler returns before it can re-subscribe, and the server-side retry
/// ladder then runs to exhaustion. The mirrors are pure derived state, and
/// `NSEDataBridge.mirrorAccountIdentity()` is the single re-derivation every
/// durable writer of a mirrored column is expected to call.
///
/// Each test is two-sided on purpose: it first shows the account is NOT
/// resolvable through a stale mirror, then that one re-derivation makes it so.
/// A one-sided assertion would pass against a mirror that happened to be
/// correct for an unrelated reason.
///
/// The decode below deliberately mirrors the extension's own parse. `NSEState`
/// is not compiled into this target, so the readers are reimplemented here —
/// but they are keyed off `SharedNSEData`, which *is*, so the writer's key
/// literals and the extension's key constants are asserted against each other
/// rather than assumed equal. The JSON *shape* remains coupled by convention.
///
/// ⚠️ NOT COVERED HERE: the production call sites themselves. These tests drive
/// `mirrorAccountIdentity(defaults:)` directly, so they prove the helper
/// re-derives both mirrors — and the helper was never broken. The shipped defect
/// was that `addIMAPAccount` and `addICloudAccount` called neither half and
/// `activateMailAccount` called one. **Delete the three production call sites
/// and every test in this suite still passes.**
///
/// That half of the invariant is deliberately unpinned. The add paths cannot be
/// driven from a unit test: `addIMAPAccount` opens a live IMAP connection before
/// it writes anything, SwiftMail rejects a non-993/143 port without an explicit
/// transport-security argument the production API does not take, `ICloudConfig`'s
/// host and port are constants, and both paths end with an escaped initial-sync
/// `Task` that would outlive the test. Covering them needs two production
/// parameters that exist only for tests, which is a change to a
/// production-critical actor and is not in scope here.
///
/// A source-reading suite used to assert the call sites by parsing the
/// production `.swift` files. It was removed: across eight review rounds it
/// never found a production defect and repeatedly reported clean while the
/// property it claimed to pin was violated — most recently a caller census that
/// missed every qualified call because Swift's `\b` uses Unicode word
/// boundaries, where the `.` in `NSEDataBridge.mirrorAccountMap` is not a break.
/// A test that is confidently wrong about the thing it exists to check is worse
/// than a documented gap. See `IOS-NSE-008`.
///
/// `.serialized` because the suite swaps the process-global `AppDatabase`.
/// `.serialized` because the suite swaps the process-global `AppDatabase`.
@Suite("NSEAccountIdentityMirror", .serialized, .processGlobalState)
struct NSEAccountIdentityMirrorTests {

    // MARK: - Mirror readers (the extension's view)

    private func resolvedAccountId(for email: String, in defaults: UserDefaults) throws -> String? {
        guard let json = defaults.string(forKey: SharedNSEData.accountMapKey) else { return nil }
        let map = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        return map[email]
    }

    private func imapEntry(for accountId: String, in defaults: UserDefaults) throws -> [String: Any]? {
        guard let json = defaults.string(forKey: SharedNSEData.imapAccountsKey) else { return nil }
        let map = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]]
        return map?[accountId]
    }

    // MARK: - Harness

    /// Installs a temp file-backed `AppDatabase.shared` plus an isolated
    /// defaults suite, seeds `accounts`, and hands both to `body`. Nothing
    /// here touches the real App Group container.
    private func withHarness(
        accounts: [Account],
        body: (UserDefaults, DatabasePool) async throws -> Void
    ) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path, configuration: config)
        defer { TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let appDb = try AppDatabase(dbPool: pool)

        let previousDb = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        defer { AppDatabase.shared.withLock { $0 = previousDb } }

        try await pool.write { db in
            for account in accounts {
                try account.insert(db)
            }
        }

        let suiteName = "NSEAccountIdentityMirrorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try await body(defaults, pool)
    }

    private func imapAccount(
        id: String,
        email: String,
        host: String,
        port: Int = 993,
        username: String? = nil,
        provider: AccountProvider = .imap
    ) -> Account {
        var account = Account(emailAddress: email, displayName: email, provider: provider)
        account.id = id
        account.imapHost = host
        account.imapPort = port
        account.imapUsername = username
        return account
    }

    // MARK: - Tests

    /// The account-add case. A mirror written before the account existed does
    /// not name it — and that is the state a reconnect push would arrive into,
    /// because the extension has nothing else to resolve the address against.
    @Test("A newly added IMAP account is unresolvable until the mirrors are re-derived")
    func newIMAPAccountBecomesResolvableAfterRefresh() async throws {
        let added = imapAccount(id: "added-id", email: "added@example.com", host: "mail.example.com", username: "added-user")

        try await withHarness(accounts: [added]) { defaults, _ in
            // A mirror pass that predates the add: valid JSON, just not naming
            // this account. This is the state after a launch-time refresh
            // followed by an account add that never refreshed.
            defaults.set("{}", forKey: SharedNSEData.accountMapKey)
            defaults.set("{}", forKey: SharedNSEData.imapAccountsKey)

            let staleId = try resolvedAccountId(for: "added@example.com", in: defaults)
            let staleEntry = try imapEntry(for: "added-id", in: defaults)
            #expect(staleId == nil)
            #expect(staleEntry == nil)

            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)

            let freshId = try resolvedAccountId(for: "added@example.com", in: defaults)
            #expect(freshId == "added-id")
            let entryOpt = try imapEntry(for: "added-id", in: defaults)
            let entry = try #require(entryOpt)
            #expect(entry["host"] as? String == "mail.example.com")
            #expect(entry["port"] as? Int == 993)
            #expect(entry["username"] as? String == "added-user")
        }
    }

    /// iCloud mail rides the same IMAP path, so it has to reach the same
    /// mirror. Pinning it separately because it is added through its own
    /// code path.
    @Test("An added iCloud account reaches the IMAP mirror like a generic IMAP account")
    func icloudAccountReachesTheIMAPMirror() async throws {
        let added = imapAccount(
            id: "icloud-id",
            email: "person@example.com",
            host: "imap.example.com",
            username: "person@example.com",
            provider: .icloud
        )

        try await withHarness(accounts: [added]) { defaults, _ in
            defaults.set("{}", forKey: SharedNSEData.accountMapKey)
            defaults.set("{}", forKey: SharedNSEData.imapAccountsKey)

            let staleEntry = try imapEntry(for: "icloud-id", in: defaults)
            #expect(staleEntry == nil)

            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)

            let freshId = try resolvedAccountId(for: "person@example.com", in: defaults)
            #expect(freshId == "icloud-id")
            let entryOpt = try imapEntry(for: "icloud-id", in: defaults)
            let entry = try #require(entryOpt)
            #expect(entry["host"] as? String == "imap.example.com")
        }
    }

    /// The edit case for the address column. A mirror keyed on the previous
    /// address resolves the wrong thing (or nothing) for every later push.
    @Test("An address change re-keys the account map and retires the old address")
    func addressChangeRekeysTheAccountMap() async throws {
        let account = imapAccount(id: "edit-id", email: "before@example.com", host: "mail.example.com", username: "shared-user")

        try await withHarness(accounts: [account]) { defaults, pool in
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)
            let beforeEdit = try resolvedAccountId(for: "before@example.com", in: defaults)
            #expect(beforeEdit == "edit-id")

            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE account SET emailAddress = ? WHERE id = ?",
                    arguments: ["after@example.com", "edit-id"]
                )
            }

            // Still the pre-edit mirror: the new address resolves to nothing.
            let staleNewAddress = try resolvedAccountId(for: "after@example.com", in: defaults)
            #expect(staleNewAddress == nil)

            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)

            let freshNewAddress = try resolvedAccountId(for: "after@example.com", in: defaults)
            let retiredOldAddress = try resolvedAccountId(for: "before@example.com", in: defaults)
            #expect(freshNewAddress == "edit-id")
            #expect(retiredOldAddress == nil)
        }
    }

    /// The edit case for the IMAP username column. A stale username is worse
    /// than a missing entry: the extension proceeds and authenticates with a
    /// credential the server no longer accepts.
    @Test("An IMAP username change reaches the connection mirror")
    func imapUsernameChangeReachesTheMirror() async throws {
        let account = imapAccount(id: "user-id", email: "person@example.com", host: "mail.example.com", username: "old-user")

        try await withHarness(accounts: [account]) { defaults, pool in
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)
            let initial = try imapEntry(for: "user-id", in: defaults)?["username"] as? String
            #expect(initial == "old-user")

            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE account SET imapUsername = ? WHERE id = ?",
                    arguments: ["new-user", "user-id"]
                )
            }

            let stale = try imapEntry(for: "user-id", in: defaults)?["username"] as? String
            #expect(stale == "old-user")

            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)

            let fresh = try imapEntry(for: "user-id", in: defaults)?["username"] as? String
            #expect(fresh == "new-user")
        }
    }

    /// The re-derivation must not become "mirror everything into both maps".
    /// The two halves filter differently on purpose: `mirrorAccountMap` takes
    /// every row, because the extension needs the full address set, while
    /// `mirrorIMAPAccounts` admits only `provider IN ('imap','icloud')` with a
    /// non-empty host. An OAuth provider therefore belongs in the address map
    /// and nowhere else — an IMAP entry for it would make the extension open a
    /// socket it cannot open. This is the same asymmetry the calendar-only
    /// precedence tests below cover from the other side, where a row that is
    /// legitimately in one map must not take an address away from a row that
    /// needs to be in both.
    @Test("A provider without IMAP configuration is mapped by address only")
    func nonIMAPAccountIsMappedByAddressOnly() async throws {
        var oauth = Account(emailAddress: "oauth@example.com", displayName: "OAuth", provider: .gmail)
        oauth.id = "oauth-id"
        let imap = imapAccount(id: "imap-id", email: "imap@example.com", host: "mail.example.com")

        try await withHarness(accounts: [oauth, imap]) { defaults, _ in
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)

            let oauthId = try resolvedAccountId(for: "oauth@example.com", in: defaults)
            let imapId = try resolvedAccountId(for: "imap@example.com", in: defaults)
            #expect(oauthId == "oauth-id")
            #expect(imapId == "imap-id")

            let oauthEntry = try imapEntry(for: "oauth-id", in: defaults)
            let imapEntryValue = try imapEntry(for: "imap-id", in: defaults)
            #expect(oauthEntry == nil)
            #expect(imapEntryValue != nil)
        }
    }

    /// With no username configured the extension must authenticate as the
    /// address, matching the main app's own IMAP setup. A blank username here
    /// would fail every login the extension attempts.
    @Test("An account with no IMAP username falls back to its address")
    func missingIMAPUsernameFallsBackToTheAddress() async throws {
        let account = imapAccount(id: "fallback-id", email: "fallback@example.com", host: "mail.example.com", username: nil)

        try await withHarness(accounts: [account]) { defaults, _ in
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)

            let entryOpt = try imapEntry(for: "fallback-id", in: defaults)
            let entry = try #require(entryOpt)
            #expect(entry["username"] as? String == "fallback@example.com")
        }
    }
    /// 🚨 A calendar-only row must NEVER own a mail account's address in
    /// `nse.accountMap`. The map is address-keyed and is the extension's only
    /// resolver, while `nse.imapAccounts` is filtered by provider — so a
    /// calendar row that wins an address gives the extension an id it resolves
    /// but has no connection info for, and every push for that address
    /// dead-ends without re-subscribing, permanently.
    ///
    /// Reachable with no concurrency at all: `addCalDAVAccount` stores the
    /// CalDAV *username* as `emailAddress`, that username is conventionally the
    /// user's mail address, and it runs no cross-provider duplicate check. This
    /// is the property the calendar-only exemption rests on, so it is pinned
    /// rather than assumed.
    ///
    /// Both insertion orders, because before the fix the winner was decided by
    /// scan order — which is arbitrary, and happened to favour whichever row
    /// was written last.
    @Test("A calendar-only row never displaces a mail account sharing its address")
    func calendarOnlyRowNeverDisplacesAMailAccount() async throws {
        let shared = "person@example.com"
        let mail = imapAccount(id: "mail-id", email: shared, host: "mail.example.com")
        var calendar = Account(emailAddress: shared, displayName: "Calendar", provider: .caldav)
        calendar.id = "calendar-id"
        calendar.calendarOnly = true

        // Calendar row inserted LAST — the losing order before the fix.
        try await withHarness(accounts: [mail, calendar]) { defaults, pool in
            try assertScanOrder(["mail-id", "calendar-id"], in: pool)
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)
            let resolved = try resolvedAccountId(for: shared, in: defaults)
            #expect(resolved == "mail-id",
                    "the calendar row won the address; the extension can resolve it but has no IMAP config for it")
            let entry = try imapEntry(for: "mail-id", in: defaults)
            #expect(entry != nil)
        }

        // Calendar row inserted FIRST — precedence must not depend on order.
        try await withHarness(accounts: [calendar, mail]) { defaults, pool in
            try assertScanOrder(["calendar-id", "mail-id"], in: pool)
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)
            let resolved = try resolvedAccountId(for: shared, in: defaults)
            #expect(resolved == "mail-id")
        }
    }

    /// The two arms above are only two arms if `mirrorAccountMap`'s unordered
    /// `SELECT … FROM account` actually returns the rows in the order the
    /// harness inserted them. It does — `account` is a rowid table — but that is
    /// an assumption about SQLite, not about our code, and an assumption a
    /// silent change would collapse: both arms would then exercise the SAME
    /// order and the one the comment calls "the losing order before the fix"
    /// would quietly stop existing, with the setup still faithfully performed.
    /// Assert it rather than rely on it.
    ///
    /// ⚠️ The probe MUST select the same columns as `mirrorAccountMap`, and the
    /// first version of this helper did not — it used `SELECT id FROM account`,
    /// which the `id` primary-key index COVERS, so SQLite answered it from the
    /// index in id order while production's three-column query does a table
    /// scan in rowid order. The two disagreed and the assertion failed against
    /// correct code. An instrument that does not share the plan it is measuring
    /// is measuring something else.
    private func assertScanOrder(_ expected: [String], in pool: DatabasePool) throws {
        // The probe must issue the SAME query production issues, or it measures
        // a different plan. An earlier version selected `id` alone — covered by
        // the primary-key index, so it scanned in id order while production
        // table-scans in rowid order — and went red against correct code. Pin
        // the literal, because the remaining drift is fail-OPEN: if production
        // later adds a column, a WHERE, an ORDER BY or a covering index, this
        // probe would keep asserting its OWN scan order and quietly certify a
        // suite that no longer exercises two distinct production orders.
        let sql = "SELECT id, emailAddress, calendarOnly FROM account"
        let bridgeSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TabMail/Services/NSEDataBridge.swift"),
            encoding: .utf8
        )
        // Comment-stripped and quote-delimited, because the naive
        // `contains(sql)` was fail-open in BOTH directions, measured: appending
        // ` ORDER BY id` or ` WHERE isActive = 1` to production's query left it
        // green (substring containment, not identity) while production stopped
        // scanning in rowid order — collapsing the precedence test's two
        // insertion orders into one; and the raw file matches the literal
        // inside a doc comment quoting the PREVIOUS query, which is exactly what
        // someone changing the query writes. The closing quote is what turns
        // containment into identity.
        // ⚠️ This pins the literal's SPELLING, not only its content, and that is
        // deliberate but worth knowing: rewriting the identical query as a `"""`
        // multi-line literal — the form `mirrorIMAPAccounts` already uses in the
        // same file — turns this red on a change that alters nothing. That is the
        // safe direction (the fix is to update both together, which is what the
        // message says), and it is the price of matching with both delimiting
        // quotes. Containment without them was satisfied by an appended
        // `ORDER BY`, and containment against the raw file was satisfied by a
        // comment quoting the previous query.
        let bridgeCode = code(bridgeSource)
        #expect(bridgeCode.contains("\"\(sql)\""), """
            NSEDataBridge no longer issues exactly `\(sql)`. This probe \
            reproduces production's scan order only while the two queries are \
            identical — an added column, WHERE or ORDER BY changes production's \
            plan and not this one — so update both together or the precedence \
            arms stop being two distinct orders.
            """)
        let observed = try pool.read { db in
            try Row.fetchAll(db, sql: sql).compactMap { $0["id"] as String? }
        }
        #expect(observed == expected, """
            the unordered account scan returned \(observed) rather than \
            \(expected), so this test's two insertion orders are no longer two \
            distinct orders. Re-establish the ordering the arms depend on.
            """)
    }

    /// The precedence rule must not *evict* a calendar-only address that no mail
    /// account claims: the extension's `getAllAccountEmails()` feeds the
    /// recipient-status suppress set, and dropping addresses there would change
    /// AI classification. Guard the consequence, not the mechanism.
    @Test("A calendar-only address with no mail account still reaches the map")
    func calendarOnlyAddressWithoutAMailAccountIsStillMapped() async throws {
        var calendar = Account(emailAddress: "calendar@example.com", displayName: "Calendar", provider: .caldav)
        calendar.id = "calendar-only-id"
        calendar.calendarOnly = true
        let mail = imapAccount(id: "mail-id", email: "person@example.com", host: "mail.example.com")

        try await withHarness(accounts: [calendar, mail]) { defaults, _ in
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)
            let resolved = try resolvedAccountId(for: "calendar@example.com", in: defaults)
            #expect(resolved == "calendar-only-id")
            // The twin of the assertion round 5 struck from the removal test —
            // "and it still cannot supply connection info" — is deliberately NOT
            // here. Three independent mechanisms exclude a `.caldav` row from
            // `nse.imapAccounts` (the provider clause, the host clause, and the
            // `guard let host` in the loop), two of them are pinned separately
            // one clause at a time, and no single production edit makes it fire.
        }
    }

    /// 🚨 REGRESSION, found by the review gate: **removing one account must not
    /// make a DIFFERENT, surviving account unresolvable.**
    ///
    /// `removeAccountFromMirrors` drops an entry whose KEY matches the removed
    /// address as well as one whose VALUE is the removed id. That was tolerable
    /// while the shared key usually belonged to the row being removed; the
    /// mail-over-calendar precedence rule inverts it, so the shared key now
    /// belongs to the SURVIVOR and the removal takes it with it. The survivor is
    /// then invisible to the extension — `findAccountId` misses, the reconnect
    /// handler returns without re-subscribing — which is the very defect this
    /// whole change exists to close, reached through the removal door.
    ///
    /// The invariant asserted is the system property, not the fix's mechanism:
    /// *after a removal settles, every account still in the database resolves.*
    /// A test pinning "removeAccount calls mirrorAccountIdentity" would go green
    /// on any call, including one placed where it cannot help.
    /// 🚨 The address map is keyed on the RAW stored address, deliberately, and
    /// the tempting "make it consistent" fix is what breaks it.
    /// `NSEState.findAccountId` is an exact `map[email]` lookup, so a key the
    /// extension cannot spell is a key it cannot use — while
    /// `Account.existing(forEmail:provider:in:)`, cited two lines away in the
    /// same file, case-FOLDS. Folding here would collapse a case-variant pair
    /// into one slot and leave one account resolvable nowhere: the exact defect
    /// class this whole change closes, arriving through the "make it consistent
    /// with the sibling" door. The mail-over-calendar precedence rule is scoped
    /// to exact keys for the same reason — it only has to arbitrate rows that
    /// share a key the reader can actually hit.
    @Test("Addresses differing only in case keep distinct map keys")
    func caseVariantAddressesKeepDistinctMapKeys() async throws {
        let mail = imapAccount(id: "mail-id", email: "Person@example.com", host: "mail.example.com")
        var calendar = Account(emailAddress: "person@example.com", displayName: "Calendar", provider: .caldav)
        calendar.id = "calendar-id"
        calendar.calendarOnly = true
        // A SECOND pair with the cases the other way round, because the roles
        // are asymmetric and a one-sided fixture does not discriminate. Folding
        // only the precedence SET — inserting and testing `mailOwnedAddresses`
        // case-insensitively while leaving the key raw — leaves both keys of the
        // first pair present and the test green, while a calendar row at a
        // case-variant of a mail address stops being mapped at all. With the
        // mixed-case row on the CALENDAR side, that fold suppresses
        // `Other@example.com` and this test sees it.
        let lowerMail = imapAccount(id: "lower-mail-id", email: "other@example.com", host: "mail.example.com")
        var upperCalendar = Account(emailAddress: "Other@example.com", displayName: "Calendar 2", provider: .caldav)
        upperCalendar.id = "upper-calendar-id"
        upperCalendar.calendarOnly = true

        try await withHarness(accounts: [mail, calendar, lowerMail, upperCalendar]) { defaults, _ in
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)

            let mailKey = try resolvedAccountId(for: "Person@example.com", in: defaults)
            let calendarKey = try resolvedAccountId(for: "person@example.com", in: defaults)
            let lowerMailKey = try resolvedAccountId(for: "other@example.com", in: defaults)
            let upperCalendarKey = try resolvedAccountId(for: "Other@example.com", in: defaults)
            #expect(mailKey == "mail-id", """
                a mail account's own stored address no longer resolves to it. If \
                the map is keyed case-insensitively, the extension's exact \
                `map[email]` lookup can no longer reach whichever row lost the \
                slot, and its reconnect pushes dead-end without re-subscribing.
                """)
            #expect(calendarKey == "calendar-id", """
                two addresses differing only in case collapsed into ONE map key, \
                so one account is resolvable nowhere. Mail-over-calendar \
                precedence arbitrates rows that share a key EXACTLY; it must not \
                become a case-folding merge, and the map must not be re-keyed to \
                match `Account.existing`, which folds.
                """)
            #expect(lowerMailKey == "lower-mail-id",
                    "a mail account lost its slot to a case-variant calendar row")
            #expect(upperCalendarKey == "upper-calendar-id", """
                a calendar row at a case-VARIANT of a mail address was suppressed \
                from the map. Mail-over-calendar precedence arbitrates rows that \
                share a key exactly; folding the precedence set alone — while \
                leaving the key raw — makes it swallow a row that never contended, \
                and shrinks `getAllAccountEmails()`'s recipient-status suppress set \
                with it.
                """)
        }
    }

    @Test("Removing one of two accounts sharing an address leaves the survivor resolvable")
    func removingOneOfTwoAccountsSharingAnAddressLeavesTheSurvivorResolvable() async throws {
        let shared = "person@example.com"
        let mail = imapAccount(id: "mail-id", email: shared, host: "mail.example.com")
        var calendar = Account(emailAddress: shared, displayName: "Calendar", provider: .caldav)
        calendar.id = "calendar-id"
        calendar.calendarOnly = true

        // A third account at an unrelated address, present only so the
        // mid-state below can DISCRIMINATE. Without it, "the shared key is
        // gone" is equally satisfied by a regression that destroys the whole
        // map — and `removeAccountFromMirrors` really does have a branch that
        // drops the entire `nse.accountMap` key on a decode failure.
        let other = imapAccount(id: "other-id", email: "other@example.com", host: "mail.example.com")

        try await withHarness(accounts: [mail, calendar, other]) { defaults, pool in
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)
            #expect(try resolvedAccountId(for: shared, in: defaults) == "mail-id")
            #expect(try resolvedAccountId(for: "other@example.com", in: defaults) == "other-id")

            // The removal path, in its production order: clear the mirrors
            // BEFORE the authoritative delete, then delete the row.
            NSEDataBridge.removeAccountFromMirrors(
                accountId: "calendar-id",
                email: shared,
                defaults: defaults
            )
            try await pool.write { db in
                try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: ["calendar-id"])
            }

            // TWO-SIDED, and discriminating. The shared key is gone — the
            // survivor is collateral damage from clearing by ADDRESS — while an
            // unrelated account's key is untouched. The second half is what
            // makes the first half mean something: a regression that wiped the
            // whole map would satisfy "the survivor is not resolvable" too.
            //
            // ⚠️ This first assertion characterises the CURRENT clearing, not a
            // system invariant: narrowing `removeAccountFromMirrors` to
            // `value != accountId` (a considered, rejected alternative) would
            // stop stranding the survivor and this line would then be the thing
            // to update. The durable invariants are the other three — the
            // unrelated account survives throughout, the removed account is
            // never resolvable after its delete, and the survivor resolves once
            // the convergence has run.
            let strandedBeforeConvergence = try resolvedAccountId(for: shared, in: defaults)
            #expect(strandedBeforeConvergence == nil, """
                the pre-commit mirror clearing no longer strands the survivor, so \
                the convergence this test is about has nothing to repair and the \
                assertion below proves nothing. Re-establish the two sides.
                """)
            #expect(try resolvedAccountId(for: "other@example.com", in: defaults) == "other-id", """
                clearing the mirrors for one account removed an UNRELATED \
                account's entry. The clearing is keyed on the removed address \
                and id; nothing else may be collateral.
                """)

            // What `removeAccount` now does once the delete commits, before
            // it tears the account's runtime down.
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)

            let resolved = try resolvedAccountId(for: shared, in: defaults)
            #expect(resolved == "mail-id", """
                a surviving account is unresolvable to the notification extension \
                after a DIFFERENT account at the same address was removed; its \
                reconnect pushes will dead-end without re-subscribing.
                """)
            #expect(try imapEntry(for: "mail-id", in: defaults) != nil)
            #expect(try resolvedAccountId(for: "other@example.com", in: defaults) == "other-id")
        }
    }

    /// `mirrorIMAPAccounts` admits only `provider IN ('imap','icloud')` AND a
    /// non-empty `imapHost`, and production rests real exemptions on EACH clause
    /// separately: calendar rows fail the provider clause, while `DemoSeed`,
    /// `ScreenshotMode` and the preview fixtures are all `provider = .imap` and
    /// fail only the host clause. Neither was pinned on its own —
    /// `nonIMAPAccountIsMappedByAddressOnly` seeds a `.gmail` row with no host,
    /// so it fails BOTH and deleting either clause from the SQL left it green.
    ///
    /// ⚠️ "Each clause" means the PROVIDER clause and the HOST clause, and the
    /// host clause is pinned through `imapHost != ''` alone. `imapHost IS NOT
    /// NULL` is DEAD and cannot be pinned by anything: in SQLite `NULL != ''`
    /// evaluates to NULL, which `WHERE` rejects, so `!= ''` already excludes a
    /// NULL host — and `mirrorIMAPAccounts`' Swift loop excludes it a third time
    /// via `guard let host: String = row["imapHost"]`. Deleting `IS NOT NULL`
    /// from production turns no test red because it changes no behaviour. That
    /// also means the `DemoSeed`/`ScreenshotMode` exemption (host column never
    /// set, so NULL) rests on the Swift guard rather than on either SQL clause;
    /// the `blank` fixture below is what pins the SQL half.
    @Test("A non-IMAP row is excluded from the connection mirror even with connection info")
    func theProviderClauseAloneExcludesANonIMAPRowThatHasAHost() async throws {
        var oauth = Account(emailAddress: "oauth@example.com", displayName: "OAuth", provider: .gmail)
        oauth.id = "oauth-id"
        oauth.imapHost = "mail.example.com"
        oauth.imapPort = 993
        oauth.imapUsername = "oauth@example.com"

        try await withHarness(accounts: [oauth]) { defaults, _ in
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)

            // Present in the ADDRESS map regardless of provider: the extension
            // needs the full address set for its recipient-status suppress set.
            let mapped = try resolvedAccountId(for: "oauth@example.com", in: defaults)
            #expect(mapped == "oauth-id")

            // Absent from the CONNECTION map on the provider clause alone —
            // this row carries a host, a port and a username.
            let entry = try imapEntry(for: "oauth-id", in: defaults)
            #expect(entry == nil, """
                an OAuth account was published to nse.imapAccounts. The extension \
                would try a direct IMAP connection for a provider whose mail it \
                cannot fetch that way.
                """)
        }
    }

    @Test("An IMAP row with no usable host is excluded from the connection mirror")
    func theHostClauseAloneExcludesIMAPRowsWithoutAUsableHost() async throws {
        var hostless = Account(emailAddress: "hostless@example.com", displayName: "Hostless", provider: .imap)
        hostless.id = "hostless-id"
        var blank = Account(emailAddress: "blank@example.com", displayName: "Blank", provider: .icloud)
        blank.id = "blank-id"
        blank.imapHost = ""

        try await withHarness(accounts: [hostless, blank]) { defaults, _ in
            NSEDataBridge.mirrorAccountIdentity(defaults: defaults)

            let hostlessMapped = try resolvedAccountId(for: "hostless@example.com", in: defaults)
            let blankMapped = try resolvedAccountId(for: "blank@example.com", in: defaults)
            #expect(hostlessMapped == "hostless-id")
            #expect(blankMapped == "blank-id")

            // This is the property the DemoSeed / ScreenshotMode / preview
            // exemption rests on: those rows are `provider = .imap` and pass the
            // provider clause, so the HOST clause is the only thing keeping them
            // out of the connection mirror.
            let hostlessEntry = try imapEntry(for: "hostless-id", in: defaults)
            let blankEntry = try imapEntry(for: "blank-id", in: defaults)
            #expect(hostlessEntry == nil, """
                an IMAP row with no host was published to nse.imapAccounts, so \
                the extension would attempt a connection to an empty host.
                """)
            #expect(blankEntry == nil, """
                an iCloud row with an EMPTY host was published to \
                nse.imapAccounts. `imapHost != ''` is the clause that excludes \
                it; `IS NOT NULL` alone does not.
                """)
        }
    }
}
