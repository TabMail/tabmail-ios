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

/// A repeating CalDAV event with floating times (no zone): from `first` (`yyyy-MM-dd`) at the wall
/// clock `start` to `end` (`HHmmss`), repeating by `rule`. `zone` and `first` are the fixture's
/// bookkeeping; the times themselves name no zone.
private func floatingSeries(first: String, start: String, end: String, rule: String) throws -> OccurrenceWireFixture {
    let ics = OccurrenceFixture.ics([[
        "UID:standup-1", "DTSTAMP:\(compact(first))T000000Z",
        "DTSTART:\(compact(first))T\(start)", "DTEND:\(compact(first))T\(end)",
        "SUMMARY:Standup", "RRULE:\(rule)",
    ].joined(separator: "\n")])
    return OccurrenceWireFixture(zone: .gmt, first: try #require(utcAt("\(first)T12:00:00")), ics: ics)
}

/// A zone a whole number of hours from the host's at `at`, where one of the candidates is; else
/// one with another offset than the host's.
private func zonesWholeHoursFromTheHost(at: Date) throws -> TimeZone {
    let candidates = ["Asia/Tokyo", "Europe/Berlin", "America/New_York", "Pacific/Honolulu"].compactMap(TimeZone.init(identifier:))
    let host = TimeZone.current.secondsFromGMT(for: at)
    let other = candidates.filter { $0.secondsFromGMT(for: at) != host }
    return try #require(other.first { ($0.secondsFromGMT(for: at) - host) % 3_600 == 0 } ?? other.first,
                        "no zone with another offset than the host's")
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

    // MARK: Edit, CalDAV floating series (#753 review, #761)
    //
    // A floating series' occurrences have no zone: the one a `recurrence_id` names is the one at
    // that wall clock. Confirmed in one zone and drained in another, the edit lands on it.

    @Test("CalDAV floating series: one occurrence named by its recurrence_id is the one changed, to the card's wall clock")
    func calDAVFloatingThisOnly() async throws {
        let fixture = try floatingSeries(first: day(0), start: "090000", end: "093000", rule: "FREQ=WEEKLY")
        let zone = try confirmZone(at: fixture.first)
        try await withCalDAV("zone-c-float-one", fixture: fixture) { harness, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(14))T09:00:00"),
                "start_iso": .string("\(day(14))T10:00:00"), "end_iso": .string("\(day(14))T10:30:00"),
            ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
               account: "zone-c-float-one", pool: pool, deviceZone: zone)
            let stored = harness.store.storedICS(path: OccurrenceWireFixture.seriesPath) ?? ""
            let lines = CalDAVProvider.icsLines(stored)
            #expect(lines.filter { $0.hasPrefix("RECURRENCE-ID") } == ["RECURRENCE-ID:\(compact(day(14)))T090000"],
                    "changed \(lines.filter { $0.hasPrefix("RECURRENCE-ID") }); \(summary(r))")
            #expect(lines.contains("DTSTART:\(compact(day(14)))T100000") && lines.contains("DTEND:\(compact(day(14)))T103000"),
                    "written \(lines.filter { $0.hasPrefix("DT") }); \(summary(r))")
        }
    }

    @Test("CalDAV floating series: a change of an occurrence and the following ones splits at it and starts at the card's wall clock")
    func calDAVFloatingThisAndFollowing() async throws {
        let fixture = try floatingSeries(first: day(0), start: "090000", end: "093000", rule: "FREQ=WEEKLY")
        let zone = try confirmZone(at: fixture.first)
        try await withCalDAV("zone-c-float-following", fixture: fixture) { harness, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_and_following"), "recurrence_id": .string("\(day(14))T09:00:00"),
                "start_iso": .string("\(day(14))T10:00:00"), "end_iso": .string("\(day(14))T10:30:00"),
            ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
               account: "zone-c-float-following", pool: pool, deviceZone: zone)
            let newPaths = Set(harness.store.recordedPuts().map(\.path)).subtracting([OccurrenceWireFixture.seriesPath])
            let newPart = newPaths.compactMap { harness.store.storedICS(path: $0) }.map(CalDAVProvider.icsLines)
            #expect(newPart.count == 1 && newPart.first?.contains("DTSTART:\(compact(day(14)))T100000") == true,
                    "new part \(newPart.map { $0.filter { $0.hasPrefix("DT") } }); \(summary(r))")
            let earlier = CalDAVProvider.icsLines(harness.store.storedICS(path: OccurrenceWireFixture.seriesPath) ?? "")
            // The earlier part ends after the occurrence a week before the one named, and before it.
            let until = earlier.first { $0.hasPrefix("RRULE:") }?
                .split(separator: ";").first { $0.hasPrefix("UNTIL=") }
                .map { String($0.dropFirst("UNTIL=".count)).replacingOccurrences(of: "Z", with: "") }
            #expect(until.map { $0 >= "\(compact(day(7)))T090000" && $0 < "\(compact(day(14)))T090000" } == true,
                    "the earlier part is not capped at the occurrence named: \(earlier.filter { $0.hasPrefix("RRULE") })")
        }
    }

    @Test("CalDAV floating series: an edit of every occurrence named by an occurrence id alone is written at a drain in another zone, never retired as not found")
    func calDAVFloatingOccurrenceIdDrainsInAnotherZone() async throws {
        let fixture = try floatingSeries(first: day(0), start: "090000", end: "093000", rule: "FREQ=WEEKLY")
        let zone = try confirmZone(at: fixture.first)
        let (store, http) = OccurrenceWireFixture.serve(fixture)
        defer { http.close() }
        let occurrenceId = CalDAVOccurrences.OccurrenceId.make(
            seriesHref: OccurrenceWireFixture.seriesPath, key: "\(compact(day(14)))T090000")
        // As the tool queues an edit of every occurrence that moves no time, named by an occurrence
        // id: no recurrence_id (`CalendarSeriesScope.route` sends it as given), the card's zone
        // stamped. The queue drains in the host's zone and names the occurrence by the start it reads.
        let rows = try await drainCalendarOperation(
            type: .edit, accountId: "zone-c-float-id", eventId: occurrenceId, calendarId: OccurrenceWireFixture.calendarId,
            arguments: ["title": .string("Renamed"), "timezone": .string(zone.identifier)],
            provider: OccurrenceWireFixture.makeProvider(http))
        let lines = CalDAVProvider.icsLines(store.storedICS(path: OccurrenceWireFixture.seriesPath) ?? "")
        let outcome = rows.map { "\($0.status) \($0.failureReason ?? "")" }
        #expect(lines.contains("SUMMARY:Renamed") && !lines.contains("SUMMARY:Standup"),
                "written \(lines.filter { $0.hasPrefix("SUMMARY") }); rows \(outcome)")
        #expect(lines.contains("DTSTART:\(compact(day(0)))T090000") && !lines.contains { $0.hasPrefix("RECURRENCE-ID") },
                "the series' times changed: \(lines.filter { $0.hasPrefix("DT") || $0.hasPrefix("RECURRENCE-ID") }); rows \(outcome)")
    }

    @Test("CalDAV zoned series: an edit of every occurrence named by an occurrence id alone is written at a drain in another zone, never retired as not found")
    func calDAVZonedOccurrenceIdAllDrainsInAnotherZone() async throws {
        let fixture = try OccurrenceWireFixture.make()
        let zone = try confirmZone(at: try fixture.occurrence(2))
        let (store, http) = OccurrenceWireFixture.serve(fixture)
        defer { http.close() }
        // An edit of every occurrence that moves no time is queued as given: no recurrence_id. The
        // drain names the occurrence by the start the provider read, in the zone it read it in, and
        // looks it up there; looked up in the queued zone, the same text is another instant.
        let rows = try await drainCalendarOperation(
            type: .edit, accountId: "zone-c-zoned-id-all", eventId: try fixture.occurrenceId(2),
            calendarId: OccurrenceWireFixture.calendarId,
            arguments: ["title": .string("Renamed"), "timezone": .string(zone.identifier)],
            provider: OccurrenceWireFixture.makeProvider(http))
        let lines = CalDAVProvider.icsLines(store.storedICS(path: OccurrenceWireFixture.seriesPath) ?? "")
        let outcome = rows.map { "\($0.status) \($0.failureReason ?? "")" }
        #expect(lines.contains("SUMMARY:Renamed") && !lines.contains("SUMMARY:Standup"),
                "written \(lines.filter { $0.hasPrefix("SUMMARY") }); rows \(outcome)")
        #expect(!outcome.contains { $0.contains("not found") }, "rows \(outcome)")
    }

    @Test("CalDAV zoned series: a this_only edit named by an occurrence id alone is refused at a drain in another zone for its missing recurrence_id, never retired as not found")
    func calDAVZonedOccurrenceIdThisOnlyDrainsInAnotherZone() async throws {
        // The tool refuses this_only without a recurrence_id before its card, and so does the
        // drain's write; a row without one is still read first (`CalendarSeriesScope.read`'s
        // this_only branch). That read finds the occurrence the id names, so the row ends with the
        // refusal that is true, never as an event the server no longer has.
        let fixture = try OccurrenceWireFixture.make()
        let zone = try confirmZone(at: try fixture.occurrence(2))
        let (store, http) = OccurrenceWireFixture.serve(fixture)
        defer { http.close() }
        let rows = try await drainCalendarOperation(
            type: .edit, accountId: "zone-c-zoned-id-one", eventId: try fixture.occurrenceId(2),
            calendarId: OccurrenceWireFixture.calendarId,
            arguments: ["edit_scope": .string("this_only"), "title": .string("Renamed"), "timezone": .string(zone.identifier)],
            provider: OccurrenceWireFixture.makeProvider(http))
        let outcome = rows.map { "\($0.status) \($0.failureReason ?? "")" }
        #expect(outcome.contains { $0.contains("requires recurrence_id") }, "rows \(outcome)")
        #expect(!outcome.contains { $0.contains("not found") }, "rows \(outcome)")
        #expect(store.storedICS(path: OccurrenceWireFixture.seriesPath) == fixture.ics, "the series changed")
    }

    @Test("control: a floating HOURLY series, whose occurrences TabMail can't work out, is refused before the card in any zone; nothing is written")
    func calDAVFloatingHourlyIsRefused() async throws {
        // A one-occurrence edit could only reach a neighbour where occurrences are closer together
        // than two zones' offsets differ. CalDAV expands no rule finer than DAILY, so an HOURLY
        // series is refused, never matched (`CalDAVOccurrences.shape`'s unexpandable rule).
        let fixture = try floatingSeries(first: day(3), start: "080000", end: "083000", rule: "FREQ=HOURLY;COUNT=12")
        for zone in [TimeZone.current] + (try zonesNotTheHost(at: fixture.first)) {
            try await withCalDAV("zone-c-float-hourly", fixture: fixture) { harness, pool in
                let r = try await runEdit([
                    "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(3))T12:00:00"),
                    "start_iso": .string("\(day(3))T12:15:00"), "end_iso": .string("\(day(3))T12:45:00"),
                ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
                   account: "zone-c-float-hourly", pool: pool, deviceZone: zone)
                #expect(r.cards.isEmpty && r.out.contains("can't work out the occurrences"), "\(zone.identifier): \(summary(r))")
                #expect(harness.store.recordedPuts().isEmpty, "\(zone.identifier): wrote \(harness.store.recordedPuts().map(\.path))")
            }
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

// MARK: - A recurrence_id names the occurrence the read tools printed, whatever zone the edit names (#794)
//
// INVARIANT: the `recurrence_id` the read tools print (an occurrence's start in the device's zone)
// names that same occurrence when it is passed back to `calendar_event_edit`, whatever `timezone`
// the edit gives for its new times. `timezone` applies to the new times only. It used to be read in
// the edit's `timezone`, where it named no occurrence, so the edit was refused before its card.
//
// The device is in one zone, the edit names a second, and the queue drains in the host's, a third:
// each case names the occurrence as the read tools print it in the device's zone and its new time in
// the edit's zone, and checks the occurrence named is the one written, at the card's start.

/// A weekly Google series on its weekday (UTC), late in the UTC day at 20:00, with `count`
/// occurrences, and its instances on day 0 and day 7. Late, so a time read in the wrong one of
/// `fixedZones` lands on another date than the one meant.
private enum LateSeries {
    static let id = "ser-late"
    static func instanceId(_ d: String) -> String { "\(id)_\(compact(d))T200000Z" }
    static func at(_ d: String) -> Date? { utcAt("\(d)T20:00:00") }

    static func calendar(rule: String) -> [[String: Any]] {
        func times(_ d: String) -> [String: Any] { [
            "start": ["dateTime": "\(d)T20:00:00Z", "timeZone": "UTC"],
            "end": ["dateTime": "\(d)T20:30:00Z", "timeZone": "UTC"],
        ] }
        var series: [String: Any] = ["id": id, "summary": "Standup", "status": "confirmed", "recurrence": [rule]]
        series.merge(times(day(0))) { $1 }
        return [series] + [day(0), day(7)].map { d -> [String: Any] in
            var e: [String: Any] = [
                "id": instanceId(d), "summary": "Standup", "status": "confirmed", "recurringEventId": id,
                "originalStartTime": ["dateTime": "\(d)T20:00:00Z", "timeZone": "UTC"],
            ]
            e.merge(times(d)) { $1 }
            return e
        }
    }
}

/// The RFC 5545 weekday code of a `yyyy-MM-dd` date in UTC.
private func weekday(_ d: String) throws -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let date = try #require(utcAt("\(d)T12:00:00"))
    return ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][cal.component(.weekday, from: date) - 1]
}

