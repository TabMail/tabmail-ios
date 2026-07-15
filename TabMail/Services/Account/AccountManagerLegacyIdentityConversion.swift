/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

enum ReleasedMessageActionIdentityConversionError: Error, Equatable, LocalizedError {
    case malformedMessageIds(operationId: String)
    case missingAccount(accountId: String)
    case unsupportedAccountProvider(accountId: String)
    case invalidScope(operationId: String)
    case missingProvider(accountId: String)
    case invalidProviderResolution(providerMessageId: String)
    case queueChangedDuringConversion

    var errorDescription: String? {
        switch self {
        case .malformedMessageIds(let operationId):
            "Released message-action row \(operationId) has malformed member identity JSON."
        case .missingAccount(let accountId):
            "Released message-action row references missing account \(accountId)."
        case .unsupportedAccountProvider(let accountId):
            "Released message-action row references unsupported account \(accountId)."
        case .invalidScope(let operationId):
            "Released message-action row \(operationId) has invalid account or source scope."
        case .missingProvider(let accountId):
            "Released message-action conversion is waiting for provider \(accountId)."
        case .invalidProviderResolution(let providerMessageId):
            "Provider returned an invalid RFC identity for \(providerMessageId)."
        case .queueChangedDuringConversion:
            "The durable message-action queue changed during identity conversion."
        }
    }
}

private struct ReleasedMessageActionOperationSnapshot: Sendable {
    let rowId: Int64
    let operation: PendingOperation
    let decodedMessageIds: [String]
    let accountProvider: AccountProvider?
    let localCandidatesByProviderId: [String: Set<ReleasedMessageActionLocalCandidate>]
}

private struct ReleasedMessageActionLocalCandidate: Hashable, Sendable {
    let folderPath: String
    let rfc822MessageId: String?
}

private struct ReleasedMessageActionResolutionKey: Hashable, Sendable {
    let accountId: String
    let providerMessageId: String
    let sourceFolder: String
    let destinationFolder: String?
}

private enum ReleasedMessageActionMemberResolution: Sendable {
    case resolved(String)
    case stale
}

private struct ReleasedMessageActionConversionPlan: Sendable {
    let snapshot: ReleasedMessageActionOperationSnapshot
    let convertedMessageIds: [String]
}

/// Legacy `.archive` / `.delete` rows are already executor no-ops and belong
/// to startup cleanup, not identity conversion. Draft and local action-tag
/// resources are separate identity domains. Keep this finite cutover limited
/// to operation kinds that will actually reach an RFC-aware provider method.
private let releasedIdentityConversionOperationTypes: Set<OperationType> = [
    .move,
    .markRead, .markUnread,
    .markFlagged, .markUnflagged,
    .markReplied, .markForwarded,
    .addUserLabel, .removeUserLabel,
]

extension AccountManager {
    /// Finite pre-drain upgrade for rows released before durable message actions
    /// used one universal RFC Message-ID. Provider I/O happens against a read-only
    /// snapshot. No durable row changes until every member has resolved or
    /// authoritatively no-oped, after which one transaction validates the entire
    /// legacy snapshot and changes only `messageIdsJSON` (or deletes an empty row).
    func convertReleasedMessageActionIdentities() async throws {
        try await convertReleasedMessageActionIdentities(using: dbPool)
    }

