/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

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
    /// True ONLY when an IMAP MOVE ended with a tagged NO/BAD after the server
    /// had already reported a `COPYUID` for the members it moved — the
    /// evidence-bearing form of the failure. The original identifiers must not
    /// be retried, and both mailbox views must be refreshed before the user
    /// decides whether any remainder needs a new gesture. A tagged NO/BAD with
    /// NO `COPYUID` never sets this: it is a refusal with no evidence of
    /// mutation, so `IMAPProvider.move` raises it as a
    /// `ProviderEvidenceUnavailable` and the op stays queued and is retried
    /// (GitHub #115).
    ///
    /// ⚠ QUALIFIED (round 3b, owner decision D9 2026-09-05): "stays queued and
    /// is retried" is true only of refusals WITHOUT a permanent code. A refusal
    /// whose resp-text BEGINS with a complete code in
    /// `IMAPProvider.permanentMoveRefusalCodes` — `TRYCREATE`, `NOPERM`,
    /// `CANNOT`, `NONEXISTENT` — is instead RETIRED by `move` with zero
    /// mutation: `provenIds` = the input ids, `provenDestinations` empty, and
    /// `reconcileMoveSource` false, because nothing was copied and the message
    /// is untouched in the source mailbox on the server.
    let reconcileMoveSource: Bool
    /// The members the server AUTHORITATIVELY reported absent on their own exact
    /// addressed request (`ProviderMemberAbsence.isAuthoritative`) — the provider
    /// asked about THIS message and was told it is gone.
    ///
    /// They are DISPOSITIONED, not failed: there is nothing left to do to them, so
    /// they are part of a complete outcome and never hold the operation open. What
    /// this field adds is ATTRIBUTION — which member — which the `Void`-returning
    /// action protocol cannot express and which the drain needs for exactly one
    /// thing: deleting that member's confirmed-gone local header, the same
    /// disposition the single-message conflict arm has always applied.
    ///
    /// Before the batch-splitting arm was removed, a multi-member batch learned
    /// this by re-shaping itself into one row per member and letting each 404
    /// individually; the attribution now comes from the provider that issued the
    /// per-member request in the first place. Empty for every provider and op type
    /// that cannot produce it.
    let confirmedGoneMembers: [String]

    init(
        provenMembers: [String]?,
        provenDestinations: [ProvenDestinationAddress],
        addressChangesOnMove: Bool = false,
        reconcileMoveSource: Bool = false,
        confirmedGoneMembers: [String] = []
    ) {
        self.provenMembers = provenMembers
        self.provenDestinations = provenDestinations
        self.addressChangesOnMove = addressChangesOnMove
        self.reconcileMoveSource = reconcileMoveSource
        self.confirmedGoneMembers = confirmedGoneMembers
    }

    /// Every member dispositioned, nothing re-keyable.
    static let allMembers = ExecutedOperation(
        provenMembers: nil, provenDestinations: [], addressChangesOnMove: false)
}

/// Executes and settles one claimed action on AccountManager's existing isolation.
/// The manager owns this object; calls borrow the manager without retaining it.
final class AccountOperationExecutor {
    typealias DrainContext = AccountManager.DrainContext
    typealias SingleOpOutcome = AccountManager.SingleOpOutcome

    /// A retirement whose LOCAL write could not commit, kept exactly as the
    /// provider handed it to us so the next drain can replay it.
    ///
    /// The wire has already PROVEN the move — Graph answered `2xx` and named
    /// the destination id, or IMAP returned `COPYUID` — and the only thing that
    /// failed is a transaction. GRDB suspends writes when the app is
    /// backgrounded mid-drain while reads keep working (ADR-IOS-041), and a full
    /// disk or an I/O error at COMMIT does the same. Discarding the provider's
    /// own returned result there loses the address for every holder of the old
    /// one: the follower serialized behind the move in the same account-scoped
    /// lane runs next naming the id Graph has just invalidated, Graph answers
    /// `404`, and `executeSingleOp`'s single-message conflict arm reads that as
    /// provider-authoritative "already done" and DELETES the user's newer
    /// intention (`IOS-GRAPH-005`, owner decision 2026-09-05,
    /// `TabMail/tabmail-ios#120`).
    ///
    /// Each case captures EXACTLY the inputs its caller's retirement transaction
    /// needs and nothing else, so the replay runs the SAME helper the original
    /// site ran rather than a second copy of it that can drift.
    ///
    /// BOUNDED to one globally claimed operation whose retirement failed. The
    /// optional blocks the next claim until recovery and leaves on replay
    /// success, when the row is gone (a local wipe or reset removed it), or with
    /// the process. A process death before the replay is the accepted crash
    /// window, unchanged — see the acceptance beside
    /// `MessageHeaderRekey.readdressQueuedOperations`.
    enum RetainedSettlement: Sendable {
        /// `executeSingleOp`'s whole-op success path.
        case full(op: PendingOperation, executed: ExecutedOperation)
        /// `retirePartiallyCompletedOp`'s narrowing path.
        ///
        /// `confirmedGoneMembers` is the subset of `provenMembers` the provider
        /// reported ABSENT rather than mutated. It is carried here for the same
        /// reason `executed` is carried by `.full`: the replay runs the same
        /// local work the original site would have, and that work includes
        /// retiring those members' local headers.
        case partial(
            op: PendingOperation,
            provenMembers: [String],
            remaining: [String],
            provenDestinations: [ProvenDestinationAddress],
            addressChangesOnMove: Bool,
            confirmedGoneMembers: [String])
    }

    private var retainedSettlement: RetainedSettlement?
    var hasPendingSettlement: Bool { retainedSettlement != nil }

    func attempt(operationId: String, context: DrainContext,
                 using manager: isolated AccountManager) async -> SingleOpOutcome {
        do {
            guard let op = try await manager.liveOperation(operationId) else { return .proceed }
            guard let queue = manager.workQueues[op.accountId] else {
                await manager.requeueOrRetain(operationId)
                return .stopDrain
            }
            queueLog("[Queue] drain pos \(op.queuePosition) — executing \(op.id.prefix(8)) \(op.type.rawValue) \(op.folderPath)→\(op.destinationPath ?? "-") ids=[\(op.messageIds.joined(separator: ","))]")
            let outcome: SingleOpOutcome = try await queue.execute(priority: .userAction) {
                await manager.executeSingleOp(op, provider: queue.provider, context: context)
            }
            queueLog("[Queue] drain pos \(op.queuePosition) — executed \(op.id.prefix(8)) \(op.type.rawValue) \(op.folderPath)→\(op.destinationPath ?? "-") ids=[\(op.messageIds.joined(separator: ","))] outcome=\(outcome)")
            return outcome
        } catch {
            // Includes cancellation/invalidation before work begins and failed live reads.
            // A claim always remains durably queued or explicitly owned for recovery.
            await manager.requeueOrRetain(operationId)
            return .stopDrain
        }
    }

