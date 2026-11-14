/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - calendar_event_edit's exdates_add deletes the occurrences it names (#694)
//
// INVARIANT (the bug's own): *a calendar_event_edit carrying exdates_add either deletes exactly the
// occurrences its dates name, one ordinary delete each, after a delete card listing exactly those
// occurrences, or it is refused before the card with nothing queued and nothing written. It never
// reports "updated", and never reports success while the calendar is unchanged.* Before #694 no
// iOS code read exdates_add: the call wrote an unchanged series (or nothing) and answered "updated
// successfully", so the assistant told the user an occurrence was gone when it was not.
//
// The rules pinned, per provider, from the tool down to the fake server (Google, Graph, CalDAV):
// - every date is looked up against the SERIES, before the card, read in the call's `timezone`,
//   also when `event_id` names one of its occurrences;
// - a date-only value on a timed series names the one occurrence that day; on an Outlook all-day
//   series a date names that date's occurrence whatever zone the call names (#647's lookup);
// - a date that names no occurrence, an already deleted one, an ambiguous or a malformed one
//   refuses the WHOLE call: no card, nothing queued, nothing written; so do an unrecognised
//   `timezone`, a malformed exdates_add (not a list, a non-string or blank entry), and a lookup
//   answering with the series' own id (a delete by it would remove every occurrence);
// - exdates_add with any other argument (every schema change field, and keys outside the schema)
//   is refused by name, telling the assistant to send the other change FIRST and exdates_add after
//   a fresh read; a one-off event is refused; a declined card deletes nothing;
// - the card is the delete card, one row per occurrence, the shared occurrence line;
// - the deletes are queued in ONE write, all or none;
// - the card shows each occurrence's own start; two dates naming one occurrence delete it once;
// - the result names each date beside the occurrence it named; a delete that fails after the card
//   is named with its reason, one that fails for a passing reason is named queued;
// - Google deletes notify guests as every iOS delete does (`sendUpdates=all`);
// - CalDAV goes through #661's EXDATE write, and refuses a resource holding only changed
//   occurrences before the card.
// Every date is relative to today.

private let utc = TimeZone(identifier: "UTC")!

/// The UTC date `offset` days after the day two weeks from today, as `yyyy-MM-dd`.
private func day(_ offset: Int) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    let base = cal.startOfDay(for: Date().addingTimeInterval(14 * 86_400))
    let date = cal.date(byAdding: .day, value: offset, to: base)!
    return OccurrenceFixture.isoDate(date, utc)
}

private func compact(_ day: String) -> String { day.replacingOccurrences(of: "-", with: "") }

/// The instant `time` UTC on `day`.
private func instant(_ day: String, _ time: String = "09:00:00") -> Date {
    ISO8601DateFormatter().date(from: "\(day)T\(time)Z")!
}

/// The words no exdates_add answer may carry: the edit tool's success for a change it did not make.
private let updatedWord = "updated"
/// What every refusal of an exdates_add call says.
private let nothingDeleted = "Nothing was deleted"
/// A combined call's refusal: the other change goes FIRST (a series change on Google and Outlook
/// brings back occurrences deleted before it), then exdates_add alone, after a fresh read.
private let otherChangeFirst = "First send the other change as its own calendar_event_edit call, without exdates_add"
private let exdatesAfterARead = "Then read the event again and call calendar_event_edit with only event_id and exdates_add"

/// The refusal sends the other change first and exdates_add after a fresh read, in that order.
private func expectOtherChangeFirst(_ out: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let first = out.range(of: otherChangeFirst), then = out.range(of: exdatesAfterARead)
    #expect(first != nil && then != nil && first!.lowerBound < then!.lowerBound,
            "the refusal does not send the other change first and exdates_add after a fresh read: \(out)",
            sourceLocation: sourceLocation)
}

/// The answer's line for `date`: the date, the start of the occurrence it named, and what happened.
/// A failed call answers in JSON, its lines in the `error` text; a successful one in plain lines.
private func answerLine(_ out: String, date: String) -> String? {
    let object = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
    let text = object?["error"] as? String ?? out
    return text.components(separatedBy: "\n").first { $0.hasPrefix("- \(date) (occurrence starting ") }
}

// MARK: - Running the tool

/// Answers every card (`confirm`: confirms, else declines) and keeps it; runs `beforeConfirming`,
/// when given, after the card is shown and before it is answered (another client's change in between).
@MainActor
private final class KeepingSink: AgentUISink {
    var confirmations: [AgentToolRouter.ActionConfirmation] = []
    private let confirm: Bool
    private let beforeConfirming: (@Sendable () -> Void)?
    nonisolated init(confirm: Bool = true, beforeConfirming: (@Sendable () -> Void)? = nil) {
        self.confirm = confirm
        self.beforeConfirming = beforeConfirming
    }
    func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
        confirmations.append(confirmation)
        beforeConfirming?()
        confirmation.onRespond(confirm)
    }
}

private struct Run {
    let out: String
    let actions: [AgentToolRouter.ActionConfirmation.ActionType]
    let cards: [AgentToolRouter.ActionConfirmation.CalendarEventDetail]
    let failureReasons: [String?]
    let queued: [PendingCalendarOperation]
}

