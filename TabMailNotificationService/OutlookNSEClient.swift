/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Thin NSE-side wrapper over `Shared/API/GraphAPI`. No HTTP, no parsing,
/// no token refresh, no body extraction — all lifted to the shared layer.
/// Mirror of `GmailNSEClient` for Microsoft Graph / Outlook.
///
/// Only the two methods the NSE flow actually needs are exposed:
/// `fetchSingleMessage` (metadata) and `fetchRenderedBody`. History/delta
/// walking is NOT required here — worker payloads always carry the
/// exact `messageId`, so the NSE fetches that one message directly.
enum OutlookNSEClient {

    /// Fetch a single message's metadata via the shared `GraphAPI`. Converts
    /// the canonical `MessageMetadata` to the NSE's local `NSEMessageMetadata`.
    static func fetchSingleMessage(
        messageId: String,
        accessToken _: String,  // legacy — AuthSource supplies it
        refreshToken _: String?,
        accountId: String
    ) async -> NSEMessageMetadata? {
        let http = AuthedHTTP(
            auth: NSEAuthSource(accountId: accountId, provider: "outlook"),
            retry: .graph, logLabel: "NSE-Outlook"
        )
        do {
            let meta = try await GraphAPI.messageMetadata(http: http, id: messageId)
            // Graph's parentFolderId is the opaque folder ID that the main-app
            // sync layer stores as folderPath for this account's inbox. Using
            // it here keeps the NSE-inserted MessageHeader.id in sync with
            // what the main-app sync produces for the same message. If Graph
            // ever omits `parentFolderId` from the response (shouldn't happen —
            // we $select it — but defensive), we MUST NOT fall back to
            // "INBOX": that's not a valid Outlook folderPath and would reinstate
            // the duplicate-row / wasted-AI bug this code was written to fix.
            // Fail the fetch so the NSE delivers a passive notification and
            // the main-app sync materializes the header with the correct path.
            guard let folderPath = meta.folderPath, !folderPath.isEmpty else {
                NSELog.step("NSE fetchSingleMessage: Graph response missing parentFolderId for \(messageId) — refusing to stage with placeholder folderPath")
                return nil
            }
            // Graph has no raw-header concept — it returns typed recipient
            // objects. Mirror `ExchangeProvider.parseGraphMessage`'s writeback
            // format so the NSE-inserted row matches what sync's UPDATE
            // branch writes: email-only, comma-joined.
            let to = meta.to.map { $0.email }.joined(separator: ", ")
            let cc = meta.cc.map { $0.email }.joined(separator: ", ")
            let bcc = meta.bcc.map { $0.email }.joined(separator: ", ")
            return NSEMessageMetadata(
                messageId: meta.providerMessageId,
                threadId: meta.threadId,
                rfc822MessageId: meta.rfc822MessageId,
                senderName: meta.from.name.isEmpty ? meta.from.email : meta.from.name,
                senderEmail: meta.from.email,
                to: to,
                cc: cc,
                bcc: bcc,
                replyTo: meta.replyTo?.email,
                inReplyTo: meta.inReplyTo,
                references: meta.references,
                subject: meta.subject,
                snippet: meta.snippet,
                dateString: PromptFormatters.formatTimestampForAgent(meta.date),
                date: meta.date,
                isRead: meta.isRead,
                isFlagged: meta.isFlagged,
                hasAttachments: meta.hasAttachments,
                // Graph doesn't expose replied/forwarded per-message —
                // matches ExchangeProvider.parseGraphMessage which hardcodes
                // `isReplied: false, isForwarded: false`.
                isReplied: false,
                isForwarded: false,
                providerLabels: meta.providerLabels,
                folderPath: folderPath
            )
        } catch {
            NSELog.step("NSE fetchSingleMessage failed for \(messageId): \(String(describing: error))")
            return nil
        }
    }

    /// Fetch and render the full body via shared `BodyRenderer`. Persisted to
    /// NSE staging DB by `NotificationService` so the main-app merge can
    /// write `MessageBody` + FTS + `bodyComplete = !hasUnresolvedCIDs`
    /// without a redundant re-fetch. NSE passes no attachment fetcher
    /// (memory budget) and no ICS renderer (main app re-renders ICS on
    /// first display if needed).
    ///
    /// No body-size cap: `GraphAPI.messageFull` returns whatever Graph sends.
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
            auth: NSEAuthSource(accountId: accountId, provider: "outlook"),
            retry: .graph, logLabel: "NSE-Outlook"
        )
        // Compute headerId via the shared MessageIdentity helper; pass to
        // GraphAPI.messageFull so inline images route through BodyAssetStore
        // identically to main-app and Gmail/IMAP NSE paths.
        let headerId = MessageIdentity.headerId(
            accountId: accountId, folderPath: folderPath, messageId: messageId
        )
        do {
            let (_, rendered) = try await GraphAPI.messageFull(
                http: http, id: messageId, headerId: headerId
            )
            return rendered
        } catch {
            NSELog.step("NSE fetchRenderedBody failed for \(messageId): \(String(describing: error))")
            return nil
        }
    }
}
