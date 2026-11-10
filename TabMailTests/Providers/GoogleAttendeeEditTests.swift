/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// A Google edit that adds or removes an attendee writes the whole attendee list, which Google
// stores as sent. Each test reads the PATCH body the server was sent: every attendee the edit keeps
// must arrive as the stored event holds them, so their role, answer and other fields stay.

private enum AttendeeEditFixture {
    static let eventPath = "/calendar/v3/calendars/primary/events/evt-1"
    static let masterPath = "/calendar/v3/calendars/primary/events/m1"
    static let instancePath = "/calendar/v3/calendars/primary/events/m1_20990520T170000Z"
    static let utc = TimeZone(identifier: "UTC")!

    static var attendees: [[String: Any]] { [
        ["email": "olivia@example.com", "organizer": true, "self": true, "responseStatus": "accepted"],
        ["email": "alice@example.com", "displayName": "Alice", "optional": true, "responseStatus": "tentative",
         "comment": "Might be late", "id": "profile-1"],
        ["email": "room-1@example.com", "displayName": "Room 1", "resource": true, "responseStatus": "accepted"],
        ["email": "bob@example.com", "responseStatus": "declined", "additionalGuests": 1],
    ] }

    static func event(id: String, attendees: [[String: Any]] = attendees, extra: [String: Any] = [:]) -> [String: Any] {
        var event: [String: Any] = [
            "kind": "calendar#event", "etag": "\"2\"", "id": id, "status": "confirmed",
            "summary": "Planning", "description": "Agenda", "location": "Room 1",
            "organizer": ["email": "olivia@example.com", "self": true],
            "start": ["dateTime": "2099-05-20T17:00:00Z", "timeZone": "UTC"],
            "end": ["dateTime": "2099-05-20T17:45:00Z", "timeZone": "UTC"],
            "attendees": attendees,
        ]
        event.merge(extra) { _, new in new }
        return event
    }

    /// The attendee list an edit asks for: every stored attendee by address and name, as the edit
    /// queue resolves an add or remove, with `adding` appended and `removing` left out.
    static func wanted(adding: [(email: String, name: String?)] = [], removing: Set<String> = [],
                       from stored: [[String: Any]] = attendees) -> [(email: String, name: String?)] {
        stored.compactMap { attendee -> (email: String, name: String?)? in
            guard let email = attendee["email"] as? String, !removing.contains(email) else { return nil }
            return (email: email, name: attendee["displayName"] as? String)
        } + adding
    }

    static func data(_ object: [String: Any]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// The JSON bodies of the PATCHes the fake calendar received.
    static func patches(_ http: FakeHTTP.Scenario) -> [[String: Any]] {
        http.recordedCalls().filter { $0.method == "PATCH" }.compactMap { call in
            call.body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
    }

    /// Edit the single event `stored` with `patch` against a fake Google calendar.
    static func editEvent(_ stored: [String: Any], patch: GCalEventInput) async throws -> [[String: Any]] {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let ok = ["Content-Type": "application/json"]
        http.register(path: eventPath, method: "GET", response: .raw(statusCode: 200, headers: ok, body: data(stored)))
        http.register(path: eventPath, method: "PATCH", response: .raw(statusCode: 200, headers: ok, body: data(stored)))
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        _ = try await provider.updateEvent(calendarId: "primary", eventId: "evt-1", event: patch, sendUpdates: "all")
        return patches(http)
    }

    /// Edit the 2099-05-20 17:00 UTC occurrence of series `m1`, whose stored instance is `instance`.
    static func editOccurrence(_ instance: [String: Any], patch: GCalEventInput) async throws -> [[String: Any]] {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let ok = ["Content-Type": "application/json"]
        let master = event(id: "m1", extra: [
            "start": ["dateTime": "2099-05-06T17:00:00Z", "timeZone": "UTC"],
            "end": ["dateTime": "2099-05-06T17:45:00Z", "timeZone": "UTC"],
            "recurrence": ["RRULE:FREQ=WEEKLY"],
        ])
        http.register(path: masterPath, method: "GET", response: .raw(statusCode: 200, headers: ok, body: data(master)))
        http.register(path: masterPath + "/instances", method: "GET",
                      response: .raw(statusCode: 200, headers: ok, body: data(["items": [instance]])))
        http.register(path: instancePath, method: "GET", response: .raw(statusCode: 200, headers: ok, body: data(instance)))
        http.register(path: instancePath, method: "PATCH", response: .raw(statusCode: 200, headers: ok, body: data(instance)))
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        _ = try await provider.updateOccurrence(
            calendarId: "primary", eventId: "m1", recurrenceId: "2099-05-20T17:00:00", recurrenceIdZone: utc,
            event: patch, sendUpdates: "all")
        return patches(http)
    }

    /// A JSON value written with sorted keys, for comparing what was stored with what was sent.
    static func canonical(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func sent(_ patch: [String: Any]?, _ address: String) -> [String: Any]? {
        (patch?["attendees"] as? [[String: Any]])?.first { ($0["email"] as? String)?.lowercased() == address }
    }

    static func stored(_ address: String, in attendees: [[String: Any]] = attendees) -> [String: Any]? {
        attendees.first { ($0["email"] as? String) == address }
    }
}

@Suite("A Google attendee edit changes only that attendee", .serialized)
struct GoogleAttendeeEditTests {
    private typealias F = AttendeeEditFixture

    @Test("adding an attendee keeps everyone else as stored and invites only the new one")
    func addKeepsTheOthers() async throws {
        var patch = GCalEventInput()
        patch.attendees = F.wanted(adding: [(email: "carol@example.com", name: "Carol")])

        let patches = try await F.editEvent(F.event(id: "evt-1"), patch: patch)

        #expect(patches.count == 1)
        guard patches.count == 1 else { return }
        for address in ["olivia@example.com", "alice@example.com", "room-1@example.com", "bob@example.com"] {
            #expect(F.canonical(F.sent(patches[0], address)) == F.canonical(F.stored(address)),
                    "\(address) was not sent as stored")
        }
        #expect(F.canonical(F.sent(patches[0], "carol@example.com"))
            == F.canonical(["email": "carol@example.com", "displayName": "Carol"]))
        #expect((patches[0]["attendees"] as? [[String: Any]])?.count == 5)
    }

    @Test("removing an attendee drops only that one and keeps everyone else as stored")
    func removeKeepsTheOthers() async throws {
        var patch = GCalEventInput()
        patch.attendees = F.wanted(removing: ["bob@example.com"])

        let patches = try await F.editEvent(F.event(id: "evt-1"), patch: patch)

        #expect(patches.count == 1)
        guard patches.count == 1 else { return }
        #expect(F.sent(patches[0], "bob@example.com") == nil)
        for address in ["olivia@example.com", "alice@example.com", "room-1@example.com"] {
            #expect(F.canonical(F.sent(patches[0], address)) == F.canonical(F.stored(address)),
                    "\(address) was not sent as stored")
        }
        #expect((patches[0]["attendees"] as? [[String: Any]])?.count == 3)
    }

