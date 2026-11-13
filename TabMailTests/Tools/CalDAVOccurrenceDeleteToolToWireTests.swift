/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - One day of a CalDAV repeating event, from the tools down to the wire (ADR-IOS-108)
//
// INVARIANT (system property): a request about ONE day of a repeating CalDAV event can
// never delete the series. The series lives in one `.ics` resource holding every
// occurrence, and a WebDAV DELETE (RFC 4918 §9.6; RFC 4791 defines no trash) removes the
// whole resource for good, so this is irreversible wire operation #5 in the place where
// being wrong cannot be undone.
//
// The chain is the one a user's request takes: `calendar_read` / `calendar_search` for
// that day hand the model the occurrence's own id, the model passes the number the chat
// translator gave it to `calendar_event_delete`, the user confirms the card, the queued
// delete drains through the real `CalDAVProvider` onto a fake CalDAV server. The test
// asserts what the server holds afterwards (the series, byte for byte, plus one EXDATE for
// that day, #661), what a listing then shows (that day empty, the next week's occurrence
// still there), what the user is shown (the one-occurrence card, and the delete reported
// done), and that the queued delete completed. The control drives the same harness with
// the series' own id and does delete the series, which is what makes the absences here
// mean something.

/// The calendar tools over the real `CalDAVProvider` on a fake CalDAV server holding one
/// weekly series (`OccurrenceWireFixture`), for the tool-to-wire suites.
enum CalDAVToolWire {
    typealias W = OccurrenceWireFixture

