/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// PORT/SUBTRACT — the repeated v2final `ServerDraftOpen` handoff check,
/// narrowed to an already-existing locally-authored Draft. No fresh compose,
/// RFC adoption, recovery, or compatibility path is authorized here.
struct LocallyAuthoredDraftOpenAuthority: Sendable, Equatable {
    enum Address: Sendable, Equatable {
        case placeholder(messageId: String)
        case gmail(resourceId: String, containedMessageId: String)
        case outlook(graphId: String)
        case demo(localId: String)
    }

    let draftId: String
    let accountId: String
    let instanceEpoch: String
    let serverPushStatus: String?
    let runtimeKind: DraftRuntimeIdentityKind
    let address: Address

    func matches(_ draft: Draft, runtimeKind currentRuntimeKind: DraftRuntimeIdentityKind) -> Bool {
        guard currentRuntimeKind == runtimeKind,
              draft.id == draftId,
              draft.accountId == accountId,
              draft.instanceEpoch == instanceEpoch,
              draft.serverPushStatus == serverPushStatus else {
            return false
        }
        switch address {
        case .placeholder(let messageId):
            return PendingOperation.draftPlaceholderMessageId(
                draftId: draft.id, instanceEpoch: draft.instanceEpoch) == messageId
        case .gmail(let resourceId, _):
            return currentRuntimeKind == .gmail && draft.serverDraftId == resourceId
        case .outlook(let graphId):
            return currentRuntimeKind == .outlook && draft.serverDraftId == graphId
        case .demo(let localId):
            return currentRuntimeKind == .demo && draft.serverDraftId == localId
        }
    }
}

/// Loads a Draft from GRDB and resolves all context (reply-to message, account)
/// before creating ComposeView. This eliminates the black-screen flash that occurs
/// when ComposeView is created with empty @State and loads data in onAppear.
///
/// Usage: `DraftComposePresenter(draftId: "reply:acct:stableId")`
/// Used by ComposeToolbarButton and ServerDraftComposeLoader.
struct DraftComposePresenter: View {
    let draftId: String
    var openAuthority: LocallyAuthoredDraftOpenAuthority? = nil
    @State private var loadResult: LoadResult?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    private enum LoadResult {
        /// The account is non-optional: a persisted `Draft` only ever opens bound to
        /// the exact account that OWNS the row (`ComposeDraftGuards
        /// .mayBindPersistedDraft`). There is no nil-account open, because a nil
        /// account is what let the inner `ComposeView` fall back to
        /// `navigationStore.accounts.first`.
        case loaded(draft: Draft, replyTo: MessageHeader?, account: Account)
        case notFound
        /// PORT — v2final `DraftComposePresenter.LoadResult.accountUnavailable`
        /// (D-OPEN #5, commits `a8eb813b5` / `69a9bae88`). The draft's exact owning
        /// account could not be resolved. FAIL CLOSED — never open on a fallback
        /// account, which would send from / attach to the WRONG account.
        case accountUnavailable
        /// ⚑ NO REFERENCE — INVENTED. The `Draft`/`Account` read THREW. The
        /// reference (and this forward-port before this change) collapsed that into
        /// `.notFound`, which AUTO-DISMISSES — so a momentarily busy/suspended
        /// database made the user's "open draft" tap silently do nothing at all. A
        /// thrown read is NOT absence: offer a retry instead of vanishing.
        case loadFailed
    }

    var body: some View {
        Group {
            switch loadResult {
            case .loaded(let draft, let replyTo, let account):
                ComposeView(
                    replyTo: replyTo,
                    account: account,
                    isForward: draft.isForward,
                    prefillDraftId: draftId,
                    openAuthority: openAuthority
                )
            case .notFound:
                // Draft doesn't exist (yet) — auto-dismiss
                Color.clear.onAppear { dismiss() }
            case .accountUnavailable:
                failClosedView(
                    message: "This draft's account couldn't be verified. Please try again in a moment.")
            case .loadFailed:
                failClosedView(
                    message: "This draft didn't finish loading. Please try again in a moment.")
            case nil:
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .overlay { ProgressView("Loading draft...") }
            }
        }
        .task {
            print("[DraftComposePresenter] onAppear fired, isLoading=\(isLoading)")
            guard isLoading else { return }
            isLoading = false
            loadResult = await loadDraft()
            print("[DraftComposePresenter] loadResult=\(loadResult == nil ? "nil" : "set")")
        }
        // ADR-IOS-030: Track presentation lifecycle so the agent compose FIFO queue
        // holds during the brief loading window before the inner ComposeView renders.
        // Without this, a queued agent compose could try to present from the same
        // source view while DraftComposePresenter is still loading and SwiftUI would
        // silently drop the second fullScreenCover.
        .onAppear {
            AgentToolRouter.shared.composePresentationDidBegin()
        }
        .onDisappear {
            AgentToolRouter.shared.composePresentationDidEnd()
        }
    }

