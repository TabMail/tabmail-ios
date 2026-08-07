/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - R18c — the recurring-occurrence ADDRESS
//
// ONE root cause, two defects, and both are properties of the ADDRESS rather
// than of any classifier:
//
//   A recurring occurrence was addressed by a naive wall-clock string with no
//   timezone, and every consumer re-interpreted that string in a different
//   frame. `resolveInstanceId` then selected an occurrence by comparing the
//   first TEN CHARACTERS of that string against the first ten characters of the
//   provider's rendering of an instance start.
//
// **INVARIANT 1 (C3).** *No edit ever lands on an occurrence other than the one
// the user named.* Google renders `start.dateTime` in the EVENT's zone, so for a
// series whose event zone crosses the device's date boundary the day prefixes
// belong to different days: the comparison selected the PRECEDING occurrence and
// `PATCH`ed it with `sendUpdates: "all"`, mailing third parties an update that
// cannot be recalled. A second arm accepted `items.count == 1` as a match — a
// guess, in the one function whose whole job is to pick one occurrence out of
// many. Failing closed is always acceptable here; guessing never is.
//
// **INVARIANT 2 (never-drop exit 2).** *A failure WE caused is never retired as
// the provider's authoritative absence.* Every failure in `resolveInstanceId`
// threw `eventNotFound`, which `AccountManager.isCalendarNotFoundError` treats as
// provider-authoritative and retires the durable operation with "event not found
// on server". A malformed `recurrence_id` and an undecodable payload are
// statements about US. *"We could not determine the answer"* is not a
// provider-authoritative stale/no-op result.
//
// ⚠️ **THE OBVIOUS REMEDY FOR INVARIANT 2 IS REFUTED — do not re-derive it.**
// Making the local failure retryable means no terminal arm claims it, so it falls
// to `drainCalendarQueue`'s transient arm, which requeues AND does
// `failedAccounts.insert(accountId)`. A resolution failure is DETERMINISTIC, so
// it re-fails identically forever and head-of-line-blocks that account's calendar
// lane permanently. A wedge is in the same non-recoverable set as a dropped
// intention. Both available dispositions being wrong is the proof that the
// disposition was never the bug — so these tests assert on the ADDRESS, and the
// disposition assertions below exist only to pin that the three failure FACTS
// stay distinguishable.
//
// ⚠️ **TWO-SIDED (`MIS-030` / `feedback_non_vacuity_must_be_two_sided`).** "Refuses
// to resolve" is trivially satisfiable by a resolver that never resolves
// anything, so every refusal test here is paired with a positive one:
// `theNamedOccurrenceIsTheOneThatResolves`, `absenceAfterEnumerationISAuthoritative`,
// and `identityWhenTheDeclaredZoneIsTheMastersZone` are those controls.
//
// ⚠️ **RED-FIRST EVIDENCE** is recorded in the commit body: the fix was inverted
// (the resolver's instant comparison replaced by the pre-fix day-prefix +
// `count == 1` logic) and the failures observed. These tests pin the SYSTEM
// PROPERTY — which occurrence the wire mutation lands on, and which error fact
// each failure carries — not the mechanism that achieves it.

// MARK: - Fixed frames
//
// Every zone below is NAMED, never `.current`. A test whose expected value moves
// with the machine's timezone cannot distinguish "the frames agree" from "the
// frames are both wrong in the same direction", which is the exact defect.

private let vancouver = TimeZone(identifier: "America/Vancouver")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

/// 2026-05-20 09:00 in Vancouver (PDT, UTC−7) == 2026-05-21 01:00 in Tokyo (UTC+9).
/// The DAY differs between the two frames, which is what makes a day-prefix
/// comparison across them wrong rather than merely imprecise.
private func instant(_ naive: String, _ zone: TimeZone) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.timeZone = zone
    return f.date(from: naive)!
}

@Suite("Recurring occurrence address — selection")
struct RecurrenceOccurrenceSelectionTests {

