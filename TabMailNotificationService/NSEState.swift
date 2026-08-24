/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum NSEState {
    private static var suite: SendableUserDefaults { SharedNSEData.suite }
    static let rejectedAccountPushMarkerKey = "tabmail.rejectedAccountPush"

    // MARK: - Reads (main app writes)

    static func findAccountId(for email: String) -> String? {
        guard let json = suite.string(forKey: SharedNSEData.accountMapKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return map[email.lowercased()]
    }

    static func accountIncarnationMatches(_ accountIncarnation: String?, for email: String) -> Bool {
        guard !email.isEmpty else { return true }
        guard let accountIncarnation, !accountIncarnation.isEmpty else { return false }
        return findAccountId(for: email) == accountIncarnation
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
    /// shared Keychain — `SharedKeychain.getPassword(for: accountId)`. Main
    /// app writes this on account add/remove via `NSEDataBridge.mirrorIMAPAccounts()`.
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

    static func findTaskInstruction(for taskName: String) -> String? {
        guard let tasks = suite.array(forKey: SharedNSEData.taskSchedulesKey) as? [[String: Any]] else { return nil }
        return tasks.first { ($0["name"] as? String) == taskName }?["instruction"] as? String
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
