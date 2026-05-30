/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct ScheduledTasksSettingsView: View {
    @State private var tasks: [Reminder] = []
    @State private var isLoading = true

    var body: some View {
        Form {
            Group {
                Section {
                    Text("Scheduled tasks run automatically at their scheduled time. The agent reads your inbox, calendar, etc. and produces a dynamic response. Swipe left to delete.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    }
                } else if tasks.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            Text("No scheduled tasks")
                                .font(.subheadline)
                                .italic()
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    }
                } else {
                    Section("Scheduled Tasks") {
                        ForEach(tasks, id: \.hash) { task in
                            if let index = tasks.firstIndex(where: { $0.hash == task.hash }) {
                                TaskRow(task: task) { enabled in
                                    toggleTask(at: index, enabled: enabled)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteTask(at: index)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("Scheduled Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadTasks() }
        .task { await loadTasks() }
    }

    private func loadTasks() async {
        let allReminders = await ReminderBuilder.buildReminderList(includeDisabled: true)
        tasks = allReminders.filter { $0.type == "task" }
        isLoading = false
    }

    private func toggleTask(at index: Int, enabled: Bool) {
        let task = tasks[index]
        DisabledRemindersStore.setEnabled(hash: task.hash, enabled: enabled)
        tasks[index] = Reminder(
            type: task.type,
            content: task.content,
            dueDate: task.dueDate,
            dueTime: task.dueTime,
            source: task.source,
            hash: task.hash,
            enabled: enabled,
            action: task.action,
            messageId: task.messageId,
            uniqueId: task.uniqueId,
            subject: task.subject,
            from: task.from,
            instruction: task.instruction,
            scheduleDays: task.scheduleDays,
            scheduleDate: task.scheduleDate,
            scheduleTime: task.scheduleTime,
            timezone: task.timezone,
            rawLine: task.rawLine
        )
    }

    /// Permanently delete a [Task] entry by applying a DEL patch to the knowledge base text.
    private func deleteTask(at index: Int) {
        let task = tasks[index]
        guard task.type == "task", task.source == "kb" else { return }

        let current = PromptStore.shared.kbText()

        // Use rawLine for exact match — avoids ambiguity with duplicate instructions
        let statement: String
        if let rawLine = task.rawLine, !rawLine.isEmpty {
            statement = rawLine.replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)
        } else {
            // Fallback: search by content (legacy path)
            let lines = current.components(separatedBy: "\n")
            let taskPattern = /^(?:-\s*)?\[Task\]/.ignoresCase()
            let contentLower = task.content.lowercased()
            var found: String?
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.prefixMatch(of: taskPattern) != nil else { continue }
                if trimmed.lowercased().contains(contentLower) {
                    found = trimmed.replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)
                    break
                }
            }
            guard let f = found else {
                print("[ScheduledTasksSettings] KB line not found for task: \(task.content.prefix(80))")
                tasks.remove(at: index)
                return
            }
            statement = f
        }

        let patchText = "DEL\n\(statement)"
        guard let updated = KBPatchApplier.applyKBPatch(content: current, patchText: patchText),
              updated != current else {
            print("[ScheduledTasksSettings] KBPatchApplier DEL failed for task: \(statement.prefix(80))")
            return
        }

        PromptStore.shared.rawKB = updated
        tasks.remove(at: index)
        print("[ScheduledTasksSettings] Deleted task: \(statement.prefix(80))")
    }
}

// MARK: - Task Row

private struct TaskRow: View {
    let task: Reminder
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { task.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.instruction ?? task.content)
                    .font(.subheadline)

                // Schedule info
                HStack(spacing: 6) {
                    if task.isOneOff {
                        if let date = task.scheduleDate {
                            Text(formatOneOffDate(date, time: task.scheduleTime))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("(one-time)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if let days = task.scheduleDays, let time = task.scheduleTime {
                        Text(formatRecurringSchedule(days: days, time: time))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .opacity(task.enabled ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: task.enabled)
    }

    /// Format a one-off date like "March 28, 2026 at 15:00"
    private func formatOneOffDate(_ dateStr: String, time: String?) -> String {
        // dateStr is "YYYY/MM/DD"
        let parts = dateStr.split(separator: "/")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            let timeSuffix = time.map { " at \($0)" } ?? ""
            return "\(dateStr)\(timeSuffix)"
        }

        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        let calendar = Calendar.current
        guard let date = calendar.date(from: comps) else {
            let timeSuffix = time.map { " at \($0)" } ?? ""
            return "\(dateStr)\(timeSuffix)"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        let timeSuffix = time.map { " at \($0)" } ?? ""
        return "\(formatter.string(from: date))\(timeSuffix)"
    }

    /// Format recurring schedule like "Weekdays at 09:00"
    private func formatRecurringSchedule(days: String, time: String) -> String {
        // Capitalize first letter of days for display
        let capitalizedDays = days.prefix(1).uppercased() + days.dropFirst()
        return "\(capitalizedDays) at \(time)"
    }
}
