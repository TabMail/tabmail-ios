/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - A queued calendar write is drained in the zone its card showed (#753)
//
// INVARIANT (system property): the time a confirmed `calendar_event_create` or
// `calendar_event_edit` writes is the time its confirmation card showed, whatever the device's
// zone is when the queue drains. The card is built in the device's zone at the tool's start; a
// write queued while offline used to be drained in the device's zone AT THE DRAIN, so a user who
// confirmed "15:00" in one zone and came online in another got 15:00 of the new zone.
//
// Each case runs the real tool with `ToolContext(deviceZone:)` set to a zone that is NOT the
// host's (the zone the user confirmed in), and the queue drains in the host's zone (the zone
// the device moved to). The model gives no `timezone`, as it does when the user names none. The
// write is read off the provider's fake (Google, Outlook, CalDAV) and compared with the card as
// the user reads it: a create's start and end, an edit's "start → …" line read in the zone the
// card shows. A CalDAV floating time has no zone, so there the written wall clock is compared
// with the card's.
//
// Every date is relative to today.

/// The UTC date `offset` days after the day two weeks from today, as `yyyy-MM-dd`.
private func day(_ offset: Int) -> String {
    let utc = TimeZone(identifier: "UTC")!
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    let base = cal.startOfDay(for: Date().addingTimeInterval(14 * 86_400))
    let date = cal.date(byAdding: .day, value: offset, to: base)!
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = utc
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt.string(from: date)
}

private func compact(_ day: String) -> String { day.replacingOccurrences(of: "-", with: "") }

/// `yyyy-MM-ddTHH:mm:ss` in UTC as an instant.
private func utcAt(_ naive: String) -> Date? { Date.fromISO8601(naive + "Z") }

private func naive(_ date: Date, _ zone: TimeZone) -> String { EKEventStoreHelper.toNaiveISO(date, timeZone: zone) }

/// The instant a stored start or end names: a `dateTime` with its offset, or a wall time read in
/// the zone it is labelled with (Graph).
private func instant(_ value: Any?) -> Date? {
    guard let stored = value as? [String: Any], let dateTime = stored["dateTime"] as? String else { return nil }
    if let date = Date.fromISO8601(dateTime) { return date }
    guard let zone = (stored["timeZone"] as? String).flatMap({ CalendarTimeZoneResolver.zone(named: $0, in: .none) }) else { return nil }
    return EKEventStoreHelper.parseNaiveISO(String(dateTime.prefix(19)), timeZone: zone)
}

/// Zones whose offset differs from the host's at `at`, in a fixed order: the zones a user
/// confirmed in, so the drain (in the host's zone) stands for a device that moved. The first
/// two always differ from each other.
private func zonesNotTheHost(at: Date) throws -> [TimeZone] {
    let candidates = ["Asia/Kathmandu", "America/St_Johns", "Pacific/Chatham"].compactMap(TimeZone.init(identifier:))
    let host = TimeZone.current.secondsFromGMT(for: at)
    let zones = candidates.filter { $0.secondsFromGMT(for: at) != host }
    try #require(zones.count >= 2, "no zone with another offset than the host's")
    return zones
}

private func confirmZone(at: Date) throws -> TimeZone { try zonesNotTheHost(at: at)[0] }

/// The instant the card's "`key` → …" line names, read in the zone the card shows its times in.
private func cardInstant(_ card: AgentToolRouter.ActionConfirmation.CalendarEventDetail, _ key: String) throws -> Date {
    let prefix = "\(key) → "
    let line = try #require(card.changes.first { $0.hasPrefix(prefix) }, "the card has no \(key) line: \(card.changes)")
    let zone = try #require(card.timeZoneId.flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) },
                            "the card names no zone: \(String(describing: card.timeZoneId))")
    return try #require(EKEventStoreHelper.parseNaiveISO(String(line.dropFirst(prefix.count)), timeZone: zone))
}

/// Confirms every card and keeps what each showed.
@MainActor
private final class ConfirmingCards: AgentUISink {
    var cards: [AgentToolRouter.ActionConfirmation.CalendarEventDetail] = []
    nonisolated init() {}
    func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
        cards.append(contentsOf: confirmation.calendarEvents)
        confirmation.onRespond(true)
    }
}

