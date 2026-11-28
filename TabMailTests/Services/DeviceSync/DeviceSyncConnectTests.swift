/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Network
import Synchronization
import Testing
@testable import TabMail

/// Accepts TCP connections on the loopback interface and records the request head each one sends. Connection N
/// (counted from 0) gets `answer(N)` once its head is in and is then closed; with no answer it stays open
/// without a reply, so a WebSocket client's upgrade stays pending while a test looks at it.
private final class LoopbackRecorder: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-recorder")
    private let heads = Mutex<[String]>([])
    private let answer: @Sendable (Int) -> Data?
    /// Read and written on `queue` only.
    private var connections: [NWConnection] = []

    init(answer: @escaping @Sendable (Int) -> Data? = { _ in nil }) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        self.answer = answer
    }

    /// Starts listening; the port it listens on.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let index = self.connections.count
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.read(connection, index, Data())
        }
        let listener = listener
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

    private func read(_ connection: NWConnection, _ index: Int, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.heads.withLock { $0.append(head) }
                if let reply = self.answer(index) {
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                }
                return
            }
            if error == nil, !isComplete { self.read(connection, index, buffer) }
        }
    }

    /// The request heads received so far, waiting up to `timeout` for at least `count` of them.
    func heads(atLeast count: Int, waitingUpTo timeout: Duration) async -> [String] {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while heads.withLock({ $0.count < count }), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return heads.withLock { $0 }
    }

    func stop() {
        listener.cancel()
        queue.async {
            self.connections.forEach { $0.cancel() }
            self.connections = []
        }
    }
}

/// Scripts what a connect takes from outside the service (`DeviceSyncService.ConnectEnvironment`) and
/// records what it asked for. A request scripted to `.hold` waits until the test answers it.
@MainActor
private final class ConnectScript {
    enum Step<Value> {
        case answer(Value)
        case hold
    }

    var relay: (base: String, webSocket: String)
    var foreground = true
    private(set) var tokenRequests = 0
    private(set) var passRequests: [(token: String, relayBase: String)] = []
    /// The step for token request N (counted from 1).
    var tokenStep: @MainActor (Int) -> Step<TabMailTokenCoordinator.RefreshResult> = { _ in
        .answer(.success(DeviceSyncConnectTests.token))
    }
    /// The step for pass request N (counted from 1).
    var passStep: @MainActor (Int) -> Step<String?> = { .answer("pass-\($0)") }

    private var heldTokens: [Int: CheckedContinuation<TabMailTokenCoordinator.RefreshResult, Never>] = [:]
    private var heldPasses: [Int: CheckedContinuation<String?, Never>] = [:]

    init(relay: (base: String, webSocket: String)) {
        self.relay = relay
    }

    var environment: DeviceSyncService.ConnectEnvironment {
        DeviceSyncService.ConnectEnvironment(
            relay: { self.relay },
            token: {
                self.tokenRequests += 1
                let request = self.tokenRequests
                switch self.tokenStep(request) {
                case .answer(let result):
                    return result
                case .hold:
                    return await withCheckedContinuation { self.heldTokens[request] = $0 }
                }
            },
            pass: { token, relayBase in
                self.passRequests.append((token, relayBase))
                let request = self.passRequests.count
                switch self.passStep(request) {
                case .answer(let pass):
                    return pass
                case .hold:
                    return await withCheckedContinuation { self.heldPasses[request] = $0 }
                }
            },
            foreground: { self.foreground }
        )
    }

    func isTokenHeld(_ request: Int) -> Bool { heldTokens[request] != nil }
    func isPassHeld(_ request: Int) -> Bool { heldPasses[request] != nil }

    func answerToken(_ request: Int, _ result: TabMailTokenCoordinator.RefreshResult) {
        heldTokens.removeValue(forKey: request)?.resume(returning: result)
    }

    func answerPass(_ request: Int, _ pass: String?) {
        heldPasses.removeValue(forKey: request)?.resume(returning: pass)
    }

    /// Answers every request still held: no session, no pass.
    func releaseAll() {
        for request in Array(heldTokens.keys) { answerToken(request, .noSession) }
        for request in Array(heldPasses.keys) { answerPass(request, nil) }
    }
}

/// A connect asks for a fresh one-time pass at the relay's HTTPS base and opens the socket at the relay's
/// socket address with that pass; both addresses come from one snapshot taken at the start of the connect.
/// A failed connect, or a socket the relay refuses, takes the shared backoff's scheduled retry, which gets a
/// pass of its own. A connect superseded during either wait (the token, the pass) changes nothing, whatever
/// answer arrives late: the attempt that replaced it keeps its state, and no stale retry is scheduled.
@Suite("Device Sync connects with a fresh pass", .serialized, .processGlobalState, .timeLimit(.minutes(1)))
@MainActor
struct DeviceSyncConnectTests {
    static let token = "header.payload.signature"
    private static let relayBase = "https://relay.example.com"
    private static let otherRelayBase = "https://other-relay.example.com"
    private static let epochZero = "1970-01-01T00:00:00.000Z"
    /// The per-field timestamps a new device's first connect writes.
    private static let timestampKeys = SyncField.legacyFields.map { "device_sync_ts:\($0.rawValue)" }

