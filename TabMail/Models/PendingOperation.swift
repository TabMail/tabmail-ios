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

    /// Operation kinds that new provider-neutral message-action admissions
    /// may persist. Legacy `.archive` / `.delete` rows remain readable by the
    /// snapshot/drain compatibility paths, but new callers must express both
    /// as `.move` with an explicit destination.
    private static let newlyAdmittedMessageActionTypes: Set<OperationType> = [
        .move,
        .markRead, .markUnread,
        .markFlagged, .markUnflagged,
        .markReplied, .markForwarded,
        .addUserLabel, .removeUserLabel,
    ]

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
        userLabelId: String? = nil
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
        self.status = PendingStatus.queued.rawValue
    }

    /// Sole constructor for newly admitted durable message actions. Draft
    /// resource operations deliberately continue to use the ordinary
    /// initializer because their provider resource IDs are a separate domain.
    static func durableMessageAction(
        type: OperationType,
        messageIds: [String],
        accountId: String,
        folderPath: String,
        destinationPath: String? = nil,
        userLabelId: String? = nil
    ) -> PendingOperation? {
        guard newlyAdmittedMessageActionTypes.contains(type),
              !messageIds.isEmpty,
              !accountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        switch type {
        case .move:
            guard let destinationPath,
                  !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  userLabelId == nil
            else { return nil }
        case .addUserLabel, .removeUserLabel:
            guard destinationPath == nil,
                  let userLabelId,
                  !userLabelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
        case .markRead, .markUnread, .markFlagged, .markUnflagged, .markReplied, .markForwarded:
            guard destinationPath == nil, userLabelId == nil else { return nil }
        default:
            return nil
        }

        // Hybrid member identity (PLAN_IDENTITY_HYBRID §2): an RFC-shaped
        // member is stored normalized; anything else non-empty is admitted
        // byte-exact as an opaque provider token. Classification is per
        // member — mixed batches are fine. Only an empty member refuses.
        let normalizedIds = messageIds.compactMap { member -> String? in
            switch MessageIdentity.durableMemberKind(member) {
            case .rfc(let normalized): normalized
            case .providerToken(let token): token
            case nil: nil
            }
        }
        guard normalizedIds.count == messageIds.count else { return nil }

        return PendingOperation(
            type: type,
            messageIds: normalizedIds,
            accountId: accountId,
            folderPath: folderPath,
            destinationPath: destinationPath,
            userLabelId: userLabelId
        )
    }
}

// MARK: - Undo matching (ADR-IOS-060 §9.6)

extension PendingOperation {
    /// Pure, provider-independent structural inverse used ONLY by Undo's
    /// bounded durable-admission matching (§8.3/§9.3). Not persisted, not a
    /// queue capability, and never compared against by the executor. Returns
    /// nil for an operation with no well-defined inverse — a non-reversible
    /// operation (e.g. permanent delete, which this queue never models)
    /// cannot reconcile durable work.
    struct Flipped: Equatable {
        let type: OperationType
        let accountId: String
        let folderPath: String
        let destinationPath: String?
        let userLabelId: String?
    }

    func flipped() -> Flipped? {
        switch type {
        case .move:
            guard let destinationPath else { return nil }
            return Flipped(
                type: .move,
                accountId: accountId,
                folderPath: destinationPath,
                destinationPath: folderPath,
                userLabelId: nil
            )
        case .markRead:
            return Flipped(type: .markUnread, accountId: accountId, folderPath: folderPath, destinationPath: nil, userLabelId: nil)
        case .markUnread:
            return Flipped(type: .markRead, accountId: accountId, folderPath: folderPath, destinationPath: nil, userLabelId: nil)
        case .markFlagged:
            return Flipped(type: .markUnflagged, accountId: accountId, folderPath: folderPath, destinationPath: nil, userLabelId: nil)
        case .markUnflagged:
            return Flipped(type: .markFlagged, accountId: accountId, folderPath: folderPath, destinationPath: nil, userLabelId: nil)
        case .addUserLabel:
            guard let userLabelId else { return nil }
            return Flipped(type: .removeUserLabel, accountId: accountId, folderPath: folderPath, destinationPath: nil, userLabelId: userLabelId)
        case .removeUserLabel:
            guard let userLabelId else { return nil }
            return Flipped(type: .addUserLabel, accountId: accountId, folderPath: folderPath, destinationPath: nil, userLabelId: userLabelId)
        default:
            return nil
        }
    }