/// The device's zone (UTC+5:45) and the zone the edit names (UTC-3:30), both not the host's at `at`:
/// far enough apart that a late-UTC time read in the other one is on another UTC date.
private func fixedZones(at: Date) throws -> (device: TimeZone, edit: TimeZone) {
    let device = try #require(TimeZone(identifier: "Asia/Kathmandu"))
    let edit = try #require(TimeZone(identifier: "America/St_Johns"))
    let host = TimeZone.current.secondsFromGMT(for: at)
    try #require(device.secondsFromGMT(for: at) != host && edit.secondsFromGMT(for: at) != host,
                 "the host is in one of the test's zones")
    return (device, edit)
}

private func withGoogle(_ account: String, seed: [[String: Any]], _ body: (FakeGoogleCalendar, DatabasePool) async throws -> Void) async throws {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    let calendar = FakeGoogleCalendar(seed)
    calendar.install(on: http)
    let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
    try await withCalendar(account: account, kind: .gmail, provider: provider) { pool in try await body(calendar, pool) }
}

/// The device's zone and the zone the edit names: two zones that differ from each other and from the
/// host's at `at`.
private func deviceAndEditZones(at: Date) throws -> (device: TimeZone, edit: TimeZone) {
    let zones = try zonesNotTheHost(at: at)
    return (zones[0], zones[1])
}

@Suite("A recurrence_id names the occurrence the read tools printed, whatever zone the edit names (#794)", .serialized, .processGlobalState)
struct CalendarRecurrenceIdZoneTests {

