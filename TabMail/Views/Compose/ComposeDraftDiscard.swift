/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Compose's Discard (the "Save Draft?" prompt) and the confirmed Delete of a
/// cleared draft (#254). It lives outside the view so tests run the production
/// path against a real database; the view only shows the outcome.
@MainActor
enum ComposeDraftDiscard {
    enum Outcome: Equatable {
        /// A Save or Send owns the compose; nothing happens and nothing is shown.
        case ignored
        /// Nothing was discarded; the compose stays open showing this message.
        case refused(String)
        /// The discard is durable, or there was nothing to discard; the compose closes.
        case dismiss
    }

    /// `draftId` and `epoch` name this compose's generation; `readState` is how
    /// its draft loaded. `isSavingDraft` and `isSending` are read when the user
    /// taps, before any suspension.
    static func run(
        _ scope: ComposeDraftGuards.DiscardScope,
        draftId: String,
        epoch: String,
        readState: ComposeDraftGuards.ReadState,
        isSavingDraft: Bool,
        isSending: Bool,
        agentSendFence: ComposeAgentSendFence
    ) async -> Outcome {
        // See `saveDraftAndDismiss`: never let Discard overtake another durable
        // disposition or a running agent edit.
        guard !isSavingDraft else { return .ignored }
        guard !isSending else { return .ignored }
        guard agentSendFence.claimExclusiveDisposition() else {
            return .refused("Wait for the draft edit to finish before discarding.")
        }
        defer { agentSendFence.releaseExclusiveDisposition() }
        guard readState != .error else {
            return .refused("This draft did not finish loading. Close and reopen it before discarding.")
        }

        // Load draft info before deleting — needed for server-side cleanup + optimistic UI removal.
        // Async read/write so the main actor isn't blocked behind a busy writer (compose-dismiss
        // freeze class) — this delete was a synchronous main-actor write on the discard path.
        //
        // PORT — v2final `discardDraftAndDismiss`'s F4 rule, now stated through
        // `ComposeDraftGuards.discardMayDelete`: a THROWN metadata read is NOT
        // absence. We need serverDraftId / folder / uidValidity to queue the remote
        // cleanup; without them a local delete would let the server copy re-sync and
        // REAPPEAR. DEFER the discard (row intact) and surface the error.
        let readResult: Result<Draft?, Error>
        do {
            readResult = .success(try await AppDatabase.dbPool.read { db in
                try Draft.fetchOne(db, key: draftId)
            })
        } catch {
            readResult = .failure(error)
        }
        guard ComposeDraftGuards.discardMayDelete(
            readState: ComposeDraftGuards.readState(readResult)) else {
            return .refused("The draft could not be verified, so it was not discarded.")
        }
        guard case .success(let loadedRecord) = readResult, let draftRecord = loadedRecord else {
            return .dismiss
        }
        guard draftRecord.instanceEpoch == epoch else {
            return .refused("This draft changed in another compose window and was not discarded.")
        }

        // PORT 3f2cc4c34: cancel only this exact generation after authority
        // has been re-read and verified.
        let sessionKey = ActiveAgentTracker.composeSessionKey(
            draftId: draftRecord.id, epoch: epoch)
        let session = ChatPillState.shared.session(for: sessionKey)
        session.activeChatTask?.cancel()
        session.activeChatTask = nil
        ActiveAgentTracker.shared.clearWorking(sessionKey)
        ChatPillState.shared.removeSession(for: sessionKey)

        switch ComposeDraftGuards.discardDisposition(scope: scope, serverDraftId: draftRecord.serverDraftId) {
        case .keepDraft:
            // #254: the draft stays as last saved; only this session's edits go.
            break
        case .deleteServerDraft:
            guard let identity = await typedDeleteIdentity(for: draftRecord) else {
                return .refused("The server draft could not be safely identified, so it was not discarded.")
            }
            guard await AccountManager.shared.queueDraftDelete(
                identity: identity,
                accountId: draftRecord.accountId,
                folderPath: draftRecord.serverDraftFolderPath,
                draftId: draftRecord.id,
                instanceEpoch: epoch,
                deleteOwnedLocalDraft: true) else {
                return .refused("The server draft delete could not be saved, so the draft was not discarded.")
            }
        case .deleteLocalDraft:
            do {
                guard try await DraftStore.shared.deleteAsync(
                    id: draftRecord.id, expectedInstanceEpoch: epoch) else {
                    return .refused("This draft changed in another compose window and was not discarded.")
                }
                // MATCHED-DIR cleanup (v2final F0f, applied at the caller). Under
                // copy-on-write staging the on-disk directory is an opaque UUID, no
                // longer the draftId, so `DraftStore.deleteAsync`'s own
                // `deleteAttachments(dirName: id)` no longer names it. Destroy the
                // dir the ROW actually pointed at, and only AFTER the row delete has
                // committed (persist-before-destroy). Every other draft-delete site
                // (`AccountManagerActions` queueDraftDelete drain,
                // `AccountManagerOutbox` send finalize, `InboxViewModel` swipe,
                // `DraftStore.evictImpl`) already deletes by the row's own
                // `attachmentsDirName`, so this is the only gap.
                if let dir = draftRecord.attachmentsDirName {
                    DraftAttachmentStorage.deleteAttachments(dirName: dir)
                }
            } catch {
                return .refused("The draft could not be discarded: \(error.localizedDescription)")
            }
        }
        return .dismiss
    }

    private static func typedDeleteIdentity(for draft: Draft) async -> DraftDeleteIdentity? {
        guard let serverId = draft.serverDraftId,
              !serverId.isEmpty,
              let kind = await AccountManager.shared.draftRuntimeIdentityKind(
                accountId: draft.accountId) else { return nil }
        switch kind {
        case .gmail:
            return .gmail(resourceId: serverId)
        case .outlook:
            return .outlook(graphId: serverId)
        case .demo:
            return .demo(localId: serverId)
        case .imap:
            guard let folder = draft.serverDraftFolderPath,
                  let epoch = draft.serverDraftUidValidity,
                  let uid = Int(serverId), uid > 0 else { return nil }
            return .imap(folder: folder, uidValidity: epoch, uid: uid)
        case .unknown:
            return nil
        }
    }
}
