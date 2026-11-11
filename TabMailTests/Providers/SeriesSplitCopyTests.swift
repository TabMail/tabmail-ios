/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

// Property preservation for a this-and-following split on Google and Outlook: the new part is a
// copy of the stored series, and the capped series keeps what it had. Each test reads what the
// server was sent or ends up holding.

/// A JSON value written with sorted keys, for comparing what was stored with what was sent.
private func canonical(_ value: Any?) -> String {
    guard let value, JSONSerialization.isValidJSONObject([value]),
          let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
    else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

private func jsonObject(_ data: Data?) -> [String: Any]? {
    data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
}

// MARK: - Google

private enum GoogleSplitFixture {
    static let masterPath = "/calendar/v3/calendars/primary/events/master-1"
    static let createPath = "/calendar/v3/calendars/primary/events"
    static let recurrenceId = "2099-05-20T17:00:00"
    static let utc = TimeZone(identifier: "UTC")!

    static var attendees: [[String: Any]] { [
        ["email": "olivia@example.com", "organizer": true, "self": true, "responseStatus": "accepted"],
        ["email": "alice@example.com", "displayName": "Alice", "optional": true, "responseStatus": "accepted",
         "comment": "Glad to", "id": "profile-1"],
        ["email": "room-1@example.com", "resource": true, "responseStatus": "accepted"],
        ["email": "bob@example.com", "responseStatus": "declined", "additionalGuests": 1],
    ] }

    /// Properties the new part must carry exactly as stored.
    static let keptKeys = [
        "description", "location", "colorId", "transparency", "visibility", "status", "eventType",
        "guestsCanModify", "guestsCanInviteOthers", "guestsCanSeeOtherGuests", "reminders",
        "extendedProperties", "conferenceData", "attachments", "source", "privateCopy",
    ]

    /// Keys the server owns or that name the stored event.
    static let serverOwnedKeys = [
        "kind", "etag", "htmlLink", "created", "updated", "creator", "organizer", "iCalUID", "sequence",
        "hangoutLink",
    ]

    static func master(
        recurrence: [String] = [
            "RRULE:FREQ=WEEKLY;UNTIL=20991230T170000Z",
            "EXDATE:20990513T170000Z,20990527T170000Z",
            "RDATE:20990515T170000Z,20990529T170000Z",
        ],
        start: [String: Any] = ["dateTime": "2099-05-06T17:00:00Z", "timeZone": "UTC"],
        end: [String: Any] = ["dateTime": "2099-05-06T17:45:00Z", "timeZone": "UTC"]
    ) -> [String: Any] {
        [
            "kind": "calendar#event", "etag": "\"3\"", "id": "master-1", "status": "confirmed",
            "htmlLink": "https://calendar.example.com/event?eid=1",
            "created": "2099-01-01T00:00:00.000Z", "updated": "2099-01-02T00:00:00.000Z",
            "summary": "Weekly sync", "description": "<b>Agenda</b> for the week", "location": "Room 1",
            "colorId": "5",
            "creator": ["email": "olivia@example.com"],
            "organizer": ["email": "olivia@example.com", "self": true],
            "start": start, "end": end,
            "recurrence": recurrence,
            "iCalUID": "master-1@example.com", "sequence": 3,
            "transparency": "opaque", "visibility": "private", "eventType": "default",
            "attendees": attendees,
            "guestsCanModify": true, "guestsCanInviteOthers": false, "guestsCanSeeOtherGuests": false,
            "reminders": ["useDefault": false, "overrides": [["method": "popup", "minutes": 15]]],
            "extendedProperties": ["private": ["app": "kept"]],
            "conferenceData": [
                "conferenceId": "abc-defg-hij",
                "conferenceSolution": ["key": ["type": "hangoutsMeet"], "name": "Google Meet"],
                "entryPoints": [["entryPointType": "video", "uri": "https://meet.example.com/abc-defg-hij"]],
            ],
            "hangoutLink": "https://meet.example.com/abc-defg-hij",
            "attachments": [["fileUrl": "https://drive.example.com/file/1", "title": "Notes", "mimeType": "application/pdf"]],
            "source": ["url": "https://example.com/source", "title": "Source"],
            "privateCopy": true,
        ]
    }

    struct Wire {
        let created: [String: Any]?
        let createQuery: [String: String]
        let patchedRecurrences: [[String]]
        let methods: [String]
    }

    /// An occurrence of `master-1` as `events.instances` lists it, at `place` (a UTC wall time, or a
    /// date for an all-day series), its place in the series (`originalStartTime`) the same.
    static func occurrence(_ place: String) -> [String: Any] {
        let at: [String: Any] = place.count == 10 ? ["date": place] : ["dateTime": place + "Z", "timeZone": "UTC"]
        return ["id": "master-1_\(place.filter(\.isNumber))", "status": "confirmed", "recurringEventId": "master-1",
                "start": at, "originalStartTime": at]
    }

    /// The instances list of `master-1`.
    static func instances(_ items: [[String: Any]]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: ["items": items])
    }

    /// Split `master` at `recurrenceId` with `patch` against a fake Google calendar whose instances
    /// list is `listed` (by default the occurrence split at).
    static func split(_ master: [String: Any], recurrenceId: String = recurrenceId, listed: [[String: Any]]? = nil,
                      patch: GCalEventInput) async throws -> Wire {
        let attempt = await attempt(master, recurrenceId: recurrenceId, listed: listed, patch: patch)
        if let error = attempt.error { throw error }
        return attempt.wire
    }

    /// `split`, returning what reached the wire whether or not the split was refused.
    static func attempt(_ master: [String: Any], recurrenceId: String = recurrenceId, listed: [[String: Any]]? = nil,
                        patch: GCalEventInput) async -> (wire: Wire, error: Error?) {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let ok = ["Content-Type": "application/json"]
        // swiftlint:disable:next force_try
        let stored = try! JSONSerialization.data(withJSONObject: master)
        http.register(path: masterPath, method: "GET", response: .raw(statusCode: 200, headers: ok, body: stored))
        http.register(path: masterPath + "/instances", method: "GET",
                      response: .raw(statusCode: 200, headers: ok, body: instances(listed ?? [occurrence(recurrenceId)])))
        http.register(path: masterPath, method: "PATCH", response: .raw(statusCode: 200, headers: ok, body: stored))
        http.register(path: createPath, method: "POST") { request in
            .raw(statusCode: 200, headers: ok, body: request.body ?? Data())
        }
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        do {
            _ = try await provider.splitSeries(
                eventId: "master-1", recurrenceId: recurrenceId, recurrenceIdZone: utc, patch: patch)
            return (wire(http), nil)
        } catch {
            return (wire(http), error)
        }
    }

    static func wire(_ http: FakeHTTP.Scenario) -> Wire {
        let calls = http.recordedCalls()
        let post = calls.first { $0.method == "POST" }
        let query = post.flatMap { URLComponents(string: $0.url)?.queryItems } ?? []
        return Wire(
            created: jsonObject(post?.body),
            createQuery: Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a }),
            patchedRecurrences: calls.filter { $0.method == "PATCH" }.map { jsonObject($0.body)?["recurrence"] as? [String] ?? [] },
            methods: calls.map(\.method))
    }

    static func attendee(_ event: [String: Any]?, _ address: String) -> [String: Any]? {
        (event?["attendees"] as? [[String: Any]])?.first { ($0["email"] as? String) == address }
    }
}

@Suite("Google split keeps the series' properties", .serialized)
struct GoogleSeriesSplitCopyTests {

