/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - MockChatIdTranslator Event Detail Caching

@Suite("Event Detail Caching via MockChatIdTranslator")
struct EventDetailCachingTests {

    private func makeTranslator() -> MockChatIdTranslator {
        MockChatIdTranslator()
    }

    @Test("cacheEventDetail stores and resolveEventDetail retrieves")
    func cacheAndResolve() async {
        let translator = makeTranslator()
        let realId = "google-event-abc123"
        let numericId = await translator.toNumericId(realId)

        await translator.cacheEventDetail(
            realId: realId,
            accountId: nil, calendarId: nil, calendarName: nil,
            title: "Team Standup",
            startDate: Date(timeIntervalSince1970: 1000),
            endDate: Date(timeIntervalSince1970: 2000),
            isAllDay: false,
            location: "Room 42",
            attendees: [],
            isRecurring: false,
            recurrenceRule: nil,
            availability: "busy",
            htmlLink: nil,
            eventTimeZone: nil
        )

        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail != nil)
        #expect(detail?.title == "Team Standup")
        #expect(detail?.realId == realId)
        #expect(detail?.isAllDay == false)
        #expect(detail?.location == "Room 42")
    }

    @Test("resolveEventDetail returns nil for uncached event")
    func uncachedReturnsNil() async {
        let translator = makeTranslator()
        await translator.seed("some-event", as: 1)

        let detail = await translator.resolveEventDetail(1)
        #expect(detail == nil)
    }

    @Test("resolveEventDetail returns nil for unknown numeric ID")
    func unknownIdReturnsNil() async {
        let translator = makeTranslator()
        let detail = await translator.resolveEventDetail(999)
        #expect(detail == nil)
    }

    @Test("evictEventDetail removes cached entry")
    func evictRemovesCache() async {
        let translator = makeTranslator()
        let realId = "event-to-delete"
        let numericId = await translator.toNumericId(realId)

        await translator.cacheEventDetail(
            realId: realId,
            accountId: nil, calendarId: nil, calendarName: nil,
            title: "Doomed Meeting",
            startDate: Date(),
            endDate: Date(),
            isAllDay: false,
            location: nil,
            attendees: [],
            isRecurring: false,
            recurrenceRule: nil,
            availability: "busy",
            htmlLink: nil,
            eventTimeZone: nil
        )

        // Verify it exists
        let before = await translator.resolveEventDetail(numericId)
        #expect(before != nil)

        // Evict
        await translator.evictEventDetail(realId: realId)

        // Verify it's gone
        let after = await translator.resolveEventDetail(numericId)
        #expect(after == nil)
    }

    @Test("evictEventDetail on non-existent key is safe")
    func evictNonExistentIsSafe() async {
        let translator = makeTranslator()
        // Should not crash
        await translator.evictEventDetail(realId: "does-not-exist")
    }

    @Test("cacheEventDetail overwrites previous entry")
    func cacheOverwritesPrevious() async {
        let translator = makeTranslator()
        let realId = "overwrite-event"
        let numericId = await translator.toNumericId(realId)

        await translator.cacheEventDetail(
            realId: realId, accountId: nil, calendarId: nil, calendarName: nil,
            title: "V1", startDate: nil, endDate: nil,
            isAllDay: false, location: nil, attendees: [], isRecurring: false,
            recurrenceRule: nil, availability: "busy", htmlLink: nil,
            eventTimeZone: nil
        )

        await translator.cacheEventDetail(
            realId: realId, accountId: nil, calendarId: nil, calendarName: nil,
            title: "V2", startDate: nil, endDate: nil,
            isAllDay: true, location: "Updated Location", attendees: [], isRecurring: false,
            recurrenceRule: nil, availability: "free", htmlLink: nil,
            eventTimeZone: nil
        )

        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.title == "V2")
        #expect(detail?.isAllDay == true)
        #expect(detail?.location == "Updated Location")
    }

    @Test("cacheEventDetail carries notes through to resolveEventDetail")
    func notesRoundTrip() async {
        // Regression: notes (Zoom/Meet links) were dropped at every pill layer.
        let translator = makeTranslator()
        let realId = "notes-event"
        let numericId = await translator.toNumericId(realId)

        await translator.cacheEventDetail(
            realId: realId, accountId: nil, calendarId: nil, calendarName: nil,
            title: "1:1", startDate: nil, endDate: nil,
            isAllDay: false, location: nil,
            notes: "Join Zoom: https://zoom.us/j/9999",
            attendees: [], isRecurring: false,
            recurrenceRule: nil, availability: "busy", htmlLink: nil,
            eventTimeZone: nil
        )

        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.notes == "Join Zoom: https://zoom.us/j/9999")
    }

    @Test("cacheEventDetailsForPills propagates notes and attendees from the event")
    func pillsCacheNotesAndAttendees() async {
        // Regression: the read/search cache path must carry both the event's
        // description (notes) and its attendees so a pill tap shows them without
        // a separate live re-fetch.
        let translator = makeTranslator()
        let event = GCalEvent(
            id: "evt-pills", summary: "Planning", location: "HQ",
            description: "Agenda + https://meet.google.com/abc-defg-hij",
            start: nil, end: nil,
            attendees: [
                GCalAttendee(email: "lead@test.com", displayName: "Lead", responseStatus: "accepted", organizer: nil, self: nil),
                GCalAttendee(email: "", displayName: "Ghost", responseStatus: "accepted", organizer: nil, self: nil),
            ],
            organizer: nil, recurrence: nil, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil
        )

        await CalendarToolHelpers.cacheEventDetailsForPills(
            [(event: event, accountId: "acct-1", calendarId: "cal-1", accessRole: "owner")],
            translator: translator
        )

        let numericId = await translator.toNumericId(CompoundEventId.make(accountId: "acct-1", eventId: "evt-pills"))
        let detail = await translator.resolveEventDetail(numericId)
        #expect(detail?.notes == "Agenda + https://meet.google.com/abc-defg-hij")
        #expect(detail?.attendees.count == 1)  // empty-email attendee dropped
        #expect(detail?.attendees.first?.email == "lead@test.com")
        #expect(detail?.location == "HQ")
    }

    @Test("cacheTemplateName stores and is retrievable via seed pattern")
    func templateNameCache() async {
        let translator = makeTranslator()
        await translator.seed("template-uuid-123", as: 5)
        await translator.cacheTemplateName(numericId: 5, name: "My Template")

        // Verify the mapping works (template names are used by processResponseForDisplay)
        let realId = await translator.toRealId(5)
        #expect(realId == "template-uuid-123")
    }
}

