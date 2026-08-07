/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Demo Mode lifecycle. See ADR-IOS-038.
///
/// Entry sequence (`start`):
/// 1. Mark `startInProgress = true` to disable the login button.
/// 2. POST /demo/start → mint a demo JWT, store in Keychain (`demo_session`).
/// 3. Wipe any leftover demo rows defensively.
/// 4. Set `DemoModeStore.isActive = true`.
///
/// Note: seeding (pre-baked AI cache) and provider injection happen
/// after the consent gates pass. RootView routes through gates first, then
/// calls `DemoModeService.completeSetup()` which seeds + injects providers.
///
/// Exit sequence (`exit`):
/// 1. Wipe demo session token.
/// 2. Disconnect demo providers from AccountManager.
/// 3. Wipe GRDB demo rows + FTS demo entries + memory.db demo entries.
/// 4. Reset `DemoModeStore.isActive = false`. Counter persists.
/// 5. Post `.demoModeDidExit` so RootView re-routes to login.
@MainActor
final class DemoModeService {
    static let shared = DemoModeService()

    private init() {}

    /// Begin the demo. Mints the JWT, primes session storage, and flips
    /// `DemoModeStore.isActive`. Throws on mint failure — caller surfaces
    /// the error and stays on the login screen.
    func start() async throws {
        let store = DemoModeStore.shared
        guard !store.isActive else { return }
        guard !store.startInProgress else { return }

        store.startInProgress = true
        defer { store.startInProgress = false }

        // Defensive: wipe any prior demo session before minting fresh.
        DemoTokenManager.clearSession()

        let mint = await DemoTokenManager.shared.mint()
        switch mint {
        case .success:
            break
        case .configMissing:
            throw DemoError.startFailed("Demo not available right now.")
        case .transientFailure(let reason):
            throw DemoError.startFailed(reason)
        }

        // Defensive wipe of any leftover demo rows from a previous session
        // that exited badly.
        if let db = AppDatabase.shared.withLock({ $0 }) {
            try? await db.dbPool.write { conn in try DemoSeed.wipe(conn) }
        }

        store.isActive = true

        // Boundary hygiene runs the INSTANT demo activates (not in
        // completeSetup, which is seconds later behind consent gates + splash):
        // - Cancel + drop all in-memory chat state. A real chat task
        //   surviving into demo would run its remaining tool calls with the
        //   demo flag set (writes into the soon-deleted overlay).
        // - Tear down Device Sync. An open coexistence socket could apply an
        //   incoming disabledReminders merge into the demo map during the
        //   entry window. connect() is demo-guarded, so it stays down.
        ChatPillState.shared.removeAllSessions()
        DeviceSyncService.shared.disconnect()

        print("[DemoMode] start(): demo mode active")
    }

    /// Debug-menu entry: enter demo mode WITHOUT logging out the live user.
    /// NOT `#if DEBUG`-gated (so it works in TestFlight/Release demo builds); it's
    /// reachable only behind the hidden debug menu (10-tap unlock + allow-listed
    /// user via `DebugModeManager`). Pre-sets the demo consent flags (the operator
    /// has already consented as a real user) so RootView's demo branch skips the
    /// consent screens and goes straight to the seeded inbox, then starts demo
    /// exactly like the login-screen path. Demo data is namespaced
    /// (`accountId == "demo-account"`) and wiped on exit; the live account,
    /// session, and real data are never touched.
    /// The bottom DemoBanner is suppressed for this entry mode (demo recording)
    /// — exit + call-counter reset live in the debug menu instead.
    func startFromDebugMenu() async throws {
        let store = DemoModeStore.shared
        store.hasCompletedConsentGate = true
        store.hasSeenAIConsent = true
        store.aiEnabled = true
        try await start()
        store.enteredFromDebugMenu = true
    }

