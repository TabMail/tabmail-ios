/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Where a tutorial coach card can appear. Each native screen hosts the cards
/// for its own steps only, so a card never points at a control that is not
/// on screen.
enum TutorialCoachHost: Equatable {
    /// The inbox list, chat collapsed. The open chat covers the card (owner
    /// 2026-10-25): its ringed Send, pill and close button show the way.
    case inbox
    /// A reply to Priya's practice email. `showingSuggestion` is the AI
    /// Suggestion bubble still waiting for Use Suggestion.
    case compose(showingSuggestion: Bool)
    /// The source email of part 3.
    case message
    /// Action Classification, opened by "See rule" on the part 1 result.
    case actionRules
}

/// The text and buttons of one coach card (owner V5 mockup copy). Pure, so
/// the step-to-card mapping is tested without a view.
struct TutorialCoachContent: Equatable {
    enum Action: Equatable {
        case continueToRetag
        case nextLesson
        case seeRule
        case seeTemplate
        case showMoreToAsk
        case showRecap
    }

    struct Button: Equatable {
        let label: String
        let action: Action
        var isPrimary = false
    }

    /// "1 of 3 · Act on email": never "lesson" (owner 2026-10-21).
    var progressLine: String
    var title: String
    var message: String
    /// "You can also ask TabMail to" examples.
    var examples: [String] = []
    var buttons: [Button] = []
    var showsProgress = false

    static let askExamples = [
        "Put an event on your calendar",
        "Invite people to an event",
        "Schedule a meeting when you’re free",
        "Remember your preferences",
    ]

    /// The card `host` shows for `step`, or nil when this host has none.
    /// `isSending`: a send is waiting out its undo window (`PendingSendService`).
    /// `replyEdited`: the practice reply's scripted edit ran.
    static func make(
        step: TutorialCoordinator.Step,
        lesson: TutorialLesson,
        host: TutorialCoachHost,
        flightsAsked: Bool,
        replyEdited: Bool = false,
        isSending: Bool = false
    ) -> TutorialCoachContent? {
        func card(_ title: String, _ message: String, done: Bool = false) -> TutorialCoachContent {
            let line = "\(lesson.rawValue) of \(TutorialLesson.allCases.count) · \(lesson.title)"
            return TutorialCoachContent(progressLine: done ? line + " · done" : line, title: title, message: message)
        }
        // Skip tutorial, always at the top right, is the way to stop (owner 2026-10-25).
        let next = Button(label: "Next", action: .nextLesson, isPrimary: true)

        switch (step, host) {
        // Part 1
        case (.archiveReceipt, .inbox):
            return card("Tap the Archive tag.", "The small colored tag is a button. Try it on the receipt.")
        case (.receiptArchived, .inbox):
            var c = card("One tap. One less email.", "Reply opens a draft. Delete moves a message to Trash.")
            c.buttons = [Button(label: "Next", action: .continueToRetag, isPrimary: true)]
            return c
        case (.retagDailyTech, .inbox):
            return card(
                "Hold to change it.",
                "Rather delete this digest? Press and hold its Archive tag, then choose Tag as Delete. "
                    + "This changes the suggestion. It doesn’t delete the email.")
        case (.actOnEmailDone, .inbox):
            var c = card(
                "Suggestion changed.",
                "The digest stays in your inbox. In your own inbox, TabMail learns a rule from changes like this.",
                done: true)
            c.buttons = [Button(label: "See rule", action: .seeRule), next]
            return c
        case (.actOnEmailDone, .actionRules):
            return card(
                "The rule it learned.",
                "Rules live in Settings → Action Classification. In your own inbox, "
                    + "TabMail adds one like this when you change a suggestion. This one is a sample.",
                done: true)

        // Part 2
        case (.replyToPriya, .inbox) where isSending:
            // The undo-send window: the Sent row appears when it closes.
            var c = card("Sending your practice reply.", "It stays in the demo. Nobody receives an email.")
            c.showsProgress = true
            return c
        case (.replyToPriya, .inbox):
            return card("Tap the green Reply tag.", "Priya’s invitation already has a suggested reply.")
        case (.replyToPriya, .compose(let showingSuggestion)):
            if !showingSuggestion {
                return card("Tap Send.", "Practice only: it goes to the demo Sent folder. Nobody receives an email.")
            }
            return replyEdited
                ? card("TabMail changed it.", "Tap Use Suggestion to put it in your reply.")
                : card("TabMail wrote a reply.", "Say what to change: tap Edit at the top, then Send.")
        case (.makeTemplate, .inbox):
            return card("Sent. Now reuse it.", "Nobody received it. Tap Chat to turn it into a template.")
        case (.reuseReplyDone, .inbox):
            var c = card(
                "Template saved.",
                "In your own inbox, ask TabMail to make a template the same way, "
                    + "and it will be used when you reply to similar emails.",
                done: true)
            c.buttons = [Button(label: "See template", action: .seeTemplate), next]
            return c

        // Part 3
        case (.askFlights, .inbox) where flightsAsked:
            return card("Check the original.", "Open Chat and tap the email reference in the answer.")
        case (.askFlights, .inbox):
            return card("Start with Chat.", "Tap Chat at the bottom of the inbox.")
        case (.askAnythingDone, .message), (.askAnythingDone, .inbox):
            var c = card("There’s your answer.", "You went from a question to the original email.", done: true)
            c.buttons = [Button(label: "Next", action: .showMoreToAsk, isPrimary: true)]
            return c
        case (.moreToAsk, .inbox):
            var c = card("Ask anything.", "Not sure where to start? Tap Chat to ask TabMail what it can do.", done: true)
            c.examples = askExamples
            c.buttons = [Button(label: "Finish", action: .showRecap, isPrimary: true)]
            return c

        default:
            return nil
        }
    }
}
