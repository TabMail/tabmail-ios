/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import UIKit

/// Device Sync always-on sync service using WebSocket relay.
/// Syncs prompt settings between TabMail instances (iOS ↔ TB) automatically.
/// Uses per-field timestamps for git-like merge (newer wins per field).
///
/// Protocol:
/// 1. Connect to Device Sync worker via WebSocket (wss://sync.tabmail.ai/ws)
/// 2. Authenticate with TabMail session JWT token
/// 3. On connect: broadcast all fields with per-field timestamps
/// 4. On local edit: debounced broadcast of changed fields
/// 5. On receive prompt_state: per-field timestamp merge (newer wins)
/// 6. On receive request_state: respond with requested fields
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

    private var webSocket: URLSessionWebSocketTask?
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

    /// Debounce task for auto-broadcast on local edits (500ms).
    private var broadcastDebounceTask: Task<Void, Never>?
    /// Fields accumulated during debounce window.
    private var pendingBroadcastFields: Set<SyncField> = []

    /// External handler for AI cache probes — set by the app layer which has access to the database.
    /// Called with probe keys and optional fields filter, returns results keyed by probe key.
    var aiCacheProbeHandler: (([String], [String]?) async -> [String: AICacheResult])?

    private let broadcastDebounceMs: UInt64 = 500

    /// Maximum backup snapshots to keep in ring buffer.
    private let maxBackups = 10

    private var baseURL: String { BackendConfig.syncWebSocketURL }

    /// Epoch zero — used for new devices that have no per-field timestamps yet.
    private static let epochZero = "1970-01-01T00:00:00.000Z"

    private override init() {
        super.init()
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        print("[DeviceSync] WebSocket didOpen, protocol: \(`protocol` ?? "none")")
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
            print("[DeviceSync] WebSocket didClose, code: \(closeCode.rawValue), reason: \(reasonStr)")
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            DeviceSyncLogger.log("WS_ERROR \(error.localizedDescription)")
            print("[DeviceSync] Task completed with error: \(error)")
            if let httpResponse = task.response as? HTTPURLResponse {
                print("[DeviceSync] HTTP status: \(httpResponse.statusCode)")
                print("[DeviceSync] HTTP headers: \(httpResponse.allHeaderFields)")
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        for tm in metrics.transactionMetrics {
            let proto = tm.networkProtocolName ?? "unknown"
            print("[DeviceSync] Protocol negotiated: \(proto)")
            if let resp = tm.response as? HTTPURLResponse {
                print("[DeviceSync] Response status: \(resp.statusCode), headers: \(resp.allHeaderFields)")
            }
        }
    }

    // MARK: - Connect / Disconnect

    func connect() {
        // Device Sync is fully disabled in demo.
        // The anonymous demo session has no peer-pairing context, and
        // probing peers from a demo install would leak demo state.
        if DemoModeStore.shared.isActive {
            print("[DeviceSync] Demo mode active — skipping connect")
            return
        }
        guard isAutoEnabled else {
            print("[DeviceSync] Auto-sync disabled, skipping connect")
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
        reconnectAttempts = 0 // fresh network, reset backoff
        print("[DeviceSync] Force reconnect — network interface changed")
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
            print("[DeviceSync] No session found, cannot connect")
            DeviceSyncLogger.log("CONNECT_FAIL no session")
            isConnecting = false
            return
        case .permanentFailure:
            print("[DeviceSync] Token refresh permanently failed — will retry later")
            DeviceSyncLogger.log("CONNECT_FAIL token refresh permanent failure")
            isConnecting = false
            scheduleReconnect()
            return
        case .transientFailure:
            print("[DeviceSync] Token refresh failed (transient), scheduling reconnect")
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

        print("[DeviceSync] Connecting to \(baseURL)...")
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
        reconnectAttempts = 0
        print("[DeviceSync] Disconnected")
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
        broadcastAllFields()
        probeAllFields()
    }

    /// Request all prompt fields from peers (routine probe).
    private func probeAllFields() {
        let allFields = SyncField.allCases.map(\.rawValue)
        requestStateFromPeers(fields: allFields)
        print("[DeviceSync] Probe: requested all fields from peers")
    }

    // MARK: - Per-Field Timestamps

    private enum TimestampKey {
        static let composition = "device_sync_ts:composition"
        static let action = "device_sync_ts:action"
        static let kb = "device_sync_ts:kb"
        static let templates = "device_sync_ts:templates"
        static let disabledReminders = "device_sync_ts:disabledReminders"
        static let taskCache = "device_sync_ts:taskCache"

        static func key(for field: SyncField) -> String {
            switch field {
            case .composition: return composition
            case .action: return action
            case .kb: return kb
            case .templates: return templates
            case .disabledReminders: return disabledReminders
            case .taskCache: return taskCache
            }
        }
    }

    private func readTimestamp(for field: SyncField) -> String {
        UserDefaults.standard.string(forKey: TimestampKey.key(for: field)) ?? Self.epochZero
    }

    private func writeTimestamp(_ ts: String, for field: SyncField) {
        UserDefaults.standard.set(ts, forKey: TimestampKey.key(for: field))
    }

    /// Public timestamp write — used by PromptStore.restoreFromHistory to set fresh timestamps.
    func writeTimestampPublic(_ ts: String, for field: SyncField) {
        writeTimestamp(ts, for: field)
    }

    /// If no per-field timestamps exist, initialize all to epoch 0 (new device).
    private func initTimestampsIfNeeded() {
        let defaults = UserDefaults.standard
        let anyExists = SyncField.allCases.contains { defaults.string(forKey: TimestampKey.key(for: $0)) != nil }
        if !anyExists {
            print("[DeviceSync] New device — initializing per-field timestamps to epoch 0")
            for field in SyncField.allCases {
                writeTimestamp(Self.epochZero, for: field)
            }
        }
    }

    // MARK: - Auto-Backup

    private let backupKey = "device_sync_backups"

    private func backupCurrentState() {
        let store = PromptStore.shared
        let snapshot: [String: Any] = [
            "composition": store.rawComposition,
            "action": store.rawAction,
            "kb": store.rawKB,
            "templates": (try? { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }().encode(store.templates)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
            "timestamp": Date().ISO8601Format()
        ]

        let defaults = UserDefaults.standard
        var backups = defaults.array(forKey: backupKey) as? [[String: Any]] ?? []
        backups.append(snapshot)
        if backups.count > maxBackups {
            backups = Array(backups.suffix(maxBackups))
        }
        defaults.set(backups, forKey: backupKey)
        print("[DeviceSync] Backed up current state (\(backups.count) snapshots)")
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

    /// Mark a field as "reset to defaults" — sets epoch-zero timestamp so the default
    /// content never overwrites customized rules on other devices, then requests the
    /// field from peers so they send back their (presumably newer) data.
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
                if let error { print("[DeviceSync] request_state send failed: \(error)") }
            }
        }
        print("[DeviceSync] Requested state from peers for fields: \(fields)")
    }

    private func flushBroadcast() {
        guard let ws = webSocket, !pendingBroadcastFields.isEmpty else { return }
        let fields = pendingBroadcastFields
        pendingBroadcastFields = []

        let store = PromptStore.shared
        var state = PromptStateData()

        for field in fields {
            switch field {
            case .composition:
                state.composition = store.rawComposition
                state.compositionUpdatedAt = readTimestamp(for: .composition)
            case .action:
                state.action = store.rawAction
                state.actionUpdatedAt = readTimestamp(for: .action)
            case .kb:
                state.kb = store.rawKB
                state.kbUpdatedAt = readTimestamp(for: .kb)
            case .templates:
                state.templates = store.templates
                state.templatesUpdatedAt = readTimestamp(for: .templates)
            case .disabledReminders:
                state.disabledReminders = DisabledRemindersStore.getDisabledMap()
                state.disabledRemindersUpdatedAt = readTimestamp(for: .disabledReminders)
            case .taskCache:
                state.taskCache = Self.readTaskCacheFromDefaults()
                state.taskCacheUpdatedAt = readTimestamp(for: .taskCache)
            }
        }

        sendPromptState(state, via: ws)
        print("[DeviceSync] Auto-broadcast \(fields.map(\.rawValue)) to peers")
    }

    /// Broadcast all fields with per-field timestamps (used on connect).
    /// Virgin devices (all timestamps epoch-zero) skip broadcasting defaults
    /// and probe peers instead — prevents default content from clobbering
    /// customized prompts on established devices via LWW.
    private func broadcastAllFields() {
        guard let ws = webSocket else { return }

        let allEpochZero = SyncField.allCases.allSatisfy { readTimestamp(for: $0) == Self.epochZero }
        if allEpochZero {
            print("[DeviceSync] Virgin device — skipping broadcast, probing peers instead")
            probeAllFields()
            return
        }

        let store = PromptStore.shared
        let state = PromptStateData(
            composition: store.rawComposition,
            action: store.rawAction,
            kb: store.rawKB,
            templates: store.templates,
            disabledReminders: DisabledRemindersStore.getDisabledMap(),
            taskCache: Self.readTaskCacheFromDefaults(),
            compositionUpdatedAt: readTimestamp(for: .composition),
            actionUpdatedAt: readTimestamp(for: .action),
            kbUpdatedAt: readTimestamp(for: .kb),
            templatesUpdatedAt: readTimestamp(for: .templates),
            disabledRemindersUpdatedAt: readTimestamp(for: .disabledReminders),
            taskCacheUpdatedAt: readTimestamp(for: .taskCache)
        )
        sendPromptState(state, via: ws)
        print("[DeviceSync] Broadcast all fields on connect")
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
                if let error { print("[DeviceSync] Failed to send: \(error)") }
            }
        } catch {
            print("[DeviceSync] Failed to encode state: \(error)")
        }
    }

    private func receiveLoop() async {
        guard let ws = webSocket else { return }

        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
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
                    print("[DeviceSync] WebSocket receive error: \(error)")
                }
                isConnecting = false
                isConnected = false
                webSocket = nil
                if !intentionalDisconnect {
                    scheduleReconnect()
                }
                return
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

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
                print("[DeviceSync] Connected as user \(msg.userId?.prefix(8) ?? "?")")
                DeviceSyncLogger.log("CONNECTED as user \(msg.userId?.prefix(8) ?? "?") via \(baseURL)")
                isConnecting = false
                isConnected = true
                reconnectAttempts = 0
                // Auto-broadcast all fields on connect
                broadcastAllFields()

            case "request_state":
                // Another client asked for our state — respond with requested fields (or all)
                print("[DeviceSync] Received request_state — responding")
                respondToRequestState(fields: msg.fields)

            case "prompt_state":
                if let stateData = msg.data {
                    applyIncomingStateWithMerge(stateData)
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
                print("[DeviceSync] Unknown message type: \(msg.type)")
            }
        } catch {
            print("[DeviceSync] Failed to decode message: \(error)")
        }
    }

    private func respondToRequestState(fields: [String]?) {
        guard let ws = webSocket else { return }
        let store = PromptStore.shared

        if let fields, !fields.isEmpty {
            var state = PromptStateData()
            for field in fields {
                switch field {
                case "composition":
                    state.composition = store.rawComposition
                    state.compositionUpdatedAt = readTimestamp(for: .composition)
                case "action":
                    state.action = store.rawAction
                    state.actionUpdatedAt = readTimestamp(for: .action)
                case "kb":
                    state.kb = store.rawKB
                    state.kbUpdatedAt = readTimestamp(for: .kb)
                case "templates":
                    state.templates = store.templates
                    state.templatesUpdatedAt = readTimestamp(for: .templates)
                case "disabledReminders":
                    state.disabledReminders = DisabledRemindersStore.getDisabledMap()
                    state.disabledRemindersUpdatedAt = readTimestamp(for: .disabledReminders)
                case "taskCache":
                    state.taskCache = Self.readTaskCacheFromDefaults()
                    state.taskCacheUpdatedAt = readTimestamp(for: .taskCache)
                default: break
                }
            }
            sendPromptState(state, via: ws)
        } else {
            broadcastAllFields()
        }
    }

    /// Per-field merge using state-based delta merge (git-style) for text fields,
    /// CRDT per-item merge for collections.
    ///
    /// Text fields (composition, action, kb) — 3-way merge with peer-received base:
    ///   1. Epoch-zero → skip (virgin/reset device)
    ///   2. Stale (incoming_ts <= peer_base_ts) → skip
    ///   3. No peer_base yet (first sync) → LWW (newer timestamp wins)
    ///   4. No local changes since last sync (local == peer_base) → fast-forward
    ///   5. Both sides changed → 3-way merge using peer_base as common ancestor
    ///   6. CRITICAL: always save peer_base = incoming (NOT merged result)
    ///
    /// Templates: per-template CRDT merge by id (newer updatedAt wins per template).
    /// DisabledReminders: per-hash CRDT merge (newer ts wins per hash).
    private func applyIncomingStateWithMerge(_ incoming: PromptStateData) {
        let store = PromptStore.shared

        // Capture pre-merge snapshot for history (before any merges modify state)
        let preMergeComposition = store.rawComposition
        let preMergeAction = store.rawAction
        let preMergeKB = store.rawKB
        let preMergeTemplates = store.templates

        var appliedFields: [SyncField] = []

        // --- Text fields: state-based delta merge ---
        var mergedComposition: String?
        var mergedAction: String?
        var mergedKB: String?

        // Helper: resolve incoming timestamp for a text field
        func incomingTimestamp(for field: SyncField) -> String {
            switch field {
            case .composition: return incoming.compositionUpdatedAt ?? incoming.updatedAt ?? Self.epochZero
            case .action: return incoming.actionUpdatedAt ?? incoming.updatedAt ?? Self.epochZero
            case .kb: return incoming.kbUpdatedAt ?? incoming.updatedAt ?? Self.epochZero
            default: return Self.epochZero
            }
        }

        // Helper: get the incoming content for a text field
        func incomingContent(for field: SyncField) -> String? {
            switch field {
            case .composition: return incoming.composition
            case .action: return incoming.action
            case .kb: return incoming.kb
            default: return nil
            }
        }

        // Helper: get the local content for a text field
        func localContent(for field: SyncField) -> String {
            switch field {
            case .composition: return store.rawComposition
            case .action: return store.rawAction
            case .kb: return store.rawKB
            default: return ""
            }
        }

        // Helper: log git-style unified diff between old and new content
        func logDiff(field: SyncField, old: String, new: String, mergeType: String) {
            let oldLines = old.components(separatedBy: "\n")
            let newLines = new.components(separatedBy: "\n")
            let oldSet = Set(oldLines)
            let newSet = Set(newLines)
            let removed = oldLines.filter { !newSet.contains($0) }
            let added = newLines.filter { !oldSet.contains($0) }
            if removed.isEmpty && added.isEmpty {
                print("[DeviceSync] \(field.rawValue) (\(mergeType)): no visible diff (reordering only)")
                return
            }
            var lines = ["[DeviceSync] \(field.rawValue) (\(mergeType)) diff:"]
            for r in removed { lines.append("  - \(r)") }
            for a in added { lines.append("  + \(a)") }
            print(lines.joined(separator: "\n"))
        }

        // Helper: 3-way merge dispatcher per field type
        func merge3way(base: String, local: String, remote: String, field: SyncField) -> String {
            switch field {
            case .composition:
                return PromptParser.mergeSectionedField(
                    base: base, local: local, remote: remote,
                    sectionHeaders: PromptParser.compositionSectionHeaders
                )
            case .action:
                return PromptParser.mergeSectionedField(
                    base: base, local: local, remote: remote,
                    sectionHeaders: PromptParser.actionSectionHeaders
                )
            case .kb:
                return PromptParser.mergeFlatField(base: base, local: local, remote: remote)
            default:
                return local
            }
        }

        for field in [SyncField.composition, .action, .kb] {
            guard let remote = incomingContent(for: field) else { continue }
            let incomingTs = incomingTimestamp(for: field)

            // 1. Epoch-zero → skip (virgin/reset device)
            if incomingTs == Self.epochZero {
                print("[DeviceSync] Skipping \(field.rawValue) — epoch-zero timestamp (virgin/reset)")
                continue
            }

            let (peerBase, peerBaseTs) = store.readPeerBase(for: field)
            let local = localContent(for: field)
            let localTs = readTimestamp(for: field)

            // 2. Stale — already processed this or newer from the peer
            if incomingTs <= peerBaseTs {
                print("[DeviceSync] Skipping \(field.rawValue) — stale (incoming \(incomingTs) <= peer_base \(peerBaseTs))")
                continue
            }

            var result: String?

            if peerBase == nil {
                // 3. First sync — no common ancestor, use LWW
                if incomingTs > localTs {
                    result = remote
                    print("[DeviceSync] \(field.rawValue): first sync, LWW accept (incoming \(incomingTs) > local \(localTs))")
                } else {
                    print("[DeviceSync] \(field.rawValue): first sync, LWW keep local (local \(localTs) >= incoming \(incomingTs))")
                }
            } else if local == peerBase {
                // 4. Fast-forward — no local changes since last sync
                result = remote
                print("[DeviceSync] \(field.rawValue): fast-forward (no local changes since last sync)")
            } else {
                // 5. Both sides changed — 3-way merge using peer_base as common ancestor
                let merged = merge3way(base: peerBase!, local: local, remote: remote, field: field)
                if merged != local {
                    result = merged
                    print("[DeviceSync] \(field.rawValue): 3-way merge (both sides changed)")
                } else {
                    print("[DeviceSync] \(field.rawValue): 3-way merge produced no change")
                }
            }

            // 6. ALWAYS save peer_base = incoming (NOT merged result)
            store.savePeerBase(remote, ts: incomingTs, for: field)

            if let result, result != local {
                let mergeType: String
                if peerBase == nil { mergeType = "LWW" }
                else if local == peerBase { mergeType = "fast-forward" }
                else { mergeType = "3-way merge" }
                logDiff(field: field, old: local, new: result, mergeType: mergeType)

                switch field {
                case .composition: mergedComposition = result
                case .action: mergedAction = result
                case .kb: mergedKB = result
                default: break
                }
                appliedFields.append(field)
                // Update field timestamp to max of local and incoming
                if incomingTs > localTs {
                    writeTimestamp(incomingTs, for: field)
                }
            }
        }

        // --- Templates: per-template CRDT merge — skip if epoch-zero ---
        if let incomingTemplates = incoming.templates {
            let incomingTs = incoming.templatesUpdatedAt ?? incoming.updatedAt ?? Self.epochZero
            if incomingTs == Self.epochZero {
                print("[DeviceSync] Skipping templates merge — epoch-zero timestamp (virgin device)")
            } else {
                let validTemplates = incomingTemplates.filter { !$0.id.isEmpty && !$0.name.isEmpty }
                let skipped = incomingTemplates.count - validTemplates.count
                if skipped > 0 {
                    print("[DeviceSync] Skipped \(skipped) invalid templates (missing id/name)")
                }
                if !validTemplates.isEmpty {
                    let before = store.templates
                    store.mergeTemplates(validTemplates)
                    store.gcDeletedTemplates()
                    if store.templates != before {
                        appliedFields.append(.templates)
                    }
                }
            }
        }

        // --- DisabledReminders: per-hash CRDT merge — skip if epoch-zero ---
        if let incomingMap = incoming.disabledReminders {
            let incomingTs = incoming.disabledRemindersUpdatedAt ?? incoming.updatedAt ?? Self.epochZero
            if incomingTs == Self.epochZero {
                print("[DeviceSync] Skipping disabledReminders merge — epoch-zero timestamp (virgin device)")
            } else {
                let beforeHashes = DisabledRemindersStore.getDisabledHashes()
                DisabledRemindersStore.mergeIncoming(incomingMap)
                let afterHashes = DisabledRemindersStore.getDisabledHashes()
                if beforeHashes != afterHashes {
                    appliedFields.append(.disabledReminders)
                    NotificationCenter.default.post(name: .remindersDidChange, object: nil)
                }
            }
        }

        // --- TaskCache: per-key CRDT merge — skip if epoch-zero ---
        if let incomingTaskCache = incoming.taskCache, !incomingTaskCache.isEmpty {
            let incomingTs = incoming.taskCacheUpdatedAt ?? incoming.updatedAt ?? Self.epochZero
            if incomingTs == Self.epochZero {
                print("[DeviceSync] Skipping taskCache merge — epoch-zero timestamp (virgin device)")
            } else {
                Task {
                    await TaskExecutionCache.shared.mergeIncoming(incomingTaskCache)
                    // Note: mergeIncoming does NOT broadcast (prevents echo)
                }
            }
        }

        // Apply text field results (skip internal history — we record below)
        if mergedComposition != nil || mergedAction != nil || mergedKB != nil {
            store.applySync(
                composition: mergedComposition,
                action: mergedAction,
                kb: mergedKB,
                skipHistory: true
            )
        }

        // Compare pre-merge vs post-merge — only record history if something actually changed
        var changedFieldNames: [String] = []
        if store.rawComposition != preMergeComposition { changedFieldNames.append("composition") }
        if store.rawAction != preMergeAction { changedFieldNames.append("action") }
        if store.rawKB != preMergeKB { changedFieldNames.append("kb") }
        if store.templates != preMergeTemplates { changedFieldNames.append("templates") }

        guard !changedFieldNames.isEmpty else {
            print("[DeviceSync] No actual changes after merge — skipping history")
            return
        }

        // Record pre-merge snapshot so diff view can show before→after
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let templatesStr = (try? encoder.encode(preMergeTemplates)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let entry = PromptHistoryEntry(
            id: UUID().uuidString,
            timestamp: Date().ISO8601Format(),
            source: "sync_receive",
            fields: changedFieldNames,
            composition: preMergeComposition,
            action: preMergeAction,
            kb: preMergeKB,
            templatesJSON: templatesStr
        )
        var history = store.loadHistory()
        history.append(entry)
        if history.count > 100 {
            history = Array(history.suffix(100))
        }
        store.saveHistory(history)

        print("[DeviceSync] Applied sync: \(changedFieldNames.joined(separator: ", "))")

        // If KB changed, re-register task alarms with push worker
        // (a synced [Task] entry needs alarm registration on this device too)
        if changedFieldNames.contains("kb") {
            Task { await TaskEvaluationService.shared.registerAlarmsWithPushWorker() }
        }
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
                if let error { print("[DeviceSync] AI cache probe send failed: \(error)") }
            }
        }
        DeviceSyncLogger.log("PROBE_SEND WSS keys=[\(keys.joined(separator: ", "))] probeId=\(probeId.prefix(8)) timeout=\(timeoutMs)ms")
        print("[DeviceSync] Sent ai_cache_probe for [\(keys.joined(separator: ", "))] (probeId=\(probeId.prefix(8)))")

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
        print("[DeviceSync] Received ai_cache_probe for [\(keys.joined(separator: ", "))] fields=\(fields ?? ["all"]) (probeId=\(probeId?.prefix(8) ?? "nil"))")

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
                    if let error { print("[DeviceSync] AI cache response send failed: \(error)") }
                }
            }
            let hitKeys = Array(results.keys)
            DeviceSyncLogger.log("PROBE_RESPOND \(hitKeys.count) hit(s) for keys=[\(keys.joined(separator: ", "))] probeId=\(probeId?.prefix(8) ?? "nil")")
            print("[DeviceSync] Responded to ai_cache_probe for [\(keys.joined(separator: ", "))]: \(hitKeys.count) hit(s)\(hitKeys.isEmpty ? "" : " [\(hitKeys.joined(separator: ", "))]") (probeId=\(probeId?.prefix(8) ?? "nil"))")
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
        print("[DeviceSync] Resolved ai_cache_probe: \(hitKeys.count) hit(s)\(hitKeys.isEmpty ? "" : " [\(hitKeys.joined(separator: ", "))]") (probeId=\(probeId.prefix(8)))")
        continuation.resume(returning: results.isEmpty ? nil : results)
    }

    // MARK: - Private Helpers

    private func sendPing() {
        guard let ws = webSocket else { return }
        let msg = #"{"type":"ping"}"#
        ws.send(.string(msg)) { error in
            if let error { print("[DeviceSync] Ping failed: \(error)") }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        // Don't reconnect in background — iOS gives no execution time for WebSocket + token fetch.
        // Foreground return (RootView scenePhase .active) calls reconnectIfNeeded().
        guard UIApplication.shared.applicationState == .active else {
            print("[DeviceSync] Skipping reconnect — app not in foreground")
            return
        }
        if reconnectAttempts >= maxReconnectAttempts {
            print("[DeviceSync] Max reconnect attempts (\(maxReconnectAttempts)) reached — giving up")
            return
        }
        let delay = min(reconnectBaseDelay * pow(2.0, Double(reconnectAttempts)), reconnectMaxDelay)
        reconnectAttempts += 1
        print("[DeviceSync] Reconnecting in \(Int(delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // Re-check foreground after delay — app may have backgrounded during sleep
            guard UIApplication.shared.applicationState == .active else {
                print("[DeviceSync] Skipping reconnect — app backgrounded during delay")
                reconnectTask = nil
                return
            }
            reconnectTask = nil
            connect()
        }
    }

    /// Read task cache directly from UserDefaults (same storage key as TaskExecutionCache actor).
    /// Used for synchronous broadcast paths where we can't await the actor.
    private static func readTaskCacheFromDefaults() -> [String: TaskExecutionCache.CacheEntry]? {
        guard let data = UserDefaults.standard.data(forKey: "task_execution_cache"),
              let map = try? JSONDecoder().decode([String: TaskExecutionCache.CacheEntry].self, from: data),
              !map.isEmpty else {
            return nil
        }
        return map
    }

}