    @Test("Google: one occurrence named as printed, with its new time in another zone, is the one moved")
    func googleThisOnly() async throws {
        let slot = try #require(utcAt("\(day(7))T09:00:00"))
        let (device, edit) = try deviceAndEditZones(at: slot)
        try await withGoogle("rid-g-one") { calendar, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_only"), "recurrence_id": .string(naive(slot, device)),
                "timezone": .string(edit.identifier),
                "start_iso": .string(naive(slot.addingTimeInterval(3_600), edit)),
                "end_iso": .string(naive(slot.addingTimeInterval(5_400), edit)),
            ], eventId: GoogleSeries.instanceId(day(7)), calendarId: "primary", account: "rid-g-one", pool: pool, deviceZone: device)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let written = instant(calendar.event(GoogleSeries.instanceId(day(7)))?["start"])
            #expect(written == slot.addingTimeInterval(3_600), "written \(String(describing: written)); \(summary(r))")
            #expect(written == (try cardInstant(card, "start")), "card \(card.changes)")
            #expect(card.startDate == slot, "the card shows \(card.startDate), not the occurrence named")
        }
    }

    @Test("Google: a change from an occurrence named as printed, with its new time in another zone, splits there")
    func googleThisAndFollowing() async throws {
        let slot = try #require(utcAt("\(day(7))T09:00:00"))
        let (device, edit) = try deviceAndEditZones(at: slot)
        let rid = naive(slot, device)
        try await withGoogle("rid-g-following") { calendar, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
                "timezone": .string(edit.identifier),
                "start_iso": .string(naive(slot.addingTimeInterval(3_600), edit)),
                "end_iso": .string(naive(slot.addingTimeInterval(5_400), edit)),
            ], eventId: GoogleSeries.id, calendarId: "primary", account: "rid-g-following", pool: pool, deviceZone: device)
            _ = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let successor = calendar.event(GoogleCalendarProvider.deterministicSplitEventId(masterId: GoogleSeries.id, recurrenceId: rid))
            #expect(instant(successor?["start"]) == slot.addingTimeInterval(3_600),
                    "new part \(successor?["start"] ?? "none"); writes \(calendar.writes); \(summary(r))")
            #expect((calendar.event(GoogleSeries.id)?["recurrence"] as? [String])?.contains { $0.contains("UNTIL=") } == true,
                    "the earlier part was not capped: \(calendar.event(GoogleSeries.id)?["recurrence"] ?? "none")")
        }
    }

    @Test("Outlook: one occurrence named as printed, with its new time in another zone, is the one moved")
    func outlookThisOnly() async throws {
        let slot = GraphFixture.occurrenceStart
        let (device, edit) = try deviceAndEditZones(at: slot)
        try await withOutlook("rid-x-one") { graph, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_only"), "recurrence_id": .string(naive(slot, device)),
                "timezone": .string(edit.identifier),
                "start_iso": .string(naive(slot.addingTimeInterval(1_800), edit)),
                "end_iso": .string(naive(slot.addingTimeInterval(3_600), edit)),
            ], eventId: GraphSeries.later, calendarId: "primary", account: "rid-x-one", pool: pool, deviceZone: device)
            _ = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let written = instant(graph.event(GraphSeries.later)?["start"])
            #expect(written == slot.addingTimeInterval(1_800), "written \(String(describing: written)); \(summary(r))")
        }
    }

    @Test("CalDAV: one occurrence named as printed, with its new time in another zone, is the one moved")
    func calDAVThisOnly() async throws {
        let fixture = try OccurrenceWireFixture.make()
        let slot = try fixture.occurrence(2)
        let (device, edit) = try deviceAndEditZones(at: slot)
        try await withCalDAV("rid-c-one", fixture: fixture) { harness, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_only"), "recurrence_id": .string(naive(slot, device)),
                "timezone": .string(edit.identifier),
                "start_iso": .string(naive(slot.addingTimeInterval(3_600), edit)),
                "end_iso": .string(naive(slot.addingTimeInterval(5_400), edit)),
            ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
               account: "rid-c-one", pool: pool, deviceZone: device)
            _ = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let occurrence = try? await OccurrenceWireFixture.makeProvider(harness.http)
                .getEvent(calendarId: OccurrenceWireFixture.calendarId, eventId: try fixture.occurrenceId(2))
            #expect(occurrence?.startDate == slot.addingTimeInterval(3_600),
                    "written \(String(describing: occurrence?.startDate)); \(summary(r))")
        }
    }

    @Test("CalDAV floating series: the occurrence at the wall clock printed is the one changed, whatever zone the edit names")
    func calDAVFloatingThisOnly() async throws {
        let fixture = try floatingSeries(first: day(0), start: "090000", end: "093000", rule: "FREQ=WEEKLY")
        let (device, edit) = try deviceAndEditZones(at: fixture.first)
        try await withCalDAV("rid-c-float-one", fixture: fixture) { harness, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(14))T09:00:00"),
                "timezone": .string(edit.identifier),
                "title": .string("Standup (renamed)"),
            ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
               account: "rid-c-float-one", pool: pool, deviceZone: device)
            let lines = CalDAVProvider.icsLines(harness.store.storedICS(path: OccurrenceWireFixture.seriesPath) ?? "")
            #expect(lines.filter { $0.hasPrefix("RECURRENCE-ID") } == ["RECURRENCE-ID:\(compact(day(14)))T090000"],
                    "changed \(lines.filter { $0.hasPrefix("RECURRENCE-ID") }); \(summary(r))")
        }
    }

    // MARK: Read by id, then edit (#794, option B)

    @Test("Google: an occurrence read by its id with any timezone, then edited with the recurrence_id read printed, is the one edited")
    func readByIdThenEditNamesTheSameOccurrence() async throws {
        let slot = try #require(LateSeries.at(day(7)))
        let (device, edit) = try fixedZones(at: slot)
        let read = try #require(TimeZone(identifier: "Pacific/Chatham"))
        try #require(read.secondsFromGMT(for: slot) != TimeZone.current.secondsFromGMT(for: slot), "the host is in the read zone")
        try await withGoogle("rid-g-read", seed: LateSeries.calendar(rule: "RRULE:FREQ=WEEKLY")) { calendar, pool in
            let account = "rid-g-read"
            let instance = LateSeries.instanceId(day(7))
            let translator = ChatIdTranslator.createIsolated()
            let compound = CompoundEventId.make(accountId: account, eventId: instance)
            let forModel = await translator.processToolOutputForLLM("event_id: \(compound)")
            let numericId = try #require(CalDAVToolWire.eventIds(in: forModel).first, "no numeric id: \(forModel)")
            await translator.cacheEventDetail(
                realId: instance, accountId: account, calendarId: "primary", calendarName: "Work",
                title: "Standup", startDate: nil, endDate: nil, isAllDay: false,
                location: nil, notes: nil, attendees: [], isRecurring: true, recurrenceRule: nil,
                availability: "busy", htmlLink: nil, eventTimeZone: nil)
            for zone in [device, edit, read] {
                let printed = try await CalendarEventReadTool(context: ToolContext(db: pool, translator: translator, deviceZone: device))
                    .execute(arguments: ["event_id": .string(numericId), "timezone": .string(zone.identifier)])
                let line = try #require(printed.split(separator: "\n").first { $0.hasPrefix("start_iso: ") },
                                        "read \(zone.identifier) printed no start_iso: \(printed)")
                let rid = String(line.dropFirst("start_iso: ".count).prefix(19))
                let sink = ConfirmingCards()
                let out = try await CalendarEventEditTool(context: ToolContext(db: pool, translator: translator, deviceZone: device))
                    .execute(arguments: [
                        "event_id": .string(numericId), "edit_scope": .string("this_only"), "recurrence_id": .string(rid),
                        "timezone": .string(edit.identifier), "title": .string("Standup \(zone.identifier)"),
                    ], invocation: ToolInvocation(uiSink: sink, sessionKey: "rid-read-\(zone.identifier)"))
                await AccountManager.shared.drainCalendarQueue()
                let cards = await sink.cards
                #expect(cards.count == 1 && cards.first?.startDate == slot,
                        "read in \(zone.identifier) printed \(rid): \(cards.map(\.startDate)); \(out)")
                #expect(calendar.event(instance)?["summary"] as? String == "Standup \(zone.identifier)",
                        "read in \(zone.identifier): the occurrence was not edited; \(calendar.writes); \(out)")
            }
        }
    }

    @Test("CalDAV: a read by start_iso keeps its timezone: it finds the event at that zone's wall clock and prints in it")
    func readByStartKeepsItsTimezone() async throws {
        let fixture = try OccurrenceWireFixture.make()
        let slot = try fixture.occurrence(2)
        let (device, read) = try deviceAndEditZones(at: slot)
        try await withCalDAV("rid-c-read-start", fixture: fixture) { _, pool in
            let printed = try await CalendarEventReadTool(context: ToolContext(db: pool, translator: ChatIdTranslator.createIsolated(), deviceZone: device))
                .execute(arguments: ["start_iso": .string(naive(slot, read)), "timezone": .string(read.identifier)])
            #expect(printed.contains("timezone: \(read.identifier)"), "printed: \(printed)")
            #expect(printed.contains("start_iso: \(naive(slot, read))"), "printed: \(printed)")
        }
    }

    @Test("CalDAV: a timed occurrence given all_day with only a new end, named as printed in another zone, is found and shown on the card")
    func calDAVTimedToAllDayEndOnlyAcrossZones() async throws {
        let fixture = try OccurrenceWireFixture.make()
        let slot = try fixture.occurrence(2)
        let (device, edit) = try deviceAndEditZones(at: slot)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = device
        fmt.dateFormat = "yyyy-MM-dd"
        let end = fmt.string(from: slot.addingTimeInterval(2 * 86_400))
        try await withCalDAV("rid-c-allday-end", fixture: fixture) { harness, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_only"), "recurrence_id": .string(naive(slot, device)),
                "timezone": .string(edit.identifier), "all_day": .bool(true), "end_iso": .string(end),
            ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
               account: "rid-c-allday-end", pool: pool, deviceZone: device)
            // The occurrence is found and its card shown; this calendar then refuses to change a repeating
            // occurrence's kind at the write, with nothing written, which is not what this test is about.
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            #expect(card.startDate == slot, "the card shows \(card.startDate), not the occurrence named")
            _ = harness
        }
    }

    // MARK: Each place the recurrence_id's zone and the edit's zone part (#794 review)

    @Test("a queued edit with no recurrence_id zone (queued before it was) reads its recurrence_id in the edit's zone")
    func legacyRowIsReadInTheEditZone() throws {
        let edit = try #require(TimeZone(identifier: "America/St_Johns"))
        let zone = try CalendarToolHelpers.recurrenceIdZone(["timezone": .string(edit.identifier)], editZone: edit)
        #expect(zone.identifier == edit.identifier, "read in \(zone.identifier)")
        #expect(zone.identifier != TimeZone.current.identifier)
    }

    @Test("a queued recurrence_id zone that is not recognized is refused, never replaced")
    func unrecognizedRecurrenceIdZoneIsRefused() throws {
        let edit = try #require(TimeZone(identifier: "America/St_Johns"))
        #expect(throws: CalendarProviderError.self) {
            _ = try CalendarToolHelpers.recurrenceIdZone(
                [CalendarToolHelpers.recurrenceIdZoneKey: .string("Not/AZone")], editZone: edit)
        }
    }

    @Test("Google: a split moved to another date, named as printed with its new time in another zone, turns the days the card says, at the occurrence named")
    func googleSplitDayMoveAcrossZones() async throws {
        let slot = try #require(LateSeries.at(day(7)))
        let newStart = try #require(utcAt("\(day(8))T01:00:00"))
        let (device, edit) = try fixedZones(at: slot)
        let rule = "RRULE:FREQ=WEEKLY;BYDAY=\(try weekday(day(0)));COUNT=10"
        let rid = naive(slot, device)
        try await withGoogle("rid-g-daymove", seed: LateSeries.calendar(rule: rule)) { calendar, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_and_following"), "recurrence_id": .string(rid),
                "timezone": .string(edit.identifier),
                "start_iso": .string(naive(newStart, edit)), "end_iso": .string(naive(newStart.addingTimeInterval(1_800), edit)),
            ], eventId: LateSeries.id, calendarId: "primary", account: "rid-g-daymove", pool: pool, deviceZone: device)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let successor = calendar.event(GoogleCalendarProvider.deterministicSplitEventId(masterId: LateSeries.id, recurrenceId: rid))
            let written = try #require((successor?["recurrence"] as? [String])?.first { $0.hasPrefix("RRULE:") },
                                       "no new part: \(calendar.writes); \(summary(r))")
            #expect(written.contains("BYDAY=\(try weekday(day(8)))"), "the new part repeats \(written)")
            #expect(instant(successor?["start"]) == newStart, "new part \(successor?["start"] ?? "none")")
            let shown = card.changes.filter { $0.hasPrefix("repeat → ") }.map { "RRULE:" + $0.dropFirst("repeat → ".count) }
            #expect(shown.map(GoogleCalendarProvider.canonicalRRULE) == [GoogleCalendarProvider.canonicalRRULE(written)],
                    "the card says \(shown), the calendar was written \(written)")
        }
    }

    @Test("Google: a new time of day of every occurrence, named by a later occurrence's id in another zone, is written to the series at the drain")
    func googleWholeSeriesTimeOfDayAcrossZones() async throws {
        let slot = try #require(LateSeries.at(day(7)))
        let newStart = try #require(utcAt("\(day(7))T01:00:00"))
        let (device, edit) = try fixedZones(at: slot)
        try await withGoogle("rid-g-all", seed: LateSeries.calendar(rule: "RRULE:FREQ=WEEKLY")) { calendar, pool in
            let r = try await runEdit([
                "timezone": .string(edit.identifier),
                "start_iso": .string(naive(newStart, edit)), "end_iso": .string(naive(newStart.addingTimeInterval(1_800), edit)),
            ], eventId: LateSeries.instanceId(day(7)), calendarId: "primary", account: "rid-g-all", pool: pool, deviceZone: device)
            _ = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            #expect(instant(calendar.event(LateSeries.id)?["start"]) == utcAt("\(day(0))T01:00:00"),
                    "series \(calendar.event(LateSeries.id)?["start"] ?? "none"); \(summary(r))")
        }
    }

    @Test("Google: an all-day occurrence given only a new end, named as printed in another zone, keeps its start")
    func googleAllDayEndOnlyAcrossZones() async throws {
        let slot = try #require(utcAt("\(day(7))T12:00:00"))
        let (device, edit) = try fixedZones(at: slot)
        let seriesId = "ser-allday"
        func dates(_ d: String, _ e: String) -> [String: Any] { ["start": ["date": d], "end": ["date": e]] }
        var series: [String: Any] = ["id": seriesId, "summary": "Offsite", "status": "confirmed", "recurrence": ["RRULE:FREQ=WEEKLY"]]
        series.merge(dates(day(0), day(1))) { $1 }
        let instances = [day(0), day(7)].map { d -> [String: Any] in
            var e: [String: Any] = ["id": "\(seriesId)_\(compact(d))", "summary": "Offsite", "status": "confirmed",
                                    "recurringEventId": seriesId, "originalStartTime": ["date": d]]
            e.merge(dates(d, d == day(0) ? day(1) : day(8))) { $1 }
            return e
        }
        try await withGoogle("rid-g-allday", seed: [series] + instances) { calendar, pool in
            let r = try await runEdit([
                "edit_scope": .string("this_only"), "recurrence_id": .string("\(day(7))T00:00:00"),
                "timezone": .string(edit.identifier), "end_iso": .string(day(9)),
            ], eventId: "\(seriesId)_\(compact(day(7)))", calendarId: "primary", account: "rid-g-allday", pool: pool, deviceZone: device)
            _ = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let written = calendar.event("\(seriesId)_\(compact(day(7)))")
            #expect((written?["end"] as? [String: Any])?["date"] as? String == day(9), "end \(written?["end"] ?? "none"); \(summary(r))")
            #expect((written?["start"] as? [String: Any])?["date"] as? String == day(7), "start \(written?["start"] ?? "none")")
        }
    }
}

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

