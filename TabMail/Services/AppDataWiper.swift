/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Comprehensive local data wipe — reusable by both SettingsView "Reset Everything"
/// and account deletion flow.
enum AppDataWiper {
    private struct AccountCleanupPlan {
        let account: Account
        let caldavConfigIds: [String]
        let outboxMessages: [OutboxMessage]
        let capturedAccessToken: String?
    }

    /// A precondition of the wipe could not be read, so nothing was deleted.
    ///
    /// Deliberately a thrown error rather than a silent no-op: the identifiers this reads are the only
    /// way to name the Keychain items belonging to the rows the wipe is about to destroy, so
    /// continuing without them would delete the rows and permanently orphan the secrets.
    enum WipeError: Error {
        case couldNotEnumerateKeychainOwners(underlying: Error)
        case localCleanupIncomplete(underlying: Error)
        case remoteAccountCleanupDeferred
        case deviceUnregisterFailed(underlying: Error)
    }

    /// ⚠️ NOT WIRED TO ANY UI. `wipeAll` has no callers in the app — verified by searching every
    /// target's sources; the only other mentions of `AppDataWiper` are comments and a metatype test.
    /// The user-reachable "delete account" flow is `AccountDeletionView.scopedTabMailCleanup`, which
    /// deliberately preserves email accounts, local messages, and therefore the BYOK and CalDAV
    /// secrets that belong to them. So this function is a factory-reset utility kept correct for a
    /// future caller, not a live code path — do not cite it as evidence that a reset happens.
    @MainActor
    static func wipeAll() async throws {
        let manager = AccountManager.shared
        let dbPool = AppDatabase.dbPool

        // Read the ids of every row whose Keychain items this wipe must delete, BEFORE the transaction wipes
        // the tables.
        //
        // ⚠️ ORDERING IS LOAD-BEARING, not stylistic. `caldavConfig.accountId` is
        // `.references("account", onDelete: .cascade)`, so `DELETE FROM account` destroys those rows —
        // and each row's id is the ONLY way to name its `caldav_password_<id>` Keychain item. Read
        // them after the wipe and the passwords become unenumerable orphans that survive app deletion
        // with no code path left that can name them.
        //
        // ⚠️ These reads FAIL CLOSED and must stay that way. They were `(try? …) ?? []`, which turned
        // any read failure — GRDB suspension (0xdead10cc), corruption, a migration failure — into an
        // empty id list: the wipe would delete the rows, iterate nothing, log "true factory reset" and
        // post `.tabMailDidSignOut`, having produced exactly the unenumerable orphans described above
        // while reporting success. Unlike most edges in this codebase that failure is NOT recoverable
        // by a sync pass, a retry, or any number of user gestures — once the rows are gone no code can
        // name the items again — so per THE MANTRA it is a defect, not a registrable edge.
        let plans: [AccountCleanupPlan]
        do {
            let inventory = try await dbPool.read { db -> [(Account, [String], [OutboxMessage])] in
                let accounts = try Account.fetchAll(db)
                return try accounts.map { account in
                    let caldavIds = try CalDAVConfig
                        .filter(Column("accountId") == account.id)
                        .fetchAll(db)
                        .map(\.id)
                    let outbox = try OutboxMessage
                        .filter(Column("accountId") == account.id)
                        .fetchAll(db)
                    return (account, caldavIds, outbox)
                }
            }
            plans = inventory.map { account, caldavIds, outbox in
                let accessToken: String?
                switch account.provider {
                case .gmail, .outlook:
                    accessToken = KeychainHelper.loadString(
                        key: KeychainHelper.accessTokenKey(accountId: account.id)
                    )
                default:
                    accessToken = nil
                }
                return AccountCleanupPlan(
                    account: account,
                    caldavConfigIds: caldavIds,
                    outboxMessages: outbox,
                    capturedAccessToken: accessToken
                )
            }
        } catch {
            print("[AppDataWiper] ABORTED before deleting anything — could not enumerate Keychain owners: \(error)")
            throw WipeError.couldNotEnumerateKeychainOwners(underlying: error)
        }

        let push = PushNotificationService.shared
        var cleanupGenerations: [UUID] = []
        for plan in plans {
            NSEDataBridge.removeAccountFromMirrors(
                accountId: plan.account.id,
                email: plan.account.emailAddress
            )
            let generation = await push.prepareRemovedAccountCleanup(
                plan.account,
                caldavConfigIds: plan.caldavConfigIds,
                outboxAttachmentDirNames: plan.outboxMessages.compactMap(\.attachmentsDirName)
            )
            cleanupGenerations.append(generation)
        }

        // Make row removal authoritative over every accepted settings edit.
        // Each discard drains already-admitted work but fences queued closures.
        for plan in plans {
            await AccountFieldPersistenceStore.production.discardAccount(plan.account.id)
        }

        // 1. Nuke all database tables. This is the authoritative boundary and
        // deliberately precedes every credential/provider/local-index side effect.
        // If it throws, `wipeAll` throws and nothing else is deleted.
        // Order still matters for the foreign keys that
        // remain (folder/account cascades). `messageBody` no longer has one — Stage D
        // dropped it — so its explicit DELETE here is now REQUIRED rather than merely
        // ordered: nothing else would remove those rows.
        do {
            try await dbPool.write { db in
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
        } catch {
            for plan in plans {
                AccountFieldPersistenceStore.production.reactivateAccount(plan.account.id)
            }
            for generation in cleanupGenerations {
                await push.cancelPreparedRemovedAccountCleanup(generation: generation)
            }
            // This method is MainActor-isolated, while mirror derivation uses
            // synchronous GRDB reads. Keep rollback work off the UI executor.
            await Task.detached(priority: .utility) {
                NSEDataBridge.mirrorAccountMap()
                NSEDataBridge.mirrorIMAPAccounts()
            }.value
            throw error
        }

        // The authoritative rows are gone even if a later local/remote cleanup
        // reports a partial result. Refresh row-backed UI immediately.
        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)

        // The rows committed absent. Runtime/credential detachment is now the
        // first post-commit work, using the CalDAV IDs captured above. Each debt
        // generation is then released to the durable drain.
        for (plan, generation) in zip(plans, cleanupGenerations) {
            await manager.disconnectAccount(
                plan.account,
                deletingCredentials: plan.caldavConfigIds
            )
            await push.commitPreparedRemovedAccountCleanup(
                generation: generation,
                capturedOAuthAccessToken: plan.capturedAccessToken
            )
            for message in plan.outboxMessages { message.deleteAttachments() }
            await push.retryPendingRemovedAccountCleanups(
                onlyEmail: plan.account.emailAddress
            )
        }

        // 2. Disconnect Device Sync WebSocket.
        DeviceSyncService.shared.disconnect()

        // Reclaim disk space — VACUUM can't run inside a transaction
        try? await dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }

