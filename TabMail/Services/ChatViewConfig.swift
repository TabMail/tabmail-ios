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

    /// A new email's "Add recipient" sheet lists at most this many recent people
    /// (`ChatRecentPeople`), found in the newest `recentPeopleScanCount` emails of the Sent folders.
    static let recentPeopleCount = 8
    static let recentPeopleScanCount = 100

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
    /// A new email's empty avatar: its person glyph's size, as a share of the avatar's.
    static let emptyAvatarGlyphScale: CGFloat = 0.45
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
    /// Room between the subject and each label chip after it on the subject line.
    static let subjectLabelGap: CGFloat = 4
    /// The AI summaries glyph at the subject line's trailing edge, before Dynamic Type scales it.
    static let aiNoticeGlyphSize: CGFloat = 14
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
    /// Between a button's glyph and the text.
    static let fieldTextGap: CGFloat = 10
    /// The Send circle's diameter, and its distance from the field's edge.
    static let fieldSendSize: CGFloat = 28
    static let fieldSendInset: CGFloat = 6
    /// The mic circle (`ChatMicCircle`) mirrors Send: the same diameter and the same distance from
    /// the field's other edge. Its tap area is Send's too (`fieldTapSize` square).
    static let fieldMicSize: CGFloat = fieldSendSize
    static let fieldMicInset: CGFloat = fieldSendInset
    /// The point sizes of the mic glyph and the listening stop square inside the mic circle, and
    /// the transcribing spinner's diameter there. Fixed, as Send's circle is, so they always fit it.
    static let fieldMicGlyphPointSize: CGFloat = 15
    static let fieldMicStopPointSize: CGFloat = 11
    static let fieldMicSpinnerSize: CGFloat = 18
    /// Every field button's tap height and the Send button's tap width.
    static let fieldTapSize: CGFloat = 44
    /// Above and below the text.
    static let fieldVerticalPadding: CGFloat = 10
    /// One line of body text at the default size: the buttons sit centred on the last line.
    static let fieldLineHeight: CGFloat = 22
    /// The collapsed reply field's corner: a capsule at one line (42 / 2), then fixed as it grows.
    static let fieldCornerRadius: CGFloat = 21
    /// The field's paperclip, at the text's end on Send's row: its glyph's width at the body size,
    /// and its tap width.
    static let fieldPaperclipGlyphWidth: CGFloat = 13
    static let fieldPaperclipTapWidth: CGFloat = 38
    /// The paperclip while the agent works on a Send from the field: it stays in its place, dimmed
    /// to this opacity and not tappable.
    static let fieldPaperclipDimmedOpacity: Double = 0.35
    /// The paperclip's pop-up (`ChatAttachChoices`): its width and each row's side padding.
    static let attachChoicesWidth: CGFloat = 200
    static let attachChoicePadding: CGFloat = 16
    /// A new email's attachments waiting above the field: a photo's thumbnail side, a file chip's
    /// height and widest name, their corner, the room between them, and the remove button's size.
    static let trayThumbnailSize: CGFloat = 56
    static let trayChipHeight: CGFloat = 40
    static let trayChipMaxWidth: CGFloat = 180
    static let trayCornerRadius: CGFloat = 10
    static let traySpacing: CGFloat = 8
    static let trayRemoveSize: CGFloat = 20
    /// How far the remove button stands out past an item's top trailing corner, and its backdrop.
    static let trayRemoveOffset: CGFloat = 6
    static let trayRemoveBackdropOpacity: Double = 0.6
    /// A file chip's icon to its name.
    static let trayChipIconGap: CGFloat = 6
    /// Dragging the reply field up (`ChatFieldDrag`): how far the field may swell under the
    /// finger, and the swell (or a flick's predicted swell) that opens the panel on let-go. The
    /// movement before it counts as a drag is UIKit's own pan's (`ChatFieldPan`).
    static let fieldDragMaxSwell: CGFloat = 220
    static let fieldDragOpenDistance: CGFloat = 60
    /// How far a flick's let-go speed carries the drag when predicting where it would rest
    /// (`ChatFieldDrag.predictedEnd`), in seconds of travel at that speed: SwiftUI's own
    /// projection (`DragGesture.Value.predictedEndTranslation`, a quarter second; its `velocity` is
    /// four times the predicted end minus the travel), which the drag used before it became a
    /// UIKit pan. The parity this gives is for equivalent samples: a let-go with the same travel and
    /// velocity SwiftUI's drag reported, on a drag that passes the pan's begin rule
    /// (`ChatFieldDrag.begins`), opens the panel exactly when it did. It is not a promise that every
    /// physical flick does, since UIKit's pan and SwiftUI's drag measure a finger in their own ways.
    static let fieldFlickCarry: CGFloat = 0.25
    /// How long the finger may hold still before it lifts and still flick (`ChatFieldDrag.letGo`),
    /// in seconds: UIKit's pan keeps the speed of the finger's last move at its let-go, so a drag
    /// held still this long lets go at rest. Six frames at 60 Hz; a flick lifts within a frame or
    /// two of its last move.
    static let fieldFlickRest: TimeInterval = 0.1
    /// How close to its end the focused field's overflowing text counts as at its end, where the
    /// rest of a drag becomes the field's (`ChatFieldPan.Coordinator.isAtEnd`), in points: the
    /// end is computed from the text's sizes while UIKit stops its scroll on its own value, so a
    /// text held at its end read a hair short of it (UI run 2026-11-22: `over=-0.0`, under 0.05)
    /// and the field never got its share. Well under a pixel at any scale.
    static let fieldTextEndTolerance: CGFloat = 0.1
    /// How far the finger may come back down from its highest point after the text handed the
    /// drag on and still be going up (`ChatFieldPan.Coordinator.fingerCameBack`), in points: a
    /// move down this small takes back at most a point of text (one pixel at 1x, two at 2x,
    /// three at 3x), so the field keeping its share then shows next to nothing. Past it the
    /// finger has taken the drag back, and a text read short of its end then ends the hand-off.
    static let fieldTextReversalSlack: CGFloat = 1
    /// How far the collapsed field's measured height must move to be a new height
    /// (`ChatThreadView.pillHeightMoved`), in points: a drag's swell is added inside the field's
    /// glass and taken back out around it, which floating point does not always cancel exactly
    /// (UI run 2026-11-22: 158.287109375 read as 158.28710937500003 under a 125 pt swell). Well
    /// under a pixel at any scale.
    static let fieldHeightTolerance: CGFloat = 0.1
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
    /// A ghost held while its card was up turning into the sent reply's bubble once the card has
    /// closed (`ChatHeldGhost`): its spring. Under Reduce Motion the bubble replaces it at once.
    static let sentMorphResponse: Double = 0.45
    static let sentMorphDamping: Double = 0.85
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

    /// What a new email's field can ask for (`ChatNewEmailField`), shown the same way: a new email
    /// has nothing to reply to, so each is an email to write.
    static let newEmailExamples = [
        "ask for the Q2 numbers",
        "invite them to lunch on Friday",
        "thank them for yesterday's meeting",
        "ask when they are free next week",
        "send them the slides from today",
        "ask how the launch went",
        "remind them about Thursday's review",
        "introduce yourself and ask for a call",
    ]

    /// One example from `examples`, at random; nil for an empty set.
    static func randomExample(from examples: [String] = replyExamples) -> String? {
        examples.randomElement()
    }

    /// The field's second line for `example`.
    static func exampleLine(_ example: String) -> String { "e.g. \(example)" }
}
