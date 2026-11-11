/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - A guest change reaches every item it covers, each from its own guest list (#620)
//
// INVARIANT (system property). After `calendar_event_edit` changes who attends (`add_attendees`,
// `remove_attendees`, `"*"` for everyone) with an edit scope:
// - the item the edit writes (the event, the series, or the one occurrence a `this_only` edit
//   names) holds the change applied to ITS OWN guest list from before the edit: each guest it
//   keeps exactly as that item stored them, each new guest unanswered, each removed guest gone;
// - for a whole-series edit, every changed occurrence holds the SERIES' RESULTING DIFFERENCE
//   applied to its own guest list: the guests the series lost removed, the guests it gained
//   added (new and unanswered), every other guest it holds kept as stored
//   (`GuestChangeOracle.seriesDifference`);
// - every item outside the scope holds its guests exactly as before;
// - a change that names nobody changes no guest list.
// "Item" is what a calendar stores a guest list on: a CalDAV VEVENT (the series and each changed
// occurrence of a resource), a Google or Outlook event or occurrence.
//
// The change applied to a list (the Thunderbird add-on's rule, `GuestChangeOracle.expected`):
// removals first (`"*"` drops everyone), matched by address in any letter case with any
// `mailto:` prefix stripped; every other stored guest kept as stored, one with no address too;
// then each added address not already there appended once, as the item stored them when it held
// them before (removed and added back), else new and unanswered.
//
// The difference rule is Google Calendar's, and Outlook's: the app writes a whole-series change
// to the series alone, and the server carries the difference between the series' stored list and
// the written one to each occurrence, on top of the occurrence's own guests. Measured on test
// accounts (2026-11-11), API and web alike on Google, for an added and a removed guest, for a
// series emptied of its guests (an occurrence with an extra guest of its own kept that guest) and
// for a series list written back unchanged (an occurrence that had dropped a guest on its own
// stayed without them); modelled by `FakeGoogleCalendar` and `FakeGraphCalendar`. Google is the
// reference, so CalDAV gives its changed occurrences the same difference. It differs from the
// change itself only for `"*"`, for an add of a guest the series already holds (or a remove and
// re-add of one), and for a removal of a guest the series does not hold (an occurrence's own guest
// stays) (case 3).
//
// It is checked on what the fake SERVER holds after the real calendar queue drains the edit
// (`drainEdit`), never on the request the app built. On Google and Outlook the app writes the
// item it read, once, and the server carries a series' change to its occurrences.
//
// RED BEFORE THE FIX, each for the reason its test names: the queue worked out ONE full list from
// the event it read (the series) and the CalDAV write put it on the series VEVENT alone, so the
// changed occurrences kept their old guests; and a one-occurrence edit given the series id was
// handed the series' list, which dropped the occurrence's own guests (#596). The fix carries the
// change itself to each write (`AttendeeChange`). The pins at the end held before the fix and must
// keep holding.
//
// Case 17 is an "all" edit named by one changed occurrence's own id (#560 writes it to the series):
// the series takes the change on its own guests, never the guests that occurrence holds on its own.

// MARK: - The oracle

enum GuestChangeOracle {
    /// One guest as an item stores it: the lowercased address (nil when the entry has none, or is
    /// a CalDAV line that is not `mailto:`) and the whole stored entry, compared byte for byte.
    struct Guest: Equatable, CustomStringConvertible {
        let address: String?
        let raw: String
        var description: String { raw }
    }

    struct Add: Sendable {
        let email: String
        let name: String?
    }

    /// A guest change as `calendar_event_edit` takes it.
    struct Change: Sendable {
        var adds: [Add] = []
        var removes: [String] = []
        /// `add_attendees: []` given, naming nobody.
        var namesNobody = false

        var arguments: [String: JSONValue] {
            var out: [String: JSONValue] = [:]
            if !adds.isEmpty || namesNobody {
                out["add_attendees"] = .array(adds.map { add in
                    var entry: [String: JSONValue] = ["email": .string(add.email)]
                    if let name = add.name { entry["name"] = .string(name) }
                    return .dictionary(entry)
                })
            }
            if !removes.isEmpty { out["remove_attendees"] = .array(removes.map { .string($0) }) }
            return out
        }
    }

    enum Expected {
        case kept(Guest)
        case added(String)
    }

    /// The address a change names: every `mailto:` prefix stripped, trimmed, lowercased.
    static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        while value.lowercased().hasPrefix("mailto:") {
            value = String(value.dropFirst("mailto:".count)).trimmingCharacters(in: .whitespaces)
        }
        return value.lowercased()
    }

    /// The guests an item must hold after `change`, given what it held before.
    static func expected(_ stored: [Guest], _ change: Change) -> [Expected] {
        let clearAll = change.removes.contains { $0.trimmingCharacters(in: .whitespaces) == "*" }
        let removes = Set(change.removes.map(normalized))
        var out: [Expected] = clearAll ? [] : stored.filter { guest in
            guard let address = guest.address else { return true }
            return !removes.contains(address)
        }.map(Expected.kept)
        var present = Set(out.compactMap { entry -> String? in
            if case .kept(let guest) = entry { return guest.address }
            return nil
        })
        for add in change.adds {
            let address = normalized(add.email)
            guard present.insert(address).inserted else { continue }
            if let earlier = stored.first(where: { $0.address == address }) {
                out.append(.kept(earlier))
            } else {
                out.append(.added(address))
            }
        }
        return out
    }

    /// A whole-series change as each changed occurrence takes it: the difference between the
    /// series' guests before and after `change` (`expected(seriesBefore, change)`). It removes each
    /// address the series held and no longer holds, and adds each address it holds that it did
    /// not, as `change` adds it. A guest with no address is in neither.
    static func seriesDifference(_ seriesBefore: [Guest], _ change: Change) -> Change {
        let had = Set(seriesBefore.compactMap(\.address))
        let has = Set(expected(seriesBefore, change).compactMap { entry -> String? in
            switch entry {
            case .kept(let guest): return guest.address
            case .added(let address): return address
            }
        })
        var seen = Set<String>()
        return Change(
            adds: change.adds.filter { add in
                let address = normalized(add.email)
                return has.contains(address) && !had.contains(address) && seen.insert(address).inserted
            },
            removes: seriesBefore.compactMap(\.address).filter { !has.contains($0) })
    }

    /// What is wrong with one item's guests after `change`, or nothing.
    static func problems(item: String, before: [Guest], after: [Guest], change: Change,
                         isUnanswered: (Guest) -> Bool) -> [String] {
        var remaining = after
        var out: [String] = []
        for entry in expected(before, change) {
            switch entry {
            case .kept(let guest):
                if let index = remaining.firstIndex(of: guest) {
                    remaining.remove(at: index)
                } else {
                    out.append("\(item): \(guest.address ?? "a guest with no address") was not kept as it stored them: \(guest.raw)")
                }
            case .added(let address):
                if let index = remaining.firstIndex(where: { $0.address == address }) {
                    if !isUnanswered(remaining[index]) {
                        out.append("\(item): the new guest \(address) is not unanswered: \(remaining[index].raw)")
                    }
                    remaining.remove(at: index)
                } else {
                    out.append("\(item): the new guest \(address) is missing")
                }
            }
        }
        for extra in remaining {
            out.append("\(item): holds a guest the change does not leave there: \(extra.raw)")
        }
        return out
    }

    /// What is wrong with a calendar's items after `change`: those in `inScope` must hold the
    /// change applied to their own list, every other one its guests exactly as before. For a
    /// whole-series edit, `series` names the series' item: it takes `change`, and every other item
    /// in scope (each occurrence) takes the series' difference (`seriesDifference`).
    static func problems(before: [String: [Guest]], after: [String: [Guest]], inScope: Set<String>,
                         change: Change, series: String? = nil, isUnanswered: (Guest) -> Bool) -> [String] {
        var out: [String] = []
        let occurrenceChange = series.map { seriesDifference(before[$0] ?? [], change) } ?? change
        for item in Set(before.keys).union(after.keys).sorted() {
            guard let was = before[item] else { out.append("\(item): an item that was not there before"); continue }
            guard let now = after[item] else { out.append("\(item): the item is gone"); continue }
            if inScope.contains(item) {
                out += problems(item: item, before: was, after: now, change: item == series ? change : occurrenceChange,
                                isUnanswered: isUnanswered)
            } else if was != now {
                out.append("\(item): outside the edit's scope, its guests changed from \(was) to \(now)")
            }
        }
        for item in inScope where before[item] == nil {
            out.append("\(item): the scope names an item the calendar did not hold")
        }
        return out
    }
}