    /// PORT — v2final `DraftComposePresenter.accountUnavailableView` (D-OPEN #5),
    /// generalized over the message so the thrown-read arm shares the scaffold.
    ///
    /// ⚑ NO REFERENCE — INVENTED: the "Try Again" button. The reference offered
    /// only "Close", which throws away the user's intent to open the draft on what
    /// is usually a transient condition (an account row not yet materialized, a busy
    /// database). Retry re-runs the exact same fail-closed load; it grants no
    /// authority of its own.
    private func failClosedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Couldn't open this draft")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Try Again") {
                    loadResult = nil
                    Task { loadResult = await loadDraft() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// Load the draft and its owning account, FAIL CLOSED on both axes.
    private func loadDraft() async -> LoadResult {
        print("[DraftComposePresenter] Loading draft: \(draftId)")
        let loaded: (Draft, Account?)?
        do {
            loaded = try await AppDatabase.dbPool.read { db in
                guard let draft = try Draft.fetchOne(db, key: draftId) else { return nil }
                return (draft, try Account.fetchOne(db, key: draft.accountId))
            }
        } catch {
            // A THROWN read is NOT absence. The superseded `return .notFound` here
            // auto-dismissed the presenter, so a busy/suspended database silently
            // swallowed the user's tap on an existing draft.
            if DebugModeManager.isLoggingEnabled() {
                print("[DraftComposePresenter] ⚠ Draft/Account read THREW for \(draftId) — offering retry, not dismissal: \(error)")
            }
            return .loadFailed
        }
        guard let (draft, account) = loaded else {
            print("[DraftComposePresenter] Draft NOT FOUND: \(draftId)")
            return .notFound
        }

        // PORT — v2final `ServerDraftOpen.mayBindPersistedDraft` (commits
        // `a8eb813b5` / `69a9bae88`), via `ComposeDraftGuards`. EVERY persisted
        // `Draft` open requires the row's exact owning `Account`; there is no
        // accounts-first fallback. Previously a nil `account` was handed to
        // `ComposeView` as `account: nil`, whose `resolvedAccount` then fell through
        // to `navigationStore.accounts.first` — a silent bind to the WRONG account,
        // which sends from the wrong address and pushes the server draft into the
        // wrong mailbox. `ComposeView` repeats this binding at its own handoff.
        //
        // SUBTRACT — v2final's `serverDraftHeader` arm (`mayOpenWithAccount`) and
        // the Gmail/Outlook `mayReuseAtComposeHandoff` RFC/RESOURCE revalidation are
        // NOT ported. `DraftComposePresenter` here has no `serverDraftHeader` and no
        // `backSeed` parameter: this forward-port's server-draft open path is
        // `LocallyAuthoredDraftOpenAuthority`, whose `matches(_:runtimeKind:)`
        // already requires the exact provider-native address (`serverDraftId ==
        // resourceId` / `graphId` / `localId`) plus accountId, instanceEpoch and
        // serverPushStatus equality against the freshly-read row — a STRICTER check
        // than the reference's RFC-corroborated union, and re-run inside
        // `ComposeView.loadDraftOrPrepopulate` at the second handoff. The
        // reference's premise (a Gmail row whose RESOURCE must be recovered from a
        // contained MESSAGE id, matched by rotating RFC) has no producer here:
        // nothing in this tree constructs a `ServerDraftOpen.Identity` or opens a
        // compose from a bare server header.
        guard ComposeDraftGuards.mayBindPersistedDraft(
            draftAccountId: draft.accountId, resolvedAccountId: account?.id
        ), let account else {
            if DebugModeManager.isLoggingEnabled() {
                print("[DraftComposePresenter] Persisted-draft account unavailable — fail closed (draft.accountId=\(draft.accountId.prefix(20)) account=\(account == nil ? "nil" : "set"))")
            }
            return .accountUnavailable
        }

        if let openAuthority {
            guard openAuthority.draftId == draftId,
                  account.id == openAuthority.accountId,
                  let runtimeKind = await AccountManager.shared.draftRuntimeIdentityKind(
                      accountId: openAuthority.accountId),
                  openAuthority.matches(draft, runtimeKind: runtimeKind) else {
                return .notFound
            }
        }

        // Resolve reply-to message (with stableId fallback for stale PKs).
        //
        // A THROWN resolver read is NOT "this draft has no reply parent". The
        // superseded call went through `Draft.resolveReplyToHeader`'s non-`db`
        // overload, whose whole body is `try? AppDatabase.dbPool.read { … }`: a
        // busy or suspended database returned nil and this function still returned
        // `.loaded(draft:replyTo: nil, account:)`. That manufactured an
        // authoritative negative out of "we could not look" — the never-drop
        // clause-2 error, in the very function whose `.loadFailed` arm documents
        // that a thrown read is not absence. A genuine REFUSAL by the guard still
        // returns nil and still opens compose (unquoted); only the throw diverts.
        let replyToResult: Result<MessageHeader?, Error>
        do {
            replyToResult = .success(try await resolveReplyTo(draft: draft))
        } catch {
            replyToResult = .failure(error)
        }
        guard ComposeDraftGuards.readState(replyToResult) != .error else {
            if DebugModeManager.isLoggingEnabled() {
                print("[DraftComposePresenter] ⚠ Reply-target resolve THREW for \(draftId) — offering retry, not a nil reply target")
            }
            return .loadFailed
        }
        // `.error` is excluded above, so this is the resolver's genuine verdict:
        // a proven header, or a refusal (nil) that opens compose with no parent.
        let replyTo: MessageHeader?
        if case .success(let value) = replyToResult { replyTo = value } else { replyTo = nil }

        print("[DraftComposePresenter] Loaded draft: \(draftId) replyTo=\(replyTo?.id.prefix(20) ?? "nil")")
        return .loaded(draft: draft, replyTo: replyTo, account: account)
    }

    /// T5.8 — resolve through the GUARDED resolver. `draft.replyToId` is a
    /// `MessageHeader` PRIMARY KEY and that key is MUTABLE
    /// (`accountId:folderPath:messageId`), so a folder move re-keys it and a
    /// UIDVALIDITY reset + purge-and-resync can seat a DIFFERENT physical message at
    /// the identical PK. The header this returns is handed straight to
    /// `ComposeView(replyTo:)`, where it drives the reply address, the subject and
    /// the quote attribution — so an unguarded hit here is a wrong-correspondent
    /// reply, not merely a wrong quote. The v80 stamp names the address the user
    /// actually replied to; nil (a pre-v80 row) falls to the draft key's RFC
    /// baseline inside the resolver, never to an unconditional accept.
    ///
    /// Goes through the `db`-scoped overload and PROPAGATES a failed read, so the
    /// caller can tell a refusal (nil) from an unreadable database (throw). The
    /// non-`db` convenience overload swallows the latter into the former.
    private func resolveReplyTo(draft: Draft) async throws -> MessageHeader? {
        // Hoisted into locals so the `@Sendable` read closure captures plain values
        // instead of `self`.
        let key = draftId
        let replyToId = draft.replyToId
        let isForward = draft.isForward
        let expectedProviderMessageId = draft.replyToProviderMessageId
        let expectedUidValidity = draft.replyToUidValidity
        return try await AppDatabase.dbPool.read { db in
            try Draft.resolveReplyToHeader(
                draftKey: key, replyToId: replyToId, isForward: isForward,
                expectedProviderMessageId: expectedProviderMessageId,
                expectedUidValidity: expectedUidValidity, db: db)
        }
    }
}