    func recoverPendingSettlement(context: DrainContext,
                                  using manager: isolated AccountManager) async -> Bool {
        guard let settlement = retainedSettlement else { return true }
        let op: PendingOperation
        switch settlement {
        case .full(let value, _): op = value
        case .partial(let value, _, _, _, _, _): op = value
        }
        do {
            guard try await manager.liveOperation(op.id) != nil else {
                retainedSettlement = nil
                queueLog("[Queue] retirement replay — row \(op.id.prefix(8)) no longer exists; a local wipe or reset removed it, so the retained proof is dropped")
                return true
            }
            let retired: PendingOperation
            let result: MoveFinishResult
            let gone: [String]
            let reconcileSource: Bool
            switch settlement {
            case .full(_, let executed):
                retired = op
                result = try await retryWrite(manager.dbPool, label: "Queue") { db in
                    try Self.commitFullRetirement(op, executed: executed, db: db)
                }
                gone = executed.confirmedGoneMembers
                reconcileSource = executed.reconcileMoveSource
            case .partial(_, let proven, let remaining, let destinations, let changesAddress, let confirmedGone):
                var subset = op
                subset.messageIds = proven
                retired = subset
                result = try await retryWrite(manager.dbPool, label: "Queue") { db in
                    try Self.commitPartialRetirement(retired, remaining: remaining,
                        provenDestinations: destinations, addressChangesOnMove: changesAddress, db: db)
                }
                gone = confirmedGone.filter(proven.contains)
                reconcileSource = false
            }
            retainedSettlement = nil
            queueLog("[Queue] retirement replay — committed retained settlement of \(op.id.prefix(8)) \(op.type.rawValue)")
            await publishCommittedEffects(retired, result: result, confirmedGoneMembers: gone,
                reconcileMoveSource: reconcileSource, context: context, using: manager)
            return true
        } catch {
            queueLog("[Queue] retirement replay — \(op.id.prefix(8)) still cannot commit: \(error); the provider's proven result is retained and this drain stops")
            return false
        }
    }

    /// The sole statement list for immediate and replayed full/partial commits.
    /// The recently-completed sync shield deliberately remains BEFORE the write.
    private func publishCommittedEffects(_ retired: PendingOperation, result: MoveFinishResult,
        confirmedGoneMembers: [String], reconcileMoveSource: Bool,
        context: DrainContext, using manager: isolated AccountManager) async {
        manager.logReaddressedFollowers(result, retiring: retired)
        await manager.publishMoveFinish(result)
        await manager.retireConfirmedGoneMemberHeaders(retired, memberIds: confirmedGoneMembers)
        await manager.materializeDeferredMoveSuccessors(after: retired, result: result)
        if [.archive, .delete, .move].contains(retired.type), let dest = retired.destinationPath {
            context.foldersToSync.insert("\(retired.accountId)|\(dest)")
            if reconcileMoveSource { context.foldersToSync.insert("\(retired.accountId)|\(retired.folderPath)") }
            if retired.type == .move, dest != retired.folderPath {
                await manager.recordMembersThatEnteredInbox(retired, destinationPath: dest, context: context)
            }
        }
        if [.saveDraft, .deleteDraft].contains(retired.type) {
            context.foldersToSync.insert("\(retired.accountId)|\(retired.folderPath)")
        }
    }

    func finishDrain(context: DrainContext, using manager: isolated AccountManager) async {
        // Post-drain: sync destination folders so new UIDs are picked up immediately.
        if !context.foldersToSync.isEmpty {
            queueLog("[MoveTrace] post-drain sync — syncing \(context.foldersToSync.count) destination folders: \(context.foldersToSync)")
            for key in context.foldersToSync {
                let parts = key.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let accountId = String(parts[0])
                let folderPath = String(parts[1])
                guard let queue = manager.workQueues[accountId] else { continue }
                guard let folder = try? await manager.dbPool.read({ db in
                    try Folder.filter(Column("accountId") == accountId && Column("path") == folderPath).fetchOne(db)
                }) else {
                    queueLog("[MoveTrace] post-drain sync — folder not found: \(accountId)|\(folderPath)")
                    continue
                }
                do {
                    try await queue.execute(priority: .userAction) {
                        try await manager.syncEngine.syncFolderMessages(folder: folder, provider: queue.provider)
                    }
                    queueLog("[MoveTrace] post-drain sync — completed for \(folder.name)")
                } catch {
                    queueLog("[MoveTrace] post-drain sync — failed for \(folder.name): \(error)")
                }
                // ADR-IOS-008 decision 3. Deliberately AFTER the sync attempt and
                // OUTSIDE its do/catch — see `enqueueAIForMembersThatEnteredInbox`
                // for why either branch is a safe place to resolve an id, and why
                // no earlier one is.
                await manager.enqueueAIForMembersThatEnteredInbox(key: key, folderPath: folderPath, context: context)
            }
        }
    }

