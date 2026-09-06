/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

enum OperationType: String, Codable, Sendable {
    case archive
    case delete
    case move
    case markRead
    case markUnread
    case markFlagged
    case markUnflagged
    case setTag
    case removeTag
    case markReplied
    case markForwarded
    case saveDraft
    case deleteDraft
    case addUserLabel
    case removeUserLabel
}

enum PendingStatus: String, Codable, Sendable {
    case queued
    case inFlight
    case cancelled
    /// TERMINAL, and used only by `pendingCalendarOperation` today (R16-1).
    ///
    /// A calendar operation that a terminal arm retires is moved HERE instead of
    /// being deleted, so the failure survives the disappearance of the in-memory
    /// awaiter that used to be its only report channel. It is not a queue state:
    /// `drainCalendarQueue` fetches `status == queued` only, and
    /// `reconcileCalendarQueue` resets `inFlight` only, so a `failed` row is never
    /// re-executed and can never head-of-line-block an account's lane — which is
    /// the mirror-image defect (`MIS-005`) that keeping terminal failures QUEUED
    /// would have created.
    case failed
}

struct PendingOperation: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "pendingOperation"

    // 🚨 THIS RECORD IS `MutablePersistableRecord`, NOT `PersistableRecord`, AND
    // THE DIFFERENCE IS THE WHOLE QUEUE-POSITION CONTRACT. (Deliberately `//`
    // and not `///`: it documents the CONFORMANCE on the line above, not the
    // property below, and a doc comment here would be read as `id`'s.)
    //
    // `PersistableRecord` re-declares `willInsert(_:)` as NON-mutating, so a
    // record that conforms to it cannot assign one of its own columns from
    // inside the insert. `queuePosition` has to be allocated from the CURRENT
    // MAXIMUM, inside the very transaction that admits the row, so the only
    // callback that can do it is `MutablePersistableRecord`'s mutating
    // `willInsert(_:)` below. Conforming to the mutable protocol makes `insert`
    // and `save` mutating, which is why every admission site holds its record in
    // a `var`; that is the cost of having ONE chokepoint instead of an
    // enumerated list of writers that a future writer can be added outside of.
    //
    // Do not "simplify" this back to `PersistableRecord`: it compiles, and it
    // silently stops allocating positions.

    var id: String
    var type: OperationType
    var messageIdsJSON: String
    var accountId: String
    var folderPath: String
    /// Destination folder for move operations
    var destinationPath: String?
    /// ActionTag rawValue for setTag/removeTag operations
    var tagValue: String?
    /// UserLabel ID for addUserLabel/removeUserLabel operations
    var userLabelId: String?
    var createdAt: Date
    var retryCount: Int
    /// THIS ROW'S CURRENT PLACE IN THE ONE GLOBAL FIFO — durable, explicit, and
    /// the ONLY ordering key the executor reads.
    ///
    /// Allocated after the current maximum inside the SAME write transaction as
    /// admission (`willInsert(_:)`), and rewritten only by a deliberate tail
    /// movement (`appendToTail`). It is not a clock and not a history: it orders
    /// LIVE pending rows and nothing else, so a counter that restarts once the
    /// table empties is harmless.
    ///
    /// 🚨 `createdAt` IS NO LONGER AN ORDERING KEY. It is age only — the stuck-op
    /// diagnostics and the log lines still read it, and nothing else may. Two
    /// rows admitted inside one millisecond, or admitted across a backward clock
    /// step, get strictly increasing positions because the allocation reads the
    /// table rather than the clock.
    ///
    /// 🚨 THERE IS NO ZERO DEFAULT AND NO NULLABLE STATE. The column is
    /// `INTEGER NOT NULL CHECK (queuePosition > 0)`, so a writer that omits it —
    /// including one that bypasses this record with raw SQL — fails its INSERT
    /// loudly instead of silently admitting a row at the head of the queue.
    /// `unallocated` below is the in-memory value a freshly constructed record
    /// carries BEFORE `willInsert(_:)` runs; it can never reach the database.
    var queuePosition: Int
    /// PORT — v2final's explicit persisted proof that provider I/O may have
    /// started. Existing rows are conservatively backfilled true by v78;
    /// newly admitted rows start false and the queue claim flips this true
    /// atomically with `.inFlight`, before any provider call. Undo may only
    /// annihilate an exact move bundle while this remains false.
    var everAttempted: Bool
    /// Dormant compatibility field retained because v67 already shipped this
    /// non-null column. Provider-ID actions no longer run an RFC resolution
    /// retry ladder; no migration rewrite is required.
    var uidResolutionRetryCount: Int = 0
    /// UIDVALIDITY admission stamp — the value of `Folder.lastKnownUidValidity`
    /// for this op's `folderPath` at the instant the op was inserted, read inside
    /// the SAME write transaction as the insert so the stamp and the row observe
    /// one consistent epoch.
    ///
    /// It exists for every IMAP op the executor addresses by a BARE NUMERIC UID.
    /// A UID means nothing outside
    /// the numbering it was observed in — after a UIDVALIDITY change the same
    /// number names a DIFFERENT message — so such an op must not survive into a
    /// numbering it was not recorded under (owner directive, 2026-07-31: *"the
    /// delete op should NOT survive a UIDVALIDITY reset — it cannot; the op
    /// should no-op once that validity gets invalid"*). `AccountManager
    /// .drainPendingQueue`'s claim transaction compares this against the folder's
    /// CURRENT `lastKnownUidValidity` and, on disagreement, deletes the row
    /// without executing it. Dropping intention at an identity-reset boundary is
    /// the blessed resolution (constraint C5): sync reconciles and the user redoes
    /// the gesture — the alternative is mutating an unrelated message (C3).
    ///
    /// `nil` remains correct for stable-provider operations and for typed draft
    /// operations that carry their own identity proof. T2.4 stamps every ordinary
    /// IMAP move/read/unread/flag operation from the source header's proven epoch;
    /// T2.6 fails those ordinary operations closed when the stamp is absent, zero,
    /// or disagrees with the current source Folder. Gmail, Graph, and Demo remain
    /// epochless.
    ///
    /// Typed `Int?` to mirror `Folder.lastKnownUidValidity`'s established storage
    /// convention for this exact value (same choice, same reasoning, as the
    /// reference's `v2final:TabMail/Models/PendingOperation.swift`).
    /// Backed by the v69 migration; `nil` on every pre-migration row.
    var observedUidValidity: Int?
    /// v72 — the UIDVALIDITY epoch `messageIds[0]` was MINTED under, for a
    /// `.deleteDraft` whose slot 0 is a bare IMAP UID. **Not the same datum as
    /// `observedUidValidity` above, and the difference is the whole point.**
    ///
    /// `observedUidValidity` is the folder's epoch AT ADMISSION — it answers "has
    /// the numbering moved since this op was recorded?" and it agrees with itself
    /// by construction, so it can never reveal that the ADDRESS was already stale
    /// when the op was recorded. This column is the epoch the address itself was
    /// born in, carried forward from `Draft.serverDraftUidValidity` through
    /// `OutboxMessage.draftServerUidValidity`. Non-nil therefore means: slot 0 is
    /// a UID that is meaningful in EXACTLY this epoch and no other, and
    /// `IMAPProvider.deleteDraft` may take its STRONG arm — compare the live
    /// SELECT's UIDVALIDITY against it and fail closed on any disagreement.
    ///
    /// nil means UNKNOWN — never "current", never zero — and an IMAP `.deleteDraft`
    /// with a nil epoch cannot be addressed at all, so `AccountManagerQueue`'s
    /// `.deleteDraft` arm throws `actionIdentityResolutionFailed` rather than
    /// issuing anything.
    ///
    /// ⚠️ CORRECTED 2026-08-06 (R12-T4): this line used to annotate that throw
    /// **"(retryable)"**. It is not. The drain's
    /// `.actionIdentityResolutionFailed` arm is a TERMINAL DROP — it logs
    /// `"TERMINAL DROP: identity refused…"` and executes
    /// `PendingOperation.deleteOne`, per `KNOWN_ISSUES.md` `IOS-QUEUE-003` item 4,
    /// which accepts that cost expressly because the loss is bounded and visible.
    /// `EmailProvider`'s declaration of the case states the same thing
    /// (*"DETERMINISTIC and PRE-WIRE… The drain terminalizes it instead"*). Two
    /// production comments claiming opposite dispositions for one error is how a
    /// later fix comes to route a SECOND op class into an arm believing it
    /// requeues; do not reintroduce the annotation. Stamped only when slot 0 is
    /// numeric: a non-numeric
    /// slot 0 is a Gmail/Graph resource id, which is stable and epoch-free, and an
    /// epoch beside it would be an asymmetric identity the provider refuses outright.
    ///
    /// ⚠️ CORRECTED 2026-08-06. This used to say the strong arm goes on to "FETCH
    /// that UID and corroborate its Message-ID", and that a nil epoch "keeps the op
    /// on the unchanged Message-ID-search arm". v3 has neither: `deleteDraft
    /// (identity:)` accepts only `.imap(folder, uidValidity, uid)` and
    /// `deleteDraftStrong`'s doc records that it omits RFC corroboration "because
    /// v3's typed identity has no RFC leg". The two live `searchByMessageId` callers
    /// (`currentUIDs`, `appendToSentFolder`) are both NON-MUTATING. A Message-ID
    /// search that selects a delete target is the banned D4 direction (ADR-IOS-068),
    /// so a doc comment describing one is an instruction to reintroduce it.
    ///
    /// ⚑ The reference (`v2final`) carries this as positional slot 2 of
    /// `messageIds` with a typed decoder. A TYPED COLUMN is used here instead
    /// because v3's stale sweep builds its protection set as
    /// `Set(opsTargetingThisFolder.flatMap(\.messageIds))` — every slot value,
    /// including the reference's empty-string placeholders, becomes an id that
    /// can protect an unrelated header that happens to match it.
    var draftServerUidValidity: Int?
    /// Generation and local owner for draft save/delete operations.
    var instanceEpoch: String?
    var draftId: String?
    /// Namespace discriminator for persisted provider-native delete addresses.
    var draftDeleteAddressKind: String?
    /// PendingStatus rawValue — stored as String for GRDB compatibility
    var status: String

    /// Decoded message IDs from JSON storage
    var messageIds: [String] {
        get {
            guard let data = messageIdsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            messageIdsJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    init(
        type: OperationType,
        messageIds: [String],
        accountId: String,
        folderPath: String,
        destinationPath: String? = nil,
        tagValue: String? = nil,
        userLabelId: String? = nil,
        observedUidValidity: Int? = nil,
        draftServerUidValidity: Int? = nil,
        instanceEpoch: String? = nil,
        draftId: String? = nil,
        draftDeleteAddressKind: DraftDeleteAddressKind? = nil
    ) {
        self.id = UUID().uuidString
        self.type = type
        self.messageIdsJSON = (try? String(data: JSONEncoder().encode(messageIds), encoding: .utf8)) ?? "[]"
        self.accountId = accountId
        self.folderPath = folderPath
        self.destinationPath = destinationPath
        self.tagValue = tagValue
        self.userLabelId = userLabelId
        self.createdAt = Date()
        self.retryCount = 0
        // Replaced by `willInsert(_:)` with a real position, from the table's
        // current maximum, inside the admitting transaction. It is deliberately
        // a value the schema REFUSES, so a row that somehow reached the database
        // without that callback running would fail its INSERT rather than land
        // at the head of the queue.
        self.queuePosition = Self.unallocatedQueuePosition
        self.everAttempted = false
        self.uidResolutionRetryCount = 0
        self.observedUidValidity = observedUidValidity
        self.draftServerUidValidity = draftServerUidValidity
        self.instanceEpoch = instanceEpoch
        self.draftId = draftId
        self.draftDeleteAddressKind = draftDeleteAddressKind?.rawValue
        self.status = PendingStatus.queued.rawValue
    }

    // MARK: - Queue position

    /// The in-memory value a constructed-but-not-yet-inserted record carries.
    /// The schema's `CHECK (queuePosition > 0)` refuses it, deliberately.
    static let unallocatedQueuePosition = 0

    /// THE ONE CHOKEPOINT for typed admissions. Every route that constructs a
    /// `PendingOperation` and inserts it — gestures, sync-engine tag producers,
    /// the outbox, the cold-notification path, the undo inverse — passes through
    /// here without knowing it exists, so a writer added later cannot forget to
    /// allocate.
    ///
    /// It reads the table's current maximum and adds one, INSIDE the caller's
    /// write transaction. GRDB serializes writers, so within that transaction
    /// the maximum cannot move under us: appending a chain of N records in one
    /// transaction therefore yields a contiguous increasing range in the order
    /// they were inserted, which is the order the gesture issued them in.
    ///
    /// It ALWAYS overwrites, and never honours a value the caller pre-set. A
    /// preset position would be a second way to decide queue order, and the
    /// whole point of this callback is that there is exactly one.
    mutating func willInsert(_ db: Database) throws {
        queuePosition = try Self.nextQueuePosition(db)
    }

    /// NON-MUTATING INSERT, for call sites that cannot hold a `var`.
    ///
    /// `insert` is `mutating` because `willInsert` writes the allocated
    /// position back into the record, and that is exactly what makes the
    /// allocation a chokepoint. It also makes `insert` unusable on a `let`, on a
    /// function parameter, and on a value captured by a `@Sendable` write
    /// closure — the last of which is the ordinary shape here, because a GRDB
    /// write closure is `@Sendable` and mutating a captured `var` inside one is
    /// a concurrency error rather than a style choice.
    ///
    /// It inserts a COPY and hands the copy back, so a caller that needs the
    /// allocated position reads it from the return value. It is not a second
    /// admission path: the copy goes through the same `insert`, so the same
    /// `willInsert` allocates, and a writer cannot use this to skip allocation.
    @discardableResult
    func inserted(_ db: Database) throws -> PendingOperation {
        var copy = self
        try copy.insert(db)
        return copy
    }

    /// `MAX(queuePosition) + 1`, or 1 for an empty table.
    ///
    /// Resetting to 1 once the table empties is harmless and deliberate: the
    /// column orders LIVE pending rows only, and there are none to be ordered
    /// against. It is not a clock, so nothing compares a position across that
    /// boundary. Backed by the `pendingOperation_queuePosition` index, so this
    /// is an index lookup rather than a table scan.
    static func nextQueuePosition(_ db: Database) throws -> Int {
        let maximum = try Int.fetchOne(
            db, sql: "SELECT MAX(queuePosition) FROM pendingOperation") ?? 0
        return max(maximum, 0) + 1
    }

    /// MOVE `ids` TO THE TAIL, IN THEIR GIVEN ORDER, IN ONE WRITE.
    ///
    /// This is the durable half of related-chain deferral: the failed row and
    /// every pending row transitively related to it are appended together, so
    /// unrelated mail moves ahead of them while their own relative order is
    /// preserved exactly. `ids` MUST already be in the order the caller wants
    /// them to keep — the caller reads them under the current ordering inside
    /// this same transaction.
    ///
    /// 🚨 IT WRITES POSITION, STATUS AND (FOR ONE ROW) THE RETRY COUNTER, AND
    /// NOTHING ELSE. Ids, payloads, `messageIdsJSON`, epochs, `createdAt` and
    /// `everAttempted` are untouched, for `markQueued`'s reason and one more of
    /// its own: a struct-shaped `save` would write back a snapshot taken before
    /// the retirement that may have just re-addressed a follower
    /// (`MessageHeaderRekey.readdressQueuedOperations`), and a deferral must
    /// never undo an address the wire proved.
    ///
    /// 🚨 IT CANNOT RESURRECT A ROW. Every statement is an `UPDATE … WHERE id`,
    /// so an id that undo, a cancel or an account deletion removed while the
    /// provider call was outstanding simply matches nothing. That is the normal,
    /// correct outcome and is not an error.
    ///
    /// `chargeRetryTo` is the ONE row that actually made a provider attempt.
    /// Followers deferred behind it were never attempted and must not age toward
    /// anything, so they are moved without a retry charge.
    static func appendToTail(
        _ db: Database, ids: [String], chargeRetryTo: String? = nil
    ) throws {
        guard !ids.isEmpty else { return }
        var next = try nextQueuePosition(db)
        for id in ids {
            if id == chargeRetryTo {
                try db.execute(
                    sql: """
                        UPDATE pendingOperation
                        SET queuePosition = ?, status = ?, retryCount = retryCount + 1
                        WHERE id = ?
                        """,
                    arguments: [next, PendingStatus.queued.rawValue, id])
            } else {
                try db.execute(
                    sql: """
                        UPDATE pendingOperation
                        SET queuePosition = ?, status = ?
                        WHERE id = ?
                        """,
                    arguments: [next, PendingStatus.queued.rawValue, id])
            }
            next += 1
        }
    }

    enum SaveDraftSlots {
        static let draftId = 0
    }

    /// PORT — exact injective generation-bearing placeholder shape from
    /// v2final `PendingOperation.draftPlaceholderMessageId`.
    static func draftPlaceholderMessageId(draftId: String, instanceEpoch: String?) -> String {
        let bare = "draft-\(MessageIdentity.colonSafeMessageIdComponent(draftId))"
        guard let instanceEpoch, !instanceEpoch.isEmpty else { return bare }
        return "\(bare):\(instanceEpoch):\(instanceEpoch.utf8.count)"
    }

    static func draftPlaceholderHeaderPK(
        accountId: String,
        draftsFolderPath: String,
        draftId: String,
        instanceEpoch: String?
    ) -> String {
        "\(accountId):\(draftsFolderPath):\(draftPlaceholderMessageId(draftId: draftId, instanceEpoch: instanceEpoch))"
    }

    /// Return a claimed row to `queued` by writing ONLY the two columns the
    /// requeue actually decides, addressed by primary key.
    ///
    /// 🚨 WHY THIS IS NOT `var updated = op; updated.status = …; try updated.save(db)`.
    /// A `save` is an UPDATE of EVERY column from the in-memory struct, and the
    /// struct the requeue holds was read BEFORE the provider call that failed.
    /// Since `MessageHeaderRekey.readdressQueuedOperations` rewrites a queued
    /// operation's `messageIdsJSON` inside the transaction that retires an
    /// earlier move (`IOS-GRAPH-005`), a struct-shaped requeue would write the
    /// pre-handoff ids back over the addresses the wire had just proved, and the
    /// operation would go out at a dead id on the next drain. That is the
    /// "identity resolved before an `await` is not a fact after it" trap: the
    /// requeue's DECISION (status, and whether this attempt counts as a retry) is
    /// the only thing it observed, so it is the only thing it may write. The same
    /// reasoning is why `appendToTail` writes `queuePosition`/`status`/`retryCount`
    /// and never `messageIds`.
    ///
    /// `incrementRetryCount` is computed by SQL rather than from the snapshot for
    /// the same reason — `retryCount + 1` cannot regress a count another writer
    /// advanced. A row deleted since the claim (cancel/annihilation) simply
    /// matches nothing; that is not an error, and the caller does not need to know.
    ///
    /// Callers that fetch and save inside ONE transaction
    /// (`AppDatabase.recoverPreviousSessionResidue` — named
    /// `reconcilePendingOperations` until 2026-09-05, when the sweep moved to the
    /// launch boundary — `claimFrontierOperation`, `retirePartiallyCompletedOp`'s
    /// narrowing) are NOT this case
    /// and are deliberately left alone: their struct is read in the same
    /// transaction that writes it, so it cannot be stale.
    static func markQueued(
        _ db: Database, id: String, incrementRetryCount: Bool = false
    ) throws {
        if incrementRetryCount {
            try db.execute(
                sql: """
                    UPDATE pendingOperation
                    SET status = ?, retryCount = retryCount + 1
                    WHERE id = ?
                    """,
                arguments: [PendingStatus.queued.rawValue, id])
        } else {
            try db.execute(
                sql: "UPDATE pendingOperation SET status = ? WHERE id = ?",
                arguments: [PendingStatus.queued.rawValue, id])
        }
    }

    /// Requeue a row ONLY IF THIS PROCESS STILL HOLDS IT — the guarded sibling
    /// of `markQueued`, for the retained-retirement replay.
    ///
    /// 🚨 THE `status = 'inFlight'` PREDICATE IS THE WHOLE POINT, and it is why
    /// this is a separate function rather than a parameter on `markQueued`. The
    /// replay runs an unbounded time after the claim that recorded the suffix —
    /// the database was refusing writes in between — so by the time it commits,
    /// the row may have been cancelled by the user, deleted by a local wipe or
    /// already requeued by the halt site's best-effort loop. Only `inFlight`
    /// means "still claimed by this process and never executed"; every other
    /// state is somebody else's newer decision and must be left exactly as it
    /// is. Matching zero rows is the normal, correct outcome and is NOT an
    /// error — the caller does not need to know.
    ///
    /// The retry charge is the CALLER's, and it defaults to none. The
    /// retained-retirement suffix passes nothing, deliberately: a refused local
    /// transaction says nothing about the provider, and the suffix was never
    /// attempted on the wire at all. But this function is also the recovery
    /// write for a requeue that was itself refused (`recoverPendingRequeues`),
    /// and there the charge belongs to the ORIGINAL site — an evidence-refused
    /// or transient-error requeue charges `retryCount + 1`, and a recovery that
    /// silently dropped that charge would leave the runaway-retry case invisible
    /// again. So the parameter mirrors `markQueued`'s exactly, the guarded
    /// `WHERE status = 'inFlight'` predicate above is kept for both, and neither
    /// contract is widened into the other.
    ///
    /// Status (and at most the counter) is all this writes — the same reasoning
    /// as `markQueued`'s banner, for the same reason: a struct-shaped `save`
    /// would write back `messageIdsJSON` that a retirement may have just
    /// re-addressed.
    static func requeueIfInFlight(
        _ db: Database, id: String, incrementRetryCount: Bool = false
    ) throws {
        if incrementRetryCount {
            try db.execute(
                sql: """
                    UPDATE pendingOperation
                    SET status = ?, retryCount = retryCount + 1
                    WHERE id = ? AND status = ?
                    """,
                arguments: [PendingStatus.queued.rawValue, id, PendingStatus.inFlight.rawValue])
        } else {
            try db.execute(
                sql: "UPDATE pendingOperation SET status = ? WHERE id = ? AND status = ?",
                arguments: [PendingStatus.queued.rawValue, id, PendingStatus.inFlight.rawValue])
        }
    }
}

// MARK: - Sync Filter Snapshot
//
// 🚨 THIS BLOCK USED TO SAY pending-op ids queued by `AccountManagerActions` are
// `MessageHeader.stableId` — rfc822 for IMAP. THAT IS NO LONGER TRUE, and the
// correction matters because the conclusion (a two-key check) survives while its
// stated reason does not. Invalidated in-range by `6ad327df9` and `065a827ca`;
// corrected 2026-08-05 after round-5 audit finding `A3-R5-01`.
//
// WHAT THE PRODUCERS ACTUALLY KEY BY TODAY:
//
// * **Ordinary actions** (archive / delete / move / flag, and the user-label and
//   outbox reply-flag producers routed through the same helper) key by the
//   provider's NATIVE address. `AccountManager.admittedOrdinaryActionTargets`
//   returns `admitted.map(\.messageId)`, and on IMAP it only admits a member whose
//   `messageId` is a bare canonical UID (`let uid = UInt32(message.messageId),
//   uid > 0, message.messageId == String(uid)`). So on IMAP these keys are UIDs,
//   NOT rfc822 Message-IDs.
// * **`.setTag`** still enqueues `MessageHeader.stableId` — which IS rfc822 on
//   IMAP when the UID is numeric. Those producers live in the SYNC ENGINES and the
//   outbox, not in `AccountManagerActions`: `SyncEngine.swift`,
//   `SyncEngineDeltaSync.swift` (×2), `SyncEngineFullSync.swift` (×2),
//   `SyncEngineBackfillDeep.swift`, `ReplyParentResolver.swift`, and
//   `AccountManagerOutbox.swift` — every one of them passes `…stableId`.
//
// ⚠️ SO THE TWO-KEY CHECK IS STILL REQUIRED — FOR THE `.setTag` PRODUCERS, NOT FOR
// THE ORDINARY ONES. Server-returned `MessageHeaderInfo` carries `messageId` plus
// an optional `rfc822MessageId`. A one-key check against `info.messageId` would
// stop matching every IMAP `.setTag` op (whose key is rfc822); a one-key check
// against rfc822 would stop matching every IMAP ordinary op (whose key is the UID)
// AND every op queued before the server assigned a Message-ID. Both single-key
// simplifications silently disarm the filter for one whole producer family, and
// the failure is invisible: the op stays queued, and sync overwrites the flags,
// tags or rows the user just acted on.
//
// Every sync path (Gmail delta, Exchange delta, IMAP fullSync, BackfillDeep) must
// use the same snapshot so the filter can't drift between them. Registered
// precedent for the stale-comment class: `IOS-QUEUE-004`.

/// Snapshot of pending operation IDs for the sync filter. Always load INSIDE
/// a write transaction — a separate read creates a TOCTOU window where a user
/// action inserts a `PendingOperation` between the snapshot and the sync write,
/// leading to UNIQUE constraint violations or silent undo.
struct PendingOperationSnapshot: Sendable {
    /// IDs from `.archive`, `.delete`, `.move` ops. Used to skip inserting a
    /// message into a folder the user is optimistically moving out of.
    let destructive: Set<String>
    /// IDs from flag/tag ops (`.markRead`, `.markUnread`, `.markFlagged`,
    /// `.markUnflagged`, `.setTag`, `.removeTag`). Used to skip overwriting
    /// flags/tags the user just toggled.
    let flag: Set<String>
    /// IDs from all queued ops (any type). Used to skip deletions of rows the
    /// user has any pending action against.
    let all: Set<String>

    static let destructiveTypes: Set<OperationType> = [.archive, .delete, .move]
    static let flagTypes: Set<OperationType> = [
        .markRead, .markUnread, .markFlagged, .markUnflagged, .setTag, .removeTag
    ]

    /// Build from a pre-fetched list of ops. Callers load ops once inside the
    /// write transaction and pass them here so the filter classification is
    /// the only work duplicated — not the DB query.
    init(ops: [PendingOperation]) {
        var destructive = Set<String>()
        var flag = Set<String>()
        var all = Set<String>()
        for op in ops {
            let ids = op.messageIds
            all.formUnion(ids)
            if Self.destructiveTypes.contains(op.type) { destructive.formUnion(ids) }
            if Self.flagTypes.contains(op.type) { flag.formUnion(ids) }
        }
        self.destructive = destructive
        self.flag = flag
        self.all = all
    }

    /// Load all pending ops for an account inside the current write transaction.
    /// Delta sync paths use this scope — Gmail IDs are globally unique across
    /// folders and Exchange uses folder IDs as routing info on the item.
    static func load(accountId: String, db: Database) throws -> PendingOperationSnapshot {
        let ops = try PendingOperation
            .filter(Column("accountId") == accountId)
            .fetchAll(db)
        return PendingOperationSnapshot(ops: ops)
    }
}

extension Set where Element == String {
    /// Two-key membership check for sync filters. Returns true if this set
    /// contains either `messageId` or a non-empty `rfc822MessageId`.
    ///
    /// ⚠️ REQUIRED BECAUSE THE QUEUE HAS **TWO** KEYING SCHEMES IN IT AT ONCE, not
    /// because pending ops are uniformly `stableId` — that older reason is stale
    /// (see the `Sync Filter Snapshot` banner above). Ordinary actions key by the
    /// provider's native address, which on IMAP is a bare canonical UID; `.setTag`,
    /// produced in the sync engines and the outbox, still keys by
    /// `MessageHeader.stableId`, which on IMAP is the rfc822 Message-ID. Dropping
    /// either key here disarms the filter for one whole producer family at EVERY
    /// call site at once — 16 of them at `01550cdc6`, all under
    /// `TabMail/Services/Sync/` (`SyncEngineDeltaSync` ×9, `SyncEngineFullSync` ×5,
    /// `SyncEngineDeletionReconcile` ×1, `SyncEngineBackfillDeep` ×1) — and the
    /// symptom is a silent overwrite of what the user just did, not an error.
    func containsAnyKey(messageId: String, rfc822MessageId: String?) -> Bool {
        if contains(messageId) { return true }
        if let rfc = rfc822MessageId, !rfc.isEmpty, contains(rfc) { return true }
        return false
    }
}
