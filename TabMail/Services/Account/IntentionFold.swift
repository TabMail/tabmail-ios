/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// MARK: - Intention Records (ADR-IOS-058 / ADR-IOS-060)
//
// One dumb append-only record per user intention. EVERY surface (inbox/detail
// gestures, agent tools, notification actions, settings bulk ops, undo)
// appends records via `AccountManager.record(...)` and knows nothing else.
// The display overlay is DERIVED from pending records
// (`IntentionJournal.derivedOverlay`), and all smartness lives at drain time:
// `IntentionFold.fold` collapses a component's records to net intent, and
// `AccountManager.executeFold` resolves row truth ONCE and executes the
// minimal writes through the EXISTING action methods.
//
// Records are IN-MEMORY only (ADR-IOS-058 / plan §9c): the gesture path is
// zero-DB, and the records' durable successor is the `PendingOperation` row
// the fold's write transaction inserts atomically with the local write.
// Crash semantics are identical to the pre-existing architecture (accepted
// ADR-IOS-057 residual, narrowed by the didEnterBackground write-queue flush).
//
// ADR-IOS-060 removed the specialized `.undoRestore` record kind: Undo is an
// ordinary `.move` intention (source/destination swapped), appended with
// `origin: .undo`. If the resulting in-memory serial model returns to the
// initial location, the fold's ordinary "latest move wins" plus the
// executor's compare-against-fresh-row-truth skip (`executeFold`) already
// emit zero durable work — no special annihilation pass is needed here.

/// Where an intention originated. Diagnostic + policy input (tools/
/// notifications await receipts; undo carries no special fold behavior but
/// rides along on `moveOrigin` so the executor can keep an Undo's durable
/// admission separate from an ordinary move to the same destination).
enum IntentionOrigin: String, Sendable {
    case gesture
    case tool
    case notification
    case settings
    case undo
}

/// Destination of a move intention.
enum IntentionMoveTarget: Sendable, Equatable {
    /// Explicit destination folder. Inbox/detail gesture sites resolve this
    /// from in-memory folder state at gesture time (zero-DB path). Undo
    /// always uses this case — its inverse move is always an explicit folder.
    case folder(folderId: String, folderPath: String, isInbox: Bool)
    /// Role destination (agent tools / notification actions). Resolved PER
    /// ACCOUNT at execution time via `archive()`/`delete()` — carries the
    /// former `performCoordinatedRoleMove` semantics (fresh re-resolve,
    /// same-role filter, per-account role paths), now structural via
    /// `AccountManager.recordRoleMove` + the fold executor's `.role` branch.
    case role(FolderRole)

    /// Whether this target's destination is the inbox — used by the
    /// executor's effective-inbox tag gate (see `executeFold`). Role
    /// destinations are never the inbox.
    var isInbox: Bool {
        switch self {
        case .folder(_, _, let isInbox): return isInbox
        case .role: return false
        }
    }
}

/// One dumb append-only intention record. `ids` usually holds one message id;
/// thread/batch surfaces append ONE record spanning all members so the fold
/// executor preserves today's batched write transactions and batched
/// `PendingOperation`s. `displays` carries per-id what the surface used to
/// pass to `registerMutation` — the derived overlay is a pure merge of these,
/// so display semantics stay byte-compatible with the imperative overlay.
struct Intention: Sendable {
    enum Kind: Sendable {
        case isRead(Bool)
        case isFlagged(Bool)
        /// `baseline` is the gesture-time visualized tag — feeds
        /// `applyManualTag`'s previousTag/auto-teach signal (an AI auto-tag
        /// landing in the gesture→drain gap must not masquerade as the tag
        /// the user overrode).
        case actionTag(target: ActionTag?, baseline: ActionTag?)
        case move(IntentionMoveTarget)
    }

    let ids: [String]
    let kind: Kind
    let displays: [String: AccountManager.PendingMutation]
    let origin: IntentionOrigin
    /// Journal-assigned, globally monotonic. Total order of user intentions.
    let seq: UInt64
}

// MARK: - The Fold (pure)

