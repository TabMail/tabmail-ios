/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// These tests reset/reuse keys on the real process-wide UserDefaults.standard.
// `.serialized` prevents sibling overlap; `.processGlobalState` prevents the
// separate visibility-filter suite from resetting the same keys concurrently.
@Suite("CalendarVisibilityStore", .serialized, .processGlobalState)
struct CalendarVisibilityStoreTests {

    private func makeCal(id: String, primary: Bool? = nil, selected: Bool? = nil) -> GCalCalendar {
        GCalCalendar(
            id: id,
            summary: "Test \(id)",
            primary: primary,
            accessRole: "owner",
            backgroundColor: nil,
            selected: selected
        )
    }

    private func resetStore() {
        CalendarVisibilityStore._resetForTesting()
    }

    @Test("override / setOverride round-trip")
    func roundTrip() {
        resetStore()
        defer { resetStore() }

        let acct = "acct-1"
        let calId = "cal-1"

        #expect(CalendarVisibilityStore.override(accountId: acct, calendarId: calId) == nil)

        CalendarVisibilityStore.setOverride(true, accountId: acct, calendarId: calId)
        #expect(CalendarVisibilityStore.override(accountId: acct, calendarId: calId) == true)

        CalendarVisibilityStore.setOverride(false, accountId: acct, calendarId: calId)
        #expect(CalendarVisibilityStore.override(accountId: acct, calendarId: calId) == false)

        CalendarVisibilityStore.setOverride(nil, accountId: acct, calendarId: calId)
        #expect(CalendarVisibilityStore.override(accountId: acct, calendarId: calId) == nil)
    }

    @Test("isVisible — no override, primary: true → visible")
    func resolvePrimaryTrue() {
        resetStore()
        defer { resetStore() }

        let cal = makeCal(id: "c1", primary: true)
        #expect(CalendarVisibilityStore.isVisible(cal, accountId: "acct") == true)
        #expect(CalendarVisibilityStore.reason(cal, accountId: "acct") == .defaultPrimary)
    }

    @Test("isVisible — no override, primary: false → hidden (default)")
    func resolvePrimaryFalse() {
        resetStore()
        defer { resetStore() }

        let cal = makeCal(id: "c1", primary: false)
        #expect(CalendarVisibilityStore.isVisible(cal, accountId: "acct") == false)
        #expect(CalendarVisibilityStore.reason(cal, accountId: "acct") == .defaultNonPrimary)
    }

    @Test("isVisible — no override, primary: nil → hidden (default)")
    func resolvePrimaryNil() {
        resetStore()
        defer { resetStore() }

        let cal = makeCal(id: "c1", primary: nil)
        #expect(CalendarVisibilityStore.isVisible(cal, accountId: "acct") == false)
        #expect(CalendarVisibilityStore.reason(cal, accountId: "acct") == .defaultNonPrimary)
    }

    @Test("isVisible — user override true beats default-hidden non-primary")
    func overrideTrueBeatsNonPrimary() {
        resetStore()
        defer { resetStore() }

        let cal = makeCal(id: "c1", primary: false)
        CalendarVisibilityStore.setOverride(true, accountId: "acct", calendarId: "c1")
        #expect(CalendarVisibilityStore.isVisible(cal, accountId: "acct") == true)
        #expect(CalendarVisibilityStore.reason(cal, accountId: "acct") == .userOverride)
    }

    @Test("isVisible — user override false beats default-visible primary")
    func overrideFalseBeatsPrimary() {
        resetStore()
        defer { resetStore() }

        let cal = makeCal(id: "c1", primary: true)
        CalendarVisibilityStore.setOverride(false, accountId: "acct", calendarId: "c1")
        #expect(CalendarVisibilityStore.isVisible(cal, accountId: "acct") == false)
        #expect(CalendarVisibilityStore.reason(cal, accountId: "acct") == .userOverride)
    }

    @Test("Different accounts isolate overrides")
    func crossAccountIsolation() {
        resetStore()
        defer { resetStore() }

        let cal = makeCal(id: "c1", primary: true)
        CalendarVisibilityStore.setOverride(false, accountId: "acct-a", calendarId: "c1")

        #expect(CalendarVisibilityStore.isVisible(cal, accountId: "acct-a") == false)
        #expect(CalendarVisibilityStore.isVisible(cal, accountId: "acct-b") == true)
    }

    @Test("Different calendars on same account isolate overrides")
    func crossCalendarIsolation() {
        resetStore()
        defer { resetStore() }

        let cal1 = makeCal(id: "c1", primary: true)
        let cal2 = makeCal(id: "c2", primary: true)
        CalendarVisibilityStore.setOverride(false, accountId: "acct", calendarId: "c1")

        #expect(CalendarVisibilityStore.isVisible(cal1, accountId: "acct") == false)
        #expect(CalendarVisibilityStore.isVisible(cal2, accountId: "acct") == true)
    }

    @Test("Setting override to nil clears the entry")
    func clearOverride() {
        resetStore()
        defer { resetStore() }

        CalendarVisibilityStore.setOverride(true, accountId: "acct", calendarId: "c1")
        #expect(CalendarVisibilityStore.override(accountId: "acct", calendarId: "c1") == true)

        CalendarVisibilityStore.setOverride(nil, accountId: "acct", calendarId: "c1")
        #expect(CalendarVisibilityStore.override(accountId: "acct", calendarId: "c1") == nil)
    }

    @Test("providerDefault: primary: true → true, false → false, nil → false")
    func providerDefaultMatrix() {
        #expect(CalendarVisibilityStore.providerDefault(makeCal(id: "c", primary: true)) == true)
        #expect(CalendarVisibilityStore.providerDefault(makeCal(id: "c", primary: false)) == false)
        #expect(CalendarVisibilityStore.providerDefault(makeCal(id: "c", primary: nil)) == false)
    }

    @Test("providerDefault is independent of any override")
    func providerDefaultIgnoresOverride() {
        resetStore()
        defer { resetStore() }

        let cal = makeCal(id: "c", primary: false)
        CalendarVisibilityStore.setOverride(true, accountId: "acct", calendarId: "c")
        // Override flips isVisible to true, but providerDefault is the
        // pure-default signal — still false (non-primary).
        #expect(CalendarVisibilityStore.providerDefault(cal) == false)
        #expect(CalendarVisibilityStore.isVisible(cal, accountId: "acct") == true)
    }

    @Test("providerDefault ignores `selected` field — only primary matters")
    func providerDefaultIgnoresSelected() {
        // A non-primary calendar with selected: true is still hidden by default.
        let cal1 = makeCal(id: "c1", primary: false, selected: true)
        #expect(CalendarVisibilityStore.providerDefault(cal1) == false)

        // A primary calendar with selected: false is still visible by default.
        let cal2 = makeCal(id: "c2", primary: true, selected: false)
        #expect(CalendarVisibilityStore.providerDefault(cal2) == true)
    }
}
