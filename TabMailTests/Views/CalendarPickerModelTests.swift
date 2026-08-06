/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Gated provider

/// A `CalendarProvider` whose `listCalendars()` blocks until `release()` is
/// called.
///
/// This is the non-vacuity instrument for the whole suite: `hasReleased == false`
/// is positive proof that this account's round trip **cannot** have completed, so
/// anything the model has published at that moment was published *before* the
/// provider answered. A sleep-based "slow" provider would only prove that the
/// model was fast enough on this machine, today.
private actor GatedCalendarProvider: CalendarProvider {
    private let calendars: [GCalCalendar]
    private let failure: Error?
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    init(calendars: [GCalCalendar] = [], failure: Error? = nil) {
        self.calendars = calendars
        self.failure = failure
    }

    var hasReleased: Bool { released }

    func release() {
        guard !released else { return }
        released = true
        gate?.resume()
        gate = nil
    }

    func listCalendars() async throws -> [GCalCalendar] {
        if !released {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate = continuation
            }
        }
        if let failure { throw failure }
        return calendars
    }

    func primaryCalendarId() async throws -> String {
        calendars.first(where: { $0.primary == true })?.id ?? calendars.first?.id ?? "primary"
    }

    func listEvents(calendarId: String, timeMin: Date?, timeMax: Date?, query: String?, singleEvents: Bool, maxResults: Int, orderBy: String) async throws -> [GCalEvent] {
        []
    }

    func getEvent(calendarId: String, eventId: String) async throws -> GCalEvent {
        throw CalendarProviderError.notSupported("GatedCalendarProvider is list-only")
    }

    func createEvent(calendarId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        throw CalendarProviderError.notSupported("GatedCalendarProvider is list-only")
    }

    func updateEvent(calendarId: String, eventId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        throw CalendarProviderError.notSupported("GatedCalendarProvider is list-only")
    }

    func deleteEvent(calendarId: String, eventId: String, sendUpdates: String) async throws {
        throw CalendarProviderError.notSupported("GatedCalendarProvider is list-only")
    }
}

// MARK: - Suite

/// Invariants of `CalendarPickerModel.loadData()`, the calendar picker's load.
///
/// Two properties are pinned here, and they are opposite halves of the same fix:
///
/// 1. **The account rows are published before any provider answers**, and one
///    slow account does not delay another account's calendars. The screen used to
///    stay blank for the SUM of every account's network round trip.
/// 2. **A stored create-target preference survives a partial load.** The pass
///    that auto-selects a default also CLEARS a preference it cannot find; run
///    against a half-loaded set it wipes a valid saved choice. The third and
///    fourth tests are its mirror image — the stale-clearing must still happen
///    once every account has resolved, so the guard cannot be satisfied by simply
///    never running the pass.
@Suite("CalendarPickerModel incremental load")
@MainActor
struct CalendarPickerModelTests {

    // MARK: - Helpers

    private static func makeCal(_ id: String, primary: Bool = false, accessRole: String = "owner") -> GCalCalendar {
        GCalCalendar(
            id: id,
            summary: "Cal \(id)",
            primary: primary,
            accessRole: accessRole,
            backgroundColor: nil,
            selected: nil
        )
    }

    private static func makeAccount(id: String, email: String) -> Account {
        var account = Account(emailAddress: email, displayName: "Test", provider: .gmail)
        account.id = id
        return account
    }

    /// A fresh, isolated defaults domain per test.
    ///
    /// Both preference keys are ALWAYS seeded, even when the test wants "nothing
    /// stored" (seeded as `""`, which is exactly what the model's `?? ""` read
    /// yields). A `UserDefaults(suiteName:)` search list falls through to the
    /// application domain for keys its own suite lacks, so an unseeded key would
    /// silently read whatever `.standard` happens to hold.
    private static func makeDefaults(storedAccountId: String, storedCalendarId: String) -> (UserDefaults, String) {
        let suiteName = "tabmail.tests.calendar-picker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(storedAccountId, forKey: CalendarProviderDispatch.preferredCalendarAccountKey)
        defaults.set(storedCalendarId, forKey: CalendarProviderDispatch.preferredCalendarKey)
        return (defaults, suiteName)
    }

    private static func storedPreference(_ defaults: UserDefaults) -> (accountId: String, calendarId: String) {
        (
            defaults.string(forKey: CalendarProviderDispatch.preferredCalendarAccountKey) ?? "",
            defaults.string(forKey: CalendarProviderDispatch.preferredCalendarKey) ?? ""
        )
    }

    /// Bounded wait for a MainActor condition. Returns `false` on timeout rather
    /// than hanging the suite, so a regression fails loudly instead of wedging.
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func entry(_ model: CalendarPickerModel, _ accountId: String) -> CalendarPickerModel.AccountEntry? {
        model.accounts.first(where: { $0.id == accountId })
    }

    // MARK: - 1. Rows paint before the network answers

