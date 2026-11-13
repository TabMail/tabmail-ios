/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

// MARK: - A Graph collection that pages

/// A Graph collection served in pages, as Graph serves one: a page holds at most the
/// client's `$top` and at most the server's own page size, and every page but the last
/// carries an `@odata.nextLink` (learn.microsoft.com/graph/paging). The link is the
/// request's own URL with the next `$skip`, the shape Graph returns for calendarView.
private final class PagedGraphCollection: Sendable {
    let serverPageSize: Int
    /// Where a page's next link points; Graph's own host unless a test says otherwise.
    let nextLinkHost: String
    /// Every request's `Prefer` header, in order.
    let preferHeaders = Mutex<[String?]>([])
    /// Every request's `$select`, in order (nil when it had none).
    let selects = Mutex<[String?]>([])

    /// Written once in `init`, only read afterwards.
    nonisolated(unsafe) private let frozen: [[String: Any]]

    init(items: [[String: Any]], serverPageSize: Int, nextLinkHost: String = "graph.microsoft.com") {
        self.frozen = items
        self.serverPageSize = serverPageSize
        self.nextLinkHost = nextLinkHost
    }

    func respond(to request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
        preferHeaders.withLock { $0.append(request.header("Prefer")) }
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        selects.withLock { $0.append(query.first { $0.name == "$select" }?.value) }
        let skip = query.first { $0.name == "$skip" }?.value.flatMap(Int.init) ?? 0
        let top = query.first { $0.name == "$top" }?.value.flatMap(Int.init) ?? serverPageSize
        let size = min(top, serverPageSize)
        let page = Array(frozen.dropFirst(skip).prefix(size))
        var body: [String: Any] = ["value": page]
        if skip + page.count < frozen.count {
            var next = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            next.host = nextLinkHost
            next.queryItems = query.filter { $0.name != "$skip" } + [URLQueryItem(name: "$skip", value: String(skip + page.count))]
            body["@odata.nextLink"] = next.url!.absoluteString
        }
        // swiftlint:disable:next force_try
        return .raw(statusCode: 200, headers: ["Content-Type": "application/json"],
                    body: try! JSONSerialization.data(withJSONObject: body))
    }
}

/// `count` timed events, one a day from tomorrow, each with a subject.
private func events(_ count: Int, subject: (Int) -> String = { "Meeting \($0)" }) -> [[String: Any]] {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "UTC")
    format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.0000000"
    let first = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
    return (0..<count).map { n in
        let start = Calendar.current.date(byAdding: .day, value: n, to: first)!
        let end = start.addingTimeInterval(3600)
        return [
            "id": "ev-\(n)",
            "subject": subject(n),
            "start": ["dateTime": format.string(from: start), "timeZone": "UTC"],
            "end": ["dateTime": format.string(from: end), "timeZone": "UTC"],
            "isAllDay": false,
        ]
    }
}

private func makeProvider(_ http: FakeHTTP.Scenario) -> ExchangeCalendarProvider {
    ExchangeCalendarProvider(mailbox: "paging@example.com", accessToken: { _ in "token" }, session: http.session)
}

private var window: (Date, Date) {
    (Date(), Calendar.current.date(byAdding: .day, value: 60, to: Date())!)
}

// MARK: - The invariant: a listing is every item Graph has, not its first page

@Suite("Outlook calendar listings read every page Graph returns", .serialized)
struct ExchangeCalendarPagingTests {

    @Test("a time window lists every event in it, across pages")
    func calendarViewListsEveryPage() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = PagedGraphCollection(items: events(7), serverPageSize: 2)
        http.register(path: "/v1.0/me/calendarView", method: "GET", handler: { graph.respond(to: $0) })

        let (from, to) = window
        let listed = try await makeProvider(http).listEvents(timeMin: from, timeMax: to, maxResults: 250)

