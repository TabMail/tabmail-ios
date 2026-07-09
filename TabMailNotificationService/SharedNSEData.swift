/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// @unchecked Sendable: UserDefaults is inherently thread-safe.
/// Per project convention, @unchecked Sendable is acceptable for thread-safe API wrappers.
struct SendableUserDefaults: @unchecked Sendable {
    let defaults: UserDefaults
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    func array(forKey key: String) -> [Any]? { defaults.array(forKey: key) }
    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
}

enum SharedNSEData {
    static let appGroupIdentifier = "group.ai.tabmail"
    static let suite = SendableUserDefaults(defaults: UserDefaults(suiteName: appGroupIdentifier)!)

    // Main app writes, NSE reads
    static let accountMapKey = "nse.accountMap"
    /// Per-IMAP-account connection info the NSE needs for one-shot fetches
    /// on `imap_new_mail` / `imap_reconnect` pushes. JSON-encoded:
    ///   accountId → { host, port, username, useTLS }
    /// The password lives in shared Keychain (`SharedKeychain.getPassword`) —
    /// never in this mirror. Main app writes on account add/remove; NSE
    /// reads per push. See `NSEState.getIMAPAccount`.
    static let imapAccountsKey = "nse.imapAccounts"
    static let userNameKey = "nse.userName"
    static let actionPromptKey = "nse.actionPrompt"
    static let kbTextKey = "nse.kbText"
    static let compositionPromptKey = "nse.compositionPrompt"
    static let backendBaseURLKey = "nse.backendBaseURL"
    static let pushWorkerURLKey = "nse.pushWorkerURL"
    static let schemaVersionKey = "nse.schemaVersion"
    static let imapPushEnabledKey = "nse.imapPushEnabled"
    static let lastHistoryIdsKey = "nse.lastHistoryIds"
    static let taskSchedulesKey = "nse.taskSchedules"
    static let filteringApprovedKey = "nse.filteringApproved"
    static let deviceSyncEnabledKey = "nse.deviceSyncEnabled"
    static let syncBaseURLKey = "nse.syncBaseURL"

    // NSE writes, main app overwrites with the authoritative count.
    // Canonical constant lives in the shared NSEBadge (visible to both
    // targets) — this alias keeps existing NSE-side callers compiling.
    static let badgeCountKey = NSEBadge.badgeCountKey

    /// Privacy opt-out flag. Shared so NSE and main app agree — otherwise main
    /// app's UserDefaults.standard is a separate namespace from the NSE process
    /// and NSE never sees the toggle. Same literal key as AIService.optOutAllAIKey
    /// so the two constants match.
    static let aiOptOutAllKey = "privacy_opt_out_all_ai"

    /// Persistent NSE file-log gate. Mirrored by `NSEDataBridge.mirrorDebugLogging()`
    /// (launch + immediately on unlock/lock) from `DebugModeManager.isLoggingEnabled()`.
    /// Same literal key as `NSELogStore.debugLoggingEnabledKey` — `NSELogStore`
    /// (Shared/) can't reference this NSE-target-only enum, so it re-declares
    /// the literal; this alias exists for NSE-side call sites that prefer the
    /// named constant.
    static let debugLoggingEnabledKey = NSELogStore.debugLoggingEnabledKey
}
