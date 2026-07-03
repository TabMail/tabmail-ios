/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `email_delete` tool matching TB addon's `email_delete.js`.
/// Resolves numeric IDs to real messages, shows confirmation card, then deletes
/// via AccountManager's optimistic UI + pending operation queue.
struct EmailDeleteTool: AgentTool, Sendable {
    let name = "email_delete"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Parse unique_ids array (numeric IDs from ChatIdTranslator)
        let numericIds = Self.parseUniqueIds(arguments)
        guard !numericIds.isEmpty else {
            return #"{"error": "missing or empty unique_ids array"}"#
        }

        // Resolve numeric IDs to MessageHeaders
        let translator = ctx.translator
        var resolved: [MessageHeader] = []
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
            action: .delete,
            emails: emailDetails
        )

        guard confirmed else {
            print("[EmailDeleteTool] User declined to delete \(resolved.count) emails")
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to delete. This likely means the wrong emails were selected. Use inbox_read to verify the correct emails before retrying.",
            ] as [String: Any]))
        }

        // Perform delete via AccountManager (optimistic UI + pending queue)
        await AccountManager.shared.delete(resolved)

        let subjects = resolved.map { $0.subject.isEmpty ? "(No subject)" : $0.subject }
        var result: [String: Any] = [
            "success": true,
            "deleted_count": resolved.count,
            "deleted_subjects": subjects,
        ]
        if !failedIds.isEmpty {
            result["failed_ids"] = failedIds
            result["warning"] = "\(failedIds.count) email(s) could not be found"
        }

        print("[EmailDeleteTool] Deleted \(resolved.count) emails, \(failedIds.count) failed")

        return ToolJSON.string(from: result)
    }

    // MARK: - Helpers

    /// Parse unique_ids from arguments — handles array of ints, strings, or mixed.
    static func parseUniqueIds(_ arguments: [String: JSONValue]) -> [Int] {
        if case .array(let arr) = arguments["unique_ids"] {
            return arr.compactMap { item -> Int? in
                switch item {
                case .int(let n): return n
                case .string(let s): return Int(s)
                case .double(let d): return Int(d)
                default: return nil
                }
            }
        }
        // Also accept a single unique_id for convenience
        if case .int(let n) = arguments["unique_id"] {
            return [n]
        }
        if case .string(let s) = arguments["unique_id"], let n = Int(s) {
            return [n]
        }
        return []
    }
}
