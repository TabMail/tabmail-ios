/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Network
import Testing
@testable import TabMail

/// A plain HTTP/1.1 server on the loopback interface, in this process, that answers every request with
/// one fixed response and records the method and body of each request it received.
private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-http")
    /// Set before `start`; read on `queue` only afterwards.
    var response = ""
    /// Read and written on `queue` only.
    private var requests: [(method: String, body: Data)] = []

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

    /// Reads one request (its header block, then the body its Content-Length names), then answers and
    /// closes the connection.
    private func readRequest(on connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var received = received
            if let data { received.append(data) }
            if let request = Self.completeRequest(in: received) {
                self.requests.append(request)
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

    /// The method and body of the request in `received`, or nil while part of it has not arrived.
    private static func completeRequest(in received: Data) -> (method: String, body: Data)? {
        guard let end = received.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: received[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? ""
        var length = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = received[end.upperBound...]
        guard body.count >= length else { return nil }
        return (method, Data(body.prefix(length)))
    }

    var requestCount: Int { queue.sync { requests.count } }

    /// The method and body of the last request received.
    var lastRequest: (method: String, body: Data)? { queue.sync { requests.last } }

    func stop() { listener.cancel() }
}

/// A redirect answered by one of TabMail's own servers is never followed: it comes back to the caller as
/// the answer and the address it names receives nothing, wherever the request started. Redirects answered
/// by every other host are followed as before.
@Suite("Requests to TabMail's own servers never follow a redirect", .serialized)
struct OwnServerRedirectPolicyTests {

    /// How a request reaches the network: a session that holds the policy (`sharedEphemeralSession`), or
    /// a session with the policy passed for the one request (the AI requests, the calls on
    /// `URLSession.shared`).
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

    /// A redirect status and the request that meets it: a GET, or a POST with a body.
    struct Wire: CustomTestStringConvertible {
        let status: Int
        let method: String
        var testDescription: String { "\(status) \(method)" }

        static let body = Data("payload-7e1".utf8)

        /// The redirects a request to an own server meets: each redirect status, with a GET and with a
        /// POST that carries a body.
        static let ownServerCases = [
            Wire(status: 302, method: "GET"),
            Wire(status: 301, method: "POST"),
            Wire(status: 302, method: "POST"),
            Wire(status: 303, method: "POST"),
            Wire(status: 307, method: "POST"),
            Wire(status: 308, method: "POST"),
        ]

        func request(to url: URL) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            if method == "POST" { request.httpBody = Self.body }
            return request
        }
    }

    /// A loopback server that answers every request with `status` and `body`, and with `location` as the
    /// new address when one is given.
    private static func server(status: Int, location: String? = nil, body: String) async throws -> (server: LoopbackHTTPServer, port: UInt16) {
        let server = try LoopbackHTTPServer()
        server.response = "HTTP/1.1 \(status) Answer\r\n" + (location.map { "Location: \($0)\r\n" } ?? "")
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let port = try await server.start()
        return (server, port)
    }

    /// Two loopback servers: `first` answers `status` ("moved") with `second` as the new address; `second`
    /// answers 200 ("landed").
    private struct Pair {
        let first: LoopbackHTTPServer
        let second: LoopbackHTTPServer
        let firstPort: UInt16

        var firstURL: URL { URL(string: "http://127.0.0.1:\(firstPort)/v1/call")! }

        func stop() {
            first.stop()
            second.stop()
        }
    }

    private static func pair(status: Int) async throws -> Pair {
        let second = try await server(status: 200, body: "landed")
        let first = try await server(status: status, location: "http://127.0.0.1:\(second.port)/landed", body: "moved")
        return Pair(first: first.server, second: second.server, firstPort: first.port)
    }

    @Test("A redirect from an own server comes back as the answer, and its target receives nothing",
          arguments: Route.allCases, Wire.ownServerCases)
    func ownServerRedirectIsNotFollowed(route: Route, wire: Wire) async throws {
        let pair = try await Self.pair(status: wire.status)
        defer { pair.stop() }
        let port = Int(pair.firstPort)
        let policy = OwnServerRedirectPolicy(isOwnServer: { $0.port == port })

        let (data, response) = try await route.send(wire.request(to: pair.firstURL), policy: policy)

        let status = (response as? HTTPURLResponse)?.statusCode
        let firstCount = pair.first.requestCount
        let firstRequest = pair.first.lastRequest
        let secondCount = pair.second.requestCount
        let sentBody = wire.method == "POST" ? Wire.body : Data()
        #expect(status == wire.status)
        #expect(String(decoding: data, as: UTF8.self) == "moved")
        #expect(firstCount == 1)
        #expect(firstRequest?.method == wire.method)
        #expect(firstRequest?.body == sentBody)
        #expect(secondCount == 0, "the redirect target received the request")
    }

    @Test("A redirect answered by an own server is not followed after another host sent the request there",
          arguments: Route.allCases)
    func ownServerRedirectAfterOtherHostIsNotFollowed(route: Route) async throws {
        let last = try await Self.server(status: 200, body: "landed")
        let own = try await Self.server(status: 302, location: "http://127.0.0.1:\(last.port)/landed", body: "moved")
        let other = try await Self.server(status: 302, location: "http://127.0.0.1:\(own.port)/v1/call", body: "")
        defer {
            last.server.stop()
            own.server.stop()
            other.server.stop()
        }
        let ownPort = Int(own.port)
        let policy = OwnServerRedirectPolicy(isOwnServer: { $0.port == ownPort })
        let start = try #require(URL(string: "http://127.0.0.1:\(other.port)/start"))

        let (data, response) = try await route.send(URLRequest(url: start), policy: policy)

        let status = (response as? HTTPURLResponse)?.statusCode
        let otherCount = other.server.requestCount
        let ownCount = own.server.requestCount
        let lastCount = last.server.requestCount
        #expect(status == 302)
        #expect(String(decoding: data, as: UTF8.self) == "moved")
        #expect(otherCount == 1)
        #expect(ownCount == 1, "the other host's redirect to the own server was followed")
        #expect(lastCount == 0, "the own server's redirect was followed")
    }

    @Test("A redirect from an own server to another path on itself is not followed either", arguments: Route.allCases)
    func ownServerRelativeRedirectIsNotFollowed(route: Route) async throws {
        let own = try await Self.server(status: 302, location: "/elsewhere", body: "moved")
        defer { own.server.stop() }
        let ownPort = Int(own.port)
        let policy = OwnServerRedirectPolicy(isOwnServer: { $0.port == ownPort })
        let url = try #require(URL(string: "http://127.0.0.1:\(own.port)/v1/call"))

        let (data, response) = try await route.send(URLRequest(url: url), policy: policy)

        let status = (response as? HTTPURLResponse)?.statusCode
        let ownCount = own.server.requestCount
        #expect(status == 302)
        #expect(String(decoding: data, as: UTF8.self) == "moved")
        #expect(ownCount == 1)
    }

    @Test("A redirect from any other host is followed as before", arguments: Route.allCases)
    func otherHostRedirectIsFollowed(route: Route) async throws {
        let pair = try await Self.pair(status: 302)
        defer { pair.stop() }
        let policy = OwnServerRedirectPolicy(isOwnServer: { _ in false })

        let (data, response) = try await route.send(URLRequest(url: pair.firstURL), policy: policy)

        let status = (response as? HTTPURLResponse)?.statusCode
        let secondCount = pair.second.requestCount
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self) == "landed")
        #expect(secondCount == 1)
    }

    @Test("Another host's 307 or 308 is followed with the same method and body",
          arguments: Route.allCases, [307, 308])
    func otherHostRedirectKeepsThePost(route: Route, status: Int) async throws {
        let pair = try await Self.pair(status: status)
        defer { pair.stop() }
        let policy = OwnServerRedirectPolicy(isOwnServer: { _ in false })
        let wire = Wire(status: status, method: "POST")

        let (data, response) = try await route.send(wire.request(to: pair.firstURL), policy: policy)

        let answered = (response as? HTTPURLResponse)?.statusCode
        let secondCount = pair.second.requestCount
        let secondRequest = pair.second.lastRequest
        #expect(answered == 200)
        #expect(String(decoding: data, as: UTF8.self) == "landed")
        #expect(secondCount == 1)
        #expect(secondRequest?.method == "POST")
        #expect(secondRequest?.body == Wire.body)
    }

    @Test("Another host's 303 after a POST is followed as a GET, as it is with no policy", arguments: Route.allCases)
    func otherHostSeeOtherIsFollowedAsAGet(route: Route) async throws {
        let pair = try await Self.pair(status: 303)
        let control = try await Self.pair(status: 303)
        defer {
            pair.stop()
            control.stop()
        }
        let policy = OwnServerRedirectPolicy(isOwnServer: { _ in false })
        let wire = Wire(status: 303, method: "POST")
        // What Foundation does on its own: the same request on a session with no delegate.
        let plain = URLSession(configuration: .ephemeral)
        defer { plain.finishTasksAndInvalidate() }

        let (data, response) = try await route.send(wire.request(to: pair.firstURL), policy: policy)
        let (controlData, _) = try await plain.data(for: wire.request(to: control.firstURL))

        let answered = (response as? HTTPURLResponse)?.statusCode
        let firstRequest = pair.first.lastRequest
        let secondCount = pair.second.requestCount
        let secondRequest = pair.second.lastRequest
        let controlRequest = control.second.lastRequest
        #expect(answered == 200)
        #expect(String(decoding: data, as: UTF8.self) == "landed")
        #expect(firstRequest?.method == "POST")
        #expect(firstRequest?.body == Wire.body)
        #expect(secondCount == 1)
        #expect(secondRequest?.method == "GET", "a 303 turns the POST into a GET")
        #expect(String(decoding: controlData, as: UTF8.self) == "landed", "control: the plain session followed")
        #expect(secondRequest?.method == controlRequest?.method)
        #expect(secondRequest?.body == controlRequest?.body)
    }

    // MARK: - Which servers are TabMail's own

    @Test("TabMail's own servers are the subdomains of its domain", arguments: [
        ("https://api.tabmail.ai/v1/chat", true),
        ("https://dev.tabmail.ai/v1/chat", true),
        ("https://sync.tabmail.ai/ai-cache/probe", true),
        ("https://sync-dev.tabmail.ai/ai-cache/probe", true),
        ("wss://sync.tabmail.ai/ws", true),
        ("wss://sync-dev.tabmail.ai/ws", true),
        ("https://auth.tabmail.ai/auth/v1/token", true),
        ("https://push.tabmail.ai/register-device", true),
        ("https://billing.tabmail.ai/status", true),
        ("https://billing-dev.tabmail.ai/status", true),
        ("https://templates.tabmail.ai/search", true),
        ("https://templates-dev.tabmail.ai/search", true),
        ("https://forms.tabmail.ai/feedback/trial", true),
        ("https://forms-dev.tabmail.ai/feedback/trial", true),
        ("https://apple-webhook.tabmail.ai/verify", true),
        ("https://apple-webhook-dev.tabmail.ai/verify", true),
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

    @Test("Every TabMail endpoint the app is configured with is one of its own servers")
    func configuredEndpointsAreOwn() throws {
        var endpoints = [BackendConfig.apiBaseURL, BackendConfig.templatesBaseURL, BackendConfig.billingBaseURL,
                         BackendConfig.trialFeedbackURL, BackendConfig.appleWebhookBaseURL]
        for address in [BackendConfig.syncBaseURL, BackendConfig.syncWebSocketURL, PushConfig.baseURL] {
            let url = try #require(URL(string: address))
            endpoints.append(url)
        }
        #expect(endpoints.count == 8)
        for url in endpoints {
            let own = OwnServerRedirectPolicy.isTabMailServer(url)
            #expect(own, "\(url)")
        }
    }

    // MARK: - The decision of the shared policy and of the device sync connection

    /// What a delegate decided about a redirect.
    enum Decision: Equatable {
        case followed(URL?)
        case refused
        /// The delegate has no redirect callback.
        case noCallback
    }

    /// A redirect answer with no address, as `HTTPURLResponse.url` allows.
    private final class AddresslessRedirect: HTTPURLResponse, @unchecked Sendable {
        override var url: URL? { nil }
    }

    /// The decision `delegate` makes for a request that started at `start` and was answered by
    /// `answeredBy` (nil: an answer with no address) with a redirect to `target`, on a data task, or on
    /// a web socket task when `socket` is true.
    @MainActor
    private static func decision(
        _ delegate: any URLSessionTaskDelegate, start: String, answeredBy: String?, target: String,
        socket: Bool = false
    ) async throws -> Decision {
        let startURL = try #require(URL(string: start))
        let targetURL = try #require(URL(string: target))
        let task: URLSessionTask = socket
            ? URLSession.shared.webSocketTask(with: startURL)
            : URLSession.shared.dataTask(with: startURL)
        defer { task.cancel() }
        let headers = ["Location": target]
        let response: HTTPURLResponse
        if let answeredBy {
            let answeredURL = try #require(URL(string: answeredBy))
            response = try #require(HTTPURLResponse(
                url: answeredURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: headers))
        } else {
            response = try #require(AddresslessRedirect(
                url: startURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: headers))
        }
        return await withCheckedContinuation { continuation in
            let called: Void? = delegate.urlSession?(
                URLSession.shared, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: targetURL)
            ) { request in
                continuation.resume(returning: request.map { Decision.followed($0.url) } ?? Decision.refused)
            }
            if called == nil { continuation.resume(returning: Decision.noCallback) }
        }
    }

    @Test("The shared policy decides by the address that answered, wherever the request started")
    @MainActor
    func sharedPolicyDecides() async throws {
        let policy = OwnServerRedirectPolicy.shared
        let next = "https://example.com/next"
        let own = try await Self.decision(policy, start: "https://api.tabmail.ai/v1/chat",
                                          answeredBy: "https://api.tabmail.ai/v1/chat", target: next)
        let ownAfterOther = try await Self.decision(policy, start: "https://example.com/start",
                                                    answeredBy: "https://push.tabmail.ai/start", target: next)
        let other = try await Self.decision(policy, start: "https://graph.microsoft.com/v1.0/me",
                                            answeredBy: "https://graph.microsoft.com/v1.0/me", target: next)
        let otherAfterOwn = try await Self.decision(policy, start: "https://api.tabmail.ai/v1/chat",
                                                    answeredBy: "https://example.com/start", target: next)
        #expect(own == .refused)
        #expect(ownAfterOther == .refused)
        #expect(other == .followed(URL(string: next)))
        #expect(otherAfterOwn == .followed(URL(string: next)))
    }

    @Test("The device sync connection passes the decision to the policy")
    @MainActor
    func deviceSyncConnectionDecides() async throws {
        let sync = DeviceSyncService.shared
        let own = try await Self.decision(sync, start: "wss://sync.tabmail.ai/ws",
                                          answeredBy: "https://sync.tabmail.ai/ws", target: "wss://example.com/ws",
                                          socket: true)
        let other = try await Self.decision(sync, start: "wss://sync.tabmail.ai/ws",
                                            answeredBy: "https://example.com/ws", target: "wss://example.com/next",
                                            socket: true)
        #expect(own == .refused)
        #expect(other == .followed(URL(string: "wss://example.com/next")))
    }

    @Test("A redirect answer with no address is refused, wherever the request started")
    @MainActor
    func redirectWithNoAddressIsRefused() async throws {
        let addressless = AddresslessRedirect(
            url: try #require(URL(string: "https://example.com/start")), statusCode: 302, httpVersion: nil, headerFields: nil)
        let hasNoAddress = addressless?.url == nil
        #expect(hasNoAddress, "control: the answer has no address")
        let shared = try await Self.decision(OwnServerRedirectPolicy.shared, start: "https://example.com/start",
                                             answeredBy: nil, target: "https://example.com/next")
        let sync = try await Self.decision(DeviceSyncService.shared, start: "wss://example.com/ws",
                                           answeredBy: nil, target: "wss://example.com/next", socket: true)
        #expect(shared == .refused)
        #expect(sync == .refused)
    }

    // MARK: - Every request that can reach TabMail's servers carries the policy

    @Test("The shared session holds the policy")
    func sharedSessionHoldsThePolicy() {
        let holds = sharedEphemeralSession.delegate === OwnServerRedirectPolicy.shared
        #expect(holds)
    }

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

    private static let policy = "delegate: OwnServerRedirectPolicy.shared"

    /// Sessions created without the policy, and why: a CalDAV server (iCloud) sends its clients on to
    /// another host; every request on the AI sessions passes the policy itself (checked below).
    private static let sessionsWithoutPolicy: Set<String> = [
        "TabMail/Providers/CalDAV/CalDAVClient.swift",
        "TabMail/Services/BackendClient.swift",
    ]

    /// The device sync connection's session has the service as its delegate, which passes the decision
    /// to the policy (`deviceSyncConnectionDecides`).
    private static let deviceSyncFile = "TabMail/Services/DeviceSyncService.swift"

    private static let backendClientFile = "TabMail/Services/BackendClient.swift"

    /// The calls that send a request on a session.
    private static let sendCalls = [".data(for:", ".bytes(for:", ".upload(for:", ".download(for:", "Task(with:"]

    /// Where the policy is passed, per file, and how many times: the shared session, and each request
    /// that carries a token, a refresh token or a signed purchase on a session of its own. A send
    /// rewritten so that it no longer passes the policy lowers its file's count.
    private static let policyUses: [String: Int] = [
        "Shared/HTTP/HTTPClient.swift": 1,                          // sharedEphemeralSession
        "TabMail/Services/BackendClient.swift": 2,                  // the AI requests: aiBytes, aiData
        "TabMail/Views/Account/PlanPickerView.swift": 1,            // verifyPurchaseWithBackend
        "TabMailNotificationService/BackendNSEClient.swift": 1,     // transport
        "TabMailNotificationService/NSEAICacheProbe.swift": 1,      // probe
        "TabMailNotificationService/NSEAuthSource.swift": 1,        // transport
        "TabMailNotificationService/NSETokenManager.swift": 1,      // transport
        "TabMailNotificationService/NotificationService.swift": 1,  // reconnectTransport
    ]

    @Test("Every use of URLSession.shared, every new session and every AI request in the app and the extension carries the policy")
    func everyRequestCarriesThePolicy() throws {
        let files = try Self.sources(under: ["TabMail", "Shared", "TabMailNotificationService"])
        var sharedUses: [String] = []
        var newSessions: [String] = []
        var deviceSyncSessions = 0
        var aiSends = 0
        var misses: [String] = []
        var uses: [String: Int] = [:]
        for file in files {
            for line in file.lines {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if code.contains(Self.policy) { uses[file.path, default: 0] += 1 }
                let usesShared = code.contains("URLSession.shared")
                    || code.range(of: #"URLSession\??\s*=\s*\.shared"#, options: .regularExpression) != nil
                if usesShared {
                    sharedUses.append(file.path)
                    if !code.contains(Self.policy) { misses.append("\(file.path): \(code)") }
                }
                if code.contains("URLSession(configuration:") {
                    newSessions.append(file.path)
                    if file.path == Self.deviceSyncFile {
                        deviceSyncSessions += 1
                        if !code.contains("delegate: self") { misses.append("\(file.path): \(code)") }
                    } else if !code.contains(Self.policy), !Self.sessionsWithoutPolicy.contains(file.path) {
                        misses.append("\(file.path): \(code)")
                    }
                }
                if file.path == Self.backendClientFile, Self.sendCalls.contains(where: { code.contains($0) }) {
                    if code.contains(Self.policy) {
                        aiSends += 1
                    } else if !code.contains("sharedEphemeralSession.") {
                        misses.append("\(file.path): \(code)")
                    }
                }
            }
        }
        #expect(misses.isEmpty, "\(misses)")
        #expect(uses == Self.policyUses, "where the policy is passed: \(uses)")
        let extensionUses = Set(sharedUses).filter { $0.hasPrefix("TabMailNotificationService/") }
        #expect(extensionUses.count >= 5, "the scan found the extension's requests: \(sharedUses)")
        #expect(newSessions.count >= 5, "the scan found the app's sessions: \(newSessions)")
        #expect(deviceSyncSessions == 1, "the scan found the device sync session")
        #expect(aiSends >= 2, "the scan found the AI requests")
    }
}
