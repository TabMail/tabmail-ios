/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Searchable chat history view.
///
/// v3: **single query path → memory.db only.** Both the default view and search
/// go through `MemoryIndex` (per-turn listing / per-turn hybrid search). The
/// chatHistory table is the authoritative write-side store; memory.db is derived
/// and rebuildable via Stage A. Users never see "empty state" on a rebuilt
/// memory.db — the brief catch-up window resolves in seconds.
///
/// See ADR-IOS-034.
struct ChatHistoryView: View {
    @State private var hits: [MemoryHit] = []
    @State private var searchText = ""
    @State private var searchResults: [MemoryHit]?
    @State private var searchTask: Task<Void, Never>?
    @State private var isLoading = true
    @State private var expandedId: String?

    /// Rows currently displayed (search mode preserves rank; default mode is
    /// reverse-chronological already from `MemoryIndex.listTurns`).
    private var displayedHits: [MemoryHit] {
        searchResults ?? hits
    }

    private var filteredExchanges: [ChatExchange] {
        buildExchanges(from: displayedHits)
    }

    /// Active search query for highlighting (trimmed, non-empty only).
    private var highlightQuery: String? {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? nil : q
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading chat history...")
            } else if hits.isEmpty && searchResults == nil {
                ContentUnavailableView("No Chat History", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Your conversations will appear here."))
            } else {
                List {
                    ForEach(filteredExchanges) { exchange in
                        VStack(alignment: .leading, spacing: 8) {
                            // User message (hidden for standalone assistant messages)
                            if !exchange.userText.isEmpty {
                                HStack(alignment: .top) {
                                    Image(systemName: "person.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        highlightedText(exchange.userText)
                                            .font(.subheadline)
                                            .lineLimit(expandedId == exchange.id ? nil : 3)
                                        Text(exchange.formattedDate)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            // Assistant response
                            HStack(alignment: .top) {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    highlightedText(exchange.assistantText)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(expandedId == exchange.id ? nil : 4)
                                    if exchange.userText.isEmpty {
                                        Text(exchange.formattedDate)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .reportConcern(contentType: .chatMessage, content: exchange.assistantText)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedId = expandedId == exchange.id ? nil : exchange.id
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteExchange(exchange)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.previewPaneBg)
        .navigationTitle("Chat History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search conversations")
        .onChange(of: searchText) { _, newQuery in
            searchTask?.cancel()
            if newQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults = nil
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                // Same memory.db hybrid pipeline the agent uses.
                let results = await MemoryIndex.shared.search(
                    query: newQuery,
                    limit: SearchConfig.memoryPrefetchMaxResults
                )
                guard !Task.isCancelled else { return }
                searchResults = results
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !hits.isEmpty {
                    Menu {
                        Section {
                            Text("\(hits.count) turns")
                            Text("\(filteredExchanges.count) exchanges")
                        }
                        Button(role: .destructive) {
                            clearHistory()
                        } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            await loadHistory()
        }
        .dismissKeyboardOnTap()
    }

    // MARK: - Search Highlighting

    /// Returns a Text view with search query matches highlighted.
    /// Falls back to plain Text when no active search.
    private func highlightedText(_ text: String) -> Text {
        guard let query = highlightQuery else {
            return Text(text)
        }

        // Build AttributedString with highlighted matches
        var attributed = AttributedString()
        var remaining = text[text.startIndex...]
        let queryLower = query.lowercased()

        while !remaining.isEmpty {
            let lowerRemaining = String(remaining).lowercased()
            if let range = lowerRemaining.range(of: queryLower) {
                let matchStart = remaining.index(remaining.startIndex, offsetBy: lowerRemaining.distance(from: lowerRemaining.startIndex, to: range.lowerBound))
                let matchEnd = remaining.index(remaining.startIndex, offsetBy: lowerRemaining.distance(from: lowerRemaining.startIndex, to: range.upperBound))

                // Text before match
                if matchStart > remaining.startIndex {
                    attributed.append(AttributedString(remaining[remaining.startIndex..<matchStart]))
                }
                // Highlighted match
                var match = AttributedString(remaining[matchStart..<matchEnd])
                match.foregroundColor = Theme.textPrimary
                match.inlinePresentationIntent = .stronglyEmphasized
                match.underlineStyle = .single
                attributed.append(match)

                remaining = remaining[matchEnd...]
            } else {
                // No more matches — append remainder
                attributed.append(AttributedString(remaining))
                break
            }
        }
        return Text(attributed)
    }

    // MARK: - Data Loading

    private func loadHistory() async {
        // Default view: reverse-chronological listing from memory.db.
        hits = await MemoryIndex.shared.listTurns(limit: SearchConfig.memoryPrefetchMaxResults)
        isLoading = false
    }

    private func deleteExchange(_ exchange: ChatExchange) {
        Task {
            do {
                try await ChatStore.shared.deleteHistoryTurns(ids: exchange.turnIds)
                hits.removeAll { exchange.turnIds.contains($0.chatHistoryId) }
                if let searchResults {
                    self.searchResults = searchResults.filter { !exchange.turnIds.contains($0.chatHistoryId) }
                }
            } catch {
                print("[ChatHistoryView] Failed to delete exchange: \(error)")
            }
        }
    }

    private func clearHistory() {
        Task {
            do {
                try await ChatStore.shared.clearAll()
                await ChatIdTranslator.shared.clearAll()
                hits = []
                searchResults = nil
            } catch {
                print("[ChatHistoryView] Failed to clear: \(error)")
            }
        }
    }

    // MARK: - Pill URL Stripping

    /// Strip markdown pill URLs for plain-text display in history view.
    /// Converts `[📧 Subject](tabmail://email/1)` → `📧 Subject`
    private static let pillURLPattern = /\[([^\]]+)\]\(tabmail:\/\/\w+\/\d+\)/

    private func stripPillURLs(_ text: String) -> String {
        var result = text
        while let match = result.firstMatch(of: Self.pillURLPattern) {
            result.replaceSubrange(match.range, with: String(match.1))
        }
        return result
    }

    // MARK: - Build exchanges (user+assistant pairs)

    /// Pair up per-turn hits into user+assistant exchanges for display.
    /// Input order matters — `listTurns` returns reverse-chronological, which we
    /// flip here so each exchange renders user-first/assistant-after. Search
    /// mode returns rank order; pairing still works row-by-row but won't enforce
    /// role adjacency (a lone user or assistant hit renders as a standalone row).
    private func buildExchanges(from inputs: [MemoryHit]) -> [ChatExchange] {
        // Default (list) mode: flip to chronological so user → assistant pairing holds.
        // Search mode: use rank order; pairing degrades gracefully to standalone rows.
        let ordered: [MemoryHit]
        if searchResults == nil {
            ordered = inputs.reversed()
        } else {
            // Search mode sorts by ascending dateMs for display adjacency so that
            // a session's multiple matching turns cluster together; rank order
            // across sessions is lost, but within-session turn order is natural.
            ordered = inputs.sorted { $0.dateMs < $1.dateMs }
        }

        var exchanges: [ChatExchange] = []
        var i = 0
        while i < ordered.count {
            let turn = ordered[i]
            if turn.role == "user" {
                let displayUser = stripPillURLs(turn.content)
                var assistantText = ""
                var ids = [turn.chatHistoryId]
                if i + 1 < ordered.count && ordered[i + 1].role == "assistant" {
                    assistantText = stripPillURLs(ordered[i + 1].content)
                    ids.append(ordered[i + 1].chatHistoryId)
                    i += 2
                } else {
                    i += 1
                }
                exchanges.append(ChatExchange(
                    id: turn.chatHistoryId,
                    turnIds: ids,
                    userText: displayUser,
                    assistantText: assistantText,
                    timestamp: Date(timeIntervalSince1970: Double(turn.dateMs) / 1000)
                ))
            } else if turn.role == "assistant" {
                let displayAssistant = stripPillURLs(turn.content)
                exchanges.append(ChatExchange(
                    id: turn.chatHistoryId,
                    turnIds: [turn.chatHistoryId],
                    userText: "",
                    assistantText: displayAssistant,
                    timestamp: Date(timeIntervalSince1970: Double(turn.dateMs) / 1000)
                ))
                i += 1
            } else {
                i += 1
            }
        }
        // Default mode: show newest first (reverse chronological).
        return searchResults == nil ? exchanges.reversed() : exchanges
    }
}

private struct ChatExchange: Identifiable {
    let id: String
    let turnIds: [String]  // IDs of all turns in this exchange (for deletion)
    let userText: String
    let assistantText: String
    let timestamp: Date

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    var formattedDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(timestamp) {
            return Self.timeFormatter.string(from: timestamp)
        } else if calendar.isDateInYesterday(timestamp) {
            return "Yesterday"
        } else {
            return Self.dateOnlyFormatter.string(from: timestamp)
        }
    }
}