    @Test("the occurrence the user named is the one that resolves, even when the event's zone puts it on a different DAY")
    func theNamedOccurrenceIsTheOneThatResolves() {
        // The address: 2026-05-20 09:00, declared in Vancouver.
        // Candidate `preceding` is the 2026-05-19 09:00 Vancouver occurrence,
        // which Google renders as 2026-05-20T01:00:00+09:00 — its day prefix
        // MATCHES the address's, and the pre-fix code returned it.
        let preceding = OccurrenceCandidate(
            id: "occ-preceding", instant: instant("2026-05-19T09:00:00", vancouver), dateOnly: nil)
        let named = OccurrenceCandidate(
            id: "occ-named", instant: instant("2026-05-20T09:00:00", vancouver), dateOnly: nil)

        let match = RecurrenceOccurrenceResolver.select(
            [preceding, named], recurrenceId: "2026-05-20T09:00:00", zone: vancouver)

        #expect(match == .resolved("occ-named"),
                "the address named the 2026-05-20 09:00 Vancouver occurrence; got \(match). Resolving to `occ-preceding` is a C3 wrong-occurrence mutation — it would be PATCHed with sendUpdates=all and the invitations cannot be recalled.")
    }

    @Test("a single candidate that does NOT answer to the address is not a match — the count==1 guess is gone")
    func aLoneNonMatchingCandidateIsNotAMatch() {
        // The pre-fix code's second arm: "if exactly one instance came back,
        // use it". One instance in the window is the COMMON case for a weekly
        // series, so this was not a rare fallback — it was the outcome whenever
        // the frames disagreed at all.
        let lone = OccurrenceCandidate(
            id: "occ-lone", instant: instant("2026-05-19T09:00:00", vancouver), dateOnly: nil)

        let match = RecurrenceOccurrenceResolver.select(
            [lone], recurrenceId: "2026-05-20T09:00:00", zone: vancouver)

        #expect(match == .absent,
                "a lone candidate whose start is NOT the named instant was accepted as the answer; got \(match). Being the only thing in the window is not evidence of being the thing that was named.")
    }

    @Test("two candidates answering to one address fail closed rather than picking the first")
    func ambiguityFailsClosed() {
        let a = OccurrenceCandidate(
            id: "occ-a", instant: instant("2026-05-20T09:00:00", vancouver), dateOnly: nil)
        let b = OccurrenceCandidate(
            id: "occ-b", instant: instant("2026-05-20T09:00:00", vancouver), dateOnly: nil)

        let match = RecurrenceOccurrenceResolver.select(
            [a, b], recurrenceId: "2026-05-20T09:00:00", zone: vancouver)

        #expect(match == .ambiguous(2),
                "two occurrences answer to this address and one was chosen anyway; got \(match). C3: failing closed is always acceptable, guessing is not.")
    }

    @Test("an unusable address is MALFORMED, never absent — 'we could not parse it' is not 'the server does not have it'")
    func malformedIsDistinctFromAbsent() {
        let only = OccurrenceCandidate(
            id: "occ-1", instant: instant("2026-05-20T09:00:00", vancouver), dateOnly: nil)
        for bad in ["garbage", "", "2026-13-99T99:99:99", "next tuesday"] {
            let match = RecurrenceOccurrenceResolver.select(
                [only], recurrenceId: bad, zone: vancouver)
            #expect(match == .malformed,
                    "'\(bad)' produced \(match). Collapsing it into .absent is what let a local parse failure be retired as the provider's authoritative 'event not found on server' — never-drop exit 2.")
        }
    }

    @Test("absence AFTER the provider enumerated the window IS authoritative — the two-sided control")
    func absenceAfterEnumerationISAuthoritative() {
        // The held direction (`MIS-026`). If this went the other way — if a
        // genuine no-match were also treated as undeterminable — the operation
        // would have no terminal arm, fall to the transient arm, and wedge the
        // account's calendar lane forever.
        let elsewhere = OccurrenceCandidate(
            id: "occ-elsewhere", instant: instant("2026-05-20T11:00:00", vancouver), dateOnly: nil)
        let match = RecurrenceOccurrenceResolver.select(
            [elsewhere], recurrenceId: "2026-05-20T09:00:00", zone: vancouver)
        #expect(match == .absent,
                "the provider listed the window and the named occurrence is not in it — that is a positive statement of absence and must stay distinguishable from .malformed; got \(match)")
    }

    @Test("an all-day occurrence is addressed by its literal DATE — a UTC offset never shifts it onto the adjacent day")
    func allDayIsAddressedByItsLiteralDate() {
        // A calendar DATE has no zone. Reading "2026-05-20T00:00:00" in Tokyo
        // and re-rendering it anywhere west of Tokyo lands on 2026-05-19, which
        // is a different occurrence of a daily all-day series.
        let day19 = OccurrenceCandidate(id: "occ-19", instant: nil, dateOnly: "2026-05-19")
        let day20 = OccurrenceCandidate(id: "occ-20", instant: nil, dateOnly: "2026-05-20")

        #expect(RecurrenceOccurrenceResolver.select(
            [day19, day20], recurrenceId: "2026-05-20T00:00:00", zone: tokyo) == .resolved("occ-20"))
        #expect(RecurrenceOccurrenceResolver.select(
            [day19, day20], recurrenceId: "2026-05-20", zone: vancouver) == .resolved("occ-20"))
    }

    @Test("a date-only address still resolves a TIMED occurrence, in the declared frame")
    func dateOnlyAddressResolvesATimedOccurrence() {
        // Capability the pre-fix code had (it recursed with a midnight form) and
        // which must survive: agents do sometimes pass a bare date. The
        // difference is that the day is now computed in ONE stated frame.
        let named = OccurrenceCandidate(
            id: "occ-named", instant: instant("2026-05-20T09:00:00", vancouver), dateOnly: nil)
        let other = OccurrenceCandidate(
            id: "occ-other", instant: instant("2026-05-21T09:00:00", vancouver), dateOnly: nil)

        #expect(RecurrenceOccurrenceResolver.select(
            [named, other], recurrenceId: "2026-05-20", zone: vancouver) == .resolved("occ-named"))
    }

    @Test("a trailing Z or fractional seconds does not make an address malformed")
    func toleratesTrailingPrecision() {
        let named = OccurrenceCandidate(
            id: "occ-named", instant: instant("2026-05-20T09:00:00", vancouver), dateOnly: nil)
        #expect(RecurrenceOccurrenceResolver.select(
            [named], recurrenceId: "2026-05-20T09:00:00.0000000", zone: vancouver) == .resolved("occ-named"))
    }
}