        #expect(listed.map(\.id) == (0..<7).map { "ev-\($0)" })
        // Every page is read in the same zone, so every listed time is in one frame.
        let prefers = graph.preferHeaders.withLock { $0 }
        #expect(prefers.count == 4)
        #expect(Set(prefers).count == 1, "pages were read with different Prefer headers: \(prefers)")
    }

    @Test("a listing without both bounds lists every event too, across pages")
    func eventsEndpointListsEveryPage() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = PagedGraphCollection(items: events(5), serverPageSize: 2)
        http.register(path: "/v1.0/me/events", method: "GET", handler: { graph.respond(to: $0) })

        let listed = try await makeProvider(http).listEvents(timeMin: Date(), maxResults: 250)

        #expect(listed.map(\.id) == (0..<5).map { "ev-\($0)" })
    }

    @Test("a search finds a match that Graph returns on a later page")
    func searchFindsAMatchOnALaterPage() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = PagedGraphCollection(
            items: events(9) { $0 == 8 ? "Dentist" : "Standup \($0)" }, serverPageSize: 2)
        http.register(path: "/v1.0/me/calendarView", method: "GET", handler: { graph.respond(to: $0) })

        let (from, to) = window
        let listed = try await makeProvider(http).listEvents(timeMin: from, timeMax: to, query: "dentist", maxResults: 250)

        #expect(listed.map(\.id) == ["ev-8"])
    }

    @Test("maxResults counts the events returned, and reading stops once it is reached")
    func maxResultsCountsReturnedEvents() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        // Matches are every other event, so the first three matches span three pages.
        let graph = PagedGraphCollection(
            items: events(12) { $0.isMultiple(of: 2) ? "Review \($0)" : "Other \($0)" }, serverPageSize: 2)
        http.register(path: "/v1.0/me/calendarView", method: "GET", handler: { graph.respond(to: $0) })

        let (from, to) = window
        let listed = try await makeProvider(http).listEvents(timeMin: from, timeMax: to, query: "review", maxResults: 3)

        #expect(listed.map(\.id) == ["ev-0", "ev-2", "ev-4"])
        #expect(http.recordedCalls().count == 3, "read past the page that held the last wanted match")
    }

    @Test("a page holding more matches than maxResults still returns exactly maxResults")
    func maxResultsTrimsTheLastPage() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        // Every event matches and the first page holds four, one more than asked for.
        let graph = PagedGraphCollection(items: events(8) { "Review \($0)" }, serverPageSize: 4)
        http.register(path: "/v1.0/me/calendarView", method: "GET", handler: { graph.respond(to: $0) })

        let (from, to) = window
        let listed = try await makeProvider(http).listEvents(timeMin: from, timeMax: to, query: "review", maxResults: 3)

        #expect(listed.map(\.id) == ["ev-0", "ev-1", "ev-2"])
        #expect(http.recordedCalls().count == 1, "read past the page that already held maxResults matches")
    }

    @Test("cancelled and empty events on a later page are left out too")
    func laterPageCancelledAndEmptyAreLeftOut() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var items = events(4)
        items[2]["isCancelled"] = true
        items[3]["subject"] = ""
        let graph = PagedGraphCollection(items: items, serverPageSize: 2)
        http.register(path: "/v1.0/me/calendarView", method: "GET", handler: { graph.respond(to: $0) })

        let (from, to) = window
        let listed = try await makeProvider(http).listEvents(timeMin: from, timeMax: to, maxResults: 250)

        #expect(listed.map(\.id) == ["ev-0", "ev-1"])
        #expect(http.recordedCalls().count == 2)
    }

    @Test("every calendar is listed, across pages")
    func calendarsListEveryPage() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let calendars: [[String: Any]] = (0..<5).map { n in
            ["id": "cal-\(n)", "name": "Calendar \(n)", "isDefaultCalendar": n == 0, "color": "auto"]
        }
        let graph = PagedGraphCollection(items: calendars, serverPageSize: 2)
        http.register(path: "/v1.0/me/calendars", method: "GET", handler: { graph.respond(to: $0) })

        let listed = try await makeProvider(http).listCalendars()

        #expect(listed.map(\.id) == (0..<5).map { "cal-\($0)" })
    }

    @Test("a next link off Graph's host is refused before any request is sent to it")
    func pageLinkOffGraphIsRefused() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = PagedGraphCollection(items: events(4), serverPageSize: 2, nextLinkHost: "graph.example.com")
        http.register(path: "/v1.0/me/calendarView", method: "GET", handler: { graph.respond(to: $0) })

        let (from, to) = window
        let error = await #expect(throws: ExchangeCalendarError.self) {
            _ = try await makeProvider(http).listEvents(timeMin: from, timeMax: to, maxResults: 250)
        }
        #expect(error.map { if case .invalidPageLink = $0 { true } else { false } } == true, "threw \(String(describing: error))")
        #expect(http.recordedCalls().map { URL(string: $0.url)?.host } == ["graph.microsoft.com"])
    }

    @Test("a listing that never ends is an error, never a part of the listing")
    func listingThatNeverEndsThrows() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = PagedGraphCollection(items: events(5_000), serverPageSize: 1)
        http.register(path: "/v1.0/me/calendarView", method: "GET", handler: { graph.respond(to: $0) })

        let (from, to) = window
        let error = await #expect(throws: ExchangeCalendarError.self) {
            _ = try await makeProvider(http).listEvents(timeMin: from, timeMax: to, maxResults: 5_000)
        }
        #expect(error.map { if case .listingIncomplete = $0 { true } else { false } } == true, "threw \(String(describing: error))")
        #expect(http.recordedCalls().count == ExchangeCalendarConfig.maxListPages)
    }

    /// learn.microsoft.com/graph/api/user-list-calendarview: "The createdDateTime and
    /// lastModifiedDateTime properties of event don't support $select."
    @Test("event reads select only properties calendarView can select")
    func eventReadsSelectOnlySelectableProperties() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let view = PagedGraphCollection(items: events(1), serverPageSize: 10)
        http.register(path: "/v1.0/me/calendarView", method: "GET", handler: { view.respond(to: $0) })
        let single = PagedGraphCollection(items: [], serverPageSize: 10)
        http.register(path: "/v1.0/me/events/ev-0", method: "GET") { request in
            _ = single.respond(to: request)
            return .raw(statusCode: 200, headers: ["Content-Type": "application/json"],
                        body: try! JSONSerialization.data(withJSONObject: events(1)[0]))
        }

        let provider = makeProvider(http)
        let (from, to) = window
        _ = try await provider.listEvents(timeMin: from, timeMax: to, maxResults: 250)
        _ = try await provider.getEvent(eventId: "ev-0")

        let selected = (view.selects.withLock { $0 } + single.selects.withLock { $0 }).compactMap { $0 }
        #expect(selected.count == 2)
        for select in selected {
            let fields = Set(select.split(separator: ",").map(String.init))
            #expect(fields.isDisjoint(with: ["createdDateTime", "lastModifiedDateTime"]), "selected: \(select)")
        }
    }
}
