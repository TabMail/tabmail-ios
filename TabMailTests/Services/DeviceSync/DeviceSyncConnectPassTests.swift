/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// The Device Sync socket opens with a one-time pass, never with the sign-in token in its address. The token
/// goes only in the Authorization header of the HTTPS request that gets the pass (`POST /ws/pass`); without a
/// pass there is no address to open. The relay's addresses here are fixed test values: the connect passes in
/// its own snapshot, so nothing reads the server setting.
@Suite("Device Sync connect pass")
struct DeviceSyncConnectPassTests {
    private static let token = "header.payload.signature"
    private static let pass = "0123abcd.c2VjcmV0LXBhcnQtb2YtdGhlLXBhc3M"
    private static let relayBase = "https://relay.example.com"
    private static let socketBase = "wss://relay.example.com/ws"

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DeviceSync
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repository root
    }

    /// Registers `response` for the pass request and counts how often the fake actually served it (a request
    /// with no matching route is answered 599 without reaching this handler).
    private static func servePass(
        _ http: FakeHTTP.Scenario,
        _ response: FakeHTTP.CannedResponse
    ) -> Mutex<[FakeHTTP.Request]> {
        let served = Mutex<[FakeHTTP.Request]>([])
        http.register(path: "/ws/pass", method: "POST") { request in
            served.withLock { $0.append(request) }
            return response
        }
        return served
    }

    @Test("The pass request goes to the given relay; the token goes only in its Authorization header")
    func passRequestCarriesTheTokenInItsHeader() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let served = Self.servePass(http, .json(raw: #"{"pass":"\#(Self.pass)"}"#))

        let pass = await BackendClient.requestSyncConnectPass(
            token: Self.token, relayBaseURL: Self.relayBase, session: http.session
        )

        #expect(pass == Self.pass)
        let requests = served.withLock { $0 }
        #expect(requests.count == 1)
        guard requests.count == 1 else { return }
        #expect(requests[0].method == "POST")
        #expect(requests[0].url == URL(string: "\(Self.relayBase)/ws/pass"))
        #expect(requests[0].header("Authorization") == "Bearer \(Self.token)")
        #expect((requests[0].body ?? Data()).isEmpty, "the request has no body; the token is in the header only")
        #expect(!requests[0].url.absoluteString.contains(Self.token))
        #expect(http.servedCallSequence() == ["POST /ws/pass"])
    }

    @Test("The socket's address is the connect's socket address with the pass, and nothing else")
    func socketAddressCarriesOnlyThePass() throws {
        let url = try #require(DeviceSyncService.socketURL(webSocketBase: Self.socketBase, pass: Self.pass))

        #expect(url.absoluteString == "\(Self.socketBase)?pass=\(Self.pass)")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "pass", value: Self.pass)])
    }

    /// The refused answers carry a well-formed pass, so only the status check can refuse them.
    @Test("A refused pass request gives no pass, even with a pass in its body", arguments: [401, 403, 429, 500, 503])
    func refusedPassRequestGivesNoPass(status: Int) async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let served = Self.servePass(http, .json(raw: #"{"pass":"\#(Self.pass)"}"#, statusCode: status))

        let pass = await BackendClient.requestSyncConnectPass(
            token: Self.token, relayBaseURL: Self.relayBase, session: http.session
        )

        #expect(pass == nil)
        #expect(served.withLock { $0.count } == 1, "the refusal came from the registered answer")
        #expect(http.servedCallSequence() == ["POST /ws/pass"])
    }

    @Test("An answer without a pass gives no pass", arguments: ["{}", #"{"pass":""}"#, #"{"pass":7}"#, "not json"])
    func answerWithoutAPassGivesNoPass(body: String) async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let served = Self.servePass(http, .json(raw: body))

        let pass = await BackendClient.requestSyncConnectPass(
            token: Self.token, relayBaseURL: Self.relayBase, session: http.session
        )

        #expect(pass == nil)
        #expect(served.withLock { $0.count } == 1, "the answer read was the registered one")
    }

    @Test("A pass request that never reaches the server gives no pass")
    func transportFailureGivesNoPass() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let served = Self.servePass(http, .transportError(.notConnectedToInternet))

        let pass = await BackendClient.requestSyncConnectPass(
            token: Self.token, relayBaseURL: Self.relayBase, session: http.session
        )

        #expect(pass == nil)
        #expect(served.withLock { $0.count } == 1, "the failure came from the registered transport error")
    }

    /// No source in the app, the shared code or the notification extension puts a sign-in token in a URL's
    /// query (the shape the socket's address once had).
    @Test("No source puts a token in a URL query")
    func noTokenQueryItemInSources() throws {
        let fileManager = FileManager.default
        var offenders: [String] = []
        var scanned = 0
        for folder in ["TabMail", "Shared", "TabMailNotificationService"] {
            let root = Self.repositoryRoot.appendingPathComponent(folder)
            guard let files = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                // A query item, or a query written into a string with the token interpolated.
                if source.contains(#"URLQueryItem(name: "token""#)
                    || source.contains(#"?token=\("#) || source.contains(#"&token=\("#) {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        #expect(scanned > 100, "the scan reached the sources")
        #expect(offenders.isEmpty, "token query items in: \(offenders)")
    }
}
