/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import UIKit

/// The refusal classes `AccountManagerFetch.fetchBody` can throw, and the two facts a
/// caller needs about each: the user-facing sentence, and whether anything in the
/// background could still produce this body.
///
/// This exists because `MessageDetailViewModel` has to make that second decision.
/// `loadBody` ends with `if messageBody == nil { startBodyPoll() }`, a 2s cadence that
/// calls `fetchBody` directly. For a refusal nothing will retract, that loop pays a full
/// TCP + TLS + LOGIN + SELECT every two seconds for as long as the detail view lives
/// (`bodyPollTask` is cancelled only in `deinit`) — with no bound, since `fetchAttempt`
/// is logging only. Matching the refusal by its user-facing string would tie control flow
/// to copy; matching it by a bare `-1` would be the hardcoded numeric value the repo bans.
///
/// ⚠️ `payloadTooLarge` is terminal for the POLL, never for the user. An overflow is an
/// observation about one wire attempt — the parser's bound is on unread aggregate bytes
/// measured after the decode loop stops, so it is fragmentation-dependent — and
/// pull-to-refresh (`replaceExistingBody: true`) is exempt at the funnel and still reaches
/// the wire. Ending the poll removes the doomed cadence, not the retry.
enum BodyFetchRefusal {
    static let domain = "TabMail"

    /// The metadata FETCH overflowed the parser on this attempt.
    static let payloadTooLarge = -1
    /// A transient failure the caller may retry.
    static let retryable = -2
    /// A previously observed overflow is recorded durably against this row.
    static let quarantined = -4
    // -3 is deliberately vacant. It used to be `addressInFlight`, carrying a byte-identical
    // copy of `ProviderError.addressPendingMove`'s user-facing sentence. The funnel now
    // throws that typed case directly — the same one `fetchAttachment` throws roughly a
    // hundred lines below, and the one `ComposeView` matches BY TYPE. Two independent
    // copies of one recovery instruction is the `IOS-BODY-005` failure shape (its sentence
    // took three attempts to get right, each wrong one caught by a separate audit round),
    // and a caller copying `ComposeView`'s idiom around a body fetch would silently have
    // failed to match an NSError encoding. The number is left unused rather than reassigned
    // so a stale `-3` anywhere cannot quietly acquire a new meaning. (Found by audit.)

    static let payloadTooLargeMessage = "This message is too large to display."
    static let retryableMessage = "Failed to load message. Please try again."
    /// Shared TEXT for the funnel's refusal, `loadBody`'s quarantine branch and the
    /// poll's — not a shared rendered string, and on the detail surface not a shipped
    /// one either. Two qualifications, both established by audit:
    ///
    /// 1. `error(_:_:)` wraps the message in `ProviderError.networkError`, whose
    ///    `errorDescription` is `"Network error: \(underlying.localizedDescription)"`. So
    ///    a refusal that reaches the user through a caller's `error.localizedDescription`
    ///    carries that prefix, while the two branches that assign this constant directly
    ///    do not. For −1 and −2 the prefix is INHERITED — they have always been wrapped
    ///    this way — and is left alone rather than unwrapped at one call site, which
    ///    would trade a visible inconsistency for an invisible one. ⚠️ −4 is NOT
    ///    inherited: `BodyFetchRefusal.quarantined` is introduced by this change, so the
    ///    prefix on it is a deliberate choice to MATCH −1/−2 rather than a legacy left
    ///    undisturbed. An earlier version of this sentence said all three had "always"
    ///    been wrapped, which would have licensed the new class on an argument that did
    ///    not cover it. (Found by audit.)
    /// 2. `MessageCardView` renders `viewModel.error` only under
    ///    `DebugModeManager.isLoggingEnabled()`; a Release user sees its generic
    ///    "Unable to load message. Pull to retry." instead — which names the one path
    ///    that is exempt at the funnel. These constants are therefore the DEBUG-surface
    ///    text on that screen. Do not reword them expecting a user-visible change.
    static let quarantinedMessage = "Unable to load this message's content."

