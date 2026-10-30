/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Darwin
import Foundation
import Network
import Testing
@testable import TabMail

/// A WebSocket server on the loopback interface, in this process, that sends a text message when asked.
private final class LoopbackWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-websocket")
    /// Read and written on `queue` only.
    private var connection: NWConnection?
    private var open = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Starts listening; the port it listens on.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.open = true }
            }
            connection.start(queue: self.queue)
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

    /// Whether a client's handshake has completed.
    var isOpen: Bool { queue.sync { open } }

    func send(_ text: String) {
        queue.async { [self] in
            let context = NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    func stop() {
        queue.sync { connection?.cancel() }
        listener.cancel()
    }
}

/// A message a socket read after its connection ended never reaches the prompt store (DS-RECEIVE): the
/// connection that replaced it would otherwise take it as its own.
@MainActor
@Suite("Device Sync socket boundary", .serialized, .processGlobalState)
struct DeviceSyncSocketBoundaryTests {
    private func stored(_ text: String) -> Bool {
        PromptStore.shared.rawKB.contains(text)
    }

    @Test("A message the socket received after a disconnect is never applied; a message received afterwards is")
    func receiveAfterDisconnectIsDropped() async throws {
        let defaults = UserDefaults.standard
        let savedAuto = defaults.object(forKey: "device_sync_auto_enabled")
        defer { defaults.set(savedAuto, forKey: "device_sync_auto_enabled") }
        let store = PromptStore.shared
        let sync = DeviceSyncService.shared
        defaults.set(false, forKey: "device_sync_auto_enabled")
        sync.disconnect()
        let tag = PromptStoreTestCleanup.tag()
        let server = try LoopbackWebSocketServer()
        let session = URLSession(configuration: .ephemeral)
        var failure: Error?
        do {
            let port = try await server.start()
            let socket = session.webSocketTask(with: try #require(URL(string: "ws://127.0.0.1:\(port)")))
            sync.webSocket = socket
            socket.resume()
            let receiver = Task { await sync.receiveLoop() }
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline, !server.isOpen {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(server.isOpen)
            // The loop waits in its receive. The message arrives while the main actor stays busy, so the
            // receive's result is queued behind the disconnect below.
            try await Task.sleep(for: .milliseconds(100))
            server.send(ForeignBulletMessage.kb("\(tag) old socket message after disconnect"))
            usleep(1_000_000)
            sync.disconnect()
            await receiver.value
            try await Task.sleep(for: .milliseconds(300))
            #expect(!stored("\(tag) old socket message after disconnect"))

            // Control: a message received afterwards is applied.
            sync.handleMessage(ForeignBulletMessage.kb("\(tag) message after the disconnect"))
            let applied = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < applied, !stored("\(tag) message after the disconnect") {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(stored("\(tag) message after the disconnect"))
        } catch {
            failure = error
        }
        sync.disconnect()
        session.invalidateAndCancel()
        server.stop()
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
        if let failure { throw failure }
    }
}