/// Runs `calendar_event_edit` for `eventId` on `account` with `provider` registered for it and the
/// app's database installed. `prepare` runs on that database before the tool.
private func run(
    _ arguments: [String: JSONValue], eventId: String, account: String, provider: any CalendarProvider,
    accountProvider: AccountProvider = .gmail,
    prepare: (@Sendable (Database) throws -> Void)? = nil,
    confirm: Bool = true,
    beforeConfirming: (@Sendable () -> Void)? = nil
) async throws -> Run {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var config = Configuration()
    config.foreignKeysEnabled = true
    let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
    let appDb = try AppDatabase(dbPool: pool)
    let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
        let prev = current; current = appDb; return prev
    }
    try await pool.write { db in
        var acc = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: accountProvider)
        acc.id = account
        try acc.insert(db)
        try prepare?(db)
    }
    await AccountManager.shared.registerCalendarProviderForTesting(accountId: account, provider: provider)
    defer {
        Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: account) }
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }
    var args = arguments
    args["event_id"] = .string(CompoundEventId.make(accountId: account, eventId: eventId))
    let sink = KeepingSink(confirm: confirm, beforeConfirming: beforeConfirming)
    let out: String
    do {
        out = try await CalendarEventEditTool(context: ToolContext(db: try TestDatabase.make(), translator: MockChatIdTranslator()))
            .execute(arguments: args, invocation: ToolInvocation(uiSink: sink, sessionKey: "exdates-\(account)"))
    } catch let error as ToolDeclinedError {
        out = error.output
    } catch {
        out = "threw: \(error)"
    }
    // A later drain must not write anything either.
    await AccountManager.shared.drainCalendarQueue()
    let queued = try await pool.read { try PendingCalendarOperation.fetchAll($0) }
    let (actions, cards, reasons) = await MainActor.run {
        (sink.confirmations.map(\.action),
         sink.confirmations.flatMap(\.calendarEvents),
         sink.confirmations.map { $0.responseState.failureReason })
    }
    return Run(out: out, actions: actions, cards: cards, failureReasons: reasons, queued: queued)
}

/// What a refused call leaves: no card, nothing queued, an answer saying nothing was deleted.
private func expectRefused(_ r: Run, writes: [String], naming words: [String] = [],
                           sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.cards.isEmpty, "a card was shown for a refused call: \(r.cards.map(\.title)); \(r.out)", sourceLocation: sourceLocation)
    #expect(r.queued.isEmpty, "something was queued: \(r.queued.map(\.operationType))", sourceLocation: sourceLocation)
    #expect(writes.isEmpty, "something was written: \(writes)", sourceLocation: sourceLocation)
    #expect(r.out.contains(nothingDeleted), "the answer does not say nothing was deleted: \(r.out)", sourceLocation: sourceLocation)
    #expect(!r.out.contains(updatedWord), "a refused call says \"updated\": \(r.out)", sourceLocation: sourceLocation)
    for word in words {
        #expect(r.out.contains(word), "the refusal does not name \(word): \(r.out)", sourceLocation: sourceLocation)
    }
}

/// What a call that deleted `ids` leaves: one delete card row per occurrence, with the occurrence
/// line and (for each id in `starts`) that occurrence's own start, the answer naming each date
/// deleted beside the start of the occurrence it named, and nothing left queued.
private func expectDeleted(_ r: Run, ids: [String], dates: [String], starts: [String: Date] = [:],
                           sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.actions == [.calendarEventDelete], "expected one delete card: \(r.actions); \(r.out)", sourceLocation: sourceLocation)
    #expect(Set(r.cards.map(\.eventId)) == Set(ids) && r.cards.count == ids.count,
            "the card does not list exactly the occurrences deleted: \(r.cards.map(\.eventId))", sourceLocation: sourceLocation)
    #expect(r.cards.allSatisfy { $0.changes == [CalendarToolHelpers.occurrenceDeleteNote] },
            "a card row does not carry the occurrence line: \(r.cards.map(\.changes))", sourceLocation: sourceLocation)
    #expect(r.failureReasons.allSatisfy { $0 == nil }, "the card shows a failure: \(r.failureReasons)", sourceLocation: sourceLocation)
    #expect(!r.out.contains(updatedWord), "the answer says \"updated\": \(r.out)", sourceLocation: sourceLocation)
    for card in r.cards {
        guard let start = starts[card.eventId] else { continue }
        #expect(card.startDate == start, "the card row for \(card.eventId) shows \(card.startDate), not its occurrence's start \(start)",
                sourceLocation: sourceLocation)
    }
    for date in dates {
        #expect(answerLine(r.out, date: date)?.hasSuffix("): deleted") == true,
                "the answer does not name \(date) deleted: \(r.out)", sourceLocation: sourceLocation)
    }
    #expect(r.queued.isEmpty, "rows left: \(r.queued.map { "\($0.status) \($0.failureReason ?? "")" })", sourceLocation: sourceLocation)
}

// MARK: - Google

/// A weekly Google series at 09:00 UTC from day 0 and its instances on days 0, 7 and 14, each with
/// its own id, as `events.instances` gives them.
private enum GoogleWeekly {
    static let id = "ser-x"
    static func instanceId(_ d: String) -> String { "\(id)_\(compact(d))T090000Z" }
    static var series: [String: Any] { [
        "id": id, "summary": "Standup", "status": "confirmed",
        "start": ["dateTime": "\(day(0))T09:00:00Z", "timeZone": "UTC"],
        "end": ["dateTime": "\(day(0))T09:30:00Z", "timeZone": "UTC"],
        "recurrence": ["RRULE:FREQ=WEEKLY"],
        "attendees": [["email": "guest@example.com", "responseStatus": "accepted"]],
    ] }
    static func instance(_ d: String, at time: String = "09:00:00") -> [String: Any] { [
        "id": instanceId(d), "summary": "Standup", "status": "confirmed", "recurringEventId": id,
        "start": ["dateTime": "\(d)T\(time)Z", "timeZone": "UTC"],
        "end": ["dateTime": "\(d)T\(time.prefix(3))30:00Z", "timeZone": "UTC"],
        "originalStartTime": ["dateTime": "\(d)T09:00:00Z", "timeZone": "UTC"],
    ] }
    static var calendar: [[String: Any]] { [series, instance(day(0)), instance(day(7)), instance(day(14))] }
}

