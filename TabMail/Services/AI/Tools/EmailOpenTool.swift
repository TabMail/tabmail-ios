/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Client-side `email_open` tool — opens an email in the message detail view.
/// Resolves a numeric unique_id to a real MessageHeader, then posts a notification
/// to navigate. Works regardless of which folder the email is in.
struct EmailOpenTool: AgentTool, Sendable {
    let name = "email_open"
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
            print("[EmailOpenTool] Failed to resolve numeric id \(numericId)")
            return #"{"error": "message not found for the given unique_id"}"#
        }

        // Verify the message exists in GRDB
        guard let header: MessageHeader = try await ctx.db.read({ db in
            try MessageHeader.fetchOne(db, key: realId)
        }) else {
            print("[EmailOpenTool] MessageHeader not found for realId=\(realId)")
            return #"{"error": "message not found"}"#
        }

        // Demo boundary (ADR-IOS-038): never navigate across the demo/real line.
        guard DemoToolGuard.headerAccessible(header) else {
            print("[EmailOpenTool] Blocked cross-boundary access to \(realId.prefix(30))")
            return #"{"error": "message not found"}"#
        }

        // Navigate to the email via notification (handled by MailNavigationView + InboxView)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .emailPillTapped,
                object: nil,
                userInfo: ["numericId": numericId, "realId": realId]
            )
        }

        let subject = header.subject.isEmpty ? "(No subject)" : header.subject
        print("[EmailOpenTool] Opening email numericId=\(numericId) realId=\(realId.prefix(30)) subject=\(subject.prefix(40))")

        return ToolJSON.string(from: [
            "success": true,
            "message": "Opened email: \(subject)",
            "subject": subject,
            "from": header.from,
        ] as [String: Any])
    }
}
