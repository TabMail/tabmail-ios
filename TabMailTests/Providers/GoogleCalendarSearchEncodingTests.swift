/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Google Calendar reads the query string form-style: `&` separates
/// parameters, `=` separates a name from its value, and `+` is a space. Event
/// search text must come back out of that decoding unchanged, as the one `q`.
@Suite("Google Calendar search text")
struct GoogleCalendarSearchEncodingTests {
    @Test("event search text reaches Google Calendar exactly as typed, as one q parameter",
          arguments: [
              "R&D review",
              "C++ sync x=y",
              "100% #1 ? / ; : , @ $ ! ' ( ) *",
              "caf\u{e9} \u{1F4C5}",
              "literal%26term%2Btag%3Dvalue%25 %2526",
          ])
    func searchTextReachesGoogleCalendarIntact(query: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/events?", method: "GET", response: .json(raw: #"{"items": []}"#))
        let provider = GoogleCalendarProvider(accessToken: { _ in "fake-access-token" }, session: http.session)

        _ = try await provider.listEvents(calendarId: "primary", query: query)

        let calls = http.recordedCalls()
        #expect(calls.count == 1)
        guard calls.count == 1, let url = URL(string: calls[0].url),
              let rawQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else {
            Issue.record("no event search request recorded")
            return
        }
        let parameters = FormDecoding.fields(rawQuery)
        #expect(parameters["q"] == [query], "Google Calendar would read \(parameters) from \(rawQuery)")
        #expect(Set(parameters.keys) == ["eventTypes", "singleEvents", "maxResults", "orderBy", "q"],
                "stray parameters in \(rawQuery)")
    }
}
