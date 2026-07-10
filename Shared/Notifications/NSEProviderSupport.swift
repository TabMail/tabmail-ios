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

    /// Pure wall-clock budget for a single NSE LLM call, given how much of the
    /// run has already elapsed against the graceful-exit watchdog.
    ///
    /// Production evidence (field nse.log, 2026-07-09): `URLRequest.timeoutInterval`
    /// is an IDLE timer that resets on every received byte. Since `/completions/chat`
    /// streams SSE frames, a trickling response can hold the "12s" summary call open
    /// indefinitely — one observed run measured 26.4s, with the 27s watchdog firing
    /// 9ms before the summary finished. Budgeting each call from the REMAINING run
    /// time (instead of always handing it the full nominal timeout) makes the
    /// watchdog a true backstop: a healthy-but-slow run gives up on its own, with
    /// `finishMargin` seconds left over for step 7/8 to persist + build.
    ///
    /// - Parameters:
    ///   - nominal: The call's normal timeout (e.g. `NSEConfig.summaryTimeoutSeconds`).
    ///   - elapsed: Wall-clock seconds since the run started (`now - runStart`).
    ///   - watchdog: `NSEConfig.watchdogSeconds` — the run's hard deadline.
    ///   - finishMargin: Seconds to reserve after the call for persist/build work.
    ///   - minCall: Below this many seconds of budget, don't bother starting the call.
    /// - Returns: The capped timeout to use, or `nil` if there isn't enough time
    ///   left to justify starting the call at all.
    public static func llmCallBudget(
        nominal: TimeInterval,
        elapsed: TimeInterval,
        watchdog: TimeInterval,
        finishMargin: TimeInterval,
        minCall: TimeInterval
    ) -> TimeInterval? {
        let budget = min(nominal, watchdog - elapsed - finishMargin)
        guard budget >= minCall else { return nil }
        return budget
    }

    /// Pure formatter for one persistent-nse.log line — extracted from
    /// `NSELog.appendTimed` (NSE-target-only, unreachable from TabMailTests)
    /// so the line format is pinned by unit tests. Exactly two shapes,
    /// byte-identical to what `appendTimed` historically emitted:
    ///   `[<timestamp>] [+<total>ms Δ<delta>ms] <message>`             (runTag nil)
    ///   `[<timestamp>] [+<total>ms Δ<delta>ms] [run:<tag>] <message>` (tagged)
    /// The `[run:<tag>]` segment attributes a line to its push when iOS runs
    /// several NotificationService instances concurrently in one reused NSE
    /// process. `timestamp` is opaque passthrough (caller formats ISO8601ms).
    ///
    /// The MESSAGE field is capped at `NSELogStore.lineMaxChars` (see its doc:
    /// one unbounded interpolated field must not blow the log-file byte cap —
    /// the once-per-process trim cannot bound an individual write). The cap
    /// lives HERE, not in `NSELog.appendTimed`, so it is covered by the
    /// format-pin tests (NSELog is NSE-target-only, unreachable from
    /// TabMailTests). Display/diagnostic truncation only — the full value
    /// still exists wherever it is actually stored.
    public static func logLine(
        timestamp: String,
        totalMs: Int,
        deltaMs: Int,
        runTag: String?,
        message: String
    ) -> String {
        let cappedMessage = String(message.prefix(NSELogStore.lineMaxChars))
        let tag = runTag.map { " [run:\($0)]" } ?? ""
        return "[\(timestamp)] [+\(totalMs)ms Δ\(deltaMs)ms]\(tag) \(cappedMessage)"
    }
}
