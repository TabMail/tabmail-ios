/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

/// A unified reminder from either message summaries, KB entries, or task entries.
struct Reminder: Sendable {
    let type: String       // "reminder" or "task"
    let content: String
    let dueDate: String?   // "YYYY-MM-DD"
    let dueTime: String?   // "HH:MM"
    let source: String     // "message" or "kb"
    let hash: String
    let enabled: Bool
    // Message-only fields:
    let action: String?
    let messageId: String?
    let uniqueId: String?
    let subject: String?
    let from: String?
    // Task-only fields:
    let instruction: String?
    let scheduleDays: String?
    let scheduleDate: String?   // "YYYY/MM/DD" — for one-off tasks
    let scheduleTime: String?
    let timezone: String?
    let rawLine: String?    // Full KB line for exact-match delete

    /// Whether this is a one-off task (has scheduleDate, no scheduleDays).
    var isOneOff: Bool { scheduleDate != nil && scheduleDays == nil }
}

/// Builds a combined reminder list from message-based and KB-based sources.
/// Port of TB's `reminderBuilder.js`.
/// ADR-IOS-008: AI processing MUST exactly replicate TB addon architecture.
enum ReminderBuilder {

    // MARK: - List Cache

    /// Cached full reminder list (includeDisabled=true). Nil means cache miss.
    private static let cachedList = Mutex<[Reminder]?>(nil)

    /// Invalidate all reminder caches (parser + list). Proactively rebuilds in background.
    /// Safe to call from any thread/actor — only does Mutex.withLock (O(1)) + Task creation.
    static func invalidateCache() {
        KBTaskParser.invalidateCache()
        KBReminderParser.invalidateCache()
        cachedList.withLock { $0 = nil }
        // DETACHED on purpose: this is a background cache refresh, so it must NOT
        // inherit the caller's context — priority, actor, or (critically) the
        // `@TaskLocal` DisabledRemindersStore test-defaults override. A plain `Task{}`
        // would inherit that override and run gcStaleEntries against a unit test's
        // ISOLATED defaults using the (empty) test GRDB, wiping the store mid-test
        // (epoch-zero-timestamped entries are >90d old → GC'd). Detached → the rebuild
        // reads the real `.standard` store, matching production (where the override is
        // always nil) and no longer racing/clobbering an isolated test store.
        #if DEBUG
        guard ReminderRebuildPolicy.hostDecision == .proactive else { return }
        #endif
        Task.detached { _ = await buildReminderList(includeDisabled: true) }
    }

    private static let didSetupInvalidation = Mutex(false)

    /// Wire up notification-based cache invalidation. Call once at app startup.
    /// Safe to call multiple times — observers are only registered once.
    static func setupCacheInvalidation() {
        guard !didSetupInvalidation.withLock({ let was = $0; $0 = true; return was }) else { return }
        let nc = NotificationCenter.default
        nc.addObserver(forName: .messageDataDidChange, object: nil, queue: nil) { _ in
            invalidateCache()
        }
        nc.addObserver(forName: .inboxDataDidChange, object: nil, queue: nil) { _ in
            invalidateCache()
        }
        nc.addObserver(forName: .remindersDidChange, object: nil, queue: nil) { _ in
            invalidateCache()
        }
    }

    // MARK: - Global Rate Limit

    /// Minimum interval between `getRandomReminders` calls (seconds).
    /// Prevents cascading Observable mutations during sync storms.
    private static let cooldownInterval: TimeInterval = 10
    @MainActor private static var lastRandomRemindersAt: Date = .distantPast
    @MainActor private static var lastRandomRemindersResult: [Reminder] = []

    // MARK: - Build

    /// Build combined reminder list from message summaries + KB entries.
    /// Returns cached result if available; rebuilds on cache miss.
    /// Matches TB's `buildReminderList()`.
    static func buildReminderList(includeDisabled: Bool = false) async -> [Reminder] {
        if let cached = cachedList.withLock({ $0 }) {
            return includeDisabled ? cached : cached.filter(\.enabled)
        }

        let result = await performBuild()
        cachedList.withLock { $0 = result }
        return includeDisabled ? result : result.filter(\.enabled)
    }

