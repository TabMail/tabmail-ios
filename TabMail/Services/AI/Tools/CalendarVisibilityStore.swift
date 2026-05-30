/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Per-calendar visibility override for the TabMail agent.
///
/// **Local-only, per-device configuration.** Never synced to Google /
/// Exchange / CalDAV, never synced via DeviceSync. Each device maintains
/// its own visibility preferences for what the agent should consider.
///
/// **Default policy: only the *primary* calendar of each account is visible.**
/// Subscribed feeds, holiday calendars, shared calendars, free/busy
/// calendars are all hidden until the user explicitly opts them in via the
/// eye toggle in Settings → Tools → Calendar. The opt-in choice is stored
/// here.
///
/// Resolution precedence:
///
/// 1. User override (this store)
/// 2. Default: visible iff `cal.primary == true`
///
/// Storage: a single `UserDefaults` dictionary at `agentCalendarVisibility`,
/// keyed `"\(accountId):\(calendarId)" → Bool`. Absence of a key means
/// "no override; fall through to the primary-only default".
enum CalendarVisibilityStore {
    static let defaultsKey = "agentCalendarVisibility"

    private static func storageKey(accountId: String, calendarId: String) -> String {
        "\(accountId):\(calendarId)"
    }

    private static func loadAll() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Bool] ?? [:]
    }

    private static func saveAll(_ dict: [String: Bool]) {
        if dict.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(dict, forKey: defaultsKey)
        }
    }

    /// Returns the user's explicit override, or nil if none.
    static func override(accountId: String, calendarId: String) -> Bool? {
        loadAll()[storageKey(accountId: accountId, calendarId: calendarId)]
    }

    /// Sets or clears the override. Pass `nil` to clear and fall back to the
    /// provider default.
    static func setOverride(_ value: Bool?, accountId: String, calendarId: String) {
        var dict = loadAll()
        let key = storageKey(accountId: accountId, calendarId: calendarId)
        if let value {
            dict[key] = value
        } else {
            dict.removeValue(forKey: key)
        }
        saveAll(dict)
    }

    /// What `isVisible` would return if there were no user override.
    /// **Primary calendars are visible by default; everything else is hidden.**
    /// Exposed so the settings UI can compare the user's tap against this
    /// and clear the override when they match, without duplicating the
    /// resolution logic.
    static func providerDefault(_ cal: GCalCalendar) -> Bool {
        return cal.primary == true
    }

    /// Resolved visibility for a calendar. Single source of truth — used by
    /// the agent's calendar fetch path AND the settings UI so the two
    /// never drift.
    static func isVisible(_ cal: GCalCalendar, accountId: String) -> Bool {
        if let override = override(accountId: accountId, calendarId: cal.id) {
            return override
        }
        return providerDefault(cal)
    }

    /// Why the resolver returned its decision — for diagnostic logging only.
    enum Reason: String {
        case userOverride = "user-override"
        case defaultNonPrimary = "default-non-primary"
        case defaultPrimary = "default-primary"
    }

    static func reason(_ cal: GCalCalendar, accountId: String) -> Reason {
        if override(accountId: accountId, calendarId: cal.id) != nil {
            return .userOverride
        }
        return cal.primary == true ? .defaultPrimary : .defaultNonPrimary
    }

    // MARK: - Test seam

    /// Wipe all overrides. Test-only helper; production code should call
    /// `setOverride(nil, …)` for individual entries.
    static func _resetForTesting() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
