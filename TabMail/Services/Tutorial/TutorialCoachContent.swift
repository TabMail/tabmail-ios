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
    /// A chat in the chat view: Priya's in part 2, Jordan's in part 3.
    case chat
    /// The TabMail panel opened from Priya's chat (part 2): its card sits at the panel's top,
    /// under the email card, since the open panel covers the chat's own card.
    case chatPanel
    /// Action Classification, opened by "See rule" on the part 1 result.
    case actionRules
    /// The Chat View switch, the chat view's last step.
    case chatViewSwitch
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
        case finishChatViewSwitch
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
    /// `sendAsIsTapped`: after the edit, the practice Send that sends nothing was tapped.
    /// `templateAsked`: part 2's template request was sent from the panel.
    static func make(
        step: TutorialCoordinator.Step,
        lesson: TutorialLesson,
        host: TutorialCoachHost,
        flightsAsked: Bool,
        replyEdited: Bool = false,
        sendAsIsTapped: Bool = false,
        isSending: Bool = false,
        templateAsked: Bool = false
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

        // Part 2, in Priya's chat.
        case (.replyToPriya, .chat) where isSending, (.replyToPriya, .inbox) where isSending:
            // The undo-send window: the Sent row appears when it closes.
            var c = card("Sending your practice reply.", "It stays in the demo. Nobody receives an email.")
            c.showsProgress = true
            return c
        case (.replyToPriya, .inbox):
            return card("Open Priya’s email.", "It opens as a chat with everyone on the thread.")
        case (.replyToPriya, .chat):
            return card(
                "Your reply is ready.",
                "Each email reads like a message, and TabMail already wrote your answer to Priya. "
                    + "Tap the AI Suggestion to see the full email.")
        case (.replyToPriya, .compose(let showingSuggestion)):
            if !showingSuggestion {
                return card("Tap Send.", "Practice only: it goes to the demo Sent folder. Nobody receives an email.")
            }
            // The edit, then a Send that sends nothing (Send sends the AI Suggestion as it is),
            // then Use Suggestion to edit it by hand.
            if !replyEdited {
                return card("TabMail wrote the email.", "Say what to change: tap Edit at the top, then Send.")
            }
            return sendAsIsTapped
                ? card("Or make it yours.", "Tap Use Suggestion, change what you like, then Send.")
                : card("TabMail changed it.", "Looks good? Just tap Send. Don't worry, this one won't go out.")
        case (.makeTemplate, .chat):
            return card(
                "Sent. Now ask TabMail.",
                "This field writes to Priya. To ask TabMail for something instead, drag the field up.")
        case (.makeTemplate, .inbox):
            return card("Sent. Now ask TabMail.", "Nobody received it. Open Priya’s email to ask TabMail for a template.")
        case (.makeTemplate, .chatPanel) where templateAsked:
            return card("Tap Create to keep it.", "A template is a reply TabMail reuses for emails like this one.")
        case (.makeTemplate, .chatPanel):
            return card(
                "Ask TabMail to keep it.",
                "In this chat you can ask TabMail for anything. Tap Send to save your reply as a template.")
        case (.reuseReplyDone, .chatPanel), (.reuseReplyDone, .chat), (.reuseReplyDone, .inbox):
            var c = card(
                "Template saved.",
                "Next time an invite like this comes in, your reply starts from it. "
                    + "Find your templates in TabMail Settings, under Reply Templates.",
                done: true)
            c.buttons = [Button(label: "See template", action: .seeTemplate), next]
            return c

        // Part 3
        case (.askFlights, .inbox) where flightsAsked:
            return card("Check the original.", "Open Chat and tap the email reference in the answer.")
        case (.askFlights, .inbox):
            return card("Start with Chat.", "Tap Chat at the bottom of the inbox.")
        case (.askAnythingDone, .chat):
            var c = card(
                "There’s your answer.",
                "You went from a question to Jordan’s email. Tap the message for the full email.", done: true)
            c.buttons = [Button(label: "Next", action: .showMoreToAsk, isPrimary: true)]
            return c
        case (.askAnythingDone, .inbox):
            var c = card("There’s your answer.", "You went from a question to the original email.", done: true)
            c.buttons = [Button(label: "Next", action: .showMoreToAsk, isPrimary: true)]
            return c
        case (.moreToAsk, .inbox):
            var c = card("Ask anything.", "Not sure where to start? Tap Chat to ask TabMail what it can do.", done: true)
            c.examples = askExamples
            c.buttons = [Button(label: "Finish", action: .showRecap, isPrimary: true)]
            return c

        // The Chat View switch step, after the three parts.
        case (.chatViewSwitch, .chatViewSwitch):
            return TutorialCoachContent(
                progressLine: "Last step",
                title: "Two ways to read.",
                message: "Prefer the classic email view? Turn off Chat View here. You can turn it back on any time.",
                buttons: [Button(label: "Finish", action: .finishChatViewSwitch, isPrimary: true)])

        default:
            return nil
        }
    }
}
