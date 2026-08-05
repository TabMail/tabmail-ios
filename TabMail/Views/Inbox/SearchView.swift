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
    /// Raised when a tapped LOCAL result's captured content witness no longer
    /// matches the row at its address, so `openResult` navigated nowhere. Without
    /// it the fail-closed refusal is an invisible dead tap.
    @State private var showStaleResultAlert = false
    @FocusState private var isFieldFocused: Bool

    private let manager = AccountManager.shared
    private let perAccountTimeout: Duration = .seconds(10)
    /// Remote search starts with this many days back
    private let initialWindowDays: Int = 30
    /// Each "load older" step goes this many more days back
    private let olderStepDays: Int = 60

    private var dbPool: PrioritizedDatabase { AppDatabase.dbPool }
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
            .navigationDestination(for: OpenTarget.self) { target in
                MessageDetailView(
                    messageId: target.headerId,
                    expectedRfc822MessageId: target.provenRfc822MessageId)
            }
        }
        .background(Palette.previewPaneBg)
        .interactiveDismissDisabled()
        .alert("Result no longer available", isPresented: $showStaleResultAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This message is no longer where the search found it. Search again to see what's there now.")
        }
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

    /// What a tap pushes onto the navigation path.
    ///
    /// 🚨 IT IS A PAIR, NOT A STRING, BECAUSE THE PROOF MUST TRAVEL WITH THE
    /// ADDRESS. `resolveLocalResultHeaderId` proves the row at `headerId` is still
    /// the message the tapped row rendered — and a bare
    /// `navigationPath.append(headerId)` then throws that proof away. What arrives
    /// at the other end is only an address, which `MessageDetailViewModel`
    /// re-resolves by primary key before `markReadOnOpenIfNeeded` durably marks it
    /// read. A UIDVALIDITY reset (purge-and-resync) or a sync merge landing in that
    /// window re-seats the address, and the read mutation lands on a message the
    /// user was never shown — the same C3 misattribution `IOS-SEARCH-001` names,
    /// one step further down the same path. Carrying the witness makes the detail
    /// view re-check the identity this view already proved, instead of trusting an
    /// address that had already been proved stale-able.
    ///
    /// `provenRfc822MessageId` is nil for a REMOTE result: that branch resolves a
    /// provider hit into a durable row and has no captured content witness to
    /// carry, so it keeps today's behaviour (fail open — see
    /// `ExpectedMessageIdentity`).
    struct OpenTarget: Hashable {
        let headerId: String
        let provenRfc822MessageId: String?
    }

    /// Resolve a REMOTE search result to a current durable headerId, folder-
    /// scoped so a colliding UID in another folder — or another account — can
    /// never be opened. Returns nil when no folder-native match exists; the
    /// caller then does not navigate, so nothing opens.
    ///
    /// `nonisolated static` on purpose: it touches no `@State` and needs no view,
    /// so a test can call it with a bare `Database`. The logic used to be inline
    /// in `openResult` and was therefore untestable.
    ///
    /// WHY FOLDER-SCOPED. A bare `(accountId, messageId)` match is an ADDRESS,
    /// not an identity: for IMAP `messageId` is the per-folder UID (see
    /// `IMAPFetchMapping.messageIdString`), so the same UID names DIFFERENT
    /// messages in different folders. Opening a row seeds
    /// `MessageDetailView`/`MessageDetailViewModel`, whose
    /// `markReadOnOpenIfNeeded` durably marks it read — so a wrong resolve is a
    /// wrong-message MUTATION (C3), not merely a wrong render. The guard is
    /// therefore fail-CLOSED: when identity cannot be established we resolve to
    /// nothing, never to a looser global match.
    ///
    /// 🚨 WHY IT TAKES `accountId`, NOT AN EMAIL ADDRESS (audit round 1 / C-3).
    /// This used to look the account up by `Account.emailAddress`, which is NOT a
    /// key: `Account.id` is a UUID and nothing stops the same address being added
    /// twice against different IMAP servers or credentials (a personal and a work
    /// mailbox behind the same alias, a migration in progress). The lookup returned
    /// whichever row `fetchOne` happened to pick, so a result found on account B
    /// resolved into account A's message at the same folder+UID — opened it and
    /// durably marked it read. The account identity travels with the result now
    /// (`SearchResult.accountId`), so no re-derivation from a non-unique attribute
    /// happens at tap time at all.
    ///
    /// Account-wide provider search passes `folderPath == ""` (Gmail/Graph, where
    /// `messageId` is already globally unique per account) and needs no folder
    /// constraint — the account constraint still applies. Mirrors the snippet
    /// lookup's own guard in `launchRemoteSearch` and the composite
    /// `SearchResult.id`.
    nonisolated static func resolveRemoteResultHeaderId(
        accountId: String, messageId: String, folderPath: String, db: Database
    ) throws -> String? {
        // An empty accountId is not an identity — it would drop the constraint's
        // meaning and match nothing useful, but state the refusal explicitly rather
        // than relying on the query.
        guard !accountId.isEmpty else { return nil }
        var request = MessageHeader
            .filter(Column("messageId") == messageId && Column("accountId") == accountId)
        if !folderPath.isEmpty {
            request = request.filter(Column("folderPath") == folderPath)
        }
        return try request.fetchOne(db)?.id
    }

    /// Resolve a LOCAL search result to the headerId it may be opened at — or `nil`
    /// when the row now living at that address is provably NOT the message the
    /// tapped row rendered.
    ///
    /// 🚨 WHY THIS EXISTS, AND WHY THE REMOTE HELPER ABOVE COULD NOT BE REUSED.
    /// `resolveRemoteResultHeaderId` filters `messageId == … && accountId == …`
    /// (+ `folderPath`) and returns the matched row's `.id` — but `MessageHeader.id`
    /// IS that same composite `accountId:folderPath:messageId`. It therefore
    /// resolves *by* an address and returns *that same address*: it establishes
    /// EXISTENCE, not IDENTITY, and against a re-seated address it hands back
    /// exactly the wrong row a bare `navigationPath.append(result.headerId!)`
    /// would. Routing the local branch through it would look like a C3 closure
    /// while closing nothing. The missing instrument is a CONTENT witness, which
    /// only a local result can carry (`SearchResult.capturedRfc822MessageId`).
    ///
    /// THE PREDICATE IS A PORT, NOT AN INVENTION. It is `AIWriteTarget
    /// .resolveCurrentHeader` **arm 6** (`AccountManagerAI.swift`) — "captured
    /// `rfc822MessageId` non-empty and EQUAL to the current row's ⇒ this is still
    /// the same physical message" — applied to the other consumer of the identical
    /// question: *is the row at this captured address still the same message?* The
    /// normalizer is the tree's single identity-COMPARISON normalizer,
    /// `MessageIdentity.comparableRfc822Identity`; no second one is minted here.
    /// (Arm 6 compares the column raw because both of its sides are read from the
    /// same column moments apart. Here the captured side has been sitting in a
    /// SwiftUI `@State` array across an arbitrary user pause, so it is normalized —
    /// which also classifies an unusable/garbage value as "no witness" instead of
    /// letting it fail the comparison and refuse a legitimate open.)
    ///
    /// ⚑ NOT AN ADR-IOS-068 / D4 VIOLATION — the direction is the opposite one. D4
    /// forbids an RFC 822 Message-ID SELECTING or AUTHORIZING a mutation target
    /// (and forbids a `SEARCH` result being one). Here the target is selected by
    /// the durable composite address exactly as before; the RFC id can only REFUSE
    /// that target, never widen it or nominate a different one. Using RFC identity
    /// as a content witness is the same architecturally-correct use the AI
    /// write-back, `MessageAICache`, the FTS/body stores and threading already make.
    ///
    /// Arms, in evaluation order:
    ///  1. **no usable captured witness** ⇒ return `headerId` unchanged. RFC-less
    ///     IMAP mail keeps today's behaviour exactly; it is the same population
    ///     `IOS-EPOCH-001` and `IOS-AI-003` already carry, and a
    ///     `(fromAddress, subject, date)` substitute is BANNED — that witness was
    ///     authored in `94fac3e79` and reverted in `3bd9f0bac` as unsound in both
    ///     directions.
    ///  2. **row gone** ⇒ `nil`. Fail closed. Recoverable by one ordinary gesture:
    ///     re-running the search rebuilds `results` from live rows.
    ///  3. **witnesses disagree** ⇒ `nil`. This is the C3 case: a different
    ///     physical message occupies the captured address. A row's
    ///     `rfc822MessageId` is never nulled once set (unlike `observedUidValidity`,
    ///     which 15 production sites clear), so a captured-present/current-absent
    ///     pair is a genuine disagreement, not an ordinary absence.
    ///
    /// `nonisolated static` for the same reason as the remote helper: it touches no
    /// `@State` and needs no view, so a test can call it with a bare `Database`.
    nonisolated static func resolveLocalResultHeaderId(
        headerId: String, capturedRfc822MessageId: String?, db: Database
    ) throws -> String? {
        // 1 — no content witness: today's behaviour, and no read at all.
        guard let captured = MessageIdentity.comparableRfc822Identity(capturedRfc822MessageId) else {
            return headerId
        }
        // 2 — the address no longer names a row.
        guard let current = try MessageHeader.fetchOne(db, key: headerId) else { return nil }
        // 3 — CONTENT PROOF. Same non-empty Message-ID at the same address ⇒ same
        //     email, whatever numbering seated it.
        guard MessageIdentity.comparableRfc822Identity(current.rfc822MessageId) == captured else {
            return nil
        }
        return headerId
    }

    private func openResult(_ result: SearchResult) {
        // Local result with headerId — the address is cached in an in-memory
        // `results` array that predates any re-seat, so prove the row still there
        // is the message this row RENDERED before opening (and durably marking) it.
        //
        // A6 (DB-performance lens): one `MessageHeader` fetch BY PRIMARY KEY, one
        // row, no scan — the same synchronous `dbPool.read` at the same call site
        // the remote branch below has always taken, and only on a tap.
        if let headerId = result.headerId {
            // A thrown read is not a verdict, but it is also not evidence, and this
            // navigation ends in a durable mark-read. Fail closed and let the user
            // re-tap; nothing is queued, so no intention is dropped.
            let resolved = try? dbPool.read { db in
                try Self.resolveLocalResultHeaderId(
                    headerId: headerId,
                    capturedRfc822MessageId: result.capturedRfc822MessageId,
                    db: db
                )
            }
            if let opened = resolved {
                // Carry the witness this resolve just validated against — see
                // `OpenTarget`. The proof is worth nothing to the consumer that
                // actually mutates unless it travels with the address.
                navigationPath.append(OpenTarget(
                    headerId: opened,
                    provenRfc822MessageId: result.capturedRfc822MessageId))
            } else {
                showStaleResultAlert = true
            }
            return
        }
        // Remote result: resolve folder-scoped; never a cross-folder/-account guess.
        // A nil resolve navigates nowhere — nothing opens, nothing is marked read.
        let resolved = try? dbPool.read { db in
            try Self.resolveRemoteResultHeaderId(
                accountId: result.accountId,
                messageId: result.messageId,
                folderPath: result.folderPath,
                db: db
            )
        }
        if let headerId = resolved {
            navigationPath.append(OpenTarget(headerId: headerId, provenRfc822MessageId: nil))
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
            // Union, don't replace (ADR-IOS-007 graceful degradation): the
            // substring scan can still catch what token-based FTS misses — e.g.
            // a mid-fragment like "marc-sup" inside "dmarc-support", or content
            // beyond FTS's ranked cutoff. Show FTS's ranked hits first, then any
            // legacy hits FTS missed.
            let ftsIds = Set(searchResults.compactMap(\.headerId))
            let legacyExtras = results.filter { result in
                result.source == .local && (result.headerId.map { !ftsIds.contains($0) } ?? true)
            }
            let remoteResults = results.filter { $0.source == .remote }
            results = searchResults + legacyExtras + remoteResults
            if DebugModeManager.isLoggingEnabled() {
                print("[Search] debounce merge: fts=\(ftsResults.count) →searchResults=\(searchResults.count) +legacyExtras=\(legacyExtras.count) +remote=\(remoteResults.count) ⇒ results=\(results.count) query='\(trimmed.prefix(40))'")
            }
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
                        // C-3: the ACCOUNT ID, never the address. Two accounts may
                        // legitimately share one `emailAddress` (same alias, different
                        // servers or credentials), and matching on it collapsed their
                        // results into each other before the user ever tapped one.
                        let accountId = account.id
                        let remoteIds = Set(accountResults.map(\.messageId))
                        // Identifies a prior row that is the SAME message as one of this
                        // batch's results. messageId is only unique within (account, folder)
                        // for IMAP (per-folder UID), so per-folder searches must match the
                        // folder too. Provider account-wide searches use folderPath="" and a
                        // globally-unique messageId, so they match on messageId alone — which
                        // also collapses the local row (folderPath="INBOX") against the
                        // account-wide remote row (folderPath="").
                        let isSameMessage: (SearchResult) -> Bool = { r in
                            r.accountId == accountId
                                && remoteIds.contains(r.messageId)
                                && (folderPath.isEmpty || r.folderPath == folderPath)
                        }
                        // Preserve snippets from local results when remote has none.
                        let localSnippets = Dictionary(
                            results.filter { isSameMessage($0) && !$0.snippet.isEmpty }
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
                            var request = MessageHeader
                                .filter(needLookup.contains(Column("messageId")) && Column("accountId") == account.id)
                            // Per-folder IMAP search: constrain to the folder so a colliding
                            // UID in another folder can't lend its snippet. Account-wide
                            // search (folderPath="") needs no folder constraint.
                            if !folderPath.isEmpty {
                                request = request.filter(Column("folderPath") == folderPath)
                            }
                            let headers = try request.fetchAll(db)
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
                            return SearchResult(source: result.source, accountId: result.accountId,
                                accountEmail: result.accountEmail,
                                messageId: result.messageId, folderPath: result.folderPath,
                                subject: result.subject, from: result.from,
                                fromAddress: result.fromAddress, date: result.date, snippet: snippet,
                                isRead: result.isRead, isFlagged: result.isFlagged, headerId: result.headerId,
                                // Field-for-field rebuild: carry the content
                                // witness too. Nil for every result reaching here
                                // today (all remote), but a rebuild that silently
                                // drops a field is how a guard loses its evidence.
                                capturedRfc822MessageId: result.capturedRfc822MessageId)
                        }
                        var merged = results
                        // Replace only the prior rows that are the SAME message (account +
                        // folder + messageId). A bare-messageId removeAll would evict a
                        // different account's — or different IMAP folder's — colliding UID.
                        merged.removeAll(where: isSameMessage)
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
        // ⚠ Both heal lists are consumed by `SearchIndex` (content-key space) but
        // are populated from `MessageHeader.id` values — another E1 crossing.
        var staleCorrections: [(headerId: String, correctFolderId: String)] = []
        // Drift heal: stale FTS headerId → current GRDB id (+ folderId). The FTS
        // key embeds the folder ("accountId:folder:messageId"); a folder move
        // (Gmail archive/trash, any re-key) re-keys the GRDB header but can leave
        // the FTS entry pointing at a dead id. Re-keying here repairs the index
        // for EVERY consumer (search, AI, embeddings), not just this query.
        var rekeyHeals: [(old: String, new: String, newMessageId: String?, newFolderId: String)] = []

        // Diagnostics: count *why* FTS hits get dropped on the way to the UI.
        var droppedNoHeader = 0
        var droppedOutOfScope = 0
        var healedDrift = 0
        var noHeaderSamples: [String] = []
        let logging = DebugModeManager.isLoggingEnabled()
        let scope = activeFolderIds

        let results: [SearchResult] = ftsResults.compactMap { ftsResult in
            // 🚨 STAGE E1 — DAY-ONE BREAKAGE, already known to the plan.
            // `ftsResult.contentKey` addresses an FTS row; the very next line uses
            // it as a `messageHeader.id` primary key. Byte-identical today. At E1
            // every UID-addressed (IMAP/iCloud) hit misses this lookup and falls
            // into the drift-recovery branch below — which deliberately REFUSES
            // IMAP — so local search would silently return nothing for those
            // accounts. A content-key → header-id resolution must land first.
            let headerId = ftsResult.contentKey.rawValue
            // 1. Exact lookup by the FTS-stored id.
            var header = (try? dbPool.read { db in
                try MessageHeader.fetchOne(db, key: headerId)
            }).flatMap { $0 }
            var recovered = false

            // 2. Drift recovery: the id missed. The message likely changed folder
            //    (Gmail archive/trash) — GRDB re-keyed it, FTS kept the old id.
            //    Recover by (accountId, messageId), which is only safe where
            //    messageId is move-STABLE and globally unique: Gmail/Graph. IMAP's
            //    messageId is a per-folder UID that changes on move and repeats
            //    across folders, so a match could be a DIFFERENT message — skip it
            //    (the sync-side re-key + delta-sync source fix own IMAP).
            if header == nil {
                let accountId = String(headerId.prefix(while: { $0 != ":" }))
                let moved = (try? dbPool.read { db -> MessageHeader? in
                    guard let provider = try Account.fetchOne(db, key: accountId)?.provider,
                          provider == .gmail || provider == .outlook else { return nil }
                    let matches = try MessageHeader
                        .filter(Column("accountId") == accountId && Column("messageId") == ftsResult.messageId)
                        .fetchAll(db)
                    // Same Gmail message can live in several folders (INBOX + All
                    // Mail + labels); any is the same message. Prefer one in scope.
                    return matches.first(where: { h in scope.map { $0.contains(h.folderId) } ?? true }) ?? matches.first
                }).flatMap { $0 }
                if let moved, moved.id != headerId {
                    rekeyHeals.append((old: headerId, new: moved.id, newMessageId: moved.messageId, newFolderId: moved.folderId))
                    healedDrift += 1
                    header = moved
                    recovered = true
                }
            }

            guard let header else {
                droppedNoHeader += 1
                if logging && noHeaderSamples.count < 5 {
                    noHeaderSamples.append("ftsId=\(headerId) msgId=\(ftsResult.messageId)")
                }
                return nil
            }

            // Self-healing: check if GRDB folderId matches the active scope.
            // If the message moved out of the scoped folder, FTS is stale — exclude and correct.
            if let scopeIds = scope, !scopeIds.contains(header.folderId) {
                // Recovered hits re-key below (which also realigns folderId); don't
                // also queue a folderId-only fix against the about-to-be-replaced id.
                if !recovered {
                    staleCorrections.append((headerId: header.id, correctFolderId: header.folderId))
                }
                droppedOutOfScope += 1
                return nil
            }

            let accountEmail = (try? dbPool.read { db in
                try Account.fetchOne(db, key: header.accountId)
            })?.emailAddress ?? ""

            return SearchResult(
                source: .local,
                accountId: header.accountId,
                accountEmail: accountEmail,
                messageId: header.messageId,
                folderPath: header.folderPath,
                subject: header.subject,
                from: header.from,
                fromAddress: header.fromAddress,
                date: header.date,
                snippet: ftsResult.snippet.isEmpty ? header.snippet : ftsResult.snippet,
                isRead: header.isRead,
                isFlagged: header.isFlagged,
                headerId: header.id,
                // Content witness from the row this result is rendered FROM — the
                // same row `subject`/`from`/`date`/`isRead`/`isFlagged` above come
                // from, so zero extra I/O. `openResult` re-proves it at tap time.
                capturedRfc822MessageId: header.rfc822MessageId
            )
        }

        // Fire-and-forget: correct stale FTS folderIds so future searches are accurate
        if !staleCorrections.isEmpty {
            Task {
                for (headerId, correctFolderId) in staleCorrections {
                    try? await SearchIndex.shared.updateFolderIds(
                        contentKeys: [ContentKey(rawValue: headerId)], newFolderId: correctFolderId)
                }
            }
        }

        // Fire-and-forget: re-key drifted FTS entries to the current GRDB id so the
        // index self-repairs for all consumers. Re-key first, THEN realign the
        // scoping folderId (rekeyHeaders only moves the id, not meta.folderId).
        if !rekeyHeals.isEmpty {
            let heals = rekeyHeals
            Task {
                try? await SearchIndex.shared.rekeyHeaders(
                    heals.map { (oldKey: ContentKey(rawValue: $0.old), newKey: ContentKey(rawValue: $0.new),
                                 newMessageId: $0.newMessageId) })
                for heal in heals {
                    try? await SearchIndex.shared.updateFolderIds(
                        contentKeys: [ContentKey(rawValue: heal.new)], newFolderId: heal.newFolderId)
                }
            }
        }

        if DebugModeManager.isLoggingEnabled() {
            print("[Search] ftsResultsToSearchResults: in=\(ftsResults.count) out=\(results.count) healedDrift=\(healedDrift) droppedNoHeader=\(droppedNoHeader) droppedOutOfScope=\(droppedOutOfScope) scope=\(activeFolderIds == nil ? "ALL" : "\(activeFolderIds!.count) folders")")
            if !noHeaderSamples.isEmpty {
                print("[Search]   noHeader sample FTS headerIds: \(noHeaderSamples)")
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
                    accountId: msg.accountId,
                    accountEmail: accountEmails[msg.accountId] ?? "",
                    messageId: msg.messageId,
                    folderPath: msg.folderPath,
                    subject: msg.subject,
                    from: msg.from,
                    fromAddress: msg.fromAddress,
                    date: msg.date,
                    snippet: msg.snippet,
                    isRead: msg.isRead,
                    isFlagged: msg.isFlagged,
                    headerId: msg.id,
                    // Same row every other field above comes from — zero extra I/O.
                    capturedRfc822MessageId: msg.rfc822MessageId
                )
            }
    }

    // MARK: - Remote Search (per account, with timeout)

    @MainActor
    private func searchAccount(_ account: Account, folder: String, query: String, after: Date?, before: Date?) async -> [SearchResult] {
        let email = account.emailAddress
        // C-3: carry the account's real identity with every result it produces. The
        // address is display-only from here on; it is not a key and two accounts may
        // share one.
        let resultAccountId = account.id
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
                accountId: resultAccountId,
                accountEmail: email,
                messageId: info.messageId,
                // The folder this result was searched in. Empty for provider
                // account-wide search (Gmail/Graph), where `messageId` is already
                // globally unique. For IMAP this is the real folder path, which is
                // required to disambiguate per-folder UIDs that collide across folders.
                folderPath: folder,
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
        let screenshotAccountId = "screenshot-account"
        results = [
            SearchResult(source: .local, accountId: screenshotAccountId,
                         accountEmail: "alex@gmail.com", messageId: "msg008",
                         folderPath: "INBOX",
                         subject: "Re: Partnership Proposal — Next Steps", from: "Emily Torres",
                         fromAddress: "emily.torres@client.com", date: now.addingTimeInterval(-45 * 60),
                         snippet: "Thanks for the detailed proposal, Alex. Our team has reviewed it and we'd like to move forward with a pilot program...",
                         isRead: false, isFlagged: false, headerId: "screenshot-account:INBOX:msg008"),
            SearchResult(source: .local, accountId: screenshotAccountId,
                         accountEmail: "alex@gmail.com", messageId: "msg-old-1",
                         folderPath: "INBOX",
                         subject: "Partnership Proposal — Draft for Review", from: "Alex Morgan",
                         fromAddress: "alex@gmail.com", date: now.addingTimeInterval(-3 * 86400),
                         snippet: "Hi Emily, attached is the partnership proposal we discussed. The pilot would cover 3 enterprise accounts starting April...",
                         isRead: true, isFlagged: false, headerId: nil),
            SearchResult(source: .local, accountId: screenshotAccountId,
                         accountEmail: "alex@gmail.com", messageId: "msg-old-2",
                         folderPath: "INBOX",
                         subject: "Re: Partnership Discussion — Follow Up", from: "Emily Torres",
                         fromAddress: "emily.torres@client.com", date: now.addingTimeInterval(-5 * 86400),
                         snippet: "Great meeting today! I'll share the proposal with our leadership team and get back to you by end of week...",
                         isRead: true, isFlagged: true, headerId: nil),
            SearchResult(source: .local, accountId: screenshotAccountId,
                         accountEmail: "alex@gmail.com", messageId: "msg-old-3",
                         folderPath: "INBOX",
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

    /// Stable, content-derived identity. NEVER use a fresh `UUID()` here: the
    /// results array is rebuilt and re-sorted on every keystroke/FTS merge/remote
    /// merge, so a random id would change for the same message on each rebuild.
    /// SwiftUI's `List`/`ForEach` would then tear down and recycle row views with
    /// churning identities and render the wrong subject on a row (the row's bound
    /// data — used on tap — stays correct, so the message opens fine).
    ///
    /// `messageId` ALONE is not unique: for IMAP it is the per-folder UID (see
    /// `IMAPFetchMapping.messageIdString`), so two *different* messages in two
    /// folders of the same account share a UID. A search-all that hits several
    /// folders would then mint duplicate identities → wrong subjects again. The
    /// key must include the folder: `accountId + folderPath + messageId`
    /// mirrors the local headerId ("accountId:folderPath:messageId") and is the
    /// same composite dedup uses.
    ///
    /// 🚨 KEYED ON `accountId`, NOT `accountEmail` (audit round 1 / C-3). The
    /// address is not a key — two accounts may carry the same `emailAddress` on
    /// different servers or credentials — so keying on it collapsed two different
    /// accounts' results into ONE identity, both in this id and in
    /// `launchRemoteSearch`'s dedup, before the user ever tapped one.
    var id: String { "\(accountId)\u{1}\(folderPath)\u{1}\(messageId)" }
    let source: Source
    /// The owning `Account.id`. THE identity: threaded from the searched account
    /// (remote) or the header row (local) all the way to `openResult`, so the tap
    /// never has to re-derive an account from a non-unique attribute.
    let accountId: String
    /// Display only — the account's address as shown to the user. Never a key.
    let accountEmail: String
    let messageId: String
    /// Folder the result came from. Local: the message's GRDB `folderPath`.
    /// Remote: the folder searched (empty string for provider account-wide
    /// search, where `messageId` is already globally unique).
    let folderPath: String
    let subject: String
    let from: String
    let fromAddress: String
    let date: Date
    let snippet: String
    let isRead: Bool
    let isFlagged: Bool
    /// GRDB header ID (available for local results)
    let headerId: String?
    /// 🚨 THE CONTENT WITNESS — the RFC 2822 Message-ID of the row this result was
    /// RENDERED FROM, captured at search time. `nil` for remote results (there is
    /// no local row to capture from) and for `ScreenshotMode`'s seeded rows.
    ///
    /// `headerId` is an ADDRESS — `accountId:folderPath:messageId`, and on IMAP
    /// `messageId` IS the per-folder UID. An address can be RE-SEATED onto a
    /// different physical message (a `UIDVALIDITY` turnover purges and resyncs the
    /// folder, so UIDs restarting is the EXPECTED outcome; a sync merge can
    /// overwrite the row at a canonical address too). `results` is an in-memory
    /// array rendered BEFORE that happens, so a tap afterwards navigates to
    /// whatever now occupies the address — and `MessageDetailViewModel
    /// .markReadOnOpenIfNeeded` durably marks THAT row read. The user is shown X's
    /// subject/sender/snippet and Y is silently mutated: misattribution, which C3
    /// forbids as squarely as a wrong-message mutation.
    ///
    /// This field is what `resolveLocalResultHeaderId` compares against the row now
    /// living at `headerId`. It is populated from the header row the local search
    /// ALREADY reads (`ftsResultsToSearchResults`, `legacyLocalSearch` — both take
    /// `subject`/`from`/`date`/`isRead`/`isFlagged` from that same row), so it costs
    /// zero extra I/O.
    ///
    /// Declared last, and `var` with a default, so the synthesized memberwise
    /// initializer carries it as a trailing defaulted parameter — every existing
    /// `SearchResult(...)` call site stays byte-identical.
    var capturedRfc822MessageId: String? = nil
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