// MARK: - The wire: which occurrence actually gets mutated

@Suite("Recurring occurrence address — Google wire", .serialized)
struct GoogleOccurrenceAddressWireTests {

    private static let master = "m1"

    /// Two instances of a Tokyo-zoned daily series, rendered the way Google
    /// renders them: RFC 3339 in the EVENT's zone.
    ///   occ-preceding = 2026-05-19 09:00 Vancouver = 2026-05-20T01:00+09:00
    ///   occ-named     = 2026-05-20 09:00 Vancouver = 2026-05-21T01:00+09:00
    private static let instancesJSON = """
    {"items":[
      {"id":"occ-preceding","summary":"Standup","status":"confirmed",
       "start":{"dateTime":"2026-05-20T01:00:00+09:00","timeZone":"Asia/Tokyo"},
       "end":{"dateTime":"2026-05-20T01:30:00+09:00","timeZone":"Asia/Tokyo"},
       "recurringEventId":"m1"},
      {"id":"occ-named","summary":"Standup","status":"confirmed",
       "start":{"dateTime":"2026-05-21T01:00:00+09:00","timeZone":"Asia/Tokyo"},
       "end":{"dateTime":"2026-05-21T01:30:00+09:00","timeZone":"Asia/Tokyo"},
       "recurringEventId":"m1"}
    ]}
    """

    private static func masterJSON() -> String {
        """
        {"id":"m1","summary":"Standup","status":"confirmed",
         "start":{"dateTime":"2026-05-01T01:00:00+09:00","timeZone":"Asia/Tokyo"},
         "end":{"dateTime":"2026-05-01T01:30:00+09:00","timeZone":"Asia/Tokyo"},
         "recurrence":["RRULE:FREQ=DAILY"]}
        """
    }