        // 5b. Delete outbox attachment files from disk
        let attachmentsDir = OutboxMessage.attachmentsBaseDir
        try? FileManager.default.removeItem(at: attachmentsDir)

        // 6. Reset FTS index and reclaim its disk space
        await AccountManager.shared.syncEngine.cancelAllFTSTasks()
        var localCleanupError: (any Error)?
        do {
            try await SearchIndex.shared.resetAll()
            try await SearchIndex.shared.vacuum()
        } catch {
            localCleanupError = error
            print("[AppDataWiper] Search index reset failed after row commit: \(error)")
        }
        // 6b. Wipe memory.db (ADR-IOS-034). memory.db lives in a
        // separate file; without this, cleared conversations remain searchable.
        do {
            try await MemoryIndex.shared.deleteAllThrowing()
        } catch {
            if localCleanupError == nil { localCleanupError = error }
            print("[AppDataWiper] Memory index reset failed after row commit: \(error)")
        }

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
        for configId in plans.flatMap(\.caldavConfigIds) {
            KeychainHelper.delete(key: "caldav_password_\(configId)")
        }
        // Demo-mode session token (ADR-IOS-038).
        DemoTokenManager.clearSession()

        // Remote failure must never prevent the local privacy wipe above. It
        // gates only auth/default clearing and the final success report, keeping
        // the original JWT and durable debt available for a retry.
        await push.retryPendingRemovedAccountCleanups()
        let hasPendingRemoteCleanup = await push.hasPendingRemovedAccountCleanups()
        var deviceUnregisterError: (any Error)?
        do {
            try await push.unregisterDeviceForReset()
        } catch {
            deviceUnregisterError = error
            print("[AppDataWiper] Device unregister remains retryable: \(error)")
        }

        if let localCleanupError {
            throw WipeError.localCleanupIncomplete(underlying: localCleanupError)
        }
        if hasPendingRemoteCleanup {
            print("[AppDataWiper] Local data wiped; remote account cleanup remains retryable")
            throw WipeError.remoteAccountCleanupDeferred
        }
        if let deviceUnregisterError {
            throw WipeError.deviceUnregisterFailed(underlying: deviceUnregisterError)
        }

        // 7. Clear ALL UserDefaults only after cleanup debt is empty. Preserve
        // the debt tuple + device identity defensively across domain removal in
        // case another exact generation was synchronously prepared meanwhile.
        if let bundleId = Bundle.main.bundleIdentifier {
            let defaults = UserDefaults.standard
            let pendingDebt = defaults.data(forKey: PushConfig.removedAccountCleanupKey)
            let pendingDeviceId = defaults.string(forKey: PushConfig.deviceIdKey)
            defaults.removePersistentDomain(forName: bundleId)
            if let pendingDebt {
                defaults.set(pendingDebt, forKey: PushConfig.removedAccountCleanupKey)
                if let pendingDeviceId {
                    defaults.set(pendingDeviceId, forKey: PushConfig.deviceIdKey)
                }
            }
        }

        // 8. Clear TabMail session (Keychain) and sign out → returns to login screen
        TabMailAuthService.clearSession()

        print("[AppDataWiper] Local data wiped — true factory reset")

        // Navigate to login screen
        NotificationCenter.default.post(name: .tabMailDidSignOut, object: nil)
    }
}
