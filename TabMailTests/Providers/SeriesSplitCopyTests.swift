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
        // The series' exceptions, read by a split that carries them (#563): none.
        http.register(path: createPath, method: "GET", response: .raw(statusCode: 200, headers: ok, body: instances([])))
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

    @Test("a new rule on the new part resets its excluded dates and keeps its added dates after the split (#563)")
    func newRuleResetsTheTailExcludedDates() async throws {
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE"]
        let wire = try await GoogleSplitFixture.split(GoogleSplitFixture.master(), patch: patch)
        // A new rule resets the occurrences deleted one by one, as Google Calendar does.
        #expect(wire.created?["recurrence"] as? [String] == [
            "RRULE:FREQ=WEEKLY;BYDAY=MO,WE", "RDATE:20990529T170000Z",
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
            // The series lists the occurrence at the split until the cap ends it before it.
            let capped = server.withLock { state in
                (state.master["recurrence"] as? [String] ?? []).contains { $0.contains("UNTIL=20990520T165959Z") }
            }
            return .raw(statusCode: 200, headers: ok,
                        body: GoogleSplitFixture.instances(capped ? [] : [GoogleSplitFixture.occurrence(GoogleSplitFixture.recurrenceId)]))
        }
        http.register(path: GoogleSplitFixture.createPath, method: "GET",
                      response: .raw(statusCode: 200, headers: ok, body: GoogleSplitFixture.instances([])))
        http.register(path: GoogleSplitFixture.createPath + "/", method: "GET") { request in
            let id = String(request.url.path.split(separator: "/").last ?? "")
            guard let event = server.withLock({ state in state.created[id].map { json($0) } }) else { return .raw(statusCode: 404) }
            return .raw(statusCode: 200, headers: ok, body: event)
        }
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        let records = SplitRecordBox()

        await #expect(throws: (any Error).self) {
            _ = try await provider.splitSeries(
                calendarId: "primary", eventId: "master-1", recurrenceId: GoogleSplitFixture.recurrenceId,
                recurrenceIdZone: GoogleSplitFixture.utc, patch: GCalEventInput(), sendUpdates: "all",
                record: records.recorder)
        }
        let writes = http.recordedCalls().map(\.method).filter { $0 != "GET" }
        #expect(writes == ["POST", "PATCH"], "the new part must be created before the cap: \(writes)")
        // The retry, as the queue runs it once the split's record is kept: the new part is still
        // there, so only the cap is finished.
        let record = try #require(records.records.first, "the split kept no record before its cap")
        #expect(try await provider.eventExists(calendarId: "primary", eventId: record.newPartId))
        try await provider.finishSplit(calendarId: "primary", record: record, zone: GoogleSplitFixture.utc, guests: nil)
        let retryWrites = http.recordedCalls().map(\.method).filter { $0 != "GET" }.dropFirst(writes.count)
        #expect(!retryWrites.contains("POST"), "the retry wrote the new part again: \(Array(retryWrites))")

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
        http.register(path: GoogleSplitFixture.masterPath + "/instances", method: "GET", response: .raw(
            statusCode: 200, headers: ok, body: GoogleSplitFixture.instances([GoogleSplitFixture.occurrence(GoogleSplitFixture.recurrenceId)])))
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

@Suite("Outlook split carries the occurrences after it changed or deleted one by one (#563)", .serialized)
struct ExchangeSplitCarryTests {
    /// The occurrence `weeks` after the series' first, at 10:00 on the device.
    private static func week(_ weeks: Int, hour: Int = 10, plusDays: Int = 0) -> Date {
        GraphFixture.onDevice(days: 7 * weeks + plusDays, hour: hour)
    }

    /// An exception of `ser-1` at week `place`, now at `at`.
    private static func exception(_ place: Int, at: Date? = nil, edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var e = GraphFixture.event(id: "ser-1-occ-\(place)", start: at ?? week(place), online: false, seriesMasterId: "ser-1")
        e["originalStart"] = GraphFixture.rfc3339(week(place))
        edit(&e)
        return e
    }

    /// A calendar holding `events`, where the new part a split creates lists its occurrences at the
    /// series' weeks `parts` (`partOccurrences`).
    static func calendar(_ events: [[String: Any]], parts: [Int]) -> FakeGraphCalendar {
        let graph = FakeGraphCalendar(events)
        graph.occurrencesOnCreate { partOccurrences($0, weeks: parts) }
        return graph
    }

    /// The occurrences of the new part `created` (`<id>-w<week>`) at the series' weeks `weeks`
    /// (counted from its first occurrence), where the part as created places them, as Graph lists
    /// them once it is made: its pattern applied from its range's start
    /// (`FakeGraphCalendar.rangeDays`, to the range's end date or number), at its own time of day
    /// in the zone it repeats in (its range's, else its start's). A new part moved, repeating on other days, or of the other kind
    /// has its occurrences where it says, not at the series' places.
    static func partOccurrences(_ created: [String: Any], weeks: [Int]) -> [[String: Any]] {
        guard let id = created["id"] as? String, var recurrence = created["recurrence"] as? [String: Any],
              var range = recurrence["range"] as? [String: Any] else { return [] }
        // A range with no end lists as far as the weeks asked for go; one with an end ends there.
        if range["type"] as? String != "numbered", range["type"] as? String != "endDate" {
            range["type"] = "numbered"
            range["numberOfOccurrences"] = 60
        }
        recurrence["range"] = range
        var counted = created
        counted["recurrence"] = recurrence
        let allDay = created["isAllDay"] as? Bool == true
        let zoneName = range["recurrenceTimeZone"] as? String ?? (created["start"] as? [String: Any])?["timeZone"] as? String ?? "UTC"
        guard let days = FakeGraphCalendar.rangeDays(counted),
              let zone = CalendarTimeZoneResolver.zone(named: zoneName, in: .none),
              let start = instant(created["start"]) else { return [] }
        let time = GraphFixture.wall(start, in: zone.identifier).dropFirst(11)
        return days.compactMap { day in
            guard let at = allDay ? EKEventStoreHelper.parseNaiveISO(day, timeZone: .gmt)
                                  : EKEventStoreHelper.parseNaiveISO("\(day)T\(time)", timeZone: zone) else { return nil }
            let week = Int((at.timeIntervalSince(Self.week(0)) / (7 * 86_400)).rounded())
            guard weeks.contains(week) else { return nil }
            return GraphFixture.event(id: "\(id)-w\(week)", start: at, online: false, seriesMasterId: id, allDay: allDay)
        }
    }

    struct Run {
        let graph: FakeGraphCalendar
        let http: FakeHTTP.Scenario
        let provider: ExchangeCalendarProvider
        let records: SplitRecordBox
        let error: Error?
    }

    /// Splits `ser-1` at week 1 with `patch`. `exceptions` are its changed occurrences (as Graph
    /// expands them), `cancelled` the weeks deleted one by one (and `cancelledOn`, any other days),
    /// `parts` the new part's occurrences.
    private func split(
        exceptions: [[String: Any]], cancelled: [Int] = [], cancelledOn: [Date] = [], parts: [Int], patch: GCalEventInput,
        series: [String: Any] = GraphSplitFixture.series(range: GraphSplitFixture.noEnd),
        configure: (FakeGraphCalendar, FakeHTTP.Scenario) -> Void = { _, _ in }
    ) async throws -> Run {
        let graph = Self.calendar([series, GraphFixture.event(id: "ser-1-occ", start: GraphSplitFixture.occurrence, online: false,
                                                              seriesMasterId: "ser-1")] + exceptions, parts: parts)
        let http = FakeHTTP.Scenario()
        graph.install(on: http)
        let ok = ["Content-Type": "application/json"]
        var expanded = series
        expanded["exceptionOccurrences"] = exceptions
        http.register(path: "/v1.0/me/events/ser-1?$expand=exceptionOccurrences", method: "GET",
                      response: .raw(statusCode: 200, headers: ok, body: try JSONSerialization.data(withJSONObject: expanded)))
        let names = ["cancelledOccurrences": (cancelled.map { Self.week($0) } + cancelledOn).map { "OID.ser-1.\(GraphFixture.deviceDay($0))" }]
        http.register(path: "/v1.0/me/events/ser-1?$select=cancelledOccurrences", method: "GET",
                      response: .raw(statusCode: 200, headers: ok, body: try JSONSerialization.data(withJSONObject: names)))
        configure(graph, http)
        let provider = GraphSplitFixture.provider(http)
        let records = SplitRecordBox()
        var thrown: Error?
        do {
            _ = try await provider.splitSeries(
                eventId: "ser-1", recurrenceId: GraphSplitFixture.recurrenceId, recurrenceIdZone: .current, patch: patch,
                record: records.recorder)
        } catch {
            thrown = error
        }
        return Run(graph: graph, http: http, provider: provider, records: records, error: thrown)
    }

    /// Splits `ser-1` named at its exception `named` (one of `exceptions`), which starts at `start`
    /// now, read in `zone`.
    private func split(
        named: String, start: Date, exceptions: [[String: Any]], parts: [Int], patch: GCalEventInput,
        series: [String: Any] = GraphSplitFixture.series(range: GraphSplitFixture.noEnd), graph given: FakeGraphCalendar? = nil,
        zone: TimeZone = .current
    ) async throws -> Run {
        let graph = given ?? Self.calendar([series] + exceptions, parts: parts)
        let http = FakeHTTP.Scenario()
        graph.install(on: http)
        let ok = ["Content-Type": "application/json"]
        // The exceptions as the calendar holds them at each read, so a retry reads what was written.
        let ids = exceptions.compactMap { $0["id"] as? String }
        let stored = try JSONSerialization.data(withJSONObject: series)
        http.register(path: "/v1.0/me/events/ser-1?$expand=exceptionOccurrences", method: "GET") { _ in
            // swiftlint:disable:next force_cast force_try
            var expanded = try! JSONSerialization.jsonObject(with: stored) as! [String: Any]
            expanded["exceptionOccurrences"] = ids.compactMap(graph.event)
            // swiftlint:disable:next force_try
            return .raw(statusCode: 200, headers: ok, body: try! JSONSerialization.data(withJSONObject: expanded))
        }
        http.register(path: "/v1.0/me/events/ser-1?$select=cancelledOccurrences", method: "GET",
                      response: .raw(statusCode: 200, headers: ok, body: try JSONSerialization.data(withJSONObject: ["cancelledOccurrences": [String]()])))
        let provider = GraphSplitFixture.provider(http)
        let records = SplitRecordBox()
        var thrown: Error?
        do {
            _ = try await provider.splitSeries(
                eventId: named, recurrenceId: GraphFixture.wall(start, in: zone.identifier), recurrenceIdZone: zone,
                patch: patch, record: records.recorder)
        } catch {
            thrown = error
        }
        return Run(graph: graph, http: http, provider: provider, records: records, error: thrown)
    }

    /// The instant a Graph `start` names.
    private static func instant(_ value: Any?) -> Date? {
        guard let time = value as? [String: Any], let wall = time["dateTime"] as? String,
              let zone = (time["timeZone"] as? String).flatMap({ CalendarTimeZoneResolver.zone(named: $0, in: .none) }) else { return nil }
        return EKEventStoreHelper.parseNaiveISO(String(wall.prefix(19)), timeZone: zone)
    }

