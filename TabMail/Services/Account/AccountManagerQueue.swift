/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization


/// Debug-gated diagnostic log for this file (global `CLAUDE.md` development
/// rule 12) — a thin forwarder onto `BackgroundSyncLogger.logQueue`, the façade
/// that owns the gate, the escaping, the console echo and the `AppLogStore`
/// append for the `.queue` channel.
///
/// ⚠️ IT IS NOT "A NO-OP IN A SHIPPING BUILD", and an earlier wording of this
/// paragraph said so. `DebugModeManager.isLoggingEnabled()` is a RUNTIME gate —
/// the ten-tap unlock flag AND an allowed user — and it is deliberately live on
/// TestFlight and App Store builds for such a user. That is the whole point:
/// these lines have to be capturable on a real device, from a real occurrence.
/// It is a no-op for everyone else.
///
/// `@autoclosure` twice over, and the laziness survives the hop: this wrapper's
/// `message()` is evaluated INSIDE the façade's own autoclosure argument, so a
/// closed gate still builds nothing. These fire per drain pass, per claimed op
/// and per executed member. Same shape as `NotificationActionRouter.log` and
/// `MessageContentStore.log`.
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
/// file-backed (the single `tabmail.log` via `AppLogStore`, on the `.error`
/// channel; recoverable with `AppLogStore.read(channel: .error)`), and exported
/// by `DebugLogView`'s "App Logs" share. There is no
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
///
/// 🚨 THE GATED PATH IS FILE-BACKED TOO, for the same reason the three ungated
/// sites above are. `print` alone reaches only an attached Xcode console: with
/// no `freopen`/`dup2` anywhere in this tree, every one of this helper's call
/// sites was INVISIBLE in a log exported from a device. That is not academic —
/// a Gmail delete → undo → delete that reappeared 31 minutes later
/// (`IOS-QUEUE-008`) could not be root-caused from the exported log, because
/// nothing recorded which drain lane ran first.
///
/// 🚨 IT GOES ON `.queue`, NOT ON THE ALWAYS-ON `.sync` CHANNEL. Every channel
/// in this app is EITHER always-on or debug-gated, exactly once
/// (`AppLogStoreTests.everyChannelIsClassifiedExactlyOnce`, memory topic 122),
/// and `.sync` is the always-on one `BackgroundSyncLogger.log` owns. Writing a
/// gated line onto it would give one channel two lifetime policies and hide this
/// writer from the locked / unlocked / print-gate tests that pin the split. The
/// `.queue` channel carries this file's drain lines AND the sync engine's
/// `[MoveTrace]` verdicts, so `AppLogStore.read(channel: .queue)` reconstructs
/// the whole interleaved decision sequence; `DebugLogView`'s "App Logs" share
/// exports it.

func queueLog(_ message: @autoclosure () -> String) {
    BackgroundSyncLogger.logQueue(message())
}

extension AccountManager {

    // MARK: - Persistent Action Queue