private struct Run {
    let out: String
    let cards: [AgentToolRouter.ActionConfirmation.CalendarEventDetail]
    let queued: [PendingCalendarOperation]
    var card: AgentToolRouter.ActionConfirmation.CalendarEventDetail? { cards.count == 1 ? cards[0] : nil }
}

private let preferenceKeys = [
    CalendarProviderDispatch.preferredCalendarAccountKey,
    CalendarProviderDispatch.preferredGoogleAccountKey,
    CalendarProviderDispatch.preferredCalendarKey,
    CalendarProviderDispatch.preferredGoogleCalendarKey,
]

/// Installs a fresh shared database holding `account` (active, of `kind`), registers `provider`
/// for it as the preferred calendar (its default calendar: "primary", which a CalDAV provider
/// resolves to its first writable calendar), runs `body`, then restores every global it touched.
private func withCalendar(
    account: String, kind: AccountProvider, provider: any CalendarProvider,
    _ body: (DatabasePool) async throws -> Void
) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var config = Configuration()
    config.foreignKeysEnabled = true
    let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
    let appDb = try AppDatabase(dbPool: pool)
    let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
        let prev = current; current = appDb; return prev
    }
    let defaults = UserDefaults.standard
    let priorPreferences = preferenceKeys.map { defaults.string(forKey: $0) }
    let priorDemoActive = await MainActor.run { DemoModeStore.shared.isActive }
    var failure: Error?
    do {
        try await pool.write { db in
            var acc = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: kind)
            acc.id = account
            acc.isActive = true
            try acc.insert(db)
        }
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: account, provider: provider)
        await MainActor.run { DemoModeStore.shared.isActive = false }
        for key in preferenceKeys { defaults.removeObject(forKey: key) }
        defaults.set(account, forKey: CalendarProviderDispatch.preferredCalendarAccountKey)
        try await body(pool)
    } catch {
        failure = error
    }
    for (key, value) in zip(preferenceKeys, priorPreferences) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    await MainActor.run { DemoModeStore.shared.isActive = priorDemoActive }
    await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: account)
    InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    if let failure { throw failure }
}

/// `calendar_event_create`, confirmed, with the device in `deviceZone`; then the queue drains.
private func runCreate(_ arguments: [String: JSONValue], pool: DatabasePool, deviceZone: TimeZone, session: String) async throws -> Run {
    let sink = ConfirmingCards()
    let out = try await CalendarEventCreateTool(context: ToolContext(db: pool, translator: MockChatIdTranslator(), deviceZone: deviceZone))
        .execute(arguments: arguments, invocation: ToolInvocation(uiSink: sink, sessionKey: session))
    await AccountManager.shared.drainCalendarQueue()
    let queued = try await pool.read { try PendingCalendarOperation.fetchAll($0) }
    return Run(out: out, cards: await sink.cards, queued: queued)
}

/// `calendar_event_edit` of `eventId` in `calendarId`, named by the number the chat translator
/// gives the model, confirmed, with the device in `deviceZone`; then the queue drains.
private func runEdit(
    _ arguments: [String: JSONValue], eventId: String, calendarId: String, account: String,
    pool: DatabasePool, deviceZone: TimeZone
) async throws -> Run {
    let translator = ChatIdTranslator.createIsolated()
    let compound = CompoundEventId.make(accountId: account, eventId: eventId)
    let forModel = await translator.processToolOutputForLLM("event_id: \(compound)")
    let numericId = try #require(CalDAVToolWire.eventIds(in: forModel).first.flatMap { Int($0) }, "no numeric id: \(forModel)")
    await translator.cacheEventDetail(
        realId: eventId, accountId: account, calendarId: calendarId, calendarName: "Work",
        title: "Standup", startDate: nil, endDate: nil, isAllDay: false,
        location: nil, notes: nil, attendees: [], isRecurring: true, recurrenceRule: nil,
        availability: "busy", htmlLink: nil, eventTimeZone: nil)
    var args = arguments
    args["event_id"] = .string(String(numericId))
    let sink = ConfirmingCards()
    let out = try await CalendarEventEditTool(context: ToolContext(db: pool, translator: translator, deviceZone: deviceZone))
        .execute(arguments: args, invocation: ToolInvocation(uiSink: sink, sessionKey: "zone-\(account)"))
    await AccountManager.shared.drainCalendarQueue()
    let queued = try await pool.read { try PendingCalendarOperation.fetchAll($0) }
    return Run(out: out, cards: await sink.cards, queued: queued)
}