// MARK: - Shared fixture

enum GuestFixture {
    static let utc = TimeZone(identifier: "UTC") ?? .current
    static let organizer = "organizer@example.com"
    static let guestA = "guest-a@example.com"
    static let guestB = "guest-b@example.com"
    static let guestC = "guest-c@example.com"
    static let guestD = "guest-d@example.com"

    /// The series' first start: 17:00 UTC, a week from today. It repeats weekly, 8 times.
    static let start: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let day = cal.startOfDay(for: Date().addingTimeInterval(7 * 86_400))
        return day.addingTimeInterval(17 * 3_600)
    }()

    static let hour: TimeInterval = 3_600

    /// Where the series puts the occurrence `week` weeks after its first.
    static func slot(_ week: Int) -> Date { start.addingTimeInterval(Double(week) * 7 * 86_400) }

    static func icsUTC(_ date: Date) -> String { format(date, "yyyyMMdd'T'HHmmss'Z'") }
    static func naiveUTC(_ date: Date) -> String { format(date, "yyyy-MM-dd'T'HH:mm:ss") }
    static func rfc3339(_ date: Date) -> String { naiveUTC(date) + "Z" }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    static func canonical(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static let addD = GuestChangeOracle.Change(adds: [.init(email: guestD, name: "Guest D")])

    /// The arguments of a one-occurrence edit of the occurrence the series puts at week `week`.
    static func thisOnly(week: Int) -> [String: JSONValue] {
        ["edit_scope": .string("this_only"), "recurrence_id": .string(naiveUTC(slot(week))),
         "timezone": .string("UTC")]
    }
}

/// The whole-series changes whose difference for a changed occurrence is not the change itself
/// (case 3), on the series every provider's suite uses: the series holds the organizer (when the
/// provider lists them as a guest), A and B; week 4 holds C as well, week 5 dropped B. The fifth,
/// a removal of C, whom the series does not hold, leaves the series as it was and is no change for
/// an occurrence: week 4 keeps its own C.
enum SeriesDifferenceShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case removeEveryone = "removes everyone with *"
    case removeEveryoneAddBack = "removes everyone with * and adds B back"
    case addHeldGuest = "adds B, whom the series holds and week 5 dropped"
    case removeAndAddBack = "removes B and adds B back, where week 5 lacks B"
    case removeOccurrenceOnlyGuest = "removes C, whom only week 4 holds"

    var testDescription: String { rawValue }

    var change: GuestChangeOracle.Change {
        let b = GuestChangeOracle.Add(email: GuestFixture.guestB, name: "Guest B")
        switch self {
        case .removeEveryone: return .init(removes: ["*"])
        case .removeEveryoneAddBack: return .init(adds: [b], removes: ["*"])
        case .addHeldGuest: return .init(adds: [b])
        case .removeAndAddBack: return .init(adds: [b], removes: [GuestFixture.guestB])
        case .removeOccurrenceOnlyGuest: return .init(removes: [GuestFixture.guestC])
        }
    }

    /// The addresses week 4 holds afterwards, worked out by hand: the guests the series lost go,
    /// its own C stays. `organizer` is the organizer's address where the provider lists them.
    func week4(organizer: [String]) -> Set<String> {
        let F = GuestFixture.self
        switch self {
        case .removeEveryone: return [F.guestC]
        case .removeEveryoneAddBack: return [F.guestB, F.guestC]
        case .addHeldGuest, .removeAndAddBack, .removeOccurrenceOnlyGuest:
            return Set(organizer + [F.guestA, F.guestB, F.guestC])
        }
    }

    /// The addresses week 5 holds afterwards: B, which the series held before and after, is not
    /// invited back.
    func week5(organizer: [String]) -> Set<String> {
        switch self {
        case .removeEveryone, .removeEveryoneAddBack: return []
        case .addHeldGuest, .removeAndAddBack, .removeOccurrenceOnlyGuest:
            return Set(organizer + [GuestFixture.guestA])
        }
    }
}

// MARK: - CalDAV

enum CalDAVGuests {
    typealias F = GuestFixture
    typealias Guest = GuestChangeOracle.Guest

    static let calendarId = "/cal/"
    static let seriesPath = "/cal/planning-guests.ics"
    static let home = URL(string: "https://caldav.example.com/cal/")!
    static let uid = "planning-guests"

    static let organizerLine = "ORGANIZER;CN=Organizer:mailto:\(F.organizer)"
    static let org = "ATTENDEE;CN=Organizer;ROLE=CHAIR;PARTSTAT=ACCEPTED:mailto:\(F.organizer)"
    static let a = "ATTENDEE;CN=Guest A;PARTSTAT=ACCEPTED:mailto:\(F.guestA)"
    /// Guest A as the moved occurrence stores them: declined for that week alone.
    static let aDeclined = "ATTENDEE;CN=Guest A;PARTSTAT=DECLINED:mailto:\(F.guestA)"
    static let b = "ATTENDEE;CN=Guest B;ROLE=OPT-PARTICIPANT;PARTSTAT=TENTATIVE;RSVP=TRUE:mailto:\(F.guestB)"
    static let c = "ATTENDEE;CN=Guest C;PARTSTAT=ACCEPTED:mailto:\(F.guestC)"
    /// An attendee whose address is not `mailto:` (a room booked by its URN).
    static let room = "ATTENDEE;CUTYPE=ROOM;CN=Room 1;PARTSTAT=ACCEPTED:urn:uuid:00000000-0000-4000-8000-000000000001"

    static let seriesKey = "series"
    static func key(week: Int) -> String { F.icsUTC(F.slot(week)) }

    static func series(_ guests: [String], organizer: Bool = true, repeats: Bool = true) -> [String] {
        var lines = ["BEGIN:VEVENT", "UID:\(uid)", "DTSTAMP:\(F.icsUTC(Date()))",
                     "DTSTART:\(F.icsUTC(F.start))", "DTEND:\(F.icsUTC(F.start.addingTimeInterval(F.hour)))"]
        if repeats { lines.append("RRULE:FREQ=WEEKLY;COUNT=8") }
        lines.append("SUMMARY:Planning")
        if organizer { lines.append(organizerLine) }
        return lines + guests + ["END:VEVENT"]
    }

    /// A changed occurrence: the one the series puts at week `week`, moved by `moved`.
    static func occurrence(week: Int, summary: String = "Planning", moved: TimeInterval = 0, _ guests: [String],
                           organizer: Bool = true) -> [String] {
        let starts = F.slot(week).addingTimeInterval(moved)
        var lines = ["BEGIN:VEVENT", "UID:\(uid)", "RECURRENCE-ID:\(key(week: week))", "DTSTAMP:\(F.icsUTC(Date()))",
                     "DTSTART:\(F.icsUTC(starts))", "DTEND:\(F.icsUTC(starts.addingTimeInterval(F.hour)))",
                     "SUMMARY:\(summary)"]
        if organizer { lines.append(organizerLine) }
        return lines + guests + ["END:VEVENT"]
    }

