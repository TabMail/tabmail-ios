/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// Tests for the iOS parity of TB's calendar_search RRULE surfacing.
//
// Background: Google's `events.list` with `singleEvents=true` returns each
// occurrence of a recurring event as its own row, with `recurrence` empty and
// `recurringEventId` pointing back to the master. Without enrichment the LLM
// sees only `(↻)` on every line — it can't tell a capped predecessor series
// from its open-ended successor. The user's "Weekly sync ends May 27" incident
// stemmed from this on the TB side; iOS has the same shape with Google.
//
// `CalendarToolHelpers.resolveMasterRecurrence` fetches each unique master
// once and returns id→master. `formatGroupedSummary` accepts that map and
// renders the master's rule in the tools' fields (#552),
// `(↻ {"freq":"WEEKLY","until":"…"})`, on every occurrence line.

@Suite("CalendarToolHelpers.resolveMasterRecurrence")
struct CalendarMasterRecurrenceResolveTests {

    private func makeAccount(id: String) -> Account {
        var a = Account(emailAddress: "test-\(id)@example.com", displayName: "Test", provider: .gmail)
        a.id = id
        return a
    }

    private func makeInstance(id: String, recurringEventId: String?) -> GCalEvent {
        GCalEvent(
            id: id, summary: "Weekly sync", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2026-05-13T17:00:00-07:00", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2026-05-13T17:45:00-07:00", date: nil, timeZone: nil),
            attendees: nil, organizer: nil,
            recurrence: nil, transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil,
            eventType: nil, iCalUID: nil, kind: nil, visibility: nil,
            recurringEventId: recurringEventId
        )
    }

    private func makeMaster(id: String, rrule: String) -> GCalEvent {
        GCalEvent(
            id: id, summary: "Weekly sync", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2026-04-08T17:00:00-07:00", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2026-04-08T17:45:00-07:00", date: nil, timeZone: nil),
            attendees: nil, organizer: nil,
            recurrence: [rrule], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        )
    }

    @Test("Resolves the master's RRULE for each unique recurringEventId")
    func resolvesMasterRRule() async {
        let provider = MockCalendarProvider()
        await provider.setGetEventResult(
            makeMaster(id: "master-abc", rrule: "RRULE:FREQ=WEEKLY;UNTIL=20260527T235959Z")
        )
        let account = makeAccount(id: "acct-1")
        let backends: [(provider: any CalendarProvider, account: Account)] = [(provider, account)]

        let events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (makeInstance(id: "master-abc_R20260513T170000", recurringEventId: "master-abc"), "acct-1", "cal-primary", "owner"),
            (makeInstance(id: "master-abc_R20260520T170000", recurringEventId: "master-abc"), "acct-1", "cal-primary", "owner"),
        ]

        let map = await CalendarToolHelpers.resolveMasterRecurrence(events: events, backends: backends)
        #expect(map["master-abc"]?.recurrence == ["RRULE:FREQ=WEEKLY;UNTIL=20260527T235959Z"])
        // Both instances refer to the SAME master — provider should be called exactly once.
        let callLog = await provider.callLog
        let getEventCalls = callLog.filter { $0.hasPrefix("getEvent") }
        #expect(getEventCalls.count == 1, "expected dedupe: 1 getEvent call, got \(getEventCalls)")
    }

    @Test("Deduplicates by (account, master) — two masters fetched once each")
    func dedupesAcrossMultipleMasters() async {
        let provider = MockCalendarProvider()
        // The mock returns the same result for every getEvent; that's enough
        // to verify dedupe by count, since we only care about call counts.
        await provider.setGetEventResult(
            makeMaster(id: "any", rrule: "RRULE:FREQ=WEEKLY")
        )
        let account = makeAccount(id: "acct-1")
        let backends: [(provider: any CalendarProvider, account: Account)] = [(provider, account)]

        // 4 instances spanning 2 distinct masters.
        let events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (makeInstance(id: "A_R1", recurringEventId: "master-A"), "acct-1", "cal", "owner"),
            (makeInstance(id: "A_R2", recurringEventId: "master-A"), "acct-1", "cal", "owner"),
            (makeInstance(id: "B_R1", recurringEventId: "master-B"), "acct-1", "cal", "owner"),
            (makeInstance(id: "B_R2", recurringEventId: "master-B"), "acct-1", "cal", "owner"),
        ]
        _ = await CalendarToolHelpers.resolveMasterRecurrence(events: events, backends: backends)
        let getEventCalls = await provider.callLog.filter { $0.hasPrefix("getEvent") }
        #expect(getEventCalls.count == 2, "expected 2 unique getEvent calls, got \(getEventCalls.count): \(getEventCalls)")
    }

    @Test("Returns empty map when no events reference a master")
    func emptyMapForNonRecurring() async {
        let provider = MockCalendarProvider()
        let account = makeAccount(id: "acct-1")
        let backends: [(provider: any CalendarProvider, account: Account)] = [(provider, account)]

        let events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (makeInstance(id: "evt-1", recurringEventId: nil), "acct-1", "cal", "owner"),
            (makeInstance(id: "evt-2", recurringEventId: nil), "acct-1", "cal", "owner"),
        ]
        let map = await CalendarToolHelpers.resolveMasterRecurrence(events: events, backends: backends)
        #expect(map.isEmpty)
        // Provider should not be hit at all.
        let getEventCalls = await provider.callLog.filter { $0.hasPrefix("getEvent") }
        #expect(getEventCalls.isEmpty)
    }

    @Test("Silently omits masters whose fetch fails — doesn't crash the whole search")
    func tolerantOfFetchFailures() async {
        let provider = MockCalendarProvider()
        await provider.setGetEventThrows(
            NSError(domain: "test", code: 404, userInfo: nil)
        )
        let account = makeAccount(id: "acct-1")
        let backends: [(provider: any CalendarProvider, account: Account)] = [(provider, account)]

        let events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (makeInstance(id: "evt-1", recurringEventId: "master-gone"), "acct-1", "cal", "owner"),
        ]
        let map = await CalendarToolHelpers.resolveMasterRecurrence(events: events, backends: backends)
        #expect(map.isEmpty)
    }

    @Test("Skips masters whose recurrence array has no RRULE entry (e.g. only EXDATE)")
    func skipsMastersWithoutRRule() async {
        let provider = MockCalendarProvider()
        // Master returned with only an EXDATE — no RRULE.
        await provider.setGetEventResult(GCalEvent(
            id: "master", summary: "x", location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil,
            recurrence: ["EXDATE:20260513T170000Z"], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        ))
        let account = makeAccount(id: "acct-1")
        let backends: [(provider: any CalendarProvider, account: Account)] = [(provider, account)]
        let events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (makeInstance(id: "evt-1", recurringEventId: "master"), "acct-1", "cal", "owner"),
        ]
        let map = await CalendarToolHelpers.resolveMasterRecurrence(events: events, backends: backends)
        #expect(map.isEmpty, "no RRULE in master.recurrence → no map entry")
    }
}

