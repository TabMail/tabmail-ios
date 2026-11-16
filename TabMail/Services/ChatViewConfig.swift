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
    /// summaries of its newest this many emails, and the background walk takes each thread's newest
    /// this many. An older email asks for its own when it comes on screen (owner 2026-11-09).
    static let summaryWindow = 10
}

/// Sizes and timings of the chat screen.
enum ChatViewLayout {
    /// A time stamp goes above a bubble that comes this long after the one before it.
    static let timeStampGap: TimeInterval = 15 * 60
    /// How long an email opened from search or a notification glows.
    static let highlightDuration: Duration = .seconds(1.2)
    static let avatarSize: CGFloat = 28
    static let headerAvatarSize: CGFloat = 32
    /// The header lists this many names, then "+N".
    static let headerNameCount = 2
    /// A bubble shows this many attachment chips, then one "+N" chip for the rest.
    static let attachmentChipCount = 2
    /// A row counts as shown once this share of it is visible (`ChatRowVisibility`)...
    static let shownShareOfRow: CGFloat = 0.5
    /// ...or once it fills this share of the chat's visible height, so a row taller than the screen
    /// counts too.
    static let shownShareOfViewport: CGFloat = 0.5
    static let bubbleCornerRadius: CGFloat = 18
    static let bubbleMaxWidthFraction: CGFloat = 0.78
    static let bubbleSpacing: CGFloat = 6
    /// The one-line pill's height, used until the pill is measured: the thread keeps the measured
    /// collapsed height under its last bubble, so it sits above the pill, never under it.
    static let pillStartHeight: CGFloat = 98
    /// Room between the last bubble and the pill's top, beyond the bubble spacing.
    static let pillGap: CGFloat = 6
    /// The jump-to-bottom button shows once the bottom is this far below the screen.
    static let jumpButtonThreshold: CGFloat = 240
    static let jumpButtonSize: CGFloat = 40
    /// The reply field's words pulse to this opacity while TabMail writes, as compose does.
    static let fieldPulseOpacity: Double = 0.35
    static let fieldPulseDuration: Double = 0.8
    /// Chat and bubble swipes: each revealed button's width and its round button.
    static let swipeButtonWidth: CGFloat = 76
    static let swipeCircleSize: CGFloat = 44
    /// A swipe past this share of the width runs the edge button (a full swipe archives).
    static let swipeFullFraction: CGFloat = 0.6
    /// A let-go faster than this (points a second) opens or closes the swipe whatever its distance.
    static let swipeFlickVelocity: CGFloat = 600
    /// How long a let-go swipe keeps holding data that lands (`ChatSwipeHold`): the swipe's spring
    /// (`swipeSpringResponse`) settling, then the interaction freeze's 200ms cooldown.
    static let swipeSettleHold: Duration = .milliseconds(550)
    /// The response of the spring a let-go swipe settles with, in seconds.
    static let swipeSpringResponse: Double = 0.35
}
