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

        // Perform archive via an intention record (ADR-IOS-058): the fold
        // executor's `.role` branch re-resolves fresh headers at execution
        // time so the write acts on row truth, not this `resolved` snapshot —
        // which may have gone stale during the unbounded confirmation wait
        // above. `resolved` is still used for the confirmation card display
        // and the response payload below.
        let actedHeaderIds = await AccountManager.shared.recordRoleMove(
            ids: resolved.map(\.id),
            role: .archive,
            origin: .tool
        )
        let acted = zip(resolvedNumericIds, resolved).filter { actedHeaderIds.contains($0.1.id) }
        let refusedResolvedIds = zip(resolvedNumericIds, resolved)
            .filter { !actedHeaderIds.contains($0.1.id) }
            .map(\.0)
        failedIds.append(contentsOf: refusedResolvedIds)

        let subjects = acted.map { $0.1.subject.isEmpty ? "(No subject)" : $0.1.subject }
        var result: [String: Any] = [
            "success": !acted.isEmpty,
            "archived_count": acted.count,
            "archived_subjects": subjects,
        ]
        if !failedIds.isEmpty {
            result["failed_ids"] = failedIds
            result["warning"] = "\(failedIds.count) email(s) could not be archived"
        }

        print("[EmailArchiveTool] Archived \(acted.count) emails, \(failedIds.count) failed")

        return ToolJSON.string(from: result)
    }
}
