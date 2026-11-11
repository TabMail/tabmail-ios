/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

// MARK: - Every edit scope, by either id, from the edit tool down to the wire (ADR-IOS-108)
//
// INVARIANT (system property): on CalDAV, a `calendar_event_edit` the user confirmed either
// writes what its card showed, or is refused with nothing sent after the user confirmed.
// "What the card showed" is the event or occurrence at the card's start and the scope the
// card names: one occurrence ("just this occurrence"), it and every later one ("this and
// all future occurrences"), or, with no scope line, the whole event. After the write, a
// listing must show the edit on exactly that slice, every occurrence where it was, and the
// occurrence the card showed among the changed ones.
//
// It is checked for every scope the tool takes (all, none given, none given with a
// recurrence_id, this_only, this_and_following) and both ids a listing hands out (the
// series' own, one occurrence's). An edit of the whole event given ONE occurrence's id
// changes the whole series, and its card shows the series (#560).
//
// The same matrix runs on a MOVED occurrence (week 2's moved past weeks 3 and 4 into week 5),
// named by where the listing shows it. There the card's "this and all future occurrences"
// would start at the occurrence's place in the series (week 2), a wider write than the card
// shows, so that split is not supported (#563): its card, then an error at the write, with
// nothing written, by either id; this_only changes exactly the moved occurrence where it is.
// A change of the series' FIRST occurrence and the following ones, moved from its place, is an
// edit of the whole series and is written.
//
// The chain is a user's: the model passes the number the chat translator gave it, the user
// confirms the card, and the queued edit drains through the real `CalDAVProvider` onto a
// fake CalDAV server (`CalDAVToolWire`).

@Suite("calendar_event_edit on CalDAV: the write matches the card, or nothing is sent", .serialized, .processGlobalState)
struct CalDAVOccurrenceEditToolToWireTests {
    typealias W = OccurrenceWireFixture
    typealias H = CalDAVToolWire

    private static let newTitle = "Retitled"

    /// How much of the series a card says the edit changes.
    private enum Extent {
        case whole, one, fromHereOn

        /// Read off the card's scope line, as the user reads it.
        init(changes: [String]) {
            if changes.contains(where: { $0.hasPrefix("scope → just this occurrence") }) {
                self = .one
            } else if changes.contains(where: { $0.hasPrefix("scope → this and all future occurrences") }) {
                self = .fromHereOn
            } else {
                self = .whole
            }
        }

        func covers(_ start: Date, cardStart: Date) -> Bool {
            switch self {
            case .whole: return true
            case .one: return start == cardStart
            case .fromHereOn: return start >= cardStart
            }
        }
    }

    struct Case {
        let label: String
        let occurrenceId: Bool
        let editScope: String?
        let givesRecurrenceId: Bool
        let refused: Bool
        /// Not supported (a split at a moved occurrence, #563): the split's card, then an error at
        /// the write, with nothing written and no write left queued.
        var errorNothingWritten = false
    }

    /// Every scope the tool takes, by each id kind. None is refused: the whole event by one
    /// occurrence's id is an edit of the series (#560).
    static let cases: [Case] = [false, true].flatMap { byOccurrence in
        [
            Case(label: "edit_scope all", occurrenceId: byOccurrence, editScope: "all", givesRecurrenceId: false, refused: false),
            Case(label: "no edit_scope", occurrenceId: byOccurrence, editScope: nil, givesRecurrenceId: false, refused: false),
            Case(label: "no edit_scope, a recurrence_id", occurrenceId: byOccurrence, editScope: nil, givesRecurrenceId: true, refused: false),
            Case(label: "edit_scope this_only", occurrenceId: byOccurrence, editScope: "this_only", givesRecurrenceId: true, refused: false),
            Case(label: "edit_scope this_and_following", occurrenceId: byOccurrence, editScope: "this_and_following", givesRecurrenceId: true, refused: false),
        ]
    }