private func google(
    _ arguments: [String: JSONValue], eventId: String = GoogleWeekly.id, account: String,
    seed: [[String: Any]] = GoogleWeekly.calendar, prepare: (@Sendable (Database) throws -> Void)? = nil,
    confirm: Bool = true, beforeConfirming: (@Sendable (FakeGoogleCalendar) -> Void)? = nil
) async throws -> (calendar: FakeGoogleCalendar, run: Run) {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    let calendar = FakeGoogleCalendar(seed)
    calendar.install(on: http)
    let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
    let hook = beforeConfirming.map { hook in { @Sendable in hook(calendar) } }
    let r = try await run(arguments, eventId: eventId, account: account, provider: provider,
                          prepare: prepare, confirm: confirm, beforeConfirming: hook)
    return (calendar, r)
}

@Suite("calendar_event_edit exdates_add: Google", .serialized, .processGlobalState)
struct CalendarEditExdatesGoogleTests {

    @Test("two dates given with the series' id delete exactly those two occurrences, one delete each, guests notified, and the answer names each date deleted")
    func twoDatesDeleteThoseOccurrences() async throws {
        let dates = ["\(day(7))T09:00:00", "\(day(14))T09:00:00"]
        let ids = [GoogleWeekly.instanceId(day(7)), GoogleWeekly.instanceId(day(14))]
        let g = try await google([
            "exdates_add": .array(dates.map { .string($0) }), "timezone": .string("UTC"),
        ], account: "exdates-g-two")
        #expect(Set(g.calendar.writes) == Set(ids.map { "DELETE \($0)" }) && g.calendar.writes.count == 2,
                "writes: \(g.calendar.writes); \(g.run.out)")
        for id in ids {
            #expect(g.calendar.event(id)?["status"] as? String == "cancelled", "\(id) is still there")
        }
        #expect(g.calendar.event(GoogleWeekly.instanceId(day(0)))?["status"] as? String == "confirmed", "another occurrence was deleted")
        #expect(g.calendar.deleteSendUpdates == ["all", "all"], "guests were not notified as every delete notifies them: \(g.calendar.deleteSendUpdates)")
        // Each row shows its own occurrence's start, never the series' (day 0).
        expectDeleted(g.run, ids: ids, dates: dates, starts: [ids[0]: instant(day(7)), ids[1]: instant(day(14))])
    }

    @Test("a declined card deletes nothing: the card was shown, nothing is queued or written, and the answer says cancelled")
    func declinedCardDeletesNothing() async throws {
        let g = try await google([
            "exdates_add": .array([.string("\(day(7))T09:00:00"), .string("\(day(14))T09:00:00")]), "timezone": .string("UTC"),
        ], account: "exdates-g-declined", confirm: false)
        #expect(g.run.actions == [.calendarEventDelete] && g.run.cards.count == 2, "the card was not shown: \(g.run.actions); \(g.run.out)")
        #expect(g.run.queued.isEmpty, "rows were queued: \(g.run.queued.map(\.operationType))")
        #expect(g.calendar.writes.isEmpty, "the calendar was written: \(g.calendar.writes)")
        #expect(g.run.out.contains("cancelled"), "the answer does not say cancelled: \(g.run.out)")
        #expect(!g.run.out.contains(updatedWord) && !g.run.out.contains("deleted successfully"), "\(g.run.out)")
    }

    @Test("two dates naming one occurrence give one card row and one delete, and both dates are named deleted")
    func twoDatesNamingOneOccurrenceDeleteItOnce() async throws {
        let dates = [day(7), "\(day(7))T09:00:00"]
        let id = GoogleWeekly.instanceId(day(7))
        let g = try await google([
            "exdates_add": .array(dates.map { .string($0) }), "timezone": .string("UTC"),
        ], account: "exdates-g-same-occurrence")
        #expect(g.calendar.writes == ["DELETE \(id)"], "writes: \(g.calendar.writes); \(g.run.out)")
        expectDeleted(g.run, ids: [id], dates: dates, starts: [id: instant(day(7))])
    }

    @Test("a one-off event is refused: it has no occurrences to delete, no card, nothing queued or written")
    func oneOffEventIsRefused() async throws {
        let oneOff: [String: Any] = [
            "id": "one-off", "summary": "Lunch", "status": "confirmed",
            "start": ["dateTime": "\(day(7))T12:00:00Z", "timeZone": "UTC"],
            "end": ["dateTime": "\(day(7))T13:00:00Z", "timeZone": "UTC"],
        ]
        let g = try await google([
            "exdates_add": .array([.string("\(day(7))T12:00:00")]), "timezone": .string("UTC"),
        ], eventId: "one-off", account: "exdates-g-one-off", seed: [oneOff])
        expectRefused(g.run, writes: g.calendar.writes, naming: ["does not repeat"])
        #expect(g.calendar.event("one-off") != nil, "the event was deleted")
    }

    @Test("an occurrence's own id given with another occurrence's date deletes that other occurrence: the date is looked up against the series")
    func occurrenceIdWithAnotherDate() async throws {
        let date = "\(day(14))T09:00:00"
        let g = try await google([
            "exdates_add": .array([.string(date)]), "timezone": .string("UTC"),
        ], eventId: GoogleWeekly.instanceId(day(7)), account: "exdates-g-occurrence-id")
        #expect(g.calendar.writes == ["DELETE \(GoogleWeekly.instanceId(day(14)))"], "writes: \(g.calendar.writes); \(g.run.out)")
        expectDeleted(g.run, ids: [GoogleWeekly.instanceId(day(14))], dates: [date])
    }

    @Test("a date alone on a timed series names the one occurrence that day")
    func dateAloneNamesThatDaysOccurrence() async throws {
        let g = try await google([
            "exdates_add": .array([.string(day(7))]), "timezone": .string("UTC"),
        ], account: "exdates-g-date-only")
        #expect(g.calendar.writes == ["DELETE \(GoogleWeekly.instanceId(day(7)))"], "writes: \(g.calendar.writes); \(g.run.out)")
        expectDeleted(g.run, ids: [GoogleWeekly.instanceId(day(7))], dates: [day(7)])
        // The line names the occurrence the date resolved to, beside the date as given.
        #expect(answerLine(g.run.out, date: day(7)) == "- \(day(7)) (occurrence starting \(day(7))T09:00:00): deleted", "\(g.run.out)")
    }

    @Test("the dates are read in the call's timezone")
    func datesAreReadInTheCallsZone() async throws {
        // 09:00 UTC is 18:00 in Tokyo, the same day.
        let date = "\(day(7))T18:00:00"
        let g = try await google([
            "exdates_add": .array([.string(date)]), "timezone": .string("Asia/Tokyo"),
        ], account: "exdates-g-zone")
        #expect(g.calendar.writes == ["DELETE \(GoogleWeekly.instanceId(day(7)))"], "writes: \(g.calendar.writes); \(g.run.out)")
        expectDeleted(g.run, ids: [GoogleWeekly.instanceId(day(7))], dates: [date])
    }

    /// The second date of a call whose first names a real occurrence, and the calendar it is asked of.
    static var unresolvable: [(name: String, date: String, seed: [[String: Any]])] { [
        ("a time between occurrences", "\(day(3))T09:00:00", GoogleWeekly.calendar),
        ("an occurrence already deleted", "\(day(14))T09:00:00",
         [GoogleWeekly.series, GoogleWeekly.instance(day(0)), GoogleWeekly.instance(day(7)),
          { var e = GoogleWeekly.instance(day(14)); e["status"] = "cancelled"; return e }()]),
        ("a malformed date", "next tuesday", GoogleWeekly.calendar),
        // Day 14's occurrence moved onto day 7 at 15:00: two occurrences that day.
        ("a date with two occurrences on it", day(7),
         [GoogleWeekly.series, GoogleWeekly.instance(day(0)), GoogleWeekly.instance(day(7)),
          { var e = GoogleWeekly.instance(day(14)); e["start"] = ["dateTime": "\(day(7))T15:00:00Z", "timeZone": "UTC"]
              e["end"] = ["dateTime": "\(day(7))T15:30:00Z", "timeZone": "UTC"]; return e }()]),
    ] }
    static let unresolvableCount = 4

    @Test("one date that names no occurrence refuses the whole call before the card, with nothing queued or written",
          arguments: 0..<unresolvableCount)
    func oneUnresolvableDateRefusesTheWholeCall(index: Int) async throws {
        #expect(Self.unresolvable.count == Self.unresolvableCount)
        let bad = Self.unresolvable[index]
        let g = try await google([
            "exdates_add": .array([.string("\(day(0))T09:00:00"), .string(bad.date)]), "timezone": .string("UTC"),
        ], account: "exdates-g-refused-\(index)", seed: bad.seed)
        expectRefused(g.run, writes: g.calendar.writes, naming: [bad.date])
    }

    /// The published `calendar_event_edit` schema's properties (the backend's
    /// `calendar_event_edit-v1.5.21.json`, the same in v1.11.2), copied here so this list is
    /// independent of the code under test. A property added to the schema must be classified here.
    static let schemaProperties = [
        "add_attendees", "all_day", "calendar_id", "description", "edit_scope", "end_iso", "event_id",
        "exdates_add", "location", "recurrence", "recurrence_id", "remove_attendees", "send_invitations",
        "start_iso", "timezone", "title", "transparency",
    ]
    /// What an exdates_add call may carry (edit_scope only as "all", tested on its own below).
    /// `send_invitations` is retired (guests are always notified), so it is refused like any change.
    static let allowedWithExdates: Set<String> = ["calendar_id", "edit_scope", "event_id", "exdates_add", "timezone"]
    /// Every schema property that is a change, and one key outside the schema the edit path applies.
    static let refusedKeys = schemaProperties.filter { !allowedWithExdates.contains($0) } + ["attendees"]
    static let refusedKeyCount = 13

    /// A value of the shape each key takes.
    static func value(for key: String) -> JSONValue {
        switch key {
        case "all_day": return .bool(true)
        case "add_attendees", "attendees": return .array([.dictionary(["email": .string("new@example.com")])])
        case "remove_attendees": return .array([.string("guest@example.com")])
        case "recurrence": return .dictionary(["freq": .string("DAILY")])
        case "recurrence_id": return .string("\(day(7))T09:00:00")
        case "start_iso": return .string("\(day(7))T10:00:00")
        case "end_iso": return .string("\(day(7))T10:30:00")
        default: return .string("Team standup")
        }
    }

    @Test("exdates_add with any other argument is refused by name, telling the assistant to send the other change FIRST and exdates_add after a fresh read",
          arguments: 0..<refusedKeyCount)
    func combinedCallIsRefused(index: Int) async throws {
        #expect(Self.refusedKeys.count == Self.refusedKeyCount, "classify the schema's properties: \(Self.refusedKeys)")
        let key = Self.refusedKeys[index]
        let g = try await google([
            "exdates_add": .array([.string("\(day(7))T09:00:00")]), "timezone": .string("UTC"), key: Self.value(for: key),
        ], account: "exdates-g-combined-\(key)")
        expectRefused(g.run, writes: g.calendar.writes, naming: [key])
        expectOtherChangeFirst(g.run.out)
    }

    @Test("exdates_add with an edit_scope other than \"all\" is refused by name, the other change first")
    func scopeOtherThanAllIsRefused() async throws {
        let g = try await google([
            "exdates_add": .array([.string("\(day(7))T09:00:00")]), "timezone": .string("UTC"), "edit_scope": .string("this_only"),
        ], account: "exdates-g-combined-scope")
        expectRefused(g.run, writes: g.calendar.writes, naming: ["edit_scope"])
        expectOtherChangeFirst(g.run.out)
    }

    @Test("an unrecognised timezone refuses the call, naming the zone, before anything is read or queued")
    func unrecognisedZoneIsRefused() async throws {
        let g = try await google([
            "exdates_add": .array([.string("\(day(7))T09:00:00")]), "timezone": .string("Olympus_Mons"),
        ], account: "exdates-g-bad-zone")
        expectRefused(g.run, writes: g.calendar.writes, naming: ["Olympus_Mons", "did not delete any occurrence"])
    }

    /// The malformed shapes of exdates_add, each with a valid date beside it where it can carry one.
    static var malformed: [(name: String, value: JSONValue)] { [
        ("not a list", .string("\(day(7))T09:00:00")),
        ("a non-string entry", .array([.string("\(day(7))T09:00:00"), .int(42)])),
        ("a blank entry", .array([.string("\(day(7))T09:00:00"), .string("   ")])),
    ] }
    static let malformedCount = 3

    @Test("a malformed exdates_add refuses the whole call: nothing queued or written, the valid date beside it not deleted",
          arguments: 0..<malformedCount)
    func malformedDatesRefuseTheWholeCall(index: Int) async throws {
        #expect(Self.malformed.count == Self.malformedCount)
        let bad = Self.malformed[index]
        let g = try await google([
            "exdates_add": bad.value, "timezone": .string("UTC"),
        ], account: "exdates-g-malformed-\(index)")
        expectRefused(g.run, writes: g.calendar.writes, naming: ["exdates_add"])
        #expect(g.calendar.event(GoogleWeekly.instanceId(day(7)))?["status"] as? String == "confirmed",
                "\(bad.name): the valid date was deleted")
    }

    @Test("the deletes are queued all or none: when the second row can't be written, nothing is queued and nothing deleted")
    func deletesAreQueuedAllOrNone() async throws {
        let g = try await google([
            "exdates_add": .array([.string("\(day(7))T09:00:00"), .string("\(day(14))T09:00:00")]), "timezone": .string("UTC"),
        ], account: "exdates-g-atomic", prepare: { db in
            // The database refuses any row after the first.
            try db.execute(sql: """
                CREATE TRIGGER refuse_second_calendar_row BEFORE INSERT ON pendingCalendarOperation
                WHEN (SELECT COUNT(*) FROM pendingCalendarOperation) >= 1
                BEGIN SELECT RAISE(ABORT, 'test: a second row is refused'); END
                """)
        })
        #expect(g.run.queued.isEmpty, "rows were queued: \(g.run.queued.map(\.operationType))")
        #expect(g.calendar.writes.isEmpty, "the calendar was written: \(g.calendar.writes)")
        #expect(!g.run.out.contains(updatedWord) && !g.run.out.contains("deleted successfully"),
                "the answer claims a change: \(g.run.out)")
    }

    @Test("an occurrence another client deleted after the card is named as not deleted with its reason, on the card and in the answer; the other is deleted")
    func failureAfterTheCardIsNamed() async throws {
        let kept = "\(day(7))T09:00:00", gone = "\(day(14))T09:00:00"
        let g = try await google([
            "exdates_add": .array([.string(kept), .string(gone)]), "timezone": .string("UTC"),
        ], account: "exdates-g-partial", beforeConfirming: { calendar in
            calendar.remove(GoogleWeekly.instanceId(day(14)))
        })
        #expect(g.calendar.writes == ["DELETE \(GoogleWeekly.instanceId(day(7)))"], "writes: \(g.calendar.writes)")
        #expect(answerLine(g.run.out, date: kept)?.hasSuffix("): deleted") == true, "\(g.run.out)")
        #expect(answerLine(g.run.out, date: gone)?.contains("): NOT deleted") == true, "\(g.run.out)")
        #expect(!g.run.out.contains("deleted successfully") && !g.run.out.contains(updatedWord), "\(g.run.out)")
        #expect(g.run.failureReasons.count == 1 && g.run.failureReasons.first??.contains(gone) == true,
                "the card does not name the date that failed: \(g.run.failureReasons)")
    }
}