// MARK: - Sync Data Types

enum SyncField: String, CaseIterable {
    case composition, action, kb, templates, disabledReminders, taskCache

    /// Prompt-only fields (excludes disabledReminders, taskCache). Used for history/backup/UI that only cares about prompt settings.
    static let promptFields: [SyncField] = [.composition, .action, .kb, .templates]

    var displayName: String {
        switch self {
        case .composition: return "Composition"
        case .action: return "Action Rules"
        case .kb: return "Knowledge Base"
        case .templates: return "Templates"
        case .disabledReminders: return "Disabled Reminders"
        case .taskCache: return "Task Cache"
        }
    }

    var icon: String {
        switch self {
        case .composition: return "pencil.line"
        case .action: return "tag"
        case .kb: return "book"
        case .templates: return "doc.on.doc"
        case .disabledReminders: return "bell.slash"
        case .taskCache: return "clock.arrow.2.circlepath"
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
    /// CRDT map: `{taskHash_date: CacheEntry}`. Per-key timestamp merge (newer ts wins).
    var taskCache: [String: TaskExecutionCache.CacheEntry]?
    var updatedAt: String? // DEPRECATED — use per-field timestamps below
    var compositionUpdatedAt: String?
    var actionUpdatedAt: String?
    var kbUpdatedAt: String?
    var templatesUpdatedAt: String?
    var disabledRemindersUpdatedAt: String?
    var taskCacheUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case composition, action, kb, templates, disabledReminders, taskCache
        case updatedAt = "updatedAt"
        case compositionUpdatedAt = "composition_updated_at"
        case actionUpdatedAt = "action_updated_at"
        case kbUpdatedAt = "kb_updated_at"
        case templatesUpdatedAt = "templates_updated_at"
        case disabledRemindersUpdatedAt = "disabledReminders_updated_at"
        case taskCacheUpdatedAt = "taskCache_updated_at"
    }

    init(
        composition: String? = nil,
        action: String? = nil,
        kb: String? = nil,
        templates: [ReplyTemplate]? = nil,
        disabledReminders: [String: DisabledRemindersStore.DisabledEntry]? = nil,
        taskCache: [String: TaskExecutionCache.CacheEntry]? = nil,
        updatedAt: String? = nil,
        compositionUpdatedAt: String? = nil,
        actionUpdatedAt: String? = nil,
        kbUpdatedAt: String? = nil,
        templatesUpdatedAt: String? = nil,
        disabledRemindersUpdatedAt: String? = nil,
        taskCacheUpdatedAt: String? = nil
    ) {
        self.composition = composition
        self.action = action
        self.kb = kb
        self.templates = templates
        self.disabledReminders = disabledReminders
        self.taskCache = taskCache
        self.updatedAt = updatedAt
        self.compositionUpdatedAt = compositionUpdatedAt
        self.actionUpdatedAt = actionUpdatedAt
        self.kbUpdatedAt = kbUpdatedAt
        self.templatesUpdatedAt = templatesUpdatedAt
        self.disabledRemindersUpdatedAt = disabledRemindersUpdatedAt
        self.taskCacheUpdatedAt = taskCacheUpdatedAt
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
        taskCacheUpdatedAt = try container.decodeIfPresent(String.self, forKey: .taskCacheUpdatedAt)

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

        // Decode taskCache
        taskCache = try container.decodeIfPresent([String: TaskExecutionCache.CacheEntry].self, forKey: .taskCache)
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
