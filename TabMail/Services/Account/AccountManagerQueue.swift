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
private func queueLog(_ message: @autoclosure () -> String) {
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
        /// `AccountManager.pendingRetirements`, `IOS-GRAPH-005`), or a requeue
        /// this process could not commit. `replayRetainedRetirements` and
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
    ///   lanes.
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
    /// Ops with empty `messageIds` (no id to key on) fall back to a singleton lane,
    /// matching the pre-existing fallback (`messageIds.first ?? op.id`).
    ///
    /// - Parameter accountScopedIdAccountIds: ids of the accounts whose message
    ///   ids name ONE MESSAGE PER ACCOUNT rather than one per folder (Gmail,
    ///   Outlook, plus the demo account). Everything absent from this set is
    ///   folder-qualified. Required, not defaulted.
    nonisolated static func buildLanes(
        _ ops: [PendingOperation],
        accountScopedIdAccountIds: Set<String>
    ) -> [[PendingOperation]] {
        /// The op's ADDRESS, in whichever address space its account uses. Both
        /// key-building passes below go through this one function, so the union
        /// pass and the lane-assignment pass cannot drift apart.
        func laneKey(_ op: PendingOperation, _ id: String) -> String {
            accountScopedIdAccountIds.contains(op.accountId)
                ? "\(op.accountId):\(id)"
                : "\(op.accountId):\(op.folderPath):\(id)"
        }
        // Union-Find over lane keys, with path compression.
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
            let keys = ids.map { laneKey(op, $0) }
            for key in keys where parent[key] == nil {
                parent[key] = key
            }
            for key in keys.dropFirst() {
                union(keys[0], key)
            }
        }

        // Assign each op to its component's group, in the caller's ORIGINAL order
        // (every production caller passes rows read `ORDER BY queuePosition ASC`).
        var laneIndexForRoot: [String: Int] = [:]
        var lanes: [[PendingOperation]] = []
        for op in ops {
            guard let firstId = op.messageIds.first else {
                // Empty messageIds — always its own singleton lane.
                lanes.append([op])
                continue
            }
            let root = find(laneKey(op, firstId))
            if let idx = laneIndexForRoot[root] {
                lanes[idx].append(op)
            } else {
                laneIndexForRoot[root] = lanes.count
                lanes.append([op])
            }
        }
        return lanes
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
    /// calculation `buildLanes` already owns — is deferred with it. So the walk
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
        guard await replayRetainedRetirements(context: ctx) else { return }

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
            // the recovery, because `replayRetainedRetirements` runs before it can
            // claim anything (owner decision 2026-09-05, `#120`).
            if !pendingRetirements.isEmpty || !pendingRequeues.isEmpty { break executor }

            let frontier = await claimFrontierOperation(context: ctx)
            switch frontier {
            case .exhausted:
                queueLog("[Queue] drain complete — \(claimedThisDrain) operation(s) claimed this drain")
                break executor
            case .stop:
                break executor
            case .claimed(let op):
                claimedThisDrain += 1
                guard let queue = workQueues[op.accountId] else {
                    // Unreachable: the frontier walk refuses to claim an op whose
                    // account has no work queue. Handled rather than trapped so a
                    // future re-ordering cannot strand a claimed row `inFlight`.
                    await requeueOrRetain(op.id)
                    break executor
                }
                let provider = queue.provider
                // WIRE ORDER, RECORDED. The pair of lines around this call is what
                // lets an exported log answer "which operation went out, in what
                // order" after the fact — the question `IOS-QUEUE-008` could not
                // answer. Under a single-operation executor the queue position IS
                // the answer, so it is what the line carries.
                queueLog(
                    "[Queue] drain pos \(op.queuePosition) — executing \(op.id.prefix(8)) "
                        + "\(op.type.rawValue) \(op.folderPath)→\(op.destinationPath ?? "-") "
                        + "ids=[\(op.messageIds.joined(separator: ","))]")
                // Outcome captured via Mutex (not a plain var) — the closure passed
                // to `queue.execute` is @Sendable, so it cannot capture a mutable
                // local var directly under Swift 6 strict concurrency.
                let outcomeBox = Mutex<SingleOpOutcome>(.proceed)
                await queue.execute(priority: .userAction) {
                    let result = await self.executeSingleOp(
                        op, provider: provider, context: ctx)
                    outcomeBox.withLock { $0 = result }
                }
                let outcome = outcomeBox.withLock { $0 }
                // The SAME fields as the `executing` line plus the outcome, on
                // purpose: an equality oracle over the pair catches a dropped
                // type, a reversed source→destination and a duplicated entry,
                // none of which a bare `outcome=` line would constrain.
                queueLog(
                    "[Queue] drain pos \(op.queuePosition) — executed \(op.id.prefix(8)) "
                        + "\(op.type.rawValue) \(op.folderPath)→\(op.destinationPath ?? "-") "
                        + "ids=[\(op.messageIds.joined(separator: ","))] outcome=\(outcome)")
                if outcome == .stopDrain { break executor }
            }
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
    /// component (`buildLanes`, over the rows this transaction just read) as
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
                for lane in Self.buildLanes(rows, accountScopedIdAccountIds: accountScopedIds) {
                    let ids = lane.map(\.id)
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
    /// component over provider ADDRESSES that `buildLanes` already computes — the
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
    private func deferRelatedChainToTail(
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
                let lanes = Self.buildLanes(live, accountScopedIdAccountIds: accountScopedIds)
                let chain = lanes.first { $0.contains { $0.id == op.id } } ?? []
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
    private func logReaddressedFollowers(
        _ result: MoveFinishResult, retiring op: PendingOperation
    ) {
        guard !result.readdressedOperationIds.isEmpty else { return }
        BackgroundSyncLogger.logQueue(
            "[Queue] handoff — move \(op.id.prefix(8)) retired and re-addressed "
                + "\(result.readdressedOperationIds.count) queued op(s): "
                + result.readdressedOperationIds.map { String($0.prefix(8)) }.joined(separator: ","))
    }

    /// THE WHOLE-OP RETIREMENT TRANSACTION, as one value.
    ///
    /// Extracted from `executeSingleOp` verbatim so the REPLAY in
    /// `replayRetainedRetirements` runs the SAME write rather than a second copy
    /// that can drift away from it. Nothing about the transaction's content
    /// changed in the extraction: the classification is still read INSIDE the
    /// write, from the same `account` rows `drainPendingQueue` keyed the lanes
    /// from, because the two facts must not be allowed to drift — the lane key
    /// promises that a follower runs after this move, and `accountScopedIds` is
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
        let lanes = buildLanes(live, accountScopedIdAccountIds: accountScopedIdAccounts)
        let chain = lanes.first { $0.contains { $0.id == frozenRetiredOp.id } } ?? []
        try PendingOperation.appendToTail(db, ids: chain.map(\.id))
        return result
    }

    /// REPLAY every retirement whose local write could not commit earlier in
    /// this process, before the drain claims anything.
    ///
    /// The provider proved these operations on the wire; only a transaction
    /// failed. Each entry is re-run through the SAME helper its original site
    /// ran, and the post-commit steps that site would have run happen here
    /// instead, because they are what a committed retirement publishes.
    ///
    /// ⚠️ THIS RUNS BEFORE THE `NetworkMonitor` CHECK, deliberately: the work
    /// left to do is entirely LOCAL, and making a local recovery wait for
    /// connectivity would strand a proven move behind an offline window it has
    /// nothing to do with.
    ///
    /// 🚨 IT NO LONGER OWNS A CLAIMED SUFFIX, because under the global
    /// single-operation executor there is never one. This function used to
    /// requeue, in the retirement's own transaction, the ops this process had
    /// claimed behind a halted lane; that suffix could only exist while several
    /// rows were `inFlight` at once. One row is claimed at a time now, so the
    /// operations behind a retained retirement are still `queued` and the next
    /// executor iteration reaches them with no recovery step at all.
    ///
    /// - Returns: `false` when the drain must stop. A replay that still cannot
    ///   commit says the database is still refusing writes, and nothing else in
    ///   this drain could retire safely either — so there is no per-account skip
    ///   machinery, just a stop. The entry is kept and the next drain tries
    ///   again.
    private func replayRetainedRetirements(context: DrainContext) async -> Bool {
        guard !pendingRetirements.isEmpty else { return true }
        for (opId, retirement) in pendingRetirements {
            do {
                // ⚠️ THE ROW CAN BE GONE, and that is not a failure. The writers
                // that delete a claimed row are the local wipes and resets —
                // `SettingsView.localIndexWipeTxn`, `AppDataWiper`,
                // `AccountManagerSetup`'s per-account delete, `DemoSeed`'s demo
                // reset and the UIDVALIDITY-reset sweep — which never join a
                // running drain. Same reasoning as `liveOperation`'s nil arm:
                // that is the user's NEWER gesture winning, so the retained proof
                // is dropped rather than replayed against a row nobody wants.
                //
                // 🚨 THIS IS `liveOperation`, NOT A SECOND COPY OF IT. The
                // existence check used to be a bespoke `dbPool.read` here, which
                // asked the same question with the same two-outcome contract —
                // `nil` is a deleted row, a THROW is "we could not determine the
                // answer" and stays retryable (clause 2 of
                // `never-drop-user-intention.md`). Two copies of that contract
                // are two places for it to drift, and the copy carried no
                // coverage for its thrown case at all. Reusing `liveOperation`
                // also inherits its `#if DEBUG` one-shot read fault, so the throw
                // arm is witnessable without a new seam — and this replay is now
                // its ONLY caller, because the executor claims the live front row
                // inside the claim transaction and has nothing left to re-read.
                // A throw lands in the catch below and stops the drain
                // with the proof still held, which is exactly what the bespoke
                // read did.
                guard try await liveOperation(opId) != nil else {
                    pendingRetirements.removeValue(forKey: opId)
                    queueLog(
                        "[Queue] retirement replay — row \(opId.prefix(8)) no longer exists; "
                            + "a local wipe or reset removed it, so the retained proof is dropped")
                    continue
                }
                switch retirement {
                case .full(let op, let executed):
                    let result = try await retryWrite(dbPool, label: "Queue") { db in
                        try Self.commitFullRetirement(op, executed: executed, db: db)
                    }
                    pendingRetirements.removeValue(forKey: opId)
                    queueLog(
                        "[Queue] retirement replay — committed the retained retirement of "
                            + "\(opId.prefix(8)) \(op.type.rawValue)")
                    logReaddressedFollowers(result, retiring: op)
                    await publishMoveFinish(result)
                    // The retained retirement carries the provider's confirmed-gone
                    // attribution, so the replay owes the same header cleanup the
                    // original site would have done had its write committed.
                    // Without this the row retires here and its ghost header
                    // survives (GPT consult finding 2, 2026-09-06).
                    await retireConfirmedGoneMemberHeaders(
                        op, memberIds: executed.confirmedGoneMembers)
                    await materializeDeferredMoveSuccessors(after: op, result: result)
                    if [.archive, .delete, .move].contains(op.type), let dest = op.destinationPath {
                        context.foldersToSync.insert("\(op.accountId)|\(dest)")
                        if executed.reconcileMoveSource {
                            context.foldersToSync.insert("\(op.accountId)|\(op.folderPath)")
                        }
                        if op.type == .move, dest != op.folderPath {
                            await recordMembersThatEnteredInbox(
                                op, destinationPath: dest, context: context)
                        }
                    }
                    if [.saveDraft, .deleteDraft].contains(op.type) {
                        context.foldersToSync.insert("\(op.accountId)|\(op.folderPath)")
                    }
                case .partial(let op, let provenMembers, let remaining,
                              let provenDestinations, let addressChangesOnMove,
                              let confirmedGoneMembers):
                    let frozenRetiredOp: PendingOperation = {
                        var frozen = op
                        frozen.messageIds = provenMembers
                        return frozen
                    }()
                    let result = try await retryWrite(dbPool, label: "Queue") { db in
                        try Self.commitPartialRetirement(
                            frozenRetiredOp, remaining: remaining,
                            provenDestinations: provenDestinations,
                            addressChangesOnMove: addressChangesOnMove, db: db)
                    }
                    pendingRetirements.removeValue(forKey: opId)
                    queueLog(
                        "[Queue] retirement replay — committed the retained narrowing of "
                            + "\(opId.prefix(8)) \(op.type.rawValue): "
                            + "\(provenMembers.count) proven member(s) retired, "
                            + "\(remaining.count) still owed")
                    logReaddressedFollowers(result, retiring: frozenRetiredOp)
                    await publishMoveFinish(result)
                    await retireConfirmedGoneMemberHeaders(
                        op, memberIds: confirmedGoneMembers)
                    await materializeDeferredMoveSuccessors(
                        after: frozenRetiredOp, result: result)
                    if [.archive, .delete, .move].contains(op.type), let dest = op.destinationPath {
                        context.foldersToSync.insert("\(op.accountId)|\(dest)")
                        // The live narrowing path records the members that
                        // entered an inbox, so its own replay owes the same
                        // event on the same frozen membership. A live path that
                        // disagrees with its own replay is the defect, not the
                        // extra call (`MIS-IOS-023`).
                        if op.type == .move, dest != op.folderPath {
                            await recordMembersThatEnteredInbox(
                                frozenRetiredOp, destinationPath: dest, context: context)
                        }
                    }
                }
            } catch {
                queueLog(
                    "[Queue] retirement replay — \(opId.prefix(8)) still cannot commit: \(error); "
                        + "the provider's proven result is retained and this drain stops")
                return false
            }
        }
        return true
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
    private func requeueOrRetain(_ id: String, incrementRetryCount: Bool = false) async {
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
    /// `replayRetainedRetirements` does: the work is entirely LOCAL, and making
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
    /// 🚨 ITS ONLY CALLER IS `replayRetainedRetirements`, and that is a property
    /// of the executor rather than an accident. The drain used to claim a row and
    /// then re-read it before sending, so a stale snapshot could not reach the
    /// wire; `claimFrontierOperation` now reads the live front row INSIDE the
    /// claim transaction, so there is no window between the read and the claim
    /// for anything to go stale in. What remains is the replay's existence
    /// check, whose two outcomes are exactly the two this function distinguishes
    /// — and that is also why there is deliberately no `?? capturedOp`
    /// fallback: a row that is gone is the user's newer decision, never a value
    /// to substitute for.
    private func liveOperation(_ id: String) async throws -> PendingOperation? {
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
                        await logStuckOpDiagnostic(currentOp, error: ProviderError.messageNotFound)
                    }
                    guard await deferRelatedChainToTail(
                        failing: currentOp, incrementRetryCount: true, context: context)
                    else { return .stopDrain }
                    return .deferred
                }
                return await retirePartiallyCompletedOp(
                    currentOp, provenMembers: provenMembers, remaining: remaining,
                    provenDestinations: executed.provenDestinations,
                    addressChangesOnMove: executed.addressChangesOnMove,
                    confirmedGoneMembers: executed.confirmedGoneMembers,
                    context: context)
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
                    try Self.commitFullRetirement(currentOp, executed: executed, db: db)
                }
                logReaddressedFollowers(finishResult, retiring: currentOp)
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
                // (`replayRetainedRetirements`), and THE WHOLE DRAIN STOPS so
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
                // drain is `replayRetainedRetirements`, so the stop is what
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
                pendingRetirements[currentOp.id] = .full(op: currentOp, executed: executed)
                print("[Queue] CRITICAL: Failed to retire completed PendingOperation \(currentOp.id) after retries — the row stays inFlight and the provider's proven result is retained for replay at the next drain")
                BackgroundSyncLogger.logError(
                    "CRITICAL: failed to retire completed PendingOperation \(currentOp.id) (type \(opType)) after retries — the row stays inFlight, so it will NOT re-execute, and the provider's proven result is retained in memory and replayed at the next drain; a process death before that replay is the accepted crash window (TabMail/tabmail-ios#120): \(error)",
                    source: "actionQueue")
                return .stopDrain
            }
            await publishMoveFinish(finishResult)
            // 🚨 THE MEMBERS THE SERVER SAID ARE GONE, RETIRED LOCALLY TOO — the
            // same disposition the single-message conflict arm below has always
            // applied, now reachable for a member of a BATCH.
            //
            // It is the batch split's cleanup half, relocated. That arm re-shaped
            // the row into one operation per member; each child then 404'd on its
            // own and took the single-message arm, which deletes the confirmed-gone
            // header. With the split gone, the provider names the member directly
            // and the deletion happens here, one drain earlier and without ever
            // creating a replacement row.
            //
            // Runs AFTER the retirement commit, deliberately: the header row is a
            // different table and its deletion releases FTS and body content, so
            // it must not be able to precede the operation's own retirement.
            //
            // ⚠ ALL FOUR RETIREMENT SITES DO THIS, AND THAT SYMMETRY IS THE
            // POINT (GPT consult finding 2/3, 2026-09-06). A confirmed-gone
            // member is retired by whichever path commits — whole-op success,
            // the narrowing path, or either of their retained replays — and the
            // header cleanup has to follow the member, not the path. The first
            // version of this change put the loop here only, so a retirement
            // that failed its local write and replayed at the next drain, or a
            // bundle with a transiently-failing sibling that took the narrowing
            // path, retired the queue row and left the ghost header behind.
            await retireConfirmedGoneMemberHeaders(currentOp, memberIds: executed.confirmedGoneMembers)
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
            return .proceed
        } catch {
            // T2.7 checkpoint B refusal is typed and precedes the generic
            // message-not-found arm. The epoch scopes the whole
            // provider-address bundle, so no member may be dispositioned
            // separately under a different attempt.
            if case ProviderError.uidValidityChanged = error {
                do {
                    try await retryWrite(dbPool, label: "Queue") { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                    dropDeferredMoveSuccessors(for: currentOp.id)
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
                    await requeueOrRetain(currentOp.id)
                    return .stopDrain
                }
            }
            if isMessageNotFoundError(error) {
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
                        await logStuckOpDiagnostic(currentOp, error: error)
                    }
                    guard await deferRelatedChainToTail(
                        failing: currentOp, incrementRetryCount: true, context: context)
                    else { return .stopDrain }
                    return .deferred
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
                try? await retryWrite(dbPool, label: "Queue") { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                dropDeferredMoveSuccessors(for: currentOp.id)
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
            //    names a message this one names is in its `buildLanes` connected
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
                    await logStuckOpDiagnostic(currentOp, error: error)
                }
                guard await deferRelatedChainToTail(
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
            guard await deferRelatedChainToTail(
                failing: currentOp, incrementRetryCount: true, context: context)
            else {
                context.failedAccounts.insert(currentOp.accountId)
                return .stopDrain
            }
            context.failedAccounts.insert(currentOp.accountId)
            return .deferred
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
    @discardableResult
    func retirePartiallyCompletedOp(
        _ currentOp: PendingOperation,
        provenMembers: [String],
        remaining: [String],
        provenDestinations: [ProvenDestinationAddress],
        addressChangesOnMove: Bool,
        confirmedGoneMembers: [String] = [],
        context: DrainContext
    ) async -> SingleOpOutcome {
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
                try Self.commitPartialRetirement(
                    frozenRetiredOp, remaining: remaining,
                    provenDestinations: provenDestinations,
                    addressChangesOnMove: addressChangesOnMove, db: db)
            }
            logReaddressedFollowers(finishResult, retiring: frozenRetiredOp)
            await publishMoveFinish(finishResult)
            // 🚨 THE NARROWING PATH RETIRES CONFIRMED-GONE MEMBERS TOO (GPT
            // consult finding 3, 2026-09-06). Before per-member absence moved to
            // the provider boundary, a partial outcome could only be a proven
            // PREFIX — every retired member had actually been mutated, and none
            // of them was gone, so there was no header to clean up and this site
            // correctly had none. It can now retire a member the server reported
            // ABSENT alongside a sibling that moved and another that failed
            // transiently, which is a shape that did not previously exist.
            //
            // ⚠️ THE FILTER IS A NO-OP AGAINST TODAY'S PRODUCERS, and saying so
            // is more useful than the "not defensive decoration" claim that used
            // to stand here. All three producers already guarantee the subset
            // relation: `executeOperation`'s chokepoint forwards
            // `ProviderMembersDispositioned.absentMemberIds`, which
            // `GmailProvider.modifyEachMessage` and
            // `ExchangeProvider.patchEachMessage` build from the SAME single
            // member they name as dispositioned; `ExchangeProvider
            // .moveProvingDestinations` reports `confirmedGoneIds` only for the
            // id it also proved; and `IMAPProvider.move` never populates the
            // field. It is kept for the producer that does not exist yet — only a
            // member that actually left the row here may lose its header, and
            // this is the one place that stays true when a fourth producer
            // arrives.
            await retireConfirmedGoneMemberHeaders(
                currentOp, memberIds: confirmedGoneMembers.filter(provenMembers.contains))
            // 🚨 DO NOT DELETE THIS BECAUSE NO PROVIDER REACHES IT TODAY.
            // It was deleted once, silently, by the edit that inserted the call
            // above it, and nothing caught it: a `DeferredMoveSuccessor` is only
            // registered against an IMAP predecessor, and `IMAPProvider.move`
            // returns `provenIds == ids` at every return site, so IMAP cannot
            // enter this narrowing path and the successor map is empty here for
            // every provider that can. That is a property of TODAY's providers,
            // not of this contract: the moment any move returns a strict subset
            // — which is exactly the shape the rest of this function exists to
            // handle — the omission becomes a DROPPED USER INTENTION. The
            // opposite move the user already gestured stays in
            // `deferredMoveSuccessors` forever, its overlay entry is never
            // released, and `coalesceDeferredMoves` folds every later gesture on
            // that message into a successor that will never materialise
            // (`MIS-IOS-008` / `IOS-QUEUE-008`). The other three retirement sites
            // — whole-op success and both retained replays — all call this
            // immediately after `retireConfirmedGoneMemberHeaders`, and the
            // narrowing path's own replay in `replayRetainedRetirements` still
            // does; a live path that disagrees with its own replay is the defect,
            // not the dead code. Reachability is covered by
            // `narrowedRetirementMaterializesTheDeferredInverseItsPredecessorOwes`.
            await materializeDeferredMoveSuccessors(after: frozenRetiredOp, result: finishResult)
            // ADR-IOS-008 decision 3's third event — "message moved to inbox" —
            // for the members THIS path proved. It is the same block the whole-op
            // success arm and the `.full` replay already run, and it belongs here
            // for the same reason `materializeDeferredMoveSuccessors` does: a
            // member proven by NARROWING owes exactly what a member proven whole
            // owes. Without it a multi-member move into the Inbox gives the event
            // only to the LAST member — the one that happens to settle through the
            // whole-op arm — and `ActiveAIQueue.repopulateFromDatabase` cannot
            // substitute, because `repopulationCandidates` is bounded in SQL to
            // the newest `SyncConfig.maxRecentEmails` Inbox rows, which is exactly
            // the bound this window-EXEMPT enqueue exists to escape (ADR-IOS-078,
            // `IOS-AI-007`).
            //
            // 🚨 `frozenRetiredOp`, NEVER `currentOp`. `optimisticMoveToFolder`
            // already moved ALL N header rows to the destination locally, so the
            // helper's `header.folderPath == destinationPath` guard passes for
            // members the server has not moved yet. Naming the whole bundle here
            // would enqueue AI for members still owed — the mirror image of the
            // miss this closes.
            //
            // 🚨 IT RUNS ONLY AFTER THE COMMIT, and that is a property of
            // CONTROL FLOW rather than of any guard inside the helper: the first
            // statement of this `do` is the retirement write, so a commit that
            // fails throws straight past this line into the `catch`. The helper
            // also resolves through
            // `MessageHeaderRekey.currentHeaderId(afterHandoffFrom:)`, whose
            // aliases are published by `db.afterNextTransaction` and so exist
            // only once that write commits. ⚠️ DO NOT MOVE THIS INTO THE TAIL
            // BLOCK BELOW where the `foldersToSync` insert lives — that block
            // runs on the retention path too, and recording there would publish
            // an inbox-entry event for a retirement that never landed. The
            // whole-op arm is shaped the same way (it returns from its catch
            // before recording), and the retained result is what carries the
            // event instead, through `replayRetainedRetirements`' `.partial` arm.
            if currentOp.type == .move, let dest = currentOp.destinationPath,
               dest != currentOp.folderPath {
                await recordMembersThatEnteredInbox(
                    frozenRetiredOp, destinationPath: dest, context: context)
            }
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
            // retained result at the next drain (`replayRetainedRetirements`,
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
            pendingRetirements[currentOp.id] = .partial(
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
            // `replayRetainedRetirements`, which is the recovery this stop
            // sequences.
            return .stopDrain
        }
        if [.archive, .delete, .move].contains(currentOp.type), let dest = currentOp.destinationPath {
            context.foldersToSync.insert("\(currentOp.accountId)|\(dest)")
        }
        return .proceed
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
    private func retireConfirmedGoneMemberHeaders(
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
        do {
            return try await dispatchOperation(op, provider: provider)
        } catch let report as ProviderMembersDispositioned {
            // 🚨 THE ONLY PLACE `ProviderMembersDispositioned` IS UNDERSTOOD, AND
            // IT IS A COMPLETION REPORT, NOT A FAILURE.
            //
            // A provider's per-member loop settled the members it names — mutated
            // or authoritatively gone — and says NOTHING about any member after
            // them. Those settled members are exactly `provenMembers`, so a report
            // naming the whole request takes the ordinary whole-op retirement and
            // a report naming a PREFIX takes `retirePartiallyCompletedOp`: the
            // same durable row, narrowed to the members still owed, with its id,
            // its order and its position untouched. What is carried forward on top
            // is the ATTRIBUTION the `Void`-returning action protocol cannot
            // express: WHICH of them were gone, so the drain can retire their
            // confirmed-gone local headers.
            //
            // 🚨 A PREFIX IS THE ORDINARY REPORT, NOT AN EXCEPTIONAL STOP.
            // There is no elapsed-time budget on these loops any more, so nothing
            // here depends on one running out. `GmailProvider.modifyEachMessage`
            // and `ExchangeProvider.patchEachMessage` address exactly ONE id per
            // attempt and then raise this report whenever `ids.count != 1`, so
            // `dispositionedMemberIds` is a ONE-ELEMENT proper prefix on the FIRST
            // attempt of every multi-member Gmail or Graph operation. The
            // narrowing conversion is therefore the COMMON path for that traffic,
            // not a contingency — scope anything downstream of it accordingly.
            // A report names the whole request only when the request named a
            // single member.
            //
            // WHY ONE MEMBER PER ATTEMPT, which is what makes the prefix routine
            // (`MIS-IOS-022`, twice). `withTimeout` resumes this caller with
            // `TimeoutError` and cancels the operation task second, so anything a
            // loop is still holding at the deadline is discarded with the
            // abandoned task, the row is requeued whole, and every retry repeats
            // the same prefix into the same deadline — the final member never
            // reaches the provider. A margin measured in ELAPSED TIME cannot close
            // that: it bounds what an attempt has already spent and nothing bounds
            // the duration of the request it is about to start, so members that
            // each fit the deadline still straddle it two at a time. Bounding an
            // attempt to ONE request makes its exposure equal to the quantity the
            // deadline actually bounds, and narrowing on the reported prefix is
            // what turns the starvation into strict per-attempt progress.
            //
            // ⚠ IT MUST NOT ESCAPE TO `executeSingleOp`. Out there it would be an
            // unclassified error, land in the generic transient arm, requeue an
            // operation whose work is finished, and poison the account for the
            // rest of the drain. The conversion is here — one wrapper around the
            // whole dispatch — rather than repeated in each arm, so a new arm
            // cannot forget it.
            //
            // ⚠ NO DESTINATION EVIDENCE, EVER, ON THIS PATH. An absent member
            // landed nowhere; `provenDestinations` stays empty and
            // `addressChangesOnMove` stays false, so nothing is re-keyed to an
            // address no server named. Graph's move arm does NOT come through
            // here — it returns its outcome rather than throwing, precisely
            // because it has destinations to report for the members that DID
            // move.
            queueLog("[Queue] \(op.type.rawValue) (\(op.messageIds.count) msgs): provider settled \(report.dispositionedMemberIds.count) member(s), \(report.absentMemberIds.count) of them confirmed gone by the server — those members' local headers are retired and any member the loop did not reach stays owed under the same operation")
            return ExecutedOperation(
                provenMembers: report.dispositionedMemberIds,
                provenDestinations: [],
                confirmedGoneMembers: report.absentMemberIds)
        }
    }

    /// The op-type switch `executeOperation` wraps. Split out for exactly one
    /// reason: `ProviderMembersDispositioned` must be converted in ONE place
    /// rather than in every arm that can raise it.
    private func dispatchOperation(_ op: PendingOperation, provider: any EmailProvider) async throws -> ExecutedOperation {
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
                    reconcileMoveSource: outcome.requiresSourceReconciliation,
                    confirmedGoneMembers: outcome.confirmedGoneIds)
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
                    addressChangesOnMove: true,
                    confirmedGoneMembers: outcome.confirmedGoneIds)
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

    /// The post-connect queue kick: drain whatever the durable action queue
    /// still owes, then run the outbox and calendar-queue reconcilers.
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
        await reconcileCalendarQueue()
    }
}
