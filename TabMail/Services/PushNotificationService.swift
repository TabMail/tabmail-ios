/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AuthenticationServices
import Foundation
import GRDB
import Synchronization
import UIKit
import UserNotifications

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
    private var dbPool: DatabasePool { AppDatabase.dbPool }

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
        let tokenHex = tokenData.map { String(format: "%02x", $0) }.joined()
        print("[Push] APNs device token: \(tokenHex.prefix(16))...")
        BackgroundSyncLogger.logPush("APNs device token received: \(tokenHex.prefix(16))...")

        UserDefaults.standard.set(tokenHex, forKey: PushConfig.lastDeviceTokenKey)
        NSEDataBridge.mirrorDeviceToken()
        await registerDeviceWithWorker(tokenHex: tokenHex, force: true)
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
        guard let sessionData = KeychainHelper.load(key: "tabmail_session"), let session = try? JSONDecoder().decode(TabMailSession.self, from: sessionData) else {
            print("[Push] No session — skipping device registration")
            return
        }

        let token = tokenHex ?? UserDefaults.standard.string(forKey: PushConfig.lastDeviceTokenKey)
        guard let deviceToken = token else {
            print("[Push] No device token — skipping registration")
            return
        }

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

    /// Unregister this device from push worker (sign-out / factory reset).
    func unregisterDevice() async {
        do {
            try await pushClient.unregisterDevice(deviceId: deviceId)
            UserDefaults.standard.removeObject(forKey: PushConfig.lastDeviceTokenKey)
            UserDefaults.standard.removeObject(forKey: PushConfig.registeredEmailsKey)
            print("[Push] Device unregistered")
            BackgroundSyncLogger.logPush("Device unregistered")
        } catch {
            print("[Push] Device unregister failed: \(error)")
            BackgroundSyncLogger.logPush("Device unregister FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Account Subscription

    /// Subscribe a single account for push notifications.
    /// Gmail/Outlook → Pub/Sub / Graph subscription. IMAP → DO IDLE proxy
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
        guard let sessionData = KeychainHelper.load(key: "tabmail_session"), let session = try? JSONDecoder().decode(TabMailSession.self, from: sessionData) else {
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
                // DO IDLE proxy path as generic IMAP. CalDAV is calendar-only, no
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
                BackgroundSyncLogger.logPush("Subscribed IMAP \(account.emailAddress) via DO IDLE proxy")
            case .caldav:
                return  // calendar-only, no mailbox to IDLE on
            }

            // Per-(device, account) registration — decides visible vs silent
            // push per-account at dispatch time. nseCapable ⇔ (global NSE
            // toggle ON) AND this provider's NSE is end-to-end ready.
            if let deviceToken = UserDefaults.standard.string(forKey: PushConfig.lastDeviceTokenKey),
               let deviceId = UserDefaults.standard.string(forKey: PushConfig.deviceIdKey) {
                let nseEnabled = UserDefaults.standard.object(forKey: PushConfig.pushNotificationsEnabledKey) as? Bool ?? false
                // Visible (nse) push needs a VISUAL surface enabled in iOS
                // settings (Lock Screen / Notification Center / Banner) —
                // otherwise iOS won't present it and won't run the NSE. When the
                // in-app toggle is on but no visual surface is enabled, register
                // SILENT (do NOT skip) so the app still wakes to sync + badge.
                //
                // Read LIVE here (no cached capability): iOS notification
                // settings can only change in the Settings app, which requires
                // backgrounding TabMail — so the foreground re-subscribe
                // (`SyncScheduler.startForegroundPolling` → `subscribeAllAccounts`)
                // always re-runs this with the current value after any change,
                // and the worker upserts idempotently. No separate reconcile /
                // stored-state needed. See PLAN_NSE_ENHANCE §3.2/§3.3.
                let visualOn = await visualAlertsEnabled()
                // iCloud routes through the IMAP IDLE proxy (app-password IMAP) —
                // the droplet emits /imap-new-mail tagged provider="imap", so the
                // device registration must match to receive visible push.
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
                    // Not fatal — dispatch will fall back to legacy device-level record.
                }
            }
        } catch {
            print("[Push] Subscribe failed for \(account.emailAddress): \(error)")
            BackgroundSyncLogger.logPush("Subscribe FAILED for \(account.emailAddress): \(error.localizedDescription)")
        }

        if updateDeviceRegistration {
            await registerDeviceWithWorker()
        }
    }

    /// Unsubscribe a single account from push notifications.
    func unsubscribeAccount(_ account: Account) async {
        do {
            switch account.provider {
            case .gmail, .outlook:
                let accessToken = try await AccountManager.shared.freshAccessToken(for: account)
                try await pushClient.unsubscribe(
                    provider: account.provider.rawValue,
                    userEmail: account.emailAddress,
                    accessToken: accessToken
                )
                BackgroundSyncLogger.logPush("Unsubscribed \(account.emailAddress)")
                return
            case .imap, .icloud:
                try await pushClient.unsubscribeIMAP(userEmail: account.emailAddress)
                BackgroundSyncLogger.logPush("Unsubscribed IMAP \(account.emailAddress)")
                return
            case .caldav:
                return  // no mailbox, no subscription
            }
        } catch {
            print("[Push] Unsubscribe failed for \(account.emailAddress): \(error)")
            BackgroundSyncLogger.logPush("Unsubscribe FAILED for \(account.emailAddress): \(error.localizedDescription)")
        }
    }

    /// Subscribe all active accounts (Gmail/Outlook + IMAP via DO IDLE proxy),
    /// then re-register device once. Account subscriptions run in parallel —
    /// each is an independent worker round-trip with no shared state.
    func subscribeAllAccounts() async {
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
        guard let sessionData = KeychainHelper.load(key: "tabmail_session"), let session = try? JSONDecoder().decode(TabMailSession.self, from: sessionData) else {
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

        // Only mark providers dirty when waking from background — connections may be stale
        // after iOS suspension. In foreground, connections are live; marking dirty would
        // unnecessarily drain IMAP pools and kill IDLE sessions.
        if await MainActor.run(body: { UIApplication.shared.applicationState != .active }) {
            await AccountManager.shared.markAllProvidersDirty()
        }

        // Ensure BGAppRefresh is scheduled — previous schedules may have been purged
        // if iOS killed the app. Uses scheduleIfNeeded to avoid resetting the timer
        // on every push (which would perpetually push BGAppRefresh forward).
        await SyncScheduler.shared.scheduleBackgroundSyncIfNeeded()

        // Task alarm push — evaluate tasks, then do delta sync if time permits
        if provider == "task_alarm" {
            print("[Push] Task alarm wake — evaluating tasks")
            BackgroundSyncLogger.log("SilentPush TASK_ALARM — evaluating tasks then delta sync")
            BackgroundSyncLogger.logPush("TASK_ALARM — evaluating tasks then delta sync")
            NSEDataBridge.mergeNSEStagingData()
            await TaskEvaluationService.shared.evaluate()
            await SyncScheduler.shared.backgroundPoll()
            return .newData
        }

        // NSE follow-up push — NSE already did summary + action. Do heavy work now.
        if provider == "nse_followup" {
            print("[Push] NSE follow-up — merging staging data + heavy AI work")
            BackgroundSyncLogger.log("SilentPush NSE_FOLLOWUP — merge + reply precompute + FTS + tags")
            BackgroundSyncLogger.logPush("NSE_FOLLOWUP — heavy AI work")
            NSEDataBridge.mergeNSEStagingData()
            // Sync first to persist MessageHeaders, then AI queue picks up reply precomputation
            await SyncScheduler.shared.syncStartup(
                inboxOnly: true,
                drain: .budget(PushConfig.silentPushDeadlineSeconds)
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
            await SyncScheduler.shared.syncStartup(
                inboxOnly: true,
                drain: .budget(PushConfig.silentPushDeadlineSeconds)
            )
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