// MARK: - A floating occurrence is found by its wall clock in the zone that names it (#761)
//
// INVARIANT: a floating time is a wall clock with no zone, so the occurrence a `recurrence_id`
// names is the one at that wall clock, whatever zone the `recurrence_id` is read in and whatever
// the device's zone is. It used to be compared as an instant, the series read in the device's
// zone and the `recurrence_id` in the zone the call named: after a change of the device's zone
// the occurrence was not found (#761), or, with a series a whole number of hours apart, another
// one was (#753 review). The host's zone stands for the device's; each case names the occurrence
// in zones whose offset is not the host's.

@Suite("A floating CalDAV occurrence is found by its wall clock in the zone that names it (#761)")
struct CalDAVFloatingOccurrenceMatchTests {
    private let href = OccurrenceFixture.href

    /// A weekly floating series from day 0 at 09:00, with `extra` VEVENTs after it.
    private func series(_ extra: [String] = []) -> String {
        OccurrenceFixture.ics([[
            "UID:standup-1", "DTSTAMP:\(compact(day(0)))T000000Z",
            "DTSTART:\(compact(day(0)))T090000", "DTEND:\(compact(day(0)))T093000",
            "SUMMARY:Standup", "RRULE:FREQ=WEEKLY",
        ].joined(separator: "\n")] + extra)
    }

