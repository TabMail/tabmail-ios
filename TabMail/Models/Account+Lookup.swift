/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import GRDB

extension Account {
    /// Case-insensitive existing-account lookup: the single predicate for
    /// "does an account row already cover this address for this provider?".
    ///
    /// Shared by the login-screen add gate (`TabMailLoginView` — decides
    /// whether to stage `PendingAccountAdd`) and the OAuth account-setup
    /// dedupe (`AccountManager.setupOAuthAccount` — decides token-refresh
    /// vs. insert). Both decisions MUST agree, and both MUST be
    /// case-insensitive: SQLite's default BINARY collation on
    /// `emailAddress` treats `User@example.com` and `user@example.com` as
    /// different rows, which turned a token refresh into a duplicate
    /// account row whenever the identity provider returned a
    /// differently-cased address (issue #56).
    ///
    /// Deliberately matches rows regardless of `calendarOnly`: a
    /// calendar-first row (created by `CalendarSetupView`) is still "this
    /// address is configured" — callers that care about the mail side
    /// inspect `calendarOnly` on the returned row (see
    /// `setupOAuthAccount`'s upgrade arm). Do NOT replace this with a
    /// `navigationStore.accounts` check: `Account.sidebarRequest` filters
    /// out `calendarOnly` rows, so calendar-first accounts are invisible
    /// to it.
    ///
    /// The provider's rows are fetched and compared in Swift rather than via
    /// SQL `LOWER()`: the account table holds a handful of rows, and
    /// SQLite's `LOWER` is ASCII-only. The comparison uses full Unicode
    /// CASE FOLDING (`folding(options: .caseInsensitive)`), not
    /// `lowercased()`: lowercasing is context-sensitive (Greek sigma takes
    /// its final form `ς` at word end, so `"…Σ@…".lowercased()` and a stored
    /// non-final `σ` never compare equal), while case folding maps every
    /// case variant to one canonical form. Swift `==` on the folded strings
    /// additionally gives canonical (NFC/NFD) equivalence.
    ///
    /// When MORE than one row matches — the pre-fix BINARY dedupe could mint
    /// case-variant duplicates, and those rows are in the wild — the result
    /// is deterministic and safe: prefer the full MAIL row over a
    /// calendar-only one (so token refresh and `setupOAuthAccount`'s upgrade
    /// arm can never seize a calendarOnly duplicate and mint a SECOND active
    /// mail account for the address), then the oldest row.
    static func existing(
        forEmail email: String,
        provider: AccountProvider,
        in db: Database
    ) throws -> Account? {
        let wanted = email.folding(options: .caseInsensitive, locale: nil)
        let matches = try Account
            .filter(Column("provider") == provider.rawValue)
            .fetchAll(db)
            .filter { $0.emailAddress.folding(options: .caseInsensitive, locale: nil) == wanted }
        // Deterministic pick under duplicates: the full MAIL row beats a
        // calendar-only one, then the oldest row wins.
        return matches.min { a, b in
            if a.calendarOnly != b.calendarOnly { return !a.calendarOnly }
            return a.createdAt < b.createdAt
        }
    }
}
