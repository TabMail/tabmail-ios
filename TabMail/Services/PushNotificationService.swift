/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AuthenticationServices
import Foundation
import GRDB
import Synchronization
import UIKit
import UserNotifications

/// Minimal durable debt retained after an account row is removed.
///
/// The email is the remote worker's deletion key; no token, message data, or
/// account credentials are retained. Every action is idempotent. A record is
/// deleted only when all actions succeed, or when an authoritative active row
/// proves the prepared delete did not commit. A new row for the same email can
/// retire email-keyed remote debt only after old account-ID artifacts are gone.
struct PendingRemovedAccountPushCleanup: Codable, Equatable, Sendable {
    enum Action: String, Codable, Hashable, Sendable {
        /// Remove the preferred per-(device, account) dispatch record.
        case deviceAccount
        /// Delete orphanable Keychain entries and captured outbox directories.
        case localArtifacts
        /// Rewrite/delete the legacy device registration's account-email list.
        case deviceRegistration
        /// Delete Gmail/Outlook smart-classifier consent held by the worker.
        case consent
        /// Revoke worker account ownership + provider-subscription KV, then
        /// best-effort stop the provider watch when an access token is present.
        case providerSubscription
        /// Delete the IMAP/iCloud IDLE subscription (worker-authenticated).
        case imapSubscription
    }

    let accountId: String
    let generation: UUID
    let caldavConfigIds: [String]
    let outboxAttachmentDirNames: [String]
    /// Supabase subject whose worker-owned records may be deleted. Nil means
    /// local cleanup can proceed but remote outcomes must not advance.
    let workerUserId: String?
    let email: String
    let provider: String
    var actions: Set<Action>

    init(
        account: Account,
        caldavConfigIds: [String],
        outboxAttachmentDirNames: [String],
        workerUserId: String?
    ) {
        accountId = account.id
        generation = UUID()
        self.caldavConfigIds = caldavConfigIds
        self.outboxAttachmentDirNames = outboxAttachmentDirNames
        self.workerUserId = workerUserId
        email = account.emailAddress
        provider = account.provider.rawValue
        // Worker deletes are scoped to the Supabase subject. If removal occurs
        // while signed out, retaining remote actions would create debt no later
        // session can safely claim (a different co-owner may share the email).
        // Local account-ID artifacts remain fully cleanable without auth.
        guard workerUserId != nil else {
            actions = [.localArtifacts]
            return
        }
        switch account.provider {
        case .gmail, .outlook:
            actions = [.localArtifacts, .deviceAccount, .deviceRegistration, .consent, .providerSubscription]
        case .imap, .icloud:
            actions = [.localArtifacts, .deviceAccount, .deviceRegistration, .imapSubscription]
        case .caldav:
            actions = [.localArtifacts, .deviceRegistration]
        }
    }

    static func load(from defaults: UserDefaults) -> [Self] {
        guard let data = defaults.data(forKey: PushConfig.removedAccountCleanupKey),
              let records = try? JSONDecoder().decode([Self].self, from: data) else {
            return []
        }
        return records
    }

    static func save(_ records: [Self], to defaults: UserDefaults) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: PushConfig.removedAccountCleanupKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: PushConfig.removedAccountCleanupKey)
    }
}

/// `UserDefaults` is documented thread-safe but is not Sendable in this SDK.
/// The cleanup actor serializes all production access; this wrapper lets the
/// DEBUG harness install an isolated suite without weakening actor checking.
struct SendableRemovedAccountCleanupDefaults: @unchecked Sendable {
    let value: UserDefaults
}

