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

    /// The bound on a thread's AI work, one number: an open chat asks for the
    /// summaries of its newest this many emails, and the background walk takes each thread's newest
    /// this many. An older email asks for its own when it comes on screen.
    static let summaryWindow = 10

    /// The reply field's VoiceOver action that opens the TabMail chat panel, the drag up's
    /// equivalent (`showChatAction`).
    static let showChatActionName = "Show TabMail chat"
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
    /// The bottom bar's height until the reply field is measured: the bar is a slot of the
    /// collapsed field's measured height, and its inset keeps the last bubble above the field.
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
    /// The interaction freeze's cooldown after an animation has settled (user-interaction-freeze
    /// rule): the part of `swipeSettleHold` past the swipe's spring.
    static var freezeCooldown: Duration { swipeSettleHold - .seconds(swipeSpringResponse) }
    /// The back swipe's zone at the screen's left edge, in points: with nothing open, a rightward
    /// drag that starts here goes back rather than opening a bubble's actions.
    static let backSwipeEdgeWidth: CGFloat = 24
    /// The AI Suggestion's dashed outline: its line width and its dash and gap lengths.
    static let suggestionStrokeWidth: CGFloat = 1.5
    static let suggestionDash: [CGFloat] = [6, 4]

    // Every open field bar's row (`ChatFieldBarRow`): the chat's reply field, the opened pill's
    // input bar (inbox, edit mode over a draft, the per-message pill) and the tutorial's copy.
    // Measured from the visible glyphs. The collapsed Chat pill keeps its own size.
    /// The field's edge to the mic glyph.
    static let fieldMicInset: CGFloat = 12
    /// The mic glyph's width at the body size.
    static let fieldMicGlyphWidth: CGFloat = 13
    /// The mic's tap width; it may reach past the field's edge into the side margin.
    static let fieldMicTapWidth: CGFloat = 38
    /// Between a button's glyph and the text.
    static let fieldTextGap: CGFloat = 10
    /// The Send circle's diameter, and its distance from the field's edge.
    static let fieldSendSize: CGFloat = 28
    static let fieldSendInset: CGFloat = 6
    /// Every field button's tap height and the Send button's tap width.
    static let fieldTapSize: CGFloat = 44
    /// Above and below the text.
    static let fieldVerticalPadding: CGFloat = 10
    /// One line of body text at the default size: the buttons sit centred on the last line.
    static let fieldLineHeight: CGFloat = 22
    /// The collapsed reply field's corner: a capsule at one line (42 / 2), then fixed as it grows.
    static let fieldCornerRadius: CGFloat = 21
    /// Dragging the reply field up (`ChatFieldDrag`): the movement before it counts as a drag,
    /// how far the field may swell under the finger, and the swell (or a flick's predicted
    /// swell) that opens the panel on let-go.
    static let fieldDragMinimumDistance: CGFloat = 10
    static let fieldDragMaxSwell: CGFloat = 220
    static let fieldDragOpenDistance: CGFloat = 60
    /// The pill's spring (the panel opening and closing, the field's swell springing back): its
    /// response in seconds and its damping ratio. A drag's settle lasts this spring's own settling
    /// duration (`ChatThreadView.fieldDragSettle`).
    static let pillSpringResponse: Double = 0.45
    static let pillSpringDamping: Double = 0.82
    /// A new email's arrival in the open chat (`ChatArrival`): it rises from behind the field over
    /// this long; under Reduce Motion the space opens at once and it fades in over the second.
    static let arrivalRiseDuration: Double = 0.42
    static let arrivalFadeDuration: Double = 0.2
}

/// The AI Suggestion in the chat: the ghost of the user's next message, and the field's hint.
enum ChatSuggestionConfig {
    /// The ghost's name, the one compose's suggestion box uses.
    static let label = "AI Suggestion"
    /// The line under the ghost.
    static let statusLine = "\(label) · Tap to use"
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