    @Test("Account rows are published before the provider returns")
    func accountRowsPublishBeforeProviderReturns() async {
        let (defaults, suiteName) = Self.makeDefaults(storedAccountId: "", storedCalendarId: "")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let slow = GatedCalendarProvider(calendars: [Self.makeCal("cal-slow", primary: true)])
        let backends: [(provider: any CalendarProvider, account: Account)] = [
            (provider: slow, account: Self.makeAccount(id: "acct-slow", email: "slow@example.com"))
        ]
        let model = CalendarPickerModel(defaults: defaults, resolveBackends: { backends })

        let run = Task { await model.loadData() }

        let published = await Self.waitUntil { model.accounts.count == 1 }
        #expect(published, "the account row must be published before the provider answers")

        // Non-vacuity: the gate proves the round trip cannot have completed.
        let releasedYet = await slow.hasReleased
        #expect(releasedYet == false)

        #expect(model.loaded == true)
        #expect(self.entry(model, "acct-slow")?.account.emailAddress == "slow@example.com")
        #expect(self.entry(model, "acct-slow")?.isLoading == true)
        #expect(self.entry(model, "acct-slow")?.calendars.isEmpty == true)

        await slow.release()
        await run.value

        #expect(self.entry(model, "acct-slow")?.isLoading == false)
        #expect(self.entry(model, "acct-slow")?.calendars.map(\.id) == ["cal-slow"])
    }

    // MARK: - 2. One slow account does not delay the others

    @Test("A slow account does not delay a LATER account's calendars")
    func slowAccountDoesNotDelayLaterAccount() async {
        let (defaults, suiteName) = Self.makeDefaults(storedAccountId: "", storedCalendarId: "")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let slow = GatedCalendarProvider(calendars: [Self.makeCal("cal-slow", primary: true)])
        let fast = MockCalendarProvider()
        await fast.setListCalendarsResult([Self.makeCal("cal-fast", primary: true)])

        // The slow account is deliberately FIRST: a serial loop can never reach
        // the second account until the first one answers, so this ordering is
        // what makes the assertion a statement about concurrency rather than
        // about which account happened to be quick.
        let backends: [(provider: any CalendarProvider, account: Account)] = [
            (provider: slow, account: Self.makeAccount(id: "acct-slow", email: "slow@example.com")),
            (provider: fast, account: Self.makeAccount(id: "acct-fast", email: "fast@example.com"))
        ]
        let model = CalendarPickerModel(defaults: defaults, resolveBackends: { backends })

        let run = Task { await model.loadData() }

        let fastArrived = await Self.waitUntil {
            model.accounts.first(where: { $0.id == "acct-fast" })?.isLoading == false
        }
        #expect(fastArrived, "the second account's calendars must land while the first is still in flight")

        let releasedYet = await slow.hasReleased
        #expect(releasedYet == false)

        #expect(self.entry(model, "acct-fast")?.calendars.map(\.id) == ["cal-fast"])
        #expect(self.entry(model, "acct-slow")?.isLoading == true)

        await slow.release()
        await run.value

        #expect(model.accounts.allSatisfy { !$0.isLoading })
        #expect(self.entry(model, "acct-slow")?.calendars.map(\.id) == ["cal-slow"])
    }

    // MARK: - 3. THE TRAP — a valid stored preference survives a partial load

    @Test("A stored valid preference survives a partial load")
    func storedPreferenceSurvivesPartialLoad() async {
        // The stored preference belongs to the account that has NOT answered yet.
        let (defaults, suiteName) = Self.makeDefaults(storedAccountId: "acct-slow", storedCalendarId: "cal-slow")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let slow = GatedCalendarProvider(calendars: [Self.makeCal("cal-slow", primary: true)])
        let fast = MockCalendarProvider()
        await fast.setListCalendarsResult([Self.makeCal("cal-fast", primary: true)])

        let backends: [(provider: any CalendarProvider, account: Account)] = [
            (provider: fast, account: Self.makeAccount(id: "acct-fast", email: "fast@example.com")),
            (provider: slow, account: Self.makeAccount(id: "acct-slow", email: "slow@example.com"))
        ]
        let model = CalendarPickerModel(defaults: defaults, resolveBackends: { backends })

        let run = Task { await model.loadData() }

        // Wait for the fast account to land — this is the exact window in which a
        // naive incremental publish would re-run the selection pass, fail to find
        // `cal-slow` among the (partial) writable set, and re-point the user's
        // saved choice at `cal-fast`.
        let fastArrived = await Self.waitUntil {
            model.accounts.first(where: { $0.id == "acct-fast" })?.isLoading == false
        }
        #expect(fastArrived)

        let releasedYet = await slow.hasReleased
        #expect(releasedYet == false)
        #expect(self.entry(model, "acct-slow")?.isLoading == true)

        let midFlight = Self.storedPreference(defaults)
        #expect(midFlight.accountId == "acct-slow")
        #expect(midFlight.calendarId == "cal-slow")

        await slow.release()
        await run.value

        let afterLoad = Self.storedPreference(defaults)
        #expect(afterLoad.accountId == "acct-slow")
        #expect(afterLoad.calendarId == "cal-slow")
    }