    static func error(_ code: Int, _ message: String) -> ProviderError {
        ProviderError.networkError(
            underlying: NSError(domain: domain, code: code,
                userInfo: [NSLocalizedDescriptionKey: message]))
    }

    /// True when no background path can produce this body, so a poll would only repeat a
    /// refusal.
    ///
    /// `retryable` (−2) is deliberately NOT included, and the mid-move refusal is excluded
    /// structurally rather than by omission: it is `ProviderError.addressPendingMove`, not
    /// a `.networkError`, so it fails the first `guard`. Both exclusions say the same
    /// thing — a transient failure clearing, or a move completing, IS the state change the
    /// poll is waiting for, so ending the poll on either would delete the poll's entire
    /// reason to exist. Pinned by `bodyFetchRefusalEndsPollingOnlyForTerminalClasses`,
    /// which walks every class rather than relying on a control that exits at the first
    /// guard. (Found by audit.)
    ///
    /// ⚠️ `payloadTooLarge` matters here for a state the durable flag cannot cover. Both
    /// `BodyFetchProcessor.markBodyMetadataOversized`'s `AND bodyComplete = 0` guard and
    /// `MessageHeader.isBodyQuarantined`'s `&& !bodyComplete` fail-safe are keyed on the
    /// row being incomplete — deliberately, so an evicted-but-fetched row can still
    /// recover. A row that WAS fetched, whose `messageBody` was then evicted by
    /// `BodyAssetMaintenance` (which leaves `bodyComplete = 1` by design), and whose
    /// re-fetch now overflows is therefore invisible to the flag at every site: nothing
    /// records it and nothing gates on it. Without this check that row polls forever.
    /// (Found by audit.)
    static func endsPolling(_ error: Error) -> Bool {
        guard case ProviderError.networkError(let underlying) = error else { return false }
        let ns = underlying as NSError
        guard ns.domain == domain else { return false }
        return ns.code == payloadTooLarge || ns.code == quarantined
    }
}

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

    func fetchBody(
        for message: MessageHeader,
        replaceExistingBody: Bool = false
    ) async throws {
        // Debug-gated (rule 12). Pre-existing and ungated until this change: it is a
        // diagnostic, and `folderPath` is a user-authored custom folder name.
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[FetchBody] Opening: id=\(message.id.prefix(40)) msgId=\(message.messageId.prefix(30)) folder=\(message.folderPath)")
        }

        // Body already loaded — nothing to do
        let hasBody = (try? await dbPool.read { db in try MessageBody.fetchOne(db, key: message.id) != nil }) ?? false
        guard replaceExistingBody || !hasBody else { return }

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
            // Debug-gated (rule 12), like its sibling at the top of this function.
            // Pre-existing and ungated until this change: gating one and leaving the other
            // makes the function read as compliant while it still logs in Release.
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[MoveTrace] fetchBody — address not corroborated (move in flight), skipping fetch for \(message.id.prefix(40))")
            }
            // The SAME typed case `fetchAttachment` throws for the same condition, so the
            // two mid-move refusals cannot drift apart and a `case ProviderError
            // .addressPendingMove` match works against either. Behaviour at both
            // `fetchBody` call sites is unchanged: `fetchBodyWithRetry` retries only
            // `messageNotFound` and `SyncEngine.isConnectionError`, and neither matches
            // this case nor the `NSError(domain: "TabMail", code: -3)` it replaces.
            throw ProviderError.addressPendingMove(message.id)
        }

        // Oversized-metadata quarantine: the last observed attempt at this message's
        // metadata FETCH overflowed the parser. A retry costs a full TCP + TLS + LOGIN +
        // SELECT, because `IMAPProvider.withFolderConnection` classifies
        // `PayloadTooLargeError` as unhealthy and tears the folder connection down — a cost
        // also paid by whatever else was using that connection. Refuse before the wire.
        //
        // ⚠️ **At the funnel, for the same reason the address gate above is.** Caller-side
        // gates alone were not enough: `MessageDetailViewModel.loadBody` checks the flag,
        // but `startBodyPoll` reaches this function directly on a 2s cadence, and
        // `loadThreadMessageBody` — a collapsed thread bubble the user expands — had no
        // check at all and paid the round trip on every tap, swallowing the failure into a
        // debug print. The caller-side checks now only decide which UI state to show.
        // (Found by audit.)
        //
        // Read FRESH rather than trusting the caller's `message`: a body queue can flag the
        // row while a detail view is open, and callers hold headers of varying age.
        //
        // `replaceExistingBody` is the deliberate escape hatch, and it is load-bearing:
        // pull-to-refresh is the ONE path that must still reach the wire. An overflow is an
        // observation about a single wire attempt — the parser's bound is on unread
        // aggregate bytes measured after the decode loop stops, so it is
        // fragmentation-dependent, not size-deterministic — never a verdict that the body is
        // unfetchable. Without this exemption the flag would be unfalsifiable by the user.
        if !replaceExistingBody {
            let quarantined: Bool = (try? await dbPool.read { db in
                try MessageHeader.fetchOne(db, key: message.id)?.isBodyQuarantined ?? false
            }) ?? false
            if quarantined {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[FetchBody] Refused — body quarantined (oversized metadata FETCH) for \(message.id.prefix(40))")
                }
                throw BodyFetchRefusal.error(
                    BodyFetchRefusal.quarantined, BodyFetchRefusal.quarantinedMessage)
            }
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
            item: item,
            provider: queue.provider,
            enableAI: true,
            // Every caller of `fetchBody` is user-driven: the detail-view paths
            // (open, poll, pull-to-refresh, thread load) and the chat agent's
            // `attachment_read_pdf`, run when the user asks about that message.
            // So this producer is user intent by construction: the AI enqueue it triggers is
            // window-exempt (ADR-IOS-078 pathway regating — the deferred-body
            // half of the manual-open exemption).
            aiWindowExempt: true,
            replaceExistingBody: replaceExistingBody
        )

        switch result {
        case .success, .confirmedEmpty:
            break
        case .payloadTooLarge:
            throw BodyFetchRefusal.error(
                BodyFetchRefusal.payloadTooLarge, BodyFetchRefusal.payloadTooLargeMessage)
        case .retry:
            throw BodyFetchRefusal.error(
                BodyFetchRefusal.retryable, BodyFetchRefusal.retryableMessage)
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
        // already-open view, which keeps the pre-move header that `publishMoveFinish` never refreshes,
        // so the recovery is going back to the message list and reopening, not tapping again.
        // See `ProviderError.addressPendingMove` and `IOS-BODY-005`.
        guard await !attachmentFetchIsBlockedByPendingAddress(for: message) else {
            throw ProviderError.addressPendingMove(message.id)
        }
        return try await fetchAttachment(
            accountId: message.accountId, messageId: message.messageId,
            folderPath: message.folderPath, section: section, encoding: encoding)
    }

    /// The files inside the attached email at `section` of `message`, for an
    /// attachment whose `AttachmentInfo.filesListedOnOpen` is set; called when the
    /// user opens that attached email. Throws when they could not be listed in
    /// full, so the caller shows the failure; opening the email again retries.
    /// Same address check as `fetchAttachment(for:)`: the list belongs to the
    /// message at `(folderPath, messageId)`.
    func fetchAttachedEmailAttachments(for message: MessageHeader, section: String) async throws -> [AttachmentInfo] {
        guard await !attachmentFetchIsBlockedByPendingAddress(for: message) else {
            throw ProviderError.addressPendingMove(message.id)
        }
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
        let messageId = message.messageId
        return try await queue.execute(priority: .userAction) {
            try await provider.fetchAttachedEmailAttachments(messageId: messageId, section: section)
        }
    }

    /// Download one attachment by its provider coordinates. The caller owns the
    /// address: a synced header goes through `fetchAttachment(for:)` and its
    /// pending-move check; #217 adoption passes the coordinates of the server copy
    /// it has just read (`ExternalDraftAdoption`).
    func fetchAttachment(
        accountId: String,
        messageId: String,
        folderPath: String,
        section: String,
        encoding: String?
    ) async throws -> Data {
        // Ensure provider exists
        if providers[accountId] == nil {
            guard let account = try? await dbPool.read({ db in try Account.fetchOne(db, key: accountId) }) else {
                throw ProviderError.notConnected
            }
            try await connectAccount(account)
        }
        guard let queue = workQueues[accountId] else {
            throw ProviderError.notConnected
        }
        let provider = queue.provider

        for attempt in 1...2 {
            do {
                return try await queue.execute(priority: .userAction) {
                    if let imapProvider = provider as? IMAPProvider {
                        return try await imapProvider.fetchAttachment(messageId: messageId, folder: folderPath, section: section, encoding: encoding)
                    } else if let gmailProvider = provider as? GmailProvider {
                        return try await gmailProvider.fetchAttachment(messageId: messageId, attachmentId: section)
                    } else if let exchangeProvider = provider as? ExchangeProvider {
                        return try await exchangeProvider.fetchAttachment(messageId: messageId, attachmentId: section)
                    }
                    throw ProviderError.notConnected
                }
            } catch let error where attempt == 1 && SyncEngine.isConnectionError(error) {
                // Pool self-heals: dead connections discarded on checkin(healthy: false),
                // next checkout creates a fresh one. Retry loop gives the pool a chance.
                BackgroundSyncLogger.logDebug("[Attachment] connection error, retrying: \(error)")
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

    /// Sync only specific folders (pull-to-refresh of the folders on screen).
    ///
    /// Each account connects (when it has no provider yet and is in `accounts`) and
    /// syncs its folders in its own task; an account's folders are sequential (shared
    /// IMAP connection). One account that cannot connect or sync never holds back or
    /// cancels another (#689): `waitForAll` waits for every task and rethrows the
    /// first error to finish, after every account has run. An account with no
    /// provider that is not in `accounts` is skipped. After its folders, each
    /// account in `accounts` runs one change read (`SyncEngine.backgroundDeltaSync`,
    /// #902); an account not in `accounts`, or one whose connect or re-list failed,
    /// gets no change read. Every folder synced here is followed (#1109,
    /// `SyncEngine.followFolders`), and after its account's listings and change
    /// read a catch-up run reconciles the whole of those folders
    /// (`SyncEngine.startAccessCatchUp`), which this call does not wait for.
    /// Returns whether a change read found its account busy (its follow-up flag
    /// set instead): the pull did not read that account, so its run is not a
    /// success for every account (it never clears the inbox banner).
    @discardableResult
    func syncFolders(_ folders: [Folder], connecting accounts: [Account]) async throws -> Bool {
        let grouped = Dictionary(grouping: folders) { $0.accountId }
        let affectedAccountIds = Array(grouped.keys)
        let accountsById = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        defer {
            // Clear phases for all accounts involved in this sync.
            Task { @MainActor in
                for id in affectedAccountIds {
                    AccountManagerState.shared.setSyncPhase(nil, forAccount: id)
                }
            }
        }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            for (accountId, accountFolders) in grouped {
                let connected = providers[accountId]
                let account = accountsById[accountId]
                guard connected != nil || account != nil else { continue }
                let syncEngine = self.syncEngine
                group.addTask {
                    // The user opened or refreshed these folders: they are followed
                    // from now on (#1109). Written first, before the connect and the
                    // listings, so an open while offline, or a listing that fails,
                    // still leaves them followed; and before the change read below,
                    // which then reads (or first baselines) them.
                    let accessed = accountFolders.filter { !$0.path.isEmpty }.map(\.id)
                    await syncEngine.followFolders(accessed)
                    var provider = connected
                    if provider == nil, let account {
                        do {
                            try await self.connectAccount(account)
                        } catch {
                            BackgroundSyncLogger.logDebug("[SyncFolders] connect failed for account \(accountId.prefix(6)); the other accounts still sync: \(error)")
                            throw error
                        }
                        provider = await self.provider(accountId: accountId)
                    }
                    // Removed while connecting (or connected with no mail provider): nothing to sync.
                    guard let provider else { return false }
                    // Pool creates connections on demand via checkout — no explicit connect needed.
                    for folder in accountFolders where !folder.path.isEmpty {
                        // Every listing goes through the one classifier (#755): an
                        // unproven listing publishes nothing and is listed again next
                        // pass. What the user sees is unchanged: a listing that ended
                        // with an error the refresh showed before (a lost connection)
                        // still ends the refresh with that error; a folder the server
                        // refused or no longer has, and an unconfirmed count, are
                        // skipped silently as before so the other folders still sync.
                        let outcome = try await syncEngine.syncFolderMessages(folder: folder, provider: provider)
                        guard case .unproven(_, _, let error) = outcome else { continue }
                        BackgroundSyncLogger.logDebug("[SyncFolders] listing of \(folder.name) proved nothing — listed again next pass")
                        guard let error else { continue }
                        if SyncEngine.isSelectFailedError(error) || error is ProviderListingUnconfirmed || isHttpGoneStatus(error) {
                            BackgroundSyncLogger.logDebug("[SyncFolders] \(folder.name) skipped: \(error)")
                            continue
                        }
                        throw error
                    }
                    // AI processing is now event-driven via ActiveBodyQueue → ActiveAIQueue.
                    // New headers from syncFolderMessages are automatically enqueued.

                    // Then one "what changed" read for the account (#902): the same pass
                    // the background sync runs, so a change made elsewhere to older mail
                    // or to a folder not on screen shows with this pull. Its deadline is
                    // taken here, once, and bounds it as a timeout too, as for the
                    // background and foreground passes. The read never waits for its
                    // turn: when another pass of the account runs, it sets the
                    // account's follow-up flag and reads nothing, and one stage 2
                    // follows when that pass ends (the sync design block in
                    // SyncEngineOneSyncAtATime.swift; #1289). So it never counts a
                    // wait for another pass's turn. The pass reports a failed read in its
                    // result (the refresh still succeeds, as in the background); a
                    // timeout or what it rethrows (a database error, a failed retry
                    // after a connection error) fails the refresh.
                    guard let account else { return false }
                    let timeout = SyncConfig.perAccountSyncTimeoutSeconds
                    let deadline = Date().addingTimeInterval(timeout)
                    let read = try await withTimeout(seconds: timeout) {
                        try await syncEngine.backgroundDeltaSync(account: account, deadline: deadline)
                    }
                    // Then the whole of each folder is reconciled (#1109): a catch-up
                    // run for these folders, started after the change read so a
                    // folder the reader has just baselined is one the catch-up may
                    // list. The refresh does not wait for it. When the read found
                    // the account busy, the run starts all the same: it waits in
                    // line like the follow-up (its time counts only inside the
                    // turn), lists an untracked folder by its access
                    // rule, and a tracked one's changes come through the
                    // follow-up's read. It may take the turn before the follow-up:
                    // a folder the follow-up has yet to baseline is then left to
                    // the ordinary catch-up.
                    await syncEngine.startAccessCatchUp(accountId: accountId, folderIds: accessed)
                    if DebugModeManager.isLoggingEnabled() {
                        let outcome = read.map { "changed=\($0.changed) reason=\($0.reason)" } ?? "busy, follow-up wanted"
                        BackgroundSyncLogger.logDebug("[SyncFolders] change read for account \(accountId.prefix(6)): \(outcome)")
                    }
                    return read == nil
                }
            }
            // Every account runs to the end; the first error is rethrown after
            // all of them (#689), as `waitForAll` does.
            var busy = false
            var firstError: (any Error)?
            while let result = await group.nextResult() {
                switch result {
                case .success(let skipped): busy = busy || skipped
                case .failure(let error): if firstError == nil { firstError = error }
                }
            }
            if let firstError { throw firstError }
            return busy
        }
    }
}