private func summary(_ run: Run) -> String {
    "\(run.out); rows: \(run.queued.map { "\($0.status) \($0.failureReason ?? "")" })"
}

// MARK: - Google

/// A weekly Google series at 09:00 UTC from day 0, and its instances on day 0 and day 7.
private enum GoogleSeries {
    static let id = "ser-g"
    static func instanceId(_ d: String) -> String { "\(id)_\(compact(d))T090000Z" }

    static func times(_ d: String) -> [String: Any] { [
        "start": ["dateTime": "\(d)T09:00:00Z", "timeZone": "UTC"],
        "end": ["dateTime": "\(d)T09:30:00Z", "timeZone": "UTC"],
    ] }

    static var calendar: [[String: Any]] {
        var series: [String: Any] = ["id": id, "summary": "Standup", "status": "confirmed", "recurrence": ["RRULE:FREQ=WEEKLY"]]
        series.merge(times(day(0))) { $1 }
        let instances = [day(0), day(7)].map { d -> [String: Any] in
            var e: [String: Any] = [
                "id": instanceId(d), "summary": "Standup", "status": "confirmed", "recurringEventId": id,
                "originalStartTime": ["dateTime": "\(d)T09:00:00Z", "timeZone": "UTC"],
            ]
            e.merge(times(d)) { $1 }
            return e
        }
        return [series] + instances
    }
}

private func withGoogle(_ account: String, _ body: (FakeGoogleCalendar, DatabasePool) async throws -> Void) async throws {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    let calendar = FakeGoogleCalendar(GoogleSeries.calendar)
    calendar.install(on: http)
    let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
    try await withCalendar(account: account, kind: .gmail, provider: provider) { pool in try await body(calendar, pool) }
}

/// The event the queue created on Google.
private func googleCreated(_ calendar: FakeGoogleCalendar) -> [String: Any]? {
    calendar.writes.first { $0.hasPrefix("POST ") }.flatMap { calendar.event(String($0.dropFirst("POST ".count))) }
}

// MARK: - Outlook

/// Graph's `ser-1` series (`GraphFixture`), its first occurrence and the one a week later, each
/// rendered as Graph renders them for the host (the drain's device).
private enum GraphSeries {
    static let first = "ser-1-occ-1"
    static let later = "ser-1-occ-2"

    static func onDevice(_ event: [String: Any], start: Date) -> [String: Any] {
        let zone = TimeZone.current.identifier
        var e = event
        e["start"] = ["dateTime": GraphFixture.wall(start, in: zone) + ".0000000", "timeZone": zone]
        e["end"] = ["dateTime": GraphFixture.wall(start.addingTimeInterval(1_800), in: zone) + ".0000000", "timeZone": zone]
        return e
    }

