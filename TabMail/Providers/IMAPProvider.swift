/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

/// Quick folder status snapshot for IMAP delta sync change detection.
struct IMAPFolderStatus: Sendable {
    let messageCount: Int
    let uidNext: Int
    let unreadCount: Int
    /// RFC 7162 CONDSTORE HIGHESTMODSEQ — increments on ANY change including
    /// \Seen/flag updates that leave `uidNext`/`messageCount` unchanged (which
    /// STATUS-count delta sync misses today). nil when the server doesn't
    /// advertise CONDSTORE → callers fall back to the uidNext+count comparison.
    let highestModSeq: Int?
    /// UIDVALIDITY — MODSEQ (and UIDs) are only comparable within one UIDVALIDITY
    /// epoch. A change means the mailbox was recreated: callers MUST force a full
    /// sync and reset any cached modseq, never trust a lower/equal value. nil when
    /// not reported (no UIDPLUS).
    let uidValidity: Int?
}

/// Result of an explicit-UID-set existence SEARCH (deletion reconcile, ADR-IOS-051).
struct UIDExistenceResult: Sendable {
    /// UIDs from the queried set that still exist server-side.
    let found: Set<UInt32>
    /// UIDVALIDITY reported by the SELECT that preceded the SEARCH.
    /// 0 = the server did not report a value (callers must treat as unknown
    /// and abort any deletion decision — never delete on uncertainty).
    let uidValidity: UInt32
}