    static func resource(_ vevents: [[String]]) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Example//Test//EN"] + vevents.flatMap { $0 } + ["END:VCALENDAR"])
            .joined(separator: "\r\n") + "\r\n"
    }

    /// The series these tests use: guests the organizer, A and B; week 2 renamed, week 3 moved an
    /// hour later (A declined it), week 4 with C as well, week 5 without B. Weeks 0, 1, 6 and 7
    /// are as the series puts them.
    static func changedSeries() -> String {
        resource([
            series([org, a, b]),
            occurrence(week: 2, summary: "Planning review", [org, a, b]),
            occurrence(week: 3, moved: F.hour, [org, aDeclined, b]),
            occurrence(week: 4, [org, a, b, c]),
            occurrence(week: 5, [org, a]),
        ])
    }

    struct Run {
        let store: FakeCalDAVStore
        let http: FakeHTTP.Scenario
        let provider: CalDAVProvider
    }

    static func serve(_ ics: String, path: String = seriesPath, servesETags: Bool = true,
                      refusesAttendeesWithoutOrganizer: Bool = false) -> Run {
        let store = FakeCalDAVStore(servesETags: servesETags, refusesAttendeesWithoutOrganizer: refusesAttendeesWithoutOrganizer)
        store.seed(path: path, ics: ics)
        let http = FakeHTTP.Scenario()
        http.register(path: "/cal/", method: "GET") { store.handleGET($0) }
        http.register(path: "/cal/", method: "PUT") { store.handlePUT($0) }
        http.register(path: "/cal/", method: "REPORT") { store.handleREPORT($0) }
        let provider = CalDAVProvider(
            client: CalDAVClient(username: "user@example.com", password: "pw", session: http.session),
            calendarHomeURL: home, serverBaseURL: home)
        return Run(store: store, http: http, provider: provider)
    }

    static func drain(_ run: Run, eventId: String = seriesPath, _ arguments: [String: JSONValue], account: String)
        async throws -> [PendingCalendarOperation] {
        try await drainEdit(accountId: account, eventId: eventId, calendarId: calendarId,
                            arguments: arguments, provider: run.provider)
    }

    static func itemKey(_ block: [String]) -> String {
        guard let rid = VEventOracle.own(block, "RECURRENCE-ID").first, let colon = rid.firstIndex(of: ":") else {
            return seriesKey
        }
        return String(rid[rid.index(after: colon)...])
    }

    /// Each VEVENT's guests, by item.
    static func guests(_ ics: String?) -> [String: [Guest]] {
        var out: [String: [Guest]] = [:]
        for block in VEventOracle.vevents(ics ?? "") {
            out[itemKey(block)] = VEventOracle.own(block, "ATTENDEE").map { line in
                Guest(address: line.range(of: ":mailto:", options: .caseInsensitive) == nil ? nil : VEventOracle.address(line),
                      raw: line)
            }
        }
        return out
    }

    /// Each VEVENT whole, by item.
    static func vevents(_ ics: String?) -> [String: [String]] {
        Dictionary(VEventOracle.vevents(ics ?? "").map { (itemKey($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Unanswered: no `PARTSTAT` (RFC 5545's default is NEEDS-ACTION) or `PARTSTAT=NEEDS-ACTION`.
    static func isUnanswered(_ guest: Guest) -> Bool {
        let params = guest.raw.uppercased().components(separatedBy: ":").first ?? ""
        guard let range = params.range(of: ";PARTSTAT=") else { return true }
        let value = params[range.upperBound...].prefix { $0 != ";" }
        return value == "NEEDS-ACTION"
    }

    /// `wholeSeries`: the edit changes the whole series, so each changed occurrence takes the
    /// series' difference (`GuestChangeOracle.seriesDifference`).
    static func problems(before: String, after: String?, inScope: Set<String>, _ change: GuestChangeOracle.Change,
                         wholeSeries: Bool = false) -> [String] {
        GuestChangeOracle.problems(before: guests(before), after: guests(after), inScope: inScope,
                                   change: change, series: wholeSeries ? seriesKey : nil, isUnanswered: isUnanswered)
    }

    static func newPartPath(splitAtWeek week: Int) -> String {
        "/cal/\(GoogleCalendarProvider.deterministicSplitEventId(masterId: seriesPath, recurrenceId: F.naiveUTC(F.slot(week)))).ics"
    }
}

@Suite("A guest change on CalDAV reaches every VEVENT it covers, each from its own guests", .serialized, .processGlobalState)
struct CalDAVGuestChangeTests {
    typealias F = GuestFixture
    typealias C = CalDAVGuests
    typealias Change = GuestChangeOracle.Change

    /// Every VEVENT of the resource: the series and each changed occurrence.
    static let everyItem: Set<String> = [C.seriesKey, C.key(week: 2), C.key(week: 3), C.key(week: 4), C.key(week: 5)]

    private func runAll(_ change: Change, account: String) async throws -> (problems: [String], rows: [PendingCalendarOperation]) {
        let seed = C.changedSeries()
        let run = C.serve(seed)
        defer { run.http.close() }
        let rows = try await C.drain(run, change.arguments, account: account)
        return (C.problems(before: seed, after: run.store.storedICS(path: C.seriesPath), inScope: Self.everyItem, change,
                           wholeSeries: true), rows)
    }

    // RED on main: the series VEVENT alone is written; the changed occurrences keep their guests.

    @Test("1. adding a guest to the whole series adds them to the series and to every changed occurrence, each keeping its own guests")
    func addReachesEveryOccurrence() async throws {
        let r = try await runAll(F.addD, account: "guests-c-add")
        #expect(r.rows.isEmpty, "the edit did not land: \(r.rows.map { $0.failureReason ?? $0.status })")
        #expect(r.problems.isEmpty, Comment(rawValue: r.problems.joined(separator: "\n")))
    }

    @Test("2. removing a guest from the whole series removes them from the series and from every changed occurrence")
    func removeReachesEveryOccurrence() async throws {
        let r = try await runAll(Change(removes: [F.guestB]), account: "guests-c-remove")
        #expect(r.rows.isEmpty, "the edit did not land: \(r.rows.map { $0.failureReason ?? $0.status })")
        #expect(r.problems.isEmpty, Comment(rawValue: r.problems.joined(separator: "\n")))
    }

    @Test("3. a whole-series change reaches each changed occurrence as the series' difference: its own guests stay, and a guest it dropped is not invited back", arguments: SeriesDifferenceShape.allCases)
    func seriesDifferenceReachesEveryOccurrence(_ shape: SeriesDifferenceShape) async throws {
        let seed = C.changedSeries()
        let run = C.serve(seed)
        defer { run.http.close() }
        let rows = try await C.drain(run, shape.change.arguments, account: "guests-c-shape-\(shape)")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let after = run.store.storedICS(path: C.seriesPath)
        let problems = C.problems(before: seed, after: after, inScope: Self.everyItem, shape.change, wholeSeries: true)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
        let guests = C.guests(after)
        #expect(Set((guests[C.key(week: 4)] ?? []).compactMap(\.address)) == shape.week4(organizer: [F.organizer]),
                "week 4 holds \(guests[C.key(week: 4)] ?? [])")
        #expect(Set((guests[C.key(week: 5)] ?? []).compactMap(\.address)) == shape.week5(organizer: [F.organizer]),
                "week 5 holds \(guests[C.key(week: 5)] ?? [])")
    }

    @Test("6. one occurrence edited by the series id gets the guest added to its own guests (#596)")
    func oneOccurrenceBySeriesIdKeepsItsOwnGuests() async throws {
        let seed = C.changedSeries()
        let run = C.serve(seed)
        defer { run.http.close() }
        let rows = try await C.drain(run, F.addD.arguments.merging(F.thisOnly(week: 4)) { mine, _ in mine },
                                     account: "guests-c-one-by-series")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let after = run.store.storedICS(path: C.seriesPath)
        let problems = C.problems(before: seed, after: after, inScope: [C.key(week: 4)], F.addD)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
        // Every other VEVENT is exactly as it was.
        let was = C.vevents(seed), now = C.vevents(after)
        for item in Self.everyItem.subtracting([C.key(week: 4)]).sorted() {
            #expect(now[item] == was[item], "\(item) changed:\n\((now[item] ?? []).joined(separator: "\n"))")
        }
    }

    @Test("7. a split adds the guest to the new series and the changed occurrences it takes, and leaves the capped series' guests as they were")
    func splitReachesTheNewPartOnly() async throws {
        // Split at week 4, which is changed but not moved (a split at a moved occurrence is
        // refused, ADR-IOS-108): the new part takes weeks 4 and 5, the capped series keeps 2 and 3.
        let seed = C.changedSeries()
        let run = C.serve(seed)
        defer { run.http.close() }
        let rows = try await C.drain(run, F.addD.arguments.merging([
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(F.naiveUTC(F.slot(4))),
            "timezone": .string("UTC"),
        ]) { mine, _ in mine }, account: "guests-c-split")
        #expect(rows.isEmpty, "the split did not land: \(rows.map { $0.failureReason ?? $0.status })")

        let before = C.guests(seed)
        let capped = C.guests(run.store.storedICS(path: C.seriesPath))
        let kept = [C.seriesKey, C.key(week: 2), C.key(week: 3)]
        #expect(Set(capped.keys) == Set(kept), "the capped series holds \(capped.keys.sorted())")
        for item in kept {
            #expect(capped[item] == before[item], "the capped series' \(item) guests changed: \(capped[item] ?? [])")
        }

        let newPart = run.store.storedICS(path: C.newPartPath(splitAtWeek: 4))
        #expect(newPart != nil, "no new part was written; PUTs: \(run.store.recordedPuts().map(\.path))")
        let taken = [C.seriesKey, C.key(week: 4), C.key(week: 5)]
        let problems = GuestChangeOracle.problems(
            before: before.filter { taken.contains($0.key) }, after: C.guests(newPart), inScope: Set(taken),
            change: F.addD, series: C.seriesKey, isUnanswered: C.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("19. a split's new part is a whole-series write for the changed occurrences it takes: they get the new series' difference, as on Google", arguments: SeriesDifferenceShape.allCases)
    func splitGivesTakenOccurrencesTheDifference(_ shape: SeriesDifferenceShape) async throws {
        let seed = C.changedSeries()
        let run = C.serve(seed)
        defer { run.http.close() }
        let rows = try await C.drain(run, shape.change.arguments.merging([
            "edit_scope": .string("this_and_following"), "recurrence_id": .string(F.naiveUTC(F.slot(4))),
            "timezone": .string("UTC"),
        ]) { mine, _ in mine }, account: "guests-c-split-shape-\(shape)")
        #expect(rows.isEmpty, "the split did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let before = C.guests(seed)
        let newPart = C.guests(run.store.storedICS(path: C.newPartPath(splitAtWeek: 4)))
        let taken = [C.seriesKey, C.key(week: 4), C.key(week: 5)]
        let problems = GuestChangeOracle.problems(
            before: before.filter { taken.contains($0.key) }, after: newPart, inScope: Set(taken),
            change: shape.change, series: C.seriesKey, isUnanswered: C.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
        #expect(Set((newPart[C.key(week: 4)] ?? []).compactMap(\.address)) == shape.week4(organizer: [F.organizer]),
                "week 4 holds \(newPart[C.key(week: 4)] ?? [])")
        #expect(Set((newPart[C.key(week: 5)] ?? []).compactMap(\.address)) == shape.week5(organizer: [F.organizer]),
                "week 5 holds \(newPart[C.key(week: 5)] ?? [])")
    }

    @Test("8. a changed occurrence with no guests and no organizer gains the guest, on a server that refuses guests without an organizer")
    func firstGuestOnAnOccurrenceLands() async throws {
        // The organizer the occurrence then needs is the PUT's own step (`putEvent`, ADR-IOS-109,
        // pinned by `CalDAVOrganizerTests`); this asserts the guests.
        let seed = C.resource([
            C.series([]),
            C.occurrence(week: 2, summary: "Planning review", [], organizer: false),
        ])
        let run = C.serve(seed, refusesAttendeesWithoutOrganizer: true)
        defer { run.http.close() }
        let rows = try await C.drain(run, F.addD.arguments, account: "guests-c-organizer")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let after = run.store.storedICS(path: C.seriesPath)
        let problems = C.problems(before: seed, after: after, inScope: [C.seriesKey, C.key(week: 2)], F.addD, wholeSeries: true)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("17. a change of every occurrence named by one changed occurrence's id reaches every VEVENT from its own guests, and the series does not take that occurrence's own guests")
    func everyOccurrenceNamedByAnOccurrenceId() async throws {
        let seed = C.changedSeries()
        let run = C.serve(seed)
        defer { run.http.close() }
        let occurrenceId = CalDAVOccurrences.OccurrenceId.make(seriesHref: C.seriesPath, key: C.key(week: 4))
        let rows = try await C.drain(run, eventId: occurrenceId,
                                     F.addD.arguments.merging(["edit_scope": .string("all")]) { mine, _ in mine },
                                     account: "guests-c-all-by-occurrence")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let problems = C.problems(before: seed, after: run.store.storedICS(path: C.seriesPath), inScope: Self.everyItem, F.addD,
                                  wholeSeries: true)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("11. an attendee whose address is not mailto: is kept on every VEVENT through an unrelated add (#607)")
    func nonMailtoAttendeeSurvives() async throws {
        let seed = C.resource([
            C.series([C.org, C.a, C.room]),
            C.occurrence(week: 2, summary: "Planning review", [C.org, C.a, C.room]),
        ])
        let run = C.serve(seed)
        defer { run.http.close() }
        let rows = try await C.drain(run, F.addD.arguments, account: "guests-c-room")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let after = run.store.storedICS(path: C.seriesPath)
        for (item, block) in C.vevents(after).sorted(by: { $0.key < $1.key }) {
            #expect(VEventOracle.own(block, "ATTENDEE").contains(C.room),
                    "\(item) lost the room:\n\(block.joined(separator: "\n"))")
        }
        let problems = C.problems(before: seed, after: after, inScope: [C.seriesKey, C.key(week: 2)], F.addD, wholeSeries: true)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    // Green on main, and bounding the fix from the other side.

    @Test("4. a guest removed and added back in one change keeps each VEVENT's own entry for them")
    func removedAndAddedBackKeepsTheStoredEntry() async throws {
        // Every VEVENT holds B, each with its own answer, so the change leaves each list as it was.
        let bDeclined = "ATTENDEE;CN=Guest B;PARTSTAT=DECLINED:mailto:\(F.guestB)"
        let seed = C.resource([
            C.series([C.org, C.a, C.b]),
            C.occurrence(week: 2, summary: "Planning review", [C.org, C.a, bDeclined]),
        ])
        let change = Change(adds: [.init(email: F.guestB, name: "Someone else")], removes: [F.guestB])
        let run = C.serve(seed)
        defer { run.http.close() }
        let rows = try await C.drain(run, change.arguments, account: "guests-c-readd")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let after = C.vevents(run.store.storedICS(path: C.seriesPath))
        #expect(VEventOracle.own(after[C.seriesKey] ?? [], "ATTENDEE").contains(C.b), "the series' B was not kept as stored")
        #expect(VEventOracle.own(after[C.key(week: 2)] ?? [], "ATTENDEE").contains(bDeclined), "the occurrence's B was not kept as stored")
        let problems = C.problems(before: seed, after: run.store.storedICS(path: C.seriesPath),
                                  inScope: [C.seriesKey, C.key(week: 2)], change, wholeSeries: true)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("5. a change naming guests in another letter case and with mailto: matches the stored ones")
    func addressesMatchInAnyCase() async throws {
        // The occurrence does not hold B and already holds A, so it is left as it was.
        let storedB = "ATTENDEE;CN=Guest B;PARTSTAT=TENTATIVE:MAILTO:Guest-B@Example.COM"
        let seed = C.resource([
            C.series([C.org, C.a, storedB]),
            C.occurrence(week: 2, summary: "Planning review", [C.org, C.a]),
        ])
        let change = Change(adds: [.init(email: "Guest-A@EXAMPLE.com", name: "Someone else")],
                            removes: ["MAILTO:GUEST-B@example.com"])
        let run = C.serve(seed)
        defer { run.http.close() }
        let rows = try await C.drain(run, change.arguments, account: "guests-c-case")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let problems = C.problems(before: seed, after: run.store.storedICS(path: C.seriesPath),
                                  inScope: [C.seriesKey, C.key(week: 2)], change, wholeSeries: true)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("9. a guest change of the whole series is one PUT, conditional on the entity tag the server gave", arguments: [true, false])
    func onePutConditionalOnTheTag(_ servesETags: Bool) async throws {
        let run = C.serve(C.changedSeries(), servesETags: servesETags)
        defer { run.http.close() }
        let rows = try await C.drain(run, F.addD.arguments, account: "guests-c-put-\(servesETags)")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let puts = run.store.recordedPuts()
        #expect(puts.count == 1, "PUTs: \(puts.map(\.path))")
        guard puts.count == 1 else { return }
        #expect(puts[0].path == C.seriesPath)
        #expect(puts[0].ifMatch == (servesETags ? "\"seed\"" : nil), "If-Match: \(puts[0].ifMatch ?? "none")")
        #expect(puts[0].ifNoneMatch == nil, "If-None-Match: \(puts[0].ifNoneMatch ?? "none")")
    }

    @Test("10. the same guest change replayed after a lost response leaves the server as the first one did")
    func replayChangesNothing() async throws {
        let change = Change(adds: [.init(email: F.guestD, name: "Guest D")], removes: [F.guestB])
        let run = C.serve(C.changedSeries())
        defer { run.http.close() }
        let first = try await C.drain(run, change.arguments, account: "guests-c-replay-1")
        #expect(first.isEmpty, "the edit did not land: \(first.map { $0.failureReason ?? $0.status })")
        let landed = run.store.storedICS(path: C.seriesPath)
        let again = try await C.drain(run, change.arguments, account: "guests-c-replay-2")
        #expect(again.isEmpty, "the replay did not complete: \(again.map { $0.failureReason ?? $0.status })")
        #expect(run.store.storedICS(path: C.seriesPath) == landed,
                "the replay changed the server:\n\(run.store.storedICS(path: C.seriesPath) ?? "<none>")")
    }

    @Test("12. a change that names nobody changes no guest list")
    func emptyChangeWritesNoGuests() async throws {
        let seed = C.changedSeries()
        let run = C.serve(seed)
        defer { run.http.close() }
        let change = Change(namesNobody: true)
        let rows = try await C.drain(run, change.arguments.merging(["title": .string("Planning, new title")]) { mine, _ in mine },
                                     account: "guests-c-nobody")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        #expect(C.guests(run.store.storedICS(path: C.seriesPath)) == C.guests(seed),
                "a guest list changed:\n\(run.store.storedICS(path: C.seriesPath) ?? "<none>")")
    }
}

// MARK: - Google

enum GoogleGuests {
    typealias F = GuestFixture
    typealias Guest = GuestChangeOracle.Guest

    static let seriesId = "planningseries"

    static var org: [String: Any] { ["email": F.organizer, "organizer": true, "self": true, "responseStatus": "accepted"] }
    static var a: [String: Any] { ["email": F.guestA, "displayName": "Guest A", "responseStatus": "accepted"] }
    static var b: [String: Any] {
        ["email": F.guestB, "displayName": "Guest B", "optional": true, "responseStatus": "tentative", "comment": "Might be late"]
    }
    static var c: [String: Any] { ["email": F.guestC, "displayName": "Guest C", "responseStatus": "accepted"] }

    static func instanceId(week: Int) -> String { "\(seriesId)_\(F.icsUTC(F.slot(week)))" }

    static func time(_ date: Date) -> [String: Any] { ["dateTime": F.rfc3339(date), "timeZone": "UTC"] }

    static func event(id: String, starts: Date, attendees: [[String: Any]], summary: String = "Planning") -> [String: Any] {
        ["id": id, "status": "confirmed", "summary": summary,
         "organizer": ["email": F.organizer, "self": true],
         "start": time(starts), "end": time(starts.addingTimeInterval(F.hour)), "attendees": attendees]
    }

    static func series(_ attendees: [[String: Any]]) -> [String: Any] {
        var e = event(id: seriesId, starts: F.start, attendees: attendees)
        e["recurrence"] = ["RRULE:FREQ=WEEKLY;COUNT=8"]
        return e
    }

    static func occurrence(week: Int, summary: String = "Planning", moved: TimeInterval = 0,
                           _ attendees: [[String: Any]]) -> [String: Any] {
        var e = event(id: instanceId(week: week), starts: F.slot(week).addingTimeInterval(moved),
                      attendees: attendees, summary: summary)
        e["recurringEventId"] = seriesId
        e["originalStartTime"] = time(F.slot(week))
        return e
    }

    /// The series these tests use, with weeks 1 and 6 stored as Google lists them, unchanged.
    static func seed() -> [[String: Any]] {
        [
            series([org, a, b]),
            occurrence(week: 1, [org, a, b]),
            occurrence(week: 2, summary: "Planning review", [org, a, b]),
            occurrence(week: 3, moved: F.hour, [org, a, b]),
            occurrence(week: 4, [org, a, b, c]),
            occurrence(week: 5, [org, a]),
            occurrence(week: 6, [org, a, b]),
        ]
    }

    static var everyId: [String] { [seriesId] + [1, 2, 3, 4, 5, 6].map { instanceId(week: $0) } }

    static func guests(_ calendar: FakeGoogleCalendar, _ ids: [String]) -> [String: [Guest]] {
        var out: [String: [Guest]] = [:]
        for id in ids {
            guard let event = calendar.event(id) else { continue }
            out[id] = (event["attendees"] as? [[String: Any]] ?? []).map {
                Guest(address: ($0["email"] as? String)?.lowercased(), raw: F.canonical($0))
            }
        }
        return out
    }

    static func isUnanswered(_ guest: Guest) -> Bool {
        let entry = (try? JSONSerialization.jsonObject(with: Data(guest.raw.utf8))) as? [[String: Any]]
        let status = entry?.first?["responseStatus"] as? String
        return status == nil || status == "needsAction"
    }

    static func run(_ seed: [[String: Any]], eventId: String, _ arguments: [String: JSONValue], account: String)
        async throws -> (calendar: FakeGoogleCalendar, patches: [[String: Any]], rows: [PendingCalendarOperation]) {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let calendar = FakeGoogleCalendar(seed)
        calendar.install(on: http)
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        let rows = try await drainEdit(accountId: account, eventId: eventId, calendarId: "primary",
                                       arguments: arguments, provider: provider)
        let patches = http.recordedCalls().filter { $0.method == "PATCH" }.compactMap { call in
            call.body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
        return (calendar, patches, rows)
    }
}

@Suite("A guest change on Google reaches the item it covers, from its own guests", .serialized, .processGlobalState)
struct GoogleGuestChangeTests {
    typealias F = GuestFixture
    typealias G = GoogleGuests

    /// The whole-series change `change`, by `eventId`: the series must hold the change on its own
    /// guests, every occurrence (weeks 4 and 5 with guests of their own included) the series'
    /// difference on its own, and the app writes no occurrence (the server carries the series'
    /// change to them). Returns every item's guests afterwards.
    @discardableResult
    private func runAll(_ change: GuestChangeOracle.Change, eventId: String = G.seriesId, account: String) async throws
        -> [String: [GuestChangeOracle.Guest]] {
        let seed = G.seed()
        let before = G.guests(FakeGoogleCalendar(seed), G.everyId)
        let arguments = change.arguments.merging(["edit_scope": .string("all")]) { mine, _ in mine }
        let r = try await G.run(seed, eventId: eventId, arguments, account: account)
        #expect(r.rows.isEmpty, "the edit did not land: \(r.rows.map { $0.failureReason ?? $0.status })")
        let occurrenceWrites = r.calendar.writes.filter { $0 != "PATCH \(G.seriesId)" }
        #expect(occurrenceWrites.isEmpty, "the app wrote an occurrence: \(r.calendar.writes)")
        let after = G.guests(r.calendar, G.everyId)
        let problems = GuestChangeOracle.problems(
            before: before, after: after, inScope: Set(G.everyId),
            change: change, series: G.seriesId, isUnanswered: G.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
        return after
    }

    @Test("13. adding a guest to the whole series reaches the series and every occurrence, each keeping its own guests, with no write to an occurrence")
    func seriesAddReachesEveryOccurrence() async throws {
        try await runAll(F.addD, account: "guests-g-series")
    }

    @Test("18. removing a guest from the whole series removes them from the series and every occurrence, with no write to an occurrence")
    func seriesRemoveReachesEveryOccurrence() async throws {
        try await runAll(GuestChangeOracle.Change(removes: [F.guestB]), account: "guests-g-series-remove")
    }

    @Test("3. a whole-series change reaches each changed occurrence as the series' difference: its own guests stay, and a guest it dropped is not invited back", arguments: SeriesDifferenceShape.allCases)
    func seriesDifferenceReachesEveryOccurrence(_ shape: SeriesDifferenceShape) async throws {
        let after = try await runAll(shape.change, account: "guests-g-shape-\(shape)")
        let week4 = after[G.instanceId(week: 4)] ?? [], week5 = after[G.instanceId(week: 5)] ?? []
        #expect(Set(week4.compactMap(\.address)) == shape.week4(organizer: [F.organizer]), "week 4 holds \(week4)")
        #expect(Set(week5.compactMap(\.address)) == shape.week5(organizer: [F.organizer]), "week 5 holds \(week5)")
    }

    @Test("14. one occurrence edited by the series id gets the guest added to its own guests (#596)")
    func oneOccurrenceBySeriesIdKeepsItsOwnGuests() async throws {
        let seed = G.seed()
        let stored = FakeGoogleCalendar(seed)
        let r = try await G.run(seed, eventId: G.seriesId, F.addD.arguments.merging(F.thisOnly(week: 4)) { mine, _ in mine },
                                account: "guests-g-one-by-series")
        #expect(r.rows.isEmpty, "the edit did not land: \(r.rows.map { $0.failureReason ?? $0.status })")
        #expect(r.calendar.writes == ["PATCH \(G.instanceId(week: 4))"], "writes: \(r.calendar.writes)")
        let problems = GuestChangeOracle.problems(
            before: G.guests(stored, G.everyId), after: G.guests(r.calendar, G.everyId),
            inScope: [G.instanceId(week: 4)], change: F.addD, isUnanswered: G.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("17. a change of every occurrence named by one changed occurrence's id reaches the series from its own guests, and every occurrence from its own (#560)")
    func everyOccurrenceNamedByAnOccurrenceId() async throws {
        // Week 4 holds C on its own: the series must not take C.
        try await runAll(F.addD, eventId: G.instanceId(week: 4), account: "guests-g-all-by-occurrence")
    }

    @Test("15. a guest stored with no address is kept through an add (#597)")
    func guestWithoutAddressSurvives() async throws {
        let noAddress: [String: Any] = ["id": "guest-without-address", "displayName": "Front desk",
                                        "responseStatus": "needsAction"]
        let seed = [G.event(id: "single", starts: F.start, attendees: [G.org, G.a, noAddress])]
        let stored = FakeGoogleCalendar(seed)
        let r = try await G.run(seed, eventId: "single", F.addD.arguments, account: "guests-g-no-address")
        #expect(r.rows.isEmpty, "the edit did not land: \(r.rows.map { $0.failureReason ?? $0.status })")
        let problems = GuestChangeOracle.problems(
            before: G.guests(stored, ["single"]), after: G.guests(r.calendar, ["single"]),
            inScope: ["single"], change: F.addD, isUnanswered: G.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }
}

// MARK: - Outlook (Microsoft Graph)

enum GraphGuests {
    typealias F = GuestFixture
    typealias Guest = GuestChangeOracle.Guest

    static let seriesId = "planning-series"
    static let answeredAt = F.rfc3339(Date().addingTimeInterval(-86_400))

    static func guest(_ address: String, _ name: String, type: String, response: String) -> [String: Any] {
        ["emailAddress": ["address": address, "name": name], "type": type,
         "status": ["response": response, "time": answeredAt]]
    }

    static var a: [String: Any] { guest(F.guestA, "Guest A", type: "required", response: "accepted") }
    static var b: [String: Any] { guest(F.guestB, "Guest B", type: "optional", response: "tentativelyAccepted") }
    static var c: [String: Any] { guest(F.guestC, "Guest C", type: "required", response: "accepted") }

    static func instanceId(week: Int) -> String { "\(seriesId)-w\(week)" }

    static func time(_ date: Date) -> [String: Any] { ["dateTime": F.naiveUTC(date) + ".0000000", "timeZone": "UTC"] }

    static func event(id: String, starts: Date, attendees: [[String: Any]], subject: String = "Planning") -> [String: Any] {
        ["id": id, "subject": subject, "body": ["contentType": "text", "content": "Agenda"],
         "start": time(starts), "end": time(starts.addingTimeInterval(F.hour)), "isAllDay": false, "showAs": "busy",
         "organizer": ["emailAddress": ["address": F.organizer, "name": "Organizer"]], "attendees": attendees]
    }

    static func series(_ attendees: [[String: Any]]) -> [String: Any] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = F.utc
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        var e = event(id: seriesId, starts: F.start, attendees: attendees)
        e["type"] = "seriesMaster"
        e["recurrence"] = [
            "pattern": ["type": "weekly", "interval": 1, "month": 0, "dayOfMonth": 0,
                        "daysOfWeek": [names[cal.component(.weekday, from: F.start) - 1]],
                        "firstDayOfWeek": "sunday", "index": "first"],
            "range": ["type": "numbered", "startDate": String(F.naiveUTC(F.start).prefix(10)), "endDate": "0001-01-01",
                      "recurrenceTimeZone": "UTC", "numberOfOccurrences": 8],
        ]
        return e
    }

    static func occurrence(week: Int, subject: String = "Planning", moved: TimeInterval = 0,
                           changed: Bool = true, _ attendees: [[String: Any]]) -> [String: Any] {
        var e = event(id: instanceId(week: week), starts: F.slot(week).addingTimeInterval(moved),
                      attendees: attendees, subject: subject)
        e["seriesMasterId"] = seriesId
        e["type"] = changed ? "exception" : "occurrence"
        e["originalStart"] = F.rfc3339(F.slot(week))
        return e
    }

    /// The series these tests use (Graph keeps the organizer out of `attendees`), with weeks 1 and 6
    /// unchanged occurrences.
    static func seed() -> [[String: Any]] {
        [
            series([a, b]),
            occurrence(week: 1, changed: false, [a, b]),
            occurrence(week: 2, subject: "Planning review", [a, b]),
            occurrence(week: 3, moved: F.hour, [a, b]),
            occurrence(week: 4, [a, b, c]),
            occurrence(week: 5, [a]),
            occurrence(week: 6, changed: false, [a, b]),
        ]
    }

    static var everyId: [String] { [seriesId] + [1, 2, 3, 4, 5, 6].map { instanceId(week: $0) } }

    static func guests(_ graph: FakeGraphCalendar, _ ids: [String]) -> [String: [Guest]] {
        var out: [String: [Guest]] = [:]
        for id in ids {
            guard let event = graph.event(id) else { continue }
            out[id] = (event["attendees"] as? [[String: Any]] ?? []).map {
                Guest(address: (($0["emailAddress"] as? [String: Any])?["address"] as? String)?.lowercased(),
                      raw: F.canonical($0))
            }
        }
        return out
    }

    /// Unanswered: a status whose response is `none` or `notResponded` (Graph refuses an attendee
    /// written with no status, #622).
    static func isUnanswered(_ guest: Guest) -> Bool {
        let entry = (try? JSONSerialization.jsonObject(with: Data(guest.raw.utf8))) as? [[String: Any]]
        let response = (entry?.first?["status"] as? [String: Any])?["response"] as? String
        return response == "none" || response == "notResponded"
    }

    static func run(_ graph: FakeGraphCalendar, eventId: String, _ arguments: [String: JSONValue], account: String)
        async throws -> [PendingCalendarOperation] {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        return try await drainEdit(accountId: account, eventId: eventId, calendarId: "primary",
                                   arguments: arguments, provider: provider)
    }
}

@Suite("A guest change on Outlook reaches the item it covers, from its own guests", .serialized, .processGlobalState)
struct OutlookGuestChangeTests {
    typealias F = GuestFixture
    typealias X = GraphGuests

    /// The whole-series change `change`, by `eventId`: the series must hold the change on its own
    /// guests, every occurrence (weeks 4 and 5 with guests of their own included) the series'
    /// difference on its own, and the app writes no occurrence (the server carries the series'
    /// change to them). Returns every item's guests afterwards.
    @discardableResult
    private func runAll(_ change: GuestChangeOracle.Change, eventId: String = X.seriesId, account: String) async throws
        -> [String: [GuestChangeOracle.Guest]] {
        let graph = FakeGraphCalendar(X.seed())
        let before = X.guests(graph, X.everyId)
        let arguments = change.arguments.merging(["edit_scope": .string("all")]) { mine, _ in mine }
        let rows = try await X.run(graph, eventId: eventId, arguments, account: account)
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let occurrencePatches = graph.patchedIds.filter { $0 != X.seriesId }
        #expect(occurrencePatches.isEmpty, "the app wrote an occurrence: \(graph.patchedIds)")
        let after = X.guests(graph, X.everyId)
        let problems = GuestChangeOracle.problems(
            before: before, after: after, inScope: Set(X.everyId),
            change: change, series: X.seriesId, isUnanswered: X.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
        return after
    }

    @Test("13. adding a guest to the whole series reaches the series and every occurrence, each keeping its own guests, with no write to an occurrence")
    func seriesAddReachesEveryOccurrence() async throws {
        try await runAll(F.addD, account: "guests-x-series")
    }

    @Test("18. removing a guest from the whole series removes them from the series and every occurrence, with no write to an occurrence")
    func seriesRemoveReachesEveryOccurrence() async throws {
        try await runAll(GuestChangeOracle.Change(removes: [F.guestB]), account: "guests-x-series-remove")
    }

    @Test("3. a whole-series change reaches each changed occurrence as the series' difference: its own guests stay, and a guest it dropped is not invited back", arguments: SeriesDifferenceShape.allCases)
    func seriesDifferenceReachesEveryOccurrence(_ shape: SeriesDifferenceShape) async throws {
        // Graph keeps the organizer out of `attendees`.
        let after = try await runAll(shape.change, account: "guests-x-shape-\(shape)")
        let week4 = after[X.instanceId(week: 4)] ?? [], week5 = after[X.instanceId(week: 5)] ?? []
        #expect(Set(week4.compactMap(\.address)) == shape.week4(organizer: []), "week 4 holds \(week4)")
        #expect(Set(week5.compactMap(\.address)) == shape.week5(organizer: []), "week 5 holds \(week5)")
    }

    @Test("14. one occurrence edited by the series id gets the guest added to its own guests (#596)")
    func oneOccurrenceBySeriesIdKeepsItsOwnGuests() async throws {
        let graph = FakeGraphCalendar(X.seed())
        let before = X.guests(graph, X.everyId)
        let rows = try await X.run(graph, eventId: X.seriesId, F.addD.arguments.merging(F.thisOnly(week: 4)) { mine, _ in mine },
                                   account: "guests-x-one-by-series")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        #expect(graph.patchedIds == [X.instanceId(week: 4)], "PATCHes: \(graph.patchedIds)")
        let problems = GuestChangeOracle.problems(
            before: before, after: X.guests(graph, X.everyId), inScope: [X.instanceId(week: 4)],
            change: F.addD, isUnanswered: X.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("17. a change of every occurrence named by one changed occurrence's id reaches the series from its own guests, and every occurrence from its own (#560)")
    func everyOccurrenceNamedByAnOccurrenceId() async throws {
        // Week 4 holds C on its own: the series must not take C.
        try await runAll(F.addD, eventId: X.instanceId(week: 4), account: "guests-x-all-by-occurrence")
    }

    @Test("16. a new guest is written with an unanswered status, which Graph requires")
    func newGuestCarriesAStatus() async throws {
        let graph = FakeGraphCalendar([X.event(id: "single", starts: F.start, attendees: [X.a, X.b])])
        let rows = try await X.run(graph, eventId: "single", F.addD.arguments, account: "guests-x-status")
        #expect(rows.isEmpty, "the edit did not land (a status-less entry is refused with 405): \(rows.map { $0.failureReason ?? $0.status })")
        let added = (graph.event("single")?["attendees"] as? [[String: Any]])?.first {
            (($0["emailAddress"] as? [String: Any])?["address"] as? String)?.lowercased() == F.guestD
        }
        #expect((added?["status"] as? [String: Any])?["response"] as? String == "none",
                "the new guest is \(F.canonical(added))")
        #expect(added?["type"] as? String == "required", "the new guest is \(F.canonical(added))")
    }
}

// MARK: - Pins: today's guest changes that the fix must keep (Testing rule 6)
//
// Each holds on main. They drive the queue from the tool's arguments to the server, so they keep
// meaning the same thing once the change reaches the provider instead of a list worked out in the
// queue.

enum GuestPinChange: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case addAndRemoveInAnyCase = "adds one guest and removes another named in capitals with mailto:"
    case addPresentGuest = "adds a guest already invited, named in another letter case and name"
    case removeEveryone = "removes everyone with *"
    case namesNobody = "names nobody, alongside a new title"

    var testDescription: String { rawValue }

    var change: GuestChangeOracle.Change {
        switch self {
        case .addAndRemoveInAnyCase:
            return .init(adds: [.init(email: GuestFixture.guestD, name: "Guest D")], removes: ["MAILTO:GUEST-B@EXAMPLE.COM"])
        case .addPresentGuest:
            return .init(adds: [.init(email: "Guest-A@Example.COM", name: "Someone else")])
        case .removeEveryone:
            return .init(removes: ["*"])
        case .namesNobody:
            return .init(namesNobody: true)
        }
    }

    var arguments: [String: JSONValue] {
        var out = change.arguments
        if self == .namesNobody { out["title"] = .string("Planning, new title") }
        return out
    }
}

@Suite("Pins: a guest change on an event that does not repeat", .serialized, .processGlobalState)
struct GuestChangeSingleEventPinTests {
    typealias F = GuestFixture
    typealias C = CalDAVGuests
    typealias G = GoogleGuests
    typealias X = GraphGuests

    @Test("CalDAV", arguments: GuestPinChange.allCases)
    func caldav(_ pin: GuestPinChange) async throws {
        let seed = C.resource([C.series([C.org, C.a, C.b], repeats: false)])
        let run = C.serve(seed)
        defer { run.http.close() }
        let rows = try await C.drain(run, pin.arguments, account: "guests-pin-c-\(pin)")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let problems = C.problems(before: seed, after: run.store.storedICS(path: C.seriesPath), inScope: [C.seriesKey], pin.change)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("Google", arguments: GuestPinChange.allCases)
    func google(_ pin: GuestPinChange) async throws {
        let seed = [G.event(id: "single", starts: F.start, attendees: [G.org, G.a, G.b])]
        let stored = FakeGoogleCalendar(seed)
        let r = try await G.run(seed, eventId: "single", pin.arguments, account: "guests-pin-g-\(pin)")
        #expect(r.rows.isEmpty, "the edit did not land: \(r.rows.map { $0.failureReason ?? $0.status })")
        let problems = GuestChangeOracle.problems(
            before: G.guests(stored, ["single"]), after: G.guests(r.calendar, ["single"]),
            inScope: ["single"], change: pin.change, isUnanswered: G.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
        if pin == .namesNobody {
            let sent = r.patches
            #expect(sent.allSatisfy { $0["attendees"] == nil }, "a write carried a guest list: \(sent.map { F.canonical($0["attendees"]) })")
        }
    }

    @Test("Outlook", arguments: GuestPinChange.allCases)
    func outlook(_ pin: GuestPinChange) async throws {
        let graph = FakeGraphCalendar([X.event(id: "single", starts: F.start, attendees: [X.a, X.b])])
        let before = X.guests(graph, ["single"])
        let rows = try await X.run(graph, eventId: "single", pin.arguments, account: "guests-pin-x-\(pin)")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let problems = GuestChangeOracle.problems(
            before: before, after: X.guests(graph, ["single"]), inScope: ["single"],
            change: pin.change, isUnanswered: X.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
        if pin == .namesNobody {
            #expect(graph.patches("single").allSatisfy { $0["attendees"] == nil },
                    "a write carried a guest list: \(graph.patches("single").map { F.canonical($0["attendees"]) })")
        }
    }
}

@Suite("Pins: one occurrence edited by its own id gets the change on its own guests", .serialized, .processGlobalState)
struct GuestChangeOccurrenceIdPinTests {
    typealias F = GuestFixture
    typealias C = CalDAVGuests
    typealias G = GoogleGuests
    typealias X = GraphGuests

    @Test("CalDAV")
    func caldav() async throws {
        let seed = C.changedSeries()
        let run = C.serve(seed)
        defer { run.http.close() }
        let occurrenceId = CalDAVOccurrences.OccurrenceId.make(seriesHref: C.seriesPath, key: C.key(week: 4))
        let rows = try await C.drain(run, eventId: occurrenceId, F.addD.arguments.merging(F.thisOnly(week: 4)) { mine, _ in mine },
                                     account: "guests-pin-c-occurrence")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let problems = C.problems(before: seed, after: run.store.storedICS(path: C.seriesPath), inScope: [C.key(week: 4)], F.addD)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("Google")
    func google() async throws {
        let seed = G.seed()
        let stored = FakeGoogleCalendar(seed)
        let r = try await G.run(seed, eventId: G.instanceId(week: 4), F.addD.arguments.merging(F.thisOnly(week: 4)) { mine, _ in mine },
                                account: "guests-pin-g-occurrence")
        #expect(r.rows.isEmpty, "the edit did not land: \(r.rows.map { $0.failureReason ?? $0.status })")
        let problems = GuestChangeOracle.problems(
            before: G.guests(stored, G.everyId), after: G.guests(r.calendar, G.everyId),
            inScope: [G.instanceId(week: 4)], change: F.addD, isUnanswered: G.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test("Outlook")
    func outlook() async throws {
        let graph = FakeGraphCalendar(X.seed())
        let before = X.guests(graph, X.everyId)
        let rows = try await X.run(graph, eventId: X.instanceId(week: 4), F.addD.arguments.merging(F.thisOnly(week: 4)) { mine, _ in mine },
                                   account: "guests-pin-x-occurrence")
        #expect(rows.isEmpty, "the edit did not land: \(rows.map { $0.failureReason ?? $0.status })")
        let problems = GuestChangeOracle.problems(
            before: before, after: X.guests(graph, X.everyId), inScope: [X.instanceId(week: 4)],
            change: F.addD, isUnanswered: X.isUnanswered)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }
}

@Suite("Pins: a guest change to a demo event that is gone", .serialized, .processGlobalState)
struct DemoGuestChangePinTests {
    @Test("is retired as not found, not left queued")
    func goneEventIsRetired() async throws {
        let account = "guests-pin-demo"
        let rows = try await drainEdit(
            accountId: account, eventId: "demo-event-gone-\(UUID().uuidString.prefix(8))", calendarId: "primary",
            arguments: GuestFixture.addD.arguments, provider: DemoCalendarProvider(accountId: account))
        #expect(rows.count == 1 && rows.first?.status == PendingStatus.failed.rawValue
                    && rows.first?.failureReason == "event not found on server",
                "rows: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
    }
}

@Suite("A guest change to a demo event", .serialized, .processGlobalState)
struct DemoGuestChangeTests {
    private static func storedGuests(_ pool: DatabasePool, _ id: String?) async throws -> [[String: String]] {
        let json = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT attendeesJSON FROM demoCalendarEvent WHERE id = ?", arguments: [id])
        }
        return try json.map { try JSONDecoder().decode([[String: String]].self, from: Data($0.utf8)) } ?? []
    }

    @Test("is applied to the guests the event stores, and an edit naming nobody keeps them")
    func changeIsAppliedToTheStoredGuests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-guests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }

        let provider = DemoCalendarProvider(accountId: "demo-guests")
        let start = Date().addingTimeInterval(7 * 86_400)
        var create = GCalEventInput()
        create.summary = "Planning"
        create.startDateTime = start.iso8601String()
        create.endDateTime = start.addingTimeInterval(3_600).iso8601String()
        create.attendees = [(email: "alice@example.com", name: "Alice"), (email: "bob@example.com", name: nil)]
        let created = try await provider.createEvent(calendarId: "primary", event: create, sendUpdates: "none")

        var edit = create
        edit.attendees = nil
        edit.attendeeChange = AttendeeChange(adds: [.init(email: "carol@example.com", name: "Carol")], removes: ["BOB@example.com"])
        _ = try await provider.updateEvent(calendarId: "primary", eventId: created.id ?? "", event: edit, sendUpdates: "none")
        #expect(try await Self.storedGuests(pool, created.id)
                == [["email": "alice@example.com", "name": "Alice"], ["email": "carol@example.com", "name": "Carol"]])

        var rename = create
        rename.attendees = nil
        rename.summary = "Planning (renamed)"
        _ = try await provider.updateEvent(calendarId: "primary", eventId: created.id ?? "", event: rename, sendUpdates: "none")
        #expect(try await Self.storedGuests(pool, created.id)
                == [["email": "alice@example.com", "name": "Alice"], ["email": "carol@example.com", "name": "Carol"]],
                "an edit that names nobody changed the guests")

        var clear = create
        clear.attendees = nil
        clear.attendeeChange = AttendeeChange(removes: ["*"])
        _ = try await provider.updateEvent(calendarId: "primary", eventId: created.id ?? "", event: clear, sendUpdates: "none")
        let rawAfterClear = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT attendeesJSON FROM demoCalendarEvent WHERE id = ?", arguments: [created.id])
        }
        #expect(rawAfterClear == nil, "an event left with no guests stores \(rawAfterClear ?? "nil"), not no guest list, as a new event with none does")
    }
}
