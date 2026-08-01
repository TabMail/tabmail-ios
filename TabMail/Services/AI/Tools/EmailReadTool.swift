/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `email_read` tool matching TB addon's `email_read.js`.
/// Returns full email content (headers + body) for a given unique_id.
/// Registered in `ToolRegistry` at app startup.
struct EmailReadTool: AgentTool, Sendable {
    let name = "email_read"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Parse unique_id (numeric ID from ChatIdTranslator)
        let numericId: Int
        if case .int(let n) = arguments["unique_id"] {
            numericId = n
        } else if case .string(let s) = arguments["unique_id"], let n = Int(s) {
            numericId = n
        } else if case .double(let d) = arguments["unique_id"] {
            numericId = Int(d)
        } else {
            return #"{"error": "invalid or missing unique_id"}"#
        }

        // Resolve numeric ID to real MessageHeader ID
        let translator = ctx.translator
        guard let realId = await translator.toRealId(numericId) else {
            print("[EmailReadTool] Failed to resolve numeric id \(numericId)")
            return #"{"error": "message not found for the given unique_id"}"#
        }

        // Fetch MessageHeader from GRDB
        guard let header: MessageHeader = try await ctx.db.read({ db in
            try MessageHeader.fetchOne(db, key: realId)
        }) else {
            print("[EmailReadTool] MessageHeader not found for realId=\(realId)")
            return #"{"error": "message not found"}"#
        }

        // Demo boundary (ADR-IOS-038): never read across the demo/real line
        // (stale ChatIdTranslator numeric IDs can reference the other side).
        guard DemoToolGuard.headerAccessible(header) else {
            print("[EmailReadTool] Blocked cross-boundary access to \(realId.prefix(30))")
            return #"{"error": "message not found"}"#
        }

        // Fetch MessageBody (full HTML content)
        let body: MessageBody? = try await ctx.db.read { db in
            try MessageBody.fetchOne(db, key: realId)
        }

        // Extract plain text from HTML for LLM consumption. The MessageBody row
        // is an evictable display cache — for older messages it's often absent
        // while the full body TEXT is still indexed in FTS, so fall back to
        // that before degrading to the snippet.
        let bodyText: String
        if let html = body?.htmlContent, !html.isEmpty {
            bodyText = EmailFilter.htmlToPlainText(html)
        } else if let ftsBody = try? await SearchIndex.shared.bodyText(
            contentKey: ContentKey(rawValue: realId)), !ftsBody.isEmpty {
            bodyText = ftsBody
        } else {
            bodyText = header.snippet
        }

        // Format output matching TB's email_read.js format
        var lines: [String] = []
        lines.append("unique_id: \(numericId)")
        lines.append("date: \(ToolFormatters.formatDate(header.date))")
        lines.append("from: \(ToolFormatters.formatFrom(header))")
        lines.append("to: \(header.to)")
        lines.append("cc: \(header.cc)")
        lines.append("subject: \(header.subject.isEmpty ? "(No subject)" : header.subject)")
        lines.append("has_attachments: \(header.hasAttachments ? "yes" : "no")")
        lines.append("replied: \(header.isReplied ? "yes" : "no")")
        lines.append("body:")
        lines.append(bodyText)

        // Include attachment metadata if available
        if let attachments = body?.attachments, !attachments.isEmpty {
            lines.append("")
            lines.append("attachments:")
            for att in attachments {
                lines.append("  - \(att.filename) (\(att.contentType), \(att.size) bytes)")
            }
        }

        print("[EmailReadTool] Returning content for numericId=\(numericId) realId=\(realId.prefix(30)) bodyLen=\(bodyText.count)")
        return lines.joined(separator: "\n")
    }

}
