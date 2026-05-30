/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Per-account "last proof of push pipeline health" timestamps, persisted in
/// the shared App Group UserDefaults so both the main app and the NSE
/// read/write the same source.
///
/// Stamped by two proof sources:
/// 1. **Strong** — receipt of a non-error push (`imap_new_mail`/`gmail`/
///    `outlook`/`task_alarm`) at NSE `didReceive` and the main-app silent-
///    push handler. Proves the IMAP/Gmail → push-worker → APNs → iOS
///    pipeline works end-to-end for this account.
/// 2. **Weaker** — successful NSE silent re-subscribe (`/subscribe-imap`
///    returned 2xx) inside the `imap_reconnect` recovery path. Proves
///    push-worker accepted the enrollment but does NOT guarantee the IDLE
///    socket stays up; the push-worker's retry ladder fires another
///    `imap_reconnect` if the socket drops again.
///
/// Used by `NotificationCleanupService` to decide whether an `imap_reconnect`
/// warning notification has been superseded (i.e. push is proven restored
/// for that account, safe to sweep the warning).
///
/// Suite name `"group.ai.tabmail"` matches `SharedNSEData.appGroupIdentifier`
/// (NSE target) and the existing call sites in `AIService` and
/// `UnreadCountManager`. Hardcoded here to avoid forcing `SharedNSEData` into
/// the main-app target.
enum PushHealthStore {
    private static let suiteName = "group.ai.tabmail"
    private static let storeKey = "tabmail.notif.lastNonReconnectPushAt"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func recordPush(accountEmail: String, at date: Date = Date()) {
        guard !accountEmail.isEmpty else { return }
        var map = load()
        map[accountEmail] = date.timeIntervalSince1970
        defaults.set(map, forKey: storeKey)
    }

    static func lastNonReconnectPushAt(accountEmail: String) -> Date? {
        guard let ts = load()[accountEmail] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    static func snapshotAll() -> [String: Date] {
        load().mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func load() -> [String: TimeInterval] {
        defaults.dictionary(forKey: storeKey) as? [String: TimeInterval] ?? [:]
    }
}
