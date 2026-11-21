/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Whether the chat view, and the AI work only it needs, is on.
///
/// The user switches it in TabMail Settings ("Enable Chat View", on by default). It needs AI:
/// while AI is off (the AI choice not made yet, opted out, or no plan) it is off everywhere,
/// nothing requests summaries for whole threads, and the user's choice is kept for when AI comes
/// back.
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

    /// AI is on: the device's AI setting is on (`AIService.isAIOff`: the AI choice made, not opted
    /// out), and a plan (or trial) is active.
    static var isAIOn: Bool {
        isAIOn(aiOff: AIService.isAIOff, subscribed: AISubscriptionGate.shared.isActive)
    }

    static func isAIOn(aiOff: Bool, subscribed: Bool) -> Bool {
        !aiOff && subscribed
    }

    static var isActive: Bool {
        isActive(enabledByUser: isEnabledByUser, aiOn: isAIOn)
    }

    static func isActive(enabledByUser: Bool, aiOn: Bool) -> Bool {
        enabledByUser && aiOn
    }

    /// The bound on a thread's AI work, one number: an open chat asks for the
    /// summaries of its newest this many emails, and the background walk takes each thread's newest
    /// this many. An older email asks for its own when it comes on screen.
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
    /// The reply field's bottom edge sits this far above the bottom safe-area line, collapsed or
    /// opened: the safe area already clears the home indicator, so nothing else is added.
    static let fieldBottomGap: CGFloat = 8
    /// The reply field's distance from each side of the screen, as in Messages.
    static let fieldSideInset: CGFloat = 16
    /// Room between the header's names and the subject line under the navigation bar.
    static let subjectLineSpacing: CGFloat = 2
    /// Room under the subject line, inside the header's bar, so its letters clear the bar's edge.
    static let subjectLineBottomGap: CGFloat = 6
    /// The AI summaries glyph at the subject line's trailing edge, before Dynamic Type scales it.
    static let aiNoticeGlyphSize: CGFloat = 13
    /// Its tap target, full size whatever the glyph's size (Apple's 44-point minimum).
    static let aiNoticeTapTarget: CGFloat = 44
    /// The popover's width and the room between its title, note and report button.
    static let aiNoticeWidth: CGFloat = 300
    static let aiNoticeSpacing: CGFloat = 10
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
    /// The back swipe's zone at the screen's left edge, in points: with nothing open, a rightward
    /// drag that starts here goes back rather than opening a bubble's actions.
    static let backSwipeEdgeWidth: CGFloat = 24
    /// The AI Suggestion's dashed outline: its line width and its dash and gap lengths.
    static let suggestionStrokeWidth: CGFloat = 1.5
    static let suggestionDash: [CGFloat] = [6, 4]
}

/// The AI Suggestion in the chat: the ghost of the user's next message, and the field's hint.
enum ChatSuggestionConfig {
    /// The ghost's name, the one compose's suggestion box uses.
    static let label = "AI Suggestion"
    /// The line under the ghost.
    static let statusLine = "\(label) · Tap to use"
    /// What a reply request typed or said in the field does while the AI Suggestion shows: it is
    /// a compose edit of the suggestion (`EmailReplyTool`), and then either the ghost shows the
    /// edit in place (true; a tap on it opens the compose card) or the compose card opens with
    /// the edited email (false). The one place this choice is made.
    static let fieldEditRewritesInPlace = true
    /// The line under the working bubble while the suggestion is written.
    static let writingLine = "\(label) · Writing"
    /// The working bubble growing into the ghost, the re-pin scroll in the same transaction.
    static let fillDuration: Double = 0.3
    /// Under Reduce Motion the ghost fades in over this as it replaces the working bubble, the only
    /// motion of the fill (the row's height changes at once). No other insertion fades.
    static let ghostFadeDuration: Double = 0.2
    /// The working bubble's dots: each pulses between this opacity and full over the period, the
    /// next one this much later.
    static let dotDimOpacity: Double = 0.3
    static let dotPulsePeriod: Double = 1.2
    static let dotStagger: Double = 0.2
    static let dotSize: CGFloat = 6
    static let dotSpacing: CGFloat = 4
    /// The dots' frame cap, as the app's other AI indicators (`aiWorkingShimmer`).
    static let dotFrameInterval: Double = 1.0 / 30
    /// Changes a reply can ask for, shown one at a time as the field's "e.g." line, picked again
    /// each time a chat opens. Content changes only: the text version is already short, so no
    /// style tweaks ("make it shorter").
    static let replyExamples = [
        "politely decline",
        "say I'm happy to",
        "say yes and suggest Tuesday",
        "ask them to resend the file",
        "thank them and say I'll reply by Friday",
        "say I'm out until Monday",
        "ask for one more week",
        "say I'll call them tomorrow",
        "agree and ask what is next",
        "ask who else should join",
    ]

    /// One example from `examples`, at random; nil for an empty set.
    static func randomExample(from examples: [String] = replyExamples) -> String? {
        examples.randomElement()
    }

    /// The field's second line for `example`.
    static func exampleLine(_ example: String) -> String { "e.g. \(example)" }
}