    /// The wait a connect is held at.
    enum Wait: String, Sendable, CaseIterable {
        case token = "its token"
        case pass = "its pass"
    }

    /// A late answer to the first connect's held request.
    enum LateAnswer: String, Sendable, CaseIterable {
        case transientFailure = "a transient token failure"
        case permanentFailure = "a permanent token failure"
        case noSession = "no session"
        case token = "a token"
        case pass = "a pass"
        case noPass = "no pass"

        var wait: Wait {
            switch self {
            case .pass, .noPass: .pass
            default: .token
            }
        }
    }

    /// What ends the first connect while it waits.
    enum Ending: String, Sendable, CaseIterable {
        case replacement = "a network change"
        case disconnect = "a disconnect"
    }

    /// Runs `body` against the shared service with `script` as its environment and the connect's gates open;
    /// `newDevice` clears the per-field timestamps, otherwise one is held back so a connect writes none.
    /// Restores all of it after.
    private func withService(
        _ script: ConnectScript,
        newDevice: Bool = false,
        _ body: (DeviceSyncService) async throws -> Void
    ) async throws {
        let standard = UserDefaults.standard
        let keys = [AgeAndTermsConsent.completedKey, "device_sync_auto_enabled"] + Self.timestampKeys
        let previous = keys.map { standard.object(forKey: $0) }
        let previousDemo = DemoModeStore.shared.isActive
        let sync = DeviceSyncService.shared
        let previousEnvironment = sync.connectEnvironment
        defer {
            sync.disconnect()
            script.releaseAll()
            sync.connectEnvironment = previousEnvironment
            DemoModeStore.shared.isActive = previousDemo
            for (key, value) in zip(keys, previous) {
                if let value { standard.set(value, forKey: key) } else { standard.removeObject(forKey: key) }
            }
        }
        sync.disconnect()
        DemoModeStore.shared.isActive = false
        standard.set(true, forKey: AgeAndTermsConsent.completedKey)
        standard.set(true, forKey: "device_sync_auto_enabled")
        if newDevice {
            Self.timestampKeys.forEach { standard.removeObject(forKey: $0) }
        } else if standard.object(forKey: Self.timestampKeys[0]) == nil {
            standard.set(Self.epochZero, forKey: Self.timestampKeys[0])
        }
        sync.connectEnvironment = script.environment

        try await body(sync)
    }

    /// Sleeps in short steps until `condition` holds or `timeout` passes.
    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func timestamps() -> [String?] {
        timestampKeys.map { UserDefaults.standard.string(forKey: $0) }
    }

    nonisolated private static func requestLine(_ head: String) -> String {
        String(head.split(separator: "\r\n", maxSplits: 1).first ?? "")
    }

    nonisolated private static func hasAuthorization(_ head: String) -> Bool {
        head.split(separator: "\r\n").contains { $0.lowercased().hasPrefix("authorization:") }
    }

    @Test("A connect opens the socket with a fresh pass; the upgrade carries neither the token nor an Authorization header")
    func connectOpensTheSocketWithAPass() async throws {
        let relay = try LoopbackRecorder()
        defer { relay.stop() }
        let port = try await relay.start()
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:\(port)/ws"))

        try await withService(script) { sync in
            sync.connect()
            await waitUntil { sync.webSocket != nil }

            let passTokens = script.passRequests.map { $0.token }
            let passBases = script.passRequests.map { $0.relayBase }
            #expect(passTokens == [Self.token])
            #expect(passBases == [Self.relayBase])
            let request = try #require(sync.webSocket?.originalRequest)
            #expect(request.url?.absoluteString == "ws://127.0.0.1:\(port)/ws?pass=pass-1")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

            let heads = await relay.heads(atLeast: 1, waitingUpTo: .seconds(10))
            #expect(heads.count == 1)
            guard heads.count == 1 else { return }
            #expect(Self.requestLine(heads[0]) == "GET /ws?pass=pass-1 HTTP/1.1")
            #expect(!Self.hasAuthorization(heads[0]))
            #expect(!heads[0].contains(Self.token))
        }
    }