    /// Phase 2 of entry — runs AFTER the user passes the consent + AI gates
    /// (or declines AI). Seeds GRDB + FTS + calendar, registers providers
    /// with `AccountManager`. Idempotent: subsequent calls during one demo
    /// session are no-ops.
    func completeSetup() async throws {
        guard DemoModeStore.shared.isActive else { return }

        // Note: the one-time destructive cached-mail resets (StartupMigrations)
        // already ran synchronously at DB-open (AppDatabase.init), long before the
        // user could tap "Try the demo". So seeding here is safe — nothing wipes it
        // afterward. (Previously these resets ran async after the seed and wiped it.)

        // Seed messages, folders, calendar events.
        try DemoSeed.seed()

        // Index seeded headers + bodies in FTS so search works in demo.
        await indexSeededFTS()

        // Register provider mocks. These plug into the existing
        // EmailProvider / CalendarProvider lookups in AccountManager.
        let provider = DemoProvider(accountId: DemoSeed.demoAccountId)
        let calendar = DemoCalendarProvider(accountId: DemoSeed.demoAccountId)
        await AccountManager.shared.registerDemoProviders(
            email: provider,
            calendar: calendar,
            accountId: DemoSeed.demoAccountId
        )

        // Open the AI subscription gate when
        // the user enabled AI in the demo consent gate. Otherwise the chat
        // pill renders the "Subscribe to unlock AI features" lock bar.
        if DemoModeStore.shared.aiEnabled {
            AISubscriptionGate.shared.openGate()
        }

        // Prompt overlay (ADR-IOS-038): swap KB / composition / action /
        // templates to bundled defaults so demo tools (kb_add, reminder_add,
        // template edits) operate on demo-scoped storage and the real prompts
        // never surface in a demo. Chat-state teardown + Device Sync
        // disconnect already happened at the top of start().
        PromptStore.shared.enterDemoOverlay()

        // Notify the search index / nav store so reactive UI picks up demo
        // folders + headers immediately. NavigationStore is a pull-model
        // observer that listens for `.backgroundDataDidChange` (full refresh
        // of accounts + folders + outbox) and `.inboxDataDidChange` (folder
        // counts). Without these, the sidebar's unified-mailboxes section
        // stays hidden because `navigationStore.accounts` is still empty
        // from the launch-time load (which ran before demo seeding). Posting
        // `.inboxDataDidChange` also invalidates ReminderBuilder's cache so
        // demo email reminders surface.
        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        // The chat pill's first ValueObservation emission can race the seed
        // writes (count=0 on first emit; 2s debounced refresh on the next).
        // Post `.remindersDidChange` directly so DynamicIslandChat's
        // onReceive fires `regenerateReminders` immediately, no race window.
        NotificationCenter.default.post(name: .remindersDidChange, object: nil)
        NotificationCenter.default.post(name: .demoSeedingComplete, object: nil)
        print("[DemoMode] completeSetup(): seed + providers ready")
    }

    /// Exit demo cleanly. Counter, gate flags, tip-shown state
    /// all persist. The ONLY things wiped are demo session, demo
    /// providers, demo GRDB rows, demo FTS entries, demo memory.db entries.
    func exit() async {
        let store = DemoModeStore.shared
        guard store.isActive else { return }

        DemoTokenManager.clearSession()
        await AccountManager.shared.unregisterDemoProviders(accountId: DemoSeed.demoAccountId)

        if let db = AppDatabase.shared.withLock({ $0 }) {
            do {
                try await db.dbPool.write { conn in try DemoSeed.wipe(conn) }
            } catch {
                print("[DemoMode] exit(): GRDB wipe failed: \(error)")
            }
        }

        // FTS — clear demo entries via SearchIndex.purgeForAccount (net-new).
        await SearchIndex.shared.purgeForAccount(DemoSeed.demoAccountId)

        // memory.db — clear demo entries via MemoryIndex.purgeForSessionPrefix
        // (net-new). Demo session ids start with "demo:".
        await MemoryIndex.shared.purgeForSessionPrefix("demo:")

        // Drop ALL in-memory chat pill state — demo session pages, live demo
        // turns, and reminder buffers must not survive into the real user's
        // chat pill (they'd resurrect wiped GRDB rows on screen).
        ChatPillState.shared.removeAllSessions()

        // Restore the real prompts + delete the overlay keys. MUST run while
        // isActive is still true (see PromptStore.exitDemoOverlay). The demo
        // disabled-reminders map is deleted the same way.
        PromptStore.shared.exitDemoOverlay()
        UserDefaults.standard.removeObject(forKey: DisabledRemindersStore.demoStorageKeyV2)

        store.isActive = false
        store.enteredFromDebugMenu = false
        // Note: callsConsumed and demo gate flags persist.

        // Re-establish Device Sync (disconnected on demo entry). connect()
        // internally no-ops unless the user has sync enabled.
        DeviceSyncService.shared.forceReconnect()

        // Symmetric to completeSetup(): NavigationStore is pull-model and
        // doesn't notice the GRDB account/folder wipe on its own. Without
        // these notifications `navigationStore.accounts` keeps the wiped
        // demo row, RootView's `hasEmailAccounts && !hasTabMailSession`
        // branch routes to MailNavigationView (empty), and the user never
        // lands back on TabMailLoginView with the "Try the demo" button.
        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        NotificationCenter.default.post(name: .remindersDidChange, object: nil)
        NotificationCenter.default.post(name: .demoModeDidExit, object: nil)
        print("[DemoMode] exit(): cleanup complete")
    }

