/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Persistent draft storage for compose sessions.
/// Saves/loads/deletes drafts and their associated chat turns.
actor DraftStore {
    static let shared = DraftStore()

    enum SaveResult: Sendable, Equatable {
        case applied
        case notApplied
    }

    /// ⚑ THERE IS NO "the provider threw" DISPOSITION, DELIBERATELY. A thrown
    /// provider call does not RETURN from `pushDraftToServer` at all — it is
    /// rethrown, so the caller's queue requeues the durable producer. See
    /// `restorePushableAfterProviderThrow`. The removed `.terminalUnconfirmed`
    /// case existed only to report a never-drop violation to a caller that then
    /// retired the op on it.
    enum PushDisposition: Sendable, Equatable {
        case completed
        /// A replacement/edit won the exact Stage A/B CAS. This producer is stale.
        case notApplied
    }

    enum DraftEpochAdmissionError: Error, LocalizedError {
        case staleOrReserved

        var errorDescription: String? {
            "This draft was changed by another compose session and can't be saved from here."
        }
    }

    // MARK: - Save

    /// PORT — v2final observed-predecessor generation CAS (3f2cc4c34).
    @discardableResult
    static func admitSave(
        _ draft: Draft,
        newEpoch: String,
        expectedPredecessor: String?,
        db: Database
    ) throws -> SaveResult {
        let observed = try Draft.fetchOne(db, key: draft.id)
        guard let observed else {
            guard expectedPredecessor == nil else {
                throw DraftEpochAdmissionError.staleOrReserved
            }
            var inserted = draft
            inserted.instanceEpoch = newEpoch
            return try applySave(inserted, db: db)
        }
        if observed.instanceEpoch != newEpoch {
            guard observed.instanceEpoch == expectedPredecessor else {
                throw DraftEpochAdmissionError.staleOrReserved
            }
        }
        var admitted = draft
        admitted.instanceEpoch = newEpoch
        let result = try applySave(admitted, db: db)
        if result == .applied {
            try db.execute(
                sql: "UPDATE draft SET instanceEpoch = ? WHERE id = ?",
                arguments: [newEpoch, draft.id])
        }
        return result
    }

    @discardableResult
    nonisolated func save(
        _ draft: Draft,
        epoch newEpoch: String,
        expectedPredecessor: String?
    ) throws -> SaveResult {
        try AppDatabase.dbPool.write {
            try Self.admitSave(
                draft, newEpoch: newEpoch,
                expectedPredecessor: expectedPredecessor, db: $0)
        }
    }

    @discardableResult
    nonisolated func saveAsync(
        _ draft: Draft,
        epoch newEpoch: String,
        expectedPredecessor: String?
    ) async throws -> SaveResult {
        try await AppDatabase.dbPool.write {
            try Self.admitSave(
                draft, newEpoch: newEpoch,
                expectedPredecessor: expectedPredecessor, db: $0)
        }
    }

    /// PORT — merge authored fields only and bump the Stage A/B conflict version.
    ///
    /// SUBTRACT — v2final's F3a BACK-SEED (`applySave`'s
    /// `if merged.serverDraftId == nil, let seeded = draft.serverDraftId { … }` and
    /// its `rfc822MessageId` twin) is deliberately NOT ported. Census over every v3
    /// producer of a `Draft` reaching this function — `ComposeView.saveDraftAndDismiss`
    /// (`draftToSave`), `ComposeView.send` (`ownedDraft`), and
    /// `DynamicIslandChatButton.autoSaveDraft` (both branches) — shows each one takes
    /// its linkage from a prior read of THIS row or leaves it nil; v3 has no
    /// `ServerDraftOpen.seedServerLinkage` equivalent, and its open path
    /// (`ServerDraftComposeLoader` → `LocallyAuthoredDraftOpenAuthority.matches`)
    /// fails closed unless the durable row ALREADY carries the exact provider-native
    /// address. So the reference's "rfc822-matched row with a nil serverDraftId"
    /// premise is unreachable here, and the only state a back-seed could restore is
    /// the linkage `applyPushCompletion`'s `.unaddressable` arm deliberately CLEARED —
    /// resurrecting a provider address the provider disowned, from a bare id that for
    /// IMAP would arrive without its `serverDraftFolderPath`/`serverDraftUidValidity`
    /// half. Do not add it back without a fresh reachability proof.
    @discardableResult
    static func applySave(_ draft: Draft, db: Database) throws -> SaveResult {
        guard let current = try Draft.fetchOne(db, key: draft.id) else {
            var inserted = draft
            if inserted.serverPushStatus == "pushed" { inserted.serverPushStatus = "dirty" }
            // PORT — assign the monotonic eviction-recency key. On an INSERT the MAX
            // excludes this not-yet-inserted row, so the new seq is strictly greater
            // than every existing row and the new draft sorts newest.
            inserted.lastTouchedSeq = try Self.nextLastTouchedSeq(db)
            try inserted.insert(db)
            return .applied
        }
        // PORT — OUT-OF-ORDER-SAVE GUARD. `save`/`saveAsync` are nonisolated, so two
        // in-flight saves are not serialized against each other: an OLDER snapshot can
        // commit AFTER a NEWER one. Writing it unconditionally would clobber the newer
        // authored content and move `updatedAt` BACKWARD (a local lost update). If the
        // incoming snapshot is older than the row already on disk, the newer edit
        // already won — SKIP the write entirely, leaving the row (including its
        // `serverPushStatus`, its provider linkage and its `lastTouchedSeq`) untouched.
        // `updatedAt` is a full-precision Double of epoch seconds: an equal-`updatedAt`
        // save is a negligible no-op, and a clock-backward snapshot is a rare accepted
        // edge.
        guard draft.updatedAt >= current.updatedAt else {
            if DebugModeManager.isLoggingEnabled() {
                print("[DraftStore] applySave: skipping stale snapshot for \(draft.id) — incoming updatedAt=\(draft.updatedAt) < current=\(current.updatedAt)")
            }
            return .notApplied
        }
        var merged = current
        merged.toJSON = draft.toJSON
        merged.ccJSON = draft.ccJSON
        merged.bccJSON = draft.bccJSON
        merged.subject = draft.subject
        merged.body = draft.body
        merged.editHistoryJSON = draft.editHistoryJSON
        merged.updatedAt = draft.updatedAt
        merged.attachmentsDirName = draft.attachmentsDirName
        merged.pushAttemptVersion = current.pushAttemptVersion + 1
        // `"unconfirmed"` is NO LONGER WRITTEN by any code path — the provider-throw
        // arm now restores `"dirty"` and rethrows — but the remap is KEPT so a dev
        // database that already carries that value from the pre-fix candidate still
        // recovers on the next authored edit instead of being permanently
        // inadmissible to `pushDraftToServer`'s entry guard.
        if current.serverPushStatus == "pushed" || current.serverPushStatus == "pushing"
            || current.serverPushStatus == "unconfirmed" {
            merged.serverPushStatus = "dirty"
        }
        // PORT — bump the monotonic eviction-recency key. This save TOUCHED the draft,
        // so it floats to the top of the eviction order. `MAX+1` under the single
        // serialized writer is strictly increasing (no wall-clock tie, no rollback).
        // The `.notApplied` stale path above returned WITHOUT reaching here, so a
        // losing snapshot never bumps.
        merged.lastTouchedSeq = try Self.nextLastTouchedSeq(db)
        try merged.update(db)
        return .applied
    }

    /// PORT — v2final `DraftStore.nextLastTouchedSeq`. The next monotonic
    /// eviction-recency sequence, computed INSIDE the save write transaction. GRDB's
    /// `DatabasePool` serializes writers, so `MAX+1` across concurrent saves is
    /// strictly increasing with no wall-clock ties and no clock rollback.
    ///
    /// The value is distinct and increasing among CURRENTLY-RETAINED rows, which is
    /// all eviction recency needs; it is NOT a global-across-time identity. A value
    /// freed by deleting the MAX row may be reused, which is harmless because
    /// eviction only ever compares surviving rows (`MAX+1` always exceeds every
    /// survivor). Never use it as a conflict version — that is `pushAttemptVersion`.
    private static func nextLastTouchedSeq(_ db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(lastTouchedSeq), 0) FROM draft") ?? 0) + 1
    }

    // MARK: - Load

    /// Load a draft by its key.
    /// Nonisolated: body doesn't touch actor-local state — lets sync call
    /// sites (e.g. PendingSendService.undo) avoid an actor hop.
    nonisolated func load(id: String) throws -> Draft? {
        try AppDatabase.dbPool.read { db in
            try Draft.fetchOne(db, key: id)
        }
    }

    // MARK: - Delete

    /// Delete a draft and its associated chat turns.
    /// Nonisolated: same rationale as `save` and `load`.
    /// PORT — generation-owned delete. A stale compose instance cannot erase a
    /// successor that has taken the same logical draft key.
    @discardableResult
    nonisolated func deleteAsync(
        id: String,
        expectedInstanceEpoch: String
    ) async throws -> Bool {
        let deleted = try await AppDatabase.dbPool.write { db -> Bool in
            guard let current = try Draft.fetchOne(db, key: id),
                  current.instanceEpoch == expectedInstanceEpoch else {
                return false
            }
            try Self.applyDelete(
                id: id, expectedInstanceEpoch: expectedInstanceEpoch, db: db)
            return true
        }
        if deleted {
            DraftAttachmentStorage.deleteAttachments(dirName: id)
            print("[DraftStore] Deleted owned draft + turns (async) for id=\(id)")
        }
        return deleted
    }

    /// The delete transaction body, shared by the sync + async overloads.
    static func applyDelete(
        id: String,
        expectedInstanceEpoch: String,
        db: Database
    ) throws {
        guard let current = try Draft.fetchOne(db, key: id),
              current.instanceEpoch == expectedInstanceEpoch else {
            throw DraftEpochAdmissionError.staleOrReserved
        }
        // Delete the draft record
        _ = try Draft.deleteOne(db, key: id)
        let sessionIds = ["compose:\(id)", "demo:compose:\(id)"]
        _ = try ChatTurn.filter(sessionIds.contains(Column("sessionId"))).deleteAll(db)
    }

    // MARK: - Query

    /// Check if a draft exists for a given key.
    func exists(id: String) throws -> Bool {
        try AppDatabase.dbPool.read { db in
            try Draft.fetchOne(db, key: id) != nil
        }
    }

    /// Load all drafts ordered by updatedAt DESC.
    func loadAll() throws -> [Draft] {
        try AppDatabase.dbPool.read { db in
            try Draft.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    // MARK: - Server Push

    /// Push a local draft to the server's Drafts folder.
    /// Builds a DraftMessage from the local Draft, calls provider.saveDraft(),
    /// and stores the returned server draft ID.
    struct StageAContext: Sendable {
        let draftId: String
        let accountId: String
        let instanceEpoch: String
        let postAPushAttemptVersion: Int
        let freshRfc: String
        let previousIdentity: DraftDeleteIdentity?
    }

    private struct HeaderMigration: Sendable {
        let oldHeaderId: String
        let newHeaderId: String
        let newMessageId: String
    }

    /// PORT — reduced v2final `PushCompletion.advanced` plus its independent
    /// migration payload. A successful completion may legitimately have no
    /// header to migrate; a rejected Stage-B CAS is a different outcome.
    private struct PushCompletion: Sendable {
        let applied: Bool
        let migration: HeaderMigration?
    }

    /// PORT — reduced v2final DraftStoreStageAB.performStageA.
    static func performStageA(
        initialDraft: Draft,
        expectedInstanceEpoch: String,
        previousIdentity: DraftDeleteIdentity?,
        freshRfc: String,
        db: Database
    ) throws -> StageAContext? {
        guard var current = try Draft.fetchOne(db, key: initialDraft.id),
              current.accountId == initialDraft.accountId,
              current.instanceEpoch == expectedInstanceEpoch,
              current.serverPushStatus == nil || current.serverPushStatus == "dirty",
              current.pushAttemptVersion == initialDraft.pushAttemptVersion else {
            return nil
        }
        let postAVersion = current.pushAttemptVersion + 1
        current.rfc822MessageId = freshRfc
        current.serverPushStatus = "pushing"
        current.pushAttemptVersion = postAVersion
        try current.update(db)
        return StageAContext(
            draftId: current.id,
            accountId: current.accountId,
            instanceEpoch: expectedInstanceEpoch,
            postAPushAttemptVersion: postAVersion,
            freshRfc: freshRfc,
            previousIdentity: previousIdentity)
    }

    private static func priorIdentity(
        for draft: Draft,
        runtimeKind: DraftRuntimeIdentityKind
    ) -> DraftDeleteIdentity? {
        guard let serverId = draft.serverDraftId, !serverId.isEmpty else {
            return nil
        }
        switch runtimeKind {
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

    /// PORT — reduced normal-completion arm of v2final applyPushCompletion.
    /// SUBTRACT: lineage, receipts, recovery, ghost, S3 and redrive.
    private static func applyPushCompletion(
        context: StageAContext,
        outcome: DraftSaveOutcome,
        runtimeKind: DraftRuntimeIdentityKind,
        draftsFolderPath: String,
        db: Database
    ) throws -> PushCompletion {
        guard var draft = try Draft.fetchOne(db, key: context.draftId),
              draft.accountId == context.accountId,
              draft.instanceEpoch == context.instanceEpoch,
              draft.pushAttemptVersion == context.postAPushAttemptVersion,
              draft.serverPushStatus == "pushing",
              draft.rfc822MessageId == context.freshRfc else {
            return PushCompletion(applied: false, migration: nil)
        }

        switch outcome {
        case .unaddressable:
            // Terminal for this attempt, without persistent lifecycle state.
            draft.serverDraftId = nil
            draft.serverDraftUidValidity = nil
            draft.serverDraftFolderPath = nil
            draft.serverPushStatus = nil
            try draft.update(db)
            return PushCompletion(applied: true, migration: nil)

        case .created(let address):
            let realMessageId: String?
            switch (runtimeKind, address) {
            case (.gmail, .gmail(let resourceId, let containedMessageId)):
                draft.serverDraftId = resourceId
                draft.serverDraftUidValidity = nil
                draft.serverDraftFolderPath = nil
                // SUBTRACT — the contained MESSAGE id is display bookkeeping,
                // not Draft mutation authority. If Gmail did not return it for
                // this exact attempt, let sync create the provider header.
                realMessageId = containedMessageId
            case (.outlook, .outlook(let graphId)):
                draft.serverDraftId = graphId
                draft.serverDraftUidValidity = nil
                draft.serverDraftFolderPath = nil
                realMessageId = graphId
            case (.imap, .imap(let folder, let uidValidity, let uid)):
                guard folder == draftsFolderPath else {
                    throw ProviderError.actionIdentityResolutionFailed(
                        "IMAP draft address returned for a different mailbox")
                }
                draft.serverDraftId = String(uid)
                draft.serverDraftUidValidity = uidValidity
                draft.serverDraftFolderPath = folder
                realMessageId = String(uid)
            case (.demo, .demo(let localId)):
                draft.serverDraftId = localId
                draft.serverDraftUidValidity = nil
                draft.serverDraftFolderPath = nil
                realMessageId = localId
            default:
                throw ProviderError.actionIdentityResolutionFailed(
                    "draft provider returned an address from the wrong namespace")
            }
            draft.serverPushStatus = "pushed"
            try draft.update(db)

            guard let realMessageId else {
                return PushCompletion(applied: true, migration: nil)
            }
            let oldHeaderId = PendingOperation.draftPlaceholderHeaderPK(
                accountId: context.accountId,
                draftsFolderPath: draftsFolderPath,
                draftId: context.draftId,
                instanceEpoch: context.instanceEpoch)
            return PushCompletion(
                applied: true,
                migration: HeaderMigration(
                    oldHeaderId: oldHeaderId,
                    newHeaderId: "\(context.accountId):\(draftsFolderPath):\(realMessageId)",
                    newMessageId: realMessageId))
        }
    }

    /// 🚨 A THROWN PROVIDER SAVE IS AN **UNKNOWN**, AND UNKNOWN IS RETRYABLE.
    ///
    /// This used to stamp `serverPushStatus = "unconfirmed"` and let
    /// `pushDraftToServer` RETURN `.terminalUnconfirmed` — a normal return — so
    /// `AccountManagerQueue.executeSingleOp`'s SUCCESS path ran
    /// `PendingOperation.deleteOne` and the user's Save intention was retired
    /// after ONE attempt, on an ordinary mobile network drop. Nothing re-enqueues
    /// on `serverPushStatus` (`IOS-DRAFT-011` states that outright), so only a
    /// later authored edit could create a fresh producer. That is outside the four
    /// exits: a thrown call is none of (1) provider success, (2) a provider-
    /// AUTHORITATIVE stale/no-op verdict, (3) inverse annihilation, (4) a proven
    /// id reset — `CLAUDE.md` clause 2 names a thrown read as retryable, never
    /// authoritative. Shipped `07a4bb703` awaited the throwing call directly, so
    /// the error reached the queue's retry arm and the durable op survived; the
    /// candidate was a REGRESSION FROM SHIPPED and this restores it.
    ///
    /// `IOS-DRAFT-011`'s "K is bounded by explicit user gestures / no sweeper
    /// re-enqueues" accounting argues for the retired behaviour — but it was
    /// written about `.unaddressable`, a provider-AUTHORITATIVE "I cannot give you
    /// an address" (exit 2). A network throw is an absence of evidence. Never-drop
    /// clause 2 and Outbox Reliability Rule 4 ("Duplicate email >> lost email")
    /// both put it on the retry side.
    ///
    /// ⚠️ THE FIX IS **BOTH HALVES**, and neither alone. The row is restored to
    /// `"dirty"` — the only non-nil value `pushDraftToServer`'s entry guard admits
    /// — AND the caller rethrows. Keeping the op queued while leaving the row
    /// `"unconfirmed"` would make every retry fall out of that entry guard with
    /// `.notApplied` forever: a permanent lane wedge, which is in the
    /// NON-recoverable set. Restoring the row without rethrowing would retire the
    /// op exactly as before.
    ///
    /// SUBTRACT — still no `v2final` recovery/ghost/redrive machinery, and none is
    /// needed: restoring shipped behaviour requires no sweeper, no reconciler and
    /// no RFC redrive. The exact-ownership guard below is UNCHANGED, so a losing
    /// racer — an authored edit or a generation replacement that won the Stage A/B
    /// CAS while the provider call was in flight — still no-ops here and its newer
    /// state is never clobbered. Authored fields and the prior provider-native
    /// linkage stay untouched.
    ///
    /// ⚠️ ACCEPTED RESIDUAL, registered as `IOS-DRAFT-015`: an attempt that
    /// actually committed on the server before its response was lost leaves one
    /// stray server draft, because the retry still carries the pre-attempt
    /// `previousIdentity`. Strays are ordinary Drafts-folder messages, synced with
    /// real UIDs and deletable by the ordinary path — the exact accounting
    /// `IOS-DRAFT-011` already accepts for the same reason.
    @discardableResult
    private static func restorePushableAfterProviderThrow(
        context: StageAContext,
        db: Database
    ) throws -> Bool {
        guard var draft = try Draft.fetchOne(db, key: context.draftId),
              draft.accountId == context.accountId,
              draft.instanceEpoch == context.instanceEpoch,
              draft.pushAttemptVersion == context.postAPushAttemptVersion,
              draft.serverPushStatus == "pushing",
              draft.rfc822MessageId == context.freshRfc else {
            return false
        }
        draft.serverPushStatus = "dirty"
        try draft.update(db)
        return true
    }

    private static func migrateExactPlaceholder(
        _ migration: HeaderMigration,
        freshRfc: String,
        db: Database
    ) throws -> Bool {
        guard var placeholder = try MessageHeader.fetchOne(db, key: migration.oldHeaderId) else {
            return false
        }
        if try MessageHeader.fetchOne(db, key: migration.newHeaderId) != nil {
            _ = try MessageBody.deleteOne(db, key: ContentKey(rawValue: placeholder.id))
            try placeholder.delete(db)
            return false
        }
        try placeholder.delete(db)
        placeholder.id = migration.newHeaderId
        placeholder.messageId = migration.newMessageId
        placeholder.rfc822MessageId = freshRfc
        try placeholder.insert(db)
        if var body = try MessageBody.fetchOne(db, key: ContentKey(rawValue: migration.oldHeaderId)) {
            try body.delete(db)
            body.id = ContentKey(rawValue: migration.newHeaderId)
            try body.insert(db)
        }
        return true
    }

    /// PORT — exact pre-A initialDraft/payload + StageAContext shape. Stage A
    /// revalidates generation/version/status before provider I/O; Stage B applies
    /// only the exact post-A version/status/generation/fresh-RFC completion.
    func pushDraftToServer(
        draftId: String,
        expectedInstanceEpoch: String,
        provider: any EmailProvider,
        runtimeKind: DraftRuntimeIdentityKind,
        draftsFolderPath: String
    ) async throws -> PushDisposition {
        // ⚠️ AN UNRESOLVABLE PROVIDER KIND IS NOT AN EXIT (R11-C, 2026-08-06).
        // `.notApplied` is exit 3 — a newer generation won the Stage A/B CAS — and
        // the `.saveDraft` arm that calls this treats EVERY returned disposition as
        // a RETIREMENT of the user's Save intention. `runtimeKind == .unknown` is an
        // ABSENCE OF EVIDENCE, which never-drop clause 2 names as retryable
        // ("an unresolvable identity"), never a provider-authoritative result. So it
        // THROWS, exactly as the sibling `.deleteDraft` arm in the same switch
        // already does (`case .unknown: throw ProviderError
        // .actionIdentityResolutionFailed(encodedId)`).
        //
        // 🚨 CORRECTED 2026-08-06 (R12-T4). This paragraph used to end *"and the
        // queue's classifier REQUEUES the op instead of dropping it."* **That is
        // false, and it was the load-bearing half of the sentence.**
        // `AccountManagerQueue`'s `.actionIdentityResolutionFailed` arm is the
        // drain's TERMINAL DROP: it logs `"TERMINAL DROP: identity refused…"` and
        // executes `PendingOperation.deleteOne`. `EmailProvider`'s own declaration
        // of the case says so plainly — *"DETERMINISTIC and PRE-WIRE… The drain
        // TERMINALIZES it instead."* So this throw changes the PATH, not the
        // outcome: the op is still retired. The disposition is the one
        // `KNOWN_ISSUES.md` `IOS-QUEUE-003` item 4 adjudicates and accepts.
        //
        // ⚠️ AND DO NOT "FIX" IT BY SWAPPING THE THROW TYPE. The obvious
        // alternative, `ProviderEvidenceUnavailable`, lands in the requeue +
        // `retryCount += 1` + `.haltLane` arm — and because
        // `draftRuntimeIdentityKind(for:)` is DETERMINISTIC PER PROVIDER CLASS,
        // every retry reproduces `.unknown` identically and forever. That is a
        // permanent lane wedge, which the wedge corollary puts in the same
        // non-recoverable set as a dropped intention. Swapping the type trades a
        // drop for a wedge: the mirror image of this bug, which is exactly how
        // this comment came to be wrong in the first place.
        //
        // WHAT IS ACTUALLY LOST IF THIS FIRES: the op row only. The local `Draft`
        // row is untouched, so the user's authored content survives and remains
        // visible in Drafts — it simply never reaches the server until the next
        // edit re-queues a Save. That bound is why the accepted terminal drop is
        // tolerable here and why no disposition change is being made under it.
        //
        // Unreachable in production today — `AccountManager
        // .draftRuntimeIdentityKind(for:)` switches over the four concrete
        // production `EmailProvider` conformers (`GmailProvider`,
        // `ExchangeProvider`, `IMAPProvider`, `DemoProvider`) and its
        // `default: .unknown` can only be reached by a TEST conformer injected via
        // `registerProviderForTesting`. It is fixed by classification anyway,
        // because "no caller produces the value" is a property of today's callers
        // rather than an invariant, and `.unknown` cannot be removed from the enum:
        // it is the fail-closed sentinel `MailNavigationView`'s
        // `runtimeKind != .unknown` guard and the `.deleteDraft` switch both rely
        // on, and a protocol can always gain another conformer.
        guard runtimeKind != .unknown else {
            throw ProviderError.actionIdentityResolutionFailed(draftId)
        }
        // The remaining three ARE exit 3: the row is gone, a newer generation
        // replaced it, or another push already owns it.
        guard let initialDraft = try load(id: draftId),
              initialDraft.instanceEpoch == expectedInstanceEpoch,
              initialDraft.serverPushStatus == nil || initialDraft.serverPushStatus == "dirty" else {
            return .notApplied
        }

        let domain = initialDraft.accountId.contains("@")
            ? String(initialDraft.accountId.split(separator: "@").last ?? "tabmail.local")
            : "tabmail.local"
        let freshRfc = "draft-\(UUID().uuidString)@\(domain)"

        // Compile repair for T4.D1 (not this item's scope): `loadAttachments` now
        // fails closed instead of silently returning a partial set. Hoisted above
        // the payload and above Stage A's write, so an unreadable attachment
        // directory throws BEFORE anything is persisted or sent — the producer's
        // drain retries rather than pushing a draft that lost the user's files
        // (Outbox Rule 5). Never `try?` here, and never continue with `[]`.
        let attachments = try DraftAttachmentStorage.loadAttachments(
            dirName: initialDraft.attachmentsDirName)

        // Build every provider payload field from the exact pre-A snapshot.
        var payload = DraftMessage(
            to: initialDraft.toArray,
            cc: initialDraft.ccArray,
            bcc: initialDraft.bccArray,
            subject: initialDraft.subject,
            body: MessageBody.plainTextToHTML(initialDraft.body),
            isHTML: true,
            inReplyTo: nil,
            attachments: attachments)
        payload.messageId = freshRfc

        guard let context = try await AppDatabase.dbPool.write({ db in
            try Self.performStageA(
                initialDraft: initialDraft,
                expectedInstanceEpoch: expectedInstanceEpoch,
                previousIdentity: Self.priorIdentity(
                    for: initialDraft, runtimeKind: runtimeKind),
                freshRfc: freshRfc,
                db: db)
        }) else {
            return .notApplied
        }

        let outcome: DraftSaveOutcome
        do {
            outcome = try await provider.saveDraft(
                payload,
                existingIdentity: context.previousIdentity,
                draftsFolderPath: draftsFolderPath)
        } catch {
            // Re-admit the row FIRST, then RETHROW. Both halves are load-bearing —
            // see `restorePushableAfterProviderThrow`. Rethrowing is what keeps the
            // durable `.saveDraft` producer queued: the error reaches
            // `AccountManagerQueue.executeSingleOp`'s classifier, which requeues it
            // exactly as it does for every other provider throw. If the restore
            // WRITE itself throws, that error propagates instead and the op still
            // requeues (the generic arm) — the row is then left `"pushing"` until an
            // authored edit remaps it, an accepted cost recoverable by one ordinary
            // gesture, and the same exposure the pre-fix code already had.
            try await AppDatabase.dbPool.write { db in
                _ = try Self.restorePushableAfterProviderThrow(context: context, db: db)
            }
            throw error
        }

        let completion = try await AppDatabase.dbPool.write { db in
            try Self.applyPushCompletion(
                context: context,
                outcome: outcome,
                runtimeKind: runtimeKind,
                draftsFolderPath: draftsFolderPath,
                db: db)
        }

        guard completion.applied else { return .notApplied }

        if let migration = completion.migration {
            let rekeyed = try await AppDatabase.dbPool.write { db in
                try Self.migrateExactPlaceholder(
                    migration, freshRfc: context.freshRfc, db: db)
            }
            if rekeyed {
                try? await SearchIndex.shared.rekeyHeaders([(
                    oldKey: ContentKey(rawValue: migration.oldHeaderId),
                    newKey: ContentKey(rawValue: migration.newHeaderId),
                    newMessageId: migration.newMessageId)])
            } else {
                await MessageContentStore.releaseUnowned(
                    [ContentKey(rawValue: migration.oldHeaderId)],
                    stores: [.searchIndex, .body])
            }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        return .completed
    }
    /// Update serverPushStatus to "dirty" (needs re-push) for a draft.
    func markDirty(id: String) throws {
        try AppDatabase.dbPool.write { db in
            _ = try Draft.filter(Column("id") == id)
                .updateAll(db, Column("serverPushStatus").set(to: "dirty"))
        }
    }

    /// LAUNCH-ONLY crash recovery for the draft push's in-flight state. Returns the
    /// number of rows re-admitted. Runs inside the caller's transaction — see
    /// `AccountManager.reconcilePendingOperations`, which is its only caller.
    ///
    /// `performStageA` durably commits `"pushing"` BEFORE the provider call, and
    /// `pushDraftToServer`'s entry guard admits only `nil` or `"dirty"`. Every
    /// in-process failure arm already clears it (`applyPushCompletion` →
    /// `nil`/`"pushed"`, `restorePushableAfterProviderThrow` → `"dirty"`), so the
    /// only way a `"pushing"` row outlives its attempt is a CRASH in the network
    /// window — a jetsam, a force-quit, a `0xdead10cc` suspension kill — where no
    /// process is alive to run those arms. Left alone, the next drain's
    /// `.notApplied` is a NORMAL return, so `executeOperation`'s `.saveDraft` arm
    /// falls through to `.allMembers` and the durable Save producer is DELETED by
    /// none of never-drop's four exits: the guard tests a local row state, and an
    /// interrupted attempt is an UNKNOWN, which clause 2 makes retryable. Both
    /// sibling queues already sweep their own in-flight state
    /// (`PendingOperation.inFlight`, `OutboxMessage.sending`); this is the third.
    ///
    /// ⚠ WHY THE LAUNCH ENTRY AND NOT A FOREGROUND ONE. `reconcilePendingOperations`
    /// is launch-only, so at that moment nothing has drained yet IN THIS PROCESS and
    /// any `"pushing"` row is orphaned BY DEFINITION. That is what lets this carry no
    /// drain latch, and it is not a shortcut — read the banner on
    /// `AccountManagerOutbox.reconcileOutbox`, which records a real shipped bug where
    /// a reset landed on a row whose send was already on the wire. Do NOT add a
    /// foreground sweep: a foreground return within the same process cannot produce
    /// `"pushing"` residue, because the in-process arms above clear it, so a
    /// foreground sweep could only ever hit a LIVE attempt.
    ///
    /// ⚠ THE MIRROR IMAGE, and it is worse than the bug: do NOT instead make
    /// `.notApplied` throw. That would requeue the four genuinely-stale cases forever
    /// (`instanceEpoch` mismatch, `"pushed"`, a lost Stage-A CAS, a lost Stage-B CAS)
    /// — a permanent lane wedge, which is in the non-recoverable set.
    ///
    /// ⚠ ACCEPTED RESIDUAL, registered as `IOS-DRAFT-016` (same family as
    /// `IOS-DRAFT-015`): a `"pushing"` row whose Stage-B *reset write* fails
    /// transiently inside a LIVE process stays stuck until the next launch. That is
    /// recoverable — the next launch, or one authored edit via `applySave`'s remap —
    /// and only the SERVER copy is stale; the local `Draft` content is intact. It is
    /// deliberately not mechanised.
    ///
    /// ⚠ RE-PUSH DUPLICATE RISK, stated rather than hidden: if the APPEND landed
    /// server-side before the crash, the retry can create a duplicate server draft.
    /// That is exactly shipped `07a4bb703`'s behaviour, and the same trade the outbox
    /// makes explicitly ("accepts the small double-send risk"). It is the correct
    /// direction — a duplicate draft is recoverable, a dropped Save producer is not.
    static func resetOrphanedPushingDrafts(db: Database) throws -> Int {
        try Draft.filter(Column("serverPushStatus") == "pushing")
            .updateAll(db, Column("serverPushStatus").set(to: "dirty"))
    }

    /// Look up the Drafts folder path for an account.
    func draftsFolderPath(accountId: String) throws -> String {
        try AppDatabase.dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.drafts.rawValue)
                .fetchOne(db)?.path ?? "Drafts"
        }
    }


    // MARK: - Eviction

    /// Evict old compose drafts beyond the limit.
    /// Drafts tied to inbox messages (reply/forward where message isInInbox) are exempt.
    /// Returns the number of evicted drafts.
    @discardableResult
    func evict(limit: Int) throws -> Int {
        try Self.evictImpl(dbPool: AppDatabase.dbPool, limit: limit)
    }

    /// Nonisolated eviction for background maintenance thread.
    nonisolated func evictSync(dbPool: PrioritizedDatabase, limit: Int) throws -> Int {
        try Self.evictImpl(dbPool: dbPool, limit: limit)
    }

    /// SUBTRACT — v2final's `pendingSaveDraftIds` exemption (G8-5a) is not ported.
    /// It existed to stop an evicted Draft un-gating an epoch-aligned recovery
    /// `.saveDraft` frontier outside the matched 4-wake set, stranding the global
    /// FIFO — machinery v3 does not have. Here a `.saveDraft` whose Draft row is
    /// gone reaches `pushDraftToServer`, fails the `load(id:)` guard, returns
    /// `.notApplied`, and the producer retires normally. No wedge, so no exemption.

    private static func evictImpl(dbPool: PrioritizedDatabase, limit: Int) throws -> Int {
        // Collect attachment dirs to delete outside the DB transaction (file I/O outside transaction)
        var attachmentDirsToDelete: [String] = []

        // PORT — snapshot the compose sessions the user currently has OPEN. Every
        // deletion below EXEMPTS them so background maintenance never drops a draft
        // (or its authored chat turns) mid-compose. Both guard forms are derived from
        // ONE snapshot so the draft-row guard and the orphan-session guard can never
        // disagree (a register/unregister landing between two separate reads would
        // otherwise protect one but not the other).
        //
        // 🚨 THIS SNAPSHOT IS THE CHEAP FIRST FILTER, NOT THE AUTHORITY. It is read
        // BEFORE `dbPool.write` opens, so a compose that calls `register(draftId)`
        // after this line is invisible to it. ⚠️ CORRECTED 2026-08-05: this comment
        // previously claimed the register-vs-commit window "only ever costs a
        // retention, and the next maintenance pass reclaims a genuinely stale row".
        // That was the exact OPPOSITE of the truth — a compose registering after the
        // snapshot was not exempt, so the sweep deleted its draft row, its authored
        // compose chat turns and its attachment directory while the user was typing
        // into it. That is a loss of authored user bytes, not a retention.
        //
        // Both loops below therefore re-ask the registry LIVE, inside the write
        // transaction, at the point the deletion decision for that row is taken.
        // `DraftSessionRegistry` is a `Sendable final class` over a `Mutex`, so its
        // reads are nonisolated and synchronous and are legal inside this block.
        //
        // RESIDUAL, stated precisely rather than claimed closed: the live check moves
        // the exposure from [snapshot .. commit] down to [this row's own check ..
        // commit]. A `register` that lands after this row has already been examined
        // still misses, because the row is by then deleted inside the open
        // transaction.
        //
        // ⚠️ CORRECTED AGAIN 2026-08-05 — the justification that used to sit here
        // ("the compose holds the draft in memory and its next save re-inserts the
        // row") is FALSE for the case that actually matters. `ComposeView` calls
        // `DraftSessionRegistry.shared.register(draftId)` and only THEN kicks off
        // `Task { await loadDraftOrPrepopulate() }`, so in the failing interleaving
        // the compose is still OPENING: it holds nothing in memory, its load queues
        // behind this writer and observes the committed deletion. What is lost is
        // the draft row, its authored compose chat turns and its attachment
        // directory — authored user bytes, and for a local-only draft nothing
        // re-derives them.
        //
        // THE BOUND: this function records `DraftSessionRegistry`'s registration
        // generation before opening the transaction and re-reads it as the LAST
        // statement inside it. Any compose that registered anywhere in between —
        // before the snapshot's window, between two rows, or after the final row —
        // makes the two readings differ, and the whole eviction is rolled back by
        // throwing. Nothing is deleted, the caller sees zero evicted, and the next
        // maintenance pass tries again against a registry that now includes the new
        // compose. The attachment directories, which are the one part that is not
        // re-derivable, are deleted only AFTER a successful commit, so the rollback
        // path must not reach that loop — see the early return below.
        //
        // The irreducible remainder is a `register` landing between that final read
        // and the commit itself (`IOS-DRAFT-012`). It is not closable without a
        // lock held across a DB write, which is forbidden here.
        let activeDraftIds = DraftSessionRegistry.shared.snapshot()
        let activeComposeSessions = Set(activeDraftIds.flatMap { ["compose:\($0)", "demo:compose:\($0)"] })
        let registrationsAtStart = DraftSessionRegistry.shared.registrationGeneration()

        let evictedCount: Int
        do {
        // (The transaction body below keeps its original indentation so this
        // change reads as the guard it is, not as a reformat.)
        evictedCount = try dbPool.write { db in
            // Also clean orphaned compose sessions (chatTurn with no matching draft)
            let orphanedSessions = try Row.fetchAll(db, sql: """
                SELECT DISTINCT ct.sessionId
                FROM chatTurn ct
                LEFT JOIN draft d ON d.id = SUBSTR(ct.sessionId, 9)
                WHERE ct.sessionId LIKE 'compose:%' AND d.id IS NULL
            """)
            var orphanEvicted = 0
            for row in orphanedSessions {
                let sid: String = row["sessionId"]
                // PORT — a brand-new compose has chat turns BEFORE its first Draft-row
                // save, so it looks "orphaned" here. Never delete an ACTIVE compose's
                // turns: the user is mid-conversation and those are authored bytes.
                //
                // Snapshot first (cheap), then the LIVE registry as the authority —
                // see the header comment above. `activeComposeSessionIds()` is the
                // registry's OWN derivation of the `compose:<id>` / `demo:compose:<id>`
                // forms; deriving them here by hand would fork the key format. Its cost
                // is O(open composes) — 0–2 in practice — not O(orphans).
                if activeComposeSessions.contains(sid)
                    || DraftSessionRegistry.shared.activeComposeSessionIds().contains(sid) { continue }
                _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(db)
                orphanEvicted += 1
            }
            if orphanEvicted > 0 {
                print("[DraftStore] Cleaned \(orphanEvicted) orphaned compose sessions")
            }

            // Evict oldest drafts beyond limit. PORT — order by the MONOTONIC
            // `lastTouchedSeq` (DESC) so a fresh save is never mis-ranked beyond the
            // keep-limit by an equal or rolled-back wall-clock `updatedAt`. `updatedAt`
            // is the secondary key only to order legacy rows that share a seq (none,
            // post-v79-seed; belt-and-suspenders for any future 0-defaulted row).
            let allDrafts = try Draft
                .order(Column("lastTouchedSeq").desc, Column("updatedAt").desc)
                .fetchAll(db)

            var kept = 0
            var evicted = 0
            for draft in allDrafts {
                // PORT — never evict a draft the user currently has OPEN in a
                // ComposeView (mirrors the inbox-tied exemption below: `continue`, so
                // it is neither evicted nor counted toward `kept`).
                //
                // Snapshot first (cheap), then the LIVE registry as the authority —
                // see the header comment above. This is the point at which THIS row's
                // eviction is decided, so this is where the question has to be asked.
                if activeDraftIds.contains(draft.id)
                    || DraftSessionRegistry.shared.isActive(draft.id) { continue }
                // Exempt: reply/forward drafts where the original message is still in inbox.
                // Strategy 1: lookup by GRDB PK (replyToId).
                // Strategy 2: if PK stale (IMAP MOVE), extract stableId from draft key
                //             and search by rfc822MessageId.
                //
                // T5.8 — THE REPLY-TARGET IDENTITY GUARD DELIBERATELY DOES NOT RUN HERE,
                // and must never be "completed" by adding it. `Draft.acceptsReplyTargetHit`
                // exists to stop an impostor row AUTHORIZING something (a quote, an
                // attribution, a carried-forward attachment). This lookup authorizes
                // nothing: it decides only whether to KEEP the draft alive. Its safe
                // direction is therefore the opposite one — a permissive hit costs at
                // most one retained row, while a REFUSAL makes an authored draft
                // eligible for eviction, i.e. it DELETES the user's own bytes on the
                // strength of an identity doubt. Same predicate, inverted consumer
                // direction; porting it across would turn a leak guard into a data-loss
                // mechanism.
                if let replyToId = draft.replyToId {
                    if let header = try MessageHeader.fetchOne(db, key: replyToId), header.isInInbox {
                        continue
                    }
                    // Fallback: extract stableId from draft.id.
                    // Format: "reply:{accountId}:{stableId}" or "forward:{accountId}:{stableId}".
                    // Drop the prefix ("reply:" or "forward:"), then find first ":" to separate
                    // accountId from stableId. This handles stableIds containing colons
                    // (rare but valid in rfc822MessageId local-parts).
                    let afterPrefix: Substring
                    if draft.id.hasPrefix("reply:") {
                        afterPrefix = draft.id.dropFirst(6) // "reply:".count
                    } else if draft.id.hasPrefix("forward:") {
                        afterPrefix = draft.id.dropFirst(8) // "forward:".count
                    } else {
                        afterPrefix = ""
                    }
                    if let colonIdx = afterPrefix.firstIndex(of: ":") {
                        let stableId = String(afterPrefix[afterPrefix.index(after: colonIdx)...])
                        let normalizedStableId = EmailFilter.normalizeMessageId(stableId)
                        if !normalizedStableId.isEmpty,
                           let header = try MessageHeader
                            .filter(Column("rfc822MessageId") == normalizedStableId)
                            .fetchOne(db), header.isInInbox {
                            continue
                        }
                    }
                }

                kept += 1
                if kept > limit {
                    if let dirName = draft.attachmentsDirName {
                        attachmentDirsToDelete.append(dirName)
                    }
                    // Both plain and demo-prefixed variants (see applyDelete).
                    let sessionIds = ["compose:\(draft.id)", "demo:compose:\(draft.id)"]
                    _ = try ChatTurn.filter(sessionIds.contains(Column("sessionId"))).deleteAll(db)
                    try draft.delete(db)
                    evicted += 1
                }
            }

            if evicted > 0 {
                print("[DraftStore] Evicted \(evicted) drafts (limit=\(limit))")
            }

            // THE LAST STATEMENT INSIDE THE TRANSACTION, deliberately. Everything
            // above has already been decided; this asks the one question a per-row
            // `isActive` check cannot answer — did ANY compose open while this
            // sweep was running? Throwing here makes GRDB roll the whole
            // transaction back, so a compose that is still loading finds its draft
            // exactly where it left it.
            guard DraftSessionRegistry.shared.registrationGeneration() == registrationsAtStart else {
                throw ComposeRegisteredDuringEviction()
            }
            return evicted + orphanEvicted
        }
        } catch is ComposeRegisteredDuringEviction {
            // Rolled back — nothing was deleted, so nothing may be reclaimed. In
            // particular this must return BEFORE the attachment loop: the local
            // `attachmentDirsToDelete` array keeps the appends made inside the
            // transaction even though the transaction itself was discarded, and
            // those directories are the one part of a draft that no re-save
            // rebuilds.
            if DebugModeManager.isLoggingEnabled() {
                print("[DraftStore] Eviction rolled back — a compose registered while the sweep was in flight; retrying on the next pass")
            }
            return 0
        }

        // Delete attachment files outside DB transaction
        for dirName in attachmentDirsToDelete {
            DraftAttachmentStorage.deleteAttachments(dirName: dirName)
        }

        return evictedCount
    }
}