    @Test("a split named at a moved occurrence edits it and what is shown after it where they are, and keeps what is shown before it whole (owner rule)")
    func movedSplitChangesWhatIsShownAfter() async throws {
        // Week 1's occurrence moved two days on: the cut is week 2.
        let named = Self.exception(1, at: Self.week(1, plusDays: 2))
        let movedOut = Self.exception(0, at: Self.week(1, plusDays: 3))   // earlier place, shown after
        let movedIn = Self.exception(3, at: Self.week(1, plusDays: 1))    // later place, shown before
        let later = Self.exception(4) { $0["location"] = ["displayName": "Room 9"] }
        let r = try await split(named: "ser-1-occ-1", start: Self.week(1, plusDays: 2), exceptions: [named, movedOut, movedIn, later],
                                parts: [2, 3, 4], patch: Self.rename)
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error)); \(r.http.servedCallSequence())")
        #expect(Self.instant(r.graph.created.first?["start"]) == Self.week(2), "the new part does not start at week 2: \(r.graph.created.first?["start"] ?? "none")")
        #expect(r.graph.event("ser-1-occ-1")?["subject"] as? String == "Renamed", "the named occurrence was not edited where it is")
        #expect(r.graph.event("ser-1-occ-0")?["subject"] as? String == "Renamed", "an occurrence shown after the named one was not edited")
        let kept = r.graph.event("created-1-w3")
        #expect(kept?["subject"] as? String != "Renamed" && Self.instant(kept?["start"]) == Self.week(1, plusDays: 1),
                "an occurrence shown before the named one changed: \(kept ?? [:])")
        let carried = r.graph.event("created-1-w4")
        // The new part holds the title; the carry writes the occurrence's own room and never its old title.
        #expect(Self.displayName(carried?["location"]) == "Room 9", "\(carried ?? [:])")
        #expect(r.graph.patches("created-1-w4").allSatisfy { $0["subject"] == nil }, "the carry wrote the old title: \(r.graph.patches("created-1-w4"))")
        #expect(!r.graph.patches("ser-1").isEmpty, "the series was not capped")
    }

    @Test("a split named at a moved occurrence ends the series the day before the CUT's day in the series' zone, never before the occurrence's original place (owner rule A, #681)")
    func movedSplitCapsBeforeTheCut() async throws {
        // Week 1's occurrence moved two days on: the cut is week 2, its original place week 1.
        let named = Self.exception(1, at: Self.week(1, plusDays: 2))
        let r = try await split(named: "ser-1-occ-1", start: Self.week(1, plusDays: 2), exceptions: [named], parts: [2], patch: Self.rename)
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error)); \(r.http.servedCallSequence())")
        let range = try #require((r.graph.event("ser-1")?["recurrence"] as? [String: Any])?["range"] as? [String: Any])
        let atCut = GraphFixture.capEndDate(GraphFixture.wall(Self.week(2), in: GraphSplitFixture.zone), zone: .current, keptIn: "Pacific Standard Time")
        let atPlace = GraphFixture.capEndDate(GraphFixture.wall(Self.week(1), in: GraphSplitFixture.zone), zone: .current, keptIn: "Pacific Standard Time")
        #expect(atCut != nil && atCut != atPlace, "non-vacuity: the cut and the original place cap alike")
        #expect(range["type"] as? String == "endDate" && range["endDate"] as? String == atCut,
                "the cap is not the day before the cut: \(range); \(r.http.servedCallSequence())")
    }

    @Test("a new start at a moved occurrence moves it where it is and the new part by the same amount (owner rule b, c)")
    func movedSplitResetShifts() async throws {
        let named = Self.exception(1, at: Self.week(1, plusDays: 2))
        let movedIn = Self.exception(3, at: Self.week(1, plusDays: 1))
        var patch = GCalEventInput()
        patch.startDateTime = Self.week(1, plusDays: 2).addingTimeInterval(3_600).iso8601String()
        patch.startTimeZone = "UTC"
        let r = try await split(named: "ser-1-occ-1", start: Self.week(1, plusDays: 2), exceptions: [named, movedIn],
                                parts: [2, 3], patch: patch)
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error)); \(r.http.servedCallSequence())")
        #expect(Self.instant(r.graph.created.first?["start"]) == Self.week(2).addingTimeInterval(3_600),
                "the new part: \(r.graph.created.first?["start"] ?? "none")")
        #expect(Self.instant(r.graph.event("ser-1-occ-1")?["start"]) == Self.week(1, plusDays: 2).addingTimeInterval(3_600),
                "the named occurrence did not move: \(r.graph.event("ser-1-occ-1") ?? [:])")
        #expect(Self.instant(r.graph.event("created-1-w3")?["start"]) == Self.week(1, plusDays: 1), "the kept occurrence moved")
    }

    /// How a split's new part moves from the cut (C1): not at all, by an hour (a typed start), or to
    /// the next day with its days turned (`ruleDayMove`).
    enum Shift: String, CaseIterable { case none, typed, dayTurn }
    /// The changed occurrence a split carries or leaves (C1): one shown before the one named but
    /// placed after the cut (`Parts.kept`), the one named as it is, the one named moved earlier
    /// onto the cut's week, and one shown after the one named but placed before the cut
    /// (`Parts.edited`).
    enum Carried: String, CaseIterable { case kept, named, namedMovedEarlier, edited }

    /// The occurrence named (its id and where it starts now), and the series' exceptions, for `carried`.
    private static func scenario(_ carried: Carried) -> (named: String, start: Date, exceptions: [[String: Any]], kept: Date?) {
        switch carried {
        case .kept:
            return ("ser-1-occ-2", week(2), [exception(2), exception(3, at: week(1, plusDays: 6))], week(1, plusDays: 6))
        case .named:
            return ("ser-1-occ-2", week(2), [exception(2)], nil)
        case .namedMovedEarlier:
            return ("ser-1-occ-3", week(2, plusDays: 3), [exception(3, at: week(2, plusDays: 3))], nil)
        case .edited:
            return ("ser-1-occ-2", week(2), [exception(2), exception(1, at: week(2, plusDays: 1))], nil)
        }
    }

    /// The RFC 5545 weekday code of `date`'s day in the series' zone.
    private static func weekdayCode(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = CalendarTimeZoneResolver.zone(named: "Pacific Standard Time", in: .none) ?? .gmt
        return ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][cal.component(.weekday, from: date) - 1]
    }

    /// `date`'s day in the series' zone.
    private static func seriesDay(_ date: Date) -> String {
        GraphFixture.wall(date, in: (CalendarTimeZoneResolver.zone(named: "Pacific Standard Time", in: .none) ?? .gmt).identifier).prefix(10).description
    }

    /// How the series ends (C1, N1): never, or with week 3 (the place the kept occurrence is placed
    /// at) by an end date or by a number of occurrences.
    enum End: String, CaseIterable { case none, until, count }

    /// The series' range for `end`: an end date is the day of week 3 in the range's zone.
    private static func range(_ end: End) -> [String: Any] {
        switch end {
        case .none: return GraphSplitFixture.noEnd
        case .until: return ["type": "endDate", "endDate": seriesDay(week(3)), "numberOfOccurrences": 0]
        case .count: return ["type": "numbered", "endDate": "0001-01-01", "numberOfOccurrences": 4]
        }
    }

    @Test("C1: a carried occurrence lands on an occurrence the new part has, or the split is refused or reset before the create, for every shift, rule, kind, end and carried occurrence")
    func carriedOccurrencesLandOrRefuseBeforeTheCreate() async throws {
        var landed = 0
        for shift in Shift.allCases {
            for newRule in [false, true] {
                for kindChange in [false, true] {
                    // A change of kind moves the new part by whole days: a typed hour is no shift of its own.
                    if kindChange, shift == .typed { continue }
                    for carried in Carried.allCases {
                    for end in End.allCases {
                        let label = "\(shift.rawValue) newRule=\(newRule) kindChange=\(kindChange) \(carried.rawValue) end=\(end.rawValue)"
                        let scene = Self.scenario(carried)
                        var target = scene.start
                        if shift == .typed { target = target.addingTimeInterval(3_600) }
                        if shift == .dayTurn { target = target.addingTimeInterval(86_400) }
                        var patch = Self.rename
                        if kindChange {
                            patch.startDate = Self.seriesDay(target)
                            patch.endDate = Self.seriesDay(target.addingTimeInterval(86_400))
                        } else if shift != .none {
                            patch.startDateTime = target.iso8601String()
                            patch.startTimeZone = "UTC"
                        }
                        if newRule {
                            patch.recurrence = ["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=\(Self.weekdayCode(target))"]
                        } else if shift == .dayTurn,
                                  let from = RecurrenceTail.Day(iso: Self.seriesDay(scene.start)), let to = RecurrenceTail.Day(iso: Self.seriesDay(target)) {
                            patch.ruleDayMove = RecurrenceDayShift.Move(from: from, to: to)
                        }
                        let r = try await split(named: scene.named, start: scene.start, exceptions: scene.exceptions,
                                                parts: Array(0...8), patch: patch, series: GraphSplitFixture.series(range: Self.range(end)))
                        defer { r.http.close() }
                        // THE property: no write of the split fails after the new part is created.
                        if let error = r.error {
                            #expect(r.graph.created.isEmpty, "\(label): refused AFTER the create: \(error); \(r.http.servedCallSequence())")
                        }
                        // What each case comes to (the owner's rules): a kept occurrence with no
                        // occurrence on the new part refuses, a turned day moving it past the end
                        // date among them (N1: an end date takes its whole day, so a typed hour
                        // does not; a number moves with the part); a change of kind with one left
                        // on the old part refuses; everything else is written.
                        let pastEnd = end == .until && shift == .dayTurn
                        let refusal: String? = carried == .kept && (newRule || kindChange || pastEnd) ? SplitCarry.keptHasNoSlotRefusal
                            : carried == .edited && kindChange ? SplitCarry.editedKindRefusal : nil
                        if let refusal {
                            guard case CalendarProviderError.notSupported(let message)? = r.error else {
                                Issue.record("\(label): not refused: \(String(describing: r.error))")
                                continue
                            }
                            #expect(message == refusal, "\(label): \(message)")
                            continue
                        }
                        // The one named moved earlier onto the series' last week, its new part
                        // moved a day past the end date: THE property above is all that is asked.
                        if pastEnd, carried == .namedMovedEarlier { continue }
                        #expect(r.error == nil, "\(label): \(String(describing: r.error)); \(r.http.servedCallSequence())")
                        guard r.error == nil else { continue }
                        landed += 1
                        #expect(!r.graph.patches("ser-1").isEmpty, "\(label): the series was not capped")
                        if let shown = scene.kept {
                            // Shown before the one named: it still shows where it did, on the new part.
                            let kept = r.graph.event("created-1-w3")
                            #expect(Self.instant(kept?["start"]) == shown, "\(label): the kept occurrence: \(kept ?? [:])")
                        }
                    }
                    }
                }
            }
        }
        #expect(landed >= 60, "non-vacuity: only \(landed) splits were written")
    }

    @Test("C1: a typed start and a new rule with a kept occurrence and a named one moved earlier: written on the new part's own occurrences, or refused before the create")
    func resetCarriesOntoTheNewPartsOccurrences() async throws {
        // A typed start: the kept occurrence stays where it shows, on the occurrence an hour on.
        var typed = Self.rename
        typed.startDateTime = Self.week(2).addingTimeInterval(3_600).iso8601String()
        typed.startTimeZone = "UTC"
        let kept = Self.scenario(.kept)
        let a = try await split(named: kept.named, start: kept.start, exceptions: kept.exceptions, parts: [2, 3, 4], patch: typed)
        defer { a.http.close() }
        #expect(a.error == nil, "\(String(describing: a.error)); \(a.http.servedCallSequence())")
        #expect(Self.instant(a.graph.event("created-1-w3")?["start"]) == Self.week(1, plusDays: 6), "\(a.graph.event("created-1-w3") ?? [:])")
        // The named one moved earlier: it starts an hour on from where it is, on the new part's first occurrence.
        let moved = Self.scenario(.namedMovedEarlier)
        var typedMoved = Self.rename
        typedMoved.startDateTime = moved.start.addingTimeInterval(3_600).iso8601String()
        typedMoved.startTimeZone = "UTC"
        let b = try await split(named: moved.named, start: moved.start, exceptions: moved.exceptions, parts: [3, 4], patch: typedMoved)
        defer { b.http.close() }
        #expect(b.error == nil, "\(String(describing: b.error)); \(b.http.servedCallSequence())")
        #expect(Self.instant(b.graph.event("created-1-w3")?["start"]) == moved.start.addingTimeInterval(3_600), "\(b.graph.event("created-1-w3") ?? [:])")
        // A new rule every other week: the kept one has no occurrence there: refused, nothing created.
        var fortnightly = Self.rename
        fortnightly.recurrence = ["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=\(Self.weekdayCode(Self.week(2)))"]
        let c = try await split(named: kept.named, start: kept.start, exceptions: kept.exceptions, parts: [2, 3, 4], patch: fortnightly)
        defer { c.http.close() }
        #expect(c.graph.created.isEmpty, "created: \(c.graph.created.count)")
        if case CalendarProviderError.notSupported(let message)? = c.error {
            #expect(message == SplitCarry.keptHasNoSlotRefusal, "\(message)")
        } else {
            Issue.record("not refused: \(String(describing: c.error))")
        }
        // The named one moved earlier under the new rule: it is the new part's first occurrence, carried there.
        let d = try await split(named: moved.named, start: moved.start, exceptions: moved.exceptions, parts: [3, 4, 5], patch: fortnightly)
        defer { d.http.close() }
        #expect(d.error == nil, "\(String(describing: d.error)); \(d.http.servedCallSequence())")
    }

    @Test("N1: a kept occurrence at the series' last place, the new part moved a day on past the end date, is refused before the create, not missed after it")
    func keptAtTheLastPlaceUnderAnEndDateRefusesBeforeTheCreate() async throws {
        let scene = Self.scenario(.kept)
        var patch = Self.rename
        let target = scene.start.addingTimeInterval(86_400)
        patch.startDateTime = target.iso8601String()
        patch.startTimeZone = "UTC"
        if let from = RecurrenceTail.Day(iso: Self.seriesDay(scene.start)), let to = RecurrenceTail.Day(iso: Self.seriesDay(target)) {
            patch.ruleDayMove = RecurrenceDayShift.Move(from: from, to: to)
        }
        let r = try await split(named: scene.named, start: scene.start, exceptions: scene.exceptions, parts: Array(0...8), patch: patch,
                                series: GraphSplitFixture.series(range: Self.range(.until)))
        defer { r.http.close() }
        #expect(r.graph.created.isEmpty, "created after all: \(r.http.servedCallSequence())")
        guard case CalendarProviderError.notSupported(let message)? = r.error else {
            Issue.record("not refused: \(String(describing: r.error)); \(r.http.servedCallSequence())")
            return
        }
        #expect(message == SplitCarry.keptHasNoSlotRefusal, "\(message)")
    }

    @Test("T4: a new-rule split named from another zone repeats the new part in the series' zone, so a kept occurrence between the two zones' daylight-time changes lands on its occurrence")
    func keptBetweenTwoZonesDaylightChangesLands() async throws {
        // Weekly on Mondays at 09:00 London from 2099-03-02. New York's daylight time starts on
        // 2099-03-08, London's on 2099-03-29. The occurrence placed on 2099-03-16 was moved to
        // Sunday 2099-03-01 12:00, before the one named on 2099-03-02: it is kept, whole.
        let london = try #require(TimeZone(identifier: "Europe/London"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        func at(_ wall: String, _ zone: TimeZone) throws -> Date { try #require(EKEventStoreHelper.parseNaiveISO(wall, timeZone: zone)) }
        // Read on the device, as Graph gives it: the start labelled in the device's zone.
        let device = TimeZone.current.identifier
        var series = GraphSplitFixture.series(range: GraphSplitFixture.noEnd)
        series["start"] = ["dateTime": GraphFixture.wall(try at("2099-03-02T09:00:00", london), in: device) + ".0000000", "timeZone": device]
        series["end"] = ["dateTime": GraphFixture.wall(try at("2099-03-02T09:30:00", london), in: device) + ".0000000", "timeZone": device]
        series["originalStartTimeZone"] = "GMT Standard Time"
        series["recurrence"] = [
            "pattern": ["type": "weekly", "interval": 1, "month": 0, "dayOfMonth": 0, "daysOfWeek": ["monday"],
                        "firstDayOfWeek": "monday", "index": "first"],
            "range": ["type": "noEnd", "startDate": "2099-03-02", "endDate": "0001-01-01",
                      "recurrenceTimeZone": "GMT Standard Time", "numberOfOccurrences": 0],
        ]
        let shown = try at("2099-03-01T12:00:00", london)
        var kept = GraphFixture.event(id: "ser-1-occ-k", start: shown, online: false, seriesMasterId: "ser-1")
        kept["originalStart"] = GraphFixture.rfc3339(try at("2099-03-16T09:00:00", london))
        // The new part's occurrences, as Graph lists them once it is made: its pattern from its
        // range's start, at its own time of day in the zone it repeats in.
        let named = GraphFixture.event(id: "ser-1-occ-n", start: try at("2099-03-02T09:00:00", london), online: false, seriesMasterId: "ser-1")
        let graph = FakeGraphCalendar([series, named, kept])
        graph.occurrencesOnCreate { created in
            guard let id = created["id"] as? String, var recurrence = created["recurrence"] as? [String: Any],
                  var range = recurrence["range"] as? [String: Any] else { return [] }
            range["type"] = "numbered"
            range["numberOfOccurrences"] = 6
            recurrence["range"] = range
            var counted = created
            counted["recurrence"] = recurrence
            let zoneName = range["recurrenceTimeZone"] as? String ?? (created["start"] as? [String: Any])?["timeZone"] as? String ?? "UTC"
            guard let days = FakeGraphCalendar.rangeDays(counted), let zone = CalendarTimeZoneResolver.zone(named: zoneName, in: .none),
                  let start = Self.instant(created["start"]) else { return [] }
            let time = GraphFixture.wall(start, in: zone.identifier).dropFirst(11)
            return days.compactMap { day in
                EKEventStoreHelper.parseNaiveISO("\(day)T\(time)", timeZone: zone).map {
                    GraphFixture.event(id: "\(id)-\(day)", start: $0, online: false, seriesMasterId: id)
                }
            }
        }
        // A new rule (the same days), named in New York: the new part is still written in the
        // series' zone, its start and its range (`splitNewPartJSON`), so it repeats at 09:00 London.
        var patch = Self.rename
        patch.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO"]
        let r = try await split(named: "ser-1-occ-n", start: try at("2099-03-02T09:00:00", london), exceptions: [kept], parts: [],
                                patch: patch, series: series, graph: graph, zone: newYork)
        defer { r.http.close() }
        // THE property: it lands on an occurrence the new part has, or nothing is created.
        guard r.error == nil else {
            #expect(r.graph.created.isEmpty, "refused AFTER the create: \(String(describing: r.error)); \(r.http.servedCallSequence())")
            return
        }
        let partId = try #require(r.graph.created.first?["id"] as? String, "no new part: \(r.http.servedCallSequence())")
        let part = try #require(r.graph.event(partId))
        let rangeZone = (((part["recurrence"] as? [String: Any])?["range"] as? [String: Any])?["recurrenceTimeZone"] as? String)
            .flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) }
        let startZone = ((part["start"] as? [String: Any])?["timeZone"] as? String).flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) }
        #expect(rangeZone?.identifier == london.identifier && startZone?.identifier == london.identifier,
                "the new part does not repeat in the series' zone: start \(part["start"] ?? ""), range \(part["recurrence"] ?? "")")
        let onPart = r.graph.event("\(partId)-2099-03-16")
        #expect(Self.instant(onPart?["start"]) == shown, "the kept occurrence is not on the new part where it was shown: \(onPart ?? [:]); \(r.http.servedCallSequence())")
    }

    @Test("T3: a carried move that can't be dated is refused while the split is planned, before the create")
    func unplacedMoveRefusesWhilePlanned() throws {
        // An all-day series (dated with no zone) with an occurrence, shown before the one named,
        // whose start reads as a time: the move can't be dated, so the plan refuses it.
        func date(_ days: Int) -> GCalDateTime {
            GCalDateTime(dateTime: nil, date: GraphFixture.utcDay(GraphFixture.onDevice(days: days, hour: 12)), timeZone: nil)
        }
        let series = GCalEvent(
            id: "ser-1", summary: nil, location: nil, description: nil, start: date(0), end: date(1),
            attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=WEEKLY"], transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil, recurringEventId: nil)
        var kept = GCalEvent(
            id: "ser-1-occ-3", summary: nil, location: nil, description: nil,
            start: GCalDateTime(dateTime: GraphFixture.onDevice(days: 13, hour: 12).iso8601String(), date: nil, timeZone: "UTC"),
            end: GCalDateTime(dateTime: GraphFixture.onDevice(days: 13, hour: 13).iso8601String(), date: nil, timeZone: "UTC"),
            attendees: nil, organizer: nil, recurrence: nil, transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil, recurringEventId: "ser-1")
        kept.originalStartTime = date(21)
        var parts = SplitCarry.Parts()
        parts.kept = [kept]
        let newPart = GCalEvent(
            id: nil, summary: nil, location: nil, description: nil, start: date(14), end: date(15),
            attendees: nil, organizer: nil, recurrence: ["RRULE:FREQ=WEEKLY"], transparency: nil, status: nil,
            htmlLink: nil, created: nil, updated: nil, recurringEventId: nil)
        #expect(throws: CalendarProviderError.self) {
            try ExchangeCalendarProvider.dateSplitMoves(
                parts: parts, mode: .carry, namedStart: date(14), namedPlace: date(14), cut: date(14),
                series: series, zone: nil, newPart: newPart, fields: [.summary])
        }
    }

    @Test("an occurrence edited where it is moves once: a retry after a failed cap (finishSplit) leaves it where the first attempt put it")
    func movedSplitRetryMovesEditedOnce() async throws {
        let named = Self.exception(1, at: Self.week(1, plusDays: 2))
        let movedOut = Self.exception(0, at: Self.week(1, plusDays: 3))   // earlier place, shown after
        var patch = GCalEventInput()
        patch.startDateTime = Self.week(1, plusDays: 2).addingTimeInterval(3_600).iso8601String()
        patch.startTimeZone = "UTC"
        let graph = Self.calendar([GraphSplitFixture.series(range: GraphSplitFixture.noEnd), named, movedOut], parts: [2])
        let failed = Mutex(false)
        // The cap is refused once, after the occurrences were edited.
        graph.beforeWrite { method, id in
            guard method == "PATCH", id == "ser-1", !failed.withLock({ $0 }) else { return }
            failed.withLock { $0 = true }
            graph.failNext("PATCH", with: 400)
        }
        let r = try await split(named: "ser-1-occ-1", start: Self.week(1, plusDays: 2), exceptions: [named, movedOut],
                                parts: [2], patch: patch, graph: graph)
        defer { r.http.close() }
        #expect(r.error != nil, "the refused cap did not stop the split")
        let moved = Self.week(1, plusDays: 3).addingTimeInterval(3_600)
        #expect(Self.instant(r.graph.event("ser-1-occ-0")?["start"]) == moved, "\(r.graph.event("ser-1-occ-0") ?? [:])")
        let record = try #require(r.records.records.first, "no record was kept before the cap")
        try await r.provider.finishSplit(record: record, zone: .current, guests: nil)
        #expect(Self.instant(r.graph.event("ser-1-occ-0")?["start"]) == moved,
                "the retry moved an edited occurrence again: \(r.graph.event("ser-1-occ-0") ?? [:])")
        #expect(Self.instant(r.graph.event("ser-1-occ-1")?["start"]) == Self.week(1, plusDays: 2).addingTimeInterval(3_600))
        #expect(!r.graph.patches("ser-1").isEmpty, "the retry did not cap")
    }

    @Test("a split named at an occurrence moved past the series' last place makes no new part and edits it where it is (owner rule e)")
    func movedPastTheEndEditsWhereItIs() async throws {
        let named = Self.exception(1, at: Self.week(2, plusDays: 2))
        let r = try await split(
            named: "ser-1-occ-1", start: Self.week(2, plusDays: 2), exceptions: [named], parts: [], patch: Self.rename,
            series: GraphSplitFixture.series(range: ["type": "numbered", "endDate": "0001-01-01", "numberOfOccurrences": 2]))
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error)); \(r.http.servedCallSequence())")
        #expect(r.graph.created.isEmpty && r.graph.patches("ser-1").isEmpty, "a part was made or the series capped: \(r.http.servedCallSequence())")
        #expect(r.graph.event("ser-1-occ-1")?["subject"] as? String == "Renamed")
    }

    /// A series of two weeks, past whose end week 1's occurrence (`ser-1-occ-1`) was moved, to
    /// week 2 plus two days, and week 0's (`ser-1-occ-0`) to week 2 plus three days.
    private static var pastEndSeries: [String: Any] {
        GraphSplitFixture.series(range: ["type": "numbered", "endDate": "0001-01-01", "numberOfOccurrences": 2])
    }

    @Test("an edit past the series' end that fails part way keeps its targets: the retry moves nothing twice and finds every one")
    func pastEndRetryMovesOnce() async throws {
        let named = Self.exception(1, at: Self.week(2, plusDays: 2))
        let other = Self.exception(0, at: Self.week(2, plusDays: 3))
        var patch = Self.rename
        patch.startDateTime = Self.week(2, plusDays: 2).addingTimeInterval(3_600).iso8601String()
        patch.startTimeZone = "UTC"
        let graph = FakeGraphCalendar([Self.pastEndSeries, named, other])
        let failed = Mutex(false)
        // The named occurrence's write is refused once, after the other one's landed.
        graph.beforeWrite { method, id in
            guard method == "PATCH", id == "ser-1-occ-1", !failed.withLock({ $0 }) else { return }
            failed.withLock { $0 = true }
            graph.failNext("PATCH", with: 400)
        }
        let r = try await split(named: "ser-1-occ-1", start: Self.week(2, plusDays: 2), exceptions: [named, other], parts: [],
                                patch: patch, series: Self.pastEndSeries, graph: graph)
        defer { r.http.close() }
        #expect(r.error != nil, "the refused write did not stop the edit")
        let record = try #require(r.records.records.first, "no record was kept before the first write")
        #expect(record.isPastEnd)
        #expect(Self.instant(r.graph.event("ser-1-occ-0")?["start"]) == Self.week(2, plusDays: 3).addingTimeInterval(3_600))
        try await r.provider.finishShownEdit(record: record, edit: patch, guests: nil)
        #expect(Self.instant(r.graph.event("ser-1-occ-0")?["start"]) == Self.week(2, plusDays: 3).addingTimeInterval(3_600),
                "the retry moved an occurrence twice: \(r.graph.event("ser-1-occ-0") ?? [:])")
        #expect(Self.instant(r.graph.event("ser-1-occ-1")?["start"]) == Self.week(2, plusDays: 2).addingTimeInterval(3_600),
                "the retry did not move the named occurrence: \(r.http.servedCallSequence())")
        #expect(r.graph.event("ser-1-occ-0")?["subject"] as? String == "Renamed" && r.graph.event("ser-1-occ-1")?["subject"] as? String == "Renamed")
    }

    @Test("occurrences edited where they are move in the order Graph takes, none onto a day another still holds")
    func shownEditsAreOrderedOffHeldDays() async throws {
        // The edit moves both a day earlier: the named one onto a free day, the other onto the named one's day.
        let named = Self.exception(1, at: Self.week(2, plusDays: 2))
        let other = Self.exception(0, at: Self.week(2, plusDays: 3))
        var patch = GCalEventInput()
        patch.startDateTime = Self.week(2, plusDays: 1).iso8601String()
        patch.startTimeZone = "UTC"
        let graph = FakeGraphCalendar([Self.pastEndSeries, named, other])
        graph.refusesSameDayMoves.withLock { $0 = true }
        let r = try await split(named: "ser-1-occ-1", start: Self.week(2, plusDays: 2), exceptions: [named, other], parts: [],
                                patch: patch, series: Self.pastEndSeries, graph: graph)
        defer { r.http.close() }
        #expect(r.error == nil, "a move landed on a held day: \(String(describing: r.error)); \(r.http.servedCallSequence())")
        #expect(Self.instant(r.graph.event("ser-1-occ-1")?["start"]) == Self.week(2, plusDays: 1)
                    && Self.instant(r.graph.event("ser-1-occ-0")?["start"]) == Self.week(2, plusDays: 2),
                "not both moved: \(r.http.servedCallSequence())")
    }

    @Test("a split moves the occurrences it edits on the series in the order Graph takes, none onto a day another still holds")
    func splitEditsAreOrderedOffHeldDays() async throws {
        // Both shown after the cut's place and kept on the series; the edit moves each a day
        // earlier: the named one onto a free day, the other onto the named one's day.
        let named = Self.exception(1, at: Self.week(1, plusDays: 2))
        let other = Self.exception(0, at: Self.week(1, plusDays: 3))
        var patch = GCalEventInput()
        patch.startDateTime = Self.week(1, plusDays: 1).iso8601String()
        patch.startTimeZone = "UTC"
        // Listed with the other one first: in that order it would land on the named one's day.
        let graph = Self.calendar([GraphSplitFixture.series(range: GraphSplitFixture.noEnd), other, named], parts: [2])
        graph.refusesSameDayMoves.withLock { $0 = true }
        let r = try await split(named: "ser-1-occ-1", start: Self.week(1, plusDays: 2), exceptions: [other, named],
                                parts: [2], patch: patch, graph: graph)
        defer { r.http.close() }
        #expect(r.error == nil, "a move landed on a held day: \(String(describing: r.error)); \(r.http.servedCallSequence())")
        #expect(Self.instant(r.graph.event("ser-1-occ-1")?["start"]) == Self.week(1, plusDays: 1)
                    && Self.instant(r.graph.event("ser-1-occ-0")?["start"]) == Self.week(1, plusDays: 2),
                "not both moved: \(r.http.servedCallSequence())")
    }

    @Test("an occurrence shown before the named one is kept whole: the edit's guest change does not reach its own guests")
    func movedSplitKeptItemKeepsItsGuests() async throws {
        let extra: [String: Any] = ["emailAddress": ["address": "extra@example.com", "name": "Extra"], "type": "required",
                                    "status": ["response": "accepted", "time": "0001-01-01T00:00:00Z"]]
        let named = Self.exception(1, at: Self.week(1, plusDays: 2))
        let movedIn = Self.exception(3, at: Self.week(1, plusDays: 1)) { e in
            e["attendees"] = (e["attendees"] as? [[String: Any]] ?? []) + [extra]
        }
        var patch = Self.rename
        patch.attendeeChange = AttendeeChange(adds: [.init(email: "new@example.com", name: nil)])
        let r = try await split(named: "ser-1-occ-1", start: Self.week(1, plusDays: 2), exceptions: [named, movedIn],
                                parts: [2, 3], patch: patch)
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error)); \(r.http.servedCallSequence())")
        let guests = Set((r.graph.event("created-1-w3")?["attendees"] as? [[String: Any]] ?? []).compactMap {
            ($0["emailAddress"] as? [String: Any])?["address"] as? String
        })
        #expect(guests.contains("extra@example.com") && !guests.contains("new@example.com"),
                "the kept occurrence's guests changed: \(guests)")
        #expect(r.graph.event("created-1-w3")?["subject"] as? String != "Renamed", "the kept occurrence was renamed")
    }

    private static var rename: GCalEventInput {
        var patch = GCalEventInput()
        patch.summary = "Renamed"
        return patch
    }

    private static func displayName(_ value: Any?) -> String? { (value as? [String: Any])?["displayName"] as? String }

    @Test("a rename from an occurrence on keeps a deleted later occurrence deleted and a changed one's own room")
    func renameCarriesLaterExceptions() async throws {
        let r = try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                cancelled: [3], parts: [2, 3], patch: Self.rename)
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error))")
        #expect(r.http.recordedCalls().filter { $0.method == "POST" }.count == 1 && r.graph.event("created-1") != nil,
                "no new part: \(r.http.servedCallSequence())")
        #expect(r.graph.event("created-1-w3") == nil, "the deleted occurrence came back: \(r.http.servedCallSequence())")
        let carried = Self.displayName(r.graph.event("created-1-w2")?["location"])
        #expect(carried == "Room 9", "the changed occurrence lost its room: \(carried ?? "none"); \(r.http.servedCallSequence())")
        #expect(!r.graph.patches("ser-1").isEmpty, "the series was not capped: \(r.http.servedCallSequence())")
    }

    @Test("a changed later occurrence carried onto the new part keeps its own file, before the cap; a retry after a failed copy adds it once")
    func carriedOccurrenceKeepsItsOwnFile() async throws {
        let minutes = Data("Minutes of week 2\n".utf8)
        let r = try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                parts: [2, 3], patch: Self.rename) { graph, _ in
            graph.attachFile("minutes.txt", contentType: "text/plain", bytes: minutes, to: "ser-1-occ-2")
            graph.failNext("ATTACH", with: 400)
        }
        defer { r.http.close() }
        #expect(r.error != nil, "the failed copy did not stop the split: \(r.http.servedCallSequence())")
        #expect(r.graph.patches("ser-1").isEmpty, "the series was capped though the occurrence's file was not copied")
        let record = try #require(r.records.records.first, "no record was kept")
        try await r.provider.finishSplit(record: record, zone: .current, guests: nil)
        let held = r.graph.files(of: "created-1-w2")
        #expect(held.map(\.name) == ["minutes.txt"] && held.first?.bytes == minutes,
                "the carried occurrence holds \(held.map(\.name)): \(r.http.servedCallSequence())")
        #expect(r.graph.files(of: "created-1-w3").isEmpty, "an occurrence that was not changed got a file")
        #expect(r.graph.files(of: "ser-1-occ-2").map(\.name) == ["minutes.txt"], "the series' occurrence lost its file")
        // The copy lands before the cap.
        let calls = r.http.recordedCalls()
        let copy = try #require(calls.lastIndex { $0.method == "POST" && $0.url.contains("/events/created-1-w2/attachments") })
        let cap = try #require(calls.lastIndex { $0.method == "PATCH" && URL(string: $0.url)?.path.hasSuffix("/events/ser-1") == true },
                               "the retry did not cap")
        #expect(copy < cap, "the occurrence's file was copied after the cap: \(r.http.servedCallSequence())")
    }

    @Test("a changed later occurrence the split carries that holds a linked file refuses the split before any write, as the series' own does")
    func carriedOccurrenceLinkedFileRefusesUnwritten() async throws {
        let r = try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                parts: [2, 3], patch: Self.rename) { graph, _ in
            graph.attachFile("minutes.txt", contentType: "text/plain", bytes: Data("Minutes\n".utf8), to: "ser-1-occ-2")
            graph.attachOther("#microsoft.graph.referenceAttachment", name: "Shared notes", to: "ser-1-occ-2")
        }
        defer { r.http.close() }
        let writes = r.http.recordedCalls().filter { $0.method != "GET" }
        #expect(writes.isEmpty, "a write was sent: \(writes.map { "\($0.method) \($0.url)" })")
        #expect(r.graph.event("created-1") == nil && r.records.records.isEmpty, "a new part or a record was made")
        var message: String?
        if case .notSupported(let said)? = r.error as? CalendarProviderError { message = said }
        #expect(message == ExchangeSplitAttachmentTests.linkedFileMessage, "the refusal: \(String(describing: r.error))")
    }

    @Test("a changed later occurrence the split carries that holds any attached Outlook item (an email, an event, a contact, any other kind) refuses the split before any write (#847, #854)",
          arguments: ["email", "event", "contact", "post"])
    func carriedOccurrenceUncopiedItemRefusesUnwritten(kind: String) async throws {
        let item = ExchangeSplitAttachmentTests.item(kind)
        let r = try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                parts: [2, 3], patch: Self.rename) { graph, _ in
            graph.attachFile("minutes.txt", contentType: "text/plain", bytes: Data("Minutes\n".utf8), to: "ser-1-occ-2")
            graph.attachItem("Week 2 \(kind)", item: item, to: "ser-1-occ-2")
        }
        defer { r.http.close() }
        let writes = r.http.recordedCalls().filter { $0.method != "GET" }
        #expect(writes.isEmpty, "\(kind): a write was sent: \(writes.map { "\($0.method) \($0.url)" })")
        #expect(r.graph.event("created-1") == nil && r.records.records.isEmpty, "\(kind): a new part or a record was made")
        #expect(r.graph.attachments(of: "ser-1-occ-2").count == 2, "\(kind): the occurrence's attachments changed")
        var message: String?
        if case .notSupported(let said)? = r.error as? CalendarProviderError { message = said }
        #expect(message == ExchangeSplitAttachmentTests.uncopiedItemMessage, "\(kind): the refusal: \(String(describing: r.error))")
    }

    /// The refusals of a retry whose carried occurrence gained an attached Outlook item or a linked
    /// file (#847, #834),
    /// as the user reads them.
    static let retryUncopiedItemMessage =
        "This change to the repeating event wasn't finished: a later occurrence now has an attached Outlook item TabMail can't copy, so both parts show the later occurrences. Remove the item from that occurrence or finish the change in your calendar app."
    static let retryLinkedFileMessage =
        "This change to the repeating event wasn't finished: a later occurrence now has a linked file TabMail can't copy, so both parts show the later occurrences. Remove the file from that occurrence or finish the change in your calendar app."

    /// Splits `ser-1` from week 2, carrying its changed week 2, with the cap refused once, so the
    /// first attempt wrote everything but the cap and kept its record; then `gain` adds to the
    /// series' week 2 occurrence, and the retry (`finishSplit`) runs. What the retry wrote, and
    /// what it threw.
    private func retryAfterARefusedCap(gain: (FakeGraphCalendar) -> Void) async throws -> (run: Run, writes: [String], error: Error?) {
        let r = try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                parts: [2, 3], patch: Self.rename) { graph, _ in
            let failed = Mutex(false)
            graph.beforeWrite { method, id in
                guard method == "PATCH", id == "ser-1", !failed.withLock({ $0 }) else { return }
                failed.withLock { $0 = true }
                graph.failNext("PATCH", with: 400)
            }
        }
        #expect(r.error != nil && r.graph.patches("ser-1").isEmpty, "non-vacuity: the first attempt capped: \(r.http.servedCallSequence())")
        let record = try #require(r.records.records.first, "no record was kept")
        #expect(Self.displayName(r.graph.event("created-1-w2")?["location"]) == "Room 9",
                "non-vacuity: the first attempt did not carry week 2: \(r.http.servedCallSequence())")
        gain(r.graph)
        let before = r.http.recordedCalls().count
        var thrown: Error?
        do {
            try await r.provider.finishSplit(record: record, zone: .current, guests: nil)
        } catch {
            thrown = error
        }
        let writes = r.http.recordedCalls().dropFirst(before).filter { $0.method != "GET" }.map { "\($0.method) \($0.url)" }
        return (r, writes, thrown)
    }

    @Test("a retry whose carried occurrence gained an attached Outlook item (an email, an event, a contact) or a linked file since the first attempt is refused before its first write: both parts stay as the first attempt left them, and the occurrence keeps it",
          arguments: ["email", "event", "contact", "linked file"])
    func retryRefusesAnItemACarriedOccurrenceGained(kind: String) async throws {
        let (r, writes, error) = try await retryAfterARefusedCap { graph in
            if kind == "linked file" {
                graph.attachOther("#microsoft.graph.referenceAttachment", name: "Week 2 deck", to: "ser-1-occ-2")
            } else {
                graph.attachItem("Week 2 \(kind)", item: ExchangeSplitAttachmentTests.item(kind), to: "ser-1-occ-2")
            }
        }
        defer { r.http.close() }
        #expect(writes.isEmpty, "\(kind): the retry wrote \(writes)")
        var message: String?
        if case .notSupported(let said)? = error as? CalendarProviderError { message = said }
        #expect(message == (kind == "linked file" ? Self.retryLinkedFileMessage : Self.retryUncopiedItemMessage),
                "\(kind): the refusal: \(String(describing: error))")
        #expect(r.graph.patches("ser-1").isEmpty, "\(kind): the series was capped")
        #expect(r.graph.attachments(of: "ser-1-occ-2").count == 1, "\(kind): the occurrence's attachment changed")
    }

    @Test("a retry whose carried occurrence gained a file copies it and finishes: the cap is written")
    func retryCopiesAFileACarriedOccurrenceGained() async throws {
        let minutes = Data("Minutes of week 2\n".utf8)
        let (r, writes, error) = try await retryAfterARefusedCap { graph in
            graph.attachFile("minutes.txt", contentType: "text/plain", bytes: minutes, to: "ser-1-occ-2")
        }
        defer { r.http.close() }
        #expect(error == nil, "\(String(describing: error)); \(r.http.servedCallSequence())")
        let held = r.graph.files(of: "created-1-w2")
        #expect(held.map(\.name) == ["minutes.txt"] && held.first?.bytes == minutes,
                "the carried occurrence holds \(held.map(\.name))")
        #expect(!r.graph.patches("ser-1").isEmpty, "the retry did not cap: \(writes)")
    }

    @Test("a retry of a split whose SERIES holds an attached Outlook item finishes: the cap is written, and the item stays on the old part only (#854)",
          arguments: ["email", "event", "contact"])
    func retryLeavesASeriesItemOnTheOldPart(kind: String) async throws {
        let (r, writes, error) = try await retryAfterARefusedCap { graph in
            graph.attachItem("Series \(kind)", item: ExchangeSplitAttachmentTests.item(kind), to: "ser-1")
        }
        defer { r.http.close() }
        #expect(error == nil, "\(kind): \(String(describing: error)); \(r.http.servedCallSequence())")
        #expect(!r.graph.patches("ser-1").isEmpty, "\(kind): the retry did not cap: \(writes)")
        #expect(r.graph.attachments(of: "ser-1").compactMap { $0["name"] as? String } == ["Series \(kind)"],
                "\(kind): the series' attachments changed: \(r.graph.attachments(of: "ser-1"))")
        let partId = try #require(r.records.records.first?.newPartId)
        #expect(r.graph.attachments(of: partId).isEmpty, "\(kind): the new part got \(r.graph.attachments(of: partId))")
        #expect(!writes.contains { $0.contains("/attachments") }, "\(kind): the retry wrote an attachment: \(writes)")
    }

    @Test("a refused retry writes nothing, not even a series file the first attempt did not copy")
    func refusedRetryCopiesNoSeriesFile() async throws {
        let agenda = Data("Agenda for the series\n".utf8)
        let r = try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                parts: [2, 3], patch: Self.rename) { graph, _ in
            graph.attachFile("agenda.txt", contentType: "text/plain", bytes: agenda, to: "ser-1")
            graph.failNext("ATTACH", with: 400)   // the series file's copy is refused (a 503 is retried)
        }
        defer { r.http.close() }
        #expect(r.error != nil && r.graph.patches("ser-1").isEmpty,
                "non-vacuity: the first attempt went past the failed copy: \(r.http.servedCallSequence())")
        let record = try #require(r.records.records.first, "no record was kept")
        #expect(r.graph.files(of: record.newPartId).isEmpty, "non-vacuity: the first attempt copied the series file")
        r.graph.attachItem("Week 2 contact", item: ExchangeSplitAttachmentTests.item("contact"), to: "ser-1-occ-2")
        let before = r.http.recordedCalls().count
        var thrown: Error?
        do {
            try await r.provider.finishSplit(record: record, zone: .current, guests: nil)
        } catch {
            thrown = error
        }
        let writes = r.http.recordedCalls().dropFirst(before).filter { $0.method != "GET" }.map { "\($0.method) \($0.url)" }
        #expect(writes.isEmpty, "the refused retry wrote \(writes)")
        var message: String?
        if case .notSupported(let said)? = thrown as? CalendarProviderError { message = said }
        #expect(message == Self.retryUncopiedItemMessage, "the refusal: \(String(describing: thrown))")
        #expect(r.graph.files(of: record.newPartId).isEmpty && r.graph.patches("ser-1").isEmpty,
                "the new part got the series file or the series was capped")
    }

    @Test("a carried occurrence holding both a linked file and an attached Outlook item is refused for the linked file, on the first attempt and on a retry")
    func linkedFileRefusalWinsOverAnUncopiedItem() async throws {
        let first = try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                    parts: [2, 3], patch: Self.rename) { graph, _ in
            graph.attachItem("Week 2 mail", item: ExchangeSplitAttachmentTests.receivedMail, to: "ser-1-occ-2")
            graph.attachOther("#microsoft.graph.referenceAttachment", name: "Week 2 deck", to: "ser-1-occ-2")
        }
        defer { first.http.close() }
        var message: String?
        if case .notSupported(let said)? = first.error as? CalendarProviderError { message = said }
        #expect(message == ExchangeSplitAttachmentTests.linkedFileMessage, "the first attempt's refusal: \(String(describing: first.error))")

        let (r, writes, error) = try await retryAfterARefusedCap { graph in
            graph.attachItem("Week 2 mail", item: ExchangeSplitAttachmentTests.receivedMail, to: "ser-1-occ-2")
            graph.attachOther("#microsoft.graph.referenceAttachment", name: "Week 2 deck", to: "ser-1-occ-2")
        }
        defer { r.http.close() }
        var retried: String?
        if case .notSupported(let said)? = error as? CalendarProviderError { retried = said }
        #expect(writes.isEmpty && retried == Self.retryLinkedFileMessage, "the retry wrote \(writes); its refusal: \(String(describing: error))")
    }

    @Test("a linked file on a changed occurrence the split does not carry (before the one named) refuses nothing")
    func uncarriedOccurrenceLinkedFileIsLeft() async throws {
        let r = try await split(exceptions: [Self.exception(0) { $0["location"] = ["displayName": "Room 9"] }],
                                parts: [2, 3], patch: Self.rename) { graph, _ in
            graph.attachOther("#microsoft.graph.referenceAttachment", name: "Shared notes", to: "ser-1-occ-0")
        }
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error)); \(r.http.servedCallSequence())")
        #expect(r.graph.event("created-1") != nil && !r.graph.patches("ser-1").isEmpty, "the split did not complete: \(r.http.servedCallSequence())")
        #expect(r.graph.attachments(of: "ser-1-occ-0").count == 1, "the occurrence's link changed")
    }

    /// `series` kept in a zone the app does not recognize, with no range zone: no series zone to
    /// date a move in.
    private static func zoneless(_ series: [String: Any]) -> [String: Any] {
        var e = series
        for key in ["start", "end"] {
            if var time = e[key] as? [String: Any] { time["timeZone"] = "Customized Time Zone"; e[key] = time }
        }
        if var recurrence = e["recurrence"] as? [String: Any], var range = recurrence["range"] as? [String: Any] {
            range.removeValue(forKey: "recurrenceTimeZone")
            recurrence["range"] = range
            e["recurrence"] = recurrence
        }
        return e
    }

    @Test("a timed series that names no zone (neither its range nor the event) is refused before anything is written and no record is kept: a rename, a new time, a deletion after it and an edit past its end alike (#681)")
    func zonelessSeriesIsRefused() async throws {
        #expect(CalendarTimeZoneResolver.zone(named: "Customized Time Zone", in: .none) == nil, "non-vacuity: the zone is recognized")
        let series = Self.zoneless(GraphSplitFixture.series(range: GraphSplitFixture.noEnd))
        let runs: [(String, Run)] = [
            ("rename", try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                       parts: [2], patch: Self.rename, series: series)),
            ("new time", try await split(exceptions: [Self.exception(2, at: Self.week(2, plusDays: 1))], parts: [2], patch: Self.hourLater, series: series)),
            ("deletion", try await split(exceptions: [], cancelled: [3], parts: [2, 3], patch: Self.rename, series: series)),
            ("past the end", try await split(named: "ser-1-occ-1", start: Self.week(2, plusDays: 2), exceptions: [Self.exception(1, at: Self.week(2, plusDays: 2))],
                                             parts: [], patch: Self.rename, series: Self.zoneless(Self.pastEndSeries))),
        ]
        for (label, r) in runs {
            defer { r.http.close() }
            var said: String?
            if case .notSupported(let message)? = r.error as? CalendarProviderError { said = message }
            #expect(said?.hasPrefix("Outlook gives no time zone for this repeating event") == true, "\(label): \(String(describing: r.error))")
            #expect(r.records.records.isEmpty && r.http.recordedCalls().allSatisfy { $0.method == "GET" }, "\(label): \(r.http.servedCallSequence())")
        }
    }

    /// A new start an hour later than the split's occurrence, given in UTC.
    private static var hourLater: GCalEventInput {
        var patch = GCalEventInput()
        patch.startDateTime = GraphSplitFixture.occurrence.addingTimeInterval(3_600).iso8601String()
        patch.startTimeZone = "UTC"
        return patch
    }

    @Test("a series whose range names no zone is dated in the event's own zone (originalStartTimeZone), as its cap is: a later occurrence moved to another day and a deleted one are carried (#681, #563)")
    func eventZoneDatesTheCarry() async throws {
        var series = GraphSplitFixture.series(range: GraphSplitFixture.noEnd)
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range.removeValue(forKey: "recurrenceTimeZone")
        recurrence["range"] = range
        series["recurrence"] = recurrence
        series["originalStartTimeZone"] = "Pacific Standard Time"
        let r = try await split(exceptions: [Self.exception(2, at: Self.week(2, plusDays: 1))], cancelled: [3], parts: [2, 3],
                                patch: Self.rename, series: series)
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error)); \(r.http.servedCallSequence())")
        #expect(Self.instant(r.graph.event("created-1-w2")?["start"]) == Self.week(2, plusDays: 1),
                "the moved occurrence was not carried: \(r.http.servedCallSequence())")
        #expect(r.graph.event("created-1-w3") == nil, "the deleted occurrence came back: \(r.http.servedCallSequence())")
        #expect(!r.graph.patches("ser-1").isEmpty, "the series was not capped: \(r.http.servedCallSequence())")
    }

    @Test("a series whose range zone is custom (desktop Outlook's) is refused with nothing written: no deleted date is placed in the zone the read was given in")
    func customRangeZoneIsRefused() async throws {
        #expect(CalendarTimeZoneResolver.zone(named: "tzone://Microsoft/Custom", in: .none) == nil, "non-vacuity: the custom zone is recognized")
        var series = GraphSplitFixture.series(range: GraphSplitFixture.noEnd)
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range["recurrenceTimeZone"] = "tzone://Microsoft/Custom"
        recurrence["range"] = range
        series["recurrence"] = recurrence
        let r = try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                cancelled: [3], parts: [2, 3], patch: Self.rename, series: series)
        defer { r.http.close() }
        #expect(r.error != nil, "the split went on: \(r.http.servedCallSequence())")
        #expect(r.http.recordedCalls().allSatisfy { $0.method == "GET" }, "something was written: \(r.http.servedCallSequence())")
    }

    @Test("a series whose range names no zone is refused with nothing written: a deleted date or a moved occurrence is never placed in the zone the read was given in")
    func noRangeZoneIsNotReadInTheDisplayZone() async throws {
        var series = GraphSplitFixture.series(range: GraphSplitFixture.noEnd)
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range.removeValue(forKey: "recurrenceTimeZone")
        recurrence["range"] = range
        series["recurrence"] = recurrence
        // Non-vacuity: the start is labelled with a zone TabMail recognizes, the one the read asked for.
        #expect(CalendarTimeZoneResolver.zone(named: GraphSplitFixture.zone, in: .none) != nil)
        let r = try await split(exceptions: [], cancelled: [3], parts: [2, 3], patch: Self.rename, series: series)
        defer { r.http.close() }
        #expect(r.error != nil, "the split went on: \(r.http.servedCallSequence())")
        #expect(r.http.recordedCalls().allSatisfy { $0.method == "GET" }, "something was written: \(r.http.servedCallSequence())")
        // A moved occurrence is dated in the series' zone too: the start's zone, only the one the read was given in, never stands in.
        let moved = try await split(exceptions: [Self.exception(2, at: Self.week(2, plusDays: 1))], parts: [2], patch: Self.rename, series: series)
        defer { moved.http.close() }
        #expect(moved.error != nil, "the split went on: \(moved.http.servedCallSequence())")
        #expect(moved.http.recordedCalls().allSatisfy { $0.method == "GET" }, "something was written: \(moved.http.servedCallSequence())")
    }

    @Test("a changed occurrence is carried WHOLE: its own importance, categories and reminder survive a rename")
    func carryCopiesTheWholeException() async throws {
        let r = try await split(exceptions: [Self.exception(2) { e in
            e["importance"] = "low"
            e["categories"] = ["Red category"]
            e["reminderMinutesBeforeStart"] = 5
        }], parts: [2], patch: Self.rename)
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error))")
        let carried = r.graph.event("created-1-w2")
        #expect(carried?["importance"] as? String == "low" && carried?["categories"] as? [String] == ["Red category"]
                    && carried?["reminderMinutesBeforeStart"] as? Int == 5,
                "the exception's own properties were lost: \(carried ?? [:]); \(r.http.servedCallSequence())")
        // The title the edit set is the new part's: the carry does not write the exception's old one back.
        #expect(r.graph.patches("created-1-w2").allSatisfy { $0["subject"] == nil }, "the carry wrote the old title: \(r.graph.patches("created-1-w2"))")
    }

    @Test("an exception listed past the first page of the new part's occurrences is still carried")
    func carryReadsEveryPage() async throws {
        let r = try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                parts: [2], patch: Self.rename) { graph, http in
            let ok = ["Content-Type": "application/json"]
            http.register(path: "/v1.0/me/events/created-1/instances", method: "GET") { request in
                if request.url.absoluteString.contains("skiptoken") {
                    let page = ["value": [graph.event("created-1-w2") ?? [:]]]
                    // swiftlint:disable:next force_try
                    return .raw(statusCode: 200, headers: ok, body: try! JSONSerialization.data(withJSONObject: page))
                }
                let first: [String: Any] = ["value": [], "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/events/created-1/instances?$skiptoken=p2"]
                // swiftlint:disable:next force_try
                return .raw(statusCode: 200, headers: ok, body: try! JSONSerialization.data(withJSONObject: first))
            }
        }
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error))")
        #expect(Self.displayName(r.graph.event("created-1-w2")?["location"]) == "Room 9",
                "the exception on page 2 was not carried: \(r.http.servedCallSequence())")
    }

    @Test("a carry refused for good stops the split before the cap; the retry (finishSplit) carries, then caps")
    func carryFailureStopsBeforeTheCapAndTheRetryCarries() async throws {
        let r = try await split(exceptions: [Self.exception(2) { $0["location"] = ["displayName": "Room 9"] }],
                                parts: [2], patch: Self.rename) { graph, _ in graph.failNext("PATCH", with: 400) }
        defer { r.http.close() }
        #expect(r.error != nil, "the refused carry did not stop the split")
        #expect(r.graph.patches("ser-1").isEmpty, "the series was capped though its carry failed: \(r.http.servedCallSequence())")
        let record = try #require(r.records.records.first, "no record was kept before the carry")
        try await r.provider.finishSplit(record: record, zone: .current, guests: nil)
        #expect(Self.displayName(r.graph.event("created-1-w2")?["location"]) == "Room 9",
                "the retry did not carry: \(r.http.servedCallSequence())")
        #expect(!r.graph.patches("ser-1").isEmpty, "the retry did not cap: \(r.http.servedCallSequence())")
    }

    @Test("moves are ordered so none lands on a day another occurrence still holds (carryOrder)")
    func carryOrdersMovesOffHeldDays() async throws {
        // Week 2's moved onto week 3's day; week 3's moved a day on. Week 3 must move first.
        let r = try await split(exceptions: [Self.exception(2, at: Self.week(3, hour: 12)),
                                             Self.exception(3, at: Self.week(3, hour: 10, plusDays: 1))],
                                parts: [2, 3], patch: Self.rename) { graph, _ in graph.refusesSameDayMoves.withLock { $0 = true } }
        defer { r.http.close() }
        #expect(r.error == nil, "a move landed on a held day: \(String(describing: r.error)); \(r.http.servedCallSequence())")
        #expect(GraphFixture.instant(r.graph.event("created-1-w2")?["start"] as? [String: Any]) == Self.week(3, hour: 12)
                    && GraphFixture.instant(r.graph.event("created-1-w3")?["start"] as? [String: Any]) == Self.week(3, hour: 10, plusDays: 1),
                "not both moved: \(r.http.servedCallSequence())")
    }

    @Test("the deleted places go before the moves, so a move onto a deleted occurrence's day is taken")
    func carryDeletesBeforeMoves() async throws {
        // Week 2's moved onto week 3's day; week 3's deleted.
        let r = try await split(exceptions: [Self.exception(2, at: Self.week(3, hour: 12))], cancelled: [3],
                                parts: [2, 3], patch: Self.rename) { graph, _ in graph.refusesSameDayMoves.withLock { $0 = true } }
        defer { r.http.close() }
        #expect(r.error == nil, "the move went before the delete: \(String(describing: r.error)); \(r.http.servedCallSequence())")
        #expect(r.graph.event("created-1-w3") == nil && GraphFixture.instant(r.graph.event("created-1-w2")?["start"] as? [String: Any]) == Self.week(3, hour: 12),
                "\(r.http.servedCallSequence())")
    }

    @Test("the edit's guest change reaches a carried occurrence's OWN guests as the series' difference")
    func carryAppliesGuestChangeToOwnGuests() async throws {
        let extra: [String: Any] = ["emailAddress": ["address": "extra@example.com", "name": "Extra"], "type": "required",
                                    "status": ["response": "accepted", "time": "0001-01-01T00:00:00Z"]]
        var patch = GCalEventInput()
        patch.attendeeChange = AttendeeChange(adds: [.init(email: "new@example.com", name: nil)])
        let r = try await split(exceptions: [Self.exception(2) { e in
            e["attendees"] = (e["attendees"] as? [[String: Any]] ?? []) + [extra]
        }], parts: [2], patch: patch)
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error))")
        let guests = Set((r.graph.event("created-1-w2")?["attendees"] as? [[String: Any]] ?? []).compactMap {
            (($0["emailAddress"] as? [String: Any])?["address"] as? String)?.lowercased()
        })
        #expect(guests.contains("extra@example.com") && guests.contains("new@example.com"), "guests: \(guests)")
    }

    @Test("an end given alone gives a carried moved occurrence its own start plus the new length")
    func endOnlySplitMovesCarriedEnd() async throws {
        let movedTo = Self.week(2, hour: 14)
        var patch = GCalEventInput()
        patch.endDateTime = GraphSplitFixture.occurrence.addingTimeInterval(3_600).iso8601String()
        let r = try await split(exceptions: [Self.exception(2, at: movedTo)], parts: [2], patch: patch)
        defer { r.http.close() }
        #expect(r.error == nil, "\(String(describing: r.error))")
        let carried = r.graph.event("created-1-w2")
        #expect(GraphFixture.instant(carried?["start"] as? [String: Any]) == movedTo && GraphFixture.instant(carried?["end"] as? [String: Any]) == movedTo.addingTimeInterval(3_600),
                "the carried occurrence: \(carried ?? [:]); \(r.http.servedCallSequence())")
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

    @Test("a new rule from another zone keeps the new part on the series' clock: every occurrence Graph lists for it stays at the series' time of day across both zones' changes of offset")
    func newRuleKeepsTheSeriesClock() async throws {
        // A weekly series at 09:00 in a zone whose daylight-time dates differ from the device's
        // (London for a device in the Americas, as measured from New York), read on the device:
        // Graph labels its start in the device's zone and keeps the range in the series'.
        let mondays = (0..<52).map { 7.0 * 86_400 * Double($0) }
        let deviceShifts = try mondays.map { gap -> Int in
            let first = try #require(EKEventStoreHelper.parseNaiveISO("2099-01-05T12:00:00", timeZone: .gmt))
            return TimeZone.current.secondsFromGMT(for: first.addingTimeInterval(gap)) - TimeZone.current.secondsFromGMT(for: first)
        }
        let candidates = [("Europe/London", "GMT Standard Time"), ("America/New_York", "Eastern Standard Time")]
        let picked = try candidates.first { iana, _ in
            let zone = try #require(TimeZone(identifier: iana))
            let first = try #require(EKEventStoreHelper.parseNaiveISO("2099-01-05T12:00:00", timeZone: .gmt))
            return mondays.map { zone.secondsFromGMT(for: first.addingTimeInterval($0)) - zone.secondsFromGMT(for: first) } != deviceShifts
        }
        let (iana, windows) = try #require(picked, "no candidate zone changes its offset on other dates than the device's")
        let seriesZone = try #require(TimeZone(identifier: iana))
        let device = TimeZone.current.identifier
        let first = try #require(EKEventStoreHelper.parseNaiveISO("2099-01-05T09:00:00", timeZone: seriesZone))
        let named = first.addingTimeInterval(7 * 86_400)
        var series = GraphFixture.event(id: "ser-1", start: first, online: false, recurring: true)
        series["start"] = ["dateTime": GraphFixture.wall(first, in: device) + ".0000000", "timeZone": device]
        series["end"] = ["dateTime": GraphFixture.wall(first.addingTimeInterval(1_800), in: device) + ".0000000", "timeZone": device]
        series["originalStartTimeZone"] = iana
        series["recurrence"] = [
            "pattern": ["type": "weekly", "interval": 1, "month": 0, "dayOfMonth": 0, "daysOfWeek": ["monday"],
                        "firstDayOfWeek": "sunday", "index": "first"],
            "range": ["type": "noEnd", "startDate": "2099-01-05", "endDate": "0001-01-01", "recurrenceTimeZone": windows, "numberOfOccurrences": 0],
        ]
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([series, GraphFixture.event(id: "ser-1-occ", start: named, online: false, seriesMasterId: "ser-1")])
        graph.install(on: http)
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO"]
        _ = try await GraphSplitFixture.provider(http).splitSeries(
            eventId: "ser-1", recurrenceId: GraphFixture.wall(named, in: device), recurrenceIdZone: .current, patch: patch)
        let partId = try #require(graph.created.first?["id"] as? String, "no new part: \(http.servedCallSequence())")
        let part = try #require(graph.event(partId))
        // Graph lists a series' occurrences on the clock of its range's zone, which a create with
        // none takes from its start's label (measured 2026-11-13).
        let range = (part["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        let repeatsIn = try #require((range?["recurrenceTimeZone"] as? String).flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) })
        let label = try #require(part["start"] as? [String: Any])
        let start = try #require((label["timeZone"] as? String).flatMap { CalendarTimeZoneResolver.zone(named: $0, in: .none) }.flatMap { zone in
            (label["dateTime"] as? String).flatMap { EKEventStoreHelper.parseNaiveISO(String($0.prefix(19)), timeZone: zone) }
        })
        let wall = GraphFixture.wall(start, in: repeatsIn.identifier)
        let day = try #require(EKEventStoreHelper.parseNaiveISO(String(wall.prefix(10)) + "T12:00:00", timeZone: .gmt))
        let off = try (0..<50).compactMap { week -> String? in
            let date = GraphFixture.wall(day.addingTimeInterval(7 * 86_400 * Double(week)), in: "UTC").prefix(10)
            let at = try #require(EKEventStoreHelper.parseNaiveISO("\(date)T\(wall.dropFirst(11))", timeZone: repeatsIn))
            let there = GraphFixture.wall(at, in: iana)
            return there.hasSuffix("T09:00:00") ? nil : there
        }
        #expect(off.isEmpty, "the new part repeats in \(repeatsIn.identifier), off the series' 09:00 \(iana) on \(off.count) weeks: \(off.prefix(4)); start \(part["start"] ?? "")")
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

        // At the split's instant, written in the series' stored zone (#719).
        let start = try #require(created["start"] as? [String: Any])
        #expect(GraphFixture.instant(start) == GraphFixture.instant(["dateTime": GraphSplitFixture.recurrenceId, "timeZone": GraphSplitFixture.zone])
                    && start["timeZone"] as? String == "Pacific Standard Time",
                "\(rangeType): the new part does not start at the split: \(start)")

        let storedRecurrence = try #require(series["recurrence"] as? [String: Any])
        let recurrence = try #require(created["recurrence"] as? [String: Any])
        #expect(canonical(recurrence["pattern"]) == canonical(storedRecurrence["pattern"]), "\(rangeType): the pattern changed")
        let newRange = try #require(recurrence["range"] as? [String: Any])
        #expect(newRange["startDate"] as? String == String(GraphSplitFixture.recurrenceId.prefix(10)), "\(rangeType): \(canonical(newRange))")
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

    @Test("a series that already ends on this split's cap is not split again: refused with nothing written, an occurrence listed there or not (#601)",
          arguments: [false, true])
    func ownCapIsNotSplitAgain(_ listed: Bool) async throws {
        // What a row queued before #601 reads when its cap was written and its create was not:
        // Outlook capped first then. A retry now finds a split only through its record, and a
        // series that already ends before the split has nothing to split.
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let cap = try #require(GraphFixture.capEndDate(GraphSplitFixture.recurrenceId, zone: .current, keptIn: "Pacific Standard Time"))
        let series = GraphSplitFixture.series(range: ["type": "endDate", "endDate": cap, "numberOfOccurrences": 0])
        let graph = GraphSplitFixture.calendar(series, listed: listed)
        graph.install(on: http)
        await #expect(throws: (any Error).self) {
            _ = try await GraphSplitFixture.provider(http).splitSeries(
                eventId: "ser-1", recurrenceId: GraphSplitFixture.recurrenceId, recurrenceIdZone: .current, patch: GCalEventInput())
        }
        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "written: \(http.servedCallSequence())")
        #expect(graph.created.isEmpty)
        #expect(canonical(graph.event("ser-1")?["recurrence"]) == canonical(series["recurrence"]), "the series was changed")
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
        // The day before the split occurrence's day in the series' zone, where Graph reads it (#681).
        #expect(range["endDate"] as? String == GraphFixture.capEndDate(GraphSplitFixture.recurrenceId, zone: .current, keptIn: "Pacific Standard Time"),
                "\(rangeType): \(canonical(range))")
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

    @Test("a failed create leaves the series untouched: the new part is written before the cap (#601)")
    func failedCreateLeavesTheSeriesUntouched() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let series = GraphSplitFixture.series(range: GraphSplitFixture.numbered)
        let graph = GraphSplitFixture.calendar(series)
        graph.install(on: http)
        graph.failNext("POST", with: 400)
        let records = SplitRecordBox()
        await #expect(throws: (any Error).self) {
            _ = try await GraphSplitFixture.provider(http).splitSeries(
                calendarId: "primary", eventId: "ser-1", recurrenceId: GraphSplitFixture.recurrenceId,
                recurrenceIdZone: .current, patch: GCalEventInput(), sendUpdates: "all", record: records.recorder)
        }
        #expect(graph.patches("ser-1").isEmpty, "the series was written: \(graph.writes)")
        #expect(canonical(graph.event("ser-1")?["recurrence"]) == canonical(series["recurrence"]),
                "the series' recurrence changed: \(canonical(graph.event("ser-1")?["recurrence"]))")
        #expect(graph.created.isEmpty)
        #expect(records.records.isEmpty, "a record was kept for a create that failed: \(records.records)")
    }

    @Test("a split whose edit moves the new part's start past the series' end date is refused with nothing written")
    func newStartPastTheEndDateIsRefused() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        // The series ends the day after the occurrence the split is at; the edit moves the new
        // part three days later, past that end. The occurrence is listed, so the lookup passes.
        let end = GraphFixture.deviceDay(GraphFixture.onDevice(days: 8, hour: 10))
        let series = GraphSplitFixture.series(range: ["type": "endDate", "endDate": end, "numberOfOccurrences": 0])
        let graph = GraphSplitFixture.calendar(series)
        graph.install(on: http)
        var patch = GCalEventInput()
        let moved = GraphSplitFixture.occurrence.addingTimeInterval(3 * 86_400)
        patch.startDateTime = moved.iso8601String(timeZone: .current)
        patch.endDateTime = moved.addingTimeInterval(1_800).iso8601String(timeZone: .current)
        var reason: String?
        do {
            _ = try await GraphSplitFixture.provider(http).splitSeries(
                eventId: "ser-1", recurrenceId: GraphSplitFixture.recurrenceId, recurrenceIdZone: .current, patch: patch)
        } catch CalendarProviderError.notSupported(let thrown) {
            reason = thrown
        }
        #expect(reason?.contains("already ends before") == true, "not refused as ending before: \(reason ?? "none")")
        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "written: \(http.servedCallSequence())")
        #expect(graph.created.isEmpty)
        #expect(canonical(graph.event("ser-1")?["recurrence"]) == canonical(series["recurrence"]), "the series was changed")
    }

    @Test("a failed record stops the split before the cap: the series is not capped (#601)")
    func failedRecordStopsBeforeTheCap() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let series = GraphSplitFixture.series(range: GraphSplitFixture.numbered)
        let graph = GraphSplitFixture.calendar(series)
        graph.install(on: http)
        let records = SplitRecordBox(failWith: SplitRecord.OperationGone())
        await #expect(throws: SplitRecord.OperationGone.self) {
            _ = try await GraphSplitFixture.provider(http).splitSeries(
                calendarId: "primary", eventId: "ser-1", recurrenceId: GraphSplitFixture.recurrenceId,
                recurrenceIdZone: .current, patch: GCalEventInput(), sendUpdates: "all", record: records.recorder)
        }
        #expect(graph.patches("ser-1").isEmpty, "the series was capped without a kept record: \(graph.writes)")
        #expect(graph.writes == ["POST"], "\(graph.writes)")
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
                // A moved occurrence is split at its place (#687), like a plain one.
                #expect(reason == nil, "\(label): refused: \(reason ?? "")")
                #expect(graph.created.count == 1, "\(label): no new part: \(http.servedCallSequence())")
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

