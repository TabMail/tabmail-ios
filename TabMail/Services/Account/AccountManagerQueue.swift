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
    /// member's copy landed on — IMAP's `COPYUID` (RFC 4315 §3) or the `id` on
    /// the message resource Graph returns from `/messages/{id}/move`. Empty for
    /// every other op type, for a provider whose move does not change the
    /// address at all (Gmail's `messages.modify` only adds/removes labels), and
    /// whenever the server furnished no usable evidence.
    let provenDestinations: [ProvenDestinationAddress]
    /// True only when a successful move invalidates the source provider
    /// address (IMAP and Microsoft Graph). Empty destination evidence cannot
    /// distinguish that state from Gmail's address-stable label mutation.
    let addressChangesOnMove: Bool
    /// True when an IMAP MOVE ended after possible partial completion. The
    /// original identifiers must not be retried, and both mailbox views must be
    /// refreshed before the user decides whether any remainder needs a new
    /// gesture.
    let reconcileMoveSource: Bool

    init(
        provenMembers: [String]?,
        provenDestinations: [ProvenDestinationAddress],
        addressChangesOnMove: Bool = false,
        reconcileMoveSource: Bool = false
    ) {
        self.provenMembers = provenMembers
        self.provenDestinations = provenDestinations
        self.addressChangesOnMove = addressChangesOnMove
        self.reconcileMoveSource = reconcileMoveSource
    }

    /// Every member dispositioned, nothing re-keyable.
    static let allMembers = ExecutedOperation(
        provenMembers: nil, provenDestinations: [], addressChangesOnMove: false)
}

/// Debug-gated diagnostic log for this file (global `CLAUDE.md` development
/// rule 12). `DebugModeManager.isLoggingEnabled()` is false for every ordinary
/// user — it requires the ten-tap unlock AND an allowed account — so in a
/// shipping build this is a no-op.
///
/// `@autoclosure` so the interpolation itself is skipped when the gate is off.
/// These fire per drain pass, per claimed op and per executed member, and the
/// string was previously built on every one of them. Same shape as
/// `NotificationActionRouter.log` and `MessageContentStore.log`.
///
/// 🚨 THREE lines in this file are DELIBERATELY LEFT AS UNGATED `print` and
/// must stay that way; each is marked `UNGATED BY DECISION` at its site. Each
/// reports a state that is NOT recoverable by a later sync or retry — a
/// completed op that will re-execute, a partially-completed bundle requeued
/// whole, and the F2b L4 terminal identity drop whose accepted cost
/// `KNOWN_ISSUES.md` `IOS-QUEUE-003` item 4 records as "bounded and VISIBLE".
/// Gating them would make that visibility conditional on a debug unlock the
/// affected user does not have, which is rule 12's own
/// production-observability exception.
///
/// ⚠️ BUT A `print` COULD NEVER HAVE DELIVERED THAT EXCEPTION, so each site now
/// also writes `BackgroundSyncLogger.logError` — ungated at the write,
/// file-backed (`error.log`), exported by `DebugLogView`. There is no
/// `freopen`/`dup2` anywhere in this tree (`rg -g '*.swift' 'freopen|dup2'`
/// returns nothing), so on a device `stdout` goes nowhere and the
/// "production observability" the exception buys from a bare `print` is zero.
/// The prints and their gating are UNCHANGED — this is strictly additive, and
/// changes no gating decision.
///
/// ⚠️ AND "the only witness" was overstated at two of the three: it is
/// literally true only where the durable row does NOT survive the failure —
/// the identity-refusal site, which DELETES the op. At the other two the
/// `PendingOperation` row is still there (its delete failed / it was requeued
/// whole), so the row itself is durable evidence of the op; what no durable
/// artifact recorded was the FAILURE. Each site states its own case.
private func queueLog(_ message: @autoclosure () -> String) {
    guard DebugModeManager.isLoggingEnabled() else { return }
    print(message())
}

extension AccountManager {

    // MARK: - Persistent Action Queue

    /// Shared mutable state for parallel drain tasks. Reference type so lane Tasks
    /// see each other's updates when they interleave at await points. The Tasks
    /// inherit `AccountManager` isolation, and the `@Sendable` closure passed to
    /// `ProviderWorkQueue.execute` only forwards the context back through
    /// `await self.executeSingleOp`, so every mutation below is serialized by the
    /// actor even while provider I/O overlaps.
    ///
    /// `@unchecked Sendable` is required solely because that `@Sendable` closure
    /// captures the reference; it does NOT make the fields thread-safe. A future
    /// direct access from that closure, `Task.detached`, a GRDB closure, or another
    /// nonisolated context would violate this contract and must add synchronization
    /// or restore the actor hop. Because the annotation lets a context-only
    /// off-actor access compile, this is a documented policy deviation rather than
    /// a compiler-enforced invariant; see `IOS-QUEUE-010`. `internal` (not
    /// `private`) so tests can construct it directly to call `executeSingleOp`.
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

        /// One member a completed `.move` landed in a folder the account treats
        /// as its INBOX, recorded by DURABLE IDENTITY rather than by address.
        ///
        /// `messageId` alone is NOT enough and using it alone would be a C3
        /// hazard, not merely a miss: on IMAP a UID is mailbox-local, so
        /// resolving a bare source UID against the destination folder can land
        /// on an unrelated message that happens to share that number
        /// (`DurableIdentityLookup`'s G3 rejection exists for exactly this).
        /// The rfc822 identity is what survives BOTH re-key paths, so it is
        /// captured beside the address and both are handed to
        /// `DurableIdentityLookup.find` later.
        struct InboxEntry: Hashable, Sendable {
            let accountId: String
            let messageId: String
            let rfc822MessageId: String?
        }

