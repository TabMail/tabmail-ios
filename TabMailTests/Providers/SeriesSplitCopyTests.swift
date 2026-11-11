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

    /// Split `master` at `recurrenceId` with `patch` against a fake Google calendar.
    static func split(_ master: [String: Any], recurrenceId: String = recurrenceId,
                      patch: GCalEventInput) async throws -> Wire {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let ok = ["Content-Type": "application/json"]
        // swiftlint:disable:next force_try
        let stored = try! JSONSerialization.data(withJSONObject: master)
        http.register(path: masterPath, method: "GET", response: .raw(statusCode: 200, headers: ok, body: stored))
        http.register(path: masterPath, method: "PATCH", response: .raw(statusCode: 200, headers: ok, body: stored))
        http.register(path: createPath, method: "POST") { request in
            .raw(statusCode: 200, headers: ok, body: request.body ?? Data())
        }
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        _ = try await provider.splitSeries(
            eventId: "master-1", recurrenceId: recurrenceId, recurrenceIdZone: utc, patch: patch)
        return wire(http)
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

    @Test("an excluded or added date exactly at the split goes to the new part only", arguments: ["EXDATE", "RDATE"])
    func splitPointGoesToTheNewPart(_ kind: String) async throws {
        let master = GoogleSplitFixture.master(recurrence: [
            "RRULE:FREQ=WEEKLY;UNTIL=20991230T170000Z", "\(kind):20990520T170000Z",
        ])
        let wire = try await GoogleSplitFixture.split(master, patch: GCalEventInput())
        #expect(wire.patchedRecurrences == [["RRULE:FREQ=WEEKLY;UNTIL=20990520T165959Z"]],
                "\(kind): the capped series: \(wire.patchedRecurrences)")
        #expect(wire.created?["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;UNTIL=20991230T170000Z", "\(kind):20990520T170000Z"],
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

    @Test("an attendee the edit adds is asked; one it leaves out is removed; the others keep their entries")
    func attendeeChange() async throws {
        var patch = GCalEventInput()
        patch.attendees = [("olivia@example.com", nil), ("alice@example.com", "Alice"), ("carol@example.com", "Carol")]
        let wire = try await GoogleSplitFixture.split(GoogleSplitFixture.master(), patch: patch)
        let attendees = try #require(wire.created?["attendees"] as? [[String: Any]])
        #expect(attendees.compactMap { $0["email"] as? String } == ["olivia@example.com", "alice@example.com", "carol@example.com"])
        #expect(canonical(GoogleSplitFixture.attendee(wire.created, "carol@example.com"))
                == canonical(["email": "carol@example.com", "displayName": "Carol"]))
        let alice = GoogleSplitFixture.attendee(wire.created, "alice@example.com")
        #expect(alice?["optional"] as? Bool == true && alice?["responseStatus"] as? String == "accepted",
                "a staying attendee lost their entry: \(canonical(alice))")
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
}

@Suite("Outlook split keeps the series' properties", .serialized)
struct ExchangeSeriesSplitCopyTests {

    private func split(_ series: [String: Any], patch: GCalEventInput) async throws -> (FakeGraphCalendar, [String: Any]) {
        let (graph, created, _) = try await splitOnTheWire(series, patch: patch)
        return (graph, created)
    }

    /// The split, with the create's body exactly as it was sent.
    private func splitOnTheWire(_ series: [String: Any], patch: GCalEventInput)
        async throws -> (FakeGraphCalendar, [String: Any], [String: Any]) {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([series])
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
            #expect(newRange["type"] as? String == "endDate" && newRange["endDate"] as? String == range["endDate"] as? String,
                    "the new part lost the series' end date: \(canonical(newRange))")
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
        let (_, _, sent) = try await splitOnTheWire(series, patch: GCalEventInput())

        let recurrence = try #require(sent["recurrence"] as? [String: Any])
        let range = try #require(recurrence["range"] as? [String: Any])
        #expect(range["type"] as? String == "noEnd" && range["endDate"] == nil,
                "the new part would end before it starts: \(canonical(range))")
        #expect(range["startDate"] as? String == String(GraphSplitFixture.recurrenceId.prefix(10)), "\(canonical(range))")
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
        patch.attendees = [("ana@example.com", "Ana"), ("bo@example.com", "Bo"), ("cy@example.com", "Cy")]
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
        let graph = FakeGraphCalendar([series])
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
        let graph = FakeGraphCalendar([series])
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
}
