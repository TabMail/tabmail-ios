/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import TipKit

/// AI summary bubble displayed above the email body in MessageDetailView.
/// Matches Thunderbird addon's summaryBubble.js visual design.
/// Single expandable card with gradient-fade truncation on collapsed content.
struct SummaryBubbleView: View {
    let message: MessageHeader
    @State private var expanded = false
    @State private var failed = false
    @AppStorage(AIService.optOutAllAIKey, store: AIService.optOutStore) private var optOutAllAI = false
    @Environment(\.hasTabMailSession) private var hasTabMailSession

    /// Whether there's actual AI content to display (blurb is non-nil and non-empty sentinel).
    private var hasContent: Bool {
        guard let blurb = message.summaryBlurb else { return false }
        return !blurb.isEmpty
    }

    /// Whether at least one AI source (LLM backend or Device Sync) is enabled.
    /// When both are off, there's no way to get AI results — hide loading bubble.
    /// When in demo with AI declined, hide entirely
    /// regardless of pre-baked content.
    private var anyAISourceEnabled: Bool {
        let demoStore = DemoModeStore.shared
        if demoStore.isActive && !demoStore.aiEnabled { return false }
        return (!optOutAllAI || DeviceSyncService.shared.isAutoEnabled) && AISubscriptionGate.shared.isActive
    }

    /// Structural display branch for the bubble. Environment-driven empty-state
    /// sub-branches (loading / failed / nudge) are decided at render time and
    /// share the same `.empty` mode here.
    enum DisplayMode: Equatable {
        /// Suppressed entirely: demo with AI declined, or message not in inbox.
        case hidden
        /// Render the cached AI summary content bubble.
        case content
        /// Empty state — render loading / failed / nudge depending on environment.
        case empty
    }

    /// Pure decision for which structural branch to render. Inputs are the only
    /// state that drives the gate; environment-driven sub-branches are decided
    /// in `body` from this view's environment values.
    static func displayMode(
        isInInbox: Bool,
        summaryBlurb: String?,
        demoSuppressed: Bool
    ) -> DisplayMode {
        if demoSuppressed { return .hidden }
        // AI summary is inbox-scoped on both compute (AccountManagerAI.processOpenedMessage
        // guards on isInInbox) and display. Cached summaries / no-content stubs left on
        // MessageHeader rows from a prior inbox stay must not surface for non-inbox views
        // (e.g. opening a Sent/Archive/Trash message via search).
        if !isInInbox { return .hidden }
        if let blurb = summaryBlurb, !blurb.isEmpty { return .content }
        return .empty
    }

    var body: some View {
        let mode = Self.displayMode(
            isInInbox: message.isInInbox,
            summaryBlurb: message.summaryBlurb,
            demoSuppressed: DemoModeStore.shared.isActive && !DemoModeStore.shared.aiEnabled
        )
        switch mode {
        case .hidden:
            EmptyView()
        case .content:
            contentBubble
        case .empty:
            if !hasTabMailSession {
                nudgeBubble(text: "Sign in to enable AI features")
            } else if !AISubscriptionGate.shared.isActive {
                nudgeBubble(text: "Subscribe to enable AI features")
            } else if !anyAISourceEnabled {
                // AI opt-out with no Device Sync — hide entirely
            } else if failed {
                failedBubble
            } else {
                loadingBubble
                    .onReceive(NotificationCenter.default.publisher(for: .aiDidFailForMessage).receive(on: DispatchQueue.main).filter { $0.object as? String == message.id }) { _ in
                        failed = true
                    }
                    .task {
                        // Safety-net timeout: if no success or failure notification after 20s, assume failure.
                        try? await Task.sleep(for: .seconds(20))
                        if !Task.isCancelled {
                            failed = true
                        }
                    }
            }
        }
    }

    // MARK: - Content Bubble