    private static func eventJSON(id: String) -> String {
        """
        {"id":"\(id)","summary":"Standup","status":"confirmed",
         "start":{"dateTime":"2026-05-21T01:00:00+09:00","timeZone":"Asia/Tokyo"},
         "end":{"dateTime":"2026-05-21T01:30:00+09:00","timeZone":"Asia/Tokyo"},
         "recurringEventId":"m1"}
        """
    }

    @Test("the PATCH lands on the occurrence the user named, not on the one whose EVENT-zone day prefix happens to match")
    func theEditLandsOnTheNamedOccurrence() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        http.register(path: "/calendars/primary/events/\(Self.master)/instances", method: "GET",
                      response: .json(raw: Self.instancesJSON))
        http.register(path: "/calendars/primary/events/occ-named", method: "GET",
                      response: .json(raw: Self.eventJSON(id: "occ-named")))
        http.register(path: "/calendars/primary/events/occ-named", method: "PATCH",
                      response: .json(raw: Self.eventJSON(id: "occ-named")))
        http.register(path: "/calendars/primary/events/occ-preceding", method: "GET",
                      response: .json(raw: Self.eventJSON(id: "occ-preceding")))
        http.register(path: "/calendars/primary/events/occ-preceding", method: "PATCH",
                      response: .json(raw: Self.eventJSON(id: "occ-preceding")))
        http.register(path: "/calendars/primary/events/\(Self.master)", method: "GET",
                      response: .json(raw: Self.masterJSON()))

        let provider = GoogleCalendarProvider(accessToken: { _ in "tok" }, session: http.session)
        var patch = GCalEventInput()
        patch.summary = "Moved standup"

        _ = try await provider.updateOccurrence(
            calendarId: "primary", eventId: Self.master,
            recurrenceId: "2026-05-20T09:00:00", recurrenceIdZone: vancouver,
            event: patch, sendUpdates: "all")