    /// In `movedFixture`, the occurrence that was moved, and the week it was moved into.
    private static let movedFromWeek = 2
    private static let movedToWeek = 5

    static func movedFixture() throws -> W {
        try W.makeMoved(week: movedFromWeek, toWeek: movedToWeek)
    }

    /// Every scope by each id kind, on the moved occurrence. The split's card, then an error at the
    /// write with nothing written: a split at it by either id.
    static let movedCases: [Case] = [false, true].flatMap { byOccurrence in
        [
            Case(label: "edit_scope all", occurrenceId: byOccurrence, editScope: "all", givesRecurrenceId: false, refused: false),
            Case(label: "no edit_scope", occurrenceId: byOccurrence, editScope: nil, givesRecurrenceId: false, refused: false),
            Case(label: "no edit_scope, a recurrence_id", occurrenceId: byOccurrence, editScope: nil, givesRecurrenceId: true, refused: false),
            Case(label: "edit_scope this_only", occurrenceId: byOccurrence, editScope: "this_only", givesRecurrenceId: true, refused: false),
            Case(label: "edit_scope this_and_following", occurrenceId: byOccurrence, editScope: "this_and_following", givesRecurrenceId: true, refused: true, errorNothingWritten: true),
        ]
    }

    /// Every occurrence from the series' first through week 5, by start, from every resource
    /// in the calendar (a split's new part included).
    private static func listing(_ fixture: W, http: FakeHTTP.Scenario) async throws -> [GCalEvent] {
        let rows = try await W.makeProvider(http).listEvents(
            calendarId: W.calendarId, timeMin: fixture.first.addingTimeInterval(-60),
            timeMax: try fixture.occurrence(6).addingTimeInterval(-60),
            query: nil, singleEvents: true, maxResults: 250, orderBy: "startTime")
        return rows.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    @Test("for every scope and both id kinds, the write matches the card or the edit is refused with nothing sent after the user confirmed", arguments: cases.indices)
    func writeMatchesTheCardOrNothingIsSent(_ index: Int) async throws {
        let entry = Self.cases[index]
        try await Self.check(entry, session: "caldav-edit-scope-\(index)", fixture: try W.make(), week: 2) { try $0.occurrence(2) }
    }

    @Test("on a moved occurrence, for every scope and both id kinds, the write matches the card or the edit is refused with nothing written", arguments: movedCases.indices)
    func movedOccurrenceWriteMatchesTheCardOrNothingIsWritten(_ index: Int) async throws {
        let entry = Self.movedCases[index]
        try await Self.check(entry, session: "caldav-edit-moved-\(index)", fixture: try Self.movedFixture(), week: Self.movedFromWeek) {
            try $0.movedStart(toWeek: Self.movedToWeek)
        }
    }

    /// Runs `entry` against `fixture` on the occurrence whose place in the series is week
    /// `week` and which a listing shows at `shownAt`.
    private static func check(
        _ entry: Case, session: String, fixture given: W, week: Int, shownAt: (W) throws -> Date
    ) async throws {
        let label = "\(entry.occurrenceId ? "occurrence id" : "series id"), \(entry.label)"
        let harness = try await H.makeHarness(accountId: session, fixture: given)
        defer { H.tearDown(harness) }
        let fixture = harness.fixture
        let eventId = entry.occurrenceId ? try fixture.occurrenceId(week) : W.seriesPath
        let before = try await Self.listing(fixture, http: harness.http)
        let shown = try shownAt(fixture)

        // The model is handed a number for the id a listing gave it.
        let translator = ChatIdTranslator.createIsolated()
        let compound = CompoundEventId.make(accountId: harness.accountId, eventId: eventId)
        let forModel = await translator.processToolOutputForLLM("event_id: \(compound)")
        let numericId = try #require(H.eventIds(in: forModel).first.flatMap { Int($0) }, "\(label): no numeric event id for the model: \(forModel)")
        await H.recordCalendar(of: eventId, accountId: harness.accountId, translator: translator)

        var arguments: [String: JSONValue] = [
            "event_id": .string(String(numericId)),
            "title": .string(Self.newTitle),
            "timezone": .string(fixture.zone.identifier),
        ]
        if let scope = entry.editScope { arguments["edit_scope"] = .string(scope) }
        if entry.givesRecurrenceId {
            arguments["recurrence_id"] = .string(OccurrenceFixture.naive(shown, fixture.zone))
        }

        let sink = H.ConfirmingSink(http: harness.http)
        let output = try await CalendarEventEditTool(context: ToolContext(db: harness.pool, translator: translator)).execute(
            arguments: arguments, invocation: ToolInvocation(uiSink: sink, sessionKey: session))
        await AccountManager.shared.drainCalendarQueue()

        let (cards, confirmedAt) = await MainActor.run {
            (sink.confirmations.flatMap(\.calendarEvents), sink.requestsAtConfirmation)
        }
        if entry.errorNothingWritten {
            #expect(cards.count == 1 && cards.first.map { Extent(changes: $0.changes) } == .fromHereOn,
                    "\(label): the split's card was not shown: \(cards.map(\.changes)): \(output)")
            #expect(harness.store.recordedPuts().isEmpty, "\(label): written: \(harness.store.recordedPuts().map(\.path))")
            #expect(H.deletes(harness.http).isEmpty, "\(label): deleted: \(H.deletes(harness.http))")
            #expect(harness.store.storedICS(path: W.seriesPath) == fixture.ics, "\(label): the series is not on the server as it was")
            let ops = try await harness.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
            #expect(ops.count == 1 && ops.allSatisfy { $0.status == PendingStatus.failed.rawValue },
                    "\(label): the split did not end failed, or a write is still queued: \(ops.map { $0.status })")
            return
        }
        #expect(cards.count == 1 && confirmedAt.count == 1, "\(label): expected one confirmed card, got \(cards.count): \(output)")
        guard cards.count == 1, confirmedAt.count == 1 else { return }
        let card = cards[0]
        let sentAfterConfirming = harness.http.recordedCalls().count - confirmedAt[0]
        let refused = output.contains("NOT changed")
        #expect(refused == entry.refused, "\(label): \(entry.refused ? "was not refused" : "was refused"): \(output)")