    /// The full build — GRDB query, KB parse, hashing, sort, GC. Called only on cache miss.
    ///
    /// Demo isolation (ADR-IOS-038): while demo mode is active, message
    /// reminders are scoped to the demo account and KB reminders/tasks come
    /// from the DEMO prompt overlay (kbTextSnapshot is demo-aware) — both
    /// directions: real reminders never surface in demo, demo reminders never
    /// surface for the user. The cache is invalidated on demo entry/exit via
    /// the `.remindersDidChange` posts in DemoModeService.
    private static func performBuild() async -> [Reminder] {
        print("[ReminderBuilder] Building complete reminder list...")

        let demoActive = await MainActor.run { DemoModeStore.shared.isActive }

        // Collect reminders from both sources. kbTextSnapshot is demo-aware
        // (PromptStore demo overlay): in demo it returns the demo KB, so
        // reminders the demo agent adds via reminder_add DO show as cards,
        // while the user's real KB reminders never do.
        let messageReminders = await collectMessageReminders(demoActive: demoActive)
        let kbText = PromptStore.kbTextSnapshot()
        let kbParsed = KBReminderParser.parse(kbText)
        var disabledHashes = DisabledRemindersStore.getDisabledHashes()

        print("[ReminderBuilder] Collected \(messageReminders.count) message reminders and \(kbParsed.count) KB reminders")

        // Convert KB reminders to unified Reminder type
        let kbReminders = kbParsed.map { kb -> Reminder in
            let hash = DisabledRemindersStore.hashReminder(source: "kb", content: kb.content, uniqueId: nil)
            return Reminder(
                type: "reminder",
                content: kb.content,
                dueDate: kb.dueDate,
                dueTime: kb.dueTime,
                source: "kb",
                hash: hash,
                enabled: !disabledHashes.contains(hash),
                action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil,
                instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil
            )
        }

        // Parse task entries from KB
        let taskParsed = KBTaskParser.parse(kbText)
        let taskReminders = taskParsed.map { task -> Reminder in
            let hash = KBTaskParser.taskHash(task)
            return Reminder(
                type: "task",
                content: task.instruction,
                dueDate: nil, dueTime: nil,
                source: "kb",
                hash: hash,
                enabled: !disabledHashes.contains(hash),
                action: nil, messageId: nil, uniqueId: nil, subject: nil, from: nil,
                instruction: task.instruction, scheduleDays: task.scheduleDays,
                scheduleDate: task.scheduleDate, scheduleTime: task.scheduleTime, timezone: task.timezone,
                rawLine: task.rawLine
            )
        }
        print("[ReminderBuilder] Parsed \(taskParsed.count) task entries")

        // Add hash + enabled to message reminders, migrating old hashes if needed
        let taggedMessageReminders = messageReminders.map { r -> Reminder in
            let hash = DisabledRemindersStore.hashReminder(source: "message", content: r.content, uniqueId: r.uniqueId, rfc822MessageId: r.rfc822MessageId)

            // Migrate old platform-specific hash → new shared hash
            if let rfc822 = r.rfc822MessageId, !rfc822.isEmpty, let uid = r.uniqueId {
                let oldHash = "m:\(uid)"
                if oldHash != hash && disabledHashes.contains(oldHash) {
                    let oldEntry = DisabledRemindersStore.getDisabledMap()[oldHash]
                    let isDisabled = !(oldEntry?.enabled ?? true)
                    DisabledRemindersStore.setEnabled(hash: hash, enabled: !isDisabled)
                    if isDisabled { disabledHashes.insert(hash) }
                    print("[ReminderBuilder] Migrated disabled hash: \(oldHash) → \(hash)")
                }
            }

            return Reminder(
                type: "reminder",
                content: r.content,
                dueDate: r.dueDate,
                dueTime: r.dueTime,
                source: "message",
                hash: hash,
                enabled: !disabledHashes.contains(hash),
                action: r.action,
                messageId: r.messageId,
                uniqueId: r.uniqueId,
                subject: r.subject,
                from: r.from,
                instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil
            )
        }

        var allReminders = taggedMessageReminders + kbReminders + taskReminders

        // One-time: auto-disable overdue reminders on first launch (v1.0.1).
        // Prevents a flood of overdue notifications for users with large inboxes.
        let didAutoDisable = autoDisableOverdueOnFirstLaunch(allReminders)
        if didAutoDisable {
            // Re-read disabled hashes — the array was built before auto-disable wrote entries
            let updatedDisabled = DisabledRemindersStore.getDisabledHashes()
            allReminders = allReminders.map { r in
                guard r.enabled, updatedDisabled.contains(r.hash) else { return r }
                return Reminder(
                    type: r.type, content: r.content, dueDate: r.dueDate, dueTime: r.dueTime,
                    source: r.source, hash: r.hash, enabled: false,
                    action: r.action, messageId: r.messageId, uniqueId: r.uniqueId,
                    subject: r.subject, from: r.from,
                    instruction: r.instruction, scheduleDays: r.scheduleDays,
                    scheduleDate: r.scheduleDate, scheduleTime: r.scheduleTime,
                    timezone: r.timezone, rawLine: r.rawLine
                )
            }
        }

        // Time-based GC of stale disabled entries (non-blocking)
        let freshHashes = Set(allReminders.map(\.hash))
        DisabledRemindersStore.gcStaleEntries(freshHashes: freshHashes)

        // Sort: regular reminders first (due-dated ascending, then undated), then tasks at end
        allReminders.sort { a, b in
            // Tasks sort after regular reminders
            if a.type == "task" && b.type != "task" { return false }
            if a.type != "task" && b.type == "task" { return true }

            // Items with due dates come first
            if a.dueDate != nil && b.dueDate == nil { return true }
            if a.dueDate == nil && b.dueDate != nil { return false }

            // Both have due dates — sort by date, then time
            if let aDate = a.dueDate, let bDate = b.dueDate {
                let dateCmp = aDate.compare(bDate)
                if dateCmp != .orderedSame { return dateCmp == .orderedAscending }
                // Same date — compare time (nil time sorts after specific time)
                if a.dueTime != nil && b.dueTime == nil { return true }
                if a.dueTime == nil && b.dueTime != nil { return false }
                if let aTime = a.dueTime, let bTime = b.dueTime {
                    return aTime < bTime
                }
            }

            return false
        }

        let disabledCount = allReminders.filter { !$0.enabled }.count
        var messageCount = 0, kbCount = 0, taskCount = 0
        for r in allReminders {
            if r.type == "task" { taskCount += 1 }
            else if r.source == "message" { messageCount += 1 }
            else if r.source == "kb" { kbCount += 1 }
        }
        print("[ReminderBuilder] Built reminder list: \(allReminders.count) total (\(messageCount) message + \(kbCount) KB + \(taskCount) task, \(disabledCount) disabled)")

        return allReminders
    }