@Suite("CalendarToolHelpers.formatGroupedSummary uses seriesById for expanded instances")
struct CalendarMasterRecurrenceFormatTests {

    private func makeInstance(id: String, dateTime: String, recurringEventId: String?) -> GCalEvent {
        GCalEvent(
            id: id, summary: "Weekly sync", location: nil, description: nil,
            start: GCalDateTime(dateTime: dateTime, date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: dateTime.replacingOccurrences(of: "T17:00:00", with: "T17:45:00"), date: nil, timeZone: nil),
            attendees: nil, organizer: nil,
            recurrence: nil, transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil,
            eventType: nil, iCalUID: nil, kind: nil, visibility: nil,
            recurringEventId: recurringEventId
        )
    }

    @Test("Instance with recurringEventId + map entry renders the master's rule in the tools' fields")
    func rendersRuleFromMap() throws {
        // A weekly master at 17:00 in Los Angeles, its UNTIL one second before the occurrence slot
        // three weeks on (a split's cap): the last day it admits is the day before that slot.
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = la
        let firstDay = try #require(cal.date(byAdding: .day, value: 14, to: cal.startOfDay(for: Date())))
        let first = try #require(cal.date(bySettingHour: 17, minute: 0, second: 0, of: firstDay))
        let capSlot = try #require(cal.date(byAdding: .day, value: 21, to: first))
        let until = FixedDateFormat.formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt).string(from: capSlot.addingTimeInterval(-1))
        let lastDay = EKEventStoreHelper.dayKey(try #require(cal.date(byAdding: .day, value: -1, to: capSlot)), timeZone: la)
        let master = GCalEvent(
            id: "master-abc", summary: "Weekly sync", location: nil, description: nil,
            start: GCalDateTime(dateTime: first.iso8601String(), date: nil, timeZone: "America/Los_Angeles"),
            end: GCalDateTime(dateTime: first.addingTimeInterval(2700).iso8601String(), date: nil, timeZone: "America/Los_Angeles"),
            attendees: nil, organizer: nil,
            recurrence: ["RRULE:FREQ=WEEKLY;UNTIL=\(until)"], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        )
        let instance = makeInstance(id: "i1", dateTime: cal.date(byAdding: .day, value: 7, to: first)!.iso8601String(), recurringEventId: "master-abc")
        let out = CalendarToolHelpers.formatGroupedSummary(
            [(instance, "acct-1", "cal", "owner")], timeZone: la, seriesById: ["master-abc": master])
        #expect(out.contains("Weekly sync (↻ {\"freq\":\"WEEKLY\",\"until\":\"\(lastDay)\"})"),
                "expected the rule in the tools' fields, got: \(out)")
        #expect(!out.contains("RRULE"))
    }

    @Test("Instance with recurringEventId but NO map entry renders bare (↻) — never \"\"")
    func bareMarkerWhenNotEnriched() {
        let events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (makeInstance(id: "i1", dateTime: "2026-05-13T17:00:00-07:00", recurringEventId: "master-abc"),
             "acct-1", "cal", "owner")
        ]
        let out = CalendarToolHelpers.formatGroupedSummary(events, seriesById: [:])
        #expect(out.contains("Weekly sync (↻)"))
        #expect(!out.contains("Weekly sync (↻ "), "no RRULE means no enriched marker")
    }

    @Test("Master event (recurrence inline) takes priority over map")
    func inlineRecurrenceWinsOverMap() {
        let master = GCalEvent(
            id: "m1", summary: "Weekly sync", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2026-05-13T17:00:00-07:00", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2026-05-13T17:45:00-07:00", date: nil, timeZone: nil),
            attendees: nil, organizer: nil,
            recurrence: ["RRULE:FREQ=WEEKLY;COUNT=10"], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        )
        let events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (master, "acct-1", "cal", "owner")
        ]
        // Map points to a DIFFERENT rule — inline should win.
        let daily = GCalEvent(
            id: "m1", summary: "Weekly sync", location: nil, description: nil,
            start: master.start, end: master.end, attendees: nil, organizer: nil,
            recurrence: ["RRULE:FREQ=DAILY"], transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil
        )
        let out = CalendarToolHelpers.formatGroupedSummary(events, seriesById: ["m1": daily])
        #expect(out.contains("(↻ {\"freq\":\"WEEKLY\",\"count\":10})"))
        #expect(!out.contains("DAILY"))
    }

    @Test("Non-recurring event renders no marker at all")
    func nonRecurringNoMarker() {
        let events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (makeInstance(id: "i1", dateTime: "2026-05-13T17:00:00-07:00", recurringEventId: nil),
             "acct-1", "cal", "owner")
        ]
        let out = CalendarToolHelpers.formatGroupedSummary(events, seriesById: [:])
        #expect(!out.contains("(↻"))
    }
}

// MARK: - MockCalendarProvider test helpers used by this suite
//
// `setListCalendarsResult` / `setListEventsResult` live in
// CalendarVisibilityFilterTests.swift — don't redeclare them here. Only add
// the get-event helpers used by these tests.

extension MockCalendarProvider {
    func setGetEventResult(_ ev: GCalEvent) { getEventResult = ev }
    func setGetEventThrows(_ e: Error) { getEventThrows = e }
}