        if refused {
            #expect(sentAfterConfirming == 0, "\(label): a refused edit sent \(sentAfterConfirming) request(s) after the user confirmed: \(harness.http.servedCallSequence())")
        }
        if refused {
            #expect(harness.store.recordedPuts().isEmpty, "\(label): a refused edit wrote: \(harness.store.recordedPuts().map(\.path))")
            #expect(H.deletes(harness.http).isEmpty, "\(label): a refused edit deleted: \(H.deletes(harness.http))")
            #expect(harness.store.storedICS(path: W.seriesPath) == fixture.ics, "\(label): the series is not on the server as it was")
            let ops = try await harness.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
            #expect(ops.count == 1 && ops.allSatisfy { $0.status == PendingStatus.failed.rawValue },
                    "\(label): the refused edit did not end failed: \(ops.map { $0.status })")
            return
        }

        // Written: the listing shows the edit on exactly the slice the card named.
        let extent = Extent(changes: card.changes)
        let after = try await Self.listing(fixture, http: harness.http)
        #expect(after.compactMap(\.startDate) == before.compactMap(\.startDate),
                "\(label): the edit moved, added or removed an occurrence: \(after.map { $0.start?.dateTime ?? "nil" })")
        #expect(after.contains { $0.startDate == card.startDate },
                "\(label): no occurrence is listed at the card's start, \(card.startDate)")
        for row in after {
            guard let start = row.startDate else { continue }
            // What an edit of the whole event does to an occurrence moved on its own is not
            // this property's, so a moved occurrence is not checked for it.
            if extent == .whole, start == shown, start != (try fixture.occurrence(week)) { continue }
            let changed = extent.covers(start, cardStart: card.startDate)
            #expect(row.summary == (changed ? Self.newTitle : "Standup"),
                    "\(label): the occurrence at \(row.start?.dateTime ?? "nil") \(changed ? "does not show" : "shows") the edit; the card named \(extent) from \(card.startDate)")
        }
    }

    // MARK: A change of the moved first occurrence and the following ones

    @Test("a change of the series' first occurrence and the following ones, moved from its place, is an edit of the whole series and is written, by either id")
    func followingAtAMovedFirstOccurrenceEditsTheSeries() async throws {
        // The first occurrence, moved on its own to the next day at 10:00, named where the listing
        // shows it. From the first occurrence on is every occurrence: no split is written, so its
        // move does not matter.
        for byOccurrence in [false, true] {
            let session = "caldav-edit-moved-first-\(byOccurrence)"
            let label = byOccurrence ? "occurrence id" : "series id"
            let harness = try await H.makeHarness(accountId: session, fixture: try W.makeMoved(week: 0, toWeek: 0))
            defer { H.tearDown(harness) }
            let fixture = harness.fixture
            let shown = try fixture.movedStart(toWeek: 0)
            let eventId = byOccurrence ? try fixture.occurrenceId(0) : W.seriesPath
            let before = try await Self.listing(fixture, http: harness.http)

            let translator = ChatIdTranslator.createIsolated()
            let compound = CompoundEventId.make(accountId: harness.accountId, eventId: eventId)
            let forModel = await translator.processToolOutputForLLM("event_id: \(compound)")
            let numericId = try #require(H.eventIds(in: forModel).first.flatMap { Int($0) }, "\(label): no numeric event id for the model: \(forModel)")
            await H.recordCalendar(of: eventId, accountId: harness.accountId, translator: translator)
            let arguments: [String: JSONValue] = [
                "event_id": .string(String(numericId)),
                "edit_scope": .string("this_and_following"),
                "recurrence_id": .string(OccurrenceFixture.naive(shown, fixture.zone)),
                "title": .string(Self.newTitle),
                "timezone": .string(fixture.zone.identifier),
            ]
            let sink = H.ConfirmingSink(http: harness.http)
            let output = try await CalendarEventEditTool(context: ToolContext(db: harness.pool, translator: translator)).execute(
                arguments: arguments, invocation: ToolInvocation(uiSink: sink, sessionKey: session))
            await AccountManager.shared.drainCalendarQueue()

            let cards = await MainActor.run { sink.confirmations.flatMap(\.calendarEvents) }
            #expect(cards.count == 1 && cards.first.map { Extent(changes: $0.changes) } == .whole,
                    "\(label): not shown as the whole series: \(cards.map(\.changes)): \(output)")
            #expect(!output.contains("NOT changed") && output.contains("edit_scope: all"), "\(label): \(output)")
            #expect(harness.store.recordedPuts().map(\.path) == [W.seriesPath],
                    "\(label): not one write of the series: \(harness.store.recordedPuts().map(\.path))")
            #expect(H.deletes(harness.http).isEmpty, "\(label): deleted: \(H.deletes(harness.http))")
            let ops = try await harness.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
            #expect(ops.isEmpty, "\(label): the edit did not drain: \(ops.map { "\($0.status) \($0.failureReason ?? "")" })")

            // Every occurrence is where it was, and the series' own (all but the moved one, which an
            // edit of the whole event leaves as its own) shows the edit.
            let after = try await Self.listing(fixture, http: harness.http)
            #expect(after.compactMap(\.startDate) == before.compactMap(\.startDate),
                    "\(label): the edit moved, added or removed an occurrence: \(after.map { $0.start?.dateTime ?? "nil" })")
            for row in after where row.startDate != shown {
                #expect(row.summary == Self.newTitle, "\(label): the occurrence at \(row.start?.dateTime ?? "nil") does not show the edit")
            }
        }
    }

    // MARK: A retry after the response to a move was lost

    @Test("a this_only edit that moves an occurrence, whose response is lost, is retired as not found on its retry with nothing written again, and leaves nothing queued")
    func retryOfAMoveWhoseResponseWasLostIsRetiredAsNotFound() async throws {
        let session = "caldav-move-lost-response"
        let harness = try await H.makeHarness(accountId: session)
        defer { H.tearDown(harness) }
        let fixture = harness.fixture
        let slot = try fixture.occurrence(2)
        let newStart = slot.addingTimeInterval(2 * 60 * 60)

        // The server applies the first write to the series, then the connection drops before
        // its response arrives; every later write is answered.
        let store = harness.store
        let lostOnce = Mutex(true)
        harness.http.register(path: W.seriesPath, method: "PUT") { request in
            let response = store.handlePUT(request)
            let lose = lostOnce.withLock { lose in defer { lose = false }; return lose }
            return lose ? .transportError(.networkConnectionLost) : response
        }

        let eventId = try fixture.occurrenceId(2)
        let translator = ChatIdTranslator.createIsolated()
        let compound = CompoundEventId.make(accountId: harness.accountId, eventId: eventId)
        let forModel = await translator.processToolOutputForLLM("event_id: \(compound)")
        let numericId = try #require(H.eventIds(in: forModel).first.flatMap { Int($0) }, "no numeric event id for the model: \(forModel)")
        await H.recordCalendar(of: eventId, accountId: harness.accountId, translator: translator)

        let arguments: [String: JSONValue] = [
            "event_id": .string(String(numericId)),
            "edit_scope": .string("this_only"),
            "recurrence_id": .string(OccurrenceFixture.naive(slot, fixture.zone)),
            "start_iso": .string(OccurrenceFixture.naive(newStart, fixture.zone)),
            "end_iso": .string(OccurrenceFixture.naive(newStart.addingTimeInterval(30 * 60), fixture.zone)),
            "timezone": .string(fixture.zone.identifier),
        ]
        let sink = H.ConfirmingSink(http: harness.http)
        let output = try await CalendarEventEditTool(context: ToolContext(db: harness.pool, translator: translator)).execute(
            arguments: arguments, invocation: ToolInvocation(uiSink: sink, sessionKey: session))
        // The first attempt's response is lost, so the edit is retried by a later drain.
        await AccountManager.shared.drainCalendarQueue()
        await AccountManager.shared.drainCalendarQueue()

        let puts = harness.store.recordedPuts()
        #expect(puts.count == 1, "the retry wrote again, or the first attempt never wrote: \(puts.map(\.path)), tool said: \(output)")
        let gets = harness.http.recordedCalls().filter { $0.method == "GET" && $0.url.hasSuffix(W.seriesPath) }
        #expect(gets.count >= 2, "the edit was not retried after its response was lost: \(harness.http.servedCallSequence())")

        // The calendar holds the move the user confirmed.
        let rows = try await Self.listing(fixture, http: harness.http)
        #expect(rows.contains { $0.startDate == newStart }, "the occurrence is not listed where the edit moved it")
        #expect(!rows.contains { $0.startDate == slot }, "the occurrence is still listed where it was")

        // The retry ended as not found, and nothing is left to run or blocks the queue.
        let ops = try await harness.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        #expect(ops.count == 1, "expected the one edit operation, got \(ops.count)")
        guard ops.count == 1 else { return }
        #expect(ops[0].status == PendingStatus.failed.rawValue, "the retried edit did not end, so the queue would keep running it: \(ops[0].status)")
        #expect(ops[0].failureReason?.contains("not found") == true, "the retried edit did not end as not found: \(ops[0].failureReason ?? "nil")")
    }
}