    /// Force a one-shot orphan wipe at app launch when stale demo rows are
    /// found but no demo session is active (force-quit recovery; also covers
    /// edge cases). Also called when the user signs up with a real account.
    static func purgeOrphanedDemoData() async {
        if let db = AppDatabase.shared.withLock({ $0 }) {
            try? await db.dbPool.write { conn in try DemoSeed.wipe(conn) }
        }
        await SearchIndex.shared.purgeForAccount(DemoSeed.demoAccountId)
        await MemoryIndex.shared.purgeForSessionPrefix("demo:")
        // Stale demo overlay keys from a force-quit mid-demo (harmless while
        // demo is inactive — all readers use the real keys — but clean up).
        PromptStore.removeDemoOverlayKeys()
        UserDefaults.standard.removeObject(forKey: DisabledRemindersStore.demoStorageKeyV2)
    }

    // MARK: - FTS indexing

    private func indexSeededFTS() async {
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return }
        let headers: [MessageHeader]
        let bodies: [MessageBody]
        do {
            (headers, bodies) = try await db.dbPool.read { conn -> ([MessageHeader], [MessageBody]) in
                let h = try MessageHeader
                    .filter(Column("accountId") == DemoSeed.demoAccountId)
                    .fetchAll(conn)
                let b = try MessageBody
                    .filter(Column("id").like("\(DemoSeed.demoAccountId):%"))
                    .fetchAll(conn)
                return (h, b)
            }
        } catch {
            print("[DemoMode] FTS index read failed: \(error)")
            return
        }

        // Index headers + bodies via existing SearchIndex API. We don't
        // generate embeddings during demo seed (FTS-only).
        let records = headers.map { h in
            FTSHeaderRecord(
                contentKey: ContentKey(rawValue: h.id),
                headerId: h.id,
                messageId: h.messageId,
                subject: h.subject,
                from: h.from,
                to: h.to,
                cc: h.cc,
                bcc: h.bcc,
                dateMs: Int64(h.date.timeIntervalSince1970 * 1000),
                folderId: h.folderId
            )
        }
        do {
            _ = try await SearchIndex.shared.indexHeaders(records)
            let bodyMap: [String: String] = bodies.reduce(into: [:]) { acc, b in
                if let html = b.htmlContent { acc[b.id.rawValue] = html }
            }
            for header in headers {
                if let html = bodyMap[header.id] {
                    let plain = stripHTML(html)
                    try await SearchIndex.shared.updateBody(contentKey: ContentKey(rawValue: header.id), body: plain)
                }
            }
        } catch {
            print("[DemoMode] FTS indexing failed: \(error)")
        }
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension Notification.Name {
    static let demoSeedingComplete = Notification.Name("demoSeedingComplete")
}
