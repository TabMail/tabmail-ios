/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// **The invariant: a CalDAV auth failure never removes the account's queued
/// calendar operations from executability.**
///
/// Executability, spelled out as the code spells it: `drainCalendarQueue` runs
/// `guard let calProvider = calendarProviders[currentOp.accountId] else
/// { continue }`, and for a CalDAV account the sole decider of membership in
/// that dictionary is whether `AccountManager.createCalDAVProvider` returns a
/// provider — every one of `AccountManager.connectAccount`'s four CalDAV arms is
/// `if let caldavProvider = try await createCalDAVProvider(for: account)
/// { calendarProviders[account.id] = caldavProvider }`. So *"the account's
/// queued ops are still executable"* and *"the factory still returns a
/// provider"* are the same statement, and this suite asserts the second because
/// it is the one a test can make without a network, a keychain grant per
/// provider, or a live drain.
///
/// What made this an invariant worth pinning: until round 18 the factory opened
/// with `if config.needsReauth { return nil }`, and `caldavConfig.needsReauth`
/// was set by the calendar queue's auth arm and **cleared by nothing**. One auth
/// failure therefore removed the account from `calendarProviders` permanently —
/// starving every op queued on it afterwards (the never-drop WEDGE COROLLARY,
/// which is in the non-recoverable set) and, because
/// `CalendarPickerModel.loadData` enumerates `CalendarProviderDispatch
/// .resolveAll()` over that same dictionary, removing the account from the
/// calendar picker where the ONE working re-auth prompt lives. The durable
/// column defeated the live signal.
///
/// **Red evidence (pre-fix):** at `b4de53ec6`, with
/// `if config.needsReauth { print(…); return nil }` still at the top of
/// `createCalDAVProvider`, `theDurableColumnDoesNotDecideExecutability()` fails
/// on its `needsReauth == true` leg — `#expect(flagged != nil)` reads nil — while
/// its `needsReauth == false` leg and the whole of
/// `aFactoryThatGenuinelyCannotBuildAClientStillReturnsNil()` pass. That
/// asymmetry is the point: the fix removes ONE gate, not all of them.
///
/// `.serialized, .processGlobalState` — replaces `AppDatabase.shared` and writes
/// to the process keychain.
@Suite("A CalDAV auth failure never wedges the account's calendar lane", .serialized, .processGlobalState)
struct CalDAVReauthWedgeTests {

    private static func seedAccount(id: String, pool: DatabasePool) throws -> Account {
        var account = Account(
            emailAddress: "\(id)@example.com",
            displayName: "R18 CalDAV fixture",
            provider: .icloud
        )
        account.id = id
        let toInsert = account
        try pool.write { db in try toInsert.insert(db) }
        return account
    }

    /// A config with discovery already cached, so `createCalDAVProvider` takes
    /// its no-network path and the only thing left that can decide the outcome is
    /// the guard under test.
    private static func seedConfig(
        accountId: String,
        needsReauth: Bool,
        pool: DatabasePool
    ) throws -> CalDAVConfig {
        var config = CalDAVConfig(
            accountId: accountId,
            serverURL: "https://caldav.example.com",
            username: "r18@example.com",
            displayName: "R18 Cal"
        )
        config.principalURL = "https://caldav.example.com/principals/r18"
        config.calendarHomeURL = "https://caldav.example.com/calendars/r18"
        config.needsReauth = needsReauth
        let toInsert = config
        try pool.write { db in try toInsert.insert(db) }
        return config
    }

    /// The headline case, stated as the two-sided property rather than the
    /// one-sided one: the durable column does not decide whether the account has a
    /// calendar provider. Asserting only the `true` leg would leave "the factory
    /// now always succeeds" indistinguishable from "the column is no longer read".
    @Test("The durable needsReauth column does not decide whether the account has a calendar provider")
    func theDurableColumnDoesNotDecideExecutability() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let flaggedAccount = try Self.seedAccount(id: "r18-caldav-flagged", pool: pool)
        let cleanAccount = try Self.seedAccount(id: "r18-caldav-clean", pool: pool)
        let flaggedConfig = try Self.seedConfig(
            accountId: flaggedAccount.id, needsReauth: true, pool: pool)
        let cleanConfig = try Self.seedConfig(
            accountId: cleanAccount.id, needsReauth: false, pool: pool)

        try KeychainHelper.save("r18-password", for: "caldav_password_\(flaggedConfig.id)")
        try KeychainHelper.save("r18-password", for: "caldav_password_\(cleanConfig.id)")
        defer {
            KeychainHelper.delete(key: "caldav_password_\(flaggedConfig.id)")
            KeychainHelper.delete(key: "caldav_password_\(cleanConfig.id)")
        }

        // MIS-030 — anchor the fixture BEFORE the act, so "the flag was set" is a
        // fact about the database and not about the seeding helper.
        let storedFlag = try await pool.read { db in
            try CalDAVConfig.fetchOne(db, key: flaggedConfig.id)?.needsReauth
        }
        #expect(storedFlag == true, "precondition: the durable re-auth flag must actually be set")

        let flagged = try await AccountManager.shared.createCalDAVProvider(for: flaggedAccount)
        let clean = try await AccountManager.shared.createCalDAVProvider(for: cleanAccount)

        #expect(flagged != nil,
                "an account whose caldavConfig is flagged needsReauth must still get a calendar provider — without one, drainCalendarQueue skips its queued ops forever and the calendar picker cannot show it the re-auth prompt")
        #expect(clean != nil,
                "control: an unflagged account must get a provider too, so the assertion above is not measuring a factory that succeeds for some unrelated reason")
    }

    /// The mirror image (`MIS-005`). Removing the `needsReauth` gate must not be
    /// mistaken for removing the factory's ability to refuse: a config whose
    /// keychain secret is genuinely absent cannot produce a working client, and
    /// returning one would be worse than returning nil.
    @Test("A CalDAV config whose keychain password is absent still yields no provider")
    func aFactoryThatGenuinelyCannotBuildAClientStillReturnsNil() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let account = try Self.seedAccount(id: "r18-caldav-nopassword", pool: pool)
        let config = try Self.seedConfig(accountId: account.id, needsReauth: true, pool: pool)
        // Defensive: a sibling test in another suite could have left this key.
        KeychainHelper.delete(key: "caldav_password_\(config.id)")

        let provider = try await AccountManager.shared.createCalDAVProvider(for: account)
        #expect(provider == nil,
                "no stored secret means no usable client; the round-18 change removed ONE gate, not the factory's ability to refuse")
    }

    /// An account with no `caldavConfig` row at all was never a CalDAV account,
    /// and must stay outside the calendar provider registry. Pins the other edge
    /// of the same function so a future simplification cannot collapse all three
    /// answers into one.
    @Test("An account with no CalDAV config still yields no provider")
    func anAccountWithoutACalDAVConfigStillYieldsNoProvider() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let account = try Self.seedAccount(id: "r18-caldav-noconfig", pool: pool)
        let provider = try await AccountManager.shared.createCalDAVProvider(for: account)
        #expect(provider == nil, "no caldavConfig row means the account has no CalDAV calendar")
    }
}