    private var contentBubble: some View {
        let todos = parseTodos(message.summaryTodos)
        let blurb = message.summaryBlurb ?? ""

        return VStack(alignment: .leading, spacing: 6) {
            // AI header (matching suggested reply sparkle style)
            HStack(spacing: 4) {
                Image(systemName: "wand.and.sparkles")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                Text("AI Summary")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            // Todos section
            if let todos, !todos.isEmpty {
                todosSection(todos: todos)
            }

            // Summary section
            summarySection(blurb: blurb)

            // Reminder badge (expanded only)
            if expanded, let reminderDate = message.reminderDate {
                reminderBadge(date: reminderDate, time: message.reminderTime, content: message.reminderContent)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.accent.opacity(0.2), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            expanded.toggle()
        }
        .reportConcern(contentType: .summary, content: blurb)
        .popoverTip(SummaryBubbleTip(), arrowEdge: .bottom)
        .padding(.horizontal, 6)
    }

    // MARK: - Todos Section

    private func todosSection(todos: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Todos:")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)

            if expanded {
                // Full list
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, item in
                        bulletRow(item)
                    }
                }
                .padding(.leading, 4)
            } else {
                // Collapsed: first bullet fully visible, 2nd bullet fades from its first line
                VStack(alignment: .leading, spacing: 2) {
                    bulletRow(todos[0])
                    if todos.count > 1 {
                        bulletRow(todos[1])
                            .frame(maxHeight: 18, alignment: .top)
                            .clipped()
                            .mask(
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            )
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    private func bulletRow(_ item: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("•")
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
            Text(item)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    // MARK: - Summary Section

    private func summarySection(blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Summary:")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)

            if expanded {
                Text(blurb)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            } else {
                Text(blurb)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .mask(
                        VStack(spacing: 0) {
                            // First line: fully visible
                            Rectangle()
                            // Second line: fade out
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 18)
                        }
                    )
            }
        }
    }

    // MARK: - Nudge Bubble

    private func nudgeBubble(text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.accent.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 6)
    }

    // MARK: - Loading Bubble

    private var loadingBubble: some View {
        HStack(spacing: 4) {
            Image(systemName: "wand.and.sparkles")
                .font(.caption2)
                .foregroundStyle(Theme.accent)
            Text("Analyzing email…")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            ProgressView()
                .controlSize(.small)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.accent.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 6)
    }

    // MARK: - Failed Bubble

    private var failedBubble: some View {
        HStack(spacing: 4) {
            Image(systemName: "wand.and.sparkles")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            Text("Couldn't analyze email")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button {
                failed = false
                Task { await AccountManager.shared.processOpenedMessage(message) }
            } label: {
                Text("Retry")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.accent.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 6)
    }

    // MARK: - Reminder Badge

    private func reminderBadge(date: String, time: String?, content: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(Theme.accent)

            Text(date + (time.map { " at \($0)" } ?? ""))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(Theme.textPrimary)

            if let content, !content.isEmpty {
                Text("— \(content)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.top, 2)
    }

    // MARK: - Todo Parsing

    /// Parse summaryTodos string into individual items.
    /// Handles multiple formats: newline-separated, bullet-separated on a single line,
    /// numbered lists, and various bullet prefixes (•, -, *).
    private func parseTodos(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty else { return nil }

        // Split on any newline character (\n, \r\n, \r, Unicode line separators)
        var items = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // If we got a single item, the data might be bullet-separated on one line
        if items.count == 1 {
            let line = items[0]
            // Try splitting on " • " (common in Device Sync cached data)
            let bulletSplit = line.components(separatedBy: " • ")
            if bulletSplit.count > 1 {
                items = bulletSplit.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else {
                // Try splitting on "• " at word boundaries (items like "•item1 •item2")
                let parts = line.components(separatedBy: "•")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if parts.count > 1 {
                    items = parts
                }
            }
        }

        // Strip leading bullet/number prefixes from each item
        items = items.map { line in
            var trimmed = line
            for prefix in ["•", "-", "*"] {
                if trimmed.hasPrefix(prefix) {
                    trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
            }
            // Strip numbered prefixes: "1.", "2.", etc.
            if let dotIndex = trimmed.firstIndex(of: "."),
               dotIndex != trimmed.startIndex,
               trimmed[trimmed.startIndex..<dotIndex].allSatisfy(\.isNumber) {
                trimmed = String(trimmed[trimmed.index(after: dotIndex)...]).trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }
        .filter { !$0.isEmpty }

        return items.isEmpty ? nil : items
    }
}