    /// Structural equality of `self` against a candidate's `flipped()` shape —
    /// exact operation kind/account/source/destination/label, used only by
    /// Undo's admission matcher. Member-set equality is checked separately by
    /// the caller (a partial-overlap batch never matches).
    func matchesFlip(of candidate: PendingOperation) -> Bool {
        guard let flipped = candidate.flipped() else { return false }
        return flipped.type == type
            && flipped.accountId == accountId
            && flipped.folderPath == folderPath
            && flipped.destinationPath == destinationPath
            && flipped.userLabelId == userLabelId
    }
}

// MARK: - Sync Filter Snapshot
//
// Durable message-action rows carry hybrid member identity: normalized RFC
// Message-ID when the message has one, otherwise the raw provider ID as an
// opaque token (PLAN_IDENTITY_HYBRID). Snapshots therefore match BOTH the
// provider `messageId` and the normalized `rfc822MessageId` permanently —
// a token member keys protection by its raw token string, which equals the
// header's `messageId` in the recorded scope.

/// Snapshot of pending operation IDs for the sync filter. Mutation decisions
/// always include a load INSIDE the write transaction; a preflight observation
/// may be merged into it only to bridge the queue's publish-then-delete boundary.
/// Relying on a separate read alone creates a TOCTOU window where a user action
/// inserts a `PendingOperation` before the sync write.
struct PendingOperationSnapshot: Sendable {
    /// IDs from `.archive`, `.delete`, `.move` ops. Used to skip inserting a
    /// message into a folder the user is optimistically moving out of.
    let destructive: Set<String>
    /// Exact source-folder memberships removed by destructive operations.
    /// Gmail delta uses this purpose-scoped form so protecting source label A
    /// never suppresses an unrelated external label X on the same message.
    let destructiveSourceMemberships: Set<String>
    /// Exact optimistic destination memberships created by destructive moves.
    /// These rows survive stale provider metadata without protecting unrelated
    /// memberships or letting a pending field toggle hide a remote label removal.
    let destructiveDestinationMemberships: Set<String>
    /// IDs from read-state operations.
    let read: Set<String>
    /// IDs from flagged-state operations.
    let flagged: Set<String>
    /// Compatibility union for provider-backed field classes.
    var flag: Set<String> { read.union(flagged) }
    /// RFC identities from queued message actions. Draft resource IDs are
    /// deliberately excluded so a provider/draft token can never be mistaken
    /// for a provider-neutral message-action identity.
    let messageActions: Set<String>
    /// Provider-specific draft resources used only by draft sync paths.
    let draftResources: Set<String>

    static let destructiveTypes: Set<OperationType> = [.archive, .delete, .move]
    static let readTypes: Set<OperationType> = [.markRead, .markUnread]
    static let flaggedTypes: Set<OperationType> = [.markFlagged, .markUnflagged]
    static let draftTypes: Set<OperationType> = [.saveDraft, .deleteDraft]
    static let messageActionTypes: Set<OperationType> = destructiveTypes
        .union(readTypes)
        .union(flaggedTypes)
        .union([.markReplied, .markForwarded, .addUserLabel, .removeUserLabel])

