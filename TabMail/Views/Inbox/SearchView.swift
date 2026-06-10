/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

struct SearchView: View {
    let folders: [Folder]
    let scopeTitle: String

    @Environment(\.dismiss) private var dismiss
    @Environment(NavigationStore.self) private var navigationStore
    @State private var query = ""
    @State private var searchAll = false
    @State private var results: [SearchResult] = []
    @State private var pendingAccounts: Int = 0
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?
    @State private var canLoadOlder = false
    @State private var isLoadingOlder = false
    /// Monotonic counter incremented on each query change. Remote search tasks capture
    /// this at launch and discard results if the generation no longer matches,
    /// preventing stale results from a previous query leaking into the current one.
    @State private var searchGeneration: Int = 0
    /// Current search window: remote search covers dates newer than this anchor
    @State private var searchAfter: Date?
    /// True once the user has submitted a remote search for the current query text.
    /// Lets a scope toggle re-run the remote search instead of requiring a re-submit.
    @State private var hasSubmittedRemote = false
    @State private var navigationPath = NavigationPath()
    @FocusState private var isFieldFocused: Bool

    private let manager = AccountManager.shared
    private let perAccountTimeout: Duration = .seconds(10)
    /// Remote search starts with this many days back
    private let initialWindowDays: Int = 30
    /// Each "load older" step goes this many more days back
    private let olderStepDays: Int = 60

    private var dbPool: DatabasePool { AppDatabase.dbPool }
    private var isSearching: Bool { pendingAccounts > 0 }

