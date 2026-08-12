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

// MARK: - An RRULE UNTIL's value type belongs to the resource's DTSTART, not to the tool call
//
// **INVARIANT (a property of the bytes that reach the wire, not of any variable):** *the `UNTIL` an
// edit emits has the same VALUE TYPE as the `DTSTART` the same edit leaves on the resource.*
// RFC 5545 §3.3.10 — "The value of the UNTIL rule part MUST have the same value type as the DTSTART
// property."
//
// The defect this pins was not in `validatedRRuleUntil`, which renders whichever type it is asked
// for and is unit-tested both ways in `GCalEventInputICSTests.untilIsValidated`. It was in WHO
// decides: `AccountManagerCalendarQueue`'s `.edit` case read `all_day` off the tool arguments, so an
// edit that changes only the recurrence — the ordinary "make it end on Jan 1" turn, which has no
// reason to restate `all_day` — passed `nil`, `buildGCalEventInput` read that as `false`, and a UTC
// DATE-TIME `UNTIL` was written against a `DTSTART;VALUE=DATE:`. `mergePatchIntoICS` carries no start
// of its own, so the mismatch is invisible from every line of the patch.
//
// ⚠️ **THE ASSERTIONS RUN ON THE EMITTED RRULE, AND FOR THE UPDATE PATH ON THE MERGED ICS DOCUMENT.**
// A test on `validatedRRuleUntil`'s return is what let this through (`MIS-015`): the function was
// already correct for the argument it was given. `mergedICSValueTypesAgree` is the strongest form
// available without a network — it runs the captured patch through the same `mergePatchIntoICS` the
// CalDAV provider uses and asserts the DTSTART and UNTIL in ONE document agree, which is the property
// a strict server checks.
//
// ⚠️ **TWO-SIDED (`MIS-030`).** "The UNTIL is a bare DATE" is satisfiable by hardcoding the all-day
// form, so `untilValueTypeFollowsTimedResource` is the mirror: the same absent `all_day` against a
// TIMED resource must still produce a UTC DATE-TIME. And `explicitAllDayIsStillHonoured` /
// `noExtraFetchWhenNoUntilIsAtStake` are the bounds — the fix must not start overriding a model that
// DID state the type, and must not put a `getEvent` on edits that emit no UNTIL at all.

@Suite("RRULE UNTIL value type — decided by the resource, not by the tool call", .serialized, .processGlobalState)
struct CalendarQueueUntilValueTypeTests {

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

    /// The resource as the SERVER has it. `GCalDateTime.date` is populated only for an all-day event
    /// on every provider, so this is exactly what `getEvent` hands the queue.
    private func allDayResource() -> GCalEvent {
        GCalEvent(
            id: "master-1", summary: "Company holiday", location: nil, description: nil,
            start: GCalDateTime(dateTime: nil, date: "2026-06-01", timeZone: nil),
            end: GCalDateTime(dateTime: nil, date: "2026-06-02", timeZone: nil),
            attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=DAILY"],
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil)
    }

    private func timedResource() -> GCalEvent {
        GCalEvent(
            id: "master-1", summary: "Standup", location: nil, description: nil,
            start: GCalDateTime(dateTime: "2026-06-01T09:00:00-07:00", date: nil, timeZone: "America/Vancouver"),
            end: GCalDateTime(dateTime: "2026-06-01T09:30:00-07:00", date: nil, timeZone: "America/Vancouver"),
            attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=DAILY"],
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil)
    }

    private func anyEvent() -> GCalEvent {
        GCalEvent(
            id: "master-1", summary: "Standup", location: nil, description: nil,
            start: nil, end: nil, attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: nil, htmlLink: nil, created: nil, updated: nil)
    }