/// Manages push notification registration, device token handling,
/// and per-account Gmail/Outlook push subscriptions.
///
/// Lifecycle:
/// - App launch → request permission + register for remote notifications
/// - Token received → register device with push worker
/// - Account added → subscribe for push (Gmail/Outlook only)
/// - Account removed → unsubscribe
/// - Sign out → unregister device
actor PushNotificationService {
    static let shared = PushNotificationService()

    let pushClient = PushClient()
    private var dbPool: PrioritizedDatabase { AppDatabase.dbPool }

    #if DEBUG
    /// Test-only override for the consent-status scan. When nil, the real
    /// `pushClient` is used. `checkPushConsentStatusForForeground` reads via
    /// `consentChecker` so tests can inject a mock without touching network
    /// or `TabMailTokenCoordinator`. Not visible in Release builds.
    private var consentCheckerOverride: (any PushConsentChecking)?
    private var consentChecker: any PushConsentChecking { consentCheckerOverride ?? pushClient }
    func _setConsentCheckerForTesting(_ checker: (any PushConsentChecking)?) {
        self.consentCheckerOverride = checker
    }

    private var removedAccountCleanupClientOverride: (any RemovedAccountPushCleaning)?
    private var removedAccountCleanupDefaultsOverride: SendableRemovedAccountCleanupDefaults?
    func _setRemovedAccountCleanupDependenciesForTesting(
        client: (any RemovedAccountPushCleaning)?,
        defaults: SendableRemovedAccountCleanupDefaults?
    ) {
        removedAccountCleanupClientOverride = client
        removedAccountCleanupDefaultsOverride = defaults
    }
    func _resetConsentScanStateForTesting() {
        self.hasSucceededConsentScanOnce = false
    }

    /// Test-only override for the iOS notification-settings read backing
    /// `visualAlertsEnabled()`. When nil, the live `UNUserNotificationCenter`
    /// is used. Lets tests drive the visible-vs-silent decision without a real
    /// notification center (whose settings can't be set from a test).
    private var settingsProviderOverride: (any NotificationSettingsProviding)?
    private var settingsProvider: any NotificationSettingsProviding {
        settingsProviderOverride ?? SystemNotificationSettingsProvider.shared
    }
    func _setNotificationSettingsProviderForTesting(_ provider: (any NotificationSettingsProviding)?) {
        self.settingsProviderOverride = provider
    }
    #else
    private var consentChecker: any PushConsentChecking { pushClient }
    private var settingsProvider: any NotificationSettingsProviding { SystemNotificationSettingsProvider.shared }
    #endif

    private var removedAccountCleanupClient: any RemovedAccountPushCleaning {
        #if DEBUG
        removedAccountCleanupClientOverride ?? pushClient
        #else
        pushClient
        #endif
    }

    private var removedAccountCleanupDefaults: UserDefaults {
        #if DEBUG
        removedAccountCleanupDefaultsOverride?.value ?? .standard
        #else
        .standard
        #endif
    }

    private var preparedRemovedAccountGenerations: Set<UUID> = []
    private var removedAccountCleanupDrainActive = false
    private var removedAccountCleanupDrainRequested = false
    private var pendingRemovedAccountAccessTokens: [UUID: String] = [:]

    /// Set to true after the first foreground consent-status scan that produced
    /// at least one authoritative per-account status (ok / error / missing).
    /// Gates the sticky-on-error behavior in `checkPushConsentStatusForForeground`:
    /// before the first success, thrown errors (timeouts, transient network
    /// failures — common on cold launch) do NOT populate the banner, avoiding
    /// a false-positive flash on boot. After the first success, sticky-on-error
    /// resumes so a later flaky check can't silently remove a truly-broken
    /// account from the banner.
    private var hasSucceededConsentScanOnce: Bool = false

    private init() {}

    // MARK: - Device ID

    /// Stable device identifier, generated once and persisted in UserDefaults.
    private(set) var deviceId: String = {
        if let existing = UserDefaults.standard.string(forKey: PushConfig.deviceIdKey) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: PushConfig.deviceIdKey)
        return id
    }()

    // MARK: - Permission & Registration

    /// Request notification permission and register for remote notifications.
    /// Silent push (content-available: 1) works without user permission,
    /// but we request alert+sound+badge for future visible notifications.
    func requestPermissionAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .alert, .sound])
            print("[Push] Notification authorization: \(granted ? "granted" : "denied")")
        } catch {
            print("[Push] Notification authorization error: \(error)")
        }

        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    // MARK: - Token Handling

    /// Called from AppDelegate when APNs provides a device token.
    /// Always re-registers (accounts may have changed since last registration).
    func didReceiveDeviceToken(_ tokenData: Data) async {
        // iOS can deliver the token callback before AppDatabase.shared is
        // published (seen as an EXC_BREAKPOINT on the rawPool force-unwrap via
        // reregisterAllDeviceAccounts during app relaunch). Gate BOTH sub-calls
        // on DB readiness — registerDeviceWithWorker's own gate sits after its
        // early-return guards, and reregisterAllDeviceAccounts has none. The
        // registration is deferred, never dropped (awaitLaunchReady resumes on
        // both DB-build success and failure).
        await AppStartup.shared.awaitLaunchReady(background: true)
        let tokenHex = tokenData.map { String(format: "%02x", $0) }.joined()
        print("[Push] APNs device token: \(tokenHex.prefix(16))...")
        BackgroundSyncLogger.logPush("APNs device token received: \(tokenHex.prefix(16))...")

        UserDefaults.standard.set(tokenHex, forKey: PushConfig.lastDeviceTokenKey)
        NSEDataBridge.mirrorDeviceToken()
        await registerDeviceWithWorker(tokenHex: tokenHex, force: true)
        // CRITICAL: the per-(device, account) records are the dispatch path —
        // dispatch prefers them over the legacy device record. On a token
        // rotation we must refresh THEM too, not just the legacy record above,
        // or dispatch keeps firing the stale per-account token (in the stale
        // APNs environment) and every push is silently dropped. Covers both
        // nseCapable=true (visible) and nseCapable=false (silent) accounts.
        await reregisterAllDeviceAccounts()
    }

    /// Called from AppDelegate when APNs registration fails.
    nonisolated func didFailToRegisterForRemoteNotifications(_ error: Error) {
        print("[Push] APNs registration failed: \(error)")
        BackgroundSyncLogger.logPush("APNs registration FAILED: \(error.localizedDescription)")
    }

    // MARK: - Device Registration

    /// Last successful registration timestamp (in-memory cache).
    private var lastRegistrationTime: Date?
    /// Hash of last registered state to detect changes.
    private var lastRegisteredStateHash: Int?

    /// Register this device with the push worker, including all active account emails.
    /// Cached: skips registration if token + accounts haven't changed and last registration
    /// was within `deviceRegistrationCacheTTLSeconds`. Pass `force: true` to bypass cache
    /// (e.g., when APNs token changes).
    func registerDeviceWithWorker(tokenHex: String? = nil, force: Bool = false) async {
        guard let session = TabMailAuthService.getSession() else {
            print("[Push] No session — skipping device registration")
            return
        }

        let token = tokenHex ?? UserDefaults.standard.string(forKey: PushConfig.lastDeviceTokenKey)
        guard let deviceToken = token else {
            print("[Push] No device token — skipping registration")
            return
        }

        // APNs can deliver the device token on a cold/background launch BEFORE
        // AppStartup has built the database. Touching AppDatabase.dbPool (a force-
        // unwrap) before then traps (EXC_BREAKPOINT crash on boot) — and after an
        // app update the DB build is delayed by migrations, so this path wins the
        // race. Gate on readiness like every other dbPool entry point. (Cheap once
        // ready; the no-session / no-token early returns above already skipped it.)
        await AppStartup.shared.awaitLaunchReady(background: true)

        do {
            let emails = try await dbPool.read { db in
                try String.fetchAll(db,
                    Account.select(Column("emailAddress"))
                        .filter(Column("isActive") == true)
                )
            }

            guard !emails.isEmpty else {
                print("[Push] No active accounts — skipping device registration")
                return
            }

            // Cache check: skip if nothing changed and TTL hasn't expired.
            // Include "nse" marker so endpoint change (/register-device → /register-device-nse)
            // forces re-registration even if token + emails are unchanged.
            let stateHash = (deviceToken + emails.sorted().joined() + "nse-v1").hashValue
            if !force,
               let lastTime = lastRegistrationTime,
               let lastHash = lastRegisteredStateHash,
               lastHash == stateHash,
               Date().timeIntervalSince(lastTime) < SyncConfig.deviceRegistrationCacheTTLSeconds {
                print("[Push] Device registration cached — skipping (no changes, TTL ok)")
                return
            }

            try await pushClient.registerDevice(
                deviceToken: deviceToken,
                deviceId: deviceId,
                userId: session.userId,
                accountEmails: emails,
                apnsSandbox: PushConfig.isAPNsSandbox
            )

            lastRegistrationTime = Date()
            lastRegisteredStateHash = stateHash
            UserDefaults.standard.set(emails, forKey: PushConfig.registeredEmailsKey)
            print("[Push] Device registered with \(emails.count) account(s)")
            BackgroundSyncLogger.logPush("Device registered with \(emails.count) account(s)")
        } catch {
            print("[Push] Device registration failed: \(error)")
            BackgroundSyncLogger.logPush("Device registration FAILED: \(error.localizedDescription)")
        }
    }

    /// Factory reset cannot report success and clear the auth/session state if
    /// the final worker device route was not removed. Failure remains visible so
    /// the still-authenticated reset gesture remains retryable.
    func unregisterDeviceForReset() async throws {
        try await pushClient.unregisterDevice(deviceId: deviceId)
        UserDefaults.standard.removeObject(forKey: PushConfig.lastDeviceTokenKey)
        UserDefaults.standard.removeObject(forKey: PushConfig.registeredEmailsKey)
        print("[Push] Device unregistered for factory reset")
        BackgroundSyncLogger.logPush("Device unregistered for factory reset")
    }

    // MARK: - Removed-account cleanup debt

    /// Persist the worker-owned cleanup tuple before the authoritative account
    /// delete begins. If that delete fails, the caller must cancel this record.
    /// On relaunch, retry first verifies that the email is no longer active, so
    /// a kill between preparation and the GRDB commit cannot disconnect a live
    /// account.
    func prepareRemovedAccountCleanup(
        _ account: Account,
        caldavConfigIds: [String],
        outboxAttachmentDirNames: [String]
    ) -> UUID {
        var records = PendingRemovedAccountPushCleanup.load(from: removedAccountCleanupDefaults)
        // Every attempt gets an independent generation. Never replace an older
        // same-email or same-ID record: it may still own local artifacts or a
        // worker revocation that this attempt cannot safely cancel.
        let record = PendingRemovedAccountPushCleanup(
            account: account,
            caldavConfigIds: caldavConfigIds,
            outboxAttachmentDirNames: outboxAttachmentDirNames,
            workerUserId: currentRemovedAccountCleanupUserId()
        )
        records.append(record)
        preparedRemovedAccountGenerations.insert(record.generation)
        PendingRemovedAccountPushCleanup.save(records, to: removedAccountCleanupDefaults)
        if removedAccountCleanupDrainActive { removedAccountCleanupDrainRequested = true }
        return record.generation
    }

    /// Roll back the prepared marker when the authoritative GRDB deletion did
    /// not commit. No remote action has run at this point.
    func cancelPreparedRemovedAccountCleanup(generation: UUID) {
        preparedRemovedAccountGenerations.remove(generation)
        pendingRemovedAccountAccessTokens.removeValue(forKey: generation)
        var records = PendingRemovedAccountPushCleanup.load(from: removedAccountCleanupDefaults)
        records.removeAll { $0.generation == generation }
        PendingRemovedAccountPushCleanup.save(records, to: removedAccountCleanupDefaults)
        if removedAccountCleanupDrainActive { removedAccountCleanupDrainRequested = true }
    }

    /// End the in-process prepare fence only after the row committed absent and
    /// AccountManager installed its runtime tombstone. A drain that overlapped
    /// the transaction then performs another pass against the authoritative DB.
    func commitPreparedRemovedAccountCleanup(
        generation: UUID,
        capturedOAuthAccessToken: String? = nil
    ) {
        if let capturedOAuthAccessToken,
           PendingRemovedAccountPushCleanup.load(from: removedAccountCleanupDefaults)
            .contains(where: { $0.generation == generation }) {
            pendingRemovedAccountAccessTokens[generation] = capturedOAuthAccessToken
        }
        preparedRemovedAccountGenerations.remove(generation)
        if removedAccountCleanupDrainActive { removedAccountCleanupDrainRequested = true }
    }

    /// Retry idempotent worker-owned cleanup for locally removed accounts.
    ///
    /// `onlyEmail` is used by the removal flow for an immediate attempt. The
    /// unfiltered form runs on every foreground push re-subscription, which is
    /// the durable offline/relaunch recovery path. A current account census is
    /// mandatory before any request: if the database cannot be read, no remote
    /// state is changed; if the same email has been re-added, its stale record
    /// is expired so cleanup cannot tear down the new registration.
    func retryPendingRemovedAccountCleanups(
        onlyEmail: String? = nil
    ) async {
        if removedAccountCleanupDrainActive {
            removedAccountCleanupDrainRequested = true
            return
        }

        removedAccountCleanupDrainActive = true
        var nextOnlyEmail = onlyEmail
        repeat {
            removedAccountCleanupDrainRequested = false
            await drainPendingRemovedAccountCleanupsOnce(onlyEmail: nextOnlyEmail)
            nextOnlyEmail = nil
        } while removedAccountCleanupDrainRequested
        removedAccountCleanupDrainActive = false
    }

    func hasPendingRemovedAccountCleanups() -> Bool {
        !PendingRemovedAccountPushCleanup.load(from: removedAccountCleanupDefaults).isEmpty
    }

    /// Whether any retained record holds debt that the given Supabase subject
    /// is the one allowed to discharge.
    ///
    /// Sharper than `hasPendingRemovedAccountCleanups()`, which answers "is any
    /// record retained at all" and therefore also reports true for debt bound to
    /// a different user, or for signed-out removals that only ever carry
    /// `.localArtifacts`. Sign-out uses this narrower question so the ordinary
    /// path — no debt this session can advance — stays a single UserDefaults
    /// read with no database access and no network.
    ///
    /// Mirrors the per-pass guard in `drainPendingRemovedAccountCleanupsOnce`:
    /// a record advances remote actions only while `workerUserId` equals the
    /// live subject, and `nil` never matches. Records whose only remaining
    /// action is `.localArtifacts` are excluded because that action needs no
    /// session and so nothing about it is lost when the session goes away.
    func hasRemovedAccountCleanupDebt(forCurrentUser userId: String?) -> Bool {
        guard let userId else { return false }
        return PendingRemovedAccountPushCleanup.load(from: removedAccountCleanupDefaults).contains {
            $0.workerUserId == userId && !$0.actions.subtracting([.localArtifacts]).isEmpty
        }
    }

    private func drainPendingRemovedAccountCleanupsOnce(onlyEmail: String?) async {
        let snapshot = PendingRemovedAccountPushCleanup.load(from: removedAccountCleanupDefaults)
        guard !snapshot.isEmpty else { return }

        let activeAccounts: [Account]
        do {
            activeAccounts = try await dbPool.read { db in
                try Account.filter(Column("isActive") == true).fetchAll(db)
            }
        } catch {
            print("[Push] Removed-account cleanup deferred: account census failed: \(error)")
            return
        }
        let currentWorkerUserId = currentRemovedAccountCleanupUserId()

        var outcomes: [UUID: Set<PendingRemovedAccountPushCleanup.Action>] = [:]
        var selected: [PendingRemovedAccountPushCleanup] = []
        for var record in snapshot {
            // An in-process owner has not yet installed the runtime/credential
            // fence. Relaunch is still recoverable because this set is memory-
            // only; cancel removes the exact record and commit releases it.
            if preparedRemovedAccountGenerations.contains(record.generation) {
                continue
            }
            let sameEmail = activeAccounts.filter {
                $0.emailAddress.caseInsensitiveCompare(record.email) == .orderedSame
            }
            if sameEmail.contains(where: { $0.id == record.accountId }) {
                // Relaunch after a kill before commit: the original row is
                // still authoritative and no in-process deletion owns it.
                outcomes[record.generation] = []
                continue
            }

            if record.actions.contains(.localArtifacts) {
                cleanupRemovedAccountLocalArtifacts(record)
                record.actions.remove(.localArtifacts)
                outcomes[record.generation] = record.actions
            }

            // Worker deletions are scoped by the current JWT subject. Never let
            // a signed-out or different user advance another user's debt.
            guard let workerUserId = record.workerUserId,
                  workerUserId == currentWorkerUserId else {
                // The raw snapshot is immediate-pass-only. A sign-out or user
                // switch must not retain it for the rest of the process.
                pendingRemovedAccountAccessTokens.removeValue(forKey: record.generation)
                continue
            }

            if !sameEmail.isEmpty {
                // The replacement owns email-global device routes. Provider-
                // specific debt is suppressed only when it would delete the
                // replacement's own state.
                // CalDAV-only replacements never register a mailbox/device
                // route, so the old mailbox route must still be deleted.
                if sameEmail.contains(where: { $0.provider != .caldav }) {
                    record.actions.remove(.deviceAccount)
                    record.actions.remove(.deviceRegistration)
                }
                let replacementProviders = Set(sameEmail.map { $0.provider })
                if let oldProvider = AccountProvider(rawValue: record.provider) {
                    if replacementProviders.contains(oldProvider) {
                        record.actions.remove(.consent)
                        record.actions.remove(.providerSubscription)
                    }
                    if oldProvider == .imap || oldProvider == .icloud,
                       !replacementProviders.isDisjoint(with: [.imap, .icloud]) {
                        record.actions.remove(.imapSubscription)
                    }
                }
                outcomes[record.generation] = record.actions
                guard !record.actions.isEmpty else { continue }
            }
            if let onlyEmail,
               record.email.caseInsensitiveCompare(onlyEmail) != .orderedSame {
                continue
            }
            selected.append(record)
        }

        guard !selected.isEmpty else {
            mergeRemovedAccountCleanupOutcomes(outcomes)
            return
        }

        let client = removedAccountCleanupClient
        let cleanupDeviceId = removedAccountCleanupDefaults.string(forKey: PushConfig.deviceIdKey) ?? deviceId

        // Pin the bearer for the WHOLE admitted pass. Every action below was
        // admitted for `currentWorkerUserId`; re-deriving a token per action
        // would let a mid-pass sign-in send the remainder under a DIFFERENT
        // subject, which IOS-PUSH-001 forbids: the worker's `user_mismatch`
        // would then be misread as proof the debt is settled, discharging an
        // action that was never performed. If no bearer is available for the
        // admitted subject — or the slot changed owner while we were obtaining
        // one — perform NO remote action and RETAIN the debt.
        guard let pinnedUserId = currentWorkerUserId,
              let pinnedToken = await currentRemovedAccountCleanupToken(),
              currentRemovedAccountCleanupUserId() == pinnedUserId else {
            print("[Push] Removed-account cleanup deferred: no pinned identity for the admitted subject")
            mergeRemovedAccountCleanupOutcomes(outcomes)
            return
        }

        selected = await PushCleanupIdentity.$pinnedAuthToken.withValue(pinnedToken) {
            await performPinnedRemovedAccountCleanupActions(
                selected: selected,
                client: client,
                cleanupDeviceId: cleanupDeviceId,
                activeAccounts: activeAccounts,
                pinnedUserId: pinnedUserId
            )
        }

        for record in selected {
            outcomes[record.generation] = record.actions
        }
        mergeRemovedAccountCleanupOutcomes(outcomes)
    }

    /// Perform the admitted pass's remote actions under the PINNED identity.
    ///
    /// Split out of `drainPendingRemovedAccountCleanupsOnce` solely so the whole
    /// action sequence can be bound inside one
    /// `PushCleanupIdentity.$pinnedAuthToken.withValue`. The action logic is
    /// unchanged; what changed is that every `client` call inside now resolves
    /// its bearer from that task-local instead of from the ambient Keychain
    /// slot, so a sign-in landing mid-pass cannot switch the subject the
    /// remaining actions are sent under.
    ///
    /// Returns the records with their remaining (undischarged) actions.
    private func performPinnedRemovedAccountCleanupActions(
        selected: [PendingRemovedAccountPushCleanup],
        client: any RemovedAccountPushCleaning,
        cleanupDeviceId: String,
        activeAccounts: [Account],
        pinnedUserId: String
    ) async -> [PendingRemovedAccountPushCleanup] {
        var selected = selected
        for index in selected.indices {
            if selected[index].actions.contains(.deviceAccount) {
                do {
                    try await client.unregisterDeviceAccount(
                        deviceId: cleanupDeviceId,
                        accountEmail: selected[index].email
                    )
                    selected[index].actions.remove(.deviceAccount)
                } catch {
                    print("[Push] Removed-account device route cleanup deferred for \(selected[index].email): \(error)")
                }
            }

            if selected[index].actions.contains(.consent) {
                do {
                    switch selected[index].provider {
                    case AccountProvider.gmail.rawValue:
                        try await client.deleteGmailConsent(userEmail: selected[index].email)
                    case AccountProvider.outlook.rawValue:
                        try await client.deleteOutlookConsent(userEmail: selected[index].email)
                    default:
                        break
                    }
                    selected[index].actions.remove(.consent)
                } catch {
                    if isTerminalRemovedAccountOwnershipRefusal(error) {
                        // Shared-address singleton belongs to another user. The
                        // worker already revoked this caller's provider proof.
                        selected[index].actions.remove(.consent)
                    } else {
                        print("[Push] Removed-account consent cleanup deferred for \(selected[index].email): \(error)")
                    }
                }
            }

            // Consent must be removed before `/unsubscribe`: legacy consent
            // rows use the account-ownership proof for authorization, while
            // `/unsubscribe` deliberately revokes that proof first. Reversing
            // these calls can turn a transient consent failure into a durable
            // 403 with no proof left to authorize its retry.
            if selected[index].actions.contains(.providerSubscription),
               !selected[index].actions.contains(.consent) {
                do {
                    // The raw snapshot gets exactly one attempt. On failure the
                    // durable action remains, but every later pass sends empty
                    // so account credentials do not gain a new lifetime here.
                    let token = pendingRemovedAccountAccessTokens.removeValue(
                        forKey: selected[index].generation
                    ) ?? ""
                    try await client.unsubscribe(
                        provider: selected[index].provider,
                        userEmail: selected[index].email,
                        accessToken: token
                    )
                    selected[index].actions.remove(.providerSubscription)
                } catch {
                    if isTerminalRemovedAccountOwnershipRefusal(error) {
                        // `/unsubscribe` revokes the caller's proof before it
                        // refuses teardown of a co-owner's singleton watch.
                        selected[index].actions.remove(.providerSubscription)
                    } else {
                        print("[Push] Removed-account provider subscription cleanup deferred for \(selected[index].email): \(error)")
                    }
                }
            }

            if selected[index].actions.contains(.imapSubscription) {
                do {
                    try await client.unsubscribeIMAP(userEmail: selected[index].email)
                    selected[index].actions.remove(.imapSubscription)
                } catch {
                    print("[Push] Removed-account IMAP cleanup deferred for \(selected[index].email): \(error)")
                }
            }

            // The access-token snapshot is only for this immediate pass. If a
            // prerequisite deferred `/unsubscribe`, later retries use empty.
            pendingRemovedAccountAccessTokens.removeValue(forKey: selected[index].generation)
        }

        // The legacy device record is global, so one successful refresh retires
        // every selected tombstone's copy of this action.
        if selected.contains(where: { $0.actions.contains(.deviceRegistration) }) {
            do {
                try await refreshDeviceRegistrationForRemovedAccountCleanup(
                    activeEmails: activeAccounts.map(\.emailAddress),
                    client: client,
                    deviceId: cleanupDeviceId,
                    pinnedUserId: pinnedUserId
                )
                for index in selected.indices {
                    selected[index].actions.remove(.deviceRegistration)
                }
            } catch {
                print("[Push] Removed-account legacy device cleanup deferred: \(error)")
            }
        }
        return selected
    }

    /// Resolve a bearer for a removed-account cleanup pass. Mirrors
    /// `PushClient.currentAuthToken`'s result mapping; kept here because that
    /// one is private to the client and this must run BEFORE the pin is bound.
    private func currentRemovedAccountCleanupToken() async -> String? {
        switch await TabMailTokenCoordinator.shared.validToken() {
        case .success(let token): return token
        case .permanentFailure, .transientFailure, .noSession: return nil
        }
    }

    private func cleanupRemovedAccountLocalArtifacts(_ record: PendingRemovedAccountPushCleanup) {
        KeychainHelper.delete(key: KeychainHelper.passwordKey(accountId: record.accountId))
        KeychainHelper.delete(key: KeychainHelper.accessTokenKey(accountId: record.accountId))
        KeychainHelper.delete(key: KeychainHelper.refreshTokenKey(accountId: record.accountId))
        for configId in record.caldavConfigIds {
            KeychainHelper.delete(key: "caldav_password_\(configId)")
        }

        let base = OutboxMessage.attachmentsBaseDir.standardizedFileURL
        for dirName in record.outboxAttachmentDirNames {
            let candidate = base.appendingPathComponent(dirName, isDirectory: true).standardizedFileURL
            guard candidate.deletingLastPathComponent() == base else {
                print("[Push] Refusing unsafe removed-account attachment directory: \(dirName)")
                continue
            }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    /// Merge only action results for the exact generations this pass loaded.
    /// A prepare/cancel that re-entered while network or DB work was suspended
    /// creates/removes a different generation and therefore cannot be clobbered.
    private func mergeRemovedAccountCleanupOutcomes(
        _ outcomes: [UUID: Set<PendingRemovedAccountPushCleanup.Action>]
    ) {
        guard !outcomes.isEmpty else { return }
        var latest = PendingRemovedAccountPushCleanup.load(from: removedAccountCleanupDefaults)
        for index in latest.indices.reversed() {
            guard let remaining = outcomes[latest[index].generation] else { continue }
            if remaining.isEmpty {
                pendingRemovedAccountAccessTokens.removeValue(forKey: latest[index].generation)
                latest.remove(at: index)
            } else {
                latest[index].actions = remaining
            }
        }
        PendingRemovedAccountPushCleanup.save(latest, to: removedAccountCleanupDefaults)
    }

    private func currentRemovedAccountCleanupUserId() -> String? {
        guard let session = TabMailAuthService.getSession() else {
            return nil
        }
        return session.userId
    }

    private func isTerminalRemovedAccountOwnershipRefusal(_ error: any Error) -> Bool {
        guard let pushError = error as? PushError,
              case .workerRequestFailed(let statusCode, let errorCode) = pushError else {
            return false
        }
        return statusCode == 403 && errorCode == "user_mismatch"
    }

    /// - Parameter pinnedUserId: the subject the pass was ADMITTED for. This
    ///   used to re-read `tabmail_session` here, which meant a sign-in landing
    ///   mid-pass re-registered the device under the NEW user while discharging
    ///   the OLD user's `.deviceRegistration` debt — a cross-user state
    ///   mutation and a false discharge. Identity now follows the work.
    private func refreshDeviceRegistrationForRemovedAccountCleanup(
        activeEmails: [String],
        client: any RemovedAccountPushCleaning,
        deviceId: String,
        pinnedUserId: String
    ) async throws {
        guard !activeEmails.isEmpty else {
            try await client.unregisterDevice(deviceId: deviceId)
            removedAccountCleanupDefaults.removeObject(forKey: PushConfig.registeredEmailsKey)
            return
        }

        guard let token = removedAccountCleanupDefaults.string(forKey: PushConfig.lastDeviceTokenKey) else {
            // No APNs token means this install could not have registered a
            // legacy device record. Retire the stale local email snapshot too.
            removedAccountCleanupDefaults.removeObject(forKey: PushConfig.registeredEmailsKey)
            return
        }

        try await client.registerDevice(
            deviceToken: token,
            deviceId: deviceId,
            userId: pinnedUserId,
            accountEmails: activeEmails,
            apnsSandbox: PushConfig.isAPNsSandbox
        )
        removedAccountCleanupDefaults.set(activeEmails, forKey: PushConfig.registeredEmailsKey)
    }

    // MARK: - Account Subscription

    /// Subscribe a single account for push notifications.
    /// Gmail/Outlook → Pub/Sub / Graph subscription. IMAP → IDLE proxy
    /// subscription (server endpoint stubbed; client implementation is complete).
    /// When `updateDeviceRegistration` is true (default), also re-registers the device
    /// to update the email list. Set to false when called in a batch loop.
    func subscribeAccount(_ account: Account, updateDeviceRegistration: Bool = true) async {
        // Push is fully disabled in demo (no real
        // server to subscribe to; prompting iOS for push consent here
        // would be misleading).
        let demoActive = await MainActor.run(resultType: Bool.self) {
            DemoModeStore.shared.isActive
        }
        if demoActive {
            print("[Push] Demo mode active — skipping subscribe \(account.emailAddress)")
            return
        }
        guard let session = TabMailAuthService.getSession() else {
            print("[Push] No session — cannot subscribe \(account.emailAddress)")
            return
        }

        do {
            switch account.provider {
            case .gmail, .outlook:
                let accessToken = try await AccountManager.shared.freshAccessToken(for: account)
                try await pushClient.subscribe(
                    provider: account.provider.rawValue,
                    userId: session.userId,
                    userEmail: account.emailAddress,
                    accessToken: accessToken
                )
                BackgroundSyncLogger.logPush("Subscribed \(account.emailAddress) (\(account.provider.rawValue))")
            case .imap, .icloud:
                // iCloud uses IMAP via app-password (imap.mail.me.com:993) — same
                // IDLE proxy path as generic IMAP. CalDAV is calendar-only, no
                // mailbox, so it's excluded below.
                let nseEnabled = UserDefaults.standard.object(forKey: PushConfig.pushNotificationsEnabledKey) as? Bool ?? false
                guard nseEnabled else {
                    print("[Push] IMAP subscribe skipped — NSE push toggle off (\(account.emailAddress))")
                    return
                }
                guard let host = account.imapHost,
                      let password = KeychainHelper.loadString(key: KeychainHelper.passwordKey(accountId: account.id)) else {
                    print("[Push] IMAP subscribe skipped — missing host/password for \(account.emailAddress)")
                    return
                }
                try await pushClient.subscribeIMAP(
                    userId: session.userId,
                    userEmail: account.emailAddress,
                    host: host,
                    port: account.imapPort ?? 993,
                    username: account.imapUsername ?? account.emailAddress,
                    password: password
                )
                BackgroundSyncLogger.logPush("Subscribed IMAP \(account.emailAddress) via IDLE proxy")
            case .caldav:
                return  // calendar-only, no mailbox to IDLE on
            }

            // Per-(device, account) registration — the dispatch record. Decides
            // visible vs silent push per-account at dispatch time.
            await registerDeviceAccountRecord(for: account)
        } catch {
            print("[Push] Subscribe failed for \(account.emailAddress): \(error)")
            BackgroundSyncLogger.logPush("Subscribe FAILED for \(account.emailAddress): \(error.localizedDescription)")
        }

        if updateDeviceRegistration {
            await registerDeviceWithWorker()
        }
    }

    /// (Re)register the per-(device, account) dispatch record for one account
    /// with the CURRENT device token + APNs environment. This is the record
    /// dispatch reads, so it MUST carry the live token regardless of push style:
    /// it runs for both `nseCapable=true` (visible/NSE) and `nseCapable=false`
    /// (silent/non-NSE) accounts — silent registrations need token rotations too.
    ///
    /// Decoupled from the provider subscription (Pub/Sub / IDLE proxy) so it can
    /// run on a bare token change (`reregisterAllDeviceAccounts`) without
    /// re-doing a full subscribe. CalDAV has no mailbox → callers skip it.
    private func registerDeviceAccountRecord(for account: Account) async {
        guard let session = TabMailAuthService.getSession(),
              let deviceToken = UserDefaults.standard.string(forKey: PushConfig.lastDeviceTokenKey),
              let deviceId = UserDefaults.standard.string(forKey: PushConfig.deviceIdKey) else { return }

        let nseEnabled = UserDefaults.standard.object(forKey: PushConfig.pushNotificationsEnabledKey) as? Bool ?? false
        // Visible (nse) push needs a VISUAL surface enabled in iOS settings
        // (Lock Screen / Notification Center / Banner) — otherwise iOS won't
        // present it and won't run the NSE. When the in-app toggle is on but no
        // visual surface is enabled, register SILENT (nseCapable=false, do NOT
        // skip) so the app still wakes to sync + badge. Read LIVE (no cached
        // capability) — the foreground re-subscribe re-runs this with the
        // current value and the worker upserts idempotently.
        let visualOn = await visualAlertsEnabled()
        // iCloud routes through the IMAP IDLE proxy (app-password IMAP) — the
        // proxy emits /imap-new-mail tagged provider="imap", so the device
        // registration must match to receive visible push.
        let providerTag = (account.provider == .icloud) ? "imap" : account.provider.rawValue
        let nseCapable = nseEnabled && NSEProviderSupport.isReady(providerTag) && visualOn
        do {
            try await pushClient.registerDeviceAccount(
                deviceToken: deviceToken,
                deviceId: deviceId,
                userId: session.userId,
                accountEmail: account.emailAddress,
                provider: providerTag,
                apnsSandbox: PushConfig.isAPNsSandbox,
                nseCapable: nseCapable
            )
        } catch {
            print("[Push] registerDeviceAccount failed for \(account.emailAddress): \(error)")
            // Not fatal — dispatch falls back to the legacy device-level record.
        }
    }

    /// Re-register EVERY active account's per-(device, account) dispatch record
    /// with the current device token. Called on APNs token rotation
    /// (`didReceiveDeviceToken`) so the dispatch records pick up the new token +
    /// environment — previously a rotation refreshed ONLY the legacy device
    /// record, leaving dispatch firing the stale per-account token (silent drop).
    /// Runs for all providers with a mailbox (CalDAV excluded) so the non-NSE /
    /// silent registrations get the token update too.
    func reregisterAllDeviceAccounts() async {
        let accounts: [Account]
        do {
            accounts = try await dbPool.read { db in
                try Account.filter(Column("isActive") == true).fetchAll(db)
            }
        } catch {
            print("[Push] reregisterAllDeviceAccounts: failed to load accounts: \(error)")
            return
        }
        for account in accounts where account.provider != .caldav {
            await registerDeviceAccountRecord(for: account)
        }
    }

    /// Subscribe all active accounts (Gmail/Outlook + IMAP via IDLE proxy),
    /// then re-register device once. Account subscriptions run in parallel —
    /// each is an independent worker round-trip with no shared state.
    func subscribeAllAccounts() async {
        // Ordinary foreground subscription cannot heal a deleted account: it
        // enumerates only live rows, and the old per-account dispatch record is
        // therefore never named. Drain compact removal debt first.
        await retryPendingRemovedAccountCleanups()

        do {
            let accounts = try await dbPool.read { db in
                try Account.filter(Column("isActive") == true).fetchAll(db)
            }
            await withTaskGroup(of: Void.self) { group in
                for account in accounts {
                    group.addTask {
                        await self.subscribeAccount(account, updateDeviceRegistration: false)
                    }
                }
            }
        } catch {
            print("[Push] Failed to load accounts for subscription: \(error)")
        }

        await registerDeviceWithWorker()
    }

    // MARK: - Notification visibility (presentation gate)

    /// Whether iOS will present a notification on a VISUAL surface (Lock Screen,
    /// Notification Center, or Banner). This is the NSE presentation gate — if no
    /// visual surface is enabled, iOS won't run the NSE, so we must register
    /// silent rather than visible.
    ///
    /// - Sound and Badge do NOT count: a sound/badge-only notification "cannot be
    ///   modified", so the NSE is skipped.
    /// - `.provisional` authorization DOES count: provisional notifications
    ///   deliver quietly to Notification Center (a visual surface), so the NSE
    ///   can still run.
    func visualAlertsEnabled() async -> Bool {
        let s = await settingsProvider.currentVisibility()
        let authed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
        let visual = s.lockScreenSetting == .enabled
            || s.notificationCenterSetting == .enabled
            || s.alertSetting == .enabled
        return authed && visual
    }

    // MARK: - Gmail Push-Consent (server-side inbox-add classifier)

    /// Result of a consent-check pass. Callers surface `.needsReconsent`
    /// accounts in the UI via a "Fix smart notifications" banner.
    struct ConsentCheckReport: Sendable {
        /// Gmail accounts for which the server reports a classification
        /// error — user should re-run the metadata OAuth flow.
        var accountsNeedingReconsent: [String] = []
        /// Gmail accounts for which the server has no consent stored yet
        /// (either never uploaded, or server revoked it). Toggle flip
        /// handler asks for consent; foreground handler just notes it.
        var accountsMissingConsent: [String] = []
    }

    /// Walk every active push-capable account (Gmail + Outlook) and ensure
    /// the worker has a valid metadata-scope consent for each. Called:
    ///   - from the NSE toggle flip OFF→ON (runs metadata OAuth for any
    ///     account in `.missing` state — sequential, one consent sheet
    ///     per account).
    ///   - from account-add when the NSE toggle is already ON (via
    ///     `ensurePushConsentAfterAccountAdd` below).
    ///   - from the "Fix Smart Notifications" banner tap.
    ///
    /// Serial by design — running N OAuth sheets in parallel would stack
    /// `ASWebAuthenticationSession` presentations, which iOS does not
    /// support.
    ///
    /// Per-account decline does NOT cascade: declining one account's
    /// sheet leaves that account in `missing` state; other accounts in the
    /// loop continue; the NSE toggle stays on. User dismisses the banner
    /// by completing consent or toggling NSE off explicitly.
    @MainActor
    func ensurePushConsentForAllAccounts(auth: OAuthService) async -> ConsentCheckReport {
        var report = ConsentCheckReport()
        let accounts: [Account]
        do {
            accounts = try await dbPool.read { db in
                try Account.filter(Column("isActive") == true).fetchAll(db)
            }
        } catch {
            print("[Push] consent: loading accounts failed: \(error)")
            return report
        }

        for account in accounts where account.hasPushSupport {
            await ensurePushConsentForAccount(account, auth: auth, report: &report)
        }
        return report
    }

    /// Check + (re-)consent for a single push-capable account. Dispatches
    /// to the right provider-specific status check + OAuth flow.
    @MainActor
    func ensurePushConsentForAccount(_ account: Account, auth: OAuthService, report: inout ConsentCheckReport) async {
        let email = account.emailAddress
        let status: PushClient.PushConsentStatus
        do {
            switch account.provider {
            case .gmail:
                status = try await pushClient.getGmailConsentStatus(userEmail: email)
            case .outlook:
                status = try await pushClient.getOutlookConsentStatus(userEmail: email)
            default:
                return  // non-push-capable provider
            }
        } catch {
            print("[Push] consent: status check failed for \(email): \(error)")
            return
        }

        switch status {
        case .ok:
            return
        case .error(let reason):
            print("[Push] consent: \(email) has error state (\(reason ?? "?")) — requesting re-consent")
            report.accountsNeedingReconsent.append(email)
            await runMetadataConsentAndUpload(account: account, auth: auth)
        case .missing:
            print("[Push] consent: \(email) missing — requesting consent")
            report.accountsMissingConsent.append(email)
            await runMetadataConsentAndUpload(account: account, auth: auth)
        }
    }

    /// Dispatch to the provider-specific metadata-scope OAuth flow.
    /// Kept as a single entry point so `ensurePushConsentForAccount` stays
    /// provider-agnostic. Inner `runGmail*` / `runOutlook*` functions differ
    /// only in which OAuth provider they drive.
    @MainActor
    private func runMetadataConsentAndUpload(account: Account, auth: OAuthService) async {
        switch account.provider {
        case .gmail:
            await runGmailMetadataConsentAndUpload(account: account, auth: auth)
        case .outlook:
            await runOutlookMetadataConsentAndUpload(account: account, auth: auth)
        default:
            break
        }
    }

    /// Drives the Gmail metadata-scope OAuth sheet for one account via the
    /// worker-hosted web flow. The resulting refresh_token is stored
    /// server-side (encrypted KV) — never returned to the device.
    /// Silently swallows user-cancelled consent; the account stays in
    /// "missing / error" state and the UI can re-prompt on next foreground.
    @MainActor
    private func runGmailMetadataConsentAndUpload(account: Account, auth: OAuthService) async {
        let email = account.emailAddress
        do {
            try await auth.authenticateGoogleMetadataScope(loginHint: email, pushClient: pushClient)
            BackgroundSyncLogger.logPush("Stored Gmail metadata consent (web-flow) for \(email)")
        } catch {
            // Per-account missing/error state is the ONLY consequence of a
            // consent failure — regardless of whether the user explicitly
            // cancelled the sheet or a transient network error fired. The
            // foreground banner keeps prompting until all accounts are ok
            // or the user flips the NSE toggle off globally themselves.
            //
            // We deliberately do NOT cascade a per-account decline into a
            // device-wide NSE shutoff: one Outlook account's "not now" must
            // not wipe Gmail consents across the user's other accounts, nor
            // flip the global push toggle. Users who want that outcome can
            // toggle NSE off in Settings / Debug menu — that path revokes
            // all consents deliberately.
            if let err = error as? ASWebAuthenticationSessionError, err.code == .canceledLogin {
                print("[Push] consent: user declined for \(email) — account stays in missing state, banner will re-prompt")
            } else if let err = error as? OAuthError, case .cancelled = err {
                print("[Push] consent: user declined for \(email) — account stays in missing state, banner will re-prompt")
            } else {
                print("[Push] consent: transient flow failure for \(email): \(error)")
            }
        }
    }

    /// Lookup-by-email convenience: resolves the active Account row from
    /// GRDB and forwards to `ensurePushConsentAfterAccountAdd`. Used by
    /// the explainer-alert UI which only knows the email string.
    @MainActor
    func ensurePushConsentAfterAccountAdd(emailAddress: String, auth: OAuthService) async {
        let account: Account?
        do {
            account = try await dbPool.read { db in
                try Account.filter(Column("emailAddress") == emailAddress && Column("isActive") == true).fetchOne(db)
            }
        } catch {
            print("[Push] consent: lookup-by-email failed for \(emailAddress): \(error)")
            return
        }
        guard let account else {
            print("[Push] consent: no active account for \(emailAddress)")
            return
        }
        await ensurePushConsentAfterAccountAdd(account, auth: auth)
    }

    /// Called immediately after a new push-capable account is added via
    /// the primary OAuth flow — if the NSE toggle is already ON, chain
    /// into the metadata-scope consent so the account is push-ready out
    /// of the gate. Safe to call regardless; no-ops when toggle is off
    /// or account has no push support.
    @MainActor
    func ensurePushConsentAfterAccountAdd(_ account: Account, auth: OAuthService) async {
        let nseEnabled = UserDefaults.standard.object(forKey: PushConfig.pushNotificationsEnabledKey) as? Bool ?? false
        guard nseEnabled, account.hasPushSupport else { return }
        var report = ConsentCheckReport()
        await ensurePushConsentForAccount(account, auth: auth, report: &report)
    }

    /// Revoke consent for all push-capable accounts — called on NSE toggle
    /// ON→OFF. Per-provider DELETE revokes the server-side token + deletes
    /// the KV record.
    func revokePushConsentForAllAccounts() async {
        do {
            let accounts = try await dbPool.read { db in
                try Account.filter(Column("isActive") == true).fetchAll(db)
            }
            for account in accounts where account.hasPushSupport {
                await revokePushConsentForAccount(account)
            }
        } catch {
            print("[Push] consent: loading accounts for revocation failed: \(error)")
        }
    }

    /// Revoke consent for a single push-capable account — called on
    /// account removal. Dispatches per provider.
    func revokePushConsentForAccount(_ account: Account) async {
        switch account.provider {
        case .gmail:
            try? await pushClient.deleteGmailConsent(userEmail: account.emailAddress)
        case .outlook:
            try? await pushClient.deleteOutlookConsent(userEmail: account.emailAddress)
        default:
            return
        }
    }

    /// Non-interactive status scan for every active Gmail AND Outlook account,
    /// posting `.pushConsentErrorsDetected` (userInfo: `[String]` of
    /// affected emails) when any are in error state. UI layer subscribes to
    /// this to surface the "Fix smart notifications" banner.
    ///
    /// Cheap — O(number of push accounts) HEAD-like requests, all issued in
    /// parallel. Run on every foreground. Non-blocking at call sites (every
    /// caller wraps in `.task` / `Task { }`).
    ///
    /// **First-scan safety:** on the first scan since process start, thrown
    /// errors (timeouts, network failures) are treated as "unknown" and do NOT
    /// add the email to the banner list. This prevents the false-positive
    /// banner flash that was visible on cold launch when the 3s timeout tripped
    /// before the network stack was ready. Once any per-account probe returns
    /// an authoritative status, `hasSucceededConsentScanOnce` flips true and
    /// sticky-on-error resumes (thrown → keep email in banner) so transient
    /// failures on later scans don't silently remove a truly-broken account.
    func checkPushConsentStatusForForeground() async {
        let nseEnabled = UserDefaults.standard.object(forKey: PushConfig.pushNotificationsEnabledKey) as? Bool ?? false
        guard nseEnabled else { return }

        // Offline → skip entirely. Probing the worker while the device has no
        // internet guarantees every request throws, which before sticky-on-error
        // kicks in would leave all emails out of the banner, and after
        // sticky-on-error would keep a stale banner pinned even though the real
        // cause is "no network" rather than "consent broken". Returning without
        // posting preserves whatever banner state existed before connectivity
        // dropped — a later foreground / reconnect tick re-runs the scan.
        guard NetworkMonitor.checkConnected() else {
            print("[Push] consent scan skipped — device offline")
            return
        }

        let accounts: [Account]
        do {
            accounts = try await dbPool.read { db in
                try Account.filter(Column("isActive") == true).fetchAll(db)
            }
        } catch {
            print("[Push] consent: foreground scan load accounts failed: \(error)")
            return
        }

        // Both `.error` AND `.missing` trigger the re-consent banner when NSE
        // is on. `.missing` is the state after key rotation on the worker
        // (records decrypt-fail → read as null → status=missing) and after
        // user-denial of a prior consent prompt. In both cases the user has
        // NSE enabled but the server can't classify — re-running metadata
        // OAuth fixes both.
        // Parallel scan with per-account 3s timeout. Serial iteration used
        // to worst-case a 5-account user at 15s of view.task blocked time;
        // TaskGroup runs them concurrently (bounded by the network stack),
        // so worst case drops to ~3s regardless of account count. Each
        // subtask is independent + idempotent (read-only GET) — no
        // ordering requirement.
        let gmailEmails = accounts
            .filter { $0.provider == .gmail }
            .map(\.emailAddress)
        let outlookEmails = accounts
            .filter { $0.provider == .outlook }
            .map(\.emailAddress)
        // Per-account probe result. Distinguishing authoritative server replies
        // from thrown errors is critical on cold launch (see first-scan safety
        // note on this method): a timeout is NOT evidence of "needs re-consent",
        // it's evidence that we don't know yet. Lumping both together produced
        // the banner flash on boot.
        enum ProbeResult: Sendable {
            case ok(String)              // authoritative: account is fine
            case confirmedError(String)  // authoritative: server says error/missing
            case threw(String)           // network/timeout — status unknown
        }
        let checker = consentChecker
        let timeout = PushConfig.consentStatusCheckTimeoutSeconds
        let probes = await withTaskGroup(of: ProbeResult.self) { group -> [ProbeResult] in
            for email in gmailEmails {
                group.addTask {
                    do {
                        let status = try await withTimeout(seconds: timeout) {
                            try await checker.getGmailConsentStatus(userEmail: email)
                        }
                        switch status {
                        case .error, .missing: return .confirmedError(email)
                        case .ok: return .ok(email)
                        }
                    } catch {
                        print("[Push] gmail consent-status check failed for \(email): \(error)")
                        return .threw(email)
                    }
                }
            }
            for email in outlookEmails {
                group.addTask {
                    do {
                        let status = try await withTimeout(seconds: timeout) {
                            try await checker.getOutlookConsentStatus(userEmail: email)
                        }
                        switch status {
                        case .error, .missing: return .confirmedError(email)
                        case .ok: return .ok(email)
                        }
                    } catch {
                        print("[Push] outlook consent-status check failed for \(email): \(error)")
                        return .threw(email)
                    }
                }
            }
            var out: [ProbeResult] = []
            for await r in group { out.append(r) }
            return out
        }

        let anyAuthoritative = probes.contains { result in
            switch result {
            case .ok, .confirmedError: return true
            case .threw: return false
            }
        }
        // Sticky-on-error: once we've observed any authoritative status in
        // this process's lifetime, a later thrown error keeps the email in
        // the banner (user had a real problem — don't silently drop it when
        // the check is flaky). Before that first success, a thrown error
        // leaves the email OUT of the banner (unknown, not broken).
        let treatThrownAsError = hasSucceededConsentScanOnce
        let needingReconsent: [String] = probes.compactMap { result in
            switch result {
            case .ok: return nil
            case .confirmedError(let email): return email
            case .threw(let email): return treatThrownAsError ? email : nil
            }
        }
        if anyAuthoritative {
            hasSucceededConsentScanOnce = true
        }

        // First-scan safety: if nothing was authoritative (e.g., all accounts
        // timed out on cold launch), suppress the post entirely. We don't know
        // the state yet — don't clear the banner (could erase a real error from
        // a prior consent_error notification tap) and don't raise it (would
        // flash a false positive). A subsequent foreground / sync trigger will
        // re-run the scan once the network is warm.
        guard anyAuthoritative else {
            print("[Push] consent scan produced no authoritative results — skipping banner update")
            return
        }

        // Always post — empty array clears the banner after a successful
        // re-consent. Posting only on non-empty left the banner visible
        // forever after the user fixed it.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .pushConsentErrorsDetected,
                object: nil,
                userInfo: ["emails": needingReconsent]
            )
        }
    }

    // MARK: - Outlook metadata consent (inner OAuth driver)
    //
    // Only the inner `runOutlookMetadataConsentAndUpload` remains here. The
    // orchestrators that used to live below (ensureOutlookConsent*,
    // revokeOutlookConsent*) were merged into the provider-agnostic
    // `ensurePushConsent*` / `revokePushConsent*` family above, which
    // dispatch per-provider using `account.provider` / `account.hasPushSupport`.

    @MainActor
    private func runOutlookMetadataConsentAndUpload(account: Account, auth: OAuthService) async {
        let email = account.emailAddress
        do {
            try await auth.authenticateMicrosoftMetadataScope(loginHint: email, pushClient: pushClient)
            BackgroundSyncLogger.logPush("Stored Outlook metadata consent for \(email)")
        } catch {
            // Per-account only — matches Gmail path above. A single account's
            // consent decline must not cascade into revoking Gmail + Outlook
            // consents across every account or flipping the NSE toggle off.
            // Foreground banner keeps prompting; user dismisses by completing
            // consent or by toggling NSE off globally themselves.
            if let err = error as? ASWebAuthenticationSessionError, err.code == .canceledLogin {
                print("[Push] outlook-consent: user declined for \(email) — account stays in missing state, banner will re-prompt")
            } else if let err = error as? OAuthError, case .cancelled = err {
                print("[Push] outlook-consent: user declined for \(email) — account stays in missing state, banner will re-prompt")
            } else {
                print("[Push] outlook-consent: transient flow failure for \(email): \(error)")
            }
        }
    }

    // MARK: - Debug

    /// Run the full push registration flow and return step-by-step results.
    func testFullFlow() async -> String {
        var log = ""

        // 1. Device token
        guard let token = UserDefaults.standard.string(forKey: PushConfig.lastDeviceTokenKey) else {
            log += "1. APNs token: MISSING (registerForRemoteNotifications may not have fired yet)\n"
            return log
        }
        log += "1. APNs token: \(token.prefix(16))...\n"

        // 2. Session
        guard let session = TabMailAuthService.getSession() else {
            log += "2. Session: MISSING (not signed in)\n"
            return log
        }
        log += "2. Session: userId=\(session.userId.prefix(8))...\n"

        // 3. Supabase JWT
        let tokenResult = await TabMailTokenCoordinator.shared.validToken()
        switch tokenResult {
        case .success:
            log += "3. Supabase JWT: OK\n"
        case .permanentFailure:
            log += "3. Supabase JWT: PERMANENT FAILURE\n"
            return log
        case .transientFailure:
            log += "3. Supabase JWT: TRANSIENT FAILURE\n"
            return log
        case .noSession:
            log += "3. Supabase JWT: NO SESSION\n"
            return log
        }

        // 4. Register device
        do {
            let emails = try await dbPool.read { db in
                try String.fetchAll(db,
                    Account.select(Column("emailAddress"))
                        .filter(Column("isActive") == true)
                )
            }
            log += "4. Active accounts: \(emails.joined(separator: ", "))\n"

            try await pushClient.registerDevice(
                deviceToken: token,
                deviceId: deviceId,
                userId: session.userId,
                accountEmails: emails,
                apnsSandbox: true // debug-only test flow
            )
            log += "5. Register device: OK\n"
        } catch {
            log += "5. Register device: FAILED — \(error)\n"
            return log
        }

        // 6. Subscribe accounts
        do {
            let accounts = try await dbPool.read { db in
                try Account.filter(Column("isActive") == true).fetchAll(db)
            }
            for account in accounts where account.provider != .imap {
                do {
                    let accessToken = try await AccountManager.shared.freshAccessToken(for: account)
                    try await pushClient.subscribe(
                        provider: account.provider.rawValue,
                        userId: session.userId,
                        userEmail: account.emailAddress,
                        accessToken: accessToken
                    )
                    log += "6. Subscribe \(account.emailAddress): OK\n"
                } catch {
                    log += "6. Subscribe \(account.emailAddress): FAILED — \(error)\n"
                }
            }
        } catch {
            log += "6. Load accounts: FAILED — \(error)\n"
        }

        log += "\nAll done."
        return log
    }

    // MARK: - Silent Push Handling

    /// In-flight sync task. Targeted to a single account per push.
    private var inFlightSyncTask: Task<Void, Never>?
    /// Track which account emails had coalesced pushes during an in-flight sync.
    /// Replaces the boolean `pendingFollowUp` to enable targeted follow-up syncs.
    private var coalescedEmails = Set<String>()
    /// The account email being synced by the current in-flight task.
    private var inFlightEmail: String?

    /// Handle a silent push notification (content-available: 1).
    /// Only syncs the specific account that received the push (not all accounts).
    /// Coalesced pushes for OTHER accounts trigger a targeted follow-up.
    func handleSilentPush(provider: String?, accountEmail: String?) async -> UIBackgroundFetchResult {
        print("[Push] Silent push: provider=\(provider ?? "?"), email=\(accountEmail ?? "?")")
        BackgroundSyncLogger.logPush("Silent push RECEIVED (provider=\(provider ?? "?"), email=\(accountEmail ?? "?"))")

        // Coalescing check FIRST — before any `await`. Two pushes arriving close together
        // could both pass this check if it were after an `await` (actor reentrancy).
        if inFlightSyncTask != nil {
            if let email = accountEmail, email != inFlightEmail {
                coalescedEmails.insert(email)
            }
            BackgroundSyncLogger.log("SilentPush COALESCED (provider=\(provider ?? "?"), email=\(accountEmail ?? "?"))")
            BackgroundSyncLogger.logPush("Silent push COALESCED (sync already in-flight)")
            return .newData
        }

        // Foreground-active oracle (ADR-IOS-056), read once and reused below for
        // (a) the stale-connection guard (unchanged behavior) and (b) the drain-
        // mode decision (`SyncScheduler.drainModeForSilentPush`) — the silent-push
        // budget is a background-envelope watchdog only; a push delivered while
        // the app is foreground-active must not poll-wait on it.
        let isForegroundActive = await MainActor.run { UIApplication.shared.applicationState == .active }

        // Only mark providers dirty when waking from background — connections may be stale
        // after iOS suspension. In foreground, connections are live; marking dirty would
        // unnecessarily drain IMAP pools and kill IDLE sessions.
        if !isForegroundActive {
            await AccountManager.shared.markAllProvidersDirty()
        }

        // Ensure BGAppRefresh is scheduled — previous schedules may have been purged
        // if iOS killed the app. Uses scheduleIfNeeded to avoid resetting the timer
        // on every push (which would perpetually push BGAppRefresh forward).
        await SyncScheduler.shared.scheduleBackgroundSyncIfNeeded()

        // NSE follow-up push — NSE already did summary + action. Do heavy work now.
        if provider == "nse_followup" {
            print("[Push] NSE follow-up — merging staging data + heavy AI work")
            BackgroundSyncLogger.log("SilentPush NSE_FOLLOWUP — merge + reply precompute + FTS + tags")
            BackgroundSyncLogger.logPush("NSE_FOLLOWUP — heavy AI work")
            await NSEDataBridge.mergeNSEStagingData()
            // Sync first to persist MessageHeaders, then AI queue picks up reply precomputation.
            // foregroundFastPath: the oracle inside syncStartup still forces a full recovery
            // when this push woke us from the background (applicationState != .active) or any
            // background occurred since the last recovery — it only skips the in-flight cancel
            // when the app is provably continuous-foreground.
            // drain: ADR-IOS-056 — `.none` when foreground-active (the active queues
            // self-drain at `.normal`; nothing should hold this handler open), else the
            // background-envelope `.budget` (unchanged behavior for an actual bg wake).
            await SyncScheduler.shared.syncStartup(
                inboxOnly: true,
                drain: SyncScheduler.drainModeForSilentPush(isForegroundActive: isForegroundActive),
                foregroundFastPath: true
            )
            return .newData
        }

        BackgroundSyncLogger.log("SilentPush RECEIVED (provider=\(provider ?? "?"), email=\(accountEmail ?? "?"))")
        let pushT0 = CFAbsoluteTimeGetCurrent()
        BackgroundSyncLogger.logPush("Silent push processing — starting unified sync for \(accountEmail ?? "all")")

        // Set sentinel BEFORE any await — prevents concurrent pushes from slipping
        // through the coalescing check during actor reentrancy.
        let sentinelTask = Task<Void, Never> {}
        inFlightSyncTask = sentinelTask
        inFlightEmail = accountEmail

        // Unified sync startup with budget-limited drain.
        // syncStartup handles: cancel stale tasks, recover incomplete headers,
        // mark connections dirty, sync all accounts, drain pending ops, repopulate queues.
        let syncTask = Task { @Sendable in
            // foregroundFastPath: skip the in-flight AI cancel only when the oracle confirms
            // continuous-foreground. A silent push that woke us from background still recovers
            // (applicationState != .active → mayHaveStaleConnections() == true).
            // drain: ADR-IOS-056 — see the nse_followup branch above for the rationale.
            await SyncScheduler.shared.syncStartup(
                inboxOnly: true,
                drain: SyncScheduler.drainModeForSilentPush(isForegroundActive: isForegroundActive),
                foregroundFastPath: true
            )
            // One-time FTS tokenizer migration (ADR-024) — small post-sync slice,
            // bounded by BOTH the slice budget AND the remaining push envelope so
            // the fetch completion is never delayed past the deadline race. Sync
            // always comes first; the race cancels this task on deadline win and
            // GRDB rolls back any mid-shard write.
            let envelopeRemaining = PushConfig.silentPushDeadlineSeconds
                - (CFAbsoluteTimeGetCurrent() - pushT0)
            let slice = min(SearchConfig.retokenizeShortWindowBudgetSec, envelopeRemaining)
            if slice > 1 {
                await SearchIndex.shared.rebuildStaleTokenizerShards(
                    deadline: Date().addingTimeInterval(slice))
            }
            await MainActor.run { SyncScheduler.shared.scheduleBackgroundProcessing() }
        }
        inFlightSyncTask = syncTask

        // Race against deadline — iOS can kill us at any point.
        let deadlineNs = UInt64(PushConfig.silentPushDeadlineSeconds * 1_000_000_000)
        let resumed = Mutex(false)
        let deadlineHit = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task { @Sendable in
                await syncTask.value
                let isFirst = resumed.withLock { val -> Bool in
                    if !val { val = true; return true }
                    return false
                }
                if isFirst { continuation.resume(returning: false) }
            }
            Task { @Sendable in
                try? await Task.sleep(nanoseconds: deadlineNs)
                let isFirst = resumed.withLock { val -> Bool in
                    if !val { val = true; return true }
                    return false
                }
                if isFirst { continuation.resume(returning: true) }
            }
        }
        // On deadline win, syncTask is still running. Wind it down via the unified
        // cancellation path so actor-owned queue Tasks (AI heartbeat in particular)
        // stop drumming on the App Group SQLite before iOS suspends — same
        // rationale as the BGAppRefresh / BGProcessing expiration handlers.
        if deadlineHit {
            syncTask.cancel()
            await SyncScheduler.cancelAllInFlightQueues(inboxOnly: true)
            // The happy path schedules BGProcessing at the end of syncTask —
            // cancelled here, so schedule it ourselves or the queued work (and
            // any pending tokenizer-migration shards) loses this follow-up.
            await MainActor.run { SyncScheduler.shared.scheduleBackgroundProcessing() }
            BackgroundSyncLogger.logPush("Silent push DEADLINE — cancelled in-flight sync + queues")
        }
        inFlightSyncTask = nil
        inFlightEmail = nil

        let pushElapsed = Int((CFAbsoluteTimeGetCurrent() - pushT0) * 1000)
        BackgroundSyncLogger.log("SilentPush COMPLETED in \(pushElapsed)ms")
        BackgroundSyncLogger.logPush("Silent push COMPLETED in \(pushElapsed)ms")
        print("[Push] Silent push completed in \(pushElapsed)ms")

        // Coalesced pushes for other accounts — syncStartup already synced all accounts,
        // so just clear the coalesced set. No per-account follow-up needed.
        if !coalescedEmails.isEmpty {
            BackgroundSyncLogger.log("SilentPush: \(coalescedEmails.count) coalesced email(s) covered by syncStartup")
            coalescedEmails.removeAll()
        }

        return .newData
    }
}

