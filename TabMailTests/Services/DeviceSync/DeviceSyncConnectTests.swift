/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Network
import Synchronization
import Testing
@testable import TabMail

/// Accepts TCP connections on the loopback interface and records the request head each one sends, without
/// answering: a WebSocket client's upgrade stays pending, so nothing fails while a test looks at it.
private final class LoopbackUpgradeRecorder: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-upgrade-recorder")
    private let heads = Mutex<[String]>([])
    /// Read and written on `queue` only.
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Starts listening; the port it listens on.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.read(connection, Data())
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

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.heads.withLock { $0.append(head) }
                return
            }
            if error == nil, !isComplete { self.read(connection, buffer) }
        }
    }

    /// The request heads received so far, waiting up to `timeout` for the first.
    func receivedHeads(waitingUpTo timeout: Duration) async -> [String] {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while heads.withLock({ $0.isEmpty }), clock.now < deadline {
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
/// records what it asked for.
@MainActor
private final class ConnectScript {
    var relay: (base: String, webSocket: String)
    private(set) var tokenRequests = 0
    private(set) var passRequests: [(token: String, relayBase: String)] = []
    /// The answer to token request N (counted from 1); nil holds that request until `release()`. At most one
    /// request is held at a time (one waiter on `released`).
    var tokenAnswer: @MainActor (Int) -> TabMailTokenCoordinator.RefreshResult? = { _ in
        .success(DeviceSyncConnectTests.token)
    }
    /// The answer to pass request N (counted from 1).
    var passAnswer: @MainActor (Int) -> String? = { "pass-\($0)" }

    /// One element each time a token request is held.
    let heldTokenRequests: AsyncStream<Void>
    private let heldSink: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releaseSink: AsyncStream<Void>.Continuation

    init(relay: (base: String, webSocket: String)) {
        self.relay = relay
        let held = AsyncStream.makeStream(of: Void.self)
        heldTokenRequests = held.stream
        heldSink = held.continuation
        let release = AsyncStream.makeStream(of: Void.self)
        released = release.stream
        releaseSink = release.continuation
    }

    var environment: DeviceSyncService.ConnectEnvironment {
        DeviceSyncService.ConnectEnvironment(
            relay: { self.relay },
            token: {
                self.tokenRequests += 1
                if let answer = self.tokenAnswer(self.tokenRequests) { return answer }
                self.heldSink.yield()
                for await _ in self.released { break }
                return .noSession
            },
            pass: { token, relayBase in
                self.passRequests.append((token, relayBase))
                return self.passAnswer(self.passRequests.count)
            }
        )
    }

    /// Lets every held token request finish (with no session).
    func release() {
        releaseSink.finish()
    }

    /// Waits until a token request is held.
    func untilATokenRequestIsHeld() async {
        for await _ in heldTokenRequests { return }
    }
}

/// A connect asks for a fresh one-time pass at the relay's HTTPS base and opens the socket at the relay's
/// socket address with that pass; both addresses come from one snapshot taken at the start of the connect.
/// A connect superseded during either wait (the token, the pass) changes nothing: the attempt that replaced
/// it keeps its state, and no stale retry is scheduled.
@Suite("Device Sync connects with a fresh pass", .serialized, .processGlobalState, .timeLimit(.minutes(1)))
@MainActor
struct DeviceSyncConnectTests {
    static let token = "header.payload.signature"
    private static let relayBase = "https://relay.example.com"
    private static let otherRelayBase = "https://other-relay.example.com"

    /// Runs `body` against the shared service with `script` as its environment, the connect's gates open,
    /// and a held-back timestamp so a connect writes no new-device state; restores all of it after.
    private func withService(
        _ script: ConnectScript,
        _ body: (DeviceSyncService) async throws -> Void
    ) async throws {
        let standard = UserDefaults.standard
        let keys = [AgeAndTermsConsent.completedKey, "device_sync_auto_enabled", "device_sync_ts:templates"]
        let previous = keys.map { standard.object(forKey: $0) }
        let previousDemo = DemoModeStore.shared.isActive
        let sync = DeviceSyncService.shared
        let previousEnvironment = sync.connectEnvironment
        defer {
            sync.disconnect()
            script.release()
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
        if previous[2] == nil { standard.set("1970-01-01T00:00:00.000Z", forKey: "device_sync_ts:templates") }
        sync.connectEnvironment = script.environment

        try await body(sync)
    }

    /// Yields the main actor until `condition` holds (bounded).
    private func settle(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 1_000 {
            await Task.yield()
            spins += 1
        }
    }

    private static func requestLine(_ head: String) -> String {
        String(head.split(separator: "\r\n", maxSplits: 1).first ?? "")
    }

    private static func hasAuthorization(_ head: String) -> Bool {
        head.split(separator: "\r\n").contains { $0.lowercased().hasPrefix("authorization:") }
    }

    @Test("A connect opens the socket with a fresh pass; the upgrade carries neither the token nor an Authorization header")
    func connectOpensTheSocketWithAPass() async throws {
        let relay = try LoopbackUpgradeRecorder()
        defer { relay.stop() }
        let port = try await relay.start()
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:\(port)/ws"))

        try await withService(script) { sync in
            sync.connect()
            await settle { sync.webSocket != nil }

            #expect(script.passRequests.map(\.token) == [Self.token])
            #expect(script.passRequests.map(\.relayBase) == [Self.relayBase])
            let request = try #require(sync.webSocket?.originalRequest)
            #expect(request.url?.absoluteString == "ws://127.0.0.1:\(port)/ws?pass=pass-1")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

            let heads = await relay.receivedHeads(waitingUpTo: .seconds(10))
            #expect(heads.count == 1)
            guard heads.count == 1 else { return }
            #expect(Self.requestLine(heads[0]) == "GET /ws?pass=pass-1 HTTP/1.1")
            #expect(!Self.hasAuthorization(heads[0]))
            #expect(!heads[0].contains(Self.token))
        }
    }

    @Test("A connect with no pass opens nothing and takes the retry step; the next connect gets a fresh pass")
    func noPassTakesTheRetryStep() async throws {
        let relay = try LoopbackUpgradeRecorder()
        defer { relay.stop() }
        let port = try await relay.start()
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:\(port)/ws"))
        script.passAnswer = { $0 == 1 ? nil : "pass-\($0)" }

        try await withService(script) { sync in
            sync.connect()
            await settle { !sync.isConnecting }

            #expect(script.passRequests.count == 1)
            #expect(sync.webSocket == nil, "no socket without a pass")
            #expect(!sync.isConnecting)
            #expect(sync.reconnectAttempts == 1, "the failure took the shared backoff's retry step")

            // The foreground return connects again at once, with a pass of its own.
            sync.reconnectIfNeeded()
            await settle { sync.webSocket != nil }

            #expect(script.passRequests.count == 2)
            #expect(sync.webSocket?.originalRequest?.url?.absoluteString == "ws://127.0.0.1:\(port)/ws?pass=pass-2")
        }
    }

    @Test(
        "A token answer that arrives after the connect was replaced leaves the new connect alone",
        arguments: ["transient failure", "permanent failure", "no session", "success"]
    )
    func tokenAnswerAfterReplacementChangesNothing(answer: String) async throws {
        let relay = try LoopbackUpgradeRecorder()
        defer { relay.stop() }
        let port = try await relay.start()
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:\(port)/ws"))
        let sync = DeviceSyncService.shared
        let staleAnswer: TabMailTokenCoordinator.RefreshResult = switch answer {
        case "transient failure": .transientFailure
        case "permanent failure": .permanentFailure
        case "no session": .noSession
        default: .success(Self.token)
        }
        // The first connect is replaced (a network change) while it waits for its token; the replacement's
        // own token request is held, so the replacement is still connecting when the first one's answer lands.
        script.tokenAnswer = { request in
            guard request == 1 else { return nil }
            sync.forceReconnect()
            return staleAnswer
        }

        try await withService(script) { sync in
            sync.connect()
            // The replacement's token request starts only once the first connect has finished.
            await script.untilATokenRequestIsHeld()

            #expect(script.tokenRequests == 2)
            #expect(sync.isConnecting, "the replacement connect is still connecting")
            #expect(sync.reconnectAttempts == 0, "no retry scheduled for the replaced connect")
            #expect(script.passRequests.isEmpty)
            #expect(sync.webSocket == nil)
        }
    }

    @Test("A pass that arrives after the connect was replaced opens nothing")
    func passAfterReplacementOpensNothing() async throws {
        let relay = try LoopbackUpgradeRecorder()
        defer { relay.stop() }
        let port = try await relay.start()
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:\(port)/ws"))
        let sync = DeviceSyncService.shared
        script.tokenAnswer = { $0 == 1 ? .success(Self.token) : nil }
        script.passAnswer = { request in
            if request == 1 { sync.forceReconnect() }
            return "pass-\(request)"
        }

        try await withService(script) { sync in
            sync.connect()
            await script.untilATokenRequestIsHeld()

            #expect(script.passRequests.count == 1)
            #expect(sync.webSocket == nil, "the replaced connect opened no socket with its pass")
            #expect(sync.isConnecting, "the replacement connect is still connecting")
            #expect(sync.reconnectAttempts == 0)
        }
    }

    @Test("Both legs of a connect use the relay read at its start; the next connect uses the new one")
    func bothLegsUseOneRelaySnapshot() async throws {
        let first = try LoopbackUpgradeRecorder()
        let second = try LoopbackUpgradeRecorder()
        defer {
            first.stop()
            second.stop()
        }
        let firstPort = try await first.start()
        let secondPort = try await second.start()
        let script = ConnectScript(relay: (Self.relayBase, "ws://127.0.0.1:\(firstPort)/ws"))
        // The server setting changes while the first connect waits for its pass.
        script.passAnswer = { request in
            if request == 1 { script.relay = (Self.otherRelayBase, "ws://127.0.0.1:\(secondPort)/ws") }
            return "pass-\(request)"
        }

        try await withService(script) { sync in
            sync.connect()
            await settle { sync.webSocket != nil }

            #expect(script.passRequests.map(\.relayBase) == [Self.relayBase])
            #expect(sync.webSocket?.originalRequest?.url?.absoluteString == "ws://127.0.0.1:\(firstPort)/ws?pass=pass-1")

            sync.disconnect()
            sync.connect()
            await settle { sync.webSocket != nil }

            #expect(script.passRequests.map(\.relayBase) == [Self.relayBase, Self.otherRelayBase])
            #expect(sync.webSocket?.originalRequest?.url?.absoluteString == "ws://127.0.0.1:\(secondPort)/ws?pass=pass-2")
        }
    }
}
