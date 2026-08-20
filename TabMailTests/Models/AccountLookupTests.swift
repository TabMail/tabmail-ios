/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Invariant tests for `Account.existing(forEmail:provider:in:)` (issue #56).
///
/// The system property: **signing in with an identity that is already
/// configured — under ANY casing, and even when the row is calendar-only —
/// must be recognized as "already configured"**, because the login flow
/// uses this predicate to decide whether to present the add-account gate,
/// and the OAuth setup path uses it to decide token-refresh vs. insert.
/// Pre-fix, the login flow never checked at all, and the setup dedupe
/// compared with SQLite BINARY collation, so a differently-cased address
/// from the identity provider produced a duplicate account row.
///
/// Two-sided: a genuinely new address must still come back nil (the add
/// gate must still appear for real new accounts), and a row under a
/// different provider must not satisfy the match.
@Suite("Account.existing lookup")
struct AccountLookupTests {

    /// Insert a row with explicit control over casing and calendarOnly.
    @discardableResult
    private func insert(
        _ db: DatabaseQueue,
        id: String,
        email: String,
        provider: AccountProvider,
        calendarOnly: Bool = false
    ) throws -> Account {
        var account = Account(emailAddress: email, displayName: "Test", provider: provider)
        account.id = id
        account.calendarOnly = calendarOnly
        try db.write { try account.insert($0) }
        return account
    }

    @Test("Differently-cased stored address matches a lowercase query")
    func mixedCaseStoredMatchesLowercaseQuery() throws {
        let db = try TestDatabase.make()
        try insert(db, id: "acc1", email: "User@Example.com", provider: .gmail)

        let found = try db.read { db in
            try Account.existing(forEmail: "user@example.com", provider: .gmail, in: db)
        }
        #expect(found?.id == "acc1")
    }

    @Test("Lowercase stored address matches a mixed-case query (reverse direction)")
    func lowercaseStoredMatchesMixedCaseQuery() throws {
        let db = try TestDatabase.make()
        try insert(db, id: "acc1", email: "user@example.com", provider: .gmail)

        let found = try db.read { db in
            try Account.existing(forEmail: "USER@Example.COM", provider: .gmail, in: db)
        }
        #expect(found?.id == "acc1")
    }

    @Test("A calendar-only row still counts as configured")
    func calendarOnlyRowMatches() throws {
        let db = try TestDatabase.make()
        try insert(db, id: "cal1", email: "user@example.com", provider: .gmail, calendarOnly: true)

        let found = try db.read { db in
            try Account.existing(forEmail: "User@example.com", provider: .gmail, in: db)
        }
        #expect(found?.id == "cal1")
        // The caller decides what to do about the mail side — the predicate
        // must surface the row, with its calendarOnly flag intact.
        #expect(found?.calendarOnly == true)
    }

    @Test("A genuinely new address returns nil (the add gate must still appear)")
    func absentAddressReturnsNil() throws {
        let db = try TestDatabase.make()
        try insert(db, id: "acc1", email: "user@example.com", provider: .gmail)

        let found = try db.read { db in
            try Account.existing(forEmail: "someone-else@example.com", provider: .gmail, in: db)
        }
        #expect(found == nil)
    }

    @Test("A row under a different provider does not satisfy the match")
    func providerMismatchReturnsNil() throws {
        let db = try TestDatabase.make()
        try insert(db, id: "acc1", email: "user@example.com", provider: .gmail)

        let found = try db.read { db in
            try Account.existing(forEmail: "user@example.com", provider: .outlook, in: db)
        }
        #expect(found == nil)
    }

    @Test("Case-fold-only variants match: stored final sigma vs queried capital sigma")
    func caseFoldOnlyVariantsMatch() throws {
        let db = try TestDatabase.make()
        // Stored with the FINAL lowercase sigma `ς` (U+03C2) — already
        // lowercase, so `lowercased()` leaves it as `ς` — while the query
        // carries the capital `Σ` (U+03A3), which `lowercased()` maps to the
        // non-final `σ` (U+03C3; red-run evidence showed Swift applies no
        // final-sigma context rule). Under `lowercased()` the two never
        // compare equal; only true case FOLDING maps all sigma forms to one
        // canonical `σ`.
        try insert(db, id: "acc1", email: "user\u{03C2}@example.com", provider: .gmail)

        let found = try db.read { db in
            try Account.existing(forEmail: "user\u{03A3}@example.com", provider: .gmail, in: db)
        }
        #expect(found?.id == "acc1")
    }

    @Test("Duplicates prefer the mail row: a calendarOnly case-variant duplicate never wins")
    func duplicatesPreferTheMailRow() throws {
        let db = try TestDatabase.make()
        // The pre-fix BINARY dedupe could mint case-variant duplicates, and
        // such rows are in the wild. Insert the calendarOnly duplicate FIRST
        // so an order-of-insertion `.first` would return it — the predicate
        // must still hand back the full MAIL row, or setupOAuthAccount's
        // upgrade arm would clear the duplicate's calendarOnly flag and mint
        // a SECOND active mail account for the same address.
        try insert(db, id: "calDup", email: "User@example.com", provider: .gmail, calendarOnly: true)
        try insert(db, id: "mailReal", email: "user@example.com", provider: .gmail)

        let found = try db.read { db in
            try Account.existing(forEmail: "USER@example.com", provider: .gmail, in: db)
        }
        #expect(found?.id == "mailReal")
        #expect(found?.calendarOnly == false)
    }

    @Test("Same address under two providers resolves to the requested provider's row")
    func sameEmailTwoProvidersPicksRequested() throws {
        let db = try TestDatabase.make()
        try insert(db, id: "gm1", email: "user@example.com", provider: .gmail)
        try insert(db, id: "ol1", email: "User@example.com", provider: .outlook)

        let gmail = try db.read { db in
            try Account.existing(forEmail: "USER@example.com", provider: .gmail, in: db)
        }
        let outlook = try db.read { db in
            try Account.existing(forEmail: "user@example.com", provider: .outlook, in: db)
        }
        #expect(gmail?.id == "gm1")
        #expect(outlook?.id == "ol1")
    }
}
