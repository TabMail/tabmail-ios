/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

enum AccountRemovalError: LocalizedError {
    case searchIndexCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .searchIndexCleanupFailed(let detail):
            "The account was removed, but its search index could not be cleared: \(detail)"
        }
    }
}

extension AccountManager {

    // MARK: - Gmail Account Setup

    func addGmailAccount() async throws -> Account {
        let tokens = try await oauthService.authenticateGoogle()
        return try await addGmailAccountWithTokens(tokens)
    }

    /// Creates a Gmail account using pre-obtained tokens (merged sign-in flow)
    /// or tokens just obtained via OAuth popup.
    func addGmailAccountWithTokens(_ tokens: OAuthTokens) async throws -> Account {
        let userInfo = try await oauthService.fetchGoogleUserInfo(accessToken: tokens.accessToken)
        return try await setupOAuthAccount(
            email: userInfo.email,
            displayName: userInfo.name,
            provider: .gmail,
            tokens: tokens
        )
    }

    // MARK: - Outlook Account Setup

    func addOutlookAccount() async throws -> Account {
        let tokens = try await oauthService.authenticateMicrosoft()
        return try await addOutlookAccountWithTokens(tokens)
    }

    /// Creates an Outlook account using pre-obtained tokens (merged sign-in flow)
    /// or tokens just obtained via OAuth popup.
    func addOutlookAccountWithTokens(_ tokens: OAuthTokens) async throws -> Account {
        let userInfo = try await oauthService.fetchMicrosoftUserInfo(accessToken: tokens.accessToken)
        return try await setupOAuthAccount(
            email: userInfo.email,
            displayName: userInfo.name,
            provider: .outlook,
            tokens: tokens
        )
    }

    // MARK: - Shared OAuth Account Setup

    /// Common setup for Gmail and Outlook accounts. Handles duplicate detection,
    /// Keychain storage, GRDB insert, provider connection, initial sync, and push.
    private func setupOAuthAccount(
        email: String,
        displayName: String,
        provider: AccountProvider,
        tokens: OAuthTokens
    ) async throws -> Account {
        // Guard: if an account with the same email+provider already exists,
        // update its tokens and reconnect instead of creating a duplicate.
        let providerRaw = provider.rawValue
        if let existing = try await dbPool.read({ db in
            try Account.filter(Column("emailAddress") == email && Column("provider") == providerRaw).fetchOne(db)
        }) {
            try KeychainHelper.save(tokens.accessToken, for: KeychainHelper.accessTokenKey(accountId: existing.id))
            if let refresh = tokens.refreshToken {
                try KeychainHelper.save(refresh, for: KeychainHelper.refreshTokenKey(accountId: existing.id))
            }
            await disconnectAccount(existing)
            try await connectAccount(existing)
            return existing
        }

        let account = Account(
            emailAddress: email,
            displayName: displayName,
            provider: provider
        )

        // Store tokens in Keychain
        try KeychainHelper.save(tokens.accessToken, for: KeychainHelper.accessTokenKey(accountId: account.id))
        if let refresh = tokens.refreshToken {
            try KeychainHelper.save(refresh, for: KeychainHelper.refreshTokenKey(accountId: account.id))
        }

        // Save to GRDB — notify NavigationStore to refresh
        // Auto-promote to primary if no other primary account exists.
        let acct = account
        try await dbPool.write { db in
            let hasPrimary = try Account.filter(Column("isPrimary") == true && Column("isActive") == true).fetchCount(db) > 0
            var toInsert = acct
            if !hasPrimary { toInsert.isPrimary = true }
            try toInsert.insert(db)
        }
        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)

        // Once a real account is added (not demo),
        // purge any orphaned demo rows. The login-screen demo button hides
        // automatically via `navigationStore.hasAnyAccount` once the new
        // account row commits and `.backgroundDataDidChange` propagates.
        if acct.id != DemoSeed.demoAccountId {
            await DemoModeService.purgeOrphanedDemoData()
        }

        // Connect provider (fast — validates tokens, no data fetch)
        try await connectAccount(account)