@Suite("Outlook split copies the series' files onto the new part (#563)", .serialized)
struct ExchangeSplitAttachmentTests {
    /// A small file, sent in one POST, and one an upload session takes in more than one range: at
    /// Graph's own edges (`GraphAttachmentLimits`), never the app's constant.
    private static let small = Data("Agenda for the series\n".utf8)
    private static let large = Data((0..<(max(GraphAttachmentLimits.singlePostMaxExclusive, ExchangeDraftConfig.uploadChunkBytes) + 1))
        .map { UInt8(truncatingIfNeeded: $0 &* 31) })

    /// A calendar holding the numbered series `ser-1` with the files `files` attached.
    private static func calendar(_ files: [(name: String, bytes: Data)]) -> FakeGraphCalendar {
        let graph = GraphSplitFixture.calendar(GraphSplitFixture.series(range: GraphSplitFixture.numbered))
        for file in files {
            graph.attachFile(file.name, contentType: "application/octet-stream", bytes: file.bytes, to: "ser-1")
        }
        return graph
    }

    private static func split(_ graph: FakeGraphCalendar, _ http: FakeHTTP.Scenario, records: SplitRecordBox) async -> Error? {
        var patch = GCalEventInput()
        patch.summary = "Planning (phase 2)"
        do {
            _ = try await GraphSplitFixture.provider(http).splitSeries(
                calendarId: "primary", eventId: "ser-1", recurrenceId: GraphSplitFixture.recurrenceId,
                recurrenceIdZone: .current, patch: patch, sendUpdates: "all", record: records.recorder)
            return nil
        } catch {
            return error
        }
    }

