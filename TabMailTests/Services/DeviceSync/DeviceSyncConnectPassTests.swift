/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// The Device Sync socket opens with a one-time pass, never with the sign-in token in its address. A WebSocket
/// request carries no Authorization header, so the token goes only in the header of the HTTPS request that
/// gets the pass (`POST /ws/pass`); without a pass there is no address to open, and the connect takes the
/// reconnect path a failed token refresh takes.
@Suite("Device Sync connect pass")
struct DeviceSyncConnectPassTests {
    private static let token = "header.payload.signature"
    private static let pass = "0123abcd.c2VjcmV0LXBhcnQtb2YtdGhlLXBhc3M"

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DeviceSync
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repository root
    }

    @Test("The socket's address carries only a fresh pass; the token goes only in the pass request's Authorization header")
    func socketOpensWithAPass() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let seen = Mutex<[FakeHTTP.Request]>([])
        http.register(path: "/ws/pass", method: "POST") { request in
            seen.withLock { $0.append(request) }
            return .json(raw: #"{"pass":"\#(Self.pass)"}"#)
        }

        let socketURL = await DeviceSyncService.socketURL(token: Self.token, session: http.session)

        let url = try #require(socketURL)
        let requests = seen.withLock { $0 }
        #expect(requests.count == 1)
        guard requests.count == 1 else { return }
        let passURL = try #require(URL(string: "\(BackendConfig.syncBaseURL)/ws/pass"))
        #expect(requests[0].url == passURL)
        #expect(requests[0].header("Authorization") == "Bearer \(Self.token)")

        let socketBase = try #require(URLComponents(string: BackendConfig.syncWebSocketURL))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == socketBase.scheme)
        #expect(components.host == socketBase.host)
        #expect(components.path == socketBase.path)
        #expect(components.queryItems == [URLQueryItem(name: "pass", value: Self.pass)])
        #expect(!url.absoluteString.contains(Self.token))
    }

    @Test("A refused pass request gives no address", arguments: [401, 403, 429, 500, 503])
    func refusedPassRequestGivesNoAddress(status: Int) async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/ws/pass", method: "POST", response: .status(status))

        let socketURL = await DeviceSyncService.socketURL(token: Self.token, session: http.session)

        #expect(socketURL == nil)
        #expect(http.servedCallSequence() == ["POST /ws/pass"])
    }

    @Test("An answer without a pass gives no address", arguments: ["{}", #"{"pass":""}"#, "not json"])
    func answerWithoutAPassGivesNoAddress(body: String) async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/ws/pass", method: "POST", response: .json(raw: body))

        let socketURL = await DeviceSyncService.socketURL(token: Self.token, session: http.session)

        #expect(socketURL == nil)
    }

    @Test("A pass request that never reaches the server gives no address")
    func transportFailureGivesNoAddress() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/ws/pass", method: "POST", response: .transportError(.notConnectedToInternet))

        let socketURL = await DeviceSyncService.socketURL(token: Self.token, session: http.session)

        #expect(socketURL == nil)
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
                if source.contains(#"URLQueryItem(name: "token""#) {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        #expect(scanned > 100, "the scan reached the sources")
        #expect(offenders.isEmpty, "token query items in: \(offenders)")
    }
}
