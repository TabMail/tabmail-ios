/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import os

/// One-shot IMAP fetcher used by the NSE on `imap_new_mail` pushes.
///
/// Lifecycle: connect → login → SELECT INBOX → UID SEARCH by Message-ID →
/// UID FETCH → LOGOUT. No pool, no IDLE, no caching; the NSE runs in a
/// 24 MB / 30 s sandbox so we do the minimum per push and then hand the
/// socket back to the OS.
///
/// Memory notes:
///   • SwiftMail pulls in SwiftNIO + NIOSSL. Static-link overhead ~2–4 MB
///     per architecture. Per-live-connection RSS ~1–2 MB steady-state.
///   • We SELECT a single mailbox (INBOX) and issue a single UID SEARCH +
///     UID FETCH. No BODYSTRUCTURE walking beyond what SwiftMail does
///     internally for `fetchMessage(from:)`.
///
/// Safety notes:
///   • No credentials are ever logged. We redact email/username in the
///     os_log output and never emit the password.
///   • The connection is always closed (LOGOUT) in a `defer`, even on
///     throw. If LOGOUT fails (server unreachable), we just drop the
///     socket and let TCP reset — the memory is local and dies with
///     the NSE process anyway.
private let log = OSLog(subsystem: "ai.tabmail.nse", category: "imap")

enum NSEIMAPConnection {

    /// Fetch one message by its RFC 5322 Message-ID. Returns `nil` on any
    /// failure (connection, auth, search empty, fetch empty). The caller
    /// falls back to a passive notification.
    ///
    /// `rfc822MessageId` may be enclosed in angle brackets (`<abc@x.y>`) or
    /// bare (`abc@x.y`). Both forms are tried to cope with server quirks.
    static func fetch(
        accountId: String,
        host: String,
        port: Int,
        useTLS: Bool?,
        username: String,
        password: String,
        rfc822MessageId: String,
        folderPath: String = "INBOX"
    ) async -> (metadata: NSEMessageMetadata, body: RenderedBody)? {
        let server = IMAPServer(
            host: host,
            port: port,
            useTLS: useTLS,
            responseBufferLimit: IMAPFetchMapping.responseBufferLimit
        )

        do {
            try await server.connect()
        } catch {
            os_log(.error, log: log, "NSE IMAP connect failed: %{public}@", String(describing: error))
            return nil
        }

        // Run the rest of the flow, then ALWAYS await logout inline before
        // returning — a detached `defer { Task { ... } }` can be collected
        // before the NSE process is reaped, leaking the socket. Keeping
        // cleanup synchronous guarantees the logout completes (or fails
        // fast) within our budget.
        let result = await performFetch(
            server: server,
            accountId: accountId,
            username: username,
            password: password,
            rfc822MessageId: rfc822MessageId,
            folderPath: folderPath
        )

        try? await server.logout()
        return result
    }

    /// Inner flow (login → select → search → fetch → map). Called from
    /// `fetch(...)` with a connected but not-yet-authenticated server.
    /// Wrapping the flow lets the outer `fetch(...)` always await logout
    /// on ALL return paths without scattering try-finally blocks.
    private static func performFetch(
        server: IMAPServer,
        accountId: String,
        username: String,
        password: String,
        rfc822MessageId: String,
        folderPath: String
    ) async -> (metadata: NSEMessageMetadata, body: RenderedBody)? {
        do {
            try await server.login(username: username, password: password)
        } catch {
            os_log(.error, log: log, "NSE IMAP login failed — auth rejected or server error: %{public}@", String(describing: error))
            return nil
        }

        do {
            _ = try await server.selectMailbox(folderPath)
        } catch {
            os_log(.error, log: log, "NSE IMAP SELECT %{public}@ failed: %{public}@", folderPath, String(describing: error))
            return nil
        }

        // Try bracketed form first, then bare — same quirk handling the
        // main-app `searchByMessageId` uses. Normalization strips stray
        // whitespace / existing brackets in case the droplet's Message-ID
        // header parser returned something slightly off.
        let normalized = normalizeMessageId(rfc822MessageId)
        guard let uidSet = await searchMessageId(server: server, normalized: normalized),
              !uidSet.isEmpty,
              let uid = uidSet.toArray().first else {
            os_log(.error, log: log, "NSE IMAP SEARCH returned no UIDs for message id")
            return nil
        }

        // Fetch the one message the push pointed us at.
        let info: MessageInfo?
        do {
            info = try await server.fetchMessageInfo(for: uid)
        } catch {
            os_log(.error, log: log, "NSE IMAP FETCH info failed: %{public}@", String(describing: error))
            return nil
        }
        guard let info else {
            os_log(.error, log: log, "NSE IMAP FETCH info returned nil")
            return nil
        }

        let message: Message
        do {
            message = try await server.fetchMessage(from: info)
        } catch {
            os_log(.error, log: log, "NSE IMAP FETCH message failed: %{public}@", String(describing: error))
            return nil
        }

        // Build `NSEMessageMetadata` + `RenderedBody` via the SAME shared
        // pipeline the main app's IMAP body fetch uses
        // (`IMAPFetchMapping.buildRawBodyIngredients` → `BodyRenderer.render`
        // with `ICSBuilder`-backed icsRenderer). Both targets now route
        // through `IMAPFetchMapping.renderBody(info:message:)` so
        // attachment/inline-image/ICS/embedded-.eml handling is byte-
        // identical to `IMAPProvider.buildFullMessageInfo`.
        guard let meta = mapInfoToMetadata(info: info, message: message, folderPath: folderPath) else {
            os_log(.error, log: log, "NSE IMAP: mapInfoToMetadata returned nil (parse failure)")
            return nil
        }

        // Compute headerId via the shared MessageIdentity helper (identical to
        // what main-app merge will use). Threaded through `renderBody` so inline
        // images route through `BodyAssetStore.makeInlineImageWriter(forHeaderId:)`
        // — same factory the main-app and Gmail/Outlook NSE paths use, so disk
        // assets land at identical paths across targets, by construction.
        let headerId = MessageIdentity.headerId(
            accountId: accountId, folderPath: folderPath, messageId: meta.messageId
        )
        let rendered = await IMAPFetchMapping.renderBody(
            info: info, message: message, headerId: headerId
        )
        return (meta, rendered)
    }