    /// Week 1's occurrence moved to the next day at 10:00, as a changed copy.
    private var movedCopy: String {
        [
            "UID:standup-1", "DTSTAMP:\(compact(day(0)))T000000Z",
            "RECURRENCE-ID:\(compact(day(7)))T090000",
            "DTSTART:\(compact(day(8)))T100000", "DTEND:\(compact(day(8)))T103000",
            "SUMMARY:Standup (moved)",
        ].joined(separator: "\n")
    }

    private func zones() throws -> [TimeZone] { try zonesNotTheHost(at: try #require(utcAt("\(day(14))T09:00:00"))) }

    @Test("an occurrence of the series is found at the wall clock named, by recurrence_id alone or with its occurrence id")
    func seriesOccurrence() throws {
        for zone in try zones() {
            let slot = try CalDAVOccurrences.scopedEditSlot(
                icsText: series(), href: href, key: nil, recurrenceId: "\(day(14))T09:00:00", zone: zone, forSplit: false)
            #expect(slot == "\(day(14))T09:00:00", "\(zone.identifier)")
            let named = try CalDAVOccurrences.scopedEdit(
                icsText: series(), href: href, key: "\(compact(day(14)))T090000",
                recurrenceId: "\(day(14))T09:00:00", zone: zone, forSplit: true)
            #expect(named.key == "\(compact(day(14)))T090000", "\(zone.identifier)")
        }
    }

    @Test("a DAILY series named from zones up to a day apart (Kiritimati, Pago Pago) finds the occurrence at the named wall clock, never the day before or after")
    func dailySeriesFromZonesADayApart() throws {
        let ics = OccurrenceFixture.ics([[
            "UID:daily-1", "DTSTAMP:\(compact(day(0)))T000000Z",
            "DTSTART:\(compact(day(0)))T090000", "DTEND:\(compact(day(0)))T093000",
            "SUMMARY:Daily", "RRULE:FREQ=DAILY",
        ].joined(separator: "\n")])
        for name in ["Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            let zone = try #require(TimeZone(identifier: name))
            for offset in [13, 14, 15] {
                let named = try CalDAVOccurrences.scopedEdit(
                    icsText: ics, href: href, key: nil, recurrenceId: "\(day(offset))T09:00:00", zone: zone, forSplit: false)
                #expect(named.key == "\(compact(day(offset)))T090000", "\(name), day \(offset): found \(named.key)")
            }
        }
    }

    @Test("control: a wall clock no occurrence starts at names none, in any zone")
    func noOccurrenceAtThatWallClock() throws {
        for zone in try zones() {
            #expect(throws: CalDAVError.self, "\(zone.identifier)") {
                try CalDAVOccurrences.scopedEditSlot(
                    icsText: series(), href: href, key: nil, recurrenceId: "\(day(14))T10:00:00", zone: zone, forSplit: false)
            }
        }
    }

    @Test("a moved occurrence is found where it is now, at its wall clock")
    func movedOccurrence() throws {
        for zone in try zones() {
            let named = try CalDAVOccurrences.scopedEdit(
                icsText: series([movedCopy]), href: href, key: nil, recurrenceId: "\(day(8))T10:00:00", zone: zone, forSplit: false)
            #expect(named.key == "\(compact(day(7)))T090000", "\(zone.identifier)")
        }
    }

    @Test("a changed occurrence held without its series is found where it is now, at its wall clock")
    func occurrenceWithoutItsSeries() throws {
        let ics = OccurrenceFixture.ics([movedCopy])
        for zone in try zones() {
            let named = try CalDAVOccurrences.scopedEdit(
                icsText: ics, href: href, key: "\(compact(day(7)))T090000", recurrenceId: "\(day(8))T10:00:00", zone: zone, forSplit: false)
            #expect(named.key == "\(compact(day(7)))T090000", "\(zone.identifier)")
        }
    }

    @Test("control: a listing shows a moved floating occurrence at its wall clock on the device")
    func listingIsUnchanged() throws {
        let from = try #require(utcAt("\(day(6))T00:00:00"))
        let to = try #require(utcAt("\(day(10))T00:00:00"))
        let rows = OccurrenceFixture.listing(series([movedCopy]), from: from, to: to)
        let moved = try #require(rows.first { $0.summary == "Standup (moved)" }, "rows: \(rows.map(\.summary))")
        #expect(moved.startDate == EKEventStoreHelper.parseNaiveISO("\(day(8))T10:00:00", timeZone: .current))
        #expect(moved.endDate == EKEventStoreHelper.parseNaiveISO("\(day(8))T10:30:00", timeZone: .current))
    }

    @Test("exdates_add with no zone given reads its dates in the zone the tool snapshotted")
    func exdatesUseTheSnapshotZone() throws {
        let zone = try zones()[0]
        let checked = CalendarEventEditExdates.check(
            ["event_id": .string("1"), "exdates_add": .array([.string("\(day(14))T09:00:00")])],
            compoundId: "acct:event", deviceZone: zone)
        guard case .dates(let dates, let resolved) = checked else {
            Issue.record("refused: \(checked)")
            return
        }
        #expect(dates == ["\(day(14))T09:00:00"])
        #expect(resolved.identifier == zone.identifier)
    }
}

// MARK: - A delete of a repeating event deletes exactly the occurrences its scope names (#695)
//
// INVARIANT (system property): `calendar_event_delete` on a repeating event removes exactly the
// occurrences `delete_scope` names, at the occurrence the read tools printed, whatever zone the
// device, the read and the delete's `timezone` are in, and wherever the drain runs: "this_only"
// that occurrence alone; "this_and_following" that occurrence and every later one, the earlier
// ones staying (the series ends just before the occurrence's place in the series, also for one
// moved from it, and guests are told); "this_and_following" at the series' first occurrence, the
// whole series. A repeating event with no scope is never deleted: the assistant is told to ask the
// user, before any card. The queue drains in the host's zone, which is neither the device's nor
// the delete's, and the series start late in the UTC day, so a cut read in the wrong zone lands
// on another date.

/// `calendar_event_delete` of `eventId` in `calendarId`, named by the number the chat translator
/// gives the model, confirmed, with the device in `deviceZone`; then the queue drains.
private func runDelete(
    _ arguments: [String: JSONValue], eventId: String, calendarId: String, account: String,
    pool: DatabasePool, deviceZone: TimeZone, translator given: ChatIdTranslator? = nil
) async throws -> Run {
    let translator = given ?? ChatIdTranslator.createIsolated()
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
    let out = try await CalendarEventDeleteTool(context: ToolContext(db: pool, translator: translator, deviceZone: deviceZone))
        .execute(arguments: args, invocation: ToolInvocation(uiSink: sink, sessionKey: "delete-\(account)"))
    await AccountManager.shared.drainCalendarQueue()
    let queued = try await pool.read { try PendingCalendarOperation.fetchAll($0) }
    return Run(out: out, cards: await sink.cards, queued: queued)
}

/// The instant a stored repeat rule's `UNTIL` names (`yyyyMMddTHHmmssZ`), nil when it has none.
private func untilInstant(_ recurrence: [String]?) -> Date? {
    guard let rule = recurrence?.first(where: { $0.uppercased().hasPrefix("RRULE:") }),
          let part = rule.split(separator: ";").first(where: { $0.uppercased().hasPrefix("UNTIL=") }) else { return nil }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = .gmt
    fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return fmt.date(from: String(part.dropFirst("UNTIL=".count)))
}

/// The device's zone, the delete's `timezone` and the zone a read names: three zones that differ
/// from each other and from the host's at `at`.
private func deleteZones(at: Date) throws -> (device: TimeZone, delete: TimeZone, read: TimeZone) {
    let (device, delete) = try fixedZones(at: at)
    let read = try #require(TimeZone(identifier: "Pacific/Chatham"))
    try #require(read.secondsFromGMT(for: at) != TimeZone.current.secondsFromGMT(for: at), "the host is in the read zone")
    return (device, delete, read)
}

/// The occurrence's `start_iso` as `calendar_event_read` prints it, read by its id with `timezone`
/// set to `zone`.
private func printedStart(eventId: String, account: String, pool: DatabasePool, translator: ChatIdTranslator,
                          deviceZone: TimeZone, zone: TimeZone) async throws -> String {
    let compound = CompoundEventId.make(accountId: account, eventId: eventId)
    let forModel = await translator.processToolOutputForLLM("event_id: \(compound)")
    let numericId = try #require(CalDAVToolWire.eventIds(in: forModel).first, "no numeric id: \(forModel)")
    await translator.cacheEventDetail(
        realId: eventId, accountId: account, calendarId: "primary", calendarName: "Work",
        title: "Standup", startDate: nil, endDate: nil, isAllDay: false,
        location: nil, notes: nil, attendees: [], isRecurring: true, recurrenceRule: nil,
        availability: "busy", htmlLink: nil, eventTimeZone: nil)
    let printed = try await CalendarEventReadTool(context: ToolContext(db: pool, translator: translator, deviceZone: deviceZone))
        .execute(arguments: ["event_id": .string(numericId), "timezone": .string(zone.identifier)])
    let line = try #require(printed.split(separator: "\n").first { $0.hasPrefix("start_iso: ") }, "no start_iso: \(printed)")
    return String(line.dropFirst("start_iso: ".count).prefix(19))
}

@Suite("calendar_event_delete: a delete_scope deletes exactly the occurrences it names (#695)", .serialized, .processGlobalState)
struct CalendarScopedDeleteTests {