        let patches = http.recordedCalls().filter { $0.method == "PATCH" }
        #expect(patches.count == 1, "expected exactly one PATCH, got \(patches.count)")
        guard patches.count == 1 else { return }
        #expect(patches[0].url.contains("occ-named"),
                "the edit was applied to \(patches[0].url). The user named the 2026-05-20 09:00 America/Vancouver occurrence; `occ-preceding` is the day before, and it went out with sendUpdates=all — a wrong-occurrence mutation mailed to every attendee, which nothing recovers.")
        #expect(!patches[0].url.contains("occ-preceding"))
    }

    @Test("a lone non-matching instance is NOT patched — nothing reaches the wire, and the absence is authoritative")
    func aLoneNonMatchingInstanceIsNotPatched() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }

        let loneJSON = """
        {"items":[
          {"id":"occ-preceding","summary":"Standup","status":"confirmed",
           "start":{"dateTime":"2026-05-20T01:00:00+09:00","timeZone":"Asia/Tokyo"},
           "end":{"dateTime":"2026-05-20T01:30:00+09:00","timeZone":"Asia/Tokyo"},
           "recurringEventId":"m1"}
        ]}
        """
        http.register(path: "/calendars/primary/events/\(Self.master)/instances", method: "GET",
                      response: .json(raw: loneJSON))
        http.register(path: "/calendars/primary/events/occ-preceding", method: "GET",
                      response: .json(raw: Self.eventJSON(id: "occ-preceding")))
        http.register(path: "/calendars/primary/events/occ-preceding", method: "PATCH",
                      response: .json(raw: Self.eventJSON(id: "occ-preceding")))
        http.register(path: "/calendars/primary/events/\(Self.master)", method: "GET",
                      response: .json(raw: Self.masterJSON()))

        let provider = GoogleCalendarProvider(accessToken: { _ in "tok" }, session: http.session)

        var thrown: Error?
        do {
            _ = try await provider.updateOccurrence(
                calendarId: "primary", eventId: Self.master,
                recurrenceId: "2026-05-20T09:00:00", recurrenceIdZone: vancouver,
                event: GCalEventInput(), sendUpdates: "all")
        } catch {
            thrown = error
        }

        #expect(thrown != nil, "the named occurrence is not in the window; resolving anyway is the count==1 guess")
        #expect(!http.recordedCalls().contains { $0.method == "PATCH" },
                "an occurrence the user did not name was PATCHed with sendUpdates=all")

        // The HELD direction: the provider enumerated the window and the
        // occurrence is not in it, so this absence IS provider-authoritative and
        // the operation may be retired with it. Anything else has no terminal arm
        // and wedges the account's calendar lane.
        if let thrown {
            #expect(AccountManager.isCalendarNotFoundError(thrown),
                    "a genuine no-match after enumeration must remain authoritative-absent, got \(thrown)")
        }
    }

    @Test("an unusable recurrence_id is never retired as the PROVIDER's absence, and never falls to the wedging arm")
    func anUnusableAddressIsNeitherAbsentNorTransient() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/calendars/primary/events/\(Self.master)", method: "GET",
                      response: .json(raw: Self.masterJSON()))

        let provider = GoogleCalendarProvider(accessToken: { _ in "tok" }, session: http.session)

        var thrown: Error?
        do {
            _ = try await provider.updateOccurrence(
                calendarId: "primary", eventId: Self.master,
                recurrenceId: "not-a-date", recurrenceIdZone: vancouver,
                event: GCalEventInput(), sendUpdates: "all")
        } catch {
            thrown = error
        }

        let error = try #require(thrown)
        #expect(!AccountManager.isCalendarNotFoundError(error),
                "OUR parse failure was classified as the provider saying the event does not exist — the durable edit is retired with 'event not found on server' and the user's intention is gone. That is never-drop exit 2. Got \(error)")
        #expect(AccountManager.isCalendarUnsupportedError(error),
                "no terminal arm claims this error, so it falls to `drainCalendarQueue`'s transient arm, which requeues AND inserts the account into `failedAccounts`. The failure is deterministic, so that is a permanent head-of-line block on the account's calendar lane — the wedge. Got \(error)")
        if case CalendarProviderError.notSupported(let reason) = error {
            #expect(reason.contains("not-a-date"),
                    "a terminal retirement must carry a reason naming the offending value so the agent can correct it; got '\(reason)'")
        } else {
            Issue.record("expected CalendarProviderError.notSupported, got \(error)")
        }
        #expect(!http.recordedCalls().contains { $0.method == "PATCH" })
    }
}

// MARK: - CalDAV: RECURRENCE-ID must be expressed in the master's frame

@Suite("Recurring occurrence address — CalDAV override frame")
struct CalDAVOccurrenceFrameTests {

    @Test("a Vancouver-declared address becomes the master's Tokyo wall clock before it is written as RECURRENCE-ID")
    func overrideIsKeyedInTheMastersFrame() throws {
        let converted = try #require(CalDAVProvider.recurrenceIdInMasterFrame(
            "2026-05-20T09:00:00", declaredZone: vancouver, kind: .zoned("Asia/Tokyo")))
        #expect(converted == "2026-05-21T01:00:00",
                "got '\(converted)'. Writing the declared wall clock verbatim under TZID=Asia/Tokyo keys the override to 2026-05-20 01:00 Tokyo — a wall clock no occurrence of this series has, so the user's edit lands on an orphan VEVENT (or, if it collides, on a DIFFERENT occurrence).")

        let block = CalDAVProvider.buildOverrideVEvent(
            patch: GCalEventInput(), uid: "uid-1", recurrenceId: converted, kind: .zoned("Asia/Tokyo"))
        #expect(block.contains("RECURRENCE-ID;TZID=Asia/Tokyo:20260521T010000"),
                "override block did not carry the master-frame RECURRENCE-ID:\n\(block)")
    }

    @Test("identity when the declared zone IS the master's zone — the single-timezone user sees no change")
    func identityWhenTheDeclaredZoneIsTheMastersZone() throws {
        let same = try #require(CalDAVProvider.recurrenceIdInMasterFrame(
            "2026-05-20T09:00:00", declaredZone: tokyo, kind: .zoned("Asia/Tokyo")))
        #expect(same == "2026-05-20T09:00:00")
    }

    @Test("an all-day master's RECURRENCE-ID is never offset-shifted")
    func allDayIsNeverShifted() throws {
        let allDay = try #require(CalDAVProvider.recurrenceIdInMasterFrame(
            "2026-05-20T00:00:00", declaredZone: tokyo, kind: .allDay))
        #expect(allDay == "2026-05-20T00:00:00",
                "a DATE has no zone; shifting it by an offset moves the override onto the adjacent day's occurrence")
    }

    @Test("an unresolvable master TZID refuses rather than falling back to the raw digits")
    func unknownMasterZoneFailsClosed() {
        #expect(CalDAVProvider.recurrenceIdInMasterFrame(
            "2026-05-20T09:00:00", declaredZone: vancouver, kind: .zoned("Pacific Standard Time")) == nil,
                "falling back to the raw digits IS the pre-fix defect — it writes a plausible-looking RECURRENCE-ID for a wall clock we never established")
    }
}

