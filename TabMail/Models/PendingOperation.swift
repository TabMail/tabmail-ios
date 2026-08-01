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
}

struct PendingOperation: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "pendingOperation"

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
    /// Dedicated retry budget for `ProviderError.uidResolutionFailed` (IMAP
    /// SEARCH-by-Message-ID miss) on non-move, non-tag ops — separate from
    /// `retryCount`, which the generic transient-error branch also increments
    /// on every ordinary connection blip. Without a dedicated counter, a few
    /// unrelated blips could pre-exhaust `SyncConfig.maxUidResolutionRetries`
    /// before the op ever hit a real SEARCH miss, causing a false "confirmed
    /// stale" drop on the FIRST uidResolutionFailed — dropping user intention.
    /// Default 0 backed by the v67 migration's `DEFAULT 0` column (existing
    /// rows are backfilled by the ALTER TABLE, so decode never sees a missing
    /// column post-migration).
    var uidResolutionRetryCount: Int = 0
    /// UIDVALIDITY admission stamp — the value of `Folder.lastKnownUidValidity`
    /// for this op's `folderPath` at the instant the op was inserted, read inside
    /// the SAME write transaction as the insert so the stamp and the row observe
    /// one consistent epoch.
    ///
    /// It exists for ONE class of op: one the executor addresses by a BARE
    /// NUMERIC UID rather than by a durable identity. A UID means nothing outside
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
    /// **`nil` is the fail-open default and MUST stay the common case.** Only
    /// `AccountManager.queueDraftDelete` stamps today, and only when its
    /// `serverDraftId` is numeric — the same discriminator `newGestureRefusedForUnknownEpoch`
    /// already uses, because `IMAPProvider.resolveUID` short-circuits a numeric id
    /// to a literal `UIDSet` with no SEARCH while a non-numeric one goes to
    /// `searchByMessageId` and is epoch-IMMUNE. Stamping an rfc822-addressed op
    /// would let the claim-time compare drop intention that is still perfectly
    /// resolvable — the mirror-image bug, a permanent refusal. Non-IMAP accounts
    /// stamp `nil` for free: Gmail and Graph never populate
    /// `Folder.lastKnownUidValidity`.
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
    /// SELECT's UIDVALIDITY against it, fail closed on any disagreement, and only
    /// then FETCH that UID and corroborate its Message-ID.
    ///
    /// nil means UNKNOWN — never "current", never zero — and keeps the op on the
    /// unchanged Message-ID-search arm. Stamped only when slot 0 is numeric: an
    /// rfc822-addressed op is epoch-immune and an epoch beside it would be an
    /// asymmetric identity the provider refuses outright.
    ///
    /// ⚑ The reference (`v2final`) carries this as positional slot 2 of
    /// `messageIds` with a typed decoder. A TYPED COLUMN is used here instead
    /// because v3's stale sweep builds its protection set as
    /// `Set(opsTargetingThisFolder.flatMap(\.messageIds))` — every slot value,
    /// including the reference's empty-string placeholders, becomes an id that
    /// can protect an unrelated header that happens to match it.
    var draftServerUidValidity: Int?
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
        draftServerUidValidity: Int? = nil
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
        self.uidResolutionRetryCount = 0
        self.observedUidValidity = observedUidValidity
        self.draftServerUidValidity = draftServerUidValidity
        self.status = PendingStatus.queued.rawValue
    }
}

// MARK: - Sync Filter Snapshot
//
// Pending-op IDs queued by `AccountManagerActions` are `MessageHeader.stableId`:
// - Gmail/Exchange: stableId == messageId (provider-stable IDs)
// - IMAP:           stableId == rfc822MessageId when UID is numeric, else UID
//
// Server-returned `MessageHeaderInfo` carries `messageId` plus optional
// `rfc822MessageId`. A one-key check against `info.messageId` misses every IMAP
// pending op (where the queued key is rfc822). A one-key check against rfc822
// misses optimistic ops queued before the server assigned a Message-ID.
//
// The only safe check is two-key: `messageId` OR `rfc822MessageId`. Every sync
// path (Gmail delta, Exchange delta, IMAP fullSync, BackfillDeep) must use the
// same snapshot so the filter can't drift between them.

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
    /// Required because `PendingOperation.messageIds` is keyed by
    /// `MessageHeader.stableId` which is rfc822 for IMAP and messageId for
    /// Gmail/Exchange — a single-key check misses IMAP pending ops.
    func containsAnyKey(messageId: String, rfc822MessageId: String?) -> Bool {
        if contains(messageId) { return true }
        if let rfc = rfc822MessageId, !rfc.isEmpty, contains(rfc) { return true }
        return false
    }
}