        /// Members that ENTERED an inbox during this drain, keyed by the same
        /// `"accountId|destinationPath"` string as `foldersToSync` so the
        /// post-drain phase can enqueue them immediately after that folder's
        /// sync — the moment both the durable row and its FTS entry are under
        /// their final ids (ADR-IOS-008 decision 3; see `recordMembersThatEnteredInbox`).
        ///
        /// `Mutex`-protected even though current accesses inherit `AccountManager`
        /// isolation. This value-level protection is deliberate future-proofing:
        /// preserve the lock and protect consistency upward if a sibling ever moves
        /// off-actor; never unprotect this field merely because the plain siblings
        /// currently rely on the actor contract above (`IOS-QUEUE-010`).
        let enteredInbox = Mutex<[String: [InboxEntry]]>([:])
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
                queueLog("[Queue] ERROR: Failed to fetch pending ops: \(error)")
                break
            }
            guard !ops.isEmpty else { break }

            if pass == 0 {
                let summary = ops.map { "\($0.type.rawValue)(\($0.messageIds.count)msgs)" }.joined(separator: ", ")
                queueLog("[Queue] Draining \(ops.count) ops: \(summary)")
            } else {
                queueLog("[Queue] Drain pass \(pass + 1): \(ops.count) ops remaining/new")
            }

            // Claim all valid ops (unchanged: failedAccounts / provider checks / atomic claim).
            var claimed: [PendingOperation] = []
            for op in ops {
                if ctx.failedAccounts.contains(op.accountId) { continue }
                guard providers[op.accountId] != nil else {
                    queueLog("[Queue] No provider for \(op.accountId) — skipping \(op.type.rawValue)")
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
                            queueLog("[Queue] Op \(op.id.prefix(8)) cancelled by undo, deleted")
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
                        // ⚑ UPDATE (2026-08-01, CORRECTED 2026-08-06):
                        // `IMAPProvider.deleteDraft` no longer executes a bare UID on the
                        // strength of the number alone — it requires the typed
                        // `.imap(folder, uidValidity, uid)` address and compares the live
                        // SELECT's epoch against the recorded (v72) minted epoch, failing
                        // closed on a provable mismatch AND on an epoch the server did not
                        // report. So that provider is now guarded at BOTH ends. The
                        // 2026-08-01 wording said it "either verifies an rfc822 identity
                        // on the wire, or (v72) corroborates the UID against the recorded
                        // epoch": there is no rfc822 leg — `e0d3d30e0` removed it, and
                        // ADR-IOS-068/D4 bans an RFC 822 Message-ID from selecting or
                        // authorizing a mutation target — so the epoch arm is the only
                        // arm. This check stays: it is provider-agnostic, it is what keeps
                        // an op recorded under a discarded numbering from running at all,
                        // and the reasoning above is what it exists for. (The paragraph
                        // above describing `queueDraftDelete` recording `[uid, rfc822]` is
                        // HISTORY — it explains why this check was added; today's
                        // `.deleteDraft` records a single typed address plus
                        // `draftServerUidValidity`.)
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
                    queueLog("[Queue] ERROR: Failed to claim op \(op.id): \(error)")
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
            queueLog("[MoveTrace] post-drain sync — syncing \(ctx.foldersToSync.count) destination folders: \(ctx.foldersToSync)")
            for key in ctx.foldersToSync {
                let parts = key.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let accountId = String(parts[0])
                let folderPath = String(parts[1])
                guard let queue = workQueues[accountId] else { continue }
                guard let folder = try? await dbPool.read({ db in
                    try Folder.filter(Column("accountId") == accountId && Column("path") == folderPath).fetchOne(db)
                }) else {
                    queueLog("[MoveTrace] post-drain sync — folder not found: \(accountId)|\(folderPath)")
                    continue
                }
                do {
                    try await queue.execute(priority: .userAction) {
                        try await self.syncEngine.syncFolderMessages(folder: folder, provider: queue.provider)
                    }
                    queueLog("[MoveTrace] post-drain sync — completed for \(folder.name)")
                } catch {
                    queueLog("[MoveTrace] post-drain sync — failed for \(folder.name): \(error)")
                }
                // ADR-IOS-008 decision 3. Deliberately AFTER the sync attempt and
                // OUTSIDE its do/catch — see `enqueueAIForMembersThatEnteredInbox`
                // for why either branch is a safe place to resolve an id, and why
                // no earlier one is.
                await enqueueAIForMembersThatEnteredInbox(key: key, folderPath: folderPath, context: ctx)
            }
        }
    }

    /// Record which members of a just-completed `.move` are now sitting in an
    /// INBOX, so the post-drain phase can enqueue AI for them.
    ///
    /// **THIS RESTORES ADR-IOS-008 PARITY; it does not invent a pattern.** The
    /// reference implementation is the TB addon's `onMoved.js`, whose
    /// `!wasInInbox && nowInInbox` arm states the rationale in its own comment:
    /// *"inbox scans may not process this message (e.g., sender filter or
    /// maxEmails cap). When a message ENTERS inbox, proactively run the unified
    /// pipeline on just this message so action tags are applied **without
    /// requiring a user click**."* iOS had the other two decision-3 events
    /// (new-mail-arrival via `BodyFetchProcessor`, startup scan via
    /// `ActiveAIQueue.repopulateFromDatabase`) and was missing this one, so a
    /// message moved into the inbox got AI only if the user opened it — i.e.
    /// only by performing the click the action tag exists to make unnecessary.
    ///
    /// **`nowInInbox` is read from the DURABLE ROW, never inferred.** The guard
    /// chain below (`accountId`, `folderPath == destinationPath`, `isInInbox`) is
    /// deliberately the SAME chain as
    /// `AccountManagerActions.restoreInboxAICacheAfterOptimisticMove`, the other
    /// place that asks "did this row actually land in the inbox" — the two are
    /// meant to stay recognisably paired.
    ///
    /// **`wasInInbox` is approximated by `dest != op.folderPath` at the call
    /// site, and that is a deliberate, benign deviation from TB.** The source row
    /// is gone by now, so a true `!wasInInbox` would cost another lookup. The
    /// only case it admits that TB would skip is inbox→inbox across two
    /// inbox-flagged folders, and the cost there is one DEDUPED job whose summary
    /// is already cached (`executeSummaryJob` returns on a cache hit and still
    /// chains the action job), never a wrong or duplicated write.
    private func recordMembersThatEnteredInbox(
        _ op: PendingOperation, destinationPath: String, context: DrainContext
    ) async {
        let accountId = op.accountId
        // Follow the provider-proven handoff first: when `COPYUID` landed,
        // `finishMove` has already re-keyed this row to its destination address,
        // so the source-shaped id no longer names it. When it did not, the alias
        // map is empty and this returns the id unchanged — which is still the
        // right key, because the row then keeps its source PK.
        let candidateIds = op.messageIds.map { messageId in
            MessageHeaderRekey.currentHeaderId(
                afterHandoffFrom: MessageIdentity.headerId(
                    accountId: accountId, folderPath: op.folderPath, messageId: messageId))
        }
        let entries: [DrainContext.InboxEntry] = (try? await dbPool.read { db in
            var found: [DrainContext.InboxEntry] = []
            for headerId in candidateIds {
                guard let header = try MessageHeader.fetchOne(db, key: headerId),
                      header.accountId == accountId,
                      header.folderPath == destinationPath,
                      header.isInInbox
                else { continue }
                found.append(DrainContext.InboxEntry(
                    accountId: accountId,
                    messageId: header.messageId,
                    rfc822MessageId: header.rfc822MessageId))
            }
            return found
        }) ?? []
        guard !entries.isEmpty else { return }
        let key = "\(accountId)|\(destinationPath)"
        context.enteredInbox.withLock { $0[key, default: []].append(contentsOf: entries) }
        queueLog("[MoveTrace] entered inbox — \(entries.count) member(s) of op \(op.id) landed in \(destinationPath), AI enqueue deferred to post-drain")
    }

    /// Enqueue AI for the members this drain moved into `folderPath`'s inbox.
    ///
    /// **WHY THIS RUNS HERE AND NOWHERE EARLIER — constraint: the id must be the
    /// POST-RE-KEY id.** `ActiveAIQueue.executeJob` resolves the body with
    /// `ContentKey(rawValue: job.headerId)`, so a job carrying a superseded
    /// address finds no FTS body and is dropped. A move can change that address
    /// twice over, by two different paths:
    ///  - the drain's own `COPYUID` re-key (`MessageHeaderRekey.finishMove`, with
    ///    the FTS/bodyAsset mirror in `publishMoveFinish`), and
    ///  - the sync's UID remap (`SyncEngine.runSyncMessages`, with its FTS mirror
    ///    in `SyncEngineFullSync.syncMessages`) when no `COPYUID` was available.
    ///
    /// Both mirrors have completed by the time the post-drain sync call above
    /// returns, so **at this point the durable id and the FTS key agree by
    /// construction** — which is a stronger guarantee than "the sync succeeded",
    /// and why this sits outside that do/catch. If `runSyncMessages` threw, its
    /// transaction rolled back and NEITHER was re-keyed; if it committed, the FTS
    /// mirror runs behind a `try?` that cannot propagate. There is no torn state
    /// to land in.
    ///
    /// Enqueueing from a gesture, from `optimisticMoveToFolder`, or at
    /// `finishMove` time would all race one of those re-keys — that race is
    /// `IOS-AI-005`'s shape and is exactly what this placement avoids.
    ///
    /// No AI-enabled gate: `dispatchPending` already refuses on `canProcessAI`
    /// and clears the queue, with `repopulateFromDatabase` re-discovering when
    /// conditions change. `repopulateFromDatabase` enqueues ungated for the same
    /// reason.
    private func enqueueAIForMembersThatEnteredInbox(
        key: String, folderPath: String, context: DrainContext
    ) async {
        let entries = context.enteredInbox.withLock { $0.removeValue(forKey: key) } ?? []
        guard !entries.isEmpty else { return }
        // This path intentionally uses the dedicated destination-scoped,
        // RFC-first resolver below: the recorded UID may be stale after the move,
        // so `DurableIdentityLookup` cannot prove identity for this caller. A
        // successful rekey leaves the destination row available by RFC identity;
        // `ActiveAIQueue` later revalidates its live Inbox scope.
        let resolved: [(headerId: String, accountId: String)] = (try? await dbPool.read { db in
            try Self.resolveInboxEntryAITargets(
                entries: entries, folderPath: folderPath, db: db)
        }) ?? []
        guard !resolved.isEmpty else {
            queueLog("[MoveTrace] entered inbox — \(entries.count) member(s) in \(folderPath) resolved to no live inbox row, nothing enqueued")
            return
        }
        // Per-item `enqueue` (S + R, with A chained by the summary job) mirrors
        // the sibling event-driven site, `BodyFetchProcessor.flushBatch`'s
        // `enableAI && item.isInInbox` arm.
        for item in resolved {
            await ActiveAIQueue.shared.enqueue(headerId: item.headerId, accountId: item.accountId)
        }
        queueLog("[MoveTrace] entered inbox — enqueued AI for \(resolved.count) member(s) in \(folderPath)")
    }

    /// The id each recorded member is CURRENTLY addressable by, for the AI
    /// enqueue above. `internal static` for executable regression coverage — the
    /// same reason `AccountManagerActions
    /// .restoreInboxAICacheAfterOptimisticMove` is internal; it is not a second
    /// enqueue path.
    ///
    /// ⚠️ **DO NOT "simplify" this to `MessageIdentity.headerId(accountId:
    /// folderPath: messageId:)` on the recorded `messageId`.** That reconstructs
    /// the address the member had when it was recorded, which the sync's UID
    /// remap can already have superseded — the job would then miss its FTS body
    /// and be dropped. Worse, resolving a bare source UID against a different
    /// folder can land on an UNRELATED message that shares that number, because
    /// IMAP UIDs are mailbox-local.
    ///
    /// 🚨 **AND DO NOT ROUTE THIS BACK THROUGH `DurableIdentityLookup.find` —
    /// IT WAS WRITTEN THAT WAY, AND IT RESOLVED THE WRONG MESSAGE.** That
    /// helper's header lists six consumers that must stay "in lockstep", so a
    /// reader who finds a seventh identity resolution sitting outside it will
    /// try to restore consistency by routing this through `find` again. That
    /// reintroduces a wrong-message defect, for a reason that is a PREMISE of
    /// the helper rather than a bug in it:
    ///
    ///  - `find`'s **step 1** matches `(accountId, folderPath, messageId)` and
    ///    returns immediately with **no rfc822 check** — the only unguarded step
    ///    of its three. Its stated justification is *"Unambiguous: IMAP UIDs are
    ///    scoped per folder, so a hit here is provably the same message."* The G3
    ///    audit that added rejection logic added it to step **2**, the
    ///    folder-BLIND case; step 1 was deliberately left bare.
    ///  - That is sound **only if the `(folderPath, messageId)` pair you pass is
    ///    the message's CURRENT address.** All six lockstep consumers pass a
    ///    STAGED row's address, which the NSE has just observed on the server —
    ///    current by construction.
    ///  - **This caller cannot honour that.** It deliberately passes the
    ///    PRE-REMAP UID against the folder the message has only just moved INTO.
    ///    An unrelated message can legitimately occupy that exact address, and
    ///    step 1 returns it. Verified: `MoveIntoInboxAIEnqueueTests
    ///    .aiTargetIsNeverAUidCollisionVictim` failed on this code, resolving the
    ///    decoy's body instead of the moved message's.
    ///
    /// The distinction that keeps the two apart: the lockstep list is about
    /// **dedup identity** for the merge and the reader. This is **AI-target
    /// selection after a known move**, whose input address is stale on purpose.
    /// Consistency must not be bought by reintroducing the wrong-message defect.
    ///
    /// So the priority is INVERTED relative to `find`: the rfc822 identity is
    /// the only thing that survives both re-key paths, so it is required rather
    /// than used as a fallback.
    ///
    /// The RFC index hint is load-bearing with migration-left statistics. Without
    /// it SQLite walks `messageHeader_accountId_messageId (accountId=?)`; on the
    /// current migrated schema with 200k rows / 100k per account, a hit/miss took
    /// 17.0–26.2 ms (p95) versus 0.004–0.005 ms through the v1 single-column RFC
    /// index. After `ANALYZE`, both forms took 0.003–0.006 ms. This loop is already
    /// off-main and the hint adds no write, space, or concurrency cost.
    ///
    /// A composite index would add per-message write/space cost, while foreground
    /// whole-database `ANALYZE` is disproportionate and does not improve every
    /// query class. If the named index disappears, the statement throws and this
    /// caller's existing `try?` resolves no AI target rather than guessing.
    ///
    /// The destination-folder predicate already selects the intended move target;
    /// `ORDER BY id ASC LIMIT 1` deliberately makes same-folder duplicate-RFC rows
    /// deterministic. It does NOT prefer or require `isInInbox`, because
    /// `ActiveAIQueue.readJobOutcome` remains the authoritative live scope check.
    /// The bounded N+1 is retained: entries are only the members of one completed
    /// operation, and per-entry refusal/logging remains clearer than broadening this
    /// fix into a set-based identity rewrite.
    nonisolated static func resolveInboxEntryAITargets(
        entries: [DrainContext.InboxEntry], folderPath: String, db: Database
    ) throws -> [(headerId: String, accountId: String)] {
        var out: [(headerId: String, accountId: String)] = []
        for entry in entries {
            // FAIL CLOSED, and OBSERVABLY. A member with no usable rfc822
            // identity cannot be re-identified across a UID remap by anything
            // this function has, and guessing from the stale address is the
            // wrong-message bug above. Refusing costs only that this message
            // waits for the ordinary foreground repopulate or an open — but a
            // SILENT refusal would be indistinguishable from "AI has not run
            // yet", which is exactly `IOS-AI-005`'s unobservable-drop shape.
            // Debug-gated per development rule 12.
            guard let rfc822 = entry.rfc822MessageId, !rfc822.isEmpty else {
                queueLog("[MoveTrace] entered inbox — REFUSED AI enqueue for \(entry.accountId) uid=\(entry.messageId) in \(folderPath): no rfc822 Message-ID, cannot re-identify across a UID remap")
                continue
            }
            // Scoped to the destination FOLDER, so the row this lands on is the
            // one that entered THIS inbox. `isInInbox = 1` is deliberately NOT a
            // conjunct here: `folderPath` already pins the folder, the capture in
            // `recordMembersThatEnteredInbox` only records rows that were
            // `isInInbox`, and `ActiveAIQueue.readJobOutcome` independently
            // refuses a job whose row is no longer in an inbox (`.scopeExited`).
            // A redundant conjunct in a correctness guard can mask the failure of
            // the one that matters.
            guard let id = try String.fetchOne(
                db, sql: Self.inboxEntryAITargetSQL,
                arguments: [entry.accountId, folderPath, rfc822]
            )
            else {
                queueLog("[MoveTrace] entered inbox — no live row in \(folderPath) for rfc822 identity of uid=\(entry.messageId), nothing enqueued")
                continue
            }
            out.append((headerId: id, accountId: entry.accountId))
        }
        return out
    }

    /// The exact moved-inbox AI-target statement, exposed so plan coverage
    /// exercises production SQL instead of a test-only copy.
    nonisolated static let inboxEntryAITargetSQL = """
        SELECT id FROM messageHeader INDEXED BY messageHeader_rfc822MessageId
        WHERE accountId = ? AND folderPath = ? AND rfc822MessageId = ?
        ORDER BY id ASC
        LIMIT 1
        """

    // MARK: - Queued-member identity lookup

    /// The `messageHeader` identity columns a drain needs for one queued member.
    struct QueuedMemberIdentity {
        let rfc822MessageId: String?
        let messageId: String
    }

    /// Resolves the identity columns for EVERY member of a queued operation in two
    /// set-based statements, replacing one `fetchOne` per member.
    ///
    /// ## Why this is not an N+1 tidy-up
    ///
    /// The per-member statement was
    /// `WHERE (messageId = ? OR rfc822MessageId = ?) AND accountId = ?`, and with no
    /// `sqlite_stat1` row for a full index on `messageHeader` — the regime a device
    /// holds until `SyncEngineMaintenance.runRefreshPlannerStatisticsIfStale` runs,
    /// see ADR-IOS-029 — SQLite cannot use a two-index `MULTI-INDEX OR` for it and
    /// falls back to `SEARCH messageHeader USING INDEX messageHeader_accountId_messageId
    /// (accountId=?)`: a walk of the whole account that stops at the first matching row.
    /// Measured on a 260k-row fixture, 189,800 rows in the account, SQLite 3.51.0 (Mac;
    /// a device is 2–4× slower), 200 members:
    ///
    /// ```
    ///                                        stale stats      ANALYZEd
    ///   per-member fetchOne (before)          12,229 ms          11 ms
    ///   IN-list arm A + hinted arm B (after)      <1 ms          <1 ms
    /// ```
    ///
    /// ⚠️ The cost depends on WHERE the member sits in the walk, not merely on whether
    /// it exists — the ADR's "probe with a value that EXISTS" warning has this sibling.
    /// The same 200 lookups against members at the HEAD of `(accountId, messageId)`
    /// order measured 0.105 ms each and made the defect look absent. The figures above
    /// draw from the tail, which is where a bulk archive of recent mail lands.
    ///
    /// ## Ordering of the two arms, and what changed
    ///
    /// Arm A matches `messageId` exactly, arm B matches the normalized
    /// `rfc822MessageId`; a member resolved by both takes arm A. That is the same
    /// precedence the `MULTI-INDEX OR` plan already applied whenever statistics
    /// existed. Within one arm several rows can match — `messageId` is a per-folder
    /// UID and repeats across the folders of one account (the fixture has 8 rows for
    /// `messageId = '1'` in one account) — so the pick is made deterministic with
    /// `ORDER BY isInInbox DESC, id ASC`, the same inbox-preferred tie-break
    /// `ChatStore.findByStableIdSQL` uses. **This is a deliberate narrowing:** the
    /// previous `fetchOne` over an `OR` returned whichever row its plan reached first,
    /// so which sibling won already differed between statistics regimes. The consumers
    /// feed `recordRecentlyCompleted`, so the change is which sibling's ids enter a 30s
    /// sync-protection set, never which message is mutated.
    ///
    /// ## `INDEXED BY` on arm B is load-bearing
    ///
    /// Without it, arm B plans as `messageHeader_accountId_messageId (accountId=?)` in
    /// the stale regime — one account walk for the whole op (69 ms measured) instead of
    /// one per member. With it, both regimes seek: `messageHeader_rfc822MessageId
    /// (rfc822MessageId=?)`, 0 ms. Same reasoning and same fail-safe as
    /// `ChatStore.findByStableIdSQL`: a migration that drops or renames the index makes
    /// this statement THROW rather than silently walk, and both callers already treat a
    /// throw as "no identity columns collected".
    nonisolated static func headerIdentitiesForQueuedMembers(
        _ memberIds: [String], accountId: String, db: Database
    ) throws -> [String: QueuedMemberIdentity] {
        guard !memberIds.isEmpty else { return [:] }

        var normalizedByRaw: [String: String] = [:]
        for id in memberIds { normalizedByRaw[id] = EmailFilter.normalizeMessageId(id) }

        // Keyed by the value each arm matches on. `pick` keeps the inbox-preferred,
        // lowest-`id` row so a member resolves to the same sibling every time.
        var byMessageId: [String: (sortKey: (Int, String), identity: QueuedMemberIdentity)] = [:]
        var byRfc822: [String: (sortKey: (Int, String), identity: QueuedMemberIdentity)] = [:]

        func absorb(_ rows: [Row], into table: inout [String: (sortKey: (Int, String), identity: QueuedMemberIdentity)],
                    keyedBy key: (Row) -> String?) {
            for row in rows {
                guard let bucket = key(row) else { continue }
                let rowId: String = row["id"]
                let isInInbox: Bool = row["isInInbox"]
                // isInInbox DESC → inbox rows sort first, hence `0` for inbox.
                let sortKey = (isInInbox ? 0 : 1, rowId)
                let identity = QueuedMemberIdentity(
                    rfc822MessageId: row["rfc822MessageId"], messageId: row["messageId"])
                if let existing = table[bucket], existing.sortKey <= sortKey { continue }
                table[bucket] = (sortKey, identity)
            }
        }

        for chunk in Array(normalizedByRaw.keys).chunked(into: SyncConfig.sqlChunkSize) {
            let rows = try Row.fetchAll(
                db, sql: Self.queuedMemberIdentitySQL(matching: "messageId", count: chunk.count),
                arguments: StatementArguments([accountId] + chunk))
            absorb(rows, into: &byMessageId, keyedBy: { (row: Row) -> String? in row["messageId"] })
        }
        for chunk in Array(Set(normalizedByRaw.values)).chunked(into: SyncConfig.sqlChunkSize) {
            let rows = try Row.fetchAll(
                db, sql: Self.queuedMemberIdentitySQL(matching: "rfc822MessageId", count: chunk.count),
                arguments: StatementArguments([accountId] + chunk))
            absorb(rows, into: &byRfc822, keyedBy: { (row: Row) -> String? in row["rfc822MessageId"] })
        }

        var out: [String: QueuedMemberIdentity] = [:]
        for (raw, normalized) in normalizedByRaw {
            if let hit = byMessageId[raw] {
                out[raw] = hit.identity
            } else if let hit = byRfc822[normalized] {
                out[raw] = hit.identity
            }
        }
        return out
    }

    /// The statements `headerIdentitiesForQueuedMembers` runs, exposed so a plan test
    /// asserts against production's own SQL rather than a copy that could drift
    /// (`ChatStore.findByStableIdSQL` / `MessageContentStore.ownersSQL` precedent).
    nonisolated static func queuedMemberIdentitySQL(matching column: String, count: Int) -> String {
        let placeholders = Array(repeating: "?", count: count).joined(separator: ", ")
        // Arm B needs the hint; arm A's plan is already a two-column seek in both
        // regimes, and an unnecessary hint would only add a way for a future migration
        // to break the statement.
        let hint = column == "rfc822MessageId" ? " INDEXED BY messageHeader_rfc822MessageId" : ""
        return """
            SELECT id, messageId, rfc822MessageId, isInInbox
            FROM messageHeader\(hint)
            WHERE accountId = ? AND \(column) IN (\(placeholders))
            """
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
                    provenDestinations: executed.provenDestinations,
                    addressChangesOnMove: executed.addressChangesOnMove,
                    context: context)
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
                        // Two set-based statements for the whole op, not one walk per
                        // member — see `headerIdentitiesForQueuedMembers`. One tuple per
                        // member, in member order, `nil` columns when no row resolves,
                        // exactly as the per-member `fetchOne` produced.
                        let identities = try Self.headerIdentitiesForQueuedMembers(
                            currentOp.messageIds, accountId: currentOp.accountId, db: db)
                        return currentOp.messageIds.map { msgId in
                            let header = identities[msgId]
                            return (msgId, header?.rfc822MessageId, header?.messageId)
                        }
                    }
                } catch {
                    queueLog("[Queue] WARNING: Failed to collect rfc822 info for \(currentOp.id): \(error)")
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
            let finishResult: MoveFinishResult
            do {
                finishResult = try await retryWrite(dbPool, label: "Queue") { db in
                    let result = try MessageHeaderRekey.finishMove(
                        currentOp,
                        destinations: executed.provenDestinations,
                        addressChangesOnMove: executed.addressChangesOnMove,
                        db: db)
                    MessageHeaderRekey.publishAddressHandoffsAfterCommit(
                        result.applied, in: db)
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    return result
                }
            } catch {
                // 🚨 UNGATED BY DECISION (rule 12's production-observability
                // exception). A completed op that could not be deleted WILL run
                // again on the next drain, so the wire effect it already applied
                // can be applied twice. No sync pass or retry recovers a
                // duplicate that has already been made, and gating this would hide
                // it behind a debug unlock the affected user does not have.
                //
                // ⚠️ CORRECTED — this line is NOT "its only witness". The DELETE is
                // what failed, so the `PendingOperation` row SURVIVES and is itself
                // durable evidence of the op that will re-run. What nothing durable
                // records is the FAILURE, which is what the `logError` below writes.
                // A bare `print` could not have been the witness in any case: with
                // no `freopen`/`dup2` in this tree, `stdout` is discarded on device.
                print("[Queue] CRITICAL: Failed to delete completed PendingOperation \(currentOp.id) after retries — will re-execute on next drain")
                BackgroundSyncLogger.logError(
                    "CRITICAL: failed to delete completed PendingOperation \(currentOp.id) (type \(opType)) after retries — it stays queued and WILL re-execute, so a wire effect already applied may be applied twice: \(error)",
                    source: "actionQueue")
                finishResult = .empty
            }
            await publishMoveFinish(finishResult)
            await materializeDeferredMoveSuccessors(after: currentOp, result: finishResult)
            if [.archive, .delete, .move].contains(currentOp.type), let dest = currentOp.destinationPath {
                context.foldersToSync.insert("\(currentOp.accountId)|\(dest)")
                if executed.reconcileMoveSource {
                    context.foldersToSync.insert("\(currentOp.accountId)|\(currentOp.folderPath)")
                }
                // ADR-IOS-008 decision 3's third event — "message moved to
                // inbox" — restored. Only `.move` can name an inbox: `.archive`
                // and `.delete` resolve their destination from the archive and
                // trash ROLES, and a same-folder move is a no-op.
                if currentOp.type == .move, dest != currentOp.folderPath {
                    await recordMembersThatEnteredInbox(
                        currentOp, destinationPath: dest, context: context)
                }
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
                    dropDeferredMoveSuccessors(for: currentOp.id)
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
                    queueLog("[Queue] Conflict in batch \(opType) (\(opMsgCount) msgs) — splitting into individual ops")
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
                        dropDeferredMoveSuccessors(for: currentOp.id)
                    } catch {
                        queueLog("[Queue] Failed to split batch op \(currentOp.id): \(error) — batch will retry as-is")
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
                queueLog("[Queue] Conflict: \(opType) — message not found, dropping")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                dropDeferredMoveSuccessors(for: currentOp.id)
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
                queueLog("[Queue] Permanently invalid \(opType): \(error) — dropping")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                dropDeferredMoveSuccessors(for: currentOp.id)
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
            // never-drop violation. Audit round 2 routed `IMAPProvider.move`'s
            // evidence gates to the dedicated `ProviderEvidenceUnavailable` arm
            // below — requeue and retry WITHOUT poisoning the account, rather than
            // the generic connection arm it originally fell through to — and audit
            // round 4 removed the withheld-`COPYUID` gate entirely, so what is left
            // of that arm refuses only BEFORE any wire mutation.
            //
            // ⚠️ CORRECTED 2026-08-06 (R12-T4). This paragraph used to conclude
            // "`IMAPProvider.move` therefore no longer raises this error at all",
            // which is LITERALLY FALSE and should never have been written as an
            // absolute. BOTH overloads can still raise it: the epoch-less
            // `move(ids:from:to:)` raises it as its ENTIRE BODY, and the
            // epoch-bearing overload raises it via `nativeUIDSet`, which refuses
            // any id that is not a bare positive integer.
            //
            // The CONCLUSION survives, but by a different argument — and it is that
            // argument, not the false absolute, that a future reader must check: an
            // IMAP op cannot REACH either raise, because Checkpoint A refuses to
            // claim an IMAP non-draft op at all unless `idsAreCanonicalUIDs` holds
            // AND a positive admitted epoch is established. By the time the executor
            // runs, the ids are exactly what `nativeUIDSet` accepts and the
            // epoch-bearing overload is the one selected. The guarantee lives in the
            // ADMISSION guard, not in the provider method: weaken Checkpoint A and
            // the premises below stop holding.
            //
            // Ported from `v2final:AccountManagerQueue`'s `.deleteDraft` arm
            // ("TERMINAL drop of a provider-authoritative identity refusal").
            if case ProviderError.actionIdentityResolutionFailed(let refusedId) = error {
                // ⚠️ TWO OP CLASSES REACH THIS ARM, NOT ONE (corrected 2026-08-06,
                // R12-T4). `.deleteDraft` raises it from its own identity switch,
                // and since `eff3ded9d` `.saveDraft` raises it too, via
                // `DraftStore.pushDraftToServer`'s `runtimeKind == .unknown` guard.
                // The sentence below used to name `.deleteDraft` as "the op class
                // that raises this error", and a comment that names a sole claimant
                // which has since gained a sibling is how a later reader concludes
                // the arm's reasoning covers their case when it was never written
                // about it. For `.saveDraft` the ids are not an address/identity
                // pair at all, so the never-split rule below is vacuously satisfied
                // rather than reasoned about — and what a `.saveDraft` drop costs is
                // NOT what the paragraph two below describes: there is no
                // server-side object yet. What survives instead is the LOCAL `Draft`
                // row, which this arm never touches, so the user's authored content
                // stays visible in Drafts and a later edit re-queues the Save.
                //
                // ⚑ NEVER SPLIT THIS ONE. A revision of this branch, on seeing an op
                // with more than one id, split it into one op per id so "the sibling the
                // provider CAN verify" could execute. For `.deleteDraft` — the op class
                // this rule was written about — the ids are not siblings: slot 0 is the
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
                // have (F2b L4). Terminal drop is the disposition **this tree already
                // has** and keeps; the intention loss is bounded and visible, and adding
                // a demote path is a separate change. ⚠️ This read *"the disposition v3
                // already shipped"* until R16-4's class census; **v3 has never shipped**
                // — neither v3 nor its `v2final` sibling has ever been on a user device,
                // both branch from `v1.6.38` (`07a4bb703`) — so the phrase asserted a
                // shipped baseline that does not exist. Nothing about the acceptance
                // rests on it: the licence is `IOS-QUEUE-003` item 4's bounded-and-
                // VISIBLE argument, which is stated on its own terms below.
                // 🚨 UNGATED BY DECISION (rule 12's production-observability
                // exception). This is the F2b L4 TERMINAL DROP of a durable user
                // intention. `KNOWN_ISSUES.md` `IOS-QUEUE-003` item 4 accepts
                // that cost expressly because the loss is "bounded and VISIBLE";
                // gating this would silently convert an accepted, observable drop
                // into an unobservable one and weaken a recorded decision.
                //
                // ✅ THE "ONLY WITNESS" CLAIM IS LITERALLY TRUE HERE, AND ONLY
                // HERE, of the three sites: the write below DELETES the row, so
                // after this arm no durable artifact of the intention remains.
                // That is exactly why the file channel matters most at this site —
                // a bare `print` reaches nobody on a device (`stdout` is discarded;
                // there is no `freopen`/`dup2` in this tree), so before the
                // `logError` below the "VISIBLE" half of the accepted cost was not
                // actually being delivered.
                print("[Queue] Identity refused in \(opType) (\(opMsgCount) id(s)): '\(refusedId)' is not a verifiable identity and never will be — dropping the op (the server-side object is untouched and remains visible for a re-issued gesture)")
                BackgroundSyncLogger.logError(
                    "TERMINAL DROP: identity refused in \(opType) (\(opMsgCount) id(s)) — '\(refusedId)' is not a verifiable identity and never will be, so the op is dropped (IOS-QUEUE-003 item 4; the server-side object is untouched and remains visible for a re-issued gesture)",
                    source: "actionQueue")
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                dropDeferredMoveSuccessors(for: currentOp.id)
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
                queueLog("[Queue] Evidence unavailable for \(opType) (\(opMsgCount) msgs): \(error) (age \(String(format: "%.1f", ageHours))h) — op stays queued, retries next drain; the rest of this account keeps draining")
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
            queueLog("[Queue] Failed \(opType): \(error) (age \(String(format: "%.1f", ageHours))h) — will retry")
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

    /// Publish a COMMITTED local move finish into the **three** stores that key
    /// by `messageHeader.id` but do not live in the GRDB database — the
    /// in-memory undo stack, the FTS index, and the body-asset manifest. Applied
    /// re-keys move all three. Retained-unaddressed members lose only their
    /// unsafe stale-address undo entries. Removed old ids lose undo entries and
    /// external mirrors. Shared by the whole-op success path and the narrowing
    /// pass so the dispositions cannot drift.
    ///
    /// ⚠️ THIS LEDE SAID "**two** … the in-memory undo stack and the FTS index"
    /// until R16-7 (corrected 2026-08-06), while the block 30 lines below it
    /// shouted that the manifest is *"THE **THIRD** STORE KEYED BY
    /// `messageHeader.id` OUTSIDE GRDB"* and the body has mirrored into it since
    /// R12-T7. A stale count in the lede is worse than no count: a reader
    /// enumerating out-of-GRDB stores stops at the first sentence that answers
    /// the question. Re-derive rather than trust — the predicate skips comments,
    /// so nothing here can satisfy it:
    ///   `rg -n --pcre2 '^(?!\s*(///|//)).*(UndoService\.shared\.applyRekeys|SearchIndex\.shared\.rekeyHeaders|BodyAssetStore\.rekeyContentKey)'
    ///    TabMail/Services/Account/AccountManagerQueue.swift` → **3**.
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
    ///
    /// 🚨 THE BODY-ASSET MANIFEST IS THE **THIRD** STORE KEYED BY
    /// `messageHeader.id` OUTSIDE GRDB, AND IT USED TO BE MISSING FROM HERE
    /// (R12-T7). `MessageHeaderRekey.apply`'s doc calls `bodyAsset`
    /// *"deliberately out of scope … swept by its own headerId-prefix
    /// maintenance path"*, and that was true while the drain never re-keyed —
    /// at `v1.6.38` the id stayed live, so `BodyAssetMaintenance.pruneOrphans`
    /// never saw the key as dead. It stopped being true the moment this
    /// function started finishing moves locally, because that sweep's ONLY
    /// recovery leg, `MessageContentStore.recoverMovedContentKey`, is gated on
    /// `provider == .gmail || .outlook` **and** matches on an **unchanged**
    /// `providerMessageId` — and `finishMove` re-keys precisely because the
    /// tail CHANGED. IMAP is excluded by the gate; Outlook passes the gate and
    /// misses the lookup. The sweep therefore reclassified a live message's
    /// cached inline images and attachments as orphans and deleted them, while
    /// the carried-over `messageBody` row at the NEW key still referenced them
    /// through `tabmail-asset://`, and `attachmentAssetId(contentKey:…)` — which
    /// looks up by `headerId` — could no longer find the bytes it had.
    ///
    /// ⚠ THIS IS A REGRESSION, NOT MERELY AN EDGE, which is why it is fixed
    /// rather than registered under THE MANTRA. It self-heals at
    /// `SyncConfig.bodyCacheTTLHours`, so it clears the recoverability test —
    /// but the path that reaches it is *archive or move a message you just
    /// read*, an ordinary primary path that `v1.6.38` handled correctly.
    ///
    /// ⚠ THE COLLISION SPLIT IS LOAD-BEARING HERE FOR A DIFFERENT REASON THAN
    /// IT IS FOR FTS. A collided re-key means a row ALREADY occupies the
    /// destination address; mirroring the re-key blindly would file two
    /// messages' attachments under one content key, and every later
    /// `attachmentAssetId` lookup at that key could return the OTHER message's
    /// bytes — a content misattribution, C3-adjacent. So the collided ids take
    /// `deleteAllAssets` exactly as they take `removeMessages` above: the
    /// destination row is the survivor and owns its own assets, and the loser's
    /// cache is re-downloadable. `rekeyContentKey` independently makes the same
    /// choice if it races (`newExists` ⇒ delete the old key), so the two agree.
    ///
    /// ⚠ COST (A6). This adds ONE bounded `UPDATE` per applied record on the
    /// manifest queue — the same cardinality IN ROWS as the FTS mirror
    /// immediately above, but NOT in transactions: `SearchIndex.rekeyHeaders`
    /// takes the whole array in ONE call, while this loop issues N separate
    /// cross-process `queue.write`s on the manifest pool. Batching it would need
    /// a manifest-side multi-key overload plus a per-key collision split, which
    /// is more mechanism than the cost justifies — N is bounded by one drained
    /// op's members and none of this is on the render path. The store's primary
    /// key is `id` and `headerId` is the column the sweep already scans, so each
    /// write is itself cheap. Both stores are separate SQLite pools;
    /// this one is synchronous because `BodyAssetStore` is a nonisolated `enum`
    /// serving the NSE and the main app identically. A missing App Group
    /// container makes `manifestQueue()` nil and every call a no-op returning 0,
    /// which is the correct fail-safe: no assets means nothing to orphan.
    func publishMoveFinish(_ result: MoveFinishResult) async {
        let applied = result.applied
        let removedOldHeaderIds = result.removedOldHeaderIds
        if !applied.isEmpty {
            queueLog("[MoveTrace] executeSingleOp — re-keyed \(applied.count) moved row(s) to their provider-proven destination address")
            // The undo stack names its members by the SAME primary key and UID
            // this re-key just changed, so it has to follow — otherwise
            // finishing the move would break undo rather than enable it.
            // An Undo already admitted to the local FIFO may still need to
            // cancel a deferred successor keyed by the predecessor's OLD
            // address. COPYUID publication happens outside that FIFO. Keep
            // only those in-progress members on the old key until their
            // already-queued cancellation runs; stacked actions and ordinary
            // in-progress Undo members still follow the provider rekey.
            let deferredCancellationIds = Set(deferredMoveSuccessors.keys)
            await UndoService.shared.applyRekeys(
                applied,
                preservingInProgressMemberIds: deferredCancellationIds)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .messageHeadersRekeyed,
                    object: applied)
            }
            // Persisted chat pills name messages by that same mutable primary key.
            // Keep their numeric identity stable across the move; otherwise a
            // cached discussion still renders its baked subject but tapping it
            // resolves the now-deleted source address and appears inert.
            for record in applied {
                _ = await ChatIdTranslator.shared.remapRealId(
                    from: record.oldHeaderId,
                    to: record.newHeaderId)
            }
            // The FTS index is a SEPARATE database, so its re-key is two-phase —
            // outside the GRDB write — exactly as the sync path does it. The
            // entry MOVES; it is never removed.
            try? await SearchIndex.shared.rekeyHeaders(applied.map {
                (oldKey: ContentKey(rawValue: $0.oldHeaderId),
                 newKey: ContentKey(rawValue: $0.newHeaderId),
                 newMessageId: $0.newProviderMessageId)
            })
            // The body-asset manifest keys by the same header id. See the
            // R12-T7 block above: `pruneOrphans`' recovery leg structurally
            // cannot see the id-CHANGING shape this function produces, so
            // without this the next sweep deletes a live message's cached
            // bodies and attachments.
            var rekeyedAssetKeys = 0
            for record in applied {
                if BodyAssetStore.rekeyContentKey(
                    from: ContentKey(rawValue: record.oldHeaderId),
                    to: ContentKey(rawValue: record.newHeaderId)) > 0 {
                    rekeyedAssetKeys += 1
                }
            }
            if rekeyedAssetKeys > 0 {
                queueLog("[MoveTrace] executeSingleOp — re-keyed \(rekeyedAssetKeys) moved row(s)' cached body assets")
            }
        }
        let unsafeUndoIds = result.unsafeUndoOldHeaderIds + removedOldHeaderIds
        if !unsafeUndoIds.isEmpty {
            await UndoService.shared.discardMembers(namedByOldHeaderIds: unsafeUndoIds)
        }
        if !removedOldHeaderIds.isEmpty {
            queueLog("[MoveTrace] executeSingleOp — dropped \(removedOldHeaderIds.count) external mirror(s) whose old header no longer exists")
            try? await SearchIndex.shared.removeMessages(
                contentKeys: removedOldHeaderIds.map { ContentKey(rawValue: $0) })
            // Same disposition for the assets, and for a stronger reason —
            // merging them onto the survivor's key would misattribute one
            // message's attachment bytes to another.
            for oldId in removedOldHeaderIds {
                _ = BodyAssetStore.deleteAllAssets(forContentKey: ContentKey(rawValue: oldId))
            }
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
    /// ⚠ AUDIT ROUND 4, CORRECTED (`IOS-GRAPH-002`). `IMAPProvider.move` is no
    /// longer a producer — it dispositions every member positively before
    /// returning (see `executeOperation`'s return-value note), so there is no
    /// undetermined remainder for this to narrow to on that arm, and the
    /// re-copy cost above cannot be incurred there. But this path is NOT
    /// producerless: `ExchangeProvider.moveProvingDestinations` returns the
    /// prefix it proved when a batch fails partway, so the members Graph
    /// already moved are retired and RE-KEYED to the ids its `/move` responses
    /// named, instead of having those addresses discarded with the error. The
    /// re-copy hazard described above does not arise on that arm either: the
    /// unproven remainder was never mutated, because each Graph move is its own
    /// request rather than one command over the whole set.
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
        addressChangesOnMove: Bool,
        context: DrainContext
    ) async {
        queueLog("[Queue] Partial \(currentOp.type.rawValue): provider proved \(provenMembers.count) of \(currentOp.messageIds.count) member(s) — retiring those and keeping \(remaining.count) queued")
        // Same TOCTOU ordering as the whole-op success path: the sync-protection
        // entry for a retired member is recorded BEFORE its id leaves the row.
        var completedIds: [String] = provenMembers
        if let infos = try? await dbPool.read({ db -> [(String?, String?)] in
            // Same set-based lookup as the whole-op success path; one entry per proven
            // member, in order, `nil` columns when no row resolves.
            let identities = try Self.headerIdentitiesForQueuedMembers(
                provenMembers, accountId: currentOp.accountId, db: db)
            return provenMembers.map { msgId in
                let header = identities[msgId]
                return (header?.rfc822MessageId, header?.messageId)
            }
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
            let finishResult = try await retryWrite(dbPool, label: "Queue") { db in
                let result = try MessageHeaderRekey.finishMove(
                    frozenRetiredOp,
                    destinations: provenDestinations,
                    addressChangesOnMove: addressChangesOnMove,
                    db: db)
                MessageHeaderRekey.publishAddressHandoffsAfterCommit(
                    result.applied, in: db)
                guard var fresh = try PendingOperation.fetchOne(db, key: currentOp.id) else {
                    return result
                }
                fresh.messageIds = remaining
                fresh.status = PendingStatus.queued.rawValue
                try fresh.save(db)
                return result
            }
            await publishMoveFinish(finishResult)
            await materializeDeferredMoveSuccessors(after: frozenRetiredOp, result: finishResult)
        } catch {
            // The narrowing write failed. NEVER leave the row `inFlight` (it
            // would only unstick at the next launch's crash recovery) and never
            // delete it: requeue the ORIGINAL bundle. A retry re-copies the
            // proven members — a duplicate at the destination, which this
            // codebase prefers over a dropped intention.
            // 🚨 UNGATED BY DECISION (rule 12's production-observability
            // exception). The requeued bundle re-copies members the provider
            // already proved, so this names a duplicate that WILL be created at
            // the destination, and a duplicate already made is not recovered by a
            // later sync.
            //
            // ⚠️ CORRECTED — the sibling CRITICAL above used to call itself "its
            // only witness" and this site inherited the claim. It is false in both
            // places: the requeue below leaves the `PendingOperation` row in place,
            // so the row is durable evidence of the bundle that will re-run. What
            // nothing durable records is the NARROWING FAILURE and the duplication
            // it implies — that is what the `logError` below writes, ungated and
            // file-backed, because on a device `stdout` is discarded (no
            // `freopen`/`dup2` exists in this tree).
            print("[Queue] CRITICAL: could not narrow partially-completed \(currentOp.id) after retries — requeuing the whole bundle (may duplicate already-moved members)")
            BackgroundSyncLogger.logError(
                "CRITICAL: could not narrow partially-completed \(currentOp.id) (type \(currentOp.type.rawValue)) after retries — requeuing the WHOLE bundle, so the \(provenMembers.count) member(s) the provider already proved will be re-applied and may duplicate at the destination: \(error)",
                source: "actionQueue")
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
            queueLog("[Gone] GRDB delete failed for \(headerId): \(error)")
            return
        }
        guard existed else { return }
        queueLog("[Gone] Deleted header \(headerId) — reason=\(reason)")
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
        // Log-only helper: gate the WHOLE body, not just the emission. Every
        // `queueLog` below is individually gated too, but this guard is what
        // skips the scoped DB read the dump exists to render — a read that in a
        // shipping build could only ever feed a log nobody can see. The caller's
        // `context.diagnosedOpIds` bookkeeping happens before this call, so
        // returning early changes no control flow there.
        guard DebugModeManager.isLoggingEnabled() else { return }
        let ageHours = Date().timeIntervalSince(op.createdAt) / 3600
        queueLog("[QueueDiag] === op=\(op.id) type=\(op.type.rawValue) ===")
        queueLog("[QueueDiag] op: accountId=\(op.accountId) folderPath=\(op.folderPath) destinationPath=\(op.destinationPath ?? "<nil>") tagValue=\(op.tagValue ?? "<nil>") userLabelId=\(op.userLabelId ?? "<nil>")")
        queueLog("[QueueDiag] op: messageIds=\(op.messageIds) retryCount=\(op.retryCount) uidResolutionRetryCount=\(op.uidResolutionRetryCount) status=\(op.status) ageHours=\(String(format: "%.2f", ageHours))")

        // Error structural unwrap — confirms whether classifiers should/shouldn't match
        queueLog("[QueueDiag] error.type=\(type(of: error)) error=\(error)")
        if case ProviderError.networkError(let underlying) = error {
            queueLog("[QueueDiag] underlying.type=\(type(of: underlying)) underlying=\(underlying)")
            if case HTTPError.networkError(let statusCode) = underlying {
                queueLog("[QueueDiag] HTTPError statusCode=\(statusCode)")
            }
            let ns = underlying as NSError
            queueLog("[QueueDiag] NSError domain=\(ns.domain) code=\(ns.code)")
        }
        queueLog("[QueueDiag] classifier: isMessageNotFoundError=\(isMessageNotFoundError(error)) isConfirmedGoneError=\(isConfirmedGoneError(error)) isPermanentlyInvalidError=\(isPermanentlyInvalidError(error))")

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
                        queueLog("[QueueDiag] MessageHeader: NONE for msgId=\(msgId) normalized=\(normalized) account=\(op.accountId)")
                    } else {
                        for h in headers {
                            queueLog("[QueueDiag] MessageHeader: id=\(h.id) folderId=\(h.folderId) folderPath=\(h.folderPath) messageId=\(h.messageId) rfc822=\(h.rfc822MessageId ?? "<nil>") isInInbox=\(h.isInInbox) isRead=\(h.isRead) actionTag=\(h.actionTag?.rawValue ?? "<nil>")")
                        }
                    }
                }

                let srcId = "\(op.accountId):\(op.folderPath)"
                if let src = try Folder.fetchOne(db, key: srcId) {
                    queueLog("[QueueDiag] Folder(source): id=\(src.id) name=\(src.name) path=\(src.path) role=\(src.role.rawValue)")
                } else {
                    queueLog("[QueueDiag] Folder(source): NONE for id=\(srcId)")
                }

                if let dest = op.destinationPath {
                    let destId = "\(op.accountId):\(dest)"
                    if let f = try Folder.fetchOne(db, key: destId) {
                        queueLog("[QueueDiag] Folder(destination): id=\(f.id) name=\(f.name) path=\(f.path) role=\(f.role.rawValue)")
                    } else {
                        queueLog("[QueueDiag] Folder(destination): NONE for id=\(destId)")
                    }
                }

                let trashFolders = try Folder
                    .filter(Column("accountId") == op.accountId && Column("role") == FolderRole.trash.rawValue)
                    .fetchAll(db)
                if trashFolders.isEmpty {
                    queueLog("[QueueDiag] Folder(role=trash): NONE for account=\(op.accountId)")
                } else {
                    for f in trashFolders {
                        queueLog("[QueueDiag] Folder(role=trash): id=\(f.id) name=\(f.name) path=\(f.path)")
                    }
                }
            }
        } catch {
            queueLog("[QueueDiag] ERROR: scoped DB read failed: \(error)")
        }
        queueLog("[QueueDiag] === end op=\(op.id) ===")
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
    /// ⚠ AUDIT ROUND 4 — `IMAPProvider.move` NEVER RETURNS A STRICT SUBSET, and
    /// that is a strengthening rather than a simplification. It used to: it
    /// returned the members the server's own `COPYUID` named, leaving members it
    /// did not name queued on the absence of evidence about them. It now
    /// determines EVERY member positively before returning — moved (COPYUID, or
    /// the COPY's tagged OK plus proof the member was in the source when that
    /// COPY ran), or no longer in the source folder at all, which is the
    /// provider saying there is nothing left to do. So no member is left
    /// undetermined for that arm to preserve.
    ///
    /// ⚠ CORRECTED (`IOS-GRAPH-002`) — this note used to end "NO PROVIDER
    /// CURRENTLY RETURNS A STRICT SUBSET", and the narrowing path was described
    /// as having no producer. `ExchangeProvider.moveProvingDestinations` IS one:
    /// a Graph move that fails partway through a batch returns the prefix it
    /// proved, because each of those members has already had its `id` churned
    /// and throwing the attempt away would discard the very addresses the wire
    /// just supplied. So the narrowing path is live, not merely contractual.
    func executeOperation(_ op: PendingOperation, provider: any EmailProvider) async throws -> ExecutedOperation {
        switch op.type {
        case .archive, .delete:
            // Legacy enum cases — all new ops use .move. No-op for any stale rows.
            return .allMembers
        case .move:
            guard let dest = op.destinationPath else {
                queueLog("[MoveTrace] ERROR: move op missing destinationPath")
                throw ProviderError.messageNotFound
            }
            // Self-move (source == dest) is a no-op — skip the provider call entirely.
            // This happens when archiving from All Mail on Gmail (source and dest both resolve
            // to __GMAIL_ALL_MAIL__). Treating as success lets the op be cleaned up normally.
            guard op.folderPath != dest else {
                queueLog("[MoveTrace] executeOperation.move — no-op (source==dest): \(op.folderPath)")
                return .allMembers
            }
            let opAgeMin = Date().timeIntervalSince(op.createdAt) / 60
            queueLog("[MoveTrace] executeOperation.move — msgIds=\(op.messageIds) from=\(op.folderPath) to=\(dest) provider=\(type(of: provider)) accountId=\(op.accountId) opId=\(op.id) retryCount=\(op.retryCount) ageMin=\(String(format: "%.1f", opAgeMin))")
            if let imap = provider as? IMAPProvider,
               let admitted = op.observedUidValidity,
               let admittedUInt = UInt32(exactly: admitted), admittedUInt > 0 {
                let outcome = try await imap.move(
                    ids: op.messageIds, from: op.folderPath, to: dest,
                    admittedUidValidity: admittedUInt)
                queueLog("[MoveTrace] executeOperation.move — completed for \(outcome.provenIds.count)/\(op.messageIds.count) member(s), \(outcome.provenDestinations.count) with a server-named destination address")
                return ExecutedOperation(
                    provenMembers: outcome.provenIds,
                    provenDestinations: outcome.provenDestinations,
                    addressChangesOnMove: true,
                    reconcileMoveSource: outcome.requiresSourceReconciliation)
            }
            // 🚨 THE SIBLING ARM THE `COPYUID` CENSUS NEVER REACHED
            // (`IOS-GRAPH-002`, `MIS-006` instance 5). Graph reallocates a
            // message's `id` on every folder move, and this arm used to drop
            // through to the `Void`-returning protocol call — so the address
            // the wire had just handed us was thrown away, the local row kept
            // an id the app itself had invalidated, and the user's NEXT gesture
            // on that message 404'd and had its `PendingOperation` deleted as
            // though the provider had said the work was done.
            //
            // NO EPOCH GUARD, deliberately and for the same reason
            // `.addUserLabel` has none: Graph ids are provider-stable resource
            // ids rather than numbers in a UIDVALIDITY space, so
            // `admittedOrdinaryActionTargets` records `nil` for Exchange and a
            // guard modelled on IMAP's would refuse every Outlook move forever.
            // What replaces it is that the address is re-learned from the
            // mutation's own response instead of being assumed to survive.
            if let exchange = provider as? ExchangeProvider {
                let outcome = try await exchange.moveProvingDestinations(
                    ids: op.messageIds, from: op.folderPath, to: dest)
                queueLog("[MoveTrace] executeOperation.move — completed for \(outcome.provenIds.count)/\(op.messageIds.count) member(s), \(outcome.provenDestinations.count) with a server-named destination address")
                return ExecutedOperation(
                    provenMembers: outcome.provenIds,
                    provenDestinations: outcome.provenDestinations,
                    addressChangesOnMove: true)
            }
            try await provider.move(ids: op.messageIds, from: op.folderPath, to: dest)
            queueLog("[MoveTrace] executeOperation.move — completed successfully")
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
            // 🚨 EVERY DISPOSITION THAT REACHES THIS LINE IS A RETIREMENT, so
            // `pushDraftToServer` must only RETURN for an outcome that is one of the
            // four exits. It returns `.completed` (exit 1) and `.notApplied` (exit 3
            // — a newer authored edit or generation replacement won the Stage A/B
            // CAS, so this producer is genuinely stale). A THROWN provider call is
            // none of them, and it now propagates from here into the classifier
            // below, which requeues the op — restoring shipped `07a4bb703`. It used
            // to be swallowed into a `.terminalUnconfirmed` return, which retired the
            // user's Save intention after one network failure (`IOS-DRAFT-015`).
            //
            // TWO MORE UNKNOWNS LEAVE THAT FUNCTION AS THROWS RATHER THAN
            // DISPOSITIONS, for this exact reason:
            //  - `DraftStore.PushClaimError.alreadyInFlight` — a push for the same
            //    draft is still live in this process (reachable because `withTimeout`
            //    ABANDONS its operation task, so a slow APPEND outlives the drain
            //    that started it). Lands in the generic transient arm below.
            //  - `ProviderError.actionIdentityResolutionFailed` — an unresolvable
            //    runtime kind. That one is TERMINAL here, deliberately and with its
            //    cost adjudicated at `IOS-QUEUE-003` item 4; read that arm's comment
            //    before changing either.
            // What is NO LONGER an unknown reaching this line: a `serverPushStatus
            // == "pushing"` row. It used to return `.notApplied` and be retired here;
            // `pushDraftToServer` now re-admits provably-orphaned residue itself
            // (`DraftStore.reAdmitOrphanedPushingDraft`).
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
            } else if let exchange = provider as? ExchangeProvider {
                // 🚨 CLOSES A LIVE NEVER-DROP VIOLATION. This arm used to be
                // `print("[Queue] addUserLabel not yet supported for Exchange")`
                // and then fall through to `return .allMembers` — the op was
                // RETIRED AS SUCCESSFUL having done nothing. That is not a
                // missing feature, it is exit-2 abuse: nothing provider-
                // authoritative said the work was done or inapplicable.
                //
                // `labelId` is `PendingOperation.userLabelId`, the BARE
                // `UserLabel.providerLabelId` (D10 / `IOS-LABEL-001`), which on
                // Outlook is the Graph category name verbatim.
                //
                // GMAIL'S SHAPE, NOT IMAP'S — deliberately no
                // `admittedUidValidity` guard. Graph ids are provider-stable
                // resource ids, not UIDs in a numbering space; Exchange has no
                // UIDVALIDITY, and `admittedOrdinaryActionTargets` records `nil`
                // for it, so requiring one here would refuse every Outlook label
                // op forever.
                try await exchange.setUserLabel(
                    messageId: msgId, category: labelId, add: true)
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
            } else if let exchange = provider as? ExchangeProvider {
                // See the identical comment in `.addUserLabel`, including why
                // this follows Gmail's shape rather than IMAP's and why the
                // `print`-and-retire it replaced was a never-drop violation.
                try await exchange.setUserLabel(
                    messageId: msgId, category: labelId, add: false)
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
    /// Ordinary operations return to queued. An attempted MOVE is deliberately
    /// dropped instead: after a process death we cannot know whether the server
    /// committed it, and resending can duplicate the move. The normal foreground
    /// sync that follows launch restores whichever state the server actually has.
    func reconcilePendingOperations() async {
        // Crash recovery MUST succeed — inFlight ops from the previous session are stuck
        // and will never drain unless reset to queued.
        try? await retryWrite(dbPool, label: "Queue") { db in
            let staleOps = try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchAll(db)
            if !staleOps.isEmpty {
                queueLog("[Queue] Crash recovery: reconciling \(staleOps.count) inFlight ops")
                for op in staleOps {
                    if op.type == .move, op.everAttempted {
                        _ = try PendingOperation.deleteOne(db, key: op.id)
                        queueLog(
                            "[Queue] Dropped interrupted MOVE \(op.id.prefix(8)) " +
                            "instead of risking a duplicate; foreground sync will reconcile")
                        continue
                    }
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
                queueLog("[Queue] Crash recovery: cleaned up \(cancelledCount) cancelled ops")
            }
            // Same crash-recovery class as the inFlight reset above, for the OTHER
            // in-flight state a previous session can leave behind: a draft push whose
            // Stage A durably committed `"pushing"` and then died before the provider
            // call returned. Left alone, `pushDraftToServer`'s `.notApplied` is a
            // NORMAL return, so the next drain retires the durable `.saveDraft`
            // producer through the generic success arm — a dropped intention by none
            // of the four exits.
            //
            // 🚨 CORRECTED 2026-08-06. This comment used to end: *"Launch-only is
            // what makes this safe without a drain latch: nothing has drained yet in
            // this process, so a `"pushing"` row is orphaned by definition."* The
            // first half is still exactly why THIS blind whole-table reset is safe
            // HERE. The second half was being read as a claim that `"pushing"` residue
            // can ONLY arise across a process boundary, and that is FALSE: an
            // in-process `restorePushableAfterProviderThrow` (or
            // `applyPushCompletion`) write that itself throws leaves the row
            // `"pushing"` while the process runs on, and the very next drain then
            // deleted the producer — before this launch entry ever ran again. That
            // hole is closed inside `pushDraftToServer` by a per-draft in-process
            // claim, not here. Full rationale, the mirror-image trap, and the residue
            // census are on `DraftStore.resetOrphanedPushingDrafts` and
            // `DraftStore.reAdmitOrphanedPushingDraft`.
            let reAdmittedPushes = try DraftStore.resetOrphanedPushingDrafts(db: db)
            if reAdmittedPushes > 0 {
                queueLog("[Queue] Crash recovery: re-admitted \(reAdmittedPushes) orphaned draft pushes")
            }
        }
        await drainPendingQueue()
        await reconcileOutbox()
        await reconcileCalendarQueue()
    }
}