// MARK: - The durable operation carries its frame all the way to the provider

@Suite("Recurring occurrence address — the declared frame reaches the provider", .serialized, .processGlobalState)
struct CalendarQueueRecurrenceFrameTests {

    private func makeTestDB(accountId: String) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: .gmail)
            acc.id = accountId
            try acc.insert(db)
        }
        return (pool, dir, previous)
    }

    private func anyEvent() -> GCalEvent {
        GCalEvent(
            id: "occ-1", summary: "Standup", location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil,
            recurrence: nil, transparency: nil, status: "confirmed",
            htmlLink: nil, created: nil, updated: nil)
    }

    @Test("the operation's `timezone` argument reaches updateOccurrence as the recurrence_id's frame")
    func declaredZoneReachesUpdateOccurrence() async throws {
        let accountId = "cal-r18c-occ"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await mock.setUpdateOccurrenceResult(anyEvent())
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let op = PendingCalendarOperation(
            operationType: .edit, accountId: accountId, eventId: "m1",
            calendarId: "primary",
            arguments: [
                "edit_scope": .string("this_only"),
                "recurrence_id": .string("2026-05-20T09:00:00"),
                "timezone": .string("Asia/Tokyo"),
                "title": .string("Moved standup"),
            ])
        try await pool.write { db in try op.insert(db) }

        await AccountManager.shared.drainCalendarQueue()

        let calls = await mock.updatedOccurrences
        #expect(calls.count == 1, "expected one updateOccurrence, got \(calls.count)")
        guard calls.count == 1 else { return }
        #expect(calls[0].recurrenceId == "2026-05-20T09:00:00")
        #expect(calls[0].recurrenceIdZone.identifier == "Asia/Tokyo",
                "got \(calls[0].recurrenceIdZone.identifier). `calendar_event_edit`'s schema publishes that every naive ISO8601 argument is read in `timezone`, and `formatDetailedEvent` MINTS start_iso in that same zone — dropping it on the way to the provider is what made one naive string mean three different instants across three providers.")
    }

    @Test("with no `timezone` argument the frame is the device zone — the default is stated, not accidental")
    func absentTimezoneMeansTheDeviceZone() async throws {
        let accountId = "cal-r18c-occ-default"
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await mock.setSplitSeriesResult(anyEvent())
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let op = PendingCalendarOperation(
            operationType: .edit, accountId: accountId, eventId: "m1",
            calendarId: "primary",
            arguments: [
                "edit_scope": .string("this_and_following"),
                "recurrence_id": .string("2026-05-20T09:00:00"),
                "title": .string("Moved standup"),
            ])
        try await pool.write { db in try op.insert(db) }

        await AccountManager.shared.drainCalendarQueue()

        let calls = await mock.splitSeriesCalls
        #expect(calls.count == 1, "expected one splitSeries, got \(calls.count)")
        guard calls.count == 1 else { return }
        #expect(calls[0].recurrenceIdZone.identifier == TimeZone.current.identifier,
                "splitSeries takes the SAME recurrence_id off the SAME durable row as updateOccurrence; honouring the declared frame in only one of them would make one argument mean two instants depending on edit_scope")
    }
}

