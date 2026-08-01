/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import UIKit

extension AccountManager {

    // MARK: - Stale Header Eviction

    /// Evict a header that no longer exists on the server (messageNotFound).
    /// Deletes from GRDB, triggers unread recount, and removes from FTS.
    func evictStaleHeader(_ header: MessageHeader) async {
        _ = try? await dbPool.write { db in
            try MessageHeader.deleteOne(db, key: header.id)
        }
        Task { await UnreadCountManager.shared.requestRecount(folderId: header.folderId) }
        _ = try? await SearchIndex.shared.removeMessages(contentKeys: [ContentKey(rawValue: header.id)])
    }

    // MARK: - Body & Attachment Fetching

    func fetchBody(for message: MessageHeader) async throws {
        print("[FetchBody] Opening: id=\(message.id.prefix(40)) msgId=\(message.messageId.prefix(30)) folder=\(message.folderPath)")

        // Body already loaded — nothing to do
        let hasBody = (try? await dbPool.read { db in try MessageBody.fetchOne(db, key: message.id) != nil }) ?? false
        guard !hasBody else { return }

        // Ensure provider exists
        if providers[message.accountId] == nil {
            guard let account = try? await dbPool.read({ db in try Account.fetchOne(db, key: message.accountId) }) else {
                throw ProviderError.notConnected
            }
            try await connectAccount(account)
        }
        guard let queue = workQueues[message.accountId] else {
            throw ProviderError.notConnected
        }

        // Use the shared BodyFetchProcessor — same pipeline as background queues.
        // Priority fetch: IMAP pool.withConnection(priority: true) jumps ahead of background.
        let item = BodyFetchProcessor.Item(
            headerId: message.id, accountId: message.accountId,
            folderPath: message.folderPath, messageId: message.messageId,
            isInInbox: message.isInInbox
        )
        let result = await BodyFetchProcessor.fetchAndProcess(
            item: item, provider: queue.provider, enableAI: true
        )

        switch result {
        case .success, .confirmedEmpty:
            break
        case .payloadTooLarge:
            throw ProviderError.networkError(
                underlying: NSError(domain: "TabMail", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "This message is too large to display."])
            )
        case .retry:
            throw ProviderError.networkError(
                underlying: NSError(domain: "TabMail", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to load message. Please try again."])
            )
        }
    }

    /// Download a single attachment's data.
    /// On connection error, reconnects the provider and retries once (handles stale IMAP after device sleep).
    func fetchAttachment(for message: MessageHeader, section: String, encoding: String?) async throws -> Data {
        // Ensure provider exists
        if providers[message.accountId] == nil {
            guard let account = try? await dbPool.read({ db in try Account.fetchOne(db, key: message.accountId) }) else {
                throw ProviderError.notConnected
            }
            try await connectAccount(account)
        }
        guard let queue = workQueues[message.accountId] else {
            throw ProviderError.notConnected
        }
        let provider = queue.provider

        for attempt in 1...2 {
            do {
                return try await queue.execute(priority: .userAction) {
                    if let imapProvider = provider as? IMAPProvider {
                        return try await imapProvider.fetchAttachment(messageId: message.messageId, folder: message.folderPath, section: section, encoding: encoding)
                    } else if let gmailProvider = provider as? GmailProvider {
                        return try await gmailProvider.fetchAttachment(messageId: message.messageId, attachmentId: section)
                    } else if let exchangeProvider = provider as? ExchangeProvider {
                        return try await exchangeProvider.fetchAttachment(messageId: message.messageId, attachmentId: section)
                    }
                    throw ProviderError.notConnected
                }
            } catch let error where attempt == 1 && SyncEngine.isConnectionError(error) {
                // Pool self-heals: dead connections discarded on checkin(healthy: false),
                // next checkout creates a fresh one. Retry loop gives the pool a chance.
                print("[Attachment] connection error, retrying: \(error)")
            }
        }
        throw ProviderError.notConnected // unreachable, satisfies compiler
    }

    /// Fetch older messages for infinite scroll. Returns the number of new messages loaded.
    func fetchOlderMessages(folders: [Folder]) async throws -> Int {
        return try await syncEngine.fetchOlderMessages(folders: folders)
    }

    /// Sync only specific folders (on-demand when user navigates to them).
    /// Syncs accounts in parallel — each account's folders are sequential (shared IMAP connection).
    func syncFolders(_ folders: [Folder]) async throws {
        let grouped = Dictionary(grouping: folders) { $0.accountId }
        let affectedAccountIds = Array(grouped.keys)
        defer {
            // Clear phases for all accounts involved in this sync.
            Task { @MainActor in
                for id in affectedAccountIds {
                    AccountManagerState.shared.setSyncPhase(nil, forAccount: id)
                }
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (accountId, accountFolders) in grouped {
                guard let provider = providers[accountId] else { continue }
                let syncEngine = self.syncEngine
                group.addTask {
                    // Pool creates connections on demand via checkout — no explicit connect needed.
                    for folder in accountFolders where !folder.path.isEmpty {
                        do {
                            try await syncEngine.syncFolderMessages(folder: folder, provider: provider)
                        } catch {
                            if SyncEngine.isSelectFailedError(error) {
                                print("[SyncFolders] SELECT failed for \(folder.name) — skipping")
                                continue
                            }
                            // 404 during folder sync is transient — e.g., a draft was just
                            // trashed and the message is no longer in this label. Skip the
                            // folder rather than surfacing to the user as a red error banner.
                            if case ProviderError.networkError(let underlying) = error,
                               (underlying as NSError).code == 404 {
                                print("[SyncFolders] 404 for \(folder.name) — skipping (message likely moved/deleted)")
                                continue
                            }
                            throw error
                        }
                    }
                    // AI processing is now event-driven via ActiveBodyQueue → ActiveAIQueue.
                    // New headers from syncFolderMessages are automatically enqueued.
                }
            }
            try await group.waitForAll()
        }
    }
}
