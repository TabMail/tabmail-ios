/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import UserNotifications

/// Proactive notification service — replicates TB's `proactiveCheckin.js`.
/// Fires local notifications for reminders. Each reminder notifies at most once
/// (dedup via ReachedOutStore with 48h TTL).
///
/// Flow: on reminder list change → loop over reminders → check validity → notify
/// unnotified ones. Due-approaching reminders also get a scheduled
/// `UNCalendarNotificationTrigger` so they fire even if the app isn't running.
///
/// No LLM calls. Content is template-based string interpolation.
/// ADR-IOS-008: AI processing MUST exactly replicate TB addon architecture.
actor ProactiveNotifyService {
    static let shared = ProactiveNotifyService()

    // MARK: - Config

    /// UserDefaults keys for user-facing settings
    static let enabledKey = "proactive.notify.enabled"
    static let windowDaysKey = "proactive.notify.window_days"
    static let advanceMinutesKey = "proactive.notify.advance_minutes"

    /// Defaults matching TB's DEFAULTS
    static let defaultWindowDays = 7
    static let defaultAdvanceMinutes = 30
    private static let minIntervalSeconds: TimeInterval = 60
    private static let debounceSeconds: TimeInterval = 1.0

    // MARK: - State

    /// Hash of the full reminder list — used to detect changes.
    private var reminderListHash: String?
    private var lastReachoutDate: Date?
    private var lastTTLRefreshDate: Date?
    private var debounceTask: Task<Void, Never>?

    private init() {
        if let ts = UserDefaults.standard.object(forKey: "proactive.last_reachout") as? Date {
            lastReachoutDate = ts
        }
    }

    // MARK: - Config Accessors

    private var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledKey) == nil { return true }
        return defaults.bool(forKey: Self.enabledKey)
    }

    private var windowDays: Int {
        let val = UserDefaults.standard.integer(forKey: Self.windowDaysKey)
        return val > 0 ? min(val, 30) : Self.defaultWindowDays
    }

    private var advanceMinutes: Int {
        let val = UserDefaults.standard.integer(forKey: Self.advanceMinutesKey)
        return val > 0 ? min(val, 120) : Self.defaultAdvanceMinutes
    }

    // MARK: - Main Entry Point

    /// Called after AI message processing completes with >= 1 processed message.
    /// Matches TB's `onInboxUpdated()` in `proactiveCheckin.js`.
    func onInboxUpdated() async {
        guard isEnabled else { return }
        // Demo guard: while demo is active the reminder list is demo-scoped
        // (ReminderBuilder) — rescheduling from it would replace the user's
        // pending notification schedule with demo content and pollute
        // ReachedOutStore with demo hashes. The user's schedule rebuilds on
        // the first reminder-list change after exit.
        let inDemo = await MainActor.run { DemoModeStore.shared.isActive }
        guard !inDemo else { return }

        // Sync any notifications iOS delivered while we weren't running
        await syncDeliveredToStore()

        let reminders = await ReminderBuilder.buildReminderList()
        let newHash = computeListHash(reminders)

        let hashChanged = newHash != reminderListHash
        reminderListHash = newHash

        // Refresh TTL for reminders still in the list — prevents entries from
        // expiring while the reminder is alive. TTL only matters for disappeared reminders.
        let activeHashes = Set(reminders.map(\.hash))
        ReachedOutStore.refreshActive(hashes: activeHashes)
        lastTTLRefreshDate = Date()

        // Prune expired entries (48h TTL) — only removes genuinely disappeared reminders
        ReachedOutStore.prune()

        // Always reschedule due-approaching triggers when list changes
        if hashChanged {
            await scheduleDueApproachingNotifications(reminders)
        }

        guard hashChanged else { return }

        // Loop over MESSAGE reminders only — KB reminders fire exclusively via
        // scheduleDueApproachingNotifications (UNCalendarNotificationTrigger).
        // Pre-fetch notified hashes once (avoids N full JSON decodes from UserDefaults)
        let messageHashes = reminders.filter { $0.source == "message" }.map(\.hash)
        let alreadyNotified = ReachedOutStore.notifiedHashes(from: messageHashes)
        var candidates: [Reminder] = []
        for r in reminders {
            guard r.source == "message" else { continue }
            guard isQualifiedForNotification(r) else { continue }
            guard !alreadyNotified.contains(r.hash) else { continue }

            let stillValid = await isMessageStillInInbox(r)
            guard stillValid else { continue }

            candidates.append(r)
        }

        guard !candidates.isEmpty else { return }

        // Mark as notified BEFORE debounce — if debounce is cancelled by a rapid
        // second onInboxUpdated, the candidates won't re-appear as unnotified.
        for c in candidates {
            ReachedOutStore.markNotified(hash: c.hash)
        }

        // Debounce (matching TB's 1s debounce) — coalesces rapid inbox changes
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(Self.debounceSeconds))
            guard !Task.isCancelled else { return }
            await deliverNotifications(candidates)
        }
    }

    // MARK: - TTL Refresh (standalone)

    /// Refresh ReachedOutStore TTL for all active reminders. Called from
    /// BGProcessingTask to keep entries alive even when onInboxUpdated doesn't fire.
    /// Skips if onInboxUpdated/onForegroundReturn already refreshed within 60s
    /// to avoid a redundant buildReminderList() GRDB query + MainActor hop.
    func refreshActiveReminders() async {
        // Demo guard — see onInboxUpdated.
        let inDemo = await MainActor.run { DemoModeStore.shared.isActive }
        guard !inDemo else { return }
        if let last = lastTTLRefreshDate, Date().timeIntervalSince(last) < 60 {
            return
        }
        let reminders = await ReminderBuilder.buildReminderList()
        let activeHashes = Set(reminders.map(\.hash))
        ReachedOutStore.refreshActive(hashes: activeHashes)
        lastTTLRefreshDate = Date()
        ReachedOutStore.prune()
    }

    // MARK: - Due Approaching (scheduled notifications)

    /// iOS caps pending local notifications at 64 (soonest survive, rest dropped).
    /// We manage the budget explicitly: collect all future fire times, sort by date,
    /// and schedule only the first 64.
    static let maxPendingNotifications = 64

    /// Build the sorted, capped list of reminders eligible for scheduled notification triggers.
    /// Pure function (no UNUserNotificationCenter dependency) for testability.
    ///
    /// - Parameters:
    ///   - reminders: full reminder list
    ///   - advanceMinutes: fire this many minutes before due time
    ///   - notifiedHashes: hashes already notified (from ReachedOutStore)
    ///   - now: current date (injectable for testing)
    ///   - windowDays: only include reminders within this many days
    /// - Returns: sorted array of (fireDate, reminder), capped at `maxPendingNotifications`
    static func buildDueNotificationCandidates(
        reminders: [Reminder],
        advanceMinutes: Int,
        notifiedHashes: Set<String>,
        now: Date,
        windowDays: Int
    ) -> [(fireDate: Date, reminder: Reminder)] {
        var candidates: [(fireDate: Date, reminder: Reminder)] = []

        for reminder in reminders {
            guard let dateTime = parseDueDateTimeStatic(reminder) else { continue }
            guard qualifiesForDueNotification(reminder, now: now, windowDays: windowDays) else { continue }
            guard !notifiedHashes.contains(reminder.hash) else { continue }

            let fireDate = dateTime.addingTimeInterval(-Double(advanceMinutes) * 60)
            guard fireDate > now else { continue }

            candidates.append((fireDate: fireDate, reminder: reminder))
        }

        candidates.sort { $0.fireDate < $1.fireDate }
        return Array(candidates.prefix(maxPendingNotifications))
    }

    /// Static version of qualification check for testability.
    private static func qualifiesForDueNotification(_ reminder: Reminder, now: Date, windowDays: Int) -> Bool {
        guard reminder.enabled else { return false }
        if reminder.source == "message" {
            guard reminder.action == "reply" else { return false }
        }
        // Within window check
        if let dueDateStr = reminder.dueDate, let dueDate = parseDateStatic(dueDateStr) {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let dueMidnight = calendar.startOfDay(for: dueDate)
            let daysDiff = calendar.dateComponents([.day], from: today, to: dueMidnight).day ?? 0
            if daysDiff > windowDays { return false }
        }
        // Must not be past due
        if let dateTime = parseDueDateTimeStatic(reminder), dateTime < now {
            return false
        }
        return true
    }

    /// Static version of parseDueDateTime for use in static methods.
    static func parseDueDateTimeStatic(_ reminder: Reminder) -> Date? {
        guard let dueDateStr = reminder.dueDate, let date = parseDateStatic(dueDateStr) else { return nil }
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        if let timeStr = reminder.dueTime {
            let timeParts = timeStr.split(separator: ":")
            if timeParts.count == 2, let hour = Int(timeParts[0]), let minute = Int(timeParts[1]) {
                components.hour = hour
                components.minute = minute
            }
        } else {
            components.hour = 9
            components.minute = 0
        }
        return calendar.date(from: components)
    }

    private static func parseDateStatic(_ str: String) -> Date? {
        let parts = str.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return Calendar.current.date(from: comps)
    }

    /// Schedule `UNCalendarNotificationTrigger` for reminders with due dates.
    /// Fires even if app is killed. Caps at 64 pending notifications (iOS limit).
    /// Sorted by fire date — soonest reminders get priority.
    private func scheduleDueApproachingNotifications(_ reminders: [Reminder]) async {
        let center = UNUserNotificationCenter.current()

        // Cancel all existing due-approaching pending notifications
        let pending = await center.pendingNotificationRequests()
        let dueIds = pending.filter { $0.identifier.hasPrefix("due_") }.map(\.identifier)
        if !dueIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: dueIds)
        }

        let notifiedHashes = ReachedOutStore.notifiedHashes(
            from: reminders.compactMap { $0.dueDate != nil ? $0.hash : nil }
        )
        let toSchedule = Self.buildDueNotificationCandidates(
            reminders: reminders,
            advanceMinutes: advanceMinutes,
            notifiedHashes: notifiedHashes,
            now: Date(),
            windowDays: windowDays
        )

        let calendar = Calendar.current
        for (fireDate, reminder) in toSchedule {
            let content = UNMutableNotificationContent()
            content.title = "Reminder"
            let dueLabel = ReminderBuilder.formatDueLabelForCard(reminder) ?? "Upcoming"
            content.body = "\(dueLabel): \(reminder.content)"
            content.sound = .default
            content.userInfo = ["hash": reminder.hash, "messageId": reminder.messageId ?? "", "source": reminder.source]

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: "due_\(reminder.hash)", content: content, trigger: trigger)

            do {
                try await center.add(request)
            } catch {
                print("[ProactiveNotify] Failed to schedule due notification: \(error)")
            }
        }

        if !toSchedule.isEmpty {
            print("[ProactiveNotify] Scheduled \(toSchedule.count) due notifications (limit \(Self.maxPendingNotifications))")
        }
    }

    // MARK: - Foreground Return

    /// On foreground return, sync delivered notifications and fire overdue ones.
    func onForegroundReturn() async {
        guard isEnabled else { return }
        // Demo guard — see onInboxUpdated.
        let inDemo = await MainActor.run { DemoModeStore.shared.isActive }
        guard !inDemo else { return }
        guard !isRateLimited() else { return }

        await syncDeliveredToStore()

        let reminders = await ReminderBuilder.buildReminderList()

        // Refresh TTL for active reminders (same as onInboxUpdated)
        let activeHashes = Set(reminders.map(\.hash))
        ReachedOutStore.refreshActive(hashes: activeHashes)
        lastTTLRefreshDate = Date()

        let now = Date()
        let center = UNUserNotificationCenter.current()
        var delivered = false

        for r in reminders {
            guard let dateTime = parseDueDateTime(r) else { continue }
            // Overdue check: must have due date in the past, be enabled, and qualify
            // (cannot use isQualifiedForNotification — it rejects past-due reminders)
            guard r.enabled else { continue }
            if r.source == "message" { guard r.action == "reply" else { continue } }
            guard isWithinWindow(r) else { continue }
            guard dateTime < now else { continue }
            guard !ReachedOutStore.hasNotified(hash: r.hash) else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Reminder"
            let dueLabel = ReminderBuilder.formatDueLabelForCard(r) ?? "Overdue"
            content.body = "\(dueLabel): \(r.content)"
            content.sound = .default
            content.userInfo = ["hash": r.hash, "messageId": r.messageId ?? "", "source": r.source]

            let request = UNNotificationRequest(identifier: "overdue_\(r.hash)", content: content, trigger: nil)

            do {
                try await center.add(request)
                ReachedOutStore.markNotified(hash: r.hash)
                delivered = true
                print("[ProactiveNotify] Delivered overdue notification: \(r.content.prefix(60))")
            } catch {
                print("[ProactiveNotify] Failed to deliver overdue notification: \(error)")
            }
        }

        if delivered {
            recordReachout()
        }
    }

    // MARK: - Notification Delivery

    private func deliverNotifications(_ candidates: [Reminder]) async {
        guard !isRateLimited() else {
            print("[ProactiveNotify] Rate limited — skipping notification batch")
            return
        }

        let center = UNUserNotificationCenter.current()

        for r in candidates {
            let header: MessageHeader? = await {
                guard let messageId = r.messageId, !messageId.isEmpty else { return nil }
                return try? await AppDatabase.dbPool.read { db in
                    try MessageHeader.filter(Column("id") == messageId).fetchOne(db)
                }
            }()

            let content = UNMutableNotificationContent()
            EmailNotificationBuilder.fill(
                content,
                signal: EmailNotificationBuilder.Signal(
                    senderName: r.from ?? header?.from ?? "",
                    senderEmail: header?.fromAddress,
                    subject: r.subject ?? header?.subject ?? "",
                    summaryBlurb: header?.summaryBlurb,
                    actionTag: r.action,
                    reminderContent: r.content,
                    dueDate: r.dueDate,
                    dueTime: r.dueTime
                ),
                accountId: header?.accountId ?? "",
                messageId: r.messageId ?? ""
            )
            var info = content.userInfo
            info["hash"] = r.hash
            info["source"] = r.source
            content.userInfo = info

            let identifier: String = {
                if let accountId = header?.accountId, let messageId = r.messageId, !messageId.isEmpty {
                    return EmailNotificationBuilder.identifier(accountId: accountId, messageId: messageId)
                }
                return "nudge_\(r.hash)"
            }()
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

            do {
                try await center.add(request)
                print("[ProactiveNotify] Delivered notification: \(r.content.prefix(60))")
            } catch {
                print("[ProactiveNotify] Failed to deliver notification: \(error)")
            }
        }

        // Record once for the whole batch
        recordReachout()
    }

    // MARK: - Qualification

    /// Check if a reminder qualifies for notification at all.
    /// Source == "message" must be reply-tagged. KB reminders always qualify.
    /// Must be within the configured window and not past due.
    private func isQualifiedForNotification(_ reminder: Reminder) -> Bool {
        // Must be enabled
        guard reminder.enabled else { return false }

        // Message reminders: only reply-tagged
        if reminder.source == "message" {
            guard reminder.action == "reply" else { return false }
        }

        // Must be within window
        guard isWithinWindow(reminder) else { return false }

        // If has due date, must not be past due (overdue handled separately in onForegroundReturn)
        if let dateTime = parseDueDateTime(reminder), dateTime < Date() {
            return false
        }

        return true
    }

    // MARK: - Validity Checks

    /// Check if a message-based reminder's message is still in inbox.
    private func isMessageStillInInbox(_ reminder: Reminder) async -> Bool {
        guard let messageId = reminder.messageId, !messageId.isEmpty else { return false }
        let header = try? await AppDatabase.dbPool.read { db in
            try MessageHeader.filter(Column("id") == messageId).fetchOne(db)
        }
        guard let header else { return false }
        return header.isInInbox
    }

    // MARK: - Delivered Notification Sync

    /// Sync delivered UNNotifications to ReachedOutStore. Covers the case where
    /// UNCalendarNotificationTrigger fired while the app was killed — iOS delivered
    /// the notification but our store doesn't know yet.
    private func syncDeliveredToStore() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        for notif in delivered {
            let info = notif.request.content.userInfo
            guard let hash = info["hash"] as? String else { continue }
            if !ReachedOutStore.hasNotified(hash: hash) {
                ReachedOutStore.markNotified(hash: hash)
            }
        }
    }

    // MARK: - Rate Limiting

    private func isRateLimited() -> Bool {
        guard let last = lastReachoutDate else { return false }
        return Date().timeIntervalSince(last) < Self.minIntervalSeconds
    }

    private func recordReachout() {
        lastReachoutDate = Date()
        UserDefaults.standard.set(lastReachoutDate, forKey: "proactive.last_reachout")
    }

    // MARK: - Helpers

    private func computeListHash(_ reminders: [Reminder]) -> String {
        let sorted = reminders.map(\.hash).sorted()
        return sorted.joined(separator: ",")
    }

    /// Check if a reminder's due date is within the configured window.
    private func isWithinWindow(_ reminder: Reminder) -> Bool {
        guard let dueDateStr = reminder.dueDate else { return true }
        guard let dueDate = parseDate(dueDateStr) else { return true }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dueMidnight = calendar.startOfDay(for: dueDate)
        let daysDiff = calendar.dateComponents([.day], from: today, to: dueMidnight).day ?? 0
        return daysDiff <= windowDays
    }

    /// Parse "YYYY-MM-DD" + optional "HH:MM" into a Date.
    private func parseDueDateTime(_ reminder: Reminder) -> Date? {
        guard let dueDateStr = reminder.dueDate, let date = parseDate(dueDateStr) else { return nil }
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        if let timeStr = reminder.dueTime {
            let timeParts = timeStr.split(separator: ":")
            if timeParts.count == 2, let hour = Int(timeParts[0]), let minute = Int(timeParts[1]) {
                components.hour = hour
                components.minute = minute
            }
        } else {
            components.hour = 9
            components.minute = 0
        }
        return calendar.date(from: components)
    }

    private func parseDate(_ str: String) -> Date? {
        let parts = str.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return Calendar.current.date(from: comps)
    }
}
