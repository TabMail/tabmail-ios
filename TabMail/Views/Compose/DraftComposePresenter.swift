/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// Loads a Draft from GRDB and resolves all context (reply-to message, account)
/// before creating ComposeView. This eliminates the black-screen flash that occurs
/// when ComposeView is created with empty @State and loads data in onAppear.
///
/// Usage: `DraftComposePresenter(draftId: "reply:acct:stableId")`
/// Used by ComposeToolbarButton and ServerDraftComposeLoader.
struct DraftComposePresenter: View {
    let draftId: String
    /// Server draft header for cleanup on send. Passed through to ComposeView.
    var serverDraftHeader: MessageHeader?
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
                    serverDraftHeader: serverDraftHeader
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
        .onAppear {
            print("[DraftComposePresenter] onAppear fired, isLoading=\(isLoading)")
            guard isLoading else { return }
            isLoading = false
            loadResult = loadDraft()
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
    private func loadDraft() -> LoadResult {
        print("[DraftComposePresenter] Loading draft: \(draftId)")
        guard let draft = try? AppDatabase.dbPool.read({ db in
            try Draft.fetchOne(db, key: draftId)
        }) else {
            print("[DraftComposePresenter] Draft NOT FOUND: \(draftId)")
            #if DEBUG
            let allDrafts = (try? AppDatabase.dbPool.read { db in try Draft.fetchAll(db) }) ?? []
            print("[DraftComposePresenter] All drafts in DB: \(allDrafts.map { "\($0.id.prefix(50))" })")
            #endif
            return .notFound
        }

        // Resolve reply-to message (with stableId fallback for stale PKs)
        let replyTo = resolveReplyTo(draft: draft)

        // Resolve account
        let account = try? AppDatabase.dbPool.read { db in
            try Account.fetchOne(db, key: draft.accountId)
        }

        print("[DraftComposePresenter] Loaded draft: \(draftId) replyTo=\(replyTo?.id.prefix(20) ?? "nil")")
        return .loaded(draft: draft, replyTo: replyTo, account: account)
    }

    private func resolveReplyTo(draft: Draft) -> MessageHeader? {
        Draft.resolveReplyToHeader(draftKey: draftId, replyToId: draft.replyToId, isForward: draft.isForward)
    }
}