// MARK: - Outlook

/// Graph's `ser-1` weekly series (`GraphFixture`), its first occurrence and the one a week later,
/// each with its own id, `seriesMasterId` and `originalStart`, rendered for the device as Graph
/// renders them (the scope tests' `GraphSeries`).
private enum GraphWeekly {
    static let first = "ser-1-occ-1"
    static let later = "ser-1-occ-2"
    static let eventZone = TimeZone(identifier: "America/Los_Angeles")!

    static func onDevice(_ event: [String: Any], start: Date) -> [String: Any] {
        let zone = TimeZone.current.identifier
        var e = event
        e["start"] = ["dateTime": GraphFixture.wall(start, in: zone) + ".0000000", "timeZone": zone]
        e["end"] = ["dateTime": GraphFixture.wall(start.addingTimeInterval(1_800), in: zone) + ".0000000", "timeZone": zone]
        return e
    }

    static func occurrence(id: String, at start: Date) -> [String: Any] {
        var e = onDevice(GraphFixture.event(id: id, start: start, seriesMasterId: "ser-1"), start: start)
        e["originalStart"] = start.iso8601String(timeZone: eventZone)
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

private func outlook(_ arguments: [String: JSONValue], eventId: String = "ser-1", account: String,
                     graph: FakeGraphCalendar = GraphWeekly.calendar())
    async throws -> (calendar: FakeGraphCalendar, run: Run) {
    let http = FakeHTTP.Scenario()
    defer { http.close() }
    graph.install(on: http)
    let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                            session: http.session)
    let r = try await run(arguments, eventId: eventId, account: account, provider: provider, accountProvider: .outlook)
    return (graph, r)
}

@Suite("calendar_event_edit exdates_add: Outlook", .serialized, .processGlobalState)
struct CalendarEditExdatesOutlookTests {

