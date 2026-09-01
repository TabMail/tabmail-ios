/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Synchronization

/// Quick folder status snapshot for IMAP delta sync change detection.
struct IMAPFolderStatus: Sendable {
    let messageCount: Int
    let uidNext: Int
    let unreadCount: Int
    /// RFC 7162 CONDSTORE HIGHESTMODSEQ — increments on ANY change including
    /// \Seen/flag updates that leave `uidNext`/`messageCount` unchanged (which
    /// STATUS-count delta sync misses today). nil when the server doesn't
    /// advertise CONDSTORE → callers fall back to the uidNext+count comparison.
    let highestModSeq: Int?
    /// UIDVALIDITY — MODSEQ (and UIDs) are only comparable within one UIDVALIDITY
    /// epoch. A change means the mailbox was recreated: callers MUST force a full
    /// sync and reset any cached modseq, never trust a lower/equal value. nil when
    /// not reported (no UIDPLUS).
    let uidValidity: Int?
}

/// Result of an explicit-UID-set existence SEARCH (deletion reconcile, ADR-IOS-051).
struct UIDExistenceResult: Sendable {
    /// UIDs from the queried set that still exist server-side.
    let found: Set<UInt32>
    /// UIDVALIDITY reported by the SELECT that preceded the SEARCH.
    /// 0 = the server did not report a value (callers must treat as unknown
    /// and abort any deletion decision — never delete on uncertainty).
    let uidValidity: UInt32
}

/// A transport-security refusal that TabMail can state in the user's own terms,
/// because the user is the only one who can act on it.
///
/// `IOS-TLS-002` requires that a connection refused by the TLS floor surface as a
/// *clear, actionable error naming the TLS floor*, never a silent or generic
/// connection failure. What actually reached the UI was NIOSSL's bridged form —
/// `"The operation couldn't be completed. (NIOSSL.NIOSSLError error 0.)"` —
/// observed directly (see `IMAPTransportSecurityError.tlsProtocolVersionAlert`).
/// That names nothing, suggests nothing, and describes a condition that is
/// permanent: the server cannot speak the floor, so no retry will ever succeed.
///
/// `CustomStringConvertible` alongside `LocalizedError` is deliberate and it is
/// SwiftMail's own `SMTPError` convention: the send path stores
/// `String(describing: error)` into `outboxMessage.errorMessage`, which
/// `OutboxView` renders verbatim for a `.failed` row, while the account-connect
/// views render `error.userFacingDescription` (i.e. `localizedDescription`).
/// Both must therefore be the same human sentence.
enum IMAPTransportSecurityError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The server would not negotiate the minimum TLS version TabMail requires.
    case tlsFloorNotMet(host: String)

    var description: String {
        switch self {
        case .tlsFloorNotMet(let host):
            // ⚠️ The version named here is SwiftMail's `MailTLSMinimumVersion`
            // default (`.tlsv12`), which is the floor TabMail's `IMAPServer` /
            // `SMTPServer` are constructed with. If that default ever moves, this
            // sentence moves with it. `IOS-TLS-001` is the owner's standing
            // decision that the floor itself stays where it is.
            return """
                \(host) does not support TLS 1.2 or later. TabMail requires TLS 1.2 so your mail \
                password cannot be read in transit, and will not fall back to an older version. \
                Ask your mail provider to enable TLS 1.2.
                """
        }
    }

    var errorDescription: String? { description }
}

actor IMAPProvider: EmailProvider, MessageExistenceProbe {
    /// IMAP `fetchMessages(limit:)` returns the highest UIDs (archive-time order,
    /// decorrelated from message date) → stale detection must use a UID window.
    nonisolated var staleWindowMode: StaleWindowMode { .uid }

    // MARK: - Transport-security error mapping (IOS-TLS-002)

    /// The BoringSSL reason token a below-floor server produces, **observed**, not
    /// assumed (2026-08-04, iOS Simulator, this app's SwiftMail → NIOSSL stack,
    /// against `openssl s_server`):
    ///
    /// - TLS 1.1-only server → `handshakeFailed(NIOSSL.BoringSSLError.sslError(
    ///   [Error: 268436526 error:1000042e:SSL routines:OPENSSL_internal:
    ///   TLSV1_ALERT_PROTOCOL_VERSION at …/tls_record.cc:484]))`
    /// - TLS 1.0-only server → byte-identical signature.
    ///
    /// 🚨 THE OUTER SHAPE IS NOT THE DISCRIMINATOR. A TLS 1.3 server presenting an
    /// untrusted certificate produced the SAME `handshakeFailed(…sslError…)`
    /// wrapper with `CERTIFICATE_VERIFY_FAILED` inside, so matching on
    /// `handshakeFailed` — or on the NIOSSL error domain — would tell a user whose
    /// certificate expired that their server is too old. Only the reason token
    /// separates them, which is why the match is on the token alone.
    ///
    /// It is matched in the RENDERED description rather than by importing NIOSSL
    /// so a rethrow that re-wraps the error in a provider type (`SMTPError`
    /// interpolates `"\(error)"`) still carries it — the same technique
    /// `SyncEngine.isConnectionError` uses for NIO's error families.
    static let tlsProtocolVersionAlert = "TLSV1_ALERT_PROTOCOL_VERSION"

    /// Return an actionable transport-security error when — and ONLY when — the
    /// failure was the server refusing the TLS version floor. Everything else is
    /// returned UNCHANGED.
    ///
    /// Fail-to-generic is the safe direction and it is chosen on purpose. A shape
    /// this function does not recognise stays whatever it already was, so it keeps
    /// its existing transient/retryable classification and the user's send keeps
    /// retrying. Recognising too much is the dangerous direction: it would label a
    /// recoverable failure permanent and stop a send that would have gone through.
    nonisolated static func mapTransportSecurityFailure(
        _ error: Error,
        host: String
    ) -> Error {
        guard String(describing: error).contains(tlsProtocolVersionAlert) else {
            return error
        }
        return IMAPTransportSecurityError.tlsFloorNotMet(host: host)
    }

    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let senderEmail: String
    private let smtpHost: String
    private let smtpPort: Int
    /// Test-only TLS override. `nil` in production — SwiftMail infers TLS from
    /// the port (993 → implicit TLS, 143 → plain). Tests set `false` to point
    /// IMAPProvider at an in-process plain-TCP fake on an ephemeral port.
    private let useTLS: Bool?

    // MARK: - UIDVALIDITY epoch observation (T1.2b)

    /// Last SELECT-observed UIDVALIDITY per folder path, written by
    /// `selectMailboxTracked`. `Mutex`-backed nonisolated seam (Resilience Rule
    /// 5) so `lastObservedUidValidity(folderPath:)` is readable synchronously
    /// from a GRDB write closure, which cannot `await` into this actor.
    ///
    /// **Observation only** — this type never compares the value against a
    /// stored epoch and never refuses or drops an operation because of it (those
    /// are later items). It answers exactly one question: *what did the most
    /// recent tracked SELECT of this folder report?*
    ///
    /// An entry exists only while the LAST tracked SELECT of that path reported a
    /// non-zero UIDVALIDITY. `0` never enters the map, and — the part that is
    /// easy to get wrong — a `0` also REMOVES any earlier entry, so the map can
    /// never answer with a previous SELECT's epoch. RFC 3501 §2.3.1.1 types
    /// UIDVALIDITY as `nz-number`, and SwiftMail's `Mailbox.Selection.uidValidity`
    /// is non-optional only because it DEFAULTS to `UIDValidity(0)`, so `0` here
    /// can only mean "the server did not report a value" (the convention
    /// `UIDExistenceResult.uidValidity` documents and
    /// `SyncEngineDeletionReconcile.swift` enforces).
    ///
    /// REFERENCE (`v2final`, tag `e28dd4edb`): `IMAPProvider
    /// .lastObservedUidValidityBox` (`v2final:TabMail/Providers/IMAPProvider
    /// .swift:84` — the `v2final:` prefix is load-bearing: this is a pointer at
    /// the immutable TAG, not a self-reference into this file, where line 84
    /// is something else entirely), same shape and the
    /// same `!= 0` guard — but the reference does NOT clear on a `0`, and this
    /// port deliberately does. See `selectMailboxTracked` for why that difference
    /// is required rather than cosmetic.
    private nonisolated let lastObservedUidValidityBox = Mutex<[String: UInt32]>([:])

    /// Protocol conformance (`EmailProvider.lastObservedUidValidity`) — see
    /// `lastObservedUidValidityBox`. `nil` = the most recent tracked SELECT of
    /// `folderPath` reported no UIDVALIDITY, or there has been no tracked SELECT
    /// of it at all. It never returns `0`, and it never returns a value an
    /// earlier SELECT reported once the current one has stopped reporting it.
    nonisolated func lastObservedUidValidity(folderPath: String) -> UInt32? {
        lastObservedUidValidityBox.withLock { $0[folderPath] }
    }

    /// SELECT `folder` and RECORD the epoch that SELECT reported, then hand the
    /// caller the very same `Mailbox.Selection` a bare `server.selectMailbox`
    /// would have returned.
    ///
    /// Observation only: it performs no comparison against any stored epoch and
    /// drops no message and no operation. The one test it does make is the
    /// unreported-sentinel classification below, which decides what this SELECT
    /// is recorded AS — never whether the caller's work proceeds.
    ///
    /// Why SELECT and not STATUS: `OK [UIDVALIDITY n]` is core IMAP4rev1
    /// (RFC 3501 §6.3.1), whereas SwiftMail asks for the `UIDVALIDITY` STATUS
    /// attribute only when the server advertises UIDPLUS
    /// (`IMAPServer+Mailbox.swift`'s `mailboxStatus`: `if capabilities
    /// .contains(.uidPlus) { attributes.append(.uidValidity) }`). So on a
    /// non-UIDPLUS server the STATUS-sourced writes added by T1.2 observe nil
    /// forever, and this is the path that still yields an epoch.
    ///
    /// **The `0` branch CLEARS; it must not merely skip the write.**
    /// `Mailbox.Selection.uidValidity` is non-optional only because SwiftMail
    /// defaults it to `UIDValidity(0)`, which is not an RFC guarantee. Recording
    /// that `0` would let it be persisted as an epoch and make every later epoch
    /// comparison `0 == 0`, i.e. vacuously true. But *leaving a previous entry
    /// standing* is just as wrong here, and less obvious: the next reader would
    /// be handed an epoch an EARLIER SELECT reported and treat it as this fetch's
    /// — "unknown now" silently falling back to "known before" (project rule 4,
    /// no fallbacks), and the value it falls back to then gets PERSISTED.
    ///
    /// ⚠ THIS IS A DELIBERATE CORRECTION OF `v2final`, NOT A PORT OF IT. The
    /// reference's chokepoint (`v2final:TabMail/Providers/IMAPProvider
    /// .swift:1353` — tag-pinned, NOT a pointer into this file) has the identical
    /// `if observed != 0 { … }` and never clears — and that is SAFE there,
    /// because its consumer is a *comparison guard*: a stale mirror value
    /// disagrees with the live epoch, and disagreement ABORTS. Fail-safe. Here
    /// the consumer is a *write* (`SyncEngine.runSyncMessages` bootstraps the
    /// column from it), so the same staleness is fail-dangerous: it plants a
    /// wrong epoch that the later checkpoints will compare against. The mechanism
    /// is only safe in the direction its consumer runs; copying it verbatim
    /// across that inversion is the bug.
    ///
    /// The map write is synchronous with the SELECT — no `await` between the two
    /// — so no other operation on this actor can interleave between this SELECT
    /// and the record of its result.
    ///
    /// ⚠ SECOND DEVIATION FROM `v2final` (deliberate, scoped): the reference makes
    /// this the chokepoint that EVERY `selectMailbox` call site routes through,
    /// because there it also carries the ADR-IOS-061 Stage-2 *refusal* — a throw
    /// that must fire on every SELECT to be a contract. This port adds no refusal
    /// (that is a later item), so only the SYNC and OPEN SELECTs are routed
    /// through it. The tracked set, by `rg -n "selectMailboxTracked" TabMail/`
    /// (five sites in this file today; attack the claim by re-running it):
    ///  1. `createFolderConnection`'s open-the-folder SELECT (both legs);
    ///  2. `fetchMessagesWithObservedEpoch`' SELECT (T1.2b — reached from
    ///     `SyncEngine.runSyncMessages` through `fetchMessages`);
    ///  3. `getUidNextWithEpoch`'s (T1.3 — the backfill walk's walk-start epoch);
    ///  4. `searchExistingUIDs(folder:from:to:)`' (T1.3 — per-chunk);
    ///  5. `fetchMessageHeadersWithObservedEpoch(folder:uids:batchSize:
    ///     interBatchDelay:)`' (ditto — round 13 moved the SELECT there from
    ///     `fetchMessageHeaders(folder:uids:batchSize:interBatchDelay:)`, which
    ///     is now a thin delegating wrapper).
    ///
    /// 3–5 were RAW until audit round 8. That was the round-7 blocker: with them
    /// raw, the mirror held the epoch the pinned connection observed when it was
    /// CREATED and tracked no turnover during the crawl, so the epoch the walk
    /// read back at the end was not bound to the UID population the walk had just
    /// inserted. `v2final` routes all three through the tracked helper too.
    ///
    /// ⚠ **RETRACTION (round 10) — round 8 claimed all three are "backfill-only
    /// call sites (`SyncEngine.runBackfill` is their sole caller)". That is FALSE
    /// for #5 and two reviewers accepted it.** `rg -n "fetchMessageHeaders\("
    /// TabMail/` finds the `folder:uids:batchSize:` overload called from SIX
    /// sites in THREE files: the walk (`SyncEngineBackfillWalk.swift`), self-heal
    /// (`SyncEngineSelfHeal.swift`) and deep backfill
    /// (`SyncEngineBackfillDeep.swift`, four sites) — all `extension SyncEngine`
    /// files, none of them a type you can cite. Neither self-heal nor deep
    /// backfill is epoch-guarded, so both now write this mirror. Do not restate
    /// any "sole caller" claim here without re-running that search.
    ///
    /// ⚠ **UPDATE (round 13, blocker 2): self-heal IS epoch-guarded now**
    /// (`SyncEngine.selfHealFolder`) — and it is guarded WITHOUT reading this
    /// mirror, by the epoch `fetchMessageHeadersWithObservedEpoch` returns from
    /// the SELECTs that served its headers. It still WRITES the mirror, because
    /// its fetch still routes through this helper. Deep backfill remains
    /// unguarded and remains a writer.
    ///
    /// That retraction is why the two consumers whose direction is a WRITE no
    /// longer read this mirror at all. They take the epoch bound to their own
    /// SELECT, returned by the call that performed it —
    /// `fetchMessagesWithObservedEpoch` (consumed by `runSyncMessages`' bootstrap)
    /// and `getUidNextWithEpoch` (consumed by the walk's stamp). A mirror read is
    /// only sound where the consumer is a COMPARISON that fails closed on
    /// disagreement, which is what the walk's per-chunk check is: an interloping
    /// SELECT of the same path can only report the epoch the server is live on,
    /// so it can force a false MISMATCH (refuse — safe) and never a false MATCH.
    ///
    /// Action SELECTs stay OUT, and narrower stays SAFER for them: a mirror
    /// written by every action SELECT too has more ways to be overwritten between
    /// a pass's fetch and its read of this value. Widening THERE belongs with
    /// the refusal.
    ///
    /// ⚠ **UPDATE (T5.3) — the scope paragraph directly above is SUPERSEDED, and
    /// its "action SELECTs stay OUT" clause was already false when it was
    /// written.** T3.1 (`3843940cb`) routed five ACTION-path SELECTs through this
    /// helper — `mutateAdmittedUIDs`' mutation SELECT and `move`'s A2/A3/A4/A5 —
    /// so the mirror has been fed by action SELECTs ever since. T5.3 finishes the
    /// job: every `server.selectMailbox` call in this file now routes through
    /// here, with exactly ONE deliberate exception — `move`'s DESTINATION probe,
    /// reserved for T3.14 and documented at its own call site. The census is
    /// reproducible and is the check to re-run rather than trust this sentence:
    /// `rg -n 'server\.selectMailbox\(' TabMail/Providers/IMAPProvider.swift`
    /// must return exactly TWO hits — this function's own call on the line below,
    /// and that destination probe.
    ///
    /// **What routing a site through here does and does NOT buy — stated plainly,
    /// because the reference's identically-named function is a DIFFERENT
    /// function.** `v2final`'s `selectMailboxTracked` additionally fires
    /// `onUidValidityObserved` (its change-reaction trigger) and carries the
    /// ADR-IOS-061 Stage-2 REFUSAL — `throw ProviderError.uidValidityChanged(…)`
    /// when `storedUidValidityForLedgerCompare` disagrees with the observation.
    /// v3's `selectMailboxTracked` has NEITHER. ⚠️ CORRECTED 2026-08-05: this said
    /// "v3 has NEITHER term (`rg -n 'uidValidityChanged' TabMail/` finds no
    /// declaration and no throw site — every hit is prose)". That was true when
    /// written and became false at `065a827ca` (2026-08-02, "Bind ordinary IMAP
    /// actions to UID epochs"), which is INSIDE the release range.
    /// `ProviderError.uidValidityChanged` is now DECLARED in `EmailProvider.swift`
    /// (`enum ProviderError`, with its message arm in the same enum's
    /// `errorDescription`) and THROWN in this file by `requireUidValidity`.
    /// **The claim that matters here is unaffected and remains true:** the throw is
    /// `requireUidValidity`'s, not `selectMailboxTracked`'s, so this helper still
    /// carries no refusal of its own. This helper is
    /// therefore a BARE MIRROR WRITE: converting a call site adds no refusal and
    /// no throw the bare `server.selectMailbox` did not already have, so it
    /// structurally cannot turn any caller's error handling — including
    /// `withActionConnectionSelection`'s LIST-probe leg, whose
    /// `IMAPActionMailboxAbsent` IS a terminal no-op — into a silent drop. Every
    /// epoch comparison stays the consumer's own: `requireUidValidity` against
    /// the queue's admitted epoch on the action path, `SyncEngine.crawlEpochGate`
    /// and the walk's per-chunk `epochStillAgrees` on the sync path.
    ///
    /// What it DOES buy is the contract `lastObservedUidValidity(folderPath:)`
    /// claims: the mirror now answers *what did the most recent SELECT of this
    /// folder report*, not *the most recent TRACKED one*. Before T5.3 a bare
    /// re-SELECT could observe a turnover ON THE WIRE and discard it, leaving the
    /// mirror asserting an epoch the server had already replaced — a FALSE MATCH
    /// for the one live production consumer, `SyncEngine.runBackfill`'s per-chunk
    /// `epochStillAgrees`. Widening the writer set cannot invert that consumer:
    /// every writer records the epoch the server is live on at its own SELECT (or
    /// CLEARS on an unreported one), so a race between two writers of the same
    /// path can only manufacture a MISMATCH — refuse, which is safe — and never
    /// agreement. The widening is monotonically safety-increasing for it.
    private func selectMailboxTracked(_ server: IMAPServer, folder: String) async throws -> Mailbox.Selection {
        let selection = try await server.selectMailbox(folder)
        let observed = selection.uidValidity.value
        // Assignment, not an `if` — a `0` (unreported) must ERASE any earlier
        // entry, never leave it behind as an answer for this SELECT.
        lastObservedUidValidityBox.withLock { $0[folder] = observed != 0 ? observed : nil }
        return selection
    }

    // MARK: - Pool State Invariants (T3.7 — the pool's INVARIANT CONTRACT)
    //
    // PORT of `v2final`'s "Pool State Invariants" block (ADR-IOS-061 Round 6
    // item B; extended Rounds 7–13), reached from `v2final`'s `IMAPProvider`
    // immediately above `assertPoolSlotWasNil`. Commit `4d34ee864` carries it.
    //
    // The complete legal-mutator + cross-field contract for ALL THREE
    // connection lanes (action, folder, IDLE). Every field lists every
    // function allowed to write it and the condition under which that write is
    // legal — anything not listed here is a bug. "Handoff" = the
    // ownership-RESERVING transfer (R5-F1): the slot is never published free
    // while a waiter is queued for it — the mark stays held and ownership
    // passes directly to the dequeued waiter's own continuation.
    //
    // ⚑ DEVIATIONS FROM THE REFERENCE, stated once here rather than repeated:
    //  * v3's `selectMailboxTracked` carries NO refusal and no
    //    `onUidValidityObserved` trigger (see its own doc comment). Wherever
    //    the reference's contract says "the `uidValidityChanged` refusal", v3
    //    has only the SELECT's own failure. This narrows the set of errors a
    //    creation path can throw; it never widens it, so every guard below is
    //    reached under a subset of the reference's conditions.
    //    ⚠️ Read "v3 has no `uidValidityChanged`" as "v3's SELECT helper does not
    //    throw it". Since `065a827ca` the case IS declared (`ProviderError` in
    //    `EmailProvider.swift`) and IS thrown — but by `requireUidValidity`, on
    //    the action path, never by `selectMailboxTracked`. The deviation above
    //    stands; only the "term does not exist" reading of it is wrong.
    //  * The reference names `move`/`moveToTrash`/`closeMailbox`/
    //    `unselectMailbox` nowhere in this contract and neither does v3 —
    //    `IMAPProvider` calls none of them on the SwiftMail server, and COPY /
    //    APPEND do not change the selected mailbox, so no lane's "the pinned
    //    connection is SELECTed on its own folder" premise has a second writer.
    //
    // ACTION POOL
    //  - `actionServer`: `ensureServer()` create-path plant — single-flighted
    //    (R6-1 Part 2), slot nil (DEBUG-asserted); `connect()` routes through
    //    it (B-3 — it must never replace a live slot). The "dead — recreating"
    //    branch in `acquireActionConnection`: SELF-REPLACE of a connection the
    //    caller just proved dead AND still holds exclusively — the ONE
    //    documented exception to "never plant over non-nil". R8-F1: that
    //    self-replace re-validates `generation` BEFORE the plant, not after,
    //    and — the fuzzer's own correction (Testing Rule 11) — generation
    //    alone is NOT the full void set, because unhealthy release and
    //    keepalive's failure leg nil the slot with NO bump; the plant
    //    therefore ALSO requires `actionServer === deadInstance`. A
    //    mismatch/nil REFUSES the plant (log `fresh` out, release the mark per
    //    invariant #5, throw for retry).
    //    `releaseActionConnection(healthy:false)`: → nil (exclusive holder's
    //    own unhealthy release). `disconnect()`/`markDirty()`: → nil
    //    (wipe-everything, generation bumped FIRST and in the SAME synchronous
    //    actor turn as the wipe for BOTH functions — R9-F1; see the
    //    `generation` row). `keepAlivePinnedConnections`: → nil on a failed
    //    NOOP, ONLY when `!actionInUse` AND the slot still holds the exact
    //    instance it NOOPed (B-2 identity guard) — `!actionInUse` is checked
    //    BOTH before the NOOP await (closing the healthy-release-handoff race,
    //    R5-F1) AND again AFTER it (R8-F3 — a concurrent acquire flips the
    //    mark with zero intervening await of its own, so only the post-await
    //    recheck can see it).
    //  - `actionInUse`: `acquireActionConnection`'s not-in-use branch:
    //    false→true in one synchronous step. Healthy-release handoff: stays
    //    TRUE across the transfer — never independently cleared there (R5-F1).
    //    Healthy release with NO waiter queued: → false. Healthy release with
    //    a NIL slot under an unchanged generation (Round 9 wedge fix): → false
    //    + fail-all — there is nothing to hand off, so the handoff is REFUSED
    //    and the branch degenerates to the unhealthy-shape cleanup minus the
    //    logout (whoever nil'd the slot owned that). Healthy release whose
    //    generation moved during its own (test-hook-only) await: touches
    //    NOTHING. Unhealthy release / `disconnect()` / `markDirty()`: → false.
    //    The R7-F1 post-liveness-rebind throw and the R8-F1 dead-recreate
    //    identity refusal both route through
    //    `releaseActionConnection(healthy: false)` before throwing (invariant
    //    #5).
    //  - `actionWaiters`: `append` (queueing, in-use branch). `removeFirst()`
    //    + `resume()` (handoff — the dequeue makes the waiter invisible to any
    //    LATER fail-all sweep, which is exactly the R6-1 hazard: the resumed
    //    continuation's OWN tail must detect a voided transfer itself).
    //    `disconnect()`/`markDirty()`/unhealthy-release: fail-all + clear.
    //  - `actionServerCreating` / `actionServerCreationWaiters` (R6-1 Part 2,
    //    generation-guarded R7-F1): `ensureServer()` is the ONLY writer —
    //    single-flights the create path the same way `folderCreating` /
    //    `folderWaiters` single-flight folder creation. Every cleanup that
    //    clears the flag and fails the queue runs in ONE synchronous turn and
    //    at most ONCE per creator epoch: the `do/catch` scope is narrowed to
    //    exactly the `createServer()` await, and the generation-mismatch path
    //    does its whole cleanup synchronously with a DETACHED discard logout.
    //    Each queued waiter carries the `generation` captured AT APPEND TIME;
    //    the success path resumes every waiter with the fresh server BY VALUE,
    //    and each waiter's own tail throws if `generation` moved OR if
    //    `actionServer !== fresh` (the slot no longer tracks the instance it
    //    was handed — unhealthy release / keepalive nil it with no bump).
    //  - `generation`: `disconnect()`, `markDirty()` — the ONLY two writers,
    //    both a monotonic increment, both BEFORE tearing anything else down —
    //    and (R9-F1) both in the SAME synchronous actor turn as every slot
    //    wipe + waiter fail-all that follows: no `await` may separate the bump
    //    from the wipe. `disconnect()` captures every slot + waiter array into
    //    a local FIRST, then bumps, wipes and fails waiters — all
    //    synchronously — and only THEN awaits the captured locals' LOGOUTs,
    //    preserving its "awaits every logout" contract without reopening the
    //    window a concurrent acquire could land in.
    //
    // FOLDER POOL
    //  - `folderServers[f]`: `createFolderConnection`'s success paths plant
    //    ONLY into a slot verified nil at call time (DEBUG-asserted) — both
    //    the primary path AND the limit-retry's own (R8-F2).
    //    `disconnect()`/`markDirty()`: wipe (same synchronous-turn guarantee
    //    as `generation`). `releaseFolderConnection(healthy:false)`: remove
    //    one. `evictLRUFolder()`: remove one (not-in-use only; candidates are
    //    also restricted to keys that actually OWN a `folderServers` entry, so
    //    the action pool's `"__action__"` liveness-timestamp key sharing
    //    `folderLastUsed` can never be picked as a phantom "eviction").
    //    `keepAlivePinnedConnections`: remove one on a failed NOOP, ONLY when
    //    the slot still holds the exact instance it NOOPed AND the folder is
    //    still not in use (B-2 + R8-F3). `acquireFolderConnection` branch 1's
    //    dead-recreate leg (R7-F2): remove one, ONLY under the same identity
    //    guard. Branch 1's noop-SUCCESS tail (R8-F3): releases via
    //    `releaseFolderConnection(healthy:false)` when the slot no longer
    //    holds the exact instance it NOOPed — generation alone does not
    //    guarantee this, because keepalive's identity-guarded removal does not
    //    bump generation.
    //  - `folderInUse`: `acquireFolderConnection` branch 1 inserts BEFORE its
    //    liveness `noop()` await (R7-F2 — the action pool's mark-before-await
    //    precedent, R4-1; pre-fix two concurrent acquires for the SAME folder
    //    could both pass the branch guard and both return the same
    //    connection). Branches 2/3 insert on their own resume/create tails.
    //    `releaseFolderConnection` healthy-no-waiter: remove. Unhealthy
    //    release / `disconnect()` / `markDirty()`: wipe/remove. Handoff
    //    (healthy, waiter queued): membership STAYS — never cleared then
    //    re-inserted (R5-F1). Branch 1's dead-recreate leg: remove before
    //    delegating to `createFolderConnection`, which requires the mark
    //    ABSENT at entry and re-marks it itself on success.
    //  - `folderCreating`: `createFolderConnection` is the ONLY writer —
    //    insert on entry, remove ONLY at the function's TRUE exits: the
    //    primary success plant, the limit-retry's own success plant, the
    //    limit-retry's own failure throw, and the no-retry failure throw
    //    (R8-F2 — the flag must survive the WHOLE limit-retry, whose own
    //    `createServer()` + SELECT are a creation genuinely still in flight).
    //    `disconnect()`/`markDirty()` MUST NOT clear it (B-1): a creation in
    //    flight is not cancelled by a teardown, and clearing the flag admits a
    //    SECOND colliding creation for the same folder.
    //  - `folderWaiters[f]`: `append` (branch 2 ONLY — capacity waiters have
    //    their own queue). `removeFirst()` + `resume()` (R5-F1 handoff).
    //    `disconnect()`/`markDirty()`/unhealthy-release/creation-failure:
    //    fail-all + clear. `createFolderConnection`'s SUCCESS paths
    //    deliberately resume NOBODY (R5-F1): the creator itself is about to
    //    use the connection it just planted and already holds `folderInUse`;
    //    a waiter resumed here would run concurrently with it on ONE socket.
    //  - `folderCapacityWaiters`: folder-agnostic FIFO for acquires parked at
    //    `maxFolderConnections` with nothing evictable. They must NOT park in
    //    `folderWaiters[their-own-folder]`, whose only wake events are
    //    SAME-folder ones — structurally never delivered for a singleton
    //    new-folder acquire, which is a liveness hole, not a fuzzer artifact.
    //    Writers: the capacity branch appends (with queue-time `generation`);
    //    `wakeOneFolderCapacityWaiter()` resumes ONE (FIFO) from every
    //    slot-freeing mutation (healthy release with no handoff waiter,
    //    unhealthy release, keepalive's failure-leg removal) AND from
    //    `createFolderConnection`'s own TWO failure exits (R10-F1 — a task
    //    that evicted to free capacity and then failed must wake the waiter
    //    parked beside the capacity it abandoned). A wake is a HINT, never an
    //    ownership transfer: the resume tail re-validates generation, adopts
    //    its folder's connection only if present AND idle (same turn, no
    //    awaits), defers (throw-for-retry) to a current owner/creator, else
    //    re-runs the whole eviction/creation loop.
    //    `disconnect()`/`markDirty()`: fail-all + clear.
    //  - `folderLastUsed`: bookkeeping only (LRU + liveness timer) — ALSO
    //    double-keyed `"__action__"` for the action pool's OWN liveness timer.
    //    `disconnect()`/`markDirty()`'s blanket `removeAll()` clears BOTH
    //    namespaces; harmless. `evictLRUFolder()`'s candidate filter excludes
    //    any key with no `folderServers` entry, which is what keeps the
    //    `"__action__"` stamp out of the LRU candidate set.
    //
    // IDLE CONNECTION
    //  - `idleServer`: `launchIdleConnection`'s Task plants via
    //    `claimIdleServerSlot` — the ONLY plant site, which re-validates
    //    `idleEnabled && idleServer == nil` in the SAME synchronous step as
    //    the plant. `launchIdleConnection` itself is deliberately NOT
    //    single-flighted (invariant #4's exception): its callers do not need
    //    each other's RESULT — nothing blocks on IDLE being ready — so the
    //    recheck-at-plant alone closes both the launch-vs-launch race and the
    //    launch-vs-stop/teardown race. `stopIdle()`/`markDirty()`/
    //    `evictIdleConnection()`: unconditional → nil (each reads the CURRENT
    //    field, not a captured reference, so no identity check is needed).
    //    `onIdleStreamEnded(owner:)`: → nil ONLY when `idleServer === owner`;
    //    a stale owner logs out its OWN connection and returns without
    //    touching the slot.
    //  - `idleListenerTask`: `launchIdleConnection` plants unconditionally
    //    (cancelling whatever it finds first). `stopIdle()`/`markDirty()`:
    //    cancel + nil. `onIdleStreamEnded(owner:)`: nil ONLY inside the
    //    identity-matched branch. `evictIdleConnection()`: cancel + nil.
    //
    // CROSS-FIELD INVARIANTS (all three lanes)
    //  1. A resumed-but-not-yet-continued waiter holds ownership: the in-use
    //     mark stays true/present across the handoff, and ONLY
    //     `markDirty()`/`disconnect()` may void the transfer — both bump
    //     `generation`, so the void set is EXACTLY "generation moved since the
    //     waiter queued". Every resume tail — action waiter, folder branch 2,
    //     folder capacity-wait, AND the action-server creation-waiter (the
    //     fourth) — captures `generation` at queue time and MUST detect a
    //     voided transfer at resume (generation moved, or slot nil / not the
    //     instance handed over) and THROW — never rebuild/adopt silently. A
    //     raw queue-time IDENTITY compare is deliberately NOT the action
    //     waiter's test: the holder's own dead-recreate legitimately swaps the
    //     instance with no bump, and handing THAT to the waiter is valid.
    //  2. No path may plant a connection over a non-nil slot, except the
    //     action pool's documented self-replace-a-known-dead-connection case.
    //     DEBUG-asserted at every plant site (`assertPoolSlotWasNil`).
    //  3. Every await inside an acquire/tail/keepalive re-validates before
    //     mutating pool state: acquires re-check `generation`; the
    //     post-liveness rebind additionally requires the SAME instance on BOTH
    //     the action pool (R6-1 Part 3) and the folder pool's branch-1
    //     noop-success tail (R8-F3) — `generation` is not bumped by every path
    //     that can change `actionServer`/`folderServers[f]`. Keepalive
    //     re-checks slot IDENTITY (B-2) AND its `!actionInUse` /
    //     not-in-`folderInUse` precondition on BOTH sides of its own NOOP
    //     await. Resume tails currently have ZERO awaits after their guard —
    //     adding one requires a fresh re-validation after it.
    //  4. Creation is single-flighted on the action and folder pools:
    //     concurrent callers who all observe "no connection, nobody creating"
    //     must converge on ONE `createServer()` call. The IDLE lane is the
    //     deliberate exception (see `idleServer` above).
    //  5. Every throw path that exits an acquire while still holding a mark it
    //     itself set, under an UNCHANGED generation, MUST explicitly release
    //     that mark before propagating — otherwise the lane wedges. The
    //     confirmed instances are `acquireActionConnection`'s post-liveness
    //     identity rebind (R7-F1), its dead-recreate identity refusal (R8-F1),
    //     its dead-recreate `createServer()` failure, and
    //     `acquireFolderConnection` branch 1's noop-success identity refusal.
    //     Every OTHER unchanged-generation throw either routes through an
    //     explicit release or is reachable only when generation DID move (in
    //     which case the teardown that moved it already reset the mark).
    //  6. Every `with{Action,Folder}Connection[NoSelect]` wrapper re-validates
    //     `generation` IMMEDIATELY BEFORE calling `body()` — not only after it
    //     returns. The action path's SELECT is a real, always-present wire
    //     round-trip, so a `disconnect()`/`markDirty()` landing during it can
    //     log the connection out from under the task; nothing re-checked
    //     before `body()` ran, so `body()` could execute against an
    //     already-invalidated connection with the holder unable to detect the
    //     interruption until its OWN command completed. The after-the-fact
    //     guard still runs too — this is additive.
    //  7. `ensureServer()`'s CREATOR path captures `generation` BEFORE
    //     `createServer()`'s RTT and re-validates it immediately before
    //     planting — mirroring the creation-WAITERS' own `queuedGeneration`
    //     guard. `assertPoolSlotWasNil` cannot substitute: it cannot
    //     distinguish "still virgin" from "was reset by a teardown that
    //     already voided this creation".
    //  8. A HEALTHY release re-validates its authority after every await of
    //     its own before mutating pool state: `releaseActionConnection(healthy:
    //     true)` captures `generation` at entry and, after its handoff test
    //     hook's await (its only pre-decision suspension point; `nil` in
    //     production, where the branch is one synchronous turn), (a) returns
    //     untouched on a moved generation, and (b) REFUSES the handoff on a
    //     nil slot. The folder-pool healthy release needs no sibling guard
    //     today: its only await sits AFTER its dequeue decision, and a
    //     post-dequeue teardown is fully handled by the resumed waiter's own
    //     tail — adding a pre-decision await there in the future imports this
    //     invariant with it.

    // MARK: - Pool Plant-Over Traps + Mutation Journal (D-19)
    //
    // PORTED from `v2final` (`TabMail/Providers/IMAPProvider.swift`):
    // `assertPoolSlotWasNil` `:494`, `assertActionServerSelfReplace` `:524`, and
    // the `mutLog` / `logMut` / `mutLogForTesting` ring journal `:629-636`.
    //
    // This base had ZERO `assert` / `assertionFailure` / `precondition` calls
    // anywhere in the file, so the reference's cross-field invariant #2
    // (`v2final:…:385-387` — *no path may plant a connection over a non-nil
    // slot, except the action pool's documented
    // self-replace-a-known-dead-connection case*) was enforced by nothing.
    // Recorded as D-19 in
    // `TabMailTests/Providers/IMAPProviderPoolInvariantTests.swift`.
    //
    // T3.7 UPDATE — the coverage deviation this block used to record is GONE.
    // At T0.6(a) this base had SIX plant sites and armed THREE; T3.7 closes the
    // other three the same way the reference did, so the inventory is now
    // 4 armed of 4 plant sites, identical to `v2final`:
    //   1. `createFolderConnection` primary plant .............. ARMED
    //   2. `createFolderConnection` limit-retry plant .......... ARMED
    //   3. action dead-recreate self-replace ................... ARMED
    //        (via `assertActionServerSelfReplace`, the ONE documented
    //         exception to "never plant over non-nil" — and, as of T3.7, its
    //         call site ALSO guards `actionServer === deadInstance` first, so
    //         the assert is defense in depth exactly as in the reference)
    //   4. `ensureServer()` create ............................. ARMED (D-02
    //        single-flight landed in this same change — the coupling the
    //        deferred block demanded)
    //   5. `setIdleServer(_:)` ........... ELIMINATED (D-20 — the only plant
    //        site is now `claimIdleServerSlot`, which re-checks
    //        `idleServer == nil` in the SAME synchronous step as the plant, so
    //        a plant-over is structurally impossible and an assert there would
    //        be dead code, exactly as in the reference)
    //   6. `connect()`'s unconditional plant ... ELIMINATED (D-23 — `connect()`
    //        now routes through the single-flighted `ensureServer()`, so the
    //        plant lives at site 4 and is trapped there)
    //
    // Two deviations from the reference remain, both cosmetic:
    // the journal's field list (the reference's `logMut` line prints
    // `actionServerCreating=`; this one does too as of T3.7 — so only the
    // GATING below still differs) and the fact that the whole journal family
    // sits inside `#if DEBUG` here.
    //
    // The GATING deviation, which is the one the T0.6(a) seam block
    // below already documents: the reference leaves `mutLog` / `logMut` /
    // `mutLogForTesting` UNGATED (only `logMut`'s BODY is `#if DEBUG`, relying
    // on `@autoclosure` to keep release call sites free of the interpolation).
    // Here the whole family — declarations AND every call site — sits inside
    // `#if DEBUG`, so Release carries neither the storage nor one executable
    // line of it. The reference's `@autoclosure` shape is kept verbatim anyway:
    // it costs nothing and stays correct if a future call site is ever moved
    // out of a `#if DEBUG` region.
    #if DEBUG
    /// R6 invariant helper (cross-field invariant #2): DEBUG-only cheap check
    /// for "no path may plant a connection over a non-nil slot". Fires as a
    /// Swift `assert` — a loud, immediate trap in debug/test builds (tests
    /// always run DEBUG) and completely compiled out of release (zero runtime
    /// cost there). Call BEFORE the write, passing whatever the slot held just
    /// before it. Deliberately NOT exercised by a dedicated test: `assert`
    /// traps the whole process on failure, which would kill the test run rather
    /// than fail one test — its job is to turn a FUTURE regression into an
    /// immediate, unambiguous crash inside whichever existing test first
    /// exercises the broken path, not to be independently green today.
    private func assertPoolSlotWasNil(_ previous: IMAPServer?, _ slot: String, file: StaticString = #file, line: UInt = #line) {
        // Post-mortem channel: the assert traps the WHOLE process, so a
        // fuzzer's normal end-of-round MUTLOG dump never runs — print the
        // journal tail here first, or the trap's interleaving is unrecoverable
        // (this is exactly how the reference root-caused its ensureServer
        // creator plant-over-non-nil). DEBUG-only by the enclosing `#if`;
        // prints only when about to trap.
        if previous != nil {
            print("[IMAPProvider] PLANT-OVER-NON-NIL POST-MORTEM (\(slot)) MUTLOG TAIL:")
            for line in mutLog.suffix(50) { print("  \(line)") }
        }
        assert(previous == nil, "[IMAPProvider] R6 pool invariant violated: planted a connection over a non-nil \(slot) slot", file: file, line: line)
    }

    /// Cross-field invariant #2's ONE documented exception: the action pool's
    /// dead-recreate self-replace may plant over a non-nil slot ONLY when that
    /// slot still holds the EXACT dead instance this task just proved dead and
    /// still holds exclusively (`actionInUse`).
    ///
    /// T3.7 UPDATE (D-05 / R8-F1 landed): the call site now guards
    /// `actionServer === deadInstance` BEFORE the plant and refuses otherwise,
    /// so the nil case is STRUCTURALLY EXCLUDED by the time this runs and this
    /// assert is pure defense in depth — identical to the reference. The nil
    /// arm of the predicate is kept (byte-identical to `v2final`'s) rather than
    /// tightened: it is unreachable, and tightening an unreachable arm would
    /// diverge from the reference for no property.
    ///
    /// Why the nil case had to be closed at the call site rather than here:
    /// `releaseActionConnection(healthy: false)` and keepalive's failure leg
    /// nil the slot WITHOUT a generation bump, so a nil slot can mean a
    /// legitimate concurrent `ensureServer()` create is already in flight for
    /// it — planting into that nil slot collides with the create. A THIRD
    /// instance means some other writer planted over the slot without bumping
    /// generation, violating the "only self-replace may skip the bump" premise
    /// this exception depends on.
    private func assertActionServerSelfReplace(_ current: IMAPServer?, dead: IMAPServer, file: StaticString = #file, line: UInt = #line) {
        assert(current == nil || current === dead, "[IMAPProvider] R8 pool invariant violated: dead-recreate self-replace found a THIRD instance in actionServer (neither nil nor the dead instance being replaced)", file: file, line: line)
    }

    /// Action-pool mutation journal. Every legal-mutator write appends one
    /// line, and the assert helpers above dump the tail on a trap — this is the
    /// ONLY post-mortem channel a plant-over trap leaves behind, because the
    /// trap kills the process before any fuzzer's end-of-round dump can run.
    private var mutLog: [String] = []
    private func logMut(_ event: @autoclosure () -> String) {
        mutLog.append("[\(mutLog.count)] \(event()) actionServer=\(actionServer.map { "\(ObjectIdentifier($0))" } ?? "nil") actionInUse=\(actionInUse) actionServerCreating=\(actionServerCreating) actionWaiters=\(actionWaiters.count) gen=\(generation)")
        if mutLog.count > 5000 { mutLog.removeFirst(2000) }
    }

    /// Test-only accessor for the journal above — for a fuzzer/test that wants
    /// the tail on a wedge or leak finding rather than on a trap.
    func mutLogForTesting() -> [String] { mutLog }
    #endif

    // MARK: - Folder-Pinned Connections
    // Each folder gets a dedicated connection, already SELECTed. LRU eviction at server limit.
    // Background ops (sync, backfill, batch fetch) go through these — zero checkout/SELECT overhead.

    /// Folder → pinned IMAP connection (already SELECTed on that folder).
    private var folderServers: [String: IMAPServer] = [:]
    /// Folder → last used timestamp (for LRU eviction).
    private var folderLastUsed: [String: Date] = [:]
    /// Folders whose pinned connection is currently in use by an operation.
    private var folderInUse: Set<String> = []
    /// Folders currently being created (prevents duplicate creation from actor reentrancy).
    private var folderCreating: Set<String> = []
    /// Per-folder waiter queues — callers waiting for a busy or creating folder connection.
    private var folderWaiters: [String: [CheckedContinuation<Void, Error>]] = [:]

    /// T3.7 PORT — `v2final:…:IMAPProvider.folderCapacityWaiters` (Round 9
    /// continuation; commit `4d34ee864`). CAPACITY waiters: callers parked
    /// because the pool is at `maxFolderConnections` with nothing evictable.
    ///
    /// These used to park in `folderWaiters[their-own-folder]` — but that queue
    /// is only ever served by SAME-folder events (the ownership handoff, the
    /// unhealthy release, a creation failure), so a capacity-parked acquire for
    /// a folder that has NO connection and NO other traffic could NEVER be
    /// woken by the very thing it waits for: a slot freeing somewhere ELSE. A
    /// singleton new-folder acquire at capacity parked until an unrelated
    /// `disconnect()`/`markDirty()`. That is a liveness hole, not a fuzzer
    /// artifact, and it is production-reachable on any account whose folder
    /// count exceeds `maxFolderConnections`.
    ///
    /// Each entry carries `generation` at queue time (cross-field invariant #1).
    /// `wakeOneFolderCapacityWaiter()` is the ONLY resume site;
    /// `disconnect()`/`markDirty()` fail-all + clear.
    private var folderCapacityWaiters: [(generation: Int, continuation: CheckedContinuation<Void, Error>)] = []

    /// Wake exactly one parked capacity waiter (FIFO). Called from every
    /// mutation that frees a folder slot or returns one to the evictable (idle)
    /// set — the healthy release with no same-folder handoff waiter, the
    /// unhealthy release, keepalive's failure-leg removal — AND (R10-F1) from
    /// `createFolderConnection`'s own TWO failure exits, because a creation
    /// attempt that evicted to free capacity and then FAILED must wake the
    /// waiter parked beside the capacity it just abandoned.
    ///
    /// Waking is a HINT, never an ownership transfer: the resumed waiter
    /// re-validates generation and re-runs the whole capacity loop, so a
    /// spurious wake is safe (the waiter simply re-parks).
    private func wakeOneFolderCapacityWaiter() {
        guard !folderCapacityWaiters.isEmpty else { return }
        let (_, cont) = folderCapacityWaiters.removeFirst()
        cont.resume()
    }

    /// Generation counter — incremented by markDirty() **and, as of T3.7,
    /// disconnect()** (D-15 / R9-F1). Zombie tasks from a previous generation
    /// skip their release logic instead of accidentally removing new
    /// connections.
    private var generation: Int = 0

    // MARK: - Action Connection
    // Dedicated connection for user-initiated actions (move, flag, mark read, draft, etc.).
    // SELECTs the needed folder per-operation (~150ms, fine for low-volume user actions).
    // Guaranteed never blocked by background work or IDLE.

    private var actionServer: IMAPServer?
    private var actionInUse = false
    private var actionWaiters: [CheckedContinuation<Void, Error>] = []

    /// T3.7 PORT — `v2final:…:IMAPProvider.actionServerCreating` (R6-1 Part 2;
    /// commit `4d34ee864`). Single-flights `ensureServer()`'s create path.
    /// Mirrors `folderCreating`/`folderWaiters`: without it, two concurrent
    /// callers who both observed `actionServer == nil` each raced their own
    /// `createServer()`, and the loser's `actionServer = fresh` assignment
    /// silently overwrote the winner's — planting over a non-nil slot and
    /// leaking a logged-in connection nobody ever released.
    ///
    /// This is D-02, and its red evidence was banked before the fix: with
    /// `assertPoolSlotWasNil` armed at the plant, `ProviderIdQueueFuzzTests`
    /// tripped it 3/3 at seed 8131249127217430530 (the `mutLog` trace is quoted
    /// in `TabMailTests/Providers/IMAPProviderPoolInvariantTests.swift`).
    private var actionServerCreating = false

    /// T3.7 PORT — `v2final:…:IMAPProvider.actionServerCreationWaiters` (R6-1
    /// Part 2, generation-guarded by R7-F1). Callers that arrived while a
    /// creation was already in flight; each carries the `generation` captured
    /// AT APPEND TIME alongside its continuation, and the success path resumes
    /// every one of them with the fresh server BY VALUE. Each waiter's own
    /// resume tail re-validates (see `ensureServer()`), because a fail-all
    /// sweep can no longer reach a waiter that was already dequeued.
    private var actionServerCreationWaiters: [(generation: Int, continuation: CheckedContinuation<IMAPServer, Error>)] = []

    // MARK: - IDLE Connection (Dedicated, Tracked, Evictable)
    // Separate connection for IMAP IDLE (RFC 2177 requires no commands during IDLE).
    // Tracked in the connection budget and evictable when connections are scarce.
    // Priority: action > folder connections > IDLE (lowest — falls back to polling).

    /// Dedicated IDLE connection — separate from action and folder connections.
    private var idleServer: IMAPServer?
    /// Task running the IDLE event listener loop.
    private var idleListenerTask: Task<Void, Never>?
    /// Callback invoked when IDLE receives an event (EXISTS, EXPUNGE, etc.).
    private var idleEventHandler: ((IMAPServerEvent) -> Void)?
    /// Whether IDLE should be running (set by startIdle/stopIdle).
    private var idleEnabled = false

    // MARK: - Server Limit
    /// Server-declared connection limit. Folder connections capped at limit - 2
    /// (reserve 1 for action, 1 for IDLE). IDLE slot is evictable when scarce.
    private var serverConnectionLimit: Int?
    /// Connections reserved from server limit (action + IDLE).
    private static let reservedConnections = 2

    // MARK: - Keepalive
    private var keepAliveTask: Task<Void, Never>?

    /// UTC calendar for IMAP date conversions — SINCE/BEFORE use date-only semantics,
    /// so UTC prevents off-by-one day gaps caused by device timezone differences.
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    init(
        host: String,
        port: Int = 993,
        username: String,
        password: String,
        senderEmail: String? = nil,
        smtpHost: String,
        smtpPort: Int = 587,
        useTLS: Bool? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.senderEmail = senderEmail ?? username
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.useTLS = useTLS
        // Start from the persisted server limit (learned from a prior
        // max_userip_connections rejection) so backfill's parallel walk never
        // re-oversubscribes a server whose cap we already know.
        self.serverConnectionLimit = Self.persistedServerLimit(host: host, username: username)
    }

    // MARK: - Object-Lifecycle Oracle Seams (T3.7 PORT — R12-F1)
    //
    // PORT of `v2final:…:IMAPProvider.serverCreatedTestHook` /
    // `.logoutAttemptTestHook` / `.deadDropTestHook` and their
    // `noteLogoutAttempt(_:)` / `noteDeadDrop(_:)` markers (commit
    // `4d34ee864`). This is the "object-lifecycle oracle" the item's reference
    // list names.
    //
    // WHY IT CANNOT BE A WIRE-LEVEL COUNTER. `FakeIMAPServer
    // .abandonedSessionCount()` is sound only in a churn-free environment: an
    // abandoned `IMAPServer` deinits, its socket EOF-closes, and the fake's
    // `closeClientFd` erases the fd from `loggedInFds` exactly like a clean
    // LOGOUT would — so `liveSessionCount() == 0` passes whether or not a leak
    // is present, and `abandonedSessionCount()` false-positives under fault
    // injection because SwiftMail's transparent reconnect closes superseded
    // logged-in channels without LOGOUT while the OBJECT lives on. The oracle
    // therefore lives at the OBJECT layer: every instance this provider
    // creates must carry a DISPOSITION — a logout attempt, or an explicit
    // proved-dead drop — before it deinits.
    //
    // `Mutex`-stored and `nonisolated` so the marks are observable from ANY
    // context (detached logout `Task`s included) with zero actor hops: the
    // instrumentation must not perturb the very interleavings a fuzzer
    // searches. All three are `nil` in production.

    /// Fires synchronously inside `createServer(diagSite:)` the instant
    /// `login()` returns — the SINGLE choke point where every connection this
    /// provider will ever own is born. The `String` is the birth-site label, so
    /// an oracle violation can name WHICH creator produced the instance nobody
    /// disposed of.
    private nonisolated let serverCreatedTestHook =
        Mutex<(@Sendable (IMAPServer, String) -> Void)?>(nil)

    /// Test seam: install `serverCreatedTestHook`.
    nonisolated func setServerCreatedTestHookForTesting(_ hook: (@Sendable (IMAPServer, String) -> Void)?) {
        serverCreatedTestHook.withLock { $0 = hook }
    }

    /// The universal "a logout was ATTEMPTED for this instance" mark, fired via
    /// `noteLogoutAttempt(_:)` immediately before EVERY `server.logout()` call
    /// in this file (inline or detached). An ATTEMPT is deliberately
    /// sufficient: whether the LOGOUT line lands on the current channel, a
    /// transparently-reconnected successor, or nowhere at all is SwiftMail's
    /// business — the invariant this supports is *no instance is discarded
    /// without anyone ever trying*.
    private nonisolated let logoutAttemptTestHook =
        Mutex<(@Sendable (IMAPServer) -> Void)?>(nil)

    /// Test seam: install `logoutAttemptTestHook`.
    nonisolated func setLogoutAttemptTestHookForTesting(_ hook: (@Sendable (IMAPServer) -> Void)?) {
        logoutAttemptTestHook.withLock { $0 = hook }
    }

    /// Mark a logout attempt for `server`. Synchronous, callable from any
    /// context; a no-op in production (nil hook).
    nonisolated private func noteLogoutAttempt(_ server: IMAPServer) {
        logoutAttemptTestHook.withLock { $0 }?(server)
    }

    /// The SECOND legitimate disposition — a PROVED-DEAD instance deliberately
    /// dropped WITHOUT a logout attempt. When an instance has just FAILED a
    /// protocol command that proves its transport dead (a liveness/keepalive
    /// NOOP throwing), sending LOGOUT would be pointless-to-harmful: SwiftMail
    /// would transparently open a brand-new channel just to log it out. Those
    /// sites drop the instance silently.
    ///
    /// ⚠️ ONLY for sites whose instance was just proved dead by its OWN failed
    /// command. Marking a LIVE discard with it instead of logging out would
    /// hide exactly the leak class (D-13 / R11-H2) this oracle exists to catch.
    private nonisolated let deadDropTestHook =
        Mutex<(@Sendable (IMAPServer) -> Void)?>(nil)

    /// Test seam: install `deadDropTestHook`.
    nonisolated func setDeadDropTestHookForTesting(_ hook: (@Sendable (IMAPServer) -> Void)?) {
        deadDropTestHook.withLock { $0 = hook }
    }

    /// Mark a deliberate proved-dead drop for `server`. Synchronous, callable
    /// from any context; a no-op in production (nil hook).
    nonisolated private func noteDeadDrop(_ server: IMAPServer) {
        deadDropTestHook.withLock { $0 }?(server)
    }

    // MARK: - Connection Creation

    /// Create a fresh logged-in IMAP connection.
    ///
    /// `diagSite` labels the creator for the object-lifecycle oracle above —
    /// no default on purpose: every new call site must identify itself.
    private func createServer(diagSite: String) async throws -> IMAPServer {
        let server = IMAPServer(
            host: host,
            port: port,
            useTLS: useTLS,
            responseBufferLimit: IMAPFetchMapping.responseBufferLimit
        )
        do {
            try await server.connect()
        } catch {
            // IOS-TLS-002: a server below the TLS floor otherwise arrives at the
            // UI as "The operation couldn't be completed. (NIOSSL.NIOSSLError
            // error 0.)" — permanent, actionable, and named nowhere.
            throw Self.mapTransportSecurityFailure(error, host: host)
        }
        try await server.login(username: username, password: password)
        // The oracle's birth mark — see `serverCreatedTestHook`.
        serverCreatedTestHook.withLock { $0 }?(server, diagSite)
        return server
    }

    /// Whether an idle reusable connection needs a NOOP before it is handed
    /// out. T3.7 PORT — `v2final:…:IMAPProvider.shouldCheckConnectionLiveness
    /// (lastUsed:now:)`: ONE production decision shared by both the
    /// folder-pinned and the action lane, so the two can never drift.
    static func shouldCheckConnectionLiveness(lastUsed: Date?, now: Date) -> Bool {
        now.timeIntervalSince(lastUsed ?? .distantPast) > SyncConfig.imapPoolLivenessCheckSeconds
    }

    /// Max folder connections (server limit minus reserved for action + IDLE).
    /// When IDLE is evicted, the freed slot becomes available for folders.
    private var maxFolderConnections: Int {
        if let limit = serverConnectionLimit {
            let activeReserved = idleServer != nil ? Self.reservedConnections : Self.reservedConnections - 1
            return max(1, limit - activeReserved)
        }
        return SyncConfig.imapMaxConnectionCeiling - Self.reservedConnections
    }

    /// Parse server connection limit from error message.
    /// The learned limit is persisted per host+username so subsequent launches
    /// start at the real cap instead of re-oversubscribing (up to 18 parallel
    /// backfill workers against e.g. Dovecot's 15/user+IP) until the server
    /// rejects a login again.
    private func parseAndApplyServerLimit(from error: Error) {
        let desc = "\(error)"
        guard desc.contains("max_userip_connections"),
              let range = desc.range(of: "mail_max_userip_connections="),
              let limit = Int(desc[range.upperBound...].prefix(while: \.isNumber))
        else { return }
        if serverConnectionLimit == nil || limit < serverConnectionLimit! {
            serverConnectionLimit = limit
            Self.persistServerLimit(limit, host: host, username: username)
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] Server connection limit detected: \(limit) (folder slots: \(maxFolderConnections))") }
            BackgroundSyncLogger.logBackfill("[IMAP] \(senderEmail) server connection limit detected: \(limit) (folder slots: \(maxFolderConnections))")
        }
    }

    // MARK: - Server Limit Persistence

    /// UserDefaults key for the learned per-server connection limit. Keyed by
    /// host+username (the provider doesn't know accountId) so a re-added account
    /// on the same server reuses the learned cap.
    static func serverLimitDefaultsKey(host: String, username: String) -> String {
        "imapServerConnLimit:\(username)@\(host)"
    }

    static func persistedServerLimit(host: String, username: String) -> Int? {
        let value = UserDefaults.standard.integer(forKey: serverLimitDefaultsKey(host: host, username: username))
        return value > 0 ? value : nil
    }

    static func persistServerLimit(_ limit: Int, host: String, username: String) {
        UserDefaults.standard.set(limit, forKey: serverLimitDefaultsKey(host: host, username: username))
    }

    // MARK: - Folder Connection API

    /// Execute an operation on a folder-pinned connection (already SELECTed).
    /// Used for all background/sync folder operations. Connection stays pinned after use.
    /// If the folder connection is busy, caller waits. If none exists, one is created.
    private func withFolderConnection<T>(
        folder: String,
        _ body: (IMAPServer) async throws -> T
    ) async throws -> T {
        let server = try await acquireFolderConnection(folder: folder)
        // T3.7 PORT (D-17 / R3 R-1) — `v2final:…:IMAPProvider
        // .withFolderConnection`. Capture generation AFTER the acquire
        // completes, in the SAME actor turn as its return (no `await` in
        // between, so nothing can interleave here). `acquireFolderConnection`
        // suspends internally (waiter dequeue, `createFolderConnection`'s
        // `createServer()` RTT) — a teardown landing in THAT window bumps
        // `generation` and this folder ends up marked in-use under the NEW
        // generation. Capturing BEFORE the acquire (what this line used to do)
        // then compares against the OLD value at release time, treats the
        // release as stale, and SKIPS it — leaking the `folderInUse` mark
        // forever, wedging this folder's lane until an unrelated teardown
        // clears it wholesale.
        let acquiredGeneration = generation
        #if DEBUG
        // T3.7: the full-body holder ENTER mark. Fires here, immediately after
        // the generation capture and BEFORE the test hook's own await — firing
        // it after that await would record a LIVE (possibly already-raced)
        // generation instead of the value this hold was acquired under, which
        // is precisely what tainted the reference's oracle bookkeeping.
        if let hook = folderConnectionHolderEnterTestHook { hook(folder, server, generation) }
        // T0.6(a) test seam — fires once per checkout, after this folder's pinned
        // connection is checked out and BEFORE `body` runs, i.e. while this
        // task is a legitimate HOLDER. Lets a test park a holder
        // deterministically so a second caller can queue as a real waiter, or
        // so a concurrent `markDirty()`/`disconnect()` can land inside a live
        // checkout. Compiled out of Release; `nil` in every non-test context.
        if let hook = folderConnectionTestHook { await hook(folder) }
        #endif
        // T3.7 PORT (D-16 / cross-field invariant #6) — `v2final:…
        // :IMAPProvider.withFolderConnection`'s pre-body guard. The hook above
        // can race a concurrent `disconnect()`/`markDirty()` that logs this
        // exact connection out from under us; re-validate BEFORE `body()` ever
        // touches it rather than only after it returns. RETRYABLE refusal — the
        // caller sees `ProviderError.notConnected`, exactly what every parked
        // waiter receives from a teardown's fail-all sweep.
        guard generation == acquiredGeneration else {
            if DebugModeManager.isLoggingEnabled() {
                print("[IMAP] Stale generation for \(folder) before body — discarding silently")
            }
            throw ProviderError.notConnected
        }
        do {
            let result = try await body(server)
            #if DEBUG
            if let hook = folderConnectionHolderExitTestHook { hook(folder, server, generation) }
            #endif
            // If markDirty() ran while body was executing, this connection is stale.
            // Don't touch folderServers — a new connection may already exist for this folder.
            guard generation == acquiredGeneration else {
                if DebugModeManager.isLoggingEnabled() { print("[IMAP] Stale generation for \(folder) — discarding connection silently") }
                return result
            }
            await releaseFolderConnection(folder: folder, healthy: true)
            return result
        } catch {
            #if DEBUG
            if let hook = folderConnectionHolderExitTestHook { hook(folder, server, generation) }
            #endif
            guard generation == acquiredGeneration else {
                if DebugModeManager.isLoggingEnabled() { print("[IMAP] Stale generation for \(folder) after error — discarding connection silently") }
                throw error
            }
            let desc = "\(error)"
            let isUnhealthy = SyncEngine.isConnectionError(error)
                || desc.contains("PayloadTooLargeError")
                || desc.contains("IMAPDecoderError")
            if isUnhealthy { parseAndApplyServerLimit(from: error) }
            await releaseFolderConnection(folder: folder, healthy: !isUnhealthy)
            throw error
        }
    }

    private func acquireFolderConnection(folder: String) async throws -> IMAPServer {
        // 1. Existing connection, not in use — verify liveness and return
        if let server = folderServers[folder], !folderInUse.contains(folder) {
            let now = Date()
            let idle = now.timeIntervalSince(folderLastUsed[folder] ?? .distantPast)
            if Self.shouldCheckConnectionLiveness(lastUsed: folderLastUsed[folder], now: now) {
                // T3.7 PORT (D-10 / R7-F2) — `v2final:…:IMAPProvider
                // .acquireFolderConnection`. Mark `folderInUse` BEFORE the
                // liveness await, porting the action pool's
                // mark-before-await precedent (R4-1). Pre-fix the mark was
                // only inserted AFTER this whole liveness block, so two
                // concurrent acquires for the SAME folder could both observe
                // `!folderInUse.contains(folder)`, both await `noop()`
                // concurrently, and both return the SAME `IMAPServer` — a
                // double checkout with NO teardown involved, i.e. mainline
                // load. SwiftMail serializes individual COMMANDS, not
                // command SEQUENCES, so a second SELECT can interpose between
                // the first holder's SELECT and its UID command: a
                // wrong-mailbox mutation, which is a direct C3 violation.
                folderInUse.insert(folder)
                // Capture generation BEFORE the liveness await (R4-1's
                // sibling): a teardown landing during `noop()` bumps
                // `generation` and wipes `folderServers`/`folderInUse`
                // wholesale; without re-validating afterwards this branch
                // would insert into the CURRENT (post-teardown) set and hand
                // back a torn-down connection as if it were exclusively held.
                let acquiredGeneration = generation
                #if DEBUG
                if let hook = acquireFolderConnectionLivenessRaceTestHook { await hook() }
                #endif
                do {
                    _ = try await server.noop()
                } catch {
                    guard generation == acquiredGeneration else {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] Stale generation for \(folder) during liveness check — discarding silently")
                        }
                        throw ProviderError.notConnected
                    }
                    // Dead — discard and create fresh. Generation UNCHANGED:
                    // this task is still the sole marked holder of `folder`'s
                    // slot, so clear the mark before delegating to
                    // `createFolderConnection`, which requires `folderInUse`
                    // to NOT contain `folder` at entry (the invariant every
                    // other caller of it honours) and re-marks it itself on
                    // success. Never leave the OLD mark stuck across the swap.
                    // The removal is identity-guarded (D-09 / B-2): only ever
                    // remove the exact instance this task just NOOPed.
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP] Pinned connection for \(folder) dead (idle \(Int(idle))s) — recreating") }
                    noteDeadDrop(server)
                    folderInUse.remove(folder)
                    if folderServers[folder] === server {
                        folderServers.removeValue(forKey: folder)
                        folderLastUsed.removeValue(forKey: folder)
                    }
                    return try await createFolderConnection(folder: folder)
                }
                // noop() succeeded — but a teardown could have landed and
                // COMPLETED during that await. A stale generation here means
                // `server` may already be logged out and `folderInUse` was
                // wiped; trusting it now would resurrect an entry the pool no
                // longer tracks. (Generation moved ⇒ the teardown already
                // wiped the mark, so this throw leaves nothing stale behind.)
                guard generation == acquiredGeneration else {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[IMAP] Stale generation for \(folder) after liveness check succeeded — discarding silently")
                    }
                    throw ProviderError.notConnected
                }
                // T3.7 PORT (D-10 tail / R8-F3) — generation-unchanged does
                // NOT guarantee the slot wasn't concurrently swapped or
                // removed: keepalive's own identity-guarded removal does not
                // bump generation. Parity with the action pool's post-liveness
                // rebind guard (R6-1 Part 3). A mismatch means keepalive (or
                // another such mutator) already tore this exact instance down
                // out from under us — release the mark THIS task holds
                // (cross-field invariant #5) and throw for retry rather than
                // resurrecting an orphaned tracking entry.
                guard folderServers[folder] === server else {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[IMAP] Folder connection for \(folder) removed during liveness re-validation — releasing mark and discarding")
                    }
                    await releaseFolderConnection(folder: folder, healthy: false)
                    throw ProviderError.notConnected
                }
                folderLastUsed[folder] = Date()
                return server
            }
            folderInUse.insert(folder)
            folderLastUsed[folder] = Date()
            return server
        }

        // 2. Existing connection but in use, OR being created (actor reentrancy guard) — wait
        if folderServers[folder] != nil || folderCreating.contains(folder) {
            // T3.7 PORT (D-04's folder sibling / R6-1 Part 1) — capture
            // `generation` BEFORE queueing. The void set is exactly
            // "generation moved", because only `markDirty()`/`disconnect()`
            // may void a transfer and both bump; the current holder's own
            // legitimate recreate does not.
            let queuedGeneration = generation
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                folderWaiters[folder, default: []].append(cont)
            }
            // Resumed. A SUCCESSFUL resume here always comes from
            // `releaseFolderConnection`'s ownership-reserving handoff, which
            // never fires unless `folderServers[folder]` was non-nil at
            // resume-call time — every other path that touches a queued
            // continuation (the unhealthy release, a creation failure,
            // `disconnect()`/`markDirty()`) FAILS it instead. So a moved
            // generation, or a nil slot, is unambiguous evidence of a teardown
            // landing in the job-hop gap between the handoff's `resume()` and
            // this continuation actually running: the fail-all sweep could not
            // reach us because the handoff had already DEQUEUED us. The
            // generation compare also catches the ABA variant (a third task
            // re-created this folder's connection post-teardown and may
            // already hold it — non-nil, but never ours).
            //
            // Throw for retry; do NOT fall into `createFolderConnection` (the
            // pre-fix behaviour), which would start a second, colliding
            // creation for the SAME folder while a third task could still be
            // using the first one — two holders on one `IMAPServer`.
            guard generation == queuedGeneration, let server = folderServers[folder] else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[IMAP] Voided folder-connection transfer for \(folder) detected at waiter resume — throwing for retry")
                }
                throw ProviderError.notConnected
            }
            folderInUse.insert(folder)
            folderLastUsed[folder] = Date()
            return server
        }

        // 3. No connection for this folder — create one
        return try await createFolderConnection(folder: folder)
    }

    private func createFolderConnection(folder: String) async throws -> IMAPServer {
        // Evict LRU if at capacity (try IDLE as last resort before waiting)
        //
        // LOOP VARIANT (restated because T3.7 gave this loop a new arm). The
        // measured quantity is `folderServers.count - maxFolderConnections`,
        // bounded below by a negative number no smaller than
        // `-maxFolderConnections`. Every iteration ends in exactly one of four
        // ways, and NONE of them re-enters the loop without having strictly
        // decreased that quantity or left the function outright:
        //   (a) an eviction succeeded  ⇒ `folderServers.count` decreased by
        //       one (`evictLRUFolder`'s candidate filter guarantees it removed
        //       a real `folderServers` entry — that is D-18's whole point) or
        //       `evictIdleConnection()` freed a reserved slot, RAISING
        //       `maxFolderConnections` by one. Either way the measure drops.
        //   (b) the capacity waiter's resume tail ADOPTS this folder's
        //       connection ⇒ `return` (leaves the loop).
        //   (c) the resume tail finds the folder owned/being created elsewhere
        //       ⇒ `throw` (leaves the loop). This is the NEW arm, and it is a
        //       LEAVING arm, not a KEEP arm — it cannot hang the loop.
        //   (d) the resume tail finds neither ⇒ `continue`, but only after a
        //       wake, and a wake is only issued by a mutation that freed or
        //       idled a slot, so the guard is re-evaluated against strictly
        //       newer state rather than spun on.
        // The only non-terminating shape would be a wake issued with no state
        // change at all; `wakeOneFolderCapacityWaiter`'s call sites are
        // enumerated in the contract above and every one of them either freed a
        // slot or abandoned capacity it had itself just freed.
        while folderServers.count >= maxFolderConnections {
            guard evictLRUFolder() || evictIdleConnection() else {
                // All connections in use and IDLE already evicted — wait for ANY folder to free up
                if DebugModeManager.isLoggingEnabled() { print("[IMAP] All \(folderServers.count) folder connections in use — waiting") }
                // T3.7 PORT (D-14) — `v2final:…:IMAPProvider
                // .createFolderConnection`'s capacity branch. Park in the
                // dedicated CAPACITY queue, NOT `folderWaiters[folder]`: that
                // queue is served only by SAME-folder events, and the event
                // this task is waiting for is an OTHER folder's slot freeing.
                // A singleton acquire for a traffic-less folder parked here
                // was structurally unwakeable — see `folderCapacityWaiters`.
                let queuedGeneration = generation
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    folderCapacityWaiters.append((queuedGeneration, cont))
                }
                // A wake is a HINT, never an ownership transfer. Re-validate
                // generation first (a teardown fails this queue, but a wake
                // already in flight can still race the bump).
                guard generation == queuedGeneration else {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[IMAP] Voided capacity-wait for \(folder) — throwing for retry")
                    }
                    throw ProviderError.notConnected
                }
                if let server = folderServers[folder], !folderInUse.contains(folder) {
                    // This folder's own connection appeared while we waited and
                    // nobody holds it — adopt it in this same turn (no awaits
                    // between the test and the mark, so no double checkout).
                    folderInUse.insert(folder)
                    folderLastUsed[folder] = Date()
                    return server
                }
                if folderServers[folder] != nil || folderCreating.contains(folder) {
                    // Someone else now owns (or is creating) this folder's
                    // connection — creating a second one here would race the
                    // single-flight. Throw for retry, exactly like a voided
                    // transfer.
                    if DebugModeManager.isLoggingEnabled() {
                        print("[IMAP] Capacity-wake found \(folder) owned elsewhere — throwing for retry")
                    }
                    throw ProviderError.notConnected
                }
                continue
            }
        }

        // Mark as creating — prevents duplicate creation from actor reentrancy
        // (another caller hitting acquireFolderConnection during our awaits below)
        folderCreating.insert(folder)
        #if DEBUG
        // T0.6(a) test seam — fires after `folder` is marked `folderCreating`
        // but BEFORE `createServer()` establishes anything. This is the window
        // the folder pool's single-flight exists to cover: a test parks here
        // and checks that a concurrent same-folder acquire QUEUES on
        // `folderWaiters[folder]` instead of racing a second creation.
        // Compiled out of Release; `nil` in every non-test context.
        if let hook = createFolderConnectionCreationTestHook { await hook() }
        #endif

        let t0 = CFAbsoluteTimeGetCurrent()
        // T3.7 PORT (D-13 / R11-H2) — visible across BOTH the primary attempt
        // and the limit-retry below. Set the instant `createServer()` returns
        // (the server is logged in), reset before the retry starts its OWN
        // attempt. It lets each catch tell "`createServer()` itself threw —
        // nothing logged in, nothing to clean up" apart from "login succeeded
        // but the SELECT after it threw before the plant — a live, logged-in
        // session this function is about to abandon".
        var createdServer: IMAPServer?
        do {
            let server = try await createServer(diagSite: "folderCreate")
            createdServer = server
            // T1.2b: the OPEN-the-folder SELECT — the one a folder-pinned
            // connection performs once, before any caller has asked for anything.
            // It is routed through the tracked helper so the mirror describes the
            // pinned connection's actual selected mailbox from the moment the
            // connection exists. No test isolates this site: every
            // `withFolderConnection` caller in this file today re-SELECTs the same
            // folder before issuing commands (`fetchMessages` directly, the
            // backfill SEARCHes via `searchDateRange`/`searchBeforeOnly`), so the
            // observation it makes is currently indistinguishable from the body's.
            _ = try await selectMailboxTracked(server, folder: folder)
            folderCreating.remove(folder)
            #if DEBUG
            assertPoolSlotWasNil(folderServers[folder], "folderServers[\(folder)]")
            #endif
            folderServers[folder] = server
            folderLastUsed[folder] = Date()
            folderInUse.insert(folder)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] Created pinned connection for \(folder) in \(ms)ms (total: \(folderServers.count)/\(maxFolderConnections))") }
            // T3.7 PORT (R5-F1) — do NOT resume a queued waiter here. THIS
            // call's caller (`withFolderConnection`) is about to use `server`
            // via its own `body`, and already holds `folderInUse`. Resuming a
            // waiter now hands the SAME socket to a second task while the
            // creator is still using it: both re-mark `folderInUse` (a no-op
            // membership test) and proceed concurrently — the creation-time
            // resume overlap, a double checkout with no teardown involved.
            // Any waiter queued during creation stays queued until the
            // creator's own `releaseFolderConnection`, which transfers
            // ownership directly (see that function's handoff).
            return server
        } catch {
            // T3.7 PORT (D-13 / R11-H2) — `createServer()` succeeded (the
            // server logged in) but `selectMailboxTracked` threw before the
            // plant above. Abandoning that logged-in server without logging it
            // out leaks a live session nothing ever tracks or tears down again
            // — and it still counts against the server's connection cap, so it
            // makes the very limit error this branch is about to handle WORSE.
            // Same explicit-logout discipline as every other discard site here.
            if let createdServer {
                noteLogoutAttempt(createdServer)
                Task { try? await createdServer.logout() }
            }
            // T3.7 PORT (D-11 / R8-F2): `folderCreating` MUST survive the whole
            // limit-retry below — do NOT remove it here at catch entry. Pre-fix
            // the removal ran immediately, and then the retry's own
            // `createServer()` + SELECT (a creation genuinely still in flight)
            // elapsed with the flag CLEARED — a window in which a concurrent
            // same-folder acquire saw "no connection, nobody creating", took
            // branch 3, and raced a SECOND creation for the SAME folder,
            // planting over `folderServers[folder]`. The flag now clears only
            // at this function's TRUE exits: the retry's success plant, the
            // retry's failure throw, and this catch's own no-retry throw.
            let isLimitError = "\(error)".contains("max_userip_connections")
            parseAndApplyServerLimit(from: error)

            // Connection limit hit — evict LRU folder (or IDLE as last resort) and retry once
            if isLimitError && (evictLRUFolder() || evictIdleConnection()) {
                if DebugModeManager.isLoggingEnabled() { print("[IMAP] Connection limit hit for \(folder) — evicted LRU, retrying") }
                #if DEBUG
                // T3.7 test seam (D-11 / R8-F2): fires right after eviction
                // succeeds but BEFORE the retry's own `createServer()` — lets a
                // test park here long enough for a concurrent same-folder
                // acquire to observe the (now-surviving) `folderCreating` mark
                // and queue instead of racing a second creation.
                if let hook = createFolderConnectionLimitRetryTestHook { await hook() }
                #endif
                // Reset — the retry tracks ONLY its own `createServer()`
                // result, never the primary attempt's (already logged out
                // above, if it ever logged in).
                createdServer = nil
                do {
                    let server = try await createServer(diagSite: "folderRetry")
                    createdServer = server
                    // T1.2b: the same open-the-folder SELECT as the primary create
                    // path above, on the connection-limit retry leg.
                    _ = try await selectMailboxTracked(server, folder: folder)
                    folderCreating.remove(folder)
                    #if DEBUG
                    assertPoolSlotWasNil(folderServers[folder], "folderServers[\(folder)]")
                    #endif
                    folderServers[folder] = server
                    folderLastUsed[folder] = Date()
                    folderInUse.insert(folder)
                    let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP] Created pinned connection for \(folder) in \(ms)ms (total: \(folderServers.count)/\(maxFolderConnections))") }
                    // Same R5-F1 rationale as the primary success path above —
                    // no premature resume; the creator's own release hands off.
                    return server
                } catch {
                    // D-13 again: the retry's own `createServer()` may have
                    // logged in before this retry's SELECT threw.
                    if let createdServer {
                        noteLogoutAttempt(createdServer)
                        Task { try? await createdServer.logout() }
                    }
                    folderCreating.remove(folder)
                    parseAndApplyServerLimit(from: error)
                    let waiters = folderWaiters.removeValue(forKey: folder) ?? []
                    for w in waiters { w.resume(throwing: error) }
                    // T3.7 PORT (R10-F1): this retry's own eviction (above)
                    // freed a slot for a creation attempt that just failed —
                    // wake a parked capacity waiter so it can claim that
                    // abandoned capacity instead of wedging beside it. Hint
                    // only; safe even when this failure freed nothing.
                    wakeOneFolderCapacityWaiter()
                    throw error
                }
            }

            // Fail waiters that queued during creation
            folderCreating.remove(folder)
            let waiters = folderWaiters.removeValue(forKey: folder) ?? []
            for w in waiters { w.resume(throwing: error) }
            // T3.7 PORT (R10-F1): the initial capacity loop above may have
            // evicted a slot for THIS task's own (now-failed) creation attempt
            // — without a wake here that freed capacity has no way to reach a
            // waiter still parked beside it. Hint only, same as above. This is
            // the SECOND of the two failure exits the item's brief names.
            wakeOneFolderCapacityWaiter()
            throw error
        }
    }

    /// Evict the least recently used folder connection that is NOT in use.
    /// Returns true if a connection was evicted, false if all are in use.
    @discardableResult
    private func evictLRUFolder() -> Bool {
        // T3.7 PORT (D-18) — `v2final:…:IMAPProvider.evictLRUFolder`'s
        // candidate filter. `folderLastUsed` is DOUBLE-KEYED: it also carries
        // `"__action__"`, the action pool's own liveness timestamp, which never
        // has a corresponding `folderServers` entry. Without restricting
        // candidates to keys that actually OWN a pinned connection, a long-idle
        // action lane can be picked as the LRU "candidate":
        // `folderServers.removeValue(forKey: "__action__")` is a no-op,
        // `folderLastUsed.removeValue` deletes the action lane's liveness
        // stamp, and this function still returns `true` ("evicted") having
        // freed no real folder slot — a PHANTOM eviction that then authorizes a
        // doomed immediate retry in `createFolderConnection`'s limit-retry
        // caller, which reads `true` as "a connection was actually freed". It
        // also breaks the capacity loop's variant above, whose arm (a) requires
        // a `true` to mean the measure strictly decreased.
        let candidates = folderLastUsed.filter { folderServers[$0.key] != nil && !folderInUse.contains($0.key) }
        guard let (folder, _) = candidates.min(by: { $0.value < $1.value }) else {
            return false
        }
        let server = folderServers.removeValue(forKey: folder)
        folderLastUsed.removeValue(forKey: folder)
        if let server {
            noteLogoutAttempt(server)
            Task { try? await server.logout() }
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] Evicted LRU pinned connection for \(folder)") }
        }
        return true
    }

    private func releaseFolderConnection(folder: String, healthy: Bool) async {
        guard healthy else {
            folderInUse.remove(folder)
            let server = folderServers.removeValue(forKey: folder)
            folderLastUsed.removeValue(forKey: folder)
            // Deliberately NOT wired into `beforeLogoutTestHook`: unlike
            // `disconnect()`/`markDirty()` (EXTERNAL teardowns that can steal a
            // connection some OTHER task still holds) this branch is the
            // exclusive holder's OWN self-triggered unhealthy release, whose
            // entry and release legitimately share one generation whenever no
            // teardown ran in between — indistinguishable from a genuine steal
            // by the entry-gen-vs-logout-gen predicate.
            if let server {
                noteLogoutAttempt(server)
                Task { try? await server.logout() }
            }
            // Fail all waiters for this folder — they'll create a new connection
            let waiters = folderWaiters.removeValue(forKey: folder) ?? []
            for waiter in waiters {
                waiter.resume(throwing: ProviderError.notConnected)
            }
            // A slot just freed — wake one parked capacity waiter (hint only).
            wakeOneFolderCapacityWaiter()
            return
        }

        folderLastUsed[folder] = Date()

        // T3.7 PORT (R5-F1) — ownership-RESERVING handoff, the folder-pool
        // sibling of `releaseActionConnection`'s. NEVER publish `folder` as
        // free (`folderInUse.remove`) while a waiter is queued for it: the old
        // order removed the mark FIRST and resumed the waiter as a separate
        // step, and in that gap a brand-new `acquireFolderConnection` with ZERO
        // awaits of its own could read `!folderInUse.contains(folder)`, check
        // the SAME pinned connection out via branch 1, and the resumed waiter
        // would later re-insert into `folderInUse` (a no-op membership test)
        // and return the SAME `IMAPServer` — both believing they hold it
        // exclusively. Keeping the mark across the handoff closes the window:
        // any concurrent acquire queues as a NEW waiter instead of stealing it.
        if var waiters = folderWaiters[folder], !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            folderWaiters[folder] = waiters.isEmpty ? nil : waiters
            #if DEBUG
            // T3.7 test seam: fires AFTER the waiter is dequeued but BEFORE its
            // continuation is resumed — the job-hop gap the resumed waiter's
            // own voided-transfer tail exists to cover.
            if let hook = releaseFolderConnectionPostDequeueTestHook { await hook() }
            #endif
            waiter.resume()
            return
        }

        folderInUse.remove(folder)
        // This folder's slot is now idle — evictable by a parked capacity
        // waiter's own eviction pass. Wake one (hint only). This is the wake
        // the pre-T3.7 design structurally lacked: a capacity-parked acquire
        // for a folder with no traffic of its own could never learn that some
        // OTHER folder's slot went idle.
        wakeOneFolderCapacityWaiter()
    }

    // MARK: - Action Connection API

    /// T3.3 — marker for "the mailbox this action names is CONFIRMED gone".
    ///
    /// PORT — `v2final:TabMail/Providers/IMAPProvider.swift`,
    /// `IMAPProvider.IMAPActionMailboxAbsent`. Deliberately `private`: nothing
    /// outside this file can name the type, so it can never become a
    /// classification input anywhere except the swallow sites in this file.
    ///
    /// Under the provider-id queue every propagated throw means "transient —
    /// retry", so a mailbox that no longer exists would otherwise pin its lane
    /// forever behind a command no server can ever satisfy. A caller with a
    /// defined "the mailbox is gone ⇒ nothing left to do" outcome catches this
    /// and returns normally. Callers with no such outcome
    /// (`fetchAttachment`, `appendToSentFolder`, `saveDraft`) let it propagate
    /// exactly like the SELECT failure it stands in for — same throw, same
    /// retry classification, only a different error value.
    private struct IMAPActionMailboxAbsent: Error {}

    /// T3.3 — authoritative existence probe, used ONLY after a SELECT has
    /// already failed on an ACTION path.
    ///
    /// PORT — `v2final:…:IMAPProvider.mailboxConfirmedAbsent(_:server:)`,
    /// body and policy unchanged. `IMAPError.selectFailed`'s reason text is
    /// server-defined and not machine-parseable, so this never inspects it: a
    /// LIST for the exact mailbox name is the only authority.
    ///   - LIST succeeds and no mailbox carries this exact name → confirmed
    ///     absent (authoritative stale — the whole op is a no-op).
    ///   - LIST succeeds and the mailbox IS present → the original SELECT
    ///     failure was transient (permissions hiccup, momentary server
    ///     glitch); the caller rethrows it and the op retries.
    ///   - LIST itself fails → uncertainty, NOT absence; the caller rethrows
    ///     the original SELECT failure. Fail-closed in the safe direction:
    ///     "don't know" never becomes "gone".
    /// Runs on the SAME connection that just failed SELECT — a tagged NO/BAD
    /// response does not kill an IMAP connection (only a connection-level
    /// failure does, and the caller's release classifies that separately).
    /// `folder` is passed as the literal LIST pattern (it carries no wildcard
    /// characters), which servers treat as an exact-match query, and the
    /// result is STILL matched on the exact name so a server that answers with
    /// a prefix/substring neighbour cannot be misread as presence.
    private func mailboxConfirmedAbsent(_ folder: String, server: IMAPServer) async -> Bool {
        guard let mailboxes = try? await server.listMailboxes(wildcard: folder) else {
            return false
        }
        return !mailboxes.contains { $0.name == folder }
    }

    /// Health classification + release for a failed action checkout, extracted
    /// so the SELECT leg and the body leg of `withActionConnectionSelection`
    /// share ONE implementation (T3.3 gave the SELECT its own leg).
    ///
    /// Deliberately NOT shared with `withActionConnectionNoSelect`: that
    /// wrapper does not call `parseAndApplyServerLimit`, and reusing this
    /// helper there would silently change its behaviour.
    ///
    /// T3.7 (D-01): takes the caller's `acquiredGeneration` and refuses to
    /// touch pool state when the epoch moved. `v2final` writes this as a nested
    /// `releaseAfterFailure` closure inside `withActionConnectionSelection`,
    /// capturing that value implicitly; this base had already factored the body
    /// out into a shared method (T3.3), so the value is passed explicitly
    /// instead. Same guard, same order, one implementation.
    private func releaseActionConnectionAfterFailure(
        _ error: Error, server: IMAPServer, acquiredGeneration: Int
    ) async {
        #if DEBUG
        if let hook = actionConnectionHolderExitTestHook { hook(server, generation) }
        #endif
        guard generation == acquiredGeneration else {
            if DebugModeManager.isLoggingEnabled() {
                print("[IMAP] Stale generation for action connection — discarding release after error")
            }
            #if DEBUG
            logMut("withActionConnection releaseAfterFailure DISCARD (acquired=\(acquiredGeneration)): \(error)")
            #endif
            return
        }
        let desc = "\(error)"
        let isUnhealthy = SyncEngine.isConnectionError(error)
            || desc.contains("PayloadTooLargeError")
            || desc.contains("IMAPDecoderError")
        if isUnhealthy { parseAndApplyServerLimit(from: error) }
        await releaseActionConnection(healthy: !isUnhealthy)
    }

    /// Execute a user-initiated operation on the reserved action connection.
    /// SELECTs the folder per-operation (~150ms). Never blocked by background work.
    private func withActionConnection<T>(
        folder: String,
        _ body: (IMAPServer) async throws -> T
    ) async throws -> T {
        try await withActionConnectionSelection(folder: folder) { server, _ in
            try await body(server)
        }
    }

    /// T1.1 (E1): the Selection-passing core — the body receives the ACTION
    /// connection's OWN `Mailbox.Selection`, i.e. the UIDVALIDITY reported by
    /// the SELECT this very call just issued on this very connection. The
    /// epoch has always been on the wire (`selectMailbox` returns it); the
    /// action path simply discarded it with `_ =`, which is why nothing
    /// downstream could verify it. A caller that needs the live epoch must
    /// read it from its own uninterrupted selection rather than from any
    /// shared mirror a concurrent SELECT on another connection can overwrite
    /// mid-flow.
    ///
    /// This helper only *surrenders* the selection. It performs no epoch
    /// comparison and drops nothing — the checkpoints that consume it land in
    /// later items.
    private func withActionConnectionSelection<T>(
        folder: String,
        _ body: (IMAPServer, Mailbox.Selection) async throws -> T
    ) async throws -> T {
        let server = try await acquireActionConnection()
        // T3.7 PORT (D-01 / R3 R-1) — `v2final:…:IMAPProvider
        // .withActionConnectionSelection`. Capture generation AFTER the acquire
        // completes, in the SAME actor turn as its return (no `await` between
        // them). This wrapper had NO generation awareness at all before T3.7:
        // an action task torn down mid-body still ran its release against the
        // SUCCESSOR epoch, stripping a live holder's `actionInUse` mark and, on
        // the unhealthy leg, logging out its connection. Capturing BEFORE the
        // acquire would be the mirror-image bug (a release that always looks
        // stale, so the mark leaks forever).
        let acquiredGeneration = generation
        #if DEBUG
        // Full-body holder ENTER — fires here, before the SELECT below, because
        // a teardown racing a real SELECT is exactly the wire-level danger the
        // NO-LOGOUT-WHILE-HELD oracle exists to catch.
        if let hook = actionConnectionHolderEnterTestHook { hook(server, generation) }
        #endif
        let selection: Mailbox.Selection
        do {
            // T5.3 PORT — `v2final:…:IMAPProvider.withActionConnectionSelection`
            // binds this same SELECT from `selectMailboxTracked`
            // (`trackedSelection`). The value handed to `body` is unchanged: this
            // helper returns the very `Mailbox.Selection` the bare call returned.
            // The catch arm below is UNAFFECTED — `selectMailboxTracked` adds one
            // non-throwing `Mutex` write and nothing else, so it cannot widen the
            // set of errors that reach `mailboxConfirmedAbsent` and become the
            // terminal `IMAPActionMailboxAbsent`.
            selection = try await selectMailboxTracked(server, folder: folder)
        } catch {
            // T3.3 PORT — `v2final`'s `withActionConnectionSelection` SELECT
            // catch. A SELECT failure here can mean the mailbox this action
            // names was deleted remotely between enqueue and drain (terminal:
            // nothing to act on), or it can be transient (auth hiccup,
            // connection drop, malformed response — must retry). Only the LIST
            // probe can tell the two apart; the NO response's own text never
            // decides it. The connection is released with the ORIGINAL error so
            // pool-health classification is unchanged either way.
            let confirmedAbsent = await mailboxConfirmedAbsent(folder, server: server)
            await releaseActionConnectionAfterFailure(
                error, server: server, acquiredGeneration: acquiredGeneration)
            if confirmedAbsent {
                if DebugModeManager.isLoggingEnabled() {
                    print("[IMAP] Action SELECT failed and LIST confirms '\(folder)' is absent — terminal, not transient")
                }
                throw IMAPActionMailboxAbsent()
            }
            throw error
        }
        #if DEBUG
        // T0.6(a) test seam — action-pool sibling of
        // `folderConnectionTestHook`. Fires once per checkout, after the
        // action connection is acquired AND SELECTed but BEFORE `body`
        // runs, i.e. while this task holds `actionInUse`. Compiled out of
        // Release; `nil` in every non-test context.
        if let hook = actionConnectionTestHook { await hook() }
        #endif
        // T3.7 PORT (D-16 / cross-field invariant #6) — the SELECT above is a
        // REAL, always-present wire round-trip in production (not merely the
        // test hook): a `disconnect()`/`markDirty()` landing during it can log
        // this exact connection out from under us. Pre-fix the ONLY re-check
        // happened AFTER `body()` completed, so `body()` itself could execute
        // against a connection whose generation had already moved, with the
        // holder unable to detect the interruption until its own command
        // returned. Re-validate HERE, before `body()` ever touches it.
        // RETRYABLE refusal (`ProviderError.notConnected`).
        guard generation == acquiredGeneration else {
            if DebugModeManager.isLoggingEnabled() {
                print("[IMAP] Stale generation for action connection before body — discarding silently")
            }
            #if DEBUG
            logMut("withActionConnection PRE-BODY GUARD fired (acquired=\(acquiredGeneration))")
            #endif
            throw ProviderError.notConnected
        }
        do {
            let result = try await body(server, selection)
            #if DEBUG
            if let hook = actionConnectionHolderExitTestHook { hook(server, generation) }
            #endif
            guard generation == acquiredGeneration else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[IMAP] Stale generation for action connection — discarding connection silently")
                }
                return result
            }
            await releaseActionConnection(healthy: true)
            return result
        } catch {
            await releaseActionConnectionAfterFailure(
                error, server: server, acquiredGeneration: acquiredGeneration)
            throw error
        }
    }

    /// Execute on the action connection without folder SELECT (for LIST, STATUS, etc.).
    ///
    /// T3.7 (D-01): this wrapper acquired and released the action slot with NO
    /// generation awareness on either path. `fetchFolders` and `folderStatus`
    /// (delta sync's routine STATUS poll) are its callers, so a task torn down
    /// mid-body wedged the STATUS poll specifically. Same
    /// capture-after-acquire shape as `withActionConnectionSelection`.
    private func withActionConnectionNoSelect<T>(
        _ body: (IMAPServer) async throws -> T
    ) async throws -> T {
        let server = try await acquireActionConnection()
        let acquiredGeneration = generation
        #if DEBUG
        if let hook = actionConnectionHolderEnterTestHook { hook(server, generation) }
        // Same hook (and same firing point: after acquire, before `body`) as
        // `withActionConnectionSelection`'s; the two wrappers' callers are
        // disjoint (LIST/STATUS here, SELECT-ful actions there), so a test
        // installing it targets exactly one wrapper per flow.
        if let hook = actionConnectionTestHook { await hook() }
        #endif
        // D-16's sibling — see `withActionConnectionSelection`'s pre-body guard.
        guard generation == acquiredGeneration else {
            if DebugModeManager.isLoggingEnabled() {
                print("[IMAP] Stale generation for action connection (no-select) before body — discarding silently")
            }
            #if DEBUG
            logMut("withActionConnectionNoSelect PRE-BODY GUARD fired (acquired=\(acquiredGeneration))")
            #endif
            throw ProviderError.notConnected
        }
        do {
            let result = try await body(server)
            #if DEBUG
            if let hook = actionConnectionHolderExitTestHook { hook(server, generation) }
            #endif
            guard generation == acquiredGeneration else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[IMAP] Stale generation for action connection (no-select) — discarding connection silently")
                }
                return result
            }
            await releaseActionConnection(healthy: true)
            return result
        } catch {
            #if DEBUG
            if let hook = actionConnectionHolderExitTestHook { hook(server, generation) }
            #endif
            guard generation == acquiredGeneration else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[IMAP] Stale generation for action connection (no-select) — discarding release after error")
                }
                throw error
            }
            let desc = "\(error)"
            let isUnhealthy = SyncEngine.isConnectionError(error)
                || desc.contains("PayloadTooLargeError")
                || desc.contains("IMAPDecoderError")
            await releaseActionConnection(healthy: !isUnhealthy)
            throw error
        }
    }

    /// Ensure the action connection exists, returning the (possibly fresh)
    /// server.
    ///
    /// T3.7 PORT (D-02 / D-07 / R6-1 Part 2 + R7-F1) —
    /// `v2final:…:IMAPProvider.ensureServer()`, commit `4d34ee864`. Two changes
    /// versus the nested local function this replaces:
    ///
    ///   1. It is a real method, so `connect()` can route through it (D-23).
    ///   2. It is SINGLE-FLIGHTED. Pre-fix, two concurrent callers that both
    ///      observed `actionServer == nil` each ran their own `createServer()`
    ///      and the loser planted OVER the winner's live slot — a leaked
    ///      logged-in connection (counting against the server's per-user cap)
    ///      plus two callers convinced they hold "the" action connection.
    ///      RED EVIDENCE (banked, pre-existing): arming
    ///      `assertPoolSlotWasNil(actionServer, …)` at the plant below on the
    ///      PRE-FIX code made `ProviderIdQueueFuzzTests`' T0.8 fuzzer trap the
    ///      process 3/3 at seed 8131249127217430530 — recorded in full under
    ///      D-02 in `IMAPProviderPoolInvariantTests.swift`. The trap is armed
    ///      in this same change, which is the only order that is ever safe.
    private func ensureServer() async throws -> IMAPServer {
        if let existing = actionServer { return existing }
        if actionServerCreating {
            // T3.7 PORT (R7-F1) — capture generation AT QUEUE TIME, the same
            // shape as every other resume tail in this file. The creator's
            // success path resumes every waiter with the fresh server BY
            // VALUE; a teardown landing after that `resume()` but before this
            // continuation actually runs (the job-hop gap) logs the fresh
            // server out, nils `actionServer` and bumps `generation`, and the
            // teardown's own fail-all sweep cannot catch us because we were
            // already dequeued at resume time. Detect it here and throw for
            // RETRY — never hand back a server this task never itself
            // validated as current.
            let queuedGeneration = generation
            let fresh = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<IMAPServer, Error>) in
                actionServerCreationWaiters.append((queuedGeneration, cont))
            }
            // Generation alone is NOT the full void set for this tail — the
            // same lesson as the dead-recreate's `actionServer === deadInstance`
            // guard. `releaseActionConnection(healthy: false)` and keepalive's
            // failure leg nil (and log out) `actionServer` with NO generation
            // bump, so a creation waiter resumed with `fresh` BY VALUE can run
            // AFTER the planted instance was already released out of the pool:
            // generation compares equal, the waiter adopts a LOGGED-OUT
            // connection the pool no longer tracks, and its caller's
            // not-in-use branch then marks `actionInUse = true` over a NIL slot
            // — a poisoned holder whose later healthy release hands off a nil
            // transfer and wedges the lane. Require the slot to STILL track the
            // exact instance being handed over; a mismatch/nil means whoever
            // removed it already owned its logout — throw for RETRY, never
            // adopt (and never log `fresh` out here: the other resumed waiters
            // legitimately hold the same reference).
            guard generation == queuedGeneration, actionServer === fresh else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[IMAP] Voided action-server creation-waiter transfer detected at resume — throwing for retry")
                }
                #if DEBUG
                logMut("creation-waiter-resume VOIDED (queuedGen=\(queuedGeneration))")
                #endif
                throw ProviderError.notConnected
            }
            return fresh
        }
        // Captured BEFORE `createServer()`'s RTT — the creator's OWN plant
        // below re-validates against THIS value, not merely
        // `assertPoolSlotWasNil`'s "slot still nil" check (which a concurrent
        // `disconnect()`/`markDirty()` ALSO leaves true, since teardowns wipe
        // `actionServer` to nil too; that assert cannot distinguish "still
        // virgin" from "was reset by a teardown that already voided this whole
        // creation attempt"). Unlike the creation WAITERS above, the CREATOR
        // had no such guard: a teardown racing the RTT could bump generation
        // with nothing to catch it, and the creator would plant `fresh` and
        // hand it to every waiter anyway — every downstream caller's OWN
        // `acquiredGeneration` capture then reads the ALREADY-POST-TEARDOWN
        // value, so nothing ever detects that `fresh` was born in a voided
        // epoch.
        let preCreateGeneration = generation
        actionServerCreating = true
        #if DEBUG
        logMut("ensureServer creator START (pre=\(preCreateGeneration))")
        #endif
        // CREATOR SINGLE-FLIGHT EPOCH SAFETY: the catch scope below is narrowed
        // to EXACTLY the `createServer()` await — the only failure it may clean
        // up after. Wrapping the race hook, the generation guard AND the plant
        // in one do/catch (the obvious shape) composes two defects: the
        // mismatch path's `throw` re-enters this function's own catch, whose
        // `actionServerCreating = false` then clobbers a SUCCESSOR creator's
        // in-flight flag and its fail-all sweeps the successor epoch's queue —
        // after which a third caller observes "nobody creating" and starts yet
        // another creator. Two concurrent creators is exactly the hazard
        // single-flight exists to prevent.
        let fresh: IMAPServer
        do {
            fresh = try await createServer(diagSite: "ensureServer")
            #if DEBUG
            logMut("ensureServer creator createServer SUCCEEDED")
            #endif
        } catch {
            actionServerCreating = false
            #if DEBUG
            logMut("ensureServer creator FAILED: \(error)")
            #endif
            let waiters = actionServerCreationWaiters
            actionServerCreationWaiters.removeAll()
            for (_, cont) in waiters { cont.resume(throwing: error) }
            throw error
        }
        #if DEBUG
        // Fires once, right after a fresh connection is created but BEFORE it
        // (or the in-use mark) lands — the exact window a concurrent
        // `disconnect()`/`markDirty()` must land in to reproduce the
        // capture-generation-before-vs-after-acquire hazard. `nil` in
        // production.
        if let hook = acquireActionConnectionRaceTestHook { await hook() }
        #endif
        guard generation == preCreateGeneration else {
            if DebugModeManager.isLoggingEnabled() {
                print("[IMAP] Stale generation for action-server creation — discarding fresh connection, failing waiters for retry")
            }
            #if DEBUG
            logMut("ensureServer creator generation MISMATCH (pre=\(preCreateGeneration)) — discard fresh, fail waiters")
            #endif
            // Whole cleanup — flag clear, waiter capture + fail — in ONE
            // synchronous turn, with the discard logout DETACHED (house style:
            // unhealthy release / markDirty), so no successor creator can ever
            // interleave a cleanup that is not its own epoch's.
            actionServerCreating = false
            let waiters = actionServerCreationWaiters
            actionServerCreationWaiters.removeAll()
            for (_, cont) in waiters { cont.resume(throwing: ProviderError.notConnected) }
            noteLogoutAttempt(fresh)
            Task { try? await fresh.logout() }
            throw ProviderError.notConnected
        }
        #if DEBUG
        // T3.7: ARMED. See this function's doc comment for the banked RED
        // evidence and why arming had to land in the same change as the
        // single-flight above.
        assertPoolSlotWasNil(actionServer, "actionServer (ensureServer create)")
        #endif
        actionServer = fresh
        actionServerCreating = false
        #if DEBUG
        logMut("ensureServer creator PLANTED fresh")
        #endif
        if DebugModeManager.isLoggingEnabled() { print("[IMAP] Created action connection") }
        let waiters = actionServerCreationWaiters
        actionServerCreationWaiters.removeAll()
        #if DEBUG
        // Fires after dequeue, before any waiter's continuation is resumed.
        // `nil` in production.
        if let hook = ensureServerCreationPostDequeueTestHook { await hook() }
        #endif
        for (_, cont) in waiters { cont.resume(returning: fresh) }
        return fresh
    }

    private func acquireActionConnection() async throws -> IMAPServer {
        var server = try await ensureServer()

        // If not in use, take it
        if !actionInUse {
            let now = Date()
            let shouldCheckLiveness = Self.shouldCheckConnectionLiveness(
                lastUsed: folderLastUsed["__action__"],
                now: now
            )
            // T3.7 PORT (R4-1) — capture generation AT MARK-SET TIME,
            // immediately as `actionInUse` flips true. Every await below (the
            // liveness noop, the post-noop re-ensure, the dead-connection
            // recreate) is a window where a concurrent `disconnect()`/
            // `markDirty()` can bump `generation` and clear the mark out from
            // under us (`markDirty()` runs on every session start — mainline
            // app lifecycle, not an edge case). Without re-validating after
            // each one, a resumed task silently returns a server WITHOUT
            // re-asserting the mark it thinks it still holds, letting a
            // concurrent acquire check out the SAME connection: SwiftMail
            // serializes individual commands only, so a second SELECT can
            // interpose between this task's SELECT and its own UID command — a
            // wrong-mailbox mutation (C3), no epoch swap required.
            // `withActionConnection*`'s own capture is structurally BLIND to
            // this: both the stale task and whatever now holds the connection
            // share the SAME post-bump generation.
            let acquiredGeneration = generation
            actionInUse = true
            #if DEBUG
            logMut("acquire-not-in-use SET actionInUse=true")
            #endif
            folderLastUsed["__action__"] = now

            // Verify liveness if idle too long
            if shouldCheckLiveness {
                #if DEBUG
                // Fires right before the liveness noop — the window a
                // concurrent teardown must land in to reproduce the hazard
                // above. `nil` in production.
                if let hook = acquireActionConnectionLivenessRaceTestHook { await hook() }
                #endif
                var livenessOk = false
                do {
                    _ = try await server.noop()
                    livenessOk = true
                } catch {
                    // Generation moved ⇒ the teardown that moved it already
                    // cleared the mark (and a successor holder may have re-set
                    // it) — releasing here would clobber that successor
                    // (ADR-IOS-059). RETRYABLE refusal.
                    guard generation == acquiredGeneration else {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] Stale generation for action connection during liveness check — discarding silently")
                        }
                        throw ProviderError.notConnected
                    }
                }

                if livenessOk {
                    // T3.7 PORT (D-03 / R6-1 Part 3) — re-`ensureServer()`
                    // after a SUCCESSFUL noop() must only ever return the SAME
                    // instance we just checked. The generation guard below
                    // catches every path that bumps `generation` when replacing
                    // `actionServer` — but nothing GUARANTEES every such path
                    // does (cross-field invariant #3). Comparing identity is
                    // independent of whether generation happened to move: if
                    // `ensureServer()` hands back something other than the
                    // connection this task just validated, someone else
                    // recreated it, and adopting a connection this task never
                    // checked the liveness of is exactly the bug.
                    let checkedServer = server
                    let reensured = try await ensureServer()
                    guard generation == acquiredGeneration else {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] Stale generation for action connection after liveness check — discarding silently")
                        }
                        throw ProviderError.notConnected
                    }
                    guard reensured === checkedServer else {
                        // Generation is UNCHANGED here — no teardown ran to
                        // reset `actionInUse` for us — yet `actionServer` was
                        // replaced under our held mark. This is the ONLY throw
                        // in either pool that could exit holding its in-use
                        // mark with an unchanged generation and no other writer
                        // having cleared it: left alone, `actionInUse` stays
                        // stuck `true` with no holder and the action lane
                        // wedges until an unrelated teardown clears it
                        // wholesale. Release exactly like every other
                        // unchanged-generation failure exit here. RETRYABLE.
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] Action connection rebound to a different instance during liveness re-validation — releasing mark and discarding")
                        }
                        await releaseActionConnection(healthy: false)
                        throw ProviderError.notConnected
                    }
                    server = reensured
                } else {
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP] Action connection dead — recreating") }
                    #if DEBUG
                    logMut("dead-recreate ENTER")
                    #endif
                    // T3.7 PORT (D-05 / R8-F1) — the instance THIS task just
                    // proved dead and still holds exclusively (`actionInUse`),
                    // captured before the createServer() RTT so the guards
                    // below can verify the slot was not re-planted by anything
                    // else while generation stayed put.
                    let deadInstance = server
                    let fresh: IMAPServer
                    do {
                        fresh = try await createServer(diagSite: "deadRecreate")
                        #if DEBUG
                        logMut("dead-recreate createServer SUCCEEDED")
                        #endif
                    } catch {
                        #if DEBUG
                        logMut("dead-recreate createServer FAILED: \(error)")
                        #endif
                        guard generation == acquiredGeneration else {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[IMAP] Stale generation for action connection after failed recreate — discarding silently")
                            }
                            throw ProviderError.notConnected
                        }
                        await releaseActionConnection(healthy: false)
                        throw error
                    }
                    #if DEBUG
                    // Fires once `createServer()` succeeds but BEFORE the
                    // generation re-validation (and therefore before the
                    // plant) — the exact window a concurrent teardown +
                    // acquire must land in to reproduce R8-F1. `nil` in
                    // production.
                    if let hook = acquireActionConnectionDeadRecreateRaceTestHook { await hook() }
                    #endif
                    // Re-validate generation BEFORE planting, not after.
                    // Pre-fix, `actionServer = fresh` ran unconditionally here:
                    // a teardown landing during the RTT above (bumping
                    // generation, wiping the slot) followed by a concurrent
                    // acquire that legitimately becomes the new holder (and
                    // plants its OWN fresh connection) meant this stale plant
                    // silently overwrote that live connection — a leaked
                    // logged-in connection in `actionServer` and an untracked
                    // holder still actively using the connection the pool no
                    // longer points to. On a moved generation: log `fresh` out
                    // and throw WITHOUT touching the slot. RETRYABLE.
                    guard generation == acquiredGeneration else {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] Stale generation for action connection after recreate — discarding silently")
                        }
                        #if DEBUG
                        logMut("dead-recreate generation MISMATCH (acquired=\(acquiredGeneration)) — discard fresh")
                        #endif
                        noteLogoutAttempt(fresh)
                        try? await fresh.logout()
                        throw ProviderError.notConnected
                    }
                    // The self-replace premise requires the slot to STILL hold
                    // the exact dead instance this task proved dead — the
                    // condition `assertActionServerSelfReplace`'s doc comment
                    // always claimed. "Generation unchanged is enough" is
                    // FALSE: `releaseActionConnection(healthy: false)` and
                    // keepalive's failure leg nil the slot WITHOUT a bump, so a
                    // dead instance released out from under this mid-recreate
                    // task leaves the slot nil under an UNCHANGED generation —
                    // and planting into that nil slot collides with any
                    // legitimately in-flight `ensureServer()` create
                    // (plant-over-non-nil from the create's side: DEBUG trap;
                    // release-build leaked logged-in connection). Mirror the
                    // rebind guard above: log `fresh` out, release the mark
                    // this task holds, throw. RETRYABLE.
                    guard actionServer === deadInstance else {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] Dead instance released out from under the action dead-recreate — refusing the plant, releasing mark and discarding")
                        }
                        #if DEBUG
                        logMut("dead-recreate IDENTITY MISMATCH — refuse plant, release")
                        #endif
                        noteLogoutAttempt(fresh)
                        try? await fresh.logout()
                        await releaseActionConnection(healthy: false)
                        throw ProviderError.notConnected
                    }
                    #if DEBUG
                    assertActionServerSelfReplace(actionServer, dead: deadInstance)
                    #endif
                    // R12-F1: `deadInstance` was proved dead by this task's own
                    // failed NOOP — dropped without logout by design (see
                    // `deadDropTestHook`).
                    noteDeadDrop(deadInstance)
                    actionServer = fresh
                    server = fresh
                    #if DEBUG
                    logMut("dead-recreate PLANTED fresh")
                    #endif
                }
            }
            return server
        }

        // In use — wait. T3.7 PORT (D-04 / R6-1 Part 1): capture `generation`
        // BEFORE queueing. By the invariant contract the ONLY events that can
        // VOID a pending/handed-off transfer are `markDirty()`/`disconnect()`,
        // and BOTH bump `generation` — so "generation moved while we waited" is
        // exactly the void set. (A raw identity compare against the instance we
        // queued behind would be WRONG here: the current holder's own
        // dead-recreate legitimately replaces `actionServer` with no bump, and
        // handing THAT fresh instance to us is a perfectly valid transfer.)
        let queuedGeneration = generation
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            actionWaiters.append(cont)
        }
        // Resumed. A successful resume here ALWAYS comes from
        // `releaseActionConnection`'s ownership-reserving handoff, which
        // transfers the CURRENT `actionServer` to us with `actionInUse` left
        // `true`. The only other paths that touch a queued continuation
        // (`releaseActionConnection(healthy:false)`, `disconnect()`,
        // `markDirty()`) explicitly FAIL it. A teardown landing in the job-hop
        // gap between the handoff's `resume()` and this continuation actually
        // running could NOT fail us (we were dequeued at handoff time), but it
        // DID bump `generation` and void the transfer. So a moved generation,
        // or a nil `actionServer`, is unambiguous evidence of a voided transfer
        // — including the ABA variant where a third task has already planted
        // and checked out a FRESH connection by the time we run. Never rebuild
        // here (D-04's pre-fix bug: the blind `ensureServer()` call silently
        // planted/adopted a connection this task never legitimately held,
        // composing into two holders on one `IMAPServer`). Throw and let the
        // caller RETRY — exactly what the still-queued waiters received from
        // the fail-all sweep. NOTE for future edits: this tail deliberately has
        // ZERO awaits between the guard below and the return; adding one
        // requires re-validating BOTH generation and identity after it.
        //
        // This throw deliberately does NOT touch `actionInUse` in EITHER void
        // case. Generation moved ⇒ the teardown already cleared the mark (and a
        // successor holder may have re-set it — clobbering that is the
        // ADR-IOS-059 bug). Generation UNCHANGED with a nil slot ⇒ the only
        // remaining source is a bumpless third-party slot-nil whose own path
        // (unhealthy release) already cleared the mark and failed the queue —
        // again nothing of ours to release. The mark's disposition is ALWAYS
        // the responsibility of whichever release/teardown voided the transfer.
        guard generation == queuedGeneration, let transferred = actionServer else {
            if DebugModeManager.isLoggingEnabled() {
                print("[IMAP] Voided action-connection transfer detected at waiter resume — throwing for retry")
            }
            #if DEBUG
            logMut("waiter-resume VOIDED (queuedGen=\(queuedGeneration))")
            #endif
            throw ProviderError.notConnected
        }
        server = transferred
        actionInUse = true
        #if DEBUG
        logMut("waiter-resume SET actionInUse=true (handoff)")
        #endif
        folderLastUsed["__action__"] = Date()
        return server
    }

    private func releaseActionConnection(healthy: Bool) async {
        guard healthy else {
            actionInUse = false
            folderLastUsed["__action__"] = Date()
            // Deliberately NOT wired into `beforeLogoutTestHook`: this is the
            // exclusive holder's OWN self-triggered unhealthy release, not an
            // external teardown, so the NO-LOGOUT-WHILE-HELD oracle must not
            // see it (it would be a false positive — see
            // `releaseFolderConnection`'s matching comment).
            if let server = actionServer {
                noteLogoutAttempt(server)
                Task { try? await server.logout() }
            }
            actionServer = nil
            #if DEBUG
            logMut("releaseActionConnection(healthy:false) CLEARED")
            #endif
            // Fail all waiters
            let waiters = actionWaiters
            actionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: ProviderError.notConnected)
            }
            return
        }

        folderLastUsed["__action__"] = Date()

        // Every caller reaches this healthy branch having just validated its
        // own `acquiredGeneration == generation` in the SAME actor turn, so
        // this capture equals the releasing holder's own generation. The ONLY
        // suspension point inside this branch is the DEBUG-only handoff hook
        // below (`nil` in production — the whole branch is then one synchronous
        // turn and this guard is trivially satisfied), but a chaos-installed
        // hook can park the release long enough for a teardown to land INSIDE
        // it: the teardown has already cleared the mark, failed every queued
        // waiter, and possibly admitted a NEW epoch's holder — a stale release
        // that then dequeues a new-epoch waiter (handing it fictitious
        // ownership: two holders on one instance) or flips `actionInUse =
        // false` out from under the new holder (double-checkout). Re-validate
        // after the await; generation moved ⇒ the teardown already did every
        // part of this release's job ⇒ return without touching anything.
        let entryGeneration = generation

        // T3.7 PORT (R5-F1) — ownership-RESERVING handoff. The old order
        // published the slot as free (`actionInUse = false` at the TOP of the
        // function) and THEN resumed a waiter as a separate step. In the gap
        // between those two steps, a brand-new `acquireActionConnection` call
        // with ZERO awaits of its own could read `actionInUse == false`, check
        // the connection out for itself via the "not in use" branch, and start
        // using it — while the resumed waiter's own continuation (scheduled but
        // not yet run) later re-marks `actionInUse = true` over the interloper
        // and returns the SAME `IMAPServer`. Both believe they hold it
        // exclusively; SwiftMail serializes individual commands only, so a
        // second SELECT can interpose before the first task's UID command — a
        // wrong-mailbox mutation (C3), no epoch swap required. Keeping
        // `actionInUse` TRUE across the handoff (never touched in this branch)
        // closes the window entirely: any concurrent acquire sees the slot
        // still held and queues as a NEW waiter instead of stealing it. This
        // also forecloses the "keepalive nils the server" variant: keepalive
        // only NOOPs/clears `actionServer` when `!actionInUse`, which can never
        // be true during this handoff.
        #if DEBUG
        if let hook = releaseActionConnectionHandoffTestHook { await hook() }
        #endif
        guard generation == entryGeneration else {
            #if DEBUG
            logMut("release healthy STALE (entry=\(entryGeneration)) — teardown landed during release, discarding")
            #endif
            return
        }
        // T3.7 PORT (D-06) — a healthy release whose slot is NIL under an
        // UNCHANGED generation has NOTHING to hand off. Pre-fix the handoff
        // below fired anyway: the dequeued waiter's resume tail found
        // `actionServer == nil` with generation unchanged and threw for retry —
        // correctly refusing the transfer, but with NO safe way to clear the
        // mark it had just been handed (ADR-IOS-059: from the tail's vantage
        // the bare `actionInUse` Bool could equally be a successor holder's
        // mark). The mark therefore stayed `true` with no live holder and every
        // remaining waiter parked forever — the action-lane wedge. HERE the
        // ambiguity does not exist: this call IS the owning holder's release,
        // so degenerate to the unhealthy-shape cleanup — clear the mark and
        // fail every waiter for RETRY (minus the logout: whoever nil'd the slot
        // already owned that).
        guard actionServer != nil else {
            #if DEBUG
            logMut("release healthy NIL SLOT — degenerate cleanup, failing \(actionWaiters.count) waiter(s)")
            #endif
            actionInUse = false
            let waiters = actionWaiters
            actionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: ProviderError.notConnected)
            }
            return
        }
        if !actionWaiters.isEmpty {
            let waiter = actionWaiters.removeFirst()
            #if DEBUG
            // Fires AFTER the waiter is dequeued but BEFORE its continuation is
            // resumed. `nil` in production.
            if let hook = releaseActionConnectionPostDequeueTestHook { await hook() }
            logMut("release HANDOFF to waiter (actionInUse stays true)")
            #endif
            waiter.resume()
            return
        }

        actionInUse = false
        #if DEBUG
        logMut("release healthy, no waiter — actionInUse=false")
        #endif
    }

    // MARK: - Keepalive

    /// Start periodic NOOP keepalive on idle pinned connections.
    /// Prevents server timeout during gaps between batches.
    func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(SyncConfig.imapPoolLivenessCheckSeconds))
                guard !Task.isCancelled else { return }
                await self?.keepAlivePinnedConnections()
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    private func keepAlivePinnedConnections() async {
        // T3.7 PORT (D-09 / R6 finding B-2) — every branch below re-validates
        // IDENTITY (`===` against the pool's CURRENT entry) after its `noop()`
        // await before mutating pool state. Pre-fix, a `markDirty()`/
        // `disconnect()` landing during a keepalive `noop()` (followed by a
        // fresh create for the same folder / the action slot) let the resumed
        // keepalive remove or nil the SUCCESSOR connection — an un-listed
        // mutator wiping a healthy entry with no logout (leaked socket) and no
        // generation awareness. The identity compare subsumes a generation
        // check here: any teardown either empties the slot or replaces it with
        // a different instance, and same-instance means the entry this pass
        // actually NOOPed is still the one being tracked.
        //
        // T3.7 PORT (D-08 / R8-F3) — identity alone is NOT enough: a concurrent
        // acquire can mark a folder (or the action slot) in-use DURING this
        // NOOP without touching the tracked instance at all (branch 1's
        // mark-before-await, D-10/R7-F2, flips the mark synchronously with zero
        // intervening await). A divergent NOOP outcome on that SAME connection
        // — the acquire's own liveness NOOP racing this one — could then have
        // keepalive remove the slot out from under a LIVE checkout even though
        // identity still matches. Pre-fix, the in-use precondition was tested
        // ONLY by the `where` clause, i.e. BEFORE the await. Both failure legs
        // below now re-check it AFTER the await, alongside identity.
        // NOOP all idle folder connections
        for (folder, server) in folderServers where !folderInUse.contains(folder) {
            #if DEBUG
            // Fires right before this folder's NOOP — AFTER the loop's own
            // `where` filter has passed, so a hook-installed concurrent-acquire
            // simulation lands in the SAME window a real acquire's zero-await
            // mark flip would. `nil` in production.
            if let hook = keepAliveFolderRaceTestHook { await hook(folder) }
            #endif
            do {
                _ = try await server.noop()
                if folderServers[folder] === server {
                    folderLastUsed[folder] = Date()
                }
            } catch {
                guard folderServers[folder] === server, !folderInUse.contains(folder) else { continue }
                if DebugModeManager.isLoggingEnabled() { print("[IMAP] Keepalive failed for \(folder) — removing") }
                noteDeadDrop(server)
                folderServers.removeValue(forKey: folder)
                folderLastUsed.removeValue(forKey: folder)
                // A slot just freed — wake one parked capacity waiter (hint
                // only; the waiter re-validates everything for itself).
                wakeOneFolderCapacityWaiter()
            }
        }
        // NOOP action connection if idle
        if !actionInUse, let server = actionServer {
            #if DEBUG
            // Folder sibling above, for the action slot. `nil` in production.
            if let hook = keepAliveActionRaceTestHook { await hook() }
            #endif
            do {
                _ = try await server.noop()
                if actionServer === server {
                    folderLastUsed["__action__"] = Date()
                }
            } catch {
                guard actionServer === server, !actionInUse else { return }
                if DebugModeManager.isLoggingEnabled() { print("[IMAP] Keepalive failed for action connection — removing") }
                noteDeadDrop(server)
                actionServer = nil
            }
        }
    }

    // MARK: - Lifecycle

    func connect() async throws {
        // T3.7 PORT (D-23 / R6 finding B-3) — routed through the
        // single-flighted `ensureServer()` instead of an unconditional
        // `actionServer = try await createServer()`.
        // `AccountManager.ensureConnected` calls `connect()` on
        // possibly-already-connected providers as a matter of course: the
        // unconditional plant overwrote a live non-nil `actionServer` (leaking
        // the old logged-in connection — cross-field invariant #2) and raced
        // any concurrent `ensureServer()` creation (invariant #4). Staleness is
        // handled by `markDirty()` (nils the slot → next `ensureServer()`
        // creates fresh) exactly as `ensureConnected`'s own doc comment
        // describes — a live slot here means "already connected", never
        // "replace me". The plant, and its `assertPoolSlotWasNil` trap, now
        // live in exactly one place.
        _ = try await ensureServer()
        if DebugModeManager.isLoggingEnabled() { print("[IMAP] Action connection ready") }
        startKeepAlive()
    }

    func disconnect() async throws {
        stopKeepAlive()
        stopIdle()
        // T3.7 PORT (D-15 / R9-F1) — advance generation BEFORE tearing anything
        // down, exactly like `markDirty()` below. Without the bump, a task whose
        // connection this call logs out mid-body still matches
        // `generation == acquiredGeneration` at release time and proceeds to
        // mutate whatever pool state exists BY THEN (a successor generation's
        // fresh connections) — killing healthy connections, clearing in-use
        // marks out from under a live checkout (double-checkout), and on the
        // action path risking a wrong-mailbox mutation (C3). `disconnect()` is
        // the reset reaction's own teardown call
        // (`AccountManagerUidValidityReset`), but every acquire/release path
        // must honor the bump regardless of which caller triggered it.
        //
        // The bump ALONE is not enough (R9-F1). Pre-fix this function awaited
        // each folder's (and the action connection's) LOGOUT INLINE, one at a
        // time, BEFORE any of `folderServers`/`actionServer`/the in-use marks
        // were cleared. That is NOT `markDirty()`'s shape despite the surface
        // similarity: `markDirty()`'s logouts run in DETACHED `Task`s, so its
        // bump-to-wipe path has ZERO suspension points; this one's did not. A
        // brand-new acquire landing in that awaited-logout window read the
        // ALREADY-bumped `generation` (nothing to compare it against — all of
        // ITS OWN downstream guards are trivially satisfied) and got handed a
        // connection this function was about to steal, with no FURTHER bump to
        // signal the theft. Worst tier: the stolen-mark holder's later HEALTHY
        // release fires the ownership-reserving handoff (R5-F1) on FICTITIOUS
        // ownership — handing a THIRD task's live connection to a waiter whose
        // resume-tail guard passes cleanly (generation unchanged since it
        // queued, slot non-nil) — two holders on one `IMAPServer`, a
        // wrong-mailbox class with no epoch swap required.
        //
        // Fix: bump generation, capture EVERY remaining slot + waiter array
        // into locals, clear every field, and fail every captured waiter — ALL
        // IN ONE SYNCHRONOUS ACTOR TURN (zero `await` between the bump and the
        // end of the fail-all). The awaited LOGOUTs then run on the captured
        // locals AFTER the wipe, not on the live fields before it — preserving
        // the reset reaction's requirement that `disconnect()` still blocks
        // until every pre-reset FOLDER-PINNED + ACTION session is provably
        // gone, without reopening the window: any concurrent acquire landing
        // during the awaited teardown now sees fully-cleared pool state and
        // builds a fresh connection instead of adopting a doomed one.
        // (`stopIdle()`, at the top, fires the IDLE session's own DONE/LOGOUT
        // on a detached Task — same fire-and-forget shape as `markDirty()` — so
        // the "provably gone" guarantee never covered the IDLE lane. An
        // in-flight `createFolderConnection` already past LOGIN is likewise not
        // captured: `folderCreating` survives this teardown by design, below,
        // and the creation's plant lands only AFTER this synchronous wipe.)
        generation += 1
        #if DEBUG
        logMut("disconnect() BUMP")
        #endif

        let capturedFolderServers = folderServers
        let capturedActionServer = actionServer
        let capturedFolderWaiters = folderWaiters
        let capturedFolderCapacityWaiters = folderCapacityWaiters
        let capturedActionWaiters = actionWaiters
        let capturedActionServerCreationWaiters = actionServerCreationWaiters

        folderServers.removeAll()
        folderLastUsed.removeAll()
        folderInUse.removeAll()
        // T3.7 PORT (D-12 / item B-1) — do NOT clear `folderCreating` here. A
        // `createFolderConnection` call genuinely in flight for some folder is
        // not cancelled by this teardown (only its EVENTUAL completion clears
        // its own entry) — wiping the flag mid-flight let a FRESH concurrent
        // caller for the SAME folder see "nobody creating" and start a SECOND
        // `createFolderConnection`, which then raced the first to plant
        // `folderServers[folder]`, silently overwriting the loser's connection
        // (planting over a non-nil slot, leaking a logged-in connection) — the
        // exact single-flight-overwrite hazard R6-1 Part 2 closes for the
        // action pool. Leaving `folderCreating` intact makes any concurrent
        // caller correctly queue as a waiter instead; the in-flight creation's
        // own completion clears the flag and its `withFolderConnection` release
        // hands off to that waiter normally (R5-F1, unaffected by the bump).
        folderWaiters.removeAll()
        folderCapacityWaiters.removeAll()

        actionServer = nil
        actionInUse = false
        #if DEBUG
        logMut("disconnect() WIPED")
        #endif
        actionWaiters.removeAll()
        // R6-1 Part 2 sibling: `actionServerCreating` is left untouched for the
        // SAME reason as `folderCreating` above — the in-flight
        // `createServer()` is not cancelled, and clearing the flag would let a
        // fresh caller race a SECOND concurrent creation.
        actionServerCreationWaiters.removeAll()

        for waiters in capturedFolderWaiters.values {
            for w in waiters { w.resume(throwing: ProviderError.notConnected) }
        }
        for (_, cont) in capturedFolderCapacityWaiters { cont.resume(throwing: ProviderError.notConnected) }
        for w in capturedActionWaiters { w.resume(throwing: ProviderError.notConnected) }
        for (_, cont) in capturedActionServerCreationWaiters { cont.resume(throwing: ProviderError.notConnected) }

        // === End of the synchronous turn. Every field the pool-state invariant
        // contract tracks is already consistent with the bumped generation —
        // nothing from here on can be observed by another task's acquire. ===

        #if DEBUG
        // Fires once, AFTER the wipe above but BEFORE the awaited teardown
        // below — lets a test deterministically interleave a concurrent acquire
        // in exactly the window the pre-fix build left open. On the FIXED code
        // this window is provably safe (every field is already cleared). `nil`
        // in production.
        if let hook = disconnectPostWipeTestHook { await hook() }
        #endif

        // Drain all folder connections
        for (folder, server) in capturedFolderServers {
            #if DEBUG
            if let logoutHook = beforeLogoutTestHook { logoutHook(server, generation) }
            #endif
            noteLogoutAttempt(server)
            try? await server.logout()
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] Disconnected pinned connection for \(folder)") }
        }
        // Drain primary connection
        if let server = capturedActionServer {
            #if DEBUG
            if let logoutHook = beforeLogoutTestHook { logoutHook(server, generation) }
            #endif
            noteLogoutAttempt(server)
            try? await server.logout()
        }
    }

    /// Fire-and-forget teardown logout used by `markDirty()`.
    ///
    /// ⚑ ADAPTED (structure only, no behavioural difference) — the reference
    /// writes `Task { [beforeLogoutTestHook, generation] in … }` inline at each
    /// of its three `markDirty()` sites. v3 gates its `…TestHook` surface behind
    /// `#if DEBUG` (the T0.6(a) deviation recorded in the Pool Invariant Test
    /// Seams header), so an inline capture list would need an `#if DEBUG` /
    /// `#else` pair at every site. Hoisting the three identical bodies here
    /// keeps ONE conditional. `generation` and the hook are read SYNCHRONOUSLY
    /// on the actor before the `Task` is created — the same capture-list
    /// semantics the reference relies on.
    private func detachedTeardownLogout(_ server: IMAPServer, sendDoneFirst: Bool = false) {
        noteLogoutAttempt(server)
        #if DEBUG
        let hook = beforeLogoutTestHook
        let logoutGeneration = generation
        Task {
            if let hook { hook(server, logoutGeneration) }
            if sendDoneFirst { try? await server.done() }
            try? await server.logout()
        }
        #else
        Task {
            if sendDoneFirst { try? await server.done() }
            try? await server.logout()
        }
        #endif
    }

    func markDirty() async {
        // After iOS suspension (background, BGAppRefresh, push wakeup), ALL connections
        // are assumed dead. Liveness checks on dead connections waste time and can silently
        // fail. The ONLY reliable path: disconnect everything, recreate fresh on next use.
        // This costs 1-3s but is the only way to guarantee working connections.

        // Advance generation — zombie tasks from previous generation will skip release
        // instead of accidentally removing newly created connections.
        //
        // T3.7: everything from this bump to the end of the function is ONE
        // SYNCHRONOUS ACTOR TURN. `markDirty()` is `async` only because its
        // callers await it; its body contains ZERO `await` — every logout is
        // detached (`detachedTeardownLogout`), and every waiter is failed
        // inline. No task can observe a half-updated pool.
        generation += 1
        #if DEBUG
        logMut("markDirty() BUMP")
        #endif

        // Nuke ALL folder connections (both idle and in-use)
        for (folder, server) in folderServers {
            detachedTeardownLogout(server)
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] markDirty: disconnecting pinned connection for \(folder)") }
        }
        folderServers.removeAll()
        folderLastUsed.removeAll()
        folderInUse.removeAll()
        // T3.7 PORT (D-12 / item B-1): `folderCreating` is deliberately NOT
        // cleared here — see `disconnect()`'s matching comment for the full
        // rationale (an in-flight `createFolderConnection` is not cancelled by
        // this teardown; wiping the flag opened a window for a second,
        // colliding concurrent creation for the same folder).
        // Fail all folder waiters — they'll get fresh connections on retry
        for (_, waiters) in folderWaiters {
            for w in waiters { w.resume(throwing: ProviderError.notConnected) }
        }
        folderWaiters.removeAll()
        // T3.7 PORT (D-14 sibling): the capacity queue is a REAL waiter queue
        // and must be swept by the teardown too, or a task parked waiting for a
        // folder slot survives the wipe with nothing left that could ever wake
        // it (every wake source — a release, an eviction, a keepalive drop —
        // needs pool state this function just erased).
        for (_, cont) in folderCapacityWaiters { cont.resume(throwing: ProviderError.notConnected) }
        folderCapacityWaiters.removeAll()

        // Stop IDLE listener (don't clear idleEnabled — it will resume after reconnect)
        idleListenerTask?.cancel()
        idleListenerTask = nil
        if let server = idleServer {
            // T3.7 PORT (D-22) — `.done()` BEFORE `.logout()`, mirroring
            // `stopIdle()`. SwiftMail's `executeCommandBody` calls
            // `waitForIdleCompletionIfNeeded()` before EVERY command including
            // LOGOUT; a bare `logout()` against a still-active IDLE session
            // therefore stalls behind a hard-coded 15s internal timeout
            // (`waitForIdleHandlerCompletion`'s default) before force-resetting
            // the connection — blowing this function's own "costs 1-3s"
            // contract for that connection's socket-level cleanup. Sending DONE
            // first terminates the IDLE session cleanly so the LOGOUT proceeds
            // immediately.
            detachedTeardownLogout(server, sendDoneFirst: true)
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] markDirty: disconnecting IDLE connection") }
        }
        idleServer = nil

        // Nuke action connection
        if let server = actionServer {
            detachedTeardownLogout(server)
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] markDirty: disconnecting action connection") }
        }
        actionServer = nil
        actionInUse = false
        #if DEBUG
        logMut("markDirty() WIPED")
        #endif
        let aw = actionWaiters
        actionWaiters.removeAll()
        for w in aw { w.resume(throwing: ProviderError.notConnected) }
        // R6-1 Part 2 sibling — see `disconnect()`'s matching comment.
        // `actionServerCreating` itself stays SET (the in-flight
        // `createServer()` is not cancelled); only its queue is swept.
        let asw = actionServerCreationWaiters
        actionServerCreationWaiters.removeAll()
        for (_, cont) in asw { cont.resume(throwing: ProviderError.notConnected) }
    }

    /// Server-declared per-user connection limit (e.g., `max_userip_connections=15`).
    /// `nil` until the server first rejects a connection with the limit error.
    func detectedServerLimit() -> Int? {
        serverConnectionLimit
    }

    /// Current max folder connections (server limit minus reserved for primary).
    func poolMaxConnections() -> Int {
        maxFolderConnections
    }

    // MARK: - Pool Invariant Test Seams (T0.6(a))
    //
    // The suite `IMAPProviderPoolInvariantTests` needs to assert the connection
    // pool's INVARIANTS on the real actor rather than on a hand-copied replica.
    // (The suites in the FILES `IMAPPrimaryConnectionTests.swift` and
    // `IMAPActionConnectionTests.swift` all drive private test doubles —
    // `TestPrimaryProvider` / `TestActionProvider`, private actors declared in
    // those two files — so nothing they assert is binding on the code below.
    // Those two names are FILENAMES; no type of either name exists.)
    //
    // T3.7 UPDATE — deviation 2 below is GONE. At T0.6(a) only the 17 seams the
    // then-shipping assertions used were ported, because the rest reproduced
    // races whose fixes were not yet in this base. T3.7 lands those fixes, so
    // the full surface is now present: matching
    // `^\s*(private |nonisolated |static )*(func|var|let) \w+(ForTesting|TestHook)`,
    // this file now declares the SAME 74 members the reference does, minus
    // `setLastObservedUidValidityForTesting` (a T1.x epoch-mirror seam with no
    // v3 counterpart — the mirror is reached differently here) and plus nothing.
    // Nothing here is invented: every member has a `v2final` counterpart.
    //
    // ONE deliberate deviation from the reference implementation (`v2final`,
    // `TabMail/Providers/IMAPProvider.swift`) remains:
    //
    //  1. The reference leaves its `…ForTesting` surface UNGATED. Here it is
    //     `#if DEBUG`, matching the convention this file already set with
    //     `actionConnectionSelectionUidValidityForTesting` (T1.1) — Release
    //     builds carry neither the storage nor the call sites. The ONE
    //     exception is the object-lifecycle oracle trio
    //     (`serverCreatedTestHook` / `logoutAttemptTestHook` /
    //     `deadDropTestHook`, declared far above with `createServer`): those are
    //     `nonisolated let Mutex<…>` deliberately reachable from detached
    //     logout `Task`s with zero actor hops, and their marker calls
    //     (`noteLogoutAttempt` / `noteDeadDrop`) sit at ~20 call sites including
    //     several inside `#if DEBUG`-free teardown paths. Gating them would
    //     require an `#if DEBUG` at every one; the reference leaves them
    //     ungated and the production cost is one uncontended lock read per
    //     connection creation/teardown (seconds apart, not per command).
    //
    // NOT a deviation, recorded because an earlier draft got it wrong: there is
    // no `generationForTesting()` here. The epoch is already observable —
    // `poolStateSnapshotForTesting()` below emits it as its leading
    // `generation=` field, exactly as the reference's does
    // (`v2final:TabMail/Providers/IMAPProvider.swift:843-844`), and the
    // reference additionally passes it to `beforeLogoutTestHook` and the
    // holder-enter/exit hooks. A dedicated getter would have been an invented
    // seam duplicating observability the reference already provides, so the
    // test reads the snapshot instead.
    #if DEBUG

    /// Test seam: install `folderConnectionTestHook` — see its call site in
    /// `withFolderConnection`.
    var folderConnectionTestHook: (@Sendable (String) async -> Void)?
    func setFolderConnectionTestHookForTesting(_ hook: (@Sendable (String) async -> Void)?) {
        folderConnectionTestHook = hook
    }

    /// Test seam: install `actionConnectionTestHook` — see its call site in
    /// `withActionConnectionSelection`.
    var actionConnectionTestHook: (@Sendable () async -> Void)?
    func setActionConnectionTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        actionConnectionTestHook = hook
    }

    /// Test seam: install `createFolderConnectionCreationTestHook` — see its
    /// call site in `createFolderConnection`.
    var createFolderConnectionCreationTestHook: (@Sendable () async -> Void)?
    func setCreateFolderConnectionCreationTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        createFolderConnectionCreationTestHook = hook
    }

    // MARK: T3.7 chaos seams (PORT — `v2final` counterparts, commit `4d34ee864`)
    //
    // Every hook below has the same contract: it fires at ONE named
    // await/resume boundary the invariant contract enumerates, and it is `nil`
    // in every non-test context (an `if let hook = optionalClosure { await
    // hook() }` executes NO suspension when the closure is nil, so production
    // timing is byte-identical either way). Together they are the PCT-style
    // chaos points the pool fuzzer parks on.

    /// Fires inside `ensureServer()` after `createServer()` succeeds but BEFORE
    /// the generation re-validation and the plant — the window a concurrent
    /// teardown must land in to reproduce the creator-epoch hazard.
    var acquireActionConnectionRaceTestHook: (@Sendable () async -> Void)?
    func setAcquireActionConnectionRaceTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        acquireActionConnectionRaceTestHook = hook
    }

    /// Fires in `acquireActionConnection`'s not-in-use branch immediately before
    /// the liveness NOOP — i.e. AFTER `actionInUse` was set, so a teardown
    /// landing here reproduces the R4-1 "mark cleared under a live holder"
    /// hazard.
    var acquireActionConnectionLivenessRaceTestHook: (@Sendable () async -> Void)?
    func setAcquireActionConnectionLivenessRaceTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        acquireActionConnectionLivenessRaceTestHook = hook
    }

    /// Fires in the dead-recreate branch once `createServer()` succeeds but
    /// BEFORE the generation/identity guards and the plant (R8-F1).
    var acquireActionConnectionDeadRecreateRaceTestHook: (@Sendable () async -> Void)?
    func setAcquireActionConnectionDeadRecreateRaceTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        acquireActionConnectionDeadRecreateRaceTestHook = hook
    }

    /// Folder-pool sibling of `acquireActionConnectionLivenessRaceTestHook` —
    /// fires in `acquireFolderConnection`'s branch 1 immediately before the
    /// liveness NOOP, after `folderInUse` was inserted (D-10 / R7-F2).
    var acquireFolderConnectionLivenessRaceTestHook: (@Sendable () async -> Void)?
    func setAcquireFolderConnectionLivenessRaceTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        acquireFolderConnectionLivenessRaceTestHook = hook
    }

    /// Fires at the TOP of `releaseActionConnection`'s healthy branch, before
    /// its entry-generation guard — the only place a test can park a release
    /// long enough for a teardown to land inside it (R5-F1's stale-release
    /// hazard).
    var releaseActionConnectionHandoffTestHook: (@Sendable () async -> Void)?
    func setReleaseActionConnectionHandoffTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        releaseActionConnectionHandoffTestHook = hook
    }

    /// Fires in `releaseActionConnection`'s healthy branch AFTER a waiter is
    /// dequeued but BEFORE its continuation is resumed — the ownership-reserving
    /// handoff's most dangerous instant (the waiter is off the queue, so no
    /// fail-all sweep can reach it).
    var releaseActionConnectionPostDequeueTestHook: (@Sendable () async -> Void)?
    func setReleaseActionConnectionPostDequeueTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        releaseActionConnectionPostDequeueTestHook = hook
    }

    /// Fires in `ensureServer()`'s creator success path after the creation
    /// waiters are dequeued but BEFORE any is resumed — the R7-F1 job-hop gap.
    var ensureServerCreationPostDequeueTestHook: (@Sendable () async -> Void)?
    func setEnsureServerCreationPostDequeueTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        ensureServerCreationPostDequeueTestHook = hook
    }

    /// Fires in `createFolderConnection`'s limit-retry catch, after the eviction
    /// but before the retry `createServer()` — the D-11 window where
    /// `folderCreating` must still be held.
    var createFolderConnectionLimitRetryTestHook: (@Sendable () async -> Void)?
    func setCreateFolderConnectionLimitRetryTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        createFolderConnectionLimitRetryTestHook = hook
    }

    /// Folder-pool sibling of `releaseActionConnectionPostDequeueTestHook`.
    var releaseFolderConnectionPostDequeueTestHook: (@Sendable () async -> Void)?
    func setReleaseFolderConnectionPostDequeueTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        releaseFolderConnectionPostDequeueTestHook = hook
    }

    /// Fires in `keepAlivePinnedConnections` right before a folder's NOOP —
    /// AFTER the loop's own `where !folderInUse.contains(folder)` filter has
    /// passed, so a hook-installed concurrent acquire lands in exactly the
    /// window D-08 describes.
    var keepAliveFolderRaceTestHook: (@Sendable (String) async -> Void)?
    func setKeepAliveFolderRaceTestHookForTesting(_ hook: (@Sendable (String) async -> Void)?) {
        keepAliveFolderRaceTestHook = hook
    }

    /// Action-slot sibling of `keepAliveFolderRaceTestHook`.
    var keepAliveActionRaceTestHook: (@Sendable () async -> Void)?
    func setKeepAliveActionRaceTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        keepAliveActionRaceTestHook = hook
    }

    /// Fires in `disconnect()` AFTER the synchronous bump-and-wipe turn but
    /// BEFORE the awaited logouts — the window the pre-R9-F1 build left open.
    /// On the fixed code every pool field is already cleared when this runs,
    /// which is precisely what a test parked here asserts.
    var disconnectPostWipeTestHook: (@Sendable () async -> Void)?
    func setDisconnectPostWipeTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        disconnectPostWipeTestHook = hook
    }

    /// Fires inside `launchIdleConnection`'s Task right after `createServer()`
    /// succeeds but BEFORE `claimIdleServerSlot` — the D-20 plant race window.
    var idleLaunchPlantRaceTestHook: (@Sendable () async -> Void)?
    func setIdleLaunchPlantRaceTestHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        idleLaunchPlantRaceTestHook = hook
    }

    // MARK: T3.7 NO-LOGOUT-WHILE-HELD oracle seams (PORT — `v2final`)
    //
    // These five are DELIBERATELY SYNCHRONOUS (no `async`), unlike every hook
    // above. Their real bodies only ever do in-memory bookkeeping — they never
    // NEEDED to suspend — but an `async` signature costs a REAL suspension
    // point at every call site once a non-nil hook is installed, and the
    // reference's own soak proved that widening `withActionConnection`'s
    // body-exit paths that way manufactured an action-lane wedge the fuzzer
    // would not otherwise reach. An observability tool must not change the
    // timing it exists to observe.
    //
    // Each also carries the provider's CURRENT `generation`. That is
    // load-bearing: `disconnect()`/`markDirty()` are DESIGNED to log out
    // whatever live connection they find regardless of whether some task holds
    // it, and that is SAFE precisely because the holder's own generation
    // mismatch catches the interruption on its next await. The class this
    // oracle catches is narrower — a connection ACQUIRED so late that its
    // `acquiredGeneration` ALREADY equals the generation a teardown had JUST
    // bumped to before that SAME teardown's logout, the one case where the
    // holder's check can never fire. Compare ENTRY generation against LOGOUT
    // generation for the same identity: equal ⇒ violation; unequal ⇒ an
    // ordinary self-correcting interruption, not a finding.
    private var actionConnectionHolderEnterTestHook: (@Sendable (IMAPServer, Int) -> Void)?
    private var actionConnectionHolderExitTestHook: (@Sendable (IMAPServer, Int) -> Void)?

    /// Test seam: install the action-pool holder enter/exit pair.
    func setActionConnectionHolderEnterTestHookForTesting(_ hook: (@Sendable (IMAPServer, Int) -> Void)?) {
        actionConnectionHolderEnterTestHook = hook
    }
    func setActionConnectionHolderExitTestHookForTesting(_ hook: (@Sendable (IMAPServer, Int) -> Void)?) {
        actionConnectionHolderExitTestHook = hook
    }

    /// Folder-pool sibling of the pair above — the folder path is passed
    /// alongside the instance since one provider tracks many folders
    /// concurrently.
    private var folderConnectionHolderEnterTestHook: (@Sendable (String, IMAPServer, Int) -> Void)?
    private var folderConnectionHolderExitTestHook: (@Sendable (String, IMAPServer, Int) -> Void)?

    /// Test seam: install the folder-pool holder enter/exit pair.
    func setFolderConnectionHolderEnterTestHookForTesting(_ hook: (@Sendable (String, IMAPServer, Int) -> Void)?) {
        folderConnectionHolderEnterTestHook = hook
    }
    func setFolderConnectionHolderExitTestHookForTesting(_ hook: (@Sendable (String, IMAPServer, Int) -> Void)?) {
        folderConnectionHolderExitTestHook = hook
    }

    /// Fires with the EXACT instance about to be logged out (and the CURRENT
    /// generation), at every teardown call site that could plausibly log out a
    /// connection some OTHER task still holds: `disconnect()` and `markDirty()`
    /// — the two EXTERNAL teardowns (cross-field invariant #1's void set).
    ///
    /// NOT wired into `releaseActionConnection(healthy:false)` /
    /// `releaseFolderConnection(healthy:false)`: those are the exclusive
    /// HOLDER'S OWN self-triggered unhealthy release, and their entry+release
    /// legitimately share one generation whenever no teardown ran in between
    /// (the mainline case) — indistinguishable from a steal by
    /// entry-gen-vs-logout-gen alone, i.e. a guaranteed false positive. Also
    /// deliberately NOT wired into call sites that only ever log out a
    /// connection nobody else could hold: a just-created `fresh` being
    /// discarded before it was ever returned to any caller, or an
    /// already-superseded IDLE owner logging out its own dead connection
    /// (`onIdleStreamEnded`'s identity-mismatch branch).
    private var beforeLogoutTestHook: (@Sendable (IMAPServer, Int) -> Void)?

    /// Test seam: install `beforeLogoutTestHook`.
    func setBeforeLogoutTestHookForTesting(_ hook: (@Sendable (IMAPServer, Int) -> Void)?) {
        beforeLogoutTestHook = hook
    }

    // MARK: T3.7 observability + direct drivers (PORT — `v2final`)

    /// Test-only observability: number of tasks parked in
    /// `actionServerCreationWaiters` (D-07's queue).
    func actionServerCreationWaiterCountForTesting() -> Int { actionServerCreationWaiters.count }

    // (No `actionServerCreatingForTesting()`: the flag is already observable
    // via `poolStateSnapshotForTesting()`'s `actionServerCreating=` field,
    // exactly as in the reference. A dedicated getter would be an invented seam
    // duplicating observability that already exists — the same reasoning the
    // header records for `generationForTesting()`.)

    /// Test-only observability: number of tasks parked in
    /// `folderCapacityWaiters` (D-14's queue).
    func folderCapacityWaiterCountForTesting() -> Int { folderCapacityWaiters.count }

    /// Test-only observability: the exact instance in the action slot, or nil.
    /// Identity — not mere presence — distinguishes "the holder's connection
    /// survived" from "some connection is there now".
    func currentActionServerForTesting() -> IMAPServer? { actionServer }

    /// Test seam: direct pass-through to the private `ensureServer()`, so a
    /// test can drive the single-flight path without a full acquire.
    @discardableResult
    func ensureServerForTesting() async throws -> IMAPServer { try await ensureServer() }

    /// Test seam: nil the action slot with NO teardown — manufactures the
    /// bumpless slot-nil that `releaseActionConnection`'s degenerate cleanup
    /// and `ensureServer()`'s creation-waiter identity guard exist to survive.
    /// Production code never does this.
    /// Hygiene: nils the slot with NO R12-F1 disposition mark — do not combine
    /// with the object-lifecycle hooks in a test that then drops the last
    /// strong reference, or the registry reports a false abandonment.
    func clearActionServerForTesting() { actionServer = nil }

    /// Test seam: set/clear the action in-use mark directly, to stage a
    /// contended acquire without a real checkout.
    func setActionInUseForTesting(_ inUse: Bool) { actionInUse = inUse }

    /// Test seam: nil a folder slot with NO teardown — folder sibling of
    /// `clearActionServerForTesting()`, same hygiene caveat.
    func clearFolderServerForTesting(folder: String) { folderServers.removeValue(forKey: folder) }

    /// Test-only observability: every folder currently checked out.
    func inUseFolderNamesForTesting() -> [String] { folderInUse.sorted() }

    /// Test-only observability: folders with at least one parked waiter, and
    /// how many. Empty entries are omitted so a `#expect` failure message names
    /// only the folders that actually matter.
    func nonEmptyFolderWaiterCountsForTesting() -> [String: Int] {
        folderWaiters.compactMapValues { $0.isEmpty ? nil : $0.count }
    }

    /// Test-only observability: the currently tracked IDLE connection, or nil.
    func currentIdleServerForTesting() -> IMAPServer? { idleServer }

    /// Test seam: trigger `launchIdleConnection()` directly — the deterministic
    /// stand-in for the retry-timer / eviction-relaunch callers that normally
    /// invoke it after a delay.
    func relaunchIdleConnectionForTesting() { launchIdleConnection() }

    /// Test seam: nil `idleServer` without a real teardown — manufactures "a
    /// successor may now claim the slot". Same R12-F1 hygiene caveat as
    /// `clearActionServerForTesting()`.
    func clearIdleServerForTesting() { idleServer = nil }

    /// Test seam: exercise `onIdleStreamEnded`'s identity-guarded teardown with
    /// an explicit (possibly stale) owner reference.
    func simulateIdleStreamEndedForTesting(owner: IMAPServer) {
        onIdleStreamEnded(owner: owner)
    }

    /// Test-only observability: number of tasks parked in `actionWaiters`.
    func actionWaiterCountForTesting() -> Int { actionWaiters.count }

    /// Test-only observability: whether the action connection is checked out.
    func actionInUseForTesting() -> Bool { actionInUse }

    /// Test-only observability: number of tasks parked in
    /// `folderWaiters[folder]`. In this base that queue holds BOTH the
    /// same-folder handoff waiters (`acquireFolderConnection` branch 2) and the
    /// capacity waiters `createFolderConnection` parks when the pool is full —
    /// the reference splits the latter into a separate `folderCapacityWaiters`
    /// queue, which this base does not have.
    func folderWaiterCountForTesting(folder: String) -> Int {
        folderWaiters[folder]?.count ?? 0
    }

    /// Test-only observability: whether `folder` is currently checked out.
    func folderInUseForTesting(folder: String) -> Bool {
        folderInUse.contains(folder)
    }

    /// Test seam: flip `folderInUse` membership without a real acquire — the
    /// deterministic stand-in for "a concurrent task holds this folder" in the
    /// keepalive and eviction tests, neither of which can otherwise pin a
    /// checkout across a synchronous call. Production code never does this.
    func setFolderInUseForTesting(folder: String, inUse: Bool) {
        if inUse { folderInUse.insert(folder) } else { folderInUse.remove(folder) }
    }

    /// Test-only observability: whether `folder` still has a tracked pinned
    /// connection.
    func hasFolderConnectionForTesting(folder: String) -> Bool {
        folderServers[folder] != nil
    }

    /// Test-only observability: the exact `IMAPServer` instance currently
    /// pinned to `folder`, or nil. Identity — not mere presence — is what
    /// distinguishes "the holder's connection survived" from "some connection
    /// is there now".
    func currentFolderServerForTesting(folder: String) -> IMAPServer? {
        folderServers[folder]
    }

    /// Test seam: backdate a pinned connection's last-used stamp so LRU
    /// ordering is decided by the test instead of by wall-clock creation
    /// order, which is too coarse to be reliable at test speed.
    func setFolderLastUsedForTesting(_ date: Date, folder: String) {
        folderLastUsed[folder] = date
    }

    /// Test seam: direct pass-through to the private `evictLRUFolder()`, so a
    /// test can exercise eviction without first driving the pool to capacity.
    @discardableResult
    func evictLRUFolderForTesting() -> Bool { evictLRUFolder() }

    /// Test seam: direct pass-through to the private
    /// `keepAlivePinnedConnections()`, so a test can run exactly one keepalive
    /// pass instead of waiting out `SyncConfig.imapPoolLivenessCheckSeconds`.
    func keepAlivePinnedConnectionsForTesting() async {
        await keepAlivePinnedConnections()
    }

    /// Test-only diagnostic dump of every pool-state field, for `#expect`
    /// failure messages. Never called outside a caller that asks for it.
    func poolStateSnapshotForTesting() -> String {
        "generation=\(generation) " +
        "actionServer=\(actionServer.map { "\(ObjectIdentifier($0))" } ?? "nil") " +
        "actionInUse=\(actionInUse) " +
        "actionWaiters=\(actionWaiters.count) " +
        "actionServerCreating=\(actionServerCreating) " +
        "actionServerCreationWaiters=\(actionServerCreationWaiters.count) " +
        "folderServers=\(folderServers.map { "\($0.key)=\(ObjectIdentifier($0.value))" }.sorted()) " +
        "folderInUse=\(folderInUse.sorted()) " +
        "folderCreating=\(folderCreating.sorted()) " +
        "folderWaiters=\(folderWaiters.mapValues { $0.count }.sorted { $0.key < $1.key }) " +
        "folderCapacityWaiters=\(folderCapacityWaiters.count) " +
        "idleServer=\(idleServer != nil) idleEnabled=\(idleEnabled)"
    }

    #endif

    // MARK: - IDLE (Dedicated Connection)

    /// Start IDLE monitoring on a dedicated connection.
    /// Creates its own connection (tracked in the budget, evictable when scarce).
    /// RFC 2177 requires no commands during IDLE, so a separate connection is mandatory.
    func startIdle(handler: @escaping @Sendable (IMAPServerEvent, String) async -> Void) {
        idleEnabled = true
        idleEventHandler = { [senderEmail] event in
            Task { await handler(event, senderEmail) }
        }
        launchIdleConnection()
    }

    /// Stop IDLE monitoring. Called on background transition.
    func stopIdle() {
        idleEnabled = false
        idleEventHandler = nil
        idleListenerTask?.cancel()
        idleListenerTask = nil
        if let server = idleServer {
            noteLogoutAttempt(server)
            Task { try? await server.done(); try? await server.logout() }
        }
        idleServer = nil
    }

    /// Minimum server connection limit to enable IDLE.
    /// With limit=2, we only have action + 1 folder slot — IDLE would starve sync.
    private static let idleMinServerLimit = 3

    /// Create the IDLE connection and start listening.
    /// Skips if server limit is too low (need action + folder + IDLE = 3 minimum).
    ///
    /// T3.7 PORT (D-20 / R7-F3) — this function is deliberately callable
    /// concurrently: its own callers (`startIdle`, `onIdleStreamEnded`'s retry
    /// timer, `evictIdleConnection`'s post-eviction relaunch) are not mutually
    /// exclusive, so two overlapping calls landing while `idleServer` is still
    /// nil (neither `createServer()` RTT has resolved) both reach the claim
    /// below. Pre-fix, the created connection was planted via an unconditional
    /// `setIdleServer(server)` with NO re-check after that await — the loser's
    /// plant silently overwrote the winner's tracked connection (leaked,
    /// logged-in, counting against the server's per-user cap), and a
    /// `stopIdle()`/`markDirty()` landing during the same await left the launch
    /// planting a connection nobody would ever clean up. The fix is entirely in
    /// `claimIdleServerSlot` — the ONLY plant site — rather than gating this
    /// function itself.
    private func launchIdleConnection() {
        guard idleEnabled, idleServer == nil else { return }
        // Don't launch IDLE if server limit is known and too tight
        if let limit = serverConnectionLimit, limit < Self.idleMinServerLimit {
            if DebugModeManager.isLoggingEnabled() { print("[IMAP:IDLE] Skipping — server limit \(limit) < \(Self.idleMinServerLimit), falling back to polling") }
            return
        }

        idleListenerTask?.cancel()
        idleListenerTask = Task { [weak self] in
            guard let self else { return }
            // T3.7 PORT (D-21 / R7-F3): tracks whether THIS launch actually
            // owns the slot, so the failure paths below can tell "my claimed
            // connection died" (tear down by identity) from "I never planted
            // anything" (just retry).
            var claimed: IMAPServer?
            do {
                let fresh = try await self.createServer(diagSite: "idleLaunch")
                #if DEBUG
                // Fires after `createServer()` succeeds but BEFORE the claim —
                // the window a concurrent overlapping launch must land in to
                // reproduce the plant race. `nil` in production.
                let plantHook = await self.idleLaunchPlantRaceTestHook
                if let plantHook { await plantHook() }
                #endif
                guard await self.claimIdleServerSlot(fresh) else {
                    // Lost the race (or IDLE was disabled/torn down while
                    // connecting) — this connection is surplus. Log it out and
                    // abandon this launch instead of overwriting whatever now
                    // holds the slot.
                    // `noteLogoutAttempt` is `nonisolated` (Mutex-backed) — no
                    // actor hop, so the mark cannot perturb the interleaving
                    // the oracle exists to observe.
                    self.noteLogoutAttempt(fresh)
                    try? await fresh.logout()
                    return
                }
                claimed = fresh
                // T5.3 PORT — `v2final:…:IMAPProvider.launchIdleConnection`
                // routes its own INBOX SELECT through `selectMailboxTracked`.
                // This connection then sits in IDLE for minutes, so the epoch it
                // reports here is a real, otherwise-unrecorded observation of
                // INBOX at the instant the IDLE lane opened.
                _ = try await self.selectMailboxTracked(fresh, folder: "INBOX")
                if DebugModeManager.isLoggingEnabled() { print("[IMAP:IDLE] Dedicated IDLE connection ready") }
                let events = try await fresh.idle()
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await self.dispatchIdleEvent(event)
                }
                // Stream ended (server broke IDLE or connection dropped)
                if DebugModeManager.isLoggingEnabled() { print("[IMAP:IDLE] Stream ended — reconnecting in 5s") }
                await self.onIdleStreamEnded(owner: fresh)
            } catch is CancellationError {
                // Expected — stopIdle or markDirty. If the claim already
                // succeeded, its owner tears down via the cancelling call
                // itself (`stopIdle`/`markDirty` read `idleServer` directly);
                // if not, nothing was ever planted — no retry, the cancellation
                // was intentional.
            } catch {
                if let claimed {
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP:IDLE] Error: \(error) — reconnecting in 10s") }
                    await self.onIdleStreamEnded(owner: claimed, delay: 10)
                } else {
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP:IDLE] Error creating IDLE connection: \(error) — reconnecting in 10s") }
                    await self.retryLaunchIdleConnection(delay: 10)
                }
            }
        }
    }

    /// T3.7 PORT (D-20 / R7-F3): the ONLY plant site for `idleServer`.
    /// Re-validates `idleEnabled && idleServer == nil` in the SAME synchronous
    /// actor-isolated step as the plant — closing both the launch-vs-launch
    /// race (two overlapping `launchIdleConnection()` calls both reaching this
    /// point) and the launch-vs-stop/teardown race (a `stopIdle()`/
    /// `markDirty()` landing during `createServer()`'s await already disabled
    /// IDLE or cleared the slot). Returns whether `server` became the tracked
    /// instance; `false` means the caller must log ITSELF out instead of
    /// proceeding to SELECT/IDLE. Deliberately NOT paired with a single-flight
    /// flag on `launchIdleConnection` itself: unlike the action/folder create
    /// paths (where concurrent callers must all converge on and WAIT for the
    /// SAME instance), IDLE callers do not need each other's result — they only
    /// need to never clobber each other — so this recheck alone fully closes
    /// the hazard.
    private func claimIdleServerSlot(_ server: IMAPServer) -> Bool {
        guard idleEnabled, idleServer == nil else { return false }
        idleServer = server
        return true
    }

    /// T3.7 PORT (R7-F3): retry helper for a launch whose `createServer()`
    /// itself failed before ever reaching the claim — it never touched
    /// `idleServer`/`idleListenerTask`, so there is nothing to tear down; just
    /// retry after the same delay every other IDLE failure path uses. Pre-fix
    /// this case fell into `onIdleStreamEnded()`, which nil'd `idleServer` and
    /// `idleListenerTask` wholesale — killing a HEALTHY IDLE connection some
    /// other launch had legitimately planted while this one was failing.
    private func retryLaunchIdleConnection(delay: TimeInterval) {
        guard idleEnabled else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            await self.launchIdleConnection()
        }
    }

    private func dispatchIdleEvent(_ event: IMAPServerEvent) {
        idleEventHandler?(event)
    }

    /// Called when IDLE stream ends unexpectedly (or after a post-claim
    /// failure). Cleans up and retries.
    ///
    /// T3.7 PORT (D-21 / R7-F3) — identity-guarded. `owner` is the SPECIFIC
    /// connection this listener session claimed and has been running on. A
    /// stale/superseded listener (this session's stream ended AFTER a LATER
    /// launch already replaced `idleServer` with a healthy successor) must
    /// never clear or log out that successor; it logs out only its OWN
    /// (already-dead) connection and returns without touching the slot or
    /// scheduling a redundant relaunch — the successor is already healthy.
    /// Pre-fix this function read `idleServer` directly and nil'd it
    /// unconditionally.
    private func onIdleStreamEnded(owner: IMAPServer, delay: TimeInterval = 5) {
        guard idleServer === owner else {
            noteLogoutAttempt(owner)
            Task { try? await owner.logout() }
            return
        }
        noteLogoutAttempt(owner)
        Task { try? await owner.logout() }
        idleServer = nil
        idleListenerTask = nil
        guard idleEnabled else { return }
        // Retry after delay
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            await self.launchIdleConnection()
        }
    }

    /// Evict the IDLE connection to free a server slot.
    /// Returns true if an IDLE connection was evicted, false if none was active.
    @discardableResult
    private func evictIdleConnection() -> Bool {
        guard let server = idleServer else { return false }
        if DebugModeManager.isLoggingEnabled() { print("[IMAP:IDLE] Evicting IDLE connection to free server slot") }
        idleListenerTask?.cancel()
        idleListenerTask = nil
        noteLogoutAttempt(server)
        Task { try? await server.done(); try? await server.logout() }
        idleServer = nil
        // Will relaunch after delay if idleEnabled is still true
        if idleEnabled {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.launchIdleConnection()
            }
        }
        return true
    }

    func fetchFolders() async throws -> [FolderInfo] {
        try await withActionConnectionNoSelect { server in
            let mailboxes = try await server.listMailboxes()

            // Build (info, attributes) pairs so the dedup pass can prefer the
            // folder carrying the actual SPECIAL-USE flag (RFC 6154) over a
            // folder that only matched the name-based heuristic. iCloud, for
            // example, exposes both "Trash" and "Deleted Messages" — only one
            // typically carries `\Trash`, and the other should fall back to
            // `.custom` instead of duplicating the role.
            var pairs: [(info: FolderInfo, attributes: Mailbox.Info.Attributes)] = []
            for info in mailboxes {
                guard info.isSelectable else { continue }
                var unread = 0
                var total = 0
                var uidNextVal: Int?
                var highestModSeqVal: Int?
                var uidValidityVal: Int?
                do {
                    let status = try await server.mailboxStatus(info.name)
                    unread = status.unseenCount ?? 0
                    total = status.messageCount ?? 0
                    uidNextVal = status.uidNext.map { Int($0.value) }
                    // CONDSTORE HIGHESTMODSEQ (nil unless the server advertises it) — the
                    // full-sync fetch-skip signal (Fix B task 4).
                    highestModSeqVal = status.highestModSequence
                    // UIDVALIDITY from the SAME STATUS response (nil unless the server
                    // advertises UIDPLUS — SwiftMail only requests the attribute then).
                    // This is what makes the epoch durable for a folder the deletion-
                    // reconcile walk has never visited. Normalised at THIS boundary so
                    // no `0` ("the server did not report a value" — the convention
                    // `UIDExistenceResult.uidValidity` documents and
                    // `SyncEngineDeletionReconcile.swift:144` enforces) can enter the
                    // sync layer wearing the shape of a real epoch.
                    uidValidityVal = SyncEngine.knownUidValidity(status.uidValidity.map { Int($0.value) })
                } catch {
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP] STATUS failed for \(info.name): \(error)") }
                }
                pairs.append((
                    info: FolderInfo(
                        name: info.name,
                        path: info.name,
                        role: IMAPProvider.mapRole(attributes: info.attributes, name: info.name),
                        unreadCount: unread,
                        totalCount: total,
                        uidNext: uidNextVal,
                        highestModSeq: highestModSeqVal,
                        uidValidity: uidValidityVal
                    ),
                    attributes: info.attributes
                ))
            }
            return IMAPProvider.dedupRoles(pairs)
        }
    }

    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] {
        try await fetchMessagesWithObservedEpoch(folder: folder, limit: limit, offset: offset).messages
    }

    /// Coverage for one windowed `fetchMessages` pass, from the SELECT that served
    /// it and the raw FETCH records it returned — computed here because this is the
    /// only place both facts exist. See `FetchCoverage`.
    ///
    /// `spansEntireFolder` needs BOTH halves and neither alone is sound:
    ///  - `messageCount <= limit` — the requested `selection.latest(limit)` range is
    ///    then the whole mailbox, so nothing on the server sits outside it. Without
    ///    this a 900-message folder that returned a full window would read as
    ///    complete the moment one record failed to map.
    ///  - `rawRecordCount == messageCount` — the server returned a record for every
    ///    message in that range. A SHORT FETCH (already visible in production as the
    ///    `[IMAP-FETCH-GAP]` diagnostic) otherwise manufactures the same false
    ///    completeness from the other direction, and the messages whose records
    ///    never came back would be stale-deleted.
    ///
    /// Records the client could not map are NOT excluded from either half — they
    /// were covered. They are reported as `unmaterialisedIds` instead, so presence
    /// stays true for them while coverage stays honest.
    nonisolated static func coverage(
        rawRecordCount: Int, serverMessageCount: Int, limit: Int, unmaterialisedIds: Set<String>
    ) -> FetchCoverage {
        FetchCoverage(
            serverRecordCount: rawRecordCount,
            spansEntireFolder: serverMessageCount <= limit && rawRecordCount == serverMessageCount,
            unmaterialisedIds: unmaterialisedIds)
    }

    /// The ids of records the server NAMED that `mapMessageInfo` refused. Derived
    /// from the SAME `IMAPFetchMapping.messageIdString` the mapper would have used,
    /// so a dropped record is named by exactly the id its local row carries.
    nonisolated static func unmaterialisedIds(
        raw: [MessageInfo], mapped: [MessageHeaderInfo]
    ) -> Set<String> {
        guard raw.count != mapped.count else { return [] }
        let mappedIds = Set(mapped.map(\.messageId))
        return Set(raw.map { IMAPFetchMapping.messageIdString(from: $0) }).subtracting(mappedIds)
    }

    /// `fetchMessages`, plus the UIDVALIDITY reported by the SELECT that served
    /// it — returned TOGETHER, from the same `Mailbox.Selection`.
    ///
    /// 🚨 The pairing is the point. `SyncEngine.runSyncMessages` BOOTSTRAPS
    /// `Folder.lastKnownUidValidity` from this value, and a write consumer cannot
    /// safely read the shared `lastObservedUidValidityBox`: any SELECT of the same
    /// path on any other connection replaces it, and after round 8 that includes
    /// the walk's, self-heal's and deep backfill's (see `selectMailboxTracked`'s
    /// retraction). One of those landing between the fetch and the read makes the
    /// pass stamp an epoch that describes the live server rather than the batch it
    /// is merging — the stamp then agrees with the live epoch while old-epoch rows
    /// sit under it, which is precisely how the deletion-reconcile abort guard
    /// (ADR-IOS-051) gets disarmed. Returning the epoch with the messages removes
    /// the window rather than narrowing it.
    ///
    /// ⚑ R0 — **NO REFERENCE in `v2final`**: there `runSyncMessages` reads the
    /// mirror, and it is sound because its consumer is the §5.5 in-transaction
    /// COMPARISON that aborts the whole merge pass on disagreement (a race can
    /// only manufacture a false mismatch, never a false match — its own comment
    /// says so). v3 had not ported that guard when this was written, so the same
    /// value here fed only a WRITE, where the identical race is fail-DANGEROUS. Same
    /// mechanism, inverted consumer direction; copying it verbatim across that
    /// inversion is what made this a defect.
    ///
    /// T4.S6 has since added the in-transaction comparison to `runSyncMessages`, so
    /// v3 now has BOTH consumers — and the pairing matters MORE, not less. The
    /// comparison's fail-safe direction only holds if the epoch it compares is the
    /// one bound to THIS fetch: a mirror read racing another connection's SELECT
    /// would manufacture agreement (a false MATCH), which is the direction that
    /// admits a merge across a turnover. Keep returning the epoch with the messages.
    ///
    /// `observedEpoch` is nil when the SELECT reported no UIDVALIDITY — `0` is
    /// SwiftMail's default for "not reported", never a real epoch (RFC 3501
    /// §2.3.1.1 types it `nz-number`).
    func fetchMessagesWithObservedEpoch(
        folder: String, limit: Int, offset: Int
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?, coverage: FetchCoverage) {
        try await withFolderConnection(folder: folder) { server in
            // T1.2b: the SYNC path's own SELECT. `SyncEngine.runSyncMessages`
            // reaches the server through here (`provider.fetchMessages`), and that
            // is the shared core of both the full-sync per-folder pass and the
            // on-navigate `syncFolderMessages`. Recording the epoch here is what
            // makes it readable for a folder the deletion-reconcile walk has never
            // visited, and on a non-UIDPLUS server, where the STATUS-sourced writes
            // see nothing. Not universal: a folder whose CONDSTORE HIGHESTMODSEQ is
            // unchanged is skipped before `runSyncMessages` (`shouldSkipFolderFetch`)
            // and observes nothing from this path on that cycle.
            let selection = try await selectMailboxTracked(server, folder: folder)
            let observed = selection.uidValidity.value
            let observedEpoch: UInt32? = observed != 0 ? observed : nil
            // `EXISTS 0` is the server stating the folder is EMPTY, which IS
            // complete knowledge — and it must stay so, or an emptied folder's
            // local rows would never be swept.
            guard selection.messageCount > 0 else {
                return ([], observedEpoch,
                        FetchCoverage(serverRecordCount: 0, spansEntireFolder: true, unmaterialisedIds: []))
            }

            // No representable range over a non-empty mailbox: we asked nothing,
            // so we proved nothing.
            guard let range = selection.latest(limit) else { return ([], observedEpoch, .unproven) }

            do {
                let infos = try await server.fetchMessageInfosBulk(using: range)
                if infos.count < limit && infos.count < selection.messageCount {
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP-FETCH-GAP] \(folder): fetchMessages requested \(limit) (msgCount=\(selection.messageCount)), got \(infos.count)") }
                }
                // compactMap: mapMessageInfo returns nil for unparseable messages (treated as fetch failure)
                let mapped = infos.compactMap { self.mapMessageInfo($0) }.sorted { $0.date > $1.date }
                // COVERAGE is measured on `infos` and `selection.messageCount` —
                // the two things the SERVER said — never on `mapped`. See
                // `IMAPProvider.coverage(rawRecordCount:serverMessageCount:limit:unmaterialisedIds:)`.
                return (mapped, observedEpoch, Self.coverage(
                    rawRecordCount: infos.count,
                    serverMessageCount: selection.messageCount,
                    limit: limit,
                    unmaterialisedIds: Self.unmaterialisedIds(raw: infos, mapped: mapped)))
            } catch {
                let msg = "\(error)"
                if msg.contains("Invalid messageset") || msg.contains("invalid messageset") {
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP] Invalid messageset for \(folder) (messageCount=\(selection.messageCount)) — skipping") }
                    return ([], observedEpoch, .unproven)
                }
                throw error
            }
        }
    }

    func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo {
        try await withActionConnection(folder: folder) { server in
            try await self.fetchMessageOnConnection(id: id, folder: folder, server: server)
        }
    }

    private func fetchMessageOnConnection(id: String, folder: String, server: IMAPServer) async throws -> FullMessageInfo {
        // T5.3 PORT — `v2final:…:IMAPProvider.fetchMessageOnConnection` tracks
        // this re-SELECT. It runs on the ACTION connection, which
        // `withActionConnection` has already SELECTed, so this is the second
        // SELECT of the pair and the one whose epoch is live at FETCH time.
        let selection = try await selectMailboxTracked(server, folder: folder)
        let selectedEpoch = selection.uidValidity.value
        let observedUidValidity = selectedEpoch == 0 ? nil : Int(selectedEpoch)

        let results = try nativeUIDSet([id])
        guard !results.isEmpty else {
            throw ProviderError.messageNotFound
        }

        let uids = results.toArray()
        guard let uid = uids.first else { throw ProviderError.messageNotFound }

        let info = try await server.fetchMessageInfo(for: uid)
        guard let info else { throw ProviderError.messageNotFound }

        var parts = info.parts
        do {
            for index in IMAPFetchMapping.requiredBodyPartIndices(in: parts) {
                let section = parts[index].section
                let expectedSize = parts[index].size
                parts[index].data = try await IMAPFetchMapping.concatenateEncodedPart(
                    expectedSize: expectedSize
                ) { offset, count in
                    try await server.fetchPart(
                        section: section,
                        of: uid,
                        offset: offset,
                        count: count
                    )
                }
            }
        } catch {
            if IMAPFetchMapping.isDeterministicPartialFetchFailure(error) {
                throw ProviderError.bodyIndexingUnsupported(
                    messageId: id,
                    observedUidValidity: observedUidValidity,
                    fetchedRfc822MessageId: IMAPFetchMapping.rfc822MessageId(from: info)
                )
            }
            throw error
        }
        let message = Message(header: info, parts: parts)

        // buildFullMessageInfo returns nil when mapMessageInfo can't parse the header
        // (e.g., date parse failure). Treat as a fetch failure so the caller retries.
        guard let full = buildFullMessageInfo(info: info, message: message) else {
            throw ProviderError.messageNotFound
        }
        return full
    }

    /// Build FullMessageInfo from BODYSTRUCTURE info + fetched message data.
    /// Extracted from fetchMessageOnConnection so batch fetch can reuse it.
    /// Returns nil if the header can't be parsed — caller should treat as fetch failure.
    private func buildFullMessageInfo(info: MessageInfo, message: Message) -> FullMessageInfo? {
        guard let header = mapMessageInfo(info) else { return nil }
        let renderIngredientSections = Set(
            IMAPFetchMapping.requiredBodyPartIndices(in: info.parts)
                .map { info.parts[$0].section.description }
        )

        // Classify each attachment as top-level vs nested-in-.eml by checking
        // whether its MIME section is a descendant of any message/rfc822 section.
        // A section like "2.2" is nested under the rfc822 at "2". The prefix
        // match uses section COMPONENTS (not string prefix), so "12" is NOT
        // considered nested under "1".
        let rfc822Sections: [[Int]] = info.parts.compactMap { part in
            part.contentType.lowercased().hasPrefix("message/rfc822")
                ? part.section.components
                : nil
        }

        // Extract attachment metadata
        var attachments: [AttachmentInfo] = info.parts.compactMap { part in
            let ct = part.contentType.lowercased()
            let disposition = part.disposition?.lowercased()
            let hasFilename = part.filename != nil
            let isExplicitAttachment = disposition == "attachment"
            let hasFileNotInline = hasFilename && disposition != "inline"
            // text/calendar (ICS invites) are attachments even without explicit
            // disposition or filename — Outlook often omits both.
            let isCalendar = ct.hasPrefix("text/calendar")
            let isAttachment = isExplicitAttachment || hasFileNotInline || isCalendar
            guard isAttachment else { return nil }
            let filename = part.filename ?? part.suggestedFilename
            let parentEml = IMAPFetchMapping.parentEmlSection(for: part.section.components, rfc822Sections: rfc822Sections)

            return AttachmentInfo(
                filename: filename,
                contentType: part.contentType,
                section: part.section.description,
                size: part.size ?? part.data?.count ?? 0,
                encoding: part.encoding,
                parentEmlSection: parentEml
            )
        }

        // Surface attachments nested INSIDE file-uploaded `.eml` parts when
        // parent bytes happen to be present (for example, an on-demand path).
        // Server-parsed `message/rfc822` parts already have their children
        // visible at the top level (BODYSTRUCTURE exposes them at numeric
        // sub-sections like `2.1`, and the block above catches them).
        // File-uploaded `.eml`s are opaque blobs server-side — background body
        // indexing deliberately does not download their attachment payloads, so
        // BODYSTRUCTURE exposes only the parent until it is opened on demand.
        //
        // `encoding` on each nested AttachmentInfo is set to the PARENT's
        // transfer encoding (not the inner attachment's). Tap-time
        // resolution calls `fetchAttachment` with this encoding, which
        // routes through the compound branch: re-fetch parent bytes using
        // this encoding (so base64-transported .emls decode correctly),
        // then `nestedBytes` parses the decoded RFC 822 and handles the
        // inner attachment's own transfer encoding internally.
        for part in message.parts where EmlParsing.isEmlFilename(part.filename)
            && !part.contentType.lowercased().hasPrefix("message/rfc822") {
            guard let raw = part.decodedData() ?? part.data,
                  let parsed = EmlParsing.parse(rawBytes: raw) else { continue }
            let parentSection = part.section.description
            let parentEncoding = part.encoding
            for (index, meta) in parsed.nested.enumerated() {
                attachments.append(AttachmentInfo(
                    filename: meta.filename,
                    contentType: meta.contentType,
                    section: EmlParsing.nestedSection(parent: parentSection, index: index),
                    size: meta.size,
                    encoding: parentEncoding,
                    parentEmlSection: parentSection
                ))
            }
        }

        // Extract CID inline images — data is already fetched by SwiftMail.
        // Use decodedData() to handle content transfer encoding (base64, quoted-printable)
        // before we re-encode as data: URI in AccountManagerFetch.
        let inlineImages: [InlineImage] = message.cids.prefix(SyncConfig.maxInlineImages).compactMap { part in
            guard let rawId = part.contentId, let data = part.decodedData() else { return nil }
            // Strip angle brackets + whitespace: "< image001@host >" → "image001@host"
            let contentId = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contentId.isEmpty else { return nil }
            return InlineImage(contentId: contentId, contentType: part.contentType, data: data)
        }

        // Extract ICS calendar data from already-fetched parts (avoids re-fetch in renderBody)
        let icsData: Data? = message.parts.first(where: {
            renderIngredientSections.contains($0.section.description)
                && $0.contentType.lowercased().contains("text/calendar")
        })?.decodedData()

        // Log body part structure for debugging embedded .eml rendering.
        //
        // Debug-gated per global rule 12 — this block was ungated and so ran in
        // release for every message carrying a `message/rfc822` part — and every
        // sender-authored MIME value in it is escaped. `filename` and
        // `contentType` are header text the SENDER chose, and `print` is a
        // line-oriented sink, so a CR/LF/U+2028 in either does not corrupt a line,
        // it forges a plausible extra one: see `DebugModeManager.escapedForLogLine`.
        //
        // The gate is in the BODY, not folded into the `if` condition. A gate in a
        // branch condition lets a debug unlock decide which branch runs, so debug
        // and release stop sharing one control-flow graph;
        // `Companion/Memory/Current/105-a-print-is-not-production-observability-on-ios.md`
        // §3 records the sibling where that happened. Keeping it inside also means
        // a non-logging statement added here later still runs in production.
        let bodyParts = message.bodies
        let rfc822Parts = message.parts.filter { $0.contentType.lowercased().hasPrefix("message/rfc822") }
        if !rfc822Parts.isEmpty {
            if DebugModeManager.isLoggingEnabled() {
                print("[EmlRender] Message has \(rfc822Parts.count) rfc822 part(s), \(bodyParts.count) body parts:")
                for part in bodyParts {
                    print("[EmlRender]   section=\(part.section.description) type=\(DebugModeManager.escapedForLogLine(part.contentType)) len=\(part.textContent?.count ?? 0)")
                }
                for part in rfc822Parts {
                    print("[EmlRender]   rfc822: section=\(part.section.description) filename=\(DebugModeManager.escapedForLogLine(part.filename ?? "nil"))")
                }
            }
        }

        // Insert TB-style header blocks before nested message/rfc822 body content
        let htmlBody = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/html")
        let textBody = IMAPFetchMapping.renderBodyWithEmbeddedHeaders(message: message, type: "text/plain")

        // Same gate, same reason. Nothing sender-authored is interpolated here —
        // only two lengths — so there is nothing to escape; rule 12 still applies.
        if !rfc822Parts.isEmpty {
            if DebugModeManager.isLoggingEnabled() {
                print("[EmlRender] htmlBody len=\(htmlBody?.count ?? 0), textBody len=\(textBody?.count ?? 0)")
            }
        }

        return FullMessageInfo(
            header: header,
            htmlBody: htmlBody,
            textBody: textBody,
            attachments: attachments,
            inlineImages: inlineImages,
            icsData: icsData,
            renderIngredientSections: renderIngredientSections
        )
    }

    // MARK: - Batch Full Message Fetch

    /// Batch fetch renderable message content on one folder connection.
    /// Flow: one SELECT → one bulk BODYSTRUCTURE → bounded partial FETCH commands
    /// for text/calendar/CID parts. Normal attachments remain metadata-only and
    /// are fetched on demand. A server that ignores or malforms a partial range is
    /// surfaced as a typed per-message terminal failure; connection/transient
    /// errors still fail the batch for retry.
    func fetchMessagesBatch(ids: [String], folder: String) async throws -> [String: FullMessageInfo] {
        // Defensive guard — see `EmailProvider.fetchMessagesBatch` extension default
        // for the rationale. The implicit `UInt32(id)` filter below would already
        // drop synthetic placeholder ids silently, but silent-drop hits the caller's
        // miss-counter → eventual CASCADE-delete path. Throw loudly instead.
        let synthetic = ids.filter(isSyntheticPlaceholderId)
        if !synthetic.isEmpty {
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] ERROR: synthetic placeholder ids leaked into fetchMessagesBatch — upstream queue regression. folder=\(folder) ids=\(synthetic.prefix(5))") }
            throw ProviderError.syntheticPlaceholderId(synthetic)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let uidPairs: [(id: String, uid: UInt32)] = ids.compactMap { id in
            guard let uid = UInt32(id) else { return nil }
            return (id, uid)
        }
        guard !uidPairs.isEmpty else {
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] fetchMessagesBatch: no valid UIDs in \(ids.count) ids") }
            return [:]
        }

        if DebugModeManager.isLoggingEnabled() { print("[IMAP] fetchMessagesBatch START: \(uidPairs.count) UIDs in \(folder)") }

        var partialFetchMessageId: String?
        var partialFetchObservedUidValidity: Int?
        var partialFetchRfc822MessageId: String?
        do {
            return try await withFolderConnection(folder: folder) { server in
            // 1. SELECT (re-selects on pinned connection — fast, refreshes state)
            let tSelect = CFAbsoluteTimeGetCurrent()
            // T5.3 PORT — `v2final:…:IMAPProvider.fetchMessagesBatch` tracks this
            // re-SELECT on the folder-pinned connection. This is the body queue's
            // hot path and runs concurrently with the backfill walk on the SAME
            // folder path, so it is one of the SELECTs most likely to be the
            // first to see a turnover.
            let selection = try await selectMailboxTracked(server, folder: folder)
            let selectedEpoch = selection.uidValidity.value
            partialFetchObservedUidValidity = selectedEpoch == 0 ? nil : Int(selectedEpoch)
            let selectMs = Int((CFAbsoluteTimeGetCurrent() - tSelect) * 1000)
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] fetchMessagesBatch SELECT: \(selectMs)ms") }

            // 2. Bulk BODYSTRUCTURE for all UIDs — we already get parts from this
            let tStruct = CFAbsoluteTimeGetCurrent()
            var uidSet = UIDSet()
            for (_, uid) in uidPairs { uidSet.insert(UID(uid)) }
            let infos = try await server.fetchMessageInfosBulk(using: uidSet)
            let structMs = Int((CFAbsoluteTimeGetCurrent() - tStruct) * 1000)
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] fetchMessagesBatch BODYSTRUCTURE: \(infos.count)/\(uidPairs.count) returned in \(structMs)ms") }

            // Map UID → (id, MessageInfo) for lookup
            var infoByUID: [UInt32: (id: String, info: MessageInfo)] = [:]
            for info in infos {
                guard let uid = info.uid else { continue }
                // Find the original string ID for this UID
                if let pair = uidPairs.first(where: { $0.uid == uid.value }) {
                    infoByUID[uid.value] = (id: pair.id, info: info)
                }
            }

            // 3. Fetch only render-required parts in bounded encoded-byte chunks.
            // BODYSTRUCTURE already supplies attachment metadata, so normal file
            // attachment payloads are intentionally absent from this background path.
            // Each part is transfer-decoded only after all encoded chunks are joined.
            let tParts = CFAbsoluteTimeGetCurrent()
            var partsByUID: [UInt32: [MessagePart]] = [:]
            var fetchedSectionsByUID: [UInt32: Set<String>] = [:]
            var totalParts = 0

            for (uidValue, entry) in infoByUID {
                let uid = UID(uidValue)
                var parts = entry.info.parts
                var fetchedSections: Set<String> = []
                for index in IMAPFetchMapping.requiredBodyPartIndices(in: parts) {
                    totalParts += 1
                    partialFetchMessageId = entry.id
                    partialFetchRfc822MessageId = IMAPFetchMapping.rfc822MessageId(
                        from: entry.info
                    )
                    let section = parts[index].section
                    let expectedSize = parts[index].size
                    parts[index].data = try await IMAPFetchMapping.concatenateEncodedPart(
                        expectedSize: expectedSize
                    ) { offset, count in
                        try await server.fetchPart(
                            section: section,
                            of: uid,
                            offset: offset,
                            count: count
                        )
                    }
                    fetchedSections.insert(section.description)
                }
                partialFetchMessageId = nil
                partialFetchRfc822MessageId = nil
                partsByUID[uidValue] = parts
                fetchedSectionsByUID[uidValue] = fetchedSections
            }

            let partsMs = Int((CFAbsoluteTimeGetCurrent() - tParts) * 1000)
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] fetchMessagesBatch PARTS CHUNKED: \(totalParts) render parts across \(infoByUID.count) messages in \(partsMs)ms") }

            // 4. Assemble Message objects from BODYSTRUCTURE + fetched part data.
            var results: [String: FullMessageInfo] = [:]
            var fetchedCount = 0
            var failedCount = 0

            for (uidValue, entry) in infoByUID {
                guard let parts = partsByUID[uidValue] else { continue }
                let fetchedSections = fetchedSectionsByUID[uidValue] ?? []

                let message = Message(header: entry.info, parts: parts)
                // Skip entries where the header can't be parsed (date parse failure).
                // Caller sees the entry missing from results and treats as fetch failure.
                guard let fullInfo = self.buildFullMessageInfo(info: entry.info, message: message) else {
                    failedCount += 1
                    continue
                }
                // Data-integrity guard (CLAUDE.md rule #1 — never cache unfetched content).
                // A top-level text/html section listed in BODYSTRUCTURE was NOT returned
                // by the chunked fetch (its section is absent from `fetchedSections`) —
                // i.e. the HTML content was silently DROPPED.
                // Rendering would fall back to the text/plain part — an HTML email FALSELY
                // shown as plaintext — frozen by MessageBody.create's onConflict:.ignore
                // until a manual pull-to-refresh. THROW so the body queue retries the batch
                // on a fresh connection (same policy as PayloadTooLargeError). We must NOT
                // omit the message from `results`: BackfillBodyQueue treats
                // "missing from result" as confirmed-gone and can DELETE the header.
                //
                // We key on the section being ABSENT (a true drop), NOT on htmlBody being
                // empty — a genuinely-empty top-level text/html part (section returned but
                // empty/whitespace, as some mailing lists emit alongside a real text/plain)
                // must render as plaintext and cache normally, else the batch would retry
                // that message forever. Single-message fetch self-heals dropped parts.
                if IMAPFetchMapping.hasDroppedTopLevelHTMLSection(
                    info: entry.info, fetchedSections: fetchedSections
                ) {
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP] fetchMessagesBatch: UID \(uidValue) — top-level text/html section dropped by chunked fetch; failing batch for retry (not caching HTML as plaintext)") }
                    throw NSError(
                        domain: "IMAPProvider.IncompleteBodyFetch", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "top-level text/html section dropped after chunked fetch for UID \(uidValue)"]
                    )
                }
                results[entry.id] = fullInfo
                fetchedCount += 1
            }

            // Check for UIDs that were in our request but not in BODYSTRUCTURE response
            for (_, uidValue) in uidPairs {
                if infoByUID[uidValue] == nil {
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP] fetchMessagesBatch: UID \(uidValue) not in BODYSTRUCTURE — skipping") }
                    failedCount += 1
                }
            }

            let totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] fetchMessagesBatch DONE: \(fetchedCount) fetched, \(failedCount) failed in \(totalMs)ms (select=\(selectMs)ms, struct=\(structMs)ms, parts=\(partsMs)ms)") }
            return results
            }
        } catch {
            if let messageId = partialFetchMessageId,
               IMAPFetchMapping.isDeterministicPartialFetchFailure(error) {
                throw ProviderError.bodyIndexingUnsupported(
                    messageId: messageId,
                    observedUidValidity: partialFetchObservedUidValidity,
                    fetchedRfc822MessageId: partialFetchRfc822MessageId
                )
            }
            throw error
        }
    }

    func search(query: String, folder: String, after: Date? = nil, before: Date? = nil, from: String? = nil, to: String? = nil) async throws -> [MessageHeaderInfo] {
        try await withActionConnection(folder: folder) { server in
            try await self.searchOnConnection(query: query, folder: folder, after: after, before: before, from: from, to: to, server: server)
        }
    }

    private func searchOnConnection(query: String, folder: String, after: Date? = nil, before: Date? = nil, from: String? = nil, to: String? = nil, server: IMAPServer) async throws -> [MessageHeaderInfo] {
        // T5.3 PORT — `v2final:…:IMAPProvider.searchOnConnection` tracks this
        // SELECT. LOOP VARIANT (unchanged by this edit): the one recursive call
        // below passes a non-nil `after`, and the recursion is guarded on
        // `after == nil`, so the depth is at most one. `selectMailboxTracked`
        // adds no failure arm — it throws exactly what `server.selectMailbox`
        // throws — so it cannot hold that bound constant.
        _ = try await selectMailboxTracked(server, folder: folder)
        var criteria: [SearchCriteria] = []
        if !query.isEmpty { criteria.append(.text(query)) }
        if let after { criteria.append(.since(after)) }
        if let before { criteria.append(.before(before)) }
        if let from, !from.isEmpty { criteria.append(.from(from)) }
        if let to, !to.isEmpty { criteria.append(.to(to)) }
        guard !criteria.isEmpty else { return [] }

        let results: UIDSet
        do {
            let extResult: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: criteria, calendar: Self.utcCalendar)
            results = extResult.asSet
        } catch {
            let desc = "\(error)"
            if desc.contains("PayloadTooLargeError") && after == nil {
                if DebugModeManager.isLoggingEnabled() { print("[IMAP Search] SEARCH too large, retrying with 1-year constraint") }
                let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date.distantPast
                return try await searchOnConnection(query: query, folder: folder, after: oneYearAgo, before: before, from: from, to: to, server: server)
            }
            throw error
        }
        guard !results.isEmpty else { return [] }

        let infos = try await server.fetchMessageInfosBulk(using: results)
        return infos.compactMap { mapMessageInfo($0) }
    }

    func markRead(ids: [String], folder: String) async throws {
        throw ProviderError.actionIdentityResolutionFailed(ids.first ?? "")
    }

    /// T2.7 checkpoint-B overload for a T2.4 provider-native queue op.
    func markRead(
        ids: [String], folder: String, admittedUidValidity: UInt32
    ) async throws {
        try await mutateAdmittedUIDs(
            ids: ids, folder: folder, admittedUidValidity: admittedUidValidity,
            flags: [.seen], add: true)
    }

    func markUnread(ids: [String], folder: String) async throws {
        throw ProviderError.actionIdentityResolutionFailed(ids.first ?? "")
    }
    func markUnread(
        ids: [String], folder: String, admittedUidValidity: UInt32
    ) async throws {
        try await mutateAdmittedUIDs(
            ids: ids, folder: folder, admittedUidValidity: admittedUidValidity,
            flags: [.seen], add: false)
    }

    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {
        throw ProviderError.actionIdentityResolutionFailed(ids.first ?? "")
    }

    func markFlagged(
        ids: [String], flagged: Bool, folder: String,
        admittedUidValidity: UInt32
    ) async throws {
        try await mutateAdmittedUIDs(
            ids: ids, folder: folder, admittedUidValidity: admittedUidValidity,
            flags: [.flagged], add: flagged)
    }

    /// PORT of v2final `mutateActionMessages`' one-UIDSet/one-STORE shape,
    /// adapted to v3's native-only queue. RFC resolution and partial-member
    /// success are deliberately subtracted: the full batch parses before any
    /// connection or mutation, then both the wrapper SELECT and the later
    /// source re-SELECT must equal the explicit per-call admitted epoch.
    private func mutateAdmittedUIDs(
        ids: [String],
        folder: String,
        admittedUidValidity: UInt32,
        flags: [Flag],
        add: Bool
    ) async throws {
        let uidSet = try nativeUIDSet(ids)
        do {
            try await withActionConnectionSelection(folder: folder) { server, wrapperSelection in
                try self.requireUidValidity(
                    wrapperSelection, expected: admittedUidValidity, folder: folder)
                let mutationSelection = try await self.selectMailboxTracked(server, folder: folder)
                try self.requireUidValidity(
                    mutationSelection, expected: admittedUidValidity, folder: folder)
                try await server.store(
                    flags: flags, on: uidSet, operation: add ? .add : .remove)
            }
        } catch is IMAPActionMailboxAbsent {
            // T3.3 PORT — `v2final:…:IMAPProvider.mutateActionMessages`' catch
            // arm. The mailbox holding these UIDs is CONFIRMED gone, so the
            // messages are gone with it: there is nothing to flag, and the flag
            // state of a destroyed mailbox is not a thing a retry can ever
            // reach. Terminal no-op rather than a lane pinned on an
            // unsatisfiable STORE.
        }
    }

    private func nativeUIDSet(_ ids: [String]) throws -> UIDSet {
        guard !ids.isEmpty else {
            throw ProviderError.actionIdentityResolutionFailed("")
        }
        var result = UIDSet()
        for id in ids {
            guard let value = UInt32(id), value > 0, id == String(value) else {
                throw ProviderError.actionIdentityResolutionFailed(id)
            }
            result.insert(UID(value))
        }
        return result
    }

    /// T3.4 ⚑ NO REFERENCE — INVENTED. The subset of `requested` that the
    /// server ITSELF stated it copied, per RFC 4315 §3's `COPYUID` response
    /// code, and therefore the ONLY UIDs a source cleanup may address.
    ///
    /// `v2final` answered "did this copy land?" with an rfc822 Message-ID probe
    /// of the destination (`idempotentMove`'s pre-move `.exact` arm and its
    /// post-move `resolveActionMessage` verify). D4 removes RFC as mutation
    /// authority on v3, so there is no counterpart to port: the only admissible
    /// evidence left is the server's own naming of what it created, which is
    /// strictly stronger than the probe was — the probe could match a
    /// PRE-EXISTING same-Message-ID sibling at the destination and authorize
    /// deleting a source message that had never been copied at all, whereas
    /// `COPYUID` is attempt-correlated by construction (the same discipline
    /// `saveDraft` already applies to `APPENDUID`).
    ///
    /// Every leg here is fail-CLOSED, because the consumer is a destructive
    /// one: no evidence, a zero destination epoch, a zero destination UID, or a
    /// source UID we never asked to copy all yield "not authorized" rather than
    /// "assume it worked". A member missing from the mapping is a member the
    /// server never claimed to copy; deleting it would destroy the only copy.
    ///
    /// Filtering against `requested` is not defensive noise: a `COPYUID` naming
    /// a source UID this call never asked for would otherwise widen the
    /// destructive set to a message the user's gesture never selected — C3.
    private static func copyProvenSourceUIDs(
        _ evidence: CopyUID?, requested: UIDSet
    ) -> UIDSet {
        // A zero destination UIDVALIDITY is not an epoch (RFC 4315 §3 specifies
        // `nz-number`), so a response carrying one is malformed and proves
        // nothing about where the copies landed.
        guard let evidence, evidence.destinationUIDValidity.value > 0 else {
            return UIDSet()
        }
        let requestedValues = Set(requested.toArray().map(\.value))
        var proven: [UID] = []
        // LOOP VARIANT: the number of unvisited elements of `evidence.mapping`,
        // a finite array fixed before the loop begins. It strictly decreases by
        // one per iteration and is bounded below by 0. The `continue` arm skips
        // this element's append and advances the iteration exactly like the
        // fall-through arm, so it cannot hold the variant constant.
        for pair in evidence.mapping {
            guard pair.destination.value > 0,
                  requestedValues.contains(pair.source.value) else { continue }
            proven.append(pair.source)
        }
        return UIDSet(proven)
    }

    /// The DESTINATION half of the same `COPYUID` (RFC 4315 §3) —
    /// `copyProvenSourceUIDs` dereferences `pair.destination` only to validate
    /// it and then throws it away, which is THE ADDRESS PROBLEM at its source.
    /// This returns it, so the drain can finish the move locally instead of
    /// leaving every moved row to be repaired later by sync on weaker evidence.
    ///
    /// 🚨 **G1 — PAIRING IS A C3 GUARD. Do not skip it.** `CopyUID.init(nio:)`
    /// in the pinned SwiftMail fork builds its mapping as
    /// `zip(expand(sourceUIDs), expand(destinationUIDs))` — POSITIONAL, after
    /// `expand(_:)` preserves the server-emitted range order — and it checks
    /// CARDINALITY and not ORDERING. While the destination half was only
    /// sanity-checked, a mis-pairing was harmless. Promoting it to a MUTATION
    /// address makes it C3-critical: a row seated at the wrong destination UID
    /// would be CONFIRMED by later syncs rather than caught, and every
    /// subsequent gesture on it would address a message the user never
    /// selected.
    ///
    /// So the whole response is admitted only when BOTH expanded lists are
    /// STRICTLY ASCENDING. That is what a conforming server produces: RFC 3501
    /// §2.3.1.1 requires UIDs to be assigned *"in a strictly ascending
    /// fashion"*, so the copies a single `UID COPY` creates take ascending
    /// destination UIDs in the order it processed the (ascending) source set. A
    /// single-member move passes trivially. Anything else yields NO destinations
    /// at all — which leaves TODAY'S behaviour exactly as it was: the copy still
    /// completed, the source cleanup is untouched, and sync repairs the row.
    /// Failing closed here costs a stale local address; failing open costs a
    /// wrong-message mutation.
    ///
    /// Every other leg is fail-CLOSED in the same shape as
    /// `copyProvenSourceUIDs`: no evidence, a zero destination epoch, a zero
    /// destination UID, or a source UID this call never requested all yield
    /// nothing. Filtering against `requested` is the same C3 guard — a `COPYUID`
    /// naming a source UID this call never asked for must never re-key a row the
    /// user's gesture never selected.
    private static func copyProvenDestinations(
        _ evidence: CopyUID?, requested: UIDSet
    ) -> [ProvenDestinationAddress] {
        guard let evidence else { return [] }
        let epoch = evidence.destinationUIDValidity.value
        // A zero destination UIDVALIDITY is not an epoch (RFC 3501 §2.3.1.1
        // types it as `nz-number`), so a response carrying one proves nothing
        // about where the copies landed.
        guard epoch > 0 else { return [] }
        guard Self.isStrictlyAscending(evidence.mapping.map(\.source.value)),
              Self.isStrictlyAscending(evidence.mapping.map(\.destination.value)) else {
            if DebugModeManager.isLoggingEnabled() {
                print("[IMAP] COPYUID pairing REFUSED — the response's source/destination lists are not both strictly ascending, so the positional zip that produced this mapping cannot be trusted to have paired them correctly; no local re-key is admitted (fail closed; the move itself is unaffected and sync repairs the row)")
            }
            return []
        }
        let requestedValues = Set(requested.toArray().map(\.value))
        var proven: [ProvenDestinationAddress] = []
        for pair in evidence.mapping {
            guard pair.destination.value > 0,
                  requestedValues.contains(pair.source.value) else { continue }
            proven.append(ProvenDestinationAddress(
                sourceProviderId: String(pair.source.value),
                // A UID IS this provider's address, so the provider-neutral id
                // is its decimal string — the same value `finishMove` has
                // always written into `MessageHeader.messageId` here.
                destinationProviderId: String(pair.destination.value),
                destinationUidValidity: epoch))
        }
        return proven
    }

    /// Strictly ascending — equal neighbours are REJECTED. A repeated UID in
    /// either list means the server described a correspondence that cannot be
    /// a bijection, which is exactly the shape the positional zip mispairs.
    private static func isStrictlyAscending(_ values: [UInt32]) -> Bool {
        guard values.count > 1 else { return true }
        return zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// 🚨 AUDIT ROUND 4 — ⚑ NO REFERENCE — INVENTED. The subset of `requested`
    /// the SOURCE mailbox still contains, read from the server itself.
    ///
    /// WHY IT EXISTS. Round 3 authorized the source cleanup of a whole batch on
    /// the COPY's tagged OK, citing RFC 3501 §6.4.7 (an unsuccessful COPY MUST
    /// restore the destination mailbox). That citation is real but it is not the
    /// whole rule: the command issued is a `UID COPY`, and §6.4.8 says verbatim
    /// that *"a non-existent unique identifier is ignored without any error
    /// message generated. Thus, it is possible for a UID FETCH command to return
    /// an OK without any data or a UID COPY or UID STORE to return an OK without
    /// performing any operations."* A UID that is no longer in the mailbox is
    /// dropped FROM the command, so the tagged OK is silent about it — and
    /// round 3 retired it as provider success anyway, which in a batch let an
    /// absent member ride out of the queue on a PRESENT sibling's OK.
    ///
    /// WHAT IT PROVES, and why the proof is per member. RFC 3501 §2.3.1.1 makes
    /// UID + UIDVALIDITY a 64-bit value that *"MUST NOT refer to any other
    /// message in the mailbox or any subsequent mailbox with the same name
    /// forever"* and assigns UIDs *"in a strictly ascending fashion"*. So within
    /// ONE epoch a UID can only ever LEAVE a mailbox — it can never arrive, come
    /// back, or be reused. A member still present AFTER the COPY was therefore
    /// present DURING it, which is exactly the premise §6.4.7 needs: it was one
    /// of "the specified message(s)", the COPY was tagged OK, so its copy is at
    /// the destination. The epoch that makes the argument hold is asserted
    /// before the COPY (A3) and again before the STORE (A4).
    ///
    /// The converse is the other half of the fix: a member the server does NOT
    /// return is one the server has just told us is not in that mailbox. That is
    /// a POSITIVE provider statement (exit 2 of
    /// `Companion/Rules/Active/never-drop-user-intention.md`), not an absence of
    /// evidence — and it is the same fact `v1.6.38`'s `idempotentMove` acted on
    /// with `if srcUIDs.isEmpty { … return }`. A THROWN probe proves nothing and
    /// propagates, so the op stays queued.
    ///
    /// ⚠ IN BOUNDS UNDER ADR-IOS-068 / D4. This is a source-UID existence check:
    /// it re-reads UIDs this operation already owns and can only ever NARROW the
    /// destructive set. No rfc822 Message-ID is consulted, and no `SEARCH`
    /// result is a mutation target. (RFC 4315 §3 suggests recovering the missing
    /// mapping by SEARCHing the DESTINATION for a Message-ID; that route is
    /// exactly what D4 forbids and it is not taken here.)
    ///
    /// `.uidFlagsOnly` is the smallest per-message payload SwiftMail offers, and
    /// RFC 3501 §6.4.8 requires the UID data item in any FETCH response caused
    /// by a UID command, so the whole question is answered by FETCHing flags for
    /// the requested set. Filtering against `requested` is the same C3 guard
    /// `copyProvenSourceUIDs` applies: a response naming a UID this call never
    /// asked about must never widen the destructive set.
    ///
    /// 🚨 AUDIT ROUND 5 — THE PROBE IS CHUNKED, AND THAT IS A WEDGE FIX RATHER
    /// THAN AN OPTIMIZATION. Round 4 wrote this as ONE
    /// `fetchMessageInfosBulk`, which builds a single `FetchMessageInfoCommand`
    /// for the entire set and issues it as one `UID FETCH` with no chunking at
    /// all. The set is unbounded: `AccountManager.move` groups every message
    /// sharing an account and source folder into ONE `PendingOperation`
    /// (`optimisticMoveToFolder` inserts one row carrying every provider id),
    /// and `SettingsView.archiveOldMessages` selects every inbox message older
    /// than the cutoff with no limit. `SyncConfig.pendingOperationTimeoutSeconds`
    /// (15s, applied in `AccountManager.executeSingleOp`) bounds the whole
    /// provider operation, so on a server that withholds `COPYUID` a large
    /// archive completed its `UID COPY` and then blew that deadline inside this
    /// probe. The throw lands in the drain's generic arm: the op is requeued,
    /// the ACCOUNT is added to `failedAccounts`, and the lane halts — so no
    /// source `\Deleted` is ever reached, the next drain REPEATS the `UID COPY`
    /// and seats another destination duplicate, and every later intention on
    /// that account is starved. That is the never-drop WEDGE corollary, not a
    /// preserved intention.
    ///
    /// The streaming overload is the chunked path
    /// (`identifierSet.chunked(size: chunkSize ?? options.suggestedChunkSize)`,
    /// one `UID FETCH` per chunk). No chunk size is passed: it defaults from the
    /// options, so `.uidFlagsOnly`'s own `suggestedChunkSize` decides, and the
    /// bound moves with the payload weight instead of being restated here.
    ///
    /// 🚨 AUDIT ROUND 5 — A RECORD WITH NO PARSEABLE UID MAKES THE WHOLE PROBE
    /// INCONCLUSIVE. Round 4 folded that case into the C3 filter
    /// (`guard let uid = info.uid, requestedValues.contains(uid.value) else
    /// { continue }`), so an unparseable record was SKIPPED — and a member
    /// missing from the returned live set is read by the caller as the server
    /// stating that member has left the source mailbox, which retires it as
    /// exit 2 with zero mutation. A malformed response would therefore have
    /// dropped that member's move outright. Requesting `UID FETCH` obliges the
    /// server to return the UID data item (RFC 3501 §6.4.8), so a nil `uid` is
    /// an RFC-violating response — *"we could not determine the answer"*, which
    /// `Companion/Rules/Active/never-drop-user-intention.md` names explicitly as
    /// NOT one of the four exits. Absence of evidence must never become
    /// evidence of absence, so this fails CLOSED for the whole probe.
    ///
    /// It cannot fail closed for "just that member": a record carrying no
    /// parseable UID does not say WHICH member it describes, so there is no
    /// member to exclude. That is precisely why the refusal is whole-probe.
    private func liveSourceUIDs(
        of requested: UIDSet, folder: String, server: IMAPServer
    ) async throws -> UIDSet {
        let requestedValues = Set(requested.toArray().map(\.value))
        var live: [UID] = []
        // LOOP VARIANT: the number of `MessageInfo` values the stream has yet to
        // yield. It is NOT "a finite array fixed before the loop begins" any
        // more — that was true of the bulk call this replaced and is false of a
        // stream — but it is still finite and still strictly decreasing.
        // `IMAPServer.fetchMessageInfos(using:options:headerFields:chunkSize:)`
        // computes its chunk array BEFORE yielding anything, runs one
        // `executeCommand` per chunk (each returning a finite `[MessageInfo]`),
        // yields every returned record exactly once, and then finishes the
        // continuation, so the total is the sum of a fixed number of finite
        // per-chunk results and is bounded below by 0. Nothing in this body can
        // add to it: the `continue` arm advances the iteration exactly like the
        // fall-through arm, and the `throw` arm terminates it outright (which
        // also cancels the producing Task through `onTermination`).
        for try await info in server.fetchMessageInfos(
            using: requested, options: .uidFlagsOnly) {
            guard let uid = info.uid else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[IMAP] liveness probe of '\(folder)': a UID FETCH response record carried no parseable UID (RFC 3501 §6.4.8 requires one), so this probe cannot say which of the \(requested.count) requested uid(s) the source still holds — REFUSING all source cleanup (fail closed; an unanswerable probe is not proof a member left the mailbox) and keeping the op retryable")
                }
                throw IMAPLivenessProbeInconclusive.unparsedUid(
                    folder: folder, requested: requested.count)
            }
            guard requestedValues.contains(uid.value) else { continue }
            live.append(uid)
        }
        return UIDSet(live)
    }

    /// ⚑ NO REFERENCE — INVENTED (audit round 5). The liveness probe's own
    /// refusal, and a `ProviderEvidenceUnavailable` for the same reason as its
    /// two siblings below (`IMAPDestinationEpochRefusal`,
    /// `IMAPEpochEvidenceMissing`): the provider asked the server for a fact its
    /// safety gate needs and did not get a usable one, so nothing is determined
    /// about this op — and nothing about the ACCOUNT either.
    ///
    /// That arm in `AccountManager.executeSingleOp` requeues the op, bumps
    /// `retryCount`, inserts it into `evidenceRefused` and halts only this lane,
    /// WITHOUT inserting the account into `failedAccounts`. Every one of those
    /// properties is wanted here, and `evidenceRefused` especially: this refusal
    /// is raised AFTER the `UID COPY`, so bounding the op to one attempt per
    /// drain bounds the destination duplicates a re-attempt would seat.
    ///
    /// Deliberately NOT `ProviderError.uidValidityChanged` (exit 4 retires the
    /// op, and no epoch was proven to have moved) and NOT
    /// `ProviderError.actionIdentityResolutionFailed` (the drain DELETES on it,
    /// and a malformed response is not a verdict on an identity). Its case name
    /// and labels carry none of the substrings
    /// `AccountManager.isMessageNotFoundError` matches, so it cannot be
    /// mistaken for a confirmed-stale message — the same posture, with the same
    /// server-supplied `folder` payload, as `IMAPEpochEvidenceMissing`.
    private enum IMAPLivenessProbeInconclusive: ProviderEvidenceUnavailable {
        /// A `UID FETCH` response record carried no parseable UID, so the probe
        /// cannot answer which members the source mailbox still holds.
        case unparsedUid(folder: String, requested: Int)
    }

    /// T3.14 — ⚑ NO REFERENCE — INVENTED. The DESTINATION-side epoch refusal.
    ///
    /// Deliberately NOT `ProviderError.uidValidityChanged`, and deliberately a
    /// distinct type from `IMAPActionMailboxAbsent`, because the drain gives
    /// each of those a TERMINAL disposition and neither is correct here:
    ///
    ///  - `uidValidityChanged` is exit 4 of `never-drop-user-intention.md`, and
    ///    exit 4 is scoped, verbatim, to "an id reset **in its own address
    ///    space**" — an epoch "disagreeing with the epoch the operation durably
    ///    recorded at admission", such that "every retry of that op fails
    ///    identically and forever". A `.move` op durably records ONE epoch and
    ///    it is the SOURCE's (`PendingOperation.observedUidValidity`); it never
    ///    records a destination address at all. A destination turnover
    ///    therefore invalidates nothing the op recorded, and the next attempt
    ///    observes the new destination epoch and completes — retry is
    ///    CONVERGENT, not futile. Retiring the op here would be a fifth exit
    ///    the rule does not authorize, and it would leave the user's gesture
    ///    half-executed (a copy at the destination, the message still in the
    ///    source) with nothing left to finish it.
    ///  - `actionIdentityResolutionFailed` is the drain's drop-now signal, used
    ///    by T3.4's gate precisely because a withheld `COPYUID` never becomes
    ///    available, so a retry only ever adds another unproven duplicate. That
    ///    reasoning does not transfer: here the evidence IS available, it just
    ///    belongs to an address space this attempt never validated, and the
    ///    duplicate cost is bounded by the number of destination turnovers
    ///    (a rare, monotone server-side event) rather than unbounded per retry.
    ///
    /// So this propagates as an unclassified error and lands in the drain's
    /// default arm — requeue, bump `retryCount`, retry — which is the "unknown
    /// / not-proven-in-my-own-space stays retryable forever" disposition. It is
    /// `private`, so it can never become a classification input anywhere else,
    /// and its description carries none of the substrings
    /// `AccountManager.isMessageNotFoundError` matches, so it cannot be
    /// mistaken for a confirmed-stale message.
    // 🚨 AUDIT ROUND 4 — `IMAPMoveEvidenceUnavailable` IS DELETED, AND ITS
    // ABSENCE IS THE SECOND HALF OF THIS ROUND'S FIX. History, kept because
    // superseded material is never dropped in this repo:
    //
    //  - It was introduced by audit round 1 (finding B-1) carrying TWO cases,
    //    `noUidPlusCapability` and `noCopyUidEvidence`, so that the MOVE path's
    //    evidence refusals would stop reaching
    //    `ProviderError.actionIdentityResolutionFailed` — whose drain arm
    //    DELETES the op and whose stated premises ("refused before touching the
    //    wire", "the same string will be refused on every future drain",
    //    "`.deleteDraft` — the only op that raises this error") are each false
    //    for a move.
    //  - Audit round 3 deleted `noUidPlusCapability`: `COPYUID` is a UIDPLUS
    //    response code (RFC 4315 §3), so on a standards-valid non-UIDPLUS server
    //    that refusal fired on EVERY attempt, forever, and its `.haltLane` drain
    //    arm starved every later gesture on the same message. A capability the
    //    server does not have is not evidence that can "arrive later".
    //  - Audit round 4 deletes `noCopyUidEvidence` for the SAME reason, which
    //    round 3 stopped one step short of. RFC 4315 §3 makes `COPYUID` a
    //    SHOULD with named exceptions — a `UIDNOTSTICKY` mail store, and a
    //    mailbox the client may COPY to but not SELECT — so for those servers
    //    the response code never arrives either, and "evidence that may appear
    //    next time" was a hope, not a property. The refusal reached NONE of the
    //    four never-drop exits, halted the lane on every drain, and re-issued
    //    the `UID COPY` each time, seating another destination duplicate.
    //
    // An op that stays queued but blocks every intention behind it has not been
    // preserved (the never-drop WEDGE corollary). What authorizes the source
    // cleanup when no `COPYUID` arrives is stated at `move`'s authorization
    // gate: the COPY's tagged OK, applied ONLY to members a source-UID
    // existence check proves were in the mailbox when that COPY ran.

    /// ⚠ Conforms to `ProviderEvidenceUnavailable` for the SAME reason its two
    /// siblings above do — it is the same class of refusal (the provider asked the
    /// server for a destination epoch and did not get a usable one), reaching the
    /// same generic arm, with the same account-wide wedge. Audit round 2 named the
    /// siblings explicitly; this one is the third instance of that class and is
    /// folded in here rather than left as a second door onto the identical defect.
    private enum IMAPDestinationEpochRefusal: ProviderEvidenceUnavailable {
        /// The destination SELECT reported no usable UIDVALIDITY (SwiftMail
        /// defaults `Mailbox.Selection.uidValidity` to `UIDValidity(0)` when the
        /// server omits the REQUIRED untagged response). Absence of evidence:
        /// raised BEFORE the COPY, so nothing has reached the wire.
        case unknownAtProbe(destination: String)
        /// The server's own `COPYUID` reported a destination UIDVALIDITY that
        /// differs from the one this attempt probed — the copy landed in a
        /// destination address space this operation never validated.
        case movedAcrossCopy(destination: String, observed: UInt32, reported: UInt32)
    }

    /// PORT — v2final `requireSameUidValidity`, with the queue's explicit
    /// admitted epoch as authority rather than an ambient/shared value.
    ///
    /// T3.14 split this into a `Mailbox.Selection` adapter and the epoch-taking
    /// core below **without changing one source-side call site or one bit of
    /// their semantics**: this overload still reads `selection.uidValidity.value`
    /// and forwards it, and the guard, the throw and its payload remain in
    /// exactly ONE place. The core exists because a destination epoch does not
    /// always arrive inside a `Mailbox.Selection` — the server reports it in the
    /// `COPYUID` response code (RFC 4315 §3) as a bare `UIDValidity` — and
    /// T3.14 must reuse this comparison rather than fork a second one.
    private func requireUidValidity(
        _ selection: Mailbox.Selection,
        expected: UInt32,
        folder: String
    ) throws {
        try requireUidValidity(
            live: selection.uidValidity.value, expected: expected, folder: folder)
    }

    /// The SOURCE-side counterpart of `IMAPDestinationEpochRefusal` — an epoch
    /// that was never reported is an ABSENCE OF EVIDENCE, not a turnover.
    ///
    /// SwiftMail types `Mailbox.Selection.uidValidity` as non-optional with a
    /// `UIDValidity(0)` default, so a server that omits the REQUIRED
    /// `* OK [UIDVALIDITY n]` untagged response (RFC 3501 §6.3.1) hands us a
    /// zero. RFC 3501 §2.3.1.1 types UIDVALIDITY as `nz-number`, so zero cannot
    /// be an epoch and must never be COMPARED — but it must equally never be
    /// reported as a turnover: `ProviderError.uidValidityChanged` is exit 4 of
    /// `Companion/Rules/Active/never-drop-user-intention.md` and the drain
    /// RETIRES the durable op on it. Raising exit 4 for "the server did not tell
    /// us" would drop the user's gesture on an unknown — precisely the widening
    /// exit 4 forbids.
    ///
    /// The asymmetry that proved this was a defect: T3.14's DESTINATION side of
    /// this exact hazard already raises the retryable private
    /// `IMAPDestinationEpochRefusal.unknownAtProbe` for the same zero, "because a
    /// zero is absence of evidence". The source side was left on exit 4.
    ///
    /// `private` and unclassified, exactly like its destination sibling, so it
    /// lands in the drain's generic arm — requeue, bump `retryCount`, retry
    /// forever if the server never conforms. Its description carries none of the
    /// substrings `AccountManager.isMessageNotFoundError` matches, so it
    /// cannot be mistaken for a confirmed-stale message.
    private enum IMAPEpochEvidenceMissing: ProviderEvidenceUnavailable {
        /// The SELECT reported no usable UIDVALIDITY for `folder`.
        case unknownLiveEpoch(folder: String, expected: UInt32)
        /// The caller supplied no usable admitted epoch to compare against.
        case unknownAdmittedEpoch(folder: String, live: UInt32)
    }

    /// The epoch comparison for every ADMITTED MUTATION in this file. `live` is
    /// what the server just reported for `folder`; `expected` is the epoch the
    /// operation is authorized under.
    ///
    /// ⚠️ IT IS NOT "THE SINGLE EPOCH COMPARISON IN THIS FILE", WHICH IS WHAT THIS
    /// SENTENCE CLAIMED UNTIL R16-7 (corrected 2026-08-06). There are **two**, and
    /// the second one — `saveDraft`'s old-copy delete guard, which compares
    /// `selection.uidValidity.value == UInt32(exactly: recordedEpoch)` — is LIVE.
    /// A reader who trusted "single" and changed the epoch contract here would have
    /// left it untouched. Re-derive rather than trust; the predicate skips `//` and
    /// `///` lines so this paragraph cannot satisfy it:
    ///   `rg -n --pcre2 '^(?!\s*(///|//)).*(live == expected|uidValidity\.value ==)'
    ///    TabMail/Providers/IMAPProvider.swift` → **2** (this guard, and the
    ///   `saveDraft` one). Non-vacuity control, so a broken regex cannot read as a
    ///   clean two: the same command with the alternation replaced by `uidValidity`
    ///   returns **29**.
    ///
    /// THE TWO ARE NOT INTERCHANGEABLE AND MUST NOT BE MERGED. This one is a
    /// MUTATION ADMISSION guard: a mismatch is a PROVEN turnover and throws
    /// `ProviderError.uidValidityChanged`, which the drain treats as exit 4 and
    /// retires. `saveDraft`'s is a fail-closed SKIP: a mismatch means the recorded
    /// coordinates are stale, so it declines the old-copy delete and continues to
    /// APPEND, dropping no intention. Same fact, opposite dispositions.
    ///
    /// THREE outcomes, not two, and the split is the whole point:
    ///  - both epochs real and EQUAL ⇒ proceed;
    ///  - both epochs real and DIFFERENT ⇒ a PROVEN turnover in this operation's
    ///    own address space: `ProviderError.uidValidityChanged`, which the drain
    ///    treats as exit 4 and retires, because every retry would fail
    ///    identically and forever and executing under unobserved numbering is C3;
    ///  - either epoch missing (zero) ⇒ `IMAPEpochEvidenceMissing`, retryable.
    ///    Nothing is proven, so nothing may be retired.
    private func requireUidValidity(
        live: UInt32,
        expected: UInt32,
        folder: String
    ) throws {
        guard live > 0 else {
            throw IMAPEpochEvidenceMissing.unknownLiveEpoch(
                folder: folder, expected: expected)
        }
        guard expected > 0 else {
            throw IMAPEpochEvidenceMissing.unknownAdmittedEpoch(
                folder: folder, live: live)
        }
        guard live == expected else {
            throw ProviderError.uidValidityChanged(
                folderPath: folder, stored: expected, live: live)
        }
    }

    /// Set \Answered flag on IMAP messages (called after sending a reply).
    func markReplied(ids: [String], folder: String) async throws {
        throw ProviderError.actionIdentityResolutionFailed(ids.first ?? "")
    }

    /// A1 RESTORATION of `v1.6.38`'s working IMAP `markReplied`. The shipped
    /// sequence was `selectMailbox` → `resolveUID` (an rfc822 Message-ID SEARCH)
    /// → `store(flags: [.answered], operation: .add)`. v3 removed RFC as
    /// mutation authority (D4) and `resolveUID` no longer exists, so the
    /// resolution step is replaced by the op's own proven provider address plus
    /// its admitted epoch — the SAME substitution `markRead`/`markFlagged`
    /// already made. The STORE itself is the shipped one, unchanged.
    func markReplied(
        ids: [String], folder: String, admittedUidValidity: UInt32
    ) async throws {
        try await mutateAdmittedUIDs(
            ids: ids, folder: folder, admittedUidValidity: admittedUidValidity,
            flags: [.answered], add: true)
    }

    /// Set $Forwarded keyword on IMAP messages (called after forwarding).
    func markForwarded(ids: [String], folder: String) async throws {
        throw ProviderError.actionIdentityResolutionFailed(ids.first ?? "")
    }

    /// A1 RESTORATION of `v1.6.38`'s working IMAP `markForwarded` — same
    /// substitution as `markReplied` above, same shipped `$Forwarded` keyword.
    func markForwarded(
        ids: [String], folder: String, admittedUidValidity: UInt32
    ) async throws {
        try await mutateAdmittedUIDs(
            ids: ids, folder: folder, admittedUidValidity: admittedUidValidity,
            flags: [.custom("$Forwarded")], add: true)
    }

    /// Action tags are local-only (see ADR-IOS-036). No IMAP STORE.
    func setActionTag(messageId: String, tag: ActionTag?, folder: String) async throws {
        _ = messageId
        _ = tag
        _ = folder
    }

    /// Add or remove a user label (IMAP custom keyword) on a message.
    func setUserLabel(messageId: String, keyword: String, add: Bool, folder: String) async throws {
        throw ProviderError.actionIdentityResolutionFailed(messageId)
    }

    /// A1 RESTORATION of `v1.6.38`'s working IMAP `setUserLabel`. The shipped
    /// sequence was `selectMailbox` → `resolveUID` → `store(flags: [.custom(
    /// keyword)], operation: add ? .add : .remove)`; the resolution step is
    /// replaced by the op's proven provider address + admitted epoch exactly as
    /// in `markReplied`. Without this the queue admitted every label gesture on
    /// an IMAP account and then deleted it unexecuted at checkpoint A — a
    /// silent, deterministic loss of a user action the shipped release performed.
    func setUserLabel(
        messageId: String, keyword: String, add: Bool, folder: String,
        admittedUidValidity: UInt32
    ) async throws {
        try await mutateAdmittedUIDs(
            ids: [messageId], folder: folder,
            admittedUidValidity: admittedUidValidity,
            flags: [.custom(keyword)], add: add)
    }

    func move(ids: [String], from source: String, to destination: String) async throws {
        throw ProviderError.actionIdentityResolutionFailed(ids.first ?? "")
    }

    /// T2.7 provider-native move, hardened by T3.1 / T3.2 / T3.3 / T3.4 / T3.12
    /// / T3.14 / T3.15.
    ///
    /// The native source UID has no cross-mailbox identity, so v2final's RFC
    /// destination recovery/probe is SUBTRACTED — `idempotentMove`'s `.exact` /
    /// `.ambiguous` arms, its `resolveActionMessage` destination resolution and
    /// its post-move verification all rest on an rfc822 Message-ID this path
    /// deliberately never carries. T3.4 replaces that subtracted evidence with
    /// the server's own `COPYUID` (see `copyProvenSourceUIDs`) — but ONLY on the
    /// class of server that can produce it.
    ///
    /// 🚨 AUDIT ROUND 4 — the source cleanup is authorized PER MEMBER, by a
    /// positive fact about THAT member, and the two facts authorize different
    /// things (full argument at the authorization gate in the body):
    ///  - **`COPYUID` names the member** (RFC 4315 §3) ⇒ it authorizes both the
    ///    reversible `\Deleted` STORE and the irreversible `UID EXPUNGE`.
    ///    Unchanged from round 3, and it is still the ONLY thing that may
    ///    authorize a purge.
    ///  - **no `COPYUID` for that member** — no UIDPLUS, a withheld response
    ///    code, or a COPY that copied nothing ⇒ the COPY's tagged OK
    ///    (RFC 3501 §6.4.7: an unsuccessful COPY MUST restore the destination)
    ///    ANDed with proof that the member was IN the source mailbox when that
    ///    COPY ran (`liveSourceUIDs`). That authorizes the `\Deleted` STORE and
    ///    nothing else.
    ///  - **the member is no longer in the source at all** ⇒ the server has told
    ///    us there is nothing left to move. Exit 2, zero mutation, retired.
    ///
    /// ROUND 3 GOT TWO THINGS WRONG HERE AND BOTH ARE FIXED. It read the tagged
    /// OK as covering the WHOLE named set, which RFC 3501 §6.4.8 contradicts —
    /// a non-existent UID is ignored without error, so a `UID COPY` can return
    /// OK having copied nothing, and in a batch an absent member was retired as
    /// provider success on a present sibling's OK. And it left the withheld-
    /// `COPYUID` refusal in place on the UIDPLUS arm, where RFC 4315 §3's named
    /// exceptions (`UIDNOTSTICKY`; a mailbox the client may COPY to but not
    /// SELECT) make the evidence unobtainable for some servers — the identical
    /// permanent wedge round 3 had just removed from the other arm, still
    /// re-copying on every drain. The A1 capability refusal round 3 deleted
    /// stays deleted. What IS ported from the reference is everything that does
    /// not depend on RFC identity:
    ///
    ///  - T3.3: the destination is probed for EXISTENCE before any source
    ///    mutation, and a confirmed-absent destination makes the whole op a
    ///    terminal no-op instead of an unsatisfiable retry.
    ///  - T3.1: the source epoch is reasserted immediately before EVERY source
    ///    mutation — five assertions, structurally one per step boundary, not a
    ///    list to be shortened.
    ///  - T3.12: `Task.checkCancellation()` between mutation steps, so an
    ///    abandoned (timed-out) Task dies at a step boundary instead of
    ///    completing a second mutation.
    ///  - T3.2: the purge tail is UID EXPUNGE or NOTHING. Never a bare EXPUNGE.
    ///  - T3.14 (⚑ INVENTED, no reference): the DESTINATION mailbox's own epoch
    ///    is recorded at the probe SELECT and asserted against the epoch the
    ///    server stamps on `COPYUID`, before any destination UID is read and
    ///    therefore before the evidence authorizes anything. A destination-side
    ///    renumber between the COPY and the source cleanup produces ZERO
    ///    mutation, and — unlike a SOURCE-side turnover — leaves the op
    ///    RETRYABLE, because the op recorded no destination address and the
    ///    next attempt observes the new destination epoch and completes.
    ///
    /// ⚑ NO REFERENCE — INVENTED (owner-directed): the route is capability-
    /// stable for one attempt. A MOVE-capable server receives exactly one
    /// fork-owned `UID MOVE`; a non-MOVE server receives the app-owned
    /// COPY → STORE `\Deleted` → UID EXPUNGE sequence below. The fork API is
    /// deliberately atomic-only: it refuses without MOVE and cannot enter
    /// SwiftMail's unsafe fallback (which lacks the app's epoch checkpoints and
    /// can degrade to mailbox-wide EXPUNGE). After choosing the atomic route,
    /// any tagged failure or transport ambiguity propagates; this method never
    /// converts it into a second COPY-based attempt.
    ///
    /// RETURNS the subset of `ids` this attempt DISPOSITIONED. Retirement is per
    /// MEMBER, never per batch (B-2), and the return value is how that reaches
    /// the drain.
    ///
    /// 🚨 AUDIT ROUND 4 — on every path that returns rather than throws, that
    /// subset is now ALL of `ids`, and the reason is the point rather than a
    /// simplification: each member has been given its OWN positive disposition
    /// before this returns — it moved (proved by `COPYUID`, or by the tagged OK
    /// plus its own liveness in the source), or the server itself said it is no
    /// longer in the source folder, which is exit 2 and leaves nothing to do.
    /// There is no third state left to leave queued, so no member can ride out
    /// of the queue on a sibling's evidence and none can be stranded on the
    /// absence of its own. `AccountManager.retirePartiallyCompletedOp`
    /// therefore has no producer here any more; it remains the drain's contract
    /// for any provider that does return a strict subset.
    ///
    /// A whole-op no-op — a LIST-confirmed absent source or destination — also
    /// returns `ids`, because that too IS provider authority that nothing
    /// remains to do.
    ///
    /// IT ALSO RETURNS WHERE THE COPIES LANDED. `provenDestinations` is the
    /// destination half of the same `COPYUID` that authorizes the source purge
    /// — the address the caller needs to finish the move LOCALLY. It is empty
    /// whenever the server furnished no usable evidence, and a caller that
    /// ignores it gets exactly the previous behaviour.
    ///
    /// `MoveOutcome` itself now lives at top level in
    /// `TabMail/Services/MessageHeaderRekey.swift`, beside
    /// `ProvenDestinationAddress`: `ExchangeProvider.moveProvingDestinations`
    /// produces the same shape from Graph's `/move` response, and one type is
    /// what stops the two arms drifting. Nothing about THIS method's contract
    /// changed with the move — the G1 pairing note above still describes what
    /// `provenDestinations` means on this arm.
    @discardableResult
    func move(
        ids: [String],
        from source: String,
        to destination: String,
        admittedUidValidity: UInt32
    ) async throws -> MoveOutcome {
        let sourceUIDs = try nativeUIDSet(ids)
        do {
            return try await withActionConnectionSelection(folder: source) { server, wrapperSelection -> MoveOutcome in
                // A1 — the wrapper's own SELECT of the source.
                try self.requireUidValidity(
                    wrapperSelection, expected: admittedUidValidity, folder: source)

                // Route once, before the first move mutation. RFC 6851 defines
                // UID MOVE under the MOVE capability; UIDPLUS only controls
                // whether the tagged OK also carries COPYUID evidence. Once
                // this attempt observes MOVE it never falls back to the
                // app-owned multi-command sequence, even if the command later
                // fails or the connection is lost.
                let serverSupportsMove = await server.supportsMove
                if serverSupportsMove {
                    if source.uppercased() == "INBOX" {
                        // A2' — the wrapper SELECT is not a perpetual lease on
                        // the epoch. Reassert immediately before the separate
                        // legacy-flag mutation as well as before UID MOVE; a
                        // turnover between checkout and this STORE must not let
                        // the old UID mutate its new occupant.
                        let preStrip = try await self.selectMailboxTracked(
                            server, folder: source)
                        try self.requireUidValidity(
                            preStrip, expected: admittedUidValidity, folder: source)
                        try Task.checkCancellation()
                        let legacyFlags: [Flag] = [
                            .custom("tm_reply"), .custom("tm_archive"),
                            .custom("tm_delete"), .custom("tm_none"),
                        ]
                        do {
                            try await server.store(
                                flags: legacyFlags, on: sourceUIDs, operation: .remove)
                        } catch {
                            if DebugModeManager.isLoggingEnabled() {
                                print("[IMAP] Legacy tm_* strip failed before atomic move (continuing): \(error)")
                            }
                        }
                    }

                    // A3' — legacy stripping is a separate mutation. Re-select
                    // and reassert the admitted source epoch immediately before
                    // the one atomic command that changes both mailboxes.
                    let preMove = try await self.selectMailboxTracked(server, folder: source)
                    try self.requireUidValidity(
                        preMove, expected: admittedUidValidity, folder: source)
                    try Task.checkCancellation()

                    do {
                        let moveEvidence = try await server.move(
                            messages: sourceUIDs, to: destination, fallback: .disabled)
                        return MoveOutcome(
                            provenIds: ids,
                            provenDestinations: Self.copyProvenDestinations(
                                moveEvidence, requested: sourceUIDs))
                    } catch IMAPError.malformedCopyUIDAfterTaggedOK {
                        // SwiftMail has already observed the MOVE's tagged OK:
                        // the provider mutation completed, but its destination
                        // address evidence is unusable. Retire the forward
                        // intention and let the ordinary source/destination
                        // sync converge; publishing no destination mapping also
                        // removes only this move's unsafe Undo member. Retrying
                        // here could move a later UID occupant or duplicate work.
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] Atomic MOVE completed with malformed COPYUID; converging by sync")
                        }
                        return MoveOutcome(provenIds: ids, provenDestinations: [])
                    } catch IMAPError.moveFailedAfterPartialCompletion(
                        let copyUID, _
                    ) {
                        // RFC 6851 permits an untagged COPYUID before EXPUNGE
                        // responses. SwiftMail retained that attempt-correlated
                        // mapping before the later tagged failure. Some members
                        // therefore moved, and resending the original set could
                        // address a later source-UID occupant. Retire this wire
                        // attempt, preserve the verified destination addresses,
                        // and make the queue reconcile BOTH mailboxes.
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] Atomic MOVE partially completed with COPYUID; reconciling both mailboxes without retry")
                        }
                        return MoveOutcome(
                            provenIds: ids,
                            provenDestinations: Self.copyProvenDestinations(
                                copyUID, requested: sourceUIDs),
                            requiresSourceReconciliation: true)
                    } catch IMAPError.moveFailedAfterPossiblePartialCompletion {
                        // The server may already have changed either mailbox but
                        // supplied no trustworthy mapping. The only safe bound is
                        // the same one used for an interrupted in-flight MOVE at
                        // launch: never resend these source UIDs; retire the
                        // attempt and converge from fresh source + destination
                        // state. The user's visible remainder can then be issued
                        // as a new, freshly-addressed gesture.
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] Atomic MOVE may have partially completed; reconciling both mailboxes without retry")
                        }
                        return MoveOutcome(
                            provenIds: ids,
                            provenDestinations: [],
                            requiresSourceReconciliation: true)
                    } catch {
                        // A tagged failure is terminal only when an exact LIST
                        // proves the destination disappeared. Transport loss,
                        // permission failures and every other unknown remain
                        // retryable; critically, none can enter COPY fallback.
                        guard await self.mailboxConfirmedAbsent(
                            destination, server: server) else { throw error }
                        throw IMAPActionMailboxAbsent()
                    }
                }

                // 🚨 AUDIT ROUND 3 — THE CAPABILITY REFUSAL THAT USED TO SIT
                // HERE IS DELETED. It read `guard await server.supportsUIDPlus`
                // and threw `IMAPMoveEvidenceUnavailable.noUidPlusCapability`
                // before any wire mutation. The reasoning was that `COPYUID` is
                // a UIDPLUS response code (RFC 4315 §3), so a server that does
                // not advertise UIDPLUS can never furnish it — therefore refuse
                // early and cheaply.
                //
                // WHY THAT WAS WRONG, and why deleting it is the fix rather
                // than a relaxation. A capability the server does not have is
                // not evidence that can arrive later: the guard threw on EVERY
                // attempt, forever, so on a standards-valid non-UIDPLUS server
                // archive/move could never complete at any time by any route.
                // And because this error's drain arm returns `.haltLane`, the
                // op held its whole lane — every op sharing that message id by
                // construction — on every future drain as well. That is the
                // never-drop WEDGE corollary: an op that stays queued but
                // prevents every intention behind it from executing has not
                // been preserved. `v1.6.38` (`07a4bb703`) moved mail on these
                // servers perfectly well.
                //
                // WHAT AUTHORIZES THE SOURCE CLEANUP INSTEAD, on that class of
                // server: the COPY's own tagged OK. RFC 3501 §6.4.7 requires
                // that "if the COPY command is unsuccessful for any reason,
                // server implementations MUST restore the destination mailbox
                // to its state before the COPY attempt" — so a tagged OK is a
                // POSITIVE statement that the message(s) the command actually
                // addressed were copied.
                //
                // ⚠ AUDIT ROUND 4 CORRECTED THE SENTENCE THAT USED TO END THAT
                // PARAGRAPH — it read "…that EVERY MESSAGE NAMED IN THE COMMAND
                // was copied", and RFC 3501 §6.4.8 says otherwise: on a `UID`
                // command "a non-existent unique identifier is ignored without
                // any error message generated", so a named-but-absent UID is
                // never one of "the specified message(s)" and the OK is silent
                // about it. The tagged OK is therefore joined with a per-member
                // liveness proof at the authorization gate below, and that gate
                // now serves BOTH classes of server rather than this one only.
                //
                // Read ONCE, here. Round 4 narrowed its remaining consumer to
                // the purge tail — `UID EXPUNGE` is itself a UIDPLUS command
                // (RFC 4315 §2.1), so this decides whether the tail may exist at
                // all, while WHICH members it may address is decided by the
                // evidence rather than the capability. `supportsUIDPlus` reads
                // capabilities the connection already gathered at login; it is
                // not a wire command.
                let serverSupportsUIDPlus = await server.supportsUIDPlus

                // T3.3 PORT — `v2final:…:IMAPProvider.move`'s destination
                // SELECT + `mailboxConfirmedAbsent` guard. Probed BEFORE any
                // source mutation, so a destination that no longer exists
                // costs the source nothing: the message stays where it is and
                // sync/delta-sync reconciles.
                //
                // T3.14 — ⚑ NO REFERENCE — INVENTED. The returned
                // `Mailbox.Selection` is now KEPT: this SELECT is the only
                // moment at which this operation observes the destination's own
                // UIDVALIDITY, and the `COPYUID` evidence that later authorizes
                // destroying the source is meaningful only inside the
                // destination address space it names. `v2final` discards the
                // selection at both of its own destination SELECTs (`_ = try
                // await self.selectMailboxTracked(server, folder: destination)`,
                // twice), so there is nothing to port here — only the shape of
                // `requireSameUidValidity` to mirror.
                //
                // Still `server.selectMailbox` rather than
                // `selectMailboxTracked`: the tracked variant's ONLY extra
                // effect is writing the shared observed-epoch mirror, and
                // recording a destination from an action SELECT would widen that
                // mirror for no consumer in this scope (see
                // `selectMailboxTracked`'s doc comment — action SELECTs stay
                // out, and narrower stays safer). The epoch this item needs is
                // returned by the bare call; the mirror was never the source of
                // it.
                let destinationProbe: Mailbox.Selection
                do {
                    destinationProbe = try await server.selectMailbox(destination)
                } catch {
                    guard await self.mailboxConfirmedAbsent(destination, server: server) else {
                        throw error
                    }
                    if DebugModeManager.isLoggingEnabled() {
                        print("[MoveTrace] IMAPProvider.move — destination '\(destination)' confirmed absent — whole-op no-op")
                    }
                    throw IMAPActionMailboxAbsent()
                }

                // T3.14 D1 — an UNKNOWN destination epoch is refused here,
                // BEFORE the COPY, so the refusal costs zero wire mutation and
                // stays cleanly retryable.
                //
                // SwiftMail types `Mailbox.Selection.uidValidity` as
                // non-optional with a `UIDValidity(0)` default, so a server that
                // omits the REQUIRED `* OK [UIDVALIDITY n]` untagged response
                // (RFC 3501 §6.3.1) yields 0 — indistinguishable, downstream,
                // from a real epoch unless it is rejected right here. Without
                // this gate the post-COPY assertion below would have nothing to
                // compare against and would have to either fail OPEN (the
                // most-repeated defect class in this codebase) or convert an
                // absence of evidence into a terminal drop. Refusing before the
                // COPY does neither: nothing is copied, nothing is deleted, and
                // the op retries — permanently, if the server never conforms,
                // which is the correct disposition for "we do not know".
                let observedDestinationUidValidity = destinationProbe.uidValidity.value
                guard observedDestinationUidValidity > 0 else {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[IMAP] move \(source)→\(destination): destination SELECT reported no UIDVALIDITY, so no COPYUID could ever be proven to belong to the mailbox we probed — REFUSING before any wire mutation (fail closed; nothing copied, nothing deleted) and keeping the op retryable")
                    }
                    throw IMAPDestinationEpochRefusal.unknownAtProbe(destination: destination)
                }

                // A2 — the destination probe above moved this connection's
                // selected mailbox. Re-SELECT the source and reassert before
                // anything touches it again.
                let preMutation = try await self.selectMailboxTracked(server, folder: source)
                try self.requireUidValidity(
                    preMutation, expected: admittedUidValidity, folder: source)

                if source.uppercased() == "INBOX" {
                    let legacyFlags: [Flag] = [
                        .custom("tm_reply"), .custom("tm_archive"),
                        .custom("tm_delete"), .custom("tm_none"),
                    ]
                    do {
                        try await server.store(flags: legacyFlags, on: sourceUIDs, operation: .remove)
                    } catch {
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] Legacy tm_* strip failed for native move (continuing): \(error)")
                        }
                    }
                }

                // A3 — immediately before the COPY.
                let preCopy = try await self.selectMailboxTracked(server, folder: source)
                try self.requireUidValidity(
                    preCopy, expected: admittedUidValidity, folder: source)
                // ⚠ THE FORK DOES NOT HAND BACK NIL EVIDENCE HERE — IT THROWS.
                // This comment used to assert that "the pinned SwiftMail fork
                // classifies tagged-OK malformed COPYUID as a successful COPY
                // with nil evidence", and that is false: `CopyHandler`
                // (`Sources/SwiftMail/IMAP/IMAP/Handler/ServerHandlers.swift` —
                // there is no `CopyHandler.swift`) overrides
                // `handleTaggedOKResponse` to call `extractCopyUID(from:)` →
                // `CopyUID(nio:)` and, when that parse fails, calls
                // `failWithError(IMAPError.malformedCopyUIDAfterTaggedOK(...))`.
                // The false comment is what let the missing catch survive
                // review, so it is corrected rather than deleted.
                //
                // WHAT THAT ERROR MEANS: the tagged OK was already observed, so
                // under RFC 3501 §6.4.7 (an unsuccessful COPY MUST restore the
                // destination to its prior state) the server COMMITTED this
                // copy; only the address evidence describing it is unusable.
                // Mapping that ONE case to `copyEvidence = nil` routes it into
                // the no-evidence path below — the same path a server that
                // withholds `COPYUID` entirely takes — where `copyProvenUIDs` is
                // empty, so `purgeAuthorizedUIDs` is empty and the irreversible
                // `UID EXPUNGE` is structurally UNREACHABLE; at most the
                // REVERSIBLE `\Deleted` STORE is authorized, and only for
                // members `liveSourceUIDs` proves the source still holds.
                // Letting it propagate instead re-runs A1/A2/A3 next drain and
                // issues ANOTHER `UID COPY` for a copy the server already made —
                // one more duplicate at the destination per drain, on an op that
                // never retires and a lane that stays halted: the never-drop
                // WEDGE corollary (`IOS-IMAP-005`).
                //
                // ⚠ DELIBERATELY NARROW — DO NOT WIDEN THIS CATCH. A bare
                // `catch`, a bare `IMAPError`, or `.commandFailed` would also
                // swallow `.copyFailed` (a genuine tagged NO/BAD, which
                // `CopyHandler.handleTaggedErrorResponse` raises), `.timeout`
                // and `.connectionFailed` — copies that provably did NOT
                // happen — and would soft-delete their sources anyway. That is a
                // wrong-message mutation (C3); those must keep throwing and stay
                // retryable.
                let copyEvidence: CopyUID?
                do {
                    copyEvidence = try await server.copy(
                        messages: sourceUIDs, to: destination)
                } catch IMAPError.malformedCopyUIDAfterTaggedOK {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[IMAP] move \(source)→\(destination): the COPY's tagged OK carried a COPYUID that could not be parsed — the server COMMITTED the copy, so this is NO EVIDENCE about a copy that DID happen, never a failed copy: no re-copy, no UID EXPUNGE (purge authorization is empty), at most a reversible \\Deleted on members the source still holds")
                    }
                    copyEvidence = nil
                }

                // T3.12 PORT (`a75196398`) — mutation-step checkpoint. The
                // reference also carried checkpoints inside its per-member
                // resolution loops; those loops do not exist here (the batch
                // is one UIDSet resolved before any I/O), so those sites are
                // NOT ported.
                try Task.checkCancellation()

                // T3.14 D2 — ⚑ NO REFERENCE — INVENTED. The DESTINATION epoch
                // assertion, placed BEFORE the first read of any destination
                // UID (`copyProvenSourceUIDs` dereferences `pair.destination`)
                // and therefore before anything the evidence authorizes.
                //
                // WHAT IS BEING DISTINGUISHED, because it is the whole crux of
                // this item: a COPY/MOVE ALWAYS gives the message a brand-new,
                // previously-unseen UID in the destination. That is normal and
                // is exactly what `COPYUID` exists to report — it is NEVER a
                // renumber and nothing here compares a destination UID against
                // anything. A renumber is a change of the destination mailbox's
                // **UIDVALIDITY**, which invalidates that mailbox's entire UID
                // address space at once (RFC 3501 §2.3.1.1, RFC 4315 §3). So
                // the assertion compares EPOCHS ONLY: the epoch the destination
                // reported when this attempt probed it, against the epoch the
                // server itself stamped on the `COPYUID` for this very copy.
                // New destination UID + same destination UIDVALIDITY ⇒
                // legitimate move, proceed. Same or new UID + DIFFERENT
                // destination UIDVALIDITY ⇒ the copy landed in an address space
                // this operation never validated, and nothing about that space
                // may authorize destroying the source.
                //
                // The server's own reported epoch is the right live value, not
                // a second destination SELECT: it is the epoch in force at the
                // instant the server executed THIS copy, whereas a re-SELECT
                // afterwards only reports the epoch at some later instant. It
                // also costs zero extra round trips.
                //
                // GUARDED BY `> 0` on the reported side so this gate cannot
                // steal T3.4's classification: a server that sent no `COPYUID`
                // at all (`nil`), or one whose response code carries a
                // malformed zero UIDVALIDITY, has furnished no evidence rather
                // than proof of a turnover, and must keep landing on the
                // no-evidence gate immediately below with its own terminal
                // signal and its own log.
                if let copyEvidence, copyEvidence.destinationUIDValidity.value > 0 {
                    do {
                        try self.requireUidValidity(
                            live: copyEvidence.destinationUIDValidity.value,
                            expected: observedDestinationUidValidity,
                            folder: destination)
                    } catch {
                        // Same comparison as every source-side assertion — see
                        // `requireUidValidity`, which has exactly one guard —
                        // but NOT the same disposition. `uidValidityChanged` is
                        // the drain's retire-now signal and is scoped to a reset
                        // in the op's OWN address space; this reset is in the
                        // destination's, which the op never recorded, so the
                        // refusal is re-raised as the retryable one. See
                        // `IMAPDestinationEpochRefusal` for the full argument.
                        if DebugModeManager.isLoggingEnabled() {
                            print("[IMAP] move \(source)→\(destination): destination UIDVALIDITY moved from \(observedDestinationUidValidity) (probed) to \(copyEvidence.destinationUIDValidity.value) (COPYUID) across the COPY — REFUSING all source cleanup (fail closed; the copy landed in an address space this attempt never validated) and keeping the op retryable")
                        }
                        throw IMAPDestinationEpochRefusal.movedAcrossCopy(
                            destination: destination,
                            observed: observedDestinationUidValidity,
                            reported: copyEvidence.destinationUIDValidity.value)
                    }
                }

                // THE AUTHORIZATION GATE — what may be soft-deleted from the
                // source, and separately what may be PURGED from it. From here
                // down the sets being mutated are `authorizedUIDs` and
                // `purgeAuthorizedUIDs`, never `sourceUIDs`.
                //
                // ONE RULE, stated per member: a source copy may be destroyed
                // only on a POSITIVE, PER-MEMBER fact about THAT member. There
                // are two such facts and they authorize different things.
                //
                //  1. `COPYUID` (RFC 4315 §3) names this member's copy and where
                //     it landed. Strongest, and the ONLY thing allowed to
                //     authorize the IRREVERSIBLE `UID EXPUNGE`. Unchanged.
                //  2. The COPY's tagged OK, ANDed with proof that this member
                //     was in the source mailbox when that COPY ran. RFC 3501
                //     §6.4.7 requires that an unsuccessful COPY MUST leave the
                //     destination as it was, so a partial copy cannot be
                //     reported as OK; `try await server.copy` returning normally
                //     therefore means tagged OK (in the pinned SwiftMail fork
                //     `BaseIMAPCommandHandler.processResponse` routes every
                //     non-`.ok` tagged state to `handleTaggedErrorResponse`,
                //     which `CopyHandler` overrides to fail the promise with
                //     `IMAPError.copyFailed`; `executeCommand` rethrows it).
                //     The liveness half is what audit round 4 adds — see
                //     `liveSourceUIDs` for the §6.4.8 / §2.3.1.1 argument. This
                //     authorizes the REVERSIBLE `\Deleted` STORE and nothing
                //     more.
                //
                // 🚨 AUDIT ROUND 4 — WHY FACT 2 IS NOW ALLOWED ON A UIDPLUS
                // SERVER TOO, which round 3 deliberately did not do. Round 3
                // gave the tagged OK to the non-UIDPLUS arm only, on the theory
                // that a UIDPLUS server which withholds `COPYUID` has made a
                // choice it can unmake next time. RFC 4315 §3 says otherwise.
                // It opens with "server implementations that advertise the
                // UIDPLUS extension SHOULD return these response codes" — but
                // "with limited exceptions, discussed below" — and then names
                // two, at two different normative strengths: for a mailbox the
                // client may COPY or APPEND to but not SELECT or EXAMINE, the
                // server "SHOULD NOT send an APPENDUID or COPYUID response code
                // as it would disclose information about the mailbox"; for a
                // `UIDNOTSTICKY` mail store it "MAY omit" it "as it is not
                // meaningful". Either way the omission is a PROPERTY OF THAT
                // MAILBOX, not a per-attempt coin flip, so for such a server the
                // evidence never arrives and the refusal was a permanent wedge
                // that re-copied on every drain. Fact 2 is not a weaker
                // reading of fact 1; it is an independent, RFC-grounded proof of
                // the SAME thing (this member's copy is at the destination),
                // and it does not depend on any capability. Widening it is
                // sound BECAUSE the irreversible half stays on fact 1: against a
                // non-conforming server that answers OK to a COPY it did not
                // complete, the worst this arm can do is leave a message marked
                // `\Deleted` and still present — recoverable — never expunged.
                //
                // ⚠ C3 BOUNDARY, unmoved: both sets are subsets of `sourceUIDs`,
                // the set resolved from the op's own ids and validated under the
                // admitted epoch at A1, and the SAME set handed to `server.copy`
                // above. Every gate here NARROWS; none can widen. A4 re-asserts
                // the epoch immediately before the STORE that mutates them.
                let copyProvenUIDs = Self.copyProvenSourceUIDs(
                    copyEvidence, requested: sourceUIDs)
                // The same evidence, read for the address rather than for the
                // authorization. Purely additive: nothing below consults it,
                // and it changes no gate. G1 lives inside it.
                let provenDestinations = Self.copyProvenDestinations(
                    copyEvidence, requested: sourceUIDs)
                let authorizedUIDs: UIDSet
                let purgeAuthorizedUIDs: UIDSet
                if copyProvenUIDs.count == sourceUIDs.count {
                    // The server named every member. Fact 1 covers the whole
                    // request, so the liveness probe would answer a question
                    // already answered: no extra round trip, and this path — the
                    // one every UIDPLUS server that follows RFC 4315 §3's SHOULD
                    // takes — is byte-for-byte what it was before round 4.
                    authorizedUIDs = copyProvenUIDs
                    purgeAuthorizedUIDs = copyProvenUIDs
                } else {
                    // Some or all members are unnamed: no UIDPLUS, a withheld
                    // response code, or a COPY that copied nothing because the
                    // UIDs are already gone. Ask the source itself which of them
                    // it still holds, and authorize per member from that.
                    let live = try await self.liveSourceUIDs(
                        of: sourceUIDs, folder: source, server: server)
                    authorizedUIDs = live
                    let liveValues = Set(live.toArray().map(\.value))
                    purgeAuthorizedUIDs = UIDSet(
                        copyProvenUIDs.toArray().filter { liveValues.contains($0.value) })
                    if DebugModeManager.isLoggingEnabled() {
                        print("[MoveTrace] IMAPProvider.move — \(source)→\(destination): COPYUID named \(copyProvenUIDs.count) of \(sourceUIDs.count) requested uid(s); the source still holds \(live.count) of them, so \(live.count) are soft-deleted on the tagged OK and \(sourceUIDs.count - live.count) are already gone from the source (provider-authoritative no-op, nothing to do)")
                    }
                }

                // EVERY MEMBER REACHED AN EXIT, so every member retires and the
                // op is complete. A member the source still holds moved (fact 1
                // or fact 2 above); a member it no longer holds was answered by
                // the server itself — it is not in the folder this op names, so
                // there is nothing left to move, which is exit 2 and is exactly
                // what `v1.6.38`'s `idempotentMove` did with `if srcUIDs.isEmpty
                // { return }`. Returning the input `ids` rather than mapping the
                // mutated set back to strings also keeps the caller's
                // set-equality check free of any round-trip assumption.
                let provenIds = ids

                // A4 — immediately before the source soft-delete. Nothing but
                // this assertion sits between it and the STORE; the liveness
                // probe above is a READ and is itself bracketed by A3 and A4,
                // which is what makes "present after the COPY" mean "present
                // under the epoch this op was admitted under".
                let preDelete = try await self.selectMailboxTracked(server, folder: source)
                try self.requireUidValidity(
                    preDelete, expected: admittedUidValidity, folder: source)
                if !authorizedUIDs.isEmpty {
                    try await server.store(
                        flags: [.deleted], on: authorizedUIDs, operation: .add)
                } else if DebugModeManager.isLoggingEnabled() {
                    // The whole request is already gone from the source. There
                    // is nothing to soft-delete and nothing to purge, and the op
                    // retires on the server's own answer rather than on a
                    // command that would address no message (RFC 3501 §6.4.8: a
                    // `UID STORE` naming only absent UIDs is a silent no-op, so
                    // issuing one would be a wire round trip that proves and
                    // changes nothing).
                    print("[MoveTrace] IMAPProvider.move — \(source)→\(destination): the source holds none of the \(sourceUIDs.count) requested uid(s) — whole-op no-op, nothing mutated anywhere")
                }

                try Task.checkCancellation()

                // T3.2 — the purge tail. PORT of `v2final`'s
                // `deleteActionSource` no-UIDPLUS early return and of
                // `storeDeletedAndMaybeExpunge`'s fail-closed arm; the local
                // precedent is `expungeScopedToTargets` in this same file.
                //
                // The UIDPLUS gate is deliberately checked BEFORE assertion A5
                // rather than after: on a server without UIDPLUS nothing
                // destructive follows, so asserting there would be able to
                // refuse an op that is already complete — and a refusal after a
                // successful COPY is retried, producing a DUPLICATE in the
                // destination. This is also why the tail is written out here
                // instead of delegating to `expungeScopedToTargets`, whose
                // UIDPLUS check is internal and therefore cannot have A5
                // sequenced inside it.
                //
                // 🚨 AUDIT ROUND 4 — the gate now ALSO requires per-member
                // `COPYUID`, because that is the only evidence allowed to
                // authorize an IRREVERSIBLE deletion (see the authorization
                // gate). `serverSupportsUIDPlus` is kept as the outer condition
                // and not collapsed into the emptiness check: `UID EXPUNGE` is
                // itself a UIDPLUS command (RFC 4315 §2.1), so a server that
                // does not advertise the extension must never be sent one even
                // if it somehow returned a `COPYUID`.
                if serverSupportsUIDPlus, !purgeAuthorizedUIDs.isEmpty {
                    // A5 — immediately before the purge. `v2final` asserts here
                    // too (`deleteActionSource`'s `finalSourceSelection`): STORE
                    // and UID EXPUNGE are distinct awaits, and a UID resolved
                    // under one epoch is mutation authority only within that
                    // epoch.
                    let preExpunge = try await self.selectMailboxTracked(server, folder: source)
                    try self.requireUidValidity(
                        preExpunge, expected: admittedUidValidity, folder: source)
                    try await server.expunge(messages: purgeAuthorizedUIDs)
                } else {
                    // 🚨 AUDIT ROUND 3 — THIS ARM IS LIVE AGAIN, and it is the
                    // whole of the non-UIDPLUS move's tail. T3.4's capability
                    // refusal used to make it unreachable ("a RESIDUAL"); that
                    // refusal is deleted, so a non-UIDPLUS move now runs COPY →
                    // `\Deleted` STORE → *nothing here*, and RETURNS, which
                    // retires the op and releases its lane.
                    //
                    // 🚨 AUDIT ROUND 4 — this arm is now reached by a SECOND
                    // class of server as well: one that advertises UIDPLUS and
                    // furnished no `COPYUID` for a member. The accepted cost
                    // below is identical for it, and so is the reason.
                    //
                    // THE ACCEPTED COST, stated plainly: the source copy stays
                    // on the server, soft-deleted, and may remain visible or
                    // relist until something else expunges that folder. That is
                    // incomplete VISIBLE cleanup — recoverable, self-evidently
                    // wrong to the user, and convergent. It is preferred over
                    // both alternatives: over the permanent queue wedge the
                    // capability refusal produced, and over a folder-wide
                    // EXPUNGE, which irreversibly destroys unrelated mail.
                    // THE GOVERNING DECISION IS `KNOWN_ISSUES.md`
                    // `IOS-IMAP-001` — *"Do not restore mailbox-wide EXPUNGE
                    // … incomplete visible cleanup is safer than permanently
                    // deleting an unrelated pre-deleted message"* — not a fresh
                    // judgement made here. `v1.6.38` DID reach a bare EXPUNGE on
                    // this path (directly, and through SwiftMail's `move`
                    // fallback, whose UID branch degrades to an argument-less
                    // `expunge()` without UIDPLUS); the shipped release is a
                    // floor, not a ceiling, and this is a weakness v3 does not
                    // inherit.
                    //
                    // A bare EXPUNGE is MAILBOX-WIDE (RFC 3501 §6.4.3): it
                    // names no UID and removes EVERY `\Deleted` message in the
                    // selected mailbox — another client's soft-deleted mail, or
                    // a copy a crashed prior attempt left marked but
                    // unexpunged. That is a wrong-message deletion (C3), with
                    // or without any UIDVALIDITY change, and the invariant is
                    // unconditional rather than UIDPLUS-gated. FAIL CLOSED: the
                    // `\Deleted` STORE above already records the intent, the
                    // destination already has the copy, and a UIDPLUS-capable
                    // client or the server's own policy completes the purge.
                    if DebugModeManager.isLoggingEnabled() {
                        print("[MoveTrace] IMAPProvider.move — \(source)→\(destination): no UID EXPUNGE (uidPlus=\(serverSupportsUIDPlus), copyuid-proven-and-live=\(purgeAuthorizedUIDs.count)) — the tagged-OK COPY plus source liveness authorized the soft delete, so the source is copied and marked \\Deleted; the mailbox-wide EXPUNGE is skipped to avoid a wrong-delete (IOS-IMAP-001) and the move COMPLETES")
                    }
                }
                return MoveOutcome(
                    provenIds: provenIds, provenDestinations: provenDestinations)
            }
        } catch is IMAPActionMailboxAbsent {
            // Source or destination CONFIRMED gone (LIST probe, T3.3) — the op
            // is terminally satisfied, not transiently failed. Nothing left to
            // do: for an absent source there is nothing to move, and for an
            // absent destination the message is untouched in the source and
            // sync reconciles the user's view. This IS provider authority, so
            // every member is reported complete and the whole op retires.
            //
            // No destination address: nothing was copied anywhere, so there is
            // nothing to re-key.
            return MoveOutcome(provenIds: ids, provenDestinations: [])
        }
    }

    /// Check if a message exists in a folder by rfc822 Message-ID.
    /// Used by backfill to distinguish a UID remap from a genuinely gone message.
    func messageExistsInFolder(rfc822MessageId: String, folderPath: String) async throws -> Bool {
        let uids = try await currentUIDs(rfc822MessageId: rfc822MessageId, folderPath: folderPath)
        return !uids.isEmpty
    }

    /// Resolve the CURRENT UID(s) for an rfc822 Message-ID (MessageExistenceProbe).
    /// Same SEARCH as `messageExistsInFolder`, but returns the UIDs so the backfill
    /// body queue can re-key a UID-remapped header instead of retrying a dead UID.
    func currentUIDs(rfc822MessageId: String, folderPath: String) async throws -> [String] {
        try await withFolderConnection(folder: folderPath) { server in
            // T5.3 PORT — `v2final:…:IMAPProvider.currentUIDs` tracks this SELECT.
            _ = try await self.selectMailboxTracked(server, folder: folderPath)
            let results = try await self.searchByMessageId(rfc822MessageId, server: server)
            return results.toArray().map { "\($0.value)" }
        }
    }

    /// Fetch a single attachment's data by MIME section.
    func fetchAttachment(messageId: String, folder: String, section: String, encoding: String?) async throws -> Data {
        // Compound path: attachment nested inside a file-uploaded `.eml`.
        // Re-fetch parent `.eml` bytes, parse, return the nth nested payload.
        // One extra IMAP fetch per tap — the parse happens in-process.
        if let nested = EmlParsing.parseNestedSection(section) {
            let parentBytes = try await fetchAttachment(
                messageId: messageId, folder: folder, section: nested.parent, encoding: encoding
            )
            guard let bytes = EmlParsing.nestedBytes(rawBytes: parentBytes, index: nested.index) else {
                throw ProviderError.messageNotFound
            }
            return bytes
        }

        return try await withActionConnection(folder: folder) { server in
            // T5.3 PORT — `v2final:…:IMAPProvider.fetchAttachment` tracks this
            // re-SELECT on the action connection.
            _ = try await self.selectMailboxTracked(server, folder: folder)

            let results = try self.nativeUIDSet([messageId])
            guard let uid = results.toArray().first else { throw ProviderError.messageNotFound }

            let mimeSection = Section(section)
            guard let info = try await server.fetchMessageInfo(for: uid),
                  let metadata = info.parts.first(where: { $0.section == mimeSection }) else {
                throw ProviderError.messageNotFound
            }
            let rawData = try await IMAPFetchMapping.concatenateEncodedPart(
                expectedSize: metadata.size
            ) { offset, count in
                try await server.fetchPart(
                    section: mimeSection,
                    of: uid,
                    offset: offset,
                    count: count
                )
            }

            let part = MessagePart(
                section: mimeSection,
                contentType: metadata.contentType,
                encoding: encoding ?? metadata.encoding
            )
            return rawData.decoded(for: part)
        }
    }

    func send(draft: DraftMessage) async throws {
        try await withTimeout(seconds: SyncConfig.smtpSendTimeoutSeconds) {
            if DebugModeManager.isLoggingEnabled() { print("[SMTP] Sending via \(self.smtpHost):\(self.smtpPort) from=\(self.senderEmail) to=\(draft.to) attachments=\(draft.attachments.count)") }
            let smtpServer = SMTPServer(host: self.smtpHost, port: self.smtpPort)
            do {
                try await smtpServer.connect()
            } catch {
                // IOS-TLS-002, send path. Without this the row stays `.queued`
                // FOREVER: `isTransientSendError` reads `.tlsFailed`/connection
                // shapes as transient, so a message addressed to a server that can
                // never accept it was retried indefinitely and the user was never
                // given the Retry/Discard agency Outbox Rules 7/9 promise.
                throw Self.mapTransportSecurityFailure(error, host: self.smtpHost)
            }
            try await smtpServer.login(username: self.username, password: self.password)

            let email = Self.buildEmail(from: draft, senderEmail: self.senderEmail)

            do {
                try await smtpServer.sendEmail(email)
            } catch {
                if !(error is CancellationError) && !SyncEngine.isConnectionError(error) {
                    BackgroundSyncLogger.logError("SMTP send failed: \(error)", source: "outbox:\(self.senderEmail)")
                }
                // Best-effort disconnect before rethrowing
                try? await smtpServer.disconnect()
                throw error
            }
            // Email is sent — disconnect is cleanup, must not throw
            try? await smtpServer.disconnect()
            if DebugModeManager.isLoggingEnabled() { print("[SMTP] Send complete") }
        }
    }

    /// Append a sent message to the IMAP Sent folder. Dedup-safe: searches by Message-ID
    /// before appending so retries after crash/disconnect don't create duplicates.
    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool {
        let senderAddr = senderEmail
        return try await withActionConnection(folder: sentFolderPath) { server in
            let existing = try await self.searchByMessageId(messageId, server: server)
            if !existing.isEmpty {
                if DebugModeManager.isLoggingEnabled() { print("[IMAP] Sent message \(messageId) already exists in \(sentFolderPath) — skipping append") }
                return true
            }

            let email = Self.buildEmail(from: draft, senderEmail: senderAddr)
            _ = try await server.append(email: email, to: sentFolderPath, flags: [.seen], internalDate: Date())
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] Appended sent message \(messageId) to \(sentFolderPath)") }
            return true
        }
    }

    // MARK: - Drafts

    func saveDraft(
        _ draft: DraftMessage,
        existingIdentity: DraftDeleteIdentity?,
        draftsFolderPath: String
    ) async throws -> DraftSaveOutcome {
        // Guard: the appended copy must carry the exact RFC 822 Message-ID the
        // durable `Draft` row recorded, because the Outbox's post-send server-draft
        // cleanup and the server-draft open path both correlate on it.
        // DraftStore.pushDraftToServer generates rfc822MessageId before calling this.
        // It is CORROBORATING METADATA ONLY — ADR-IOS-068/D4 forbids it from ever
        // selecting or authorizing a mutation target (see the no-APPENDUID arm below).
        guard let messageId = draft.messageId, !messageId.isEmpty else {
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] saveDraft: no messageId — cannot track draft UID reliably") }
            throw NSError(domain: "IMAPProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Draft must have a Message-ID for IMAP tracking"])
        }

        let senderAddr = senderEmail
        // `withActionConnectionSelection`, not `withActionConnection`: the UID this
        // APPEND is about to mint is an ADDRESS scoped to the epoch of THIS SELECT, so
        // the epoch has to be captured from this same uninterrupted selection and
        // returned beside it. Reading it later from a shared mirror (or from
        // `Folder.lastKnownUidValidity`) would be a different, possibly newer,
        // observation — and a UID paired with the wrong epoch is worse than a UID with
        // no epoch, because it makes the delete path's equality check pass vacuously.
        return try await withActionConnectionSelection(folder: draftsFolderPath) { server, selection in
            // PORT 83205c5's strong tuple. SUBTRACT the reference's RFC old-copy
            // search: it can wrong-delete the sole surviving same-RFC sibling.
            // Save-path polarity is fail-closed but intention-preserving: missing,
            // malformed, mailbox-mismatched or stale prior coordinates simply skip
            // the old delete and continue to APPEND.
            if case .imap(let folder, let recordedEpoch, let uid) = existingIdentity,
               folder == draftsFolderPath,
               recordedEpoch > 0,
               uid > 0,
               selection.uidValidity.value == UInt32(exactly: recordedEpoch),
               let uidValue = UInt32(exactly: uid) {
                let target = UIDSet(UID(uidValue))
                let infos = try await server.fetchMessageInfosBulk(using: target)
                if infos.contains(where: { $0.uid?.value == uidValue }) {
                    try await server.store(
                        flags: [.deleted], on: target, operation: .add)
                    try await self.expungeScopedToTargets(
                        target, server: server,
                        logDescription: "old draft uid=\(uid) from \(draftsFolderPath)")
                }
            }

            // APPEND new draft with \Draft + \Seen flags (drafts are never "unread").
            // PORT 4d34ee864/82c9ce5: APPENDUID is the exact attempt-correlated
            // identity and always wins over a mailbox search.
            let email = Self.buildEmail(from: draft, senderEmail: senderAddr)
            let appendResult = try await server.append(
                email: email, to: draftsFolderPath,
                flags: [.draft, .seen], internalDate: Date())
            if let appendedUid = appendResult.firstUID,
               let appendedEpoch = appendResult.uidValidity,
               appendedUid.value != 0,
               appendedEpoch.value != 0 {
                if DebugModeManager.isLoggingEnabled() { print("[IMAP] Saved draft to \(draftsFolderPath) via APPENDUID uid=\(appendedUid) uidValidity=\(appendedEpoch)") }
                return .created(.imap(
                    folder: draftsFolderPath,
                    uidValidity: Int(appendedEpoch.value),
                    uid: Int(appendedUid.value)))
            }

            // NO APPENDUID ⇒ NO ADDRESS. ADR-IOS-068/D4, clause 3: mutating UIDSets
            // are built ONLY from UIDs that passed the discharge checklist, so **no
            // SEARCH result is ever a mutation target** — on any path, however well
            // verified. This arm used to run a Message-ID SEARCH, exact-verify the
            // hits, and return the sole survivor's UID as this draft's address.
            //
            // Cardinality and exact-match verification cannot rescue that. They
            // prove "exactly one message in this mailbox carries this Message-ID";
            // they cannot prove "this is the message we just appended", because
            // nothing correlates a SEARCH hit with THIS attempt. RFC 3501 gives a
            // client no exclusivity over a mailbox between two commands: after the
            // APPEND of X and before the SEARCH, another IMAP actor (a second
            // TabMail instance, the Thunderbird addon, any other client) can move or
            // expunge the appended copy while a same-Message-ID sibling Y remains.
            // Every guard then passes on Y, Y's UID is persisted as X's address, and
            // the next `deleteDraft` runs `deleteDraftStrong` → STORE `\Deleted` →
            // `expungeScopedToTargets` → `UID EXPUNGE` against Y. That is C3 —
            // and it is the one delete in this app that is NOT a move to Trash, so
            // it destroys a draft the user still has. It is exactly the shape of
            // `IOS-IMAP-002`, where "but we verified the hit" reasoning mutated
            // every copy sharing a Message-ID.
            //
            // APPENDUID (RFC 4315 §3) is the ONLY attempt-correlated authority for a
            // newly appended message. Without it this attempt has no address, so it
            // reports one — `.unaddressable`, which is terminal for this attempt and
            // clears the linkage rather than dropping the user's draft.
            //
            // ⚠️ ACCEPTED COST: a draft appended to a server that withholds
            // APPENDUID (RFC 4315 §3 makes it a SHOULD "with limited exceptions",
            // and those exceptions are properties of the MAILBOX) has no server
            // address, so the app can no longer update or delete that server-side
            // copy.
            //
            // ⚠️ THE COST IS **K STRAYS FOR K SAVES**, NOT ONE. This comment used
            // to read "the user may see a stray duplicate draft to remove by
            // hand" — SINGULAR — which understates it by an unbounded factor, in
            // the one place an implementer touching this arm will read. The
            // arithmetic: `.unaddressable` makes `DraftStore.applyPushCompletion`
            // null `serverDraftId` / `serverDraftUidValidity` /
            // `serverDraftFolderPath` / `serverPushStatus`, so
            // `DraftStore.priorIdentity` returns nil on the NEXT save of the same
            // draft, the old-copy delete is skipped, and each subsequent save
            // APPENDs another copy. A user who edits a draft repeatedly
            // accumulates one stray server copy PER SAVE.
            //
            // THE BOUND, and it is what makes K acceptable rather than an
            // unbounded write loop: K is bounded by explicit user gestures and
            // nothing else. The only `.saveDraft` `PendingOperation` producer is
            // the user-gesture site in `AccountManagerActions`, and NO sweeper
            // re-enqueues on `serverPushStatus` — so there is no autonomous
            // APPEND loop and K cannot grow while the user is not saving.
            //
            // Every stray is recoverable by an ordinary gesture: the strays are
            // ordinary messages in the Drafts folder, synced with real server
            // UIDs by `SyncEngine`, so the ordinary message-delete path addresses
            // them by their own synced UID and never needs APPENDUID —
            // `.unaddressable` is a property of the APPEND RESPONSE, not of the
            // mailbox's ability to report UIDs on FETCH/SELECT. Expunging the
            // wrong draft is NOT recoverable. Failing closed is correct here.
            // Registered as `KNOWN_ISSUES.md` `IOS-DRAFT-011`.
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] saveDraft: APPEND to \(draftsFolderPath) succeeded WITHOUT APPENDUID for '\(messageId)' (uidValidity=\(selection.uidValidity.value)) — no attempt-correlated address exists; NOT searching by Message-ID (ADR-IOS-068/D4: a SEARCH result is never a mutation target)") }
            return .unaddressable
        }
    }

    /// Delete only the provider-native `(folder, UIDVALIDITY, UID)` address.
    /// Unknown, malformed, or stale coordinates fail closed; an absent addressed UID
    /// is already gone. No RFC identity is accepted as mutation authority.
    func deleteDraft(identity: DraftDeleteIdentity) async throws {
        guard case .imap(let folder, let uidValidity, let uid) = identity else {
            throw ProviderError.actionIdentityResolutionFailed("IMAPProvider received a non-IMAP draft identity")
        }
        do {
            try await deleteDraftStrong(
                uid: uid, uidValidity: uidValidity, draftsFolderPath: folder)
        } catch is IMAPActionMailboxAbsent {
            // T3.3 PORT — `v2final:…:IMAPProvider.deleteDraft`'s catch arm. The
            // Drafts mailbox is CONFIRMED gone (LIST probe), so the server copy
            // of this draft went with it. Terminal no-op; propagating would pin
            // the lane behind a delete no server can ever satisfy.
            //
            // This changes ONLY the mailbox-absent classification. It does not
            // touch draft IDENTITY handling (T3.9/T3.10) — an unknown,
            // malformed or stale address still fails closed in
            // `deleteDraftStrong` exactly as before.
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] Drafts mailbox absent — draft delete completed as no-op (mailbox '\(folder)' confirmed gone)") }
        }
    }

    /// PORT/SUBTRACT of `v2final.deleteDraftStrong`: retain its UID validation and
    /// absent-target no-op, but omit optional RFC corroboration because v3's typed
    /// identity has no RFC leg.
    ///
    /// ⚠ **DEVIATION FROM THE REFERENCE, DELIBERATE — do not "restore" it.** This
    /// used to say it retained the reference's *exact epoch* validation, and it did:
    /// `v2final:e28dd4edb:TabMail/Providers/IMAPProvider.swift` `deleteDraftStrong`
    /// carries `guard selection.uidValidity.value == recordedUidValidity else {
    /// throw ProviderError.actionIdentityResolutionFailed(…) }`, and its
    /// `requireSameUidValidity` is likewise a bare two-outcome `guard stored ==
    /// live`. The reference is a FLOOR, not a ceiling: that shape treats a live
    /// epoch of ZERO — what SwiftMail yields when the server omits the untagged
    /// UIDVALIDITY response — as a mismatch, and the drain destroys the durable op
    /// on it. v3 replaced it with the file's own three-outcome
    /// `requireUidValidity(live:expected:folder:)`; see the block at the comparison.
    private func deleteDraftStrong(
        uid: Int, uidValidity: Int, draftsFolderPath: String
    ) async throws {
        guard uid > 0,
              uidValidity > 0,
              let recordedUidValidity = UInt32(exactly: uidValidity),
              let targetUidValue = UInt32(exactly: uid) else {
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] deleteDraft (strong): out-of-range identity (uid=\(uid), uidValidity=\(uidValidity)) in \(draftsFolderPath) — REFUSING") }
            throw ProviderError.actionIdentityResolutionFailed(String(uid))
        }
        try await withActionConnectionSelection(folder: draftsFolderPath) { server, selection in
            // 🚨 THIS COMPARISON MUST HAVE THREE OUTCOMES, NOT TWO — and it must be
            // the file's ONE comparison, not a second copy of it.
            //
            // It used to be a bare `guard selection.uidValidity.value ==
            // recordedUidValidity else { throw
            // ProviderError.actionIdentityResolutionFailed(…) }`, inherited verbatim
            // from `v2final`'s `deleteDraftStrong`. SwiftMail types
            // `Mailbox.Selection.uidValidity` as non-optional with a `UIDValidity(0)`
            // default, so a SELECT that omits the REQUIRED `* OK [UIDVALIDITY n]`
            // untagged response (RFC 3501 §6.3.1) reaches this line as a live epoch
            // of ZERO. Zero is never equal to a recorded `nz-number`, so the guard
            // fired — and the drain DELETES the durable `PendingOperation` on
            // `actionIdentityResolutionFailed`. "The server did not tell us" was
            // taking a terminal exit: an intention destroyed on an ABSENCE of
            // evidence, which `Companion/Rules/Active/never-drop-user-intention.md`
            // forbids in the clause naming it "the single most repeated defect in
            // this codebase's history". Every send on such a server left a permanent
            // duplicate in Drafts, because the delete was annihilated rather than
            // retried.
            //
            // `requireUidValidity(live:expected:folder:)` is that three-outcome
            // comparison and already existed, ten screens up, for exactly this
            // hazard — this leg was simply never routed through it. Do not add a
            // second epoch checker here. What each outcome now means:
            //  - equal, both real ⇒ proceed (unchanged);
            //  - both real and DIFFERENT ⇒ `ProviderError.uidValidityChanged`, exit 4
            //    of the never-drop rule. STILL TERMINAL — the drain retires the op —
            //    and now under the classification that actually describes it, a
            //    PROVEN turnover in this op's own address space, rather than a
            //    verdict on the identity's parsability;
            //  - either epoch zero ⇒ `IMAPEpochEvidenceMissing`, retryable, requeued
            //    by the drain's `ProviderEvidenceUnavailable` arm.
            //
            // ⚠ THE EVIDENCE THIS OPERATION REQUIRES IS UNCHANGED — the refusal set
            // only GREW. `deleteDraftStrong` is an irreversible wire operation (it
            // destroys a draft outright instead of moving it to Trash), so nothing here
            // may ever make it mutate on WEAKER proof.
            //
            // ⚠ DO NOT WRITE A COUNT HERE. This comment said "TWO", was corrected to
            // "FOUR", and "FOUR" was wrong within two days as well — the set is defined
            // by a PREDICATE, never by an integer, and an integer is what goes stale
            // silently. THE PREDICATE: *every wire call that destroys, or may destroy,
            // user-authored content on a server, where TabMail has no positive
            // documented per-item recovery path that its own call actually reaches.*
            //
            // ⚠️ THE SEARCHES BELOW ARE A LOWER BOUND ON THAT PREDICATE, NEVER ITS
            // DEFINITION — corrected 2026-08-06 (R12-T9), because the previous wording
            // said membership "is re-derived by three searches" and every one of those
            // three searches is for a destructive **verb**, while the predicate is about
            // the **effect on the stored representation**. An HTTP `PUT` replaces a
            // representation, so the previous bytes are gone; no `DELETE`-shaped or
            // `expunge`-shaped pattern can ever see it. That is `MIS-007` one level up:
            // the first correction fixed the SPELLING of a verb (`method:` versus
            // `httpMethod =`) and left the CATEGORY — "destructive means DELETE" —
            // unexamined. Run BOTH axes, over
            // `TabMail/ Shared/ TabMailNotificationService/`, `--multiline`:
            //  - deletion axis: `method\s*:\s*"DELETE"`, `httpMethod\s*=\s*"DELETE"`,
            //    `expunge\(`;
            //  - replacement axis: `httpMethod\s*=\s*"PUT"`, `method\s*:\s*"PUT"` — and
            //    treat a full-resource `PATCH`, an overwriting `POST`, or a computed
            //    `URLRequest.httpMethod` as the next spellings to look for, since a
            //    verb-shaped census is blind to each of them in turn.
            // Then adjudicate every hit against THE PROPERTY; a pattern proposes a
            // candidate, it never decides membership.
            //
            // ⚠️ THE SET HAS TWO FAMILIES, AND `splitSeries` IS IN IT. The five members
            // listed below are the **deletion family**. `CalDAVProvider.splitSeries`
            // step 3 `PUT`s a capped ICS over the EXISTING master event resource, so
            // every occurrence after the split point ceases to exist on the server and
            // the pre-cap representation is gone — the same WebDAV absence of trash,
            // undelete and restore that puts `CalDAVProvider.deleteEvent` in the set. It
            // satisfies THE PROPERTY exactly. It is deliberately **NOT** a sixth
            // numbered member: it is the **replacement family**, and the routed
            // authority adjudicates it that way so the distinction stays reusable
            // (both destroy; only one is spelled like it). Consequence for design: it is
            // a MULTI-STEP irreversible operation whose rollback is a best-effort
            // compensating `PUT`, not a transaction — do not widen the successor PUT
            // past `.ifNoneMatchAny`, and do not make the rollback unconditional again.
            // `GmailProvider.saveDraft`'s `PUT /drafts/{existingId}` is the replacement
            // axis' NEGATIVE case: excluded on positive evidence (the bytes it replaces
            // are a revision the local `draft` row still holds, and refusing it would
            // drop a user intention rather than preserve one), and that exclusion is
            // void the moment a path PUTs a draft with content not derived from that
            // draft's own current local state.
            //
            // The authority for current
            // membership, and for the POSITIVE evidence behind every exclusion, is
            // `Companion/Memory/Current/102-there-are-four-irreversible-wire-operations-not-one.md`
            // (its filename is a frozen slug, not the count); this comment is a pointer
            // to it, and where they differ that note wins. DELETION-FAMILY members as
            // adjudicated 2026-08-05 (the replacement family is stated above, and this
            // enumeration is not the whole set without it):
            // `IMAPProvider.move`'s `COPYUID`-gated source expunge (which
            // removes a proven DUPLICATE and is the only member that touches a message
            // rather than a draft or an event); THIS function; `saveDraft`'s old-copy
            // replacement, which issues the same `STORE \Deleted` +
            // `expungeScopedToTargets` pair against the previous draft UID on the
            // ordinary save path; Gmail's `DELETE /drafts/{id}`, which Google documents
            // as immediate and permanent rather than a trash; and
            // `CalDAVProvider.deleteEvent`, a WebDAV `DELETE` on the event's own `.ics`
            // for which RFC 4918/4791 define no trash, undelete or restore.
            //
            // NEGATIVE CASE, because an absolute without one is what produced the wrong
            // enumeration twice: this function and `saveDraft`'s replacement are
            // irreversible ONLY where the server advertises UIDPLUS —
            // `expungeScopedToTargets` issues `UID EXPUNGE` there and NOTHING AT ALL
            // otherwise, deliberately refusing to degrade to a mailbox-wide `EXPUNGE`,
            // so on a non-UIDPLUS server the draft is left `\Deleted`-but-present and is
            // recoverable. Ordinary mail is untouched by any of this: `.delete` on a
            // message is still a move to Trash.
            //
            // EXCLUDED ON POSITIVE EVIDENCE, never on absence of it — the distinction
            // that decides membership. `ExchangeProvider.deleteDraft` issues
            // `DELETE {baseURL}/messages/{id}`, and Graph exposes a SEPARATE
            // `message: permanentDelete` action for the destroying semantic, so the
            // plain `DELETE` is a soft delete into Deleted Items / Recoverable Items;
            // `ExchangeCalendarProvider.deleteEvent` and `GoogleCalendarProvider`'s
            // single-event delete are excluded the same way (Graph soft delete; Google
            // Calendar's documented 30-day event trash). Recoverable ⇒ out of the set.
            // CalDAV has no such documented path on any server TabMail supports, which
            // is why it is IN rather than merely unobserved.
            //
            // Zero previously reached the mutation only in the sense that it reached
            // a terminal drop; it now reaches neither the mutation nor a drop.
            do {
                try self.requireUidValidity(
                    selection, expected: recordedUidValidity, folder: draftsFolderPath)
            } catch let missing as IMAPEpochEvidenceMissing {
                // Debug-gated (rule 12): this is NEW diagnostic trace, and unlike the
                // mismatch line below it does not witness a drop — the op stays
                // durably queued and the drain's own `ProviderEvidenceUnavailable`
                // arm already logs it. Gating it cannot hide a loss, because there
                // is no loss.
                if DebugModeManager.isLoggingEnabled() {
                    print("[IMAP] deleteDraft (strong): SELECT of \(draftsFolderPath) reported NO usable UIDVALIDITY for uid=\(uid) (recorded=\(uidValidity), current=\(selection.uidValidity.value)) — REFUSING and keeping the op QUEUED (absence of evidence is not a proven turnover; retries when the server reports one)")
                }
                throw missing
            } catch {
                if DebugModeManager.isLoggingEnabled() { print("[IMAP] deleteDraft (strong): UIDVALIDITY mismatch for uid=\(uid) in \(draftsFolderPath) (recorded=\(uidValidity), current=\(selection.uidValidity.value)) — REFUSING (fail closed; never rebind by rfc822)") }
                throw error
            }
            let targetSet = UIDSet(UID(targetUidValue))
            let infos = try await server.fetchMessageInfosBulk(using: targetSet)
            guard infos.contains(where: { $0.uid?.value == targetUidValue }) else {
                // Already gone — expunged by another actor, or by a prior attempt whose
                // response was lost. Terminal no-op, and NOT an invitation to go looking
                // for something else that carries the same Message-ID.
                if DebugModeManager.isLoggingEnabled() { print("[IMAP] deleteDraft (strong): uid=\(uid) in \(draftsFolderPath) not found on FETCH — treating as already deleted") }
                return
            }
            try await server.store(flags: [.deleted], on: targetSet, operation: .add)
            try await self.expungeScopedToTargets(
                targetSet, server: server,
                logDescription: "draft uid=\(uid) from \(draftsFolderPath)")
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] Deleted draft uid=\(uid) from \(draftsFolderPath)") }
        }
    }

    /// STORE-`\Deleted`'s purge tail, scoped to the UID(s) actually being deleted.
    ///
    /// A bare `EXPUNGE` is MAILBOX-WIDE (RFC 3501 §6.4.3): it names no UID and
    /// removes EVERY message flagged `\Deleted` in the selected mailbox — another
    /// client's soft-deleted mail, or a copy a crashed prior attempt left marked
    /// but unexpunged. On the draft path the blast radius lands in Drafts, which is
    /// precisely where `saveDraft` leaves `\Deleted`-but-unexpunged messages behind.
    /// That is a wrong-message deletion — C3 — with or without any UIDVALIDITY
    /// change.
    ///
    /// ⚠️ **THIS SENTENCE SAID "on its `try?`-swallowed legs" UNTIL 2026-08-06 AND
    /// THAT MECHANISM DOES NOT EXIST.** `saveDraft`'s old-copy replacement issues
    /// `try await server.store(flags: [.deleted], …)` and `try await
    /// self.expungeScopedToTargets(…)` — both propagate, neither swallows, and the
    /// current polarity is CORRECT (do not "restore" `try?` to make a comment
    /// true). The conclusion is unchanged, because Drafts accumulates
    /// marked-but-unexpunged messages by **two live mechanisms** instead:
    ///   1. **This function's own non-UIDPLUS arm deliberately issues nothing.** The
    ///      caller has already sent the `\Deleted` STORE, so on every server without
    ///      UIDPLUS the message stays marked and present, by design, forever.
    ///   2. **A crash, kill or connection drop between the STORE `await` and the
    ///      expunge `await`** leaves the same residue, on any server.
    /// Both are recoverable soft deletes and both are exactly the population a bare
    /// mailbox-wide `EXPUNGE` would destroy.
    ///
    /// UID EXPUNGE (RFC 4315) when the server advertises UIDPLUS, and NOTHING
    /// otherwise. `target` must already name exactly the verified UID(s) to
    /// delete — this is never a mailbox-wide operation. Ported from `v2final`'s
    /// `storeDeletedAndMaybeExpunge` ("audit #9 semantics"), including its
    /// fail-closed non-UIDPLUS arm.
    ///
    /// An earlier revision of this function ran a bare `server.expunge()` on the
    /// non-UIDPLUS branch and carried a comment presenting that as a deliberate
    /// deviation from `v2final`, on the reasoning that a soft delete alone lets
    /// the server draft re-materialise on the next sync. **That reasoning was
    /// wrong and the comment has been removed.** The "never wrong-delete"
    /// invariant (C3) is UNCONDITIONAL, not UIDPLUS-gated: trading a guaranteed
    /// wrong-delete of somebody else's mail for a cosmetic reappearance is not a
    /// trade this codebase is allowed to make. A draft that comes back is
    /// visible, re-deletable, and costs the user a second gesture; a draft this
    /// call destroyed without ever identifying it is gone.
    private func expungeScopedToTargets(
        _ target: UIDSet, server: IMAPServer, logDescription: String
    ) async throws {
        // Debug-gated: these two lines are NEW trace, not the pre-existing
        // production logs. Every log this refactor displaced is preserved verbatim
        // and unconditional at its original call site.
        if await server.supportsUIDPlus {
            try await server.expunge(messages: target)
            if DebugModeManager.isLoggingEnabled() {
                print("[IMAP] Purged \(logDescription) (UID EXPUNGE)")
            }
        } else {
            // No UIDPLUS: a mailbox-wide EXPUNGE is the ONLY server-side purge
            // available, and it removes EVERY `\Deleted` message in the selected
            // mailbox (RFC 3501 §6.4.3) — another client's soft-deleted mail, or a
            // copy left marked-but-unexpunged by a `saveDraft` that was killed
            // between its STORE `await` and its expunge `await`, or by an EARLIER
            // TRIP THROUGH THIS VERY BRANCH. That is a wrong-message deletion, with
            // or without any UIDVALIDITY change. (This said "on one of its
            // `try?`-swallowed legs" until 2026-08-06; `saveDraft` has no `try?` on
            // that path and never did in this revision — see the doc comment above.
            // Note the self-reference: on a non-UIDPLUS server this arm is itself
            // the main producer of the residue, so the population grows with every
            // draft replacement and a bare EXPUNGE gets more dangerous over time,
            // not less.) FAIL CLOSED: the `\Deleted` STORE the
            // caller already issued records the deletion intent (soft delete), and a
            // UIDPLUS-capable client or the server's own policy completes the purge.
            // NEVER a mailbox-wide EXPUNGE.
            if DebugModeManager.isLoggingEnabled() {
                print("[IMAP] \(logDescription): server lacks UIDPLUS — marked \\Deleted (soft delete), skipped mailbox-wide EXPUNGE to avoid a wrong-delete")
            }
        }
    }

    /// Build an Email object from a DraftMessage. Shared between send() and appendToSentFolder().
    static func buildEmail(from draft: DraftMessage, senderEmail: String) -> Email {
        let smtpAttachments: [Attachment]? = draft.attachments.isEmpty ? nil : draft.attachments.map {
            Attachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
        var email = Email(
            sender: SwiftMail.EmailAddress(address: senderEmail),
            recipients: draft.to.map { SwiftMail.EmailAddress(address: $0) },
            ccRecipients: draft.cc.map { SwiftMail.EmailAddress(address: $0) },
            // Own the complete outbound Subject boundary before handing it to
            // SwiftMail. The app encoder preserves literal RFC 2047-shaped text,
            // controls, Unicode, and the 75-octet word limit; its ASCII result makes
            // SwiftMail's own encoder a no-op without a fork-local deviation.
            subject: RFC2047.encodeHeaderValue(draft.subject),
            textBody: draft.isHTML ? EmailFilter.htmlToPlainText(draft.body) : draft.body,
            htmlBody: draft.isHTML ? draft.body : nil,
            attachments: smtpAttachments
        )
        // Set pre-generated Message-ID (first-class property on Email)
        if let messageId = draft.messageId {
            email.messageID = MessageID(messageId)
        }
        // Set threading headers (RFC 2822 requires angle brackets around message IDs)
        var headers: [String: String] = [:]
        if let inReplyTo = draft.inReplyTo, !inReplyTo.isEmpty {
            headers["In-Reply-To"] = inReplyTo.hasPrefix("<") ? inReplyTo : "<\(inReplyTo)>"
        }
        if !draft.references.isEmpty {
            headers["References"] = draft.references.map { $0.hasPrefix("<") ? $0 : "<\($0)>" }.joined(separator: " ")
        }
        if !headers.isEmpty {
            email.additionalHeaders = headers
        }
        return email
    }

    // MARK: - Incremental Sync

    /// Flush pending server-side state before STATUS checks.
    /// SELECT INBOX + NOOP forces the server to refresh its mailbox state.
    /// Plain NOOP alone is insufficient on some servers (they only flush the
    /// currently-SELECTed mailbox). SELECT is the most reliable way to force
    /// the server to report current state for subsequent STATUS commands.
    /// Acquires lock because SELECT changes the server's selected mailbox —
    /// without it, actor reentrancy could corrupt a concurrent operation's
    /// selected-mailbox state (e.g., fetchMessage SELECTs "Sent", then
    /// flushServerState SELECTs "INBOX" at an await point, then fetchMessage
    /// resumes and FETCHes from INBOX instead of Sent).
    func flushServerState() async throws {
        try await withFolderConnection(folder: "INBOX") { server in
            // T5.3 PORT — `v2final:…:IMAPProvider.flushServerState` tracks this
            // SELECT. It is issued to make the server flush state before the
            // STATUS poll, but it is still a genuine observation of INBOX's
            // epoch, and on a non-UIDPLUS server (where STATUS never carries
            // UIDVALIDITY) it is one of the few that exist.
            _ = try await selectMailboxTracked(server, folder: "INBOX")
            _ = try await server.noop()
        }
    }

    /// Quick STATUS check for delta sync — returns folder stats without SELECT.
    /// Compares against stored values to detect new messages, deletions, or flag changes.
    func folderStatus(path: String) async throws -> IMAPFolderStatus {
        try await withActionConnectionNoSelect { server in
            let status = try await server.mailboxStatus(path)
            return IMAPFolderStatus(
                messageCount: status.messageCount ?? 0,
                uidNext: status.uidNext.map { Int($0.value) } ?? 0,
                unreadCount: status.unseenCount ?? 0,
                // Non-nil only when the server advertised CONDSTORE / UIDPLUS
                // (SwiftMail conditionally requests these STATUS attributes).
                highestModSeq: status.highestModSequence,
                // Normalised at THIS boundary: `0` means "the server did not report
                // a value" (see `UIDExistenceResult.uidValidity`), so it must reach
                // the sync layer as nil/unknown, never as an epoch that would make
                // every downstream comparison `0 == 0` and therefore vacuous.
                uidValidity: SyncEngine.knownUidValidity(status.uidValidity.map { Int($0.value) })
            )
        }
    }

    func fetchHistory(since historyId: String) async throws -> HistoryResponse? {
        // IMAP doesn't have a history API like Gmail.
        // Return nil to signal SyncEngine should use full sync.
        return nil
    }

    func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] {
        // Not used for IMAP (no incremental sync path yet)
        return []
    }

    // MARK: - Batch Body Fetch (FTS)

    /// Result of a batch text body fetch for a single message.
    struct TextBodyResult: Sendable {
        let uid: UInt32
        let htmlBody: String?
        let textBody: String?
    }

    func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] {
        let uids = ids.compactMap { UInt32($0) }
        guard !uids.isEmpty else { return [] }
        // Split into sub-batches fetched via folder-pinned connection.
        // All sub-batches go through the same pinned connection for this folder.
        let batchSize = BackfillProfile.normal.imapBodyFetchBatchSize
        let subBatches: [[UInt32]] = stride(from: 0, to: uids.count, by: batchSize).map { i in
            Array(uids[i..<min(i + batchSize, uids.count)])
        }

        return try await withThrowingTaskGroup(of: [TextBodyResult].self) { group in
            for subBatch in subBatches {
                group.addTask {
                    try await self.fetchTextBodiesBatch(folder: folder, uids: subBatch, batchSize: batchSize)
                }
            }
            var allResults: [TextBodyFetchResult] = []
            for try await batchResults in group {
                for r in batchResults {
                    allResults.append(TextBodyFetchResult(id: "\(r.uid)", htmlBody: r.htmlBody, textBody: r.textBody, error: nil))
                }
            }
            return allResults
        }
    }

    /// Batch fetch text bodies for FTS indexing. Each batch checks out a pool connection.
    /// Only fetches text/plain and text/html MIME parts — skips attachments entirely.
    /// Uses bulk BODYSTRUCTURE fetch to avoid redundant per-message structure queries.
    ///
    /// Connection is checked out per-batch (not for the entire call) so user actions
    /// can use other pool connections between batches.
    private func fetchTextBodiesBatch(
        folder: String,
        uids: [UInt32],
        batchSize: Int
    ) async throws -> [TextBodyResult] {
        guard !uids.isEmpty else { return [] }

        var results: [TextBodyResult] = []
        // Mutable chunk size — halved on PayloadTooLargeError, same as backfill walk
        var currentBatchSize = batchSize
        var index = 0

        while index < uids.count {
            try Task.checkCancellation()
            let batchEnd = min(index + currentBatchSize, uids.count)
            let batchUIDs = Array(uids[index..<batchEnd])

            let batchResults = try await fetchTextBodiesChunk(
                folder: folder, batchUIDs: batchUIDs
            )

            if let batchResults {
                // Success — advance past this chunk
                results.append(contentsOf: batchResults)
                index = batchEnd
                // Brief yield between batches
                if index < uids.count {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } else {
                // PayloadTooLargeError — halve chunk size and retry same index
                // Connection is contaminated, pool will discard it on next checkout
                if currentBatchSize <= 1 {
                    // Single UID still too large — return empty result so caller can confirm empty
                    let uid = batchUIDs.first ?? 0
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP] Single UID \(uid) too large — marking as empty") }
                    results.append(TextBodyResult(uid: uid, htmlBody: nil, textBody: nil))
                    index += 1
                } else {
                    currentBatchSize = max(1, currentBatchSize / 2)
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP] Batch too large, reducing chunk to \(currentBatchSize)") }
                }
            }
        }

        return results
    }

    /// Fetch text bodies for a single chunk. Returns nil on PayloadTooLargeError (caller should retry with smaller chunk).
    private func fetchTextBodiesChunk(
        folder: String,
        batchUIDs: [UInt32]
    ) async throws -> [TextBodyResult]? {
        var uidSet = UIDSet()
        for uid in batchUIDs { uidSet.insert(UID(uid)) }

        let capturedUidSet = uidSet
        return try await withFolderConnection(folder: folder) { server in
            try await withTimeout(seconds: SyncConfig.imapBatchOperationTimeoutSeconds) {
                // T5.3 PORT — `v2final:…:IMAPProvider.fetchTextBodiesChunk` tracks
                // this SELECT inside the identical `withFolderConnection` →
                // `withTimeout` nesting, with the same explicit `self.` (the
                // timeout closure is `@Sendable @escaping`, so implicit `self` is
                // not available and the call is a normal cross-actor `await` onto
                // this actor). Capturing `self` here is sound: `IMAPProvider` is
                // an actor and therefore `Sendable`, and the closure is not
                // stored on `self`.
                _ = try await self.selectMailboxTracked(server, folder: folder)

                let infos: [MessageInfo]
                do {
                    infos = try await server.fetchMessageInfosBulk(using: capturedUidSet)
                } catch {
                    let desc = "\(error)"
                    if desc.contains("PayloadTooLargeError") {
                        return nil  // Signal caller to split and retry
                    }
                    throw error
                }

                var batch: [TextBodyResult] = []
                var connectionDead = false

                for info in infos {
                    guard let uid = info.uid else { continue }
                    if connectionDead { break }

                    let textParts = info.parts.filter { part in
                        let ct = part.contentType.lowercased()
                        return (ct.hasPrefix("text/plain") || ct.hasPrefix("text/html"))
                            && part.disposition?.lowercased() != "attachment"
                    }

                    var textBody: String?
                    var htmlBody: String?

                    for part in textParts {
                        do {
                            let data = try await IMAPFetchMapping.concatenateEncodedPart(
                                expectedSize: part.size
                            ) { offset, count in
                                try await server.fetchPart(
                                    section: part.section,
                                    of: uid,
                                    offset: offset,
                                    count: count
                                )
                            }
                            var populated = part
                            populated.data = data
                            if part.contentType.lowercased().hasPrefix("text/plain"), textBody == nil {
                                textBody = populated.textContent
                            } else if part.contentType.lowercased().hasPrefix("text/html"), htmlBody == nil {
                                htmlBody = populated.textContent
                            }
                        } catch {
                            if DebugModeManager.isLoggingEnabled() { print("[IMAP] Failed to fetch part \(part.section) for UID \(uid.value): \(error)") }
                            if SyncEngine.isConnectionError(error) {
                                if DebugModeManager.isLoggingEnabled() { print("[IMAP] Connection dead during batch — aborting remaining fetches") }
                                connectionDead = true
                                break
                            }
                        }
                    }

                    batch.append(TextBodyResult(uid: uid.value, htmlBody: htmlBody, textBody: textBody))
                }
                return batch
            }
        }
    }

    // MARK: - UID Range Backfill

    /// Get UIDNEXT for a folder via SELECT, together with the UIDVALIDITY that
    /// same SELECT reported. Returns `uidNext == 0` if the server doesn't provide
    /// UIDNEXT (shouldn't happen per RFC 3501), and `observedEpoch == nil` if it
    /// reported no UIDVALIDITY.
    ///
    /// 🚨 The two travel together because `SyncEngine.runBackfill` STAMPS
    /// `observedEpoch` onto the folder (through
    /// `bootstrapCrawledFolderUidValidity`) and hands it to every worker as the
    /// epoch the walk is accounted in. Reading it back out of
    /// `lastObservedUidValidityBox` instead — which round 8 did — leaves a window
    /// in which any other SELECT of the same path replaces it first, and after
    /// round 8's widening that includes self-heal's and deep backfill's
    /// `fetchMessageHeaders` (see `selectMailboxTracked`'s round-10 retraction).
    /// The mirror is sound only for the walk's per-chunk COMPARISON, which fails
    /// closed on disagreement; it is not sound for the value the walk writes.
    func getUidNextWithEpoch(folder: String) async throws -> (uidNext: Int?, observedEpoch: UInt32?) {
        try await withFolderConnection(folder: folder) { server in
            // T1.3 (round 8): TRACKED. This is the crawl's walk-start SELECT —
            // the one the walk's per-chunk checks compare against. A raw
            // `selectMailbox` here left the mirror holding whatever the pinned
            // connection's CREATION SELECT observed, which on a resumed crawl can
            // be an epoch from a different pass entirely. See
            // `selectMailboxTracked`'s scope note.
            let selection = try await selectMailboxTracked(server, folder: folder)
            let observed = selection.uidValidity.value
            // 🚨 BOTH HALVES ARE NORMALISED FOR ABSENCE OF EVIDENCE, and only
            // the epoch used to be. `Mailbox.Selection`'s UIDNEXT and
            // UIDVALIDITY are BOTH non-optional with a zero default
            // (`SwiftMail/IMAP/Models/Mailbox.swift`: `public var uidNext: UID
            // = UID(0)`; `SelectHandler` assigns it only when the wire carried
            // an `* OK [UIDNEXT n]` response code), and RFC 3501 §6.3.1 types
            // both as `nz-number`, so ZERO is not a value any conformant
            // server can report — it means THIS SELECT DID NOT SAY. Returning
            // it as a number let `SyncEngineBackfillWalk`'s `.fresh` branch
            // compute `initialCursor = 0 - 1 = -1`, take the `< 1` early-out
            // written for a genuinely empty mailbox (UIDNEXT 1 ⇒ cursor 0) and
            // mark the folder `backfillComplete` — permanently, since
            // completion excludes it from every later crawl. "Could not
            // determine" is not an authoritative answer (`MIS-IOS-004`);
            // `nil` makes it unrepresentable as one at the decision site.
            let next = selection.uidNext.value
            return (next != 0 ? Int(next) : nil, observed != 0 ? observed : nil)
        }
    }

    /// Discover which UIDs actually exist in a UID range using UID SEARCH.
    /// Caller should use the same chunk size as FETCH (e.g., 500 UIDs) so the
    /// SEARCH response is always small (~3.5KB max) and never overflows.
    /// For sparse ranges, returns empty → caller skips FETCH entirely.
    func searchExistingUIDs(folder: String, from: Int, to: Int) async throws -> [UInt32] {
        guard from >= 1, to >= from else { return [] }
        try Task.checkCancellation()

        return try await withFolderConnection(folder: folder) { server in
            // T1.3 (round 8): TRACKED — this SELECT is the one that decides
            // which UID space this chunk's SEARCH result belongs to, and the
            // walk compares the epoch it records against the walk's own before
            // it trusts (or inserts) anything from this range.
            let _ = try await selectMailboxTracked(server, folder: folder)
            var searchSet = MessageIdentifierSet<UID>()
            searchSet.insert(range: Int(from)...Int(to))
            let extResult: ExtendedSearchResult<UID> = try await server.extendedSearch(
                identifierSet: searchSet, criteria: [.all]
            )
            return extResult.asSet.toArray().map { UInt32($0.value) }
        }
    }

    /// Check which of an EXPLICIT set of UIDs still exist in a folder via
    /// `UID SEARCH UID <set>` (deletion reconcile, ADR-IOS-051). Unlike the
    /// range variant above, the response can only ever name UIDs from the
    /// queried set, so with chunks of `SyncConfig.deletionReconcileChunkSize`
    /// both the command and the response stay far below the 1MB NIO buffer
    /// limit even in dense folders. Also returns the SELECT's UIDVALIDITY so
    /// the caller can abort when the folder's UID numbering was invalidated
    /// (a UIDVALIDITY change makes every local UID meaningless — deleting on
    /// a "not found" result would then be unsafe).
    func searchExistingUIDs(folder: String, uids: [UInt32]) async throws -> UIDExistenceResult {
        guard !uids.isEmpty else { return UIDExistenceResult(found: [], uidValidity: 0) }
        try Task.checkCancellation()

        return try await withFolderConnection(folder: folder) { server in
            // T5.3 PORT — `v2final:…:IMAPProvider.searchExistingUIDs(folder:uids:)`
            // tracks this SELECT. The epoch this call RETURNS is still the one
            // bound to this very `Mailbox.Selection` (below) — the mirror write is
            // additive and no consumer of `UIDExistenceResult` reads the mirror.
            let selection = try await selectMailboxTracked(server, folder: folder)
            var searchSet = UIDSet()
            for uid in uids { searchSet.insert(UID(uid)) }
            let extResult: ExtendedSearchResult<UID> = try await server.extendedSearch(
                identifierSet: searchSet, criteria: [.all]
            )
            return UIDExistenceResult(
                found: Set(extResult.asSet.toArray().map { UInt32($0.value) }),
                uidValidity: selection.uidValidity.value
            )
        }
    }

    /// Fetch message headers for a UID range (from...to inclusive).
    /// Creates a UIDSet from the range and fetches in sub-batches with per-batch lock.
    /// Server returns only UIDs that exist — gaps (deleted messages) are silently skipped.
    func fetchUIDRange(
        folder: String,
        from: Int,
        to: Int,
        batchSize: Int,
        interBatchDelay: TimeInterval = 0.5
    ) async throws -> [MessageHeaderInfo] {
        guard from >= 1, to >= from else { return [] }

        // Build flat UID array from the range, then delegate to fetchMessageHeaders
        // which handles per-batch locking and SELECT.
        let uids = (UInt32(from)...UInt32(to)).map { $0 }
        return try await fetchMessageHeaders(
            folder: folder, uids: Array(uids),
            batchSize: batchSize, interBatchDelay: interBatchDelay
        )
    }

    // MARK: - Backfill (Date-Based, used by fetchOlderMessages / self-heal)

    /// Shared SEARCH helper: finds UIDs in a date range, binary-splitting on PayloadTooLargeError.
    /// Must be called with a checked-out server connection.
    /// Re-selects the folder before each SEARCH to guard against state corruption from splits.
    private func searchDateRange(
        folder: String,
        since: Date,
        before: Date,
        server: IMAPServer
    ) async throws -> [UID] {
        // T5.3 PORT — `v2final:…:IMAPProvider.searchDateRange` tracks this SELECT.
        // LOOP VARIANT (unchanged by this edit): the binary split recurses only
        // on `PayloadTooLargeError` and only while
        // `before.timeIntervalSince(since) > 86400`, and each level halves that
        // interval — a value that strictly decreases with a lower bound of 86400,
        // so the depth is at most `log2(totalSeconds / 86400)`.
        // `selectMailboxTracked` introduces no new arm: it throws exactly what
        // `server.selectMailbox` throws, and a throw exits the recursion entirely
        // rather than re-entering it, so no refusal can hold the variant constant.
        _ = try await selectMailboxTracked(server, folder: folder)

        let results: UIDSet
        do {
            let extResult: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [.since(since), .before(before)], calendar: Self.utcCalendar)
            results = extResult.asSet
        } catch {
            let desc = "\(error)"
            if desc.contains("PayloadTooLargeError") {
                let totalSeconds = before.timeIntervalSince(since)
                guard totalSeconds > 86400 else {
                    // Can't split further — IMAP SINCE/BEFORE uses date-only granularity.
                    // Re-throw so callers can handle (skip folder, shrink window, etc.)
                    // rather than silently dropping all messages in this range.
                    if DebugModeManager.isLoggingEnabled() { print("[IMAP Search] \(folder): PayloadTooLargeError on single day \(since) — cannot split further, propagating error") }
                    throw error
                }
                let midpoint = since.addingTimeInterval(totalSeconds / 2)
                if DebugModeManager.isLoggingEnabled() { print("[IMAP Search] \(folder): SEARCH too large, splitting at \(midpoint)") }
                let firstHalf = try await searchDateRange(folder: folder, since: since, before: midpoint, server: server)
                try Task.checkCancellation()
                let secondHalf = try await searchDateRange(folder: folder, since: midpoint, before: before, server: server)
                return firstHalf + secondHalf
            }
            throw error
        }
        return results.toArray()
    }

    /// SEARCH phase for backfill: find all UIDs in a date range.
    /// Delegates to searchDateRange for binary-split PayloadTooLargeError handling.
    /// Returns lightweight UID values — no message content fetched.
    /// When `since` is nil, searches all messages before `before` (unbounded start).
    func searchBackfillUIDs(
        folder: String,
        since: Date?,
        before: Date? = nil
    ) async throws -> [UInt32] {
        try await withFolderConnection(folder: folder) { server in
            let end = before ?? Date()
            if let since {
                let uids = try await self.searchDateRange(folder: folder, since: since, before: end, server: server)
                return uids.map(\.value)
            } else {
                let uids = try await self.searchBeforeOnly(folder: folder, before: end, server: server)
                return uids.map(\.value)
            }
        }
    }

    /// SEARCH with only BEFORE criterion — finds all messages older than `before`.
    /// Used as final fallback when windowed search exhausts without finding messages.
    private func searchBeforeOnly(folder: String, before: Date, server: IMAPServer) async throws -> [UID] {
        // T5.3 PORT — `v2final:…:IMAPProvider.searchBeforeOnly` tracks this
        // SELECT. The `PayloadTooLargeError` leg hands off to `searchDateRange`
        // exactly once and never re-enters this function, so there is no loop
        // here whose variant a refusal could hold constant.
        _ = try await selectMailboxTracked(server, folder: folder)
        do {
            let extResult: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [.before(before)], calendar: Self.utcCalendar)
            return extResult.asSet.toArray()
        } catch {
            let desc = "\(error)"
            if desc.contains("PayloadTooLargeError") {
                let syntheticSince = Calendar(identifier: .gregorian).date(byAdding: .year, value: -30, to: before) ?? Date.distantPast
                return try await searchDateRange(folder: folder, since: syntheticSince, before: before, server: server)
            }
            throw error
        }
    }

    /// FETCH phase: fetch message headers for specific UIDs. No SEARCH involved.
    /// Called after existence checks have filtered to only missing UIDs.
    /// `interBatchDelay` controls throttle between batches (power-aware via BackfillProfile).
    ///
    /// Connection is checked out per-batch so other operations can use the pool
    /// between batches. Each batch re-SELECTs the folder since it gets a fresh connection.
    func fetchMessageHeaders(
        folder: String,
        uids: [UInt32],
        batchSize: Int,
        interBatchDelay: TimeInterval = 0.5
    ) async throws -> [MessageHeaderInfo] {
        try await fetchMessageHeadersWithObservedEpoch(
            folder: folder, uids: uids, batchSize: batchSize, interBatchDelay: interBatchDelay
        ).messages
    }

    /// The same fetch as above, plus the UIDVALIDITY **the SELECTs that actually
    /// SERVED it reported** — taken from each batch's returned
    /// `Mailbox.Selection`, never from `lastObservedUidValidityBox`.
    ///
    /// 🚨 **WHY THIS EXISTS RATHER THAN A MIRROR READ** (round 13, blocker 2).
    /// `lastObservedUidValidity(folderPath:)` answers *what did the most recent
    /// tracked SELECT of this path report* — and this fetch is one of SEVERAL
    /// concurrent writers of that box (the crawl's per-chunk SELECTs, deep
    /// backfill's, self-heal's; see `selectMailboxTracked`'s round-10
    /// retraction). Reading it back therefore yields an epoch that may belong to
    /// a DIFFERENT SELECT than the one that produced these headers. That is
    /// tolerable where the consumer is a comparison that fails CLOSED on
    /// disagreement — the crawl's per-chunk `epochStillAgrees()` — and it is not
    /// tolerable where the consumer decides whether a batch may be written under
    /// a folder's stamp, which is a fail-DANGEROUS direction. `v2final` can pass
    /// a mirror read into `insertBackfillBatch` because its own
    /// `selectMailboxTracked` carries the ADR-IOS-061 Stage-2 refusal
    /// (`throw ProviderError.uidValidityChanged(…)` on a stored/observed
    /// disagreement), so a SELECT under a changed epoch never reaches an insert
    /// at all. **v3's `selectMailboxTracked` carries no such refusal.** ⚠️ CORRECTED
    /// 2026-08-05: this said "**v3 has no such error and no such refusal**: `rg -n
    /// 'uidValidityChanged' TabMail/` finds no declaration and no throw site — every
    /// hit is prose". Both halves of that evidence are now false —
    /// `ProviderError.uidValidityChanged` was DECLARED (`EmailProvider.swift`) and
    /// THROWN (`requireUidValidity`, this file) by `065a827ca` (2026-08-02), inside
    /// the release range. **The conclusion is unchanged**, because it never depended
    /// on the term's absence, only on WHERE it is thrown: the throw is on the ACTION
    /// path in `requireUidValidity`, so a SELECT under a changed epoch still reaches
    /// an insert on this line. The reference's mirror read is load-bearing on a
    /// refusal v3's SELECT helper does not have, and does not transfer.
    ///
    /// For a non-empty `uids`, `observedEpoch` is nil when — and only when — the
    /// batches were NOT all served under one reported epoch: any batch whose
    /// SELECT reported none (`0` is SwiftMail's default for "not reported", never
    /// a real epoch — RFC 3501 §2.3.1.1 types UIDVALIDITY as `nz-number`), or two
    /// batches reporting DIFFERENT epochs because the mailbox was re-created
    /// mid-fetch. (An EMPTY `uids` also returns nil, having performed no SELECT at
    /// all — with no headers to place there is nothing for a caller to decide.)
    /// Collapsing those to nil is deliberate and fail-closed: a caller comparing
    /// this against its own gated epoch then refuses, because a non-nil gated
    /// epoch can never equal nil.
    ///
    /// A caller whose gated epoch is ITSELF nil admits. That is sound because the
    /// gate that produced the nil (`SyncEngine.crawlEpochGate`) only yields
    /// `.proceed` on a nil observation when the FOLDER's own
    /// `lastKnownUidValidity` is nil too — and an unstamped folder is exactly what
    /// `AccountManager.newGestureRefusedForUnknownEpoch` refuses every gesture on,
    /// so no bare UID from such a folder is ever resolved against a live mailbox
    /// (the `IOS-EPOCH-001` accepted window). Note this is a per-FOLDER property,
    /// not a per-account one: `Folder.lastKnownUidValidity` can also be stamped
    /// from IMAP **STATUS** via `fetchFolders`, an independent channel from
    /// SELECT (see `selectMailboxTracked`'s round-12 retraction), so a server that
    /// omits UIDVALIDITY on SELECT but reports it in STATUS yields a STAMPED
    /// folder plus a nil observation — which the gate refuses rather than admits.
    ///
    /// ⚑ R0 — **NO REFERENCE in `v2final`**: there this overload returns bare
    /// `[MessageHeaderInfo]` and every caller that needs an epoch samples the
    /// mirror. The SHAPE is the reference's own, though, and this file's:
    /// `fetchMessagesWithObservedEpoch` and `getUidNextWithEpoch` already return
    /// the epoch of the SELECT they performed, for exactly this reason.
    func fetchMessageHeadersWithObservedEpoch(
        folder: String,
        uids: [UInt32],
        batchSize: Int,
        interBatchDelay: TimeInterval = 0.5
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?) {
        guard !uids.isEmpty else { return ([], nil) }

        var allHeaders: [MessageHeaderInfo] = []
        var offset = 0
        var batchEpochs = Set<UInt32>()
        var anyBatchUnreported = false
        while offset < uids.count {
            try Task.checkCancellation()

            let end = min(offset + batchSize, uids.count)
            let batch = uids[offset..<end]
            var uidSet = UIDSet()
            for uid in batch {
                uidSet.insert(UID(uid))
            }

            let fetched: (infos: [SwiftMail.MessageInfo], observed: UInt32?) =
                try await withFolderConnection(folder: folder) { server in
                    // T1.3 (round 8): TRACKED — the crawl's per-batch SELECT. The
                    // headers this batch returns belong to the epoch THIS SELECT
                    // reported, and the walk refuses to insert them when that
                    // disagrees with the epoch it captured at walk start.
                    let selection = try await selectMailboxTracked(server, folder: folder)
                    let observed = selection.uidValidity.value
                    return (
                        try await server.fetchMessageInfosBulk(using: uidSet),
                        observed != 0 ? observed : nil
                    )
                }
            let infos = fetched.infos
            if let observed = fetched.observed { batchEpochs.insert(observed) } else { anyBatchUnreported = true }

            let returnedCount = infos.count
            let requestedCount = batch.count
            if returnedCount < requestedCount {
                let returnedUIDs = Set(infos.compactMap { $0.uid?.value })
                let requestedUIDs = Set(batch)
                let missingUIDs = requestedUIDs.subtracting(returnedUIDs)
                if DebugModeManager.isLoggingEnabled() { print("[IMAP-FETCH-GAP] \(folder): requested \(requestedCount) UIDs, got \(returnedCount). Missing UIDs: \(missingUIDs.sorted())") }
            }

            allHeaders.append(contentsOf: infos.compactMap { mapMessageInfo($0) })

            offset = end
            if offset < uids.count {
                try await Task.sleep(for: .seconds(interBatchDelay))
            }
        }

        let observedEpoch: UInt32? =
            (!anyBatchUnreported && batchEpochs.count == 1) ? batchEpochs.first : nil
        return (allHeaders, observedEpoch)
    }

    /// Fetch older messages before a given date for infinite scroll.
    /// Returns up to `limit` messages, newest-first from the older batch.
    /// Widens the search window progressively if no results found.
    /// Delegates SEARCH to searchDateRange which handles PayloadTooLargeError via binary-split.
    func fetchOlderMessages(folder: String, before: Date, limit: Int) async throws -> [MessageHeaderInfo] {
        try await fetchOlderMessagesWithObservedEpoch(
            folder: folder, before: before, limit: limit).messages
    }

    /// Infinite-scroll headers paired with the SELECT that immediately served
    /// their UID FETCH. A search-window premise is not promoted into authority.
    ///
    /// `coverage.serverRecordCount` is the size of the batch the SERVER named for
    /// this page (`allUIDs`, capped at `limit`) — computed before the FETCH and
    /// therefore before `mapMessageInfo` drops anything. That is the number
    /// `SyncEngine.fetchOlderMessages` needs for its continuation decision; the
    /// materialised array's count is a survivor count and cannot answer "does the
    /// server hold more beyond this page?".
    ///
    /// `spansEntireFolder` is always false here: a date-range SEARCH is a window by
    /// construction and never proves anything about the whole folder.
    func fetchOlderMessagesWithObservedEpoch(
        folder: String, before: Date, limit: Int
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?, coverage: FetchCoverage) {
        try await withActionConnection(folder: folder) { server in
            var windowDays = 90
            let maxWindowDays = 365 * 10

            while windowDays <= maxWindowDays {
                let since = Self.utcCalendar.date(byAdding: .day, value: -windowDays, to: before) ?? Date.distantPast

                let allUIDs = try await self.searchDateRange(folder: folder, since: since, before: before, server: server)

                if !allUIDs.isEmpty {
                    let sorted = allUIDs.sorted { $0.value > $1.value }
                    let batch = Array(sorted.prefix(limit))

                    var uidSet = UIDSet()
                    for uid in batch {
                        uidSet.insert(uid)
                    }

                    let selection = try await self.selectMailboxTracked(server, folder: folder)
                    let infos = try await server.fetchMessageInfosBulk(using: uidSet)
                    let observed = selection.uidValidity.value
                    let mapped = infos.compactMap { self.mapMessageInfo($0) }.sorted { $0.date > $1.date }
                    return (
                        mapped,
                        observed != 0 ? observed : nil,
                        FetchCoverage(
                            serverRecordCount: batch.count,
                            spansEntireFolder: false,
                            unmaterialisedIds: Self.unmaterialisedIds(raw: infos, mapped: mapped))
                    )
                }

                windowDays *= 2
            }

            // Every widened window came back empty: the server named nothing at
            // all, which is honest coverage of zero records — not "unproven".
            return ([], nil, FetchCoverage(
                serverRecordCount: 0, spansEntireFolder: false, unmaterialisedIds: []))
        }
    }

    // MARK: - UID Resolution

    /// Search the currently selected mailbox for a message by its RFC 2822 Message-ID.
    /// Single point of resolution — all Message-ID lookups MUST use this method.
    /// Tries with angle brackets first (iCloud and other strict-match servers require them),
    /// then bare value for servers that do RFC 3501 substring matching.
    private func searchByMessageId(_ messageId: String, server: IMAPServer) async throws -> UIDSet {
        let normalizedId = EmailFilter.normalizeMessageId(messageId)
        if DebugModeManager.isLoggingEnabled() { print("[IMAP] searchByMessageId — searching for '\(normalizedId)'") }
        var ext: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [.header("Message-ID", "<\(normalizedId)>")])
        var results: UIDSet = ext.asSet
        if results.isEmpty {
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] searchByMessageId — bracket search empty, trying bare") }
            ext = try await server.extendedSearch(criteria: [.header("Message-ID", normalizedId)])
            results = ext.asSet
        }
        if DebugModeManager.isLoggingEnabled() { print("[IMAP] searchByMessageId — '\(normalizedId)' → \(results.isEmpty ? "NOT FOUND" : "\(results.count) UIDs")") }
        return results
    }

    // MARK: - Helpers

    /// Convert an IMAP MessageInfo to our MessageHeaderInfo.
    /// Returns nil if the message cannot be trusted — e.g., both INTERNALDATE and
    /// ENVELOPE date are missing/unparseable. Such messages are treated as fetch
    /// failures: if the date is broken, other fields are likely broken too. Next
    /// fetch cycle will retry — by then the server should have indexed the message.
    private func mapMessageInfo(_ info: MessageInfo) -> MessageHeaderInfo? {
        // Shared parser — same From-header handling as Gmail/Graph/future NSE
        // IMAP. Returns ("name", "email") for "Name <email>", ("addr", "addr")
        // for bare addresses.
        let from = info.from.map { EmailAddress.parse($0) }
            ?? EmailAddress(name: "Unknown", email: "")
        let fromName = from.name
        let fromAddr = from.email

        // Prefer INTERNALDATE (server delivery time) over ENVELOPE date (sender's Date: header).
        // ENVELOPE date can be wrong due to sender clock skew, mailing list delays, or timezone issues.
        let date: Date
        if let internalDate = info.internalDate {
            date = internalDate
        } else if let parsed = info.date {
            date = parsed
        } else {
            // Both date sources failed — treat as fetch failure. The message is likely
            // still being indexed by the server (happens right after APPEND). Skipping
            // here means it never enters GRDB with a broken 1970 date. Next sync retries.
            if DebugModeManager.isLoggingEnabled() { print("[IMAP] Date parse failed for message: \(info.subject ?? "unknown") (id: \(info.messageId?.description ?? "?")) — treating as fetch failure, will retry") }
            return nil
        }

        // Action tags are local-only (ADR-IOS-036): MessageAICache + Device
        // Sync probe. We no longer resolve ActionTag from IMAP keywords.
        // Legacy tm_* keywords on already-on-server messages are ignored by
        // the user-label filter below (see `UserLabelStore.isExcludedKeyword`).
        let tag: ActionTag? = nil

        // Extract user label keywords from custom flags (non-tm_*, non-standard)
        var userLabelKeywords: [String] = []
        for flag in info.flags {
            if case .custom(let keyword) = flag {
                if !UserLabelStore.isExcludedKeyword(keyword) {
                    userLabelKeywords.append(keyword.lowercased())
                }
            }
        }

        let subject = info.subject ?? "(no subject)"
        // `messageId` + `rfc822MessageId` go through the shared
        // `IMAPFetchMapping` helper so NSE's one-shot fetch and this sync
        // path produce byte-identical output for the same `MessageInfo`.
        // Prior to the 2026-04-19 fix NSE had its own inline copy that
        // diverged — duplicate iCloud inbox rows were the visible symptom.
        let rfc822MessageId = IMAPFetchMapping.rfc822MessageId(from: info)
        let inReplyTo = info.inReplyTo.map { EmailFilter.normalizeMessageId("\($0.localPart)@\($0.domain)") }
        let references = info.references?.map { "\($0.localPart)@\($0.domain)" }

        return MessageHeaderInfo(
            messageId: IMAPFetchMapping.messageIdString(from: info),
            rfc822MessageId: rfc822MessageId,
            inReplyTo: inReplyTo,
            references: references ?? [],
            threadId: nil,
            subject: subject,
            from: fromName,
            fromAddress: fromAddr,
            to: info.to.joined(separator: ", "),
            cc: info.cc.joined(separator: ", "),
            bcc: info.bcc.joined(separator: ", "),
            replyTo: nil,
            date: date,
            snippet: "",
            isRead: info.flags.contains(.seen),
            isFlagged: info.flags.contains(.flagged),
            hasAttachments: info.parts.contains { part in
                let ct = part.contentType.lowercased()
                let disposition = part.disposition?.lowercased()
                let hasFilename = !(part.filename?.isEmpty ?? true)
                let isExplicitAttachment = disposition == "attachment"
                let hasFileNotInline = hasFilename && disposition != "inline"
                let isCalendar = ct.hasPrefix("text/calendar")
                return isExplicitAttachment || hasFileNotInline || isCalendar
            },
            isReplied: info.flags.contains(.answered),
            isForwarded: info.flags.contains(.custom("$Forwarded")),
            actionTag: tag,
            userLabelIds: userLabelKeywords,
            // IOS-IMAP-001 / D3. Until this line the mapping read `.seen`,
            // `.flagged`, `.answered` and `$Forwarded` and never looked at
            // `.deleted` at all, so a source copy left `\Deleted`-but-present by a
            // move on a server without UIDPLUS was ingested as an ordinary
            // message and re-listed in the Inbox once the ~30s `recentlyCompleted`
            // and `pendingDestructiveIds` protections expired. Repeating the
            // gesture then seated a SECOND destination copy and soft-deleted an
            // already-soft-deleted source — a gesture-driven duplication loop.
            //
            // Surfacing the flag is all this provider does. It issues NO wire
            // operation for it: the mailbox-wide `EXPUNGE` shipped `v1.6.38`
            // reached is FORBIDDEN, and the `COPYUID`-gated source expunge's
            // evidence is never widened. The decision to hide is the merge's
            // (`SyncEngine.selectStaleHeaders` + `runSyncMessages`).
            isDeletedOnServer: info.flags.contains(.deleted)
        )
    }


    private func mapRole(_ attributes: Mailbox.Info.Attributes, name: String) -> FolderRole {
        IMAPProvider.mapRole(attributes: attributes, name: name)
    }

    /// Canonical name lists for name-based role detection (lowercased).
    /// Order matters: index 0 is the preferred canonical name and wins
    /// dedup tiebreaks (e.g., "Trash" beats "Deleted Messages" on iCloud).
    static let canonicalNames: [FolderRole: [String]] = [
        .inbox:   ["inbox"],
        .sent:    ["sent", "sent messages", "sent items", "sent mail"],
        .drafts:  ["drafts", "draft"],
        .trash:   ["trash", "deleted messages", "deleted items", "bin"],
        .archive: ["archive", "archives", "all mail"],
        .spam:    ["junk", "spam", "junk e-mail", "bulk mail"]
    ]

    /// Pure mapping function — exposed for tests + the role-dedup pass.
    static func mapRole(attributes: Mailbox.Info.Attributes, name: String) -> FolderRole {
        // Check IMAP special-use attributes first (RFC 6154)
        if attributes.contains(.inbox) { return .inbox }
        if attributes.contains(.sent) { return .sent }
        if attributes.contains(.drafts) { return .drafts }
        if attributes.contains(.trash) { return .trash }
        if attributes.contains(.archive) { return .archive }
        if attributes.contains(.junk) { return .spam }

        // Name-based fallback — many servers don't return special-use flags without RETURN (SPECIAL-USE)
        let lower = name.lowercased()
        for (role, names) in canonicalNames where names.contains(lower) {
            return role
        }
        return .custom
    }

    /// Returns the IMAP SPECIAL-USE attribute that corresponds to a role,
    /// or nil for `.custom` / `.inbox` (inbox uses a separate attribute).
    static func attributeForRole(_ role: FolderRole) -> Mailbox.Info.Attributes? {
        switch role {
        case .inbox:   return .inbox
        case .sent:    return .sent
        case .drafts:  return .drafts
        case .trash:   return .trash
        case .archive: return .archive
        case .spam:    return .junk
        case .custom:  return nil
        }
    }

    /// Lower index = more canonical name for the role. Returns Int.max
    /// when the name is not in the list — so unknown names lose tiebreaks.
    static func canonicalNameRank(_ name: String, role: FolderRole) -> Int {
        let lower = name.lowercased()
        guard let names = canonicalNames[role],
              let idx = names.firstIndex(of: lower) else { return .max }
        return idx
    }

    /// Picks one folder per role when multiple folders were assigned the same
    /// role (e.g., iCloud exposes both "Trash" and "Deleted Messages"). Returns
    /// the deduped list — losers are demoted to `.custom`. `.custom` and `.inbox`
    /// are passed through unchanged (multiple inboxes don't occur on real IMAP).
    static func dedupRoles(
        _ folders: [(info: FolderInfo, attributes: Mailbox.Info.Attributes)]
    ) -> [FolderInfo] {
        let grouped = Dictionary(grouping: folders.indices, by: { folders[$0].info.role })
        var demoted: Set<Int> = []

        for (role, indices) in grouped where indices.count > 1 && role != .custom {
            // Winner ranking — lower tuple wins:
            //   1. Has the SPECIAL-USE attribute (false=0 < true=1, so invert)
            //   2. Lower canonical-name rank
            //   3. Shorter name (stable, deterministic)
            let attr = attributeForRole(role)
            let winner = indices.min { a, b in
                let fa = folders[a]
                let fb = folders[b]
                let aHasAttr = attr.map { fa.attributes.contains($0) } ?? false
                let bHasAttr = attr.map { fb.attributes.contains($0) } ?? false
                if aHasAttr != bHasAttr { return aHasAttr }
                let aRank = canonicalNameRank(fa.info.name, role: role)
                let bRank = canonicalNameRank(fb.info.name, role: role)
                if aRank != bRank { return aRank < bRank }
                return fa.info.name.count < fb.info.name.count
            }!
            for i in indices where i != winner {
                demoted.insert(i)
                if DebugModeManager.isLoggingEnabled() { print("[IMAP:dedup] role=\(role) collision — demoting \"\(folders[i].info.name)\" to .custom; winner=\"\(folders[winner].info.name)\"") }
            }
        }

        return folders.enumerated().map { idx, pair in
            if demoted.contains(idx) {
                var info = pair.info
                info.role = .custom
                return info
            }
            return pair.info
        }
    }

    // MARK: - IMAP → shared EmlMarker adapters
    //
    // These thin wrappers adapt SwiftMail `MessageInfo` to `EmlMarker.Envelope`
    // so the actual HTML/text shapes live in one place (`Shared/Rendering/EmlMarker.swift`),
    // shared with Gmail and Exchange. Callers and tests keep the familiar names.

    static let embeddedDateFormatter = EmlMarker.dateFormatter

    static func embeddedHeadersHtml(_ info: MessageInfo, filename: String?) -> String {
        let envelope = EmlMarker.Envelope(
            subject: info.subject, from: info.from, date: info.date,
            to: info.to, cc: info.cc
        )
        return EmlMarker.embeddedHeadersHtml(envelope: envelope, filename: filename)
    }

    static func embeddedHeadersPlainText(_ info: MessageInfo, filename: String?) -> String {
        let envelope = EmlMarker.Envelope(
            subject: info.subject, from: info.from, date: info.date,
            to: info.to, cc: info.cc
        )
        return EmlMarker.embeddedHeadersPlainText(envelope: envelope, filename: filename)
    }

    static func extractBodyContent(from html: String) -> String {
        EmlMarker.extractBodyContent(from: html)
    }

    static func escapeHtml(_ string: String) -> String {
        EmlMarker.escapeHtml(string)
    }
}