        // Kick off initial sync in background so the UI dismisses immediately.
        // SyncEngine.syncing guard prevents double-sync if RootView.foregroundSyncAll fires.
        let engine = syncEngine
        Task {
            do {
                try await engine.sync(account: account)
            } catch {
                print("[AccountManager] Background initial sync failed for \(account.emailAddress): \(error)")
            }
        }

        // Subscribe for push notifications
        Task { await PushNotificationService.shared.subscribeAccount(account) }

        // If NSE is already on, ask MailNavigationView to present the
        // explainer alert. On Continue, it calls
        // `ensurePushConsentAfterAccountAdd` (provider-agnostic — dispatches
        // to Gmail or Microsoft OAuth internally). No-ops here when NSE
        // is off; the flow will be triggered later on toggle ON.
        let nseEnabled = UserDefaults.standard.object(forKey: PushConfig.pushNotificationsEnabledKey) as? Bool ?? false
        if nseEnabled && account.hasPushSupport {
            NotificationCenter.default.post(
                name: .pushConsentExplainerNeeded,
                object: nil,
                userInfo: [
                    "email": account.emailAddress,
                    "provider": account.provider.rawValue,
                ]
            )
        }

        // Mirror account map to shared UserDefaults for NSE
        NSEDataBridge.mirrorAccountMap()

        // Rerun the foreground consent-status scan so the banner reflects
        // the freshly-added account. Without this trigger, the banner only
        // updates on next app foreground-return / launch — confusing when
        // the user just added an account with NSE push on.
        Task { @MainActor in
            await PushNotificationService.shared.checkPushConsentStatusForForeground()
        }

