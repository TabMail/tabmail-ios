/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension AccountOperationExecutor {
    enum Eligibility: Sendable {
        case ready
        case notReady(String)
        case retire(diagnostic: String?)
    }

    /// A process availability snapshot; database policy is evaluated lazily inside
    /// the claim write, after the scheduler has protected its in-flight frontier.
    struct SchedulingPolicy: Sendable {
        private let availableAccountIds: Set<String>

        init(availableAccountIds: Set<String>) { self.availableAccountIds = availableAccountIds }

        func rows(_ db: Database, excludingCancelled: Bool = false) throws -> [QueueJob] {
            let accountScopedIds = try AccountOperationExecutor.accountScopedIdAccountIds(db)
            var request = PendingOperation.order(Column("queuePosition").asc)
            if excludingCancelled { request = request.filter(Column("status") != PendingStatus.cancelled.rawValue) }
            return try request.fetchAll(db).map {
                AccountOperationExecutor.schedulingMetadata($0, accountScopedIds: accountScopedIds)
            }
        }

        func eligibility(id: String, db: Database) throws -> Eligibility {
            guard let fetched = try PendingOperation.fetchOne(db, key: id) else { return .retire(diagnostic: nil) }
            guard availableAccountIds.contains(fetched.accountId) else {
                return .notReady("no registered provider or work queue")
            }
            return try AccountOperationExecutor.preflight(fetched, db: db)
        }
    }

    func schedulingPolicy(using manager: isolated AccountManager) -> SchedulingPolicy {
        SchedulingPolicy(availableAccountIds: Set(manager.providers.keys).intersection(manager.workQueues.keys))
    }

    static func schedulingMetadata(_ op: PendingOperation, accountScopedIds: Set<String>) -> QueueJob {
        QueueJob(id: op.id, accountId: op.accountId, queuePosition: op.queuePosition,
            status: op.status, dependencyKeys: op.messageIds.map { id in
                QueueDependencyKey(accountScopedIds.contains(op.accountId)
                    ? "\(op.accountId):\(id)" : "\(op.accountId):\(op.folderPath):\(id)")
            })
    }

    /// Unknown address/epoch/reset state never authorizes retirement. Only two
    /// positively known, differing epochs authorize the existing reset exit.
    private static func preflight(_ fetched: PendingOperation, db: Database) throws -> Eligibility {
        let sourceFolderId = MessageIdentity.folderId(
            accountId: fetched.accountId, folderPath: fetched.folderPath)
        let sourceFolder = try Folder.fetchOne(db, key: sourceFolderId)
        if let sourceFolder, sourceFolder.uidValidityResetPendingAt != nil {
            return .notReady("folder \(fetched.folderPath) is mid UIDVALIDITY reset")
        }
        let nonDraftTypes: Set<OperationType> = [
            .archive, .delete, .move,
            .markRead, .markUnread, .markFlagged, .markUnflagged,
            .markReplied, .markForwarded,
            .addUserLabel, .removeUserLabel,
        ]
        if nonDraftTypes.contains(fetched.type) {
            guard let account = try Account.fetchOne(db, key: fetched.accountId) else {
                return .notReady("no account row for checkpoint A")
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
                    BackgroundSyncLogger.log(
                        "[Queue] Checkpoint A skipped \(fetched.id.prefix(8)) " +
                        "(\(fetched.type.rawValue), \(fetched.folderPath)) — " +
                        "provider address or UIDVALIDITY not established; op stays queued")
                    return .notReady("checkpoint A has no address or epoch evidence")
                }
                if live != stamped {
                    return .retire(diagnostic:
                        "[Queue] Checkpoint A refused \(fetched.id.prefix(8)) " +
                        "(\(fetched.type.rawValue), \(fetched.folderPath)) — " +
                        "UIDVALIDITY moved \(stamped) → \(live); dropped whole before provider I/O")
                }
            }
        } else if let stamped = SyncEngine.knownUidValidity(fetched.observedUidValidity),
                  let live = SyncEngine.knownUidValidity(
                    sourceFolder?.lastKnownUidValidity),
                  live != stamped {
            return .retire(diagnostic: "[Queue] UIDVALIDITY changed under op \(fetched.id.prefix(8)) (\(fetched.type.rawValue), \(fetched.folderPath)): recorded under \(stamped), folder now \(live) — dropped without executing (C5)")
        }
        return .ready
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

}

#if DEBUG
extension AccountOperationExecutor {
    /// Domain fixtures keep their rows; grouping itself exercises the production
    /// metadata projection and provider-blind connected-component algorithm.
    static func relatedOperationsForTesting(_ ops: [PendingOperation],
        accountScopedIdAccountIds: Set<String>) -> [[PendingOperation]] {
        let byId = Dictionary(uniqueKeysWithValues: ops.map { ($0.id, $0) })
        return QueueScheduling.relatedChains(ops.map {
            schedulingMetadata($0, accountScopedIds: accountScopedIdAccountIds)
        }).map { $0.compactMap { byId[$0.id] } }
    }
}
#endif