    /// The files an event holds, by name, in name order.
    private static func files(_ graph: FakeGraphCalendar, _ id: String) -> [String: Data] {
        Dictionary(graph.files(of: id).map { ($0.name, $0.bytes) }, uniquingKeysWith: { a, _ in a })
    }

    @Test("the new part holds every file of the series, a small one and one an upload session takes, byte for byte, before the cap")
    func newPartKeepsTheSeriesFiles() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = Self.calendar([("agenda.txt", Self.small), ("deck.bin", Self.large)])
        graph.install(on: http)
        let error = await Self.split(graph, http, records: SplitRecordBox())
        #expect(error == nil, "\(String(describing: error)); \(http.servedCallSequence())")
        let partId = try #require(graph.created.first?["id"] as? String, "no new part was created")

        // What Outlook's own split keeps on the new part (measured 2026-11-13): every file.
        let onPart = Self.files(graph, partId)
        #expect(onPart.keys.sorted() == ["agenda.txt", "deck.bin"], "the new part holds \(onPart.keys.sorted())")
        #expect(onPart["agenda.txt"] == Self.small, "the small file changed on the new part")
        #expect(onPart["deck.bin"] == Self.large, "the large file changed on the new part: \(onPart["deck.bin"]?.count ?? 0) bytes")
        #expect(graph.attachments(of: partId).count == 2, "a file was added twice: \(graph.attachments(of: partId).count)")
        // The series keeps its own.
        #expect(Self.files(graph, "ser-1").keys.sorted() == ["agenda.txt", "deck.bin"])
        // The upload session's ranges carry no bearer token.
        #expect(!graph.uploadAuthorizations.isEmpty && graph.uploadAuthorizations.allSatisfy { $0 == nil },
                "upload ranges: \(graph.uploadAuthorizations)")
        // Every file lands before the series is capped, so a series capped holds a complete new part.
        let calls = http.recordedCalls()
        let lastFile = try #require(calls.lastIndex { $0.url.contains("AttachmentSessions") || ($0.method == "POST" && $0.url.hasSuffix("/attachments")) })
        let cap = try #require(calls.firstIndex { $0.method == "PATCH" && URL(string: $0.url)?.path.hasSuffix("/events/ser-1") == true },
                               "the series was not capped")
        #expect(lastFile < cap, "a file was copied after the cap: \(http.servedCallSequence())")
    }

    @Test("a file copy that fails stops the split before the cap; the retry (finishSplit) adds only what is missing, then caps")
    func failedCopyStopsBeforeTheCapAndTheRetryFinishes() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = Self.calendar([("agenda.txt", Self.small), ("deck.bin", Self.large)])
        graph.install(on: http)
        graph.failNext("PUT", with: 503)
        let records = SplitRecordBox()
        let error = await Self.split(graph, http, records: records)
        #expect(error != nil, "the failed upload did not stop the split: \(http.servedCallSequence())")
        #expect(graph.patches("ser-1").isEmpty, "the series was capped though a file was not copied: \(http.servedCallSequence())")
        let record = try #require(records.records.first, "no record was kept before the copy")

        try await GraphSplitFixture.provider(http).finishSplit(record: record, zone: .current, guests: nil)
        let onPart = Self.files(graph, record.newPartId)
        #expect(onPart["agenda.txt"] == Self.small && onPart["deck.bin"] == Self.large, "the retry did not copy every file: \(onPart.keys.sorted())")
        #expect(graph.attachments(of: record.newPartId).count == 2,
                "the retry added a file the first attempt had copied: \(graph.attachments(of: record.newPartId).compactMap { $0["name"] as? String })")
        #expect(!graph.patches("ser-1").isEmpty, "the retry did not cap: \(http.servedCallSequence())")
    }

    @Test("an inline picture of the series reaches the new part placed inline under the same contentId, by a single POST and by an upload session")
    func inlinePictureStaysInline() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphSplitFixture.calendar(GraphSplitFixture.series(range: GraphSplitFixture.numbered))
        graph.attachFile("logo.png", contentType: "image/png", bytes: Self.small, to: "ser-1", isInline: true, contentId: "logo@series.example.com")
        graph.attachFile("banner.png", contentType: "image/png", bytes: Self.large, to: "ser-1", isInline: true, contentId: "banner@series.example.com")
        graph.attachFile("agenda.txt", contentType: "text/plain", bytes: Self.small, to: "ser-1")
        graph.install(on: http)
        let error = await Self.split(graph, http, records: SplitRecordBox())
        #expect(error == nil, "\(String(describing: error)); \(http.servedCallSequence())")
        let partId = try #require(graph.created.first?["id"] as? String, "no new part was created")
        let byName = Dictionary(graph.attachments(of: partId).compactMap { a in (a["name"] as? String).map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        for (name, cid) in [("logo.png", "logo@series.example.com"), ("banner.png", "banner@series.example.com")] {
            #expect(byName[name]?["isInline"] as? Bool == true, "\(name) is not inline on the new part: \(byName[name] ?? [:])")
            #expect(byName[name]?["contentId"] as? String == cid, "\(name) lost its contentId: \(byName[name]?["contentId"] ?? "none")")
        }
        #expect(byName["agenda.txt"]?["isInline"] as? Bool == false && byName["agenda.txt"]?["contentId"] == nil,
                "an ordinary file became inline: \(byName["agenda.txt"] ?? [:])")
    }

    /// The item attachments an event holds: name and item.
    private static func items(_ graph: FakeGraphCalendar, _ id: String) -> [(name: String, item: [String: Any])] {
        graph.attachments(of: id).compactMap { a in
            guard a["@odata.type"] as? String == "#microsoft.graph.itemAttachment", let name = a["name"] as? String,
                  let item = a["item"] as? [String: Any] else { return nil }
            return (name, item)
        }
    }

    /// A received email attached to the series, as `$expand` reads it (the keys measured
    /// 2026-11-13), with the headers every received mail carries. It holds no file of its own.
    static var receivedMail: [String: Any] {
        let person: (String) -> [String: Any] = { ["emailAddress": ["name": "Person \($0)", "address": "\($0)@example.com"]] }
        return [
            "@odata.type": "#microsoft.graph.message", "id": "mail-1", "createdDateTime": "2099-01-01T00:00:00Z",
            "lastModifiedDateTime": "2099-01-02T00:00:00Z", "sentDateTime": "2099-01-01T00:00:00Z", "hasAttachments": false,
            "subject": "Quarterly numbers", "conversationId": "conv-1", "conversationIndex": "index-1",
            "isReadReceiptRequested": false, "isRead": true, "isDraft": false, "webLink": "https://outlook.example.com/mail-1",
            "internetMessageHeaders": (1...8).map { ["name": "X-Header-\($0)", "value": "v\($0)"] },
            "body": ["contentType": "html", "content": "<p>The numbers</p>"], "sender": person("sender"), "from": person("sender"),
            "toRecipients": [person("to")], "ccRecipients": [person("cc")], "flag": ["flagStatus": "notFlagged"],
        ]
    }

    /// An event attached to the series, as `$expand` reads it (the keys measured 2026-11-13).
    static var attachedEvent: [String: Any] { [
        "@odata.type": "#microsoft.graph.event", "id": "ev-1", "createdDateTime": "2099-01-01T00:00:00Z",
        "lastModifiedDateTime": "2099-01-02T00:00:00Z", "categories": ["Blue category"], "originalStartTimeZone": "UTC",
        "originalEndTimeZone": "UTC", "reminderMinutesBeforeStart": 17, "isReminderOn": true, "hasAttachments": false,
        "subject": "Offsite", "importance": "high", "sensitivity": "private", "isAllDay": false, "isCancelled": false,
        "isOrganizer": true, "responseRequested": true, "showAs": "tentative", "type": "singleInstance", "isOnlineMeeting": false,
        "isDraft": true, "body": ["contentType": "html", "content": "<p>Offsite plan</p>"],
        "start": ["dateTime": "2099-06-01T17:00:00.0000000", "timeZone": "UTC"],
        "end": ["dateTime": "2099-06-01T17:30:00.0000000", "timeZone": "UTC"],
        "location": ["displayName": "Room 1", "locationType": "default", "uniqueIdType": "unknown"],
        "organizer": ["emailAddress": ["name": "Organizer", "address": "organizer@example.com"]],
    ] }

    /// A contact attached to the series, as `$expand` reads it (the keys measured 2026-11-13).
    static var attachedContact: [String: Any] { [
        "@odata.type": "#microsoft.graph.contact", "id": "ct-1", "createdDateTime": "2099-01-01T00:00:00Z",
        "lastModifiedDateTime": "2099-01-02T00:00:00Z", "fileAs": "Inner, Probe", "displayName": "Probe Inner",
        "givenName": "Probe", "surname": "Inner", "jobTitle": "Tester", "companyName": "Company", "businessPhones": ["555-0100"],
        "personalNotes": "notes", "emailAddresses": [["name": "Probe Inner", "address": "probe@example.com"]],
        "primaryEmailAddress": ["name": "Probe Inner", "address": "probe@example.com"],
    ] }

    /// `receivedMail` holding a file of its own, as `$expand` reads an attached email that has one
    /// (measured 2026-11-13: `hasAttachments` true and the file in `attachments`, with its bytes).
    static var receivedMailWithFile: [String: Any] {
        var mail = receivedMail
        mail["id"] = "mail-2"
        mail["subject"] = "Signed contract"
        mail["hasAttachments"] = true
        mail["attachments"] = [["@odata.type": "#microsoft.graph.fileAttachment", "id": "inner-1", "name": "contract.txt",
                                "contentType": "text/plain", "size": 108, "isInline": false, "contentBytes": "Y29udHJhY3Q="]]
        return mail
    }

    /// The attached Outlook item of the kind `kind`, as `$expand` reads it: "email", "email with
    /// file", "event", "contact", or "post" (a kind no case names).
    static func item(_ kind: String) -> [String: Any] {
        var post = attachedContact
        post["@odata.type"] = "#microsoft.graph.post"
        return ["email": receivedMail, "email with file": receivedMailWithFile, "event": attachedEvent,
                "contact": attachedContact, "post": post][kind] ?? [:]
    }

    @Test("""
        an attached Outlook item of any kind or size on the series (an email with files of its own or none, an event, a \
        contact, any other kind, one of 3 MB or more, one listed with no size) is not copied, read or written: the split \
        completes with the series' files, and the old part keeps the item (#835, #845, #846, #852, #854)
        """,
          arguments: ["email", "email with file", "event", "contact", "post", "large contact", "unsized contact"])
    func seriesItemIsLeftOnTheOldPart(kind: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = Self.calendar([("agenda.txt", Self.small)])
        let name = "Series \(kind)"
        let size = kind == "large contact" ? ExchangeDraftConfig.singlePostAttachmentLimitBytes : nil
        graph.attachItem(name, item: Self.item(kind.hasSuffix("contact") ? "contact" : kind), to: "ser-1", size: size,
                         listsSize: kind != "unsized contact")
        let itemId = try #require(graph.attachments(of: "ser-1").first { $0["name"] as? String == name }?["id"] as? String)
        graph.install(on: http)
        let error = await Self.split(graph, http, records: SplitRecordBox())
        #expect(error == nil, "\(kind): \(String(describing: error)); \(http.servedCallSequence())")
        let partId = try #require(graph.created.first?["id"] as? String, "\(kind): no new part was created")
        #expect(graph.attachments(of: partId).compactMap { $0["name"] as? String } == ["agenda.txt"],
                "\(kind): the new part holds \(graph.attachments(of: partId).compactMap { $0["name"] as? String })")
        let posts = http.recordedCalls().filter { $0.method == "POST" && $0.url.contains("/attachments") }
        #expect(posts.count == 1, "\(kind): a write was attempted for the item: \(posts.map(\.url))")
        #expect(!http.recordedCalls().contains { $0.url.contains(itemId) || $0.url.lowercased().contains("itemattachment") },
                "\(kind): the item was read: \(http.servedCallSequence())")
        #expect(Self.items(graph, "ser-1").map(\.name) == [name] && graph.attachments(of: "ser-1").count == 2,
                "\(kind): the series' attachments changed")
        #expect(!graph.patches("ser-1").isEmpty, "\(kind): the series was not capped")
    }

    @Test("a series holding a linked file is refused before any write: no new part, no copy, no change, no cap, with the calendar-app message")
    func linkedFileRefusesTheSplitUnwritten() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = Self.calendar([("agenda.txt", Self.small)])
        graph.attachItem("Probe Inner", item: Self.attachedContact, to: "ser-1")
        graph.attachOther("#microsoft.graph.referenceAttachment", name: "Shared deck", to: "ser-1")
        let before = graph.attachments(of: "ser-1").count
        graph.install(on: http)
        let records = SplitRecordBox()
        let error = await Self.split(graph, http, records: records)
        let writes = http.recordedCalls().filter { $0.method != "GET" }
        #expect(writes.isEmpty, "a write was sent: \(writes.map { "\($0.method) \($0.url)" })")
        #expect(graph.created.isEmpty && records.records.isEmpty, "a new part or a record was made")
        #expect(graph.attachments(of: "ser-1").count == before, "the series' attachments changed")
        var message: String?
        if case .notSupported(let said)? = error as? CalendarProviderError { message = said }
        #expect(message == Self.linkedFileMessage, "the refusal: \(String(describing: error))")
    }

    /// The refusal of a split that would leave a linked file behind (#834), as the user reads it.
    static let linkedFileMessage =
        "This repeating event has a linked file TabMail can't copy to the new part, so it was not changed. Make the change in your calendar app."

    /// The refusal of a split that carries a changed occurrence holding an attached Outlook item
    /// (#847, #854), as the user reads it.
    static let uncopiedItemMessage =
        "This repeating event has an attached Outlook item TabMail can't copy to the new part, so it was not changed. Make the change in your calendar app."

    @Test("a linked file the series gained after the first attempt does not stop the retry: the new part exists, so finishSplit copies the rest and caps")
    func retryLeavesALaterLinkedFile() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = Self.calendar([("agenda.txt", Self.small)])
        graph.install(on: http)
        graph.failNext("PATCH", with: 400)   // the cap is refused (a 503 is retried); the record is kept
        let records = SplitRecordBox()
        _ = await Self.split(graph, http, records: records)
        let record = try #require(records.records.first, "no record was kept")
        #expect(graph.patches("ser-1").isEmpty, "non-vacuity: the first attempt capped")
        graph.attachOther("#microsoft.graph.referenceAttachment", name: "Shared deck", to: "ser-1")
        try await GraphSplitFixture.provider(http).finishSplit(record: record, zone: .current, guests: nil)
        #expect(graph.attachments(of: record.newPartId).compactMap { $0["name"] as? String } == ["agenda.txt"],
                "the new part holds \(graph.attachments(of: record.newPartId).compactMap { $0["name"] as? String })")
        #expect(!graph.patches("ser-1").isEmpty, "the retry did not cap: \(http.servedCallSequence())")
    }

    @Test("a retry keeps two files of the same name and a file with no name: each is added once, the unnamed one as a draft names it")
    func retryKeepsSameNamedAndUnnamedFiles() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let other = Data("A second picture, same name\n".utf8)
        let graph = Self.calendar([("image.png", Self.small), ("image.png", Self.large)])
        graph.attachFile(nil, contentType: "text/plain", bytes: other, to: "ser-1")
        graph.install(on: http)
        // The first image.png lands by a single POST; the second's upload range fails.
        graph.failNext("PUT", with: 503)
        let records = SplitRecordBox()
        let error = await Self.split(graph, http, records: records)
        #expect(error != nil, "the failed upload did not stop the split")
        let record = try #require(records.records.first, "no record was kept")
        #expect(graph.attachments(of: record.newPartId).count == 1, "non-vacuity: the first attempt copied \(graph.attachments(of: record.newPartId).count)")
        try await GraphSplitFixture.provider(http).finishSplit(record: record, zone: .current, guests: nil)
        let held = graph.files(of: record.newPartId)
        #expect(held.filter { $0.name == "image.png" }.map(\.bytes).sorted { $0.count < $1.count } == [Self.small, Self.large],
                "the same-named files on the new part: \(held.map { ($0.name, $0.bytes.count) })")
        #expect(held.filter { $0.name == DraftReadConfig.unnamedAttachmentFilename }.map(\.bytes) == [other],
                "the unnamed file: \(held.map { ($0.name, $0.bytes.count) })")
        #expect(held.count == 3, "a file was added twice or lost: \(held.map(\.name))")
        #expect(!graph.patches("ser-1").isEmpty, "the retry did not cap")
    }

    @Test("an attachment list Graph pages is read to its end on the series and on the new part")
    func pagedAttachmentListIsReadToTheEnd() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = Self.calendar([("a.txt", Self.small), ("b.txt", Self.small), ("c.txt", Self.small)])
        graph.attachmentPageSize.withLock { $0 = 1 }
        graph.install(on: http)
        let records = SplitRecordBox()
        graph.failNext("PATCH", with: 503)   // the cap fails; the retry reads the new part's three pages
        _ = await Self.split(graph, http, records: records)
        let record = try #require(records.records.first, "no record was kept")
        #expect(graph.files(of: record.newPartId).map(\.name).sorted() == ["a.txt", "b.txt", "c.txt"],
                "the new part holds \(graph.files(of: record.newPartId).map(\.name))")
        try await GraphSplitFixture.provider(http).finishSplit(record: record, zone: .current, guests: nil)
        #expect(graph.files(of: record.newPartId).map(\.name).sorted() == ["a.txt", "b.txt", "c.txt"],
                "the retry added a file again: \(graph.files(of: record.newPartId).map(\.name))")
        #expect(http.recordedCalls().contains { $0.url.contains("skip=2") }, "non-vacuity: no third page was read")
    }

    @Test("a draft's file is written with no inline placement, exactly the four keys it had; a split's inline picture adds isInline and contentId")
    func draftWireIsUnchanged() {
        let file = DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Self.small)
        #expect(Set(ExchangeProvider.graphFileAttachment(file).keys) == ["@odata.type", "name", "contentType", "contentBytes"])
        #expect(GraphInlinePlacement(isInline: nil, contentId: nil) == nil && GraphInlinePlacement(isInline: nil, contentId: "") == nil)
        let placed = ExchangeProvider.graphFileAttachment(file, inline: GraphInlinePlacement(isInline: true, contentId: "logo@example.com"))
        #expect(placed["isInline"] as? Bool == true && placed["contentId"] as? String == "logo@example.com")
    }
}
