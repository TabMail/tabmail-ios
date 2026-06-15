/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import os

private let log = OSLog(subsystem: "ai.tabmail.nse", category: "gmail")

/// Thin NSE-side wrapper over `Shared/API/GmailAPI`. No HTTP, no parsing,
/// no token refresh, no body extraction — all lifted to the shared layer.
/// Previous duplication of `callAPI`, `refreshAccessToken`,
/// `parseMessageMetadata`, `extractTextPlain` removed.
///
/// Returns `HistoryResult` (NSE-specific — counts badge-affecting changes)
/// built from the canonical `HistoryDelta` and `NSEMessageMetadata` built
/// from the canonical `MessageMetadata`.
enum GmailNSEClient {
    /// NSE-specific history result: added + removed inbox messages + label-change
    /// counts used to adjust the badge count in `NSEState`.
    struct HistoryResult {
        let addedMessageIds: [String]
        let removedMessageIds: [String]
        let unreadRemovedCount: Int
        let markedReadCount: Int
        let markedUnreadCount: Int
        let latestHistoryId: String?
    }

    /// Fetch inbox changes via the shared GmailAPI. Filters to INBOX label +
    /// computes NSE-specific badge deltas from the canonical HistoryDelta.
    static func fetchNewMessageIds(
        accessToken _: String,  // legacy parameter, unused — AuthSource supplies the token now
        refreshToken _: String?,
        historyId: String?,
        accountId: String
    ) async -> HistoryResult {
        guard historyId != nil else { return .empty }
        guard let startHistoryId = NSEState.getLastHistoryId(for: accountId) else {
            return .empty
        }

        let http = AuthedHTTP(
            auth: NSEAuthSource(accountId: accountId, provider: "gmail"),
            retry: .gmail, logLabel: "NSE-Gmail"
        )

        let delta: HistoryDelta?
        do {
            delta = try await GmailAPI.historyList(
                http: http,
                startHistoryId: startHistoryId,
                historyTypes: ["messageAdded", "labelRemoved", "labelAdded"],
                labelId: "INBOX"
            )
        } catch {
            os_log(.error, log: log, "NSE history.list failed: %{public}@", String(describing: error))
            return .empty
        }
        guard let delta else {
            os_log(.error, log: log, "NSE history.list: 404 — historyId expired; main app will recover via full sync")
            return .empty
        }

        let addedIds = delta.added
            .filter { $0.providerLabels.contains("INBOX") }
            .map { $0.providerMessageId }
        let addedSet = Set(addedIds)

        var removedIds: [String] = []
        var unreadRemovedCount = 0
        var markedReadCount = 0
        for change in delta.labelsRemoved {
            if change.labelIds.contains("INBOX") {
                removedIds.append(change.providerMessageId)
                if change.currentLabels.contains("UNREAD") { unreadRemovedCount += 1 }
            } else if change.labelIds.contains("UNREAD") && change.currentLabels.contains("INBOX") {
                markedReadCount += 1
            }
        }

        var markedUnreadCount = 0
        for change in delta.labelsAdded {
            // Exclude messages that ALSO appear as new arrivals (messageAdded):
            // a brand-new message is badge-counted on delivery (badgeForDelivery
            // on the head) or by the main app's sync (the tail) — counting it
            // here too would double-bump. labelsAdded(UNREAD) should only move
            // the badge for messages that were ALREADY in the inbox and got
            // re-marked unread on another client.
            if change.labelIds.contains("UNREAD") && change.currentLabels.contains("INBOX")
                && !addedSet.contains(change.providerMessageId) {
                markedUnreadCount += 1
            }
        }

        // Don't notify for messages added then immediately removed in same batch.
        let removedSet = Set(removedIds)
        let filteredAdded = addedIds.filter { !removedSet.contains($0) }

        os_log(.error, log: log, "NSE history: +%d added -%d removed unreadRm=%d markRd=%d markUnrd=%d",
               filteredAdded.count, removedIds.count, unreadRemovedCount, markedReadCount, markedUnreadCount)

        return HistoryResult(
            addedMessageIds: filteredAdded,
            removedMessageIds: removedIds,
            unreadRemovedCount: unreadRemovedCount,
            markedReadCount: markedReadCount,
            markedUnreadCount: markedUnreadCount,
            latestHistoryId: delta.cursor.isEmpty ? nil : delta.cursor
        )
    }

