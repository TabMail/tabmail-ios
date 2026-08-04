/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

/// What one dispatched operation PROVED, as reported by `executeOperation` to
/// `executeSingleOp`.
struct ExecutedOperation: Sendable {
    /// The subset of `op.messageIds` the provider POSITIVELY DISPOSITIONED, or
    /// `nil` for "all of them". Retirement is per MEMBER, never per batch.
    let provenMembers: [String]?
    /// For a `.move` the server itself proved, the destination address each
    /// member's copy landed on (`COPYUID`, RFC 4315 §3). Empty for every other
    /// op type, for every provider that does not address by epoch-scoped UID,
    /// and whenever the server furnished no usable evidence.
    let provenDestinations: [ProvenDestinationAddress]

    /// Every member dispositioned, nothing re-keyable.
    static let allMembers = ExecutedOperation(provenMembers: nil, provenDestinations: [])
}

extension AccountManager {

    // MARK: - Persistent Action Queue

    /// Shared mutable state for parallel drain tasks. Reference type so concurrent
    /// lane Tasks (launched from the `AccountManager` actor) see each other's updates
    /// at await points. `internal` (not `private`) so tests can construct it directly
    /// to call `executeSingleOp`.
    class DrainContext: @unchecked Sendable {
        /// Accounts whose PROVIDER is failing — a connectivity fact, deliberately
        /// account-wide, so one drain does not hammer a server that is down.
        ///
        /// ⚠ Membership stops EVERY op on that account for the rest of the drain,
        /// so only an error that says something about the CONNECTION belongs here.
        /// A provider refusal that merely could not obtain a proof does not: see
        /// `ProviderEvidenceUnavailable` and `evidenceRefused`.
        var failedAccounts = Set<String>()
        var foldersToSync: Set<String> = []
        /// `PendingOperation.id`s whose provider could not obtain the evidence its
        /// own safety gate requires (`ProviderEvidenceUnavailable`). Per-op, not
        /// per-account: the op stays durably queued and retries on a LATER drain,
        /// while everything else on the account keeps executing in THIS one.
        ///
        /// ⚠ THE SKIP IS LOAD-BEARING, not an optimization. Without it the outer
        /// drain loop re-claims this op as soon as any other op sets `executedAny`,
        /// and a refusal can be raised AFTER a wire mutation has already gone out —
        /// so every re-attempt within one drain could repeat it. Attempt each
        /// evidence-refused op AT MOST ONCE PER DRAIN.
        ///
        /// ⚠ AUDIT ROUND 4 — the case that motivated this, `IMAPProvider.move`'s
        /// withheld-`COPYUID` refusal, is GONE (it was raised after the `UID COPY`,
        /// so each re-attempt seated another destination duplicate; RFC 4315 §3
        /// names servers for which the evidence never arrives, so it was a wedge).
        ///
        /// ⚠ CENSUS CORRECTED (`IOS-QUEUE-004`). This paragraph used to claim
        /// that "the surviving producers — the destination-epoch and source-epoch
        /// refusals — are raised BEFORE any wire mutation, so the bound is now
        /// about round trips rather than duplicates". BOTH halves were false at
        /// the tip, and the correction is recorded rather than silently applied
        /// because this comment is precisely a case of documentation outliving
        /// the code it describes. `ProviderEvidenceUnavailable` has THREE
        /// conformers, all private enums in `IMAPProvider`:
        /// `IMAPDestinationEpochRefusal`, `IMAPEpochEvidenceMissing` and
        /// `IMAPLivenessProbeInconclusive` — the third was never enumerated.
        /// Some refusal sites in `IMAPProvider.move` ARE pre-mutation
        /// (assertions A1 and A2, and `IMAPDestinationEpochRefusal
        /// .unknownAtProbe` at the destination probe), which is what made the
        /// retracted sentence plausible. But FOUR sit AFTER the `UID COPY`:
        ///  - `IMAPDestinationEpochRefusal.movedAcrossCopy` — from the `catch`
        ///    around the destination-epoch comparison, whose whole input is the
        ///    server's `COPYUID` response, so it cannot exist before the COPY.
        ///  - `IMAPLivenessProbeInconclusive.unparsedUid` — thrown from
        ///    `liveSourceUIDs`, which `move` calls ONLY on the
        ///    `copyProvenUIDs.count != sourceUIDs.count` arm, i.e. after the COPY.
        ///  - `IMAPEpochEvidenceMissing` at assertion A4 — after the COPY and
        ///    after the liveness probe, immediately before the `\Deleted` STORE.
        ///  - the same type at assertion A5 — after the COPY *and* after that
        ///    STORE, immediately before the `UID EXPUNGE`.
        /// (A3 is a fifth, sitting after the INBOX-only legacy `tm_*` flag
        /// strip; that strip is idempotent and reversible, so it is the one
        /// post-mutation site whose repetition costs nothing.)
        /// `IMAPLivenessProbeInconclusive`'s own doc comment says it "is raised
        /// AFTER the `UID COPY`, so bounding the op to one attempt per drain
        /// bounds the destination duplicates a re-attempt would seat" — the
        /// exact opposite of the retracted paragraph, in the same tree.
        ///
        /// So the bound is STILL about duplicates, not merely round trips: a
        /// UIDPLUS server that stops reporting `UIDVALIDITY` on SELECT between
        /// the COPY and A4 (SwiftMail defaults `Mailbox.Selection.uidValidity`
        /// to `UIDValidity(0)`, which `requireUidValidity`'s `live > 0` guard
        /// turns into `unknownLiveEpoch`) leaves the op copied to the
        /// destination and requeued, and every re-attempt seats another copy.
        /// The skip is what bounds that to one per drain. It stays for both
        /// reasons: it is the general contract for `ProviderEvidenceUnavailable`,
        /// not a patch for one error case, AND four of its refusal sites already
        /// refuse post-mutation today.
        ///
        /// ⚠ AND IT IS CONSULTED IN THE LANE LOOP, NEVER THE CLAIM LOOP. The op must
        /// still be claimed and still enter `buildLanes`, or its lane-mates would
        /// form a lane without it and run ahead of it — see the comment at the check
        /// itself. Skipping is about not re-attempting the PROVIDER, not about
        /// removing the op from its lane.
        var evidenceRefused: Set<String> = []
        var executedAny = false
        // op.id values that have already produced a [QueueDiag] deep-dump this drain.
        // Prevents log-spam on the same stuck op that retries every drain cycle.
        var diagnosedOpIds: Set<String> = []
    }

    /// Outcome of a single claimed-op execution (`executeSingleOp`), used by the
    /// per-lane drain loop in `drainPendingQueue` to decide whether to keep draining
    /// the lane or halt it for this pass.
    enum SingleOpOutcome: Sendable, Equatable {
        /// The op reached a terminal state this pass — either it completed
        /// successfully, or it was CONFIRMED stale/invalid and dropped (deleted, or
        /// split into fresh individual ops). The lane may proceed to its next op.
        case proceed
        /// The op was reset to `.queued` for retry (its staleness/success could NOT
        /// be confirmed this pass). The REST of this lane must halt: a later op on
        /// the same connected component (e.g. a flag change queued after a move of
        /// the same message) must never run ahead of its unresolved predecessor —
        /// running it would race the predecessor's eventual retry on the wire. The
        /// lane loop requeues the remaining claimed ops in this lane (same as the
        /// existing failedAccounts requeue path) and stops.
        case haltLane
    }

    /// Groups claimed pending operations into serialized "lanes" via connected-
    /// component grouping over shared message ADDRESSES (scoped per account AND
    /// per folder). Two ops that name ANY member at the same address land in the
    /// same lane — and transitively, any op sharing an address with either of
    /// those joins too (union-find).
    ///
    /// 🚨 THE FOLDER IS PART OF THE ADDRESS, AND OMITTING IT WAS A NEVER-DROP
    /// BUG (`IOS-QUEUE-001`). On IMAP a UID is mailbox-local: UID 77 in `INBOX`
    /// and UID 77 in `Archive` are DIFFERENT PHYSICAL MESSAGES, and every id an
    /// ordinary IMAP gesture enqueues is a bare UID
    /// (`admittedOrdinaryActionTargets` requires `messageId == String(uid)`).
    /// The lane key used to be `"accountId:msgId"`, so those two unrelated
    /// messages shared a lane. Delay was the benign half. The harmful half is
    /// the WEDGE COROLLARY WITH A BYSTANDER: `executeSingleOp`'s
    /// `ProviderEvidenceUnavailable` arm returns `.haltLane` and requeues, and a
    /// server that stops reporting `UIDVALIDITY` on SELECT reproduces that
    /// refusal identically on every drain, forever. With the folder-less key
    /// that permanent halt propagated to a message in a DIFFERENT FOLDER that
    /// merely shared the UID number — and its owner could neither see nor clear
    /// it, because no UI lists `PendingOperation` rows. An op that stays queued
    /// but prevents other intentions executing has not been preserved.
    ///
    /// The op already CARRIES the folder (`PendingOperation.folderPath`, used by
    /// checkpoint A, by `retirePartiallyCompletedOp` and by the executor), so
    /// this reads information that was present and discarded rather than
    /// reconstructing one. Every producer takes that path from the same source —
    /// a `Folder.path` or a `MessageHeader.folderPath`, never a literal — and
    /// the batch-split site in `executeSingleOp` copies `currentOp.folderPath`,
    /// so two ops on the SAME message still key identically and still serialize.
    ///
    /// The key is a plain colon join, exactly like `MessageIdentity.folderId`.
    /// A folder path containing a colon can only make two distinct addresses
    /// collide, which OVER-merges — the conservative direction, and precisely
    /// the behaviour that shipped before this change.
    ///
    /// WHY this matters: `drainPendingQueue` runs one Task per lane CONCURRENTLY,
    /// each drawing from `ProviderWorkQueue` (bounded concurrency > 1 — separate
    /// IMAP connections). The OLD lane key was `"accountId:messageIds.first"`, so a
    /// batch move `[A,B,C]` landed in a lane keyed by A while a LATER single-id op
    /// on B (e.g. a flag change) landed in a SEPARATE lane keyed by B — even though
    /// B is a member of both. The two lanes then ran concurrently, racing on the
    /// wire: a flag STORE on B could race the batch MOVE of B, silently losing the
    /// flag on the MOVE's source cleanup, or running against the old location
    /// before the move finishes. Connected-component lanes guarantee
    /// any op sharing a member id with an in-flight op serializes AFTER it.
    ///
    /// Pure and side-effect free (no DB/IO) — `nonisolated static` so it's directly
    /// unit-testable without an actor hop. Callers pass ops in createdAt-asc order;
    /// each lane preserves that relative order (FIFO within its component).
    /// Ops with empty `messageIds` (no id to key on) fall back to a singleton lane,
    /// matching the pre-existing fallback (`messageIds.first ?? op.id`).
    nonisolated static func buildLanes(_ ops: [PendingOperation]) -> [[PendingOperation]] {
        // Union-Find over "accountId:folderPath:msgId" keys, with path compression.
        var parent: [String: String] = [:]

        func find(_ x: String) -> String {
            var root = x
            while let p = parent[root], p != root {
                root = p
            }
            var current = x
            while let p = parent[current], p != root {
                parent[current] = root
                current = p
            }
            return root
        }

        func union(_ a: String, _ b: String) {
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[rootA] = rootB }
        }