    /// Nothing but the scheduled retry calls connect again here.
    @Test("A connect with no pass opens nothing; the scheduled retry connects with a fresh pass")
    func noPassTakesTheScheduledRetry() async throws {
        let relay = try LoopbackRecorder()
        defer { relay.stop() }
        let port = try await relay.start()
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:\(port)/ws"))
        script.passStep = { $0 == 1 ? .answer(nil) : .answer("pass-\($0)") }

        try await withService(script) { sync in
            sync.connect()
            let first = try #require(sync.connectTask)
            await first.value

            #expect(script.passRequests.count == 1)
            #expect(sync.webSocket == nil, "no socket without a pass")
            #expect(!sync.isConnecting)
            #expect(sync.reconnectAttempts == 1, "the failure took the shared backoff's first step")

            await waitUntil(.seconds(20)) { sync.webSocket != nil }

            #expect(script.passRequests.count == 2)
            #expect(sync.webSocket?.originalRequest?.url?.absoluteString == "ws://127.0.0.1:\(port)/ws?pass=pass-2")
            let heads = await relay.heads(atLeast: 1, waitingUpTo: .seconds(10))
            let requestLines = heads.map(Self.requestLine)
            #expect(requestLines == ["GET /ws?pass=pass-2 HTTP/1.1"])
        }
    }

    /// The relay refuses a pass it does not hold (spent, expired, minted elsewhere) at the upgrade.
    @Test("A socket the relay refuses at the upgrade ends; the scheduled retry connects with a fresh pass")
    func refusedUpgradeTakesTheScheduledRetry() async throws {
        let refusal = Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        let relay = try LoopbackRecorder(answer: { $0 == 0 ? refusal : nil })
        defer { relay.stop() }
        let port = try await relay.start()
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:\(port)/ws"))

        try await withService(script) { sync in
            sync.connect()

            let heads = await relay.heads(atLeast: 2, waitingUpTo: .seconds(20))
            let requestLines = heads.map(Self.requestLine)

            #expect(requestLines == ["GET /ws?pass=pass-1 HTTP/1.1", "GET /ws?pass=pass-2 HTTP/1.1"])
            #expect(script.passRequests.count == 2)
            #expect(sync.reconnectAttempts == 1, "the refused socket took the shared backoff's first step")
            await waitUntil { sync.webSocket?.originalRequest?.url?.query == "pass=pass-2" }
            #expect(sync.webSocket?.originalRequest?.url?.absoluteString == "ws://127.0.0.1:\(port)/ws?pass=pass-2")
        }
    }

    @Test(
        "A token refusal ends the connect: no session stops there, a failed refresh takes the retry step",
        arguments: [LateAnswer.noSession, .transientFailure, .permanentFailure]
    )
    func tokenRefusalEndsTheConnect(answer: LateAnswer) async throws {
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:9/ws"))
        let refusal: TabMailTokenCoordinator.RefreshResult = switch answer {
        case .transientFailure: .transientFailure
        case .permanentFailure: .permanentFailure
        default: .noSession
        }
        script.tokenStep = { _ in .answer(refusal) }

        try await withService(script, newDevice: true) { sync in
            sync.connect()
            let attempt = try #require(sync.connectTask)
            await attempt.value

            #expect(!sync.isConnecting)
            #expect(script.passRequests.isEmpty)
            #expect(sync.webSocket == nil)
            #expect(sync.reconnectAttempts == (answer == .noSession ? 0 : 1))
            let written = Self.timestamps()
            #expect(written == [nil, nil, nil], "a connect that opened nothing wrote no new-device state")
        }
    }

