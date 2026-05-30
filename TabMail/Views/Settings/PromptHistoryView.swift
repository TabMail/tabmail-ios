/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct PromptHistoryView: View {
    @State private var entries: [PromptHistoryEntry] = []
    @State private var hasLoaded = false
    @State private var selectedEntry: PromptHistoryEntry?

    var body: some View {
        List {
            ForEach(entries) { entry in
                Button {
                    selectedEntry = entry
                } label: {
                    HistoryEntryRow(entry: entry)
                }
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .overlay {
            if entries.isEmpty && hasLoaded {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("History entries will appear here as you edit prompts, sync with your other devices, or reset settings.")
                )
            }
        }
        .navigationTitle("Sync History")
        .sheet(item: $selectedEntry) { entry in
            NavigationStack {
                PromptHistoryDetailView(
                    entry: entry,
                    afterState: afterState(for: entry),
                    onRestore: {
                        entries = PromptStore.shared.loadHistory().sorted(by: { $0.date > $1.date })
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            selectedEntry = nil
                        }
                    }
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            entries = PromptStore.shared.loadHistory().sorted(by: { $0.date > $1.date })
            hasLoaded = true
        }
    }

    /// The state AFTER this entry's event was applied.
    /// Entries are sorted newest-first. Each entry captures pre-event state.
    /// The next entry (idx-1, newer) captures post-event state.
    /// For the newest entry (idx 0), use the current live prompts.
    private func afterState(for entry: PromptHistoryEntry) -> PromptHistoryEntry {
        let store = PromptStore.shared
        if let idx = entries.firstIndex(where: { $0.id == entry.id }), idx > 0 {
            return entries[idx - 1]
        }
        // Newest entry — diff against current live state
        return PromptHistoryEntry(
            id: "live",
            timestamp: Date().iso8601String(),
            source: "live",
            fields: [],
            composition: store.rawComposition,
            action: store.rawAction,
            kb: store.rawKB,
            templatesJSON: {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return (try? String(data: encoder.encode(store.templates), encoding: .utf8)) ?? "[]"
            }()
        )
    }
}

// MARK: - History Entry Row

private struct HistoryEntryRow: View {
    let entry: PromptHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SourceBadge(source: entry.source)
                Spacer()
                Text(entry.date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.fields.map { fieldLabel($0) }.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func fieldLabel(_ field: String) -> String {
        switch field {
        case "composition": return "Composition"
        case "action": return "Action Rules"
        case "kb": return "Knowledge Base"
        case "templates": return "Templates"
        default: return field
        }
    }
}

// MARK: - Source Badge

private struct SourceBadge: View {
    let source: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var label: String {
        switch source {
        case "local_edit": return "Edit"
        case "reset": return "Reset"
        case "sync_receive": return "Sync"
        default: return source
        }
    }

    private var color: Color {
        switch source {
        case "local_edit": return .blue
        case "reset": return .red
        case "sync_receive": return .green
        default: return .secondary
        }
    }
}

// MARK: - Detail View

private struct PromptHistoryDetailView: View {
    let entry: PromptHistoryEntry
    /// The state AFTER this entry's event was applied (next snapshot, or live state for newest)
    let afterState: PromptHistoryEntry
    var onRestore: (() -> Void)?
    @State private var showRestoreConfirmation = false
    @State private var showFullView: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Group {
            Section("Metadata") {
                LabeledContent("Date") {
                    Text(formattedDate(entry.date))
                }
                LabeledContent("Source") {
                    SourceBadge(source: entry.source)
                }
                LabeledContent("Fields Changed") {
                    Text(entry.fields.map { fieldLabel($0) }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }

            if showField("composition") {
                diffSection(
                    field: "composition",
                    label: "Composition",
                    icon: "pencil.line",
                    beforeText: entry.composition,
                    afterText: afterState.composition
                )
            }

            if showField("action") {
                diffSection(
                    field: "action",
                    label: "Action Rules",
                    icon: "tag",
                    beforeText: entry.action,
                    afterText: afterState.action
                )
            }

            if showField("kb") {
                diffSection(
                    field: "kb",
                    label: "Knowledge Base",
                    icon: "book",
                    beforeText: entry.kb,
                    afterText: afterState.kb
                )
            }

            if showField("templates") {
                templatesSection
            }

            Section {
                Button("Restore to This State") {
                    showRestoreConfirmation = true
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.red)
            }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("History Detail")
        .confirmationDialog("Restore to this state?", isPresented: $showRestoreConfirmation) {
            Button("Restore", role: .destructive) {
                PromptStore.shared.restoreFromHistory(entry)
                onRestore?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will replace all your current prompts, rules, KB, and templates with the state from \(formattedDate(entry.date)).")
        }
    }

    private func showField(_ field: String) -> Bool {
        entry.fields.contains(field) || entry.source == "sync_receive" || entry.source == "reset"
    }

    // MARK: - Diff Section

    @ViewBuilder
    private func diffContentView(beforeText: String, afterText: String) -> some View {
        let diff = computeDiff(old: beforeText, new: afterText)
        if diff.isEmpty {
            if beforeText.isEmpty && afterText.isEmpty {
                Text("(empty)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(Array(diff.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Text(line.prefix)
                        .font(.subheadline.monospaced().weight(.bold))
                        .foregroundStyle(line.color)
                        .frame(width: 14, alignment: .center)
                    Text(line.text)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(line.color)
                }
                .listRowBackground(line.bgColor)
            }
        }
    }

    @ViewBuilder
    private func fullContentView(_ text: String) -> some View {
        let items = parseBulletItems(text)
        if items.isEmpty {
            Text("(empty)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.subheadline.monospaced())
            }
        }
    }

    @ViewBuilder
    private func diffSection(field: String, label: String, icon: String, beforeText: String, afterText: String) -> some View {
        Section {
            if showFullView.contains(field) {
                fullContentView(afterText)
            } else {
                diffContentView(beforeText: beforeText, afterText: afterText)
            }
        } header: {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                Button(showFullView.contains(field) ? "Diff" : "Full") {
                    if showFullView.contains(field) {
                        showFullView.remove(field)
                    } else {
                        showFullView.insert(field)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Templates Section

    @ViewBuilder
    private var templatesSection: some View {
        Section {
            let diff = computeTemplateDiff(old: entry.decodedTemplates, new: afterState.decodedTemplates)
            if diff.isEmpty {
                Text("No changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(diff.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 6) {
                        Text(line.prefix)
                            .font(.subheadline.monospaced().weight(.bold))
                            .foregroundStyle(line.color)
                            .frame(width: 14, alignment: .center)
                        Text(line.text)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(line.color)
                    }
                    .listRowBackground(line.bgColor)
                }
            }
        } header: {
            Label("Templates (\(entry.decodedTemplates.count))", systemImage: "doc.on.doc")
        }
    }

    // MARK: - Diff Computation

    private struct DiffLine {
        let prefix: String
        let text: String
        let color: Color
        let bgColor: Color
    }

    private func computeDiff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let newLines = new.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let oldSet = Set(oldLines)
        let newSet = Set(newLines)

        let removed = oldLines.filter { !newSet.contains($0) }
        let added = newLines.filter { !oldSet.contains($0) }

        if removed.isEmpty && added.isEmpty { return [] }

        var result: [DiffLine] = []
        for line in removed {
            let display = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            result.append(DiffLine(prefix: "−", text: display, color: .red, bgColor: .red.opacity(0.08)))
        }
        for line in added {
            let display = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            result.append(DiffLine(prefix: "+", text: display, color: .green, bgColor: .green.opacity(0.08)))
        }
        return result
    }

    private func computeTemplateDiff(old: [ReplyTemplate], new: [ReplyTemplate]) -> [DiffLine] {
        let oldNames = Set(old.filter { !$0.deleted }.map { $0.name })
        let newNames = Set(new.filter { !$0.deleted }.map { $0.name })
        let removed = old.filter { !$0.deleted && !newNames.contains($0.name) }
        let added = new.filter { !$0.deleted && !oldNames.contains($0.name) }

        if removed.isEmpty && added.isEmpty { return [] }

        var result: [DiffLine] = []
        for t in removed {
            result.append(DiffLine(prefix: "−", text: t.name, color: .red, bgColor: .red.opacity(0.08)))
        }
        for t in added {
            result.append(DiffLine(prefix: "+", text: t.name, color: .green, bgColor: .green.opacity(0.08)))
        }
        return result
    }

    // MARK: - Helpers

    private func parseBulletItems(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
    }

    private func fieldLabel(_ field: String) -> String {
        switch field {
        case "composition": return "Composition"
        case "action": return "Action Rules"
        case "kb": return "Knowledge Base"
        case "templates": return "Templates"
        default: return field
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