    // MARK: - Format for System Prompt

    /// Format reminders as JSON for injection into the `chat_converse_reminders` template.
    /// Returns a JSON array string of `{content, dueDate, dueTime, source, ...}`.
    /// Translates `uniqueId` and `messageId` to numeric IDs via `ChatIdTranslator`
    /// (matching TB's `processToolResultTBtoLLM` on the reminder array).
    static func formatRemindersJSON(_ reminders: [Reminder]) async -> String {
        guard !reminders.isEmpty else { return "[]" }

        let translator = ChatIdTranslator.shared
        var items: [[String: Any]] = []
        for r in reminders {
            var dict: [String: Any] = [
                "content": r.content,
                "source": r.source,
                "type": r.type,
            ]
            if r.type == "task" {
                // Task-specific fields
                if let inst = r.instruction { dict["instruction"] = inst }
                if let sd = r.scheduleDays { dict["schedule"] = "\(sd) \(r.scheduleTime ?? "")" }
                if let tz = r.timezone { dict["timezone"] = tz }
            } else {
                // Reminder-specific fields
                if let d = r.dueDate { dict["dueDate"] = d }
                if let t = r.dueTime { dict["dueTime"] = t }
                if let s = r.subject { dict["subject"] = s }
                if let f = r.from { dict["from"] = f }
                if let a = r.action { dict["action"] = a }
                // Translate IDs to numeric (matching TB's processToolResultTBtoLLM)
                if let u = r.uniqueId {
                    dict["uniqueId"] = await translator.toNumericId(u)
                }
                if let m = r.messageId {
                    dict["messageId"] = await translator.toNumericId(m)
                }
            }
            items.append(dict)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    // MARK: - Urgency Check

    /// Whether a reminder is urgent (overdue, today, or tomorrow).
    /// Used for visual highlighting in reminder cards.
    static func isUrgent(_ reminder: Reminder) -> Bool {
        guard let dueDateStr = reminder.dueDate else { return false }
        let parts = dueDateStr.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return false }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let dueDate = calendar.date(from: comps) else { return false }
        let dueMidnight = calendar.startOfDay(for: dueDate)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        return dueMidnight <= today || dueMidnight == tomorrow
    }

    // MARK: - Random Reminders (due always shown + random fill)

    /// Get reminders for display:
    /// - Due (overdue + today + tomorrow) — always included, exempt from count limit
    /// - Others (upcoming + undated) — shuffled, fill remaining slots up to `count`
    /// Matches TB's `getRandomReminders()`.
    static func getRandomReminders(count: Int = 2, force: Bool = false) async -> [Reminder] {
        // Global rate limit: return cached result if called too soon
        let now = await MainActor.run { Date() }
        let elapsed = await MainActor.run { now.timeIntervalSince(lastRandomRemindersAt) }
        if !force && elapsed < cooldownInterval {
            let cached = await MainActor.run { lastRandomRemindersResult }
            if !cached.isEmpty {
                print("[ReminderBuilder] Skipped — cooldown (\(Int(elapsed))s < \(Int(cooldownInterval))s)")
                return cached
            }
        }
        let allRemindersRaw = await buildReminderList()
        // Filter out task entries — they're background tasks, not chat-display reminders
        let allReminders = allRemindersRaw.filter { $0.type != "task" }
        guard !allReminders.isEmpty else { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        var dueReminders: [Reminder] = []
        var otherReminders: [Reminder] = []

        for reminder in allReminders {
            if let dueDateStr = reminder.dueDate {
                let parts = dueDateStr.split(separator: "-")
                if parts.count == 3,
                   let year = Int(parts[0]),
                   let month = Int(parts[1]),
                   let day = Int(parts[2]) {
                    var comps = DateComponents()
                    comps.year = year
                    comps.month = month
                    comps.day = day
                    if let dueDate = calendar.date(from: comps) {
                        let dueMidnight = calendar.startOfDay(for: dueDate)
                        if dueMidnight <= today || dueMidnight == tomorrow {
                            dueReminders.append(reminder)
                            continue
                        }
                    }
                }
            }
            otherReminders.append(reminder)
        }

        // Due reminders always included (exempt from count)
        var selected = dueReminders

        // Fill remaining slots with shuffled others (upcoming + undated)
        let remainingSlots = count - selected.count
        if remainingSlots > 0 && !otherReminders.isEmpty {
            let shuffled = otherReminders.shuffled()
            let take = min(remainingSlots, shuffled.count)
            selected.append(contentsOf: shuffled.prefix(take))
        }

        print("[ReminderBuilder] Selected \(selected.count) reminders (\(dueReminders.count) due + \(selected.count - dueReminders.count) random) from \(allReminders.count) total")
        // Cache result and timestamp for cooldown
        await MainActor.run {
            lastRandomRemindersAt = Date()
            lastRandomRemindersResult = selected
        }
        return selected
    }

    // MARK: - Card Formatting

    /// Format a due date for reminder card display. Delegates to the shared
    /// `EmailNotificationBuilder.formatDueLabel` so reminder cards (main app)
    /// and local notifications (main app + NSE) produce byte-identical strings.
    static func formatDueLabelForCard(_ reminder: Reminder) -> String? {
        EmailNotificationBuilder.formatDueLabel(dueDate: reminder.dueDate, dueTime: reminder.dueTime)
    }

    // MARK: - First Launch Overdue Suppression

    private static let didAutoDisableKey = "didAutoDisableOverdueReminders"

    /// One-time: disable all reminders with due dates before `firstLaunchDate`.
    /// Only runs on fresh installs. Uses epoch-zero timestamps so Device Sync
    /// state (from TB or other devices) always wins in CRDT merge — if a TB user
    /// installs iOS, their synced reminder state overrides this suppression.
    /// Returns `true` if any reminders were disabled (caller must refresh enabled state).
    @discardableResult
    private static func autoDisableOverdueOnFirstLaunch(
        _ reminders: [Reminder],
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !defaults.bool(forKey: didAutoDisableKey) else { return false }
        guard let firstLaunchDate = defaults.object(forKey: "firstLaunchDate") as? Date else { return false }

        let calendar = Calendar.current
        let cutoff = calendar.startOfDay(for: firstLaunchDate)
        var hashesToDisable: [String] = []

        for reminder in reminders {
            guard reminder.enabled else { continue }
            guard let dueDateStr = reminder.dueDate else { continue }
            let parts = dueDateStr.split(separator: "-")
            guard parts.count == 3,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2]) else { continue }
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            guard let dueDate = calendar.date(from: comps) else { continue }
            let dueMidnight = calendar.startOfDay(for: dueDate)

            if dueMidnight < cutoff {
                hashesToDisable.append(reminder.hash)
            }
        }

        // Epoch-zero timestamps ensure Device Sync always overrides these entries
        DisabledRemindersStore.bulkDisableWithEpochZero(hashes: hashesToDisable)
        if !hashesToDisable.isEmpty {
            NotificationCenter.default.post(name: .remindersDidChange, object: nil)
        }

        defaults.set(true, forKey: didAutoDisableKey)
        print("[ReminderBuilder] First-launch overdue suppression: disabled \(hashesToDisable.count) reminders with due dates before \(cutoff)")
        return !hashesToDisable.isEmpty
    }

