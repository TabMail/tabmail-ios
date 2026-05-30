/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Per-provider NSE (Notification Service Extension) readiness flag.
///
/// The NSE push toggle (`PushConfig.pushNotificationsEnabledKey`) is a single
/// global boolean on the device — flipping it ON registers **every** account
/// with `/register-device-nse`, which asks the push worker to send visible
/// (mutable-content) pushes for all of them. If the NSE code can't handle a
/// provider (Outlook + IMAP today), the visible push arrives and falls through
/// to `deliverPassive("Inbox updated")` — strictly worse UX than the silent-
/// push path.
///
/// This registry is the single source of truth for "which providers does the
/// NSE actually handle end-to-end". The client sends only these provider
/// names in the `/register-device-nse` `nseProviders` field; the push worker
/// filters its visible-push dispatch accordingly (visible push only if the
/// incoming event's provider is in that device's `nseProviders` list, else
/// silent push to keep the legacy flow working).
///
/// When Outlook NSE ships, flip `.outlook` to `true` here + add a
/// test. When IMAP NSE ships, same for `.imap`.
public enum NSEProviderSupport {

    /// The provider string used on the wire (matches push payload `provider:`
    /// field and `/register-device-nse` body entries).
    public static let gmail  = "gmail"
    public static let outlook = "outlook"
    public static let imap   = "imap"

    /// Set of provider identifiers the NSE can fully process end-to-end —
    /// history/delta fetch, message fetch, body render, AI summary + action,
    /// staging-DB persist, notification delivery.
    ///
    /// Sources of truth for each entry:
    ///   gmail  → `GmailNSEClient` + `NSEAuthSource.refreshGoogle`
    ///            (implemented, verified in Gmail NSE round-3 verification).
    ///   outlook → `OutlookNSEClient` + `NSEAuthSource.refreshMicrosoft`
    ///            (shipped; worker classifier wired up server-side).
    ///   imap   → NEEDS `IMAPNSEClient` + `Shared/API/IMAPCommands.swift`
    ///            impl + DO IDLE proxy server (not yet built).
    public static let readyProviders: Set<String> = [
        gmail,
        outlook,
        imap,
    ]

    public static func isReady(_ provider: String) -> Bool {
        readyProviders.contains(provider)
    }

    /// Filter an account-provider list down to the NSE-ready subset, preserving
    /// original order. Used at `/register-device-nse` registration time to
    /// declare which subset of the user's accounts the worker should send
    /// visible push for. Other accounts' pushes arrive silently via the legacy
    /// path and are handled by the main-app silent-push handler.
    public static func filterReady(_ providers: [String]) -> [String] {
        providers.filter { isReady($0) }
    }
}
