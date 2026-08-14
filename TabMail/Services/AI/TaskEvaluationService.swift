/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import UserNotifications

/// Thrown when a task execution exceeds the defensive timeout.
/// Not marked as fired — will retry on next evaluation cycle (e.g. BGProcessingTask).
struct TaskTimeoutError: Error {}

/// Evaluates task entries and fires them when due.
/// Port of TB's `_handleTaskEvaluation` / `_executeTask` in `proactiveCheckin.js`.
///
/// Architecture:
/// - Foreground timer fires every 5 minutes
/// - iOS pre-fire offset: T-3min (TB fires at T-5min for staggered execution)
/// - Cache probe: checks TaskExecutionCache first (TB may have already executed)
/// - If cache hit: reuse result (skip LLM call), still deliver notification
/// - If cache miss: execute agent via sendWithTools, cache result, deliver
/// - Both devices always notify independently (no notification suppression)
///
/// ADR-IOS-008: AI processing MUST exactly replicate TB addon architecture.
actor TaskEvaluationService {
    static let shared = TaskEvaluationService()

    private var loopTask: Task<Void, Never>?
    private var isEvaluating = false

    /// Evaluation interval (matches TB's TASK_EVAL_INTERVAL_MINUTES = 5)
    private static let evalIntervalSeconds: UInt64 = 5 * 60

    /// Backend prompt token for UNATTENDED task evaluation — a security boundary, not an alias for
    /// convenience. The backend keys per-prompt `allowed_tools` off this string, so this constant is
    /// what decides which tools an unattended run can reach. Named so the invariant is testable and so
    /// the interactive token cannot be substituted silently. See the use site.
    static let taskEvalSystemPrompt = "system_prompt_task_eval"

    // MARK: - Lifecycle

    /// Start the periodic task evaluation loop. Call on app foreground.
    func startTimer() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            // Fire immediately on start
            await self?.evaluate()
            // Then loop every 5 minutes
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.evalIntervalSeconds))
                guard !Task.isCancelled else { break }
                await self?.evaluate()
            }
        }
        print("[TaskEval] Evaluation loop started (every \(Self.evalIntervalSeconds)s)")
    }

    /// Stop the evaluation loop. Call on app background.
    func stopTimer() {
        loopTask?.cancel()
        loopTask = nil
        print("[TaskEval] Evaluation loop stopped")
    }

    // MARK: - Evaluation

    /// Evaluate all task entries and fire any that are due.
    /// Serialized: one task at a time for simplicity.
    func evaluate() async {
        guard !isEvaluating else {
            print("[TaskEval] Already evaluating, skipping")
            return
        }
        isEvaluating = true
        defer { isEvaluating = false }

        // Demo guard (ADR-IOS-038): tasks are a real-user feature. With the
        // demo prompt overlay active, kbTextSnapshot returns the DEMO KB (no
        // tasks) — running the loop would GC the user's task execution states
        // + cache against an empty active set (duplicate fires after exit).
        guard !DemoModeStore.isDemoActive else {
            print("[TaskEval] Skipped — demo mode active")
            return
        }

        // Check task.enabled setting (defaults to true if never set)
        let isEnabled = await MainActor.run {
            UserDefaults.standard.object(forKey: "task.enabled") == nil || UserDefaults.standard.bool(forKey: "task.enabled")
        }
        guard isEnabled else {
            print("[TaskEval] Task evaluation skipped (task.enabled=false)")
            return
        }

        // Parse tasks from KB
        let kbText = PromptStore.kbTextSnapshot()
        let tasks = KBTaskParser.parse(kbText)
        guard !tasks.isEmpty else { return }

        let disabledHashes = DisabledRemindersStore.getDisabledHashes()
        let activeTaskHashes = Set(tasks.map { KBTaskParser.taskHash($0) })

        for task in tasks {
            let hash = KBTaskParser.taskHash(task)
            let taskIsEnabled = !disabledHashes.contains(hash)
            let execState = await MainActor.run { TaskScheduler.getExecutionState(for: hash) }

            // Check for missed fires
            let missResult = TaskScheduler.detectMiss(task: task, taskHash: hash, executionState: execState)
            if missResult.missed, let missedDate = missResult.missedDate {
                await MainActor.run { TaskScheduler.markMissed(hash, date: missedDate) }
                print("[TaskEval] Task missed: \(hash) on \(missedDate)")
            }

            // Check if should fire
            let fireResult = TaskScheduler.shouldFire(task: task, taskHash: hash, isEnabled: taskIsEnabled, executionState: execState)
            guard fireResult.shouldFire else { continue }

            print("[TaskEval] Task firing: \(hash) (prefire=\(fireResult.isPrefire), oneOff=\(task.isOneOff))")

            // Get today's date in task's timezone for cache key
            let tz = task.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
            var tzCal = Calendar(identifier: .gregorian)
            tzCal.timeZone = tz
            let todayComps = tzCal.dateComponents([.year, .month, .day], from: Date())
            let today = String(format: "%04d-%02d-%02d", todayComps.year!, todayComps.month!, todayComps.day!)

            // Probe cache — another device (TB at T-5min) may have already executed
            let cached = await TaskExecutionCache.shared.getCachedResult(taskHash: hash, date: today)
            if let cached {
                print("[TaskEval] Task \(hash) has cached result from another device, delivering")
                await persistTaskSession(sessionId: cached.sessionId, userText: "", assistantText: cached.content, task: task)
                await deliverResult(task: task, hash: hash, content: cached.content, sessionId: cached.sessionId)
                await MainActor.run { TaskScheduler.markFired(hash, success: true) }
                // Auto-remove one-off tasks after successful fire
                if task.isOneOff {
                    await autoRemoveOneOffTask(task: task)
                }
                continue
            }

            // Execute the task with defensive timeout.
            // Silent push gives ~30s, BGProcessingTask gives minutes.
            // If we timeout, don't mark as fired — retry on next eval.
            do {
                let result = try await withTimeout(seconds: 24) {
                    try await self.executeTask(task: task, hash: hash)
                }
                if let result {
                    await TaskExecutionCache.shared.setCachedResult(
                        taskHash: hash, date: today, content: result.content, sessionId: result.sessionId
                    )
                    await deliverResult(task: task, hash: hash, content: result.content, sessionId: result.sessionId)
                await MainActor.run { TaskScheduler.markFired(hash, success: true) }

                    // Broadcast cache via Device Sync
                    await MainActor.run {
                        DeviceSyncService.shared.debouncedBroadcast(fields: [.taskCache])
                    }

                    // Auto-remove one-off tasks after successful fire
                    if task.isOneOff {
                        await autoRemoveOneOffTask(task: task)
                    }
                } else {
                    await MainActor.run { TaskScheduler.markFired(hash, success: false) }
                }
            } catch is TaskTimeoutError {
                // Timeout — mark as failed (increments consecutiveErrors).
                // After 3 consecutive timeouts, shouldFire skips it to prevent infinite retries.
                await MainActor.run { TaskScheduler.markFired(hash, success: false) }
                print("[TaskEval] Task \(hash) timed out (24s) — errors=\(((await MainActor.run { TaskScheduler.getExecutionState(for: hash) })?.consecutiveErrors ?? 0))")
                // Schedule BGProcessingTask as fallback (has more time)
                await MainActor.run { SyncScheduler.shared.scheduleBackgroundProcessing() }
            } catch {
                print("[TaskEval] Task execution failed for \(hash): \(error)")
                if case BackendError.requestFailed(statusCode: 402) = error {
                    print("[TaskEval] Quota exhausted, will retry at next scheduled time")
                } else {
                    await MainActor.run { TaskScheduler.markFired(hash, success: false) }
                }
            }
        }

        // GC orphaned execution states and cache
        await MainActor.run { TaskScheduler.gcOrphanedStates(activeTaskHashes: activeTaskHashes) }
        await TaskExecutionCache.shared.gcOrphanedEntries(activeTaskHashes: activeTaskHashes)

        // Periodic alarm re-registration (refreshes push worker TTL and catches
        // any tasks that were added/modified since last registration)
        await registerAlarmsWithPushWorker()
    }

    // MARK: - Agent Invocation

    /// Execute a task by invoking the agent with the task instruction.
    /// Builds the full agent system prompt (same as normal chat) and sends
    /// the task instruction as a user message. Multi-turn tool execution
    /// is handled by sendWithTools.
    private func executeTask(task: KBTaskEntry, hash: String) async throws -> (content: String, sessionId: String)? {
        let tz = task.timezone.flatMap(TimeZone.init(identifier:)) ?? .current

        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = tz
        dateFormatter.dateFormat = "h:mm a"
        let timeStr = dateFormatter.string(from: Date())
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        let dateStr = dateFormatter.string(from: Date())

        var userText = "It is now \(timeStr), \(dateStr). I previously scheduled this task to run at this time: \"\(task.instruction)\" Execute and respond."

        // Include missed fire note if applicable
        let execState = await MainActor.run { TaskScheduler.getExecutionState(for: hash) }
        if let missed = execState?.lastMissed {
            userText += "\nNote: A previous run was missed on \(missed) (device was not available). Please include anything that would have been covered."
            await MainActor.run { TaskScheduler.consumeMissed(hash) }
        }

        let sessionId = "task:\(hash)"
        print("[TaskEval] Executing task \(hash): \"\(task.instruction.prefix(80))...\"")

        // Build system prompt — same as normal chat (AIService.sendChatMessage)
        let aiService = AIService.shared
        let userName = AIService.chatUserName()
        let kbText = PromptStore.kbTextSnapshot()
        let reminders = await ReminderBuilder.buildReminderList()
        let remindersJSON = reminders.isEmpty ? "" : await ReminderBuilder.formatRemindersJSON(reminders)

        // Unattended scheduled-task evaluation. The backend expands this token into the SAME agent
        // system prompt (it aliases the agent expander and shares its template, so they cannot drift)
        // but resolves it to a narrower allowed_tools list than interactive chat gets.
        //
        // ⚠️ SECURITY BOUNDARY — do not substitute the interactive token here. This path is unattended,
        // so it is scoped deliberately; widening it is a backend decision (systemPromptTiers.json),
        // never a token swap at this call site.
        //
        // ⚠️ DEPLOY ORDER: the backend must ship this token BEFORE this line does — its tier lookup
        // throws on an unknown token rather than failing closed, so a client that ships first breaks
        // task evaluation outright instead of degrading.
        let systemMessage = CompletionsMessage(
            role: "system",
            content: Self.taskEvalSystemPrompt,
            vars: [
                "user_name": .string(userName),
                "user_kb_content": .string(kbText),
                "user_reminders_json": .string(remindersJSON),
                "recent_chat_history": .string(""),
            ]
        )

        let userMessage = CompletionsMessage(
            role: "user",
            content: userText,
            vars: [:]
        )

        let response = try await aiService.sendWithTools(
            messages: [systemMessage, userMessage]
        )

        if let error = response.error {
            print("[TaskEval] Task \(hash) server error: \(error)")
            throw AIService.ChatError.serverError(error)
        }

        if let assistant = response.assistant, !assistant.isEmpty {
            print("[TaskEval] Task \(hash) executed successfully (\(assistant.count) chars)")

            // Persist as chat turns so the pill can load this session on tap
            await persistTaskSession(sessionId: sessionId, userText: userText, assistantText: assistant, task: task)

            return (content: assistant, sessionId: sessionId)
        }

        print("[TaskEval] Task \(hash) returned no assistant response")
        return nil
    }

    /// Save task execution result as an assistant-only chat turn in GRDB.
    /// The synthetic user message ("It is now...") is NOT persisted — the user didn't
    /// type it, so it shouldn't appear as a user bubble. Only the agent's response
    /// is visible, matching TB's approach (session_break + task_result).
    /// This allows the chat pill to load the session when the user taps
    /// the notification deep link (PendingDeepLink.taskResult).
    private func persistTaskSession(sessionId: String, userText: String, assistantText: String, task: KBTaskEntry) async {
        let chatStore = ChatStore.shared
        let now = Date().timeIntervalSince1970 * 1000

        // Format with schedule label (matches TB's _deliverTaskResult format)
        let scheduleLabel: String
        if task.isOneOff, let date = task.scheduleDate {
            scheduleLabel = "\(date) at \(task.scheduleTime)"
        } else {
            scheduleLabel = "\(task.scheduleDays ?? "") at \(task.scheduleTime)"
        }
        let formattedContent = "**Scheduled Task** _(\(scheduleLabel))_\n\n\(assistantText)"

        let taskTurn = ChatTurn(
            id: ChatTurn.generateId(),
            timestamp: now,
            role: "assistant",
            content: formattedContent,
            userMessage: nil,
            type: "task_result",
            chars: formattedContent.count,
            renderedContent: formattedContent,
            sessionId: sessionId,
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )

        do {
            _ = try await chatStore.appendTurn(taskTurn)

            // Verify the turn was actually persisted
            let verifySession = try? await chatStore.loadContextSession(sessionId: sessionId)
            let turnCount = verifySession?.turns.count ?? 0
            print("[TaskEval] Persisted task session \(sessionId) — verified \(turnCount) turn(s) in GRDB")

            if turnCount == 0 {
                print("[TaskEval] WARNING: appendTurn succeeded but loadContextSession found 0 turns for \(sessionId)")
            }

            // Force the chat pill to reload sessions from GRDB
            await MainActor.run {
                ChatPillState.shared.session(for: "inbox").hasLoadedHistory = false
                NotificationCenter.default.post(name: .remindersDidChange, object: nil)
            }
        } catch {
            print("[TaskEval] FAILED to persist task session: \(error)")
        }
    }

    // MARK: - Markdown Stripping

    /// Strip markdown formatting from text for plain-text notifications.
    private static func stripMarkdown(_ text: String) -> String {
        var result = text
        // Bold: **text** or __text__
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "__(.+?)__", with: "$1", options: .regularExpression)
        // Italic: *text* or _text_
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<![\\w])_(.+?)_(?![\\w])", with: "$1", options: .regularExpression)
        // Headers: # text
        result = result.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        // Bullet lists: - text or * text (multiline via \n prefix)
        result = result.replacingOccurrences(of: "(?:^|\\n)[\\-\\*]\\s+", with: "\n• ", options: .regularExpression)
        // Links: [text](url)
        result = result.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
        // Collapse multiple newlines
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - One-Off Task Auto-Removal

    /// Auto-remove a one-off task from KB after successful fire.
    private func autoRemoveOneOffTask(task: KBTaskEntry) async {
        let current = PromptStore.kbTextSnapshot()

        // Extract the raw statement (without leading "- ")
        let statement = task.rawLine.replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)

        let patchText = "DEL\n\(statement)"
        guard let updated = KBPatchApplier.applyKBPatch(content: current, patchText: patchText),
              updated != current else {
            print("[TaskEval] Failed to auto-remove one-off task: \(task.rawLine.prefix(80))")
            return
        }

        await MainActor.run { PromptStore.shared.rawKB = updated }
        print("[TaskEval] Auto-removed one-off task after fire: \(task.instruction.prefix(80))")
    }

    // MARK: - Push Worker Alarm Registration

    /// Register task wake times with the push worker for background execution.
    /// Called on each foreground return to refresh the 48h TTL.
    /// The client computes absolute UTC wake times — the push worker is a dumb alarm clock.
    func registerAlarmsWithPushWorker() async {
        // Demo guard (ADR-IOS-038): the demo KB overlay would yield demo task
        // wake times (or none) — never touch the real user's push-worker alarm
        // registration from demo. TTL is 48h; a demo session won't outlast it.
        guard !DemoModeStore.isDemoActive else { return }
        let kbText = PromptStore.kbTextSnapshot()
        let tasks = KBTaskParser.parse(kbText)
        let disabledHashes = DisabledRemindersStore.getDisabledHashes()
        let enabledTasks = tasks.filter { !disabledHashes.contains(KBTaskParser.taskHash($0)) }

        guard !enabledTasks.isEmpty else { return }

        // Compute absolute UTC wake times for the next 48h
        var wakeTimes: [String] = []
        let now = Date()
        let cutoff = now.addingTimeInterval(48 * 3600)
        let prefireMinutes = await MainActor.run {
            let stored = UserDefaults.standard.integer(forKey: "task.advance_minutes")
            return stored > 0 ? stored : TaskScheduler.prefireOffsetMinutes
        }

        for task in enabledTasks {
            let tz = task.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
            guard let parsed = TaskScheduler.parseScheduleTime(task.scheduleTime) else { continue }

            var tzCalendar = Calendar(identifier: .gregorian)
            tzCalendar.timeZone = tz

            if task.isOneOff {
                // One-off: single wake time on the scheduled date
                guard let scheduleDate = task.scheduleDate else { continue }
                let dateParts = scheduleDate.split(separator: "/")
                guard dateParts.count == 3,
                      let year = Int(dateParts[0]),
                      let month = Int(dateParts[1]),
                      let day = Int(dateParts[2]) else { continue }
                var comps = DateComponents()
                comps.year = year
                comps.month = month
                comps.day = day
                comps.hour = parsed.hour
                comps.minute = parsed.minute
                comps.second = 0
                if let fireDate = tzCalendar.date(from: comps) {
                    let wakeDate = fireDate.addingTimeInterval(-Double(prefireMinutes * 60))
                    if wakeDate > now && wakeDate < cutoff {
                        wakeTimes.append(wakeDate.iso8601String())
                    }
                }
            } else {
                // Recurring: check each day in the next 48h
                guard let scheduleDays = task.scheduleDays else { continue }
                let scheduledDays = TaskScheduler.resolveScheduleDays(scheduleDays)

                var candidate = now
                while candidate < cutoff {
                    let weekday = tzCalendar.component(.weekday, from: candidate)
                    if scheduledDays.contains(weekday) {
                        // Build the fire time for this day in the task's timezone
                        var comps = tzCalendar.dateComponents([.year, .month, .day], from: candidate)
                        comps.hour = parsed.hour
                        comps.minute = parsed.minute
                        comps.second = 0
                        if let fireDate = tzCalendar.date(from: comps) {
                            // Apply pre-fire offset
                            let wakeDate = fireDate.addingTimeInterval(-Double(prefireMinutes * 60))
                            if wakeDate > now && wakeDate < cutoff {
                                wakeTimes.append(wakeDate.iso8601String())
                            }
                        }
                    }
                    // Move to next day
                    candidate = tzCalendar.date(byAdding: .day, value: 1, to: tzCalendar.startOfDay(for: candidate))!
                        .addingTimeInterval(3600) // avoid midnight edge — move to 1am
                }
            }
        }

        guard !wakeTimes.isEmpty else {
            print("[TaskEval] No upcoming wake times to register")
            return
        }

        // Send to push worker
        do {
            let deviceToken = UserDefaults.standard.string(forKey: PushConfig.lastDeviceTokenKey) ?? ""
            guard !deviceToken.isEmpty else {
                print("[TaskEval] No device token — skipping alarm registration")
                return
            }

            try await PushNotificationService.shared.pushClient.registerAlarms(
                deviceToken: deviceToken,
                wakeTimes: wakeTimes,
                apnsSandbox: PushConfig.isAPNsSandbox
            )
            print("[TaskEval] Registered \(wakeTimes.count) alarm wake times with push worker")
        } catch {
            print("[TaskEval] Failed to register alarms with push worker: \(error)")
        }
    }

    // MARK: - Result Delivery

    /// Deliver a task result as a local notification.
    /// If this is a pre-fire execution (before T+0), schedule the notification
    /// for the actual fire time so it appears on time. Otherwise fire immediately.
    private func deliverResult(task: KBTaskEntry, hash: String, content: String, sessionId: String) async {
        let scheduleLabel: String
        if task.isOneOff {
            scheduleLabel = "\(task.scheduleDate ?? "") at \(task.scheduleTime)"
        } else {
            scheduleLabel = "\(task.scheduleDays ?? "") at \(task.scheduleTime)"
        }

        // Strip markdown for notification body (notifications don't render markdown)
        let plainContent = Self.stripMarkdown(content)
        let truncated = plainContent.count > 256 ? String(plainContent.prefix(253)) + "..." : plainContent

        let notifContent = UNMutableNotificationContent()
        notifContent.title = "Scheduled Task"
        notifContent.subtitle = scheduleLabel
        notifContent.body = truncated
        notifContent.sound = .default
        notifContent.userInfo = [
            "hash": hash,
            "sessionId": sessionId,
            "source": "task",
        ]

        // Calculate trigger: if we're in pre-fire window (before scheduled time),
        // schedule for T+0. Otherwise fire immediately.
        var trigger: UNNotificationTrigger?
        if let parsed = TaskScheduler.parseScheduleTime(task.scheduleTime) {
            let tz = task.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
            var tzCal = Calendar(identifier: .gregorian)
            tzCal.timeZone = tz
            let nowComps = tzCal.dateComponents([.hour, .minute], from: Date())
            let nowMinutes = (nowComps.hour ?? 0) * 60 + (nowComps.minute ?? 0)
            let schedMinutes = parsed.hour * 60 + parsed.minute

            if nowMinutes < schedMinutes {
                // Pre-fire: schedule for T+0
                var fireComps = tzCal.dateComponents([.year, .month, .day], from: Date())
                fireComps.hour = parsed.hour
                fireComps.minute = parsed.minute
                fireComps.second = 0
                fireComps.timeZone = tz
                trigger = UNCalendarNotificationTrigger(dateMatching: fireComps, repeats: false)
                print("[TaskEval] Pre-scheduling notification for \(hash) at \(task.scheduleTime)")
            }
        }

        let request = UNNotificationRequest(
            identifier: "task-\(hash)-\(Date().timeIntervalSince1970)",
            content: notifContent,
            trigger: trigger // nil = fire immediately, UNCalendarNotificationTrigger = fire at T+0
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            print("[TaskEval] \(trigger == nil ? "Delivered" : "Scheduled") notification for \(hash)")
        } catch {
            print("[TaskEval] Failed to deliver notification for \(hash): \(error)")
        }
    }

    // MARK: - Timeout Helper

    /// Execute an async closure with a timeout. Throws TaskTimeoutError if exceeded.
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TaskTimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