// MARK: - CalendarEventCreateTool Caching

@Suite("CalendarEventCreateTool Caching")
struct CalendarEventCreateToolCachingTests {

    @Test("Tool name is calendar_event_create")
    func toolName() throws {
        let db = try TestDatabase.make()
        let tool = CalendarEventCreateTool(context: ToolContext(db: db, translator: MockChatIdTranslator()))
        #expect(tool.name == "calendar_event_create")
    }
}

// MARK: - CalendarEventEditTool Caching

@Suite("CalendarEventEditTool — event_id validation unchanged")
struct CalendarEventEditToolCachingTests {

    private func makeContext() throws -> ToolContext {
        let db = try TestDatabase.make()
        return ToolContext(db: db, translator: MockChatIdTranslator())
    }

    @Test("Missing event_id still returns error after caching refactor")
    func missingEventId() async throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing event_id"))
    }

    @Test("Empty event_id still returns error after caching refactor")
    func emptyEventId() async throws {
        let tool = CalendarEventEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .string("")])
        #expect(result.contains("missing event_id"))
    }
}

// MARK: - CalendarEventDeleteTool Caching

@Suite("CalendarEventDeleteTool — event_id validation unchanged")
struct CalendarEventDeleteToolCachingTests {

    private func makeContext() throws -> ToolContext {
        let db = try TestDatabase.make()
        return ToolContext(db: db, translator: MockChatIdTranslator())
    }