    /// Drain one `.edit` against a mock whose `getEvent` returns `resource`, and report everything the
    /// wire saw plus whether the durable row survived.
    private func drainOneEdit(
        accountId: String,
        arguments: [String: JSONValue],
        resource: GCalEvent?,
        getEventThrows: Error? = nil
    ) async throws -> (updates: [(calendarId: String, eventId: String, event: GCalEventInput, sendUpdates: String)],
                       splits: [(calendarId: String, eventId: String, recurrenceId: String, recurrenceIdZone: TimeZone, patch: GCalEventInput, sendUpdates: String)],
                       getEventCalls: Int,
                       remaining: Int,
                       rows: [PendingCalendarOperation]) {
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        if let resource { await mock.setGetEventResult(resource) }
        if let getEventThrows { await mock.setGetEventThrows(getEventThrows) }
        await mock.setUpdateEventResult(anyEvent())
        await mock.setSplitSeriesResult(anyEvent())
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let op = PendingCalendarOperation(
            operationType: .edit, accountId: accountId, eventId: "master-1",
            calendarId: "primary", arguments: arguments)
        try await pool.write { db in try op.insert(db) }

        await AccountManager.shared.drainCalendarQueue()

        let log = await mock.callLog
        let rows = try await pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        return (await mock.updatedEvents,
                await mock.splitSeriesCalls,
                log.filter { $0.hasPrefix("getEvent(") }.count,
                rows.count,
                rows)
    }

    /// The UNTIL parameter of the single emitted RRULE, or nil.
    private func untilOf(_ input: GCalEventInput?) -> String? {
        guard let rule = input?.recurrence?.first(where: { $0.uppercased().hasPrefix("RRULE:") }) else { return nil }
        return rule.split(separator: ";").first { $0.uppercased().hasPrefix("UNTIL=") }
            .map { String($0.dropFirst("UNTIL=".count)) }
    }

    /// An edit that only moves the end of the series — no `all_day`, no `start_iso`. This is the
    /// argument set the defect needed, and it is the ordinary one.
    private func untilOnlyArgs(scope: String? = nil) -> [String: JSONValue] {
        var args: [String: JSONValue] = [
            "recurrence": .dictionary([
                "freq": .string("DAILY"),
                "until": .string("2027-01-01"),
            ]),
            "timezone": .string("America/Vancouver"),
        ]
        if let scope {
            args["edit_scope"] = .string(scope)
            args["recurrence_id"] = .string("2026-06-10T00:00:00")
        }
        return args
    }

