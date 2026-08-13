/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation
import Synchronization

/// Gates all debug features behind a hidden activation.
/// Tap the version label in TabMail Settings 10 times to unlock.
/// Once unlocked, persists until explicitly locked again.
/// Only allowed user IDs can unlock debug mode.
@MainActor @Observable
final class DebugModeManager {
    static let shared = DebugModeManager()

    private static let unlockedKey = "debug_mode_unlocked"
    private static let requiredTaps = 10

    /// Email domains allowed to unlock debug mode.
    /// Only accounts with these domains can activate debug features + debug logging.
    nonisolated private static let allowedEmailDomain = "tabmail.ai"

    /// Individual emails outside `allowedEmailDomain` allowed to unlock debug
    /// mode (e.g. external team members on personal Gmail used for video
    /// demos). Keep short — every entry bypasses the domain check.
    nonisolated private static let allowedEmails: Set<String> = [
        "tabmail.ai@gmail.com",
    ]

    nonisolated private static func isEmailAllowed(_ email: String) -> Bool {
        if email.hasSuffix("@\(allowedEmailDomain)") { return true }
        return allowedEmails.contains(email.lowercased())
    }

    /// Whether debug features are visible and usable.
    var isUnlocked: Bool {
        didSet {
            UserDefaults.standard.set(isUnlocked, forKey: Self.unlockedKey)
            if !isUnlocked {
                // Reset dev servers to production when locking debug mode
                BackendConfig.useDevServers = false
            }
            // Push the NSE file-log gate immediately — don't wait for the next
            // `mirrorAllState()` pass (app launch) to reflect a mid-session
            // toggle. `isLoggingEnabled()` re-derives from the fresh UserDefaults
            // write above, so this reflects the new state, not the old one.
            NSEDataBridge.mirrorDebugLogging()
        }
    }

    /// Tracks consecutive taps on the version label.
    private(set) var tapCount = 0

    /// Remaining taps to show as feedback (nil = no feedback shown).
    var remainingTaps: Int? {
        let remaining = Self.requiredTaps - tapCount
        // Show feedback after 3 taps and before unlock
        if tapCount >= 3 && remaining > 0 {
            return remaining
        }
        return nil
    }

    private init() {
        self.isUnlocked = UserDefaults.standard.bool(forKey: Self.unlockedKey)
    }

    /// Override for tests — bypasses the user ID check when true.
    #if DEBUG
    var allowAllUsersForTesting = false
    #endif

    /// Whether the current logged-in user is allowed to use debug features.
    /// Checks the session email against the allowed domain.
    var isAllowedUser: Bool {
        #if DEBUG
        if allowAllUsersForTesting { return true }
        #endif
        guard let session = TabMailAuthService.getSession() else { return false }
        return Self.isEmailAllowed(session.userEmail)
    }

    /// Memoized result of the keychain-derived half of `isLoggingEnabled()`
    /// (session load + decode + domain check). `nil` = not yet computed.
    ///
    /// The session identity only changes on login/logout, so this is computed
    /// once and reused. Without it, every gated log call did a synchronous
    /// Keychain XPC (`SecItemCopyMatching` → `securityd`). Hit from the
    /// 100 ms main-thread `MainActorStallDetector` timer and once per backfilled
    /// body, that blocking call wedged the main thread while backfill held SQLite
    /// write locks during app suspension → `0xdead10cc` kill (TestFlight
    /// 1.6.16/324, debug-unlocked accounts only). Invalidated via
    /// `invalidateLoggingCache()` from the auth session save/clear sites.
    nonisolated private static let loggingAllowedCache = Mutex<Bool?>(nil)

    /// Whether debug logging should be active (unlocked AND allowed user).
    /// Called from BackgroundSyncLogger to gate file I/O in production.
    /// Static nonisolated so it can be called from any thread without MainActor hop.
    /// Reads UserDefaults (thread-safe) + a cached Keychain-derived flag, so the
    /// per-log-call hot path never blocks on a synchronous Keychain XPC.
    static nonisolated func isLoggingEnabled() -> Bool {
        let unlocked = UserDefaults.standard.bool(forKey: "debug_mode_unlocked")
        guard unlocked else { return false }
        return loggingAllowedCache.withLock { cache in
            if let cached = cache { return cached }
            // Read session directly from Keychain (thread-safe) to avoid MainActor
            // hop. Cached because SecItemCopyMatching is a synchronous XPC to
            // securityd — far too costly to run on every log call.
            let allowed: Bool
            if let data = KeychainHelper.load(key: "tabmail_session"),
               let session = try? JSONDecoder().decode(TabMailSession.self, from: data) {
                allowed = isEmailAllowed(session.userEmail)
            } else {
                allowed = false
            }
            cache = allowed
            return allowed
        }
    }