    static func occurrence(id: String, at start: Date) -> [String: Any] {
        var e = onDevice(GraphFixture.event(id: id, start: start, seriesMasterId: "ser-1"), start: start)
        e["originalStart"] = start.iso8601String(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        return e
    }

    static func calendar() -> FakeGraphCalendar {
        FakeGraphCalendar([
            onDevice(GraphFixture.event(id: "ser-1", recurring: true), start: GraphFixture.start),
            occurrence(id: first, at: GraphFixture.start),
            occurrence(id: later, at: GraphFixture.occurrenceStart),
        ])
    }
}

private func withOutlook(_ account: String, _ body: (FakeGraphCalendar, DatabasePool) async throws -> Void) async throws {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    let graph = GraphSeries.calendar()
    graph.install(on: http)
    let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" }, session: http.session)
    try await withCalendar(account: account, kind: .outlook, provider: provider) { pool in try await body(graph, pool) }
}

// MARK: - CalDAV

private func withCalDAV(
    _ account: String, fixture: OccurrenceWireFixture? = nil,
    _ body: (CalDAVToolWire.Harness, DatabasePool) async throws -> Void
) async throws {
    let harness = try await CalDAVToolWire.makeHarness(accountId: account, fixture: fixture)
    defer { CalDAVToolWire.tearDown(harness) }
    let defaults = UserDefaults.standard
    let priorPreferences = preferenceKeys.map { defaults.string(forKey: $0) }
    let priorDemoActive = await MainActor.run { DemoModeStore.shared.isActive }
    var failure: Error?
    do {
        await MainActor.run { DemoModeStore.shared.isActive = false }
        for key in preferenceKeys { defaults.removeObject(forKey: key) }
        defaults.set(account, forKey: CalendarProviderDispatch.preferredCalendarAccountKey)
        try await body(harness, harness.pool)
    } catch {
        failure = error
    }
    for (key, value) in zip(preferenceKeys, priorPreferences) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    await MainActor.run { DemoModeStore.shared.isActive = priorDemoActive }
    if let failure { throw failure }
}

private func calDAVListing(_ harness: CalDAVToolWire.Harness, from: Date, to: Date) async throws -> [GCalEvent] {
    try await OccurrenceWireFixture.makeProvider(harness.http).listEvents(
        calendarId: OccurrenceWireFixture.calendarId, timeMin: from, timeMax: to,
        query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")
}

// MARK: - The suite

@Suite("A queued calendar write is drained in the zone its card showed (#753)", .serialized, .processGlobalState)
struct CalendarWriteZoneSnapshotTests {

    // MARK: Create

    @Test("Google: a timed create is written at the card's start and end")
    func googleCreate() async throws {
        let zone = try confirmZone(at: try #require(utcAt("\(day(3))T10:00:00")))
        try await withGoogle("zone-g-create") { calendar, pool in
            let r = try await runCreate([
                "title": .string("Planning"), "start_iso": .string("\(day(3))T10:00:00"), "end_iso": .string("\(day(3))T11:00:00"),
            ], pool: pool, deviceZone: zone, session: "zone-g-create")
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            #expect(card.startDate == EKEventStoreHelper.parseNaiveISO("\(day(3))T10:00:00", timeZone: zone))
            #expect(card.timeZoneId == zone.identifier, "the card shows \(String(describing: card.timeZoneId))")
            let created = try #require(googleCreated(calendar), "nothing created: \(calendar.writes); \(summary(r))")
            #expect(instant(created["start"]) == card.startDate, "written \(created["start"] ?? "nil"), card \(card.startDate)")
            #expect(instant(created["end"]) == card.endDate, "written \(created["end"] ?? "nil"), card \(card.endDate)")
        }
    }

    @Test("Outlook: a timed create is written at the card's start and end")
    func outlookCreate() async throws {
        let zone = try confirmZone(at: try #require(utcAt("\(day(3))T10:00:00")))
        try await withOutlook("zone-x-create") { graph, pool in
            let r = try await runCreate([
                "title": .string("Planning"), "start_iso": .string("\(day(3))T10:00:00"), "end_iso": .string("\(day(3))T11:00:00"),
            ], pool: pool, deviceZone: zone, session: "zone-x-create")
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let created = try #require(graph.created.first, "nothing created: \(graph.writes); \(summary(r))")
            #expect(instant(created["start"]) == card.startDate, "written \(created["start"] ?? "nil"), card \(card.startDate)")
            #expect(instant(created["end"]) == card.endDate, "written \(created["end"] ?? "nil"), card \(card.endDate)")
        }
    }

    @Test("CalDAV: a timed create is written at the card's start and end")
    func calDAVCreate() async throws {
        let zone = try confirmZone(at: try #require(utcAt("\(day(3))T10:00:00")))
        try await withCalDAV("zone-c-create") { harness, pool in
            let r = try await runCreate([
                "title": .string("Planning"), "start_iso": .string("\(day(3))T10:00:00"), "end_iso": .string("\(day(3))T11:00:00"),
            ], pool: pool, deviceZone: zone, session: "zone-c-create")
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let rows = try await calDAVListing(harness, from: card.startDate.addingTimeInterval(-2 * 86_400),
                                               to: card.startDate.addingTimeInterval(2 * 86_400))
            let created = try #require(rows.first { $0.summary == "Planning" },
                                       "nothing created: \(harness.store.recordedPuts().map(\.path)); \(summary(r))")
            #expect(created.startDate == card.startDate, "written \(String(describing: created.startDate)), card \(card.startDate)")
            #expect(created.endDate == card.endDate, "written \(String(describing: created.endDate)), card \(card.endDate)")
        }
    }

    @Test("a change of the device's zone applies to the next create: each is written in the zone its own card showed")
    func nextCreateUsesTheNewZone() async throws {
        let zones = try zonesNotTheHost(at: try #require(utcAt("\(day(3))T10:00:00")))
        try await withGoogle("zone-g-next") { calendar, pool in
            for (index, zone) in zones.prefix(2).enumerated() {
                let title = "Planning \(index)"
                let r = try await runCreate([
                    "title": .string(title), "start_iso": .string("\(day(3))T10:00:00"), "end_iso": .string("\(day(3))T11:00:00"),
                ], pool: pool, deviceZone: zone, session: "zone-g-next-\(index)")
                let card = try #require(r.cards.last, "no card: \(summary(r))")
                #expect(card.timeZoneId == zone.identifier)
                let created = calendar.writes.filter { $0.hasPrefix("POST ") }
                    .compactMap { calendar.event(String($0.dropFirst("POST ".count))) }
                    .first { $0["summary"] as? String == title }
                #expect(instant(created?["start"]) == EKEventStoreHelper.parseNaiveISO("\(day(3))T10:00:00", timeZone: zone),
                        "\(zone.identifier): written \(created?["start"] ?? "nil"); \(summary(r))")
            }
        }
    }

    // MARK: Edit, Google

    @Test("Google: a new time of every occurrence is written at the card's start")
    func googleWholeSeries() async throws {
        let newStart = try #require(utcAt("\(day(0))T10:00:00"))
        let zone = try confirmZone(at: newStart)
        try await withGoogle("zone-g-all") { calendar, pool in
            let r = try await runEdit([
                "start_iso": .string(naive(newStart, zone)), "end_iso": .string(naive(newStart.addingTimeInterval(1_800), zone)),
            ], eventId: GoogleSeries.id, calendarId: "primary", account: "zone-g-all", pool: pool, deviceZone: zone)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let written = instant(calendar.event(GoogleSeries.id)?["start"])
            #expect(written == (try cardInstant(card, "start")), "written \(String(describing: written)); \(summary(r))")
        }
    }

    @Test("Google: one occurrence named by its recurrence_id is the one moved, to the card's start")
    func googleThisOnly() async throws {
        let slot = try #require(utcAt("\(day(7))T09:00:00"))
        let zone = try confirmZone(at: slot)
        try await withGoogle("zone-g-one") { calendar, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_only"), "recurrence_id": .string(naive(slot, zone)),
                "start_iso": .string(naive(slot.addingTimeInterval(3_600), zone)),
                "end_iso": .string(naive(slot.addingTimeInterval(5_400), zone)),
            ], eventId: GoogleSeries.instanceId(day(7)), calendarId: "primary", account: "zone-g-one", pool: pool, deviceZone: zone)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let written = instant(calendar.event(GoogleSeries.instanceId(day(7)))?["start"])
            #expect(written == (try cardInstant(card, "start")), "written \(String(describing: written)); \(summary(r))")
        }
    }

    @Test("Google: a change of an occurrence and the following ones starts its new part at the card's start")
    func googleThisAndFollowing() async throws {
        let slot = try #require(utcAt("\(day(7))T09:00:00"))
        let zone = try confirmZone(at: slot)
        let rid = naive(slot, zone)
        try await withGoogle("zone-g-following") { calendar, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
                "start_iso": .string(naive(slot.addingTimeInterval(3_600), zone)),
                "end_iso": .string(naive(slot.addingTimeInterval(5_400), zone)),
            ], eventId: GoogleSeries.id, calendarId: "primary", account: "zone-g-following", pool: pool, deviceZone: zone)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let successor = calendar.event(GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: rid))
            #expect(instant(successor?["start"]) == (try cardInstant(card, "start")),
                    "new part \(successor?["start"] ?? "none"); writes \(calendar.writes); \(summary(r))")
            #expect((calendar.event(GoogleSeries.id)?["recurrence"] as? [String])?.contains { $0.contains("UNTIL=") } == true,
                    "the earlier part was not capped: \(calendar.event(GoogleSeries.id)?["recurrence"] ?? "none")")
        }
    }

    // MARK: Edit, Outlook

    @Test("Outlook: a new time of every occurrence is written at the card's start")
    func outlookWholeSeries() async throws {
        let newStart = GraphFixture.start.addingTimeInterval(1_800)
        let zone = try confirmZone(at: newStart)
        try await withOutlook("zone-x-all") { graph, pool in
            let r = try await runEdit([
                "start_iso": .string(naive(newStart, zone)), "end_iso": .string(naive(newStart.addingTimeInterval(1_800), zone)),
            ], eventId: "ser-1", calendarId: "primary", account: "zone-x-all", pool: pool, deviceZone: zone)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let written = instant(graph.event("ser-1")?["start"])
            #expect(written == (try cardInstant(card, "start")), "written \(String(describing: written)); \(summary(r))")
        }
    }

    @Test("Outlook: one occurrence named by its recurrence_id is the one moved, to the card's start")
    func outlookThisOnly() async throws {
        let slot = GraphFixture.occurrenceStart
        let zone = try confirmZone(at: slot)
        try await withOutlook("zone-x-one") { graph, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_only"), "recurrence_id": .string(naive(slot, zone)),
                "start_iso": .string(naive(slot.addingTimeInterval(1_800), zone)),
                "end_iso": .string(naive(slot.addingTimeInterval(3_600), zone)),
            ], eventId: GraphSeries.later, calendarId: "primary", account: "zone-x-one", pool: pool, deviceZone: zone)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let written = instant(graph.event(GraphSeries.later)?["start"])
            #expect(written == (try cardInstant(card, "start")), "written \(String(describing: written)); \(summary(r))")
        }
    }

    // MARK: Edit, CalDAV

    @Test("CalDAV: a new time of every occurrence is written at the card's start")
    func calDAVWholeSeries() async throws {
        let fixture = try OccurrenceWireFixture.make()
        let newStart = fixture.first.addingTimeInterval(3_600)
        let zone = try confirmZone(at: newStart)
        try await withCalDAV("zone-c-all", fixture: fixture) { harness, pool in
            let r = try await runEdit([
                "start_iso": .string(naive(newStart, zone)), "end_iso": .string(naive(newStart.addingTimeInterval(1_800), zone)),
            ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
               account: "zone-c-all", pool: pool, deviceZone: zone)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let series = try await OccurrenceWireFixture.makeProvider(harness.http)
                .getEvent(calendarId: OccurrenceWireFixture.calendarId, eventId: OccurrenceWireFixture.seriesPath)
            #expect(series.startDate == (try cardInstant(card, "start")),
                    "written \(String(describing: series.startDate)); \(summary(r))")
        }
    }

    @Test("CalDAV: one occurrence named by its recurrence_id is the one moved, to the card's start")
    func calDAVThisOnly() async throws {
        let fixture = try OccurrenceWireFixture.make()
        let slot = try fixture.occurrence(2)
        let zone = try confirmZone(at: slot)
        try await withCalDAV("zone-c-one", fixture: fixture) { harness, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_only"), "recurrence_id": .string(naive(slot, zone)),
                "start_iso": .string(naive(slot.addingTimeInterval(3_600), zone)),
                "end_iso": .string(naive(slot.addingTimeInterval(5_400), zone)),
            ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
               account: "zone-c-one", pool: pool, deviceZone: zone)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let occurrence = try? await OccurrenceWireFixture.makeProvider(harness.http)
                .getEvent(calendarId: OccurrenceWireFixture.calendarId, eventId: try fixture.occurrenceId(2))
            #expect(occurrence?.startDate == (try cardInstant(card, "start")),
                    "written \(String(describing: occurrence?.startDate)); \(summary(r))")
        }
    }

    @Test("CalDAV: an event with floating times is written at the card's wall clock")
    func calDAVFloating() async throws {
        let dayValue = compact(day(3))
        let ics = OccurrenceFixture.ics([[
            "UID:standup-1", "DTSTAMP:\(dayValue)T000000Z",
            "DTSTART:\(dayValue)T090000", "DTEND:\(dayValue)T093000", "SUMMARY:Standup",
        ].joined(separator: "\n")])
        let fixture = OccurrenceWireFixture(zone: TimeZone(identifier: "America/New_York")!, first: try #require(utcAt("\(day(3))T09:00:00")), ics: ics)
        let zone = try confirmZone(at: fixture.first)
        try await withCalDAV("zone-c-floating", fixture: fixture) { harness, pool in
            let r = try await runEdit([
                "start_iso": .string("\(day(3))T10:00:00"), "end_iso": .string("\(day(3))T10:30:00"),
            ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
               account: "zone-c-floating", pool: pool, deviceZone: zone)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            #expect(card.changes.contains("start → \(day(3))T10:00:00"), "card: \(card.changes)")
            let stored = harness.store.storedICS(path: OccurrenceWireFixture.seriesPath) ?? ""
            let lines = CalDAVProvider.icsLines(stored)
            #expect(lines.contains("DTSTART:\(dayValue)T100000") && lines.contains("DTEND:\(dayValue)T103000"),
                    "written \(lines.filter { $0.hasPrefix("DT") }); \(summary(r))")
        }
    }

    // MARK: Controls (hold today, with or without the fix)

    @Test("a zone the assistant names (IANA or Windows) is shown on the card and written in that zone")
    func givenZoneIsKept() async throws {
        let zone = try confirmZone(at: try #require(utcAt("\(day(3))T10:00:00")))
        for (given, resolved) in [("Asia/Tokyo", "Asia/Tokyo"), ("Tokyo Standard Time", "Asia/Tokyo")] {
            try await withGoogle("zone-g-given-\(compact(given))") { calendar, pool in
                let r = try await runCreate([
                    "title": .string("Planning"), "start_iso": .string("\(day(3))T10:00:00"),
                    "end_iso": .string("\(day(3))T11:00:00"), "timezone": .string(given),
                ], pool: pool, deviceZone: zone, session: "zone-g-given")
                #expect(r.card?.timeZoneId == resolved, "\(given): the card shows \(String(describing: r.card?.timeZoneId))")
                let tokyo = try #require(TimeZone(identifier: resolved))
                #expect(instant(googleCreated(calendar)?["start"]) == EKEventStoreHelper.parseNaiveISO("\(day(3))T10:00:00", timeZone: tokyo),
                        "\(given): written \(googleCreated(calendar)?["start"] ?? "nil"); \(summary(r))")
            }
        }
    }

    @Test("an all-day create is written on the card's date")
    func allDayCreateKeepsItsDate() async throws {
        let zone = try confirmZone(at: try #require(utcAt("\(day(3))T12:00:00")))
        try await withGoogle("zone-g-all-day") { calendar, pool in
            let r = try await runCreate([
                "title": .string("Offsite"), "start_iso": .string(day(3)), "end_iso": .string(day(4)), "all_day": .bool(true),
            ], pool: pool, deviceZone: zone, session: "zone-g-all-day")
            let created = googleCreated(calendar)
            #expect((created?["start"] as? [String: Any])?["date"] as? String == day(3), "written \(created?["start"] ?? "nil"); \(summary(r))")
            #expect((created?["end"] as? [String: Any])?["date"] as? String == day(4), "written \(created?["end"] ?? "nil")")
        }
    }

    @Test("a create queued with no zone (before the zone was queued) is drained in the device's zone, as before")
    func rowWithoutAZoneDrainsInTheDeviceZone() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let calendar = FakeGoogleCalendar([])
        calendar.install(on: http)
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        let eventId = PendingCalendarOperation.generateGoogleEventId(from: UUID().uuidString)
        let rows = try await drainCalendarOperation(
            type: .create, accountId: "zone-g-old-row", eventId: eventId, calendarId: "primary",
            arguments: ["title": .string("Planning"), "start_iso": .string("\(day(3))T10:00:00"), "end_iso": .string("\(day(3))T11:00:00")],
            provider: provider)
        #expect(instant(googleCreated(calendar)?["start"]) == EKEventStoreHelper.parseNaiveISO("\(day(3))T10:00:00", timeZone: .current),
                "written \(googleCreated(calendar)?["start"] ?? "nil"); rows \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
    }
}

