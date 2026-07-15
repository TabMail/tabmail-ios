/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing

@Suite("FakeHTTP scenario isolation")
struct FakeHTTPTests {
    @Test("parallel identical requests keep responses, logs, reset, and close scenario-local")
    func parallelScenariosAreIsolated() async throws {
        let first = FakeHTTP.Scenario()
        let second = FakeHTTP.Scenario()
        defer {
            first.close()
            second.close()
        }

        let url = try #require(URL(string: "https://example.com/shared-resource"))
        first.register(
            path: "/shared-resource",
            response: .bytes(Data("first-response".utf8), contentType: "text/plain")
        )
        second.register(
            path: "/shared-resource",
            response: .bytes(Data("second-response".utf8), contentType: "text/plain")
        )

        async let firstFetch = first.session.data(from: url)
        async let secondFetch = second.session.data(from: url)
        let ((firstData, _), (secondData, _)) = try await (firstFetch, secondFetch)

        #expect(String(decoding: firstData, as: UTF8.self) == "first-response")
        #expect(String(decoding: secondData, as: UTF8.self) == "second-response")

        let firstCalls = first.recordedCalls()
        let secondCalls = second.recordedCalls()
        #expect(firstCalls.count == 1)
        #expect(secondCalls.count == 1)
        guard firstCalls.count == 1, secondCalls.count == 1 else { return }
        #expect(firstCalls[0].method == "GET")
        #expect(secondCalls[0].method == "GET")
        #expect(firstCalls[0].url == secondCalls[0].url)

        first.reset()
        #expect(first.recordedCalls().isEmpty)
        #expect(second.recordedCalls().count == 1)

        first.close()
        let (secondAgain, _) = try await second.session.data(from: url)
        #expect(String(decoding: secondAgain, as: UTF8.self) == "second-response")
        #expect(second.recordedCalls().count == 2)
    }

    @Test("stateful handler observes request bodies and derives later responses")
    func statefulHandler() async throws {
        struct State: Sendable {
            var values: [String] = []
        }

        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }
        let state = Mutex(State())
        scenario.register(path: "/state", method: "POST") { request in
            let value = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let values = state.withLock { model -> [String] in
                model.values.append(value)
                return model.values
            }
            return .json(raw: #"{"values":\#(values)}"#)
        }

        let url = try #require(URL(string: "https://example.com/state"))
        var firstRequest = URLRequest(url: url)
        firstRequest.httpMethod = "POST"
        firstRequest.httpBody = Data("first".utf8)
        let (firstData, _) = try await scenario.session.data(for: firstRequest)

        var secondRequest = URLRequest(url: url)
        secondRequest.httpMethod = "POST"
        secondRequest.httpBody = Data("second".utf8)
        let (secondData, _) = try await scenario.session.data(for: secondRequest)

        let firstJSON = try #require(
            JSONSerialization.jsonObject(with: firstData) as? [String: [String]]
        )
        let secondJSON = try #require(
            JSONSerialization.jsonObject(with: secondData) as? [String: [String]]
        )
        #expect(firstJSON["values"] == ["first"])
        #expect(secondJSON["values"] == ["first", "second"])
        #expect(scenario.recordedCalls().count == 2)
    }
}
