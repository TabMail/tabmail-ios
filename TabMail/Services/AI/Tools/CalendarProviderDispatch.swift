/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Dispatches calendar tool calls to the appropriate calendar API.
/// Gmail accounts → Google Calendar API, Outlook accounts → Microsoft Graph Calendar API.
enum CalendarBackend: Sendable {
    case google(provider: GoogleCalendarProvider, account: Account)
    case outlook(provider: ExchangeCalendarProvider, account: Account)
    case caldav(provider: CalDAVProvider, account: Account)
    /// Demo mode's local mock calendar (ADR-IOS-038) — GRDB-backed, no network.
    case demo(provider: DemoCalendarProvider, account: Account)
    case none

    /// Returns the provider and account, regardless of backend type.
    var resolved: (provider: any CalendarProvider, account: Account)? {
        switch self {
        case .google(let p, let a): return (p, a)
        case .outlook(let p, let a): return (p, a)
        case .caldav(let p, let a): return (p, a)
        case .demo(let p, let a): return (p, a)
        case .none: return nil
        }
    }
}

enum CalendarProviderDispatch {
    /// UserDefaults key for the user's preferred calendar ID.
    /// Empty / nil = "primary" (the user's main calendar).
    static let preferredCalendarKey = "preferred_calendar_id"
    /// Legacy key — kept for reading existing preferences.
    static let preferredGoogleCalendarKey = "google_calendar_preferred_id"

    /// UserDefaults key for the preferred account (when multiple accounts exist).
    static let preferredCalendarAccountKey = "preferred_calendar_account_id"
    /// Legacy key — kept for reading existing preferences.
    static let preferredGoogleAccountKey = "google_calendar_preferred_account_id"

    /// UserDefaults key for the default event duration (minutes) used when the
    /// agent omits `end_iso` on `calendar_event_create`. Resolved client-side
    /// — the LLM is never asked to compute this. Range guarded at read time.
    static let defaultEventDurationKey = "default_event_duration_minutes"
    /// Fallback when the user hasn't set a preference yet.
    static let defaultEventDurationFallback = 45

    /// Resolved default duration in minutes — clamped to a sane range so a
    /// stray UserDefaults value can't produce zero-length or absurdly long events.
    static var defaultEventDurationMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: defaultEventDurationKey)
        guard stored > 0 else { return defaultEventDurationFallback }
        return min(max(stored, 5), 12 * 60)
    }

    /// Resolved calendar ID from user preference, falling back to "primary".
    /// For CalDAV providers, "primary" is resolved to the first writable calendar at call time.
    static var defaultCalendarIdForCreation: String {
        // Check new key first, fall back to legacy Google-specific key
        let stored = UserDefaults.standard.string(forKey: preferredCalendarKey)
            ?? UserDefaults.standard.string(forKey: preferredGoogleCalendarKey)
            ?? ""
        return stored.isEmpty ? "primary" : stored
    }

    /// Resolve the calendarId for a specific provider. For CalDAV, "primary" means
    /// we need to call primaryCalendarId(). For Google/Exchange, "primary" works natively.
    static func defaultCalendarIdForCreation(for provider: any CalendarProvider) async -> String {
        let stored = defaultCalendarIdForCreation
        if stored != "primary" { return stored }
        // For CalDAV, "primary" must be resolved to an actual calendar path
        if provider is CalDAVProvider {
            return (try? await provider.primaryCalendarId()) ?? stored
        }
        return stored
    }

    /// Resolve the active calendar backend for tool calls.
    /// Uses the preferred account if set, otherwise falls back to the first account with a calendar provider.
    static func resolve(db: (any DatabaseReader & Sendable)? = nil) async -> CalendarBackend {
        let dbReader: any DatabaseReader & Sendable = db ?? AppDatabase.rawPool
        let manager = AccountManager.shared

        // Snapshot calendarProviders from actor
        let calProviders = await manager.calendarProviders

        // Demo boundary (ADR-IOS-038): demo calendar tools MUST resolve the
        // DemoCalendarProvider only — during debug-menu coexistence the real
        // user's calendar providers stay registered and would otherwise be
        // picked (real reads AND real event writes from a demo chat).
        if DemoModeStore.isDemoActive {
            if let demoProvider = calProviders[DemoSeed.demoAccountId],
               let account = try? await dbReader.read({ db in
                   try Account.filter(Column("id") == DemoSeed.demoAccountId && Column("isActive") == true).fetchOne(db)
               }) {
                return backendFor(provider: demoProvider, account: account)
            }
            return .none
        }

        // Use preferred account if set and still active
        // Check new key first, fall back to legacy Google-specific key
        let preferredAccountId = UserDefaults.standard.string(forKey: preferredCalendarAccountKey)
            ?? UserDefaults.standard.string(forKey: preferredGoogleAccountKey)
            ?? ""
        if !preferredAccountId.isEmpty,
           preferredAccountId != DemoSeed.demoAccountId,
           let calProvider = calProviders[preferredAccountId],
           let account = try? await dbReader.read({ db in
               try Account.filter(Column("id") == preferredAccountId && Column("isActive") == true).fetchOne(db)
           }) {
            return backendFor(provider: calProvider, account: account)
        }

        // Fall back to first account with a calendar provider (never demo).
        for (accountId, calProvider) in calProviders where accountId != DemoSeed.demoAccountId {
            if let account = try? await dbReader.read({ db in
                try Account.filter(Column("id") == accountId && Column("isActive") == true).fetchOne(db)
            }) {
                return backendFor(provider: calProvider, account: account)
            }
        }
        return .none
    }

    /// Resolve ALL connected calendar backends.
    /// Snapshots the providers dict on main actor (instant), then does GRDB reads off-main
    /// to avoid holding the main actor during IO.
    static func resolveAll(db: (any DatabaseReader & Sendable)? = nil) async -> [(provider: any CalendarProvider, account: Account)] {
        let dbReader: any DatabaseReader & Sendable = db ?? AppDatabase.rawPool
        // One instant main-actor hop to snapshot the dict
        let calProviders = await AccountManager.shared.calendarProviders
        // Demo boundary (ADR-IOS-038): demo enumerates ONLY the demo provider;
        // normal mode never includes it (see resolve()).
        let demoActive = DemoModeStore.isDemoActive
        // Rest runs off-main — GRDB is thread-safe
        var results: [(provider: any CalendarProvider, account: Account)] = []
        for (accountId, calProvider) in calProviders
        where (accountId == DemoSeed.demoAccountId) == demoActive {
            if let account = try? await dbReader.read({ db in
                try Account.filter(Column("id") == accountId && Column("isActive") == true).fetchOne(db)
            }) {
                results.append((provider: calProvider, account: account))
            }
        }
        return results
    }

    /// Standard error message when no calendar provider is available.
    static let notAvailableMessage = #"{"error": "Calendar features require a connected calendar (Gmail, Outlook, iCloud, or CalDAV). Add a calendar in Settings to use calendar tools."}"#

    // MARK: - Helpers

    private static func backendFor(provider: any CalendarProvider, account: Account) -> CalendarBackend {
        if let google = provider as? GoogleCalendarProvider {
            return .google(provider: google, account: account)
        } else if let exchange = provider as? ExchangeCalendarProvider {
            return .outlook(provider: exchange, account: account)
        } else if let caldav = provider as? CalDAVProvider {
            return .caldav(provider: caldav, account: account)
        } else if let demo = provider as? DemoCalendarProvider {
            return .demo(provider: demo, account: account)
        }
        return .none
    }
}