    @Test("the new part is the stored series under its own id, with only the edited title changed")
    func newPartCopiesTheSeries() async throws {
        var patch = GCalEventInput()
        patch.summary = "Weekly sync (phase 2)"
        let master = GoogleSplitFixture.master()
        let wire = try await GoogleSplitFixture.split(master, patch: patch)
        let created = try #require(wire.created, "no new part was created")

        for key in GoogleSplitFixture.keptKeys {
            #expect(canonical(created[key]) == canonical(master[key]), "the new part changed '\(key)': \(canonical(created[key]))")
        }
        for key in GoogleSplitFixture.serverOwnedKeys {
            #expect(created[key] == nil, "the new part carried the server-owned '\(key)'")
        }
        #expect(created["summary"] as? String == "Weekly sync (phase 2)")
        #expect(created["id"] as? String == GoogleCalendarProvider.deterministicSplitEventId(
            masterId: "master-1", recurrenceId: GoogleSplitFixture.recurrenceId))
        let start = try #require(created["start"] as? [String: Any])
        #expect((start["dateTime"] as? String).flatMap(Date.fromISO8601)
                == Date.fromISO8601("2099-05-20T17:00:00Z"), "the new part does not start at the split: \(start)")
        #expect(wire.createQuery["conferenceDataVersion"] == "1", "the conference would be dropped: \(wire.createQuery)")
        #expect(wire.createQuery["supportsAttachments"] == "true", "the attachments would be dropped: \(wire.createQuery)")
        #expect(wire.createQuery["sendUpdates"] == "all")
    }

    @Test("excluded and added dates stay with the part they fall in, and the new part keeps the end date")
    func recurrenceIsSplitAtTheSlot() async throws {
        var patch = GCalEventInput()
        patch.summary = "Weekly sync"
        let wire = try await GoogleSplitFixture.split(GoogleSplitFixture.master(), patch: patch)
        #expect(wire.patchedRecurrences == [[
            "RRULE:FREQ=WEEKLY;UNTIL=20990520T165959Z", "EXDATE:20990513T170000Z", "RDATE:20990515T170000Z",
        ]], "the capped series: \(wire.patchedRecurrences)")
        #expect(wire.created?["recurrence"] as? [String] == [
            "RRULE:FREQ=WEEKLY;UNTIL=20991230T170000Z", "EXDATE:20990527T170000Z", "RDATE:20990529T170000Z",
        ], "the new part: \(canonical(wire.created?["recurrence"]))")
    }

    @Test("a new rule on the new part keeps the excluded and added dates after the split")
    func newRuleKeepsTheTailDates() async throws {
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE"]
        let wire = try await GoogleSplitFixture.split(GoogleSplitFixture.master(), patch: patch)
        #expect(wire.created?["recurrence"] as? [String] == [
            "RRULE:FREQ=WEEKLY;BYDAY=MO,WE", "EXDATE:20990527T170000Z", "RDATE:20990529T170000Z",
        ], "the new part: \(canonical(wire.created?["recurrence"]))")
    }

    @Test("an excluded or added date exactly at the split goes to the new part only", arguments: ["EXDATE", "RDATE"])
    func splitPointGoesToTheNewPart(_ kind: String) async throws {
        let recurrence = ["RRULE:FREQ=WEEKLY;UNTIL=20991230T170000Z", "\(kind):20990520T170000Z"]
        // How the lines are split. A split reaches an excluded date at the split only on a retry after
        // its own cap, the occurrence deleted in between: the series does not list an excluded
        // occurrence, so a first split there is refused (`splitAtNoOccurrenceWritesNothing`).
        let parts = try GoogleCalendarProvider.splitRecurrence(
            recurrence, cappedRRule: "RRULE:FREQ=WEEKLY;UNTIL=20990520T165959Z",
            tailRRule: "RRULE:FREQ=WEEKLY;UNTIL=20991230T170000Z",
            slot: try #require(Date.fromISO8601("2099-05-20T17:00:00Z")))
        #expect(parts.capped == ["RRULE:FREQ=WEEKLY;UNTIL=20990520T165959Z"], "\(kind): the capped series: \(parts.capped)")
        #expect(parts.tail == recurrence, "\(kind): the new part: \(parts.tail)")
        guard kind == "RDATE" else { return }
        // On the wire, for an added date on an occurrence the series lists.
        let wire = try await GoogleSplitFixture.split(GoogleSplitFixture.master(recurrence: recurrence), patch: GCalEventInput())
        #expect(wire.patchedRecurrences == [["RRULE:FREQ=WEEKLY;UNTIL=20990520T165959Z"]],
                "\(kind): the capped series: \(wire.patchedRecurrences)")
        #expect(wire.created?["recurrence"] as? [String] == recurrence,
                "\(kind): the new part: \(canonical(wire.created?["recurrence"]))")
    }

    @Test("an all-day series' excluded dates are split by date")
    func allDayDatesSplitByDate() async throws {
        let master = GoogleSplitFixture.master(
            recurrence: ["RRULE:FREQ=WEEKLY;COUNT=20", "EXDATE;VALUE=DATE:20990513,20990527"],
            start: ["date": "2099-05-06"], end: ["date": "2099-05-07"])
        let wire = try await GoogleSplitFixture.split(master, recurrenceId: "2099-05-20", patch: GCalEventInput())
        #expect(wire.patchedRecurrences == [["RRULE:FREQ=WEEKLY;UNTIL=20990519", "EXDATE;VALUE=DATE:20990513"]],
                "the capped series: \(wire.patchedRecurrences)")
        // Twenty weekly meetings from 2099-05-06; two fall before the split, so eighteen are left.
        #expect(wire.created?["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;COUNT=18", "EXDATE;VALUE=DATE:20990527"],
                "the new part: \(canonical(wire.created?["recurrence"]))")
        #expect(canonical(wire.created?["start"]) == canonical(["date": "2099-05-20"]))
    }

    @Test("attendees keep their entries when the edit does not move the new part")
    func attendeesKeptWithoutReschedule() async throws {
        var patch = GCalEventInput()
        patch.summary = "Renamed"
        patch.description = "New notes"
        let wire = try await GoogleSplitFixture.split(GoogleSplitFixture.master(), patch: patch)
        let attendees = try #require(wire.created?["attendees"] as? [[String: Any]])
        #expect(attendees.count == GoogleSplitFixture.attendees.count)
        for stored in GoogleSplitFixture.attendees {
            let address = try #require(stored["email"] as? String)
            let sent = try #require(GoogleSplitFixture.attendee(wire.created, address), "\(address) was dropped")
            let expected = stored.filter { !["self", "id", "organizer"].contains($0.key) }
            #expect(canonical(sent) == canonical(expected), "\(address) changed: \(canonical(sent))")
        }
    }

    @Test("a reschedule asks every attendee but the organizer again, keeping their entries", arguments: [
        "a new start", "an earlier start with the same end", "only a new end", "only a new rule", "a new place",
    ])
    func rescheduleAsksAgain(_ label: String) async throws {
        var patch = GCalEventInput()
        switch label {
        case "a new start": patch.startDateTime = "2099-05-20T18:00:00Z"
        case "an earlier start with the same end":
            patch.startDateTime = "2099-05-20T16:45:00Z"
            patch.endDateTime = "2099-05-20T17:45:00Z"
        case "only a new end": patch.endDateTime = "2099-05-20T18:00:00Z"
        case "only a new rule": patch.recurrence = ["RRULE:FREQ=DAILY"]
        default: patch.location = "Room 2"
        }
        let wire = try await GoogleSplitFixture.split(GoogleSplitFixture.master(), patch: patch)
        let organizer = GoogleSplitFixture.attendee(wire.created, "olivia@example.com")
        #expect(organizer?["responseStatus"] as? String == "accepted", "\(label): the organizer was asked")
        let alice = try #require(GoogleSplitFixture.attendee(wire.created, "alice@example.com"))
        #expect(alice["responseStatus"] as? String == "needsAction", "\(label): \(canonical(alice))")
        #expect(alice["optional"] as? Bool == true && alice["displayName"] as? String == "Alice", "\(label): \(canonical(alice))")
        let bob = GoogleSplitFixture.attendee(wire.created, "bob@example.com")
        #expect(bob?["responseStatus"] as? String == "needsAction", "\(label): \(canonical(bob))")
        #expect(bob?["additionalGuests"] as? Int == 1)
    }

    @Test("the organizer is never asked again, whether the attendee list flags them or only names them",
          arguments: ["flag only", "address only"])
    func organizerIsNotAskedAgain(_ how: String) async throws {
        var master = GoogleSplitFixture.master()
        var attendees = GoogleSplitFixture.attendees
        if how == "flag only" {
            // The series' organizer is a shared calendar; the attendee entry carries the flag.
            master["organizer"] = ["email": "team-calendar@example.com"]
        } else {
            attendees[0].removeValue(forKey: "organizer")
        }
        master["attendees"] = attendees
        var patch = GCalEventInput()
        patch.startDateTime = "2099-05-20T18:00:00Z"
        let wire = try await GoogleSplitFixture.split(master, patch: patch)
        let olivia = GoogleSplitFixture.attendee(wire.created, "olivia@example.com")
        #expect(olivia?["responseStatus"] as? String == "accepted", "\(how): the organizer was asked: \(canonical(olivia))")
        let alice = GoogleSplitFixture.attendee(wire.created, "alice@example.com")
        #expect(alice?["responseStatus"] as? String == "needsAction", "\(how): setup: the edit did not reschedule")
    }

    @Test("each change that moves the new part counts as a reschedule on its own; a restated time does not")
    func reschedulesByEachTrigger() {
        var timed = GCalEventInput()
        timed.startDateTime = "2099-05-20T17:00:00Z"
        timed.endDateTime = "2099-05-20T17:45:00Z"
        timed.recurrence = ["RRULE:FREQ=WEEKLY"]
        timed.location = "Room 1"
        func edited(_ change: (inout GCalEventInput) -> Void) -> GCalEventInput {
            var copy = timed
            change(&copy)
            return copy
        }
        #expect(!GoogleCalendarProvider.splitReschedules(timed, timed))
        #expect(!GoogleCalendarProvider.splitReschedules(timed, edited { $0.startDateTime = "2099-05-20T17:00:00.000Z" }),
                "the same start written another way")
        #expect(GoogleCalendarProvider.splitReschedules(timed, edited { $0.startDateTime = "2099-05-20T16:45:00Z" }), "start only")
        #expect(GoogleCalendarProvider.splitReschedules(timed, edited { $0.endDateTime = "2099-05-20T18:00:00Z" }), "end only")
        #expect(GoogleCalendarProvider.splitReschedules(timed, edited { $0.recurrence = ["RRULE:FREQ=DAILY"] }), "rule only")
        #expect(GoogleCalendarProvider.splitReschedules(timed, edited { $0.location = "Room 2" }), "place only")
        #expect(GoogleCalendarProvider.splitReschedules(timed, edited {
            $0.startDateTime = nil
            $0.endDateTime = nil
            $0.startDate = "2099-05-20"
            $0.endDate = "2099-05-21"
        }), "timed to all day")
        var allDay = GCalEventInput()
        allDay.startDate = "2099-05-20"
        allDay.endDate = "2099-05-21"
        #expect(!GoogleCalendarProvider.splitReschedules(allDay, allDay))
        var moved = allDay
        moved.startDate = "2099-05-21"
        moved.endDate = "2099-05-22"
        #expect(GoogleCalendarProvider.splitReschedules(allDay, moved), "all day, another date")
    }

    @Test("an attendee the edit adds is asked; ones it removes go; the others keep their entries")
    func attendeeChange() async throws {
        var patch = GCalEventInput()
        patch.attendeeChange = AttendeeChange(adds: [.init(email: "carol@example.com", name: "Carol")],
                                              removes: ["room-1@example.com", "bob@example.com"])
        let wire = try await GoogleSplitFixture.split(GoogleSplitFixture.master(), patch: patch)
        let attendees = try #require(wire.created?["attendees"] as? [[String: Any]])
        #expect(attendees.compactMap { $0["email"] as? String } == ["olivia@example.com", "alice@example.com", "carol@example.com"])
        #expect(canonical(GoogleSplitFixture.attendee(wire.created, "carol@example.com"))
                == canonical(["email": "carol@example.com", "displayName": "Carol"]))
        let alice = GoogleSplitFixture.attendee(wire.created, "alice@example.com")
        #expect(alice?["optional"] as? Bool == true && alice?["responseStatus"] as? String == "accepted",
                "a staying attendee lost their entry: \(canonical(alice))")
    }

    @Test("a guest the edit adds to a series with no guests is the new part's only guest, unanswered")
    func firstGuestOnASeriesWithNone() async throws {
        var master = GoogleSplitFixture.master()
        master.removeValue(forKey: "attendees")
        var patch = GCalEventInput()
        patch.attendeeChange = AttendeeChange(adds: [.init(email: "dave@example.com", name: "Dave")])
        let wire = try await GoogleSplitFixture.split(master, patch: patch)
        let attendees = wire.created?["attendees"] as? [[String: Any]] ?? []
        #expect(attendees.map { canonical($0) } == [canonical(["email": "dave@example.com", "displayName": "Dave"])],
                "the new part's guests: \(attendees.map { canonical($0) })")
    }

    @Test("""
    the new part is created before the cap; a cap whose response is lost, then a retry, keeps the \
    excluded and added dates after the split on the new part
    """)
    func lostCapResponseKeepsTheLaterDates() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let ok = ["Content-Type": "application/json"]
        let server = Mutex((master: GoogleSplitFixture.master(), created: [String: [String: Any]](), patches: 0))
        @Sendable func json(_ object: Any) -> Data {
            // swiftlint:disable:next force_try
            try! JSONSerialization.data(withJSONObject: object)
        }
        http.register(path: GoogleSplitFixture.masterPath, method: "GET") { _ in
            .raw(statusCode: 200, headers: ok, body: server.withLock { json($0.master) })
        }
        http.register(path: GoogleSplitFixture.masterPath, method: "PATCH") { request in
            server.withLock { state in
                if let recurrence = jsonObject(request.body)?["recurrence"] { state.master["recurrence"] = recurrence }
                state.patches += 1
                // The server keeps the first cap; its response never arrives.
                return state.patches == 1 ? .raw(statusCode: 500) : .raw(statusCode: 200, headers: ok, body: json(state.master))
            }
        }
        http.register(path: GoogleSplitFixture.createPath, method: "POST") { request in
            server.withLock { state in
                guard let body = jsonObject(request.body), let id = body["id"] as? String else { return .raw(statusCode: 400) }
                guard state.created[id] == nil else {
                    return .raw(statusCode: 409, headers: ok, body: json(
                        ["error": ["code": 409, "message": "duplicate", "errors": [["reason": "duplicate", "message": "duplicate"]]]]))
                }
                state.created[id] = body
                return .raw(statusCode: 200, headers: ok, body: json(body))
            }
        }
        http.register(path: GoogleSplitFixture.masterPath + "/instances", method: "GET") { _ in
            // The series lists the occurrence at the split until the cap ends it before it, so the
            // retry finds none there: it is this split's own cap, and is not asked again.
            let capped = server.withLock { state in
                (state.master["recurrence"] as? [String] ?? []).contains { $0.contains("UNTIL=20990520T165959Z") }
            }
            return .raw(statusCode: 200, headers: ok,
                        body: GoogleSplitFixture.instances(capped ? [] : [GoogleSplitFixture.occurrence(GoogleSplitFixture.recurrenceId)]))
        }
        http.register(path: GoogleSplitFixture.createPath + "/", method: "GET") { request in
            let id = String(request.url.path.split(separator: "/").last ?? "")
            guard let event = server.withLock({ state in state.created[id].map { json($0) } }) else { return .raw(statusCode: 404) }
            return .raw(statusCode: 200, headers: ok, body: event)
        }
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        func split() async throws {
            _ = try await provider.splitSeries(
                eventId: "master-1", recurrenceId: GoogleSplitFixture.recurrenceId,
                recurrenceIdZone: GoogleSplitFixture.utc, patch: GCalEventInput())
        }

        await #expect(throws: (any Error).self) { try await split() }
        let writes = http.recordedCalls().map(\.method).filter { $0 != "GET" }
        #expect(writes == ["POST", "PATCH"], "the new part must be created before the cap: \(writes)")
        try await split()

        let (count, newPart, capped) = server.withLock { state in
            (state.created.count,
             (state.created.values.first?["recurrence"] as? [String] ?? []).joined(separator: "|"),
             (state.master["recurrence"] as? [String] ?? []).joined(separator: "|"))
        }
        #expect(count == 1, "expected one new part, got \(count)")
        #expect(capped.contains("UNTIL=20990520T165959Z"), "the series was not capped: \(capped)")
        for later in ["20990527T170000Z", "20990529T170000Z"] {
            #expect(newPart.contains(later), "the new part lost \(later): \(newPart)")
            #expect(!capped.contains(later), "the series kept \(later): \(capped)")
        }
        for earlier in ["20990513T170000Z", "20990515T170000Z"] {
            #expect(capped.contains(earlier), "the series lost \(earlier): \(capped)")
            #expect(!newPart.contains(earlier), "the new part took \(earlier): \(newPart)")
        }
    }

    @Test("a series whose excluded dates can't be read is refused before anything is written")
    func unreadableDatesWriteNothing() async {
        let master = GoogleSplitFixture.master(recurrence: [
            "RRULE:FREQ=WEEKLY", "EXDATE;TZID=Not/AZone:20990513T170000",
        ])
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let ok = ["Content-Type": "application/json"]
        // swiftlint:disable:next force_try
        let stored = try! JSONSerialization.data(withJSONObject: master)
        http.register(path: GoogleSplitFixture.masterPath, method: "GET", response: .raw(statusCode: 200, headers: ok, body: stored))
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        await #expect(throws: CalendarProviderError.self) {
            _ = try await provider.splitSeries(
                eventId: "master-1", recurrenceId: GoogleSplitFixture.recurrenceId,
                recurrenceIdZone: GoogleSplitFixture.utc, patch: GCalEventInput())
        }
        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "a write was sent: \(http.servedCallSequence())")
    }

    @Test("a split at a recurrence_id at which no occurrence starts now writes nothing, and is the provider's absence", arguments: [
        "a time between two occurrences", "a date off the series' days", "a deleted occurrence", "a moved occurrence's place",
    ])
    func splitAtNoOccurrenceWritesNothing(_ label: String) async throws {
        // The series lists its occurrence on 2099-05-20 at 17:00 (its place) unless the case says otherwise.
        var master = GoogleSplitFixture.master()
        var listed = [GoogleSplitFixture.occurrence(GoogleSplitFixture.recurrenceId)]
        var recurrenceId = GoogleSplitFixture.recurrenceId
        switch label {
        case "a time between two occurrences": recurrenceId = "2099-05-20T17:30:00"
        case "a date off the series' days": recurrenceId = "2099-05-21T17:00:00"
        case "a deleted occurrence":
            // Deleted: excluded from the rule, and not listed.
            master["recurrence"] = ["RRULE:FREQ=WEEKLY;UNTIL=20991230T170000Z", "EXDATE:20990520T170000Z"]
            listed = []
        default:
            // Moved on its own to 18:00: nothing starts at its place (17:00) now. A recurrence_id
            // names an occurrence where it is now, never by its place in the series.
            listed[0]["start"] = ["dateTime": "2099-05-20T18:00:00Z", "timeZone": "UTC"]
        }
        var patch = GCalEventInput()
        patch.startDateTime = "2099-05-20T19:00:00Z"
        let attempt = await GoogleSplitFixture.attempt(master, recurrenceId: recurrenceId, listed: listed, patch: patch)
        #expect(attempt.wire.methods.allSatisfy { $0 == "GET" }, "\(label): written: \(attempt.wire.methods)")
        let error = try #require(attempt.error, "\(label): not refused")
        #expect(AccountManager.isCalendarNotFoundError(error), "\(label): \(error)")
    }
}

