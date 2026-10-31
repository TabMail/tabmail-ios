/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import UIKit

/// Device Sync always-on sync service using WebSocket relay.
/// Syncs prompt settings between TabMail instances (iOS ↔ TB) automatically.
///
/// Protocol:
/// 1. Connect to Device Sync worker via WebSocket (wss://sync.tabmail.ai/ws)
/// 2. Authenticate with TabMail session JWT token
/// 3. The knowledge base, composition rules and action rules sync as labelled bullets
///    (`bullet_state`, `PromptBulletSync`): each is sent on connect, after a local change, and after
///    a merge of a peer's state that differed from this device's (DS-SEND, DS-MERGE).
/// 4. Templates, disabled reminders and the action config sync in `prompt_state`: on connect
///    broadcast with per-field timestamps, on local edit debounced, on receive per-field merge (newer
///    wins). Its three text fields go out empty at epoch zero, which released apps skip; a released
///    app's texts are imported as additions only (DS-LEGACY-OUT, DS-LEGACY-IN).
/// 5. On receive request_state: respond with requested fields
///
/// Every received message is applied inside a hold of the prompt store (DS-RECEIVE), in arrival order.
@MainActor @Observable
final class DeviceSyncService: NSObject, URLSessionWebSocketDelegate {
    static let shared = DeviceSyncService()

    private(set) var isConnected = false {
        didSet { DeviceSyncService.connectedMutex.withLock { $0 = isConnected } }
    }
    private(set) var isConnecting = false

    /// Mutex-backed for nonisolated reads from background actors (AI queue, AI service).
    nonisolated private static let connectedMutex = Mutex(false)

    /// Read connectivity from any isolation context without MainActor hop.
    nonisolated static func checkConnected() -> Bool {
        connectedMutex.withLock { $0 }
    }