    @Test("two dates given with the series' id delete exactly those two occurrences, and the answer names each date deleted")
    func twoDatesDeleteThoseOccurrences() async throws {
        let dates = [GraphFixture.naive(GraphFixture.start), GraphFixture.naive(GraphFixture.occurrenceStart)]
        let o = try await outlook([
            "exdates_add": .array(dates.map { .string($0) }), "timezone": .string("UTC"),
        ], account: "exdates-o-two")
        #expect(Set(o.calendar.deleted) == [GraphWeekly.first, GraphWeekly.later] && o.calendar.deleted.count == 2,
                "deleted: \(o.calendar.deleted); \(o.run.out)")
        #expect(o.calendar.event("ser-1") != nil, "the series was deleted")
        #expect(o.calendar.patches("ser-1").isEmpty, "the series was written: \(o.calendar.patches("ser-1"))")
        expectDeleted(o.run, ids: [GraphWeekly.first, GraphWeekly.later], dates: dates,
                      starts: [GraphWeekly.first: GraphFixture.start, GraphWeekly.later: GraphFixture.occurrenceStart])
    }

    @Test("an all-day series' date names that date's occurrence and deletes it alone, whatever zone the call names (#647's date lookup)")
    func allDayDateDeletesThatDatesOccurrence() async throws {
        // #647's series and zones (`GraphAllDaySeries`): the series' zone east of the device's, the
        // call's zone the device's or one west of it, so every row crosses a date boundary on any
        // host. The instant-based lookup named the next day's occurrence here, now a delete.
        #expect(GraphAllDaySeries.crossesOnThisHost, "device offset \(GraphAllDaySeries.deviceHours)h")
        let named = GraphAllDaySeries.occurrence(GraphAllDaySeries.named)
        let shownStart = GraphAllDaySeries.names[1]
        for (index, row) in GraphAllDaySeries.rows.enumerated() {
            for (form, date) in GraphAllDaySeries.names.enumerated() {
                let label = GraphAllDaySeries.label(row.daily, row.zone, date)
                let o = try await outlook([
                    "exdates_add": .array([.string(date)]), "timezone": .string(row.zone),
                ], eventId: GraphAllDaySeries.id, account: "exdates-o-allday-\(index)-\(form)",
                   graph: GraphAllDaySeries.calendar(daily: row.daily))
                #expect(o.calendar.deleted == [named], "\(label): deleted \(o.calendar.deleted); \(o.run.out)")
                for offset in GraphAllDaySeries.offsets(daily: row.daily) where offset != GraphAllDaySeries.named {
                    #expect(o.calendar.event(GraphAllDaySeries.occurrence(offset)) != nil, "\(label): another occurrence was deleted")
                }
                #expect(o.calendar.event(GraphAllDaySeries.id) != nil && o.calendar.patches(GraphAllDaySeries.id).isEmpty,
                        "\(label): the series was written")
                expectDeleted(o.run, ids: [named], dates: [date])
                #expect(answerLine(o.run.out, date: date) == "- \(date) (occurrence starting \(shownStart)): deleted",
                        "\(label): \(o.run.out)")
            }
        }
    }

    @Test("a one-off event is refused: it has no occurrences to delete, no card, nothing deleted")
    func oneOffEventIsRefused() async throws {
        let graph = FakeGraphCalendar([GraphWeekly.onDevice(GraphFixture.event(id: "one-off"), start: GraphFixture.start)])
        let o = try await outlook([
            "exdates_add": .array([.string(GraphFixture.naive(GraphFixture.start))]), "timezone": .string("UTC"),
        ], eventId: "one-off", account: "exdates-o-one-off", graph: graph)
        expectRefused(o.run, writes: o.calendar.deleted + o.calendar.patches("one-off").map { "\($0)" }, naming: ["does not repeat"])
        #expect(o.calendar.event("one-off") != nil, "the event was deleted")
    }

    @Test("a delete that fails for a passing reason is reported queued, never deleted or failed")
    func transientFailureIsReportedQueued() async throws {
        let graph = GraphWeekly.calendar()
        graph.failNext("DELETE", with: 500)
        let date = GraphFixture.naive(GraphFixture.occurrenceStart)
        let o = try await outlook([
            "exdates_add": .array([.string(date)]), "timezone": .string("UTC"),
        ], account: "exdates-o-transient", graph: graph)
        #expect(answerLine(o.run.out, date: date)?.hasSuffix("): queued, will be deleted shortly") == true, "\(o.run.out)")
        #expect(o.run.out.hasPrefix("Occurrence deletion queued successfully."), "\(o.run.out)")
        #expect(!o.run.out.contains("deleted successfully") && !o.run.out.contains("NOT deleted") && !o.run.out.contains(updatedWord),
                "\(o.run.out)")
        #expect(o.run.failureReasons.allSatisfy { $0 == nil }, "the card shows a failure: \(o.run.failureReasons)")
    }

    @Test("deletes refused for a full mailbox are each reported queued and waiting for space, also the ones queued behind the first (#865)")
    func fullMailboxIsReportedForEveryOccurrence() async throws {
        let graph = GraphWeekly.calendar()
        graph.refuseWrites(["DELETE"], code: FakeGraphCalendar.mailboxFullCode)
        let dates = [GraphFixture.naive(GraphFixture.start), GraphFixture.naive(GraphFixture.occurrenceStart)]
        let o = try await outlook([
            "exdates_add": .array(dates.map { .string($0) }), "timezone": .string("UTC"),
        ], account: "exdates-o-mailbox-full", graph: graph)
        // The drain stops the account at the first refused delete; the second waits behind it unattempted.
        #expect(o.run.queued.count == 2 && o.run.queued.filter { $0.waitReason == .mailboxFull }.count == 1,
                "fixture check: \(o.run.queued.map { "\($0.status) \(String(describing: $0.waitReason))" }); \(o.run.out)")
        for date in dates {
            #expect(answerLine(o.run.out, date: date)?.hasSuffix("): queued, will be deleted shortly; waiting because the Outlook mailbox is full") == true,
                    "\(date) does not say it waits for space: \(o.run.out)")
        }
        #expect(o.run.out.hasPrefix("Occurrence deletion queued successfully."), "\(o.run.out)")
        #expect(o.calendar.deleted.isEmpty, "a refused delete landed: \(o.calendar.deleted)")
        #expect(o.run.failureReasons.allSatisfy { $0 == nil }, "the card shows a failure: \(o.run.failureReasons)")
    }

    @Test("an occurrence's own id given with another occurrence's date deletes that other occurrence")
    func occurrenceIdWithAnotherDate() async throws {
        let date = GraphFixture.naive(GraphFixture.occurrenceStart)
        let o = try await outlook([
            "exdates_add": .array([.string(date)]), "timezone": .string("UTC"),
        ], eventId: GraphWeekly.first, account: "exdates-o-occurrence-id")
        #expect(o.calendar.deleted == [GraphWeekly.later], "deleted: \(o.calendar.deleted); \(o.run.out)")
        expectDeleted(o.run, ids: [GraphWeekly.later], dates: [date])
    }

    @Test("one date that names no occurrence refuses the whole call before the card, with nothing deleted")
    func oneUnresolvableDateRefusesTheWholeCall() async throws {
        let between = GraphFixture.naive(GraphFixture.start.addingTimeInterval(3 * 86_400))
        let o = try await outlook([
            "exdates_add": .array([.string(GraphFixture.naive(GraphFixture.start)), .string(between)]), "timezone": .string("UTC"),
        ], account: "exdates-o-refused")
        expectRefused(o.run, writes: o.calendar.deleted + o.calendar.patches("ser-1").map { "\($0)" }, naming: [between])
    }

    @Test("exdates_add with a new title is refused by name")
    func combinedCallIsRefused() async throws {
        let o = try await outlook([
            "exdates_add": .array([.string(GraphFixture.naive(GraphFixture.occurrenceStart))]), "timezone": .string("UTC"),
            "title": .string("Team planning"),
        ], account: "exdates-o-combined")
        expectRefused(o.run, writes: o.calendar.deleted + o.calendar.patches("ser-1").map { "\($0)" }, naming: ["title"])
        expectOtherChangeFirst(o.run.out)
    }
}

