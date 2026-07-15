/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import UserNotifications

/// Single source of truth for user-facing email notification content. Used by
/// both the main-app silent-push / BGAppRefresh path (`AccountManagerAI.post-
/// ReplyNotificationIfNeeded`) and the NSE (`NotificationService`).
///
/// Rule:
///   - Messages where `isImportant(_:)` returns true → **active** banner +
///     sound, "New email" title. Body is "`<dueLabel> — <reminderContent>`"
///     when the AI extracted a reminder, otherwise the summary blurb.
///   - Everything else → **passive** (no banner, no sound) with sender +
///     summary so Notification Center still surfaces the mail.
///
/// Due-date-based reminder pings (`ProactiveNotifyService`'s scheduled +
/// overdue paths) have their own scheduling logic and are intentionally
/// NOT governed by this function.
///
/// Both paths use the same notification identifier + threadIdentifier so
/// re-delivery from the other path replaces (doesn't duplicate) the
/// existing notification.
enum EmailNotificationBuilder {

    /// Provider message IDs are transport/deep-link identifiers. Notification
    /// actions use only this normalized RFC Message-ID field.
    static let actionMessageIdUserInfoKey = "rfc822MessageId"

    /// Normalize the action identity at the notification boundary. Newlines
    /// are never valid inside a Message-ID and must not survive into a durable
    /// action payload.
    static func normalizedActionMessageId(_ raw: String?) -> String? {
        MessageIdentity.durableActionRFC822MessageId(raw)
    }

    /// Bundle of facts about a newly-arrived email that feed the importance
    /// gate AND the notification layout. Kept as one struct so future signals
    /// (reminder + action combined, sender allow-lists, subject keywords,
    /// thread participation, etc.) can be added without churning every call
    /// site.
    ///
    /// All fields other than `senderName` and `subject` are optional to keep
    /// construction cheap from partial sources (peer cache hits, silent-push
    /// merges with incomplete headers, reminder-driven nudges, etc.).
    struct Signal {
        let senderName: String
        let senderEmail: String?
        let subject: String
        let summaryBlurb: String?
        let actionTag: String?
        let reminderContent: String?
        let dueDate: String?
        let dueTime: String?

        init(
            senderName: String,
            senderEmail: String? = nil,
            subject: String,
            summaryBlurb: String? = nil,
            actionTag: String? = nil,
            reminderContent: String? = nil,
            dueDate: String? = nil,
            dueTime: String? = nil
        ) {
            self.senderName = senderName
            self.senderEmail = senderEmail
            self.subject = subject
            self.summaryBlurb = summaryBlurb
            self.actionTag = actionTag
            self.reminderContent = reminderContent
            self.dueDate = dueDate
            self.dueTime = dueTime
        }
    }

    /// Whether this email is important enough to interrupt the user
    /// (active + sound) vs land silently in Notification Center (passive).
    /// Single source of truth for every new-email ping path: NSE, main-app
    /// silent push, BGAppRefresh merge.
    ///
    /// Today: only reply-tagged messages ping. The full `Signal` is passed
    /// so future rules can combine fields (e.g. reply + reminder, VIP
    /// sender, subject keywords) without reshaping callers.
    static func isImportant(_ s: Signal) -> Bool {
        s.actionTag == "reply"
    }

    /// Stable notification identifier — same scheme in both main app + NSE.
    static func identifier(accountId: String, messageId: String) -> String {
        "email-\(accountId)-\(messageId)"
    }