    @Test("Google: one occurrence read by its id in another zone, deleted with the recurrence_id printed, is the only one deleted")
    func googleThisOnlyAsPrinted() async throws {
        let slot = try #require(LateSeries.at(day(7)))
        let (device, delete, read) = try deleteZones(at: slot)
        let account = "del-g-one"
        try await withGoogle(account, seed: LateSeries.calendar(rule: "RRULE:FREQ=WEEKLY")) { calendar, pool in
            let translator = ChatIdTranslator.createIsolated()
            let rid = try await printedStart(eventId: LateSeries.instanceId(day(7)), account: account, pool: pool,
                                             translator: translator, deviceZone: device, zone: read)
            let r = try await runDelete([
                "delete_scope": .string("this_only"), "recurrence_id": .string(rid), "timezone": .string(delete.identifier),
            ], eventId: LateSeries.id, calendarId: "primary", account: account, pool: pool, deviceZone: device, translator: translator)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            #expect(card.startDate == slot, "the card shows \(card.startDate), not the occurrence named")
            #expect(card.changes == [CalendarToolHelpers.occurrenceDeleteNote], "card \(card.changes)")
            #expect(calendar.event(LateSeries.instanceId(day(7)))?["status"] as? String == "cancelled",
                    "the occurrence named was not deleted; writes \(calendar.writes); \(summary(r))")
            #expect(calendar.event(LateSeries.instanceId(day(0)))?["status"] as? String == "confirmed",
                    "another occurrence was deleted; writes \(calendar.writes)")
            #expect(calendar.event(LateSeries.id)?["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY"],
                    "the series changed: \(calendar.event(LateSeries.id) ?? [:])")
            #expect(calendar.deleteSendUpdates == ["all"], "guests: \(calendar.deleteSendUpdates)")
            #expect(r.out.contains("the rest of the series stays"), "\(r.out)")
        }
    }

    @Test("Google: an occurrence and every later one, named as printed, end the series just before it; earlier ones stay and guests are told")
    func googleThisAndFollowingAsPrinted() async throws {
        let slot = try #require(LateSeries.at(day(7)))
        let first = try #require(LateSeries.at(day(0)))
        let (device, delete, read) = try deleteZones(at: slot)
        let account = "del-g-following"
        try await withGoogle(account, seed: LateSeries.calendar(rule: "RRULE:FREQ=WEEKLY")) { calendar, pool in
            let translator = ChatIdTranslator.createIsolated()
            let rid = try await printedStart(eventId: LateSeries.instanceId(day(7)), account: account, pool: pool,
                                             translator: translator, deviceZone: device, zone: read)
            let r = try await runDelete([
                "delete_scope": .string("this_and_following"), "recurrence_id": .string(rid), "timezone": .string(delete.identifier),
            ], eventId: LateSeries.instanceId(day(7)), calendarId: "primary", account: account, pool: pool,
               deviceZone: device, translator: translator)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            #expect(card.startDate == slot, "the card shows \(card.startDate), not the occurrence named")
            #expect(card.changes == ["This and every later occurrence will be deleted; earlier ones stay.", "Repeats weekly"],
                    "card \(card.changes)")
            let series = calendar.event(LateSeries.id)
            let until = try #require(untilInstant(series?["recurrence"] as? [String]),
                                     "the series was not ended: \(series ?? [:]); writes \(calendar.writes); \(summary(r))")
            #expect(until < slot && until >= first, "the series now ends at \(until): not just before the occurrence named (\(slot))")
            #expect(series?["status"] as? String == "confirmed", "the series was deleted: \(series ?? [:])")
            #expect(calendar.patchSendUpdates == ["all"], "guests: \(calendar.patchSendUpdates)")
            #expect(calendar.deleteSendUpdates.isEmpty, "an event was deleted: \(calendar.writes)")
            #expect(r.queued.isEmpty, "the delete did not complete: \(summary(r))")
            #expect(r.out.contains("This and every later occurrence deleted successfully; earlier ones stay."), "\(r.out)")
        }
    }

    @Test("Google: from the series' first occurrence on, named by that occurrence, is the whole series, deleted with every occurrence")
    func googleFollowingFromTheFirstIsTheSeries() async throws {
        let first = try #require(LateSeries.at(day(0)))
        let (device, delete, _) = try deleteZones(at: first)
        try await withGoogle("del-g-first", seed: LateSeries.calendar(rule: "RRULE:FREQ=WEEKLY")) { calendar, pool in
            let r = try await runDelete([
                "delete_scope": .string("this_and_following"), "recurrence_id": .string(naive(first, device)),
                "timezone": .string(delete.identifier),
            ], eventId: LateSeries.instanceId(day(0)), calendarId: "primary", account: "del-g-first", pool: pool, deviceZone: device)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            #expect(card.changes == [CalendarToolHelpers.seriesDeleteNote, "Repeats weekly"], "card \(card.changes)")
            #expect(calendar.event(LateSeries.id) == nil, "the series is still there; writes \(calendar.writes); \(summary(r))")
            #expect(calendar.deleteSendUpdates == ["all"], "guests: \(calendar.deleteSendUpdates)")
            #expect(r.out.contains("every occurrence"), "\(r.out)")
        }
    }

    @Test("Google: an occurrence moved to another day is cut at its place in the series, and the card shows both times")
    func googleMovedOccurrenceIsCutAtItsPlace() async throws {
        let slot = try #require(LateSeries.at(day(7)))
        let first = try #require(LateSeries.at(day(0)))
        let now = try #require(LateSeries.at(day(9)))
        let (device, delete, _) = try deleteZones(at: slot)
        var seed = LateSeries.calendar(rule: "RRULE:FREQ=WEEKLY")
        let index = try #require(seed.firstIndex { $0["id"] as? String == LateSeries.instanceId(day(7)) })
        seed[index]["start"] = ["dateTime": "\(day(9))T20:00:00Z", "timeZone": "UTC"]
        seed[index]["end"] = ["dateTime": "\(day(9))T20:30:00Z", "timeZone": "UTC"]
        try await withGoogle("del-g-moved", seed: seed) { calendar, pool in
            let r = try await runDelete([
                "delete_scope": .string("this_and_following"), "recurrence_id": .string(naive(now, device)),
                "timezone": .string(delete.identifier),
            ], eventId: LateSeries.id, calendarId: "primary", account: "del-g-moved", pool: pool, deviceZone: device)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            #expect(card.startDate == now, "the card shows \(card.startDate), not the occurrence where it is now")
            #expect(card.changes.first == "This and every later occurrence will be deleted (from \(naive(now, device)), originally \(naive(slot, device))); earlier ones stay.",
                    "card \(card.changes)")
            let until = try #require(untilInstant(calendar.event(LateSeries.id)?["recurrence"] as? [String]),
                                     "the series was not ended: writes \(calendar.writes); \(summary(r))")
            #expect(until < slot && until >= first, "the series now ends at \(until), not just before the moved occurrence's place (\(slot))")
        }
    }

    @Test("Google: a repeating event with no delete_scope is refused before the card, the assistant told to ask, nothing written")
    func googleNoScopeIsAsked() async throws {
        let slot = try #require(LateSeries.at(day(7)))
        let (device, _, _) = try deleteZones(at: slot)
        for eventId in [LateSeries.id, LateSeries.instanceId(day(7))] {
            try await withGoogle("del-g-ask", seed: LateSeries.calendar(rule: "RRULE:FREQ=WEEKLY")) { calendar, pool in
                let r = try await runDelete([:], eventId: eventId, calendarId: "primary", account: "del-g-ask", pool: pool, deviceZone: device)
                #expect(r.cards.isEmpty, "a card was shown for \(eventId): \(r.cards.map(\.changes))")
                #expect(calendar.writes.isEmpty, "\(eventId): written \(calendar.writes)")
                #expect(r.queued.isEmpty, "\(eventId): queued \(summary(r))")
                #expect(r.out.contains("Just this one, this and following, or all of them?"), "\(eventId): \(r.out)")
            }
        }
    }

    @Test("Outlook: an occurrence and every later one, named as printed in another zone, end the series before it; the first stays")
    func outlookThisAndFollowing() async throws {
        let slot = GraphFixture.occurrenceStart
        let (device, delete) = try deviceAndEditZones(at: slot)
        try await withOutlook("del-x-following") { graph, pool in
            let r = try await runDelete([
                "delete_scope": .string("this_and_following"), "recurrence_id": .string(naive(slot, device)),
                "timezone": .string(delete.identifier),
            ], eventId: "ser-1", calendarId: "primary", account: "del-x-following", pool: pool, deviceZone: device)
            _ = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let rangeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
            let days = try #require(graph.rangeDays(of: "ser-1"), "the series was not ended: writes \(graph.writes); \(summary(r))")
            let named = EKEventStoreHelper.dayKey(slot, timeZone: rangeZone)
            #expect(!days.isEmpty && days.allSatisfy { $0 < named }, "the series repeats on \(days), not only before \(named)")
            #expect(days.first == EKEventStoreHelper.dayKey(GraphFixture.start, timeZone: rangeZone), "the first occurrence went: \(days)")
            #expect(r.queued.isEmpty, "the delete did not complete: \(summary(r))")
        }
    }

    @Test("CalDAV: one occurrence named as printed by the series' id is the only one excluded")
    func calDAVThisOnlyBySeriesId() async throws {
        let fixture = try OccurrenceWireFixture.make()
        let slot = try fixture.occurrence(2)
        let (device, delete) = try deviceAndEditZones(at: slot)
        try await withCalDAV("del-c-one", fixture: fixture) { harness, pool in
            let r = try await runDelete([
                "delete_scope": .string("this_only"), "recurrence_id": .string(naive(slot, device)),
                "timezone": .string(delete.identifier),
            ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
               account: "del-c-one", pool: pool, deviceZone: device)
            _ = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let lines = CalDAVProvider.icsLines(harness.store.storedICS(path: OccurrenceWireFixture.seriesPath) ?? "")
            #expect(lines.filter { $0.hasPrefix("EXDATE") } == ["EXDATE;TZID=America/New_York:\(OccurrenceFixture.wall(slot, fixture.zone))"],
                    "excluded \(lines.filter { $0.hasPrefix("EXDATE") }); \(summary(r))")
            #expect(CalDAVToolWire.deletes(harness.http).isEmpty, "a DELETE reached the server")
        }
    }

    @Test("CalDAV: an occurrence and every later one, named as printed in another zone, end the series before it; earlier ones stay")
    func calDAVThisAndFollowing() async throws {
        let fixture = try OccurrenceWireFixture.make()
        let slot = try fixture.occurrence(2)
        let earlier = try fixture.occurrence(1)
        let (device, delete) = try deviceAndEditZones(at: slot)
        try await withCalDAV("del-c-following", fixture: fixture) { harness, pool in
            let r = try await runDelete([
                "delete_scope": .string("this_and_following"), "recurrence_id": .string(naive(slot, device)),
                "timezone": .string(delete.identifier),
            ], eventId: OccurrenceWireFixture.seriesPath, calendarId: OccurrenceWireFixture.calendarId,
               account: "del-c-following", pool: pool, deviceZone: device)
            _ = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            let lines = CalDAVProvider.icsLines(harness.store.storedICS(path: OccurrenceWireFixture.seriesPath) ?? "")
            let until = try #require(untilInstant(lines.filter { $0.hasPrefix("RRULE:") }),
                                     "the series was not ended: \(lines.filter { $0.hasPrefix("RRULE") }); \(summary(r))")
            #expect(until < slot && until >= earlier, "the series now ends at \(until), not just before \(slot)")
            #expect(CalDAVToolWire.deletes(harness.http).isEmpty, "a DELETE reached the server")
            #expect(r.queued.isEmpty, "the delete did not complete: \(summary(r))")
        }
    }

    @Test("Google: every occurrence, named by one occurrence's id, deletes the series, not that occurrence alone")
    func googleAllFromAnOccurrence() async throws {
        let slot = try #require(LateSeries.at(day(7)))
        let (device, _, _) = try deleteZones(at: slot)
        try await withGoogle("del-g-all-occ", seed: LateSeries.calendar(rule: "RRULE:FREQ=WEEKLY")) { calendar, pool in
            let r = try await runDelete(["delete_scope": .string("all")], eventId: LateSeries.instanceId(day(7)),
                                        calendarId: "primary", account: "del-g-all-occ", pool: pool, deviceZone: device)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            #expect(card.changes == [CalendarToolHelpers.seriesDeleteNote, "Repeats weekly"], "card \(card.changes)")
            #expect(calendar.writes == ["DELETE \(LateSeries.id)"], "writes \(calendar.writes); \(summary(r))")
            #expect(calendar.event(LateSeries.id) == nil, "the series is still there: \(calendar.event(LateSeries.id) ?? [:])")
            #expect(calendar.deleteSendUpdates == ["all"], "guests: \(calendar.deleteSendUpdates)")
            #expect(r.queued.isEmpty, "the delete did not complete: \(summary(r))")
            #expect(r.out.contains("every occurrence"), "\(r.out)")
        }
    }

    @Test("CalDAV: every occurrence, named by one occurrence's id, deletes the series, not that occurrence alone")
    func calDAVAllFromAnOccurrence() async throws {
        let fixture = try OccurrenceWireFixture.make()
        let slot = try fixture.occurrence(2)
        let (device, _) = try deviceAndEditZones(at: slot)
        try await withCalDAV("del-c-all-occ", fixture: fixture) { harness, pool in
            let r = try await runDelete(["delete_scope": .string("all")], eventId: try fixture.occurrenceId(2),
                                        calendarId: OccurrenceWireFixture.calendarId, account: "del-c-all-occ", pool: pool, deviceZone: device)
            let card = try #require(r.card, "\(r.cards.count) cards: \(summary(r))")
            #expect(card.changes == [CalendarToolHelpers.seriesDeleteNote, "Repeats weekly"], "card \(card.changes)")
            #expect(CalDAVToolWire.deletes(harness.http).count == 1, "DELETEs: \(CalDAVToolWire.deletes(harness.http)); \(summary(r))")
            #expect(harness.store.storedICS(path: OccurrenceWireFixture.seriesPath) == nil, "the series is still on the server")
            #expect(harness.store.recordedPuts().isEmpty, "the series was rewritten: \(harness.store.recordedPuts().map(\.path))")
            #expect(r.queued.isEmpty, "the delete did not complete: \(summary(r))")
        }
    }

    /// A delete of a repeating event the tool refuses before its card, and what the refusal says.
    struct RefusedScope: Sendable, CustomTestStringConvertible {
        let scope: String
        let namesOccurrence: Bool
        let says: String
        var testDescription: String { "\(scope)\(namesOccurrence ? " with recurrence_id" : " without recurrence_id")" }
    }

    static let refusedScopes = [
        RefusedScope(scope: "next_ones", namesOccurrence: true,
                     says: "delete_scope 'next_ones' is not one of 'this_only', 'this_and_following' or 'all'."),
        RefusedScope(scope: "this_only", namesOccurrence: false, says: "delete_scope 'this_only' needs recurrence_id"),
        RefusedScope(scope: "this_and_following", namesOccurrence: false, says: "delete_scope 'this_and_following' needs recurrence_id"),
    ]

    @Test("Google: an unknown delete_scope, or a scope of occurrences on the series' id with no recurrence_id, is refused before the card, nothing written or queued",
          arguments: refusedScopes)
    func googleRefusedBeforeTheCard(_ refused: RefusedScope) async throws {
        let slot = try #require(LateSeries.at(day(7)))
        let (device, delete, _) = try deleteZones(at: slot)
        try await withGoogle("del-g-refused", seed: LateSeries.calendar(rule: "RRULE:FREQ=WEEKLY")) { calendar, pool in
            var arguments: [String: JSONValue] = ["delete_scope": .string(refused.scope), "timezone": .string(delete.identifier)]
            if refused.namesOccurrence { arguments["recurrence_id"] = .string(naive(slot, device)) }
            let r = try await runDelete(arguments, eventId: LateSeries.id, calendarId: "primary", account: "del-g-refused",
                                        pool: pool, deviceZone: device)
            #expect(r.cards.isEmpty, "a card was shown: \(r.cards.map(\.changes))")
            #expect(calendar.writes.isEmpty, "written \(calendar.writes)")
            #expect(r.queued.isEmpty, "queued \(summary(r))")
            #expect(r.out.contains(refused.says), "\(r.out)")
            #expect(r.out.contains("The event was NOT deleted."), "\(r.out)")
        }
    }

    @Test("A queued delete of an occurrence and every later one that names no place or zone to end the series is retired as failed, and nothing is sent")
    func queuedFollowingDeleteWithNoCutIsRetired() async throws {
        let slot = try #require(LateSeries.at(day(7)))
        let (device, _, _) = try deleteZones(at: slot)
        let malformed: [[String: JSONValue]] = [
            ["delete_scope": .string("this_and_following")],
            ["delete_scope": .string("this_and_following"), CalendarToolHelpers.deleteCutKey: .string(naive(slot, device))],
            ["delete_scope": .string("this_and_following"), CalendarToolHelpers.recurrenceIdZoneKey: .string(device.identifier)],
        ]
        for arguments in malformed {
            try await withGoogle("del-g-no-cut", seed: LateSeries.calendar(rule: "RRULE:FREQ=WEEKLY")) { calendar, pool in
                // Inserted directly: `queueCalendarOperation` starts a drain of its own, which this
                // test's drain would then skip as "already draining", reading the row mid-flight.
                let op = PendingCalendarOperation(
                    operationType: .delete, accountId: "del-g-no-cut", eventId: LateSeries.id, calendarId: "primary",
                    arguments: arguments)
                try await pool.write { db in try op.insert(db) }
                await AccountManager.shared.drainCalendarQueue()
                let rows = try await pool.read { try PendingCalendarOperation.fetchAll($0) }
                #expect(rows.count == 1, "\(arguments.keys.sorted()): rows \(rows.map(\.status))")
                guard rows.count == 1 else { return }
                #expect(rows[0].id == op.id && rows[0].status == PendingStatus.failed.rawValue,
                        "\(arguments.keys.sorted()): \(rows[0].status) \(rows[0].failureReason ?? "")")
                #expect(rows[0].failureReason?.contains("names no place to end the series") == true,
                        "\(arguments.keys.sorted()): \(rows[0].failureReason ?? "nil")")
                #expect(calendar.writes.isEmpty, "\(arguments.keys.sorted()): written \(calendar.writes)")
                #expect(calendar.event(LateSeries.id)?["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY"],
                        "\(arguments.keys.sorted()): the series changed: \(calendar.event(LateSeries.id) ?? [:])")
            }
        }
    }

    @Test("Google: an event that does not repeat, given any delete_scope, is deleted as it is: the scope is dropped")
    func googleNonRepeatingDropsTheScope() async throws {
        let at = try #require(LateSeries.at(day(7)))
        let (device, delete, _) = try deleteZones(at: at)
        let single: [String: Any] = [
            "id": "one-off", "summary": "Review", "status": "confirmed",
            "start": ["dateTime": "\(day(7))T20:00:00Z", "timeZone": "UTC"],
            "end": ["dateTime": "\(day(7))T20:30:00Z", "timeZone": "UTC"],
        ]
        for scope in CalendarEventDeleteTool.scopes {
            try await withGoogle("del-g-single", seed: [single]) { calendar, pool in
                let r = try await runDelete([
                    "delete_scope": .string(scope), "recurrence_id": .string(naive(at, device)),
                    "timezone": .string(delete.identifier),
                ], eventId: "one-off", calendarId: "primary", account: "del-g-single", pool: pool, deviceZone: device)
                let card = try #require(r.card, "\(scope): \(r.cards.count) cards: \(summary(r))")
                #expect(card.changes.isEmpty, "\(scope): card \(card.changes)")
                #expect(calendar.writes == ["DELETE one-off"], "\(scope): writes \(calendar.writes); \(summary(r))")
                #expect(calendar.deleteSendUpdates == ["all"], "\(scope): guests \(calendar.deleteSendUpdates)")
                #expect(r.queued.isEmpty, "\(scope): the delete did not complete: \(summary(r))")
                #expect(r.out.hasPrefix("Calendar event deleted successfully."), "\(scope): \(r.out)")
                #expect(!r.out.contains("delete_scope"), "\(scope): \(r.out)")
            }
        }
    }
}