// MARK: - A lookup that names the series

@Suite("calendar_event_edit exdates_add: a lookup answering with the series' own id", .serialized, .processGlobalState)
struct CalendarEditExdatesSeriesIdTests {

    @Test("an occurrence lookup that answers with the series' own id is refused before the card: a delete by that id would remove every occurrence")
    func lookupNamingTheSeriesIsRefused() async throws {
        let seriesId = "ser-stub"
        let mock = MockCalendarProvider()
        await mock.setGetEventResult(GCalEvent(
            id: seriesId, summary: "Standup", location: nil, description: nil,
            start: GCalDateTime(dateTime: "\(day(0))T09:00:00Z", date: nil, timeZone: "UTC"),
            end: GCalDateTime(dateTime: "\(day(0))T09:30:00Z", date: nil, timeZone: "UTC"),
            attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=WEEKLY"],
            transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil,
            recurringEventId: nil))
        // The lookup answers with the series' id itself, as no provider does today.
        await mock.setOccurrenceResult(GCalEvent(
            id: seriesId, summary: "Standup", location: nil, description: nil,
            start: GCalDateTime(dateTime: "\(day(7))T09:00:00Z", date: nil, timeZone: "UTC"),
            end: GCalDateTime(dateTime: "\(day(7))T09:30:00Z", date: nil, timeZone: "UTC"),
            attendees: nil, organizer: nil, recurrence: nil,
            transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil,
            recurringEventId: seriesId))
        let r = try await run([
            "exdates_add": .array([.string("\(day(7))T09:00:00")]), "timezone": .string("UTC"),
        ], eventId: seriesId, account: "exdates-stub-series-id", provider: mock)
        let deleted = await mock.deletedEvents.map(\.eventId)
        expectRefused(r, writes: deleted, naming: ["no id of its own"])
    }
}