    // MARK: - Helpers

    private static func searchMessageId(server: IMAPServer, normalized: String) async -> UIDSet? {
        // Bracketed — most servers match on the canonical "<id>" form.
        do {
            let ext: ExtendedSearchResult<UID> = try await server.extendedSearch(
                criteria: [.header("Message-ID", "<\(normalized)>")]
            )
            let bracketed: UIDSet = ext.asSet
            if !bracketed.isEmpty { return bracketed }
        } catch {
            os_log(.error, log: log, "NSE IMAP SEARCH (bracketed) failed: %{public}@", String(describing: error))
            // fall through to bare
        }
        do {
            let ext: ExtendedSearchResult<UID> = try await server.extendedSearch(
                criteria: [.header("Message-ID", normalized)]
            )
            return ext.asSet
        } catch {
            os_log(.error, log: log, "NSE IMAP SEARCH (bare) failed: %{public}@", String(describing: error))
            return nil
        }
    }

    /// Normalize a Message-ID to bare (no angle brackets, no whitespace).
    /// Local copy — the shared `EmailFilter.normalizeMessageId` is in the
    /// main app target; re-implementing the 6 lines here avoids a cross-
    /// target Shared/ refactor that would be broader than Block E warrants.
    private static func normalizeMessageId(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") { s = String(s.dropFirst()) }
        if s.hasSuffix(">") { s = String(s.dropLast()) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mapInfoToMetadata(
        info: MessageInfo,
        message: Message,
        folderPath: String
    ) -> NSEMessageMetadata? {
        // Sender — SwiftMail's `info.from` is a raw RFC5322 string like
        // `"Alice" <alice@example.com>`. Use shared EmailAddress.parse.
        let fromStr = info.from ?? ""
        let from = EmailAddress.parse(fromStr)
        let senderName = from.name.isEmpty ? from.email : from.name
        let senderEmail = from.email

        let subject = info.subject ?? ""
        // Pure helpers — see `IMAPFetchMapping` for the messageId / rfc822
        // format rules and the bug history that drove them.
        let messageId = IMAPFetchMapping.messageIdString(from: info)
        let rfc822 = IMAPFetchMapping.rfc822MessageId(from: info)

        // Prefer INTERNALDATE; fall back to parsed Date: header. A missing
        // date is fine here — `NSEMessageMetadata.dateString` stays the
        // pretty-formatted value if present, empty otherwise.
        let date: Date? = info.internalDate ?? info.date
        let dateString = date.map { PromptFormatters.formatTimestampForAgent($0) } ?? ""

        // `snippet` — we don't compute one here; the AI pipeline uses the
        // rendered body directly, and the notification builder uses
        // subject. Keep the field present as empty so the downstream
        // PromptVariables.summaryVariables path doesn't see nil.
        let snippet = ""

        // Recipient strings: match `IMAPProvider.buildMessageHeaderInfo`'s
        // `info.to.joined(separator: ", ")` format exactly so sync's UPDATE
        // branch doesn't produce a write delta against the NSE row. SwiftMail
        // exposes `info.replyTo` only since the Dec-2025 fork bump; earlier
        // callers (main-app IMAP builder, line 1872) hardcoded nil, so keep
        // that parity until main-app wires replyTo up.
        let to = info.to.joined(separator: ", ")
        let cc = info.cc.joined(separator: ", ")
        let bcc = info.bcc.joined(separator: ", ")

        return NSEMessageMetadata(
            messageId: messageId,
            threadId: nil,
            rfc822MessageId: rfc822,
            senderName: senderName,
            senderEmail: senderEmail,
            to: to,
            cc: cc,
            bcc: bcc,
            replyTo: nil,
            inReplyTo: IMAPFetchMapping.inReplyTo(from: info),
            references: IMAPFetchMapping.references(from: info),
            subject: subject,
            snippet: snippet,
            dateString: dateString,
            date: date,
            isRead: info.flags.contains(.seen),
            isFlagged: info.flags.contains(.flagged),
            hasAttachments: IMAPFetchMapping.hasAttachments(from: info),
            // Parity with IMAPProvider.buildMessageHeaderInfo:1886-1887.
            isReplied: info.flags.contains(.answered),
            isForwarded: info.flags.contains(.custom("$Forwarded")),
            // Raw custom keywords — merge filters tm_* + excluded in the
            // main-app target where `UserLabelStore.isExcludedKeyword` is
            // available. This mirrors how main-app `IMAPProvider` already
            // handles it (line 1840-1848 of IMAPProvider.swift).
            providerLabels: IMAPFetchMapping.customKeywords(from: info),
            folderPath: folderPath
        )
    }

}
