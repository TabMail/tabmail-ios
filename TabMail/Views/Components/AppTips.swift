/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import TipKit

// MARK: - Global onboarding gate
//
// All tips are gated on `OnboardingTipGate.onboardingComplete` so no
// tip can render until the user has cleared every consent gate. Set
// to `true` from `RootView` when the user finishes the last gate;
// TipKit persists `@Parameter` values to its datastore, so once
// flipped this stays flipped across launches.
//
// Why parameter rules instead of `Tips.hideAllTipsForTesting()` —
// the hide/show APIs are documented test utilities (must be called
// before `Tips.configure(...)`); Apple's WWDC23 "Make Features
// Discoverable with TipKit" session recommends parameter rules for
// any production gating.
enum OnboardingTipGate {
    @Parameter
    static var onboardingComplete: Bool = false
}

// MARK: - Inbox Tips

/// Shown on first inbox message to teach swipe gestures.
struct SwipeActionsTip: Tip {
    static let inboxVisitCount = Event(id: "inboxVisitCount")

    var title: Text { Text("Swipe for Quick Actions") }
    var message: Text? { Text("Swipe left to archive or delete. Swipe right to mark read/unread or move.\u{00A0}") }
    var image: Image? { Image(systemName: "hand.draw") }

    var rules: [Rule] {
        #Rule(Self.inboxVisitCount) { $0.donations.count >= 2 }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

/// Shown near the tag badge to teach long-press tag teaching.
/// Shown on tag badge in MessageDetailView.
struct TagTeachingTip: Tip {
    var title: Text { Text("Teach TabMail") }
    var message: Text? { Text("Long-press the tag to re-tag this message.\u{00A0}") }
    var image: Image? { Image(systemName: "tag") }

    var rules: [Rule] {
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

/// Shown on inbox rows that have a tag.
struct InboxTagTeachingTip: Tip {
    var title: Text { Text("Teach TabMail") }
    var message: Text? { Text("Long-press an action tag to teach TabMail what it should be.\u{00A0}") }
    var image: Image? { Image(systemName: "tag") }

    var rules: [Rule] {
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Large Inbox Tips

/// Shown when inbox has 100+ messages with some older than 2 weeks.
/// Suggests archiving old emails to keep inbox as a task queue.
/// Matches TB's inboxArchivePrompt behavior. Shown once — directs to
/// Email Accounts settings for bulk archive on dismiss.
struct ArchiveOldEmailsTip: Tip {
    @Parameter
    static var isLargeInbox: Bool = false

    var title: Text { Text("Keep Your Inbox Focused") }
    var message: Text? { Text("You have old emails in your inbox. Archiving emails older than 2 weeks helps you focus on what matters — think of your inbox as your task queue. You can archive old emails from Email Accounts in settings.\u{00A0}") }
    var image: Image? { Image(systemName: "archivebox") }

    var rules: [Rule] {
        #Rule(Self.$isLargeInbox) { $0 == true }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Push Notifications Tip

/// Shown on the unified inbox when push notifications are OFF. Encourages
/// users to enable inbox push notifications for more reliable and immediate
/// email delivery. Auto-hides (via @Parameter rule) when the user turns
/// push on. Dismissible; capped at a single display.
struct EnableInboxPushTip: Tip {
    static let openSettingsActionId = "open-email-accounts"

    @Parameter
    static var pushEnabled: Bool = false

    var title: Text { Text("Instant New Email") }
    var message: Text? { Text("Turn on Inbox Push Notifications for reliable, real-time delivery. TabMail only buzzes you for important emails — the rest arrive quietly in Notification Center.\u{00A0}") }
    var image: Image? { Image(systemName: "bell.badge") }

    var actions: [Action] {
        Action(id: Self.openSettingsActionId, title: "Open Email Accounts")
    }

    var rules: [Rule] {
        #Rule(Self.$pushEnabled) { $0 == false }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Triage Tips

/// Shown on the triage mode toggle button after enough tags have been seen.
struct TriageModeTip: Tip {
    static let tagSeen = Event(id: "triageTagSeen")

    var title: Text { Text("Triage Mode") }
    var message: Text? { Text("Switch to triage view to sort messages by tag and quickly act on them in bulk.\u{00A0}") }
    var image: Image? { Image(systemName: "line.3.horizontal.decrease.circle") }

    var rules: [Rule] {
        #Rule(Self.tagSeen) { $0.donations.count >= 10 }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Search Tips

/// Shown on the scope toggle button in SearchView.
struct SearchScopeTip: Tip {
    var title: Text { Text("Search Scope") }
    var message: Text? { Text("Tap to toggle between searching the current mailbox or all mailboxes.\u{00A0}") }
    var image: Image? { Image(systemName: "globe") }

    var rules: [Rule] {
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Message Detail Tips

/// Shown on the AI summary bubble to teach expand/report.
struct SummaryBubbleTip: Tip {
    var title: Text { Text("AI Summary") }
    var message: Text? { Text("Tap to expand. Long-press any AI-generated content to report a concern.\u{00A0}") }
    var image: Image? { Image(systemName: "wand.and.sparkles") }

    var rules: [Rule] {
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Chat Tips

/// Shown on the chat pill in inbox view.
struct InboxChatPillTip: Tip {
    static let inboxVisitCount = Event(id: "inboxChatPillVisit")

    var title: Text { Text("Your AI Assistant") }
    var message: Text? { Text("Ask anything, schedule meetings, search your email, and more.\u{00A0}") }
    var image: Image? { Image(systemName: "bubble.left.and.bubble.right") }

    var rules: [Rule] {
        #Rule(Self.inboxVisitCount) { $0.donations.count >= 2 }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

/// Shown on the chat pill in message detail view.
struct ChatPillTip: Tip {
    static let messageOpened = Event(id: "messageOpened")

    var title: Text { Text("Ask About This Email") }
    var message: Text? { Text("Tap the chat pill to ask questions about this email.\u{00A0}") }
    var image: Image? { Image(systemName: "bubble.left.and.bubble.right") }

    var rules: [Rule] {
        #Rule(Self.messageOpened) { $0.donations.count >= 1 }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

/// Shown on the chat pill in compose view.
struct ComposeChatPillTip: Tip {
    var title: Text { Text("Edit with AI") }
    var message: Text? { Text("Tap to chat with AI and edit your draft.\u{00A0}") }
    var image: Image? { Image(systemName: "wand.and.sparkles") }

    var rules: [Rule] {
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

/// Shown on a chat message bubble to teach fork/re-send.
struct ChatForkTip: Tip {
    static let chatMessageSent = Event(id: "chatMessageSent")

    var title: Text { Text("Re-send or Fork") }
    var message: Text? { Text("Long-press your message to re-send it or start a new branch from that point.\u{00A0}") }
    var image: Image? { Image(systemName: "arrow.uturn.right") }

    var rules: [Rule] {
        #Rule(Self.chatMessageSent) { $0.donations.count >= 2 }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Settings Tips

/// Shown once on first visit to prompt settings pages (Composition, Templates, Action Rules).
/// Teaches pull-to-refresh to sync with other devices.
struct DeviceSyncTip: Tip {
    var title: Text { Text("Sync with Other Devices") }
    var message: Text? { Text("Pull down to sync these settings with your other TabMail devices.\u{00A0}") }
    var image: Image? { Image(systemName: "arrow.triangle.2.circlepath") }

    var rules: [Rule] {
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Outbox Tips

/// Shown on first outbox visit to teach swipe gestures (retry/discard).
struct OutboxSwipeActionsTip: Tip {
    var title: Text { Text("Swipe for Actions") }
    var message: Text? { Text("Swipe right to retry a failed send. Swipe left to discard.\u{00A0}") }
    var image: Image? { Image(systemName: "hand.draw") }

    var rules: [Rule] {
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Agent Background Tip

/// Shown once when the user navigates away while an agent is working.
/// Teaches that the agent will notify them when done.
struct AgentBackgroundTip: Tip {
    @Parameter
    static var hasNavigatedAwayDuringWork: Bool = false

    var title: Text { Text("Agent working in background") }
    var message: Text? { Text("No need to wait — you'll be notified when the agent is done.\u{00A0}") }
    var image: Image? { Image(systemName: "bell.badge") }

    var rules: [Rule] {
        #Rule(Self.$hasNavigatedAwayDuringWork) { $0 == true }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

/// Modifier that shows the AgentBackgroundTip on the chat pill when an agent is working
/// in a different view (message-detail or compose).
struct AgentBackgroundTipModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .popoverTip(AgentBackgroundTip(), arrowEdge: .bottom)
            .onChange(of: active) { _, isActive in
                if isActive {
                    AgentBackgroundTip.hasNavigatedAwayDuringWork = true
                }
            }
    }
}

// MARK: - Compose Save-Draft Background Tip

/// Shown once after the user has used the compose agent AND collapsed the chat
/// at least once. Anchors on the (collapsed) compose chat pill in `ComposeView`.
/// Teaches that closing the compose view lets the agent keep working in the
/// background — distinct from `ComposeChatCollapseTip` (shown on the expanded
/// header) which teaches that collapsing the chat keeps the agent working.
struct ComposeSaveDraftTip: Tip {
    @Parameter
    static var hasClosedComposeChat: Bool = false

    var title: Text { Text("Agent Keeps Working") }
    var message: Text? { Text("You can save this draft and leave by pressing Close — the agent will finish editing in the background and notify you when done.\u{00A0}") }
    var image: Image? { Image(systemName: "arrow.down.doc") }

    var rules: [Rule] {
        #Rule(Self.$hasClosedComposeChat) { $0 == true }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Chat Pill Collapse Background Tips

/// Shown once when the user first sends a message in the inbox chat pill.
/// Teaches that collapsing the pill lets the agent work in the background.
struct InboxChatCollapseTip: Tip {
    @Parameter
    static var hasStartedInboxChat: Bool = false

    var title: Text { Text("Agent Works in Background") }
    var message: Text? { Text("Tap here to close the chat — the agent will keep working and notify you when done.\u{00A0}") }
    var image: Image? { Image(systemName: "chevron.down") }

    var rules: [Rule] {
        #Rule(Self.$hasStartedInboxChat) { $0 == true }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

/// Shown once when the user first sends a chat message in compose mode.
/// Anchors on the "Edit Draft" header of the expanded compose chat pill.
/// Teaches that collapsing the pill lets the agent keep editing in the background.
struct ComposeChatCollapseTip: Tip {
    @Parameter
    static var hasStartedComposeChat: Bool = false

    var title: Text { Text("Agent Works in Background") }
    var message: Text? { Text("Tap here to close — the agent will keep editing your draft.\u{00A0}") }
    var image: Image? { Image(systemName: "chevron.down") }

    var rules: [Rule] {
        #Rule(Self.$hasStartedComposeChat) { $0 == true }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

/// Shown once when the user first sends a message in the message-detail chat pill.
/// Teaches that collapsing the pill lets the agent work in the background.
struct MessageChatCollapseTip: Tip {
    @Parameter
    static var hasStartedMessageChat: Bool = false

    var title: Text { Text("Agent Works in Background") }
    var message: Text? { Text("Tap here to close the chat — the agent will keep working and notify you when done.\u{00A0}") }
    var image: Image? { Image(systemName: "chevron.down") }

    var rules: [Rule] {
        #Rule(Self.$hasStartedMessageChat) { $0 == true }
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

/// Selects the appropriate collapse tip based on chat pill context.
struct ChatPillCollapseTipModifier: ViewModifier {
    let isComposeMode: Bool
    let hasMessage: Bool

    func body(content: Content) -> some View {
        if isComposeMode {
            content.popoverTip(ComposeChatCollapseTip(), arrowEdge: .top)
        } else if hasMessage {
            content.popoverTip(MessageChatCollapseTip(), arrowEdge: .top)
        } else {
            content.popoverTip(InboxChatCollapseTip(), arrowEdge: .top)
        }
    }
}

// MARK: - Reminders Menu Tip

/// Shown once on the Reminders nav link in the mailboxes sidebar.
/// Teaches users where to find and manage their email reminders.
struct RemindersMenuTip: Tip {
    var title: Text { Text("Your Reminders") }
    var message: Text? { Text("View and manage all your email reminders here.\u{00A0}") }
    var image: Image? { Image(systemName: "bell") }

    var rules: [Rule] {
        #Rule(OnboardingTipGate.$onboardingComplete) { $0 == true }
    }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
}

// MARK: - Chat Pill Tip Modifier

/// Selects the appropriate chat pill tip based on context (inbox / detail / compose).
struct ChatPillTipModifier: ViewModifier {
    let isComposeMode: Bool
    let hasMessage: Bool

    func body(content: Content) -> some View {
        if isComposeMode {
            content
                .popoverTip(ComposeChatPillTip(), arrowEdge: .top)
        } else if hasMessage {
            content
                .popoverTip(ChatPillTip(), arrowEdge: .bottom)
                .task { await ChatPillTip.messageOpened.donate() }
        } else {
            content
                .popoverTip(InboxChatPillTip(), arrowEdge: .bottom)
                .task { await InboxChatPillTip.inboxVisitCount.donate() }
        }
    }
}

// MARK: - Preview Canvas

#Preview("All Tips") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                TipView(SwipeActionsTip())
                TipView(TagTeachingTip())
                TipView(InboxTagTeachingTip())
                TipView(ArchiveOldEmailsTip())
                TipView(EnableInboxPushTip())
                TipView(TriageModeTip())
                TipView(SearchScopeTip())
                TipView(SummaryBubbleTip())
                TipView(InboxChatPillTip())
                TipView(ChatPillTip())
            }
            Group {
                TipView(ComposeChatPillTip())
                TipView(ChatForkTip())
                TipView(DeviceSyncTip())
                TipView(OutboxSwipeActionsTip())
                TipView(AgentBackgroundTip())
                TipView(ComposeSaveDraftTip())
                TipView(ComposeChatCollapseTip())
                TipView(InboxChatCollapseTip())
                TipView(MessageChatCollapseTip())
                TipView(RemindersMenuTip())
            }
        }
        .padding()
    }
}