    /// Confirms every card, as a user tapping the card's button would, and keeps it so the
    /// test can read what the card showed and ends up showing. Given the fake server, it
    /// also notes how many requests the server had served when each card was confirmed.
    @MainActor
    final class ConfirmingSink: AgentUISink {
        var confirmations: [AgentToolRouter.ActionConfirmation] = []
        var requestsAtConfirmation: [Int] = []
        private let http: FakeHTTP.Scenario?
        nonisolated init(http: FakeHTTP.Scenario? = nil) { self.http = http }
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            confirmations.append(confirmation)
            if let http { requestsAtConfirmation.append(http.recordedCalls().count) }
            confirmation.onRespond(true)
        }
    }

    /// The calendar home's one calendar, writable, as a CalDAV server lists it.
    private static let calendarListXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:response><d:href>/cal/</d:href><d:propstat><d:prop>
        <d:displayname>Work</d:displayname>
        <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
        <d:current-user-privilege-set><d:privilege><d:write/></d:privilege></d:current-user-privilege-set>
        <c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """

    struct Harness {
        let accountId: String
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let fixture: OccurrenceWireFixture
        let store: FakeCalDAVStore
        let http: FakeHTTP.Scenario
    }

    /// A test database holding one active CalDAV account, and the real `CalDAVProvider`
    /// for it over a fake server holding one weekly series (`fixture`, else `W.make()`).
    static func makeHarness(accountId: String, fixture given: OccurrenceWireFixture? = nil) async throws -> Harness {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try await pool.writeWithoutTransaction { db in
            var account = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: .caldav)
            account.id = accountId
            try account.insert(db)
        }

        let fixture = try given ?? W.make()
        let (store, http) = W.serve(fixture)
        http.register(
            path: "/cal/", method: "PROPFIND",
            response: .raw(
                statusCode: 207,
                headers: ["Content-Type": "application/xml; charset=utf-8"],
                body: Data(calendarListXML.utf8)))
        await AccountManager.shared.registerCalendarProviderForTesting(
            accountId: accountId, provider: W.makeProvider(http))
        return Harness(
            accountId: accountId, pool: pool, dir: dir, previous: previous,
            fixture: fixture, store: store, http: http)
    }

    static func tearDown(_ harness: Harness) {
        let accountId = harness.accountId
        Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
        harness.http.close()
        InstalledTestDatabaseLifetime.finish(previous: harness.previous, pool: harness.pool, directory: harness.dir)
    }

    /// Every `event_id:` value in a tool's output.
    static func eventIds(in output: String) -> [String] {
        output.matches(of: /(?:^|\t)event_id:\s+(\S+)/.anchorsMatchLineEndings()).map { String($0.1) }
    }

    /// The calendar a listed event is in, as the read tools' pill cache records it for
    /// the translator (the tools write it from a background task into the shared
    /// translator; the test writes it into its own).
    static func recordCalendar(
        of eventId: String, accountId: String, translator: ChatIdTranslator
    ) async {
        await translator.cacheEventDetail(
            realId: eventId, accountId: accountId, calendarId: W.calendarId, calendarName: "Work",
            title: "Standup", startDate: nil, endDate: nil, isAllDay: false,
            location: nil, notes: nil, attendees: [], isRecurring: true, recurrenceRule: "RRULE:FREQ=WEEKLY",
            availability: "busy", htmlLink: nil)
    }

    static func deletes(_ http: FakeHTTP.Scenario) -> [String] {
        http.recordedCalls().filter { $0.method == "DELETE" }.map(\.url)
    }

    /// An invitation to one changed occurrence of another organizer's series (RFC 4791 §4.1),
    /// seeded on the harness's server at `path`: a resource with a RECURRENCE-ID VEVENT and no
    /// series VEVENT (`OccurrenceWireFixture.overrideOnly`), its RECURRENCE-ID in `form`. Returns
    /// its path, its text and the id a listing gives its one occurrence.
    static func seedOverrideOnly(
        _ harness: Harness, form: String, moved: Bool = true, path: String = "/cal/invite.ics"
    ) throws -> (path: String, ics: String, occurrenceId: String) {
        let invite = try harness.fixture.overrideOnly(form: form, moved: moved)
        harness.store.seed(path: path, ics: invite.ics)
        return (path, invite.ics, CalDAVOccurrences.OccurrenceId.make(seriesHref: path, key: invite.key))
    }
}

@Suite("calendar tools: one day of a CalDAV repeating event never deletes the series", .serialized, .processGlobalState)
struct CalDAVOccurrenceDeleteToolToWireTests {
    typealias W = OccurrenceWireFixture
    typealias H = CalDAVToolWire
    typealias ConfirmingSink = CalDAVToolWire.ConfirmingSink

    @Test("read and search for one day name that day's occurrence, and deleting it removes that occurrence alone, the series staying on the server")
    func deletingOneDayNeverDeletesTheSeries() async throws {
        let harness = try await H.makeHarness(accountId: "caldav-one-day-delete")
        defer { H.tearDown(harness) }
        let fixture = harness.fixture
        let occurrenceId = try fixture.occurrenceId(2)
        let expected = CompoundEventId.make(accountId: harness.accountId, eventId: occurrenceId)
        let day = OccurrenceFixture.isoDate(try fixture.occurrence(2), fixture.zone)
        let oneDay: [String: JSONValue] = [
            "from_date": .string(day), "to_date": .string(day), "timezone": .string("America/New_York"),
        ]
        var search = oneDay
        search["query"] = .string("Standup")

        // 1. The listing tools name that day's occurrence, not the series.
        let readOutput = try await CalendarReadTool().execute(arguments: oneDay)
        let searchOutput = try await CalendarSearchTool().execute(arguments: search)
        #expect(H.eventIds(in: readOutput) == [expected], "calendar_read for one day did not name that day's occurrence: \(readOutput)")
        #expect(H.eventIds(in: searchOutput) == [expected], "calendar_search for one day did not name that day's occurrence: \(searchOutput)")

        // 2. The model is handed a number that maps back to that occurrence.
        let translator = ChatIdTranslator.createIsolated()
        let forModel = await translator.processToolOutputForLLM(readOutput)
        let numericId = try #require(H.eventIds(in: forModel).first.flatMap { Int($0) }, "no numeric event id for the model: \(forModel)")
        let mapped = await translator.toRealId(numericId)
        #expect(mapped == expected)
        await H.recordCalendar(of: occurrenceId, accountId: harness.accountId, translator: translator)

        // 3. The user asks to delete it and confirms the card.
        let sink = ConfirmingSink()
        let output = try await CalendarEventDeleteTool(context: ToolContext(db: harness.pool, translator: translator)).execute(
            arguments: ["event_id": .string(String(numericId)), "delete_scope": .string("this_only")],
            invocation: ToolInvocation(uiSink: sink, sessionKey: "caldav-one-day-delete"))
        // A later drain must not send it either.
        await AccountManager.shared.drainCalendarQueue()

        // The series stays on the server: no DELETE, one PUT that adds one EXDATE for that
        // day's occurrence, and every other line as it was (#661).
        #expect(H.deletes(harness.http).isEmpty,
                "a DELETE reached the server for one day of the series, which deletes every occurrence: \(H.deletes(harness.http))")
        #expect(harness.store.recordedPuts().count == 1, "expected one write of the series: \(harness.store.recordedPuts().map(\.path))")
        let stored = try #require(harness.store.storedICS(path: W.seriesPath), "the series is no longer on the server")
        let exdate = "EXDATE;TZID=America/New_York:\(OccurrenceFixture.wall(try fixture.occurrence(2), fixture.zone))"
        let storedLines = stored.components(separatedBy: "\r\n")
        #expect(storedLines.filter { $0 == exdate }.count == 1, "the series does not exclude that day's occurrence: \(stored)")
        #expect(storedLines.filter { $0 != exdate }.joined(separator: "\r\n") == fixture.ics,
                "the rest of the series changed on the wire: \(stored)")

        // That day now lists nothing; the days around it keep their occurrences.
        let readAfter = try await CalendarReadTool().execute(arguments: oneDay)
        #expect(H.eventIds(in: readAfter).isEmpty, "the deleted occurrence is still listed: \(readAfter)")
        let weekAfter = OccurrenceFixture.isoDate(try fixture.occurrence(3), fixture.zone)
        let readNext = try await CalendarReadTool().execute(arguments: [
            "from_date": .string(weekAfter), "to_date": .string(weekAfter), "timezone": .string("America/New_York"),
        ])
        #expect(H.eventIds(in: readNext) == [CompoundEventId.make(accountId: harness.accountId, eventId: try fixture.occurrenceId(3))],
                "the next occurrence of the series is not listed: \(readNext)")

        // The user is told it was deleted, on the card and in the tool's answer.
        #expect(output.contains("deleted successfully"), "the tool's answer does not say the occurrence was deleted: \(output)")
        let cardFailures = await MainActor.run { sink.confirmations.map { $0.responseState.failureReason } }
        #expect(cardFailures.count == 1, "expected one confirmation card, got \(cardFailures.count)")
        guard cardFailures.count == 1 else { return }
        #expect(cardFailures[0] == nil, "the confirmed card shows a failure: \(cardFailures[0] ?? "nil")")
        // The card shows one occurrence and says the rest of the series stays, which is now what
        // the server holds; it never says every occurrence goes (#639).
        let cardLines = await MainActor.run { sink.confirmations.flatMap { $0.calendarEvents.flatMap(\.changes) } }
        #expect(cardLines == [CalendarSeriesDeleteCardTests.occurrenceLine],
                "the card for one occurrence does not say only it is meant: \(cardLines)")

        // The queued delete completed; nothing is left to send again.
        let ops = try await harness.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        #expect(ops.isEmpty, "the queued delete did not complete: \(ops.map { $0.status })")
    }

    @Test("Control: the series' own id deletes the series through the same harness")
    func seriesOwnIdDeletesTheSeries() async throws {
        let harness = try await H.makeHarness(accountId: "caldav-series-delete-control")
        defer { H.tearDown(harness) }
        // The series' own id, handed to the model as an event_id, as a listing names a
        // series it shows once. No calendar is recorded for it: the delete tool finds it as
        // it finds any id the pill cache doesn't know.
        let translator = ChatIdTranslator.createIsolated()
        let seriesCompound = CompoundEventId.make(accountId: harness.accountId, eventId: W.seriesPath)
        let forModel = await translator.processToolOutputForLLM("event_id: \(seriesCompound)")
        let seriesNumber = try #require(H.eventIds(in: forModel).first.flatMap { Int($0) }, "no numeric series id for the model: \(forModel)")
        let mapped = await translator.toRealId(seriesNumber)
        #expect(mapped == seriesCompound)

        let sink = ConfirmingSink(http: harness.http)
        let output = try await CalendarEventDeleteTool(context: ToolContext(db: harness.pool, translator: translator)).execute(
            arguments: ["event_id": .string(String(seriesNumber)), "delete_scope": .string("all")],
            invocation: ToolInvocation(uiSink: sink, sessionKey: "caldav-series-delete-control"))

        #expect(H.deletes(harness.http).count == 1,
                "the harness must be able to send a DELETE, or the refusal's absence proves nothing: \(output)")
        #expect(harness.store.storedICS(path: W.seriesPath) == nil, "deleting by the series id left the series on the server")

        // The card the user confirmed, before the DELETE was sent, said the event repeats and
        // that every occurrence goes, with its rule (#639).
        let (cardLines, requestsAtConfirmation) = await MainActor.run {
            (sink.confirmations.flatMap { $0.calendarEvents.flatMap(\.changes) }, sink.requestsAtConfirmation)
        }
        #expect(cardLines == [CalendarToolHelpers.seriesDeleteNote, "Repeats weekly"],
                "the card for deleting the series does not say it repeats: \(cardLines)")
        #expect(requestsAtConfirmation.count == 1, "expected one confirmation card, got \(requestsAtConfirmation.count)")
        guard requestsAtConfirmation.count == 1 else { return }
        let sentBeforeConfirming = harness.http.recordedCalls().prefix(requestsAtConfirmation[0])
        #expect(!sentBeforeConfirming.contains { $0.method == "DELETE" }, "the DELETE was sent before the user confirmed the card")
    }

    @Test("one occurrence of a resource holding only changed occurrences: the card says the rest stays, and the delete is refused with no DELETE sent")
    func changedOnlyOccurrenceCardSaysTheRestStays() async throws {
        let harness = try await H.makeHarness(accountId: "caldav-changed-only-occurrence-delete")
        defer { H.tearDown(harness) }
        let (path, ics, occurrenceId) = try H.seedOverrideOnly(harness, form: "tzid")

        let translator = ChatIdTranslator.createIsolated()
        let compound = CompoundEventId.make(accountId: harness.accountId, eventId: occurrenceId)
        let forModel = await translator.processToolOutputForLLM("event_id: \(compound)")
        let number = try #require(H.eventIds(in: forModel).first.flatMap { Int($0) }, "no numeric id for the model: \(forModel)")
        await H.recordCalendar(of: occurrenceId, accountId: harness.accountId, translator: translator)

        let sink = ConfirmingSink()
        let output = try await CalendarEventDeleteTool(context: ToolContext(db: harness.pool, translator: translator)).execute(
            arguments: ["event_id": .string(String(number)), "delete_scope": .string("this_only")],
            invocation: ToolInvocation(uiSink: sink, sessionKey: "caldav-changed-only-occurrence-delete"))
        await AccountManager.shared.drainCalendarQueue()

        let (cardLines, titles) = await MainActor.run {
            (sink.confirmations.flatMap { $0.calendarEvents.flatMap(\.changes) }, sink.confirmations.flatMap { $0.calendarEvents.map(\.title) })
        }
        #expect(titles == ["Planning"], "the card was not for the changed occurrence: \(titles)")
        #expect(cardLines == [CalendarSeriesDeleteCardTests.occurrenceLine],
                "the card for one changed occurrence does not say only it is meant: \(cardLines)")
        #expect(H.deletes(harness.http).isEmpty, "a DELETE reached the server: \(H.deletes(harness.http))")
        #expect(harness.store.storedICS(path: path) == ics, "the resource is not on the server as it was")
        #expect(output.contains("NOT deleted"), "the tool's answer does not say the event was not deleted: \(output)")
    }

    @Test("a resource holding only changed occurrences, deleted by its own id, is refused before the card and no DELETE is sent")
    func overrideOnlyResourceByItsOwnIdIsNeverDeleted() async throws {
        let harness = try await H.makeHarness(accountId: "caldav-override-only-delete")
        defer { H.tearDown(harness) }
        // Its own href names every occurrence it holds, and a WebDAV DELETE of it can't be undone.
        let (invitePath, inviteICS, _) = try H.seedOverrideOnly(harness, form: "tzid")

        let translator = ChatIdTranslator.createIsolated()
        let inviteCompound = CompoundEventId.make(accountId: harness.accountId, eventId: invitePath)
        let forModel = await translator.processToolOutputForLLM("event_id: \(inviteCompound)")
        let inviteNumber = try #require(H.eventIds(in: forModel).first.flatMap { Int($0) }, "no numeric id for the model: \(forModel)")
        await H.recordCalendar(of: invitePath, accountId: harness.accountId, translator: translator)

        let sink = ConfirmingSink()
        let output = try await CalendarEventDeleteTool(context: ToolContext(db: harness.pool, translator: translator)).execute(
            arguments: ["event_id": .string(String(inviteNumber))],
            invocation: ToolInvocation(uiSink: sink, sessionKey: "caldav-override-only-delete"))
        await AccountManager.shared.drainCalendarQueue()

        #expect(H.deletes(harness.http).isEmpty, "a DELETE reached the server for the resource: \(H.deletes(harness.http))")
        #expect(harness.store.storedICS(path: invitePath) == inviteICS, "the resource is not on the server as it was")
        #expect(output.contains("could not find event"), "the tool did not refuse the delete: \(output)")
        let cards = await MainActor.run { sink.confirmations.count }
        #expect(cards == 0, "a confirmation card was shown for an id the tool could not read as one event")
        let ops = try await harness.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        #expect(ops.isEmpty, "a delete was queued for the resource: \(ops.map(\.status))")
    }
}

// MARK: - What the model and the user read about a CalDAV occurrence (ADR-IOS-108)

@Suite("calendar tool output: CalDAV occurrences and series that can't be listed")
struct CalDAVOccurrenceToolOutputTests {

    private static func event(
        id: String, recurrence: [String]?, recurringEventId: String?, notListed: Bool?
    ) -> GCalEvent {
        let start = Date().addingTimeInterval(7 * 24 * 60 * 60)
        var event = GCalEvent(
            id: id, summary: "Standup", location: nil, description: nil,
            start: GCalDateTime(dateTime: start.iso8601String(), date: nil, timeZone: nil),
            end: GCalDateTime(dateTime: start.addingTimeInterval(30 * 60).iso8601String(), date: nil, timeZone: nil),
            attendees: nil, organizer: nil, recurrence: recurrence, transparency: nil,
            status: "confirmed", htmlLink: nil, created: nil, updated: nil,
            recurringEventId: recurringEventId)
        event.occurrencesNotListed = notListed
        return event
    }

    @Test("a series listed once is marked as repeating with its rule and as not listing its occurrences; the pill shows only its title")
    func seriesListedOnceIsMarked() async {
        let realId = "/cal/hourly-\(UUID().uuidString).ics"
        let row = Self.event(id: realId, recurrence: ["RRULE:FREQ=HOURLY;INTERVAL=2"], recurringEventId: nil, notListed: true)
        let output = CalendarToolHelpers.formatGroupedSummary(
            [(event: row, accountId: "acct-a", calendarId: "/cal/", accessRole: nil)], timeZone: TimeZone(identifier: "UTC"))

        #expect(output.contains("Standup (↻ RRULE:FREQ=HOURLY;INTERVAL=2; \(CalendarToolHelpers.occurrencesNotListedNote))"),
                "the row does not say it is a series whose occurrences are not listed: \(output)")

        let translator = ChatIdTranslator.createIsolated()
        _ = await translator.processToolOutputForLLM(output)
        let numericId = await translator.toNumericId(CompoundEventId.make(accountId: "acct-a", eventId: realId))
        let rendered = await translator.processResponseForDisplay("[Event](\(numericId))")
        #expect(rendered.contains("[📅 Standup](tabmail://event/\(numericId))"), "the pill does not show the title alone: \(rendered)")
    }

    @Test("one occurrence's detail names that occurrence's id alone, as on every provider: no series id")
    func occurrenceDetailNamesOnlyItself() {
        let seriesHref = "/cal/standup-\(UUID().uuidString).ics"
        let occurrenceId = CalDAVOccurrences.OccurrenceId.make(seriesHref: seriesHref, key: "20990105T140000Z")
        let rows = [
            Self.event(id: occurrenceId, recurrence: ["RRULE:FREQ=WEEKLY"], recurringEventId: seriesHref, notListed: nil),
            Self.event(id: "series-1_20990105T140000Z", recurrence: nil, recurringEventId: "series-1", notListed: nil),
        ]
        for row in rows {
            let detail = CalendarToolHelpers.formatDetailedEvent(row, accountId: "acct-a", calendarId: "/cal/")
            let ownId = CompoundEventId.make(accountId: "acct-a", eventId: row.id ?? "")
            #expect(detail.contains("event_id: \(ownId)\n"), "the detail does not name the occurrence: \(detail)")
            #expect(detail.matches(of: /event_id:/).count == 1, "the detail names another id besides the occurrence's own: \(detail)")
        }
    }
}
