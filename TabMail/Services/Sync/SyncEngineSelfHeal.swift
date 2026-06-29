/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

    // MARK: - Self-Healing: Detect and Repair Missing Messages

    /// Lightweight UID gap detector that runs after full sync for IMAP accounts.
    /// Compares IMAP UIDs (via SEARCH) with local GRDB messageIds for recent messages
    /// and fetches any that are missing. Catches messages silently dropped by:
    ///   - IMAP FETCH returning fewer results than requested
    ///   - Backfill date-window boundary misses
    ///   - Connection drops mid-batch
    ///
    /// Rate-limited to once per hour per account (lightweight SEARCH is ~50ms,
    /// but we don't want to hammer the server on every 60s poll).
    func selfHealRecentMessages(account: Account, forceSingleFolder: Folder? = nil) async {
        guard account.provider == .imap,
              let provider = providers[account.id] as? IMAPProvider else { return }

        // Rate limit: once per hour (bypassed for single-folder forced heal)
        if forceSingleFolder == nil {
            let key = "selfHeal_lastRun_\(account.id)"
            let lastRun = UserDefaults.standard.double(forKey: key)
            let hourAgo = Date().timeIntervalSince1970 - 3600
            guard lastRun < hourAgo else {
                print("[SelfHeal] Skipping — last run \(Int(Date().timeIntervalSince1970 - lastRun))s ago")
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        }

        let syncableFolders: [Folder]
        if let single = forceSingleFolder {
            syncableFolders = [single]
        } else {
            let folders: [Folder]
            do {
                folders = try await dbPool.read { db in
                    try Folder.filter(Column("accountId") == account.id && Column("path") != "").fetchAll(db)
                }
            } catch {
                print("[SelfHeal] Failed to load folders: \(error)")
                return
            }
            syncableFolders = folders.filter { folder in
                primaryRoles.contains(folder.role) ||
                secondaryRoles.contains(folder.role) ||
                folder.isFavorite
            }
        }
        print("[SelfHeal] Starting for \(account.emailAddress): \(syncableFolders.count) folders")

        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let since = utcCal.date(byAdding: .day, value: -90, to: now) ?? now

        var totalRepaired = 0

        for folder in syncableFolders {
            do {
                let repaired = try await selfHealFolder(
                    folder: folder,
                    account: account,
                    provider: provider,
                    since: since
                )
                totalRepaired += repaired
            } catch {
                // Don't abort other folders if one fails
                print("[SelfHeal] Error for \(folder.name): \(error)")
            }
        }

        if totalRepaired > 0 {
            print("[SelfHeal] Repaired \(totalRepaired) missing messages for \(account.emailAddress)")
        }
    }

    /// Compare IMAP UIDs vs GRDB for a single folder in the given date range.
    /// Returns the number of messages repaired (fetched and inserted).
    private func selfHealFolder(
        folder: Folder,
        account: Account,
        provider: IMAPProvider,
        since: Date
    ) async throws -> Int {
        let folderId = folder.id

        // Step 1: SEARCH — get all UIDs in the date range from IMAP
        let remoteUIDs: [UInt32]
        do {
            remoteUIDs = try await provider.searchBackfillUIDs(
                folder: folder.path, since: since, before: Date()
            )
        } catch {
            let desc = "\(error)"
            if desc.contains("PayloadTooLargeError") {
                // Too many UIDs to compare — skip this folder (backfill handles it)
                return 0
            }
            throw error
        }
        guard !remoteUIDs.isEmpty else { return 0 }

        // Step 2: Find which UIDs we're missing locally
        let missingUIDs: [UInt32] = try await dbPool.read { db in
            let sqlChunkSize = 500
            var existingIds = Set<String>()
            for start in stride(from: 0, to: remoteUIDs.count, by: sqlChunkSize) {
                let end = min(start + sqlChunkSize, remoteUIDs.count)
                let chunk = remoteUIDs[start..<end].map { "\($0)" }
                let found = try String.fetchSet(db,
                    MessageHeader
                        .select(Column("messageId"))
                        .filter(Column("folderId") == folderId && chunk.contains(Column("messageId")))
                )
                existingIds.formUnion(found)
            }
            return remoteUIDs.filter { !existingIds.contains(String($0)) }
        }

        guard !missingUIDs.isEmpty else { return 0 }
        print("[SelfHeal] \(folder.name): found \(missingUIDs.count) missing UIDs out of \(remoteUIDs.count) remote (last 90 days). Missing: \(missingUIDs.sorted().prefix(20))")

        // Step 3: Fetch missing headers from IMAP
        let profile = await getBackfillProfile()
        let headers = try await provider.fetchMessageHeaders(
            folder: folder.path,
            uids: missingUIDs,
            batchSize: profile.imapFetchBatchSize,
            interBatchDelay: profile.imapInterBatchDelay
        )

        if headers.count < missingUIDs.count {
            let fetched = Set(headers.map(\.messageId))
            let stillMissing = missingUIDs.filter { !fetched.contains(String($0)) }
            print("[SelfHeal] \(folder.name): IMAP FETCH returned \(headers.count)/\(missingUIDs.count). Permanently missing UIDs: \(stillMissing.sorted().prefix(20))")
        }

        guard !headers.isEmpty else { return 0 }

        // Step 4: Insert into GRDB (reuse backfill insert which handles dedup)
        let (inserted, ftsRecords, _) = await insertBackfillBatch(
            headers,
            folderId: folderId,
            accountId: account.id,
            folderPath: folder.path,
            folderRole: folder.role,
            isInInbox: folder.role == .inbox
        )

        if inserted > 0 {
            print("[SelfHeal] \(folder.name): repaired \(inserted) messages")
            if !ftsRecords.isEmpty {
                await indexHeadersForFTS(ftsRecords)
                await BackfillBodyQueue.shared.enqueueItems(
                    ftsRecords: ftsRecords, accountId: account.id,
                    folderPath: folder.path, isInInbox: folder.role == .inbox
                )
            }
        }

        return inserted
    }
}