// MARK: - R18d — the MINT site of an ALL-DAY occurrence address
//
// The suites above pin what the RESOLVER does with an address. This one pins the
// address the app HANDS the agent in the first place, for the one event shape
// whose address is frame-free by definition.
//
// **INVARIANT.** *An all-day event's rendered `start_iso` names the provider's
// own calendar date, whatever display timezone the output is rendered in.*
//
// RFC 5545 §3.3.4's `DATE` value type carries no zone, and Google/Graph both hand
// it over as a bare `yyyy-MM-dd`. Until round 18d the all-day path nonetheless
// went through a zone conversion twice: `GCalEvent.parseDateOnly` fixed the date
// to midnight in `.current` (the DEVICE zone) and
// `EKEventStoreHelper.toNaiveISO` re-rendered that instant in the resolved
// DISPLAY zone. Any display zone west of the device zone pushes the wall clock
// back past midnight, so `start_iso` names the PREVIOUS DAY.
//
// **Why that is C3 and not cosmetic.** `CalendarEventEditTool` documents
// `recurrence_id` as "the `start_iso` of the target occurrence", and
// `RecurrenceOccurrenceResolver`'s rule 3 matches an all-day candidate on its
// literal `dateOnly` against `recurrenceId.prefix(10)`. On an all-day DAILY
// series the shifted date answers to the PRECEDING occurrence, and
// `updateOccurrence` `PATCH`es it with `sendUpdates: "all"`. On `splitSeries`
// the same shift caps the master a day early through an irreversible-family PUT.
// `allDayShiftedAddressResolvesThePrecedingOccurrence` below is the machine-
// checkable statement of that consequence — it is what makes this a C3 test and
// not a formatting test.
//
// ⚠️ **TWO-SIDED (`MIS-030`).** "The date never moves" is satisfiable by a
// formatter that emits nothing, so `allDayStartIsoStillCarriesTheDate` asserts
// the key is present and carries the right digits, and
// `timedStartIsoStillFollowsTheDisplayZone` is the negative control proving the
// fix did not flatten the TIMED path into the same frame-free treatment.
//
// ⚠️ **Every zone here is NAMED and the spread spans the whole offset range
// (−12 … +14).** The pre-fix error is `displayOffset − deviceOffset`, so a test
// that used one fixed display zone would be red or green depending on the
// machine the suite runs on. With both extremes in the list at least one entry
// shifts for every possible device zone, which is what makes the red proof
// independent of the simulator's locale.

private let allDayProbeZones: [String] = [
    "Etc/GMT+12",          // UTC−12, the western extreme
    "Pacific/Honolulu",    // UTC−10
    "America/Vancouver",   // UTC−7 (PDT)
    "UTC",
    "Asia/Tokyo",          // UTC+9
    "Pacific/Kiritimati",  // UTC+14, the eastern extreme
]

@Suite("All-day occurrence address — the date is frame-free at the mint site")
struct AllDayOccurrenceAddressMintTests {

    private func allDayEvent(id: String = "allday-1", start: String, end: String) -> GCalEvent {
        GCalEvent(
            id: id, summary: "Company holiday", location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: start, timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: end, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=DAILY"],
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
    }

    private func line(_ output: String, _ key: String) -> String? {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("\(key): ") }
            .map { String($0.dropFirst(key.count + 2)) }
    }

