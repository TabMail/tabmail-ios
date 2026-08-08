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
    ///
    /// 🚨 ORDERING CONTRACT (`MessageContentStore`): the content key and its scope
    /// are captured INSIDE the delete transaction and the release happens AFTER it
    /// commits. Reversed, the header still exists when owners are counted, the count
    /// is always ≥ 1, and the FTS row is never removed — a silent no-op.
    ///
    /// `.body` joins `.searchIndex` from Stage D: `v70_dropMessageBodyHeaderFK`
    /// removed the FK cascade that used to reclaim the `messageBody` row as a side
    /// effect of the header delete, so this release is now the eager reclaimer.
    func evictStaleHeader(_ header: MessageHeader) async {
        let captured = try? await dbPool.write { db -> MessageContentStore.CapturedContent? in
            let captured = try MessageContentStore.capture(header, db: db)
            try MessageHeader.deleteOne(db, key: header.id)
            return captured
        }
        Task { await UnreadCountManager.shared.requestRecount(folderId: header.folderId) }
        if let captured = captured ?? nil {
            await MessageContentStore.releaseUnowned(
                captured.contentKey, scope: captured.scope,
                stores: [.searchIndex, .body], pool: dbPool)
        } else {
            // No account row to read a key space from — keep the pre-existing
            // unconditional removal rather than invent an owner. `.body` is part of
            // that pre-existing behaviour: the cascade deleted it here too.
            await MessageContentStore.release(
                ContentKey(rawValue: header.id), stores: [.searchIndex, .body], pool: dbPool)
        }
    }

    // MARK: - Body & Attachment Fetching

    /// True when this row's provider address is not corroborated, so a body fetch would
    /// name a DIFFERENT message on the wire. See `BodyAddressGate`.
    ///
    /// ⚠️ **This is a PRE-FILTER, not the guard.** It exists to avoid a round trip that
    /// `BodyFetchProcessor.process` would refuse anyway, and to let the UI show a pending
    /// state instead of a blank body. It therefore FAILS OPEN (returns false) when the
    /// account cannot be read: a dropped pre-filter costs one wasted fetch, while the
    /// authoritative refusal still runs at the write. Do not promote this to a guard
    /// without flipping that direction — a fail-open seam feeding a guard is
    /// fail-dangerous (`feedback_port_safe_only_if_consumer_direction_same`).
    func bodyFetchIsBlockedByPendingAddress(for message: MessageHeader) async -> Bool {
        let provider: AccountProvider?
        do {
            provider = try await dbPool.read { db in
                try Account.fetchOne(db, key: message.accountId)?.provider
            }
        } catch {
            return false
        }
        guard let provider else { return false }
        return !BodyAddressGate.isFetchable(header: message, provider: provider)
    }

    /// The ATTACHMENT counterpart — and it FAILS CLOSED, the opposite direction from the
    /// body pre-filter above. That asymmetry is deliberate and load-bearing.
    ///
    /// The body path can afford a fail-OPEN pre-filter because a dropped pre-filter costs
    /// only a wasted round trip: `BodyFetchProcessor.process` still refuses authoritatively
    /// before anything is written. **The attachment path has no such downstream refusal.**
    /// `fetchAttachment` hands raw bytes back to `AttachmentListView.downloadAndPreview`,
    /// which previews them AND caches them via `BodyAssetStore.writeAttachment` under
    /// `ContentKey(message.id)` — the MOVED row's key — stamped with that row's own
    /// identity from `AttachmentCacheIdentity.stamp(for:)`. So a stranger's attachment
    /// bytes land under the victim's key carrying the victim's identity proof, and every
    /// later read check accepts them: the wrong attachment is served as this message's
    /// attachment indefinitely.
    ///
    /// This function IS the guard, not a pre-filter, so an unreadable account must REFUSE.
    /// Reusing the fail-open version here would be a fail-open seam feeding a guard, which
    /// is fail-dangerous (`feedback_port_safe_only_if_consumer_direction_same`).
    func attachmentFetchIsBlockedByPendingAddress(for message: MessageHeader) async -> Bool {
        let provider: AccountProvider?
        do {
            provider = try await dbPool.read { db in
                try Account.fetchOne(db, key: message.accountId)?.provider
            }
        } catch {
            return true
        }
        guard let provider else { return true }
        return !BodyAddressGate.isFetchable(header: message, provider: provider)
    }

    func fetchBody(for message: MessageHeader) async throws {
        print("[FetchBody] Opening: id=\(message.id.prefix(40)) msgId=\(message.messageId.prefix(30)) folder=\(message.folderPath)")

        // Body already loaded — nothing to do
        let hasBody = (try? await dbPool.read { db in try MessageBody.fetchOne(db, key: message.id) != nil }) ?? false
        guard !hasBody else { return }

        // Address not corroborated: this UID names a DIFFERENT message on the wire right now,
        // and `BodyFetchProcessor.process` would refuse the write anyway. Skip the round trip.
        //
        // ⚠️ **The check belongs HERE, at the funnel — not only in the callers.** It was first
        // placed in `MessageDetailViewModel.loadBody` alone, but `startBodyPoll` calls this
        // function directly on a 2s cadence and never re-runs the caller-side check, so a move
        // parked offline produced an IMAP round trip every two seconds for as long as the detail
        // view stayed open, each one guaranteed to be refused at the write. Every body path
        // converges here; the caller-side check now only decides which UI state to show.
        // (Found by audit.)
        if await bodyFetchIsBlockedByPendingAddress(for: message) {
            print("[MoveTrace] fetchBody — address not corroborated (move in flight), skipping fetch for \(message.id.prefix(40))")
            throw ProviderError.networkError(
                underlying: NSError(domain: "TabMail", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "This message is still being moved. Go back to the message list and open it again in a moment."])
            )
        }

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
        // 🚨 C3 — THE SAME ADDRESS HAZARD THE BODY GATE CLOSES, IN THE SIBLING READER.
        // The fetch below addresses the wire by `(message.folderPath, message.messageId)`.
        // `optimisticMoveToFolder` rewrites `folderPath` to the destination while leaving
        // the SOURCE UID in `messageId`, and on IMAP every folder has its own UID space —
        // so mid-move that pair names a DIFFERENT message and this returns a stranger's
        // attachment. Unlike the body path there is nothing downstream to catch it: the
        // bytes are previewed to the user and cached under this row's content key with this
        // row's identity stamp, after which every read check accepts them. Refuse instead;
        // the refusal clears in the DATABASE when `finishMove` re-keys the row — but NOT in an
        // already-open view, which keeps the pre-move header that `publishRekeys` never refreshes,
        // so the recovery is going back to the message list and reopening, not tapping again.
        // See `ProviderError.addressPendingMove` and `IOS-BODY-005`.
        guard await !attachmentFetchIsBlockedByPendingAddress(for: message) else {
            throw ProviderError.addressPendingMove(message.id)
        }
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

    /// Fetch older messages for infinite scroll. Returns the number of new rows
    /// materialised and the scroller's continuation signal — see
    /// `SyncEngine.fetchOlderMessages` for what `mayHaveMore` means and why it is
    /// NOT derived from `inserted`.
    func fetchOlderMessages(folders: [Folder]) async throws -> (inserted: Int, mayHaveMore: Bool) {
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