    /// Build from a pre-fetched list of ops. Callers load ops once inside the
    /// write transaction and pass them here so the filter classification is
    /// the only work duplicated — not the DB query. Cancelled rows are forensic
    /// cleanup state, not live intentions, and never protect sync fields/membership.
    init(ops: [PendingOperation]) {
        var destructive = Set<String>()
        var destructiveSourceMemberships = Set<String>()
        var destructiveDestinationMemberships = Set<String>()
        var read = Set<String>()
        var flagged = Set<String>()
        var messageActions = Set<String>()
        var draftResources = Set<String>()
        for op in ops where op.status == PendingStatus.queued.rawValue
            || op.status == PendingStatus.inFlight.rawValue {
            let ids = op.messageIds
            if Self.messageActionTypes.contains(op.type) { messageActions.formUnion(ids) }
            if Self.draftTypes.contains(op.type) { draftResources.formUnion(ids) }
            if Self.destructiveTypes.contains(op.type) {
                destructive.formUnion(ids)
                destructiveSourceMemberships.formUnion(ids.map {
                    MessageIdentity.membershipKey(
                        accountId: op.accountId,
                        folderPath: op.folderPath,
                        messageId: $0,
                        membership: .removedSource
                    )
                })
                if let destinationPath = op.destinationPath {
                    destructiveDestinationMemberships.formUnion(ids.map {
                        MessageIdentity.membershipKey(
                            accountId: op.accountId,
                            folderPath: destinationPath,
                            messageId: $0,
                            membership: .addedDestination
                        )
                    })
                }
            }
            if Self.readTypes.contains(op.type) { read.formUnion(ids) }
            if Self.flaggedTypes.contains(op.type) { flagged.formUnion(ids) }
        }
        self.destructive = destructive
        self.destructiveSourceMemberships = destructiveSourceMemberships
        self.destructiveDestinationMemberships = destructiveDestinationMemberships
        self.read = read
        self.flagged = flagged
        self.messageActions = messageActions
        self.draftResources = draftResources
    }

    private init(
        destructive: Set<String>,
        destructiveSourceMemberships: Set<String>,
        destructiveDestinationMemberships: Set<String>,
        read: Set<String>,
        flagged: Set<String>,
        messageActions: Set<String>,
        draftResources: Set<String>
    ) {
        self.destructive = destructive
        self.destructiveSourceMemberships = destructiveSourceMemberships
        self.destructiveDestinationMemberships = destructiveDestinationMemberships
        self.read = read
        self.flagged = flagged
        self.messageActions = messageActions
        self.draftResources = draftResources
    }

    /// Union two observations taken on opposite sides of the
    /// recently-completed publication boundary. The queue publishes recent
    /// protection before deleting its durable operation, so reading DB first,
    /// then the actor map, then unioning this snapshot with an in-transaction
    /// reload guarantees at least one side of every transition is observed.
    func merging(_ other: PendingOperationSnapshot) -> PendingOperationSnapshot {
        PendingOperationSnapshot(
            destructive: destructive.union(other.destructive),
            destructiveSourceMemberships: destructiveSourceMemberships
                .union(other.destructiveSourceMemberships),
            destructiveDestinationMemberships: destructiveDestinationMemberships
                .union(other.destructiveDestinationMemberships),
            read: read.union(other.read),
            flagged: flagged.union(other.flagged),
            messageActions: messageActions.union(other.messageActions),
            draftResources: draftResources.union(other.draftResources)
        )
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
    /// PERMANENT two-key hybrid membership check (PLAN_IDENTITY_HYBRID §4).
    /// RFC members match through the normalized-RFC leg; token members match
    /// through the raw provider-ID leg (`header.messageId`). Sync-side
    /// membership checks against queued/pending/recently-completed sets MUST
    /// consult both legs — this is a designed feature of the hybrid identity
    /// model, not legacy compatibility.
    func containsAnyKey(messageId: String, rfc822MessageId: String?) -> Bool {
        if contains(messageId) { return true }
        if let rfc = MessageIdentity.durableActionRFC822MessageId(rfc822MessageId),
           contains(rfc) {
            return true
        }
        return false
    }
}