    /// Shared mutable state for ONE drain — the facts every iteration of the
    /// executor loop accumulates and every later iteration reads.
    ///
    /// ⚠️ IT IS NOT SHARED BETWEEN CONCURRENT TASKS ANY MORE, and the reference
    /// type is retained for a different reason. It existed so the parallel lane
    /// Tasks could see each other's updates; the global single-operation executor
    /// has no lane Tasks and never has two operations in flight, so the only
    /// thing that still needs the reference is that the context outlives the
    /// `@Sendable` closure passed to `ProviderWorkQueue.execute`, which forwards
    /// it back through `await self.executeSingleOp`. Every mutation below is
    /// therefore serialized by the actor, and now also by the loop itself.
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
        /// `ProviderEvidenceUnavailable`, whose arm defers one related chain and
        /// leaves the account alone.
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
        /// `PendingOperation.id`s that this drain has decided not to attempt
        /// again — the spin guard, and the ONLY thing that stops the executor
        /// re-claiming a row it just could not make progress on.
        ///
        /// 🚨 IT IS ALWAYS A WHOLE CONNECTED CHAIN, NEVER ONE ROW. Every writer
        /// (`claimFrontierOperation`'s no-attempt skips and
        /// `deferRelatedChainToTail`'s post-failure tail movement) inserts the
        /// deferred row's ENTIRE component over provider addresses. That is what
        /// makes it safe for the frontier walk to take the next candidate: no
        /// operation naming a message the deferred one names can be reached, so a
        /// later gesture can never overtake an unresolved predecessor, and only
        /// genuinely unrelated mail proceeds.
        ///
        /// 🚨 IT REPLACES BOTH v2final's PER-DRAIN DEMOTION SET AND v3's
        /// `evidenceRefused`. v2final ended the drain when the frontier turned out
        /// to be already-demoted; v3 held a separate per-op set consulted in the
        /// lane loop so an evidence refusal could not be repeated after a wire
        /// mutation. One set expresses both: an id in here is never claimed again
        /// this drain, so an evidence-refused operation gets AT MOST ONE provider
        /// attempt per drain, and the walk runs out of candidates instead of
        /// spinning. The refusal case it was built for is real — some
        /// `ProviderEvidenceUnavailable` sites in `IMAPProvider.move` are raised
        /// AFTER the `UID COPY`, so a re-attempt within one drain would seat
        /// another destination duplicate.
        var deferredOperationIds: Set<String> = []
        // op.id values that have already produced a [QueueDiag] deep-dump this drain.
        // Prevents log-spam on the same stuck op that retries every drain cycle.
        var diagnosedOpIds: Set<String> = []
    }

    /// Outcome of one claimed operation's execution (`executeSingleOp`), read by
    /// the global executor to decide whether to keep claiming.
    enum SingleOpOutcome: Sendable, Equatable {
        /// THE EXECUTOR KEEPS CLAIMING. The operation reached a terminal state —
        /// it completed, or it was CONFIRMED stale/invalid and dropped — or it
        /// made STRICT MEMBER PROGRESS and was narrowed to the members still
        /// owed. Either way the queue is strictly smaller than it was, so the
        /// next iteration cannot be a repeat of this one.
        ///
        /// 🚨 THE NARROWING CASE IS WHY AN N-MEMBER GESTURE SETTLES IN ONE RUN.
        /// A provider settles exactly one member per attempt (`MIS-IOS-022`), so
        /// a healthy multi-member operation reports a proper prefix on every
        /// attempt. Reporting that as `.proceed` — rather than as a deferral —
        /// is what lets the executor come straight back for the next member
        /// instead of waiting for another drain trigger. The narrowed row is
        /// appended to the TAIL in the same transaction as its retirement, so
        /// unrelated mail queued behind it goes first and the remainder is
        /// re-claimed as soon as that work is done: one continuous run, and each
        /// member under its own fresh `pendingOperationTimeoutSeconds`.
        case proceed
        /// THE EXECUTOR KEEPS CLAIMING, BUT NOT THIS CHAIN. The attempt failed
        /// in a way that says nothing terminal about the operation, so the row
        /// and every pending row transitively related to it have been appended
        /// to the queue TAIL in one write, `queued` again, and marked deferred
        /// for the rest of this drain. Unrelated mail proceeds; nothing that
        /// shares a message with this operation can overtake it; and the
        /// operation gets exactly ONE provider attempt per drain, which is what
        /// stops a persistent failure becoming a self-rescheduling hot loop.
        case deferred
        /// THE DRAIN STOPS. The operation is unresolved AND this process is
        /// holding something no later claim may run ahead of: a provider result
        /// that PROVED work whose local retirement could not commit (the row
        /// stays `inFlight` with all of its members while the proof is retained,
        /// so the move is never sent to the wire twice —
        /// `AccountOperationExecutor.retainedSettlement`, `IOS-GRAPH-005`), or a requeue
        /// this process could not commit. `recoverPendingSettlement` and
        /// `recoverPendingRequeues` own the recovery at the top of the next
        /// drain; nothing is replayed here, because whatever refused the write
        /// milliseconds ago is overwhelmingly still refusing it.
        case stopDrain
    }

    /// The ids of the accounts whose message ids are ACCOUNT-SCOPED — one id names
    /// exactly ONE message per ACCOUNT, never one per FOLDER — and which may
    /// therefore share ONE drain lane for one message regardless of the folder each
    /// op names. This is the ONLY place membership is decided; it is
    /// extracted from `drainPendingQueue` so it can be unit-tested directly
    /// against real `account` rows rather than only through a full drain.
    ///
    /// Membership is `AccountProvider.gmail` and `AccountProvider.outlook`, plus
    /// the demo account (`DemoSeed.demoAccountId`, stored as `.imap` but backed by
    /// `DemoProvider`, whose local ids never change).
    ///
    /// 🚨 THE PROPERTY IS "ONE ID, ONE MESSAGE PER ACCOUNT" — NOT "the id survives
    /// a move", which is what this function's OLD name asserted (it was named for
    /// id IMMUTABILITY) and which is FALSE of Graph: Microsoft reallocates a message's
    /// default id on every folder move and this tree sends no
    /// `Prefer: IdType="ImmutableId"` (`IOS-GRAPH-002`). Immutability is not what
    /// the lane key needs. What it needs is that the id is not FOLDER-LOCAL, so
    /// that two ops naming one id name one message and therefore must serialize.
    ///
    /// ⚠️ OUTLOOK WAS EXCLUDED UNTIL THE RETIREMENT HANDOFF EXISTED, and the
    /// exclusion is now superseded rather than merely relaxed (`IOS-QUEUE-008`'s
    /// amendment, `IOS-GRAPH-005`). Serializing a follower behind a move that
    /// reallocates its id used to GUARANTEE the follower reached the wire with a
    /// dead id — an inherited race turned into a deterministic 404 and a dropped
    /// intention. `MessageHeaderRekey.finishMove` now rewrites every queued
    /// follower's `messageIds` inside the SAME retirement transaction that learns
    /// the new address (`readdressQueuedOperations`), so a follower reads its live
    /// address before its own wire call and serializing is exactly what makes it
    /// CORRECT. The two facts are one: this set is both the lane key's address
    /// space AND the `accountScopedIds` argument the retirement passes to
    /// `finishMove`.
    ///
    /// `.imap`/`.icloud` UIDs are mailbox-local and stay folder-qualified, as does
    /// any provider string this build cannot decode; `.caldav` never carries mail
    /// operations.
    ///
    /// 🚨 ID-ONLY, MATCHED ON THE RAW PROVIDER COLUMN — deliberately NOT
    /// `Account.fetchAll(db)`. `AccountProvider` is a closed `String, Codable`
    /// enum while the `account.provider` column is unconstrained text, so decoding
    /// whole rows lets ONE bystander row carrying an unrecognised provider string
    /// (persistent corruption, or a row written by a newer build) throw
    /// `DecodingError.dataCorrupted` before any op is claimed. In `drainPendingQueue`
    /// that throw takes the `catch`'s `break`, every later drain reproduces it
    /// identically, and valid ops for EVERY OTHER account stay queued forever
    /// behind a debug-gated log nobody sees — the wedge corollary, app-wide.
    /// Selecting only the ids of the rows that MATCH cannot be defeated by a row
    /// that does not. Precedent:
    /// `AccountManagerUidValidityReset.armImapUidValidityResetForEpochRebuildIfNeeded`.
    ///
    /// An unrecognised provider is therefore simply not a member, which is the
    /// SAFE side: it gets the folder-qualified key the base always used. Its ops
    /// cannot execute anyway (`providers[op.accountId]` is nil, so the claim loop
    /// skips them), so no address-space decision is ever acted on for it. No
    /// "unknown" classification, no quarantine state, no new column.
    nonisolated static func accountScopedIdAccountIds(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, Account
            .select(Column("id"))
            .filter(Column("provider") == AccountProvider.gmail.rawValue
                || Column("provider") == AccountProvider.outlook.rawValue
                || Column("id") == DemoSeed.demoAccountId)))
    }

    /// Groups pending operations into connected components over shared message
    /// ADDRESSES. Two ops that name ANY member at the same address land in the
    /// same component — and transitively, any op sharing an address with either
    /// of those joins too (union-find).
    ///
    /// 🚨 WHAT IT IS FOR NOW: DEFERRAL, NOT DISPATCH. Nothing executes
    /// concurrently any more — the global executor claims ONE row, executes it,
    /// and commits its result before claiming again — so this calculation no
    /// longer decides what runs beside what. It decides what MOVES TOGETHER:
    /// when an operation is deferred, its whole component goes to the tail in
    /// its current relative order, and the executor's no-attempt skips defer the
    /// skipped row's whole component too. That is what lets unrelated mail
    /// proceed without any later gesture overtaking an unresolved predecessor
    /// that names the same message.
    ///
    /// The relation is IDENTICAL to the one the lane dispatcher used, and
    /// deliberately so — the address-space split, the conservative default, the
    /// union-find and their regression tests are retained verbatim. Only the
    /// CONSUMER changed. The name is kept because every routed document,
    /// `KNOWN_ISSUES` entry and test in this tree calls it that.
    ///
    /// 🚨 SCHEDULING RELATEDNESS NEVER AUTHORIZES A MUTATION TARGET. A component
    /// says two operations must not be reordered relative to each other; it
    /// never says an address in one may be used to address the other.
    ///
    /// 🚨 THE KEY IS THE OP'S ADDRESS SPACE, NOT A FIXED SHAPE, and which space
    /// an op lives in is a property of its ACCOUNT. This function is pure, so it
    /// cannot read the `Account` row itself; the caller passes
    /// `accountScopedIdAccountIds` (see `AccountManager.accountScopedIdAccountIds(_:)`,
    /// which is the single place that decides membership).
    ///
    /// 🚨 THE DEFAULT IS THE FOLDER-QUALIFIED KEY, AND THAT IS DELIBERATE. An
    /// account is account-qualified only by being NAMED in the set; an empty set
    /// reproduces the pre-`IOS-QUEUE-008` behaviour exactly. So an account this
    /// code has never heard of — an unknown `provider` string, a provider added
    /// by a newer build — falls on the CONSERVATIVE side by construction, and no
    /// "unknown" classification, quarantine state or extra column is needed to
    /// make that true. ⚠️ The parameter is still REQUIRED rather than defaulted:
    /// a defaulted-empty parameter would let a caller silently lose the Gmail
    /// serialization that `IOS-QUEUE-008` exists for, which is a wrong end state
    /// rather than merely a conservative one.
    ///
    /// - **Folder-qualified — EVERYTHING NOT IN THE SET (IMAP, iCloud, and
    ///   anything unknown)** — key `"accountId:folderPath:msgId"`. A UID is
    ///   mailbox-local: UID 77 in `INBOX` and UID 77 in `Archive` are DIFFERENT
    ///   PHYSICAL MESSAGES, and every id an ordinary IMAP gesture enqueues is a
    ///   bare UID (`admittedOrdinaryActionTargets` requires
    ///   `messageId == String(uid)`).
    ///   Merging them was a NEVER-DROP BUG (`IOS-QUEUE-001`): a component defers
    ///   as a unit on the first evidence refusal, and a server that stops
    ///   reporting `UIDVALIDITY` on SELECT reproduces that refusal identically on
    ///   every drain, forever — so a permanent deferral of `(INBOX, 77)` starved
    ///   the unrelated message at `(Archive, 77)`. That is the WEDGE COROLLARY WITH A
    ///   BYSTANDER, and its owner could neither see nor clear it, because no UI
    ///   lists `PendingOperation` rows. An op that stays queued but prevents
    ///   other intentions executing has not been preserved.
    /// - **Account-qualified — ACCOUNT-SCOPED-ID accounts: Gmail, Outlook, plus
    ///   the demo account** — key `"accountId:msgId"`, folder deliberately
    ///   EXCLUDED. The provider's id is folder-INDEPENDENT, so the folder is not
    ///   part of the address and including it splits one resource across two
    ///   chains.
    ///
    /// 🚨 OUTLOOK/GRAPH IS HERE BECAUSE THE RETIREMENT HANDOFF EXISTS, AND ONLY
    /// BECAUSE OF IT (`IOS-GRAPH-005`). Folder-independent is not the same
    /// property as immutable: Microsoft Graph REALLOCATES a message's default id
    /// on every move, and this tree never sends `Prefer: IdType="ImmutableId"`
    /// (`IOS-GRAPH-002`). Account-qualifying Graph puts a move `A: Inbox→Archive`
    /// and any op on `A` queued BEFORE that move landed (offline, or simply in the
    /// same drain snapshot) into ONE lane, which GUARANTEES the follower runs
    /// AFTER the move. Until 2026-09-04 that guarantee was the defect: the
    /// follower still named the id the move had just invalidated, Graph answered
    /// 404, and `executeSingleOp`'s single-message conflict arm deleted it — the
    /// user's latest intention, gone deterministically rather than merely raced.
    /// `MessageHeaderRekey.finishMove` now REWRITES every non-cancelled
    /// same-account operation whose members include an id the wire just
    /// re-addressed, inside the same transaction that retires the move
    /// (`readdressQueuedOperations`), and the executor claims each row inside a
    /// fresh transaction immediately before executing it. So "the follower runs
    /// after the move" now means "the follower runs against the address the move
    /// PROVED", and single-operation execution is what makes the newest gesture
    /// win instead of racing.
    /// ⚠️ The two halves are not independent: reverting either the handoff or the
    /// claim-time read while leaving Outlook in this set restores the
    /// deterministic loss. `IOS-QUEUE-008`'s amendment records the supersession.
    ///
    /// 🚨 THE NEGATIVE CASE THAT MOTIVATED THE SPLIT (`IOS-QUEUE-008`): on
    /// Gmail, delete → undo → delete again. `undoMove` enqueues a real inverse
    /// whose source is by construction the forward op's DESTINATION, so the queue
    /// held `TRASH→INBOX` and, one second later, `INBOX→TRASH` on ONE message.
    /// Under a uniformly folder-qualified key they landed in different connected
    /// components, ran concurrently, and the INVERSE finished last: the server
    /// kept the message in INBOX while the local row said TRASH, both ops retired
    /// as provider successes, and the next full sync imported the wrong state as
    /// if it were fresh — the deleted message reappeared. That also inverts
    /// never-drop's ordering clause, since the user's NEWEST intention lost to an
    /// older one.
    ///
    /// The op already CARRIES the folder (`PendingOperation.folderPath`, used by
    /// checkpoint A, by `retirePartiallyCompletedOp` and by the executor), so the
    /// folder-local key reads information that was present and discarded rather
    /// than reconstructing one. Every producer takes that path from the same
    /// source — a `Folder.path` or a `MessageHeader.folderPath`, never a literal
    /// — and no site rebuilds an operation from another one, so no row can be
    /// keyed differently from the gesture that created it. (Until 2026-09-06 the
    /// batch-split site in `executeSingleOp` DID rebuild rows, and had to copy
    /// `currentOp.folderPath` onto every child so they keyed as their parent
    /// did; deleting the split deleted that obligation with it.)
    ///
    /// The key is a plain colon join, exactly like `MessageIdentity.folderId`.
    /// A folder path containing a colon can only make two distinct addresses
    /// collide, which OVER-merges — the conservative direction, and precisely
    /// the behaviour that shipped before the folder was added to the key.
    ///
    /// WHY CONNECTED COMPONENTS AND NOT A SINGLE KEY: the ORIGINAL key was
    /// `"accountId:messageIds.first"`, so a batch move `[A,B,C]` was grouped by A
    /// while a LATER single-id op on B (e.g. a flag change) was grouped by B —
    /// even though B is a member of both. Under the old lane dispatcher the two
    /// groups ran concurrently and raced on the wire; under the executor they
    /// would be deferred independently, so the flag change could be left ahead of
    /// the move that invalidates its address. Either way, the union-find is what
    /// makes an op sharing a member id with another op stay ordered behind it.
    ///
    /// Pure and side-effect free (no DB/IO) — `nonisolated static` so it's directly
    /// unit-testable without an actor hop. Callers pass ops in `queuePosition`-asc
    /// order; each component preserves that relative order (FIFO within it).
    /// Ops with empty `messageIds` (no id to key on) fall back to a singleton chain,
    /// matching the pre-existing fallback (`messageIds.first ?? op.id`).
    ///
    /// - Parameter accountScopedIdAccountIds: ids of the accounts whose message
    ///   ids name ONE MESSAGE PER ACCOUNT rather than one per folder (Gmail,
    ///   Outlook, plus the demo account). Everything absent from this set is
    ///   folder-qualified. Required, not defaulted.
    nonisolated static func buildRelatedChains(
        _ ops: [PendingOperation],
        accountScopedIdAccountIds: Set<String>
    ) -> [[PendingOperation]] {
        /// The op's ADDRESS, in whichever address space its account uses. Both
        /// key-building passes below go through this one function, so the union
        /// pass and the chain-assignment pass cannot drift apart.
        func addressKey(_ op: PendingOperation, _ id: String) -> String {
            accountScopedIdAccountIds.contains(op.accountId)
                ? "\(op.accountId):\(id)"
                : "\(op.accountId):\(op.folderPath):\(id)"
        }
        // Union-Find over address keys, with path compression.
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
            let keys = ids.map { addressKey(op, $0) }
            for key in keys where parent[key] == nil {
                parent[key] = key
            }
            for key in keys.dropFirst() {
                union(keys[0], key)
            }
        }

        // Assign each op to its component's group, in the caller's ORIGINAL order
        // (every production caller passes rows read `ORDER BY queuePosition ASC`).
        var chainIndexForRoot: [String: Int] = [:]
        var chains: [[PendingOperation]] = []
        for op in ops {
            guard let firstId = op.messageIds.first else {
                // Empty messageIds — always its own singleton chain.
                chains.append([op])
                continue
            }
            let root = find(addressKey(op, firstId))
            if let idx = chainIndexForRoot[root] {
                chains[idx].append(op)
            } else {
                chainIndexForRoot[root] = chains.count
                chains.append([op])
            }
        }
        return chains
    }

    /// THE GLOBAL SINGLE-OPERATION FIFO EXECUTOR.
    ///
    /// One owner repeatedly claims the LIVE FRONT ROW of one durable queue —
    /// `ORDER BY queuePosition ASC` — executes it, and commits its result before
    /// looking at anything else. There are no lanes, no per-lane Tasks and no
    /// claim-all snapshot: at most one operation is in flight across every
    /// account at any instant, which is what makes "two gestures on one message
    /// never race" a property of the SCHEDULER rather than of a grouping
    /// heuristic that has to be right about which ops share a resource.
    ///
    /// 🚨 THE LOOP HAS NO PASS CAP, AND THAT IS THE THROUGHPUT FIX. The
    /// predecessor claimed everything, dispatched it across concurrent lanes and
    /// stopped after at most THREE passes; a provider that settles one member per
    /// attempt (`MIS-IOS-022`) therefore needed about `ceil(N/3)` separate DRAINS
    /// to finish an N-member gesture, and the next drain waited on a new gesture,
    /// a reconnect or the five-minute poll. On an idle device a ten-message
    /// gesture took fifteen to twenty minutes. This loop instead keeps claiming
    /// while a claimable front row exists, so the same gesture settles member
    /// after member inside ONE continuous run — each member under its own fresh
    /// `pendingOperationTimeoutSeconds`, because each is its own attempt.
    ///
    /// 🚨 WHY IT TERMINATES. Every iteration does exactly one of four things:
    /// retires or drops a row (rows strictly decrease); narrows an operation
    /// after STRICT member progress (members strictly decrease); marks at least
    /// one id deferred for this drain, after which the frontier walk skips it
    /// (the deferred set strictly grows and is bounded by the row count); or
    /// stops the drain. No arm can leave all three quantities unchanged, so the
    /// loop cannot spin. `executeSingleOp` owns that guarantee for the execution
    /// arms and states it at each one.
    ///
    /// 🚨 A DEFERRAL IS A SKIP, NOT A STOP, AND THE CHAIN IS WHAT MAKES THAT
    /// SAFE. When an operation cannot proceed, every pending row transitively
    /// related to it — same connected component over provider ADDRESSES, the
    /// calculation `buildRelatedChains` already owns — is deferred with it. So the walk
    /// can safely take the next unrelated row: nothing that shares a message with
    /// the deferred operation is reachable, and unrelated mail proceeds. This
    /// replaces v2final's "stop the drain when the frontier is already demoted"
    /// spin guard with the same guarantee expressed once: an id in the deferred
    /// set is never claimed again this drain, so the walk simply runs out of
    /// candidates and the drain ends.
    ///
    /// Provider-level concurrency is managed by each provider (IMAP connection
    /// pool, HTTP pooling); operations still execute through
    /// `ProviderWorkQueue.execute(priority: .userAction)` so provider scheduling
    /// priority is unchanged.
    ///
    /// Skips drain when offline to prevent retry storms.
    func drainPendingQueue() async {
        guard !isDraining else {
            needsRedrain = true
            return
        }
        isDraining = true
        defer {
            isDraining = false
            if needsRedrain {
                needsRedrain = false
                Task { await drainPendingQueue() }
            }
        }

        let ctx = DrainContext()

        // 🚨 NO CLAIM STARTS WHILE THIS PROCESS HOLDS AN UNRESOLVED PROVEN
        // RETIREMENT. An operation whose provider result committed nowhere is
        // holding an address every later gesture on that message needs, so it
        // must be retired before anything is claimed — and it must not be made to
        // wait for connectivity it does not use. `isDraining` is therefore set
        // ABOVE the `NetworkMonitor` check: the replay is real work that must not
        // run concurrently with itself or with a claim.
        //
        // Under this executor the invariant needs stating ONCE rather than at
        // every pass boundary, because there are no passes: the loop below
        // re-checks it on every iteration, at the only place a claim can begin.
        guard await operationExecutor.recoverPendingSettlement(context: ctx, using: self) else { return }

        // AND FINISH ANY REQUEUE THIS PROCESS COULD NOT COMMIT, for the same
        // reason and in the same window: a row this process claimed and did not
        // execute is invisible to the frontier walk until it is `queued` again,
        // so resolving that ownership must happen before anything is claimed, and
        // it must not wait for connectivity it does not use.
        guard await recoverPendingRequeues() else { return }

        guard NetworkMonitor.checkConnected() else { return }

        pruneRecentlyCompleted()

        var claimedThisDrain = 0
        executor: while true {
            // 🚨 THE SAME INVARIANT AS THE TWO RECOVERIES ABOVE, RE-ASSERTED AT
            // THE ONLY PLACE A CLAIM CAN BEGIN. A retirement whose local write
            // could not commit leaves its row `inFlight` holding an address the
            // provider has already invalidated; claiming ANY further work while
            // that is outstanding is how a follower goes to the wire at a dead id
            // and has the user's newest gesture deleted as "already done"
            // (`IOS-GRAPH-005`). Stopping is the whole fix — the NEXT drain owns
            // the recovery, because `recoverPendingSettlement` runs before it can
            // claim anything (owner decision 2026-09-05, `#120`).
            if operationExecutor.hasPendingSettlement || !pendingRequeues.isEmpty { break executor }

            let frontier = await claimFrontierOperation(context: ctx)
            switch frontier {
            case .exhausted:
                queueLog("[Queue] drain complete — \(claimedThisDrain) operation(s) claimed this drain")
                break executor
            case .stop:
                break executor
            case .claimed(let op):
                claimedThisDrain += 1
                let outcome = await operationExecutor.attempt(
                    operationId: op.id, context: ctx, using: self)
                if outcome == .stopDrain { break executor }
            }
        }

        await operationExecutor.finishDrain(context: ctx, using: self)
    }

    /// What the frontier walk decided.
    enum FrontierClaim: Sendable {
        /// Nothing claimable is left: the queue is empty, or every remaining row
        /// is deferred for this drain, belongs to a suppressed account, or is
        /// unclaimable for want of evidence. The drain ends normally.
        case exhausted
        /// The walk must not advance: the front row is `inFlight` (owned by work
        /// this process has not resolved), or the claim transaction itself failed.
        /// Ending the drain is the safe answer — nothing may overtake an
        /// unresolved frontier.
        case stop
        /// The claimed row, as read inside the claim transaction.
        case claimed(PendingOperation)
    }

    /// CLAIM THE LIVE FRONT ROW, in one short write transaction.
    ///
    /// Walks `pendingOperation` in `queuePosition ASC` and claims the first row
    /// that can actually be attempted. Everything it can decide without a
    /// provider is decided here, before `inFlight`/`everAttempted` are written,
    /// which is the point: an operation that is skipped for want of a provider,
    /// an epoch or a folder has NOT been attempted, keeps its undo eligibility,
    /// and does not widen crash-time retirement of a never-sent move.
    ///
    /// 🚨 A NO-ATTEMPT SKIP DEFERS THE WHOLE LIVE RELATED CHAIN, IN MEMORY.
    /// Skipping one row and taking the next would let a LATER operation on the
    /// SAME message overtake it — the exact ordering violation this executor
    /// exists to prevent. So every skip marks the skipped row's entire connected
    /// component (`buildRelatedChains`, over the rows this transaction just read) as
    /// deferred for this drain, and the walk refuses every id in that set. It is
    /// an in-memory mark and NOT a durable tail movement: nothing was attempted,
    /// no position changes, no retry is charged, and the rows stay exactly where
    /// the user's gestures put them. Durable tail movement is reserved for a row
    /// that actually FAILED a provider attempt (`deferRelatedChainToTail`).
    ///
    /// 🚨 EXACTLY ONE ARM OF THIS WALK MAY DELETE A ROW ON EVIDENCE, and it is
    /// checkpoint A's POSITIVE epoch mismatch — two epochs that are both real and
    /// disagree, which is exit 4 of `never-drop-user-intention.md`. Every other
    /// thing the walk can observe is an ABSENCE of evidence and is a skip. (The
    /// cancelled-row delete is not an evidence decision: the user withdrew it.)
    private func claimFrontierOperation(context: DrainContext) async -> FrontierClaim {
        // Actor-isolated process state, snapshotted OUTSIDE the write closure:
        // the `@Sendable` GRDB closure cannot read it directly, and both facts are
        // stable for the duration of this one synchronous walk.
        let providerAccountIds = Set(providers.keys)
        let workQueueAccountIds = Set(workQueues.keys)
        let failedAccounts = context.failedAccounts
        let alreadyDeferred = context.deferredOperationIds

        struct WalkResult {
            var claimed: PendingOperation?
            var newlyDeferred: Set<String> = []
            var stop = false
        }

        let result: WalkResult
        do {
            result = try await dbPool.write { db -> WalkResult in
                var out = WalkResult()
                var deferred = alreadyDeferred
                // The address space each account's ids live in — read in the SAME
                // transaction as the rows, so the relatedness calculation and the
                // rows it partitions cannot disagree. ID-only and matched on the
                // raw provider column, so one corrupt bystander `account` row
                // cannot throw and wedge every account's drain.
                let accountScopedIds = try Self.accountScopedIdAccountIds(db)
                let rows = try PendingOperation
                    .order(Column("queuePosition").asc)
                    .fetchAll(db)

                // The connected components over provider addresses, computed ONCE
                // from the rows this transaction read and then indexed by id.
                // Computing them per deferral instead would make a drain that
                // defers k chains cost O(k · N) union-find passes over the whole
                // queue, which is the shape that turns a long offline backlog into
                // a visible stall.
                //
                // Deletes performed later in this walk do not invalidate it: an id
                // that is no longer a row simply cannot be claimed, and its
                // presence in a deferred set is inert.
                var componentById: [String: [String]] = [:]
                for chain in Self.buildRelatedChains(rows, accountScopedIdAccountIds: accountScopedIds) {
                    let ids = chain.map(\.id)
                    for id in ids { componentById[id] = ids }
                }

                /// Every id in `seed`'s connected component over provider
                /// addresses, computed from the rows THIS transaction read.
                func relatedIds(of seed: PendingOperation) -> [String] {
                    componentById[seed.id] ?? [seed.id]
                }

                func deferChain(_ seed: PendingOperation, reason: String) {
                    let ids = relatedIds(of: seed)
                    deferred.formUnion(ids)
                    out.newlyDeferred.formUnion(ids)
                    queueLog(
                        "[Queue] frontier \(seed.id.prefix(8)) (\(seed.type.rawValue)) not attempted "
                            + "— \(reason); deferring its live related chain "
                            + "(\(ids.count) row(s)) for this drain, no claim and no retry charge")
                }

                for row in rows {
                    if deferred.contains(row.id) { continue }
                    guard var fetched = try PendingOperation.fetchOne(db, key: row.id) else {
                        continue
                    }
                    if fetched.status == PendingStatus.cancelled.rawValue {
                        _ = try PendingOperation.deleteOne(db, key: fetched.id)
                        queueLog("[Queue] Op \(fetched.id.prefix(8)) cancelled by undo, deleted")
                        continue
                    }
                    if fetched.status == PendingStatus.inFlight.rawValue {
                        // THE PROTECTED-FRONTIER LAW. An `inFlight` row is owned by
                        // work this process started and has not resolved. Skipping
                        // past it would let a later gesture overtake an unresolved
                        // predecessor; stealing it would send the same mutation
                        // twice. Stop instead, and let the two recoveries at the top
                        // of the next drain resolve the ownership.
                        queueLog(
                            "[Queue] frontier \(fetched.id.prefix(8)) is inFlight — "
                                + "stopping this drain rather than overtaking it")
                        out.stop = true
                        return out
                    }
                    if failedAccounts.contains(fetched.accountId) {
                        deferChain(fetched, reason: "its account is suppressed for this drain")
                        continue
                    }
                    guard providerAccountIds.contains(fetched.accountId),
                          workQueueAccountIds.contains(fetched.accountId) else {
                        // Absence of a provider entry is a NO-ATTEMPT DEFERRAL,
                        // explicitly not v2final's global-stop branch: a
                        // not-yet-connected account must not hold every other
                        // account's mail. Account removal purges that account's rows
                        // separately, so this is transient state, not an orphan.
                        deferChain(fetched, reason: "no registered provider or work queue")
                        continue
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
                        deferChain(
                            fetched,
                            reason: "folder \(fetched.folderPath) is mid UIDVALIDITY reset")
                        continue
                    }
                    // T2.6 checkpoint A. PORT: v2final's A4 compare/delete
                    // inside the claim transaction. SUBTRACT: RFC/hybrid
                    // compatibility, nil fail-open, and the withdrawn recovery
                    // machinery. ⚑ NO REFERENCE — INVENTED: v3's DB provider
                    // classification and fail-closed shape.
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
                    // exit: those ops are NOT claimed and stay durably `queued`,
                    // exactly as they would across an offline window. The
                    // predecessor deleted on all of them, which is the single
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
                            deferChain(fetched, reason: "no account row for checkpoint A")
                            continue
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
                                // left `queued` and simply not claimed.
                                BackgroundSyncLogger.log(
                                    "[Queue] Checkpoint A skipped \(fetched.id.prefix(8)) " +
                                    "(\(fetched.type.rawValue), \(fetched.folderPath)) — " +
                                    "provider address or UIDVALIDITY not established; op stays queued")
                                deferChain(
                                    fetched,
                                    reason: "checkpoint A has no address or epoch evidence")
                                continue
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
                                continue
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
                        continue
                    }
                    fetched.status = PendingStatus.inFlight.rawValue
                    // PORT — v2final's persisted attempted-row proof, adapted to
                    // v3's claim. Every no-attempt condition above has already
                    // been evaluated, so this bit is written only when a provider
                    // call is about to be made. Never infer it from status or
                    // retryCount.
                    fetched.everAttempted = true
                    try fetched.update(db)
                    out.claimed = fetched
                    return out
                }
                return out
            }
        } catch {
            queueLog("[Queue] ERROR: frontier claim failed: \(error) — this drain stops")
            return .stop
        }

        context.deferredOperationIds.formUnion(result.newlyDeferred)
        if result.stop { return .stop }
        guard let claimed = result.claimed else { return .exhausted }
        return .claimed(claimed)
    }

    /// APPEND A FAILED OPERATION AND ITS LIVE RELATED CHAIN TO THE TAIL, IN ONE
    /// WRITE, and mark every one of them deferred for this drain.
    ///
    /// This is the durable half of related-chain deferral, and the only thing in
    /// the executor that rewrites `queuePosition` after admission. Spec §3's
    /// worked examples are what it implements:
    ///
    /// ```text
    /// Before: A1, B1, A2, C1   A1 fails   After: B1, C1, A1, A2
    /// Before: A1, X1, action(A+B), B2, Y1   A1 fails   After: X1, Y1, A1, action(A+B), B2
    /// ```
    ///
    /// A2 cannot pass A1, because A2 moves WITH it; B1 and C1 keep their relative
    /// order because nothing else is touched. Relatedness is the connected
    /// component over provider ADDRESSES that `buildRelatedChains` already computes — the
    /// same pure calculation, the same account-qualified/folder-qualified split,
    /// the same conservative default for a provider string this build cannot
    /// decode — read from the LIVE rows inside this transaction rather than from
    /// any snapshot. Scheduling relatedness never authorizes a mutation target;
    /// it only decides what moves together.
    ///
    /// 🚨 THE MEMBERSHIP IS RE-READ HERE, AFTER THE PROVIDER CALL. A retirement
    /// committed earlier in this drain may have re-addressed a follower
    /// (`MessageHeaderRekey.readdressQueuedOperations`), and a chain computed from
    /// pre-call ids would group by an address the wire has already replaced.
    ///
    /// 🚨 IT NEVER RECREATES A ROW. Every write is an `UPDATE … WHERE id`, so a
    /// row that undo, a cancel or an account deletion removed while the provider
    /// call was outstanding stays removed — the user's newer decision wins.
    ///
    /// - Returns: `true` when the tail movement committed. `false` means the
    ///   transaction failed and NOTHING moved; the caller must not report a
    ///   deferral it did not perform, and falls back to the ordinary requeue so
    ///   the claimed row is never stranded `inFlight`.
    @discardableResult
    func deferRelatedChainToTail(
        failing op: PendingOperation,
        incrementRetryCount: Bool,
        context: DrainContext
    ) async -> Bool {
        do {
            let movedIds = try await retryWrite(dbPool, label: "Queue deferral") { db -> [String] in
                let accountScopedIds = try Self.accountScopedIdAccountIds(db)
                let live = try PendingOperation
                    .filter(Column("status") != PendingStatus.cancelled.rawValue)
                    .order(Column("queuePosition").asc)
                    .fetchAll(db)
                guard live.contains(where: { $0.id == op.id }) else {
                    // Undo, a cancel or an account deletion removed the row while
                    // the provider call was outstanding. There is nothing to defer
                    // and nothing to recreate.
                    return []
                }
                let chains = Self.buildRelatedChains(live, accountScopedIdAccountIds: accountScopedIds)
                let chain = chains.first { $0.contains { $0.id == op.id } } ?? []
                let ids = chain.map(\.id)
                try PendingOperation.appendToTail(
                    db, ids: ids, chargeRetryTo: incrementRetryCount ? op.id : nil)
                return ids
            }
            guard !movedIds.isEmpty else {
                queueLog(
                    "[Queue] deferral — row \(op.id.prefix(8)) no longer exists; "
                        + "nothing moved and nothing recreated")
                context.deferredOperationIds.insert(op.id)
                return true
            }
            context.deferredOperationIds.formUnion(movedIds)
            queueLog(
                "[Queue] deferral — moved \(movedIds.count) related row(s) to the tail after "
                    + "\(op.id.prefix(8)) \(op.type.rawValue) failed, preserving their order; "
                    + "they are deferred for the rest of this drain")
            return true
        } catch {
            // NEVER REPORT SUCCESSFUL TAIL MOVEMENT ON A FAILED TRANSACTION.
            // Nothing moved, so the claimed row is still `inFlight`; hand it to
            // the ordinary requeue, which keeps ownership in `pendingRequeues`
            // when its own write is refused too.
            queueLog(
                "[Queue] deferral — tail movement for \(op.id.prefix(8)) failed: \(error); "
                    + "nothing moved, requeueing the claimed row and stopping this drain")
            await requeueOrRetain(op.id, incrementRetryCount: incrementRetryCount)
            return false
        }
    }

    /// Record which queued operations this retirement re-addressed.
    ///
    /// Debug-gated (`BackgroundSyncLogger.logQueue`, `AppLogChannel.queue`) and
    /// present because `IOS-QUEUE-008` took a month to diagnose for exactly this
    /// reason: the lane decision and the address handoff are both invisible after
    /// the fact unless something writes them down. The line names the retiring op
    /// and every follower whose members it rewrote.
    func logReaddressedFollowers(
        _ result: MoveFinishResult, retiring op: PendingOperation
    ) {
        guard !result.readdressedOperationIds.isEmpty else { return }
        BackgroundSyncLogger.logQueue(
            "[Queue] handoff — move \(op.id.prefix(8)) retired and re-addressed "
                + "\(result.readdressedOperationIds.count) queued op(s): "
                + result.readdressedOperationIds.map { String($0.prefix(8)) }.joined(separator: ","))
    }







    /// RETURN A CLAIMED-BUT-UNEXECUTED OPERATION TO `queued`, AND KEEP OWNING IT
    /// IF THAT WRITE FAILS.
    ///
    /// The one implementation of a shape that used to be written out eight times
    /// as `try? await retryWrite(dbPool, label: "Queue") { PendingOperation
    /// .markQueued(...) }` — with the write's error discarded at every one of
    /// them. Discarding it is the defect: the producers of that failure are
    /// database-wide (GRDB suspension while backgrounded, ADR-IOS-041; a full
    /// disk; an I/O error at COMMIT), the row stays `inFlight`, the claim loop
    /// refuses `inFlight`, and no later pass in this process can ever pick it up.
    /// At the next launch `AppDatabase.recoverPreviousSessionResidue` deletes it
    /// if it is an `everAttempted` `.move` — a gesture that never reached the
    /// provider, lost with no crash at all.
    ///
    /// On success the id is released; on a throw this process KEEPS it, with the
    /// caller's own retry-count choice, and `recoverPendingRequeues` finishes the
    /// job at the top of the next drain. The write itself is unchanged: same
    /// `retryWrite`, same `markQueued`, same column semantics.
    ///
    /// `removeValue` on the success path matters as much as the insert: a site
    /// that requeues an id this process was still holding has resolved that
    /// ownership, and leaving a stale entry behind would stop later drains for a
    /// row that is already `queued`.
    func requeueOrRetain(_ id: String, incrementRetryCount: Bool = false) async {
        do {
            try await retryWrite(dbPool, label: "Queue") { db in
                try PendingOperation.markQueued(
                    db, id: id, incrementRetryCount: incrementRetryCount)
            }
            pendingRequeues.removeValue(forKey: id)
        } catch {
            pendingRequeues[id] = incrementRetryCount
            queueLog(
                "[Queue] requeue of \(id.prefix(8)) failed: \(error); this process keeps the row "
                    + "(retry charge: \(incrementRetryCount)) and recovers it at the next drain")
        }
    }

    /// FINISH EVERY REQUEUE THIS PROCESS COULD NOT COMMIT, BEFORE THE DRAIN
    /// CLAIMS ANYTHING.
    ///
    /// ⚠️ IT RUNS BEFORE THE `NetworkMonitor` CHECK, for the same reason
    /// `recoverPendingSettlement` does: the work is entirely LOCAL, and making
    /// it wait for connectivity would strand a claimed row behind an offline
    /// window it has nothing to do with.
    ///
    /// The write is `requeueIfInFlight`, not `markQueued`, and the guard is the
    /// point. This runs an unbounded time after the claim, so the row may since
    /// have been cancelled by the user, deleted by a local wipe or reset, or
    /// already requeued by the retained retirement that owns the same suffix.
    /// Only `inFlight` means "still claimed by this process and never executed".
    /// A ZERO-ROW UPDATE IS SUCCESS: whatever the row's state is now, this
    /// process no longer owns it, so the entry is released.
    ///
    /// A failure STOPS THE DRAIN with ownership retained. A database that cannot
    /// take this one-column write cannot claim, execute or retire anything else
    /// safely either, and starting a claim pass while an unresolved claimed row
    /// is invisible to the claim loop is exactly how a follower gets admitted
    /// alone ahead of its predecessor. It schedules no redrain of its own: the
    /// next drain from any ordinary entry point runs this again, first.
    ///
    /// - Returns: `false` when the drain must stop.
    private func recoverPendingRequeues() async -> Bool {
        guard !pendingRequeues.isEmpty else { return true }
        for (opId, incrementRetryCount) in pendingRequeues {
            do {
                try await retryWrite(dbPool, label: "Queue") { db in
                    try PendingOperation.requeueIfInFlight(
                        db, id: opId, incrementRetryCount: incrementRetryCount)
                }
                pendingRequeues.removeValue(forKey: opId)
                queueLog(
                    "[Queue] requeue recovery — released \(opId.prefix(8)); it is claimable again "
                        + "(or was already cancelled, wiped or requeued)")
            } catch {
                queueLog(
                    "[Queue] requeue recovery — \(opId.prefix(8)) still cannot be returned to "
                        + "`queued`: \(error); this process keeps the row and this drain stops")
                return false
            }
        }
        return true
    }

    /// TEST-ONLY one-shot fault for the post-claim re-read below.
    ///
    /// Holds an operation id; the next `liveOperation` call for that id throws a
    /// `DatabaseError` instead of reading, and clears the arming in the same
    /// critical section so it fires EXACTLY ONCE. `nil` (the default) is no
    /// fault, so production behaviour is the unarmed path.
    ///
    /// Modelled on `DebugModeManager.loggingEnabledOverrideForTesting`: `#if
    /// DEBUG` only, `Mutex`-wrapped, and it may only ADD a throw — it can never
    /// skip a guard, change a disposition, or make a read succeed that would
    /// otherwise fail. It exists because the state this seam produces (a read
    /// that throws AFTER the claim committed `inFlight` + `everAttempted`) is
    /// reachable in production from an interrupted/busy/I-O SQLite read but is
    /// not schedulable from a test against a healthy pool: every earlier read of
    /// the same drain — the ops snapshot, the classifier, the claim — runs on
    /// the same `PrioritizedDatabase`, so a connection-level fault would fail the
    /// drain before anything is ever claimed, which is a different scenario.
    #if DEBUG
    nonisolated static let liveOperationReadFaultForTesting = Mutex<String?>(nil)
    #endif

    /// The row as it is RIGHT NOW, by primary key — the address the drain is
    /// about to send, rather than the one it snapshotted.
    ///
    /// `nil` means exactly one thing: the row no longer exists. A read that
    /// FAILS throws instead, because "we could not determine the answer" is not
    /// evidence about the row and must stay retryable.
    ///
    /// Both executor admission by claimed ID and retained settlement recovery use
    /// this read. A positive absence honors a reset/removal; a thrown read keeps
    /// lifecycle or settlement ownership and stops this drain.
    func liveOperation(_ id: String) async throws -> PendingOperation? {
        #if DEBUG
        let faultArmed = Self.liveOperationReadFaultForTesting.withLock { armed -> Bool in
            guard armed == id else { return false }
            armed = nil
            return true
        }
        if faultArmed {
            throw DatabaseError(
                resultCode: .SQLITE_INTERRUPT,
                message: "injected post-claim re-read failure for \(id)")
        }
        #endif
        return try await dbPool.read { db in try PendingOperation.fetchOne(db, key: id) }
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
    func recordMembersThatEnteredInbox(
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
    /// reason. ⚠️ That rediscovery is WINDOW-BOUNDED (ADR-IOS-078; comment
    /// corrected 2026-08-20, iOS #66) — `repopulationCandidates` selects only the
    /// newest `SyncConfig.maxRecentEmails` Inbox rows, while the enqueue below is
    /// deliberately window-EXEMPT, so for exactly the out-of-window rows this
    /// exemption exists to serve the stated recovery does NOT fire. Accepted per
    /// ADR-IOS-078's residual invariant: fail-closed, non-durable, one-gesture
    /// recoverable (reopen/Retry). Do NOT widen the sweep to "fix" it, and do NOT
    /// re-gate this producer to "restore" a global bound.
    /// `internal` (not `private`) for executable regression coverage — the same
    /// reason `resolveInboxEntryAITargets` below is: the window-exempt admission
    /// this handler performs is otherwise unreachable from a unit test.
    func enqueueAIForMembersThatEnteredInbox(
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
        // `enableAI && item.isInInbox` arm — EXCEPT the window: a move into the
        // Inbox is explicit user intent on a specific message, so it is
        // window-exempt (ADR-IOS-078 pathway regating, coordinator-ruled
        // 2026-08-19); gating it would recreate the user-must-click gap
        // ADR-IOS-008 decision 3 closed. `flushBatch`'s DEFAULT (background/sync)
        // path stays gated — it is the sync-origin producer the install-flood
        // bound exists for (that same function is dual-origin: the user-open body
        // fetch passes `aiWindowExempt: true`, but that is a different caller).
        // The executor still retires any job whose message has LEFT the Inbox
        // (membership is unconditional; only the newest-100 rank is waived).
        for item in resolved {
            await ActiveAIQueue.shared.enqueue(
                headerId: item.headerId, accountId: item.accountId, windowExempt: true)
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


    /// Retire the local headers of members a PROVIDER named as gone, for an
    /// operation whose retirement has just committed.
    ///
    /// 🚨 CALLED FROM EVERY PATH THAT RETIRES SUCH A MEMBER, AND ONLY AFTER ITS
    /// RETIREMENT HAS COMMITTED. The header row lives in a different table and its
    /// deletion releases FTS and body content, so it must never be able to precede
    /// the operation's own retirement; and the four sites that can commit one —
    /// whole-op success, the narrowing path, and the retained replay of either —
    /// must all do it, or a member is retired from the queue while its ghost row
    /// survives in the mailbox.
    ///
    /// `memberIds` are ids the provider reported through
    /// `ProviderMembersDispositioned` / `MoveOutcome.confirmedGoneIds`, i.e. members a
    /// request addressed to THAT member answered `ProviderMemberAbsence`-
    /// authoritatively for. Nothing else may be passed here.
    ///
    /// 🚨 WHY `op.folderPath` RECONSTRUCTS THE HEADER'S REAL PRIMARY KEY, even
    /// though the gesture has already moved the row locally. A header's id is
    /// `(accountId, folderPath, messageId)`, and a `.move` gesture applies
    /// `optimisticMoveToFolder` immediately — but that helper UPDATEs
    /// `folderId` / `folderPath` / `isInInbox` / `observedUidValidity` BY PRIMARY
    /// KEY `id` and does NOT re-key the row, so the id still spells the SOURCE
    /// folder while the columns spell the destination. The operation's
    /// `folderPath` is that same source folder, so it is the correct component
    /// here; taking `destinationPath`, or re-deriving from the header's current
    /// `folderPath` column, would compute an id no row has and the delete would
    /// silently match nothing.
    ///
    /// The same reasoning covers a FOLLOWER of an already-landed move: the drain
    /// re-keys a row only through `MessageHeaderRekey.finishMove`, and a
    /// follower's own `folderPath` is by construction its predecessor's landing
    /// folder — the address space the follower was admitted into — so the pair
    /// (op.folderPath, memberId) is exactly what that row's id was built from.
    func retireConfirmedGoneMemberHeaders(
        _ op: PendingOperation, memberIds: [String]
    ) async {
        for goneId in memberIds {
            let hid = MessageIdentity.headerId(
                accountId: op.accountId,
                folderPath: op.folderPath,
                messageId: goneId)
            await deleteConfirmedGoneHeader(
                headerId: hid, reason: "\(op.type.rawValue) member gone")
        }
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
        // skips the scoped DB read the dump exists to render — a read whose only
        // consumer is a line that is never rendered while the gate is closed.
        //
        // ⚠️ "while the gate is CLOSED", not "in a shipping build" — an earlier
        // wording of this comment said the latter and it is FALSE.
        // `DebugModeManager.isLoggingEnabled()` is a RUNTIME unlock, not a build
        // configuration, so on a device or TestFlight build belonging to an
        // allowed user who has unlocked debug logging this guard passes, the DB
        // read runs, and the dump IS visible. That is the intended behaviour —
        // this diagnostic exists to be readable in the field. Do not "optimise"
        // it away on the belief that release builds never reach it.
        //
        // The caller's `context.diagnosedOpIds` bookkeeping happens before this
        // call, so returning early changes no control flow there.
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
        queueLog("[QueueDiag] classifier: isMessageNotFoundError=\(AccountOperationExecutor.isMessageNotFoundError(error)) isConfirmedGoneError=\(AccountOperationExecutor.isConfirmedGoneError(error)) isPermanentlyInvalidError=\(AccountOperationExecutor.isPermanentlyInvalidError(error))")

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




    /// The post-connect queue kick: drain whatever the durable action queue
    /// still owes, then reconcile the outbox and drain the calendar queue.
    ///
    /// 🚨 THIS IS NOT CRASH RECOVERY ANY MORE, and it must never become it
    /// again. The blind whole-table sweep of previous-session residue that used
    /// to open this function now lives in
    /// `AppDatabase.recoverPreviousSessionResidue`, called from
    /// `AppDatabase.init` before the pool is ever published — the only boundary
    /// at which "residue" is provable. It could not stay here: `RootView` calls
    /// this function only AFTER every account has finished connecting, while a
    /// connected account's gestures and the background entry points have already
    /// been draining, so a whole-table sweep here reaches rows this LIVE process
    /// owns. It deleted a `.move` whose proven provider result this process was
    /// still holding for replay, after which the replay dropped that proof as if
    /// the user had wiped the row and the follower went to the wire at an
    /// address Graph had already reallocated (`IOS-GRAPH-005`, #114).
    ///
    /// The name and both callers are unchanged; what changed is that this
    /// function no longer writes anything before it drains.
    func reconcilePendingOperations() async {
        await drainPendingQueue()
        await reconcileOutbox()
        await drainCalendarQueue()
    }
}
