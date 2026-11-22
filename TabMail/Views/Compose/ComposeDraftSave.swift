/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// A draft written as compose's Save writes it, for compose and for the chat view's new email
/// (`ChatNewDraftSave`), so the two editors never order the steps differently:
///
/// 1. One read of the row. A thrown read is not absence: nothing is written.
/// 2. The attachments staged in a fresh directory (`DraftAttachmentStorage.newStagingDirName`),
///    never the live one, so a failed or rolled-back save leaves the live files untouched.
/// 3. The row built by `ComposeDraftGuards.draftToSave` and saved through the editor's
///    generation (`admit`).
/// 4. Only once the save committed, the staged or superseded directory removed
///    (`ComposeDraftGuards.attachmentDisposition`).
///
/// The caller queues the push to the server's Drafts (`AccountManager.queueDraftSave`) only on
/// `.committed`, and words every other outcome its own way. It lives outside the view so tests
/// run the production path against a real database.
@MainActor
enum ComposeDraftSave {
    /// What the editor wrote. `fields` is given the row read at the start (nil when the key holds
    /// none), so an editor without a subject, Cc or Bcc of its own keeps the row's.
    struct Fields {
        var to: [String]
        var cc: [String]
        var bcc: [String]
        var subject: String
        var body: String
        var replyTo: MessageHeader?
        var isForward: Bool
        var isReplyAll: Bool
    }

    enum Outcome: Equatable {
        /// The save committed and this snapshot was adopted. `previousPushStatus` is the row's
        /// server push status before it (nil for a first save).
        case committed(previousPushStatus: String?)
        /// The row read threw: nothing was written.
        case readFailed
        /// The attachments could not be staged: nothing was written.
        case attachmentsNotStaged(reason: String)
        /// The save threw or rolled back: the row and its attachments are as they were.
        case saveFailed(reason: String)
        /// A newer save of this draft already won: this snapshot was not adopted, and the live
        /// row and attachments are intact.
        case superseded
    }

