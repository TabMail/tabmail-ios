/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Comprehensive local data wipe — reusable by both SettingsView "Reset Everything"
/// and account deletion flow.
enum AppDataWiper {
    @MainActor
    static func wipeAll() async {
        let manager = AccountManager.shared
        let dbPool = AppDatabase.dbPool
        // Read accounts directly from GRDB (not tied to NavigationStore/UI)
        let accounts = (try? await dbPool.read { db in try Account.fetchAll(db) }) ?? []

        // Read the CalDAV config ids NOW, before step 5 wipes the tables.
        //
        // ⚠️ ORDERING IS LOAD-BEARING, not stylistic. `caldavConfig.accountId` is
        // `.references("account", onDelete: .cascade)`, so `DELETE FROM account` destroys these rows —
        // and each row's id is the ONLY way to name its `caldav_password_<id>` Keychain item. Read
        // them after the wipe and the passwords become unenumerable orphans that survive app deletion
        // with no code path left that can name them. That is exactly why they leak today.
        let caldavConfigIds = (try? await dbPool.read { db in
            try CalDAVConfig.fetchAll(db).map(\.id)
        }) ?? []

        // 1. Unsubscribe all accounts from push (needs access tokens still in Keychain)
        for account in accounts {
            await PushNotificationService.shared.unsubscribeAccount(account)
        }

        // 2. Unregister device from push worker
        await PushNotificationService.shared.unregisterDevice()

        // 3. Disconnect all IMAP/Gmail providers and clear per-account keychain tokens
        for account in accounts {
            await manager.disconnectAccount(account)
            KeychainHelper.delete(key: KeychainHelper.passwordKey(accountId: account.id))
            KeychainHelper.delete(key: KeychainHelper.accessTokenKey(accountId: account.id))
            KeychainHelper.delete(key: KeychainHelper.refreshTokenKey(accountId: account.id))
        }

        // 4. Disconnect Device Sync WebSocket
        DeviceSyncService.shared.disconnect()

        // 5. Nuke all database tables. Order still matters for the foreign keys that
        // remain (folder/account cascades). `messageBody` no longer has one — Stage D
        // dropped it — so its explicit DELETE here is now REQUIRED rather than merely
        // ordered: nothing else would remove those rows.
        try? await dbPool.write { db in
            try db.execute(sql: "DELETE FROM messageBody")
            try db.execute(sql: "DELETE FROM messageHeader")
            try db.execute(sql: "DELETE FROM pendingOperation")
            try db.execute(sql: "DELETE FROM messageAICache")
            try db.execute(sql: "DELETE FROM chatTurn")
            try db.execute(sql: "DELETE FROM chatHistory")
            try db.execute(sql: "DELETE FROM chatIdMapping")
            try db.execute(sql: "DELETE FROM outboxMessage")
            try db.execute(sql: "DELETE FROM pendingCalendarOperation")
            try db.execute(sql: "DELETE FROM folder")
            try db.execute(sql: "DELETE FROM account")
        }
        // Reclaim disk space — VACUUM can't run inside a transaction
        try? await dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }

        // 5b. Delete outbox attachment files from disk
        let attachmentsDir = OutboxMessage.attachmentsBaseDir
        try? FileManager.default.removeItem(at: attachmentsDir)

        // 6. Reset FTS index and reclaim its disk space
        await AccountManager.shared.syncEngine.cancelAllFTSTasks()
        try? await SearchIndex.shared.resetAll()
        try? await SearchIndex.shared.vacuum()
        // 6b. Wipe memory.db (ADR-IOS-034). memory.db lives in a
        // separate file; without this, cleared conversations remain searchable.
        await MemoryIndex.shared.deleteAll()

        // 7. Clear ALL UserDefaults — prompts, Device Sync state, settings, migration flags
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }

        // 8. Clear TabMail session (Keychain) and sign out → returns to login screen
        TabMailAuthService.clearSession()

        // 8b. Clear the remaining Keychain items. Keychain survives app DELETION, so anything missed
        // here outlives not just this wipe but a delete-and-reinstall, and is then silently adopted by
        // whoever uses the device next.
        //
        // Enumerated from the Keychain WRITE sites rather than from what this function already deleted
        // — a census that starts from the existing cleanup can only ever confirm itself.
        //
        // BYOK is the sharp one: `saveBYOK` keys by provider name (`kSecAttrAccount = "openai"`), a
        // deterministic and NON-per-user string. So after a reset, `loadBYOK` returns the previous
        // owner's key and `AIService` attaches it to requests — the next user's usage is billed to the
        // person who reset the device. That is a real financial consequence, not just stale state.
        for provider in BYOKProviderInfo.allProviders {
            KeychainHelper.deleteBYOK(provider: provider)
        }
        // CalDAV passwords, using the ids captured before the tables were wiped.
        for configId in caldavConfigIds {
            KeychainHelper.delete(key: "caldav_password_\(configId)")
        }
        // Demo-mode session token (ADR-IOS-038).
        DemoTokenManager.clearSession()

        print("[AppDataWiper] Local data wiped — true factory reset")

        // Navigate to login screen
        NotificationCenter.default.post(name: .tabMailDidSignOut, object: nil)
    }
}
