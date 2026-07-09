/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import UserNotifications
@testable import TabMail

/// `EmailNotificationBuilder` — the single source of truth for new-email
/// notification content/importance, shared by the NSE and the main app's
/// silent-push / BGAppRefresh paths.
///
/// Coverage here is what backs the NSE's partial-result watchdog delivery
/// (`NotificationService.applyPartialOrBareFallback`): a `Signal` with a
/// summary but no action tag (the vote hasn't returned yet) MUST render as
/// PASSIVE with no sound — never active/ringing for a guess.
@Suite("EmailNotificationBuilder")
struct EmailNotificationBuilderTests {

    // MARK: - Importance gate

    @Test("isImportant is false with no actionTag")
    func isImportantFalseWithNoActionTag() {
        let signal = EmailNotificationBuilder.Signal(senderName: "Alice", subject: "Hello")
        #expect(!EmailNotificationBuilder.isImportant(signal))
    }

    @Test("isImportant is true only for actionTag == reply")
    func isImportantTrueForReply() {
        let reply = EmailNotificationBuilder.Signal(senderName: "Alice", subject: "Hello", actionTag: "reply")
        let archive = EmailNotificationBuilder.Signal(senderName: "Alice", subject: "Hello", actionTag: "archive")
        #expect(EmailNotificationBuilder.isImportant(reply))
        #expect(!EmailNotificationBuilder.isImportant(archive))
    }

    // MARK: - fill(): summary-only (no action tag) → PASSIVE

    @Test("Signal with summaryBlurb set and actionTag nil produces a PASSIVE notification whose body is the summary")
    func summaryOnlyProducesPassiveWithSummaryBody() {
        let content = UNMutableNotificationContent()
        let signal = EmailNotificationBuilder.Signal(
            senderName: "Alice", senderEmail: "alice@example.com", subject: "Project update",
            summaryBlurb: "Alice shared the Q3 numbers and asked for feedback by Friday.",
            actionTag: nil
        )

        let wasActive = EmailNotificationBuilder.fill(content, signal: signal, accountId: "acc1", messageId: "msg1")

        #expect(!wasActive)
        #expect(content.interruptionLevel == .passive)
        #expect(content.sound == nil)
        #expect(content.body == "Alice shared the Q3 numbers and asked for feedback by Friday.")
        #expect(content.title == "New email - Alice")
        #expect(content.subtitle == "Project update")
    }

    // MARK: - fill(): reply-tagged → ACTIVE

    @Test("Signal with actionTag reply produces an ACTIVE notification with default sound")
    func replyTaggedProducesActiveWithSound() {
        let content = UNMutableNotificationContent()
        let signal = EmailNotificationBuilder.Signal(
            senderName: "Bob", subject: "Quick question",
            summaryBlurb: "Bob is asking whether the meeting still works for Thursday.",
            actionTag: "reply"
        )

        let wasActive = EmailNotificationBuilder.fill(content, signal: signal, accountId: "acc1", messageId: "msg2")

        #expect(wasActive)
        #expect(content.interruptionLevel == .active)
        #expect(content.sound != nil)
    }

    // MARK: - fill(): no summary, no action → PASSIVE with empty body

    @Test("Signal with neither summary nor action produces PASSIVE with empty body")
    func noAIResultProducesPassiveEmptyBody() {
        let content = UNMutableNotificationContent()
        let signal = EmailNotificationBuilder.Signal(senderName: "Carol", subject: "No AI yet")

        let wasActive = EmailNotificationBuilder.fill(content, signal: signal, accountId: "acc1", messageId: "msg3")

        #expect(!wasActive)
        #expect(content.interruptionLevel == .passive)
        #expect(content.sound == nil)
        #expect(content.body == "")
    }

    // MARK: - fill(): reminder content takes priority over the summary blurb

    @Test("Signal with reminderContent uses the due-labeled reminder body, not the summary")
    func reminderContentTakesPriorityOverSummary() {
        let content = UNMutableNotificationContent()
        // Built from LOCAL calendar components (not an ISO8601Formatter, which
        // defaults to UTC) — `formatDueLabel` reconstructs the date via
        // `Calendar.current`, so this must match that same local calendar to
        // avoid a UTC/local-timezone off-by-one-day flake near midnight.
        let todayComps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        guard let year = todayComps.year, let month = todayComps.month, let day = todayComps.day else {
            Issue.record("failed to derive today's local date components")
            return
        }
        let todayString = String(format: "%04d-%02d-%02d", year, month, day)
        let signal = EmailNotificationBuilder.Signal(
            senderName: "Dana", subject: "Renewal reminder",
            summaryBlurb: "This should be superseded by the reminder body.",
            actionTag: nil,
            reminderContent: "Renew the domain",
            dueDate: todayString
        )

        _ = EmailNotificationBuilder.fill(content, signal: signal, accountId: "acc1", messageId: "msg4")

        #expect(content.body == "Today \u{2014} Renew the domain")
        #expect(content.interruptionLevel == .passive)
    }
}
