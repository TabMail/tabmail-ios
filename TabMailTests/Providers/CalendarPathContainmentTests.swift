/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - R13-U1 — an event id may never redirect a calendar request
//
// INVARIANT (system property, stated once for both providers):
// **a string that arrives as a calendar/event id can change WHAT resource a
// request names, and nothing else. It can never change WHERE the request goes.**
//
// The two failures that violates:
//   * CalDAV — `CalDAVClient.setAuthHeader` attaches `Authorization: Basic …`
//     UNCONDITIONALLY, with no host check and no `URLSession` delegate. So an id
//     that moves the request's ORIGIN sends the account's password to that
//     origin. An RFC 3986 *network-path reference* (`//host/path`) does exactly
//     that: it carries no scheme, so a `hasPrefix("https://")` test does not see
//     it, yet resolving it against a base takes the **authority from the string**.
//     Nothing recovers a credential that has left the device.
//   * Google — every id is interpolated into `/calendars/{id}/events/{id}`, and
//     `.urlPathAllowed` passes `/` through unescaped, so an id can add path
//     segments and `..` can walk out of `/calendar/v3/` into a sibling Google API
//     under the same OAuth token.
//
// Reachable because the three calendar tools accept a NON-NUMERIC `event_id`
// verbatim from the model (see the block comment in `CalendarEventReadTool`),
// which is deliberately still true — the containment is asserted here, at the
// boundary where the string's provenance stops mattering, precisely so that the
// tools' recovery path does not have to be removed to make the system safe.
//
// ⚠️ EVERY REFUSAL TEST IS PAIRED WITH A CONTROL, and the controls are not
// decoration. "No request reached the wire" is satisfiable by a provider that
// cannot reach the wire at all, and by a fixture that never could (`MIS-030`).
// Each control proves the same call shape DOES reach the wire when the id is
// ordinary.
//
// ⚠️ TWO-SIDED ON SCOPE, TOO. `sameOrigin` compares scheme+host+port and
// deliberately NOT path: on iCloud a calendar shared by another user lives under
// the OWNER's principal path, outside our `calendarHomeURL`. The
// `sharedCalendarOutsideTheHomePathIsAccepted` test pins that, so a later
// "tighten it to a path prefix" edit fails here instead of silently breaking
// shared calendars in the field.

@Suite("R13-U1 — a calendar id cannot redirect the request")
struct CalendarPathContainmentTests {

    // MARK: - CalDAV

    private func makeCalDAV(_ http: FakeHTTP.Scenario) -> CalDAVProvider {
        let client = CalDAVClient(username: "user@example.com", password: "pw", session: http.session)
        return CalDAVProvider(
            client: client,
            calendarHomeURL: URL(string: "https://p01-caldav.example.com/1234567/calendars/")!,
            serverBaseURL: URL(string: "https://caldav.example.com/")!
        )
    }

    /// Every host any request in this scenario was actually sent to.
    private func hostsTouched(_ http: FakeHTTP.Scenario) -> [String] {
        http.recordedCalls().compactMap { URL(string: $0.url)?.host }
    }

