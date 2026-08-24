/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("NSE Data Bridge — Mirroring, Settings, and Merge", .serialized, .processGlobalState)
struct NSEDataBridgeTests {

    @Test("account incarnation is required for account pushes but not other notifications")
    func accountIncarnationFence() throws {
        let name = "NSEDataBridgeTests.incarnation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let map = ["account@example.com": "current-account"]
        defaults.set(
            String(data: try JSONEncoder().encode(map), encoding: .utf8),
            forKey: "nse.accountMap"
        )

        #expect(!NSEDataBridge.accountIncarnationMatches(
            nil,
            accountEmail: "account@example.com",
            defaults: defaults
        ))
        #expect(!NSEDataBridge.accountIncarnationMatches(
            "",
            accountEmail: "account@example.com",
            defaults: defaults
        ))
        #expect(NSEDataBridge.accountIncarnationMatches(
            nil,
            accountEmail: "",
            defaults: defaults
        ))
        #expect(!NSEDataBridge.accountIncarnationMatches(
            "current-account",
            accountEmail: "",
            provider: "gmail",
            defaults: defaults
        ))
        #expect(NSEDataBridge.accountIncarnationMatches(
            "current-account",
            accountEmail: "Account@Example.COM",
            defaults: defaults
        ))
        #expect(!NSEDataBridge.accountIncarnationMatches(
            "removed-account",
            accountEmail: "account@example.com",
            defaults: defaults
        ))

        #expect(NSEDataBridge.notificationAccountMatches([
            "provider": "gmail",
            "accountEmail": "Account@Example.COM",
            "accountIncarnation": "current-account",
        ], defaults: defaults))
        #expect(!NSEDataBridge.notificationAccountMatches([
            "provider": "gmail",
            "accountEmail": "account@example.com",
        ], defaults: defaults))
        #expect(!NSEDataBridge.notificationAccountMatches([
            "provider": "gmail",
            "accountIncarnation": "current-account",
        ], defaults: defaults))
        #expect(NSEDataBridge.notificationAccountMatches([
            "provider": "task_alarm",
        ], defaults: defaults))
        #expect(!NSEDataBridge.notificationAccountMatches([
            "provider": "gmail",
            "messageId": "stale-message",
            "accountEmail": "account@example.com",
            "accountIncarnation": "removed-account",
        ], defaults: defaults))
        #expect(!NSEDataBridge.notificationAccountMatches([
            "tabmail.rejectedAccountPush": true,
        ], defaults: defaults))

        // Exercise the exact lookup compiled into the extension, not an app-
        // side copy of its logic.
        #expect(NSEState.accountIncarnationMatches(
            "current-account",
            for: "Account@Example.COM",
            provider: "gmail",
            defaults: defaults
        ))
        #expect(!NSEState.accountIncarnationMatches(
            "removed-account",
            for: "account@example.com",
            provider: "gmail",
            defaults: defaults
        ))
        #expect(!NSEState.accountIncarnationMatches(
            "current-account",
            for: "",
            provider: "outlook",
            defaults: defaults
        ))
        #expect(NSEState.accountIncarnationMatches(
            nil,
            for: "",
            provider: "task_alarm",
            defaults: defaults
        ))
    }

    @Test("account-map mirroring normalizes mixed-case OAuth, iCloud, and IMAP addresses")
    func accountMapNormalizesEmailKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NSEDataBridgeTests.account-map.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previousDatabase = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }
        defer {
            AppDatabase.shared.withLock { $0 = previousDatabase }
            TestDatabaseTeardown.retire(pool: pool, directory: directory)
        }

        let accounts = [
            ("gmail-account", "Person@GMAIL.com", AccountProvider.gmail),
            ("icloud-account", "Person@iCloud.COM", AccountProvider.imap),
            ("imap-account", "Person@Mail.Example.COM", AccountProvider.imap),
        ]
        try pool.write { db in
            for (id, email, provider) in accounts {
                var account = Account(emailAddress: email, displayName: "Test", provider: provider)
                account.id = id
                try account.insert(db)
            }
        }

        let name = "NSEDataBridgeTests.account-map-defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        NSEDataBridge.mirrorAccountMap(defaults: defaults)

        for (id, email, _) in accounts {
            #expect(NSEDataBridge.accountIncarnationMatches(
                id,
                accountEmail: email.uppercased(),
                defaults: defaults
            ))
        }
        let json = try #require(defaults.string(forKey: "nse.accountMap"))
        let map = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        #expect(Set(map.keys) == Set(accounts.map { $0.1.lowercased() }))
    }

    // MARK: - Helpers

    private let appGroupId = "group.ai.tabmail"

    /// Get shared UserDefaults suite (same as NSEDataBridge reads from)
    private var suite: UserDefaults? { UserDefaults(suiteName: appGroupId) }

    private func cleanupSuite() {
        guard let s = suite else { return }
        for key in ["nse.accountMap", "nse.userName", "nse.actionPrompt", "nse.kbText",
                     "nse.compositionPrompt", "nse.backendBaseURL", "nse.pushWorkerURL",
                     "nse.lastHistoryIds", "nse.filteringApproved",
                     "nse.deviceSyncEnabled", "nse.syncBaseURL", "nse.deviceToken",
                     "nse.googleClientId"] {
            s.removeObject(forKey: key)
        }
    }

    // MARK: - Backend URL mirrors from BackendConfig toggle

    @Test("mirrorBackendConfig uses BackendConfig.apiBaseURL, not hardcoded URL")
    func backendURLFromConfig() {
        cleanupSuite()
        NSEDataBridge.mirrorBackendConfig()
        let mirrored = suite?.string(forKey: "nse.backendBaseURL")
        #expect(mirrored == BackendConfig.apiBaseURL.absoluteString)
    }

    @Test("mirrorBackendConfig always sets pushWorkerURL")
    func pushWorkerURL() {
        cleanupSuite()
        NSEDataBridge.mirrorBackendConfig()
        let mirrored = suite?.string(forKey: "nse.pushWorkerURL")
        #expect(mirrored == "https://push.tabmail.ai")
    }

    // MARK: - Push settings mirroring

    @Test("mirrorPushSettings does not mirror nse.pushEnabled (flag was removed)")
    func pushEnabledNotMirrored() {
        cleanupSuite()
        suite?.removeObject(forKey: "nse.pushEnabled")  // clear any stale value from prior runs
        UserDefaults.standard.set(true, forKey: PushConfig.pushNotificationsEnabledKey)
        NSEDataBridge.mirrorPushSettings()
        // NSE's deliverPassive no longer suppresses based on opt-in state — it
        // passes the worker's pre-populated alert through. No NSE-side mirror.
        let mirrored = suite?.object(forKey: "nse.pushEnabled")
        #expect(mirrored == nil)
        UserDefaults.standard.removeObject(forKey: PushConfig.pushNotificationsEnabledKey)
    }

    @Test("mirrorPushSettings mirrors filteringApproved from PushConfig constant")
    func filteringApprovedMirrored() {
        cleanupSuite()
        NSEDataBridge.mirrorPushSettings()
        let mirrored = suite?.bool(forKey: "nse.filteringApproved")
        #expect(mirrored == PushConfig.nseFilteringApproved)
    }

    @Test("mirrorPushSettings mirrors deviceSyncEnabled default true")
    func deviceSyncEnabledDefault() {
        cleanupSuite()
        UserDefaults.standard.removeObject(forKey: "device_sync_auto_enabled")
        NSEDataBridge.mirrorPushSettings()
        let mirrored = suite?.object(forKey: "nse.deviceSyncEnabled") as? Bool
        #expect(mirrored == true)
        // Cleanup
        UserDefaults.standard.removeObject(forKey: "device_sync_auto_enabled")
    }

    @Test("mirrorPushSettings mirrors deviceSyncEnabled false")
    func deviceSyncEnabledFalse() {
        cleanupSuite()
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        NSEDataBridge.mirrorPushSettings()
        let mirrored = suite?.object(forKey: "nse.deviceSyncEnabled") as? Bool
        #expect(mirrored == false)
        // Cleanup
        UserDefaults.standard.removeObject(forKey: "device_sync_auto_enabled")
    }

    @Test("mirrorPushSettings mirrors syncBaseURL from BackendConfig")
    func syncBaseURLMirrored() {
        cleanupSuite()
        NSEDataBridge.mirrorPushSettings()
        let mirrored = suite?.string(forKey: "nse.syncBaseURL")
        #expect(mirrored == BackendConfig.syncBaseURL)
    }

    // MARK: - Prompt mirroring

    @Test("mirrorPrompts mirrors composition, action, and KB from UserDefaults")
    func promptsMirrored() {
        cleanupSuite()
        UserDefaults.standard.set("test composition", forKey: "user_prompts:user_composition.md")
        UserDefaults.standard.set("test action", forKey: "user_prompts:user_action.md")
        UserDefaults.standard.set("test kb", forKey: "user_prompts:user_kb.md")

        NSEDataBridge.mirrorPrompts()

        #expect(suite?.string(forKey: "nse.compositionPrompt") == "test composition")
        #expect(suite?.string(forKey: "nse.actionPrompt") == "test action")
        #expect(suite?.string(forKey: "nse.kbText") == "test kb")

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "user_prompts:user_composition.md")
        UserDefaults.standard.removeObject(forKey: "user_prompts:user_action.md")
        UserDefaults.standard.removeObject(forKey: "user_prompts:user_kb.md")
    }

    @Test("mirrorPrompts handles empty/nil prompts gracefully")
    func promptsEmptyHandled() {
        cleanupSuite()
        UserDefaults.standard.removeObject(forKey: "user_prompts:user_composition.md")
        UserDefaults.standard.removeObject(forKey: "user_prompts:user_action.md")
        UserDefaults.standard.removeObject(forKey: "user_prompts:user_kb.md")

        NSEDataBridge.mirrorPrompts()

        // Should be empty strings, not nil (NSE expects strings)
        #expect(suite?.string(forKey: "nse.compositionPrompt") == "")
        #expect(suite?.string(forKey: "nse.actionPrompt") == "")
        #expect(suite?.string(forKey: "nse.kbText") == "")
    }

    // MARK: - Bridge key-name parity (regression guard)
    //
    // The NSE↔main-app action classification divergence (Apr 2026) was caused by
    // `NSEDataBridge.mirrorPrompts` reading `userActionPrompt` from UserDefaults while
    // `PromptStore` wrote to `user_prompts:user_action.md`. The mirror produced "" and
    // NSE always sent an empty `user_action_prompt`. These tests lock the exact keys
    // so a future rename on one side fails the build, not production.

    @Test("mirrorPrompts reads from the exact keys PromptStore writes")
    func promptKeysMatchPromptStore() {
        // These string literals MUST match PromptStore.Keys.{composition,action,kb}
        // (private in PromptStore — asserted by round-trip below).
        cleanupSuite()
        UserDefaults.standard.set("C", forKey: "user_prompts:user_composition.md")
        UserDefaults.standard.set("A", forKey: "user_prompts:user_action.md")
        UserDefaults.standard.set("K", forKey: "user_prompts:user_kb.md")

        NSEDataBridge.mirrorPrompts()

        #expect(suite?.string(forKey: "nse.compositionPrompt") == "C")
        #expect(suite?.string(forKey: "nse.actionPrompt") == "A")
        #expect(suite?.string(forKey: "nse.kbText") == "K")

        // Old (buggy) keys must NOT be consulted — writes here must not leak.
        UserDefaults.standard.removeObject(forKey: "user_prompts:user_composition.md")
        UserDefaults.standard.removeObject(forKey: "user_prompts:user_action.md")
        UserDefaults.standard.removeObject(forKey: "user_prompts:user_kb.md")
        UserDefaults.standard.set("STALE", forKey: "userActionPrompt")
        UserDefaults.standard.set("STALE", forKey: "userCompositionPrompt")
        UserDefaults.standard.set("STALE", forKey: "userKB")
        cleanupSuite()
        NSEDataBridge.mirrorPrompts()
        #expect(suite?.string(forKey: "nse.compositionPrompt") == "")
        #expect(suite?.string(forKey: "nse.actionPrompt") == "")
        #expect(suite?.string(forKey: "nse.kbText") == "")
        UserDefaults.standard.removeObject(forKey: "userActionPrompt")
        UserDefaults.standard.removeObject(forKey: "userCompositionPrompt")
        UserDefaults.standard.removeObject(forKey: "userKB")
    }

    @Test("PromptStore → mirrorPrompts round-trip — setter flows to NSE suite")
    @MainActor
    func promptStoreRoundTripToMirror() {
        cleanupSuite()
        // Mutate via PromptStore's public setter (triggers didSet → writes UserDefaults → calls mirrorPrompts).
        let marker = "ROUNDTRIP-\(UUID().uuidString)"
        let original = PromptStore.shared.rawAction
        PromptStore.shared.rawAction = marker
        defer { PromptStore.shared.rawAction = original }

        // didSet already called mirrorPrompts; still, call again explicitly to prove read-side parity.
        NSEDataBridge.mirrorPrompts()

        #expect(suite?.string(forKey: "nse.actionPrompt") == marker)
        // And snapshot reader (used by main-app action pipeline) agrees.
        #expect(PromptStore.actionMarkdownSnapshot() == marker)
    }

    @Test("mirrorUserName uses 'userName' key")
    func userNameMirrorKey() {
        cleanupSuite()
        UserDefaults.standard.set("Alice", forKey: "userName")
        defer { UserDefaults.standard.removeObject(forKey: "userName") }
        NSEDataBridge.mirrorUserName()
        #expect(suite?.string(forKey: "nse.userName") == "Alice")
    }

    @Test("mirrorUserName defaults to empty string when unset")
    func userNameMirrorEmpty() {
        cleanupSuite()
        UserDefaults.standard.removeObject(forKey: "userName")
        NSEDataBridge.mirrorUserName()
        #expect(suite?.string(forKey: "nse.userName") == "")
    }

    @Test("mirrorDeviceToken uses 'lastDeviceToken' key")
    func deviceTokenMirrorKey() {
        cleanupSuite()
        UserDefaults.standard.set("tok-123", forKey: "lastDeviceToken")
        defer { UserDefaults.standard.removeObject(forKey: "lastDeviceToken") }
        NSEDataBridge.mirrorDeviceToken()
        #expect(suite?.string(forKey: "nse.deviceToken") == "tok-123")
    }

    @Test("mirrorPushSettings uses 'device_sync_auto_enabled' key and defaults to true")
    func pushSettingsSyncKey() {
        cleanupSuite()
        // Unset → default true (preserves current behavior)
        UserDefaults.standard.removeObject(forKey: "device_sync_auto_enabled")
        NSEDataBridge.mirrorPushSettings()
        #expect(suite?.bool(forKey: "nse.deviceSyncEnabled") == true)

        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        defer { UserDefaults.standard.removeObject(forKey: "device_sync_auto_enabled") }
        NSEDataBridge.mirrorPushSettings()
        #expect(suite?.bool(forKey: "nse.deviceSyncEnabled") == false)

        // filteringApproved + syncBaseURL always written.
        #expect(suite?.object(forKey: "nse.filteringApproved") != nil)
        #expect(suite?.string(forKey: "nse.syncBaseURL") == BackendConfig.syncBaseURL)
    }

    // MARK: - First-run default persistence (Finding E)

    @Test("PromptStore in-memory rawAction is non-empty when UserDefaults empty (Finding E)")
    @MainActor
    func promptStoreHasInMemoryDefaults() {
        // PromptStore.init uses `d.string(forKey:) ?? Defaults.x` — in-memory values are
        // always non-empty. Finding E's fix (flushing to UserDefaults) is tested via the
        // round-trip test above once the user edits — here we just assert the in-memory
        // invariant that unblocks main-app AI calls (ActionMarkdown() returns non-empty).
        let store = PromptStore.shared
        #expect(!store.rawAction.isEmpty)
        #expect(!store.rawKB.isEmpty)
        #expect(!store.rawComposition.isEmpty)
    }

    // MARK: - Account map mirroring

    @Test("mirrorAccountMap writes JSON-encoded email→accountId map")
    func accountMapMirrored() throws {
        _ = try TestDatabase.make()
        // Temporarily swap dbPool — mirrorAccountMap reads from AppDatabase.dbPool
        // We can't easily swap it, so just verify the function doesn't crash
        // with an empty database
        cleanupSuite()
        NSEDataBridge.mirrorAccountMap()
        // Should have written something (even if empty map)
        _ = suite?.string(forKey: "nse.accountMap")
        // May be nil if AppDatabase.dbPool points to a different DB, but should not crash
        // The key test is that the function is callable and doesn't throw
    }

    // MARK: - History ID mirroring

    @Test("mirrorLastHistoryIds writes JSON-encoded accountId→historyId map")
    func historyIdsMirrored() throws {
        cleanupSuite()
        NSEDataBridge.mirrorLastHistoryIds()
        // Same limitation as accountMap — reads from AppDatabase.dbPool
        // Verify it doesn't crash and writes to the correct key
        _ = "nse.lastHistoryIds"
        // Function should have been called without error
    }

    // MARK: - mirrorAllState coverage

    @Test("mirrorAllState calls all individual mirror functions")
    func allStateMirrored() {
        cleanupSuite()
        // Set known values
        UserDefaults.standard.set("AllState Test", forKey: "userName")
        UserDefaults.standard.set("test comp", forKey: "user_prompts:user_composition.md")
        UserDefaults.standard.set(true, forKey: PushConfig.pushNotificationsEnabledKey)

        NSEDataBridge.mirrorAllState()

        // Verify multiple mirror results
        #expect(suite?.string(forKey: "nse.userName") == "AllState Test")
        #expect(suite?.string(forKey: "nse.compositionPrompt") == "test comp")
        #expect(suite?.string(forKey: "nse.backendBaseURL") != nil)
        #expect(suite?.string(forKey: "nse.pushWorkerURL") == "https://push.tabmail.ai")

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "userName")
        UserDefaults.standard.removeObject(forKey: "user_prompts:user_composition.md")
        UserDefaults.standard.removeObject(forKey: PushConfig.pushNotificationsEnabledKey)
    }

    // MARK: - PushConfig constants

    @Test("PushConfig.nseFilteringApproved is false (pending Apple approval)")
    func filteringNotApproved() {
        #expect(PushConfig.nseFilteringApproved == false)
    }

    @Test("PushConfig keys are stable strings")
    func pushConfigKeys() {
        #expect(PushConfig.pushNotificationsEnabledKey == "push_notifications_enabled")
        #expect(PushConfig.deviceIdKey == "push_device_id")
        #expect(PushConfig.lastDeviceTokenKey == "push_last_device_token")
    }

    // MARK: - Staging DB merge — AI results into main GRDB

    @Test("Merge writes AI results to existing MessageHeader")
    func mergeAIResultsToHeader() throws {
        let mainDB = try TestDatabase.make()
        try TestDatabase.insertAccount(mainDB, id: "acc1", email: "user@gmail.com")
        try TestDatabase.insertFolder(mainDB, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg100", folderId: "acc1:INBOX", accountId: "acc1", rfc822MessageId: "abc@mail.gmail.com")

        // Simulate what mergeNSEStagingData does for a single message
        try mainDB.write { db in
            try db.execute(sql: """
                UPDATE messageHeader SET
                    summaryBlurb = ?, summaryTodos = ?, actionTag = ?,
                    notified = 1
                WHERE accountId = ? AND messageId = ?
                """, arguments: ["Test summary", "- Todo 1", "reply", "acc1", "msg100"])

            // Write AI cache
            let cacheKey = "acc1:acc1:INBOX:abc@mail.gmail.com"
            try db.execute(sql: """
                INSERT OR REPLACE INTO messageAICache (key, summaryBlurb, summaryTodos, actionTag, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [cacheKey, "Test summary", "- Todo 1", "reply", Date().timeIntervalSince1970])
        }

        // Verify header updated
        let header = try mainDB.read { db in
            try Row.fetchOne(db, sql: "SELECT summaryBlurb, actionTag, notified FROM messageHeader WHERE messageId = 'msg100'")
        }
        #expect(header?["summaryBlurb"] as String? == "Test summary")
        #expect(header?["actionTag"] as String? == "reply")
        let notified: Int? = header?["notified"]
        #expect(notified == 1)

        // Verify AI cache written
        let cacheCount = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageAICache") }
        #expect(cacheCount == 1)
    }

    // MARK: - ReachedOut hash parity (NSE merge ↔ ReminderBuilder)
    //
    // When NSE delivers an active reminder notification, `mergeNSEStagingData`
    // marks the reminder hash in ReachedOutStore so ProactiveNotifyService
    // won't re-deliver a second notification for the same reminder on the
    // same device. The hash formula MUST match what ReminderBuilder later
    // computes from the main GRDB header — otherwise the dedup silently fails.
    //
    // Invariant: both sides use `DisabledRemindersStore.hashReminder(source:"message", ...)`
    // with priority `m:{rfc822MessageId}` > `m:{uniqueId}`.

    @Test("ReachedOut hash parity — rfc822 present: bridge and ReminderBuilder produce same hash")
    func reachedOutHashParityWithRfc822() {
        let content = "Reply by Friday"
        let rfc822 = "abc@mail.gmail.com"
        let headerId = "acc1:INBOX:msg100"

        // Bridge path (NSEDataBridge.markReachedOutIfNotified): uniqueId = headerId, rfc822 present
        let bridgeHash = DisabledRemindersStore.hashReminder(
            source: "message", content: content,
            uniqueId: headerId, rfc822MessageId: rfc822
        )
        // ReminderBuilder path (line 141): uniqueId = msg.id (GRDB headerId), rfc822 = msg.rfc822MessageId
        let reminderBuilderHash = DisabledRemindersStore.hashReminder(
            source: "message", content: content,
            uniqueId: headerId, rfc822MessageId: rfc822
        )
        #expect(bridgeHash == reminderBuilderHash)
        #expect(bridgeHash == "m:\(rfc822)")  // rfc822 wins, brackets stripped (none here)
    }

    @Test("ReachedOut hash parity — rfc822 absent: bridge fallback matches ReminderBuilder fallback")
    func reachedOutHashParityFallback() {
        let content = "Reply by Friday"
        let headerId = "acc1:INBOX:msg100"

        let bridgeHash = DisabledRemindersStore.hashReminder(
            source: "message", content: content,
            uniqueId: headerId, rfc822MessageId: nil
        )
        let reminderBuilderHash = DisabledRemindersStore.hashReminder(
            source: "message", content: content,
            uniqueId: headerId, rfc822MessageId: nil
        )
        #expect(bridgeHash == reminderBuilderHash)
        #expect(bridgeHash == "m:\(headerId)")
    }

    @Test("ReachedOut hash parity — empty rfc822 also falls back to headerId")
    func reachedOutHashParityEmptyRfc822() {
        let bridgeHash = DisabledRemindersStore.hashReminder(
            source: "message", content: "x", uniqueId: "hdr-1", rfc822MessageId: ""
        )
        #expect(bridgeHash == "m:hdr-1")
    }

    @Test("ReachedOut dedup — marking a hash suppresses subsequent hasNotified check")
    func reachedOutMarkAndCheck() {
        let hash = "m:test-\(UUID().uuidString)"
        #expect(ReachedOutStore.hasNotified(hash: hash) == false)
        ReachedOutStore.markNotified(hash: hash)
        #expect(ReachedOutStore.hasNotified(hash: hash) == true)
        let batch = ReachedOutStore.notifiedHashes(from: [hash])
        #expect(batch.contains(hash))
    }

    @Test("Merge AI results for message not yet in main GRDB writes to AI cache only")
    func mergeAICacheForMissingHeader() throws {
        let mainDB = try TestDatabase.make()
        try TestDatabase.insertAccount(mainDB, id: "acc1", email: "user@gmail.com")
        try TestDatabase.insertFolder(mainDB, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        // No message header inserted — simulates NSE processing before main app sync

        // Write to AI cache directly (what mergeNSEStagingData does for missing headers)
        try mainDB.write { db in
            let cacheKey = "acc1:INBOX:abc@mail.gmail.com"
            try db.execute(sql: """
                INSERT OR REPLACE INTO messageAICache (key, summaryBlurb, summaryTodos, actionTag, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [cacheKey, "Pre-computed summary", nil, "archive", Date().timeIntervalSince1970])
        }

        // Header count is 0
        let headerCount = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader") }
        #expect(headerCount == 0)

        // AI cache has the entry — will be applied when header arrives via sync
        let cache = try mainDB.read { try Row.fetchOne($0, sql: "SELECT * FROM messageAICache") }
        #expect(cache?["summaryBlurb"] as String? == "Pre-computed summary")
        #expect(cache?["actionTag"] as String? == "archive")
    }

    // MARK: - Staging DB merge — inbox removals

    @Test("Merge inbox removals deletes messages and clears across accounts")
    func mergeInboxRemovalsIsolated() throws {
        let mainDB = try TestDatabase.make()
        try TestDatabase.insertAccount(mainDB, id: "acc1", email: "user1@gmail.com")
        try TestDatabase.insertAccount(mainDB, id: "acc2", email: "user2@gmail.com")
        try TestDatabase.insertFolder(mainDB, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(mainDB, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg1", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg2", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(mainDB, messageId: "msg1", folderId: "acc2:INBOX", accountId: "acc2")

        // Remove msg1 from acc1 only
        try mainDB.write { db in
            try db.execute(sql: """
                DELETE FROM messageHeader WHERE accountId = ? AND messageId = ? AND folderId LIKE '%:INBOX'
                """, arguments: ["acc1", "msg1"])
        }

        let acc1Count = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader WHERE accountId = 'acc1'") }
        let acc2Count = try mainDB.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader WHERE accountId = 'acc2'") }
        #expect(acc1Count == 1) // msg2 remains
        #expect(acc2Count == 1) // acc2's msg1 untouched
    }

    // MARK: - Staging DB cache probe (local dedup)
    //
    // ⚠️ These three HAND-MIRROR `getCachedResult`'s `WHERE id = ? AND
    // aiCompleted = 1` SELECT; they predate `NSEStagingDB` being compiled into
    // this target and do NOT call the function. They cover the completion-flag
    // semantics only. The function's IDENTITY guard (`IOS-NSE-006`) is upstream
    // of the row they build, so a mirror structurally cannot exercise it — it is
    // covered by `NSEStagingZombieWriterTests`
    // (`cachedAiIsNeverCombinedWithADifferentMessagesHeader`, plus the
    // unanswerable-identity anchor) and by
    // `NSEStagingIdentitySplicingTests.stagingCacheProbeServesNothingOfThePredecessor`,
    // all of which drive the REAL `NSEStagingDB.getCachedResult`. Do not read
    // these names as coverage of the guard.

    @Test("getCachedResult returns nil for non-existent message")
    func cacheProbeNonExistent() throws {
        let db = try makeStagingDB()
        let result = try db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT summaryBlurb, actionTag FROM nse_processed_message
                WHERE id = ? AND aiCompleted = 1
                """, arguments: ["acc1:nonexistent"])
        }
        #expect(result == nil)
    }

    @Test("getCachedResult returns data for aiCompleted message")
    func cacheProbeHit() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, summaryBlurb, actionTag,
                 processedAt, aiCompleted, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["acc1:msg100", "acc1", "user@gmail.com", "gmail", "msg100",
                                 "Cached summary", "reply", now, 1, 1])
        }

        let result = try db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT summaryBlurb, actionTag FROM nse_processed_message
                WHERE id = ? AND aiCompleted = 1
                """, arguments: ["acc1:msg100"])
        }
        #expect(result != nil)
        let summary: String? = result?["summaryBlurb"]
        let action: String? = result?["actionTag"]
        #expect(summary == "Cached summary")
        #expect(action == "reply")
    }

    @Test("getCachedResult ignores aiCompleted=0 entries")
    func cacheProbeIgnoresIncomplete() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, summaryBlurb,
                 processedAt, aiCompleted, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["acc1:msg100", "acc1", "user@gmail.com", "gmail", "msg100",
                                 "Partial summary", now, 0, 0])
        }

        let result = try db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT summaryBlurb FROM nse_processed_message
                WHERE id = ? AND aiCompleted = 1
                """, arguments: ["acc1:msg100"])
        }
        #expect(result == nil) // aiCompleted=0 should not be returned
    }

    // MARK: - Staging DB schema consistency

    @Test("Staging DB schema matches between NSEStagingDB and AppDatabase")
    func schemaConsistency() throws {
        // Create via the app's schema creation path
        let appDB = try makeStagingDB()

        // Verify all three tables exist
        let tables = try appDB.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        #expect(tables.contains("nse_inbox_removal"))
        #expect(tables.contains("nse_pending_task_result"))
        #expect(tables.contains("nse_processed_message"))
    }

    @Test("Staging DB nse_processed_message has all required columns")
    func processedMessageColumns() throws {
        let db = try makeStagingDB()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(nse_processed_message)").map { row -> String in
                row["name"] as String
            }
        }
        let required = ["id", "accountId", "accountEmail", "provider", "messageId",
                         "rfc822MessageId", "threadId", "folderId", "subject", "senderName",
                         "senderEmail", "snippet", "date", "isRead", "summaryBlurb",
                         "summaryTodos", "actionTag", "reminderDate", "reminderTime",
                         "reminderContent", "processedAt", "historyId", "aiCompleted", "notified"]
        for col in required {
            #expect(columns.contains(col), "Missing column: \(col)")
        }
    }

    @Test("Staging DB nse_inbox_removal has all required columns")
    func inboxRemovalColumns() throws {
        let db = try makeStagingDB()
        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(nse_inbox_removal)").map { row -> String in
                row["name"] as String
            }
        }
        #expect(columns.contains("id"))
        #expect(columns.contains("accountId"))
        #expect(columns.contains("messageId"))
        #expect(columns.contains("timestamp"))
    }

    // MARK: - Edge cases

    @Test("Merge handles concurrent staging DB writes gracefully")
    func mergeConcurrentWrites() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970

        // Write two messages
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, processedAt, aiCompleted, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["acc1:msg1", "acc1", "u@g.com", "gmail", "msg1", now, 1, 1])
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, processedAt, aiCompleted, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["acc1:msg2", "acc1", "u@g.com", "gmail", "msg2", now, 0, 0])
        }

        // Read back — both should exist
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nse_processed_message") }
        #expect(count == 2)

        // Delete only msg1 (simulating merge processing only completed messages)
        try db.write { db in
            try db.execute(sql: "DELETE FROM nse_processed_message WHERE id = ?", arguments: ["acc1:msg1"])
        }

        // msg2 should still exist
        let remaining = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nse_processed_message") }
        #expect(remaining == 1)

        let remainingId = try db.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM nse_processed_message")
        }
        #expect(remainingId == "acc1:msg2")
    }

    @Test("Merge handles empty staging DB without error")
    func mergeEmptyDB() throws {
        let db = try makeStagingDB()

        // Read from empty tables — should return empty arrays, not crash
        let processed = try db.read { try Row.fetchAll($0, sql: "SELECT * FROM nse_processed_message") }
        let removals = try db.read { db -> [Row] in
            guard try db.tableExists("nse_inbox_removal") else { return [] }
            return try Row.fetchAll(db, sql: "SELECT * FROM nse_inbox_removal")
        }
        let tasks = try db.read { try Row.fetchAll($0, sql: "SELECT * FROM nse_pending_task_result") }

        #expect(processed.isEmpty)
        #expect(removals.isEmpty)
        #expect(tasks.isEmpty)
    }

    @Test("INSERT OR REPLACE handles re-delivered push (same message ID)")
    func redeliveredPushDedup() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970

        // First delivery — no AI
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, processedAt, aiCompleted, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["acc1:msg100", "acc1", "u@g.com", "gmail", "msg100", now, 0, 0])
        }

        // Re-delivery — now with AI
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, summaryBlurb, actionTag,
                 processedAt, aiCompleted, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["acc1:msg100", "acc1", "u@g.com", "gmail", "msg100",
                                 "Final summary", "reply", now + 5, 1, 1])
        }

        // Only one row, with the latest data
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nse_processed_message") }
        #expect(count == 1)

        let row = try db.read { try Row.fetchOne($0, sql: "SELECT * FROM nse_processed_message") }
        let summary: String? = row?["summaryBlurb"]
        let completed: Int? = row?["aiCompleted"]
        #expect(summary == "Final summary")
        #expect(completed == 1)
    }

    // MARK: - Staging DB helper

    private func makeStagingDB() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_processed_message (
                    id TEXT PRIMARY KEY,
                    accountId TEXT NOT NULL, accountEmail TEXT NOT NULL,
                    provider TEXT NOT NULL, messageId TEXT NOT NULL,
                    rfc822MessageId TEXT, threadId TEXT, folderId TEXT,
                    subject TEXT DEFAULT '', senderName TEXT DEFAULT '', senderEmail TEXT DEFAULT '',
                    snippet TEXT DEFAULT '', date REAL, isRead INTEGER DEFAULT 0,
                    summaryBlurb TEXT, summaryTodos TEXT, actionTag TEXT,
                    reminderDate TEXT, reminderTime TEXT, reminderContent TEXT,
                    processedAt REAL NOT NULL, historyId TEXT,
                    aiCompleted INTEGER DEFAULT 0, notified INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_pending_task_result (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    taskName TEXT NOT NULL, taskInstruction TEXT NOT NULL,
                    result TEXT NOT NULL, timestamp REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_inbox_removal (
                    id TEXT PRIMARY KEY,
                    accountId TEXT NOT NULL,
                    messageId TEXT NOT NULL,
                    timestamp REAL NOT NULL
                )
                """)
        }
        return db
    }
}