// MARK: - Notification settings seam (test-injectable)

/// Snapshot of the presentation-relevant notification settings. Abstracted from
/// `UNNotificationSettings` (which has no public initializer) so the
/// visible-vs-silent decision in `PushNotificationService.visualAlertsEnabled`
/// is unit-testable without a real `UNUserNotificationCenter`.
struct NotificationVisibilitySnapshot: Sendable {
    let authorizationStatus: UNAuthorizationStatus
    let alertSetting: UNNotificationSetting
    let lockScreenSetting: UNNotificationSetting
    let notificationCenterSetting: UNNotificationSetting
}

/// Narrow seam consumed by `PushNotificationService.visualAlertsEnabled`. The
/// production conformance reads the live system settings; tests inject a mock
/// via `_setNotificationSettingsProviderForTesting` (DEBUG-only).
protocol NotificationSettingsProviding: Sendable {
    func currentVisibility() async -> NotificationVisibilitySnapshot
}

/// Production provider — reads the live settings from `UNUserNotificationCenter`.
struct SystemNotificationSettingsProvider: NotificationSettingsProviding {
    static let shared = SystemNotificationSettingsProvider()
    func currentVisibility() async -> NotificationVisibilitySnapshot {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationVisibilitySnapshot(
            authorizationStatus: s.authorizationStatus,
            alertSetting: s.alertSetting,
            lockScreenSetting: s.lockScreenSetting,
            notificationCenterSetting: s.notificationCenterSetting
        )
    }
}
