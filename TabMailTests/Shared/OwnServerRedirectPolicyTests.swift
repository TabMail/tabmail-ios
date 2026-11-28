/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Network
import Testing
@testable import TabMail

/// A plain HTTP/1.1 server on the loopback interface, in this process, that answers every request with
/// one fixed response and counts the requests it received.
private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-http")
    /// Set before `start`; read on `queue` only afterwards.
    var response = ""
    /// Read and written on `queue` only.
    private var requests = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Starts listening; the port it listens on.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.readRequest(on: connection, received: Data())
        }
        let listener = listener
        let queue = queue
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Reads until the end of the request's header block (the requests here have no body), then
    /// answers and closes the connection.
    private func readRequest(on connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var received = received
            if let data { received.append(data) }
            if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.requests += 1
                connection.send(content: Data(self.response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if error == nil, !isComplete {
                self.readRequest(on: connection, received: received)
            } else {
                connection.cancel()
            }
        }
    }

    var requestCount: Int { queue.sync { requests } }

    func stop() { listener.cancel() }
}

/// A request to one of TabMail's own servers never follows a redirect: the redirect comes back to the
/// caller as the answer and the host it names receives nothing. Requests to every other host follow
/// redirects as before.
@Suite("Requests to TabMail's own servers never follow a redirect", .serialized)
struct OwnServerRedirectPolicyTests {

    /// Two loopback servers: `first` answers 302 with `second` as the new address; `second` answers 200.
    private struct Servers {
        let first: LoopbackHTTPServer
        let second: LoopbackHTTPServer
        let firstPort: UInt16

        var firstURL: URL { URL(string: "http://127.0.0.1:\(firstPort)/v1/call")! }

        func stop() {
            first.stop()
            second.stop()
        }
    }

    private static func servers() async throws -> Servers {
        let second = try LoopbackHTTPServer()
        second.response = "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nlanded"
        let secondPort = try await second.start()
        let first = try LoopbackHTTPServer()
        first.response = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(secondPort)/landed\r\n"
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        let firstPort = try await first.start()
        return Servers(first: first, second: second, firstPort: firstPort)
    }

    /// How a request reaches the network: a session that holds the policy (the app's sessions), or
    /// `URLSession.shared` with the policy passed for the one request (the notification service
    /// extension).
    enum Route: String, CaseIterable, CustomTestStringConvertible {
        case sessionDelegate, perRequestDelegate
        var testDescription: String { rawValue }

        func send(_ request: URLRequest, policy: OwnServerRedirectPolicy) async throws -> (Data, URLResponse) {
            switch self {
            case .sessionDelegate:
                let session = URLSession(configuration: .ephemeral, delegate: policy, delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                return try await session.data(for: request)
            case .perRequestDelegate:
                return try await URLSession.shared.data(for: request, delegate: policy)
            }
        }
    }

    @Test("A redirect from an own server comes back as the answer, and its target receives nothing",
          arguments: Route.allCases)
    func ownServerRedirectIsNotFollowed(route: Route) async throws {
        let servers = try await Self.servers()
        defer { servers.stop() }
        let port = Int(servers.firstPort)
        let policy = OwnServerRedirectPolicy(isOwnServer: { $0.port == port })

        let (data, response) = try await route.send(URLRequest(url: servers.firstURL), policy: policy)

        let status = (response as? HTTPURLResponse)?.statusCode
        let firstCount = servers.first.requestCount
        let secondCount = servers.second.requestCount
        #expect(status == 302)
        #expect(data.isEmpty)
        #expect(firstCount == 1)
        #expect(secondCount == 0, "the redirect target received the request")
    }