    @Test("an all-day resource gets a bare-DATE UNTIL when the edit does not restate all_day")
    func untilValueTypeFollowsAllDayResource() async throws {
        let r = try await drainOneEdit(
            accountId: "cal-until-allday", arguments: untilOnlyArgs(), resource: allDayResource())
        #expect(r.updates.count == 1, "setup: the drain never reached updateEvent (got \(r.updates.count))")
        guard r.updates.count == 1 else { return }
        let until = untilOf(r.updates[0].event)
        #expect(until == "20270101",
                "got UNTIL=\(until ?? "<absent>"). The resource's DTSTART is VALUE=DATE, so RFC 5545 §3.3.10 requires a bare DATE; a UTC DATE-TIME here is the value-type mismatch a strict server rejects, and it is invisible in the patch because mergePatchIntoICS leaves the server's DTSTART alone.")
        #expect(r.getEventCalls == 1, "the value type must be LEARNED from the resource, not assumed")
    }

    @Test("the merged ICS document's DTSTART and UNTIL agree on their value type")
    func mergedICSValueTypesAgree() async throws {
        let r = try await drainOneEdit(
            accountId: "cal-until-ics", arguments: untilOnlyArgs(), resource: allDayResource())
        #expect(r.updates.count == 1, "setup: the drain never reached updateEvent")
        guard r.updates.count == 1 else { return }
        // The master exactly as a CalDAV server stores an all-day daily series.
        let masterICS = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        BEGIN:VEVENT\r
        UID:master-1\r
        DTSTART;VALUE=DATE:20260601\r
        DTEND;VALUE=DATE:20260602\r
        RRULE:FREQ=DAILY\r
        SUMMARY:Company holiday\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let merged = CalDAVProvider.mergePatchIntoICS(masterICS, patch: r.updates[0].event)
        let lines = merged.split(whereSeparator: \.isNewline).map(String.init)
        let dtstart = lines.first { $0.hasPrefix("DTSTART") }
        let rrule = lines.first { $0.hasPrefix("RRULE:") }
        #expect(dtstart?.contains("VALUE=DATE") == true,
                "setup: the merge changed the master's DTSTART value type (\(dtstart ?? "<absent>")), so this document proves nothing")
        #expect(rrule?.contains("UNTIL=20270101") == true,
                "the resource carries a DATE DTSTART and the rule carries \(rrule ?? "<absent>"). One document, two value types — this is the exact byte sequence §3.3.10 forbids.")
        // The UNTIL is compared as an EXTRACTED VALUE, never as a substring of the line. Both naive
        // substring forms are wrong in opposite directions: `contains("T") == false` can never hold
        // because the keyword `UNTIL` itself contains a T, and `contains("UNTIL=20270101") == true`
        // holds just as well for `UNTIL=20270101T000000Z`. Pull the value out and compare it whole.
        let untilValue = (rrule?.hasPrefix("RRULE:") == true ? String(rrule!.dropFirst("RRULE:".count)) : (rrule ?? ""))
            .split(separator: ";").map(String.init)
            .first { $0.hasPrefix("UNTIL=") }
            .map { String($0.dropFirst("UNTIL=".count)) }
        #expect(untilValue == "20270101",
                "the UNTIL value is \(untilValue ?? "<absent>") in \(rrule ?? "<absent>") — a DATE-TIME against this document's VALUE=DATE DTSTART.")
    }

    @Test("a TIMED resource still gets a UTC DATE-TIME UNTIL — the fix did not flatten every event to all-day")
    func untilValueTypeFollowsTimedResource() async throws {
        let r = try await drainOneEdit(
            accountId: "cal-until-timed", arguments: untilOnlyArgs(), resource: timedResource())
        #expect(r.updates.count == 1, "setup: the drain never reached updateEvent")
        guard r.updates.count == 1 else { return }
        let until = untilOf(r.updates[0].event)
        #expect(until?.hasSuffix("Z") == true,
                "got UNTIL=\(until ?? "<absent>"). A zoned DTSTART requires a UTC DATE-TIME UNTIL; a bare DATE here is the mirror-image defect, not the fix.")
        #expect(until?.contains("T") == true, "got UNTIL=\(until ?? "<absent>")")
        #expect(r.getEventCalls == 1)
    }

    @Test("a this_and_following split writes the master's value type into the successor's rule")
    func splitSuccessorUntilMatchesTheAllDayMaster() async throws {
        let r = try await drainOneEdit(
            accountId: "cal-until-split",
            arguments: untilOnlyArgs(scope: "this_and_following"),
            resource: allDayResource())
        #expect(r.splits.count == 1, "setup: the drain never reached splitSeries (got \(r.splits.count))")
        guard r.splits.count == 1 else { return }
        let until = untilOf(r.splits[0].patch)
        #expect(until == "20270101",
                "got UNTIL=\(until ?? "<absent>"). CalDAV's buildNewSeriesInput prefers patch.recurrence over its own stripped rule while forcing the successor's DTSTART to the master's all-day form, so a mismatched pair here lands AFTER the irreversible cap PUT and its rollback is best-effort.")
    }

    @Test("no extra fetch on an edit that emits no UNTIL")
    func noExtraFetchWhenNoUntilIsAtStake() async throws {
        // A title change: no recurrence at all.
        let title = try await drainOneEdit(
            accountId: "cal-until-none",
            arguments: ["title": .string("Renamed")],
            resource: allDayResource())
        #expect(title.getEventCalls == 0, "an edit with no recurrence paid a round trip")
        #expect(title.updates.count == 1)

        // A recurrence whose COUNT wins over UNTIL in buildGCalEventInput — the rule emits no UNTIL,
        // so its value type is not at stake and nothing needs to be learned.
        let counted = try await drainOneEdit(
            accountId: "cal-until-count",
            arguments: ["recurrence": .dictionary([
                "freq": .string("WEEKLY"),
                "count": .int(10),
                "until": .string("2027-01-01"),
            ])],
            resource: allDayResource())
        #expect(counted.getEventCalls == 0, "COUNT suppresses the UNTIL, so no fetch is warranted")
        #expect(untilOf(counted.updates.first?.event) == nil,
                "setup: the producer emitted an UNTIL alongside COUNT, so the predicate's COUNT case is wrong")
    }

    @Test("an explicitly stated all_day is still honoured, and costs no fetch")
    func explicitAllDayIsStillHonoured() async throws {
        // The agent converting a timed series to all-day states `all_day` AND a date. Overriding it
        // from the (still timed) resource would break the conversion.
        let r = try await drainOneEdit(
            accountId: "cal-until-explicit",
            arguments: [
                "all_day": .bool(true),
                "start_iso": .string("2026-06-01"),
                "recurrence": .dictionary([
                    "freq": .string("DAILY"),
                    "until": .string("2027-01-01"),
                ]),
            ],
            resource: timedResource())
        #expect(r.getEventCalls == 0, "the model stated the type; asking the server is both wasteful and wrong")
        #expect(r.updates.count == 1)
        guard r.updates.count == 1 else { return }
        #expect(untilOf(r.updates[0].event) == "20270101")
        #expect(r.updates[0].event.startDate == "2026-06-01", "the declared conversion to all-day was dropped")
    }

    @Test("a failed resource read keeps the edit queued rather than guessing a value type")
    func failedResourceReadKeepsTheEditQueued() async throws {
        let r = try await drainOneEdit(
            accountId: "cal-until-throws",
            arguments: untilOnlyArgs(),
            resource: nil,
            getEventThrows: URLError(.notConnectedToInternet))
        #expect(r.updates.isEmpty,
                "an edit whose value type could not be established still reached the wire — a guessed type is the same wrong write, chosen by us instead of the model")
        #expect(r.remaining == 1,
                "the durable row was deleted on a transient read failure; never-drop clause 2 makes 'we could not determine the answer' retryable")
        // `remaining == 1` alone is not enough: a terminal arm RETIRES the row in place
        // (`status = failed`, R16-1) instead of deleting it, which would still count as one row while
        // meaning the user's edit will never run again.
        #expect(r.rows.first?.status == PendingStatus.queued.rawValue,
                "the row survived but was retired: status=\(r.rows.first?.status ?? "<none>") reason=\(r.rows.first?.failureReason ?? "<none>")")
        #expect(r.rows.first?.failureReason == nil)
    }

    @Test("recurrenceUntilIsAtStake mirrors the producer's own UNTIL branch")
    func recurrenceUntilAtStakePredicate() {
        let until: JSONValue = .string("2027-01-01")
        // At stake: a legal FREQ plus an UNTIL string.
        #expect(CalendarToolHelpers.recurrenceUntilIsAtStake(
            ["recurrence": .dictionary(["freq": .string("daily"), "until": until])]))
        // Not at stake — each for a reason the producer shares.
        #expect(!CalendarToolHelpers.recurrenceUntilIsAtStake(["title": .string("x")]),
                "no recurrence at all")
        #expect(!CalendarToolHelpers.recurrenceUntilIsAtStake(
            ["recurrence": .dictionary(["freq": .string("NOTAFREQ"), "until": until])]),
                "an unvalidated FREQ drops the whole RRULE, so there is no UNTIL")
        #expect(!CalendarToolHelpers.recurrenceUntilIsAtStake(
            ["recurrence": .dictionary(["freq": .string("DAILY")])]),
                "no until key")
        #expect(!CalendarToolHelpers.recurrenceUntilIsAtStake(
            ["recurrence": .dictionary(["freq": .string("DAILY"), "count": .int(5), "until": until])]),
                "an integer COUNT wins over UNTIL in buildGCalEventInput")
        #expect(!CalendarToolHelpers.recurrenceUntilIsAtStake(
            ["recurrence": .dictionary(["freq": .string("DAILY"), "count": .double(5), "until": until])]),
                "a double COUNT is the producer's second case and wins too")
        // A STRING count is NOT one of the producer's two COUNT cases, so it does not suppress the
        // UNTIL there and must not suppress the fetch here. This is the asymmetry a predicate written
        // from the schema instead of from the producer would get wrong.
        #expect(CalendarToolHelpers.recurrenceUntilIsAtStake(
            ["recurrence": .dictionary(["freq": .string("DAILY"), "count": .string("5"), "until": until])]),
                "a string count does not reach the producer's COUNT branch, so the UNTIL is still emitted")
    }
}

extension MockCalendarProvider {
    func setUpdateEventResult(_ ev: GCalEvent) { updateEventResult = ev }
}