// MARK: - CalDAV

@Suite("calendar_event_edit exdates_add: CalDAV", .serialized, .processGlobalState)
struct CalendarEditExdatesCalDAVTests {
    typealias W = OccurrenceWireFixture
    typealias H = CalDAVToolWire

    /// Runs the tool over the CalDAV harness (`CalDAVToolWire`).
    private func run(_ harness: CalDAVToolWire.Harness, eventId: String, _ arguments: [String: JSONValue]) async throws -> Run {
        let sink = KeepingSink()
        var args = arguments
        args["event_id"] = .string(CompoundEventId.make(accountId: harness.accountId, eventId: eventId))
        let out: String
        do {
            out = try await CalendarEventEditTool(context: ToolContext(db: harness.pool, translator: ChatIdTranslator.createIsolated()))
                .execute(arguments: args, invocation: ToolInvocation(uiSink: sink, sessionKey: "exdates-\(harness.accountId)"))
        } catch let error as ToolDeclinedError {
            out = error.output
        }
        await AccountManager.shared.drainCalendarQueue()
        let queued = try await harness.pool.read { try PendingCalendarOperation.fetchAll($0) }
        let (actions, cards, reasons) = await MainActor.run {
            (sink.confirmations.map(\.action), sink.confirmations.flatMap(\.calendarEvents),
             sink.confirmations.map { $0.responseState.failureReason })
        }
        return Run(out: out, actions: actions, cards: cards, failureReasons: reasons, queued: queued)
    }

    private func naive(_ fixture: W, _ week: Int) throws -> String {
        OccurrenceFixture.naive(try fixture.occurrence(week), fixture.zone)
    }