    /// Whether auto-sync is enabled (default: true). User can toggle in settings.
    var isAutoEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "device_sync_auto_enabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "device_sync_auto_enabled")
            if newValue {
                connect()
            } else {
                disconnect()
            }
        }
    }

    var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pingTimer: Timer?
    private var probeTimer: Timer?
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    private let pingInterval: TimeInterval = 30
    private let probeInterval: TimeInterval = 300 // 5 minutes
    private let reconnectBaseDelay: TimeInterval = 5
    private let reconnectMaxDelay: TimeInterval = 300 // 5 minutes
    private let maxReconnectAttempts = 10
    private var reconnectAttempts = 0

    /// When true, the receive loop should NOT schedule a reconnect (user pressed disconnect or app backgrounded).
    private var intentionalDisconnect = false

    /// The received messages for the prompt store, applied one after another in arrival order (DS-RECEIVE):
    /// one the store refused as busy is applied again before any received after it.
    private var receiveChain: Task<Void, Never>?
    /// The received messages of this connection in `receiveChain` not yet finished, at most
    /// `BulletSyncConfig.maxWaitingReceives`.
    private var waitingReceives = 0
    /// The parts the engine held for incomplete snapshots after the last `bullet_state` applied on this
    /// connection; they count toward the same bound as waiting messages (DS-RECEIVE, Bound).
    private var heldParts = 0
    /// Renewed when the connection ends: a message received on an earlier connection is never applied
    /// again (peers send their state on every connect).
    private var connectionID = UUID()

    /// Debounce task for auto-broadcast on local edits (500ms).
    private var broadcastDebounceTask: Task<Void, Never>?
    /// Fields accumulated during debounce window.
    private var pendingBroadcastFields: Set<SyncField> = []

    /// External handler for AI cache probes — set by the app layer which has access to the database.
    /// Called with probe keys and optional fields filter, returns results keyed by probe key.
    var aiCacheProbeHandler: (([String], [String]?) async -> [String: AICacheResult])?

    private let broadcastDebounceMs: UInt64 = 500

    private var baseURL: String { BackendConfig.syncWebSocketURL }

    /// Epoch zero — used for new devices that have no per-field timestamps yet.
    private static let epochZero = "1970-01-01T00:00:00.000Z"

    /// Log-safe rendering of a transport error. URLSession errors carry the
    /// failing URL in userInfo (`NSErrorFailingURLStringKey`) — for this
    /// service that URL embeds the auth token as a query parameter
    /// (`ws?token=JWT`), so interpolating the raw error leaked a live
    /// credential into the console capture (observed 2026-06-09). Render only
    /// domain + code + description, with any query string stripped
    /// defensively. Use this for EVERY error originating from the WebSocket /
    /// URLSession layer; never interpolate those errors raw.
    nonisolated static func redactedTransportError(_ error: any Error) -> String {
        let ns = error as NSError
        let redactedDescription = ns.localizedDescription.replacingOccurrences(
            of: #"\?[^\s"'\)]+"#,
            with: "?<redacted>",
            options: .regularExpression
        )
        return "\(ns.domain) code=\(ns.code) \(redactedDescription)"
    }

    private override init() {
        super.init()
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        BackgroundSyncLogger.logDebug("[DeviceSync] WebSocket didOpen, protocol: \(`protocol` ?? "none")")
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        DeviceSyncLogger.log("WS_CLOSE code=\(closeCode.rawValue) reason=\(reasonStr)")
        if closeCode != .normalClosure {
            BackgroundSyncLogger.logDebug("[DeviceSync] WebSocket didClose, code: \(closeCode.rawValue), reason: \(reasonStr)")
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            let redacted = Self.redactedTransportError(error)
            DeviceSyncLogger.log("WS_ERROR \(redacted)")
            BackgroundSyncLogger.logDebug("[DeviceSync] Task completed with error: \(redacted)")
            if let httpResponse = task.response as? HTTPURLResponse {
                BackgroundSyncLogger.logDebug("[DeviceSync] HTTP status: \(httpResponse.statusCode)")
                BackgroundSyncLogger.logDebug("[DeviceSync] HTTP headers: \(httpResponse.allHeaderFields)")
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        for tm in metrics.transactionMetrics {
            let proto = tm.networkProtocolName ?? "unknown"
            BackgroundSyncLogger.logDebug("[DeviceSync] Protocol negotiated: \(proto)")
            if let resp = tm.response as? HTTPURLResponse {
                BackgroundSyncLogger.logDebug("[DeviceSync] Response status: \(resp.statusCode), headers: \(resp.allHeaderFields)")
            }
        }
    }

    // MARK: - Connect / Disconnect

    func connect() {
        // Device Sync is fully disabled in demo.
        // The anonymous demo session has no peer-pairing context, and
        // probing peers from a demo install would leak demo state.
        if DemoModeStore.shared.isActive {
            BackgroundSyncLogger.logDebug("[DeviceSync] Demo mode active — skipping connect")
            return
        }
        guard isAutoEnabled else {
            BackgroundSyncLogger.logDebug("[DeviceSync] Auto-sync disabled, skipping connect")
            return
        }
        // The device-sync worker refuses an account that has not passed the
        // age and terms screen; RootView connects once it has.
        guard AgeAndTermsConsent.isComplete() else {
            BackgroundSyncLogger.logDebug("[DeviceSync] Age and terms screen not passed, skipping connect")
            return
        }
        guard webSocket == nil, !isConnecting else { return }
        intentionalDisconnect = false
        isConnecting = true

        connectTask = Task { [weak self] in
            await self?.connectWithFreshToken()
        }
    }

    /// No-op if already connected or auto-sync disabled; calls connect() otherwise.
    func reconnectIfNeeded() {
        guard isAutoEnabled, !isConnected, !isConnecting else { return }
        reconnectAttempts = 0 // reset backoff when explicitly reconnecting
        connect()
    }

    /// Tear down the current WebSocket and reconnect immediately.
    /// Called by NetworkMonitor when the network interface changes (WiFi ↔ cellular)
    /// — the old TCP connection is bound to the previous interface and is dead.
    func forceReconnect() {
        guard isAutoEnabled else { return }
        // Tear down old connection without setting intentionalDisconnect
        connectTask?.cancel()
        connectTask = nil
        broadcastDebounceTask?.cancel()
        broadcastDebounceTask = nil
        pendingBroadcastFields = []
        pingTimer?.invalidate()
        pingTimer = nil
        probeTimer?.invalidate()
        probeTimer = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        for (_, continuation) in pendingProbes {
            continuation.resume(returning: nil)
        }
        pendingProbes.removeAll()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        isConnecting = false
        connectionEnded()
        reconnectAttempts = 0 // fresh network, reset backoff
        BackgroundSyncLogger.logDebug("[DeviceSync] Force reconnect — network interface changed")
        connect()
    }

    /// Mark as dirty — forces reconnect on next use.
    /// Called by AccountManager.markAllProvidersDirty() on session start
    /// (foreground return, BGAppRefresh, push wakeup).
    func markDirty() {
        guard isAutoEnabled, isConnected || isConnecting else { return }
        forceReconnect()
    }

    private func connectWithFreshToken() async {
        // Get a valid token via the shared coordinator (deduplicates concurrent refreshes)
        let token: String
        switch await TabMailTokenCoordinator.shared.validToken() {
        case .success(let t):
            token = t
        case .noSession:
            BackgroundSyncLogger.logDebug("[DeviceSync] No session found, cannot connect")
            DeviceSyncLogger.log("CONNECT_FAIL no session")
            isConnecting = false
            return
        case .permanentFailure:
            BackgroundSyncLogger.logDebug("[DeviceSync] Token refresh permanently failed — will retry later")
            DeviceSyncLogger.log("CONNECT_FAIL token refresh permanent failure")
            isConnecting = false
            scheduleReconnect()
            return
        case .transientFailure:
            BackgroundSyncLogger.logDebug("[DeviceSync] Token refresh failed (transient), scheduling reconnect")
            DeviceSyncLogger.log("CONNECT_FAIL token refresh transient failure")
            isConnecting = false
            scheduleReconnect()
            return
        }

        // Check if superseded by forceReconnect() / disconnect() during token fetch
        guard !Task.isCancelled else {
            isConnecting = false
            return
        }

        // Initialize per-field timestamps if this is a new device
        initTimestampsIfNeeded()

        guard var components = URLComponents(string: baseURL) else {
            isConnecting = false
            return
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            isConnecting = false
            return
        }

        BackgroundSyncLogger.logDebug("[DeviceSync] Connecting to \(baseURL)...")
        DeviceSyncLogger.log("CONNECT → \(baseURL)")

        let config = URLSessionConfiguration.default
        let wsSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = wsSession
        let ws = wsSession.webSocketTask(with: url)
        webSocket = ws
        ws.resume()

        // Start receiving messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // Start ping timer
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendPing()
            }
        }

        // Start probe timer — periodically request state from peers (every 5 min)
        probeTimer = Timer.scheduledTimer(withTimeInterval: probeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.probeAllFields()
            }
        }
    }

    func disconnect() {
        DeviceSyncLogger.log("DISCONNECT intentional")
        intentionalDisconnect = true
        connectTask?.cancel()
        connectTask = nil
        broadcastDebounceTask?.cancel()
        broadcastDebounceTask = nil
        pendingBroadcastFields = []
        pingTimer?.invalidate()
        pingTimer = nil
        probeTimer?.invalidate()
        probeTimer = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        // Resume any pending AI cache probe continuations so callers don't hang
        for (_, continuation) in pendingProbes {
            continuation.resume(returning: nil)
        }
        pendingProbes.removeAll()
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnecting = false
        isConnected = false
        connectionEnded()
        reconnectAttempts = 0
        BackgroundSyncLogger.logDebug("[DeviceSync] Disconnected")
    }

    /// Public "Sync Now" — broadcasts local state AND requests state from peers.
    /// Used by pull-to-refresh and manual sync buttons.
    func syncNow() {
        guard isConnected else {
            // Not connected — try to connect first
            if isAutoEnabled {
                connect()
            }
            return
        }
        // DS-NO-REQUEST: Sync Now sends all three bullet fields, as on connect, then the prompt_state fields.
        if !DemoModeStore.isDemoActive {
            applyReceived("sync now") { [weak self] access in
                try access.sendAll()
                self?.broadcastAllFields()
            }
        } else {
            broadcastAllFields()
        }
        probeAllFields()
    }

    /// Request every `prompt_state` field from peers (routine probe), never the bullet fields: those
    /// arrive as `bullet_state` when a peer connects or changes them.
    private func probeAllFields() {
        requestStateFromPeers(fields: SyncField.legacyFields.map(\.rawValue))
        BackgroundSyncLogger.logDebug("[DeviceSync] Probe: requested the prompt_state fields from peers")
    }

    // MARK: - Per-Field Timestamps

    private enum TimestampKey {
        static let composition = "device_sync_ts:composition"
        static let action = "device_sync_ts:action"
        static let kb = "device_sync_ts:kb"
        static let templates = "device_sync_ts:templates"
        static let disabledReminders = "device_sync_ts:disabledReminders"
        static let actionConfig = ActionCompactConfig.updatedAtKey

        static func key(for field: SyncField) -> String {
            switch field {
            case .composition: return composition
            case .action: return action
            case .kb: return kb
            case .templates: return templates
            case .disabledReminders: return disabledReminders
            case .actionConfig: return actionConfig
            }
        }
    }

    private func readTimestamp(for field: SyncField) -> String {
        UserDefaults.standard.string(forKey: TimestampKey.key(for: field)) ?? Self.epochZero
    }

    private func writeTimestamp(_ ts: String, for field: SyncField) {
        UserDefaults.standard.set(ts, forKey: TimestampKey.key(for: field))
    }

    /// If no per-field timestamps exist, initialize all to epoch 0 (new device).
    private func initTimestampsIfNeeded() {
        let defaults = UserDefaults.standard
        let anyExists = SyncField.legacyFields.contains { defaults.string(forKey: TimestampKey.key(for: $0)) != nil }
        if !anyExists {
            BackgroundSyncLogger.logDebug("[DeviceSync] New device — initializing per-field timestamps to epoch 0")
            for field in SyncField.legacyFields {
                writeTimestamp(Self.epochZero, for: field)
            }
        }
    }

    // MARK: - Debounced Broadcast (called from PromptStore.didSet)

    /// Accumulate fields and broadcast after a debounce window.
    func debouncedBroadcast(fields: Set<SyncField>) {
        pendingBroadcastFields.formUnion(fields)

        // Update per-field timestamps for locally changed fields
        let now = Date().ISO8601Format()
        for field in fields {
            writeTimestamp(now, for: field)
        }

        broadcastDebounceTask?.cancel()
        broadcastDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.broadcastDebounceMs ?? 500))
            guard !Task.isCancelled else { return }
            self?.flushBroadcast()
        }
    }

    /// Mark a `prompt_state` field as "reset to defaults" — sets epoch-zero timestamp so the default
    /// content never overwrites customized data on other devices, then requests the field from
    /// peers so they send back their (presumably newer) data. The bullet fields reset through
    /// `PromptStore` (DS-RESET), with no request.
    func markFieldAsReset(_ field: SyncField) {
        writeTimestamp(Self.epochZero, for: field)
        requestStateFromPeers(fields: [field.rawValue])
    }

    /// Send request_state to peers asking them to send back specified fields.
    private func requestStateFromPeers(fields: [String]) {
        guard let ws = webSocket, isConnected else { return }
        let msg: [String: Any] = ["type": "request_state", "fields": fields]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let text = String(data: data, encoding: .utf8) {
            ws.send(.string(text)) { error in
                if let error { BackgroundSyncLogger.logDebug("[DeviceSync] request_state send failed: \(Self.redactedTransportError(error))") }
            }
        }
        BackgroundSyncLogger.logDebug("[DeviceSync] Requested state from peers for fields: \(fields)")
    }

    private func flushBroadcast() {
        guard let ws = webSocket, !pendingBroadcastFields.isEmpty else { return }
        let fields = pendingBroadcastFields
        pendingBroadcastFields = []

        sendPromptState(promptState(for: Array(fields)), via: ws)
        BackgroundSyncLogger.logDebug("[DeviceSync] Auto-broadcast \(fields.map(\.rawValue)) to peers")
    }

    /// This device's current value and per-field timestamp for each of `fields` — the one
    /// payload builder for auto-broadcasts, `request_state` replies and the connect broadcast.
    /// The bullet fields go out empty at epoch zero (DS-LEGACY-OUT): released apps skip them, and never
    /// receive this app's texts, which could make a released receiver remove its own bullets.
    func promptState(for fields: [SyncField]) -> PromptStateData {
        let store = PromptStore.shared
        var state = PromptStateData()

        for field in fields {
            switch field {
            case .composition:
                state.composition = ""
                state.compositionUpdatedAt = Self.epochZero
            case .action:
                state.action = ""
                state.actionUpdatedAt = Self.epochZero
            case .kb:
                state.kb = ""
                state.kbUpdatedAt = Self.epochZero
            case .templates:
                state.templates = store.templates
                state.templatesUpdatedAt = readTimestamp(for: .templates)
            case .disabledReminders:
                state.disabledReminders = DisabledRemindersStore.getDisabledMap()
                state.disabledRemindersUpdatedAt = readTimestamp(for: .disabledReminders)
            case .actionConfig:
                state.actionConfig = ActionCompactConfig.local()
                state.actionConfigUpdatedAt = readTimestamp(for: .actionConfig)
            }
        }
        return state
    }

    /// Broadcast all `prompt_state` fields with per-field timestamps (used on connect).
    /// Virgin devices (all of those timestamps epoch-zero) skip broadcasting defaults
    /// and probe peers instead — prevents default content from clobbering
    /// customized data on established devices via LWW. The bullet fields are not
    /// part of this: they always go out as `bullet_state`.
    private func broadcastAllFields() {
        guard let ws = webSocket else { return }

        let allEpochZero = SyncField.legacyFields.allSatisfy { readTimestamp(for: $0) == Self.epochZero }
        if allEpochZero {
            BackgroundSyncLogger.logDebug("[DeviceSync] Virgin device — skipping broadcast, probing peers instead")
            probeAllFields()
            return
        }

        sendPromptState(promptState(for: SyncField.legacyFields), via: ws)
        BackgroundSyncLogger.logDebug("[DeviceSync] Broadcast all fields on connect")
    }

    // MARK: - Private Message Handling

    private func sendPromptState(_ state: PromptStateData, via ws: URLSessionWebSocketTask) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let msg = SyncMessage(type: "prompt_state", data: state)
            let payload = try encoder.encode(msg)
            let text = String(data: payload, encoding: .utf8) ?? "{}"
            ws.send(.string(text)) { error in
                if let error { BackgroundSyncLogger.logDebug("[DeviceSync] Failed to send: \(Self.redactedTransportError(error))") }
            }
        } catch {
            BackgroundSyncLogger.logDebug("[DeviceSync] Failed to encode state: \(error)")
        }
    }

    func receiveLoop() async {
        guard let ws = webSocket else { return }

        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                // A message read from a socket that has since ended is never handled: the connection that
                // renewed it would otherwise take it as its own (DS-RECEIVE).
                guard webSocket === ws, !Task.isCancelled else {
                    BackgroundSyncLogger.logDebug("[DeviceSync] A message received on an ended connection was dropped")
                    return
                }
                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                // Guard: if webSocket was replaced by forceReconnect() while we were
                // awaiting, this error is from a stale connection — don't touch state.
                guard webSocket === ws else { return }
                if !intentionalDisconnect {
                    BackgroundSyncLogger.logDebug("[DeviceSync] WebSocket receive error: \(Self.redactedTransportError(error))")
                }
                isConnecting = false
                isConnected = false
                webSocket = nil
                connectionEnded()
                if !intentionalDisconnect {
                    scheduleReconnect()
                }
                return
            }
        }
    }

    func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        // The bullet fields read the message as JSON values (DS-VALIDATE); demo never syncs them (DS-DEMO).
        // A bullet_state is theirs alone, applied through the prompt store (DS-RECEIVE); everything else
        // decodes below.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let object, object["type"] as? String == "bullet_state" {
            if !DemoModeStore.isDemoActive { receiveBulletState(object) }
            return
        }

        struct IncomingMessage: Decodable {
            let type: String
            let userId: String?
            let data: PromptStateData?
            let fields: [String]?
            let keys: [String]?
            let results: [String: AICacheResult]?
            let probeId: String?
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let msg = try decoder.decode(IncomingMessage.self, from: data)

            switch msg.type {
            case "connected":
                BackgroundSyncLogger.logDebug("[DeviceSync] Connected as user \(msg.userId?.prefix(8) ?? "?")")
                DeviceSyncLogger.log("CONNECTED as user \(msg.userId?.prefix(8) ?? "?") via \(baseURL)")
                isConnecting = false
                isConnected = true
                reconnectAttempts = 0
                // The bullet fields always go out on connect, read through the prompt store (DS-SEND),
                // then the prompt_state fields.
                PromptStore.shared.bullets.send = { [weak self] message in self?.sendBulletMessage(message) }
                guard !DemoModeStore.isDemoActive else { break }
                applyReceived("connected") { [weak self] access in
                    try access.sendAll()
                    self?.broadcastAllFields()
                }

            case "request_state":
                // Another client asked for our state — respond with requested fields (or all)
                BackgroundSyncLogger.logDebug("[DeviceSync] Received request_state — responding")
                respondToRequestState(fields: msg.fields)

            case "prompt_state":
                // A released device's state, applied whole through the prompt store (DS-RECEIVE): its bullet
                // texts imported (DS-LEGACY-IN), then its other fields merged; applied again whole while busy.
                if let stateData = msg.data {
                    // DS-DEMO: Device Sync does not run in demo; a message still in flight when demo started
                    // writes nothing (the demo flag is snapshotted here, when the operation starts).
                    guard !DemoModeStore.isDemoActive else {
                        BackgroundSyncLogger.logDebug("[DeviceSync] A prompt_state received in demo mode was dropped")
                        return
                    }
                    let legacy = object
                    applyReceived("prompt_state") { [weak self] access in
                        if let legacy { try access.receive(legacy) }
                        try self?.applyIncomingStateWithMerge(stateData, access: access)
                    }
                }

            case "pong":
                break

            case "ai_cache_probe":
                DeviceSyncLogger.log("PROBE_RECV keys=[\(msg.keys?.joined(separator: ", ") ?? "")] probeId=\(msg.probeId?.prefix(8) ?? "nil")")
                handleAICacheProbe(keys: msg.keys ?? [], probeId: msg.probeId, fields: msg.fields)

            case "ai_cache_response":
                DeviceSyncLogger.log("RESPONSE_RECV hits=\(msg.results?.count ?? 0) keys=[\(msg.results?.keys.joined(separator: ", ") ?? "")] probeId=\(msg.probeId?.prefix(8) ?? "nil")")
                handleAICacheResponse(results: msg.results ?? [:], probeId: msg.probeId)

            default:
                BackgroundSyncLogger.logDebug("[DeviceSync] Unknown message type: \(msg.type)")
            }
        } catch {
            BackgroundSyncLogger.logDebug("[DeviceSync] Failed to decode message: \(error)")
        }
    }

    private func respondToRequestState(fields: [String]?) {
        guard let ws = webSocket else { return }

        if let fields, !fields.isEmpty {
            // Wire field names are the SyncField raw values; unknown names are ignored.
            sendPromptState(promptState(for: fields.compactMap(SyncField.init(rawValue:))), via: ws)
        } else {
            broadcastAllFields()
        }
    }

    // MARK: - Received messages through the prompt store (DS-RECEIVE)

    /// A received `bullet_state` part, merged through the prompt store (DS-MERGE). The engine validates it
    /// (DS-VALIDATE); the parts of a snapshot apply in arrival order, after every message received before
    /// them (DS-CHUNK).
    private func receiveBulletState(_ message: [String: Any]) {
        // DS-VALIDATE: a message with no string sender, field and snapshot id is not one a peer sends, and
        // is rejected before it waits in line, where it would displace valid ones.
        guard let sender = message["sender"] as? String, let field = message["field"] as? String,
              let snap = message["snap"] as? String else {
            BackgroundSyncLogger.logDebug("[DeviceSync] A bullet_state without a string sender, field and snap was dropped")
            return
        }
        applyReceived("bullet_state \(sender) \(field) \(snap) \(message["part"] ?? "")") { [weak self] access in
            try access.receive(message)
            self?.heldParts = PromptStore.shared.bullets.heldParts
        }
    }

    /// Applies a received message through the prompt store after every message received before it, only
    /// while the connection it was received on lasts.
    func applyReceived(_ key: String, _ apply: @escaping @MainActor (PromptAccess) throws -> Void) {
        // Never a queue without limit behind a busy store: past the bound the connection ends, dropping
        // every message waiting on it, and the next connect brings every peer's state again.
        guard waitingReceives + heldParts < BulletSyncConfig.maxWaitingReceives else {
            BackgroundSyncLogger.logDebug("[DeviceSync] \(waitingReceives) received messages wait for the prompt store and \(heldParts) parts of incomplete snapshots are held: the connection is renewed")
            connectionEnded()
            forceReconnect()
            return
        }
        waitingReceives += 1
        let previous = receiveChain
        let connection = connectionID
        // Created outside any hold: a task created inside one would inherit its mark (MIS-IOS-028).
        receiveChain = PromptSemaphore.$holding.withValue(nil) {
            Task { [weak self] in
                await previous?.value
                await self?.applyWhenFree(key, connection: connection, apply)
                if let self, connection == self.connectionID { self.waitingReceives -= 1 }
            }
        }
    }

    /// One received message applied. While the prompt store stays busy through every retry it is applied
    /// again after `BulletSyncConfig.busyReapplySeconds`, holding nothing while it waits, until it applies or
    /// its connection ends (DS-RECEIVE): with both peers connected and nobody editing, nothing waits for the
    /// next connect, and every message received after it waits for it, so they apply in arrival order. Any
    /// other refusal drops it: peers send their state on the next connect.
    private func applyWhenFree(_ key: String, connection: UUID,
                               _ apply: @escaping @MainActor (PromptAccess) throws -> Void) async {
        while connection == connectionID {
            do {
                // Checked inside the hold, where the message is applied: one received before the connection
                // ended is never applied after it.
                try await PromptStore.shared.withPromptStore("sync receive", demo: false) { [weak self] access in
                    guard connection == self?.connectionID else {
                        BackgroundSyncLogger.logDebug("[DeviceSync] A received message (\(key.prefix(48))) was dropped: its connection ended")
                        return
                    }
                    try apply(access)
                }
                return
            } catch let refusal as PromptRefusal {
                // Busy after its wait in line, or the hold ended (its lease) before the message was applied:
                // the message is stale, not unsaved, and is applied again (DS-RECEIVE, DS-LEASE).
                BackgroundSyncLogger.logDebug("[DeviceSync] A received message (\(key.prefix(48))) was refused (\(refusal)): it is applied again shortly")
                try? await Task.sleep(for: .seconds(BulletSyncConfig.busyReapplySeconds))
            } catch {
                BackgroundSyncLogger.logDebug("[DeviceSync] A received message (\(key.prefix(48))) was not applied: \(error)")
                return
            }
        }
        BackgroundSyncLogger.logDebug("[DeviceSync] A received message (\(key.prefix(48))) was dropped: its connection ended")
    }

    /// The connection ended: the engine forgets incomplete snapshots, and a message received on it is never
    /// applied (DS-RECEIVE): peers send their state on the next connect.
    private func connectionEnded() {
        PromptStore.shared.bullets.disconnected()
        connectionID = UUID()
        waitingReceives = 0
        heldParts = 0
    }

    /// Sends one `bullet_state` message while connected.
    private func sendBulletMessage(_ text: String) {
        guard let ws = webSocket, isConnected else { return }
        ws.send(.string(text)) { error in
            if let error { BackgroundSyncLogger.logDebug("[DeviceSync] bullet_state send failed: \(Self.redactedTransportError(error))") }
        }
    }

    /// Per-field merge of the `prompt_state` fields: CRDT per-item merge for collections,
    /// last-write-wins for the action config. Its text fields are imported before this
    /// (`PromptBulletSync.receiveLegacy`), in the same hold of the prompt store (DS-RECEIVE).
    ///
    /// Everything here runs synchronously on the MainActor inside the hold, with no await between a store's
    /// read and its write, and reads the timestamps it compares in the same step it writes (the local
    /// writers of these stores are synchronous MainActor code too, so none can interleave).
    ///
    /// Templates: per-template CRDT merge by id (newer updatedAt wins per template).
    /// DisabledReminders: per-hash CRDT merge (newer ts wins per hash).
    func applyIncomingStateWithMerge(_ incoming: PromptStateData, access: PromptAccess) throws {
        let store = PromptStore.shared

        // Capture pre-merge snapshot for history (before any merges modify state)
        let preMergeTemplates = store.templates

        // --- Templates: per-template CRDT merge — skip if epoch-zero ---
        if let incomingTemplates = incoming.templates {
            let incomingTs = incoming.templatesUpdatedAt ?? incoming.updatedAt ?? Self.epochZero
            if incomingTs == Self.epochZero {
                BackgroundSyncLogger.logDebug("[DeviceSync] Skipping templates merge — epoch-zero timestamp (virgin device)")
            } else {
                let validTemplates = incomingTemplates.filter { !$0.id.isEmpty && !$0.name.isEmpty }
                let skipped = incomingTemplates.count - validTemplates.count
                if skipped > 0 {
                    BackgroundSyncLogger.logDebug("[DeviceSync] Skipped \(skipped) invalid templates (missing id/name)")
                }
                if !validTemplates.isEmpty {
                    store.mergeTemplates(validTemplates)
                    store.gcDeletedTemplates()
                }
            }
        }

        // --- DisabledReminders: per-hash CRDT merge — skip if epoch-zero ---
        if let incomingMap = incoming.disabledReminders {
            let incomingTs = incoming.disabledRemindersUpdatedAt ?? incoming.updatedAt ?? Self.epochZero
            if incomingTs == Self.epochZero {
                BackgroundSyncLogger.logDebug("[DeviceSync] Skipping disabledReminders merge — epoch-zero timestamp (virgin device)")
            } else {
                let beforeHashes = DisabledRemindersStore.getDisabledHashes()
                DisabledRemindersStore.mergeIncoming(incomingMap)
                let afterHashes = DisabledRemindersStore.getDisabledHashes()
                if beforeHashes != afterHashes {
                    NotificationCenter.default.post(name: .remindersDidChange, object: nil)
                }
            }
        }

        // --- ActionConfig: last-write-wins. Not prompt history material — applied
        // outside the history snapshot below.
        if let incomingConfig = incoming.actionConfig {
            let incomingTs = incoming.actionConfigUpdatedAt ?? Self.epochZero
            let localTs = readTimestamp(for: .actionConfig)
            if let accepted = Self.acceptedActionConfig(incomingConfig, incomingTs: incomingTs, localTs: localTs) {
                UserDefaults.standard.set(accepted.rules, forKey: PromptStore.actionCompactThresholdKey)
                UserDefaults.standard.set(accepted.chars, forKey: PromptStore.actionCompactThresholdCharsKey)
                writeTimestamp(incomingTs, for: .actionConfig)
                BackgroundSyncLogger.logDebug("[DeviceSync] actionConfig: LWW accept compact_threshold=\(accepted.rules) compact_threshold_chars=\(accepted.chars)")
            } else {
                BackgroundSyncLogger.logDebug("[DeviceSync] Skipping actionConfig — not newer or invalid (incoming \(incomingTs), local \(localTs))")
            }
        }

        // Only record history if the templates actually changed (the bullet fields record their own).
        guard store.templates != preMergeTemplates else {
            BackgroundSyncLogger.logDebug("[DeviceSync] No template changes after merge — skipping history")
            return
        }

        // Record the pre-merge templates so the diff view can show before→after
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let templatesStr = (try? encoder.encode(preMergeTemplates)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let entry = PromptHistoryEntry(
            id: UUID().uuidString,
            timestamp: Date().ISO8601Format(),
            source: "sync_receive",
            fields: ["templates"],
            composition: store.rawComposition,
            action: store.rawAction,
            kb: store.rawKB,
            templatesJSON: templatesStr
        )
        var history = try access.loadHistory()
        history.append(entry)
        if history.count > 100 {
            history = Array(history.suffix(100))
        }
        try access.saveHistory(history)

        BackgroundSyncLogger.logDebug("[DeviceSync] Applied sync: templates")
    }

    /// The thresholds to adopt from a peer, or nil to keep local. Last-write-wins by
    /// ISO timestamp, matching TB `deviceSync.js`; an epoch-zero (never edited)
    /// incoming timestamp is never newer than local, so defaults never overwrite.
    nonisolated static func acceptedActionConfig(
        _ incoming: ActionCompactConfig,
        incomingTs: String,
        localTs: String
    ) -> (rules: Int, chars: Int)? {
        guard incomingTs > localTs,
              let rules = incoming.compactThreshold, rules > 0,
              let chars = incoming.compactThresholdChars, chars > 0 else { return nil }
        return (rules, chars)
    }

    // MARK: - AI Cache Probe (Phase 5 — placeholder handlers)

    /// Pending AI cache probe continuations keyed by probeId.
    private var pendingProbes: [String: CheckedContinuation<[String: AICacheResult]?, Never>] = [:]

    /// Probe connected peers for cached AI results. Returns nil on timeout or if no peers available.
    func probeAICache(keys: [String], timeoutMs: UInt64 = 2000) async -> [String: AICacheResult]? {
        guard !keys.isEmpty else { return nil }

        // If WSS is not connected, skip probe entirely. No HTTPS fallback — if WSS
        // is down, the relay endpoint is likely unreachable too. The AI queue will
        // just run the LLM call instead of using peer data.
        guard let ws = webSocket, isConnected else {
            return nil
        }

        let probeId = UUID().uuidString

        // Send probe
        let probe: [String: Any] = ["type": "ai_cache_probe", "keys": keys, "probeId": probeId]
        if let data = try? JSONSerialization.data(withJSONObject: probe),
           let text = String(data: data, encoding: .utf8) {
            ws.send(.string(text)) { error in
                if let error { BackgroundSyncLogger.logDebug("[DeviceSync] AI cache probe send failed: \(Self.redactedTransportError(error))") }
            }
        }
        DeviceSyncLogger.log("PROBE_SEND WSS keys=[\(keys.joined(separator: ", "))] probeId=\(probeId.prefix(8)) timeout=\(timeoutMs)ms")
        BackgroundSyncLogger.logDebug("[DeviceSync] Sent ai_cache_probe for [\(keys.joined(separator: ", "))] (probeId=\(probeId.prefix(8)))")

        // Wait for response with timeout
        return await withCheckedContinuation { continuation in
            pendingProbes[probeId] = continuation

            Task {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                if let cont = pendingProbes.removeValue(forKey: probeId) {
                    DeviceSyncLogger.log("PROBE_TIMEOUT probeId=\(probeId.prefix(8)) after \(timeoutMs)ms")
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func handleAICacheProbe(keys: [String], probeId: String?, fields: [String]? = nil) {
        guard let ws = webSocket, !keys.isEmpty else { return }
        BackgroundSyncLogger.logDebug("[DeviceSync] Received ai_cache_probe for [\(keys.joined(separator: ", "))] fields=\(fields ?? ["all"]) (probeId=\(probeId?.prefix(8) ?? "nil"))")

        Task { @MainActor in
            var results = [String: AICacheResult]()
            if let handler = aiCacheProbeHandler {
                results = await handler(keys, fields)
            }

            // Encode response — use JSONSerialization for the outer envelope
            // since AICacheResult is Codable, encode inner results first
            let encoder = JSONEncoder()
            var encodedResults = [String: Any]()
            for (key, value) in results {
                if let data = try? encoder.encode(value),
                   let obj = try? JSONSerialization.jsonObject(with: data) {
                    encodedResults[key] = obj
                }
            }

            let response: [String: Any] = [
                "type": "ai_cache_response",
                "results": encodedResults,
                "probeId": probeId ?? "",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: response),
               let text = String(data: data, encoding: .utf8) {
                ws.send(.string(text)) { error in
                    if let error { BackgroundSyncLogger.logDebug("[DeviceSync] AI cache response send failed: \(Self.redactedTransportError(error))") }
                }
            }
            let hitKeys = Array(results.keys)
            DeviceSyncLogger.log("PROBE_RESPOND \(hitKeys.count) hit(s) for keys=[\(keys.joined(separator: ", "))] probeId=\(probeId?.prefix(8) ?? "nil")")
            BackgroundSyncLogger.logDebug("[DeviceSync] Responded to ai_cache_probe for [\(keys.joined(separator: ", "))]: \(hitKeys.count) hit(s)\(hitKeys.isEmpty ? "" : " [\(hitKeys.joined(separator: ", "))]") (probeId=\(probeId?.prefix(8) ?? "nil"))")
        }
    }

    private func handleAICacheResponse(results: [String: AICacheResult], probeId: String?) {
        guard let probeId, let continuation = pendingProbes.removeValue(forKey: probeId) else {
            // Expected: late responses after timeout, or relay echoes from other clients
            DeviceSyncLogger.log("RESPONSE_LATE probeId=\(probeId?.prefix(8) ?? "nil") (already timed out or unknown)")
            return
        }
        let hitKeys = Array(results.keys)
        DeviceSyncLogger.log("PROBE_HIT \(hitKeys.count) hit(s) keys=[\(hitKeys.joined(separator: ", "))] probeId=\(probeId.prefix(8))")
        BackgroundSyncLogger.logDebug("[DeviceSync] Resolved ai_cache_probe: \(hitKeys.count) hit(s)\(hitKeys.isEmpty ? "" : " [\(hitKeys.joined(separator: ", "))]") (probeId=\(probeId.prefix(8)))")
        continuation.resume(returning: results.isEmpty ? nil : results)
    }

    // MARK: - Private Helpers

    private func sendPing() {
        guard let ws = webSocket else { return }
        let msg = #"{"type":"ping"}"#
        ws.send(.string(msg)) { error in
            if let error { BackgroundSyncLogger.logDebug("[DeviceSync] Ping failed: \(Self.redactedTransportError(error))") }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        // Don't reconnect in background — iOS gives no execution time for WebSocket + token fetch.
        // Foreground return (RootView scenePhase .active) calls reconnectIfNeeded().
        guard UIApplication.shared.applicationState == .active else {
            BackgroundSyncLogger.logDebug("[DeviceSync] Skipping reconnect — app not in foreground")
            return
        }
        if reconnectAttempts >= maxReconnectAttempts {
            BackgroundSyncLogger.logDebug("[DeviceSync] Max reconnect attempts (\(maxReconnectAttempts)) reached — giving up")
            return
        }
        let delay = min(reconnectBaseDelay * pow(2.0, Double(reconnectAttempts)), reconnectMaxDelay)
        reconnectAttempts += 1
        BackgroundSyncLogger.logDebug("[DeviceSync] Reconnecting in \(Int(delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // Re-check foreground after delay — app may have backgrounded during sleep
            guard UIApplication.shared.applicationState == .active else {
                BackgroundSyncLogger.logDebug("[DeviceSync] Skipping reconnect — app backgrounded during delay")
                reconnectTask = nil
                return
            }
            reconnectTask = nil
            connect()
        }
    }

}

// MARK: - Sync Data Types

enum SyncField: String, CaseIterable {
    case composition, action, kb, templates, disabledReminders, actionConfig

    /// The fields `prompt_state` still syncs: the bullet fields go in `bullet_state`.
    static let legacyFields: [SyncField] = [.templates, .disabledReminders, .actionConfig]

    var displayName: String {
        switch self {
        case .composition: return "Composition"
        case .action: return "Action Rules"
        case .kb: return "Knowledge Base"
        case .templates: return "Templates"
        case .disabledReminders: return "Disabled Reminders"
        case .actionConfig: return "Action Compaction Settings"
        }
    }

    var icon: String {
        switch self {
        case .composition: return "pencil.line"
        case .action: return "tag"
        case .kb: return "book"
        case .templates: return "doc.on.doc"
        case .disabledReminders: return "bell.slash"
        case .actionConfig: return "slider.horizontal.3"
        }
    }
}

struct PromptStateData: Codable {
    var composition: String?
    var action: String?
    var kb: String?
    var templates: [ReplyTemplate]?
    /// CRDT map: `{hash: {enabled: Bool, ts: ISO8601}}`. Decoded from either v2 map or legacy `[String]` array.
    var disabledReminders: [String: DisabledRemindersStore.DisabledEntry]?
    var actionConfig: ActionCompactConfig?
    var updatedAt: String? // DEPRECATED — use per-field timestamps below
    var compositionUpdatedAt: String?
    var actionUpdatedAt: String?
    var kbUpdatedAt: String?
    var templatesUpdatedAt: String?
    var disabledRemindersUpdatedAt: String?
    var actionConfigUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case composition, action, kb, templates, disabledReminders, actionConfig
        case updatedAt = "updatedAt"
        case compositionUpdatedAt = "composition_updated_at"
        case actionUpdatedAt = "action_updated_at"
        case kbUpdatedAt = "kb_updated_at"
        case templatesUpdatedAt = "templates_updated_at"
        case disabledRemindersUpdatedAt = "disabledReminders_updated_at"
        case actionConfigUpdatedAt = "actionConfig_updated_at"
    }

    init(
        composition: String? = nil,
        action: String? = nil,
        kb: String? = nil,
        templates: [ReplyTemplate]? = nil,
        disabledReminders: [String: DisabledRemindersStore.DisabledEntry]? = nil,
        actionConfig: ActionCompactConfig? = nil,
        updatedAt: String? = nil,
        compositionUpdatedAt: String? = nil,
        actionUpdatedAt: String? = nil,
        kbUpdatedAt: String? = nil,
        templatesUpdatedAt: String? = nil,
        disabledRemindersUpdatedAt: String? = nil,
        actionConfigUpdatedAt: String? = nil
    ) {
        self.composition = composition
        self.action = action
        self.kb = kb
        self.templates = templates
        self.disabledReminders = disabledReminders
        self.actionConfig = actionConfig
        self.updatedAt = updatedAt
        self.compositionUpdatedAt = compositionUpdatedAt
        self.actionUpdatedAt = actionUpdatedAt
        self.kbUpdatedAt = kbUpdatedAt
        self.templatesUpdatedAt = templatesUpdatedAt
        self.disabledRemindersUpdatedAt = disabledRemindersUpdatedAt
        self.actionConfigUpdatedAt = actionConfigUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        composition = try container.decodeIfPresent(String.self, forKey: .composition)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        kb = try container.decodeIfPresent(String.self, forKey: .kb)
        templates = try container.decodeIfPresent([ReplyTemplate].self, forKey: .templates)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        compositionUpdatedAt = try container.decodeIfPresent(String.self, forKey: .compositionUpdatedAt)
        actionUpdatedAt = try container.decodeIfPresent(String.self, forKey: .actionUpdatedAt)
        kbUpdatedAt = try container.decodeIfPresent(String.self, forKey: .kbUpdatedAt)
        templatesUpdatedAt = try container.decodeIfPresent(String.self, forKey: .templatesUpdatedAt)
        disabledRemindersUpdatedAt = try container.decodeIfPresent(String.self, forKey: .disabledRemindersUpdatedAt)
        actionConfigUpdatedAt = try container.decodeIfPresent(String.self, forKey: .actionConfigUpdatedAt)
        // A malformed config from a peer must not drop the rest of the message.
        actionConfig = try? container.decodeIfPresent(ActionCompactConfig.self, forKey: .actionConfig)

        // Decode disabledReminders: try v2 map first, fall back to legacy [String] array
        if let mapValue = try? container.decodeIfPresent([String: DisabledRemindersStore.DisabledEntry].self, forKey: .disabledReminders) {
            disabledReminders = mapValue
        } else if let arrayValue = try? container.decodeIfPresent([String].self, forKey: .disabledReminders) {
            // Convert legacy array to CRDT map — all entries are disabled, use field-level timestamp
            let ts = disabledRemindersUpdatedAt ?? updatedAt ?? "1970-01-01T00:00:00.000Z"
            var map: [String: DisabledRemindersStore.DisabledEntry] = [:]
            for hash in arrayValue {
                map[hash] = DisabledRemindersStore.DisabledEntry(enabled: false, ts: ts)
            }
            disabledReminders = map
        } else {
            disabledReminders = nil
        }
    }
}

/// Action-rule compaction thresholds — TB `user_prompts:action_config`, sent to the
/// backend as `action_compact_threshold` / `action_compact_threshold_chars`.
struct ActionCompactConfig: Codable, Equatable {
    var compactThreshold: Int?
    var compactThresholdChars: Int?

    enum CodingKeys: String, CodingKey {
        case compactThreshold = "compact_threshold"
        case compactThresholdChars = "compact_threshold_chars"
    }

    /// Device Sync's per-field timestamp for these thresholds.
    nonisolated static let updatedAtKey = "device_sync_ts:actionConfig"
    /// Device Sync's "never edited" timestamp (`DeviceSyncService.epochZero`). Every slider
    /// edit and every accepted sync write stamps a real timestamp.
    private nonisolated static let neverEditedTimestamp = "1970-01-01T00:00:00.000Z"

    /// This device's effective thresholds — what `AIService` sends to the backend.
    nonisolated static func local() -> ActionCompactConfig {
        let defaults = UserDefaults.standard
        let resolved = resolve(
            rules: defaults.object(forKey: PromptStore.actionCompactThresholdKey) as? Int,
            chars: defaults.object(forKey: PromptStore.actionCompactThresholdCharsKey) as? Int,
            updatedAt: defaults.string(forKey: updatedAtKey)
        )
        return ActionCompactConfig(compactThreshold: resolved.rules, compactThresholdChars: resolved.chars)
    }

    /// Effective thresholds for stored values: a value still at the legacy default that was
    /// never edited moves to the current default; every value is clamped to the slider range.
    nonisolated static func resolve(rules: Int?, chars: Int?, updatedAt: String?) -> (rules: Int, chars: Int) {
        let neverEdited = updatedAt == nil || updatedAt == "" || updatedAt == neverEditedTimestamp
        return (
            resolveThreshold(rules, fallback: PromptStore.defaultActionCompactThreshold,
                             legacyDefault: PromptStore.legacyDefaultActionCompactThreshold,
                             range: PromptStore.actionCompactThresholdRange, neverEdited: neverEdited),
            resolveThreshold(chars, fallback: PromptStore.defaultActionCompactThresholdChars,
                             legacyDefault: PromptStore.legacyDefaultActionCompactThresholdChars,
                             range: PromptStore.actionCompactThresholdCharsRange, neverEdited: neverEdited)
        )
    }

    private nonisolated static func resolveThreshold(
        _ value: Int?, fallback: Int, legacyDefault: Int, range: ClosedRange<Int>, neverEdited: Bool
    ) -> Int {
        guard let value, value > 0 else { return fallback }
        if neverEdited && value == legacyDefault { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

struct AICacheSummary: Codable {
    var blurb: String
    var todos: String?
    var detailed: String?
    var reminderDate: String?
    var reminderTime: String?
    var reminderContent: String?
}

struct AICacheResult: Codable {
    var summary: AICacheSummary?
    var action: String?
    var reply: String?
}

private struct SyncMessage: Encodable {
    let type: String
    let data: PromptStateData?

    enum CodingKeys: String, CodingKey {
        case type, data
    }
}