    /// Stable-database overload used by the pre-drain preparation flight. The
    /// process-global database pointer is replaceable in tests, so both snapshot
    /// reads and the final compare-and-swap must stay on the database instance
    /// that the flight was created for.
    func convertReleasedMessageActionIdentities(
        using conversionDatabase: PrioritizedDatabase
    ) async throws {
        let snapshots = try await conversionDatabase.read { db in
            try Self.loadReleasedMessageActionConversionSnapshots(db: db)
        }
        guard !snapshots.isEmpty else { return }

        var providersByAccount: [String: any EmailProvider] = [:]
        for snapshot in snapshots where snapshot.decodedMessageIds.contains(where: {
            MessageIdentity.durableActionRFC822MessageId($0) == nil
        }) {
            if let provider = providers[snapshot.operation.accountId] {
                providersByAccount[snapshot.operation.accountId] = provider
            }
        }

        var cachedResolutions: [
            ReleasedMessageActionResolutionKey: ReleasedMessageActionMemberResolution
        ] = [:]
        var plans: [ReleasedMessageActionConversionPlan] = []
        plans.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            var convertedMessageIds: [String] = []
            convertedMessageIds.reserveCapacity(snapshot.decodedMessageIds.count)

            for storedMessageId in snapshot.decodedMessageIds {
                if let normalized = MessageIdentity.durableActionRFC822MessageId(storedMessageId) {
                    convertedMessageIds.append(normalized)
                    continue
                }

                guard let accountProvider = snapshot.accountProvider else {
                    throw ReleasedMessageActionIdentityConversionError.missingAccount(
                        accountId: snapshot.operation.accountId
                    )
                }
                guard accountProvider != .caldav else {
                    throw ReleasedMessageActionIdentityConversionError.unsupportedAccountProvider(
                        accountId: snapshot.operation.accountId
                    )
                }
                guard !snapshot.operation.accountId.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty,
                    !snapshot.operation.folderPath.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                    snapshot.operation.accountId.rangeOfCharacter(
                        from: .controlCharacters
                    ) == nil,
                    snapshot.operation.folderPath.rangeOfCharacter(
                        from: .controlCharacters
                    ) == nil
                else {
                    throw ReleasedMessageActionIdentityConversionError.invalidScope(
                        operationId: snapshot.operation.id
                    )
                }

                let key = ReleasedMessageActionResolutionKey(
                    accountId: snapshot.operation.accountId,
                    providerMessageId: storedMessageId,
                    sourceFolder: snapshot.operation.folderPath,
                    destinationFolder: snapshot.operation.destinationPath
                )
                let resolution: ReleasedMessageActionMemberResolution
                if let cached = cachedResolutions[key] {
                    resolution = cached
                } else if let local = Self.resolveReleasedIdentityLocally(
                    operation: snapshot.operation,
                    accountProvider: accountProvider,
                    candidates: snapshot.localCandidatesByProviderId[storedMessageId] ?? []
                ) {
                    resolution = .resolved(local)
                    cachedResolutions[key] = resolution
                } else {
                    guard let provider = providersByAccount[snapshot.operation.accountId] else {
                        throw ReleasedMessageActionIdentityConversionError.missingProvider(
                            accountId: snapshot.operation.accountId
                        )
                    }
                    switch try await provider.resolveLegacyMessageActionIdentity(
                        providerMessageId: storedMessageId,
                        sourceFolder: snapshot.operation.folderPath,
                        destinationFolder: snapshot.operation.destinationPath
                    ) {
                    case .resolved(let rfc822MessageId):
                        guard let normalized = MessageIdentity.durableActionRFC822MessageId(
                            rfc822MessageId
                        ) else {
                            throw ReleasedMessageActionIdentityConversionError
                                .invalidProviderResolution(providerMessageId: storedMessageId)
                        }
                        resolution = .resolved(normalized)
                    case .staleOrAmbiguous:
                        resolution = .stale
                    }
                    cachedResolutions[key] = resolution
                }

                if case .resolved(let rfc822MessageId) = resolution {
                    convertedMessageIds.append(rfc822MessageId)
                }
            }

            plans.append(ReleasedMessageActionConversionPlan(
                snapshot: snapshot,
                convertedMessageIds: convertedMessageIds
            ))
        }