    @Test("an all-day event's start_iso names the provider's calendar date in EVERY display timezone")
    func allDayDateNeverMovesWithTheDisplayZone() {
        let event = allDayEvent(start: "2026-05-20", end: "2026-05-21")
        for id in allDayProbeZones {
            let tz = TimeZone(identifier: id)!
            let output = CalendarToolHelpers.formatDetailedEvent(event, timeZone: tz)
            let start = line(output, "start_iso")
            #expect(start?.hasPrefix("2026-05-20") == true,
                    "display zone \(id) (device \(TimeZone.current.identifier)): start_iso is \(start ?? "<absent>"), not the provider's date 2026-05-20. A calendar DATE has no zone; shifting one by a UTC offset is how an all-day recurrence_id names the adjacent day's occurrence.")
            let end = line(output, "end_iso")
            #expect(end?.hasPrefix("2026-05-21") == true,
                    "display zone \(id): end_iso is \(end ?? "<absent>"), not the provider's date 2026-05-21")
        }
    }

    @Test("the shifted address resolves the PRECEDING occurrence — why the frame error is C3, not cosmetic")
    func allDayShiftedAddressResolvesThePrecedingOccurrence() {
        // A daily all-day series. These are the candidates Google's `instances`
        // call returns, keyed on their literal DATE.
        let candidates = [
            OccurrenceCandidate(id: "occ-05-19", instant: nil, dateOnly: "2026-05-19"),
            OccurrenceCandidate(id: "occ-05-20", instant: nil, dateOnly: "2026-05-20"),
            OccurrenceCandidate(id: "occ-05-21", instant: nil, dateOnly: "2026-05-21"),
        ]
        // The address the agent copies out of `start_iso`. This is the whole
        // point: the resolver is CORRECT — it faithfully resolves whatever date
        // it is handed — so a mint site that hands it the previous day gets a
        // confident, well-formed mutation of the wrong occurrence.
        #expect(RecurrenceOccurrenceResolver.select(candidates, recurrenceId: "2026-05-19T00:00:00", zone: .current)
                == .resolved("occ-05-19"))
        #expect(RecurrenceOccurrenceResolver.select(candidates, recurrenceId: "2026-05-20T00:00:00", zone: .current)
                == .resolved("occ-05-20"))

        // And the mint site must never produce the first of those two for an
        // event whose provider date is 2026-05-20 — in any display zone.
        let event = allDayEvent(start: "2026-05-20", end: "2026-05-21")
        for id in allDayProbeZones {
            let tz = TimeZone(identifier: id)!
            let minted = line(CalendarToolHelpers.formatDetailedEvent(event, timeZone: tz), "start_iso") ?? ""
            let match = RecurrenceOccurrenceResolver.select(candidates, recurrenceId: minted, zone: tz)
            #expect(match == .resolved("occ-05-20"),
                    "display zone \(id): the minted address '\(minted)' resolved \(match). Anything other than occ-05-20 is a wrong-target PATCH with sendUpdates=all.")
        }
    }

    @Test("start_iso is still emitted and still carries the date — the non-vacuity control")
    func allDayStartIsoStillCarriesTheDate() {
        let output = CalendarToolHelpers.formatDetailedEvent(
            allDayEvent(start: "2026-05-20", end: "2026-05-21"),
            timeZone: TimeZone(identifier: "Etc/GMT+12")!)
        #expect(line(output, "start_iso") == "2026-05-20T00:00:00")
        #expect(line(output, "end_iso") == "2026-05-21T00:00:00")
        #expect(output.contains("all_day: yes"))
    }

    @Test("a TIMED event's start_iso still follows the display zone — the fix did not flatten the timed path")
    func timedStartIsoStillFollowsTheDisplayZone() {
        // 2026-05-20 17:00 Vancouver == 2026-05-21 09:00 Tokyo. A timed value IS
        // frame-bearing, so it MUST move with the display zone; only the DATE
        // type is frame-free.
        let event = GCalEvent(
            id: "timed-1", summary: "Standup", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2026-05-21T00:00:00Z", date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: "2026-05-21T01:00:00Z", date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil
        )
        #expect(line(CalendarToolHelpers.formatDetailedEvent(event, timeZone: vancouver), "start_iso")
                == "2026-05-20T17:00:00")
        #expect(line(CalendarToolHelpers.formatDetailedEvent(event, timeZone: tokyo), "start_iso")
                == "2026-05-21T09:00:00")
        #expect(CalendarToolHelpers.formatDetailedEvent(event, timeZone: tokyo).contains("all_day: no"))
    }
}