    // MARK: - 4. The mirror image — stale clearing must STILL happen

    @Test("A stale preference is re-pointed once every account has resolved")
    func stalePreferenceRepointedAfterFullLoad() async {
        let (defaults, suiteName) = Self.makeDefaults(storedAccountId: "acct-1", storedCalendarId: "cal-gone")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let provider = MockCalendarProvider()
        await provider.setListCalendarsResult([
            Self.makeCal("cal-other"),
            Self.makeCal("cal-primary", primary: true)
        ])
        let backends: [(provider: any CalendarProvider, account: Account)] = [
            (provider: provider, account: Self.makeAccount(id: "acct-1", email: "one@example.com"))
        ]
        let model = CalendarPickerModel(defaults: defaults, resolveBackends: { backends })

        await model.loadData()

        let resolved = Self.storedPreference(defaults)
        #expect(resolved.accountId == "acct-1")
        #expect(resolved.calendarId == "cal-primary")
    }

    @Test("A stale preference is cleared when no writable calendar exists anywhere")
    func stalePreferenceClearedWhenNothingWritable() async {
        let (defaults, suiteName) = Self.makeDefaults(storedAccountId: "acct-1", storedCalendarId: "cal-gone")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let provider = MockCalendarProvider()
        await provider.setListCalendarsResult([Self.makeCal("cal-ro", accessRole: "reader")])
        let backends: [(provider: any CalendarProvider, account: Account)] = [
            (provider: provider, account: Self.makeAccount(id: "acct-1", email: "one@example.com"))
        ]
        let model = CalendarPickerModel(defaults: defaults, resolveBackends: { backends })

        await model.loadData()

        let resolved = Self.storedPreference(defaults)
        #expect(resolved.accountId == "")
        #expect(resolved.calendarId == "")
    }

    // MARK: - 5. A failed account still counts as resolved

    @Test("A failed account resolves its row and does not block the selection pass")
    func failedAccountStillResolves() async {
        let (defaults, suiteName) = Self.makeDefaults(storedAccountId: "", storedCalendarId: "")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let failing = GatedCalendarProvider(failure: URLError(.notConnectedToInternet))
        await failing.release()  // fails immediately, no gating
        let healthy = MockCalendarProvider()
        await healthy.setListCalendarsResult([Self.makeCal("cal-ok", primary: true)])

        let backends: [(provider: any CalendarProvider, account: Account)] = [
            (provider: failing, account: Self.makeAccount(id: "acct-bad", email: "bad@example.com")),
            (provider: healthy, account: Self.makeAccount(id: "acct-ok", email: "ok@example.com"))
        ]
        let model = CalendarPickerModel(defaults: defaults, resolveBackends: { backends })

        await model.loadData()

        #expect(model.accounts.allSatisfy { !$0.isLoading })
        #expect(self.entry(model, "acct-bad")?.errorMessage != nil)
        #expect(self.entry(model, "acct-bad")?.needsReauth == false)
        // The selection pass ran even though one account failed.
        let resolved = Self.storedPreference(defaults)
        #expect(resolved.accountId == "acct-ok")
        #expect(resolved.calendarId == "cal-ok")
    }

    // MARK: - 6. No accounts

    @Test("With no calendar accounts the empty state is reachable immediately")
    func noAccountsMarksLoaded() async {
        let (defaults, suiteName) = Self.makeDefaults(storedAccountId: "", storedCalendarId: "")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = CalendarPickerModel(defaults: defaults, resolveBackends: { [] })
        await model.loadData()

        #expect(model.accounts.isEmpty)
        #expect(model.loaded == true)
    }

    // MARK: - 7. The guard itself

    @Test("resolveSelection refuses to touch the preference while any entry is loading")
    func resolveSelectionRefusesPartialSet() {
        let loadedEntry = CalendarPickerModel.AccountEntry(
            account: Self.makeAccount(id: "acct-fast", email: "fast@example.com"),
            provider: MockCalendarProvider(),
            calendars: [Self.makeCal("cal-fast", primary: true)],
            isLoading: false
        )
        let pendingEntry = CalendarPickerModel.AccountEntry(
            account: Self.makeAccount(id: "acct-slow", email: "slow@example.com"),
            provider: MockCalendarProvider(),
            isLoading: true
        )

        #expect(CalendarPickerModel.resolveSelection(
            entries: [loadedEntry, pendingEntry],
            storedAccountId: "acct-slow",
            storedCalendarId: "cal-slow"
        ) == nil)

        // Same inputs, everything resolved: now it is allowed to act.
        let resolved = CalendarPickerModel.resolveSelection(
            entries: [loadedEntry],
            storedAccountId: "acct-slow",
            storedCalendarId: "cal-slow"
        )
        #expect(resolved?.accountId == "acct-fast")
        #expect(resolved?.calendarId == "cal-fast")
    }
}