// MARK: - The queued arguments name the zone the card showed

@Suite("A queued calendar write names the zone its times are in (#753)")
struct CalendarQueuedZoneStampTests {
    private let zone = TimeZone(identifier: "Asia/Kathmandu")!

    @Test("no zone, or an empty one, from the assistant: the card's zone is queued; nothing else changes")
    func missingZoneIsStamped() {
        for given: JSONValue? in [nil, .string("")] {
            var args: [String: JSONValue] = ["start_iso": .string("2099-01-05T10:00:00"), "all_day": .bool(false)]
            if let given { args["timezone"] = given }
            let stamped = CalendarToolHelpers.stampingZone(args, zone)
            #expect(CalendarToolHelpers.stringArgOpt(stamped, "timezone") == "Asia/Kathmandu", "\(String(describing: given))")
            #expect(stamped["start_iso"] == args["start_iso"] && stamped["all_day"] == args["all_day"])
            #expect(stamped.count == 3)
        }
    }

    @Test("a zone the assistant named is queued as given, IANA or Windows")
    func givenZoneIsKept() {
        for given in ["Asia/Tokyo", "Tokyo Standard Time"] {
            let args: [String: JSONValue] = ["start_iso": .string("2099-01-05T10:00:00"), "timezone": .string(given)]
            #expect(CalendarToolHelpers.stampingZone(args, zone) == args, "\(given)")
        }
    }