    private func exdate(_ fixture: W, _ week: Int) throws -> String {
        "EXDATE;TZID=America/New_York:\(OccurrenceFixture.wall(try fixture.occurrence(week), fixture.zone))"
    }

    @Test("two dates given with the series' id exclude exactly those occurrences through the one-occurrence delete: two EXDATEs, every other line kept, no DELETE")
    func twoDatesExcludeThoseOccurrences() async throws {
        let harness = try await H.makeHarness(accountId: "exdates-caldav-two")
        defer { H.tearDown(harness) }
        let fixture = harness.fixture
        let dates = [try naive(fixture, 2), try naive(fixture, 3)]
        let r = try await run(harness, eventId: W.seriesPath, [
            "exdates_add": .array(dates.map { .string($0) }), "timezone": .string("America/New_York"),
        ])

        #expect(H.deletes(harness.http).isEmpty, "a DELETE reached the server: \(H.deletes(harness.http))")
        #expect(harness.store.recordedPuts().count == 2, "expected one write per occurrence: \(harness.store.recordedPuts().map(\.path))")
        let stored = try #require(harness.store.storedICS(path: W.seriesPath), "the series is no longer on the server")
        let exdates = [try exdate(fixture, 2), try exdate(fixture, 3)]
        let lines = stored.components(separatedBy: "\r\n")
        for line in exdates {
            #expect(lines.filter { $0 == line }.count == 1, "the series does not exclude \(line): \(stored)")
        }
        #expect(lines.filter { !exdates.contains($0) }.joined(separator: "\r\n") == fixture.ics,
                "the rest of the series changed on the wire: \(stored)")
        expectDeleted(r, ids: [try fixture.occurrenceId(2), try fixture.occurrenceId(3)], dates: dates,
                      starts: [try fixture.occurrenceId(2): try fixture.occurrence(2), try fixture.occurrenceId(3): try fixture.occurrence(3)])
    }

    @Test("an occurrence's own id given with another occurrence's date excludes that other occurrence")
    func occurrenceIdWithAnotherDate() async throws {
        let harness = try await H.makeHarness(accountId: "exdates-caldav-occurrence-id")
        defer { H.tearDown(harness) }
        let fixture = harness.fixture
        let date = try naive(fixture, 3)
        let r = try await run(harness, eventId: try fixture.occurrenceId(2), [
            "exdates_add": .array([.string(date)]), "timezone": .string("America/New_York"),
        ])
        let stored = try #require(harness.store.storedICS(path: W.seriesPath))
        let lines = stored.components(separatedBy: "\r\n")
        #expect(lines.filter { $0.hasPrefix("EXDATE") } == [try exdate(fixture, 3)], "excluded: \(stored)")
        expectDeleted(r, ids: [try fixture.occurrenceId(3)], dates: [date])
    }

    @Test("one date that names no occurrence refuses the whole call before the card, with nothing PUT")
    func oneUnresolvableDateRefusesTheWholeCall() async throws {
        let harness = try await H.makeHarness(accountId: "exdates-caldav-refused")
        defer { H.tearDown(harness) }
        let fixture = harness.fixture
        let between = OccurrenceFixture.naive(try fixture.occurrence(2).addingTimeInterval(3 * 86_400), fixture.zone)
        let r = try await run(harness, eventId: W.seriesPath, [
            "exdates_add": .array([.string(try naive(fixture, 2)), .string(between)]), "timezone": .string("America/New_York"),
        ])
        expectRefused(r, writes: harness.store.recordedPuts().map(\.path) + H.deletes(harness.http), naming: [between])
        #expect(harness.store.storedICS(path: W.seriesPath) == fixture.ics, "the series changed")
    }

    @Test("a resource holding only changed occurrences is refused before the card, nothing PUT or deleted, saying plainly why and never steering to a one-occurrence edit")
    func changedOnlyResourceIsRefused() async throws {
        let harness = try await H.makeHarness(accountId: "exdates-caldav-changed-only")
        defer { H.tearDown(harness) }
        let fixture = harness.fixture
        let slot = try fixture.occurrence(2)
        let start = slot.addingTimeInterval(60 * 60)
        let wall = { (date: Date) in OccurrenceFixture.wall(date, fixture.zone) }
        let path = "/cal/invite.ics"
        let ics = OccurrenceFixture.ics([[
            "UID:invite-1",
            "DTSTAMP:\(OccurrenceFixture.utcValue(fixture.first))",
            "RECURRENCE-ID;TZID=America/New_York:\(wall(slot))",
            "DTSTART;TZID=America/New_York:\(wall(start))",
            "DTEND;TZID=America/New_York:\(wall(start.addingTimeInterval(30 * 60)))",
            "SUMMARY:Planning",
            "ORGANIZER:mailto:organizer@example.com",
            "ATTENDEE:mailto:user@example.com",
        ].joined(separator: "\n")])
        harness.store.seed(path: path, ics: ics)
        let occurrenceId = CalDAVOccurrences.OccurrenceId.make(seriesHref: path, key: OccurrenceFixture.utcValue(slot))

        let r = try await run(harness, eventId: occurrenceId, [
            "exdates_add": .array([.string(OccurrenceFixture.naive(start, fixture.zone))]), "timezone": .string("America/New_York"),
        ])
        expectRefused(r, writes: harness.store.recordedPuts().map(\.path) + H.deletes(harness.http),
                      naming: ["only changed occurrences of this repeating event are on the server", "calendar app"])
        // The edit path's refusal advises a one-occurrence edit, which no exdates call can use.
        #expect(!r.out.contains("this_only") && !r.out.contains("edit_scope") && !r.out.contains("recurrence_id"),
                "the answer steers to a one-occurrence edit: \(r.out)")
        #expect(harness.store.storedICS(path: path) == ics, "the resource is not on the server as it was")
    }
}
