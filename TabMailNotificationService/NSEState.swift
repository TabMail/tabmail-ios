/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum NSEState {
    private static var suite: SendableUserDefaults { SharedNSEData.suite }

    // MARK: - Reads (main app writes)

    static func findAccountId(for email: String) -> String? {
        guard let json = suite.string(forKey: SharedNSEData.accountMapKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return map[email]
    }

    /// All registered account email addresses (keys of the email→accountId map
    /// the main app mirrors). Used only for the recipient-status SUPPRESS set —
    /// returns [] when the mirror is missing (suppression just narrows).
    static func getAllAccountEmails() -> [String] {
        guard let json = suite.string(forKey: SharedNSEData.accountMapKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [] }
        return Array(map.keys)
    }

    static func getUserName() -> String? {
        suite.string(forKey: SharedNSEData.userNameKey)
    }

    static func getActionPrompt() -> String? {
        suite.string(forKey: SharedNSEData.actionPromptKey)
    }

    static func getKBText() -> String? {
        suite.string(forKey: SharedNSEData.kbTextKey)
    }

    static func getCompositionPrompt() -> String? {
        suite.string(forKey: SharedNSEData.compositionPromptKey)
    }

    static func getBackendBaseURL() -> String {
        suite.string(forKey: SharedNSEData.backendBaseURLKey) ?? "https://api.tabmail.ai"
    }

    static func getPushWorkerURL() -> String {
        suite.string(forKey: SharedNSEData.pushWorkerURLKey) ?? "https://push.tabmail.ai"
    }

    static func isIMAPPushEnabled() -> Bool {
        suite.bool(forKey: SharedNSEData.imapPushEnabledKey)
    }

    /// Minimal IMAP connection info the NSE needs to open a one-shot socket
    /// for `imap_new_mail` / `imap_reconnect` processing. Password lives in
    /// shared Keychain — `SharedKeychain.getPassword(for: accountId)`.
    ///
    /// The main app re-derives this at every *mail* account-add site and on
    /// every foreground return, via `NSEDataBridge.mirrorAccountIdentity()`.
    /// Several `Account` inserts deliberately do not, and they are safe for one
    /// shared reason rather than by name: none of them can produce a row that
    /// `mirrorIMAPAccounts` would emit, because that half admits only
    /// `provider IN ('imap','icloud')` WITH a non-empty `imapHost`.
    /// `AccountManager.addCalDAVAccount` and both `CalendarSetupView` arms write
    /// `calendarOnly` rows on non-IMAP providers; `DemoSeed`, `ScreenshotMode`
    /// and the preview fixtures write rows with no `imapHost`. (`mirrorAccountMap`
    /// does still hold calendar-only addresses — the extension needs them for
    /// its suppress set — which is why that half gives a mail row precedence
    /// over a calendar row at the same address.) Account *removal* runs BOTH
    /// mechanisms in order: `NSEDataBridge.removeAccountFromMirrors()` edits
    /// both mirrors in place before the row is deleted (so process death cannot
    /// leave a committed deletion resolvable), and a re-derivation follows once
    /// that delete commits (so the survivor of a shared address, whose key the
    /// clearing takes with it, is restored). An
    /// account-field *edit* has no refresh at its write site and converges on
    /// the next foreground return, so a mirrored column can be one edit stale
    /// for as long as the app stays in the foreground (`IOS-NSE-008` residual
    /// B). That bound has no last-account edge: the fields are editable only
    /// through the sidebar, which lists active non-calendar accounts, so an
    /// account that can be edited is by construction one that keeps the
    /// foreground pass's account gate open.
    struct IMAPAccountInfo: Sendable {
        let host: String
        let port: Int
        let username: String
        let useTLS: Bool?
    }

    static func getIMAPAccount(for accountId: String) -> IMAPAccountInfo? {
        guard let json = suite.string(forKey: SharedNSEData.imapAccountsKey),
              let data = json.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              let entry = map[accountId],
              let host = entry["host"] as? String,
              let username = entry["username"] as? String else {
            return nil
        }
        let port = (entry["port"] as? Int) ?? 993
        // `useTLS` stored as a Bool or Int(0/1). nil = "let SwiftMail decide".
        let useTLS: Bool?
        if let b = entry["useTLS"] as? Bool { useTLS = b }
        else if let n = entry["useTLS"] as? Int { useTLS = n != 0 }
        else { useTLS = nil }
        return IMAPAccountInfo(host: host, port: port, username: username, useTLS: useTLS)
    }

    /// Whether Apple has approved the filtering entitlement (can fully suppress).
    static func isFilteringApproved() -> Bool {
        suite.bool(forKey: SharedNSEData.filteringApprovedKey)
    }

    /// Whether Device Sync is enabled (user setting). Controls AI cache probe.
    static func isDeviceSyncEnabled() -> Bool {
        suite.defaults.object(forKey: SharedNSEData.deviceSyncEnabledKey) as? Bool ?? true
    }

    /// Sync server base URL for AI cache probe REST endpoint.
    static func getSyncBaseURL() -> String {
        suite.string(forKey: SharedNSEData.syncBaseURLKey) ?? "https://sync.tabmail.ai"
    }

    /// Privacy opt-out: skip all backend AI calls. Written by the main app's
    /// Settings and consent flow. Default false (AI enabled) so missing key
    /// never silently blocks AI on a fresh install.
    static func isAIDisabled() -> Bool {
        suite.bool(forKey: SharedNSEData.aiOptOutAllKey)
    }

    static func getLastHistoryId(for accountId: String) -> String? {
        guard let json = suite.string(forKey: SharedNSEData.lastHistoryIdsKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return map[accountId]
    }

    // MARK: - Badge (temporary incremental approximation)
    //
    // The NSE cannot read main GRDB (app-private container), so it maintains
    // a temporary incremental counter in shared UserDefaults as a best-effort
    // badge approximation. This counter is NOT authoritative — it drifts.
    //
    // The main app's UnreadCountManager.updateBadge() overwrites this on
    // every recount with the authoritative inbox unread count
    // (SUM(folder.unreadCount) WHERE role = inbox).
    //
    // The counter exists solely to give iOS a reasonable badge number between
    // NSE runs and the next app wake. Counter logic lives in the shared
    // `NSEBadge` — per-delivery badge values MUST go through
    // `NSEBadge.badgeForDelivery` (idempotent per message, main-app-overlap
    // aware), not these raw primitives. The raw increment/decrement below are
    // only for the legacy history.list delta-adjust path, which counts label
    // flips on EXISTING messages (disjoint from delivered-message counting).

    static func incrementBadgeCount() -> Int {
        NSEBadge.increment(suite: suite.defaults)
    }

    static func decrementBadgeCount(by count: Int) -> Int {
        NSEBadge.decrement(by: count, suite: suite.defaults)
    }

    /// Advance the historyId for an account after NSE processes history.list.
    /// Only advances forward — never overwrites a higher value (main app may have advanced it).
    /// Prevents re-processing the same events on subsequent pushes.
    static func setLastHistoryId(_ historyId: String, for accountId: String) {
        guard let json = suite.string(forKey: SharedNSEData.lastHistoryIdsKey),
              let data = json.data(using: .utf8),
              var map = try? JSONDecoder().decode([String: String].self, from: data) else {
            // No existing map — create one
            if let data = try? JSONEncoder().encode([accountId: historyId]),
               let str = String(data: data, encoding: .utf8) {
                suite.set(str, forKey: SharedNSEData.lastHistoryIdsKey)
            }
            return
        }
        // Only advance forward — historyIds are numeric strings
        if let existing = map[accountId],
           let existingNum = UInt64(existing),
           let newNum = UInt64(historyId),
           newNum <= existingNum {
            return // Don't regress
        }
        map[accountId] = historyId
        if let data = try? JSONEncoder().encode(map),
           let str = String(data: data, encoding: .utf8) {
            suite.set(str, forKey: SharedNSEData.lastHistoryIdsKey)
        }
    }
}