    @Test("A network-path reference event id never reaches the wire — the account credential does not leave for another host")
    func networkPathReferenceIsRefused() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        // Answer ANY GET, so a request that did escape containment would be
        // served rather than erroring for an unrelated reason.
        http.register(path: "/", method: "GET", response: .raw(statusCode: 200, body: Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8)))
        let provider = makeCalDAV(http)

        await #expect(throws: (any Error).self) {
            // `//attacker.example/x` — no scheme, so the `hasPrefix("https://")`
            // branch does not fire; `URL(string:relativeTo:)` inherits `https`
            // and takes the authority from the string.
            _ = try await provider.getEvent(calendarId: "/1234567/calendars/work/", eventId: "//attacker.example/x")
        }

        let hosts = hostsTouched(http)
        #expect(hosts.isEmpty,
                "a request was issued for a network-path-reference event id; CalDAVClient attaches Basic auth unconditionally, so every host here received the account password: \(hosts)")
    }

    @Test("An absolute event id on a foreign origin never reaches the wire")
    func foreignAbsoluteOriginIsRefused() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/", method: "GET", response: .raw(statusCode: 200, body: Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8)))
        let provider = makeCalDAV(http)

        await #expect(throws: (any Error).self) {
            _ = try await provider.getEvent(calendarId: "/1234567/calendars/work/", eventId: "https://attacker.example/1234567/calendars/work/e.ics")
        }

        let hosts = hostsTouched(http)
        #expect(hosts.isEmpty,
                "an absolute foreign-origin href was dereferenced with the account credential attached: \(hosts)")
    }

    @Test("CONTROL — an ordinary relative href on the configured origin still reaches the wire")
    func ordinaryHrefStillReachesTheWire() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(
            path: "/1234567/calendars/work/e.ics",
            method: "GET",
            response: .raw(
                statusCode: 200,
                headers: ["ETag": "\"v1\""],
                body: Data(Self.minimalVEvent.utf8)))
        let provider = makeCalDAV(http)

        let event = try await provider.getEvent(
            calendarId: "/1234567/calendars/work/", eventId: "/1234567/calendars/work/e.ics")

        #expect(event.summary == "Quarterly review")
        let hosts = hostsTouched(http)
        #expect(hosts == ["p01-caldav.example.com"],
                "the fixture must be able to produce a CalDAV request at all, or the two absences above are vacuous (MIS-030) — got \(hosts)")
    }

    @Test("A same-origin ABSOLUTE href is still accepted — the guard is origin containment, not 'refuse anything absolute'")
    func sameOriginAbsoluteHrefIsAccepted() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(
            path: "/1234567/calendars/work/e.ics",
            method: "GET",
            response: .raw(statusCode: 200, body: Data(Self.minimalVEvent.utf8)))
        let provider = makeCalDAV(http)

        let event = try await provider.getEvent(
            calendarId: "/1234567/calendars/work/",
            eventId: "https://p01-caldav.example.com/1234567/calendars/work/e.ics")

        #expect(event.summary == "Quarterly review")
    }

    @Test("A shared calendar OUTSIDE the calendar-home path but on the same origin is accepted — the check is scheme+host+port, never path")
    func sharedCalendarOutsideTheHomePathIsAccepted() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        // iCloud puts a calendar shared BY ANOTHER USER under that user's own
        // principal id — a sibling of ours, not a descendant of our home path.
        http.register(
            path: "/9999999/calendars/team/e.ics",
            method: "GET",
            response: .raw(statusCode: 200, body: Data(Self.minimalVEvent.utf8)))
        let provider = makeCalDAV(http)

        let event = try await provider.getEvent(
            calendarId: "/9999999/calendars/team/", eventId: "/9999999/calendars/team/e.ics")

        #expect(event.summary == "Quarterly review",
                "a path-prefix containment check would reject this and break every shared calendar; the guard is deliberately origin-only")
    }

    @Test("An href on the PRE-redirect serverBaseURL host is accepted — both configured origins are trusted")
    func serverBaseURLOriginIsAccepted() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(
            path: "/1234567/calendars/work/e.ics",
            method: "GET",
            response: .raw(statusCode: 200, body: Data(Self.minimalVEvent.utf8)))
        let provider = makeCalDAV(http)

        let event = try await provider.getEvent(
            calendarId: "/1234567/calendars/work/",
            eventId: "https://caldav.example.com/1234567/calendars/work/e.ics")

        #expect(event.summary == "Quarterly review")
    }

    private static let minimalVEvent = """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    BEGIN:VEVENT\r
    UID:evt-1\r
    DTSTART:20260601T090000Z\r
    DTEND:20260601T100000Z\r
    SUMMARY:Quarterly review\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    // MARK: - Google
    //
    // Oracle: `GoogleCalendarProvider.request` calls `try await accessToken(false)`
    // as its FIRST statement, so no HTTP request can be formed without it. A
    // token closure that COUNTS and then THROWS therefore proves "the request was
    // refused before it could be built" using NO transport seam at all — and,
    // deliberately, with no test in this file able to reach the live internet
    // (`feedback_nil_defaulted_seam_is_fail_dangerous`).
    //
    // ⚠️ NARROWED (R14-F1): this used to read *"without adding a `URLSession` seam
    // to the provider"*, which now reads as a prohibition the provider violates.
    // `GoogleCalendarProvider` DOES have a transport seam today — a SEPARATE
    // `init(accessToken:session:)` taking a NON-OPTIONAL session, so a dropped
    // injection is a compile error rather than a silent live-internet fallback
    // (the same shape as `CalDAVClient`'s pair, and deliberately *not*
    // `GmailProvider`'s `session: URLSession? = nil`). It exists because
    // `CalendarConflictDispositionTests` must prove a property OF THE TRANSPORT
    // SEAM, which a mock `CalendarProvider` cannot reach. The claim that survives,
    // and the only one this file needs, is the narrower one: **these path-
    // containment proofs need no session, because the refusal happens before the
    // token is even requested.** Do not "modernise" them onto the seam — the
    // absence of a session is what makes `spy.calls == 0` mean what it says.

    private final class TokenSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func record() { lock.lock(); _calls += 1; lock.unlock() }
    }

    private struct TokenReached: Error {}

    private func makeGoogle(_ spy: TokenSpy) -> GoogleCalendarProvider {
        GoogleCalendarProvider(accessToken: { _ in
            spy.record()
            throw TokenReached()
        })
    }

    @Test("An event id containing '/' is refused before a request can be formed")
    func slashBearingEventIdIsRefused() async throws {
        let spy = TokenSpy()
        let provider = makeGoogle(spy)

        await #expect(throws: GoogleCalendarError.self) {
            _ = try await provider.getEvent(calendarId: "primary", eventId: "evt/../../../gmail/v1/users/me/messages")
        }
        #expect(spy.calls == 0,
                "the id added path segments and the request was built anyway — `.urlPathAllowed` passes '/' through, so this would have addressed a different Google API surface under the same OAuth token")
    }

    @Test("A calendar id containing '/' is refused before a request can be formed")
    func slashBearingCalendarIdIsRefused() async throws {
        let spy = TokenSpy()
        let provider = makeGoogle(spy)

        await #expect(throws: GoogleCalendarError.self) {
            _ = try await provider.deleteEvent(calendarId: "primary/../../gmail/v1", eventId: "evt-1", sendUpdates: "none")
        }
        #expect(spy.calls == 0, "a delete was formed against a rewritten path")
    }

    @Test("A bare dot-segment id is refused — `standardized` would let it climb")
    func dotSegmentIdIsRefused() async throws {
        let spy = TokenSpy()
        let provider = makeGoogle(spy)

        await #expect(throws: GoogleCalendarError.self) {
            _ = try await provider.getEvent(calendarId: "primary", eventId: "..")
        }
        #expect(spy.calls == 0)
    }

    @Test("CONTROL — an ordinary Google id reaches the request path, and a secondary-calendar id keeps its '@' on the wire")
    func ordinaryGoogleIdsStillReachTheRequestPath() async throws {
        let spy = TokenSpy()
        let provider = makeGoogle(spy)

        await #expect(throws: TokenReached.self) {
            _ = try await provider.getEvent(
                calendarId: "team@group.calendar.google.com", eventId: "abc123_20260601T090000Z")
        }
        #expect(spy.calls == 1,
                "the fixture must be able to reach the request path at all, or the three absences above are vacuous (MIS-030) — got \(spy.calls)")

        // The encoding is byte-identical to what shipped sent. `@` is a `pchar`
        // and NOT unreserved, so `%40` is not formally equivalent to it
        // (RFC 3986 §6.2.2.2) — adopting `GraphAPI.encodedGraphPathSegment`'s
        // stricter unreserved-only set here would have been a silent wire change
        // to every secondary Google calendar. This asserts it was not.
        let encoded = try GoogleCalendarProvider.encodedPathSegment("team@group.calendar.google.com", "Google calendar id")
        #expect(encoded == "team@group.calendar.google.com")
    }
}