    static func run(
        draftId: String,
        accountId: String,
        attachments: [DraftAttachment],
        now: Double,
        fields: @MainActor (_ existing: Draft?) -> Fields,
        admit: @MainActor (Draft) async throws -> DraftStore.SaveResult
    ) async -> Outcome {
        // PORT — v2final `saveDraftAndDismiss`'s "N2: ONE throwing draft read at
        // the TOP, BEFORE any disk or DB mutation". This replaces the TWO separate
        // `try?` reads an earlier forward-port carried (one for `attachmentsDirName`,
        // one for the merge base), each of which turned a THROWN read into "absent":
        //   - the dir read fell through to the raw `draftId` path and DELETED the
        //     live attachment directory it had merely failed to see;
        //   - the merge read fell through to the INSERT branch, whose
        //     `editHistoryJSON: nil` then clobbered the row's stored AI edit history
        //     through `DraftStore.applySave`'s merge.
        // A thrown read is NOT absence: FAIL CLOSED with nothing written, and let
        // the user retry. A genuine nil still takes the normal first-save path.
        let readResult: Result<Draft?, Error>
        do {
            readResult = .success(try await AppDatabase.dbPool.read { db in
                try Draft.fetchOne(db, key: draftId)
            })
        } catch {
            readResult = .failure(error)
        }
        guard ComposeDraftGuards.saveMayMutate(readState: ComposeDraftGuards.readState(readResult)),
              case .success(let existing) = readResult else {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ComposeDraftSave] ⚠ Save-path draft read THREW for draftId=\(draftId) — failing closed (no disk/DB write)")
            }
            return .readFailed
        }
        let previousDirName = existing?.attachmentsDirName

        // PORT — v2final `saveDraftAndDismiss`'s F0d COPY-ON-WRITE attachment
        // staging. Persist attachments to disk BEFORE the DB write (file I/O
        // outside GRDB transactions), but into a FRESH, opaque-UUID staging dir —
        // NEVER the live dir. An earlier call site wrote into
        // `existingDirName ?? draftId`, which (a) DELETED the live set before
        // rewriting it, so a failed/rolled-back save left the row pointing at
        // destroyed or half-written files, and (b) used the raw `draftId` as a path
        // component — and a draftId may contain `/` (a `reply:<acct>:<Message-ID>`
        // key, an Exchange base64 id), which `appendingPathComponent` treats as a
        // SEPARATOR and silently nests outside the intended slot. See
        // `DraftAttachmentStorage.newStagingDirName()`.
        //
        // ORPHAN-ON-CRASH: a kill after this staging write but before the row adopts
        // it leaves an unreferenced opaque-UUID dir. That is a bounded disk leak —
        // never data loss — and does not grow during crash-free operation.
        let stagingDirName: String?
        if attachments.isEmpty {
            // N→0 (drop-all) or 0→0: the row will carry a nil dir; the OLD dir (if
            // any) is destroyed ONLY post-commit. No staging dir here.
            stagingDirName = nil
        } else {
            let staging = DraftAttachmentStorage.newStagingDirName()
            do {
                try DraftAttachmentStorage.saveAttachments(attachments, dirName: staging)
            } catch {
                // Staging write failed — nothing durable changed. Best-effort clean
                // the partial staging dir; the live dir is UNTOUCHED.
                DraftAttachmentStorage.deleteAttachments(dirName: staging)
                return .attachmentsNotStaged(reason: error.localizedDescription)
            }
            stagingDirName = staging
        }

        // Route through DraftStore's save (NOT a raw GRDB write, which `admit` wraps):
        // the store marks serverPushStatus "pushed" → "dirty" so pushDraftToServer
        // doesn't early-return. Without this, a 2nd-save-onwards draft never
        // actually reaches the server — queueDraftSave drains but pushDraft
        // sees `serverPushStatus == "pushed"` (from the previous push) and
        // bails before sending the update. `existing` was read fail-closed above.
        let written = fields(existing)
        let draft = ComposeDraftGuards.draftToSave(
            existing: existing, id: draftId, accountId: accountId,
            recipients: (written.to, written.cc, written.bcc), subject: written.subject, body: written.body,
            replyTo: written.replyTo, isForward: written.isForward, isReplyAll: written.isReplyAll,
            attachmentsDirName: stagingDirName, now: now)

        // The staging-cleanup catch covers ONLY the save. Once the save has
        // COMMITTED (either result), the staging dir's fate is decided by the
        // disposition below and NOTHING afterward (queueDraftSave, dismiss…) may
        // delete it — deleting it post-commit would destroy the now-LIVE dir.
        let saveResult: DraftStore.SaveResult
        do {
            saveResult = try await admit(draft)
        } catch {
            // The save threw / rolled back — nothing durable adopted our staging
            // dir. Delete ONLY the staging dir; leave the live dir UNTOUCHED
            // (persist-before-destroy).
            if case .deleteStaging(let dir) = ComposeDraftGuards.attachmentDisposition(
                saveApplied: false, stagingDir: stagingDirName, previousDir: previousDirName) {
                DraftAttachmentStorage.deleteAttachments(dirName: dir)
            }
            return .saveFailed(reason: error.localizedDescription)
        }
        // Disposition-driven attachment cleanup (persist-before-destroy). The DB
        // has durably committed; only NOW is it safe to destroy files.
        switch ComposeDraftGuards.attachmentDisposition(
            saveApplied: saveResult == .applied,
            stagingDir: stagingDirName, previousDir: previousDirName
        ) {
        case .deleteSuperseded(let dir), .deleteStaging(let dir):
            DraftAttachmentStorage.deleteAttachments(dirName: dir)
        case .noCleanup:
            break
        }
        guard saveResult == .applied else {
            // A newer snapshot already won on disk — our snapshot was NOT adopted.
            // Its staging dir was destroyed above; the live dir is intact.
            return .superseded
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[ComposeDraftSave] Saved draft: id=\(draftId) prevStatus=\(existing?.serverPushStatus ?? "nil")")
        }
        return .committed(previousPushStatus: existing?.serverPushStatus)
    }
}