// MARK: - Outlook

private enum GraphSplitFixture {
    static let zone = TimeZone.current.identifier
    /// 10:00 on the device eight days ahead, and the same time a week later.
    static let start = GraphFixture.onDevice(days: 0, hour: 10)
    static let occurrence = GraphFixture.onDevice(days: 7, hour: 10)
    static var recurrenceId: String { GraphFixture.wall(occurrence, in: zone) }

    /// A series as Graph renders it for the device, carrying every property a split copies.
    static func series(range: [String: Any], online: Bool = false) -> [String: Any] {
        var e = GraphFixture.event(id: "ser-1", start: start, online: online, recurring: true)
        e["start"] = ["dateTime": GraphFixture.wall(start, in: zone) + ".0000000", "timeZone": zone]
        e["end"] = ["dateTime": GraphFixture.wall(start.addingTimeInterval(1_800), in: zone) + ".0000000", "timeZone": zone]
        e["importance"] = "high"
        e["sensitivity"] = "private"
        e["categories"] = ["Blue category", "Planning"]
        e["isReminderOn"] = true
        e["reminderMinutesBeforeStart"] = 30
        e["responseRequested"] = false
        e["allowNewTimeProposals"] = false
        e["hideAttendees"] = true
        var recurrence = e["recurrence"] as? [String: Any] ?? [:]
        var stored: [String: Any] = ["startDate": GraphFixture.deviceDay(start), "recurrenceTimeZone": "Pacific Standard Time"]
        stored.merge(range) { _, new in new }
        recurrence["range"] = stored
        e["recurrence"] = recurrence
        return e
    }