    /// Fetch a single message's metadata via the shared GmailAPI. Converts the
    /// canonical `MessageMetadata` to the NSE's local `NSEMessageMetadata`.
    static func fetchSingleMessage(
        messageId: String,
        accessToken _: String,  // legacy — AuthSource supplies it
        refreshToken _: String?,
        accountId: String
    ) async -> NSEMessageMetadata? {
        let http = AuthedHTTP(
            auth: NSEAuthSource(accountId: accountId, provider: "gmail"),
            retry: .gmail, logLabel: "NSE-Gmail"
        )
        do {
            let (meta, json) = try await GmailAPI.messageMetadata(http: http, id: messageId)
            // Use the RAW RFC 2822 header values (not MessageMetadata's parsed
            // [EmailAddress] list) so the row the merge inserts is byte-
            // identical to what main-app sync would write via
            // `GmailProvider.parseGmailMessage` — see that adapter which also
            // uses `GmailParse.rawHeader`. Matching exactly avoids a write
            // delta (and ValueObservation re-render) when sync's UPDATE
            // eventually runs over the same row.
            let rawTo = GmailParse.rawHeader(json, name: "To") ?? ""
            let rawCc = GmailParse.rawHeader(json, name: "Cc") ?? ""
            let rawBcc = GmailParse.rawHeader(json, name: "Bcc") ?? ""
            let rawReplyTo = GmailParse.rawHeader(json, name: "Reply-To")
            return NSEMessageMetadata(
                messageId: meta.providerMessageId,
                threadId: meta.threadId,
                rfc822MessageId: meta.rfc822MessageId,
                senderName: meta.from.name.isEmpty ? meta.from.email : meta.from.name,
                senderEmail: meta.from.email,
                to: rawTo,
                cc: rawCc,
                bcc: rawBcc,
                replyTo: rawReplyTo,
                inReplyTo: meta.inReplyTo,
                references: meta.references,
                subject: meta.subject,
                snippet: meta.snippet,
                dateString: PromptFormatters.formatTimestampForAgent(meta.date),
                date: meta.date,
                isRead: meta.isRead,
                isFlagged: meta.isFlagged,
                hasAttachments: meta.hasAttachments,
                // Gmail REST doesn't expose replied/forwarded per-message —
                // matches GmailProvider.parseGmailMessage which hardcodes
                // `isReplied: false, isForwarded: false`.
                isReplied: false,
                isForwarded: false,
                providerLabels: meta.providerLabels,
                // Gmail pushed arrivals always carry the INBOX label; fall back
                // defensively so the main-app merge-side id stays valid even
                // if labels were missing in the response.
                folderPath: meta.folderPath ?? "INBOX"
            )
        } catch {
            os_log(.error, log: log, "NSE fetchSingleMessage failed for %{public}@: %{public}@",
                   messageId, String(describing: error))
            return nil
        }
    }

    /// Fetch and render the full body via shared `BodyRenderer`. Persisted to
    /// NSE staging DB by `NotificationService` so the main-app merge can write
    /// `MessageBody` + FTS + `bodyComplete = !hasUnresolvedCIDs` without a
    /// redundant re-fetch. NSE passes no attachment fetcher (memory budget)
    /// and no ICS renderer (main app re-renders ICS on first display if needed).
    ///
    /// No body-size cap: `GmailAPI.messageFull` returns whatever Gmail sends.
    /// The NSE's ~24MB process budget is our only ceiling — if a truly huge
    /// email OOMs the NSE, iOS falls back to the default push payload and
    /// the main app fetches the real body on the next wake. Silent truncation
    /// here (the prior 4KB cap) was strictly worse: it baked a short body
    /// into MessageBody and flipped bodyComplete=1, so the main-app body
    /// queue never re-fetched.
    static func fetchRenderedBody(
        messageId: String,
        folderPath: String,
        accessToken _: String,
        refreshToken _: String?,
        accountId: String
    ) async -> RenderedBody? {
        let http = AuthedHTTP(
            auth: NSEAuthSource(accountId: accountId, provider: "gmail"),
            retry: .gmail, logLabel: "NSE-Gmail"
        )
        // Compute the canonical headerId via the shared `MessageIdentity` helper —
        // identical to what the main-app merge will use when persisting MessageBody.
        // Passing it through to `GmailAPI.messageFull` routes inline images
        // through `BodyAssetStore.makeInlineImageWriter(forHeaderId:)` so NSE-
        // written assets land at the same paths the main app reads.
        let headerId = MessageIdentity.headerId(
            accountId: accountId, folderPath: folderPath, messageId: messageId
        )
        do {
            let (_, rendered) = try await GmailAPI.messageFull(
                http: http, id: messageId, headerId: headerId
            )
            return rendered
        } catch {
            os_log(.error, log: log, "NSE fetchRenderedBody failed for %{public}@: %{public}@",
                   messageId, String(describing: error))
            return nil
        }
    }
}

private extension GmailNSEClient.HistoryResult {
    static let empty = GmailNSEClient.HistoryResult(
        addedMessageIds: [], removedMessageIds: [],
        unreadRemovedCount: 0, markedReadCount: 0, markedUnreadCount: 0,
        latestHistoryId: nil
    )
}