    /// Folder IDs for scoped search, or nil for search-all.
    private var activeFolderIds: [String]? {
        searchAll ? nil : folders.map(\.id)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                searchBar
                Divider()
                resultsBody
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        cancelAll()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .principal) {
                    Button {
                        cancelAll()
                        dismiss()
                    } label: {
                        Text("Search")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        searchAll.toggle()
                    } label: {
                        Text("\(Image(systemName: "globe")) All")
                            .foregroundStyle(searchAll ? Theme.accent : .secondary)
                    }
                    .popoverTip(SearchScopeTip())
                }
            }
            .navigationDestination(for: String.self) { messageId in
                MessageDetailView(messageId: messageId)
            }
        }
        .background(Palette.previewPaneBg)
        .interactiveDismissDisabled()
        .onAppear {
            if ScreenshotMode.isActive {
                seedScreenshotSearchResults()
            } else {
                isFieldFocused = true
            }
        }
        .onDisappear { cancelAll() }
        .onChange(of: query) { _, newValue in onQueryChanged(newValue) }
        .onChange(of: searchAll) { _, _ in onScopeChanged() }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search emails...", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isFieldFocused)
                .submitLabel(.search)
                .onSubmit { triggerRemoteSearch() }
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }
            if !query.isEmpty {
                Button {
                    cancelAll()
                    query = ""
                    results = []
                    hasSearched = false
                    canLoadOlder = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Results Body

    @ViewBuilder
    private var resultsBody: some View {
        if hasSearched && results.isEmpty && !isSearching {
            Spacer()
            ContentUnavailableView.search(text: query)
            Spacer()
        } else if !results.isEmpty {
            List {
                ForEach(results) { result in
                    Button {
                        isFieldFocused = false
                        openResult(result)
                    } label: {
                        SearchResultRow(result: result, query: query)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                // "Load older" row at bottom
                if canLoadOlder && !isLoadingOlder {
                    Button {
                        loadOlderResults()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Search older emails")
                                .font(.subheadline)
                                .foregroundStyle(Theme.accent)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if isLoadingOlder {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching older...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
        } else if !hasSearched {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(searchAll ? "Search across all accounts" : "Search in \(scopeTitle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        } else {
            Spacer()
        }
    }

    // MARK: - Navigation

    private func openResult(_ result: SearchResult) {
        // Local result with headerId — navigate directly
        if let headerId = result.headerId {
            navigationPath.append(headerId)
            return
        }
        // Remote result: look up by messageId + accountEmail via GRDB
        let msgId = result.messageId
        let email = result.accountEmail
        if let header = try? dbPool.read({ db in
            let account = try Account.filter(Column("emailAddress") == email).fetchOne(db)
            if let accountId = account?.id {
                return try MessageHeader.filter(Column("messageId") == msgId && Column("accountId") == accountId).fetchOne(db)
            }
            return try MessageHeader.filter(Column("messageId") == msgId).fetchOne(db)
        }) {
            navigationPath.append(header.id)
        }
    }

    // MARK: - Search Logic

    private func cancelAll() {
        debounceTask?.cancel()
        debounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        pendingAccounts = 0
    }

    /// Called on every keystroke in the query field.
    private func onQueryChanged(_ newValue: String) {
        if ScreenshotMode.isActive { return }
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)

        debounceTask?.cancel()
        searchTask?.cancel()
        pendingAccounts = 0
        searchGeneration += 1

        guard !trimmed.isEmpty else {
            results = []
            hasSearched = false
            canLoadOlder = false
            hasSubmittedRemote = false
            return
        }

        hasSearched = true
        canLoadOlder = false
        hasSubmittedRemote = false
        results = legacyLocalSearch(trimmed)

        // Typing only searches locally (FTS). Remote search fires on submit
        // (keyboard search key → triggerRemoteSearch) to avoid a network call
        // per keystroke.
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            let ftsResults = (try? await SearchIndex.shared.keywordSearch(
                query: trimmed, limit: SearchConfig.searchDefaultLimit,
                folderIds: activeFolderIds)) ?? []
            guard !Task.isCancelled else { return }

            let searchResults = ftsResultsToSearchResults(ftsResults)
            // Union, don't replace (ADR-IOS-007 graceful degradation): FTS misses
            // matches the substring scan catches — e.g. "dmarc-" mid-token inside
            // "noreply-dmarc-support@…" (tokenchars glue addresses into single
            // tokens; prefix queries only match from the token start). Show FTS's
            // ranked hits first, then any legacy hits FTS missed.
            let ftsIds = Set(searchResults.compactMap(\.headerId))
            let legacyExtras = results.filter { result in
                result.source == .local && (result.headerId.map { !ftsIds.contains($0) } ?? true)
            }
            let remoteResults = results.filter { $0.source == .remote }
            results = searchResults + legacyExtras + remoteResults
        }
    }

    /// Called when the scope toggle changes — re-runs the search with new scope.
    private func onScopeChanged() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let wasSubmitted = hasSubmittedRemote
        onQueryChanged(query)
        // Scope toggle is an explicit tap, not a keystroke: if the user already
        // submitted a remote search, re-run it against the new scope.
        if wasSubmitted { triggerRemoteSearch() }
    }

    /// Fire time-scoped remote search for the current query
    private func triggerRemoteSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        searchTask?.cancel()
        pendingAccounts = 0
        hasSearched = true
        hasSubmittedRemote = true
        // Invalidate any in-flight wave (re-submit of the same query would otherwise
        // share its generation, letting cancelled children corrupt pendingAccounts).
        searchGeneration += 1

        let after = Calendar.current.date(byAdding: .day, value: -initialWindowDays, to: Date())!
        searchAfter = after
        canLoadOlder = true
        isLoadingOlder = false

        launchRemoteSearch(query: query.trimmingCharacters(in: .whitespaces), after: after, before: nil)
    }

    /// Load older results beyond the current search window
    private func loadOlderResults() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let currentAfter = searchAfter else { return }

        isLoadingOlder = true
        let newAfter = Calendar.current.date(byAdding: .day, value: -olderStepDays, to: currentAfter)!
        let before = currentAfter
        searchAfter = newAfter

        launchRemoteSearch(query: query.trimmingCharacters(in: .whitespaces), after: newAfter, before: before)
    }

    private func launchRemoteSearch(query: String, after: Date?, before: Date?) {
        // Build (account, folderPath) pairs to search
        let searchFolders: [(Account, String)]
        if let folderIds = activeFolderIds {
            // Folder-scoped: search only the specified folders
            let folderSet = Set(folderIds)
            let matchedFolders = navigationStore.folders.filter { folderSet.contains($0.id) }
            let accountMap = Dictionary(uniqueKeysWithValues: navigationStore.accounts.map { ($0.id, $0) })
            searchFolders = matchedFolders.compactMap { folder in
                guard let account = accountMap[folder.accountId] else { return nil }
                return (account, folder.path)
            }
        } else {
            // Search all: API providers (Gmail/Graph) support account-wide search —
            // one call with folder="" covers everything (both APIs exclude
            // spam/trash by default). Per-folder fan-out there wasted calls and
            // tripped Graph's MailboxConcurrency throttle. IMAP has no
            // account-wide SEARCH, so it keeps the per-folder fan-out.
            let accountMap = Dictionary(uniqueKeysWithValues: navigationStore.accounts.map { ($0.id, $0) })
            let accountWide: [(Account, String)] = navigationStore.accounts
                .filter { $0.provider == .gmail || $0.provider == .outlook }
                .map { ($0, "") }
            let accountWideIds = Set(accountWide.map(\.0.id))
            let perFolder: [(Account, String)] = navigationStore.folders
                .filter { $0.role != .trash && $0.role != .spam && !accountWideIds.contains($0.accountId) }
                .compactMap { folder in
                    guard let account = accountMap[folder.accountId] else { return nil }
                    return (account, folder.path)
                }
            searchFolders = accountWide + perFolder
        }
        guard !searchFolders.isEmpty else { return }

        pendingAccounts += searchFolders.count
        let generation = searchGeneration

        // Cancelling searchTask (query change, dismiss, new submit) propagates to
        // every per-folder child. Cancelled or failed folder searches resolve as
        // empty results — whatever completed is merged. Children are unstructured
        // Tasks with manual cancellation propagation because the Swift 6
        // region-isolation checker rejects group.addTask closures capturing a
        // SwiftUI view ("pattern that the region-based isolation checker does not
        // understand").
        searchTask = Task {
            var children: [Task<Void, Never>] = []
            for pair in searchFolders {
                let account = pair.0
                let folderPath = pair.1
                children.append(Task { @MainActor in
                    let accountResults = await searchAccount(account, folder: folderPath, query: query, after: after, before: before)
                    guard searchGeneration == generation else { return }
                    if !accountResults.isEmpty {
                        let remoteIds = Set(accountResults.map(\.messageId))
                        // Preserve snippets from local results when remote has none
                        let localSnippets = Dictionary(
                            results.filter { remoteIds.contains($0.messageId) && !$0.snippet.isEmpty }
                                .map { ($0.messageId, $0.snippet) },
                            uniquingKeysWith: { first, _ in first }
                        )
                        // Batch the GRDB snippet lookup: all results in this block
                        // belong to `account`, so one async read covers every missing
                        // snippet (was 2 blocking reads per result on the main actor).
                        let needLookup = accountResults
                            .filter { $0.snippet.isEmpty && localSnippets[$0.messageId] == nil }
                            .map(\.messageId)
                        let dbSnippets: [String: String] = needLookup.isEmpty ? [:] : (try? await AppDatabase.dbPool.read { db in
                            let headers = try MessageHeader
                                .filter(needLookup.contains(Column("messageId")) && Column("accountId") == account.id)
                                .fetchAll(db)
                            return Dictionary(headers.map { ($0.messageId, $0.snippet) },
                                              uniquingKeysWith: { first, _ in first })
                        }) ?? [:]
                        // The async read suspended — re-check the wave is still current
                        // before merging (query may have changed mid-lookup).
                        guard searchGeneration == generation else { return }
                        let enriched: [SearchResult] = accountResults.map { result in
                            guard result.snippet.isEmpty else { return result }
                            // Try local snippet first, then the batched GRDB lookup
                            let snippet = localSnippets[result.messageId] ?? dbSnippets[result.messageId] ?? ""
                            guard !snippet.isEmpty else { return result }
                            return SearchResult(source: result.source, accountEmail: result.accountEmail,
                                messageId: result.messageId, subject: result.subject, from: result.from,
                                fromAddress: result.fromAddress, date: result.date, snippet: snippet,
                                isRead: result.isRead, isFlagged: result.isFlagged, headerId: result.headerId)
                        }
                        var merged = results
                        merged.removeAll { remoteIds.contains($0.messageId) }
                        merged.append(contentsOf: enriched)
                        merged.sort { $0.date > $1.date }
                        results = merged
                    }
                    pendingAccounts = max(0, pendingAccounts - 1)
                    if pendingAccounts == 0 {
                        isLoadingOlder = false
                    }
                })
            }
            let kids = children
            await withTaskCancellationHandler {
                for child in kids { await child.value }
            } onCancel: {
                for child in kids { child.cancel() }
            }
        }
    }

    // MARK: - Local Search (FTS5 hybrid, fallback to string matching)

    /// Convert FTS results to SearchResults by looking up headers from the main DB.
    /// Self-healing: if FTS returned a result whose folderId is stale (message moved),
    /// exclude it from results and correct the FTS entry in the background.
    private func ftsResultsToSearchResults(_ ftsResults: [FTSSearchResult]) -> [SearchResult] {
        var staleCorrections: [(headerId: String, correctFolderId: String)] = []

        let results: [SearchResult] = ftsResults.compactMap { ftsResult in
            let headerId = ftsResult.headerId
            guard let header = try? dbPool.read({ db in
                try MessageHeader.fetchOne(db, key: headerId)
            }) else { return nil }

            // Self-healing: check if GRDB folderId matches the active scope.
            // If the message moved out of the scoped folder, FTS is stale — exclude and correct.
            if let scopeIds = activeFolderIds, !scopeIds.contains(header.folderId) {
                staleCorrections.append((headerId: headerId, correctFolderId: header.folderId))
                return nil
            }

            let accountEmail = (try? dbPool.read { db in
                try Account.fetchOne(db, key: header.accountId)
            })?.emailAddress ?? ""

            return SearchResult(
                source: .local,
                accountEmail: accountEmail,
                messageId: header.messageId,
                subject: header.subject,
                from: header.from,
                fromAddress: header.fromAddress,
                date: header.date,
                snippet: ftsResult.snippet.isEmpty ? header.snippet : ftsResult.snippet,
                isRead: header.isRead,
                isFlagged: header.isFlagged,
                headerId: header.id
            )
        }

        // Fire-and-forget: correct stale FTS folderIds so future searches are accurate
        if !staleCorrections.isEmpty {
            Task {
                for (headerId, correctFolderId) in staleCorrections {
                    try? await SearchIndex.shared.updateFolderIds(headerIds: [headerId], newFolderId: correctFolderId)
                }
            }
        }

        return results
    }

    private func legacyLocalSearch(_ query: String) -> [SearchResult] {
        let folderIds = activeFolderIds

        // Bounded fetch — 200 most recent messages, with optional folder scope.
        guard let messages: [MessageHeader] = try? dbPool.read({ db in
            var request = MessageHeader.order(Column("date").desc).limit(200)
            if let ids = folderIds, !ids.isEmpty {
                request = request.filter(ids.contains(Column("folderId")))
            }
            return try request.fetchAll(db)
        }) else { return [] }

        let accountEmails: [String: String] = {
            guard let accounts = try? dbPool.read({ db in try Account.fetchAll(db) }) else { return [:] }
            return Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.emailAddress) })
        }()

        return messages
            .filter {
                $0.subject.localizedCaseInsensitiveContains(query) ||
                $0.from.localizedCaseInsensitiveContains(query) ||
                $0.fromAddress.localizedCaseInsensitiveContains(query) ||
                $0.snippet.localizedCaseInsensitiveContains(query)
            }
            .prefix(50)
            .map { msg in
                SearchResult(
                    source: .local,
                    accountEmail: accountEmails[msg.accountId] ?? "",
                    messageId: msg.messageId,
                    subject: msg.subject,
                    from: msg.from,
                    fromAddress: msg.fromAddress,
                    date: msg.date,
                    snippet: msg.snippet,
                    isRead: msg.isRead,
                    isFlagged: msg.isFlagged,
                    headerId: msg.id
                )
            }
    }

    // MARK: - Remote Search (per account, with timeout)

    @MainActor
    private func searchAccount(_ account: Account, folder: String, query: String, after: Date?, before: Date?) async -> [SearchResult] {
        let email = account.emailAddress
        let searchTask = Task { @MainActor in
            try await manager.search(query: query, account: account, folder: folder, after: after, before: before)
        }
        let timeoutTask = Task {
            try await Task.sleep(for: perAccountTimeout)
            searchTask.cancel()
        }
        defer { timeoutTask.cancel() }

        let infos: [MessageHeaderInfo]
        do {
            // Forward caller cancellation (query change, dismiss, new submit) into
            // the inner search task — a cancelled search resolves as empty results.
            infos = try await withTaskCancellationHandler {
                try await searchTask.value
            } onCancel: {
                searchTask.cancel()
            }
        } catch is CancellationError {
            print("[Search] Cancelled/timed out searching \(email) — treating as empty")
            return []
        } catch {
            print("[Search] Error searching \(email): \(error)")
            return []
        }

        if DebugModeManager.isLoggingEnabled() {
            print("[Search] \(email) \(folder.isEmpty ? "account-wide" : "folder=\(folder)") returned \(infos.count) results")
        }

        return infos.map { info in
            SearchResult(
                source: .remote,
                accountEmail: email,
                messageId: info.messageId,
                subject: info.subject,
                from: info.from,
                fromAddress: info.fromAddress,
                date: info.date,
                snippet: EmailFilter.cleanSnippet(info.snippet),
                isRead: info.isRead,
                isFlagged: info.isFlagged,
                headerId: nil
            )
        }
    }

    // MARK: - Screenshot Mode

    private func seedScreenshotSearchResults() {
        query = "partnership proposal"
        hasSearched = true
        let now = Date()
        results = [
            SearchResult(source: .local, accountEmail: "alex@gmail.com", messageId: "msg008",
                         subject: "Re: Partnership Proposal — Next Steps", from: "Emily Torres",
                         fromAddress: "emily.torres@client.com", date: now.addingTimeInterval(-45 * 60),
                         snippet: "Thanks for the detailed proposal, Alex. Our team has reviewed it and we'd like to move forward with a pilot program...",
                         isRead: false, isFlagged: false, headerId: "screenshot-account:INBOX:msg008"),
            SearchResult(source: .local, accountEmail: "alex@gmail.com", messageId: "msg-old-1",
                         subject: "Partnership Proposal — Draft for Review", from: "Alex Morgan",
                         fromAddress: "alex@gmail.com", date: now.addingTimeInterval(-3 * 86400),
                         snippet: "Hi Emily, attached is the partnership proposal we discussed. The pilot would cover 3 enterprise accounts starting April...",
                         isRead: true, isFlagged: false, headerId: nil),
            SearchResult(source: .local, accountEmail: "alex@gmail.com", messageId: "msg-old-2",
                         subject: "Re: Partnership Discussion — Follow Up", from: "Emily Torres",
                         fromAddress: "emily.torres@client.com", date: now.addingTimeInterval(-5 * 86400),
                         snippet: "Great meeting today! I'll share the proposal with our leadership team and get back to you by end of week...",
                         isRead: true, isFlagged: true, headerId: nil),
            SearchResult(source: .local, accountEmail: "alex@gmail.com", messageId: "msg-old-3",
                         subject: "Partnership Opportunity — Initial Inquiry", from: "Emily Torres",
                         fromAddress: "emily.torres@client.com", date: now.addingTimeInterval(-12 * 86400),
                         snippet: "Hi Alex, I came across TabMail and I think there's a great opportunity for our companies to partner...",
                         isRead: true, isFlagged: false, headerId: nil),
        ]
    }
}