actor IMAPProvider: EmailProvider, MessageExistenceProbe {
    /// IMAP `fetchMessages(limit:)` returns the highest UIDs (archive-time order,
    /// decorrelated from message date) → stale detection must use a UID window.
    nonisolated var staleWindowMode: StaleWindowMode { .uid }

    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let senderEmail: String
    private let smtpHost: String
    private let smtpPort: Int
    /// Test-only TLS override. `nil` in production — SwiftMail infers TLS from
    /// the port (993 → implicit TLS, 143 → plain). Tests set `false` to point
    /// IMAPProvider at an in-process plain-TCP fake on an ephemeral port.
    private let useTLS: Bool?

    // MARK: - Folder-Pinned Connections
    // Each folder gets a dedicated connection, already SELECTed. LRU eviction at server limit.
    // Background ops (sync, backfill, batch fetch) go through these — zero checkout/SELECT overhead.

    /// Folder → pinned IMAP connection (already SELECTed on that folder).
    private var folderServers: [String: IMAPServer] = [:]
    /// Folder → last used timestamp (for LRU eviction).
    private var folderLastUsed: [String: Date] = [:]
    /// Folders whose pinned connection is currently in use by an operation.
    private var folderInUse: Set<String> = []
    /// Folders currently being created (prevents duplicate creation from actor reentrancy).
    private var folderCreating: Set<String> = []
    /// Per-folder waiter queues — callers waiting for a busy or creating folder connection.
    private var folderWaiters: [String: [CheckedContinuation<Void, Error>]] = [:]
    /// Generation counter — incremented by markDirty(). Zombie tasks from a previous
    /// generation skip their release logic instead of accidentally removing new connections.
    private var generation: Int = 0

    // MARK: - Action Connection
    // Dedicated connection for user-initiated actions (move, flag, mark read, draft, etc.).
    // SELECTs the needed folder per-operation (~150ms, fine for low-volume user actions).
    // Guaranteed never blocked by background work or IDLE.

    private var actionServer: IMAPServer?
    private var actionInUse = false
    private var actionWaiters: [CheckedContinuation<Void, Error>] = []

    // MARK: - IDLE Connection (Dedicated, Tracked, Evictable)
    // Separate connection for IMAP IDLE (RFC 2177 requires no commands during IDLE).
    // Tracked in the connection budget and evictable when connections are scarce.
    // Priority: action > folder connections > IDLE (lowest — falls back to polling).

    /// Dedicated IDLE connection — separate from action and folder connections.
    private var idleServer: IMAPServer?
    /// Task running the IDLE event listener loop.
    private var idleListenerTask: Task<Void, Never>?
    /// Callback invoked when IDLE receives an event (EXISTS, EXPUNGE, etc.).
    private var idleEventHandler: ((IMAPServerEvent) -> Void)?
    /// Whether IDLE should be running (set by startIdle/stopIdle).
    private var idleEnabled = false

    // MARK: - Server Limit
    /// Server-declared connection limit. Folder connections capped at limit - 2
    /// (reserve 1 for action, 1 for IDLE). IDLE slot is evictable when scarce.
    private var serverConnectionLimit: Int?
    /// Connections reserved from server limit (action + IDLE).
    private static let reservedConnections = 2

    // MARK: - Keepalive
    private var keepAliveTask: Task<Void, Never>?

    /// UTC calendar for IMAP date conversions — SINCE/BEFORE use date-only semantics,
    /// so UTC prevents off-by-one day gaps caused by device timezone differences.
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    init(
        host: String,
        port: Int = 993,
        username: String,
        password: String,
        senderEmail: String? = nil,
        smtpHost: String,
        smtpPort: Int = 587,
        useTLS: Bool? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.senderEmail = senderEmail ?? username
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.useTLS = useTLS
        // Start from the persisted server limit (learned from a prior
        // max_userip_connections rejection) so backfill's parallel walk never
        // re-oversubscribes a server whose cap we already know.
        self.serverConnectionLimit = Self.persistedServerLimit(host: host, username: username)
    }

    // MARK: - Connection Creation

    /// Create a fresh logged-in IMAP connection.
    private func createServer() async throws -> IMAPServer {
        let server = IMAPServer(
            host: host,
            port: port,
            useTLS: useTLS,
            responseBufferLimit: IMAPFetchMapping.responseBufferLimit
        )
        try await server.connect()
        try await server.login(username: username, password: password)
        return server
    }

    /// Max folder connections (server limit minus reserved for action + IDLE).
    /// When IDLE is evicted, the freed slot becomes available for folders.
    private var maxFolderConnections: Int {
        if let limit = serverConnectionLimit {
            let activeReserved = idleServer != nil ? Self.reservedConnections : Self.reservedConnections - 1
            return max(1, limit - activeReserved)
        }
        return SyncConfig.imapMaxConnectionCeiling - Self.reservedConnections
    }

    /// Parse server connection limit from error message.
    /// The learned limit is persisted per host+username so subsequent launches
    /// start at the real cap instead of re-oversubscribing (up to 18 parallel
    /// backfill workers against e.g. Dovecot's 15/user+IP) until the server
    /// rejects a login again.
    private func parseAndApplyServerLimit(from error: Error) {
        let desc = "\(error)"
        guard desc.contains("max_userip_connections"),
              let range = desc.range(of: "mail_max_userip_connections="),
              let limit = Int(desc[range.upperBound...].prefix(while: \.isNumber))
        else { return }
        if serverConnectionLimit == nil || limit < serverConnectionLimit! {
            serverConnectionLimit = limit
            Self.persistServerLimit(limit, host: host, username: username)
            print("[IMAP] Server connection limit detected: \(limit) (folder slots: \(maxFolderConnections))")
            BackgroundSyncLogger.logBackfill("[IMAP] \(senderEmail) server connection limit detected: \(limit) (folder slots: \(maxFolderConnections))")
        }
    }

    // MARK: - Server Limit Persistence

    /// UserDefaults key for the learned per-server connection limit. Keyed by
    /// host+username (the provider doesn't know accountId) so a re-added account
    /// on the same server reuses the learned cap.
    static func serverLimitDefaultsKey(host: String, username: String) -> String {
        "imapServerConnLimit:\(username)@\(host)"
    }

    static func persistedServerLimit(host: String, username: String) -> Int? {
        let value = UserDefaults.standard.integer(forKey: serverLimitDefaultsKey(host: host, username: username))
        return value > 0 ? value : nil
    }

    static func persistServerLimit(_ limit: Int, host: String, username: String) {
        UserDefaults.standard.set(limit, forKey: serverLimitDefaultsKey(host: host, username: username))
    }

    /// Whether an idle reusable connection needs a NOOP before it is handed out.
    /// Kept as one production decision for both folder-pinned and action connections.
    static func shouldCheckConnectionLiveness(lastUsed: Date?, now: Date) -> Bool {
        now.timeIntervalSince(lastUsed ?? .distantPast) > SyncConfig.imapPoolLivenessCheckSeconds
    }

    // MARK: - Folder Connection API

    /// Execute an operation on a folder-pinned connection (already SELECTed).
    /// Used for all background/sync folder operations. Connection stays pinned after use.
    /// If the folder connection is busy, caller waits. If none exists, one is created.
    private func withFolderConnection<T>(
        folder: String,
        _ body: (IMAPServer) async throws -> T
    ) async throws -> T {
        let acquiredGeneration = generation
        let server = try await acquireFolderConnection(folder: folder)
        do {
            let result = try await body(server)
            // If markDirty() ran while body was executing, this connection is stale.
            // Don't touch folderServers — a new connection may already exist for this folder.
            guard generation == acquiredGeneration else {
                print("[IMAP] Stale generation for \(folder) — discarding connection silently")
                return result
            }
            releaseFolderConnection(folder: folder, healthy: true)
            return result
        } catch {
            guard generation == acquiredGeneration else {
                print("[IMAP] Stale generation for \(folder) after error — discarding connection silently")
                throw error
            }
            let desc = "\(error)"
            let isUnhealthy = SyncEngine.isConnectionError(error)
                || desc.contains("PayloadTooLargeError")
                || desc.contains("IMAPDecoderError")
            if isUnhealthy { parseAndApplyServerLimit(from: error) }
            releaseFolderConnection(folder: folder, healthy: !isUnhealthy)
            throw error
        }
    }

    private func acquireFolderConnection(folder: String) async throws -> IMAPServer {
        // 1. Existing connection, not in use — verify liveness and return
        if let server = folderServers[folder], !folderInUse.contains(folder) {
            let now = Date()
            let idle = now.timeIntervalSince(folderLastUsed[folder] ?? .distantPast)
            if Self.shouldCheckConnectionLiveness(lastUsed: folderLastUsed[folder], now: now) {
                do {
                    _ = try await server.noop()
                } catch {
                    // Dead — discard and create fresh
                    print("[IMAP] Pinned connection for \(folder) dead (idle \(Int(idle))s) — recreating")
                    folderServers.removeValue(forKey: folder)
                    folderLastUsed.removeValue(forKey: folder)
                    return try await createFolderConnection(folder: folder)
                }
            }
            folderInUse.insert(folder)
            folderLastUsed[folder] = Date()
            return server
        }

        // 2. Existing connection but in use, OR being created (actor reentrancy guard) — wait
        if folderServers[folder] != nil || folderCreating.contains(folder) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                folderWaiters[folder, default: []].append(cont)
            }
            // Resumed — connection is ours. Verify it still exists (unhealthy release may have removed it).
            guard let server = folderServers[folder] else {
                return try await createFolderConnection(folder: folder)
            }
            folderInUse.insert(folder)
            folderLastUsed[folder] = Date()
            return server
        }

        // 3. No connection for this folder — create one
        return try await createFolderConnection(folder: folder)
    }

    private func createFolderConnection(folder: String) async throws -> IMAPServer {
        // Evict LRU if at capacity (try IDLE as last resort before waiting)
        while folderServers.count >= maxFolderConnections {
            guard evictLRUFolder() || evictIdleConnection() else {
                // All connections in use and IDLE already evicted — wait for ANY folder to free up
                print("[IMAP] All \(folderServers.count) folder connections in use — waiting")
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    folderWaiters[folder, default: []].append(cont)
                }
                // Resumed — try again (a slot may have opened)
                if let server = folderServers[folder] {
                    folderInUse.insert(folder)
                    folderLastUsed[folder] = Date()
                    return server
                }
                continue
            }
        }

        // Mark as creating — prevents duplicate creation from actor reentrancy
        // (another caller hitting acquireFolderConnection during our awaits below)
        folderCreating.insert(folder)

        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let server = try await createServer()
            _ = try await server.selectMailbox(folder)
            folderCreating.remove(folder)
            folderServers[folder] = server
            folderLastUsed[folder] = Date()
            folderInUse.insert(folder)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("[IMAP] Created pinned connection for \(folder) in \(ms)ms (total: \(folderServers.count)/\(maxFolderConnections))")
            // Resume one waiter (if any were queued during creation)
            if var waiters = folderWaiters[folder], !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                folderWaiters[folder] = waiters.isEmpty ? nil : waiters
                waiter.resume()
            }
            return server
        } catch {
            folderCreating.remove(folder)
            let isLimitError = "\(error)".contains("max_userip_connections")
            parseAndApplyServerLimit(from: error)

            // Connection limit hit — evict LRU folder (or IDLE as last resort) and retry once
            if isLimitError && (evictLRUFolder() || evictIdleConnection()) {
                print("[IMAP] Connection limit hit for \(folder) — evicted LRU, retrying")
                do {
                    let server = try await createServer()
                    _ = try await server.selectMailbox(folder)
                    folderServers[folder] = server
                    folderLastUsed[folder] = Date()
                    folderInUse.insert(folder)
                    let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    print("[IMAP] Created pinned connection for \(folder) in \(ms)ms (total: \(folderServers.count)/\(maxFolderConnections))")
                    if var waiters = folderWaiters[folder], !waiters.isEmpty {
                        let waiter = waiters.removeFirst()
                        folderWaiters[folder] = waiters.isEmpty ? nil : waiters
                        waiter.resume()
                    }
                    return server
                } catch {
                    parseAndApplyServerLimit(from: error)
                    let waiters = folderWaiters.removeValue(forKey: folder) ?? []
                    for w in waiters { w.resume(throwing: error) }
                    throw error
                }
            }

            // Fail waiters that queued during creation
            let waiters = folderWaiters.removeValue(forKey: folder) ?? []
            for w in waiters { w.resume(throwing: error) }
            throw error
        }
    }

    /// Evict the least recently used folder connection that is NOT in use.
    /// Returns true if a connection was evicted, false if all are in use.
    @discardableResult
    private func evictLRUFolder() -> Bool {
        let candidates = folderLastUsed.filter { !folderInUse.contains($0.key) }
        guard let (folder, _) = candidates.min(by: { $0.value < $1.value }) else {
            return false
        }
        let server = folderServers.removeValue(forKey: folder)
        folderLastUsed.removeValue(forKey: folder)
        if let server {
            Task { try? await server.logout() }
            print("[IMAP] Evicted LRU pinned connection for \(folder)")
        }
        return true
    }

    private func releaseFolderConnection(folder: String, healthy: Bool) {
        folderInUse.remove(folder)

        if !healthy {
            let server = folderServers.removeValue(forKey: folder)
            folderLastUsed.removeValue(forKey: folder)
            if let server { Task { try? await server.logout() } }
            // Fail all waiters for this folder — they'll create a new connection
            let waiters = folderWaiters.removeValue(forKey: folder) ?? []
            for waiter in waiters {
                waiter.resume(throwing: ProviderError.notConnected)
            }
            return
        }

        folderLastUsed[folder] = Date()

        // Resume next waiter for this folder
        if var waiters = folderWaiters[folder], !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            folderWaiters[folder] = waiters.isEmpty ? nil : waiters
            waiter.resume()
        }
    }

    // MARK: - Action Connection API

    /// Thrown internally when a SELECT failure on an ACTION path was
    /// authoritatively confirmed to mean "this mailbox no longer exists"
    /// (`mailboxConfirmedAbsent`). Never constructed from unstructured error
    /// text (Law 5 forbids the queue from guessing that way; doing it here
    /// would just relocate the exact fragility). A caller with a defined
    /// "stale means no-op" outcome for its operation (`move`,
    /// `mutateActionMessages`) catches this and returns normally per Law 4;
    /// a caller without one (`fetchAttachment`, `appendToSentFolder`,
    /// `saveDraft`, `deleteDraft`) lets it propagate like any other error —
    /// unchanged behavior from before this type existed.
    private struct IMAPActionMailboxAbsent: Error {}

    /// Authoritative existence probe used only after a SELECT already failed
    /// on an ACTION path. `IMAPError.selectFailed`'s raw reason text is
    /// server-defined and not machine-parseable, so this never inspects it —
    /// a LIST for the exact mailbox name is the only authority:
    ///   - LIST succeeds and returns no mailbox with this exact name →
    ///     confirmed absent (authoritative stale — Law 4).
    ///   - LIST succeeds and the mailbox IS present → the original SELECT
    ///     failure was transient (permissions hiccup, momentary server
    ///     glitch); the caller rethrows it.
    ///   - LIST itself fails → uncertainty, not absence; the caller rethrows
    ///     the original SELECT failure.
    /// Runs on the SAME connection that just failed SELECT — a tagged NO/BAD
    /// response does not kill an IMAP connection (only a connection-level
    /// failure does, already classified separately by the caller). `folder`
    /// is passed as the literal LIST pattern (no wildcard characters), which
    /// IMAP servers treat as an exact-match query — this cannot accidentally
    /// match a different mailbox that merely shares a substring/prefix.
    private func mailboxConfirmedAbsent(_ folder: String, server: IMAPServer) async -> Bool {
        guard let mailboxes = try? await server.listMailboxes(wildcard: folder) else {
            return false
        }
        return !mailboxes.contains { $0.name == folder }
    }

    /// Execute a user-initiated operation on the reserved action connection.
    /// SELECTs the folder per-operation (~150ms). Never blocked by background work.
    private func withActionConnection<T>(
        folder: String,
        _ body: (IMAPServer) async throws -> T
    ) async throws -> T {
        let server = try await acquireActionConnection()

        func releaseAfterFailure(_ error: Error) {
            let desc = "\(error)"
            let isUnhealthy = SyncEngine.isConnectionError(error)
                || desc.contains("PayloadTooLargeError")
                || desc.contains("IMAPDecoderError")
            if isUnhealthy { parseAndApplyServerLimit(from: error) }
            releaseActionConnection(healthy: !isUnhealthy)
        }

        do {
            _ = try await server.selectMailbox(folder)
        } catch {
            // A SELECT failure here might mean the recorded mailbox was
            // deleted remotely between enqueue and drain (Law 4: authoritative
            // stale no-op), or might be transient (auth hiccup, connection
            // drop, malformed response — must retry). Only a LIST probe can
            // tell the difference (see `mailboxConfirmedAbsent`).
            let confirmedAbsent = await mailboxConfirmedAbsent(folder, server: server)
            releaseAfterFailure(error)
            if confirmedAbsent { throw IMAPActionMailboxAbsent() }
            throw error
        }

        do {
            let result = try await body(server)
            releaseActionConnection(healthy: true)
            return result
        } catch {
            releaseAfterFailure(error)
            throw error
        }
    }

    /// Execute on the action connection without folder SELECT (for LIST, STATUS, etc.).
    private func withActionConnectionNoSelect<T>(
        _ body: (IMAPServer) async throws -> T
    ) async throws -> T {
        let server = try await acquireActionConnection()
        do {
            let result = try await body(server)
            releaseActionConnection(healthy: true)
            return result
        } catch {
            let desc = "\(error)"
            let isUnhealthy = SyncEngine.isConnectionError(error)
                || desc.contains("PayloadTooLargeError")
                || desc.contains("IMAPDecoderError")
            releaseActionConnection(healthy: !isUnhealthy)
            throw error
        }
    }

    private func acquireActionConnection() async throws -> IMAPServer {
        // Ensure a connection exists, returning the (possibly fresh) server.
        // Every path captures into a local BEFORE the next await to guard against
        // actor reentrancy nilling actionServer between suspension points.
        func ensureServer() async throws -> IMAPServer {
            if let existing = actionServer { return existing }
            let fresh = try await createServer()
            actionServer = fresh
            print("[IMAP] Created action connection")
            return fresh
        }

        var server = try await ensureServer()

        // If not in use, take it
        if !actionInUse {
            let now = Date()
            let shouldCheckLiveness = Self.shouldCheckConnectionLiveness(
                lastUsed: folderLastUsed["__action__"],
                now: now
            )
            actionInUse = true
            folderLastUsed["__action__"] = now

            // Verify liveness if idle too long
            if shouldCheckLiveness {
                do {
                    _ = try await server.noop()
                    server = try await ensureServer()
                } catch {
                    print("[IMAP] Action connection dead — recreating")
                    do {
                        let fresh = try await createServer()
                        actionServer = fresh
                        server = fresh
                    } catch {
                        releaseActionConnection(healthy: false)
                        throw error
                    }
                }
            }
            return server
        }

        // In use — wait
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            actionWaiters.append(cont)
        }
        // Resumed — connection may have been released unhealthy while waiting
        server = try await ensureServer()
        actionInUse = true
        folderLastUsed["__action__"] = Date()
        return server
    }

    private func releaseActionConnection(healthy: Bool) {
        actionInUse = false
        folderLastUsed["__action__"] = Date()

        if !healthy {
            if let server = actionServer { Task { try? await server.logout() } }
            actionServer = nil
            // Fail all waiters
            let waiters = actionWaiters
            actionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: ProviderError.notConnected)
            }
            return
        }

        // Resume next waiter
        if !actionWaiters.isEmpty {
            let waiter = actionWaiters.removeFirst()
            waiter.resume()
        }
    }

    // MARK: - Keepalive

    /// Start periodic NOOP keepalive on idle pinned connections.
    /// Prevents server timeout during gaps between batches.
    func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(SyncConfig.imapPoolLivenessCheckSeconds))
                guard !Task.isCancelled else { return }
                await self?.keepAlivePinnedConnections()
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    private func keepAlivePinnedConnections() async {
        // NOOP all idle folder connections
        for (folder, server) in folderServers where !folderInUse.contains(folder) {
            do {
                _ = try await server.noop()
                folderLastUsed[folder] = Date()
            } catch {
                print("[IMAP] Keepalive failed for \(folder) — removing")
                folderServers.removeValue(forKey: folder)
                folderLastUsed.removeValue(forKey: folder)
            }
        }
        // NOOP action connection if idle
        if !actionInUse, let server = actionServer {
            do {
                _ = try await server.noop()
                folderLastUsed["__action__"] = Date()
            } catch {
                print("[IMAP] Keepalive failed for action connection — removing")
                actionServer = nil
            }
        }
    }

    // MARK: - Lifecycle

    func connect() async throws {
        // Create the action connection eagerly
        actionServer = try await createServer()
        print("[IMAP] Action connection ready")
        startKeepAlive()
    }

    func disconnect() async throws {
        stopKeepAlive()
        stopIdle()
        // Drain all folder connections
        for (folder, server) in folderServers {
            try? await server.logout()
            print("[IMAP] Disconnected pinned connection for \(folder)")
        }
        folderServers.removeAll()
        folderLastUsed.removeAll()
        folderInUse.removeAll()
        folderCreating.removeAll()
        // Fail all folder waiters
        for (_, waiters) in folderWaiters {
            for w in waiters { w.resume(throwing: ProviderError.notConnected) }
        }
        folderWaiters.removeAll()
        // Drain primary connection
        if let server = actionServer { try? await server.logout() }
        actionServer = nil
        actionInUse = false
        let aw = actionWaiters
        actionWaiters.removeAll()
        for w in aw { w.resume(throwing: ProviderError.notConnected) }
    }

    func markDirty() async {
        // After iOS suspension (background, BGAppRefresh, push wakeup), ALL connections
        // are assumed dead. Liveness checks on dead connections waste time and can silently
        // fail. The ONLY reliable path: disconnect everything, recreate fresh on next use.
        // This costs 1-3s but is the only way to guarantee working connections.

        // Advance generation — zombie tasks from previous generation will skip release
        // instead of accidentally removing newly created connections.
        generation += 1

        // Nuke ALL folder connections (both idle and in-use)
        for (folder, server) in folderServers {
            Task { try? await server.logout() }
            print("[IMAP] markDirty: disconnecting pinned connection for \(folder)")
        }
        folderServers.removeAll()
        folderLastUsed.removeAll()
        folderInUse.removeAll()
        folderCreating.removeAll()
        // Fail all folder waiters — they'll get fresh connections on retry
        for (_, waiters) in folderWaiters {
            for w in waiters { w.resume(throwing: ProviderError.notConnected) }
        }
        folderWaiters.removeAll()

        // Stop IDLE listener (don't clear idleEnabled — it will resume after reconnect)
        idleListenerTask?.cancel()
        idleListenerTask = nil
        if let server = idleServer {
            Task { try? await server.logout() }
            print("[IMAP] markDirty: disconnecting IDLE connection")
        }
        idleServer = nil

        // Nuke action connection
        if let server = actionServer {
            Task { try? await server.logout() }
            print("[IMAP] markDirty: disconnecting action connection")
        }
        actionServer = nil
        actionInUse = false
        let aw = actionWaiters
        actionWaiters.removeAll()
        for w in aw { w.resume(throwing: ProviderError.notConnected) }
    }

    /// Server-declared per-user connection limit (e.g., `max_userip_connections=15`).
    /// `nil` until the server first rejects a connection with the limit error.
    func detectedServerLimit() -> Int? {
        serverConnectionLimit
    }

    /// Current max folder connections (server limit minus reserved for primary).
    func poolMaxConnections() -> Int {
        maxFolderConnections
    }

    // MARK: - IDLE (Dedicated Connection)

    /// Start IDLE monitoring on a dedicated connection.
    /// Creates its own connection (tracked in the budget, evictable when scarce).
    /// RFC 2177 requires no commands during IDLE, so a separate connection is mandatory.
    func startIdle(handler: @escaping @Sendable (IMAPServerEvent, String) async -> Void) {
        idleEnabled = true
        idleEventHandler = { [senderEmail] event in
            Task { await handler(event, senderEmail) }
        }
        launchIdleConnection()
    }

    /// Stop IDLE monitoring. Called on background transition.
    func stopIdle() {
        idleEnabled = false
        idleEventHandler = nil
        idleListenerTask?.cancel()
        idleListenerTask = nil
        if let server = idleServer {
            Task { try? await server.done(); try? await server.logout() }
        }
        idleServer = nil
    }

    /// Minimum server connection limit to enable IDLE.
    /// With limit=2, we only have action + 1 folder slot — IDLE would starve sync.
    private static let idleMinServerLimit = 3

    /// Create the IDLE connection and start listening.
    /// Skips if server limit is too low (need action + folder + IDLE = 3 minimum).
    private func launchIdleConnection() {
        guard idleEnabled, idleServer == nil else { return }
        // Don't launch IDLE if server limit is known and too tight
        if let limit = serverConnectionLimit, limit < Self.idleMinServerLimit {
            print("[IMAP:IDLE] Skipping — server limit \(limit) < \(Self.idleMinServerLimit), falling back to polling")
            return
        }

        idleListenerTask?.cancel()
        idleListenerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let server = try await self.createServer()
                await self.setIdleServer(server)
                _ = try await server.selectMailbox("INBOX")
                print("[IMAP:IDLE] Dedicated IDLE connection ready")
                let events = try await server.idle()
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await self.dispatchIdleEvent(event)
                }
                // Stream ended (server broke IDLE or connection dropped)
                print("[IMAP:IDLE] Stream ended — reconnecting in 5s")
                await self.onIdleStreamEnded()
            } catch is CancellationError {
                // Expected — stopIdle or markDirty
            } catch {
                print("[IMAP:IDLE] Error: \(error) — reconnecting in 10s")
                await self.onIdleStreamEnded(delay: 10)
            }
        }
    }

    private func setIdleServer(_ server: IMAPServer?) {
        idleServer = server
    }

    private func dispatchIdleEvent(_ event: IMAPServerEvent) {
        idleEventHandler?(event)
    }

    /// Called when IDLE stream ends unexpectedly. Cleans up and retries.
    private func onIdleStreamEnded(delay: TimeInterval = 5) {
        if let server = idleServer {
            Task { try? await server.logout() }
        }
        idleServer = nil
        idleListenerTask = nil
        guard idleEnabled else { return }
        // Retry after delay
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            await self.launchIdleConnection()
        }
    }

    /// Evict the IDLE connection to free a server slot.
    /// Returns true if an IDLE connection was evicted, false if none was active.
    @discardableResult
    private func evictIdleConnection() -> Bool {
        guard let server = idleServer else { return false }
        print("[IMAP:IDLE] Evicting IDLE connection to free server slot")
        idleListenerTask?.cancel()
        idleListenerTask = nil
        Task { try? await server.done(); try? await server.logout() }
        idleServer = nil
        // Will relaunch after delay if idleEnabled is still true
        if idleEnabled {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.launchIdleConnection()
            }
        }
        return true
    }

    func fetchFolders() async throws -> [FolderInfo] {
        try await withActionConnectionNoSelect { server in
            let mailboxes = try await server.listMailboxes()

            // Build (info, attributes) pairs so the dedup pass can prefer the
            // folder carrying the actual SPECIAL-USE flag (RFC 6154) over a
            // folder that only matched the name-based heuristic. iCloud, for
            // example, exposes both "Trash" and "Deleted Messages" — only one
            // typically carries `\Trash`, and the other should fall back to
            // `.custom` instead of duplicating the role.
            var pairs: [(info: FolderInfo, attributes: Mailbox.Info.Attributes)] = []
            for info in mailboxes {
                guard info.isSelectable else { continue }
                var unread = 0
                var total = 0
                var uidNextVal: Int?
                var highestModSeqVal: Int?
                do {
                    let status = try await server.mailboxStatus(info.name)
                    unread = status.unseenCount ?? 0
                    total = status.messageCount ?? 0
                    uidNextVal = status.uidNext.map { Int($0.value) }
                    // CONDSTORE HIGHESTMODSEQ (nil unless the server advertises it) — the
                    // full-sync fetch-skip signal (Fix B task 4).
                    highestModSeqVal = status.highestModSequence
                } catch {
                    print("[IMAP] STATUS failed for \(info.name): \(error)")
                }
                pairs.append((
                    info: FolderInfo(
                        name: info.name,
                        path: info.name,
                        role: IMAPProvider.mapRole(attributes: info.attributes, name: info.name),
                        unreadCount: unread,
                        totalCount: total,
                        uidNext: uidNextVal,
                        highestModSeq: highestModSeqVal
                    ),
                    attributes: info.attributes
                ))
            }
            return IMAPProvider.dedupRoles(pairs)
        }
    }

    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] {
        try await withFolderConnection(folder: folder) { server in
            let selection = try await server.selectMailbox(folder)
            guard selection.messageCount > 0 else { return [] }

            guard let range = selection.latest(limit) else { return [] }

            do {
                let infos = try await server.fetchMessageInfosBulk(using: range)
                if infos.count < limit && infos.count < selection.messageCount {
                    print("[IMAP-FETCH-GAP] \(folder): fetchMessages requested \(limit) (msgCount=\(selection.messageCount)), got \(infos.count)")
                }
                // compactMap: mapMessageInfo returns nil for unparseable messages (treated as fetch failure)
                return infos.compactMap { self.mapMessageInfo($0) }.sorted { $0.date > $1.date }
            } catch {
                let msg = "\(error)"
                if msg.contains("Invalid messageset") || msg.contains("invalid messageset") {
                    print("[IMAP] Invalid messageset for \(folder) (messageCount=\(selection.messageCount)) — skipping")
                    return []
                }
                throw error
            }
        }
    }

    func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo {
        try await withActionConnection(folder: folder) { server in
            try await self.fetchMessageOnConnection(id: id, folder: folder, server: server)
        }
    }

    private func fetchMessageOnConnection(id: String, folder: String, server: IMAPServer) async throws -> FullMessageInfo {
        _ = try await server.selectMailbox(folder)

        let results = try await resolveUID(id, server: server)
        guard !results.isEmpty else {
            throw ProviderError.messageNotFound
        }

        let uids = results.toArray()
        guard let uid = uids.first else { throw ProviderError.messageNotFound }

        let info = try await server.fetchMessageInfo(for: uid)
        guard let info else { throw ProviderError.messageNotFound }

        let message = try await server.fetchMessage(from: info)

        // buildFullMessageInfo returns nil when mapMessageInfo can't parse the header
        // (e.g., date parse failure). Treat as a fetch failure so the caller retries.
        guard let full = buildFullMessageInfo(info: info, message: message) else {
            throw ProviderError.messageNotFound
        }
        return full
    }

    /// Build FullMessageInfo from BODYSTRUCTURE info + fetched message data.
    /// Extracted from fetchMessageOnConnection so batch fetch can reuse it.
    /// Returns nil if the header can't be parsed — caller should treat as fetch failure.
    private func buildFullMessageInfo(info: MessageInfo, message: Message) -> FullMessageInfo? {
        guard let header = mapMessageInfo(info) else { return nil }

        // Classify each attachment as top-level vs nested-in-.eml by checking
        // whether its MIME section is a descendant of any message/rfc822 section.
        // A section like "2.2" is nested under the rfc822 at "2". The prefix
        // match uses section COMPONENTS (not string prefix), so "12" is NOT
        // considered nested under "1".
        let rfc822Sections: [[Int]] = info.parts.compactMap { part in
            part.contentType.lowercased().hasPrefix("message/rfc822")
                ? part.section.components
                : nil
        }

        // Extract attachment metadata
        var attachments: [AttachmentInfo] = info.parts.compactMap { part in
            let ct = part.contentType.lowercased()
            let disposition = part.disposition?.lowercased()
            let hasFilename = part.filename != nil
            let isExplicitAttachment = disposition == "attachment"
            let hasFileNotInline = hasFilename && disposition != "inline"
            // text/calendar (ICS invites) are attachments even without explicit
            // disposition or filename — Outlook often omits both.
            let isCalendar = ct.hasPrefix("text/calendar")
            let isAttachment = isExplicitAttachment || hasFileNotInline || isCalendar
            guard isAttachment else { return nil }
            let filename = part.filename ?? part.suggestedFilename
            let parentEml = IMAPFetchMapping.parentEmlSection(for: part.section.components, rfc822Sections: rfc822Sections)

            return AttachmentInfo(
                filename: filename,
                contentType: part.contentType,
                section: part.section.description,
                size: part.data?.count ?? 0,
                encoding: part.encoding,
                parentEmlSection: parentEml
            )
        }

        // Surface attachments nested INSIDE file-uploaded `.eml` parts.
        // Server-parsed `message/rfc822` parts already have their children
        // visible at the top level (BODYSTRUCTURE exposes them at numeric
        // sub-sections like `2.1`, and the block above catches them).
        // File-uploaded `.eml`s are opaque blobs server-side — the nested
        // attachments only exist after we parse the bytes ourselves.
        //
        // `encoding` on each nested AttachmentInfo is set to the PARENT's
        // transfer encoding (not the inner attachment's). Tap-time
        // resolution calls `fetchAttachment` with this encoding, which
        // routes through the compound branch: re-fetch parent bytes using
        // this encoding (so base64-transported .emls decode correctly),
        // then `nestedBytes` parses the decoded RFC 822 and handles the
        // inner attachment's own transfer encoding internally.
        for part in message.parts where EmlParsing.isEmlFilename(part.filename)
            && !part.contentType.lowercased().hasPrefix("message/rfc822") {
            guard let raw = part.decodedData() ?? part.data,
                  let parsed = EmlParsing.parse(rawBytes: raw) else { continue }
            let parentSection = part.section.description
            let parentEncoding = part.encoding
            for (index, meta) in parsed.nested.enumerated() {
                attachments.append(AttachmentInfo(
                    filename: meta.filename,
                    contentType: meta.contentType,
                    section: EmlParsing.nestedSection(parent: parentSection, index: index),
                    size: meta.size,
                    encoding: parentEncoding,
                    parentEmlSection: parentSection
                ))
            }
        }

        // Extract CID inline images — data is already fetched by SwiftMail.
        // Use decodedData() to handle content transfer encoding (base64, quoted-printable)
        // before we re-encode as data: URI in AccountManagerFetch.
        let inlineImages: [InlineImage] = message.cids.prefix(SyncConfig.maxInlineImages).compactMap { part in
            guard let rawId = part.contentId, let data = part.decodedData() else { return nil }
            // Strip angle brackets + whitespace: "< image001@host >" → "image001@host"
            let contentId = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contentId.isEmpty else { return nil }
            return InlineImage(contentId: contentId, contentType: part.contentType, data: data)
        }

        // Extract ICS calendar data from already-fetched parts (avoids re-fetch in renderBody)
        let icsData: Data? = message.parts.first(where: {
            $0.contentType.lowercased().contains("text/calendar")
        })?.decodedData()

        // Log body part structure for debugging embedded .eml rendering
        let bodyParts = message.bodies
        let rfc822Parts = message.parts.filter { $0.contentType.lowercased().hasPrefix("message/rfc822") }
        if !rfc822Parts.isEmpty {
            print("[EmlRender] Message has \(rfc822Parts.count) rfc822 part(s), \(bodyParts.count) body parts:")
            for part in bodyParts {
                print("[EmlRender]   section=\(part.section.description) type=\(part.contentType) len=\(part.textContent?.count ?? 0)")
            }
            for part in rfc822Parts {
                print("[EmlRender]   rfc822: section=\(part.section.description) filename=\(part.filename ?? "nil")")
            }
        }

        // Insert TB-style header blocks before nested message/rfc822 body content
        let htmlBody = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        let textBody = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/plain")

        if !rfc822Parts.isEmpty {
            print("[EmlRender] htmlBody len=\(htmlBody?.count ?? 0), textBody len=\(textBody?.count ?? 0)")
        }

        return FullMessageInfo(
            header: header,
            htmlBody: htmlBody,
            textBody: textBody,
            attachments: attachments,
            inlineImages: inlineImages,
            icsData: icsData
        )
    }

    // MARK: - Batch Full Message Fetch

    /// Batch fetch full messages on a single connection using pipelined part fetches.
    /// Flow: one SELECT → one bulk BODYSTRUCTURE → pipelined FETCH for all parts across all messages.
    /// Avoids redundant per-message BODYSTRUCTURE re-fetch that `fetchMessage(from:)` does internally.
    /// PayloadTooLarge messages are marked bodyEmptyConfirmed and omitted from result.
    /// Throws on connection-level errors (caller should retry the batch).
    func fetchMessagesBatch(ids: [String], folder: String) async throws -> [String: FullMessageInfo] {
        // Defensive guard — see `EmailProvider.fetchMessagesBatch` extension default
        // for the rationale. The implicit `UInt32(id)` filter below would already
        // drop synthetic placeholder ids silently, but silent-drop hits the caller's
        // miss-counter → eventual CASCADE-delete path. Throw loudly instead.
        let synthetic = ids.filter(isSyntheticPlaceholderId)
        if !synthetic.isEmpty {
            print("[IMAP] ERROR: synthetic placeholder ids leaked into fetchMessagesBatch — upstream queue regression. folder=\(folder) ids=\(synthetic.prefix(5))")
            throw ProviderError.syntheticPlaceholderId(synthetic)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let uidPairs: [(id: String, uid: UInt32)] = ids.compactMap { id in
            guard let uid = UInt32(id) else { return nil }
            return (id, uid)
        }
        guard !uidPairs.isEmpty else {
            print("[IMAP] fetchMessagesBatch: no valid UIDs in \(ids.count) ids")
            return [:]
        }

        print("[IMAP] fetchMessagesBatch START: \(uidPairs.count) UIDs in \(folder)")

        return try await withFolderConnection(folder: folder) { server in
            // 1. SELECT (re-selects on pinned connection — fast, refreshes state)
            let tSelect = CFAbsoluteTimeGetCurrent()
            _ = try await server.selectMailbox(folder)
            let selectMs = Int((CFAbsoluteTimeGetCurrent() - tSelect) * 1000)
            print("[IMAP] fetchMessagesBatch SELECT: \(selectMs)ms")

            // 2. Bulk BODYSTRUCTURE for all UIDs — we already get parts from this
            let tStruct = CFAbsoluteTimeGetCurrent()
            var uidSet = UIDSet()
            for (_, uid) in uidPairs { uidSet.insert(UID(uid)) }
            let infos = try await server.fetchMessageInfosBulk(using: uidSet)
            let structMs = Int((CFAbsoluteTimeGetCurrent() - tStruct) * 1000)
            print("[IMAP] fetchMessagesBatch BODYSTRUCTURE: \(infos.count)/\(uidPairs.count) returned in \(structMs)ms")

            // Map UID → (id, MessageInfo) for lookup
            var infoByUID: [UInt32: (id: String, info: MessageInfo)] = [:]
            for info in infos {
                guard let uid = info.uid else { continue }
                // Find the original string ID for this UID
                if let pair = uidPairs.first(where: { $0.uid == uid.value }) {
                    infoByUID[uid.value] = (id: pair.id, info: info)
                }
            }

            // 3. Collect ALL parts from ALL messages for pipelined fetch.
            //    We already have BODYSTRUCTURE from step 2 — no need to re-fetch it
            //    (fetchMessage(from:) internally calls fetchStructure again, which is wasteful
            //    and causes NIO buffer accumulation with 200+ redundant IMAP commands).
            var partRequests: [(uid: UID, section: Section)] = []
            var partsByUID: [UInt32: [MessagePart]] = [:]

            for (uidValue, entry) in infoByUID {
                let uid = UID(uidValue)
                partsByUID[uidValue] = entry.info.parts
                for part in entry.info.parts {
                    partRequests.append((uid: uid, section: part.section))
                }
            }

            let totalParts = partRequests.count
            print("[IMAP] fetchMessagesBatch: \(totalParts) parts to fetch across \(infoByUID.count) messages")

            // 4. Pipelined fetch — all parts in one burst.
            //    PayloadTooLarge contaminates the NIO connection (unfulfilled promises crash
            //    on dealloc), so we do NOT retry here. Instead, throw to the queue which
            //    handles halving with a fresh connection on each retry.
            let tParts = CFAbsoluteTimeGetCurrent()
            let pipelinedResults: [UID: [(section: Section, data: Data)]]
            if !partRequests.isEmpty {
                pipelinedResults = try await server.fetchPartsPipelined(parts: partRequests)
            } else {
                pipelinedResults = [:]
            }

            let partsMs = Int((CFAbsoluteTimeGetCurrent() - tParts) * 1000)
            print("[IMAP] fetchMessagesBatch PARTS PIPELINED: \(pipelinedResults.count) UIDs returned in \(partsMs)ms")

            // 5. Assemble Message objects from BODYSTRUCTURE + fetched part data
            var results: [String: FullMessageInfo] = [:]
            var fetchedCount = 0
            var failedCount = 0

            for (uidValue, entry) in infoByUID {
                let uid = UID(uidValue)
                guard var parts = partsByUID[uidValue] else { continue }

                // Populate part data from pipelined results
                let fetchedParts = pipelinedResults[uid] ?? []
                var fetchedBySection: [String: Data] = [:]
                for (section, data) in fetchedParts {
                    fetchedBySection[section.description] = data
                }

                for i in 0..<parts.count {
                    if let data = fetchedBySection[parts[i].section.description] {
                        parts[i].data = data
                    }
                }

                let message = Message(header: entry.info, parts: parts)
                // Skip entries where the header can't be parsed (date parse failure).
                // Caller sees the entry missing from results and treats as fetch failure.
                guard let fullInfo = self.buildFullMessageInfo(info: entry.info, message: message) else {
                    failedCount += 1
                    continue
                }
                // Data-integrity guard (CLAUDE.md rule #1 — never cache unfetched content).
                // A top-level text/html section listed in BODYSTRUCTURE was NOT returned
                // by the pipelined fetch (its section is absent from `fetchedBySection`) —
                // i.e. the HTML content was silently DROPPED under NIO buffer pressure.
                // Rendering would fall back to the text/plain part — an HTML email FALSELY
                // shown as plaintext — frozen by MessageBody.create's onConflict:.ignore
                // until a manual pull-to-refresh. THROW so the body queue retries the batch
                // on a fresh connection (same policy as PayloadTooLargeError). We must NOT
                // omit the message from `results`: BackfillBodyQueue treats
                // "missing from result" as confirmed-gone and can DELETE the header.
                //
                // We key on the section being ABSENT (a true drop), NOT on htmlBody being
                // empty — a genuinely-empty top-level text/html part (section returned but
                // empty/whitespace, as some mailing lists emit alongside a real text/plain)
                // must render as plaintext and cache normally, else the batch would retry
                // that message forever. Single-message fetch self-heals dropped parts.
                if IMAPFetchMapping.hasDroppedTopLevelHTMLSection(
                    info: entry.info, fetchedSections: Set(fetchedBySection.keys)
                ) {
                    print("[IMAP] fetchMessagesBatch: UID \(uidValue) — top-level text/html section dropped by pipelined fetch; failing batch for retry (not caching HTML as plaintext)")
                    throw NSError(
                        domain: "IMAPProvider.IncompleteBodyFetch", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "top-level text/html section dropped after pipelined fetch for UID \(uidValue)"]
                    )
                }
                results[entry.id] = fullInfo
                fetchedCount += 1
            }

            // Check for UIDs that were in our request but not in BODYSTRUCTURE response
            for (_, uidValue) in uidPairs {
                if infoByUID[uidValue] == nil {
                    print("[IMAP] fetchMessagesBatch: UID \(uidValue) not in BODYSTRUCTURE — skipping")
                    failedCount += 1
                }
            }

            let totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("[IMAP] fetchMessagesBatch DONE: \(fetchedCount) fetched, \(failedCount) failed in \(totalMs)ms (select=\(selectMs)ms, struct=\(structMs)ms, parts=\(partsMs)ms)")
            return results
        }
    }

    func search(query: String, folder: String, after: Date? = nil, before: Date? = nil, from: String? = nil, to: String? = nil) async throws -> [MessageHeaderInfo] {
        try await withActionConnection(folder: folder) { server in
            try await self.searchOnConnection(query: query, folder: folder, after: after, before: before, from: from, to: to, server: server)
        }
    }

    private func searchOnConnection(query: String, folder: String, after: Date? = nil, before: Date? = nil, from: String? = nil, to: String? = nil, server: IMAPServer) async throws -> [MessageHeaderInfo] {
        _ = try await server.selectMailbox(folder)
        var criteria: [SearchCriteria] = []
        if !query.isEmpty { criteria.append(.text(query)) }
        if let after { criteria.append(.since(after)) }
        if let before { criteria.append(.before(before)) }
        if let from, !from.isEmpty { criteria.append(.from(from)) }
        if let to, !to.isEmpty { criteria.append(.to(to)) }
        guard !criteria.isEmpty else { return [] }

        let results: UIDSet
        do {
            let extResult: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: criteria, calendar: Self.utcCalendar)
            results = extResult.asSet
        } catch {
            let desc = "\(error)"
            if desc.contains("PayloadTooLargeError") && after == nil {
                print("[IMAP Search] SEARCH too large, retrying with 1-year constraint")
                let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date.distantPast
                return try await searchOnConnection(query: query, folder: folder, after: oneYearAgo, before: before, from: from, to: to, server: server)
            }
            throw error
        }
        guard !results.isEmpty else { return [] }

        let infos = try await server.fetchMessageInfosBulk(using: results)
        return infos.compactMap { mapMessageInfo($0) }
    }

    func markRead(ids: [String], folder: String) async throws {
        try await mutateActionMessages(
            ids: ids, folder: folder, flags: [.seen], operation: .add
        )
    }

    func markUnread(ids: [String], folder: String) async throws {
        try await mutateActionMessages(
            ids: ids, folder: folder, flags: [.seen], operation: .remove
        )
    }

    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {
        try await mutateActionMessages(
            ids: ids,
            folder: folder,
            flags: [.flagged],
            operation: flagged ? .add : .remove
        )
    }

    /// Set \Answered flag on IMAP messages (called after sending a reply).
    func markReplied(ids: [String], folder: String) async throws {
        try await mutateActionMessages(
            ids: ids, folder: folder, flags: [.answered], operation: .add
        )
    }

    /// Set $Forwarded keyword on IMAP messages (called after forwarding).
    func markForwarded(ids: [String], folder: String) async throws {
        try await mutateActionMessages(
            ids: ids,
            folder: folder,
            flags: [.custom("$Forwarded")],
            operation: .add
        )
    }

    /// Action tags are local-only (see ADR-IOS-036). No IMAP STORE.
    func setActionTag(messageId: String, tag: ActionTag?, folder: String) async throws {
        _ = messageId
        _ = tag
        _ = folder
    }

    /// Add or remove a user label (IMAP custom keyword) on a message.
    func setUserLabel(messageId: String, keyword: String, add: Bool, folder: String) async throws {
        try await mutateActionMessages(
            ids: [messageId],
            folder: folder,
            flags: [.custom(keyword)],
            operation: add ? .add : .remove
        )
    }

    func setUserLabel(ids: [String], labelId: String, present: Bool, folder: String) async throws {
        try await mutateActionMessages(
            ids: ids,
            folder: folder,
            flags: [.custom(labelId)],
            operation: present ? .add : .remove
        )
    }

    func move(ids: [String], from source: String, to destination: String) async throws {
        if DebugModeManager.isLoggingEnabled() {
            print("[MoveTrace] IMAPProvider.move — ids=\(ids) source=\(source) dest=\(destination)")
        }
        do {
            try await withActionConnection(folder: source) { server in
                _ = try await server.selectMailbox(source)
                let messages = try await self.resolveActionMessages(ids, server: server)
                do {
                    _ = try await server.selectMailbox(destination)
                } catch {
                    guard await self.mailboxConfirmedAbsent(destination, server: server) else {
                        throw error
                    }
                    // Destination confirmed gone — Law 4: a deleted
                    // destination folder is stale. The whole move is a
                    // no-op; the message(s) remain untouched in `source`.
                    if DebugModeManager.isLoggingEnabled() {
                        print("[MoveTrace] IMAPProvider.move — destination '\(destination)' confirmed absent — whole-op no-op")
                    }
                    throw IMAPActionMailboxAbsent()
                }
                var plans: [(ResolvedActionMessage, ActionUIDResolution)] = []
                for message in messages {
                    let destinationResolution = try await self.resolveActionMessage(
                        message.rfc822MessageId,
                        server: server
                    )
                    plans.append((message, destinationResolution))
                }
                for (message, destinationResolution) in plans {
                    try await self.idempotentMove(
                        message: message,
                        destinationResolution: destinationResolution,
                        from: source,
                        to: destination,
                        server: server
                    )
                }
            }
        } catch is IMAPActionMailboxAbsent {
            // Source or destination confirmed gone (Law 4: authoritative
            // stale no-op) — nothing left to do.
        }
    }

    /// Idempotent per-message move. Costs extra SEARCH round-trips but eliminates
    /// the retry-after-partial-failure duplicate class:
    ///
    /// SwiftMail's fallback path (COPY + STORE \Deleted + UID EXPUNGE) is not
    /// atomic. If COPY succeeds and either STORE or EXPUNGE fails, the op stays
    /// `queued` — but no marker is recorded for the partial-copy state. A retry
    /// would re-run COPY from scratch and leave two copies in the destination.
    /// Two copies with the same Message-ID trip the push server's move-detection,
    /// which fires a phantom "new mail" notification.
    ///
    /// Strategy: always probe the destination for the rfc822 Message-ID before
    /// calling `server.move`. If the destination already has it, a prior attempt
    /// COPIED successfully — skip COPY and just finish the source-side cleanup.
    /// Verify the destination has the message after the operation; throw otherwise
    /// so the op stays queued for another (idempotent) retry.
    ///
    private func idempotentMove(
        message: ResolvedActionMessage,
        destinationResolution: ActionUIDResolution,
        from source: String,
        to destination: String,
        server: IMAPServer
    ) async throws {
        let id = message.rfc822MessageId
        let srcUIDs = UIDSet(message.uid)

        switch destinationResolution {
        case .ambiguous:
            if DebugModeManager.isLoggingEnabled() {
                print("[MoveTrace] IMAPProvider.move — \(id): destination ambiguous, skip")
            }
            return
        case .exact:
            if DebugModeManager.isLoggingEnabled() {
                print("[MoveTrace] IMAPProvider.move — \(id): destination already contains exact match; clean source")
            }
            _ = try await server.selectMailbox(source)
            try await deleteActionSource(srcUIDs, server: server)
            return
        case .missing:
            break
        }

        _ = try await server.selectMailbox(source)

        // Legacy-label decay (ADR-IOS-036): on inbox-exit, strip any residual
        // tm_* keywords from the source UID(s) before the MOVE. Keywords
        // follow the message to the destination, so stripping beforehand
        // leaves the moved copy clean. Best-effort — a STORE failure must
        // NOT block the move itself.
        if source.uppercased() == "INBOX" {
            let legacyFlags: [Flag] = [
                .custom("tm_reply"), .custom("tm_archive"),
                .custom("tm_delete"), .custom("tm_none"),
            ]
            do {
                try await server.store(flags: legacyFlags, on: srcUIDs, operation: .remove)
            } catch {
                print("[IMAP] Legacy tm_* strip failed for \(id) (continuing): \(error)")
            }
        }

        try await server.move(messages: srcUIDs, to: destination)

        // Post-verify: confirm destination has the message by rfc822. If verification
        // fails (e.g. atomic MOVE silently dropped, or fallback partial failure we didn't
        // catch), throw so the op stays queued for retry — the next pass's probe will
        // handle the partial state idempotently.
        _ = try await server.selectMailbox(destination)
        let destinationAfterMove = try await resolveActionMessage(id, server: server)
        if case .missing = destinationAfterMove {
            if DebugModeManager.isLoggingEnabled() {
                print("[MoveTrace] IMAPProvider.move — \(id): VERIFY FAILED (not in dst after move) — will retry")
            }
            throw ProviderError.actionIdentityResolutionFailed(id)
        }
        if DebugModeManager.isLoggingEnabled() {
            print("[MoveTrace] IMAPProvider.move — \(id): completed")
        }
    }

    private func deleteActionSource(_ sourceUIDs: UIDSet, server: IMAPServer) async throws {
        try await server.store(flags: [.deleted], on: sourceUIDs, operation: .add)
        if await server.supportsUIDPlus {
            try await server.expunge(messages: sourceUIDs)
        } else {
            try await server.expunge()
        }
    }

    /// Check if a message exists in a folder by rfc822 Message-ID.
    /// Returns true if found, false if confirmed not found. Throws on connection error.
    func messageExistsInFolder(rfc822MessageId: String, folderPath: String) async throws -> Bool {
        let uids = try await currentUIDs(rfc822MessageId: rfc822MessageId, folderPath: folderPath)
        return !uids.isEmpty
    }

    /// Resolve the current UID(s) for an rfc822 Message-ID.
    /// Uses the same SEARCH as `messageExistsInFolder`, but returns the UIDs so the backfill
    /// body queue can re-key a UID-remapped header instead of retrying a dead UID.
    func currentUIDs(rfc822MessageId: String, folderPath: String) async throws -> [String] {
        try await withFolderConnection(folder: folderPath) { server in
            _ = try await server.selectMailbox(folderPath)
            let results = try await self.searchByMessageId(rfc822MessageId, server: server)
            return results.toArray().map { "\($0.value)" }
        }
    }

    /// Fetch a single attachment's data by MIME section.
    func fetchAttachment(messageId: String, folder: String, section: String, encoding: String?) async throws -> Data {
        // Compound path: attachment nested inside a file-uploaded `.eml`.
        // Re-fetch parent `.eml` bytes, parse, return the nth nested payload.
        // One extra IMAP fetch per tap — the parse happens in-process.
        if let nested = EmlParsing.parseNestedSection(section) {
            let parentBytes = try await fetchAttachment(
                messageId: messageId, folder: folder, section: nested.parent, encoding: encoding
            )
            guard let bytes = EmlParsing.nestedBytes(rawBytes: parentBytes, index: nested.index) else {
                throw ProviderError.messageNotFound
            }
            return bytes
        }

        return try await withActionConnection(folder: folder) { server in
            _ = try await server.selectMailbox(folder)

            let results = try await self.resolveUID(messageId, server: server)
            guard let uid = results.toArray().first else { throw ProviderError.messageNotFound }

            let mimeSection = Section(section)
            let rawData = try await server.fetchPart(section: mimeSection, of: uid)

            let part = MessagePart(section: mimeSection, contentType: "", encoding: encoding)
            return rawData.decoded(for: part)
        }
    }

    func send(draft: DraftMessage) async throws {
        try await withTimeout(seconds: SyncConfig.smtpSendTimeoutSeconds) {
            print("[SMTP] Sending via \(self.smtpHost):\(self.smtpPort) from=\(self.senderEmail) to=\(draft.to) attachments=\(draft.attachments.count)")
            let smtpServer = SMTPServer(host: self.smtpHost, port: self.smtpPort)
            try await smtpServer.connect()
            try await smtpServer.login(username: self.username, password: self.password)

            let email = Self.buildEmail(from: draft, senderEmail: self.senderEmail)

            do {
                try await smtpServer.sendEmail(email)
            } catch {
                if !(error is CancellationError) && !SyncEngine.isConnectionError(error) {
                    BackgroundSyncLogger.logError("SMTP send failed: \(error)", source: "outbox:\(self.senderEmail)")
                }
                // Best-effort disconnect before rethrowing
                try? await smtpServer.disconnect()
                throw error
            }
            // Email is sent — disconnect is cleanup, must not throw
            try? await smtpServer.disconnect()
            print("[SMTP] Send complete")
        }
    }

    /// Append a sent message to the IMAP Sent folder. Dedup-safe: searches by Message-ID
    /// before appending so retries after crash/disconnect don't create duplicates.
    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool {
        let senderAddr = senderEmail
        return try await withActionConnection(folder: sentFolderPath) { server in
            let existing = try await self.searchByMessageId(messageId, server: server)
            if !existing.isEmpty {
                print("[IMAP] Sent message \(messageId) already exists in \(sentFolderPath) — skipping append")
                return true
            }

            let email = Self.buildEmail(from: draft, senderEmail: senderAddr)
            _ = try await server.append(email: email, to: sentFolderPath, flags: [.seen], internalDate: Date())
            print("[IMAP] Appended sent message \(messageId) to \(sentFolderPath)")
            return true
        }
    }

    // MARK: - Drafts

    func saveDraft(_ draft: DraftMessage, existingDraftId: String?, draftsFolderPath: String) async throws -> DraftSaveResult {
        // Guard: Message-ID is required for IMAP draft tracking (find UID after APPEND).
        // DraftStore.pushDraftToServer generates rfc822MessageId before calling this.
        guard let messageId = draft.messageId, !messageId.isEmpty else {
            print("[IMAP] saveDraft: no messageId — cannot track draft UID reliably")
            throw NSError(domain: "IMAPProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Draft must have a Message-ID for IMAP tracking"])
        }

        let senderAddr = senderEmail
        return try await withActionConnection(folder: draftsFolderPath) { server in
            // Delete existing draft by UID if updating.
            // If existingDraftId is non-numeric (e.g., UID changed), fall back to Message-ID search.
            if let existingId = existingDraftId {
                if let uid = UInt32(existingId) {
                    let uidSet = MessageIdentifierSet<UID>(UID(uid))
                    try? await server.store(flags: [.deleted], on: uidSet, operation: .add)
                    try? await server.expunge()
                } else {
                    // Stale UID — try finding by Message-ID (rfc822MessageId survives UID changes)
                    let found = try await self.searchByMessageId(messageId, server: server)
                    if !found.isEmpty {
                        try? await server.store(flags: [.deleted], on: found, operation: .add)
                        try? await server.expunge()
                        print("[IMAP] Deleted stale draft by Message-ID search (existingDraftId=\(existingId) was non-numeric)")
                    }
                }
            }

            // APPEND new draft with \Draft + \Seen flags (drafts are never "unread")
            let email = Self.buildEmail(from: draft, senderEmail: senderAddr)
            _ = try await server.append(email: email, to: draftsFolderPath, flags: [.draft, .seen], internalDate: Date())

            // Find the appended UID by searching for the Message-ID
            let found = try await self.searchByMessageId(messageId, server: server)
            if !found.isEmpty {
                for range in found.ranges {
                    let uid = range.lowerBound
                    print("[IMAP] Saved draft to \(draftsFolderPath), uid=\(uid)")
                    return DraftSaveResult(serverId: String(uid))
                }
            }
            // Should not happen if APPEND succeeded — log warning
            print("[IMAP] WARNING: Saved draft to \(draftsFolderPath) but could not find UID by Message-ID \(messageId)")
            return DraftSaveResult(serverId: "unknown")
        }
    }

    func deleteDraft(draftId: String, draftsFolderPath: String) async throws {
        do {
            try await withActionConnection(folder: draftsFolderPath) { server in
                let uidSet = try await resolveUID(draftId, server: server)
                try await server.store(flags: [.deleted], on: uidSet, operation: .add)
                try await server.expunge()
                print("[IMAP] Deleted draft \(draftId) from \(draftsFolderPath)")
            }
        } catch ProviderError.uidResolutionFailed {
            // Non-numeric draftId (stale UID) resolved via Message-ID
            // SEARCH, which completed successfully and found no match: the
            // draft is authoritatively absent (already deleted server-side,
            // or never existed under this identity). Law 4 terminal no-op —
            // a FAILED search throws a different, unclassified error above
            // and still retries.
            print("[IMAP] deleteDraft: draft \(draftId) — Message-ID search confirmed absent, treating as already deleted")
        }
    }

    /// Build an Email object from a DraftMessage. Shared between send() and appendToSentFolder().
    static func buildEmail(from draft: DraftMessage, senderEmail: String) -> Email {
        let smtpAttachments: [Attachment]? = draft.attachments.isEmpty ? nil : draft.attachments.map {
            Attachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
        var email = Email(
            sender: SwiftMail.EmailAddress(address: senderEmail),
            recipients: draft.to.map { SwiftMail.EmailAddress(address: $0) },
            ccRecipients: draft.cc.map { SwiftMail.EmailAddress(address: $0) },
            subject: draft.subject,
            textBody: draft.isHTML ? EmailFilter.htmlToPlainText(draft.body) : draft.body,
            htmlBody: draft.isHTML ? draft.body : nil,
            attachments: smtpAttachments
        )
        // Set pre-generated Message-ID (first-class property on Email)
        if let messageId = draft.messageId {
            email.messageID = MessageID(messageId)
        }
        // Set threading headers (RFC 2822 requires angle brackets around message IDs)
        var headers: [String: String] = [:]
        if let inReplyTo = draft.inReplyTo, !inReplyTo.isEmpty {
            headers["In-Reply-To"] = inReplyTo.hasPrefix("<") ? inReplyTo : "<\(inReplyTo)>"
        }
        if !draft.references.isEmpty {
            headers["References"] = draft.references.map { $0.hasPrefix("<") ? $0 : "<\($0)>" }.joined(separator: " ")
        }
        if !headers.isEmpty {
            email.additionalHeaders = headers
        }
        return email
    }

    // MARK: - Incremental Sync

    /// Flush pending server-side state before STATUS checks.
    /// SELECT INBOX + NOOP forces the server to refresh its mailbox state.
    /// Plain NOOP alone is insufficient on some servers (they only flush the
    /// currently-SELECTed mailbox). SELECT is the most reliable way to force
    /// the server to report current state for subsequent STATUS commands.
    /// Acquires lock because SELECT changes the server's selected mailbox —
    /// without it, actor reentrancy could corrupt a concurrent operation's
    /// selected-mailbox state (e.g., fetchMessage SELECTs "Sent", then
    /// flushServerState SELECTs "INBOX" at an await point, then fetchMessage
    /// resumes and FETCHes from INBOX instead of Sent).
    func flushServerState() async throws {
        try await withFolderConnection(folder: "INBOX") { server in
            _ = try await server.selectMailbox("INBOX")
            _ = try await server.noop()
        }
    }

    /// Quick STATUS check for delta sync — returns folder stats without SELECT.
    /// Compares against stored values to detect new messages, deletions, or flag changes.
    func folderStatus(path: String) async throws -> IMAPFolderStatus {
        try await withActionConnectionNoSelect { server in
            let status = try await server.mailboxStatus(path)
            return IMAPFolderStatus(
                messageCount: status.messageCount ?? 0,
                uidNext: status.uidNext.map { Int($0.value) } ?? 0,
                unreadCount: status.unseenCount ?? 0,
                // Non-nil only when the server advertised CONDSTORE / UIDPLUS
                // (SwiftMail conditionally requests these STATUS attributes).
                highestModSeq: status.highestModSequence,
                uidValidity: status.uidValidity.map { Int($0.value) }
            )
        }
    }

    func fetchHistory(since historyId: String) async throws -> HistoryResponse? {
        // IMAP doesn't have a history API like Gmail.
        // Return nil to signal SyncEngine should use full sync.
        return nil
    }

    func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] {
        // Not used for IMAP (no incremental sync path yet)
        return []
    }

    // MARK: - Batch Body Fetch (FTS)

    /// Result of a batch text body fetch for a single message.
    struct TextBodyResult: Sendable {
        let uid: UInt32
        let htmlBody: String?
        let textBody: String?
    }

    func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] {
        let uids = ids.compactMap { UInt32($0) }
        guard !uids.isEmpty else { return [] }
        // Split into sub-batches fetched via folder-pinned connection.
        // All sub-batches go through the same pinned connection for this folder.
        let batchSize = BackfillProfile.normal.imapBodyFetchBatchSize
        let subBatches: [[UInt32]] = stride(from: 0, to: uids.count, by: batchSize).map { i in
            Array(uids[i..<min(i + batchSize, uids.count)])
        }

        return try await withThrowingTaskGroup(of: [TextBodyResult].self) { group in
            for subBatch in subBatches {
                group.addTask {
                    try await self.fetchTextBodiesBatch(folder: folder, uids: subBatch, batchSize: batchSize)
                }
            }
            var allResults: [TextBodyFetchResult] = []
            for try await batchResults in group {
                for r in batchResults {
                    allResults.append(TextBodyFetchResult(id: "\(r.uid)", htmlBody: r.htmlBody, textBody: r.textBody, error: nil))
                }
            }
            return allResults
        }
    }

    /// Batch fetch text bodies for FTS indexing. Each batch checks out a pool connection.
    /// Only fetches text/plain and text/html MIME parts — skips attachments entirely.
    /// Uses bulk BODYSTRUCTURE fetch to avoid redundant per-message structure queries.
    ///
    /// Connection is checked out per-batch (not for the entire call) so user actions
    /// can use other pool connections between batches.
    private func fetchTextBodiesBatch(
        folder: String,
        uids: [UInt32],
        batchSize: Int
    ) async throws -> [TextBodyResult] {
        guard !uids.isEmpty else { return [] }

        var results: [TextBodyResult] = []
        // Mutable chunk size — halved on PayloadTooLargeError, same as backfill walk
        var currentBatchSize = batchSize
        var index = 0

        while index < uids.count {
            try Task.checkCancellation()
            let batchEnd = min(index + currentBatchSize, uids.count)
            let batchUIDs = Array(uids[index..<batchEnd])

            let batchResults = try await fetchTextBodiesChunk(
                folder: folder, batchUIDs: batchUIDs
            )

            if let batchResults {
                // Success — advance past this chunk
                results.append(contentsOf: batchResults)
                index = batchEnd
                // Brief yield between batches
                if index < uids.count {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } else {
                // PayloadTooLargeError — halve chunk size and retry same index
                // Connection is contaminated, pool will discard it on next checkout
                if currentBatchSize <= 1 {
                    // Single UID still too large — return empty result so caller can confirm empty
                    let uid = batchUIDs.first ?? 0
                    print("[IMAP] Single UID \(uid) too large — marking as empty")
                    results.append(TextBodyResult(uid: uid, htmlBody: nil, textBody: nil))
                    index += 1
                } else {
                    currentBatchSize = max(1, currentBatchSize / 2)
                    print("[IMAP] Batch too large, reducing chunk to \(currentBatchSize)")
                }
            }
        }

        return results
    }

    /// Fetch text bodies for a single chunk. Returns nil on PayloadTooLargeError (caller should retry with smaller chunk).
    private func fetchTextBodiesChunk(
        folder: String,
        batchUIDs: [UInt32]
    ) async throws -> [TextBodyResult]? {
        var uidSet = UIDSet()
        for uid in batchUIDs { uidSet.insert(UID(uid)) }

        let capturedUidSet = uidSet
        return try await withFolderConnection(folder: folder) { server in
            try await withTimeout(seconds: SyncConfig.imapBatchOperationTimeoutSeconds) {
                _ = try await server.selectMailbox(folder)

                let infos: [MessageInfo]
                do {
                    infos = try await server.fetchMessageInfosBulk(using: capturedUidSet)
                } catch {
                    let desc = "\(error)"
                    if desc.contains("PayloadTooLargeError") {
                        return nil  // Signal caller to split and retry
                    }
                    throw error
                }

                var batch: [TextBodyResult] = []
                var connectionDead = false

                for info in infos {
                    guard let uid = info.uid else { continue }
                    if connectionDead { break }

                    let textParts = info.parts.filter { part in
                        let ct = part.contentType.lowercased()
                        return (ct.hasPrefix("text/plain") || ct.hasPrefix("text/html"))
                            && part.disposition?.lowercased() != "attachment"
                    }

                    var textBody: String?
                    var htmlBody: String?

                    for part in textParts {
                        do {
                            let data = try await server.fetchPart(section: part.section, of: uid)
                            var populated = part
                            populated.data = data
                            if part.contentType.lowercased().hasPrefix("text/plain"), textBody == nil {
                                textBody = populated.textContent
                            } else if part.contentType.lowercased().hasPrefix("text/html"), htmlBody == nil {
                                htmlBody = populated.textContent
                            }
                        } catch {
                            print("[IMAP] Failed to fetch part \(part.section) for UID \(uid.value): \(error)")
                            if SyncEngine.isConnectionError(error) {
                                print("[IMAP] Connection dead during batch — aborting remaining fetches")
                                connectionDead = true
                                break
                            }
                        }
                    }

                    batch.append(TextBodyResult(uid: uid.value, htmlBody: htmlBody, textBody: textBody))
                }
                return batch
            }
        }
    }

    // MARK: - UID Range Backfill

    /// Get UIDNEXT for a folder via SELECT. Returns the next UID the server will assign.
    /// Returns 0 if server doesn't provide UIDNEXT (shouldn't happen per RFC 3501).
    func getUidNext(folder: String) async throws -> Int {
        try await withFolderConnection(folder: folder) { server in
            let selection = try await server.selectMailbox(folder)
            return Int(selection.uidNext.value)
        }
    }

    /// Discover which UIDs actually exist in a UID range using UID SEARCH.
    /// Caller should use the same chunk size as FETCH (e.g., 500 UIDs) so the
    /// SEARCH response is always small (~3.5KB max) and never overflows.
    /// For sparse ranges, returns empty → caller skips FETCH entirely.
    func searchExistingUIDs(folder: String, from: Int, to: Int) async throws -> [UInt32] {
        guard from >= 1, to >= from else { return [] }
        try Task.checkCancellation()

        return try await withFolderConnection(folder: folder) { server in
            let _ = try await server.selectMailbox(folder)
            var searchSet = MessageIdentifierSet<UID>()
            searchSet.insert(range: Int(from)...Int(to))
            let extResult: ExtendedSearchResult<UID> = try await server.extendedSearch(
                identifierSet: searchSet, criteria: [.all]
            )
            return extResult.asSet.toArray().map { UInt32($0.value) }
        }
    }

    /// Check which of an EXPLICIT set of UIDs still exist in a folder via
    /// `UID SEARCH UID <set>` (deletion reconcile, ADR-IOS-051). Unlike the
    /// range variant above, the response can only ever name UIDs from the
    /// queried set, so with chunks of `SyncConfig.deletionReconcileChunkSize`
    /// both the command and the response stay far below the 1MB NIO buffer
    /// limit even in dense folders. Also returns the SELECT's UIDVALIDITY so
    /// the caller can abort when the folder's UID numbering was invalidated
    /// (a UIDVALIDITY change makes every local UID meaningless — deleting on
    /// a "not found" result would then be unsafe).
    func searchExistingUIDs(folder: String, uids: [UInt32]) async throws -> UIDExistenceResult {
        guard !uids.isEmpty else { return UIDExistenceResult(found: [], uidValidity: 0) }
        try Task.checkCancellation()

        return try await withFolderConnection(folder: folder) { server in
            let selection = try await server.selectMailbox(folder)
            var searchSet = UIDSet()
            for uid in uids { searchSet.insert(UID(uid)) }
            let extResult: ExtendedSearchResult<UID> = try await server.extendedSearch(
                identifierSet: searchSet, criteria: [.all]
            )
            return UIDExistenceResult(
                found: Set(extResult.asSet.toArray().map { UInt32($0.value) }),
                uidValidity: selection.uidValidity.value
            )
        }
    }

    /// Fetch message headers for a UID range (from...to inclusive).
    /// Creates a UIDSet from the range and fetches in sub-batches with per-batch lock.
    /// Server returns only UIDs that exist — gaps (deleted messages) are silently skipped.
    func fetchUIDRange(
        folder: String,
        from: Int,
        to: Int,
        batchSize: Int,
        interBatchDelay: TimeInterval = 0.5
    ) async throws -> [MessageHeaderInfo] {
        guard from >= 1, to >= from else { return [] }

        // Build flat UID array from the range, then delegate to fetchMessageHeaders
        // which handles per-batch locking and SELECT.
        let uids = (UInt32(from)...UInt32(to)).map { $0 }
        return try await fetchMessageHeaders(
            folder: folder, uids: Array(uids),
            batchSize: batchSize, interBatchDelay: interBatchDelay
        )
    }

    // MARK: - Backfill (Date-Based, used by fetchOlderMessages / self-heal)

    /// Shared SEARCH helper: finds UIDs in a date range, binary-splitting on PayloadTooLargeError.
    /// Must be called with a checked-out server connection.
    /// Re-selects the folder before each SEARCH to guard against state corruption from splits.
    private func searchDateRange(
        folder: String,
        since: Date,
        before: Date,
        server: IMAPServer
    ) async throws -> [UID] {
        _ = try await server.selectMailbox(folder)

        let results: UIDSet
        do {
            let extResult: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [.since(since), .before(before)], calendar: Self.utcCalendar)
            results = extResult.asSet
        } catch {
            let desc = "\(error)"
            if desc.contains("PayloadTooLargeError") {
                let totalSeconds = before.timeIntervalSince(since)
                guard totalSeconds > 86400 else {
                    // Can't split further — IMAP SINCE/BEFORE uses date-only granularity.
                    // Re-throw so callers can handle (skip folder, shrink window, etc.)
                    // rather than silently dropping all messages in this range.
                    print("[IMAP Search] \(folder): PayloadTooLargeError on single day \(since) — cannot split further, propagating error")
                    throw error
                }
                let midpoint = since.addingTimeInterval(totalSeconds / 2)
                print("[IMAP Search] \(folder): SEARCH too large, splitting at \(midpoint)")
                let firstHalf = try await searchDateRange(folder: folder, since: since, before: midpoint, server: server)
                try Task.checkCancellation()
                let secondHalf = try await searchDateRange(folder: folder, since: midpoint, before: before, server: server)
                return firstHalf + secondHalf
            }
            throw error
        }
        return results.toArray()
    }

    /// SEARCH phase for backfill: find all UIDs in a date range.
    /// Delegates to searchDateRange for binary-split PayloadTooLargeError handling.
    /// Returns lightweight UID values — no message content fetched.
    /// When `since` is nil, searches all messages before `before` (unbounded start).
    func searchBackfillUIDs(
        folder: String,
        since: Date?,
        before: Date? = nil
    ) async throws -> [UInt32] {
        try await withFolderConnection(folder: folder) { server in
            let end = before ?? Date()
            if let since {
                let uids = try await self.searchDateRange(folder: folder, since: since, before: end, server: server)
                return uids.map(\.value)
            } else {
                let uids = try await self.searchBeforeOnly(folder: folder, before: end, server: server)
                return uids.map(\.value)
            }
        }
    }

    /// SEARCH with only BEFORE criterion — finds all messages older than `before`.
    /// Used as final fallback when windowed search exhausts without finding messages.
    private func searchBeforeOnly(folder: String, before: Date, server: IMAPServer) async throws -> [UID] {
        _ = try await server.selectMailbox(folder)
        do {
            let extResult: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [.before(before)], calendar: Self.utcCalendar)
            return extResult.asSet.toArray()
        } catch {
            let desc = "\(error)"
            if desc.contains("PayloadTooLargeError") {
                let syntheticSince = Calendar(identifier: .gregorian).date(byAdding: .year, value: -30, to: before) ?? Date.distantPast
                return try await searchDateRange(folder: folder, since: syntheticSince, before: before, server: server)
            }
            throw error
        }
    }

    /// FETCH phase: fetch message headers for specific UIDs. No SEARCH involved.
    /// Called after existence checks have filtered to only missing UIDs.
    /// `interBatchDelay` controls throttle between batches (power-aware via BackfillProfile).
    ///
    /// Connection is checked out per-batch so other operations can use the pool
    /// between batches. Each batch re-SELECTs the folder since it gets a fresh connection.
    func fetchMessageHeaders(
        folder: String,
        uids: [UInt32],
        batchSize: Int,
        interBatchDelay: TimeInterval = 0.5
    ) async throws -> [MessageHeaderInfo] {
        guard !uids.isEmpty else { return [] }

        var allHeaders: [MessageHeaderInfo] = []
        var offset = 0
        while offset < uids.count {
            try Task.checkCancellation()

            let end = min(offset + batchSize, uids.count)
            let batch = uids[offset..<end]
            var uidSet = UIDSet()
            for uid in batch {
                uidSet.insert(UID(uid))
            }

            let infos: [SwiftMail.MessageInfo] = try await withFolderConnection(folder: folder) { server in
                _ = try await server.selectMailbox(folder)
                return try await server.fetchMessageInfosBulk(using: uidSet)
            }

            let returnedCount = infos.count
            let requestedCount = batch.count
            if returnedCount < requestedCount {
                let returnedUIDs = Set(infos.compactMap { $0.uid?.value })
                let requestedUIDs = Set(batch)
                let missingUIDs = requestedUIDs.subtracting(returnedUIDs)
                print("[IMAP-FETCH-GAP] \(folder): requested \(requestedCount) UIDs, got \(returnedCount). Missing UIDs: \(missingUIDs.sorted())")
            }

            allHeaders.append(contentsOf: infos.compactMap { mapMessageInfo($0) })

            offset = end
            if offset < uids.count {
                try await Task.sleep(for: .seconds(interBatchDelay))
            }
        }

        return allHeaders
    }

    /// Fetch older messages before a given date for infinite scroll.
    /// Returns up to `limit` messages, newest-first from the older batch.
    /// Widens the search window progressively if no results found.
    /// Delegates SEARCH to searchDateRange which handles PayloadTooLargeError via binary-split.
    func fetchOlderMessages(folder: String, before: Date, limit: Int) async throws -> [MessageHeaderInfo] {
        try await withActionConnection(folder: folder) { server in
            var windowDays = 90
            let maxWindowDays = 365 * 10

            while windowDays <= maxWindowDays {
                let since = Self.utcCalendar.date(byAdding: .day, value: -windowDays, to: before) ?? Date.distantPast

                let allUIDs = try await self.searchDateRange(folder: folder, since: since, before: before, server: server)

                if !allUIDs.isEmpty {
                    let sorted = allUIDs.sorted { $0.value > $1.value }
                    let batch = Array(sorted.prefix(limit))

                    var uidSet = UIDSet()
                    for uid in batch {
                        uidSet.insert(uid)
                    }

                    _ = try await server.selectMailbox(folder)
                    let infos = try await server.fetchMessageInfosBulk(using: uidSet)
                    return infos.compactMap { self.mapMessageInfo($0) }.sorted { $0.date > $1.date }
                }

                windowDays *= 2
            }

            return []
        }
    }

    // MARK: - UID Resolution

    /// Upgrade one released durable row that still carries a mailbox-local UID.
    /// The UID is meaningful only in the recorded source mailbox: a numerically
    /// identical UID in the optimistic destination can name another message and
    /// must never participate in identity conversion.
    func resolveLegacyMessageActionIdentity(
        providerMessageId: String,
        sourceFolder: String,
        destinationFolder: String?
    ) async throws -> LegacyMessageActionIdentityResolution {
        _ = destinationFolder
        let trimmedSourceFolder = sourceFolder.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedSourceFolder.isEmpty,
              sourceFolder.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw ProviderError.actionIdentityResolutionFailed(providerMessageId)
        }
        guard let uidValue = UInt32(providerMessageId),
              uidValue > 0,
              providerMessageId == String(uidValue)
        else {
            return .staleOrAmbiguous
        }

        return try await withActionConnection(folder: sourceFolder) { server in
            let infos = try await server.fetchMessageInfosBulk(
                using: UIDSet(UID(uidValue)),
                options: [.envelope]
            )
            guard !infos.isEmpty else { return .staleOrAmbiguous }
            guard infos.count == 1,
                  let info = infos.first,
                  info.uid?.value == uidValue
            else {
                throw ProviderError.actionIdentityResolutionFailed(providerMessageId)
            }
            guard let rfc822MessageId = MessageIdentity.durableActionRFC822MessageId(
                IMAPFetchMapping.rfc822MessageId(from: info)
            ) else {
                return .staleOrAmbiguous
            }
            return .resolved(rfc822MessageId: rfc822MessageId)
        }
    }

    private enum ActionUIDResolution {
        case missing
        case ambiguous
        case exact(UID)
    }

    private struct ResolvedActionMessage {
        let rfc822MessageId: String
        let uid: UID
    }

    private enum ActionFlagOperation: Sendable {
        case add
        case remove
    }

    /// Resolve a durable RFC identity inside the currently selected mailbox.
    /// IMAP HEADER SEARCH may return substring matches, so every candidate is
    /// fetched and compared exactly before it is allowed to mutate anything.
    private func resolveActionMessage(
        _ rawRFC822MessageId: String,
        server: IMAPServer
    ) async throws -> ActionUIDResolution {
        guard let rfc822MessageId = MessageIdentity.durableActionRFC822MessageId(
            rawRFC822MessageId
        ) else { return .missing }

        let hits = try await searchByMessageId(rfc822MessageId, server: server)
        guard !hits.isEmpty else { return .missing }

        let hitValues = Set(hits.toArray().map(\.value))
        let infos = try await server.fetchMessageInfosBulk(using: hits)
        guard infos.count == hitValues.count else {
            throw ProviderError.actionIdentityResolutionFailed(rfc822MessageId)
        }

        var fetchedUIDs = Set<UInt32>()
        var exactUIDs: [UID] = []
        for info in infos {
            guard let uid = info.uid,
                  hitValues.contains(uid.value),
                  fetchedUIDs.insert(uid.value).inserted,
                  let returnedRFC822MessageId = MessageIdentity.durableActionRFC822MessageId(
                      IMAPFetchMapping.rfc822MessageId(from: info)
                  )
            else {
                throw ProviderError.actionIdentityResolutionFailed(rfc822MessageId)
            }
            if returnedRFC822MessageId == rfc822MessageId {
                exactUIDs.append(uid)
            }
        }

        switch exactUIDs.count {
        case 0: return .missing
        case 1: return .exact(exactUIDs[0])
        default: return .ambiguous
        }
    }

    /// Resolve the whole batch before its first mutation. Missing or ambiguous
    /// messages are stale no-ops; transport/verification failures abort the batch.
    private func resolveActionMessages(
        _ ids: [String],
        server: IMAPServer
    ) async throws -> [ResolvedActionMessage] {
        var resolved: [ResolvedActionMessage] = []
        var seenUIDs = Set<UInt32>()
        for id in ids {
            guard let rfc822MessageId = MessageIdentity.durableActionRFC822MessageId(id),
                  case .exact(let uid) = try await resolveActionMessage(id, server: server),
                  seenUIDs.insert(uid.value).inserted
            else { continue }
            resolved.append(
                ResolvedActionMessage(rfc822MessageId: rfc822MessageId, uid: uid)
            )
        }
        return resolved
    }

    private func mutateActionMessages(
        ids: [String],
        folder: String,
        flags: [Flag],
        operation: ActionFlagOperation
    ) async throws {
        do {
            try await withActionConnection(folder: folder) { server in
                _ = try await server.selectMailbox(folder)
                let messages = try await self.resolveActionMessages(ids, server: server)
                guard !messages.isEmpty else { return }

                var uidSet = UIDSet()
                for message in messages {
                    uidSet.insert(message.uid)
                }
                switch operation {
                case .add:
                    try await server.store(flags: flags, on: uidSet, operation: .add)
                case .remove:
                    try await server.store(flags: flags, on: uidSet, operation: .remove)
                }
            }
        } catch is IMAPActionMailboxAbsent {
            // Source mailbox confirmed gone (Law 4: missing source membership
            // is stale) — nothing to mutate.
        }
    }

    /// Search the currently selected mailbox for a message by its RFC 2822 Message-ID.
    /// Single point of resolution — all Message-ID lookups MUST use this method.
    /// Tries with angle brackets first (iCloud and other strict-match servers require them),
    /// then bare value for servers that do RFC 3501 substring matching.
    private func searchByMessageId(_ messageId: String, server: IMAPServer) async throws -> UIDSet {
        let normalizedId = EmailFilter.normalizeMessageId(messageId)
        print("[IMAP] searchByMessageId — searching for '\(normalizedId)'")
        var ext: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [.header("Message-ID", "<\(normalizedId)>")])
        var results: UIDSet = ext.asSet
        if results.isEmpty {
            print("[IMAP] searchByMessageId — bracket search empty, trying bare")
            ext = try await server.extendedSearch(criteria: [.header("Message-ID", normalizedId)])
            results = ext.asSet
        }
        print("[IMAP] searchByMessageId — '\(normalizedId)' → \(results.isEmpty ? "NOT FOUND" : "\(results.count) UIDs")")
        return results
    }

    /// Resolve a stored messageId to a UIDSet for IMAP operations.
    /// If the messageId looks like a UID (all digits), construct a UIDSet directly.
    /// Otherwise, search by Message-ID header via `searchByMessageId`.
    /// Throws `uidResolutionFailed` if a non-numeric ID resolves to no UIDs.
    /// This is distinct from `messageNotFound` — the message likely exists but SEARCH
    /// couldn't find it (server quirk, timing issue). Drain queue treats this as transient.
    private func resolveUID(_ id: String, server: IMAPServer) async throws -> UIDSet {
        if let uidValue = UInt32(id) {
            return UIDSet(UID(uidValue))
        }
        let results = try await searchByMessageId(id, server: server)
        guard !results.isEmpty else {
            throw ProviderError.uidResolutionFailed(id)
        }
        return results
    }

    // MARK: - Helpers

    /// Convert an IMAP MessageInfo to our MessageHeaderInfo.
    /// Returns nil if the message cannot be trusted — e.g., both INTERNALDATE and
    /// ENVELOPE date are missing/unparseable. Such messages are treated as fetch
    /// failures: if the date is broken, other fields are likely broken too. Next
    /// fetch cycle will retry — by then the server should have indexed the message.
    private func mapMessageInfo(_ info: MessageInfo) -> MessageHeaderInfo? {
        // Shared parser — same From-header handling as Gmail/Graph/future NSE
        // IMAP. Returns ("name", "email") for "Name <email>", ("addr", "addr")
        // for bare addresses.
        let from = info.from.map { EmailAddress.parse($0) }
            ?? EmailAddress(name: "Unknown", email: "")
        let fromName = from.name
        let fromAddr = from.email

        // Prefer INTERNALDATE (server delivery time) over ENVELOPE date (sender's Date: header).
        // ENVELOPE date can be wrong due to sender clock skew, mailing list delays, or timezone issues.
        let date: Date
        if let internalDate = info.internalDate {
            date = internalDate
        } else if let parsed = info.date {
            date = parsed
        } else {
            // Both date sources failed — treat as fetch failure. The message is likely
            // still being indexed by the server (happens right after APPEND). Skipping
            // here means it never enters GRDB with a broken 1970 date. Next sync retries.
            print("[IMAP] Date parse failed for message: \(info.subject ?? "unknown") (id: \(info.messageId?.description ?? "?")) — treating as fetch failure, will retry")
            return nil
        }

        // Action tags are local-only (ADR-IOS-036): MessageAICache + Device
        // Sync probe. We no longer resolve ActionTag from IMAP keywords.
        // Legacy tm_* keywords on already-on-server messages are ignored by
        // the user-label filter below (see `UserLabelStore.isExcludedKeyword`).
        let tag: ActionTag? = nil

        // Extract user label keywords from custom flags (non-tm_*, non-standard)
        var userLabelKeywords: [String] = []
        for flag in info.flags {
            if case .custom(let keyword) = flag {
                if !UserLabelStore.isExcludedKeyword(keyword) {
                    userLabelKeywords.append(keyword.lowercased())
                }
            }
        }

        let subject = info.subject ?? "(no subject)"
        // `messageId` + `rfc822MessageId` go through the shared
        // `IMAPFetchMapping` helper so NSE's one-shot fetch and this sync
        // path produce byte-identical output for the same `MessageInfo`.
        // Prior to the 2026-04-19 fix NSE had its own inline copy that
        // diverged — duplicate iCloud inbox rows were the visible symptom.
        let rfc822MessageId = IMAPFetchMapping.rfc822MessageId(from: info)
        let inReplyTo = info.inReplyTo.map { EmailFilter.normalizeMessageId("\($0.localPart)@\($0.domain)") }
        let references = info.references?.map { "\($0.localPart)@\($0.domain)" }

        return MessageHeaderInfo(
            messageId: IMAPFetchMapping.messageIdString(from: info),
            rfc822MessageId: rfc822MessageId,
            inReplyTo: inReplyTo,
            references: references ?? [],
            threadId: nil,
            subject: subject,
            from: fromName,
            fromAddress: fromAddr,
            to: info.to.joined(separator: ", "),
            cc: info.cc.joined(separator: ", "),
            bcc: info.bcc.joined(separator: ", "),
            replyTo: nil,
            date: date,
            snippet: "",
            isRead: info.flags.contains(.seen),
            isFlagged: info.flags.contains(.flagged),
            hasAttachments: info.parts.contains { part in
                let ct = part.contentType.lowercased()
                let disposition = part.disposition?.lowercased()
                let hasFilename = !(part.filename?.isEmpty ?? true)
                let isExplicitAttachment = disposition == "attachment"
                let hasFileNotInline = hasFilename && disposition != "inline"
                let isCalendar = ct.hasPrefix("text/calendar")
                return isExplicitAttachment || hasFileNotInline || isCalendar
            },
            isReplied: info.flags.contains(.answered),
            isForwarded: info.flags.contains(.custom("$Forwarded")),
            actionTag: tag,
            userLabelIds: userLabelKeywords,
            userLabelIdsAreAuthoritative: true
        )
    }


    private func mapRole(_ attributes: Mailbox.Info.Attributes, name: String) -> FolderRole {
        IMAPProvider.mapRole(attributes: attributes, name: name)
    }

    /// Canonical name lists for name-based role detection (lowercased).
    /// Order matters: index 0 is the preferred canonical name and wins
    /// dedup tiebreaks (e.g., "Trash" beats "Deleted Messages" on iCloud).
    static let canonicalNames: [FolderRole: [String]] = [
        .inbox:   ["inbox"],
        .sent:    ["sent", "sent messages", "sent items", "sent mail"],
        .drafts:  ["drafts", "draft"],
        .trash:   ["trash", "deleted messages", "deleted items", "bin"],
        .archive: ["archive", "archives", "all mail"],
        .spam:    ["junk", "spam", "junk e-mail", "bulk mail"]
    ]

    /// Pure mapping function — exposed for tests + the role-dedup pass.
    static func mapRole(attributes: Mailbox.Info.Attributes, name: String) -> FolderRole {
        // Check IMAP special-use attributes first (RFC 6154)
        if attributes.contains(.inbox) { return .inbox }
        if attributes.contains(.sent) { return .sent }
        if attributes.contains(.drafts) { return .drafts }
        if attributes.contains(.trash) { return .trash }
        if attributes.contains(.archive) { return .archive }
        if attributes.contains(.junk) { return .spam }

        // Name-based fallback — many servers don't return special-use flags without RETURN (SPECIAL-USE)
        let lower = name.lowercased()
        for (role, names) in canonicalNames where names.contains(lower) {
            return role
        }
        return .custom
    }

    /// Returns the IMAP SPECIAL-USE attribute that corresponds to a role,
    /// or nil for `.custom` / `.inbox` (inbox uses a separate attribute).
    static func attributeForRole(_ role: FolderRole) -> Mailbox.Info.Attributes? {
        switch role {
        case .inbox:   return .inbox
        case .sent:    return .sent
        case .drafts:  return .drafts
        case .trash:   return .trash
        case .archive: return .archive
        case .spam:    return .junk
        case .custom:  return nil
        }
    }

    /// Lower index = more canonical name for the role. Returns Int.max
    /// when the name is not in the list — so unknown names lose tiebreaks.
    static func canonicalNameRank(_ name: String, role: FolderRole) -> Int {
        let lower = name.lowercased()
        guard let names = canonicalNames[role],
              let idx = names.firstIndex(of: lower) else { return .max }
        return idx
    }

    /// Picks one folder per role when multiple folders were assigned the same
    /// role (e.g., iCloud exposes both "Trash" and "Deleted Messages"). Returns
    /// the deduped list — losers are demoted to `.custom`. `.custom` and `.inbox`
    /// are passed through unchanged (multiple inboxes don't occur on real IMAP).
    static func dedupRoles(
        _ folders: [(info: FolderInfo, attributes: Mailbox.Info.Attributes)]
    ) -> [FolderInfo] {
        let grouped = Dictionary(grouping: folders.indices, by: { folders[$0].info.role })
        var demoted: Set<Int> = []

        for (role, indices) in grouped where indices.count > 1 && role != .custom {
            // Winner ranking — lower tuple wins:
            //   1. Has the SPECIAL-USE attribute (false=0 < true=1, so invert)
            //   2. Lower canonical-name rank
            //   3. Shorter name (stable, deterministic)
            let attr = attributeForRole(role)
            let winner = indices.min { a, b in
                let fa = folders[a]
                let fb = folders[b]
                let aHasAttr = attr.map { fa.attributes.contains($0) } ?? false
                let bHasAttr = attr.map { fb.attributes.contains($0) } ?? false
                if aHasAttr != bHasAttr { return aHasAttr }
                let aRank = canonicalNameRank(fa.info.name, role: role)
                let bRank = canonicalNameRank(fb.info.name, role: role)
                if aRank != bRank { return aRank < bRank }
                return fa.info.name.count < fb.info.name.count
            }!
            for i in indices where i != winner {
                demoted.insert(i)
                print("[IMAP:dedup] role=\(role) collision — demoting \"\(folders[i].info.name)\" to .custom; winner=\"\(folders[winner].info.name)\"")
            }
        }

        return folders.enumerated().map { idx, pair in
            if demoted.contains(idx) {
                var info = pair.info
                info.role = .custom
                return info
            }
            return pair.info
        }
    }

    // MARK: - IMAP → shared EmlMarker adapters
    //
    // These thin wrappers adapt SwiftMail `MessageInfo` to `EmlMarker.Envelope`
    // so the actual HTML/text shapes live in one place (`Shared/Rendering/EmlMarker.swift`),
    // shared with Gmail and Exchange. Callers and tests keep the familiar names.

    static let embeddedDateFormatter = EmlMarker.dateFormatter

    static func embeddedHeadersHtml(_ info: MessageInfo, filename: String?) -> String {
        let envelope = EmlMarker.Envelope(
            subject: info.subject, from: info.from, date: info.date,
            to: info.to, cc: info.cc
        )
        return EmlMarker.embeddedHeadersHtml(envelope: envelope, filename: filename)
    }

    static func embeddedHeadersPlainText(_ info: MessageInfo, filename: String?) -> String {
        let envelope = EmlMarker.Envelope(
            subject: info.subject, from: info.from, date: info.date,
            to: info.to, cc: info.cc
        )
        return EmlMarker.embeddedHeadersPlainText(envelope: envelope, filename: filename)
    }

    static func extractBodyContent(from html: String) -> String {
        EmlMarker.extractBodyContent(from: html)
    }

    static func escapeHtml(_ string: String) -> String {
        EmlMarker.escapeHtml(string)
    }
}