    static var noEnd: [String: Any] { ["type": "noEnd", "endDate": "0001-01-01", "numberOfOccurrences": 0] }
    static var endDate: [String: Any] {
        ["type": "endDate", "endDate": GraphFixture.deviceDay(GraphFixture.onDevice(days: 70, hour: 10)), "numberOfOccurrences": 0]
    }
    static var numbered: [String: Any] { ["type": "numbered", "endDate": "0001-01-01", "numberOfOccurrences": 10] }

    /// The stored properties the new part must carry exactly as stored (the subject is edited).
    static let keptKeys = [
        "body", "importance", "sensitivity", "showAs", "categories", "isReminderOn", "reminderMinutesBeforeStart",
        "location", "locations", "isAllDay", "responseRequested", "allowNewTimeProposals", "hideAttendees",
    ]

    /// Every key the create may carry: the kept properties, the subject, and what the split writes.
    static let createKeys = Set(keptKeys + ["subject", "start", "end", "recurrence", "attendees", "transactionId"])

    static func provider(_ http: FakeHTTP.Scenario) -> ExchangeCalendarProvider {
        ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" }, session: http.session)
    }

    /// A calendar holding `series` and, when `listed`, its occurrence at the split, as Graph lists it.
    static func calendar(_ series: [String: Any], listed: Bool = true) -> FakeGraphCalendar {
        FakeGraphCalendar([series] + (listed ? [GraphFixture.event(id: "ser-1-occ", start: occurrence, online: false,
                                                                   seriesMasterId: "ser-1")] : []))
    }
}

@Suite("Outlook split keeps the series' properties", .serialized)
struct ExchangeSeriesSplitCopyTests {

    private func split(_ series: [String: Any], patch: GCalEventInput) async throws -> (FakeGraphCalendar, [String: Any]) {
        let (graph, created, _) = try await splitOnTheWire(series, patch: patch)
        return (graph, created)
    }

    /// The split, with the create's body exactly as it was sent. `listed`: whether the series lists
    /// its occurrence at the split.
    private func splitOnTheWire(_ series: [String: Any], listed: Bool = true, patch: GCalEventInput)
        async throws -> (FakeGraphCalendar, [String: Any], [String: Any]) {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphSplitFixture.calendar(series, listed: listed)
        graph.install(on: http)
        _ = try await GraphSplitFixture.provider(http).splitSeries(
            eventId: "ser-1", recurrenceId: GraphSplitFixture.recurrenceId, recurrenceIdZone: .current, patch: patch)
        #expect(graph.created.count == 1, "expected one new part, got \(graph.created.count)")
        let posts = http.recordedCalls().filter { $0.method == "POST" }
        #expect(posts.count == 1, "expected one create, got \(posts.count)")
        let sent = try #require(jsonObject(posts.first?.body), "the create had no JSON body")
        return (graph, try #require(graph.created.first), sent)
    }

    @Test("the new part keeps every stored property the edit does not change, and its pattern",
          arguments: ["noEnd", "endDate", "numbered"])
    func newPartCopiesTheSeries(_ rangeType: String) async throws {
        let range = ["noEnd": GraphSplitFixture.noEnd, "endDate": GraphSplitFixture.endDate,
                     "numbered": GraphSplitFixture.numbered][rangeType]!
        let series = GraphSplitFixture.series(range: range)
        var patch = GCalEventInput()
        patch.summary = "Planning (phase 2)"
        let (_, created, sent) = try await splitOnTheWire(series, patch: patch)

        for key in GraphSplitFixture.keptKeys {
            #expect(series[key] != nil, "setup: the series has no '\(key)'")
            #expect(canonical(created[key]) == canonical(series[key]), "\(rangeType): the new part changed '\(key)': \(canonical(created[key]))")
        }
        // Nothing the server owns, or that names the stored series, is sent on the create.
        let extra = Set(sent.keys).subtracting(GraphSplitFixture.createKeys)
        #expect(extra.isEmpty, "\(rangeType): the create carried \(extra.sorted())")
        #expect(sent["transactionId"] != nil)
        #expect(created["subject"] as? String == "Planning (phase 2)")
        #expect(created["transactionId"] as? String == GoogleCalendarProvider.deterministicSplitEventId(
            masterId: "ser-1", recurrenceId: GraphSplitFixture.recurrenceId))

