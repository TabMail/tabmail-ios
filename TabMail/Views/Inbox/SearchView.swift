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
    /// Raised when a tapped REMOTE result has no folder-native local row to open.
    /// Separate from `showStaleResultAlert` because the CAUSE is different and the
    /// copy must not lie: nothing here says the message is gone — only that this
    /// device holds no copy of it to open.
    @State private var showRemoteResultUnavailableAlert = false
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
        .alert("Not downloaded yet", isPresented: $showRemoteResultUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This result was found on the server, but the message isn't on this device yet, so there's nothing to open. Try again once this folder has finished syncing.")
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
    /// `provenRfc822MessageId` travels on BOTH branches. A local result captures it
    /// from the row it rendered; a REMOTE result carries the provider's own
    /// `MessageHeaderInfo.rfc822MessageId` for the record it rendered. It is nil
    /// only when there is genuinely no witness to carry — a provider that supplied
    /// no Message-ID, or `ScreenshotMode`'s seeded rows — and that population keeps
    /// today's behaviour (fail open — see `ExpectedMessageIdentity`).
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
    ///     which many production sites clear), so a captured-present/current-absent
    ///     pair is a genuine disagreement, not an ordinary absence. ⚠️ "never nulled
    ///     once set" is OVERSTATED — see the CORRECTED 2026-08-05 block below before
    ///     relying on it; the conclusion (refuse) is unchanged, the absoluteness is
    ///     not.
    ///
    ///     **THE COUNT, WITH ITS PREDICATE AND ITS MEMBERS — it said "15", then
    ///     "19", and both drifted. Enumerate, do not restate an integer**
    ///     (ADR-IOS-068 clause 5). The predicate is: *production Swift statements
    ///     (excluding `TabMailTests/`) that ASSIGN to
    ///     `MessageHeader.observedUidValidity`*, counting neither
    ///     stored-property declarations whose default is `nil`, nor reads or
    ///     comparisons, nor the same-named field on other types
    ///     (`PendingOperation`, `StagedInboxRow`, `MessageSnapshot`, the NSE's
    ///     `NSEMessageMetadata` / `nse_processed_message` staging column).
    ///
    ///     ⚠️ **"19" was reachable under NO single predicate** — it counted
    ///     `SyncEngineFullSync`'s ternary as a nil-write (inclusive) while
    ///     omitting `AccountManagerActions`' identically-shaped one (exclusive).
    ///     Applied uniformly the answer is 18 exclusive / 20 inclusive. The
    ///     census must also be `--multiline` with `\s*` at EVERY join: the
    ///     `AccountManagerActions` ternary wraps at `.set(` → `to:`, so
    ///     `\.set\(to:` misses it (MIS-007 instances 36–37).
    ///
    ///     **Writes ONLY `nil` — 18, by enclosing symbol:**
    ///     `AccountManagerActions.optimisticMoveToFolder` ×2 (its two `updateAll`
    ///     arms) · `AccountManagerActions.queueDraftSave` ×1 ·
    ///     `MessageHeaderRekey.finishMove` ×1 (its no-proven-epoch else arm) ·
    ///     `BackfillBodyQueue.rekeyRemappedHeader` ×1 ·
    ///     `SyncEngineDeltaSync.gmailDeltaSync` ×2 ·
    ///     `SyncEngineDeltaSync.exchangeDeltaSync` ×3 ·
    ///     `SyncEngineFullSync.canonicalizeLocalRows` ×2 ·
    ///     `SyncEngineFullSync.runSyncMessages` ×6.
    ///
    ///     **Writes `nil` OR an epoch, by a branch inside the statement — 2:**
    ///     `SyncEngineFullSync.runSyncMessages`'s
    ///     `recon.sourceAddressProven ? sourceBoundEpoch : nil` ·
    ///     `AccountManagerActions.exactPayload`'s
    ///     `restoreSourceEpoch ? member.sourceObservedUidValidity : nil`.
    ///
    ///     **Writes ONLY a proven epoch — 5:** `MessageHeaderRekey.finishMove` ·
    ///     `SyncEngine.fetchOlderMessages` ·
    ///     `SyncEngineBackfillDeep.insertBackfillBatchGuardable` ·
    ///     `SyncEngineFullSync.runSyncMessages` ×2 (the proven merge and the
    ///     insert). **TWO statements are in NEITHER class** — they copy whatever
    ///     the NSE staged, so the value's provenance is the staging row rather
    ///     than this pass: `NSEDataBridge.insertNewHeaderFromStaging` and
    ///     `StagedInboxRow.toMessageHeader`. Classified total: 18 + 2 + 5 + 2 = **27**.
    ///
    ///     ⚠️ **`StagedInboxRow.toMessageHeader` WAS MISSING FROM THIS CENSUS UNTIL
    ///     2026-08-06, AND THE EXCLUSION CLAUSE ABOVE IS WHY** — it lists
    ///     `StagedInboxRow` among the types carrying a *same-named field*, which is
    ///     correct as far as it goes and is not the shape of that statement.
    ///     `h.observedUidValidity = observedUidValidity` has a **`MessageHeader` on
    ///     the LEFT** and `StagedInboxRow`'s field only on the right, so it assigns
    ///     to `MessageHeader.observedUidValidity` and the predicate claims it.
    ///     **THE INVARIANT, so the next reader does not need this instance:** this
    ///     census is about the type of the ASSIGNMENT TARGET. A same-named field on
    ///     another type excludes a statement only when it is the target; as a
    ///     source it is irrelevant, and a name-shaped exclusion cannot tell those
    ///     apart (`feedback_filename_is_not_a_type_qualifier`). All 25 previous
    ///     attributions were CORRECT — only completeness failed. Re-derived with a
    ///     deliberately different instrument from the `.set(to:)` one that built the
    ///     list above (a direct `\.observedUidValidity\s*=\s*[^=]` sweep over
    ///     `TabMail/ Shared/ TabMailNotificationService/`), because a census re-run
    ///     with its own shape returns its own answer.
    ///
    ///     Some nil-writers write onto a row being re-keyed or adopted under a
    ///     new primary key rather than onto a row updated in place — **that
    ///     distinction does not matter to this arm**, because either way the
    ///     message ends up carrying a `nil` stamp it did not carry before, which
    ///     is exactly the ordinary absence this comment warns against reading as
    ///     disagreement. The load-bearing fact is the RATIO's direction (18–20
    ///     against 5), not its magnitude — invert it and this arm's conclusion
    ///     inverts with it.
    ///
    ///     **THE OTHER HALF IS THE ONE THE GUARD DEPENDS ON, AND IT IS EXACT: the
    ///     same census for `rfc822MessageId` is ZERO.** No production statement
    ///     assigns `nil` to `MessageHeader.rfc822MessageId`. That asymmetry — many
    ///     versus none — is the whole reason a missing epoch is not evidence and a
    ///     missing content witness is.
    ///
    ///     ⚠️ **CORRECTED 2026-08-05 — the census above is TRUE AS STATED and is
    ///     NOT sufficient to support arm 3's "never nulled once set" above.** The
    ///     census counts *literal* `nil` assignments; it says nothing about a
    ///     PROPAGATED nil. `MessageMetadata.rfc822MessageId` is `String?` by
    ///     construction and IS nil whenever the provider payload omits the header
    ///     (`GmailParse` derives it from `header("Message-Id")`, `GraphParse` from
    ///     `internetMessageId`; both are `.map`-over-Optional). **FIVE** production
    ///     statements then assign that Optional STRAIGHT ONTO A STORED ROW without a
    ///     nil check — `SyncEngine.gmailDeltaSync` ×2 and
    ///     `SyncEngine.exchangeDeltaSync` ×3, in `SyncEngineDeltaSync.swift`, in
    ///     **TWO different shapes**:
    ///       • `existing.rfc822MessageId = info.rfc822MessageId` … `existing.update(db)`
    ///         — the in-place merge arm (gmail ×1, exchange ×2); and
    ///       • `orphaned.rfc822MessageId = header.rfc822MessageId` … `orphaned.update(db)`
    ///         — the ORPHAN-RECLAIM arm (gmail ×1, exchange ×1), where a row found
    ///         outside the synced folder is re-pointed at it and re-stamped from the
    ///         freshly parsed `header`. `header.rfc822MessageId` is assigned from the
    ///         same `info.rfc822MessageId` Optional a few lines earlier, so it nulls a
    ///         stored value under exactly the same conditions.
    ///     (The two remaining assignments in that file write a freshly-built `header`
    ///     that is about to be INSERTed, so they cannot null a stored value and are
    ///     not counted. Seven assignments total.) So a stored `rfc822MessageId` CAN in
    ///     principle go from present to absent, and the right claim is "no production
    ///     statement nulls it *deliberately*", not "it is never nulled".
    ///
    ///     ⚠️ **RE-CENSUSED 2026-08-06 (round-11 R11-I): this said THREE, and the
    ///     miss is the reason both shapes are now named.** The original census
    ///     searched the shape it already had in mind — `existing.rfc822MessageId =`
    ///     — so it saw only the in-place merge arm and was structurally blind to the
    ///     orphan-reclaim arm, which writes the identical value through a differently
    ///     named variable onto an equally stored row (`MIS-007`, *a census inherits
    ///     its search shape*). The correct predicate is by PROPERTY — *an assignment
    ///     to `rfc822MessageId` on a row that is subsequently `update`d rather than
    ///     `insert`ed* — not by receiver name. Re-derive it that way, and restate the
    ///     integer beside the predicate, before relying on it again.
    ///
    ///     **The sibling path already carries the stricter form, and it is the one
    ///     to copy if this is ever tightened:** `SyncEngine.performFullSync`
    ///     (`SyncEngineFullSync.swift`) wraps the analogous merge in
    ///     `if normalizedIncomingRfc822 != nil { existing.rfc822MessageId = … }`,
    ///     and repeats the rule at the pre-sync inbox reclaim
    ///     (`if normalizedIncomingRfc822 == nil { header.rfc822MessageId =
    ///     preSync.rfc822MessageId }`) — "a nil incoming value carries no metadata
    ///     signal and must never NULL a stored value".
    ///
    ///     **No guard is being added here, deliberately.** At the release base
    ///     `07a4bb703` NEITHER file had any such guard (`normalizedIncomingRfc822`
    ///     does not exist at that revision, and all five delta-sync assignments are
    ///     already bare there), so the range NARROWS this exposure rather than
    ///     regressing it, and guarding those three sites would be an unrequested
    ///     behaviour change in a release-audit fix round. The residual is bounded
    ///     and recoverable: a delta sync that nulls a stored id makes arm 3 read an
    ///     ordinary absence as disagreement and return `nil` — a SPURIOUS REFUSAL,
    ///     fail-closed, recovered by one ordinary gesture (re-run the search), which
    ///     is exactly what the MANTRA says to leave alone. The direction that would
    ///     matter — a wrong message being OPENED — is unreachable from this arm,
    ///     because the arm's only output is refusal.
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

    /// What a tap on a search result does.
    ///
    /// The invariant this type serves: *no result the user can tap is a no-op.*
    /// Both resolvers are fail-CLOSED and return `nil` far more often than a
    /// reader expects (a re-seated address, a remote hit with no local row at
    /// all), and before this type the remote branch answered a `nil` by simply
    /// returning — an invisible dead tap, indistinguishable from a broken app.
    ///
    /// 🚨 CORRECTION OF RECORD (2026-08-04). This comment used to claim *"THERE IS
    /// DELIBERATELY NO SILENT CASE, and that absence is the invariant… a future
    /// re-implementation cannot reintroduce silence without adding a case here."*
    /// **That is false, and it was load-bearing false** — it was the stated reason
    /// no test covered the wiring. **Swift exhaustiveness forces a case to EXIST,
    /// not to DO anything.** `case .explainRemoteResultNotOnThisDevice: break`
    /// compiles, adds no case, and restores the exact dead silent tap this type was
    /// introduced to kill. Absence of a silent CASE is not absence of a silent
    /// PATH, and an enum can only make a decision explicit — it can never make the
    /// consumer act on it.
    ///
    /// What actually holds the invariant is `TapEffect` + `effect(of:)` below: the
    /// mapping from outcome to visible consequence is a value a test can assert,
    /// and `openResult` applies that value by unconditional assignment rather than
    /// by re-deciding in a `switch` of its own. See `TapEffect` for exactly how far
    /// that reaches and where it stops.
    enum ResultTapOutcome: Equatable {
        /// Navigate. Carries the witness the resolve validated against, if any.
        case open(OpenTarget)
        /// A LOCAL result whose captured content witness no longer matches the row
        /// at its address (or whose row is gone) — the message moved or was
        /// replaced since the search ran.
        case explainStaleLocalResult
        /// A REMOTE result with no folder-native local row. The message exists on
        /// the server; this device just has no copy to open.
        case explainRemoteResultNotOnThisDevice
    }

    /// Turn a resolve into what the user sees.
    ///
    /// `resolvedHeaderId == nil` covers BOTH a refusal and a thrown read: neither
    /// is evidence that the row is safe to open, and this navigation ends in a
    /// durable mark-read, so both fail closed the same way.
    ///
    /// `nonisolated static` for the same reason as the two resolve helpers: it
    /// touches no `@State` and needs no view, so a test can call it directly.
    nonisolated static func tapOutcome(
        for result: SearchResult, resolvedHeaderId: String?
    ) -> ResultTapOutcome {
        let isRemote = result.headerId == nil
        guard let resolvedHeaderId else {
            return isRemote ? .explainRemoteResultNotOnThisDevice : .explainStaleLocalResult
        }
        // 🚨 BOTH SOURCES CARRY THE WITNESS, AND THE CORRECTION OF RECORD FOR WHY
        // THE REMOTE ONE USED TO BE DISCARDED. This previously read *"a remote
        // result carries NO content witness (there was no local row to capture one
        // from)"* and concluded, correctly from that premise, that "a false proof is
        // worse than none". The premise was FALSE: the witness never needed a local
        // row. `MessageHeaderInfo.rfc822MessageId` is the SERVER's Message-ID for
        // the very record this row was rendered from, and
        // `presentableRemoteResults` now carries it onto the `SearchResult` at zero
        // extra I/O — the same field, from the same producer, that populates a local
        // row's own column. Discarding it here was not caution; it threw away the
        // only instrument that distinguishes the message the user was shown from
        // whatever now occupies its address.
        //
        // IT IS SOUND EVEN THOUGH THE REMOTE RESOLVE DID NOT CHECK IT. The resolve
        // (`resolveRemoteResultHeaderId`) still establishes EXISTENCE at an address
        // and nothing more — unchanged. The witness's only consumer is
        // `MessageDetailViewModel.markReadPermitted`, where it can REFUSE the
        // durable mark-read and can never select, widen or nominate a target. That
        // is the same direction as the local arm and the same reason neither is an
        // ADR-IOS-068 / D4 violation.
        //
        // ⚑ WHAT THIS DOES NOT COVER, stated because the absolute above is
        // otherwise unfalsifiable (MIS-019):
        //  • A provider that supplies no Message-ID yields `nil` here,
        //    `ExpectedMessageIdentity.init?` rejects it, and the open keeps today's
        //    FAIL-OPEN mark-read exactly. No new branch exists for that population.
        //  • The mirror-image population is NEW and fails CLOSED: a live local row
        //    whose own `rfc822MessageId` is absent or differs while the server
        //    reports one loses only its mark-read-on-open. The message still opens
        //    and renders; it stays unread, which one ordinary gesture fixes.
        //    Registered as `IOS-SEARCH-003`.
        //  • Only the mark-read is gated. A re-seated address still OPENS — refusing
        //    to render would be a regression with no C3 payoff, per `OpenTarget`.
        return .open(OpenTarget(
            headerId: resolvedHeaderId,
            provenRfc822MessageId: result.capturedRfc822MessageId))
    }

    /// The COMPLETE visible consequence of one tap, as a value.
    ///
    /// 🚨 THIS EXISTS BECAUSE THE ENUM ALONE NEVER HELD THE INVARIANT. Asserting
    /// `tapOutcome` returns `.explainRemoteResultNotOnThisDevice` pins the
    /// CLASSIFIER; the system property is *the user sees something*, which lives one
    /// hop later, in what the view does with that answer. Those are different
    /// propositions, and the whole tap suite asserted only the first — so
    /// `case .explainRemoteResultNotOnThisDevice: break` in `openResult` restored the
    /// dead silent tap with every one of those tests still GREEN (observed, not
    /// reasoned — see the round-2 commit body). Testing rule 12: pin the invariant,
    /// not the mechanism.
    ///
    /// ⚑ HOW FAR THIS REACHES, AND WHERE IT STOPS — stated because the claim it
    /// replaces was an unfalsifiable absolute (MIS-019). `effect(of:)` is pure and
    /// exhaustively asserted, so an outcome that maps to no visible consequence now
    /// fails a test instead of compiling silently. The LAST hop — `openResult`
    /// assigning these three fields onto `@State` — is still NOT covered by a unit
    /// test, because it needs a hosted SwiftUI view. It is merely made harder to get
    /// wrong: `openResult` no longer re-decides anything, so there is no branch left
    /// in it to `break` out of, and a regression there has to be a visible DELETION
    /// of an assignment rather than an empty case body. That is a real reduction, not
    /// a proof, and it should not be described as one.
    struct TapEffect: Equatable {
        /// Non-nil ⇒ navigate to this target.
        var navigate: OpenTarget?
        /// The local result's content witness no longer matches the row at its address.
        var explainStaleLocalResult: Bool
        /// The remote hit has no folder-native local row on this device.
        var explainRemoteResultNotOnThisDevice: Bool

        /// The invariant, expressed so a test can assert it over every outcome:
        /// a tap must always do at least one of navigate / explain.
        var isVisible: Bool {
            navigate != nil || explainStaleLocalResult || explainRemoteResultNotOnThisDevice
        }
    }

    /// Map a decision onto its visible consequence. Pure; no `@State`, no view.
    nonisolated static func effect(of outcome: ResultTapOutcome) -> TapEffect {
        switch outcome {
        case .open(let target):
            return TapEffect(navigate: target,
                             explainStaleLocalResult: false,
                             explainRemoteResultNotOnThisDevice: false)
        case .explainStaleLocalResult:
            return TapEffect(navigate: nil,
                             explainStaleLocalResult: true,
                             explainRemoteResultNotOnThisDevice: false)
        case .explainRemoteResultNotOnThisDevice:
            return TapEffect(navigate: nil,
                             explainStaleLocalResult: false,
                             explainRemoteResultNotOnThisDevice: true)
        }
    }

    private func openResult(_ result: SearchResult) {
        // Local result with headerId — the address is cached in an in-memory
        // `results` array that predates any re-seat, so prove the row still there
        // is the message this row RENDERED before opening (and durably marking) it.
        // Remote result: resolve folder-scoped; never a cross-folder/-account guess.
        //
        // A6 (DB-performance lens): one `MessageHeader` fetch, one row, no scan —
        // the same synchronous `dbPool.read` at the same call site both branches
        // have always taken, and only on a tap.
        let resolved: String? = try? dbPool.read { db in
            if let headerId = result.headerId {
                return try Self.resolveLocalResultHeaderId(
                    headerId: headerId,
                    capturedRfc822MessageId: result.capturedRfc822MessageId,
                    db: db
                )
            }
            return try Self.resolveRemoteResultHeaderId(
                accountId: result.accountId,
                messageId: result.messageId,
                folderPath: result.folderPath,
                db: db
            )
        }
        // Decide once, then APPLY — no second decision lives here. The assignments
        // are unconditional so the applied state is exactly the asserted value,
        // including the falses: an open cannot leave a stale alert flag raised, and
        // an explain cannot silently skip being raised.
        let effect = Self.effect(of: Self.tapOutcome(for: result, resolvedHeaderId: resolved))
        if let target = effect.navigate {
            navigationPath.append(target)
        }
        showStaleResultAlert = effect.explainStaleLocalResult
        showRemoteResultUnavailableAlert = effect.explainRemoteResultNotOnThisDevice
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
                                // Field-for-field rebuild: carry the content witness
                                // too. Every result reaching here is remote, and
                                // remote results NOW CARRY ONE (the provider's
                                // `MessageHeaderInfo.rfc822MessageId`, populated in
                                // `presentableRemoteResults`) — so this line is load
                                // bearing rather than defensive, and the snippet
                                // enrichment is the one place a rebuild could
                                // silently strip the evidence back off again.
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

        return await Self.remoteResults(
            accountId: resultAccountId, accountEmail: email, folderPath: folder
        ) {
            // Forward caller cancellation (query change, dismiss, new submit) into
            // the inner search task — a cancelled search resolves as empty results.
            // Still registered on THIS task (an `await` into a nonisolated function
            // is an executor hop, not a new task), so propagation is unchanged.
            try await withTaskCancellationHandler {
                try await searchTask.value
            } onCancel: {
                searchTask.cancel()
            }
        }
    }

    /// Everything between "the provider answered" and "the view has results" —
    /// failure handling, the debug census, and the `\Deleted` presentation filter.
    ///
    /// 🚨 THIS SEAM EXISTS TO PIN THE WIRING, NOT TO ABSTRACT ANYTHING.
    /// `SearchDeletedResiduePresentationTests` proved that `presentableRemoteResults`
    /// DROPS a `\Deleted` residue, which is a property of a function nobody was
    /// proven to call: the filter sat on the tail of a `@MainActor` view method that
    /// builds two `Task`s and a timeout, so no test could reach the path the search
    /// actually takes, and deleting the call would have left that suite green. With
    /// the fetch injected, a test drives the REAL return path and the filter is
    /// pinned where it runs.
    ///
    /// ⚑ WHAT REMAINS UNPINNED: that `searchAccount` calls this at all. That hop is
    /// now a single `return await` with no branch and no second mapping, but it is
    /// not covered, and calling this seam "wiring coverage" without that caveat would
    /// repeat the error it was written to correct.
    ///
    /// Semantics are byte-for-byte the previous behaviour: `CancellationError` and
    /// any other error both resolve to an empty result set, never a thrown search.
    nonisolated static func remoteResults(
        accountId: String, accountEmail: String, folderPath: String,
        fetch: @Sendable () async throws -> [MessageHeaderInfo]
    ) async -> [SearchResult] {
        let infos: [MessageHeaderInfo]
        do {
            infos = try await fetch()
        } catch is CancellationError {
            // Gate the DIAGNOSTIC, never the control flow: `return []` stays
            // outside, so a debug unlock cannot change what this function does.
            // Ordinary transient-failure traces, NOT a C3 refusal — a refusal
            // leaving no production trace would be an observability gap and would
            // belong on an ungated durable channel instead (`af98d92c7`).
            // Sharper reason to gate these two: they interpolate `accountEmail`,
            // putting the user's own address into a production device log.
            if DebugModeManager.isLoggingEnabled() {
                print("[Search] Cancelled/timed out searching \(accountEmail) — treating as empty")
            }
            return []
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                print("[Search] Error searching \(accountEmail): \(error)")
            }
            return []
        }

        if DebugModeManager.isLoggingEnabled() {
            print("[Search] \(accountEmail) \(folderPath.isEmpty ? "account-wide" : "folder=\(folderPath)") returned \(infos.count) results")
        }

        return presentableRemoteResults(
            from: infos, accountId: accountId, accountEmail: accountEmail, folderPath: folderPath)
    }

    /// The remote hits this search may SHOW, from what the provider returned.
    ///
    /// 🚨 IOS-IMAP-001 — A MESSAGE THE SERVER REPORTS `\Deleted` IS NOT PRESENTED
    /// (RFC 3501 §2.3.2 — the flag means "pending removal"). This is the FIFTH
    /// consumer of `MessageHeaderInfo` that reaches the user, and the only one that
    /// PRESENTS without MATERIALISING a `MessageHeader` — which is exactly why the
    /// census that closed this row (noun: `MessageHeader` construction sites) could
    /// not see it. The other four skip the same records at
    /// `SyncEngineFullSync.selectStaleHeaders`, `SyncEngineFullSync.runSyncMessages`,
    /// `SyncEngine.insertBackfillBatchGuardable` and `SyncEngine.fetchOlderMessages`.
    ///
    /// The user-visible defect on the server class this row is about (no UIDPLUS,
    /// where the `COPYUID`-gated purge can never fire and soft-deleted move sources
    /// accumulate): a search showed **two hits for one email**, and the residue was
    /// the one with no local row, so tapping it did nothing at all.
    ///
    /// ⚑ PRESENTATION ONLY, established by search rather than by meaning (MIS-021).
    /// `AccountManager.search` has exactly one caller — this view — so nothing
    /// downstream of the dropped values is a wire op, a queued intention or a sync
    /// decision. Inside `launchRemoteSearch` the only other consumer of these
    /// results is the same-message merge (`isSameMessage` / `removeAll`), where
    /// dropping a residue can only PRESERVE the local row it would have replaced.
    ///
    /// 🚨 AND THE FILTER STAYS HERE, NOT IN THE SEARCH CRITERIA. Adding a
    /// `NOT DELETED` term to `IMAPProvider.searchOnConnection` would narrow what the
    /// SERVER reports, which is the ADR-IOS-042 / `MIS-IOS-002` shape in a different
    /// coordinate system — and it would cover IMAP only, leaving the invariant
    /// provider-specific. Filtering the presented set uses the one true producer's
    /// flag (`IMAPProvider.mapMessageInfo`) and holds for every provider, including
    /// any future one that learns to observe it.
    ///
    /// `nonisolated static` for the same reason as the resolve helpers: it touches
    /// no `@State` and needs no view, so a test can call it directly.
    nonisolated static func presentableRemoteResults(
        from infos: [MessageHeaderInfo], accountId: String, accountEmail: String, folderPath: String
    ) -> [SearchResult] {
        infos.filter { !$0.isDeletedOnServer }.map { info in
            SearchResult(
                source: .remote,
                accountId: accountId,
                accountEmail: accountEmail,
                messageId: info.messageId,
                // The folder this result was searched in. Empty for provider
                // account-wide search (Gmail/Graph), where `messageId` is already
                // globally unique. For IMAP this is the real folder path, which is
                // required to disambiguate per-folder UIDs that collide across folders.
                folderPath: folderPath,
                subject: info.subject,
                from: info.from,
                fromAddress: info.fromAddress,
                date: info.date,
                snippet: EmailFilter.cleanSnippet(info.snippet),
                isRead: info.isRead,
                isFlagged: info.isFlagged,
                headerId: nil,
                // 🚨 THE CONTENT WITNESS THE PROVIDER ALREADY HANDED US. The
                // second field of `MessageHeaderInfo`, set by the same producer
                // that populates a local row's `rfc822MessageId` column, for the
                // very record this result renders. Costs zero extra I/O — it is
                // already in the value being mapped. `SearchResult
                // .capturedRfc822MessageId` is nil-DEFAULTED, so omitting it here
                // was silent: nothing failed to compile and no test went red while
                // every remote open travelled unwitnessed (a fail-DANGEROUS seam).
                // `tapOutcome` carries it to `MessageDetailViewModel`, where it can
                // only REFUSE that open's durable mark-read — see `tapOutcome` for
                // why an unchecked-by-the-resolve witness is sound in that
                // direction, and for the population this newly fails closed.
                capturedRfc822MessageId: info.rfc822MessageId
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
    /// 🚨 THE CONTENT WITNESS — the RFC 2822 Message-ID of the record this result
    /// was RENDERED FROM, captured at search time. Local results take it from the
    /// header row they read; REMOTE results take it from the provider's own
    /// `MessageHeaderInfo.rfc822MessageId` (`presentableRemoteResults`), which needs
    /// no local row and is set by the same producer as the local column.
    ///
    /// `nil` only where there is genuinely nothing to capture: a provider that
    /// supplied no Message-ID, and `ScreenshotMode`'s seeded rows.
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
