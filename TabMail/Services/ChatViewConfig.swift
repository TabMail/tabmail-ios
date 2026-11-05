/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Whether the chat view, and the AI work only it needs, is on.
///
/// The chat view lands on `main` in several changes, and `main` must stay releasable in between, so
/// release builds keep it off (`isAvailableInBuild`) until the last of them turns it on. Until then
/// it can be turned on from the debug menu for testing. While it is off nothing requests summaries
/// for whole threads (they would spend model calls on a feature nobody sees).
///
/// Once reachable, the user switches it in TabMail Settings ("Enable Chat View", on by default).
/// It needs AI: while AI is off (opted out, or no plan) it is off everywhere, and the user's
/// choice is kept for when AI comes back.
///
/// Read `isActive` ONCE at the start of an operation and pass the value along; never re-read it
/// mid-operation.
enum ChatViewConfig {
    /// The release gate: false until the chat view ships.
    static let isAvailableInBuild = false

    private static let debugOverrideKey = "debug_chat_view_enabled"

    /// The user's "Enable Chat View" setting. A missing key means on.
    static let enabledKey = "chatViewEnabled"

    /// The debug menu's override. Only counts while debug mode is unlocked, like
    /// `BackendConfig.useDevServers`.
    static var debugOverride: Bool {
        get {
            guard UserDefaults.standard.bool(forKey: "debug_mode_unlocked") else { return false }
            return UserDefaults.standard.bool(forKey: debugOverrideKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: debugOverrideKey)
        }
    }

    /// Whether this build offers the chat view at all (and so shows its Settings row).
    static var isReachable: Bool { isAvailableInBuild || debugOverride }

    /// The user's choice, kept while AI is off.
    static var isEnabledByUser: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// AI is on: not opted out, and a plan (or trial) is active.
    static var isAIOn: Bool {
        isAIOn(optedOut: AIService.optOutStore.bool(forKey: AIService.optOutAllAIKey),
               subscribed: AISubscriptionGate.shared.isActive)
    }

    static func isAIOn(optedOut: Bool, subscribed: Bool) -> Bool {
        !optedOut && subscribed
    }

    static var isActive: Bool {
        isActive(reachable: isReachable, enabledByUser: isEnabledByUser, aiOn: isAIOn)
    }

    static func isActive(reachable: Bool, enabledByUser: Bool, aiOn: Bool) -> Bool {
        reachable && enabledByUser && aiOn
    }
}

/// Sizes and timings of the chat screen.
enum ChatViewLayout {
    /// A time stamp goes above a bubble that comes this long after the one before it.
    static let timeStampGap: TimeInterval = 15 * 60
    /// How long an email opened from search or a notification glows (O2).
    static let highlightDuration: Duration = .seconds(1.2)
    static let avatarSize: CGFloat = 28
    static let headerAvatarSize: CGFloat = 32
    /// The header lists this many names, then "+N".
    static let headerNameCount = 2
    static let bubbleCornerRadius: CGFloat = 18
    static let bubbleMaxWidthFraction: CGFloat = 0.78
    static let bubbleSpacing: CGFloat = 6
    /// Room under the last bubble so it sits above the pill, never under it (N2.10).
    static let pillClearance: CGFloat = 104
    /// The jump-to-bottom button shows once the bottom is this far below the screen.
    static let jumpButtonThreshold: CGFloat = 240
    static let jumpButtonSize: CGFloat = 40
}