        let start = try #require(created["start"] as? [String: Any])
        let startWall = try #require(start["dateTime"] as? String)
        #expect(String(startWall.prefix(19)) == GraphSplitFixture.recurrenceId && start["timeZone"] as? String == GraphSplitFixture.zone,
                "\(rangeType): the new part does not start at the split: \(start)")

        let storedRecurrence = try #require(series["recurrence"] as? [String: Any])
        let recurrence = try #require(created["recurrence"] as? [String: Any])
        #expect(canonical(recurrence["pattern"]) == canonical(storedRecurrence["pattern"]), "\(rangeType): the pattern changed")
        let newRange = try #require(recurrence["range"] as? [String: Any])
        #expect(newRange["startDate"] as? String == String(startWall.prefix(10)), "\(rangeType): \(canonical(newRange))")
        #expect(newRange["recurrenceTimeZone"] as? String == "Pacific Standard Time", "\(rangeType): the range's zone was dropped")
        switch rangeType {
        case "endDate":
            // The stored 0 count Graph fills on every non-numbered range is not sent back.
            #expect(newRange["type"] as? String == "endDate" && newRange["endDate"] as? String == range["endDate"] as? String
                    && newRange["numberOfOccurrences"] == nil,
                    "the new part lost the series' end date: \(canonical(newRange))")
        case "numbered":
            // What is left of the count; the exact number is held to the series in
            // `ExchangeNumberedSplitTests` (this fixture's pattern day is the UTC one, so how many
            // occurrences come before the split in the range's Pacific zone depends on the host's).
            let left = newRange["numberOfOccurrences"] as? Int ?? 0
            #expect(newRange["type"] as? String == "numbered" && newRange["endDate"] == nil
                    && (1...(range["numberOfOccurrences"] as? Int ?? 0)).contains(left),
                    "the new part does not end with the series: \(canonical(newRange))")
        default:
            #expect(newRange["type"] as? String == "noEnd" && newRange["endDate"] == nil && newRange["numberOfOccurrences"] == nil,
                    "\(rangeType): \(canonical(newRange))")
        }
    }

    @Test("a series that already ends on this split's cap is a retry: the new part has no end")
    func ownCapIsARetry() async throws {
        // The state a retry reads when the cap was written and the create was not.
        let cap = try #require(ExchangeCalendarProvider.graphEndDateBefore(
            naiveISO: GraphSplitFixture.recurrenceId, allDay: false, zone: .current))
        let series = GraphSplitFixture.series(range: ["type": "endDate", "endDate": cap, "numberOfOccurrences": 0])
        // The cap ended the series before the occurrence, so the series no longer lists it: this
        // split's own cap is not asked again.
        let (_, _, sent) = try await splitOnTheWire(series, listed: false, patch: GCalEventInput())

        let recurrence = try #require(sent["recurrence"] as? [String: Any])
        let range = try #require(recurrence["range"] as? [String: Any])
        #expect(range["type"] as? String == "noEnd" && range["endDate"] == nil,
                "the new part would end before it starts: \(canonical(range))")
        #expect(range["startDate"] as? String == String(GraphSplitFixture.recurrenceId.prefix(10)), "\(canonical(range))")
    }

    @Test("a retry after this split's own cap does not look its occurrence up again: no instances read, and an occurrence moved there does not stop it")
    func ownCapRetryDoesNotLookTheOccurrenceUp() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let cap = try #require(ExchangeCalendarProvider.graphEndDateBefore(
            naiveISO: GraphSplitFixture.recurrenceId, allDay: false, zone: .current))
        let series = GraphSplitFixture.series(range: ["type": "endDate", "endDate": cap, "numberOfOccurrences": 0])
        // An occurrence at the split's place, moved on its own an hour later: looked up, it would stop
        // the split (nothing starts at the place now, and the one there was moved).
        var moved = GraphFixture.event(id: "ser-1-occ", start: GraphSplitFixture.occurrence, online: false, seriesMasterId: "ser-1")
        moved["start"] = ["dateTime": GraphFixture.naive(GraphSplitFixture.occurrence.addingTimeInterval(3_600)), "timeZone": "UTC"]
        let graph = FakeGraphCalendar([series, moved])
        graph.install(on: http)
        _ = try await GraphSplitFixture.provider(http).splitSeries(
            eventId: "ser-1", recurrenceId: GraphSplitFixture.recurrenceId, recurrenceIdZone: .current, patch: GCalEventInput())
        #expect(!http.recordedCalls().contains { $0.url.contains("/instances") },
                "the occurrence was looked up on a retry: \(http.servedCallSequence())")
        #expect(graph.created.count == 1, "no new part: \(http.servedCallSequence())")
    }

    @Test("attendees keep their name and type; one the edit adds is required")
    func attendeesKeepTheirType() async throws {
        let series = GraphSplitFixture.series(range: GraphSplitFixture.noEnd)
        let (_, kept) = try await split(series, patch: GCalEventInput())
        func types(_ event: [String: Any]) -> [String: String] {
            var out: [String: String] = [:]
            for a in event["attendees"] as? [[String: Any]] ?? [] {
                if let address = (a["emailAddress"] as? [String: Any])?["address"] as? String { out[address] = a["type"] as? String }
            }
            return out
        }
        #expect(types(kept) == types(series), "got \(types(kept))")
        let names = (kept["attendees"] as? [[String: Any]] ?? []).compactMap { ($0["emailAddress"] as? [String: Any])?["name"] as? String }
        #expect(names == ["Ana", "Bo", "Room 1"])

        var patch = GCalEventInput()
        patch.attendeeChange = AttendeeChange(adds: [.init(email: "cy@example.com", name: "Cy")], removes: ["room-1@example.com"])
        let (_, changed) = try await split(series, patch: patch)
        #expect(types(changed) == ["ana@example.com": "required", "bo@example.com": "optional", "cy@example.com": "required"],
                "got \(types(changed))")
    }

    @Test("new notes on an online series' new part keep its join section as stored")
    func onlineNotesKeepTheJoinSection() async throws {
        let series = GraphSplitFixture.series(range: GraphSplitFixture.noEnd, online: true)
        var patch = GCalEventInput()
        patch.description = "Phase 2 agenda"
        let (_, created) = try await split(series, patch: patch)
        let body = try #require(created["body"] as? [String: Any])
        let content = try #require(body["content"] as? String)
        #expect(body["contentType"] as? String == "html", "the new part's notes were written as text: \(canonical(body))")
        #expect(content.contains("Phase 2 agenda"), "the new notes are missing")
        let stored = try #require((series["body"] as? [String: Any])?["content"] as? String)
        let section = try #require(stored.range(of: GraphFixture.joinSection).map { String(stored[$0.lowerBound...]) })
        #expect(content.hasSuffix(section), "the join section was not kept as stored")
    }

    @Test("a new place replaces the stored places")
    func newPlaceReplacesPlaces() async throws {
        var patch = GCalEventInput()
        patch.location = "Room 5"
        let (_, created) = try await split(GraphSplitFixture.series(range: GraphSplitFixture.noEnd), patch: patch)
        #expect(canonical(created["location"]) == canonical(["displayName": "Room 5"]))
        #expect(!canonical(created["locations"]).contains("Room B"), "the old places stayed: \(canonical(created["locations"]))")
    }

    @Test("the capped series keeps its pattern, range zone and other properties, and ends at the split whatever its range",
          arguments: ["noEnd", "endDate", "numbered"])
    func cappedSeriesKeepsItsPattern(_ rangeType: String) async throws {
        let stored = ["noEnd": GraphSplitFixture.noEnd, "endDate": GraphSplitFixture.endDate,
                      "numbered": GraphSplitFixture.numbered][rangeType]!
        let series = GraphSplitFixture.series(range: stored)
        let (graph, _) = try await split(series, patch: GCalEventInput())
        // The cap as sent: an end date and no count, so a numbered series can't
        // be read as still running for its stored count.
        let capRecurrence = graph.patches("ser-1").first?["recurrence"] as? [String: Any]
        let capRange = capRecurrence?["range"] as? [String: Any]
        #expect(capRange?["type"] as? String == "endDate" && capRange?["numberOfOccurrences"] == nil,
                "\(rangeType): the cap sent \(canonical(capRange))")
        // As sent, not only as stored: a range sent with no zone is stored as UTC, and a pattern
        // sent without the stored first day of the week makes it Sunday.
        #expect(capRange?["recurrenceTimeZone"] as? String == "Pacific Standard Time",
                "\(rangeType): the cap sent the range zone \(capRange?["recurrenceTimeZone"] as? String ?? "none")")
        #expect((capRecurrence?["pattern"] as? [String: Any])?["firstDayOfWeek"] as? String == "monday",
                "\(rangeType): the cap sent \(canonical(capRecurrence?["pattern"]))")
        let capped = try #require(graph.event("ser-1"))
        let storedRecurrence = try #require(series["recurrence"] as? [String: Any])
        let recurrence = try #require(capped["recurrence"] as? [String: Any])
        #expect(canonical(recurrence["pattern"]) == canonical(storedRecurrence["pattern"]), "the cap changed the pattern")
        let range = try #require(recurrence["range"] as? [String: Any])
        #expect(range["type"] as? String == "endDate", "\(rangeType)")
        #expect(range["endDate"] as? String == GraphFixture.deviceDay(GraphFixture.onDevice(days: 6, hour: 10)), "\(rangeType): \(canonical(range))")
        #expect(range["startDate"] as? String == GraphFixture.deviceDay(GraphSplitFixture.start))
        #expect(range["recurrenceTimeZone"] as? String == "Pacific Standard Time")
        for key in GraphSplitFixture.keptKeys + ["subject", "attendees", "organizer"] {
            #expect(canonical(capped[key]) == canonical(series[key]), "the cap changed '\(key)'")
        }
    }

    @Test("a rule in the edit becomes the new part's rule, starting at the split; the capped series keeps its own")
    func editedRuleReplacesTheStoredOne() async throws {
        let series = GraphSplitFixture.series(range: GraphSplitFixture.noEnd)
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=DAILY"]
        let (graph, created) = try await split(series, patch: patch)

        let recurrence = try #require(created["recurrence"] as? [String: Any])
        let pattern = try #require(recurrence["pattern"] as? [String: Any])
        #expect(pattern["type"] as? String == "daily", "the stored rule replaced the edited one: \(canonical(pattern))")
        let startWall = try #require((created["start"] as? [String: Any])?["dateTime"] as? String)
        let range = try #require(recurrence["range"] as? [String: Any])
        #expect(range["startDate"] as? String == String(startWall.prefix(10)), "\(canonical(range))")

        let storedRecurrence = try #require(series["recurrence"] as? [String: Any])
        let capped = try #require(graph.event("ser-1")?["recurrence"] as? [String: Any])
        #expect(canonical(capped["pattern"]) == canonical(storedRecurrence["pattern"]), "the cap took the edited rule")
    }

    @Test("a split whose new start can't be dated is refused before the series is capped")
    func undatableStartWritesNothing() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let series = GraphSplitFixture.series(range: GraphSplitFixture.noEnd)
        // With its occurrence listed, so the split's lookup finds it on that date and the new part's
        // start is what refuses it.
        let graph = GraphSplitFixture.calendar(series)
        graph.install(on: http)
        // A timed series given only a date for the occurrence: the new part's start can't be read.
        let dateOnly = String(GraphSplitFixture.recurrenceId.prefix(10))
        await #expect(throws: CalendarProviderError.self) {
            _ = try await GraphSplitFixture.provider(http).splitSeries(
                eventId: "ser-1", recurrenceId: dateOnly, recurrenceIdZone: .current, patch: GCalEventInput())
        }
        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "a write was sent: \(http.servedCallSequence())")
        #expect(graph.created.isEmpty)
        #expect(canonical(graph.event("ser-1")?["recurrence"]) == canonical(series["recurrence"]), "the series was changed")
    }

    @Test("a failed create puts the stored recurrence back exactly")
    func failedCreateRestoresTheRecurrence() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let series = GraphSplitFixture.series(range: GraphSplitFixture.numbered)
        let graph = GraphSplitFixture.calendar(series)
        graph.install(on: http)
        graph.failNext("POST", with: 400)
        await #expect(throws: (any Error).self) {
            _ = try await GraphSplitFixture.provider(http).splitSeries(
                eventId: "ser-1", recurrenceId: GraphSplitFixture.recurrenceId, recurrenceIdZone: .current, patch: GCalEventInput())
        }
        #expect(graph.patches("ser-1").count == 2, "expected the cap and the revert")
        #expect(canonical(graph.event("ser-1")?["recurrence"]) == canonical(series["recurrence"]),
                "the series' recurrence was not restored: \(canonical(graph.event("ser-1")?["recurrence"]))")
        #expect(graph.created.isEmpty)
    }

    @Test("a split at a recurrence_id at which no occurrence starts now writes nothing, and is the provider's absence", arguments: [
        "a time between two occurrences", "a date off the series' days", "a deleted occurrence", "a moved occurrence's place",
    ])
    func splitAtNoOccurrenceWritesNothing(_ label: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let series = GraphSplitFixture.series(range: GraphSplitFixture.noEnd)
        var occurrence = GraphFixture.event(id: "ser-1-occ", start: GraphSplitFixture.occurrence, online: false,
                                            seriesMasterId: "ser-1")
        var recurrenceId = GraphSplitFixture.recurrenceId
        var seed = [series, occurrence]
        switch label {
        case "a time between two occurrences":
            recurrenceId = GraphFixture.wall(GraphSplitFixture.occurrence.addingTimeInterval(1_800), in: GraphSplitFixture.zone)
        case "a date off the series' days":
            recurrenceId = GraphFixture.wall(GraphSplitFixture.occurrence.addingTimeInterval(86_400), in: GraphSplitFixture.zone)
        case "a deleted occurrence":
            seed = [series]
        default:
            // Moved on its own an hour later: nothing starts at its place now. A recurrence_id names
            // an occurrence where it is now, never by its place in the series.
            occurrence["start"] = ["dateTime": GraphFixture.naive(GraphSplitFixture.occurrence.addingTimeInterval(3_600)), "timeZone": "UTC"]
            seed = [series, occurrence]
        }
        let graph = FakeGraphCalendar(seed)
        graph.install(on: http)
        var patch = GCalEventInput()
        patch.summary = "Planning (phase 2)"
        var thrown: Error?
        do {
            _ = try await GraphSplitFixture.provider(http).splitSeries(
                eventId: "ser-1", recurrenceId: recurrenceId, recurrenceIdZone: .current, patch: patch)
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "\(label): not refused")
        #expect(AccountManager.isCalendarNotFoundError(error), "\(label): \(error)")
        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "\(label): written: \(http.servedCallSequence())")
        #expect(canonical(graph.event("ser-1")?["recurrence"]) == canonical(series["recurrence"]), "\(label): the series was changed")
    }

    @Test("an all-day series' occurrence is found at the date its place begins in the series' own zone")
    func allDayPlaceIsDatedInTheSeriesZone() async throws {
        // Measured: Graph gives an all-day occurrence's place as the instant its date begins in the
        // series' zone, which it names on the series only (its range's `recurrenceTimeZone`); read
        // in that zone, its date is the place. Tokyo's date begins the day before in UTC; Los
        // Angeles' the same day.
        for (zone, windows) in [("Asia/Tokyo", "Tokyo Standard Time"), ("America/Los_Angeles", "Pacific Standard Time")] {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let date = GraphFixture.utcDay(GraphSplitFixture.occurrence)
            let series = Self.allDaySeries(zone: windows)
            var occurrence = GraphFixture.event(id: "ser-1-occ", start: GraphSplitFixture.occurrence, online: false,
                                                seriesMasterId: "ser-1", allDay: true)
            occurrence["originalStart"] = GraphFixture.allDayPlace(date, in: zone)
            let graph = FakeGraphCalendar([series, occurrence])
            graph.install(on: http)
            // In UTC, where `GraphFixture.event` renders an all-day occurrence's start.
            _ = try await GraphSplitFixture.provider(http).splitSeries(
                eventId: "ser-1", recurrenceId: date + "T00:00:00", recurrenceIdZone: .gmt, patch: GCalEventInput())
            #expect(graph.created.count == 1, "\(zone): no new part: \(http.servedCallSequence())")
        }
    }

    @Test("an all-day series in a zone TabMail does not recognize is split like any other: its occurrence's place is read in that zone as Graph names it, and needs no zone of TabMail's")
    func allDaySeriesInAZoneTabMailDoesNotRecognizeIsSplit() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let date = GraphFixture.utcDay(GraphSplitFixture.occurrence)
        // A zone the server knows by a name TabMail does not (here Kathmandu's, 5:45 ahead of UTC);
        // the occurrence is where its place puts it.
        let serverZone = "Custom Server Zone"
        let kathmandu = try #require(TimeZone(identifier: "Asia/Kathmandu"))
        #expect(CalendarTimeZoneResolver.zone(named: serverZone, in: .none) == nil, "TabMail recognizes the zone")
        var occurrence = GraphFixture.event(id: "ser-1-occ", start: GraphSplitFixture.occurrence, online: false,
                                            seriesMasterId: "ser-1", allDay: true)
        occurrence["originalStart"] = GraphFixture.allDayPlace(date, in: kathmandu.identifier)
        let graph = FakeGraphCalendar([Self.allDaySeries(zone: serverZone), occurrence], zones: [serverZone: kathmandu])
        graph.install(on: http)
        _ = try await GraphSplitFixture.provider(http).splitSeries(
            eventId: "ser-1", recurrenceId: date + "T00:00:00", recurrenceIdZone: .gmt, patch: GCalEventInput())
        #expect(graph.readZones("ser-1-occ") == [serverZone], "the occurrence was not read in the series' zone: \(graph.readZones("ser-1-occ"))")
        #expect(graph.created.count == 1, "no new part: \(http.servedCallSequence())")
    }

    @Test("an all-day series whose range names no zone is not split, and its occurrence is not read in another zone: a plain error with nothing written")
    func allDaySeriesWithoutARangeZoneIsRefused() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let date = GraphFixture.utcDay(GraphSplitFixture.occurrence)
        var series = Self.allDaySeries(zone: "Tokyo Standard Time")
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range.removeValue(forKey: "recurrenceTimeZone")
        recurrence["range"] = range
        series["recurrence"] = recurrence
        var occurrence = GraphFixture.event(id: "ser-1-occ", start: GraphSplitFixture.occurrence, online: false,
                                            seriesMasterId: "ser-1", allDay: true)
        occurrence["originalStart"] = GraphFixture.allDayPlace(date, in: "Asia/Tokyo")
        let graph = FakeGraphCalendar([series, occurrence])
        graph.install(on: http)
        var reason: String?
        do {
            _ = try await GraphSplitFixture.provider(http).splitSeries(
                eventId: "ser-1", recurrenceId: date + "T00:00:00", recurrenceIdZone: .gmt, patch: GCalEventInput())
        } catch CalendarProviderError.notSupported(let thrown) {
            reason = thrown
        }
        #expect(reason?.contains("Outlook gives no time zone for this all-day repeating event") == true, "refused by: \(reason ?? "not refused")")
        #expect(graph.readZones("ser-1-occ").isEmpty, "the occurrence was read in a zone the series does not name: \(graph.readZones("ser-1-occ"))")
        #expect(graph.created.isEmpty && graph.patches("ser-1").isEmpty, "written: \(http.servedCallSequence())")
    }

    @Test("an all-day series' occurrence is read in the series' own zone, as Graph names it: split at a plain one, a plain error with nothing written at a moved one, in zones ahead of UTC and behind it")
    func allDayOccurrenceIsReadInTheSeriesZone() async throws {
        // Measured on Graph: an all-day series every two days; a plain occurrence, and one moved a
        // day earlier. Read in the series' zone, `originalStart` is midnight there with its offset,
        // and its date is the occurrence's place; read in UTC it is the instant, the day before in
        // Tokyo and Kathmandu.
        let first = GraphFixture.utcDay(GraphSplitFixture.start)
        for (name, iana) in [("Tokyo Standard Time", "Asia/Tokyo"), ("Asia/Kathmandu", "Asia/Kathmandu"),
                             ("Pacific Standard Time", "America/Los_Angeles")] {
            for moved in [false, true] {
                let label = "\(name), \(moved ? "moved" : "plain")"
                let http = FakeHTTP.Scenario()
                defer { http.close() }
                // The plain one is on its place, the third date; the moved one's place is the fifth
                // date, and it is on the fourth.
                let place = try Self.date(first, plus: moved ? 4 : 2)
                let now = try Self.date(first, plus: moved ? 3 : 2)
                var occurrence = GraphFixture.event(id: "ser-1-occ", start: try Self.midnight(now), online: false,
                                                    seriesMasterId: "ser-1", allDay: true)
                occurrence["originalStart"] = GraphFixture.allDayPlace(place, in: iana)
                let graph = FakeGraphCalendar([try Self.everyTwoDays(from: first, zone: name), occurrence])
                graph.install(on: http)
                var reason: String?
                do {
                    _ = try await GraphSplitFixture.provider(http).splitSeries(
                        eventId: "ser-1", recurrenceId: now + "T00:00:00", recurrenceIdZone: .gmt, patch: GCalEventInput())
                } catch CalendarProviderError.notSupported(let thrown) {
                    reason = thrown
                }
                #expect(graph.readZones("ser-1-occ") == [name], "\(label): the occurrence was not read in the series' zone: \(graph.readZones("ser-1-occ"))")
                if moved {
                    #expect(reason == "split at a moved occurrence", "\(label): \(reason ?? "not refused")")
                    #expect(graph.created.isEmpty && graph.patches("ser-1").isEmpty, "\(label): written: \(http.servedCallSequence())")
                } else {
                    #expect(reason == nil, "\(label): refused: \(reason ?? "")")
                    #expect(graph.created.count == 1, "\(label): no new part: \(http.servedCallSequence())")
                }
            }
        }
    }

    /// `date` (`yyyy-MM-dd`) `days` later.
    private static func date(_ date: String, plus days: Int) throws -> String {
        GraphFixture.utcDay(try midnight(date).addingTimeInterval(Double(days) * 86_400))
    }

    /// UTC midnight of `date`, where `GraphFixture.event` puts an all-day event on that date.
    private static func midnight(_ date: String) throws -> Date {
        try #require(EKEventStoreHelper.parseNaiveISO(date, timeZone: .gmt))
    }

    /// An all-day series every two days from `first`, repeating in `zone` (the name Graph gives).
    private static func everyTwoDays(from first: String, zone: String) throws -> [String: Any] {
        var series = GraphFixture.event(id: "ser-1", start: try midnight(first), online: false, recurring: true, allDay: true)
        var recurrence = series["recurrence"] as? [String: Any] ?? [:]
        recurrence["pattern"] = ["type": "daily", "interval": 2, "month": 0, "dayOfMonth": 0,
                                 "firstDayOfWeek": "sunday", "index": "first"]
        var range = recurrence["range"] as? [String: Any] ?? [:]
        range["recurrenceTimeZone"] = zone
        range["startDate"] = first
        recurrence["range"] = range
        series["recurrence"] = recurrence
        return series
    }

    /// A weekly all-day series repeating in `zone` (a Windows zone name, as Graph's range gives it).
    private static func allDaySeries(zone: String) -> [String: Any] {
        var series = GraphFixture.event(id: "ser-1", start: GraphSplitFixture.start, online: false, recurring: true, allDay: true)
        var recurrence = series["recurrence"] as? [String: Any] ?? [:]
        var range = recurrence["range"] as? [String: Any] ?? [:]
        range["recurrenceTimeZone"] = zone
        recurrence["range"] = range
        series["recurrence"] = recurrence
        return series
    }
}

