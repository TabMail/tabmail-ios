/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - JobType

/// Discriminator for the polymorphic pendingAIRefinement table.
enum BackfillAIJobType: String, Codable, Sendable {
    case actionRefine  // autoUpdateUserPromptOnTag
    case kbRefine      // refineKB on chat session idle-expiry
}

// MARK: - Snapshot payloads
//
// Each job type has its own payload struct. The snapshot is built at capture
// time (enqueue site) and written to the `payloadJSON` column. The dispatcher
// decodes it at drain time and calls the existing refinement function as-is.
//
// Field names match the parameters of `AIService.autoUpdateUserPromptOnTag`
// directly so `actionRefine` dispatch is a 1:1 decode-and-call.
// `kbRefine` requires role-aware reconstruction at drain time — see the
// dispatcher in `BackfillAIQueue`.

/// Snapshot for `.actionRefine` — all fields needed to call
/// `AIService.autoUpdateUserPromptOnTag(...)`. `currentUserActionMd` is NOT
/// snapshotted: it's read live at drain via `PromptStore.actionMarkdownSnapshot()`.
struct ActionRefineSnapshot: Codable, Sendable {
    let messageStableId: String
    let accountId: String
    let subject: String
    let from: String
    let summaryBlurb: String?
    let summaryTodos: String?
    let originalAction: String
    let userManualTag: String?   // nil means user untagged

    /// Dedup key for the `pendingAIRefinement` PK.
    /// Collapses re-teaches of the same (message, tag) into one row via UPSERT.
    var dedupKey: String {
        "actionRefine:\(messageStableId):\(userManualTag ?? "nil")"
    }
}

/// Snapshot for `.kbRefine` — session turns in dereferenced plain-text form.
/// Reconstructed into `[ChatTurn]` at drain time for `refineKB(sessionTurns:)`.
///
/// Per-turn `text` is ROLE-specific and must be populated at capture time:
///   - user turn:   `turn.renderedContent ?? turn.userMessage ?? ""`
///   - assistant:   `turn.renderedContent ?? turn.content`
///
/// `buildChatHistory` (KBRefinementService.swift:130) reads `userMessage` for
/// user turns and `content` for assistant turns. For user turns, `content` is
/// the template name "chat_converse" (not human text). Snapshotting raw
/// `content` for user turns would silently drop the user side of the transcript.
struct KBRefineSnapshot: Codable, Sendable {
    let sessionId: String
    let enqueuedAt: Int64        // unix millis
    let turns: [Turn]

    struct Turn: Codable, Sendable {
        let role: String         // "user" | "assistant"
        let type: String         // "normal" | "greeting" | ...
        let text: String         // dereferenced, role-specific per rules above

        /// Build a snapshot Turn from a live `ChatTurn` with the role-aware text
        /// extraction required by `KBRefinementService.buildChatHistory`.
        /// - User turn:   `renderedContent ?? userMessage ?? ""`
        /// - Assistant:   `renderedContent ?? content`
        ///
        /// Raw `content` for user turns is the template name "chat_converse" and
        /// must NOT be snapshotted — `buildChatHistory` reads `userMessage` for
        /// user turns, so raw `content` would reach the backend as garbage.
        static func from(_ turn: ChatTurn) -> Turn {
            let text: String
            if turn.role == "user" {
                text = turn.renderedContent ?? turn.userMessage ?? ""
            } else {
                text = turn.renderedContent ?? turn.content
            }
            return Turn(role: turn.role, type: turn.type, text: text)
        }
    }

    var dedupKey: String {
        "kbRefine:\(sessionId)"
    }

    /// Reconstruct `[ChatTurn]` suitable for `KBRefinementService.refineKB`.
    /// Role-aware: user turns get `userMessage: text, content: ""`; assistant
    /// turns get `content: text, userMessage: nil`.
    ///
    /// This is the drain-side complement of `Turn.from(_:)`. It must preserve
    /// the contract that `KBRefinementService.buildChatHistory` reads
    /// `userMessage` for user turns and `content` for assistant turns
    /// (KBRefinementService.swift:130–149). Swapping the branches would
    /// silently drop the user side of the transcript.
    func toChatTurns() -> [ChatTurn] {
        let ts = Double(enqueuedAt)
        return turns.enumerated().map { (i, turn) in
            let isUser = (turn.role == "user")
            return ChatTurn(
                id: "snapshot-\(sessionId)-\(i)",
                timestamp: ts,
                role: turn.role,
                content: isUser ? "" : turn.text,
                userMessage: isUser ? turn.text : nil,
                type: turn.type,
                chars: turn.text.count,
                renderedContent: nil,
                sessionId: sessionId,
                remindersSnapshot: nil,
                emailContextJSON: nil,
                thinkingContent: nil
            )
        }
    }
}

// MARK: - GRDB record

/// Durable row for a pending refinement job. PK is the `dedupKey`:
/// UPSERT via `INSERT OR REPLACE` collapses re-enqueues of the same
/// `(jobType, identifying-fields)` into one row.
struct PendingAIRefinement: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "pendingAIRefinement"

    /// Primary key — derived from jobType + identifying snapshot fields.
    /// See `ActionRefineSnapshot.dedupKey` / `KBRefineSnapshot.dedupKey`.
    var dedupKey: String

    /// Discriminator. Decodes via `BackfillAIJobType`.
    var jobType: String

    /// Type-specific snapshot, JSON-encoded.
    var payloadJSON: String

    /// Unix millis. Drives FIFO order on drain and TTL sweep on repopulate.
    var createdAt: Int64

    /// Conflict policy: REPLACE on PK conflict. This is the UPSERT.
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .replace, update: .replace)

    // MARK: - Convenience initializers

    init(dedupKey: String, jobType: BackfillAIJobType, payloadJSON: String, createdAt: Int64) {
        self.dedupKey = dedupKey
        self.jobType = jobType.rawValue
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }

    /// Convenience: build a row from an `ActionRefineSnapshot`. Throws if JSON
    /// encoding fails (shouldn't under normal conditions — all fields are strings).
    static func make(_ snapshot: ActionRefineSnapshot, now: Int64) throws -> PendingAIRefinement {
        let data = try JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return PendingAIRefinement(
            dedupKey: snapshot.dedupKey,
            jobType: .actionRefine,
            payloadJSON: json,
            createdAt: now
        )
    }

    static func make(_ snapshot: KBRefineSnapshot, now: Int64) throws -> PendingAIRefinement {
        let data = try JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return PendingAIRefinement(
            dedupKey: snapshot.dedupKey,
            jobType: .kbRefine,
            payloadJSON: json,
            createdAt: now
        )
    }

    // MARK: - Decode

    /// Decode the payload back to an `ActionRefineSnapshot`. Throws on malformed JSON.
    func decodeActionRefine() throws -> ActionRefineSnapshot {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "payloadJSON not UTF-8"
            ))
        }
        return try JSONDecoder().decode(ActionRefineSnapshot.self, from: data)
    }

    func decodeKBRefine() throws -> KBRefineSnapshot {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "payloadJSON not UTF-8"
            ))
        }
        return try JSONDecoder().decode(KBRefineSnapshot.self, from: data)
    }
}
