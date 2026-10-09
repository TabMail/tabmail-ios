import Foundation
import Testing
@testable import TabMail

/// The synced state on a device (prompts, KB, templates, disabled reminders, compaction
/// thresholds) belongs to one TabMail account. A different account signing in must neither
/// see it nor broadcast it into its own devices; the same account signing back in keeps it.
@MainActor
@Suite("Device Sync account ownership", .serialized, .processGlobalState)
struct DeviceSyncAccountOwnershipTests {
    private static let timestampKeys = [
        "device_sync_ts:composition", "device_sync_ts:action", "device_sync_ts:kb",
        "device_sync_ts:templates", "device_sync_ts:disabledReminders", ActionCompactConfig.updatedAtKey,
    ]
    /// Every key the claim reads or clears, besides the ownership key itself.
    private static let compositionKey = "user_prompts:user_composition.md"
    private static let actionKey = "user_prompts:user_action.md"
    private static let kbKey = "user_prompts:user_kb.md"
    private static let peerBaseKeys = [
        "device_peer_base:composition", "device_peer_base:action", "device_peer_base:kb",
        "device_peer_base_ts:composition", "device_peer_base_ts:action", "device_peer_base_ts:kb",
    ]
    private static let accountKeys = [
        compositionKey, actionKey, kbKey, "user_templates", "user_templates_initialized",
        "prompt_history", "prompt_history_migrated",
        "disabled_reminders", "disabled_reminders_v2",
        PromptStore.actionCompactThresholdKey, PromptStore.actionCompactThresholdCharsKey,
        "device_sync_backups", "device_sync_auto_enabled",
    ] + peerBaseKeys + timestampKeys
    private static let allKeys = [DeviceSyncService.ownerUserIdKey, AgeAndTermsConsent.completedKey] + accountKeys

    private func iso(daysFromNow days: Double) -> String { Date().addingTimeInterval(days * 86_400).ISO8601Format() }

    /// Runs `body` as an account that has passed the age and terms screen
    /// (Device Sync connects only then), then restores every touched key and
    /// the in-memory prompt values.
    private func preservingState(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let saved = Self.allKeys.map { defaults.object(forKey: $0) }
        defaults.set(true, forKey: AgeAndTermsConsent.completedKey)
        let store = PromptStore.shared
        let memory = (store.rawComposition, store.rawAction, store.rawKB, store.templates)
        defer {
            for (key, value) in zip(Self.allKeys, saved) { defaults.set(value, forKey: key) }
            store.applySync(composition: memory.0, action: memory.1, kb: memory.2, templates: memory.3, skipHistory: true)
        }
        try body()
    }

    /// Runs `body` with a signed-in session for `userId`, then restores the previous session.
    private func withSession(userId: String, _ body: () throws -> Void) throws {
        let store = TabMailSessionStore.shared
        let previous = store.loadActiveSession()?.data
        defer {
            _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
            if let previous { _ = try? store.installNewSession(previous) }
        }
        // Far enough ahead that nothing refreshes it; relative to now so it never goes stale.
        let expiresAt = Int(Date().addingTimeInterval(365 * 24 * 60 * 60).timeIntervalSince1970)
        _ = try store.installNewSession(JSONSerialization.data(withJSONObject: [
            "access_token": "ownership-test-access",
            "refresh_token": "ownership-test-refresh",
            "expires_at": expiresAt,
            "user": ["id": userId, "email": "owner@example.com"],
        ]))
        try body()
    }

    private func storedTemplates() -> [ReplyTemplate]? {
        UserDefaults.standard.data(forKey: "user_templates").flatMap { try? JSONDecoder().decode([ReplyTemplate].self, from: $0) }
    }

    /// The bundled defaults, read through the store's own reset (the values themselves are private).
    private func bundledDefaults() -> (composition: String, action: String, kb: String, templates: [ReplyTemplate]) {
        let store = PromptStore.shared
        store.resetComposition()
        store.resetAction()
        store.resetKB()
        store.resetTemplates()
        return (store.rawComposition, store.rawAction, store.rawKB, store.templates)
    }

    /// Gives the device a previous account's edited, synced state.
    private func seedAccountState(owner: String?) {
        let defaults = UserDefaults.standard
        defaults.set(owner, forKey: DeviceSyncService.ownerUserIdKey)
        let templates = bundledDefaults().templates.prefix(1).map { template -> ReplyTemplate in
            var template = template
            template.name = "Owner template"
            return template
        }
        PromptStore.shared.applySync(composition: "owner composition", action: "owner action", kb: "owner kb",
                                     templates: templates, skipHistory: true)
        for key in ["prompt_history", "disabled_reminders", "disabled_reminders_v2", "device_sync_backups"] + Self.peerBaseKeys {
            defaults.set(Data("owner".utf8), forKey: key)
        }
        defaults.set(300, forKey: PromptStore.actionCompactThresholdKey)
        defaults.set(40000, forKey: PromptStore.actionCompactThresholdCharsKey)
        defaults.set(false, forKey: "device_sync_auto_enabled")
        let edited = iso(daysFromNow: -1)
        for key in Self.timestampKeys { defaults.set(edited, forKey: key) }
    }