    @Test("Missing event_id still returns error after caching refactor")
    func missingEventId() async throws {
        let tool = CalendarEventDeleteTool(context: try makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing event_id"))
    }

    @Test("Empty event_id still returns error after caching refactor")
    func emptyEventId() async throws {
        let tool = CalendarEventDeleteTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["event_id": .string("")])
        #expect(result.contains("missing event_id"))
    }
}

// MARK: - TemplateEditTool Caching

@Suite("TemplateEditTool Argument Validation")
struct TemplateEditToolCachingTests {

    private func makeContext() throws -> ToolContext {
        let db = try TestDatabase.make()
        return ToolContext(db: db, translator: MockChatIdTranslator())
    }

    @Test("Tool name is template_edit")
    func toolName() throws {
        let tool = TemplateEditTool(context: try makeContext())
        #expect(tool.name == "template_edit")
    }

    @Test("Missing template_id returns error")
    func missingTemplateId() async throws {
        let tool = TemplateEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("Template ID is required"))
    }

    @Test("Non-integer template_id returns error")
    func nonIntTemplateId() async throws {
        let tool = TemplateEditTool(context: try makeContext())
        let result = try await tool.execute(arguments: ["template_id": .string("abc")])
        #expect(result.contains("Template ID is required"))
    }
}

// MARK: - Contact Tool Output Format

@Suite("Contact Tool Output Format Validation")
struct ContactToolOutputFormatTests {

    private func makeContext() -> ToolContext {
        let db = try! DatabaseQueue()
        return ToolContext(db: db, translator: MockChatIdTranslator())
    }

    @Test("ContactAddTool tool name is contacts_add")
    func addToolName() {
        let tool = ContactAddTool(context: makeContext())
        #expect(tool.name == "contacts_add")
    }

    @Test("ContactEditTool tool name is contacts_edit")
    func editToolName() {
        let tool = ContactEditTool(context: makeContext())
        #expect(tool.name == "contacts_edit")
    }

    @Test("ContactDeleteTool tool name is contacts_delete")
    func deleteToolName() {
        let tool = ContactDeleteTool(context: makeContext())
        #expect(tool.name == "contacts_delete")
    }

    @Test("ContactAddTool missing identity fields still returns error")
    func addMissingFields() async throws {
        let tool = ContactAddTool(context: makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("Provide at least a name or an email"))
    }