        let finalizedPlans = plans
        // Gated (§9.3): only this closing compare-and-swap transaction — the
        // provider lookups/resolution above already completed against a
        // read-only snapshot and must never run while the gate is held.
        try await retryGatedQueueWrite(conversionDatabase, label: "convertReleasedMessageActionIdentities", maxAttempts: 1) { db in
            let currentSnapshots = try Self.loadReleasedMessageActionConversionSnapshots(db: db)
            guard currentSnapshots.count == finalizedPlans.count else {
                throw ReleasedMessageActionIdentityConversionError.queueChangedDuringConversion
            }
            let currentById = Dictionary(uniqueKeysWithValues: currentSnapshots.map {
                ($0.operation.id, $0)
            })

            for plan in finalizedPlans {
                guard let current = currentById[plan.snapshot.operation.id],
                      current.rowId == plan.snapshot.rowId,
                      Self.sameStoredOperation(current.operation, plan.snapshot.operation),
                      current.decodedMessageIds == plan.snapshot.decodedMessageIds,
                      current.accountProvider == plan.snapshot.accountProvider,
                      current.localCandidatesByProviderId
                        == plan.snapshot.localCandidatesByProviderId
                else {
                    throw ReleasedMessageActionIdentityConversionError.queueChangedDuringConversion
                }
            }

            for plan in finalizedPlans {
                if plan.convertedMessageIds.isEmpty {
                    guard try PendingOperation.deleteOne(
                        db,
                        key: plan.snapshot.operation.id
                    ) else {
                        throw ReleasedMessageActionIdentityConversionError.queueChangedDuringConversion
                    }
                    continue
                }
                let data = try JSONEncoder().encode(plan.convertedMessageIds)
                guard let encoded = String(data: data, encoding: .utf8) else {
                    throw ReleasedMessageActionIdentityConversionError.malformedMessageIds(
                        operationId: plan.snapshot.operation.id
                    )
                }
                try db.execute(
                    sql: "UPDATE pendingOperation SET messageIdsJSON = ? WHERE id = ?",
                    arguments: [encoded, plan.snapshot.operation.id]
                )
                guard db.changesCount == 1 else {
                    throw ReleasedMessageActionIdentityConversionError.queueChangedDuringConversion
                }
            }

            guard try Self.loadReleasedMessageActionOperationRows(db: db).isEmpty else {
                throw ReleasedMessageActionIdentityConversionError.queueChangedDuringConversion
            }
        }
    }

    private nonisolated static func loadReleasedMessageActionConversionSnapshots(
        db: Database
    ) throws -> [ReleasedMessageActionOperationSnapshot] {
        let operationRows = try loadReleasedMessageActionOperationRows(db: db)
        guard !operationRows.isEmpty else { return [] }

        let accounts = Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).map {
            ($0.id, $0.provider)
        })
        var providerIdsByAccount: [String: Set<String>] = [:]
        for row in operationRows {
            for messageId in row.decodedMessageIds
                where MessageIdentity.durableActionRFC822MessageId(messageId) == nil {
                providerIdsByAccount[row.operation.accountId, default: []].insert(messageId)
            }
        }

        var candidatesByAccountAndProviderId: [
            String: [String: Set<ReleasedMessageActionLocalCandidate>]
        ] = [:]
        for (accountId, providerIds) in providerIdsByAccount where !providerIds.isEmpty {
            for providerMessageId in providerIds {
                let headers = try MessageHeader
                    .filter(
                        Column("accountId") == accountId
                            && Column("messageId") == providerMessageId
                    )
                    .fetchAll(db)
                for header in headers {
                    candidatesByAccountAndProviderId[accountId, default: [:]][
                        header.messageId,
                        default: []
                    ].insert(ReleasedMessageActionLocalCandidate(
                        folderPath: header.folderPath,
                        rfc822MessageId: header.rfc822MessageId
                    ))
                }
            }
        }

        return operationRows.map { row in
            ReleasedMessageActionOperationSnapshot(
                rowId: row.rowId,
                operation: row.operation,
                decodedMessageIds: row.decodedMessageIds,
                accountProvider: accounts[row.operation.accountId],
                localCandidatesByProviderId: candidatesByAccountAndProviderId[
                    row.operation.accountId
                ] ?? [:]
            )
        }
    }

    private nonisolated static func loadReleasedMessageActionOperationRows(
        db: Database
    ) throws -> [(rowId: Int64, operation: PendingOperation, decodedMessageIds: [String])] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT rowid AS conversionRowId, * FROM pendingOperation ORDER BY rowid"
        )
        var result: [(Int64, PendingOperation, [String])] = []
        for row in rows {
            let operation = try PendingOperation(row: row)
            guard releasedIdentityConversionOperationTypes.contains(operation.type) else {
                continue
            }
            guard operation.status == PendingStatus.queued.rawValue
                    || operation.status == PendingStatus.inFlight.rawValue else {
                continue
            }
            guard let data = operation.messageIdsJSON.data(using: .utf8),
                  let messageIds = try? JSONDecoder().decode([String].self, from: data)
            else {
                throw ReleasedMessageActionIdentityConversionError.malformedMessageIds(
                    operationId: operation.id
                )
            }
            let needsConversion = messageIds.isEmpty || messageIds.contains { messageId in
                MessageIdentity.durableActionRFC822MessageId(messageId) != messageId
            }
            guard needsConversion else { continue }
            let rowId: Int64 = row["conversionRowId"]
            result.append((rowId, operation, messageIds))
        }
        return result
    }

    private nonisolated static func resolveReleasedIdentityLocally(
        operation: PendingOperation,
        accountProvider: AccountProvider,
        candidates: Set<ReleasedMessageActionLocalCandidate>
    ) -> String? {
        let relevantFolders: Set<String>
        switch accountProvider {
        case .imap, .icloud:
            relevantFolders = [operation.folderPath]
        case .gmail, .outlook:
            relevantFolders = Set([operation.folderPath, operation.destinationPath].compactMap { $0 })
        case .caldav:
            return nil
        }

        let scoped = candidates.filter { relevantFolders.contains($0.folderPath) }
        guard !scoped.isEmpty else { return nil }
        let normalized = scoped.compactMap {
            MessageIdentity.durableActionRFC822MessageId($0.rfc822MessageId)
        }
        guard normalized.count == scoped.count,
              Set(normalized).count == 1 else { return nil }
        return normalized[0]
    }

    private nonisolated static func sameStoredOperation(
        _ lhs: PendingOperation,
        _ rhs: PendingOperation
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.type == rhs.type
            && lhs.messageIdsJSON == rhs.messageIdsJSON
            && lhs.accountId == rhs.accountId
            && lhs.folderPath == rhs.folderPath
            && lhs.destinationPath == rhs.destinationPath
            && lhs.tagValue == rhs.tagValue
            && lhs.userLabelId == rhs.userLabelId
            && lhs.createdAt == rhs.createdAt
            && lhs.retryCount == rhs.retryCount
            && lhs.status == rhs.status
    }
}