        return account
    }

    // MARK: - IMAP Account Setup

    func addIMAPAccount(
        displayName: String,
        email: String,
        username: String,
        password: String,
        imapHost: String,
        imapPort: Int,
        smtpHost: String,
        smtpPort: Int
    ) async throws -> Account {
        // Test connection first — use username for auth (falls back to email if empty)
        let authUser = username.isEmpty ? email : username
        let testProvider = IMAPProvider(
            host: imapHost,
            port: imapPort,
            username: authUser,
            password: password,
            senderEmail: email,
            smtpHost: smtpHost,
            smtpPort: smtpPort
        )
        try await testProvider.connect()

        var account = Account(
            emailAddress: email,
            displayName: displayName.isEmpty ? email : displayName,
            provider: .imap
        )
        account.imapUsername = username.isEmpty ? nil : username
        account.imapHost = imapHost
        account.imapPort = imapPort
        account.smtpHost = smtpHost
        account.smtpPort = smtpPort

        // Store password in Keychain
        try KeychainHelper.save(password, for: KeychainHelper.passwordKey(accountId: account.id))

        // Save to GRDB — notify NavigationStore to refresh
        // Auto-promote to primary if no other primary account exists.
        let acct = account
        try await dbPool.write { db in
            let hasPrimary = try Account.filter(Column("isPrimary") == true && Column("isActive") == true).fetchCount(db) > 0
            var toInsert = acct
            if !hasPrimary { toInsert.isPrimary = true }
            try toInsert.insert(db)
        }
        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)

        // Once a real account is added (not demo),
        // purge any orphaned demo rows. The login-screen demo button hides
        // automatically via `navigationStore.hasAnyAccount` once the new
        // account row commits and `.backgroundDataDidChange` propagates.
        if acct.id != DemoSeed.demoAccountId {
            await DemoModeService.purgeOrphanedDemoData()
        }

        providers[account.id] = testProvider
        let concurrency: Int
        switch account.provider {
        case .gmail: concurrency = SyncConfig.gmailWorkQueueConcurrency
        case .outlook: concurrency = SyncConfig.exchangeWorkQueueConcurrency
        default: concurrency = SyncConfig.imapMaxConnectionCeiling
        }
        let queue = ProviderWorkQueue(provider: testProvider, maxConcurrency: concurrency)
        workQueues[account.id] = queue
        await syncEngine.register(accountId: account.id, provider: testProvider, workQueue: queue)

        // Kick off initial sync in background so the UI dismisses immediately.
        let engine = syncEngine
        let syncAccount = account
        Task { @Sendable in
            do {
                try await engine.sync(account: syncAccount)
            } catch {
                print("[AccountManager] Background initial sync failed for \(syncAccount.emailAddress): \(error)")
            }
        }

        return account
    }

    // MARK: - iCloud Account Setup

    func addICloudAccount(
        email: String,
        appSpecificPassword: String,
        includeCalendar: Bool
    ) async throws -> Account {
        // Use email for IMAP auth (try full email first — Apple typically accepts this)
        let testProvider = IMAPProvider(
            host: ICloudConfig.imapHost,
            port: ICloudConfig.imapPort,
            username: email,
            password: appSpecificPassword,
            senderEmail: email,
            smtpHost: ICloudConfig.smtpHost,
            smtpPort: ICloudConfig.smtpPort
        )
        try await testProvider.connect()

        var account = Account(
            emailAddress: email,
            displayName: email.components(separatedBy: "@").first ?? email,
            provider: .icloud
        )
        account.imapHost = ICloudConfig.imapHost
        account.imapPort = ICloudConfig.imapPort
        account.smtpHost = ICloudConfig.smtpHost
        account.smtpPort = ICloudConfig.smtpPort

        // Store password in Keychain
        try KeychainHelper.save(appSpecificPassword, for: KeychainHelper.passwordKey(accountId: account.id))

        // Save to GRDB — notify NavigationStore to refresh
        let acct = account
        try await dbPool.write { db in
            let hasPrimary = try Account.filter(Column("isPrimary") == true && Column("isActive") == true).fetchCount(db) > 0
            var toInsert = acct
            if !hasPrimary { toInsert.isPrimary = true }
            try toInsert.insert(db)
        }
        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)

        // Once a real account is added (not demo),
        // purge any orphaned demo rows. The login-screen demo button hides
        // automatically via `navigationStore.hasAnyAccount` once the new
        // account row commits and `.backgroundDataDidChange` propagates.
        if acct.id != DemoSeed.demoAccountId {
            await DemoModeService.purgeOrphanedDemoData()
        }

        providers[account.id] = testProvider
        let concurrency: Int
        switch account.provider {
        case .gmail: concurrency = SyncConfig.gmailWorkQueueConcurrency
        case .outlook: concurrency = SyncConfig.exchangeWorkQueueConcurrency
        default: concurrency = SyncConfig.imapMaxConnectionCeiling
        }
        let queue = ProviderWorkQueue(provider: testProvider, maxConcurrency: concurrency)
        workQueues[account.id] = queue
        await syncEngine.register(accountId: account.id, provider: testProvider, workQueue: queue)

        // Set up CalDAV if requested. Best-effort: the email account is the
        // primary entity and its IMAP connection was already validated above,
        // so a calendar (CalDAV) failure must NOT fail the whole add. Otherwise
        // a transient iCloud CalDAV hiccup would both (a) strand the committed
        // email account behind a "failed" message and (b) block the user from
        // adding iCloud Mail at all (the onboarding form only offers
        // Mail+Calendar / Calendar-Only). iCloud uses the same app-specific
        // password for IMAP and CalDAV, so if IMAP connected a CalDAV failure
        // is almost always transient/server-side; the calendar can be
        // reconnected later.
        if includeCalendar {
            do {
                try await setupCalDAV(
                    accountId: account.id,
                    serverURL: ICloudConfig.caldavURL,
                    username: email,
                    password: appSpecificPassword,
                    displayName: "iCloud Calendar"
                )
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    print("[AccountManager] iCloud Calendar setup failed for \(account.emailAddress); email account kept: \(error)")
                }
                // Record the failure so the user is told: the returned account
                // drives the add-time alert; the persisted column drives the
                // persistent "Calendar not connected" note in Settings.
                account.calendarSetupFailed = true
                let failedId = account.id
                do {
                    try await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE account SET calendarSetupFailed = 1 WHERE id = ?",
                            arguments: [failedId]
                        )
                    }
                } catch let writeError {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[AccountManager] Failed to persist calendarSetupFailed for \(failedId): \(writeError)")
                    }
                }
            }
        }

        // Kick off initial sync in background
        let engine = syncEngine
        let syncAccount = account
        Task { @Sendable in
            do {
                try await engine.sync(account: syncAccount)
            } catch {
                print("[AccountManager] Background initial sync failed for \(syncAccount.emailAddress): \(error)")
            }
        }

        return account
    }

    /// Set up a CalDAV calendar for an account. Creates CalDAVConfig, runs discovery, creates provider.
    func setupCalDAV(
        accountId: String,
        serverURL: String,
        username: String,
        password: String,
        displayName: String?
    ) async throws {
        var config = CalDAVConfig(
            accountId: accountId,
            serverURL: serverURL,
            username: username,
            displayName: displayName
        )

        // Store password in Keychain
        let caldavPasswordKey = "caldav_password_\(config.id)"
        try KeychainHelper.save(password, for: caldavPasswordKey)

        do {
            // Run discovery
            guard let serverBaseURL = URL(string: serverURL) else {
                throw CalDAVError.discoveryFailed("Invalid server URL: \(serverURL)")
            }
            let client = CalDAVClient(username: username, password: password)
            let discovery = try await CalDAVDiscovery.discover(serverURL: serverBaseURL, client: client)
            config.principalURL = discovery.principalURL.absoluteString
            config.calendarHomeURL = discovery.calendarHomeURL.absoluteString

            // Save config to GRDB
            let configToInsert = config
            try await dbPool.write { db in
                try configToInsert.insert(db)
            }

            // Create and register provider
            let provider = CalDAVProvider(
                client: client,
                calendarHomeURL: discovery.calendarHomeURL,
                serverBaseURL: serverBaseURL
            )
            calendarProviders[accountId] = provider

            print("[AccountManager] CalDAV set up for account \(accountId): home=\(discovery.calendarHomeURL)")
        } catch {
            // Calendar setup failed after the password was written to the
            // Keychain but before a CalDAVConfig row exists to own it. config.id
            // is a fresh UUID, so this key is unreachable by removeAccount's
            // cleanup (which enumerates CalDAVConfig rows) — delete it here so a
            // failed attempt doesn't leak the app-specific password.
            KeychainHelper.delete(key: caldavPasswordKey)
            throw error
        }
    }

    /// Add a standalone CalDAV calendar account (no email).
    func addCalDAVAccount(
        serverURL: String,
        username: String,
        password: String,
        displayName: String?
    ) async throws -> Account {
        // Create synthetic account
        var account = Account(
            emailAddress: username,
            displayName: displayName ?? username,
            provider: .caldav
        )
        account.calendarOnly = true

        // Save to GRDB
        let acct = account
        try await dbPool.write { db in
            try acct.insert(db)
        }

        // Set up CalDAV. Unlike addICloudAccount, the calendar IS the account
        // here (calendar-only, no email), so a CalDAV failure must fail the
        // whole add — roll back the just-inserted synthetic account so it isn't
        // left orphaned behind the error message. The FK cascade clears any
        // caldavConfig row; setupCalDAV self-cleans its Keychain entry.
        do {
            try await setupCalDAV(
                accountId: account.id,
                serverURL: serverURL,
                username: username,
                password: password,
                displayName: displayName
            )
        } catch let setupError {
            let rollbackId = account.id
            do {
                try await dbPool.write { db in
                    _ = try Account.filter(Column("id") == rollbackId).deleteAll(db)
                }
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    print("[AccountManager] CalDAV rollback failed to delete synthetic account \(rollbackId): \(error)")
                }
            }
            throw setupError
        }

        return account
    }

    // MARK: - Account Management

    func removeAccount(_ account: Account) async throws {
        let acctId = account.id

        // Capture every identifier needed for post-commit file/Keychain cleanup
        // while the account graph still exists. These are reads only. If either
        // fails, nothing has been changed and the error is surfaced to Settings.
        let cleanupInventory = try await dbPool.read { db -> ([String], [OutboxMessage]) in
            let caldavIds = try CalDAVConfig
                .filter(Column("accountId") == acctId)
                .fetchAll(db)
                .map(\.id)
            let outboxMessages = try OutboxMessage
                .filter(Column("accountId") == acctId)
                .fetchAll(db)
            return (caldavIds, outboxMessages)
        }
        // A raw current access token is the most we retain for the one-shot
        // upstream watch stop. It is never persisted as cleanup debt and may be
        // stale; durable worker delivery-gate removal remains authoritative.
        let upstreamAccessToken: String?
        switch account.provider {
        case .gmail, .outlook:
            upstreamAccessToken = KeychainHelper.loadString(
                key: KeychainHelper.accessTokenKey(accountId: acctId)
            )
        default:
            upstreamAccessToken = nil
        }

        let push = PushNotificationService.shared
        let wasPrimary = account.isPrimary
        // Fail closed before the DB commit so process death can never leave a
        // committed deletion with usable NSE identity. If the row remains live,
        // the catch below or launch-time mirrorAllState restores both mirrors.
        NSEDataBridge.removeAccountFromMirrors(
            accountId: acctId,
            email: account.emailAddress
        )
        let cleanupGeneration = await push.prepareRemovedAccountCleanup(
            account,
            caldavConfigIds: cleanupInventory.0,
            outboxAttachmentDirNames: cleanupInventory.1.compactMap(\.attachmentsDirName)
        )

        // Account removal is authoritative over optimistic settings edits.
        // Await any write already admitted to GRDB, fence queued closures, and
        // purge retry/overlay state before the row-delete transaction begins.
        await AccountFieldPersistenceStore.production.discardAccount(acctId)
        do {
            try await dbPool.write { db in
                try Self.removeAccountRowsTxn(db, accountId: acctId, wasPrimary: wasPrimary)
            }
        } catch {
            await AccountFieldPersistenceStore.production.reactivateAccount(acctId)
            await push.cancelPreparedRemovedAccountCleanup(generation: cleanupGeneration)
            // The DB row is still authoritative. Re-derive both maps rather
            // than restoring a possibly stale captured Account snapshot.
            NSEDataBridge.mirrorAccountMap()
            NSEDataBridge.mirrorIMAPAccounts()
            throw error
        }

        NotificationCenter.default.post(name: .backgroundDataDidChange, object: nil)

        // This actor enters disconnectAccount synchronously: it tombstones the
        // account, removes every runtime route, invalidates OAuth/queue state,
        // and deletes credentials before that method reaches its first await.
        await disconnectAccount(account, deletingCredentials: cleanupInventory.0)
        await push.commitPreparedRemovedAccountCleanup(
            generation: cleanupGeneration,
            capturedOAuthAccessToken: upstreamAccessToken
        )
        for message in cleanupInventory.1 {
            message.deleteAttachments()
        }

        // The local removal is complete. Remote attempts must not hold Settings
        // open: every action was persisted before commit and foreground/launch
        // retries it after a failure or process death. Only this immediate pass
        // can use the raw token snapshot; relaunch sends an empty token, which
        // still revokes worker ownership and its subscription record.
        Task {
            await push.retryPendingRemovedAccountCleanups(
                onlyEmail: account.emailAddress
            )
        }

        // Rerun the foreground consent-status scan so the banner drops the
        // just-removed account from its error list immediately.
        Task { @MainActor in
            await PushNotificationService.shared.checkPushConsentStatusForForeground()
        }

        // FTS is derived and follows the authoritative commit, but a failure
        // still contains removed-account content. Surface the partial result
        // truthfully instead of logging false success.
        do {
            try await SearchIndex.shared.removeMessagesForAccount(accountId: acctId)
            print("[AccountManager] Cleaned up FTS entries for removed account \(acctId)")
        } catch {
            print("[AccountManager] Removed account but FTS cleanup failed for \(acctId): \(error)")
            throw AccountRemovalError.searchIndexCleanupFailed(error.localizedDescription)
        }
    }

    /// The whole database side of account removal, in ONE transaction.
    ///
    /// `nonisolated static` so tests can drive the real thing: `removeAccount`
    /// itself needs providers, Keychain and push unsubscription, none of which a
    /// unit test can stand up, and the invariant that matters here — **nothing of a
    /// removed account's mail is left behind** — is entirely a property of this
    /// transaction. Same idiom as `AccountManagerUidValidityReset
    /// .uidValidityResetPurgeTxn` and `SyncEngine.deleteConfirmedGhostHeaders`.
    nonisolated static func removeAccountRowsTxn(
        _ db: Database, accountId: String, wasPrimary: Bool
    ) throws {
        // Clean up non-cascaded tables first
        try PendingOperation.filter(Column("accountId") == accountId).deleteAll(db)
        try db.execute(sql: "DELETE FROM messageAICache WHERE key LIKE ? || ':%'", arguments: [accountId])
        // `messageBody` is keyed by CONTENT key, not by `messageHeader.id`, and
        // Stage D (`v70_dropMessageBodyHeaderFK`) removed the FK that used to carry
        // it out on the cascade. Without this the removed account's cached email
        // HTML would survive in the database for up to `bodyCacheTTLHours` after the
        // user asked for the account to be gone. LIKE-escaped (account ids are
        // colon-free UUIDs today, so this is hygiene rather than a fix) — content
        // keys share the header id's `accountId:folderPath:` prefix, so one prefix
        // covers every folder of the account.
        try db.execute(
            sql: #"DELETE FROM messageBody WHERE id LIKE ? ESCAPE '\'"#,
            arguments: [MessageIdentity.escapeForLike(accountId) + ":%"])
        // Cascade: account → folders → messageHeaders → outboxMessages.
        // (messageBody is NO LONGER on this chain — see the explicit delete above.)
        try Account.deleteOne(db, key: accountId)

        // Promote next oldest active account to primary if we just removed the primary
        if wasPrimary {
            try db.execute(sql: """
                UPDATE account SET isPrimary = 1
                WHERE id = (SELECT id FROM account WHERE isActive = 1 ORDER BY createdAt LIMIT 1)
            """)
        }
    }

    /// Update IMAP password and reconnect.
    func updateIMAPPassword(_ newPassword: String, for account: Account) async throws {
        guard account.provider == .imap else { return }
        guard !isRuntimeRemoved(account.id) else { throw ProviderError.notConnected }

        // Test connection with new password before saving
        let testProvider = try createIMAPProvider(for: account, passwordOverride: newPassword)
        try await testProvider.connect()
        guard !isRuntimeRemoved(account.id) else {
            try? await testProvider.disconnect()
            throw ProviderError.notConnected
        }

        // Save new password to Keychain
        try KeychainHelper.save(newPassword, for: KeychainHelper.passwordKey(accountId: account.id))

        // Replace active provider
        providers[account.id] = testProvider
        let concurrency: Int
        switch account.provider {
        case .gmail: concurrency = SyncConfig.gmailWorkQueueConcurrency
        case .outlook: concurrency = SyncConfig.exchangeWorkQueueConcurrency
        default: concurrency = SyncConfig.imapMaxConnectionCeiling
        }
        let queue = ProviderWorkQueue(provider: testProvider, maxConcurrency: concurrency)
        workQueues[account.id] = queue
        await syncEngine.register(accountId: account.id, provider: testProvider, workQueue: queue)
        if isRuntimeRemoved(account.id) {
            providers.removeValue(forKey: account.id)
            workQueues.removeValue(forKey: account.id)
            await queue.invalidate()
            await syncEngine.remove(accountId: account.id)
            try? await testProvider.disconnect()
            throw ProviderError.notConnected
        }
        authFailedAccounts.remove(account.id)
    }

    /// Re-authenticate Gmail via OAuth and reconnect.
    func reauthenticateGmail(for account: Account) async throws {
        guard account.provider == .gmail else { return }

        let tokens = try await oauthService.authenticateGoogle()
        try KeychainHelper.save(tokens.accessToken, for: KeychainHelper.accessTokenKey(accountId: account.id))
        if let refresh = tokens.refreshToken {
            try KeychainHelper.save(refresh, for: KeychainHelper.refreshTokenKey(accountId: account.id))
        }

        // Reconnect with fresh tokens
        await disconnectAccount(account)
        try await connectAccount(account)
    }

    /// Re-authenticate Outlook via OAuth and reconnect.
    func reauthenticateMicrosoft(for account: Account) async throws {
        guard account.provider == .outlook else { return }

        let tokens = try await oauthService.authenticateMicrosoft()
        try KeychainHelper.save(tokens.accessToken, for: KeychainHelper.accessTokenKey(accountId: account.id))
        if let refresh = tokens.refreshToken {
            try KeychainHelper.save(refresh, for: KeychainHelper.refreshTokenKey(accountId: account.id))
        }

        // Reconnect with fresh tokens
        await disconnectAccount(account)
        try await connectAccount(account)
    }
}
