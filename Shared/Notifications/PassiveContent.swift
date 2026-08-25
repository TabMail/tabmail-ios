/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UserNotifications

/// Mutates `c` for passive (no-banner, no-sound) delivery.
///
/// Default is pass-through: title/body are left as the push-worker
/// pre-populated them in `aps.alert` (e.g. `"New email - <sender>"` /
/// `<subject>`, `"Reconnecting…"`, the give-up `"Failed to reconnect…"`).
/// Callers supply `overrideTitle` / `overrideBody` only for situation-
/// specific copy — auth failure, reconnect-success acknowledgement.
///
/// `interruptionLevel` and `sound` are always normalised to passive / nil so
/// every code path that takes "we have nothing actionable to surface" produces
/// the same low-key delivery (Notification Center entry, no banner, no sound).
func applyPassiveSettings(
    _ c: UNMutableNotificationContent,
    overrideTitle: String? = nil,
    overrideBody: String? = nil
) {
    if let t = overrideTitle { c.title = t }
    if let b = overrideBody { c.body = b }
    c.interruptionLevel = .passive
    c.sound = nil
}

/// Strip a push the account-incarnation rule refused down to an inert
/// placeholder: passive delivery (via `applyPassiveSettings`), no action
/// buttons, no routing identifiers, no attachments, no badge — plus the marker
/// the main app reads so a tap on the stripped notification is refused too.
///
/// Shared with the main app's admission check rather than hand-rolled at the
/// NSE call site, so "what a refused push looks like" has one definition.
func neutralizeRefusedAccountPush(_ c: UNMutableNotificationContent) {
    applyPassiveSettings(
        c,
        overrideTitle: "TabMail",
        overrideBody: "Open TabMail to view your inbox"
    )
    c.userInfo = [AccountPushIncarnationPolicy.refusedPushMarkerKey: true]
    c.categoryIdentifier = ""
    c.threadIdentifier = ""
    c.targetContentIdentifier = nil
    c.badge = nil
    c.attachments = []
}