    /// Format the due label from raw AI summary strings (`YYYY-MM-DD` date +
    /// optional `HH:mm` time). Mirrors `ReminderBuilder.formatDueLabelForCard`
    /// — both targets compile this function, so NSE and main app produce
    /// byte-identical notification bodies.
    ///
    /// Returns nil if the date is malformed or missing — caller should then
    /// use the raw reminder content without a due prefix.
    static func formatDueLabel(dueDate: String?, dueTime: String?) -> String? {
        guard let dueDateStr = dueDate else { return nil }
        let parts = dueDateStr.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }

        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let dueDateObj = calendar.date(from: comps) else { return nil }
        let dueMidnight = calendar.startOfDay(for: dueDateObj)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }

        let timeSuffix = dueTime.map { " at \($0)" } ?? ""

        if dueMidnight == today { return "Today\(timeSuffix)" }
        if dueMidnight == tomorrow { return "Tomorrow\(timeSuffix)" }
        if dueMidnight < today {
            let daysOverdue = calendar.dateComponents([.day], from: dueMidnight, to: today).day ?? 0
            let dayWord = daysOverdue == 1 ? "day" : "days"
            return "Overdue (\(daysOverdue) \(dayWord))"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return "Due \(formatter.string(from: dueMidnight))\(timeSuffix)"
    }

    /// Notification category per AI action tag: the category picks which
    /// long-press action buttons iOS attaches, so a tagged notification
    /// surfaces the SUGGESTED action first (registered in
    /// `AppDelegate.registerNotificationCategories` with identical action
    /// ids — `NotificationActionRouter` handles all categories unchanged).
    /// Only `archive`/`delete` get suggestion categories; `reply` has no
    /// notification-actionable equivalent yet and `none`/nil mean no
    /// suggestion — both keep the generic `EMAIL` category. Tag strings are
    /// the canonical lowercase set validated by
    /// `AIResponseParser.parseActionTag` (delete/archive/reply/none).
    static func categoryIdentifier(forActionTag tag: String?) -> String {
        switch tag {
        case "archive": return "EMAIL_TAG_ARCHIVE"
        case "delete": return "EMAIL_TAG_DELETE"
        default: return "EMAIL"
        }
    }

    /// Fill an email notification with unified layout used by every
    /// new-email ping path (NSE, main-app silent push, BGAppRefresh merge).
    ///
    ///   title    = "New email - <sender>"
    ///   subtitle = <email subject>
    ///   body     = "<dueLabel> — <reminderContent>"   when reminder extracted
    ///            = <summaryBlurb>                     when only summary exists
    ///            = ""                                 when AI produced neither
    ///
    /// Interruption level is `.active` with default sound **only** when
    /// `isImportant(_:)` returns true. Everything else is `.passive` so
    /// it lands in Notification Center without ringing.
    ///
    /// Returns `true` if the notification was delivered at active level
    /// (caller uses this to decide whether to persist `notified=true`).
    @discardableResult
    static func fill(
        _ c: UNMutableNotificationContent,
        signal s: Signal,
        accountId: String,
        messageId: String,
        rfc822MessageId: String?
    ) -> Bool {
        c.title = s.senderName.isEmpty ? "New email" : "New email - \(s.senderName)"
        c.subtitle = s.subject
        c.threadIdentifier = accountId
        var info = c.userInfo
        // `messageId` remains the momentary provider identifier used to open
        // or fetch the notification's message. It must never be interpreted as
        // the durable action identity.
        info["messageId"] = messageId
        info["accountId"] = accountId
        if let actionMessageId = normalizedActionMessageId(rfc822MessageId) {
            info[actionMessageIdUserInfoKey] = actionMessageId
            c.categoryIdentifier = categoryIdentifier(forActionTag: s.actionTag)
        } else {
            // No durable provider-neutral identity means no action buttons.
            // The notification itself remains visible and deep-linkable.
            info.removeValue(forKey: actionMessageIdUserInfoKey)
            c.categoryIdentifier = ""
        }
        c.userInfo = info

        if let rc = s.reminderContent, !rc.isEmpty {
            if let dueLabel = formatDueLabel(dueDate: s.dueDate, dueTime: s.dueTime) {
                c.body = "\(dueLabel) \u{2014} \(rc)"
            } else {
                c.body = rc
            }
        } else {
            c.body = s.summaryBlurb ?? ""
        }

        if isImportant(s) {
            c.interruptionLevel = .active
            c.sound = .default
            return true
        }
        c.interruptionLevel = .passive
        c.sound = nil
        return false
    }
}
