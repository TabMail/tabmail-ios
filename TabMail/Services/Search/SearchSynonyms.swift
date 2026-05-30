/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// Email-specific synonym groups for search expansion.
// Ported from tabmail-native-fts/src/fts/synonyms.rs.

enum SearchSynonyms {

    /// Lookup table: word → full synonym group (including the word itself).
    /// Built once at static init from the raw groups below.
    static let map: [String: [String]] = {
        var m = [String: [String]]()
        for group in rawGroups {
            let normalized = group.map { $0.lowercased() }
            for word in normalized {
                if m[word] == nil {
                    m[word] = normalized.sorted()
                }
            }
        }
        return m
    }()

    /// Expand a single word to an FTS5 OR group if synonyms exist.
    /// Returns the original word unchanged if no synonyms found.
    static func expand(_ word: String) -> String {
        let key = word.lowercased()
        guard let group = map[key], group.count > 1 else {
            return word
        }
        let joined = group.joined(separator: " OR ")
        return "(\(joined))"
    }

    /// Check if a word would expand to an OR group.
    static func wouldExpand(_ word: String) -> Bool {
        let key = word.lowercased()
        guard let group = map[key] else { return false }
        return group.count > 1
    }

    // MARK: - Raw synonym groups (from Rust synonyms.rs)

    private static let rawGroups: [[String]] = [
        ["meeting", "call", "sync", "standup", "huddle", "session", "appointment"],
        ["call", "meeting", "phone", "dial", "ring", "conference"],
        ["conference", "meeting", "call", "webinar", "summit"],
        ["appointment", "meeting", "booking", "reservation", "slot"],
        ["schedule", "calendar", "agenda", "timetable", "plan"],
        ["reschedule", "postpone", "delay", "move", "push"],
        ["cancel", "cancelled", "abort", "drop", "revoke"],
        ["urgent", "asap", "immediately", "priority", "critical", "important", "rush"],
        ["asap", "urgent", "immediately", "priority", "rush", "soon"],
        ["important", "urgent", "priority", "critical", "key", "essential"],
        ["deadline", "due", "duedate", "cutoff", "target"],
        ["reminder", "followup", "nudge", "ping", "checkin"],
        ["attachment", "attached", "file", "document", "enclosed", "enclosure"],
        ["attached", "attachment", "enclosed", "file", "included"],
        ["document", "doc", "file", "paper", "pdf", "attachment"],
        ["file", "document", "attachment", "doc"],
        ["pdf", "document", "file", "acrobat"],
        ["spreadsheet", "excel", "xlsx", "xls", "sheet", "csv"],
        ["presentation", "ppt", "powerpoint", "slides", "deck"],
        ["report", "summary", "analysis", "review", "findings"],
        ["invoice", "bill", "payment", "receipt", "statement", "billing"],
        ["payment", "pay", "invoice", "remittance", "transfer", "transaction"],
        ["bill", "invoice", "payment", "charge", "fee"],
        ["receipt", "invoice", "confirmation", "proof"],
        ["quote", "quotation", "estimate", "proposal", "pricing", "bid"],
        ["budget", "cost", "expense", "spending", "allocation"],
        ["expense", "cost", "spending", "reimbursement", "claim"],
        ["approve", "approved", "approval", "authorize", "confirm", "signoff"],
        ["review", "feedback", "comments", "evaluate", "assess", "check"],
        ["feedback", "review", "comments", "input", "thoughts", "opinion"],
        ["confirm", "confirmation", "verified", "acknowledge", "approve"],
        ["reject", "rejected", "decline", "deny", "disapprove"],
        ["update", "status", "progress", "news", "latest"],
        ["status", "update", "progress", "state", "situation"],
        ["progress", "update", "status", "advancement", "development"],
        ["complete", "completed", "done", "finished", "ready"],
        ["pending", "waiting", "outstanding", "incomplete", "open"],
        ["team", "group", "squad", "crew", "staff"],
        ["manager", "supervisor", "boss", "lead", "director"],
        ["client", "customer", "account", "partner"],
        ["customer", "client", "user", "buyer"],
        ["vendor", "supplier", "provider", "contractor"],
        ["send", "sent", "forward", "share", "transmit"],
        ["forward", "fwd", "send", "share", "pass"],
        ["reply", "respond", "answer", "response"],
        ["request", "ask", "require", "need", "inquiry"],
        ["submit", "submitted", "send", "file", "deliver"],
        ["share", "send", "forward", "distribute", "circulate"],
        ["question", "query", "inquiry", "ask", "help"],
        ["help", "assist", "support", "aid", "guidance"],
        ["issue", "problem", "bug", "error", "trouble", "concern"],
        ["problem", "issue", "bug", "error", "trouble"],
        ["error", "bug", "issue", "problem", "mistake", "failure"],
        ["today", "now"],
        ["tomorrow"],
        ["week", "weekly"],
        ["month", "monthly"],
        ["project", "initiative", "program", "effort", "work"],
        ["task", "todo", "action", "item", "job", "assignment"],
        ["milestone", "deliverable", "checkpoint", "goal", "target"],
        ["launch", "release", "deploy", "ship", "rollout", "golive"],
        ["contract", "agreement", "deal", "terms", "nda"],
        ["agreement", "contract", "deal", "terms", "arrangement"],
        ["sign", "signature", "execute", "approve", "authorize"],
        ["legal", "law", "attorney", "lawyer", "counsel", "compliance"],
        ["travel", "trip", "flight", "booking", "itinerary"],
        ["flight", "travel", "airline", "plane", "booking"],
        ["hotel", "accommodation", "lodging", "booking", "stay"],
        ["booking", "reservation", "travel", "flight", "hotel"],
    ]
}
