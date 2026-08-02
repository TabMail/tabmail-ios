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
        self.everAttempted = false
        self.uidResolutionRetryCount = 0
        self.observedUidValidity = observedUidValidity
        self.draftServerUidValidity = draftServerUidValidity
        self.instanceEpoch = instanceEpoch
        self.draftId = draftId
        self.draftDeleteAddressKind = draftDeleteAddressKind?.rawValue
        self.status = PendingStatus.queued.rawValue
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
