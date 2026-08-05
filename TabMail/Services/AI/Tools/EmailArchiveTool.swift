/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `email_archive` tool matching TB addon's `email_archive.js`.
/// Resolves numeric IDs to real messages, shows confirmation card, then archives
/// via AccountManager's optimistic UI + pending operation queue.
struct EmailArchiveTool: AgentTool, Sendable {
    let name = "email_archive"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments, invocation: .noninteractive)
    }

    /// ADR-IOS-053: real entry point — delivers the confirmation card to the
    /// invoking session via `invocation.uiSink` (nil sink → declined fast-fail).
    func execute(arguments: [String: JSONValue], invocation: ToolInvocation) async throws -> String {
        // Parse unique_ids array (numeric IDs from ChatIdTranslator)
        let numericIds = EmailDeleteTool.parseUniqueIds(arguments)
        guard !numericIds.isEmpty else {
            return #"{"error": "missing or empty unique_ids array"}"#
        }

        // Resolve numeric IDs to MessageHeaders
        let translator = ctx.translator
        var resolved: [MessageHeader] = []
        /// Parallel to `resolved` — the agent-facing numeric id for each resolved
        /// header, so the per-id dispositions below can be reported back in the
        /// same vocabulary the agent used (T4.V8).
        var resolvedNumericIds: [Int] = []
        var emailDetails: [AgentToolRouter.ActionConfirmation.EmailDetail] = []
        var failedIds: [Int] = []

        for numericId in numericIds {
            guard let realId = await translator.toRealId(numericId) else {
                failedIds.append(numericId)
                continue
            }
            let header: MessageHeader? = try await ctx.db.read { db in
                try MessageHeader.fetchOne(db, key: realId)
            }
            // Demo boundary (ADR-IOS-038): headerAccessible blocks acting on a
            // real email from demo (and vice versa) via stale translator IDs.
            if let header, DemoToolGuard.headerAccessible(header) {
                resolved.append(header)
                resolvedNumericIds.append(numericId)
                emailDetails.append(.init(
                    numericId: numericId,
                    subject: header.subject.isEmpty ? "(No subject)" : header.subject,
                    from: header.from,
                    date: header.date
                ))
            } else {
                failedIds.append(numericId)
            }
        }

        if resolved.isEmpty {
            return #"{"error": "none of the specified emails could be found"}"#
        }

        // Suspend until user confirms or declines (cancellation-safe).
        let (confirmed, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .archive,
            emails: emailDetails,
            via: invocation.uiSink
        )

        guard confirmed else {
            print("[EmailArchiveTool] User declined to archive \(resolved.count) emails")
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to archive. This likely means the wrong emails were selected. Use inbox_read to verify the correct emails before retrying.",
            ] as [String: Any]))
        }

        // Perform archive via the coordinated overlay + FIFO write-queue path
        // (ADR-IOS-057 vicinity): re-resolves fresh headers INSIDE the queued
        // closure so the write acts on row truth at execution time, not this
        // `resolved` snapshot — which may have gone stale during the
        // unbounded confirmation wait above. `resolved` is still used for the
        // confirmation card display and the response payload below.
        //
        // 🚨 THE RE-RESOLVE NEEDS A WITNESS, OR IT ONLY ANSWERS "WHAT IS AT THIS
        // ADDRESS NOW". The confirmation wait is unbounded, and on IMAP the
        // address is a per-folder UID a UIDVALIDITY turnover reassigns — so
        // re-resolving `resolved.map(\.id)` alone can hand the archive a
        // DIFFERENT physical message, which every downstream address and epoch
        // check then correctly authenticates because it IS the row that was
        // resolved. `ExpectedMessageIdentity.map` captures the content witness
        // from the very headers already rendered on the confirmation card, so it
        // costs zero extra I/O, and the helper refuses any id whose row is
        // provably no longer that message. PORT of
        // `v2final:EmailArchiveTool.execute`, which passes the whole captured
        // `headers` to `recordRoleMove` for exactly this reason.
        let admission = await AccountManager.shared.performCoordinatedRoleMove(
            ids: resolved.map(\.id), role: .archive,
            expectedIdentities: ExpectedMessageIdentity.map(resolved))
        // T4.V8 (PORT of `v2final:EmailArchiveTool.execute`, commit `b1c89ad4a`):
        // report only DURABLY ADMITTED work as archived. This call previously
        // reported `"success": true` with `archived_count == resolved.count`
        // unconditionally, so a refused admission, a rolled-back write, or a
        // vanished row all read to the agent exactly like a completed archive.
        let actedHeaderIds = admission.admittedIds
        // A PENDING id is still outstanding and its outcome is unconfirmed — it
        // must never be reported as `failed`, or the agent may retry it itself
        // and act twice.
        let pendingHeaderIds = admission.pendingIds
        let terminalHeaderIds = admission.failedIds
        let acted = zip(resolvedNumericIds, resolved).filter { actedHeaderIds.contains($0.1.id) }
        let pendingIds = zip(resolvedNumericIds, resolved)
            .filter { pendingHeaderIds.contains($0.1.id) }
            .map(\.0)
        let terminalResolvedIds = zip(resolvedNumericIds, resolved)
            .filter { terminalHeaderIds.contains($0.1.id) }
            .map(\.0)
        failedIds.append(contentsOf: terminalResolvedIds)

        let subjects = acted.map { $0.1.subject.isEmpty ? "(No subject)" : $0.1.subject }
        let complete = acted.count == resolved.count
            && failedIds.isEmpty
            && pendingIds.isEmpty
        var result: [String: Any] = [
            "success": complete,
            "archived_count": acted.count,
            "archived_subjects": subjects,
        ]
        if !pendingIds.isEmpty {
            result["pending_ids"] = pendingIds
            result["pending_message"] =
                "\(pendingIds.count) email action(s) are still outstanding — their outcome could not be confirmed. Do not repeat the action."
        }
        if !failedIds.isEmpty {
            result["failed_ids"] = failedIds
            result["warning"] = "\(failedIds.count) email(s) could not be archived"
        }
        // A refusal by CONTENT IDENTITY needs its own line, not just a slot in
        // `failed_ids`: retrying the same unique_id fails identically forever
        // (the id names an address a different message now occupies), so an agent
        // told only "failed" will retry and get the same answer. Told this, it
        // re-reads and re-addresses. Refusing silently is not an option — the
        // user confirmed this archive and must learn it did not happen.
        let identityChangedIds = zip(resolvedNumericIds, resolved)
            .filter { admission.identityRefusedIds.contains($0.1.id) }
            .map(\.0)
        if !identityChangedIds.isEmpty {
            result["identity_changed_ids"] = identityChangedIds
            result["identity_changed_message"] =
                "\(identityChangedIds.count) email(s) were NOT archived: the message at that id is no longer the one shown on the confirmation card, so acting on it would have hit the wrong email. Use inbox_read to re-read the mailbox and confirm again with the new ids."
        }

        if DebugModeManager.isLoggingEnabled() {
            print("[EmailArchiveTool] Admitted \(acted.count), pending \(pendingIds.count), terminal \(failedIds.count)")
        }

        return ToolJSON.string(from: result)
    }
}
