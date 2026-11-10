/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// INVARIANT (ADR-IOS-038 demo boundary): the calendar tools act on exactly one
// side of the demo boundary. While demo mode is active they resolve the demo
// calendar or nothing, never a real account's calendar, even when real
// providers stay registered (debug-menu coexistence). Outside demo mode they
// never resolve the demo calendar, even when the stored preference names it.
// Within the real side, an active preferred account wins, otherwise the first
// active registered account. A wrong answer here is a demo chat reading or
// writing the user's real calendar.
//
// Each case registers mock providers under unique account ids, in the shared
// registry, and resolves against its own database, so a provider another
// suite left registered has no account row here and cannot be picked.

@MainActor
@Suite("Calendar dispatch: demo mode and the real accounts never resolve each other's calendar", .serialized, .processGlobalState)
struct CalendarProviderDispatchResolveTests {

    private struct Fixture {
        let db: DatabaseQueue
        let demo = MockCalendarProvider()
        let realA = MockCalendarProvider()
        let realB = MockCalendarProvider()
        let realAId = "cal-dispatch-a-\(UUID().uuidString)"
        let realBId = "cal-dispatch-b-\(UUID().uuidString)"
    }

    /// Accounts to create, by role, with their `isActive` value.
    private enum Role { case demo, realA, realB }

    /// Runs `body` with the given demo state, preference, account rows and
    /// registered providers, then restores every global it touched.
    private func withFixture(
        demoActive: Bool,
        preferred: Role? = nil,
        accounts: [Role: Bool],
        registered: Set<Role>,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let fixture = Fixture(db: try TestDatabase.make())
        func id(_ role: Role) -> String {
            switch role {
            case .demo: return DemoSeed.demoAccountId
            case .realA: return fixture.realAId
            case .realB: return fixture.realBId
            }
        }
        func provider(_ role: Role) -> MockCalendarProvider {
            switch role {
            case .demo: return fixture.demo
            case .realA: return fixture.realA
            case .realB: return fixture.realB
            }
        }
        let rows = accounts.map { role, isActive in
            (id: id(role), email: "\(role)@example.com", isActive: isActive)
        }
        try await fixture.db.write { db in
            for row in rows {
                var account = Account(emailAddress: row.email, displayName: "Test", provider: .gmail)
                account.id = row.id
                account.isActive = row.isActive
                try account.insert(db)
            }
        }

        let manager = AccountManager.shared
        let priorDemoProvider = await manager.calendarProviders[DemoSeed.demoAccountId]
        let priorDemoActive = DemoModeStore.shared.isActive
        let defaults = UserDefaults.standard
        let preferenceKeys = [CalendarProviderDispatch.preferredCalendarAccountKey, CalendarProviderDispatch.preferredGoogleAccountKey]
        let priorPreferences = preferenceKeys.map { defaults.string(forKey: $0) }

        await manager.unregisterCalendarProviderForTesting(accountId: DemoSeed.demoAccountId)
        for role in registered {
            await manager.registerCalendarProviderForTesting(accountId: id(role), provider: provider(role))
        }
        DemoModeStore.shared.isActive = demoActive
        for key in preferenceKeys { defaults.removeObject(forKey: key) }
        if let preferred {
            defaults.set(id(preferred), forKey: CalendarProviderDispatch.preferredCalendarAccountKey)
        }

        var failure: Error?
        do { try await body(fixture) } catch { failure = error }

        for (key, value) in zip(preferenceKeys, priorPreferences) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        DemoModeStore.shared.isActive = priorDemoActive
        await manager.unregisterCalendarProviderForTesting(accountId: fixture.realAId)
        await manager.unregisterCalendarProviderForTesting(accountId: fixture.realBId)
        await manager.unregisterCalendarProviderForTesting(accountId: DemoSeed.demoAccountId)
        if let priorDemoProvider {
            await manager.registerCalendarProviderForTesting(accountId: DemoSeed.demoAccountId, provider: priorDemoProvider)
        }
        if let failure { throw failure }
    }

    private func isSame(_ provider: (any CalendarProvider)?, _ mock: MockCalendarProvider) -> Bool {
        guard let provider else { return false }
        return (provider as AnyObject) === mock
    }