/// Net intent for one message id after folding its pending records.
struct IntentionFieldIntents: Sendable {
    var isRead: Bool?
    var isFlagged: Bool?
    /// Outer `.some` = the tag field was touched; inner value may be nil (clear).
    var actionTag: ActionTag??
    /// First-touch baseline (outer `.some` when a tag record was seen).
    var actionTagBaseline: ActionTag??
    /// Inbox-ness of the row's PENDING location at the moment the tag record
    /// landed (the latest surviving pending move's destination) — nil when no
    /// move preceded the tag, meaning the executor gates on row truth. Tags
    /// are inbox-scoped (ADR-IOS-036): serial replay gates each tag write on
    /// the row's location AT THAT MOMENT, so the fold must carry that
    /// context — gating on the FINAL destination diverges (property-caught).
    var actionTagGate: Bool?
    var moveTarget: IntentionMoveTarget?
    /// The origin of the record that produced `moveTarget` (latest move
    /// wins, alongside `moveTarget`) — lets `executeFold`'s phase-3 grouping
    /// keep an Undo's inverse move in its own durable-admission group,
    /// separate from an ordinary move that happens to share a destination
    /// within the same connected component (ADR-IOS-060).
    var moveOrigin: IntentionOrigin?

    var isEmpty: Bool {
        isRead == nil && isFlagged == nil && actionTag == nil && moveTarget == nil
    }
}

/// Result of folding one connected component's records.
struct IntentionFoldResult: Sendable {
    var perId: [String: IntentionFieldIntents] = [:]
}

/// Pure fold: collapse a seq-ordered record list to net intent. NO I/O, no
/// clocks, no singletons — property-tested against a serial-replay model
/// (`IntentionFoldTests`). Execution-time concerns (skip-if-row-already-
/// reflects-target, the effective-inbox tag gate, vanished rows) deliberately
/// live in `executeFold`, NOT here: they depend on row truth the fold cannot
/// see (ADR-IOS-058 two-layer rule).
enum IntentionFold {

    static func fold(_ records: [Intention]) -> IntentionFoldResult {
        var result = IntentionFoldResult()

        for record in records {
            switch record.kind {
            case .isRead(let target):
                for id in record.ids {
                    result.perId[id, default: IntentionFieldIntents()].isRead = target
                }
            case .isFlagged(let target):
                for id in record.ids {
                    result.perId[id, default: IntentionFieldIntents()].isFlagged = target
                }
            case .actionTag(let target, let baseline):
                for id in record.ids {
                    var intents = result.perId[id, default: IntentionFieldIntents()]
                    // Gate on the location the row will have WHEN this tag was
                    // gestured: the latest surviving pending move's destination,
                    // else (nil) row truth at execution. A gate of FALSE means
                    // serial replay drops this write entirely (tags are
                    // inbox-scoped, ADR-IOS-036) — the record is a no-op and
                    // must not disturb fold state (in particular it must not
                    // cancel a pending clear from the move that left the inbox,
                    // nor park a dead intent that would mask that clear).
                    let gate = intents.moveTarget?.isInbox
                    if gate == false { continue }
                    if intents.actionTagBaseline == nil {
                        intents.actionTagBaseline = .some(baseline)
                    }
                    intents.actionTag = .some(target)
                    intents.actionTagGate = gate
                    result.perId[id] = intents
                }
            case .move(let target):
                // Latest move wins per id (A→B→C ⇒ C). A move — including one
                // that leaves the inbox — no longer touches the pending tag
                // state (Round D-0 supersedes the old ADR-IOS-036 F6
                // destructive clear): the tag is retained on the header
                // regardless of folder, so serial replay's DB write for this
                // move doesn't write `actionTag` either, and the fold must not
                // synthesize an intent it doesn't produce.
                //
                // In-memory annihilation (ADR-IOS-060 §7.2): an Undo's move
                // record targets the exact pre-forward-move source. If the
                // forward record is still in this SAME pending set (never
                // consumed by an earlier fold), "latest wins" nets the target
                // back to that source — and `executeFold`'s phase-3 write
                // compares the final target against FRESH ROW TRUTH, which
                // still reflects that same unwritten source, so the write
                // (and the durable append it would have produced) is skipped
                // entirely. No special pairing/checkpoint pass is needed.
                for id in record.ids {
                    var intents = result.perId[id, default: IntentionFieldIntents()]
                    intents.moveTarget = target
                    intents.moveOrigin = record.origin
                    result.perId[id] = intents
                }
            }
        }

        // Drop ids whose intents fully cancelled down to nothing (e.g. an
        // isRead(true) followed by isRead(false)... never happens today since
        // fields are latest-wins, not cancelling — kept as a defensive filter
        // for any future intent kind that can net to empty).
        result.perId = result.perId.filter { !$0.value.isEmpty }
        return result
    }
}