    /// The first connect is held at its token or its pass; a network change replaces it (the replacement is
    /// held at its own token) or a disconnect ends it. Only then does the first connect's answer arrive, and
    /// the test waits for that connect to finish before looking.
    @Test(
        "An answer that arrives after the connect was replaced or ended changes nothing",
        arguments: LateAnswer.allCases, Ending.allCases
    )
    func lateAnswerChangesNothing(late: LateAnswer, ending: Ending) async throws {
        let relay = try LoopbackRecorder()
        defer { relay.stop() }
        let port = try await relay.start()
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:\(port)/ws"))
        script.tokenStep = { request in
            request == 1 && late.wait == .pass ? .answer(.success(Self.token)) : .hold
        }
        script.passStep = { request in
            request == 1 && late.wait == .pass ? .hold : .answer("pass-\(request)")
        }

        try await withService(script, newDevice: true) { sync in
            sync.connect()
            await waitUntil { late.wait == .token ? script.isTokenHeld(1) : script.isPassHeld(1) }
            let first = try #require(sync.connectTask)

            switch ending {
            case .replacement:
                sync.forceReconnect()
                await waitUntil { script.isTokenHeld(2) }
                let replacementHeld = script.isTokenHeld(2)
                #expect(replacementHeld, "the replacement waits at its own token")
            case .disconnect:
                sync.disconnect()
            }

            switch late {
            case .transientFailure: script.answerToken(1, .transientFailure)
            case .permanentFailure: script.answerToken(1, .permanentFailure)
            case .noSession: script.answerToken(1, .noSession)
            case .token: script.answerToken(1, .success(Self.token))
            case .pass: script.answerPass(1, "pass-1")
            case .noPass: script.answerPass(1, nil)
            }
            await first.value

            #expect(sync.webSocket == nil, "the ended connect opened no socket")
            #expect(sync.reconnectAttempts == 0, "no retry scheduled for the ended connect")
            #expect(script.passRequests.count == (late.wait == .pass ? 1 : 0), "the ended connect asked for no pass")
            let writtenByTheEndedConnect = Self.timestamps()
            #expect(writtenByTheEndedConnect == [nil, nil, nil], "the ended connect wrote no new-device state")

            switch ending {
            case .replacement:
                #expect(sync.isConnecting, "the replacement connect is still connecting")
                #expect(script.tokenRequests == 2)

                // The replacement goes on with its own pass and sets up the new device.
                script.answerToken(2, .success(Self.token))
                await waitUntil { sync.webSocket != nil }
                let pass = "pass-\(late.wait == .pass ? 2 : 1)"
                #expect(sync.webSocket?.originalRequest?.url?.absoluteString == "ws://127.0.0.1:\(port)/ws?pass=\(pass)")
                let writtenByTheReplacement = Self.timestamps()
                #expect(writtenByTheReplacement == [Self.epochZero, Self.epochZero, Self.epochZero])
            case .disconnect:
                #expect(!sync.isConnecting)
                #expect(script.tokenRequests == 1)
            }
        }
    }

    @Test(
        "Both legs of a connect use the relay read at its start, whichever wait the setting changes in; the next connect uses the new one",
        arguments: Wait.allCases
    )
    func bothLegsUseOneRelaySnapshot(changedDuring wait: Wait) async throws {
        let first = try LoopbackRecorder()
        let second = try LoopbackRecorder()
        defer {
            first.stop()
            second.stop()
        }
        let firstPort = try await first.start()
        let secondPort = try await second.start()
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:\(firstPort)/ws"))
        script.tokenStep = { request in
            request == 1 && wait == .token ? .hold : .answer(.success(Self.token))
        }
        script.passStep = { request in
            request == 1 && wait == .pass ? .hold : .answer("pass-\(request)")
        }

        try await withService(script) { sync in
            sync.connect()
            await waitUntil { wait == .token ? script.isTokenHeld(1) : script.isPassHeld(1) }

            // The server setting changes while the first connect waits.
            script.relay = (Self.otherRelayBase, "ws://127.0.0.1:\(secondPort)/ws")
            switch wait {
            case .token: script.answerToken(1, .success(Self.token))
            case .pass: script.answerPass(1, "pass-1")
            }
            await waitUntil { sync.webSocket != nil }

            let firstBases = script.passRequests.map { $0.relayBase }
            #expect(firstBases == [Self.relayBase])
            #expect(sync.webSocket?.originalRequest?.url?.absoluteString == "ws://127.0.0.1:\(firstPort)/ws?pass=pass-1")

            sync.disconnect()
            sync.connect()
            await waitUntil { sync.webSocket != nil }

            let bothBases = script.passRequests.map { $0.relayBase }
            #expect(bothBases == [Self.relayBase, Self.otherRelayBase])
            #expect(sync.webSocket?.originalRequest?.url?.absoluteString == "ws://127.0.0.1:\(secondPort)/ws?pass=pass-2")
        }
    }

    /// The live pass request against a real HTTP listener: what actually leaves the app.
    @Test("The pass request reaches the relay with the token in its Authorization header and nowhere else")
    func passRequestCarriesTheTokenOnlyInItsHeader() async throws {
        let body = #"{"pass":"pass-from-relay"}"#
        let answer = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8
        )
        let relay = try LoopbackRecorder(answer: { _ in answer })
        defer { relay.stop() }
        let port = try await relay.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let pass = await BackendClient.requestSyncConnectPass(
            token: Self.token, relayBaseURL: "http://127.0.0.1:\(port)", session: session
        )

        #expect(pass == "pass-from-relay")
        let heads = await relay.heads(atLeast: 1, waitingUpTo: .seconds(10))
        #expect(heads.count == 1)
        guard heads.count == 1 else { return }
        let lines = heads[0].split(separator: "\r\n").map(String.init)
        #expect(lines.first == "POST /ws/pass HTTP/1.1")
        let carrying = lines.filter { $0.contains(Self.token) }.map { $0.lowercased() }
        #expect(carrying == ["authorization: bearer \(Self.token)"])
    }
}