    // MARK: - Demo mode

    @Test("Demo mode resolves the demo calendar while a real calendar is also registered")
    func demoModeResolvesTheDemoCalendar() async throws {
        try await withFixture(demoActive: true, accounts: [.demo: true, .realA: true], registered: [.demo, .realA]) { f in
            let resolved = await CalendarProviderDispatch.resolve(db: f.db)
            #expect(resolved?.account.id == DemoSeed.demoAccountId)
            #expect(isSame(resolved?.provider, f.demo))
        }
    }

    @Test("Demo mode without a demo calendar resolves nothing, never the registered real calendar")
    func demoModeWithoutTheDemoCalendarResolvesNothing() async throws {
        try await withFixture(demoActive: true, preferred: .realA, accounts: [.demo: true, .realA: true], registered: [.realA]) { f in
            let resolved = await CalendarProviderDispatch.resolve(db: f.db)
            #expect(resolved == nil, "resolved \(resolved?.account.id ?? "nil")")
        }
    }

    @Test("Demo mode with an inactive demo account resolves nothing, never the registered real calendar")
    func demoModeWithAnInactiveDemoAccountResolvesNothing() async throws {
        try await withFixture(demoActive: true, accounts: [.demo: false, .realA: true], registered: [.demo, .realA]) { f in
            let resolved = await CalendarProviderDispatch.resolve(db: f.db)
            #expect(resolved == nil, "resolved \(resolved?.account.id ?? "nil")")
        }
    }

    // MARK: - Normal mode

    @Test("Outside demo mode the real calendar is resolved, not the registered demo calendar")
    func normalModeResolvesTheRealCalendar() async throws {
        try await withFixture(demoActive: false, accounts: [.demo: true, .realA: true], registered: [.demo, .realA]) { f in
            let resolved = await CalendarProviderDispatch.resolve(db: f.db)
            #expect(resolved?.account.id == f.realAId)
            #expect(isSame(resolved?.provider, f.realA))
        }
    }

    @Test("A stored preference naming the demo account is ignored outside demo mode")
    func preferenceNamingTheDemoAccountIsIgnored() async throws {
        try await withFixture(demoActive: false, preferred: .demo, accounts: [.demo: true, .realA: true], registered: [.demo, .realA]) { f in
            let resolved = await CalendarProviderDispatch.resolve(db: f.db)
            #expect(resolved?.account.id == f.realAId)
        }
    }

    @Test("An active preferred account wins over another registered account")
    func activePreferredAccountWins() async throws {
        // The registry's order is not fixed, so one resolve could pick the
        // preferred account by chance. Resolving once per preference, against
        // the same registry, names each account in turn only if the preference
        // is honoured.
        try await withFixture(demoActive: false, preferred: .realB, accounts: [.realA: true, .realB: true], registered: [.realA, .realB]) { f in
            let toB = await CalendarProviderDispatch.resolve(db: f.db)
            #expect(toB?.account.id == f.realBId)
            #expect(isSame(toB?.provider, f.realB))

            UserDefaults.standard.set(f.realAId, forKey: CalendarProviderDispatch.preferredCalendarAccountKey)
            let toA = await CalendarProviderDispatch.resolve(db: f.db)
            #expect(toA?.account.id == f.realAId)
            #expect(isSame(toA?.provider, f.realA))
        }
    }

    @Test("An inactive preferred account falls back to the active registered account")
    func inactivePreferredAccountFallsBack() async throws {
        try await withFixture(demoActive: false, preferred: .realA, accounts: [.realA: false, .realB: true], registered: [.realA, .realB]) { f in
            let resolved = await CalendarProviderDispatch.resolve(db: f.db)
            #expect(resolved?.account.id == f.realBId)
        }
    }

    @Test("With no calendar registered for any account, nothing is resolved")
    func nothingRegisteredResolvesNothing() async throws {
        try await withFixture(demoActive: false, accounts: [.demo: true, .realA: true], registered: []) { f in
            let resolved = await CalendarProviderDispatch.resolve(db: f.db)
            #expect(resolved == nil, "resolved \(resolved?.account.id ?? "nil")")
        }
    }
}