// MARK: - Search Result Model

struct SearchResult: Identifiable {
    enum Source { case local, remote }

    let id = UUID()
    let source: Source
    let accountEmail: String
    let messageId: String
    let subject: String
    let from: String
    let fromAddress: String
    let date: Date
    let snippet: String
    let isRead: Bool
    let isFlagged: Bool
    /// GRDB header ID (available for local results)
    let headerId: String?
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let result: SearchResult
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                highlightedField(result.from, baseColor: result.isRead ? Theme.textRead : Theme.textUnread)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text(result.date.formattedForInbox())
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if result.isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.flagged)
                }
            }
            highlightedField(result.subject, baseColor: result.isRead ? Theme.textRead : Theme.textUnread)
                .font(.subheadline)
                .lineLimit(1)
            if !result.snippet.isEmpty {
                highlightedSnippet(result.snippet)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    /// Highlight query terms in a field (sender, subject) using case-insensitive matching.
    private func highlightedField(_ text: String, baseColor: Color) -> Text {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Strip field prefixes like "from:" or "subject:" for matching
        let rawTerms = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let terms = rawTerms.map { term -> String in
            if let colonIdx = term.firstIndex(of: ":") {
                return String(term[term.index(after: colonIdx)...])
            }
            return term
        }.filter { !$0.isEmpty }

        guard !terms.isEmpty else {
            return Text(text).foregroundColor(baseColor)
        }

        // Find all matching ranges
        var highlights = [Range<String.Index>]()
        for term in terms {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                highlights.append(range)
                searchStart = range.upperBound
            }
        }

        guard !highlights.isEmpty else {
            return Text(text).foregroundColor(baseColor)
        }

        // Sort and merge overlapping ranges
        let sorted = highlights.sorted { $0.lowerBound < $1.lowerBound }
        var merged = [sorted[0]]
        for range in sorted.dropFirst() {
            if range.lowerBound <= merged.last!.upperBound {
                let last = merged.removeLast()
                merged.append(last.lowerBound..<max(last.upperBound, range.upperBound))
            } else {
                merged.append(range)
            }
        }

        // Build attributed string (avoids deprecated Text '+' operator on iOS 26)
        var attrStr = AttributedString()
        var pos = text.startIndex
        for range in merged {
            if pos < range.lowerBound {
                var segment = AttributedString(text[pos..<range.lowerBound])
                segment.foregroundColor = baseColor
                attrStr.append(segment)
            }
            var highlight = AttributedString(text[range])
            highlight.inlinePresentationIntent = .stronglyEmphasized
            highlight.foregroundColor = Theme.accent
            attrStr.append(highlight)
            pos = range.upperBound
        }
        if pos < text.endIndex {
            var segment = AttributedString(text[pos..<text.endIndex])
            segment.foregroundColor = baseColor
            attrStr.append(segment)
        }
        return Text(attrStr)
    }

    /// Parse FTS5 snippet markers `[match]` into styled Text with bold + accent highlights.
    private func highlightedSnippet(_ snippet: String) -> Text {
        var result = AttributedString()
        var remaining = snippet[snippet.startIndex...]

        while let openIdx = remaining.firstIndex(of: "[") {
            // Text before the marker
            if openIdx > remaining.startIndex {
                var plain = AttributedString(remaining[remaining.startIndex..<openIdx])
                plain.foregroundColor = Theme.textSecondary
                result.append(plain)
            }
            let afterOpen = remaining.index(after: openIdx)
            if let closeIdx = remaining[afterOpen...].firstIndex(of: "]") {
                // Matched term — bold + accent
                var matched = AttributedString(remaining[afterOpen..<closeIdx])
                matched.inlinePresentationIntent = .stronglyEmphasized
                matched.foregroundColor = Theme.accent
                result.append(matched)
                remaining = remaining[remaining.index(after: closeIdx)...]
            } else {
                // No closing bracket — render rest as plain
                var rest = AttributedString(remaining[openIdx...])
                rest.foregroundColor = Theme.textSecondary
                result.append(rest)
                remaining = remaining[remaining.endIndex...]
            }
        }

        // Remaining text after last marker
        if !remaining.isEmpty {
            var rest = AttributedString(remaining)
            rest.foregroundColor = Theme.textSecondary
            result.append(rest)
        }

        return Text(result)
    }

}
