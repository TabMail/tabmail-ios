/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// PORT/SUBTRACT — the repeated v2final `ServerDraftOpen` handoff check,
/// narrowed to an already-existing Draft row. No fresh compose, RFC adoption,
/// recovery, or compatibility path is authorized here. A draft written by another
/// mail app gets its row from `ExternalDraftAdoption` (exact address only, #217)
/// before this check runs.
struct LocallyAuthoredDraftOpenAuthority: Sendable, Equatable {
    enum Address: Sendable, Equatable {
        case placeholder(messageId: String)
        case gmail(resourceId: String, containedMessageId: String)
        case outlook(graphId: String)
        /// The COMPLETE IMAP provider-native address of a pushed draft. A bare UID
        /// is not an address: it is a slot number inside one mailbox's one
        /// UIDVALIDITY numbering space, so `(folderPath, uidValidity, uid)` is the
        /// smallest tuple that names a message (THE ADDRESS PROBLEM). Every
        /// component is written by `DraftStore`'s `case (.imap, .imap(...))` push
        /// arm — this case reads what that arm already recorded and invents nothing.
        case imap(folderPath: String, uidValidity: Int, uid: String)
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
        case .imap(let folderPath, let uidValidity, let uid):
            // All THREE components, because the UID alone is ambiguous across
            // mailboxes and across numbering spaces. This re-check runs against a
            // freshly-read `Draft` row at both handoffs; it deliberately does NOT
            // re-read the live folder's epoch (no `Database` here, same as every
            // other arm) — the folder-epoch agreement is proven once, inside the
            // resolver's read transaction, where the folder row is already in hand.
            return currentRuntimeKind == .imap
                && draft.serverDraftId == uid
                && draft.serverDraftFolderPath == folderPath
                && draft.serverDraftUidValidity == uidValidity
        case .demo(let localId):
            return currentRuntimeKind == .demo && draft.serverDraftId == localId
        }
    }

    /// The database half of `ServerDraftComposeLoader.resolveLocallyAuthoredDraft`
    /// for every runtime except Gmail (whose resolution needs a provider round trip
    /// to turn a contained MESSAGE id into a draft RESOURCE id, so it cannot live in
    /// a read transaction).
    ///
    /// Extracted so the INVARIANT — *given a database and a Drafts header, exactly
    /// the locally-authored `Draft` that owns that header comes back, and nothing
    /// else does* — is testable. Pinning `matches` alone pins a mechanism: it stayed
    /// green for the whole window in which `.imap` fell through to `default: return
    /// nil` and no IMAP draft could be reopened at all (`MIS-015`).
    ///
    /// FAIL CLOSED is the default on every axis. A server-origin draft has no local
    /// `Draft` row and produces no match here; `ServerDraftComposeLoader` then adopts
    /// it (`ExternalDraftAdoption`) and calls this again. An ambiguous result (two
    /// local rows claiming the same header) refuses rather than guessing.
    static func resolve(
        db: Database,
        header: MessageHeader,
        runtimeKind: DraftRuntimeIdentityKind
    ) throws -> LocallyAuthoredDraftOpenAuthority? {
        guard let current = try MessageHeader.fetchOne(db, key: header.id),
              current.accountId == header.accountId,
              current.folderId == header.folderId,
              current.folderPath == header.folderPath,
              current.messageId == header.messageId,
              current.rfc822MessageId == header.rfc822MessageId,
              let draftsFolder = try Folder.fetchOne(db, key: current.folderId),
              draftsFolder.role == .drafts else {
            return nil
        }
        let drafts = try Draft
            .filter(Column("accountId") == current.accountId)
            .fetchAll(db)
        let matches = drafts.compactMap { draft -> LocallyAuthoredDraftOpenAuthority? in
            guard let instanceEpoch = draft.instanceEpoch,
                  !instanceEpoch.isEmpty else { return nil }
            if PendingOperation.draftPlaceholderMessageId(
                draftId: draft.id,
                instanceEpoch: draft.instanceEpoch) == current.messageId {
                return LocallyAuthoredDraftOpenAuthority(
                    draftId: draft.id,
                    accountId: draft.accountId,
                    instanceEpoch: instanceEpoch,
                    serverPushStatus: draft.serverPushStatus,
                    runtimeKind: runtimeKind,
                    address: .placeholder(messageId: current.messageId))
            }
            guard let serverId = draft.serverDraftId, !serverId.isEmpty else {
                return nil
            }
            switch runtimeKind {
            case .outlook where serverId == current.messageId:
                return LocallyAuthoredDraftOpenAuthority(
                    draftId: draft.id, accountId: draft.accountId,
                    instanceEpoch: instanceEpoch,
                    serverPushStatus: draft.serverPushStatus,
                    runtimeKind: runtimeKind,
                    address: .outlook(graphId: serverId))
            case .imap where serverId == current.messageId:
                // The placeholder arm above stops matching the instant the push
                // completes: `DraftStore`'s IMAP push arm rewrites the header's
                // `messageId` to the bare UID, which never equals the placeholder
                // string. From that moment this arm is the ONLY thing that can
                // reopen a draft the user authored on this device.
                //
                // A bare UID match is NOT sufficient authority. It is a slot number
                // in one mailbox's numbering space, so it must agree with the
                // mailbox the draft was pushed to AND with the numbering space that
                // mailbox is currently in — otherwise a renumbered Drafts folder
                // would hand the user a different message's slot to edit (C3).
                // A folder whose epoch is unknown (nil / <= 0) refuses: unknown is
                // never authoritative (`IOS-EPOCH-001`), and the refusal is
                // recovered by an ordinary sync that stamps the folder.
                guard let recordedFolder = draft.serverDraftFolderPath,
                      recordedFolder == current.folderPath,
                      let recordedEpoch = draft.serverDraftUidValidity,
                      recordedEpoch > 0,
                      let liveEpoch = draftsFolder.lastKnownUidValidity,
                      liveEpoch > 0,
                      recordedEpoch == liveEpoch else {
                    return nil
                }
                return LocallyAuthoredDraftOpenAuthority(
                    draftId: draft.id, accountId: draft.accountId,
                    instanceEpoch: instanceEpoch,
                    serverPushStatus: draft.serverPushStatus,
                    runtimeKind: runtimeKind,
                    address: .imap(
                        folderPath: recordedFolder,
                        uidValidity: recordedEpoch,
                        uid: serverId))
            case .demo where serverId == current.messageId:
                return LocallyAuthoredDraftOpenAuthority(
                    draftId: draft.id, accountId: draft.accountId,
                    instanceEpoch: instanceEpoch,
                    serverPushStatus: draft.serverPushStatus,
                    runtimeKind: runtimeKind,
                    address: .demo(localId: serverId))
            default:
                return nil
            }
        }
        return matches.count == 1 ? matches.first : nil
    }
}