    @Test("A redirect from any other host is followed as before", arguments: Route.allCases)
    func otherHostRedirectIsFollowed(route: Route) async throws {
        let servers = try await Self.servers()
        defer { servers.stop() }
        let policy = OwnServerRedirectPolicy(isOwnServer: { _ in false })

        let (data, response) = try await route.send(URLRequest(url: servers.firstURL), policy: policy)

        let status = (response as? HTTPURLResponse)?.statusCode
        let secondCount = servers.second.requestCount
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self) == "landed")
        #expect(secondCount == 1)
    }

    // MARK: - Which servers are TabMail's own

    @Test("TabMail's own servers are the subdomains of its domain", arguments: [
        ("https://api.tabmail.ai/v1/chat", true),
        ("https://dev.tabmail.ai/v1/chat", true),
        ("https://sync.tabmail.ai/ai-cache/probe", true),
        ("wss://sync-dev.tabmail.ai/ws", true),
        ("https://auth.tabmail.ai/auth/v1/token", true),
        ("https://push.tabmail.ai/register-device", true),
        ("https://billing.tabmail.ai/status", true),
        ("https://templates.tabmail.ai/search", true),
        ("https://API.TabMail.AI/v1/chat", true),
        ("https://tabmail.ai/docs/", false),
        ("https://gmail.googleapis.com/gmail/v1/users/me", false),
        ("https://graph.microsoft.com/v1.0/me", false),
        ("https://caldav.icloud.com/", false),
        ("https://example.com/", false),
        ("https://notabmail.ai/", false),
        ("https://api.tabmail.ai.example.com/", false),
    ])
    func ownServerHosts(address: String, isOwn: Bool) throws {
        let url = try #require(URL(string: address))
        let result = OwnServerRedirectPolicy.isTabMailServer(url)
        #expect(result == isOwn, "\(address)")
    }

    /// The decision `delegate` makes for a request to `first` that is redirected to `target`.
    @MainActor
    private static func decision(
        _ delegate: any URLSessionTaskDelegate, first: String, target: String
    ) async throws -> URLRequest? {
        let firstURL = try #require(URL(string: first))
        let targetURL = try #require(URL(string: target))
        let task = URLSession.shared.dataTask(with: firstURL)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(
            url: firstURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target]))
        return await withCheckedContinuation { continuation in
            delegate.urlSession?(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                                 newRequest: URLRequest(url: targetURL)) { continuation.resume(returning: $0) }
        }
    }

    @Test("The shared policy refuses a redirect from TabMail's servers and passes every other one on")
    func sharedPolicyDecides() async throws {
        let own = try await Self.decision(OwnServerRedirectPolicy.shared,
                                          first: "https://api.tabmail.ai/v1/chat", target: "https://example.com/next")
        let other = try await Self.decision(OwnServerRedirectPolicy.shared,
                                            first: "https://graph.microsoft.com/v1.0/me", target: "https://example.com/next")
        let ownRefused = own == nil
        let otherTarget = other?.url?.absoluteString
        #expect(ownRefused)
        #expect(otherTarget == "https://example.com/next")
    }

    // MARK: - Every session that reaches TabMail's servers holds the policy

    @Test("The shared session and the AI sessions hold the policy")
    func sessionsHoldThePolicy() async {
        let client = BackendClient()
        let longOpSession = await client.llmLongOpSession
        let shared = sharedEphemeralSession.delegate === OwnServerRedirectPolicy.shared
        let llm = client.llmSession.delegate === OwnServerRedirectPolicy.shared
        let longOp = longOpSession.delegate === OwnServerRedirectPolicy.shared
        #expect(shared)
        #expect(llm)
        #expect(longOp)
    }

    @Test("The device sync connection refuses a redirect from the sync server")
    @MainActor
    func deviceSyncConnectionRefusesRedirect() async throws {
        let own = try await Self.decision(DeviceSyncService.shared,
                                          first: "wss://sync.tabmail.ai/ws", target: "wss://example.com/ws")
        let ownRefused = own == nil
        #expect(ownRefused)
    }

    // MARK: - Source fence

    private static func sources(under folders: [String]) throws -> [(path: String, lines: [Substring])] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Shared
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
        let rootPath = root.standardizedFileURL.path
        var files: [(path: String, lines: [Substring])] = []
        for folder in folders {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
                files.append((relative, text.split(separator: "\n", omittingEmptySubsequences: false)))
            }
        }
        return files
    }

    /// Sessions that need not hold the policy, and why: a CalDAV server (iCloud) sends its clients on to
    /// another host; the device sync connection's delegate passes the decision to the policy.
    private static let sessionsWithOwnDelegate: Set<String> = [
        "TabMail/Providers/CalDAV/CalDAVClient.swift",
        "TabMail/Services/DeviceSyncService.swift",
    ]

    @Test("Every request on URLSession.shared and every new session in the app and the extension carries the policy")
    func everySessionCarriesThePolicy() throws {
        let files = try Self.sources(under: ["TabMail", "Shared", "TabMailNotificationService"])
        var sharedCalls: [String] = []
        var newSessions: [String] = []
        var misses: [String] = []
        for file in files {
            for line in file.lines {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if code.contains("URLSession.shared.") {
                    sharedCalls.append(file.path)
                    if !code.contains("delegate: OwnServerRedirectPolicy.shared") { misses.append("\(file.path): \(code)") }
                }
                if code.contains("URLSession(configuration:") {
                    newSessions.append(file.path)
                    let exempt = Self.sessionsWithOwnDelegate.contains(file.path)
                    if !code.contains("delegate: OwnServerRedirectPolicy.shared"), !exempt {
                        misses.append("\(file.path): \(code)")
                    }
                }
            }
        }
        #expect(misses.isEmpty, "\(misses)")
        let extensionCalls = Set(sharedCalls).filter { $0.hasPrefix("TabMailNotificationService/") }
        #expect(extensionCalls.count >= 5, "the scan found the extension's requests: \(sharedCalls)")
        #expect(newSessions.count >= 5, "the scan found the app's sessions: \(newSessions)")
    }
}