// MARK: - Outlook: a series that ends after a number of occurrences

/// A weekly Outlook series dated on the device: its start, its range (`startDate` and
/// `recurrenceTimeZone`, the device's IANA name, which Graph accepts for a range, measured) and the
/// split, so every date here is the same date in every frame whatever the host's zone.
private enum NumberedSplitFixture {
    static let zone = TimeZone.current.identifier

    /// 10:00 on the device eight days ahead: the first occurrence.
    static let base = GraphFixture.onDevice(days: 0, hour: 10)

    static func provider(_ http: FakeHTTP.Scenario) -> ExchangeCalendarProvider {
        ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" }, session: http.session)
    }

    /// `date`'s day of the week on the device, as Graph names it.
    static func weekday(_ date: Date) -> String {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        return names[Calendar(identifier: .gregorian).component(.weekday, from: date) - 1]
    }

    /// `date` moved by `days` calendar days on the device, its time of day kept.
    static func adding(days: Int, to date: Date) throws -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return try #require(cal.date(byAdding: .day, value: days, to: date))
    }

    /// The first Tuesday on or after `base`, at 10:00 on the device.
    static func firstTuesday() throws -> Date {
        for offset in 0..<7 {
            let day = try adding(days: offset, to: base)
            if weekday(day) == "tuesday" { return day }
        }
        Issue.record("no Tuesday in a week")
        return base
    }

    /// The first second Tuesday of a month on or after `base`, at 10:00 on the device.
    static func firstSecondTuesday() throws -> Date {
        let cal = Calendar(identifier: .gregorian)
        for offset in 0..<62 {
            let day = try adding(days: offset, to: base)
            if weekday(day) == "tuesday", (8...14).contains(cal.component(.day, from: day)) { return day }
        }
        Issue.record("no second Tuesday in two months")
        return base
    }

    /// A Graph pattern for the second Tuesday of every month.
    static var secondTuesdayMonthly: [String: Any] {
        ["type": "relativeMonthly", "interval": 1, "month": 0, "dayOfMonth": 0, "daysOfWeek": ["tuesday"],
         "firstDayOfWeek": "sunday", "index": "second"]
    }

    /// The first year after this one that is a leap year (`leap`) or a common one.
    static func nextYear(leap: Bool) -> Int {
        func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }
        var year = Calendar(identifier: .gregorian).component(.year, from: Date()) + 1
        while isLeap(year) != leap { year += 1 }
        return year
    }

    /// `yyyy-MM-dd` for `day` of `month` in `year`.
    static func date(_ year: Int, _ month: Int, _ day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 10:00 on the device on `day` (`yyyy-MM-dd`, a device date).
    static func tenOClock(_ day: String) throws -> Date {
        try #require(EKEventStoreHelper.parseNaiveISO(day + "T10:00:00", timeZone: .current))
    }

    /// A weekly series of `count` whose range starts on `rangeStart`'s date, as Graph stores it;
    /// `pattern`, when given, replaces the weekly pattern.
    static func series(rangeStart: Date, daysOfWeek: [String], interval: Int, firstDayOfWeek: String,
                       count: Int, rangeZone: String = zone, pattern: [String: Any]? = nil) -> [String: Any] {
        var e = GraphFixture.event(id: "ser-1", start: rangeStart, online: false, recurring: true)
        e["start"] = ["dateTime": GraphFixture.wall(rangeStart, in: zone) + ".0000000", "timeZone": zone]
        e["end"] = ["dateTime": GraphFixture.wall(rangeStart.addingTimeInterval(1_800), in: zone) + ".0000000", "timeZone": zone]
        e["recurrence"] = [
            "pattern": pattern ?? ["type": "weekly", "interval": interval, "month": 0, "dayOfMonth": 0, "daysOfWeek": daysOfWeek,
                                   "firstDayOfWeek": firstDayOfWeek, "index": "first"],
            // A numbered range reads `endDate` as "0001-01-01" (measured).
            "range": ["type": "numbered", "startDate": GraphFixture.deviceDay(rangeStart), "endDate": "0001-01-01",
                      "recurrenceTimeZone": rangeZone, "numberOfOccurrences": count],
        ]
        return e
    }

    /// The series' occurrence on `day`, as Graph lists it; `movedADay`: moved on its own to the
    /// next day, its place in the series (`originalStart`) kept.
    static func occurrence(_ index: Int, on day: String, movedADay: Bool = false) throws -> [String: Any] {
        let at = try tenOClock(day)
        var e = GraphFixture.event(id: "ser-1-occ-\(index)", start: at, online: false, seriesMasterId: "ser-1")
        if movedADay {
            let now = at.addingTimeInterval(86_400)
            e["start"] = ["dateTime": GraphFixture.naive(now), "timeZone": "UTC"]
            e["end"] = ["dateTime": GraphFixture.naive(now.addingTimeInterval(1_800)), "timeZone": "UTC"]
        }
        return e
    }
}