    /// Invalidate the `isLoggingEnabled()` cache. MUST be called whenever the
    /// stored session changes (login / logout) so the debug-logging gate
    /// re-evaluates against the new identity. Cheap and thread-safe.
    static nonisolated func invalidateLoggingCache() {
        loggingAllowedCache.withLock { $0 = nil }
    }

    /// Neutralises line terminators — and every other control character — in a
    /// value that is about to be interpolated into a diagnostic log line.
    ///
    /// `print` is a LINE-oriented sink: one call becomes one line in the device
    /// log. So a sender-authored value carrying a raw CR/LF does not corrupt one
    /// line, it FORGES a second, entirely plausible one. A MIME `filename` of
    /// `"invoice.pdf\n[Attachment] QuickLook presenting payroll.pdf from …"` reads
    /// back as two ordinary diagnostics, and the reader has no way to tell which
    /// of them the app actually emitted. Attachment filenames, `Content-Type`
    /// parameters and error descriptions carrying a server-supplied path are all
    /// sender-authored, and all of them reach `print` interpolations.
    ///
    /// Escaped rather than stripped, so the line still shows what the sender
    /// actually sent. The escaped set is the C0 range, `DEL` + the C1 range, and
    /// U+2028/U+2029 — deliberately the same class `imageLoadDiagnosticJS`'s
    /// `sanitize` closes, which this `print` channel is NOT covered by.
    /// U+0085 (NEL) needs no separate case: it is inside the C1 range.
    ///
    /// ⚠️ **This sentence said `sanitize` closes that class "on the webview's
    /// `postMessage` channel" until 2026-08-12. It does not, and the overclaim
    /// mattered in the direction that made the webview look protected.**
    /// `sanitize` runs inside `imageLoadDiagnosticJS`'s own `log()` wrapper, one
    /// line before that wrapper posts to `consoleLog`. It sanitises the values
    /// OUR script interpolates. It cannot sanitise the channel — and the reason it
    /// could be bypassed has since been closed twice, by configuration rather than
    /// by this helper. It read, correctly when written: *"every `WKUserScript` in
    /// `AutoSizingHTMLView.makeUIView` is installed with no content world, so
    /// sender script shares our `window` and can call
    /// `window.webkit.messageHandlers.consoleLog.postMessage(…)` directly with
    /// embedded newlines, bypassing `log()` entirely."* Both halves of that are now
    /// false: P1b set `allowsContentJavaScript = false` (ADR-IOS-076 decision 1) so
    /// no sender script runs, and P3 registered every bridge channel in
    /// `RenderContentWorld.isolated` so the page world has no `messageHandlers`
    /// object at all. Either alone would close it; both are single settings, and
    /// four P1b settings in that file were reversed by owner directive within a day
    /// of shipping, which is why neither is treated as permanent. Out of scope for
    /// this helper regardless — it owns only the Swift-side `print` interpolations.
    ///
    /// ⚠️ This is NOT a reversible encoding and NOT injective. A backslash in the
    /// input is passed through unchanged, so a sender who writes the six literal
    /// characters backslash-u-0-0-0-a renders identically to one who writes a real
    /// newline. That ambiguity is deliberate — it is exactly what the JS choke point does,
    /// and matching it keeps one rule rather than two — and it is not the property
    /// being bought here. The invariant is that no sender-controlled value can
    /// introduce a LINE BREAK into a diagnostic line, which an ambiguous but
    /// break-free rendering satisfies. A future consumer that PARSES these lines
    /// rather than reading them needs a real encoding; this is not one.
    ///
    /// Pinned by `DiagnosticLogLineForgeryTests`.
    static nonisolated func escapedForLogLine(_ value: String) -> String {
        var escaped = String()
        escaped.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if code < 0x20 || (code >= 0x7F && code <= 0x9F) || code == 0x2028 || code == 0x2029 {
                escaped += String(format: "\\u%04x", code)
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// Call on each version label tap. Returns true when debug mode is freshly unlocked.
    @discardableResult
    func registerTap() -> Bool {
        guard isAllowedUser else {
            tapCount = 0
            return false
        }
        tapCount += 1
        if tapCount >= Self.requiredTaps && !isUnlocked {
            isUnlocked = true
            tapCount = 0
            return true
        }
        return false
    }

    /// Resets the tap counter (e.g. when navigating away).
    func resetTapCount() {
        tapCount = 0
    }
}