        for op in ops {
            let ids = op.messageIds
            guard !ids.isEmpty else { continue }
            let keys = ids.map { "\(op.accountId):\(op.folderPath):\($0)" }
            for key in keys where parent[key] == nil {
                parent[key] = key
            }
            for key in keys.dropFirst() {
                union(keys[0], key)
            }
        }

        // Assign each op to its component's lane, in the ORIGINAL (createdAt-asc) order.
        var laneIndexForRoot: [String: Int] = [:]
        var lanes: [[PendingOperation]] = []
        for op in ops {
            guard let firstId = op.messageIds.first else {
                // Empty messageIds — always its own singleton lane.
                lanes.append([op])
                continue
            }
            let root = find("\(op.accountId):\(op.folderPath):\(firstId)")
            if let idx = laneIndexForRoot[root] {
                lanes[idx].append(op)
            } else {
                laneIndexForRoot[root] = lanes.count
                lanes.append([op])
            }
        }
        return lanes
    }

    /// Drain all queued operations with per-message parallelism.
    ///
    /// Ops are grouped into lanes by `buildLanes`: an op joins the lane of ANY op
    /// sharing any member message id (connected components), not just its first id.
    /// Each lane is a FIFO — ops in the same connected component execute
    /// sequentially (preserving ordering like removeTag→move, or a batch move and a
    /// later single-id flag change on one of its members). The drain runs every
    /// lane concurrently, so ops for disjoint messages make progress in parallel.
    ///
    /// Provider-level concurrency is managed by each provider (IMAP connection pool, HTTP pooling).
    ///
    /// Re-fetches after each pass to pick up ops inserted during the drain.
    /// Skips drain when offline to prevent retry storms.
    func drainPendingQueue() async {
        guard !isDraining else {
            needsRedrain = true
            return
        }
        guard NetworkMonitor.checkConnected() else { return }
        isDraining = true
        defer {
            isDraining = false
            if needsRedrain {
                needsRedrain = false
                Task { await drainPendingQueue() }
            }
        }

        pruneRecentlyCompleted()
        let ctx = DrainContext()

        // Max 3 passes to pick up ops inserted during drain.
        for pass in 0..<3 {
            let ops: [PendingOperation]
            do {
                ops = try await dbPool.read({ db in
                    try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
                })
            } catch {
                print("[Queue] ERROR: Failed to fetch pending ops: \(error)")
                break
            }
            guard !ops.isEmpty else { break }

            if pass == 0 {
                let summary = ops.map { "\($0.type.rawValue)(\($0.messageIds.count)msgs)" }.joined(separator: ", ")
                print("[Queue] Draining \(ops.count) ops: \(summary)")
            } else {
                print("[Queue] Drain pass \(pass + 1): \(ops.count) ops remaining/new")
            }

            // Claim all valid ops (unchanged: failedAccounts / provider checks / atomic claim).
            var claimed: [PendingOperation] = []
            for op in ops {
                if ctx.failedAccounts.contains(op.accountId) { continue }
                guard providers[op.accountId] != nil else {
                    print("[Queue] No provider for \(op.accountId) — skipping \(op.type.rawValue)")
                    continue
                }

                let currentOp: PendingOperation?
                do {
                    currentOp = try await dbPool.write { db -> PendingOperation? in
                        guard var fetched = try PendingOperation.fetchOne(db, key: op.id) else {
                            return nil
                        }
                        if fetched.status == PendingStatus.cancelled.rawValue {
                            _ = try PendingOperation.deleteOne(db, key: fetched.id)
                            print("[Queue] Op \(op.id.prefix(8)) cancelled by undo, deleted")
                            return nil
                        }
                        if fetched.status == PendingStatus.inFlight.rawValue {
                            return nil
                        }
                        // T4.S6 — PARK (never drop) while this op's source folder is
                        // mid UIDVALIDITY reset. The reaction has purged, or is about
                        // to purge, every header in that folder, and the UIDs this op
                        // addresses belong to a numbering the server has discarded:
                        // executing it now would mutate whichever message the new
                        // epoch put at that address (C3). The row stays `queued` with
                        // its retry counters untouched, so nothing is lost and nothing
                        // ages toward `failed` — Law 5. TRANSIENT: the flag is cleared
                        // by the reaction's step-5 stamp, and full sync re-drives an
                        // interrupted reaction on every cycle.
                        //
                        // ⚠ WHAT MAKES THE UNPARK SAFE — TWO CHECKS, NOT ONE. This
                        // comment used to claim the step-5 transaction alone was enough
                        // ("the same transaction that clears the flag also removes the
                        // address-only ops"). It is NOT: `opIsAddressOnly` is false for
                        // any op carrying a non-numeric id ALONGSIDE a UID, and
                        // `.deleteDraft` is exactly that shape — `queueDraftDelete`
                        // records `[uid, rfc822]`, and `executeOperation` used to hand
                        // `messageIds.first` (the UID) alone to `provider.deleteDraft`.
                        // Such an op survived the sweep and then unparked onto a UID the
                        // new epoch had reassigned. The admission-time stamp compared
                        // below is the second check, and the one that does not depend on
                        // guessing an op's id shapes.
                        // ⚑ UPDATE (2026-08-01): `IMAPProvider.deleteDraft` no longer
                        // executes a bare UID on the strength of the number alone — it
                        // either verifies an rfc822 identity on the wire, or (v72)
                        // corroborates the UID against the recorded epoch it was minted
                        // in — so that provider is now guarded at BOTH ends. This check
                        // stays: it is provider-agnostic, it is what keeps an op recorded
                        // under a discarded numbering from running at all, and the
                        // reasoning above is what it exists for.
                        let sourceFolderId = MessageIdentity.folderId(
                            accountId: fetched.accountId, folderPath: fetched.folderPath)
                        let sourceFolder = try Folder.fetchOne(db, key: sourceFolderId)
                        if let sourceFolder, sourceFolder.uidValidityResetPendingAt != nil {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Queue] Op \(op.id.prefix(8)) (\(fetched.type.rawValue)) parked — folder \(fetched.folderPath) is mid UIDVALIDITY reset")
                            }
                            return nil
                        }
                        // T2.6 checkpoint A. PORT: v2final's A4 compare/delete
                        // inside the claim transaction. SUBTRACT: RFC/hybrid
                        // compatibility, nil fail-open, claimFrontier/global FIFO,
                        // and demotion machinery. ⚑ NO REFERENCE — INVENTED: v3's
                        // DB provider classification and fail-closed shape.
                        //
                        // 🚨 EXACTLY ONE ARM OF THIS CHECKPOINT MAY DELETE, and it is
                        // the POSITIVE mismatch — two epochs that are both real
                        // (`nz-number`) and disagree. That is exit 4 of
                        // `Companion/Rules/Active/never-drop-user-intention.md`:
                        // a PROVEN id reset in the operation's own address space.
                        // Everything else this guard can observe — a malformed or
                        // non-canonical provider address, an unstamped or zero op
                        // epoch, a missing `Folder` row, a folder whose epoch is
                        // unknown or zero, or a folder mid-reset — is an ABSENCE OF
                        // EVIDENCE. "We could not determine the answer" is not an
                        // exit: those ops are NOT claimed this pass and stay durably
                        // `queued`, exactly as they would across an offline window.
                        // The predecessor deleted on all of them, which is the single
                        // most repeated defect class in this codebase's history.
                        //
                        // `.setTag`/`.removeTag` are deliberately NOT in this set:
                        // action tags are LOCAL-ONLY (ADR-IOS-036) and their executor
                        // arm is a `break`, so such an op carries no provider address
                        // for a provider-address checkpoint to judge. Subjecting them
                        // to it made every ReplyDetect `reply→none` op (7 producers,
                        // all enqueueing an rfc822 `stableId`) a deterministic drop on
                        // IMAP; leaving them in while the arm above stopped deleting
                        // would instead accumulate unclaimable rows forever.
                        let nonDraftTypes: Set<OperationType> = [
                            .archive, .delete, .move,
                            .markRead, .markUnread, .markFlagged, .markUnflagged,
                            .markReplied, .markForwarded,
                            .addUserLabel, .removeUserLabel,
                        ]
                        if nonDraftTypes.contains(fetched.type) {
                            guard let account = try Account.fetchOne(db, key: fetched.accountId) else {
                                // A missing account row tells us nothing about the
                                // server's state. Leave the intention queued.
                                if DebugModeManager.isLoggingEnabled() {
                                    print("[Queue] Checkpoint A skipped \(fetched.id.prefix(8)) — no account row for \(fetched.accountId.prefix(8))")
                                }
                                return nil
                            }
                            let isDemo = fetched.accountId == DemoSeed.demoAccountId
                            let isIMAP = !isDemo && (account.provider == .imap || account.provider == .icloud)
                            if isIMAP {
                                let idsAreCanonicalUIDs = !fetched.messageIds.isEmpty && fetched.messageIds.allSatisfy { id in
                                    guard let uid = UInt32(id), uid > 0 else { return false }
                                    return id == String(uid)
                                }
                                guard idsAreCanonicalUIDs,
                                      let stamped = fetched.observedUidValidity,
                                      let stampedUInt = UInt32(exactly: stamped), stampedUInt > 0,
                                      let sourceFolder,
                                      sourceFolder.uidValidityResetPendingAt == nil,
                                      let live = sourceFolder.lastKnownUidValidity,
                                      let liveUInt = UInt32(exactly: live), liveUInt > 0 else {
                                    // ABSENCE OF EVIDENCE — never a drop. The row is
                                    // left `queued` and simply not claimed this pass.
                                    BackgroundSyncLogger.log(
                                        "[Queue] Checkpoint A skipped \(fetched.id.prefix(8)) " +
                                        "(\(fetched.type.rawValue), \(fetched.folderPath)) — " +
                                        "provider address or UIDVALIDITY not established; op stays queued")
                                    return nil
                                }
                                if live != stamped {
                                    // EXIT 4 — a PROVEN turnover in this op's own
                                    // source address space. Every retry would fail
                                    // identically and forever, and executing under a
                                    // numbering the op never observed is C3.
                                    _ = try PendingOperation.deleteOne(db, key: fetched.id)
                                    BackgroundSyncLogger.log(
                                        "[Queue] Checkpoint A refused \(fetched.id.prefix(8)) " +
                                        "(\(fetched.type.rawValue), \(fetched.folderPath)) — " +
                                        "UIDVALIDITY moved \(stamped) → \(live); dropped whole before provider I/O")
                                    return nil
                                }
                            }
                        } else if let stamped = SyncEngine.knownUidValidity(fetched.observedUidValidity),
                                  let live = SyncEngine.knownUidValidity(
                                    sourceFolder?.lastKnownUidValidity),
                                  live != stamped {
                            // Preserve the already-landed draft/reset safeguard.
                            // Draft operations remain outside generic checkpoint A
                            // and continue through their typed execution gates.
                            //
                            // 🚨 BOTH EPOCHS MUST BE REAL BEFORE A DISAGREEMENT
                            // MEANS ANYTHING (`IOS-QUEUE-002`). This arm used to
                            // compare on bare inequality, so a ZERO on either
                            // side read as a POSITIVE mismatch and took the
                            // DELETE direction — turning an absence of evidence
                            // into exit 4. `SyncEngine.knownUidValidity` is the
                            // same normalizer the IMAP arm ten lines up already
                            // requires (`stampedUInt > 0` / `liveUInt > 0`), and
                            // exists because `Mailbox.Selection.uidValidity`
                            // DEFAULTS to `UIDValidity(0)` rather than being
                            // absent. Zero is "we were told nothing", and an
                            // unknown epoch stays retryable forever.
                            _ = try PendingOperation.deleteOne(db, key: fetched.id)
                            BackgroundSyncLogger.log("[Queue] UIDVALIDITY changed under op \(fetched.id.prefix(8)) (\(fetched.type.rawValue), \(fetched.folderPath)): recorded under \(stamped), folder now \(live) — dropped without executing (C5)")
                            return nil
                        }
                        fetched.status = PendingStatus.inFlight.rawValue
                        // PORT — v2final's persisted attempted-row proof,
                        // adapted to v3's lane claim. v3 has no post-claim
                        // zombie/demotion stage, so status and proof change in
                        // this same transaction before provider I/O. Never
                        // infer this bit from status or retryCount.
                        fetched.everAttempted = true
                        try fetched.save(db)
                        return fetched
                    }
                } catch {
                    print("[Queue] ERROR: Failed to claim op \(op.id): \(error)")
                    continue
                }
                guard let currentOp else { continue }
                claimed.append(currentOp)
            }

            // Connected-component lane grouping (F1) — pure, see buildLanes doc comment.
            let lanes = Self.buildLanes(claimed)
            guard !lanes.isEmpty else { break }

            // Launch one Task per lane. Each task drains its lane sequentially,
            // halting (and requeuing the rest of the lane) on `.haltLane` so a later
            // op never runs ahead of an unresolved predecessor sharing a message id.
            // Different lanes (disjoint connected components) run concurrently.
            var tasks: [Task<Void, Never>] = []
            for lane in lanes {
                let capturedLane = lane
                let capturedCtx = ctx
                let task = Task { [self] in
                    for (index, op) in capturedLane.enumerated() {
                        if capturedCtx.failedAccounts.contains(op.accountId) {
                            try? await retryWrite(dbPool, label: "Queue") { db in
                                var updated = op
                                updated.status = PendingStatus.queued.rawValue
                                try updated.save(db)
                            }
                            continue
                        }
                        // 🚨 ALREADY REFUSED THIS DRAIN for want of provider evidence.
                        // Attempt it AT MOST ONCE per drain — a refusal raised after
                        // a wire mutation has gone out would otherwise be repeated
                        // within the same drain, and the one that motivated this
                        // (`IMAPProvider.move`'s withheld-`COPYUID` refusal, deleted
                        // in audit round 4) seated another destination duplicate
                        // each time. See `DrainContext.evidenceRefused`.
                        //
                        // ⚠ THE CHECK BELONGS HERE, NOT IN THE CLAIM LOOP. Skipping
                        // the op at claim time would keep it out of `buildLanes`
                        // entirely, so its lane-mates — ops that share a message id
                        // with it BY CONSTRUCTION — would form a lane without it and
                        // execute, running ahead of an unresolved predecessor. That
                        // is precisely the race `.haltLane` exists to prevent: a
                        // `delete M` landing before the `move M` the user asked for
                        // first, with the move's retry then acting on state it never
                        // observed. Holding the op inside its lane and stopping the
                        // lane HERE preserves lane membership and ordering while
                        // still letting every other lane and account drain.
                        if capturedCtx.evidenceRefused.contains(op.id) {
                            // This op was claimed (`inFlight`) this pass, so the
                            // requeue starts AT it, not after it — unlike the
                            // `.haltLane` branch below, where the op has already been
                            // dispositioned by `executeSingleOp`.
                            for heldOp in capturedLane[index...] {
                                try? await retryWrite(dbPool, label: "Queue") { db in
                                    var updated = heldOp
                                    updated.status = PendingStatus.queued.rawValue
                                    try updated.save(db)
                                }
                            }
                            break
                        }
                        guard let queue = self.workQueues[op.accountId] else {
                            try? await retryWrite(dbPool, label: "Queue") { db in
                                var updated = op
                                updated.status = PendingStatus.queued.rawValue
                                try updated.save(db)
                            }
                            continue
                        }
                        let provider = queue.provider
                        // Outcome captured via Mutex (not a plain var) — the closure
                        // passed to queue.execute is @Sendable, so it cannot capture a
                        // mutable local var directly under Swift 6 strict concurrency.
                        let outcomeBox = Mutex<SingleOpOutcome>(.proceed)
                        await queue.execute(priority: .userAction) {
                            let result = await self.executeSingleOp(op, provider: provider, context: capturedCtx)
                            outcomeBox.withLock { $0 = result }
                        }
                        if outcomeBox.withLock({ $0 }) == .haltLane {
                            // Requeue the REMAINING claimed ops of this lane — exactly
                            // like the failedAccounts requeue path above — then stop.
                            let remaining = capturedLane[(index + 1)...]
                            for remainingOp in remaining {
                                try? await retryWrite(dbPool, label: "Queue") { db in
                                    var updated = remainingOp
                                    updated.status = PendingStatus.queued.rawValue
                                    try updated.save(db)
                                }
                            }
                            break
                        }
                    }
                }
                tasks.append(task)
            }
            for task in tasks { await task.value }

            if !ctx.executedAny { break }
            ctx.executedAny = false
        }

        // Post-drain: sync destination folders so new UIDs are picked up immediately.
        if !ctx.foldersToSync.isEmpty {
            print("[MoveTrace] post-drain sync — syncing \(ctx.foldersToSync.count) destination folders: \(ctx.foldersToSync)")
            for key in ctx.foldersToSync {
                let parts = key.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let accountId = String(parts[0])
                let folderPath = String(parts[1])
                guard let queue = workQueues[accountId] else { continue }
                guard let folder = try? await dbPool.read({ db in
                    try Folder.filter(Column("accountId") == accountId && Column("path") == folderPath).fetchOne(db)
                }) else {
                    print("[MoveTrace] post-drain sync — folder not found: \(accountId)|\(folderPath)")
                    continue
                }
                do {
                    try await queue.execute(priority: .userAction) {
                        try await self.syncEngine.syncFolderMessages(folder: folder, provider: queue.provider)
                    }
                    print("[MoveTrace] post-drain sync — completed for \(folder.name)")
                } catch {
                    print("[MoveTrace] post-drain sync — failed for \(folder.name): \(error)")
                }
            }
        }
    }

    // MARK: - Drain-barrier Test Seam (T0.8)
    //
    // `ProviderIdQueueFuzzTests` needs a drain barrier, and per the plan's T0.5
    // callout a barrier is only correct if it samples its predicate BEFORE
    // requesting a drain — otherwise every poll lands on `drainPendingQueue()`'s
    // is-draining guard above, sets `needsRedrain` itself, and the barrier keeps
    // its own re-arm alive forever. That corrected shape needs to be able to
    // observe "no drain in flight", which `isDraining`/`needsRedrain`
    // (`AccountManager.swift:274`, `:276`) do not expose to a test on their own.
    //
    // This is a verbatim port of the reference accessor
    // (`v2final:TabMail/Services/Account/AccountManagerQueue.swift:3172-3174`) —
    // same name, same predicate — with the one deviation this file's sibling
    // seams already established (`IMAPProvider.mutLogForTesting` and the
    // T0.6(a) pool-invariant seams; symbol-cited, no line numbers): the
    // reference leaves its `…ForTesting` surface UNGATED, here it is `#if DEBUG`
    // so Release builds carry neither the member nor any call site. Purely
    // additive: nothing above changed, and no production code reads it.
    #if DEBUG

    /// Narrow test seam for proving that awaiting a drain also joins any
    /// requested re-drain instead of leaving unstructured queue work behind.
    ///
    /// The barrier that consumes it MUST read this FIRST and only then ask for a
    /// drain (see `ProviderIdQueueFuzzTests.drainProviderQueue`) — the inverse
    /// ordering is the self-re-arm bug the reference fixed in `f214c704a`.
    func pendingQueueIsQuiescentForTesting() -> Bool {
        !isDraining && !needsRedrain
    }

    #endif

    /// Execute a single claimed op against its provider. Updates shared DrainContext
    /// with results (executedAny, failedAccounts, foldersToSync, recentActions).
    /// Returns the outcome (`.proceed`/`.haltLane`) so the per-lane drain loop knows
    /// whether it's safe to run this lane's next op. `internal` (not `private`) so
    /// tests can call it directly against a `MockEmailProvider`.
    func executeSingleOp(_ currentOp: PendingOperation, provider: any EmailProvider, context: DrainContext) async -> SingleOpOutcome {
        let opType = currentOp.type.rawValue
        let opMsgCount = currentOp.messageIds.count

        do {
            let executed = try await withTimeout(
                seconds: SyncConfig.pendingOperationTimeoutSeconds
            ) { () -> ExecutedOperation in
                try await self.executeOperation(currentOp, provider: provider)
            }
            let provenMembers = executed.provenMembers
            // 🚨 RETIREMENT IS PER MEMBER, NEVER PER BATCH. A provider that
            // proves only SOME members completed has told us nothing about the
            // rest — they were never mutated, and retiring the whole row would
            // discard their user intention on an absence of evidence. Narrow the
            // durable row to the unproven remainder instead; the proven members
            // are retired, the rest stay queued and retry.
            if let provenMembers, Set(provenMembers) != Set(currentOp.messageIds) {
                let remaining = currentOp.messageIds.filter { !provenMembers.contains($0) }
                await retirePartiallyCompletedOp(
                    currentOp, provenMembers: provenMembers, remaining: remaining,
                    provenDestinations: executed.provenDestinations, context: context)
                return .haltLane
            }
            // TOCTOU fix: record recentActions BEFORE deleting PendingOp.
            // Sync engine has two guards against re-inserting moved messages:
            //   1. pendingDestructiveIds — read inside the sync write transaction
            //   2. recentMoveIdsByFolder — snapshot from actor before the sync write
            // If we delete the PendingOp first and record recentAction after, there's
            // a window where neither guard is active (PendingOp gone from DB, recentAction
            // not yet on actor). By recording recentAction first, at every instant at least
            // one guard is active:
            //   - Before step 3 (delete): PendingOp in DB → pendingDestructiveIds catches it
            //   - After step 2 (record): recentAction on actor → recentMoveIdsByFolder catches it
            // If app crashes between steps 2 and 3, the PendingOp re-executes (idempotent).

            // Step 1: Collect rfc822MessageIds (read-only, separate from delete).
            var actionInfos: [(String, String?, String?)] = [] // (opMsgId, rfc822MessageId, numericMessageId)
            let trackedTypes: Set<OperationType> = [
                .archive, .delete, .move,
                .markRead, .markUnread, .markFlagged, .markUnflagged, .setTag, .removeTag
            ]
            if trackedTypes.contains(currentOp.type) {
                do {
                    actionInfos = try await dbPool.read { db -> [(String, String?, String?)] in
                        var infos: [(String, String?, String?)] = []
                        for msgId in currentOp.messageIds {
                            let normalizedMsgId = EmailFilter.normalizeMessageId(msgId)
                            let header = try MessageHeader
                                .filter(
                                    (Column("messageId") == msgId || Column("rfc822MessageId") == normalizedMsgId) &&
                                    Column("accountId") == currentOp.accountId
                                )
                                .fetchOne(db)
                            infos.append((msgId, header?.rfc822MessageId, header?.messageId))
                        }
                        return infos
                    }
                } catch {
                    print("[Queue] WARNING: Failed to collect rfc822 info for \(currentOp.id): \(error)")
                }
            }

            // Step 2: Record in recentlyCompleted (30s TTL) BEFORE deleting PendingOp.
            // Bridges the gap between PendingOp deletion and server-side state propagation.
            // This ensures sync engine always sees the protection entry.
            var completedIds: [String] = []
            for (msgId, rfc822, numericId) in actionInfos {
                completedIds.append(msgId)
                if let rfc822 { completedIds.append(rfc822) }
                if let numericId, numericId != msgId { completedIds.append(numericId) }
            }
            recordRecentlyCompleted(messageIds: completedIds)

            // Step 3: Delete PendingOp. MUST succeed — remote op already completed.
            // If we don't delete, it re-executes on next drain (idempotent but wasteful).
            //
            // 🚨 THE MOVE IS ALSO FINISHED LOCALLY HERE, IN THIS SAME WRITE.
            // `optimisticMoveToFolder` left the row's primary key and
            // `messageId` at their SOURCE values with a NIL epoch, so until it
            // is re-keyed the row is refused by `admittedOrdinaryActionTargets`
            // and the user's NEXT gesture on a just-moved message is a silent
            // dead no-op. Re-keying it to the address the server itself named
            // in `COPYUID` (already in hand — see `MessageHeaderRekey.finishMove`
            // for the four guards) closes that, and makes undo-after-drain an
            // ordinary reverse move. Sharing this transaction with the op's
            // deletion keeps the crash window exactly where it already was.
            let rekeyOutcome: (applied: [HeaderRekeyRecord], collided: [String])
            do {
                rekeyOutcome = try await retryWrite(dbPool, label: "Queue") {
                    db -> (applied: [HeaderRekeyRecord], collided: [String]) in
                    var collided: [String] = []
                    let rekeys = try MessageHeaderRekey.finishMove(
                        currentOp, destinations: executed.provenDestinations, db: db,
                        onCollidedRekey: { collided.append($0) })
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    return (rekeys, collided)
                }
            } catch {
                print("[Queue] CRITICAL: Failed to delete completed PendingOperation \(currentOp.id) after retries — will re-execute on next drain")
                rekeyOutcome = ([], [])
            }
            await publishRekeys(rekeyOutcome.applied, collidedOldHeaderIds: rekeyOutcome.collided)
            if [.archive, .delete, .move].contains(currentOp.type), let dest = currentOp.destinationPath {
                context.foldersToSync.insert("\(currentOp.accountId)|\(dest)")
            }
            // Sync Drafts folder after draft save/delete so MessageHeaders reflect server state.
            // After saveDraft: the sync's UID remap detection matches our optimistic header
            // (placeholder messageId) to the real server header by rfc822MessageId, migrating
            // the header in-place and preserving the body + local state.
            if [.saveDraft, .deleteDraft].contains(currentOp.type) {
                context.foldersToSync.insert("\(currentOp.accountId)|\(currentOp.folderPath)")
            }
            context.executedAny = true
            return .proceed
        } catch {
            // T2.7 checkpoint B refusal is typed and precedes every generic
            // message-not-found / UID-resolution split arm. The epoch scopes
            // the whole provider-address bundle, so no member may be retried as
            // a child under a different attempt.
            if case ProviderError.uidValidityChanged = error {
                do {
                    try await retryWrite(dbPool, label: "Queue") { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                    context.executedAny = true
                    return .proceed
                } catch {
                    // The provider wrote nothing. If retiring the refused op
                    // fails, preserve the exact original bundle for retry.
                    try? await retryWrite(dbPool, label: "Queue") { db in
                        var queued = currentOp
                        queued.status = PendingStatus.queued.rawValue
                        try queued.save(db)
                    }
                    return .haltLane
                }
            }
            if isMessageNotFoundError(error) {
                if currentOp.messageIds.count > 1 {
                    // Batch op hit messageNotFound — one message is gone but others
                    // may still need processing. Split into individual single-message
                    // ops so each can succeed/fail independently.
                    print("[Queue] Conflict in batch \(opType) (\(opMsgCount) msgs) — splitting into individual ops")
                    do {
                        try await dbPool.write { db in
                            for msgId in currentOp.messageIds {
                                var splitOp = PendingOperation(
                                    type: currentOp.type, messageIds: [msgId],
                                    accountId: currentOp.accountId, folderPath: currentOp.folderPath,
                                    destinationPath: currentOp.destinationPath, tagValue: currentOp.tagValue,
                                    userLabelId: currentOp.userLabelId,
                                    // 🚨 THE ADMISSION EPOCH MUST TRAVEL WITH THE CHILD.
                                    // The parent is deleted in this same transaction, so
                                    // anything not copied here is destroyed. A child built
                                    // without this stamp is one checkpoint A cannot admit —
                                    // and before the never-drop fix, one checkpoint A
                                    // DELETED, silently reverting the whole gesture on the
                                    // next sync. The children are the SAME user intention,
                                    // re-shaped: they are admitted under exactly the epoch
                                    // and identity the parent was.
                                    observedUidValidity: currentOp.observedUidValidity,
                                    draftServerUidValidity: currentOp.draftServerUidValidity,
                                    instanceEpoch: currentOp.instanceEpoch,
                                    draftId: currentOp.draftId)
                                // Carried as the stored raw value rather than through the
                                // typed initializer parameter: an unrecognized raw string
                                // must survive verbatim, not decode to `nil`.
                                splitOp.draftDeleteAddressKind = currentOp.draftDeleteAddressKind
                                // The parent was claimed, so provider I/O may already have
                                // started for these members. Undo may only annihilate an
                                // unattempted bundle; a child that forgot this would be
                                // annihilable after the wire was touched.
                                splitOp.everAttempted = currentOp.everAttempted
                                // Split ops inherit the batch's queue position — they are
                                // the SAME user intention, re-shaped. Without this, the
                                // default `PendingOperation.init` createdAt (Date()) would
                                // stamp a LATER timestamp than a same-lane sibling op queued
                                // between the batch and the split, starving the split op
                                // behind it on every later buildLanes pass (createdAt-order
                                // invariant).
                                splitOp.createdAt = currentOp.createdAt
                                try splitOp.insert(db)
                            }
                            _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                        }
                    } catch {
                        print("[Queue] Failed to split batch op \(currentOp.id): \(error) — batch will retry as-is")
                    }
                    context.executedAny = true
                    // Halt the lane rather than .proceed: the split singles are
                    // freshly queued (not yet executed) and a LATER same-lane op
                    // sharing a member id (e.g. a chained move of one of the split
                    // messages) must never run ahead of them this pass — that would
                    // race/misread state the split children haven't written yet and
                    // could act on stale row state. The lane loop requeues the rest back
                    // to `.queued` so it serializes behind the split ops on a later
                    // pass/drain.
                    return .haltLane
                }
                // Single-message conflict — drop (server wins)
                print("[Queue] Conflict: \(opType) — message not found, dropping")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                // If the error was a structurally-confirmed permanent gone (HTTP 404/410
                // or ProviderError.messageNotFound), also delete the local header. The
                // message is verified gone on the server; retaining a ghost row causes
                // other queues (body fetch, AI) to retry forever.
                // We deliberately DO NOT delete on the string-matching branch of
                // isMessageNotFoundError — too risky for false positives.
                if isConfirmedGoneError(error), let msgId = currentOp.messageIds.first {
                    // Scope delete to the exact (account, folder, messageId) row — broader
                    // matches risk deleting unrelated messages that happen to share a UID
                    // in a different IMAP folder.
                    let hid = MessageIdentity.headerId(accountId: currentOp.accountId, folderPath: currentOp.folderPath, messageId: msgId)
                    await deleteConfirmedGoneHeader(headerId: hid, reason: "\(opType) 404")
                }
                context.executedAny = true
                return .proceed
            }
            // Permanently invalid operation — drop immediately (will never succeed on retry).
            // E.g., Gmail "Invalid label: DRAFT" when a .move op tried to remove the DRAFT label.
            if isPermanentlyInvalidError(error) {
                print("[Queue] Permanently invalid \(opType): \(error) — dropping")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                context.executedAny = true
                return .proceed
            }
            // The provider REFUSED the id before touching the wire — it is not an
            // identity anything can verify (a bare numeric UID, or a value that does
            // not canonicalize to an rfc822 Message-ID). DETERMINISTIC: the same
            // string will be refused on every future drain, so this must not spend
            // `uidResolutionRetryCount` and must not reach the "confirmed stale"
            // branch below — that branch's whole meaning is "the server told us the
            // message is gone", and nothing here ever asked the server.
            //
            // ⚠ SCOPE, CORRECTED (audit round 1, finding B-1). Three premises this
            // comment used to state as unconditional were `.deleteDraft`-specific and
            // became FALSE when `IMAPProvider.move` started raising this error too:
            // "refused BEFORE touching the wire" (the COPY had already gone out),
            // "DETERMINISTIC — the same string will be refused on every future drain"
            // (it depended on the SERVER's UIDPLUS capability and on whether it chose
            // to send `COPYUID`, neither of which is a property of the id), and
            // "`.deleteDraft` — the only op that raises this error". A refusal that
            // depends on server behaviour is an ABSENCE OF EVIDENCE, not an
            // authoritative verdict on an identity, and retiring an op on it is a
            // never-drop violation. `IMAPProvider.move` therefore no longer raises
            // this error at all: audit round 2 routed its evidence gates to the
            // dedicated `ProviderEvidenceUnavailable` arm below — requeue and retry
            // WITHOUT poisoning the account, rather than the generic connection arm
            // it originally fell through to — and audit round 4 removed the
            // withheld-`COPYUID` gate entirely, so what is left of that arm refuses
            // only BEFORE any wire mutation. The premises below are once again true
            // of every op that reaches here.
            //
            // Ported from `v2final:AccountManagerQueue`'s `.deleteDraft` arm
            // ("TERMINAL drop of a provider-authoritative identity refusal").
            if case ProviderError.actionIdentityResolutionFailed(let refusedId) = error {
                // ⚑ NEVER SPLIT THIS ONE. A revision of this branch, on seeing an op
                // with more than one id, split it into one op per id so "the sibling the
                // provider CAN verify" could execute. For `.deleteDraft` — the op class
                // that raises this error — the ids are not siblings: slot 0 is the
                // ADDRESS and slot 1 is the IDENTITY *of the same draft*, and splitting
                // them manufactured an identity-only op that resolves by Message-ID
                // SEARCH. Run after the addressed target has gone, that search returns a
                // legitimate same-Message-ID SIBLING as its sole exact match and deletes
                // it — a wrong-message delete (C3) built out of a refusal. The op now
                // carries every id to the provider in ONE call (see the `.deleteDraft`
                // executor arm), so a refusal here is the provider's FINAL verdict on
                // the whole identity, not an invitation to retry a fragment of it.
                //
                // Retrying cannot change it and parking it is a permanent lane wedge, so
                // it ends here — but LOUDLY and immediately, not after three fake
                // retries dressed up as a staleness confirmation. Nothing is destroyed:
                // the server-side object this op named is still there, still visible
                // after the next sync, and the user's re-issued gesture goes through the
                // UI paths that carry a full identity (`InboxViewModel.deleteDraftMessage`,
                // `ComposeView`'s discard/send paths). ⚑ `v2final` demotes this case to
                // its queue tail instead of dropping it, via
                // `ProviderError.persistentActionFailure` — machinery this tree does not
                // have (F2b L4). Terminal drop is the disposition v3 already shipped and
                // keeps; the intention loss is bounded and visible, and adding a demote
                // path is a separate change.
                print("[Queue] Identity refused in \(opType) (\(opMsgCount) id(s)): '\(refusedId)' is not a verifiable identity and never will be — dropping the op (the server-side object is untouched and remains visible for a re-issued gesture)")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                context.executedAny = true
                return .proceed
            }
            // 🚨 EVIDENCE UNAVAILABLE — RETRYABLE, AND NOT AN ACCOUNT-LEVEL FACT.
            //
            // The provider's own safety gate asked the server for a proof (a
            // `COPYUID` mapping, a `UIDVALIDITY`) and did not get one. Nothing was
            // determined about this op, so it stays durably queued — and nothing was
            // determined about the ACCOUNT either, which is the half this arm exists
            // to say. Before it, these errors fell through to the generic arm below
            // and inserted the account into `failedAccounts`, whose skip is
            // account-wide. On a standards-valid non-UIDPLUS server (RFC 4315 §3
            // makes `COPYUID` a MAY) one unprovable op therefore stopped EVERY later
            // gesture on that account from executing — permanently, since `ctx` is
            // per-drain and the next drain reproduced it identically, and invisibly,
            // since no UI lists or clears `PendingOperation` rows. The predecessor
            // behaviour was to delete the op: one dropped move, queue kept working.
            // Preserving one intention by denying every intention behind it is not
            // never-drop; it is a worse never-drop violation wearing a safe shape.
            //
            // THREE properties, each load-bearing:
            //  - `.haltLane`, NOT `.proceed`. Every op later in this lane shares a
            //    message id with this one BY CONSTRUCTION (`buildLanes` is a
            //    connected-component grouping), so running one ahead of an unresolved
            //    predecessor races its eventual retry on the wire. The defect was the
            //    account poisoning; the lane halt is correct and stays.
            //  - `evidenceRefused`, so this op is attempted AT MOST ONCE per drain.
            //    Required, not defensive: another lane's success sets `executedAny`,
            //    the outer loop iterates, and this op would be re-claimed. The
            //    refusal that made that costly — `IMAPProvider.move`'s withheld-
            //    `COPYUID` gate, raised AFTER the `UID COPY` so each re-attempt
            //    seated ANOTHER unproven duplicate at the destination — was deleted
            //    in audit round 4, but the property is a contract of this arm and
            //    not a patch for one error case, so it stays.
            //  - `executedAny` is NOT set. This arm made no progress, so it must not
            //    by itself keep the drain looping; `if !ctx.executedAny { break }`
            //    still terminates when nothing else advanced.
            if error is ProviderEvidenceUnavailable {
                let ageHours = Date().timeIntervalSince(currentOp.createdAt) / 3600
                print("[Queue] Evidence unavailable for \(opType) (\(opMsgCount) msgs): \(error) (age \(String(format: "%.1f", ageHours))h) — op stays queued, retries next drain; the rest of this account keeps draining")
                if !context.diagnosedOpIds.contains(currentOp.id) {
                    context.diagnosedOpIds.insert(currentOp.id)
                    await logStuckOpDiagnostic(currentOp, error: error)
                }
                try? await retryWrite(dbPool, label: "Queue") { db in
                    var updated = currentOp
                    updated.status = PendingStatus.queued.rawValue
                    updated.retryCount += 1
                    try updated.save(db)
                }
                context.evidenceRefused.insert(currentOp.id)
                return .haltLane
            }
            // Connection/transient error — reset op to queued and mark account failed.
            // NEVER drop on age alone — transient errors don't confirm the op is stale.
            // Staleness is confirmed only by messageNotFound (server says gone).
            // failedAccounts prevents hammering within a single drain.
            let ageHours = Date().timeIntervalSince(currentOp.createdAt) / 3600
            print("[Queue] Failed \(opType): \(error) (age \(String(format: "%.1f", ageHours))h) — will retry")
            // Deep diagnostic on the failing op — fires once per (drain, opId) so a
            // stuck op that retries every drain doesn't fill the log. Dumps full op
            // fields, error structural unwrap, classifier results, and the DB rows
            // scoped to the exact message + the involved folders.
            if !context.diagnosedOpIds.contains(currentOp.id) {
                context.diagnosedOpIds.insert(currentOp.id)
                await logStuckOpDiagnostic(currentOp, error: error)
            }
            // 🚨 A LOCALLY-MISSING DESTINATION FOLDER IS NOT PROVIDER AUTHORITY.
            // This arm used to DELETE a `.move` op whose destination `Folder` row
            // was absent from GRDB, calling it a "self-heal" for a re-ingested
            // folder list (e.g. IMAP→OAuth renaming "Deleted Messages" → "TRASH").
            // But the local folder table is OUR cache, not the server's answer:
            // the row is equally absent during a first sync, after a folder-list
            // read failed, and for any account whose folders have not been
            // enumerated yet. Dropping on it retires a durable intention on an
            // absence of evidence — outside the four exits. The op stays queued and
            // retries; if the folder never returns the op parks visibly rather than
            // vanishing, and a real server-side "destination is gone" is answered by
            // `IMAPProvider.move`'s LIST-confirmed `IMAPActionMailboxAbsent` arm,
            // which IS provider-authoritative. Diagnostic retained.
            if currentOp.type == .move, let destPath = currentOp.destinationPath,
               DebugModeManager.isLoggingEnabled() {
                let destMissing: Bool = (try? await dbPool.read { db in
                    try Folder.fetchOne(db, key: "\(currentOp.accountId):\(destPath)") == nil
                }) ?? false
                if destMissing {
                    print("[Queue] \(opType) destination Folder missing locally: \(currentOp.accountId):\(destPath) — op stays queued (local absence is not provider authority)")
                }
            }
            try? await retryWrite(dbPool, label: "Queue") { db in
                var updated = currentOp
                updated.status = PendingStatus.queued.rawValue
                // Bump retryCount on each failure so the value matches reality (and
                // is visible in [QueueDiag] dumps). Previously this stayed at 0
                // forever, masking the runaway-retry case where we observed
                // `retryCount=0 ageHours=217` on the same op.
                updated.retryCount += 1
                try updated.save(db)
            }
            context.failedAccounts.insert(currentOp.accountId)
            return .haltLane
        }
    }

    /// Mirror a COMMITTED re-key into the two stores that key by
    /// `messageHeader.id` but do not live in the GRDB database — the in-memory
    /// undo stack and the FTS index. Shared by the whole-op success path and by
    /// the narrowing pass, so the two cannot drift.
    ///
    /// 🚨 THE UNDO STACK IS PUBLISHED FIRST, AND THE ORDER IS THE FIX
    /// (`IOS-UNDO-002`). `SearchIndex` is a SEPARATE SQLite pool, so its re-key
    /// is a real cross-database round trip. Running it first left the undo stack
    /// naming the STALE `originalHeaderId` for the whole of that suspension: an
    /// `Undo` landing inside it popped an entry `AccountManager.undoMove`
    /// authenticates with `MessageHeader.fetchOne(db, key: originalHeaderId)`,
    /// which is now nil, so the WHOLE command was refused — and the later
    /// publication could not repair an entry already popped off the stack.
    /// Publishing to the undo stack first removes the cross-database trip from
    /// that window entirely, leaving only the `@MainActor` hop every publication
    /// in this app already has. Nothing else about the ordering moves: both
    /// stores are still updated AFTER the GRDB commit, which is the two-phase
    /// shape the sync path uses.
    ///
    /// ⚠ ACCEPTED RESIDUAL: an undo landing inside that single `@MainActor` hop
    /// is still refused whole. It is fail-closed — the message is correctly at
    /// the destination, nothing mutates the wrong message, no queued op is
    /// dropped — and the user recovers by moving it back with one ordinary
    /// gesture.
    ///
    /// 🚨 A COLLIDED RE-KEY LEAVES NO HEADER BEHIND (`IOS-SEARCH-002`), so its
    /// FTS entry is removed rather than moved. `MessageHeaderRekey.apply`
    /// deletes the old row before its collision return, so the old id names
    /// nothing; leaving its index entry in place produces the *indexed but
    /// unfindable* class — a search hit whose header is gone, at a composite id
    /// a later message can re-occupy. The sync caller already compensates by
    /// routing the id down its `staleIds` path; this is the drain's equivalent.
    func publishRekeys(
        _ applied: [HeaderRekeyRecord],
        collidedOldHeaderIds: [String]
    ) async {
        if !applied.isEmpty {
            print("[MoveTrace] executeSingleOp — re-keyed \(applied.count) moved row(s) to their COPYUID-proven destination address")
            // The undo stack names its members by the SAME primary key and UID
            // this re-key just changed, so it has to follow — otherwise
            // finishing the move would break undo rather than enable it.
            await UndoService.shared.applyRekeys(applied)
            // The FTS index is a SEPARATE database, so its re-key is two-phase —
            // outside the GRDB write — exactly as the sync path does it. The
            // entry MOVES; it is never removed.
            try? await SearchIndex.shared.rekeyHeaders(applied.map {
                (oldKey: ContentKey(rawValue: $0.oldHeaderId),
                 newKey: ContentKey(rawValue: $0.newHeaderId),
                 newMessageId: $0.newProviderMessageId)
            })
        }
        if !collidedOldHeaderIds.isEmpty {
            print("[MoveTrace] executeSingleOp — dropped \(collidedOldHeaderIds.count) FTS entry(s) whose re-key collided; the destination row is the survivor")
            try? await SearchIndex.shared.removeMessages(
                contentKeys: collidedOldHeaderIds.map { ContentKey(rawValue: $0) })
        }
    }

    /// Retire ONLY the members a provider positively proved it completed, and
    /// leave the remainder durably queued.
    ///
    /// The batch is one row, but it is N user intentions. A provider that
    /// mutated some members and could not prove the others (IMAP's `COPYUID`
    /// names a subset — RFC 4315 §3 makes reporting a MAY, and RFC 3501 §6.4.8
    /// lets `UID COPY` silently ignore a UID that is already gone) has said
    /// nothing about the unproven ones. Deleting the whole row there discards
    /// their intention on an absence of evidence; re-running the whole batch
    /// would instead re-copy the proven members and duplicate them at the
    /// destination. Narrowing avoids BOTH of those.
    ///
    /// ⚠ IT DOES NOT AVOID DUPLICATION (audit round 2). This used to say
    /// "narrowing is the only shape that does neither", which is false about the
    /// unproven members: the initial `UID COPY` was issued for the WHOLE set, so a
    /// withheld `COPYUID` is SILENCE about the outcome, not evidence the copy
    /// failed. Those members may well be sitting at the destination already, and
    /// the narrowed row's retry copies them again.
    ///
    /// THE BOUND, stated because "one per drain" was assumed here and is not true
    /// of this path: this arm sets `executedAny = true`, so the outer loop takes
    /// another pass and re-claims the narrowed row IN THE SAME DRAIN. It did not
    /// throw, so `evidenceRefused` — which bounded the zero-evidence sibling in
    /// `IMAPProvider.move` — does not cover it. The narrowed members can therefore
    /// be re-copied once per remaining pass, i.e. up to the drain's 3-pass cap,
    /// and again on every later drain until the server proves or denies them.
    /// Duplicated mail is recoverable; a dropped intention is not.
    ///
    /// ⚠ AUDIT ROUND 4 — THIS PATH HAS NO CURRENT PRODUCER. `IMAPProvider.move`
    /// was the only one, and it now dispositions every member positively before
    /// returning (see `executeOperation`'s return-value note), so there is no
    /// undetermined remainder for this to narrow to — which is also why the
    /// re-copy cost above can no longer be incurred. It is retained as the
    /// drain's contract for any provider that returns a strict subset.
    ///
    /// 🚨 A RETIRED MEMBER IS FINISHED LOCALLY HERE TOO (`IOS-QUEUE-005`). This
    /// leg used to return before any re-key, so a member retired in a narrowing
    /// pass kept its SOURCE address while its copy lived at the destination —
    /// exactly the state `MessageHeaderRekey.finishMove` exists to close, in
    /// which `admittedOrdinaryActionTargets` refuses the row and the user's next
    /// gesture on it is a silent dead no-op until a sync repairs it. A standing
    /// contract that silently loses the destination address the server itself
    /// named is a trap laid for the future provider that first returns a strict
    /// subset. The re-key runs in the SAME write that narrows the row, which is
    /// the transaction shape the whole-op success path already uses, and it is
    /// scoped to `provenMembers` so an unproven member is never re-keyed.
    ///
    /// `internal` (not `private`) so tests can drive it directly, the same
    /// reason `executeSingleOp` and `DrainContext` are: no production provider
    /// returns a strict subset, so a test IS this path's only reachability.
    func retirePartiallyCompletedOp(
        _ currentOp: PendingOperation,
        provenMembers: [String],
        remaining: [String],
        provenDestinations: [ProvenDestinationAddress],
        context: DrainContext
    ) async {
        print("[Queue] Partial \(currentOp.type.rawValue): provider proved \(provenMembers.count) of \(currentOp.messageIds.count) member(s) — retiring those and keeping \(remaining.count) queued")
        // Same TOCTOU ordering as the whole-op success path: the sync-protection
        // entry for a retired member is recorded BEFORE its id leaves the row.
        var completedIds: [String] = provenMembers
        if let infos = try? await dbPool.read({ db -> [(String?, String?)] in
            var out: [(String?, String?)] = []
            for msgId in provenMembers {
                let normalized = EmailFilter.normalizeMessageId(msgId)
                let header = try MessageHeader
                    .filter(
                        (Column("messageId") == msgId || Column("rfc822MessageId") == normalized) &&
                        Column("accountId") == currentOp.accountId
                    )
                    .fetchOne(db)
                out.append((header?.rfc822MessageId, header?.messageId))
            }
            return out
        }) {
            for (rfc822, numericId) in infos {
                if let rfc822 { completedIds.append(rfc822) }
                if let numericId { completedIds.append(numericId) }
            }
        }
        recordRecentlyCompleted(messageIds: completedIds)

        // The retired members only — an unproven member has no server-named
        // destination and must keep its source address.
        let frozenRetiredOp: PendingOperation = {
            var op = currentOp
            op.messageIds = provenMembers
            return op
        }()
        do {
            let rekeyOutcome = try await retryWrite(dbPool, label: "Queue") {
                db -> (applied: [HeaderRekeyRecord], collided: [String]) in
                var collided: [String] = []
                let rekeys = try MessageHeaderRekey.finishMove(
                    frozenRetiredOp, destinations: provenDestinations, db: db,
                    onCollidedRekey: { collided.append($0) })
                guard var fresh = try PendingOperation.fetchOne(db, key: currentOp.id) else {
                    return (rekeys, collided)
                }
                fresh.messageIds = remaining
                fresh.status = PendingStatus.queued.rawValue
                try fresh.save(db)
                return (rekeys, collided)
            }
            await publishRekeys(rekeyOutcome.applied, collidedOldHeaderIds: rekeyOutcome.collided)
        } catch {
            // The narrowing write failed. NEVER leave the row `inFlight` (it
            // would only unstick at the next launch's crash recovery) and never
            // delete it: requeue the ORIGINAL bundle. A retry re-copies the
            // proven members — a duplicate at the destination, which this
            // codebase prefers over a dropped intention.
            print("[Queue] CRITICAL: could not narrow partially-completed \(currentOp.id) after retries — requeuing the whole bundle (may duplicate already-moved members)")
            try? await retryWrite(dbPool, label: "Queue") { db in
                var queued = currentOp
                queued.status = PendingStatus.queued.rawValue
                try queued.save(db)
            }
        }
        if [.archive, .delete, .move].contains(currentOp.type), let dest = currentOp.destinationPath {
            context.foldersToSync.insert("\(currentOp.accountId)|\(dest)")
        }
        context.executedAny = true
    }

    /// Returns true if the error indicates the message no longer exists (conflict — drop op).
    ///
    /// Matches three classes of signal:
    /// 1. `ProviderError.messageNotFound` — providers that classify explicitly.
    /// 2. `ProviderError.networkError` wrapping an HTTP 404. Must unwrap both the
    ///    `HTTPError.networkError(statusCode:)` shape (Exchange/Gmail providers throw
    ///    this — a plain Swift enum that does NOT bridge to `NSError` with code=404)
    ///    AND the `NSError(code: 404)` shape (other paths that throw `NSError` directly).
    /// 3. IMAP server-side rejection strings ("NONEXISTENT", "UID not found", etc.).
    ///
    /// Strict structural matches (1 and 2) are additionally surfaced via
    /// `isConfirmedGoneError`, which gates destructive header deletion.
    nonisolated func isMessageNotFoundError(_ error: Error) -> Bool {
        if case ProviderError.messageNotFound = error { return true }
        if case ProviderError.networkError(let underlying) = error {
            if case HTTPError.networkError(let statusCode) = underlying, statusCode == 404 {
                return true
            }
            if (underlying as NSError).code == 404 { return true }
        }
        let desc = "\(error)"
        if desc.contains("no such message") || desc.contains("UID not found") ||
           desc.contains("Message not found") || desc.contains("NONEXISTENT") { return true }
        return false
    }

    /// Stricter sibling of `isMessageNotFoundError` used to decide whether we may also
    /// DELETE the local messageHeader row. Only fires on structural signals that
    /// unambiguously confirm the message is gone from the server:
    ///   - `ProviderError.messageNotFound` (providers that classify explicitly)
    ///   - HTTP 404 / 410 (server responded with a permanent not-found status)
    ///
    /// Deliberately does NOT match the string-matching fallback in
    /// `isMessageNotFoundError` — IMAP error descriptions can be noisy and we never
    /// want a false positive to permanently delete user data.
    nonisolated func isConfirmedGoneError(_ error: Error) -> Bool {
        if case ProviderError.messageNotFound = error { return true }
        if case ProviderError.networkError(let underlying) = error {
            if case HTTPError.networkError(let statusCode) = underlying,
               statusCode == 404 || statusCode == 410 {
                return true
            }
            let nsCode = (underlying as NSError).code
            if nsCode == 404 || nsCode == 410 { return true }
        }
        return false
    }

    /// Delete a single messageHeader (identified by its full primary key) that has
    /// been structurally confirmed gone from the server. The FK cascade removes the
    /// MessageReference children; the `messageBody` row is reclaimed by the routed
    /// release below (Stage D dropped that cascade — a content key is not a header
    /// id). The FTS row is removed on the same release.
    /// Safe to call with a headerId that isn't in the local DB — DELETE returns 0
    /// rows and FTS remove is idempotent.
    ///
    /// Scoped to the exact (accountId, folderPath, messageId) combination, NOT
    /// (accountId, messageId) alone: for IMAP, UIDs are per-folder so the same
    /// messageId can identify completely different messages across folders, and
    /// a broader delete would orphan unrelated rows.
    ///
    /// ONLY call this when `isConfirmedGoneError` returned true (Exchange/Gmail
    /// 404/410 or ProviderError.messageNotFound) or the IMAP-backfill miss-count
    /// threshold has been reached after an rfc822 confirmation. Never call on a
    /// transient connection error.
    /// 🚨 ORDERING CONTRACT (`MessageContentStore`): the content key and its scope
    /// are captured INSIDE the delete transaction, from the row about to go away,
    /// and the release happens AFTER that transaction commits. Reversed, the header
    /// still exists when owners are counted, the count is always ≥ 1, and the FTS
    /// row is never removed — a silent no-op every outcome-only test still passes.
    func deleteConfirmedGoneHeader(headerId: String, reason: String) async {
        let captured: MessageContentStore.CapturedContent?
        let existed: Bool
        do {
            (existed, captured) = try await dbPool.write {
                db -> (Bool, MessageContentStore.CapturedContent?) in
                guard let header = try MessageHeader.fetchOne(db, key: headerId) else {
                    return (false, nil)
                }
                let captured = try MessageContentStore.capture(header, db: db)
                try header.delete(db)
                return (true, captured)
            }
        } catch {
            print("[Gone] GRDB delete failed for \(headerId): \(error)")
            return
        }
        guard existed else { return }
        print("[Gone] Deleted header \(headerId) — reason=\(reason)")
        if let captured {
            await MessageContentStore.releaseUnowned(
                captured.contentKey, scope: captured.scope,
                stores: [.searchIndex, .body], pool: dbPool)
        } else {
            // No account row to read a key space from — keep the pre-existing
            // unconditional removal rather than invent an owner. `.body` is part of
            // that pre-existing behaviour: the cascade deleted it here too.
            await MessageContentStore.release(
                ContentKey(rawValue: headerId), stores: [.searchIndex, .body], pool: dbPool)
        }
    }

    /// Deep-dive log for a failing PendingOperation. Gated by `context.diagnosedOpIds`
    /// so it fires at most once per drain per opId. Logs:
    ///   - Full op fields (accountId, folderPath, destinationPath, retryCount, …)
    ///   - Error structural unwrap (ProviderError → HTTPError statusCode, NSError domain/code)
    ///   - Classifier verdicts (isMessageNotFound, isConfirmedGone, isPermanentlyInvalid)
    ///   - DB rows scoped to the exact message + the involved folders:
    ///       * MessageHeader rows for each msgId in the op (any folder, same account)
    ///       * Source Folder row (accountId:folderPath)
    ///       * Destination Folder row (accountId:destinationPath)
    ///       * All Folders with role=.trash for the account (sanity check role lookup)
    func logStuckOpDiagnostic(_ op: PendingOperation, error: Error) async {
        let ageHours = Date().timeIntervalSince(op.createdAt) / 3600
        print("[QueueDiag] === op=\(op.id) type=\(op.type.rawValue) ===")
        print("[QueueDiag] op: accountId=\(op.accountId) folderPath=\(op.folderPath) destinationPath=\(op.destinationPath ?? "<nil>") tagValue=\(op.tagValue ?? "<nil>") userLabelId=\(op.userLabelId ?? "<nil>")")
        print("[QueueDiag] op: messageIds=\(op.messageIds) retryCount=\(op.retryCount) uidResolutionRetryCount=\(op.uidResolutionRetryCount) status=\(op.status) ageHours=\(String(format: "%.2f", ageHours))")

        // Error structural unwrap — confirms whether classifiers should/shouldn't match
        print("[QueueDiag] error.type=\(type(of: error)) error=\(error)")
        if case ProviderError.networkError(let underlying) = error {
            print("[QueueDiag] underlying.type=\(type(of: underlying)) underlying=\(underlying)")
            if case HTTPError.networkError(let statusCode) = underlying {
                print("[QueueDiag] HTTPError statusCode=\(statusCode)")
            }
            let ns = underlying as NSError
            print("[QueueDiag] NSError domain=\(ns.domain) code=\(ns.code)")
        }
        print("[QueueDiag] classifier: isMessageNotFoundError=\(isMessageNotFoundError(error)) isConfirmedGoneError=\(isConfirmedGoneError(error)) isPermanentlyInvalidError=\(isPermanentlyInvalidError(error))")

        // Message-scoped DB dump — only rows relevant to this op + its folders.
        do {
            try await dbPool.read { db in
                for msgId in op.messageIds {
                    let normalized = EmailFilter.normalizeMessageId(msgId)
                    let headers = try MessageHeader
                        .filter(
                            (Column("messageId") == msgId || Column("rfc822MessageId") == normalized) &&
                            Column("accountId") == op.accountId
                        )
                        .fetchAll(db)
                    if headers.isEmpty {
                        print("[QueueDiag] MessageHeader: NONE for msgId=\(msgId) normalized=\(normalized) account=\(op.accountId)")
                    } else {
                        for h in headers {
                            print("[QueueDiag] MessageHeader: id=\(h.id) folderId=\(h.folderId) folderPath=\(h.folderPath) messageId=\(h.messageId) rfc822=\(h.rfc822MessageId ?? "<nil>") isInInbox=\(h.isInInbox) isRead=\(h.isRead) actionTag=\(h.actionTag?.rawValue ?? "<nil>")")
                        }
                    }
                }

                let srcId = "\(op.accountId):\(op.folderPath)"
                if let src = try Folder.fetchOne(db, key: srcId) {
                    print("[QueueDiag] Folder(source): id=\(src.id) name=\(src.name) path=\(src.path) role=\(src.role.rawValue)")
                } else {
                    print("[QueueDiag] Folder(source): NONE for id=\(srcId)")
                }

                if let dest = op.destinationPath {
                    let destId = "\(op.accountId):\(dest)"
                    if let f = try Folder.fetchOne(db, key: destId) {
                        print("[QueueDiag] Folder(destination): id=\(f.id) name=\(f.name) path=\(f.path) role=\(f.role.rawValue)")
                    } else {
                        print("[QueueDiag] Folder(destination): NONE for id=\(destId)")
                    }
                }

                let trashFolders = try Folder
                    .filter(Column("accountId") == op.accountId && Column("role") == FolderRole.trash.rawValue)
                    .fetchAll(db)
                if trashFolders.isEmpty {
                    print("[QueueDiag] Folder(role=trash): NONE for account=\(op.accountId)")
                } else {
                    for f in trashFolders {
                        print("[QueueDiag] Folder(role=trash): id=\(f.id) name=\(f.name) path=\(f.path)")
                    }
                }
            }
        } catch {
            print("[QueueDiag] ERROR: scoped DB read failed: \(error)")
        }
        print("[QueueDiag] === end op=\(op.id) ===")
    }

    /// Returns true only when the provider's own response STRUCTURALLY PROVES the
    /// operation can never succeed — e.g. Gmail rejecting a label modification on
    /// a system label like `DRAFT`. Such a `400` is a provider-authoritative
    /// no-op (exit 2) and retires the durable row.
    ///
    /// 🚨 A BARE STATUS CODE IS NOT A CLASSIFICATION. The predecessor returned
    /// `true` for `HTTPError.networkError(400)`, for
    /// `HTTPError.networkErrorWithBody(400, _)` with the body bound to `_`, and
    /// for `NSError(domain: "Gmail"|"Exchange", code: 400)` — i.e. it retired the
    /// user's intention on every `400`, INCLUDING the ones nothing had
    /// classified. "The request was rejected and we do not know why" is an
    /// absence of evidence, not the provider telling us the work is already done
    /// or no longer applicable, and conflating the two is the exact clause-2
    /// conflation `Companion/Rules/Active/never-drop-user-intention.md` forbids.
    /// An unclassified `400` now falls through to the generic arm and retries —
    /// forever, if the provider never explains itself, which is the correct
    /// disposition for "we could not determine the answer". (`v2final` demotes
    /// such a chain to its queue tail via `ProviderError.persistentActionFailure`;
    /// v3 has no demote lane, so the cost of the honest classification is a
    /// retrying row rather than a silently discarded gesture.)
    ///
    /// The only shape that still retires is the one a provider can be held to:
    /// `HTTPError.networkErrorWithBody(400, body)` whose body decodes to Gmail's
    /// documented structured error object and names a deterministic rejection —
    /// see `GmailProvider.isAuthoritativeActionRejection`. That shape reaches
    /// here through `AuthedHTTP.requestPreservingBadRequestBody`, which action
    /// call sites opt into precisely so the body survives to be classified
    /// instead of being guessed at from the status line.
    nonisolated func isPermanentlyInvalidError(_ error: Error) -> Bool {
        GmailProvider.isAuthoritativeActionRejection(error)
    }

    /// Dispatch one claimed op to its provider.
    ///
    /// RETURN VALUE — the subset of `op.messageIds` the provider POSITIVELY
    /// DISPOSITIONED, or `nil` for "all of them". `executeSingleOp` retires
    /// exactly those members and leaves the rest durably queued — retirement is
    /// per MEMBER, never per batch.
    ///
    /// ⚠ AUDIT ROUND 4 — NO PROVIDER CURRENTLY RETURNS A STRICT SUBSET, and that
    /// is a strengthening rather than a simplification. `IMAPProvider.move` was
    /// the only producer: it returned the members the server's own `COPYUID`
    /// named, leaving members it did not name queued on the absence of evidence
    /// about them. It now determines EVERY member positively before returning —
    /// moved (COPYUID, or the COPY's tagged OK plus proof the member was in the
    /// source when that COPY ran), or no longer in the source folder at all,
    /// which is the provider saying there is nothing left to do. So no member is
    /// left undetermined for this arm to preserve. The narrowing path below is
    /// kept as the drain's standing contract for any provider that does return a
    /// strict subset; it is not dead code, it has no current producer.
    func executeOperation(_ op: PendingOperation, provider: any EmailProvider) async throws -> ExecutedOperation {
        switch op.type {
        case .archive, .delete:
            // Legacy enum cases — all new ops use .move. No-op for any stale rows.
            return .allMembers
        case .move:
            guard let dest = op.destinationPath else {
                print("[MoveTrace] ERROR: move op missing destinationPath")
                throw ProviderError.messageNotFound
            }
            // Self-move (source == dest) is a no-op — skip the provider call entirely.
            // This happens when archiving from All Mail on Gmail (source and dest both resolve
            // to __GMAIL_ALL_MAIL__). Treating as success lets the op be cleaned up normally.
            guard op.folderPath != dest else {
                print("[MoveTrace] executeOperation.move — no-op (source==dest): \(op.folderPath)")
                return .allMembers
            }
            let opAgeMin = Date().timeIntervalSince(op.createdAt) / 60
            print("[MoveTrace] executeOperation.move — msgIds=\(op.messageIds) from=\(op.folderPath) to=\(dest) provider=\(type(of: provider)) accountId=\(op.accountId) opId=\(op.id) retryCount=\(op.retryCount) ageMin=\(String(format: "%.1f", opAgeMin))")
            if let imap = provider as? IMAPProvider,
               let admitted = op.observedUidValidity,
               let admittedUInt = UInt32(exactly: admitted), admittedUInt > 0 {
                let outcome = try await imap.move(
                    ids: op.messageIds, from: op.folderPath, to: dest,
                    admittedUidValidity: admittedUInt)
                print("[MoveTrace] executeOperation.move — completed for \(outcome.provenIds.count)/\(op.messageIds.count) member(s), \(outcome.provenDestinations.count) with a server-named destination address")
                return ExecutedOperation(
                    provenMembers: outcome.provenIds,
                    provenDestinations: outcome.provenDestinations)
            }
            try await provider.move(ids: op.messageIds, from: op.folderPath, to: dest)
            print("[MoveTrace] executeOperation.move — completed successfully")
            return .allMembers
        case .markRead:
            if let imap = provider as? IMAPProvider,
               let admitted = op.observedUidValidity,
               let admittedUInt = UInt32(exactly: admitted), admittedUInt > 0 {
                try await imap.markRead(
                    ids: op.messageIds, folder: op.folderPath,
                    admittedUidValidity: admittedUInt)
            } else {
                try await provider.markRead(ids: op.messageIds, folder: op.folderPath)
            }
        case .markUnread:
            if let imap = provider as? IMAPProvider,
               let admitted = op.observedUidValidity,
               let admittedUInt = UInt32(exactly: admitted), admittedUInt > 0 {
                try await imap.markUnread(
                    ids: op.messageIds, folder: op.folderPath,
                    admittedUidValidity: admittedUInt)
            } else {
                try await provider.markUnread(ids: op.messageIds, folder: op.folderPath)
            }
        case .markFlagged:
            if let imap = provider as? IMAPProvider,
               let admitted = op.observedUidValidity,
               let admittedUInt = UInt32(exactly: admitted), admittedUInt > 0 {
                try await imap.markFlagged(
                    ids: op.messageIds, flagged: true, folder: op.folderPath,
                    admittedUidValidity: admittedUInt)
            } else {
                try await provider.markFlagged(ids: op.messageIds, flagged: true, folder: op.folderPath)
            }
        case .markUnflagged:
            if let imap = provider as? IMAPProvider,
               let admitted = op.observedUidValidity,
               let admittedUInt = UInt32(exactly: admitted), admittedUInt > 0 {
                try await imap.markFlagged(
                    ids: op.messageIds, flagged: false, folder: op.folderPath,
                    admittedUidValidity: admittedUInt)
            } else {
                try await provider.markFlagged(ids: op.messageIds, flagged: false, folder: op.folderPath)
            }
        case .setTag, .removeTag:
            // Action tags are local-only (ADR-IOS-036). Local state is already
            // applied at the call site; the op drains to a no-op so legacy
            // queued rows flush cleanly. No provider write.
            break
        case .markReplied:
            // A1 — `v1.6.38` had a WORKING IMAP `markReplied` (`resolveUID` +
            // `STORE \Answered`). v3 removed RFC-as-mutation-authority (D4), so
            // the restoration is the same STORE addressed by the op's own proven
            // provider address and admitted epoch. An op with no epoch is one
            // checkpoint A never admits, so this arm is only reached WITH one.
            if let imap = provider as? IMAPProvider,
               let admitted = op.observedUidValidity,
               let admittedUInt = UInt32(exactly: admitted), admittedUInt > 0 {
                try await imap.markReplied(
                    ids: op.messageIds, folder: op.folderPath,
                    admittedUidValidity: admittedUInt)
            }
            // Gmail/Exchange REST APIs don't support \Answered flag — local state preserved by sync
        case .markForwarded:
            if let imap = provider as? IMAPProvider,
               let admitted = op.observedUidValidity,
               let admittedUInt = UInt32(exactly: admitted), admittedUInt > 0 {
                try await imap.markForwarded(
                    ids: op.messageIds, folder: op.folderPath,
                    admittedUidValidity: admittedUInt)
            }
            // Gmail/Exchange REST APIs don't support $Forwarded keyword — local state preserved by sync
        case .saveDraft:
            guard let draftId = op.draftId ?? op.messageIds.first,
                  let instanceEpoch = op.instanceEpoch,
                  !instanceEpoch.isEmpty else { return .allMembers }
            let disposition = try await DraftStore.shared.pushDraftToServer(
                draftId: draftId,
                expectedInstanceEpoch: instanceEpoch,
                provider: provider,
                runtimeKind: Self.draftRuntimeIdentityKind(for: provider),
                draftsFolderPath: op.folderPath
            )
            if DebugModeManager.isLoggingEnabled() {
                print("[DraftQueue] Retiring save producer \(op.id) with disposition \(disposition)")
            }
        case .deleteDraft:
            guard let encodedId = op.messageIds.first else { return .allMembers }
            let runtimeKind = Self.draftRuntimeIdentityKind(for: provider)
            let addressKind = op.draftDeleteAddressKind.flatMap(DraftDeleteAddressKind.init(rawValue:))
            let identity: DraftDeleteIdentity
            switch runtimeKind {
            case .imap:
                guard addressKind == .providerResource,
                      let uid = Int(encodedId), uid > 0,
                      let uidValidity = op.draftServerUidValidity,
                      uidValidity > 0 else {
                    throw ProviderError.actionIdentityResolutionFailed(encodedId)
                }
                identity = .imap(
                    folder: op.folderPath,
                    uidValidity: uidValidity,
                    uid: uid)
            case .gmail:
                identity = addressKind == .gmailContainedMessage
                    ? .gmailContainedMessage(messageId: encodedId)
                    : .gmail(resourceId: encodedId)
            case .outlook:
                guard addressKind == .providerResource else {
                    throw ProviderError.actionIdentityResolutionFailed(encodedId)
                }
                identity = .outlook(graphId: encodedId)
            case .demo:
                guard addressKind == .providerResource else {
                    throw ProviderError.actionIdentityResolutionFailed(encodedId)
                }
                identity = .demo(localId: encodedId)
            case .unknown:
                throw ProviderError.actionIdentityResolutionFailed(encodedId)
            }
            try await provider.deleteDraft(identity: identity)
        case .addUserLabel:
            guard let labelId = op.userLabelId, let msgId = op.messageIds.first else { return .allMembers }
            if let gmail = provider as? GmailProvider {
                try await gmail.modifyMessage(id: msgId, addLabelIds: [labelId])
            } else if provider is ExchangeProvider {
                print("[Queue] addUserLabel not yet supported for Exchange")
            } else if let imap = provider as? IMAPProvider,
                      let admitted = op.observedUidValidity,
                      let admittedUInt = UInt32(exactly: admitted), admittedUInt > 0 {
                // A1 — `v1.6.38`'s IMAP keyword STORE, re-addressed by the op's
                // own provider address and admitted epoch (see `.markReplied`).
                try await imap.setUserLabel(
                    messageId: msgId, keyword: labelId, add: true,
                    folder: op.folderPath, admittedUidValidity: admittedUInt)
            }
        case .removeUserLabel:
            guard let labelId = op.userLabelId, let msgId = op.messageIds.first else { return .allMembers }
            if let gmail = provider as? GmailProvider {
                try await gmail.modifyMessage(id: msgId, removeLabelIds: [labelId])
            } else if provider is ExchangeProvider {
                print("[Queue] removeUserLabel not yet supported for Exchange")
            } else if let imap = provider as? IMAPProvider,
                      let admitted = op.observedUidValidity,
                      let admittedUInt = UInt32(exactly: admitted), admittedUInt > 0 {
                try await imap.setUserLabel(
                    messageId: msgId, keyword: labelId, add: false,
                    folder: op.folderPath, admittedUidValidity: admittedUInt)
            }
        }
        return .allMembers
    }

    /// On app launch, recover from any crash during the previous session.
    /// Resets inFlight ops back to queued (they were mid-execution when app died),
    /// then drains the entire queue. All operations are idempotent, so re-execution is safe.
    func reconcilePendingOperations() async {
        // Crash recovery MUST succeed — inFlight ops from the previous session are stuck
        // and will never drain unless reset to queued.
        try? await retryWrite(dbPool, label: "Queue") { db in
            let staleOps = try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchAll(db)
            if !staleOps.isEmpty {
                print("[Queue] Crash recovery: resetting \(staleOps.count) inFlight ops to queued")
                for op in staleOps {
                    var updated = op
                    updated.status = PendingStatus.queued.rawValue
                    try updated.save(db)
                }
            }
            // Clean up cancelled ops from previous session
            let cancelledCount = try PendingOperation
                .filter(Column("status") == PendingStatus.cancelled.rawValue)
                .deleteAll(db)
            if cancelledCount > 0 {
                print("[Queue] Crash recovery: cleaned up \(cancelledCount) cancelled ops")
            }
        }
        await drainPendingQueue()
        await reconcileOutbox()
        await reconcileCalendarQueue()
    }
}
