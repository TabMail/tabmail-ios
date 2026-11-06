/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Whether the chat view, and the AI work only it needs, is on.
///
/// The user switches it in TabMail Settings ("Enable Chat View", on by default). It needs AI:
/// while AI is off (opted out, or no plan) it is off everywhere, nothing requests summaries for
/// whole threads, and the user's choice is kept for when AI comes back.
///
/// Read `isActive` ONCE at the start of an operation and pass the value along; never re-read it
/// mid-operation.
enum ChatViewConfig {
    /// The user's "Enable Chat View" setting. A missing key means on.
    static let enabledKey = "chatViewEnabled"

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
        isActive(enabledByUser: isEnabledByUser, aiOn: isAIOn)
    }

    static func isActive(enabledByUser: Bool, aiOn: Bool) -> Bool {
        enabledByUser && aiOn
    }

    /// The bound on a thread's AI work, one number (owner 2026-11-06): an open chat asks for the
    /// summaries of the emails on screen and this many older than the oldest of them; once a hand
    /// scroll stops, the emails on screen and this many on each side; the background walk takes
    /// each thread's newest this many.
    static let summaryWindow = 10
    /// The emails on screen are asked for once they have stayed the same this long, so the brief
    /// layout jumps while the chat moves to its opening place ask for nothing.
    static let summaryAskSettle: Duration = .milliseconds(300)
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