    private func expectAccountStateKept() {
        let defaults = UserDefaults.standard
        let store = PromptStore.shared
        #expect(store.rawComposition == "owner composition")
        #expect(store.rawAction == "owner action")
        #expect(store.rawKB == "owner kb")
        #expect(store.templates.map(\.name) == ["Owner template"])
        #expect(defaults.string(forKey: Self.actionKey) == "owner action")
        #expect(defaults.data(forKey: "disabled_reminders_v2") == Data("owner".utf8))
        #expect(defaults.data(forKey: "prompt_history") == Data("owner".utf8))
        #expect(ActionCompactConfig.local() == ActionCompactConfig(compactThreshold: 300, compactThresholdChars: 40000))
        #expect(!DeviceSyncService.shared.isAutoEnabled)
        for key in Self.timestampKeys { #expect(defaults.string(forKey: key) != nil, "\(key)") }
    }

    @Test("A different account gets defaults and no sync timestamps, so it probes instead of broadcasting the previous account's state")
    func differentAccountStartsFromDefaults() {
        preservingState {
            let bundled = bundledDefaults()
            seedAccountState(owner: "account-a")
            DeviceSyncService.shared.claimLocalState(for: "account-b")

            let defaults = UserDefaults.standard
            let store = PromptStore.shared
            #expect(defaults.string(forKey: DeviceSyncService.ownerUserIdKey) == "account-b")
            #expect(store.rawComposition == bundled.composition)
            #expect(store.rawAction == bundled.action)
            #expect(store.rawKB == bundled.kb)
            #expect(store.templates == bundled.templates)
            #expect(defaults.string(forKey: Self.compositionKey) == bundled.composition)
            #expect(defaults.string(forKey: Self.actionKey) == bundled.action)
            #expect(defaults.string(forKey: Self.kbKey) == bundled.kb)
            #expect(store.loadHistory().isEmpty)
            #expect(DisabledRemindersStore.getDisabledMap().isEmpty)
            #expect(ActionCompactConfig.local() == ActionCompactConfig(compactThreshold: 200, compactThresholdChars: 32000))
            #expect(DeviceSyncService.shared.isAutoEnabled)
            for key in ["disabled_reminders", "device_sync_backups"] + Self.peerBaseKeys + Self.timestampKeys {
                #expect(defaults.object(forKey: key) == nil, "\(key)")
            }
        }
    }

    @Test("The same account signing back in keeps everything")
    func sameAccountKeepsState() {
        preservingState {
            seedAccountState(owner: "account-a")
            DeviceSyncService.shared.claimLocalState(for: "account-a")
            #expect(UserDefaults.standard.string(forKey: DeviceSyncService.ownerUserIdKey) == "account-a")
            expectAccountStateKept()
        }
    }

    @Test("With no recorded owner, the first claim adopts the device's state as-is")
    func firstClaimAdoptsState() {
        preservingState {
            seedAccountState(owner: nil)
            DeviceSyncService.shared.claimLocalState(for: "account-a")
            #expect(UserDefaults.standard.string(forKey: DeviceSyncService.ownerUserIdKey) == "account-a")
            expectAccountStateKept()
        }
    }

    @Test("Completing a session closes Device Sync, so the next account never inherits this one's connection")
    func completeSessionDisconnectsDeviceSync() throws {
        try preservingState {
            let sync = DeviceSyncService.shared
            sync.disconnect()
            UserDefaults.standard.set(true, forKey: "device_sync_auto_enabled")
            sync.connect()
            try #require(sync.isConnecting)

            let name = "DeviceSyncAccountOwnershipTests.\(UUID().uuidString)"
            let cleanupDefaults = try #require(UserDefaults(suiteName: name))
            defer { cleanupDefaults.removePersistentDomain(forName: name) }
            let lockDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: lockDirectory) }
            let sessionStore = TabMailSessionStore(
                backend: MemorySessionKeychainBackend(),
                storageLock: CredentialStorageLock(directory: lockDirectory),
                cleanupDefaults: cleanupDefaults,
                makeGeneration: { UUID().uuidString }
            )

            #expect(TabMailAuthService.completeSession(mode: .deactivate, notify: false, sessionStore: sessionStore))
            #expect(!sync.isConnecting)
            #expect(!sync.isConnected)
        }
    }

    @Test("Connecting records the signed-in account as owner on an install that has none, and keeps its state")
    func connectAdoptsOwnerForUnownedInstall() throws {
        try preservingState {
            seedAccountState(owner: nil)
            try withSession(userId: "account-a") {
                DeviceSyncService.shared.connect()
                DeviceSyncService.shared.disconnect()
                #expect(UserDefaults.standard.string(forKey: DeviceSyncService.ownerUserIdKey) == "account-a")
                expectAccountStateKept()
            }
        }
    }

    @Test("Connecting as an account other than the recorded owner resets to the defaults")
    func connectResetsForDifferentSignedInAccount() throws {
        try preservingState {
            let bundled = bundledDefaults()
            seedAccountState(owner: "account-b")
            try withSession(userId: "account-a") {
                DeviceSyncService.shared.connect()
                DeviceSyncService.shared.disconnect()
                #expect(UserDefaults.standard.string(forKey: DeviceSyncService.ownerUserIdKey) == "account-a")
                #expect(PromptStore.shared.rawAction == bundled.action)
                #expect(UserDefaults.standard.string(forKey: Self.actionKey) == bundled.action)
                for key in Self.timestampKeys { #expect(UserDefaults.standard.object(forKey: key) == nil, "\(key)") }
            }
        }
    }

    @Test("Claiming a different account closes the previous account's connection; the same account leaves it open")
    func claimClosesConnectionOnlyOnAccountChange() throws {
        try preservingState {
            let sync = DeviceSyncService.shared
            defer { sync.disconnect() }
            try withSession(userId: "account-a") {
                UserDefaults.standard.set("account-a", forKey: DeviceSyncService.ownerUserIdKey)
                UserDefaults.standard.set(true, forKey: "device_sync_auto_enabled")
                sync.disconnect()
                sync.connect()
                try #require(sync.isConnecting)

                sync.claimLocalState(for: "account-a")
                #expect(sync.isConnecting)

                sync.claimLocalState(for: "account-b")
                #expect(!sync.isConnecting)
                #expect(!sync.isConnected)
            }
        }
    }

    @Test("A different account claimed during demo gets the defaults in the real keys, which load when demo ends")
    func claimDuringDemoResetsRealKeys() {
        preservingState {
            let bundled = bundledDefaults()
            let defaults = UserDefaults.standard
            let store = PromptStore.shared
            DemoModeStore.shared._resetForTests()
            DemoModeStore.shared.isActive = true
            defer {
                DemoModeStore.shared._resetForTests()
                PromptStore.removeDemoOverlayKeys()
            }
            store.enterDemoOverlay()
            let overlay = (store.rawComposition, store.rawAction, store.rawKB, store.templates)
            defaults.set("account-a", forKey: DeviceSyncService.ownerUserIdKey)
            defaults.set("owner composition", forKey: Self.compositionKey)
            defaults.set("owner action", forKey: Self.actionKey)
            defaults.set("owner kb", forKey: Self.kbKey)
            defaults.set(Data("owner".utf8), forKey: "user_templates")

            DeviceSyncService.shared.claimLocalState(for: "account-b")

            #expect(defaults.string(forKey: Self.compositionKey) == bundled.composition)
            #expect(defaults.string(forKey: Self.actionKey) == bundled.action)
            #expect(defaults.string(forKey: Self.kbKey) == bundled.kb)
            #expect(storedTemplates() == bundled.templates)
            // The demo overlay in memory is untouched while demo runs.
            #expect(store.rawComposition == overlay.0)
            #expect(store.rawAction == overlay.1)
            #expect(store.rawKB == overlay.2)
            #expect(store.templates == overlay.3)

            store.exitDemoOverlay()
            #expect(store.rawComposition == bundled.composition)
            #expect(store.rawAction == bundled.action)
            #expect(store.rawKB == bundled.kb)
            #expect(store.templates == bundled.templates)
        }
    }

    @Test("An edit pending its history entry when a different account is claimed never records into the new account's history")
    func pendingHistoryEditIsDroppedOnAccountChange() async throws {
        let defaults = UserDefaults.standard
        let saved = Self.allKeys.map { defaults.object(forKey: $0) }
        let store = PromptStore.shared
        let memory = (store.rawComposition, store.rawAction, store.rawKB, store.templates)
        defer {
            for (key, value) in zip(Self.allKeys, saved) { defaults.set(value, forKey: key) }
            store.applySync(composition: memory.0, action: memory.1, kb: memory.2, templates: memory.3, skipHistory: true)
        }
        defaults.set("account-a", forKey: DeviceSyncService.ownerUserIdKey)
        defaults.removeObject(forKey: "prompt_history")
        store.rawKB = "previous account kb edit"
        DeviceSyncService.shared.claimLocalState(for: "account-b")
        // Past the 2 s history debounce.
        try await Task.sleep(for: .milliseconds(2500))
        #expect(store.loadHistory().isEmpty)
    }
}
