/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// PORT — v2final `TabMail/Services/AI/DraftSessionRegistry.swift` in full
/// (commit `d2f0c96a3`). The set of compose sessions the user currently has OPEN.
///
/// Background maintenance automatically garbage-collects drafts and chat turns
/// (recency eviction, TTL sweeps, memory caps). None of those may delete a draft
/// or its compose chat turns WHILE the user has that compose on screen — that
/// would silently drop the draft the user is editing (or its AI edit history),
/// destroying authored user bytes. Every automatic (non-user-initiated) deletion
/// site consults this registry and EXEMPTS active compose sessions. Explicit,
/// user-initiated destructive ops (discard, send, session-clear, account-cascade
/// delete) are NOT vetoed — the user asked for those.
///
/// 🚨 **CONSULTING THIS REGISTRY MEANS ASKING IT AT THE DELETION DECISION, NOT
/// BEFORE THE TRANSACTION.** A deletion site that reads `snapshot()` /
/// `activeComposeSessionIds()` once and then opens a write transaction has only a
/// STALE answer: a compose that calls `register` in between is invisible to it, and
/// the sweep deletes the draft the user is typing into. `DraftStore.evictImpl` did
/// exactly that until 2026-08-05. Use the snapshot as a cheap first filter if you
/// like, but re-ask `isActive(_:)` / `activeComposeSessionIds()` INSIDE the write
/// block — both are nonisolated synchronous `Mutex` reads precisely so that is legal.
///
/// REFCOUNTED: a deterministic draftId (`reply:{msg}` / `forward:{msg}`) can be
/// open in two ComposeViews at once (two windows replying to the same message).
/// A plain `Set` would collapse both registrations so the FIRST close exposes the
/// still-open second. The refcount keeps the id protected until the LAST view closes.
///
/// In-memory only. A missed `unregister` (SwiftUI does not guarantee `.onDisappear`)
/// over-RETAINS (the safe direction — a draft is kept, never wrongly deleted) and
/// self-heals at launch: the dict starts empty, and at launch no compose is open,
/// so the next maintenance pass reclaims anything genuinely stale.
///
/// ⚠️ **THAT SENTENCE IS ABOUT A MISSED `unregister` ONLY — it is NOT a statement
/// that this registry has just one failure direction.** A missed `unregister` is
/// safe. A LATE `register` — one that lands after a deletion site sampled the
/// registry — is the opposite and is NOT safe: it reads as "no compose is open" and
/// the sweep deletes live authored bytes. That is why the rule above is about
/// *when* the registry is asked, not merely *that* it is asked.
///
/// SUBTRACT — this is the ONE file carried from the reference's draft-lineage
/// bucket. It depends on nothing but `Synchronization`, so `DraftStoreStageAB`,
/// `DraftLineage`, `ComposeCloseState` and `ComposeGenerationCursor` do not arrive
/// with it. It stores a PLAIN `draftId`, never a generation-bearing key, because
/// the durable consumers (`DraftStore.evictImpl`'s row loop and its
/// `compose:<id>` / `demo:compose:<id>` session join) read the bare form.
///
/// Thread-safe (a `Mutex` from Synchronization, per the project rule over
/// `nonisolated(unsafe)`) so the nonisolated background-maintenance thread can read it.
final class DraftSessionRegistry: Sendable {
    static let shared = DraftSessionRegistry()
    private init() {}

    /// draftId → open-view count. An id is "active" while its count > 0.
    private let active = Mutex<[String: Int]>([:])

    /// A compose opened. Increments the refcount.
    func register(_ draftId: String) {
        active.withLock { $0[draftId, default: 0] += 1 }
    }

    /// A compose closed. Decrements the refcount; drops the id at zero. A spurious
    /// unregister for an id at zero is a no-op (never goes negative).
    func unregister(_ draftId: String) {
        active.withLock { dict in
            guard let count = dict[draftId] else { return }
            if count <= 1 { dict[draftId] = nil } else { dict[draftId] = count - 1 }
        }
    }

    /// Whether the user currently has this draftId open in any ComposeView.
    func isActive(_ draftId: String) -> Bool {
        active.withLock { ($0[draftId] ?? 0) > 0 }
    }

    /// Snapshot of the active draftIds (used by the DraftStore eviction row-loop /
    /// orphan-session cleanup).
    func snapshot() -> Set<String> {
        active.withLock { Set($0.keys) }
    }

    /// The `chatTurn` / `chatHistory` sessionId forms for every active compose
    /// draftId — both the plain `compose:<id>` and the demo-scoped
    /// `demo:compose:<id>` variants the eviction SQL / loops match. Used by the
    /// ChatStore eviction sites to exempt active compose sessions.
    func activeComposeSessionIds() -> Set<String> {
        active.withLock { dict in
            var out = Set<String>()
            out.reserveCapacity(dict.count * 2)
            for id in dict.keys {
                out.insert("compose:\(id)")
                out.insert("demo:compose:\(id)")
            }
            return out
        }
    }
}