/// Presents a saved draft's compose from a `DraftOpenPreparation` outcome, so the
/// compose is created already holding the draft (#309). Every caller prepares the
/// open before presenting, so the first frame is the draft; only Try Again on a
/// failure card shows a spinner here while the open is prepared again.
///
/// Usage: `DraftComposePresenter(source: .header(header), prepared: outcome)`
struct DraftComposePresenter: View {
    let source: DraftOpenPreparation.Source
    #if DEBUG
    @Environment(\.draftOpenResolverForTesting) private var resolveOpenAuthorityForTesting
    #endif
    /// Nil only while Try Again prepares the open again.
    @State private var outcome: DraftOpenPreparation.Outcome?
    @Environment(\.dismiss) private var dismiss

    init(source: DraftOpenPreparation.Source, prepared: DraftOpenPreparation.Outcome) {
        self.source = source
        _outcome = State(initialValue: prepared)
    }

    var body: some View {
        Group {
            switch outcome {
            case .ready(let prepared):
                ComposeView(
                    replyTo: prepared.replyTo,
                    account: prepared.account,
                    isForward: prepared.draft.isForward,
                    prefillDraftId: prepared.draft.id,
                    openAuthority: prepared.openAuthority,
                    preparedDraft: prepared.draft
                )
            case .nothingToOpen:
                // Draft doesn't exist (yet) — auto-dismiss
                Color.clear.onAppear { dismiss() }
            case .unavailable(let failure):
                DraftOpenFailureView(
                    failure: failure,
                    close: { dismiss() },
                    retry: {
                        outcome = nil
                        Task { await prepare() }
                    })
            case nil:
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .overlay { ProgressView("Loading draft...") }
            }
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

    private func prepare() async {
        #if DEBUG
        outcome = await DraftOpenPreparation.prepare(source, resolver: resolveOpenAuthorityForTesting)
        #else
        outcome = await DraftOpenPreparation.prepare(source)
        #endif
    }
}

/// The terminal states of a draft open, each with a way out.
///
/// 🚨 **`.noLocalCopy` AND `.loadFailed` ARE NOT THE SAME ANSWER.** A THROWN read
/// once rendered the very same authoritative "no editable copy of this draft was
/// found" card as a genuine, fully-determined absence — never-drop clause 2's *"we
/// could not determine the answer" treated as authoritative*. Do not merge them
/// back — and equally, do not let the retryable card swallow the final ones: a
/// header with no local `Draft` must keep getting its honest card rather than an
/// endless "try again" the user can never satisfy.
private struct DraftOpenFailureView: View {
    let failure: DraftOpenPreparation.Failure
    let close: () -> Void
    let retry: () -> Void

    var body: some View {
        switch failure {
        case .noLocalCopy:
            // STATE ONLY THE OBSERVED FACT — do not promise a remedy. Since #217
            // every draft with an exact server address is adopted, so this arm is
            // reached only when the header changed or vanished under us, or has no
            // exact address (an IMAP folder whose epoch is unknown).
            unavailable(systemImage: "exclamationmark.shield",
                        message: "This draft couldn't be opened. It may have been changed or deleted in another app.")
        case .unsupportedAttachment:
            unavailable(systemImage: "paperclip", message: DraftReadConfig.unsupportedAttachmentMessage)
        case .changedWhileOpening:
            retryable(message: "This draft changed while it was opening. Please try again.")
        case .accountUnavailable:
            retryable(message: "This draft's account couldn't be verified. Please try again in a moment.")
        case .loadFailed:
            retryable(message: "This draft didn't finish loading. Please try again in a moment.")
        }
    }

    private func unavailable(systemImage: String, message: String) -> some View {
        ContentUnavailableView {
            Label("Draft unavailable", systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            closeButton
        }
    }

    /// ⚑ NO REFERENCE — INVENTED: the "Try Again" button. The reference offered
    /// only "Close", which throws away the user's intent to open the draft on what
    /// is usually a transient condition (an account row not yet materialized, a busy
    /// database). Retry re-runs the exact same fail-closed preparation; it grants no
    /// authority of its own.
    private func retryable(message: String) -> some View {
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
                closeButton
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var closeButton: some View {
        Button("Close", action: close)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("server-draft-close")
    }
}