    /// Test-only entry point for `autoDisableOverdueOnFirstLaunch`.
    /// Allows unit tests to exercise the logic without going through `buildReminderList`.
    /// Pass an isolated `UserDefaults(suiteName:)` to keep test state off the shared domain.
    @discardableResult
    static func testAutoDisableOverdue(
        _ reminders: [Reminder],
        defaults: UserDefaults = .standard
    ) -> Bool {
        autoDisableOverdueOnFirstLaunch(reminders, defaults: defaults)
    }

    // MARK: - Message Reminder Collection

    /// Intermediate type for message reminders before hashing.
    private struct MessageReminderRaw {
        let content: String
        let dueDate: String?
        let dueTime: String?
        let action: String?
        let messageId: String?
        let uniqueId: String?
        let rfc822MessageId: String?
        let subject: String?
        let from: String?
    }

    /// Collect message reminders from GRDB inbox (messages with non-nil reminderContent).
    /// Matches TB's `collectMessageReminders()`.
    /// `demoActive` scopes by account: demo mode reads ONLY demo-seeded rows;
    /// normal mode excludes them (a stray demo row must never remind the user).
    /// This is an extra AND predicate on the existing reminder query, not a new
    /// scan — the accountId filter applies to rows the query already reads.
    private static func collectMessageReminders(demoActive: Bool) async -> [MessageReminderRaw] {
        do {
            let messages: [MessageHeader] = try await AppDatabase.dbPool.read { db in
                let accountScope = demoActive
                    ? Column("accountId") == DemoSeed.demoAccountId
                    : Column("accountId") != DemoSeed.demoAccountId
                return try MessageHeader
                    .filter(Column("isInInbox") == true)
                    .filter(Column("reminderContent") != nil)
                    .filter(Column("isReplied") == false)
                    .filter(accountScope)
                    .fetchAll(db)
            }

            var reminders: [MessageReminderRaw] = []
            for msg in messages {
                guard let content = msg.reminderContent,
                      !content.trimmingCharacters(in: .whitespaces).isEmpty else {
                    continue
                }

                reminders.append(MessageReminderRaw(
                    content: content.trimmingCharacters(in: .whitespaces),
                    dueDate: msg.reminderDate,
                    dueTime: msg.reminderTime,
                    action: msg.actionTag?.rawValue,
                    messageId: msg.id,
                    uniqueId: msg.id,
                    rfc822MessageId: msg.rfc822MessageId,
                    subject: msg.subject,
                    from: msg.from
                ))
            }

            print("[ReminderBuilder] Collected \(reminders.count) message reminders from \(messages.count) inbox messages with reminder content")
            return reminders
        } catch {
            print("[ReminderBuilder] Error collecting message reminders: \(error)")
            return []
        }
    }
}

#if DEBUG
/// DEBUG-only policy for the proactive reminder-cache warm-up. Ordinary unit-test
/// hosts still invalidate every cache, then build lazily when a test needs one.
/// Release retains the exact detached warm-up above without XCTest environment access.
enum ReminderRebuildPolicy {
    enum Decision: Equatable, Sendable {
        case skippedUnitTestHost
        case proactive
    }

    static func decision(environment: [String: String]) -> Decision {
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil {
            return .skippedUnitTestHost
        }
        return .proactive
    }

    /// Resolve once: invalidation is posted from many hot paths and must not
    /// rebuild `ProcessInfo.environment` for each cache clear.
    static let hostDecision = decision(environment: ProcessInfo.processInfo.environment)
}
#endif