    @Test("with no zone given, the write resolves to the zone the tool snapshotted, not the host's")
    func writeZoneIsTheSnapshot() throws {
        let tz = try CalendarToolHelpers.resolveWriteTimeZone([:], deviceZone: zone, consequence: "test")
        #expect(tz.identifier == "Asia/Kathmandu")
    }
}

// MARK: - The card names a zone only when it is not the device's

@Suite("The calendar card names a zone only when it is not the device's (#753)")
struct CalendarCardZoneLabelTests {
    private func detail(_ zone: String?) -> AgentToolRouter.ActionConfirmation.CalendarEventDetail {
        .init(eventId: "", calendarId: "", title: "Planning", startDate: Date(), endDate: Date().addingTimeInterval(3_600),
              isAllDay: false, timeZoneId: zone)
    }

    @Test("times in the device's zone: no zone row")
    func sameZoneHasNoRow() throws {
        let device = try #require(TimeZone(identifier: "Asia/Kathmandu"))
        #expect(ActionConfirmationCard.eventTimezoneLabel(detail("Asia/Kathmandu"), deviceZone: device) == nil)
    }

    @Test("times in another zone: the row names it by its IANA id")
    func otherZoneHasARow() throws {
        let device = try #require(TimeZone(identifier: "America/St_Johns"))
        let label = ActionConfirmationCard.eventTimezoneLabel(detail("Asia/Kathmandu"), deviceZone: device)
        #expect(label?.contains("Asia/Kathmandu") == true, "label: \(String(describing: label))")
    }

    @Test("a Windows zone name is the zone it names")
    func windowsNameIsItsZone() throws {
        let device = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(ActionConfirmationCard.eventTimezoneLabel(detail("Tokyo Standard Time"), deviceZone: device) == nil)
        #expect(ActionConfirmationCard.eventZone(detail("Tokyo Standard Time")).identifier == "Asia/Tokyo")
    }
}
