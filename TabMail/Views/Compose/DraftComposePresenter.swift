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
        case loaded(draft: Draft, replyTo: MessageHeader?, account: Account?)
        case notFound
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

    /// Synchronous load — GRDB reads are fast on DatabasePool.
    private func loadDraft() async -> LoadResult {
        print("[DraftComposePresenter] Loading draft: \(draftId)")
        let loaded: (Draft, Account?)?
        do {
            loaded = try await AppDatabase.dbPool.read { db in
                guard let draft = try Draft.fetchOne(db, key: draftId) else { return nil }
                return (draft, try Account.fetchOne(db, key: draft.accountId))
            }
        } catch {
            return .notFound
        }
        guard let (draft, account) = loaded else {
            print("[DraftComposePresenter] Draft NOT FOUND: \(draftId)")
            return .notFound
        }

        if let openAuthority {
            guard openAuthority.draftId == draftId,
                  account?.id == openAuthority.accountId,
                  let runtimeKind = await AccountManager.shared.draftRuntimeIdentityKind(
                      accountId: openAuthority.accountId),
                  openAuthority.matches(draft, runtimeKind: runtimeKind) else {
                return .notFound
            }
        }

        // Resolve reply-to message (with stableId fallback for stale PKs)
        let replyTo = resolveReplyTo(draft: draft)

        print("[DraftComposePresenter] Loaded draft: \(draftId) replyTo=\(replyTo?.id.prefix(20) ?? "nil")")
        return .loaded(draft: draft, replyTo: replyTo, account: account)
    }

    private func resolveReplyTo(draft: Draft) -> MessageHeader? {
        Draft.resolveReplyToHeader(draftKey: draftId, replyToId: draft.replyToId, isForward: draft.isForward)
    }
}