/// #474: an Outlook series that ends after a number of occurrences (a `numbered` range) is split
/// into two parts that hold exactly the series' occurrences: the capped series those before the
/// split, the new part (numbered with what is left) the rest, ending on the series' last occurrence.
/// Each test holds the parts to the series through `FakeGraphCalendar.rangeDays`, which applies a
/// range as Graph does, apart from the app's counter. Deleted and moved occurrences still count
/// toward the number (measured on Outlook), so a split after them leaves the same number.
@Suite("Outlook split of a numbered series", .serialized)
struct ExchangeNumberedSplitTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        var count = 6
        /// The occurrence the split is at, by its place in the series (0 is the first).
        var split = 3
        var deleted: Set<Int> = []
        var moved: Set<Int> = []
        /// The range starts the day before its first occurrence (Graph: "the first occurrence of the
        /// meeting may be this date or later").
        var rangeStartsTheDayBefore = false
        /// A series on Tuesday and Sunday every other week from a Tuesday, its weeks starting on
        /// this day; nil: a series every week on the first occurrence's day.
        var everyOtherWeekFrom: String?
        /// A series on the second Tuesday of every month (`relativeMonthly`).
        var secondTuesdayMonthly = false
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "a plain series"),
        Case(name: "an occurrence before the split deleted", split: 4, deleted: [2]),
        Case(name: "an occurrence before the split moved a day", split: 4, moved: [3]),
        Case(name: "one deleted and the next moved, as measured on Outlook", split: 4, deleted: [2], moved: [3]),
        Case(name: "the split at the last occurrence", split: 5),
        Case(name: "a range that starts the day before its first occurrence", rangeStartsTheDayBefore: true),
        Case(name: "every other week, weeks starting on Sunday", everyOtherWeekFrom: "sunday"),
        Case(name: "every other week, weeks starting on Monday", everyOtherWeekFrom: "monday"),
        Case(name: "the second Tuesday of every month", secondTuesdayMonthly: true),
        Case(name: "the second Tuesday of every month, its range starting the day before",
             rangeStartsTheDayBefore: true, secondTuesdayMonthly: true),
    ]

    @Test("the two parts hold the series' occurrences between them, the new part numbered with what is left", arguments: cases)
    func partsHoldTheSeries(_ c: Case) async throws {
        let first = try c.secondTuesdayMonthly ? NumberedSplitFixture.firstSecondTuesday()
            : c.everyOtherWeekFrom == nil ? NumberedSplitFixture.base : NumberedSplitFixture.firstTuesday()
        let rangeStart = try c.rangeStartsTheDayBefore ? NumberedSplitFixture.adding(days: -1, to: first) : first
        let series = NumberedSplitFixture.series(
            rangeStart: rangeStart,
            daysOfWeek: c.everyOtherWeekFrom == nil ? [NumberedSplitFixture.weekday(first)] : ["tuesday", "sunday"],
            interval: c.everyOtherWeekFrom == nil ? 1 : 2,
            firstDayOfWeek: c.everyOtherWeekFrom ?? "sunday",
            count: c.count,
            pattern: c.secondTuesdayMonthly ? NumberedSplitFixture.secondTuesdayMonthly : nil)
        let original = try #require(FakeGraphCalendar.rangeDays(series))
        #expect(original.count == c.count, "\(c.name): setup: \(original)")
        guard original.count == c.count, original.first == GraphFixture.deviceDay(first) else {
            Issue.record("\(c.name): setup: the series does not start on its first occurrence: \(original)")
            return
        }
        var seed = [series]
        for (index, day) in original.enumerated() where !c.deleted.contains(index) {
            seed.append(try NumberedSplitFixture.occurrence(index, on: day, movedADay: c.moved.contains(index)))
        }
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar(seed)
        graph.install(on: http)
        let recurrenceId = GraphFixture.wall(try NumberedSplitFixture.tenOClock(original[c.split]), in: NumberedSplitFixture.zone)
        _ = try await NumberedSplitFixture.provider(http).splitSeries(
            eventId: "ser-1", recurrenceId: recurrenceId, recurrenceIdZone: .current, patch: GCalEventInput())

        let created = try #require(graph.created.first, "\(c.name): no new part: \(http.servedCallSequence())")
        let range = (created["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        let newPart = try #require(FakeGraphCalendar.rangeDays(created), "\(c.name): the new part has no end: \(canonical(range))")
        let capped = try #require(graph.rangeDays(of: "ser-1"), "\(c.name): the series was not capped: \(canonical(graph.event("ser-1")?["recurrence"]))")
        #expect(capped.count + newPart.count == c.count,
                "\(c.name): \(capped.count) + \(newPart.count) occurrences, not the series' \(c.count)")
        #expect(capped + newPart == original, "\(c.name): capped \(capped) and new \(newPart), not the series' \(original)")
        #expect(range?["type"] as? String == "numbered" && range?["endDate"] == nil, "\(c.name): \(canonical(range))")
    }

    struct AllDayCase: CustomTestStringConvertible, Sendable {
        let name: String
        /// The range's `recurrenceTimeZone` as Graph names it, and the same zone's IANA name.
        let rangeZone: String
        let ianaZone: String
        let interval: Int
        var testDescription: String { name }
    }

    /// The split is declared at midnight UTC. Read in a zone behind UTC that instant is the day
    /// before, which a daily series counts as one fewer occurrence before the split; so only the
    /// date, never a zone, may place an all-day split.
    @Test("an all-day series is split at its date, whatever zone the series repeats in", arguments: [
        AllDayCase(name: "every other day, in a zone ahead of UTC", rangeZone: "Tokyo Standard Time", ianaZone: "Asia/Tokyo", interval: 2),
        AllDayCase(name: "every day, in a zone behind UTC", rangeZone: "Pacific Standard Time", ianaZone: "America/Los_Angeles", interval: 1),
    ])
    func allDaySeries(_ c: AllDayCase) async throws {
        let first = GraphFixture.utcDay(GraphFixture.start)
        let midnight = try #require(EKEventStoreHelper.parseNaiveISO(first, timeZone: .gmt))
        var series = GraphFixture.event(id: "ser-1", start: midnight, online: false, recurring: true, allDay: true)
        series["recurrence"] = [
            "pattern": ["type": "daily", "interval": c.interval, "month": 0, "dayOfMonth": 0, "firstDayOfWeek": "sunday", "index": "first"],
            "range": ["type": "numbered", "startDate": first, "endDate": "0001-01-01",
                      "recurrenceTimeZone": c.rangeZone, "numberOfOccurrences": 6],
        ]
        let original = try #require(FakeGraphCalendar.rangeDays(series))
        #expect(original.count == 6, "setup: \(original)")
        guard original.count == 6 else { return }
        let day = original[2]
        var occurrence = GraphFixture.event(id: "ser-1-occ", start: try #require(EKEventStoreHelper.parseNaiveISO(day, timeZone: .gmt)),
                                            online: false, seriesMasterId: "ser-1", allDay: true)
        occurrence["originalStart"] = GraphFixture.allDayPlace(day, in: c.ianaZone)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([series, occurrence])
        graph.install(on: http)
        _ = try await NumberedSplitFixture.provider(http).splitSeries(
            eventId: "ser-1", recurrenceId: day + "T00:00:00", recurrenceIdZone: .gmt, patch: GCalEventInput())

        let created = try #require(graph.created.first, "\(c.name): no new part: \(http.servedCallSequence())")
        let range = (created["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        let newPart = try #require(FakeGraphCalendar.rangeDays(created), "\(c.name): the new part has no end: \(canonical(range))")
        let capped = try #require(graph.rangeDays(of: "ser-1"))
        #expect(capped + newPart == original, "\(c.name): capped \(capped) and new \(newPart), not the series' \(original)")
    }

    /// The two shapes measured on Outlook, where a month lacks the pattern's day.
    enum MonthEnd: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case monthlyOn31st = "monthly on the 31st, split after February"
        case yearlyOnLeapDay = "yearly on February 29, split at the second common year"
        var testDescription: String { rawValue }
    }

    /// Outlook holds an occurrence a month lacks on the month's last day, and it counts toward the
    /// number (measured), so a split after a short month leaves the new part the number less the
    /// occurrences before it, month ends included. The fake's own expansion first reproduces the
    /// measured shape, from the next common year (monthly) or leap year (yearly).
    @Test("a split after a short month leaves the new part what is left, the month's last day counted", arguments: MonthEnd.allCases)
    func monthEndSeries(_ shape: MonthEnd) async throws {
        let measured: [String]
        let pattern: [String: Any]
        switch shape {
        case .monthlyOn31st:
            let y = NumberedSplitFixture.nextYear(leap: false)
            measured = [NumberedSplitFixture.date(y, 1, 31), NumberedSplitFixture.date(y, 2, 28),
                        NumberedSplitFixture.date(y, 3, 31), NumberedSplitFixture.date(y, 4, 30)]
            pattern = ["type": "absoluteMonthly", "interval": 1, "month": 0, "dayOfMonth": 31, "daysOfWeek": [String](),
                       "firstDayOfWeek": "sunday", "index": "first"]
        case .yearlyOnLeapDay:
            let leap = NumberedSplitFixture.nextYear(leap: true)
            measured = [NumberedSplitFixture.date(leap, 2, 29), NumberedSplitFixture.date(leap + 1, 2, 28),
                        NumberedSplitFixture.date(leap + 2, 2, 28)]
            pattern = ["type": "absoluteYearly", "interval": 1, "month": 2, "dayOfMonth": 29, "daysOfWeek": [String](),
                       "firstDayOfWeek": "sunday", "index": "first"]
        }
        // The split is at the third occurrence: two come before it, one of them a month end.
        let split = 2
        let series = NumberedSplitFixture.series(
            rangeStart: try NumberedSplitFixture.tenOClock(measured[0]), daysOfWeek: [], interval: 1,
            firstDayOfWeek: "sunday", count: measured.count, pattern: pattern)
        let original = try #require(FakeGraphCalendar.rangeDays(series))
        #expect(original == measured, "\(shape): setup: the fake's expansion is not the measured one: \(original)")
        guard original == measured else { return }
        var seed = [series]
        for (index, day) in original.enumerated() { seed.append(try NumberedSplitFixture.occurrence(index, on: day)) }
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar(seed)
        graph.install(on: http)
        let recurrenceId = GraphFixture.wall(try NumberedSplitFixture.tenOClock(original[split]), in: NumberedSplitFixture.zone)
        _ = try await NumberedSplitFixture.provider(http).splitSeries(
            eventId: "ser-1", recurrenceId: recurrenceId, recurrenceIdZone: .current, patch: GCalEventInput())

        let created = try #require(graph.created.first, "\(shape): no new part: \(http.servedCallSequence())")
        let range = (created["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(range?["numberOfOccurrences"] as? Int == measured.count - split,
                "\(shape): the new part is not numbered with what is left: \(canonical(range))")
        let newPart = try #require(FakeGraphCalendar.rangeDays(created), "\(shape): the new part has no end: \(canonical(range))")
        let capped = try #require(graph.rangeDays(of: "ser-1"), "\(shape): the series was not capped")
        #expect(capped + newPart == original, "\(shape): capped \(capped) and new \(newPart), not the series' \(original)")
    }

    @Test("a split that leaves no occurrence of the number, or can't count them, writes nothing", arguments: [
        "no occurrence left", "a range zone TabMail does not recognize",
    ])
    func refusedWithNothingWritten(_ label: String) async throws {
        let first = NumberedSplitFixture.base
        let weekday = NumberedSplitFixture.weekday(first)
        var series = NumberedSplitFixture.series(rangeStart: first, daysOfWeek: [weekday], interval: 1, firstDayOfWeek: "sunday", count: 3)
        // The occurrences as listed: one past the series' three when nothing is left, which stands
        // for a count that disagrees with the listing; the split must then write nothing rather
        // than a part that runs on.
        let listed = try #require(FakeGraphCalendar.rangeDays(
            NumberedSplitFixture.series(rangeStart: first, daysOfWeek: [weekday], interval: 1, firstDayOfWeek: "sunday", count: 4)))
        var split = 3
        if label == "a range zone TabMail does not recognize" {
            series = NumberedSplitFixture.series(rangeStart: first, daysOfWeek: [weekday], interval: 1, firstDayOfWeek: "sunday",
                                                 count: 3, rangeZone: "Not A Zone Standard Time")
            split = 1
        }
        var seed = [series]
        for (index, day) in listed.enumerated() { seed.append(try NumberedSplitFixture.occurrence(index, on: day)) }
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar(seed)
        graph.install(on: http)
        let recurrenceId = GraphFixture.wall(try NumberedSplitFixture.tenOClock(listed[split]), in: NumberedSplitFixture.zone)
        var reason: String?
        do {
            _ = try await NumberedSplitFixture.provider(http).splitSeries(
                eventId: "ser-1", recurrenceId: recurrenceId, recurrenceIdZone: .current, patch: GCalEventInput())
        } catch CalendarProviderError.notSupported(let message) {
            reason = message
        }
        #expect(reason?.isEmpty == false, "\(label): not refused: \(http.servedCallSequence())")
        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "\(label): written: \(http.servedCallSequence())")
        #expect(graph.created.isEmpty, "\(label): a new part was created")
        #expect(canonical(graph.event("ser-1")?["recurrence"]) == canonical(series["recurrence"]), "\(label): the series was changed")
    }
}