    @Test("an attendee named in another letter case is still matched to their stored entry")
    func addressCaseIsIgnored() async throws {
        var patch = GCalEventInput()
        patch.attendees = F.wanted(removing: ["alice@example.com"]) + [(email: "Alice@Example.com", name: nil)]

        let patches = try await F.editEvent(F.event(id: "evt-1"), patch: patch)

        #expect(patches.count == 1)
        guard patches.count == 1 else { return }
        #expect(F.canonical(F.sent(patches[0], "alice@example.com")) == F.canonical(F.stored("alice@example.com")))
        // The list goes out in the order the edit asks for, not the stored order.
        let sentOrder = (patches[0]["attendees"] as? [[String: Any]])?.compactMap { $0["email"] as? String }
        #expect(sentOrder == ["olivia@example.com", "room-1@example.com", "bob@example.com", "alice@example.com"])
    }

    @Test("an attendee stored in capitals is still matched to their stored entry")
    func storedAddressCaseIsIgnored() async throws {
        var stored = F.attendees
        stored[3]["email"] = "Bob@Example.com"
        var patch = GCalEventInput()
        // The queue builds the wanted list from the stored entries, so Bob keeps his capitals here.
        patch.attendees = F.wanted(adding: [(email: "carol@example.com", name: nil)], from: stored)

        let patches = try await F.editEvent(F.event(id: "evt-1", attendees: stored), patch: patch)

        #expect(patches.count == 1)
        guard patches.count == 1 else { return }
        #expect(F.canonical(F.sent(patches[0], "bob@example.com")) == F.canonical(stored[3]))
        #expect((patches[0]["attendees"] as? [[String: Any]])?.count == 5)
    }

    @Test("adding the first attendee to an event with none sends just that attendee")
    func firstAttendeeOnAnEventWithNone() async throws {
        var event = F.event(id: "evt-1")
        event.removeValue(forKey: "attendees")
        var patch = GCalEventInput()
        patch.attendees = [(email: "carol@example.com", name: "Carol")]

        let patches = try await F.editEvent(event, patch: patch)

        #expect(patches.count == 1)
        guard patches.count == 1 else { return }
        #expect(F.canonical(patches[0]["attendees"])
            == F.canonical([["email": "carol@example.com", "displayName": "Carol"]]))
    }

    @Test("an edit that names no attendee change sends no attendee list")
    func otherEditsSendNoAttendees() async throws {
        var patch = GCalEventInput()
        patch.summary = "Planning (moved)"

        let patches = try await F.editEvent(F.event(id: "evt-1"), patch: patch)

        #expect(patches.count == 1)
        guard patches.count == 1 else { return }
        #expect(patches[0]["summary"] as? String == "Planning (moved)")
        #expect(patches[0]["attendees"] == nil)
    }

    @Test("an occurrence edit keeps the occurrence's own stored attendees, not the series'")
    func occurrenceKeepsItsAttendees() async throws {
        // This occurrence was changed before: Alice declined it, and the room is not booked for it.
        let own: [[String: Any]] = [
            ["email": "olivia@example.com", "organizer": true, "self": true, "responseStatus": "accepted"],
            ["email": "alice@example.com", "displayName": "Alice", "optional": true, "responseStatus": "declined",
             "comment": "Away that week"],
            ["email": "bob@example.com", "responseStatus": "accepted", "additionalGuests": 2],
        ]
        let instance = F.event(id: "m1_20990520T170000Z", attendees: own, extra: [
            "recurringEventId": "m1",
            "originalStartTime": ["dateTime": "2099-05-20T17:00:00Z", "timeZone": "UTC"],
        ])
        var patch = GCalEventInput()
        patch.attendees = F.wanted(adding: [(email: "carol@example.com", name: nil)], from: own)

        let patches = try await F.editOccurrence(instance, patch: patch)

        #expect(patches.count == 1)
        guard patches.count == 1 else { return }
        for address in ["olivia@example.com", "alice@example.com", "bob@example.com"] {
            #expect(F.canonical(F.sent(patches[0], address)) == F.canonical(F.stored(address, in: own)),
                    "\(address) was not sent as the occurrence stores them")
        }
        #expect(F.canonical(F.sent(patches[0], "carol@example.com")) == F.canonical(["email": "carol@example.com"]))
        #expect((patches[0]["attendees"] as? [[String: Any]])?.count == 4)
        #expect(patches[0]["recurrence"] == nil)
    }
}