    /// THE WHOLE-OP RETIREMENT TRANSACTION, as one value.
    ///
    /// Extracted from `executeSingleOp` verbatim so the REPLAY in
    /// `recoverPendingSettlement` runs the SAME write rather than a second copy
    /// that can drift away from it. Nothing about the transaction's content
    /// changed in the extraction: the classification is still read INSIDE the
    /// write, from the same `account` rows `drainPendingQueue` keyed the related
    /// chains from, because the two facts must not be allowed to drift — the
    /// address key promises a follower runs after this move, and `accountScopedIds` is
    /// what makes that promise safe by re-addressing it.
    ///
    /// 🚨 THE MOVE IS FINISHED LOCALLY HERE, IN THE SAME WRITE THAT DELETES THE
    /// OP. `optimisticMoveToFolder` left the row's primary key and `messageId`
    /// at their SOURCE values with a NIL epoch, so until it is re-keyed the row
    /// is refused by `admittedOrdinaryActionTargets` and the user's NEXT gesture
    /// on a just-moved message is a silent dead no-op. Re-keying it to the
    /// address the server itself named in `COPYUID` (already in hand — see
    /// `MessageHeaderRekey.finishMove` for the four guards) closes that, and
    /// makes undo-after-drain an ordinary reverse move.



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
    nonisolated static func isMessageNotFoundError(_ error: Error) -> Bool {
        if case ProviderError.messageNotFound = error { return true }
        if case ProviderError.networkError(let underlying) = error {
            if case HTTPError.networkError(let statusCode) = underlying, statusCode == 404 {
                return true
            }
            if (underlying as NSError).code == 404 { return true }
        }
        // 🚨 NO EVIDENCE-UNAVAILABLE ERROR MAY BE READ AS "ALREADY GONE" BY ITS
        // TEXT (GitHub #115). `ProviderEvidenceUnavailable` is the provider
        // contract for "we asked the server for a fact our safety gate needs and
        // did not get a usable one" — an ABSENCE of evidence, which is never
        // exit 2 and must reach the drain's own lane-local requeue arm. Several
        // of these errors carry the server's raw tagged response text as a
        // diagnostic payload, so the substring fallback below would otherwise
        // read a refusal that happens to quote an RFC 5530 `[NONEXISTENT]` code
        // (which names a missing MAILBOX, not a missing message) or the words
        // `UID not found` as a provider-authoritative disposition and delete the
        // op. Structural and keyed on the PROTOCOL, not on one transport
        // library's enum, so no response text and no future conformer can undo
        // it.
        if error is ProviderEvidenceUnavailable { return false }
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
    ///
    /// 🚨 THIS IS NOT THE PREDICATE THE PROVIDER LOOPS USE, AND IT MUST NOT BE
    /// UNIFIED WITH IT. `ProviderMemberAbsence.isAuthoritative` decides whether a
    /// PER-MEMBER provider answer retires that member; this decides whether a
    /// member the drain has ALREADY retired may also lose its local header. They
    /// look like the same question and are not, because they sit at different
    /// depths: this one is only ever consulted inside the single-message arm that
    /// `isMessageNotFoundError` has already admitted, so its extra `410` is
    /// unreachable there — `isMessageNotFoundError` accepts 404 only.
    ///
    /// A forwarding version of this function was written and REVERTED (2026-09-06,
    /// GPT consult finding 1). Forwarding is harmless in this direction but not in
    /// the other: the provider loops would have inherited the `410`, which no gate
    /// on the old path admitted, and a bare `410` — a status a message endpoint can
    /// return for meanings other than "this message no longer exists" — would have
    /// gone from "retry forever" to "retire the operation AND delete the header" as
    /// a side effect of sharing a helper. The member predicate is deliberately
    /// NARROWER than this one; that asymmetry is the safety, not an oversight.
    nonisolated static func isConfirmedGoneError(_ error: Error) -> Bool {
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
    /// this tree reaches the same end state by a shorter route — the generic arm
    /// itself runs `deferRelatedChainToTail`, so the retrying chain sits at the
    /// TAIL of the `queuePosition` order and nothing queues behind it. The cost
    /// of the honest classification is a retrying row rather than a silently
    /// discarded gesture, and that row costs no other intention anything.)
    ///
    /// The only shape that still retires is the one a provider can be held to:
    /// `HTTPError.networkErrorWithBody(400, body)` whose body decodes to Gmail's
    /// documented structured error object and names a deterministic rejection —
    /// see `GmailProvider.isAuthoritativeActionRejection`. That shape reaches
    /// here through `AuthedHTTP.requestPreservingBadRequestBody`, which action
    /// call sites opt into precisely so the body survives to be classified
    /// instead of being guessed at from the status line.
    nonisolated static func isPermanentlyInvalidError(_ error: Error) -> Bool {
        GmailProvider.isAuthoritativeActionRejection(error)
    }

    nonisolated static func commitFullRetirement(
        _ op: PendingOperation, executed: ExecutedOperation, db: Database
    ) throws -> MoveFinishResult {
        let accountScopedIds = try AccountManager
            .accountScopedIdAccountIds(db).contains(op.accountId)
        let result = try MessageHeaderRekey.finishMove(
            op,
            destinations: executed.provenDestinations,
            addressChangesOnMove: executed.addressChangesOnMove,
            accountScopedIds: accountScopedIds,
            db: db)
        MessageHeaderRekey.publishAddressHandoffsAfterCommit(result.applied, in: db)
        _ = try PendingOperation.deleteOne(db, key: op.id)
        return result
    }


    /// THE NARROWING TRANSACTION, as one value — the partial sibling of
    /// `commitFullRetirement`, extracted from `retirePartiallyCompletedOp` for
    /// the same reason and with the same content.
    ///
    /// `frozenRetiredOp` carries the PROVEN members only, so the re-key is
    /// scoped to them and an unproven member is never re-keyed. The durable row
    /// is then narrowed to `remaining` and made retryable, in this same write:
    /// a partial outcome — members removed while the header keeps its source
    /// address, or the reverse — would be a dropped intention or a row nothing
    /// can address (`IOS-QUEUE-005`).
    ///
    /// 🚨 THE NARROWED REMAINDER AND ITS POST-REKEY LIVE RELATED CHAIN GO TO THE
    /// TAIL, IN THIS SAME TRANSACTION. Spec §5's PR 2 sentence and the failure
    /// table's "only some members are settled" row both require it, and §6
    /// states the property it buys: *a partial Graph move must yield to
    /// unrelated work before its remainder is attempted again, with remainder
    /// and followers at the tail in order.* Every multi-member Gmail/Graph
    /// operation reaches this function on its FIRST attempt (one member per
    /// provider call, `MIS-IOS-022`), so without the move a ten-message gesture
    /// would hold the head of the queue for ten consecutive provider calls and
    /// an unrelated single-message action admitted behind it would wait for all
    /// of them.
    ///
    /// 🚨 THE CHAIN IS READ AFTER `finishMove`, WHICH IS WHAT "POST-REKEY"
    /// MEANS. `MessageHeaderRekey.readdressQueuedOperations` has already
    /// rewritten the followers' member ids to the addresses the provider named
    /// (ADR-IOS-081, `IOS-GRAPH-005`), so the connected component computed here
    /// groups by the addresses the NEXT attempt will use. Computing it from
    /// pre-call ids would group by an address the wire has already replaced and
    /// could leave a follower ahead of the predecessor it depends on.
    ///
    /// ⚠️ NO RETRY IS CHARGED. Narrowing is strict progress, not a failure: the
    /// provider settled a member and the row is smaller than it was. Charging
    /// here would make `retryCount` count successes.
    nonisolated static func commitPartialRetirement(
        _ frozenRetiredOp: PendingOperation,
        remaining: [String],
        provenDestinations: [ProvenDestinationAddress],
        addressChangesOnMove: Bool,
        db: Database
    ) throws -> MoveFinishResult {
        let accountScopedIdAccounts = try AccountManager.accountScopedIdAccountIds(db)
        let result = try MessageHeaderRekey.finishMove(
            frozenRetiredOp,
            destinations: provenDestinations,
            addressChangesOnMove: addressChangesOnMove,
            accountScopedIds: accountScopedIdAccounts.contains(frozenRetiredOp.accountId),
            db: db)
        MessageHeaderRekey.publishAddressHandoffsAfterCommit(result.applied, in: db)
        guard var fresh = try PendingOperation.fetchOne(db, key: frozenRetiredOp.id) else {
            return result
        }
        fresh.messageIds = remaining
        fresh.status = PendingStatus.queued.rawValue
        try fresh.update(db)
        let live = try PendingOperation
            .filter(Column("status") != PendingStatus.cancelled.rawValue)
            .order(Column("queuePosition").asc)
            .fetchAll(db)
        let chains = AccountManager.buildRelatedChains(live, accountScopedIdAccountIds: accountScopedIdAccounts)
        let chain = chains.first { $0.contains { $0.id == frozenRetiredOp.id } } ?? []
        try PendingOperation.appendToTail(db, ids: chain.map(\.id))
        return result
    }


    /// Execute a single claimed op against its provider. Updates shared DrainContext
    /// with results (failedAccounts, foldersToSync, recentActions, the per-drain
    /// deferred set). Returns the outcome (`.proceed` / `.deferred` / `.stopDrain`)
    /// so the global executor knows whether to keep claiming. `internal` (not
    /// `private`) so tests can call it directly against a `MockEmailProvider`.
    ///
    /// 🚨 EVERY ARM MUST MAKE THE QUEUE STRICTLY SMALLER OR DEFER A CHAIN. That is
    /// the executor's termination argument, and this function is where it is
    /// discharged: an arm either removes the row, narrows it by at least one
    /// member, adds its whole related chain to `context.deferredOperationIds`, or
    /// returns `.stopDrain`. An arm that returns `.proceed` without shrinking
    /// anything would spin the executor forever — the strict-progress guard on the
    /// narrowing path below exists for exactly that reason.
    ///
    /// 🚨 THE INVARIANT, STATED AS AN INVARIANT RATHER THAN AS A LIST OF ARMS:
    /// **NO ARM MAY RETURN `.proceed` UNLESS THE CLAIMED ROW IS PROVABLY GONE,
    /// PROVABLY NARROWED, OR PROVABLY OWNED BY `pendingRequeues` /
    /// `retainedSettlement`.** The claim transaction has already committed
    /// `inFlight` + `everAttempted`, and `claimFrontierOperation`'s
    /// protected-frontier law STOPS the walk at an `inFlight` row — so a
    /// `.proceed` on an iteration that changed nothing does not merely waste a
    /// pass: it wedges the drain at that row for EVERY account for the life of
    /// the process, every gesture is applied locally and acknowledged in the UI
    /// and never reaches the wire, and at the next launch
    /// `AppDatabase.recoverPreviousSessionResidue` deletes an `everAttempted`
    /// `.move` outright. That is the wedge corollary, and it terminates in a
    /// DROPPED INTENTION rather than a delay.
    ///
    /// The failure shape it rules out is `try? await retryWrite { … deleteOne }`
    /// followed by `return .proceed`: `retryWrite` is three attempts 100 ms apart,
    /// and GRDB write suspension on backgrounding (ADR-IOS-041), a data-protection
    /// lock and `SQLITE_FULL` all make all three throw while reads keep working.
    /// `try?` then discards the only evidence that nothing happened. Three arms
    /// did exactly that until 2026-09-06 (the single-message conflict, the
    /// permanently-invalid drop and the identity refusal); all three now use the
    /// `uidValidityChanged` arm's shape — a real `do`/`catch`, `requeueOrRetain`
    /// in the catch, `.stopDrain`. This is the same class the eight
    /// `try? … markQueued` requeue sites were fixed for one commit earlier
    /// (`288231f1b`); that census covered the REQUEUE writes and not the
    /// RETIREMENT writes, which is why it has to be stated as an invariant here
    /// rather than as a list of sites (`MIS-006`, `MIS-IOS-020`).
    ///
    /// CENSUS, STATED AS A FALSIFIABLE COUNT SO IT CAN BE CHECKED RATHER THAN
    /// TRUSTED. Before this change `grep -n '\.proceed'` over this file returned
    /// SEVEN sites: six `return .proceed` statements and the executor's
    /// outcome-box default (`drainPendingQueue`). Three of the six were provably
    /// resolved — whole-op success, `uidValidityChanged`, and
    /// `retirePartiallyCompletedOp`'s tail, each reached only after its
    /// retirement transaction COMMITTED. Three were the arms named above. The
    /// seventh, the outcome-box default, was fail-dangerous for the same reason
    /// (the closure can be skipped entirely) and is now `.stopDrain`. AFTER the
    /// change the same grep returns SIX, and every one of them is in the
    /// provably-resolved class. An eighth site, then or now, is a finding.
    func executeSingleOp(_ currentOp: PendingOperation, provider: any EmailProvider, context: DrainContext, using manager: isolated AccountManager) async -> SingleOpOutcome {
        let opType = currentOp.type.rawValue
        let opMsgCount = currentOp.messageIds.count

        do {
            let executed = try await withTimeout(
                seconds: SyncConfig.pendingOperationTimeoutSeconds
            ) { () -> ExecutedOperation in
                try await manager.executeOperation(currentOp, provider: provider)
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
                // 🚨 THE STRICT-PROGRESS GUARD, AND IT IS THE EXECUTOR'S TERMINATION
                // ARGUMENT FOR THIS ARM. A narrowing is reported as `.proceed`, which
                // means the executor comes straight back for the next member — sound
                // only while the membership actually SHRANK. A report that named no
                // member (`provenMembers` empty against a non-empty request) leaves
                // `remaining == messageIds`, and re-claiming that row would replay the
                // identical attempt forever, at wire speed, for as long as the app is
                // running. No provider produces that shape today — every per-member
                // loop settles exactly one member before reporting — but "no current
                // producer" is a property of three provider files, not of this
                // contract, so it is checked here rather than assumed. Without
                // progress the outcome is an ordinary retryable failure: defer the
                // chain to the tail and let unrelated mail through.
                guard remaining.count < currentOp.messageIds.count else {
                    queueLog(
                        "[Queue] \(opType) reported \(provenMembers.count) proven member(s) but "
                            + "narrowed nothing (\(remaining.count) of \(opMsgCount) still owed) — "
                            + "treating it as a retryable failure rather than re-claiming an "
                            + "identical attempt")
                    if !context.diagnosedOpIds.contains(currentOp.id) {
                        context.diagnosedOpIds.insert(currentOp.id)
                        await manager.logStuckOpDiagnostic(currentOp, error: ProviderError.messageNotFound)
                    }
                    guard await manager.deferRelatedChainToTail(
                        failing: currentOp, incrementRetryCount: true, context: context)
                    else { return .stopDrain }
                    return .deferred
                }
                return await retirePartiallyCompletedOp(
                    currentOp, provenMembers: provenMembers, remaining: remaining,
                    provenDestinations: executed.provenDestinations,
                    addressChangesOnMove: executed.addressChangesOnMove,
                    confirmedGoneMembers: executed.confirmedGoneMembers,
                    context: context, using: manager)
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
                    actionInfos = try await manager.dbPool.read { db -> [(String, String?, String?)] in
                        // Two set-based statements for the whole op, not one walk per
                        // member — see `headerIdentitiesForQueuedMembers`. One tuple per
                        // member, in member order, `nil` columns when no row resolves,
                        // exactly as the per-member `fetchOne` produced.
                        let identities = try AccountManager.headerIdentitiesForQueuedMembers(
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
            manager.recordRecentlyCompleted(messageIds: completedIds)

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
                finishResult = try await retryWrite(manager.dbPool, label: "Queue") { db in
                    try Self.commitFullRetirement(currentOp, executed: executed, db: db)
                }
            } catch {
                // 🚨 THE PROOF IS RETAINED, NOT DISCARDED. The provider already
                // completed this op and — for an address-changing move — already
                // told us where each member landed. The only thing that failed is
                // a local transaction, which GRDB's suspension (the app was
                // backgrounded mid-drain, ADR-IOS-041), a full disk, or an I/O
                // error at COMMIT all produce while the process keeps running and
                // reads keep working. Dropping `executed` here would leave every
                // holder of the old address behind: the follower serialized after
                // this move in the same account-scoped lane would name the id the
                // move just invalidated, the provider would answer 404, and the
                // single-message conflict arm below would delete the user's NEWER
                // intention. So the returned result is kept in memory and replayed
                // through the SAME transaction at the next drain
                // (`recoverPendingSettlement`), and THE WHOLE DRAIN STOPS so
                // nothing runs against an address that has not been committed
                // yet (owner decision 2026-09-05, `TabMail/tabmail-ios#120`,
                // `IOS-GRAPH-005`).
                //
                // ⚠️ IT IS A FULL STOP NOW, NOT A LANE HALT, AND THAT IS A
                // WIDENING ON PURPOSE. The write that failed is DATABASE-WIDE —
                // GRDB suspends writes on background entry (ADR-IOS-041), and a
                // full disk or an I/O error at COMMIT behaves the same — so the
                // next operation's retirement would fail identically, and it
                // would fail AFTER its own wire call had already mutated the
                // server. Continuing would convert one retained proof into a
                // growing set of them. The executor's first act on the next
                // drain is `recoverPendingSettlement`, so the stop is what
                // sequences the recovery.
                //
                // The row stays `inFlight`: the claim loop refuses `inFlight`, so
                // it cannot be handed to the provider a second time, and that is
                // what makes "exactly one wire operation per proven operation"
                // hold without any new guard. A process death before the replay is
                // the accepted crash window, unchanged.
                //
                // 🚨 UNGATED BY DECISION (rule 12's production-observability
                // exception). The user's queue is now holding a completed
                // operation that only this process can retire, and the two states
                // it can reach — replayed, or lost with the process — are not
                // distinguishable from anything durable. Gating this would hide it
                // behind a debug unlock the affected user does not have.
                //
                // ⚠️ CORRECTED — this line is NOT "its only witness". The DELETE is
                // what failed, so the `PendingOperation` row SURVIVES and is itself
                // durable evidence of the op. What nothing durable records is the
                // FAILURE, which is what the `logError` below writes. A bare
                // `print` could not have been the witness in any case: with no
                // `freopen`/`dup2` in this tree, `stdout` is discarded on device.
                retainedSettlement = .full(op: currentOp, executed: executed)
                print("[Queue] CRITICAL: Failed to retire completed PendingOperation \(currentOp.id) after retries — the row stays inFlight and the provider's proven result is retained for replay at the next drain")
                BackgroundSyncLogger.logError(
                    "CRITICAL: failed to retire completed PendingOperation \(currentOp.id) (type \(opType)) after retries — the row stays inFlight, so it will NOT re-execute, and the provider's proven result is retained in memory and replayed at the next drain; a process death before that replay is the accepted crash window (TabMail/tabmail-ios#120): \(error)",
                    source: "actionQueue")
                return .stopDrain
            }
            await publishCommittedEffects(
                currentOp, result: finishResult,
                confirmedGoneMembers: executed.confirmedGoneMembers,
                reconcileMoveSource: executed.reconcileMoveSource,
                context: context, using: manager)
            return .proceed
        } catch {
            // T2.7 checkpoint B refusal is typed and precedes the generic
            // message-not-found arm. The epoch scopes the whole
            // provider-address bundle, so no member may be dispositioned
            // separately under a different attempt.
            if case ProviderError.uidValidityChanged = error {
                do {
                    try await retryWrite(manager.dbPool, label: "Queue") { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                    manager.dropDeferredMoveSuccessors(for: currentOp.id)
                    return .proceed
                } catch {
                    // The provider wrote nothing. If retiring the refused op
                    // fails, preserve the exact original bundle for retry.
                    //
                    // ⚠️ `.stopDrain`, not a deferral. The failure is the DELETE,
                    // i.e. a database-wide write refusal, and the deferral path
                    // is itself a write — it would fail in the same breath and
                    // leave the executor claiming the same protected frontier
                    // row forever. Stopping lets the next drain retry from a
                    // clean state.
                    await manager.requeueOrRetain(currentOp.id)
                    return .stopDrain
                }
            }
            if Self.isMessageNotFoundError(error) {
                // 🚨 A MULTI-MEMBER NOT-FOUND IS UNRESOLVED, AND THE TERMINAL
                // ARM BELOW IS STRICTLY SINGLE-MESSAGE.
                //
                // This used to be the batch-splitting arm: it constructed one
                // replacement `PendingOperation` per member, inserted them all and
                // deleted the parent, so that each member could be re-addressed
                // individually and succeed or fail on its own. It is DELETED, and
                // nothing replaces it in the scheduler.
                //
                // The reason the split existed at all is that a batch error does
                // not name a member: `messages.modify` on three ids answers `404`
                // for the batch, and re-addressing each id separately was the only
                // way to learn WHICH one is gone. That discovery belongs at the
                // provider/action-adapter boundary, which issues the per-member
                // request and can therefore attribute the answer — see
                // `executeOperation`'s `ProviderMembersDispositioned` conversion. The
                // scheduler only ever sees a complete outcome, an unresolved one,
                // or an already-authorized terminal exit, and never re-shapes the
                // user's intention into different rows to find out which it is.
                //
                // 🚨 THE ONE THING THAT MUST NOT HAPPEN HERE is falling through
                // into the single-message arm below, which DELETES the row. That
                // arm is authorized by exit 2 — the provider told us this exact
                // addressed message is gone — and with more than one member NOTHING
                // told us that about any particular member. The batch error is an
                // ABSENCE of per-member evidence, which is never authoritative
                // (`MIS-IOS-004`), and it includes every hit of
                // `isMessageNotFoundError`'s substring fallback (`NONEXISTENT`,
                // `UID not found`) — RFC 5530's `[NONEXISTENT]` names a missing
                // MAILBOX, not a missing message, and a rendered IMAP failure that
                // merely quotes those words has dispositioned no member at all.
                //
                // ⚠️ IT IS NOT WHAT PROTECTS THE POSITIONAL DRAFT PAYLOADS —
                // this paragraph used to claim it was. The hazard was real: a
                // `.deleteDraft` op's `messageIds` are an ADDRESS and an IDENTITY
                // of ONE draft, not two mail members; the split arm treated them
                // as members, and the identity-only child it produced resolved by
                // Message-ID `SEARCH`, which is a wrong-message delete built out
                // of a refusal (see the `actionIdentityResolutionFailed` arm's ⚑
                // NEVER SPLIT THIS ONE note, which described this exact hazard
                // while the arm that could still reach it sat above). What removes
                // that reach is DELETING the split arm, not the `count > 1` test
                // below, which `.deleteDraft` cannot reach in the first place: its
                // only producer — the draft-delete gesture in
                // `AccountManagerActions` — inserts `messageIds: [encodedId]`, one
                // element, so a `.deleteDraft` row is always single-member. The
                // test below is about mail members; the draft payload is safe
                // because nothing splits it any more.
                //
                // The disposition is the retryable one, and it is deliberately NOT
                // the generic transient arm at the bottom of this `catch`: a
                // not-found says nothing about the CONNECTION, so the account must
                // not enter `failedAccounts` and stop every other account's mail.
                // The op's whole related chain moves to the TAIL and is marked
                // deferred, so it is attempted at most once per drain and every
                // unrelated intention behind it executes in the same run.
                if currentOp.messageIds.count > 1 {
                    let ageHours = Date().timeIntervalSince(currentOp.createdAt) / 3600
                    queueLog("[Queue] Unresolved multi-member \(opType) (\(opMsgCount) msgs): \(error) (age \(String(format: "%.1f", ageHours))h) — no member was individually dispositioned, so the op keeps its id and moves to the tail with its related chain; unrelated mail keeps draining")
                    if !context.diagnosedOpIds.contains(currentOp.id) {
                        context.diagnosedOpIds.insert(currentOp.id)
                        await manager.logStuckOpDiagnostic(currentOp, error: error)
                    }
                    guard await manager.deferRelatedChainToTail(
                        failing: currentOp, incrementRetryCount: true, context: context)
                    else { return .stopDrain }
                    return .deferred
                }
                // Single-message conflict — drop (server wins)
                queueLog("[Queue] Conflict: \(opType) — message not found, dropping")
                do {
                    try await retryWrite(manager.dbPool, label: "Queue") { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                } catch {
                    // ⚠️ `.stopDrain`, not `.proceed` — the SAME shape as the
                    // `uidValidityChanged` arm above, for the same reason. The
                    // DELETE is what failed, so the row is still `inFlight` with
                    // every member it had, this iteration changed NOTHING, and
                    // `.proceed` would send the executor back to a frontier that
                    // `claimFrontierOperation`'s protected-frontier law refuses —
                    // `.stop` at that row on every later drain, for every account,
                    // for the life of the process. That is the wedge corollary:
                    // every gesture is applied locally and acknowledged in the UI
                    // and none of them ever reaches the wire again.
                    // `requeueOrRetain` returns the row to `queued`, or keeps
                    // ownership in `pendingRequeues` so `recoverPendingRequeues`
                    // finishes it at the top of the next drain.
                    queueLog(
                        "[Queue] Conflict retirement of \(currentOp.id.prefix(8)) (\(opType)) "
                            + "could not commit: \(error); the row is returned to `queued` and "
                            + "this drain stops rather than reporting progress it did not make")
                    await manager.requeueOrRetain(currentOp.id)
                    return .stopDrain
                }
                // 🚨 INSIDE THE SUCCESS BRANCH, DELIBERATELY. This discards the
                // in-memory successor an undo already gestured (and releases its
                // overlay entry); doing that for an operation that is still LIVE
                // would drop a user intention whose predecessor has not retired.
                manager.dropDeferredMoveSuccessors(for: currentOp.id)
                // If the error was a structurally-confirmed permanent gone (HTTP 404/410
                // or ProviderError.messageNotFound), also delete the local header. The
                // message is verified gone on the server; retaining a ghost row causes
                // other queues (body fetch, AI) to retry forever.
                // We deliberately DO NOT delete on the string-matching branch of
                // isMessageNotFoundError — too risky for false positives.
                if Self.isConfirmedGoneError(error), let msgId = currentOp.messageIds.first {
                    // Scope delete to the exact (account, folder, messageId) row — broader
                    // matches risk deleting unrelated messages that happen to share a UID
                    // in a different IMAP folder.
                    let hid = MessageIdentity.headerId(accountId: currentOp.accountId, folderPath: currentOp.folderPath, messageId: msgId)
                    await manager.deleteConfirmedGoneHeader(headerId: hid, reason: "\(opType) 404")
                }
                return .proceed
            }
            // Permanently invalid operation — drop immediately (will never succeed on retry).
            // E.g., Gmail "Invalid label: DRAFT" when a .move op tried to remove the DRAFT label.
            if Self.isPermanentlyInvalidError(error) {
                queueLog("[Queue] Permanently invalid \(opType): \(error) — dropping")
                do {
                    try await retryWrite(manager.dbPool, label: "Queue") { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                } catch {
                    // Same invariant as the conflict arm above: a `.proceed` here
                    // would claim the frontier is resolved while the row is still
                    // `inFlight` with all of its members, and the protected-frontier
                    // law would then stop every drain at it forever.
                    queueLog(
                        "[Queue] Permanently-invalid retirement of \(currentOp.id.prefix(8)) "
                            + "(\(opType)) could not commit: \(error); the row is returned to "
                            + "`queued` and this drain stops")
                    await manager.requeueOrRetain(currentOp.id)
                    return .stopDrain
                }
                manager.dropDeferredMoveSuccessors(for: currentOp.id)
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
                // Retrying cannot change it, so it ends here — but LOUDLY and
                // immediately, not after three fake retries dressed up as a staleness
                // confirmation. Nothing is destroyed:
                // the server-side object this op named is still there, still visible
                // after the next sync, and the user's re-issued gesture goes through the
                // UI paths that carry a full identity (`InboxViewModel.deleteDraftMessage`,
                // `ComposeView`'s discard/send paths). ⚑ `v2final` demotes this case to
                // its queue tail instead of dropping it, via
                // `ProviderError.persistentActionFailure`.
                // ⚠️ THE "MACHINERY THIS TREE DOES NOT HAVE (F2b L4)" CLAUSE THAT
                // STOOD HERE IS NOW FALSE. The global single-operation FIFO executor
                // gave this tree tail demotion (`deferRelatedChainToTail` →
                // `PendingOperation.appendToTail`), and every retryable arm above uses
                // it. So the drop is no longer forced by a missing mechanism, and it is
                // NOT re-justified by one here. It is retained UNCHANGED and
                // DELIBERATELY, because switching it is a product-behaviour change to a
                // recorded, owner-accepted limitation (`KNOWN_ISSUES.md`
                // `IOS-QUEUE-003` item 4) and not this change's business: a refused
                // identity "never will be" verifiable, so demoting it substitutes an
                // unbounded, forever-retrying row for an accepted bounded-and-VISIBLE
                // loss. Which of those the product wants is the owner's call. Whoever
                // asks the question next: the mechanism is available now, the argument
                // is not. ⚠️ This read *"the disposition v3
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
                do {
                    try await retryWrite(manager.dbPool, label: "Queue") { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                } catch {
                    // The accepted limitation is a drop that COMMITTED. A DELETE
                    // that did not commit has dropped nothing and resolved
                    // nothing: the row is still `inFlight` with its whole payload,
                    // so reporting `.proceed` would wedge the frontier for every
                    // account instead of discharging `IOS-QUEUE-003` item 4.
                    // Requeue and stop; the next drain re-reaches this arm and the
                    // logged terminal drop above is re-emitted when it commits.
                    queueLog(
                        "[Queue] Identity-refusal drop of \(currentOp.id.prefix(8)) (\(opType)) "
                            + "could not commit: \(error); the row is returned to `queued` and "
                            + "this drain stops — the drop is retried at the next drain")
                    await manager.requeueOrRetain(currentOp.id)
                    return .stopDrain
                }
                manager.dropDeferredMoveSuccessors(for: currentOp.id)
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
            // THREE properties, each load-bearing, now discharged by ONE call:
            //  - THE WHOLE RELATED CHAIN MOVES, not just this row. Every op that
            //    names a message this one names is in its `buildRelatedChains` connected
            //    component BY CONSTRUCTION, so running one ahead of an unresolved
            //    predecessor races its eventual retry on the wire. Tail movement
            //    keeps their relative order and puts all of them behind every
            //    unrelated intention, which is the ordering guarantee the old
            //    `.haltLane` bought — except that a lane halt also stopped the
            //    unrelated ops that shared a LANE only through this one, and this
            //    does not.
            //  - `deferredOperationIds`, so this op is attempted AT MOST ONCE per
            //    drain. Required, not defensive: the executor keeps claiming while
            //    a live front row exists, so without the deferred set it would walk
            //    the queue, come back round to this row at the tail, and retry it
            //    at wire speed. The refusal that made that costly —
            //    `IMAPProvider.move`'s withheld-`COPYUID` gate, raised AFTER the
            //    `UID COPY` so each re-attempt seated ANOTHER unproven duplicate at
            //    the destination — was deleted in audit round 4, but the property
            //    is a contract of this arm and not a patch for one error case, so
            //    it stays.
            //  - THE ACCOUNT IS NOT MARKED FAILED. Nothing was determined about the
            //    connection, so every other operation on this account still runs in
            //    this same drain.
            if error is ProviderEvidenceUnavailable {
                let ageHours = Date().timeIntervalSince(currentOp.createdAt) / 3600
                queueLog("[Queue] Evidence unavailable for \(opType) (\(opMsgCount) msgs): \(error) (age \(String(format: "%.1f", ageHours))h) — op and its related chain move to the tail, retry next drain; the rest of this account keeps draining")
                if !context.diagnosedOpIds.contains(currentOp.id) {
                    context.diagnosedOpIds.insert(currentOp.id)
                    await manager.logStuckOpDiagnostic(currentOp, error: error)
                }
                guard await manager.deferRelatedChainToTail(
                    failing: currentOp, incrementRetryCount: true, context: context)
                else { return .stopDrain }
                return .deferred
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
                await manager.logStuckOpDiagnostic(currentOp, error: error)
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
                let destMissing: Bool = (try? await manager.dbPool.read { db in
                    try Folder.fetchOne(db, key: "\(currentOp.accountId):\(destPath)") == nil
                }) ?? false
                if destMissing {
                    print("[Queue] \(opType) destination Folder missing locally: \(currentOp.accountId):\(destPath) — op stays queued (local absence is not provider authority)")
                }
            }
            // Bump retryCount on each failure so the value matches reality (and
            // is visible in [QueueDiag] dumps). Previously this stayed at 0
            // forever, masking the runaway-retry case where we observed
            // `retryCount=0 ageHours=217` on the same op.
            //
            // 🚨 THE CHAIN MOVES TO THE TAIL EVEN THOUGH THE ACCOUNT IS ALREADY
            // MARKED FAILED, and the redundancy is deliberate. `failedAccounts`
            // is per-drain and this row's position is DURABLE, so without the
            // move a connection blip would leave a whole gesture parked at the
            // head of the queue and the NEXT drain would open by re-attempting
            // it before any newer intention. The deferred set additionally stops
            // this drain re-claiming it after the account recovers.
            guard await manager.deferRelatedChainToTail(
                failing: currentOp, incrementRetryCount: true, context: context)
            else {
                context.failedAccounts.insert(currentOp.accountId)
                return .stopDrain
            }
            context.failedAccounts.insert(currentOp.accountId)
            return .deferred
        }
    }

    @discardableResult

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
    /// of this path: a narrowing is STRICT PROGRESS, so it does NOT enter the
    /// drain's deferred set and the executor re-claims the narrowed row later in
    /// the SAME continuous run — after the unrelated work it was just moved
    /// behind. The narrowed members can therefore be re-copied once per pass
    /// through the queue, and again on every later drain until the server proves
    /// or denies them. Duplicated mail is recoverable; a dropped intention is
    /// not. The termination argument is the strict shrink itself: `messageIds`
    /// loses at least one member on every visit (`executeSingleOp`'s
    /// strict-progress guard enforces it), so the row cannot be revisited more
    /// times than it has members.
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
    /// 🚨 THIS IS NOW THE PRIMARY PRODUCTION PATH FOR EVERY MULTI-MEMBER
    /// GMAIL AND GRAPH OPERATION — it is no longer test-only, and the sentence
    /// that used to stand here ("no production provider returns a strict subset,
    /// so a test IS this path's only reachability") is FALSE as of the change
    /// that moved per-member absence to the provider boundary. `modifyEachMessage`
    /// (Gmail) and `patchEachMessage` (Exchange) address exactly ONE id per
    /// attempt and then throw `ProviderMembersDispositioned(dispositionedMemberIds:
    /// [id], …)` whenever `ids.count != 1`; `executeOperation` converts that
    /// report into `provenMembers == [id]`, so `executeSingleOp`'s
    /// `Set(provenMembers) != Set(currentOp.messageIds)` test is TRUE on the very
    /// first attempt of every `.markRead` / `.markUnread` / `.markFlagged` /
    /// `.markUnflagged` / `.move` naming two or more members on those providers.
    /// `ExchangeProvider.moveProvingDestinations` is the third producer, and
    /// `IMAPProvider.move` is still not one (it dispositions every member at all
    /// of its return sites). Anything reasoned about downstream of this function
    /// — the re-key, the confirmed-gone header cleanup, the deferred-successor
    /// materialization — must therefore be scoped as ORDINARY multi-member
    /// traffic, not as a contingency.
    ///
    /// 🚨 THE THROUGHPUT PROPERTY LIVES HERE, AND IT IS WHY THIS ARM RETURNS
    /// `.proceed` RATHER THAN `.deferred`. Under the lane drain this arm halted
    /// its lane and relied on the outer loop's next pass to re-claim the narrowed
    /// row, so at most THREE members of one operation settled per drain and a
    /// ten-message gesture needed four drains — waiting on a gesture, a
    /// reconnect or the five-minute poll between each, i.e. 15–20 minutes on an
    /// idle device, well past the convergence window the owner set. The global
    /// executor keeps claiming while a live front row exists, and a narrowing is
    /// strict progress rather than a deferral, so the SAME continuous run comes
    /// back to the narrowed row once the work it yielded to is done. An N-member
    /// operation settles in ONE run, each member under its own fresh
    /// `SyncConfig.pendingOperationTimeoutSeconds`.
    ///
    /// ⚠️ IT STILL YIELDS FIRST. `commitPartialRetirement` moves the narrowed
    /// remainder and its live related chain to the TAIL in the retirement
    /// transaction, so unrelated mail admitted behind a ten-message gesture is
    /// not stuck behind ten provider calls (spec §6). Yielding and settling in
    /// one run are not in tension: the tail is still inside this drain.
    ///
    /// ⚠️ DEVIATION FROM SPEC §5, DELIBERATE AND REPORTED. The spec's
    /// failure table also says to "mark the chain deferred for this drain" on a
    /// partial completion. That would bound this path to ONE member per DRAIN —
    /// ten drains for a ten-message gesture, strictly worse than the three-per-
    /// drain shape it replaces — and directly contradicts the throughput
    /// requirement the same document sets. The spin guard exists so that FAILURE
    /// ALONE cannot create a self-rescheduling hot loop; a narrowing is not
    /// failure, and its loop is bounded by the membership it strictly shrinks.
    /// A "partial" that narrows NOTHING is not progress and does not come here:
    /// `executeSingleOp`'s strict-progress guard routes it to the ordinary
    /// retryable-failure disposition, which does defer.
    ///
    /// `internal` (not `private`) so tests can drive it directly, the same
    /// reason `executeSingleOp` and `DrainContext` are — but that is now a
    /// convenience for pinning shapes the wire reaches only rarely (an IMAP
    /// narrowing), not this path's only reachability.
    func retirePartiallyCompletedOp(
        _ currentOp: PendingOperation,
        provenMembers: [String],
        remaining: [String],
        provenDestinations: [ProvenDestinationAddress],
        addressChangesOnMove: Bool,
        confirmedGoneMembers: [String] = [],
        context: DrainContext,
        using manager: isolated AccountManager
    ) async -> SingleOpOutcome {
        queueLog("[Queue] Partial \(currentOp.type.rawValue): provider proved \(provenMembers.count) of \(currentOp.messageIds.count) member(s) — retiring those and keeping \(remaining.count) queued")
        // Same TOCTOU ordering as the whole-op success path: the sync-protection
        // entry for a retired member is recorded BEFORE its id leaves the row.
        var completedIds: [String] = provenMembers
        if let infos = try? await manager.dbPool.read({ db -> [(String?, String?)] in
            // Same set-based lookup as the whole-op success path; one entry per proven
            // member, in order, `nil` columns when no row resolves.
            let identities = try AccountManager.headerIdentitiesForQueuedMembers(
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
        manager.recordRecentlyCompleted(messageIds: completedIds)

        // The retired members only — an unproven member has no server-named
        // destination and must keep its source address.
        let frozenRetiredOp: PendingOperation = {
            var op = currentOp
            op.messageIds = provenMembers
            return op
        }()
        do {
            let finishResult = try await retryWrite(manager.dbPool, label: "Queue") { db in
                try Self.commitPartialRetirement(
                    frozenRetiredOp, remaining: remaining,
                    provenDestinations: provenDestinations,
                    addressChangesOnMove: addressChangesOnMove, db: db)
            }
            await publishCommittedEffects(
                frozenRetiredOp, result: finishResult,
                confirmedGoneMembers: confirmedGoneMembers.filter(provenMembers.contains),
                reconcileMoveSource: false, context: context, using: manager)
        } catch {
            // 🚨 THE PROVEN PREFIX IS RETAINED, NOT HANDED BACK TO THE WIRE. This
            // used to requeue the ORIGINAL bundle, accepting a duplicate at the
            // destination in exchange for never losing a member. That trade also
            // discarded the destination addresses the provider had ALREADY named
            // for the proven prefix — and on an account-scoped provider those are
            // the queued followers' addresses too, so the next pass sent the
            // follower to an id Graph had reallocated, where the single-message
            // conflict arm deletes it.
            //
            // The row is left exactly as the provider left it — `inFlight`, with
            // ALL of its members, no retry charged — so nothing can claim it and
            // re-copy the proven prefix, and the narrowing is replayed from the
            // retained result at the next drain (`recoverPendingSettlement`,
            // owner decision 2026-09-05, `TabMail/tabmail-ios#120`). A process
            // death before that replay is the accepted crash window, unchanged.
            //
            // 🚨 UNGATED BY DECISION (rule 12's production-observability
            // exception). A partially-completed bundle that only this process can
            // narrow is a state nothing durable distinguishes from an ordinary
            // in-flight one.
            //
            // ⚠️ CORRECTED — the sibling CRITICAL above used to call itself "its
            // only witness" and this site inherited the claim. It is false in both
            // places: the `PendingOperation` row stays in place, so the row is
            // durable evidence of the bundle. What nothing durable records is the
            // NARROWING FAILURE — that is what the `logError` below writes,
            // ungated and file-backed, because on a device `stdout` is discarded
            // (no `freopen`/`dup2` exists in this tree).
            retainedSettlement = .partial(
                op: currentOp, provenMembers: provenMembers, remaining: remaining,
                provenDestinations: provenDestinations,
                addressChangesOnMove: addressChangesOnMove,
                confirmedGoneMembers: confirmedGoneMembers.filter(provenMembers.contains))
            print("[Queue] CRITICAL: could not narrow partially-completed \(currentOp.id) after retries — the row stays inFlight with all members and the proven prefix is retained for replay at the next drain")
            BackgroundSyncLogger.logError(
                "CRITICAL: could not narrow partially-completed \(currentOp.id) (type \(currentOp.type.rawValue)) after retries — the row stays inFlight with all \(currentOp.messageIds.count) member(s), so nothing re-applies the \(provenMembers.count) member(s) the provider already proved, and the narrowing is retained in memory and replayed at the next drain; a process death before that replay is the accepted crash window (TabMail/tabmail-ios#120): \(error)",
                source: "actionQueue")
            if [.archive, .delete, .move].contains(currentOp.type),
               let dest = currentOp.destinationPath {
                context.foldersToSync.insert("\(currentOp.accountId)|\(dest)")
            }
            // 🚨 `.stopDrain`, matching the whole-op retention arm. The row is
            // left `inFlight` holding a proof only this process can commit, and
            // the write that failed is database-wide, so the next operation's
            // retirement would fail the same way — after its own wire call had
            // already mutated the server. The next drain opens with
            // `recoverPendingSettlement`, which is the recovery this stop
            // sequences.
            return .stopDrain
        }
        return .proceed
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
    /// a Graph move attempt settles one native member and carries the address
    /// returned by that move. The rest remain owed under the same durable row;
    /// discarding the outcome would lose the address the wire supplied.
    func executeOperation(_ op: PendingOperation, provider: any EmailProvider, using manager: isolated AccountManager) async throws -> ExecutedOperation {
        let source = ProviderMessageSource(memberIds: op.messageIds, folderPath: op.folderPath,
                                           admittedUidValidity: op.observedUidValidity)
        let action: ProviderMessageAction
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
            action = .move(destination: dest)
        case .markRead:
            action = .read(true)
        case .markUnread:
            action = .read(false)
        case .markFlagged:
            action = .flagged(true)
        case .markUnflagged:
            action = .flagged(false)
        case .setTag, .removeTag:
            // Action tags are local-only; their state was applied at admission.
            return .allMembers
        case .markReplied:
            action = .replied
        case .markForwarded:
            action = .forwarded
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
                runtimeKind: AccountManager.draftRuntimeIdentityKind(for: provider),
                draftsFolderPath: op.folderPath
            )
            if DebugModeManager.isLoggingEnabled() {
                print("[DraftQueue] Retiring save producer \(op.id) with disposition \(disposition)")
            }
            return .allMembers
        case .deleteDraft:
            guard let encodedId = op.messageIds.first else { return .allMembers }
            let runtimeKind = AccountManager.draftRuntimeIdentityKind(for: provider)
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
            return .allMembers
        case .addUserLabel, .removeUserLabel:
            guard let labelId = op.userLabelId, !op.messageIds.isEmpty else { return .allMembers }
            action = .userLabel(id: labelId, add: op.type == .addUserLabel)
        }
        let outcome = try await provider.performMessageAction(action, at: source)
        queueLog("[Queue] \(op.type.rawValue) (\(op.messageIds.count) msgs): provider settled \(outcome.dispositionedMemberIds.count) member(s), \(outcome.confirmedGoneMemberIds.count) confirmed gone, \(outcome.provenDestinations.count) server-named destinations")
        return ExecutedOperation(
            provenMembers: outcome.dispositionedMemberIds,
            provenDestinations: outcome.provenDestinations,
            addressChangesOnMove: outcome.addressChangesOnMove,
            reconcileMoveSource: outcome.requiresSourceReconciliation,
            confirmedGoneMembers: outcome.confirmedGoneMemberIds)
    }
}

// Sendable work/timeout closures enter through the actor, which keeps its
// non-Sendable executor and plain optional confined to the same isolation.
// These methods contain no dispatch, proof storage, or committed effects.
extension AccountManager {
    func executeOperation(_ op: PendingOperation, provider: any EmailProvider) async throws -> ExecutedOperation {
        try await operationExecutor.executeOperation(op, provider: provider, using: self)
    }
    func executeSingleOp(_ op: PendingOperation, provider: any EmailProvider, context: DrainContext) async -> SingleOpOutcome {
        await operationExecutor.executeSingleOp(op, provider: provider, context: context, using: self)
    }
    #if DEBUG
    var hasPendingOperationSettlement: Bool { operationExecutor.hasPendingSettlement }
    nonisolated func isPermanentlyInvalidError(_ error: Error) -> Bool { AccountOperationExecutor.isPermanentlyInvalidError(error) }
    nonisolated func isConfirmedGoneError(_ error: Error) -> Bool { AccountOperationExecutor.isConfirmedGoneError(error) }
    nonisolated func isMessageNotFoundError(_ error: Error) -> Bool { AccountOperationExecutor.isMessageNotFoundError(error) }
    @discardableResult
    func retirePartiallyCompletedOp(_ op: PendingOperation, provenMembers: [String], remaining: [String],
        provenDestinations: [ProvenDestinationAddress], addressChangesOnMove: Bool,
        confirmedGoneMembers: [String] = [], context: DrainContext) async -> SingleOpOutcome {
        await operationExecutor.retirePartiallyCompletedOp(op, provenMembers: provenMembers,
            remaining: remaining, provenDestinations: provenDestinations,
            addressChangesOnMove: addressChangesOnMove, confirmedGoneMembers: confirmedGoneMembers,
            context: context, using: self)
    }
    #endif
}