    @Test("ContactEditTool missing contact_id still returns error")
    func editMissingId() async throws {
        let tool = ContactEditTool(context: makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing contact_id"))
    }

    @Test("ContactDeleteTool missing contact_id still returns error")
    func deleteMissingId() async throws {
        let tool = ContactDeleteTool(context: makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing contact_id"))
    }
}

// MARK: - R16-6: an all-day create's DEFAULT end is the EXCLUSIVE next day

/// 🚨 THE INVARIANT, stated as the system property and not as the mechanism
/// (`MIS-015`): **a single-day all-day event created with no explicit end covers
/// exactly that one day.** Under the half-open `[start, end)` convention every
/// calendar backend uses, "one day" means `end == start + 1 day`; `end == start` is
/// an event covering NO days at all, which is what `CalendarEventCreateTool` used to
/// produce. The tree's own anchor for the convention is
/// `GoogleCalendarSplitHelpersTests.mergeMasterAndPatchAllDayPreserved` — *"1-day all-day
/// event → end is exclusive next day"*.
///
/// ⚠️ WHY THE ASSERTION IS AT THE CONFIRMATION CARD AND NOT AT THE PROVIDER.
/// The provider boundary is UNREACHABLE for this tool from a test, and that is a
/// property of production code, not of the fixture: `CalendarEventCreateTool`
/// resolves its backend through `CalendarProviderDispatch.resolve()`, whose
/// `backendFor` returns `.none` for anything that is not literally a
/// `GoogleCalendarProvider`, `ExchangeCalendarProvider`, `CalDAVProvider` or
/// `DemoCalendarProvider` — an `as?` chain over four concrete types that no
/// conforming test double can satisfy. A `MockCalendarProvider` registered via
/// `registerCalendarProviderForTesting` therefore resolves to `.none`, the tool
/// returns `CalendarProviderDispatch.notAvailableMessage`, and NOTHING is ever
/// queued or sent. (An earlier draft of this suite asserted on
/// `MockCalendarProvider.createdEvents` and failed with `created.count == 0` for
/// exactly that reason — recorded here so the next author does not re-derive it.)
///
/// The card is nonetheless the RIGHT seam rather than a consolation one, because the
/// value under test does not exist twice. `execute` computes ONE `endDate` local; it
/// hands that same local to the card via `ActionConfirmation.CalendarEventDetail` and
/// to `queueCalendarCreate(…endDate:…)`, which is what stamps the durable
/// `end_iso` that `CalendarToolHelpers.buildGCalEventInput` later passes to the wire
/// verbatim (`String(endIso.prefix(10))`, no normalization anywhere downstream).
/// There is no second computation between here and Google `end.date` / Graph's
/// midnight-to-midnight values / CalDAV `DTEND;VALUE=DATE`, so pinning the card
/// pins the wire. It is also the user-visible half of the same property: the range
/// the user is asked to approve is the range that gets created.
///
/// ⚠️ NO PROVIDER IS REGISTERED, DELIBERATELY. The card is delivered strictly before
/// `resolve()`, so stopping there keeps the test fully deterministic: no
/// `PendingCalendarOperation` is written and `queueCalendarOperation`'s
/// fire-and-forget `Task { await drainCalendarQueue() }` never starts — a detached
/// drain outliving `InstalledTestDatabaseLifetime.finish` would touch a closed pool.
///
/// ⚠️ TWO-SIDED (`MIS-026`). The mirror image of the bug is normalising EVERY
/// all-day end by +1 day, which would silently extend every explicit range the agent
/// already computed correctly. `explicitAllDayEndIsNotNormalised` is the side that
/// must stay GREEN when the fix is inverted toward blanket normalisation, and it
/// also anchors the fixture (`MIS-030`): it proves this harness can observe a
/// caller-supplied end at all, so the equality asserted above is meaningful.
///
/// No hardcoded dates — every date is computed from `Date()`.
@Suite("Calendar create — an all-day default end is the exclusive next day",
       .serialized, .processGlobalState)
struct CalendarAllDayDefaultEndTests {

    /// Auto-responding confirmation sink that also RECORDS the card it was handed —
    /// the observation point for this suite. Shape mirrors
    /// `CalendarDeleteIdentityProofTests.AutoConfirmSink`.
    @MainActor
    private final class RecordingConfirmSink: AgentUISink {
        var calendarEvents: [AgentToolRouter.ActionConfirmation.CalendarEventDetail] = []
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            calendarEvents.append(contentsOf: confirmation.calendarEvents)
            confirmation.onRespond(true)
        }
    }

    /// A fixed IANA zone so the assertion cannot drift with the simulator's locale,
    /// and one with a DST rule so a `+86400` implementation is observable on the
    /// days it is wrong.
    private static let timeZoneId = "America/New_York"

    private static var zone: TimeZone { TimeZone(identifier: timeZoneId)! }

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    /// `yyyy-MM-dd`, `daysFromNow` days after today in `timeZoneId`.
    private static func day(_ daysFromNow: Int) -> String {
        let cal = calendar
        let start = cal.startOfDay(for: Date())
        let shifted = cal.date(byAdding: .day, value: daysFromNow, to: start) ?? start
        return format(shifted)
    }

    /// Render a resolved `Date` back to the `yyyy-MM-dd` the all-day path stamps —
    /// the same `prefix(10)`-of-naive-ISO reduction `queueCalendarCreate` performs.
    private static func format(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = zone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    /// A real installed database. Required even though this suite never writes a
    /// queue row: `CalendarProviderDispatch.resolve()` reads `AppDatabase.rawPool`,
    /// which force-unwraps `AppDatabase.shared`. Mirrors
    /// `CalendarDeleteIdentityProofTests.makeTestDB`.
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

    /// Drive the REAL tool and return the calendar card(s) it presented.
    ///
    /// No calendar provider is registered for `accountId`, so `resolve()` answers
    /// `.none` and the tool returns `notAvailableMessage` right after the card — see
    /// the suite header for why that is deliberate rather than a missing fixture.
    private func cardFromCreate(
        accountId: String, arguments: [String: JSONValue]
    ) async throws -> [AgentToolRouter.ActionConfirmation.CalendarEventDetail] {
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }

        let tool = CalendarEventCreateTool(
            context: ToolContext(db: pool, translator: MockChatIdTranslator()))
        let sink = RecordingConfirmSink()
        _ = try await tool.execute(
            arguments: arguments,
            invocation: ToolInvocation(uiSink: sink, sessionKey: "r16-6-\(accountId)"))
        return await sink.calendarEvents
    }

    @Test("An all-day create with no end_iso resolves an end of start + 1 day")
    func allDayDefaultEndIsTheExclusiveNextDay() async throws {
        let start = Self.day(30)
        let expectedEnd = Self.day(31)
        let cards = try await cardFromCreate(accountId: "cal-r16-6-default", arguments: [
            "title": .string("All-day fixture"),
            "start_iso": .string(start),
            "all_day": .bool(true),
            "timezone": .string(Self.timeZoneId),
        ])

        #expect(cards.count == 1,
                "setup: the tool never presented a calendar card, so nothing below is evidence — got \(cards.count)")
        guard cards.count == 1 else { return }
        #expect(cards[0].isAllDay,
                "setup: the card must be the all-day branch's, or the default under test was never taken")
        #expect(Self.format(cards[0].startDate) == start,
                "setup: the start the caller supplied must survive verbatim — got \(Self.format(cards[0].startDate))")
        #expect(Self.format(cards[0].endDate) == expectedEnd,
                """
                an all-day event created with no explicit end must cover exactly ONE day. \
                All-day ranges are half-open [start, end) on every backend, so a one-day \
                event ends on the NEXT calendar day; end == start is an event covering no \
                days at all, which no client renders and Google rejects. This same `endDate` \
                is what `queueCalendarCreate` stamps into the durable `end_iso`. \
                Expected \(expectedEnd), got \(Self.format(cards[0].endDate))
                """)
    }

    @Test("A caller-supplied all-day end_iso is NOT normalised")
    func explicitAllDayEndIsNotNormalised() async throws {
        let start = Self.day(40)
        let explicitEnd = Self.day(43)
        let cards = try await cardFromCreate(accountId: "cal-r16-6-explicit", arguments: [
            "title": .string("All-day fixture"),
            "start_iso": .string(start),
            "end_iso": .string(explicitEnd),
            "all_day": .bool(true),
            "timezone": .string(Self.timeZoneId),
        ])

        #expect(cards.count == 1,
                "setup: the tool never presented a calendar card — got \(cards.count)")
        guard cards.count == 1 else { return }
        #expect(Self.format(cards[0].startDate) == start)
        #expect(Self.format(cards[0].endDate) == explicitEnd,
                """
                only the DEFAULT moves. A caller-supplied end is taken verbatim, so an \
                explicit multi-day range must arrive unchanged — normalising every all-day \
                end by +1 day would silently extend every range the agent computed \
                correctly. Expected \(explicitEnd), got \(Self.format(cards[0].endDate))
                """)
    }
}
