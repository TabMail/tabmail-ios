/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// T0.8 — the provider-id durable action queue's ADVERSARIAL fuzz suite
/// (global `CLAUDE.md` Testing Rule 11; acceptance gate
/// `PLAN_IOS_REFACTOR_V3.md` §6.3). **SCAFFOLD.** It is wired, seeded,
/// reproducible and provably able to fail today; the invariant set it carries
/// is the subset that is assertable against the code as it exists on `v3`
/// RIGHT NOW.
///
/// ## Provenance — what is ported and from where (RULE R0)
/// Structure is ported from the two reference fuzzers named in the T0.8 row:
/// - `v2final:TabMailTests/Services/UIDValidityPipelineFuzzTests.swift` (777
///   lines) — the Tier-2 *system* fuzzer. Ported: the `FuzzConfig`
///   seeds/replay/iteration-knob shape (`:109-131`), the per-round
///   fixture/restore pair (`:135-196`), the `rfc822`/`makeHeader` fixture
///   builders (`:219-247`), `drainProviderQueue` (`:249-259` — see the T0.5
///   note below), the single-shot-plus-repeatable `planSteps` shape
///   (`:348-368`), the `RoundIdentities`/`RoundHeaders` split (`:372-391`),
///   the `performStep` dispatch (`:398-535`), the spawn-with-jitter loop and
///   the closing ledger/oracle/convergence assertion block (`:749-763`).
/// - `v2final:TabMailTests/Providers/IMAPProviderPoolFuzzTests.swift` (1,151
///   lines) — the Tier-1 *pool* fuzzer. Ported: `ChaosScheduler` verbatim
///   (`:541-571`, including its 80% / three-branch park distribution), the
///   uniform "same closure at every contract-enumerated boundary" hook
///   installation (`:978-990`), seeded per-command latency injection
///   (`:881`), the seeded op START SPREAD (`:1042-1053`), the injected
///   LOGIN-limit failure with its real error shape (`:770-777`), and the
///   `persistServerLimit` cleanup `defer` (`:866-869`).
///
/// Everything that has no counterpart in either reference is flagged in place
/// as `⚑ NO REFERENCE — INVENTED`. There are three, all consequences of the
/// scaffold being keying-agnostic; each carries its reason.
///
/// ## ⛔ WHAT THIS SUITE DELIBERATELY DOES **NOT** ASSERT
/// **The drop property is NOT in the invariant set** — nothing here asserts
/// that an op whose folder epoch moved is dropped. That is `T2.6`'s property
/// and the code cannot satisfy it yet: `v3` durable ops are still RFC-KEYED
/// (`MessageHeader.stableId`, `MessageHeader.swift:203-212`, is what every
/// enqueue site writes into `PendingOperation.messageIds` —
/// `AccountManagerActions.swift:88`, `:97`, `:255`, …), and `stableId` prefers
/// `rfc822MessageId` *precisely because it survives UIDVALIDITY changes*.
/// Asserting the destination behaviour here is what got the sibling item
/// `T0.7` REJECTED: it passed vacuously. Two corollaries this suite obeys:
/// 1. There is **no epoch-reset / renumber step** in the operation mix at all.
///    That dimension belongs to `T0.7`/`T0.9`, which are re-sequenced to run
///    after `T2.6`/`T2.7`.
/// 2. **Queue-absence is never read as evidence of a drop.** Absence cannot
///    discriminate *dropped* from *executed* — a successful execution deletes
///    the row too (`AccountManagerQueue.swift`, `PendingOperation.deleteOne`
///    on the success path). The only sound discriminator is ZERO PROVIDER I/O,
///    and that assertion belongs to `T2.6`. The convergence check below reads
///    an empty queue as "the round settled", never as "something was dropped";
///    the *ledger* is what has to account for every intention, and it does so
///    against a SERVER-side end state, not against the queue.
///
/// The ledger's `ACCEPTED-ID-RESET-DROP` disposition is still legal — the
/// ledger may record it. What is absent is any assertion *requiring* a drop.
/// No intention recorded here supplies an `IdResetDropWitness`, so none can
/// settle that way today; the vocabulary is simply left intact for `T0.9`.
///
/// ## Invariants checked EVERY round (machine-checkable only — never an
/// expected-value assertion on a specific schedule)
/// (a) **The T0.2 wrong-message wire oracle is clean.**
///     `server.wrongMessageViolations()` must be empty. This is the one hard
///     invariant (owner constraint C3): *never mutate the wrong message*.
///     Sharpened here at zero production cost by seeding every round's INBOX
///     with `FuzzConfig.bystanderCount` messages that are never gestured on
///     and never registered via `expectMutations` — any mutating command that
///     lands on one is a violation by construction. (The oracle's allowlist is
///     round-wide, not per-intention — a known limitation recorded in the
///     plan's T0.7 callout; the allowlist is registered by
///     `FakeIMAPServer.expectMutations` and read by its `recordOracleCheck`.
///     Invariant (b)'s
///     per-intention SERVER-side end state is what covers the residual: if
///     gesture X's mutation landed on gesture Y's message, X's own end state
///     is false and X settles `.unaccounted`.)
/// (b) **The T0.3 `IntentionLedger` accounts for every intention.** Every
///     gesture settles into an accepted disposition — `EXECUTED` /
///     `REPORTED-REFUSED` / `PROVABLE-NOOP` / `ACCEPTED-ID-RESET-DROP` — never
///     `UNACCOUNTED`, which is a never-drop violation
///     (`CLAUDE.md`, "Never Drop User Intention"). Every end-state predicate
///     here reads the FAKE SERVER, not the local row: the local write is
///     optimistic and lands before any provider I/O, so a DB-sourced predicate
///     would be true even for an intention that never reached the wire.
/// (c) **End-state convergence.** After the bounded drain barrier the durable
///     queue is empty — the round reached a settled state rather than leaving
///     unfinished work whose absence a later round would inherit.
///
/// `.reportedRefused` is unreachable end-to-end until `T4.V8` builds the
/// production refusal channel (plan T0.3 constraint 3), so `settle` is handed
/// an EMPTY reported-id set. That is honest, not a gap: with no channel, a
/// refusal cannot be reported, and an intention that vanishes without one must
/// fail the ledger.
///
/// ## Adversarial, not merely random (Testing Rule 11's three layers)
/// (a) **Seeded fault + latency injection.** `setSeededLatencyInjection`
///     stretches every command's RTT (weighted to LOGIN/SELECT/NOOP —
///     `FakeIMAPServer.latencyChancePercent`), so the await windows the queue's
///     failure legs live in become routinely reachable instead of a
///     microsecond lottery. Three faults are injected:
///     1. `killConnectionOnNextCommand` — a real dead transport.
///     2. An injected LOGIN connection-limit `NO`.
///     3. `returnEmptySearch(forMessageId:resolutionCount:)` — a `UID SEARCH`
///        that SUCCEEDS and resolves to zero UIDs, the sole producer of
///        `ProviderError.uidResolutionFailed` (thrown in
///        `IMAPProvider.resolveUID` — the one throw site in the app target).
///        This is the queue's IDENTITY-RESOLUTION phase, and it is fuzzed here
///        because that error carries a DEDICATED retry budget
///        (`PendingOperation.uidResolutionRetryCount`, capped at
///        `SyncConfig.maxUidResolutionRetries`) which makes a bounded run of
///        misses RECOVERABLE, hence accountable: the op is requeued
///        (`AccountManager.executeSingleOp`'s non-move `uidResolutionFailed`
///        leg), a later drain resolves it, and
///        the intention settles `EXECUTED` against the fake server's real end
///        state. See `Step.injectEmptySearchResolution` for the accounting and
///        for the ONE gesture that is excluded from it.
///
///        The fault's unit is a whole RESOLUTION, not a `UID SEARCH` command —
///        see the seam's own doc comment for why that distinction decides
///        whether this suite's non-vacuity guard means anything.
///
///     ⚠️ CORRECTION (this file's own prior claims, both FALSE, were the T0.8
///     blocker). The superseded text asserted (i) that faults on `UID SEARCH`
///     "make a live message look gone and drive the remote-state-wins drop
///     legs", and (ii) that "the drain classifies these via
///     `SyncEngine.isConnectionError`". Neither holds:
///     - `killConnectionOnNextCommand` closes the socket BEFORE
///       `handleCommand` runs (`FakeIMAPServer.swift`'s pre-dispatch failure
///       check), so it yields a transient TRANSPORT error and can never
///       produce an empty result. The feared outcome was unreachable via the
///       fault the exclusion named — the stated reason did not hold.
///     - `SyncEngine.isConnectionError` does not appear in
///       `AccountManagerQueue.swift` at all. The drain's generic trailing
///       catch requeues whatever the earlier permanent/drop legs did not
///       match; it never consults that classifier.
///     What survives of the old exclusion is much narrower and is stated at
///     its real site (`Step.injectEmptySearchResolution`): only the `.move`
///     op's resolution-failure leg lacks an accepted ledger disposition, and
///     only that one gesture is held back.
/// (b) **PCT-style seeded parking** — one identical `chaos.point()` closure
///     installed on every await/resume boundary the pool contract enumerates
///     on `v3` today: the action-connection checkout
///     (`IMAPProvider.withActionConnectionSelection`), the folder-connection
///     checkout (`withFolderConnection`), and the folder-connection
///     single-flight creation window (`createFolderConnection`). Per the
///     reference's own coordinator-corrected reading, the "no bespoke hooks"
///     rule forbids scenario CONSTRUCTION, not the physical boundary — an
///     identical seeded coin flip at every boundary is generic PCT
///     infrastructure. `v3` exposes exactly these three (T0.6(a) ported 17 of
///     the reference's 74 seam members); the rest arrive with `T3.7`, and this
///     suite picks them up for free when they do.
/// (c) **Plain yield jitter** — the seeded per-step START SPREAD plus
///     `chaos.point()`'s yield branch.
///
/// ## Seed / replay / iteration knobs
/// - **Seeds**: `FuzzConfig.seeds`, a fixed checked-in list run on every
///   `xcodebuild test`. Every operation SEQUENCE is drawn from a seeded
///   `SplitMix64` (declared once at file scope in
///   `InboxComposeScenarioTests.swift`, reused rather than redeclared). The
///   real thread SCHEDULE is deliberately not pinned — the seed pins the
///   operation sequence, not the interleaving.
/// - **Replay**: `QUEUE_FUZZ_REPLAY_SEED=0x…` runs only that seed. Every
///   failure message embeds its seed in `0x…` hex. ⚠️ On the CLI the working
///   form is the `TEST_RUNNER_` prefix — a bare env var does not reach the
///   simulator-hosted test process:
///   `TEST_RUNNER_QUEUE_FUZZ_REPLAY_SEED=0x… xcodebuild test-without-building …`
///   (reference caveat, `IMAPProviderPoolFuzzTests.swift:137-152`).
/// - **Soak**: `QUEUE_FUZZ_ROUNDS` / `QUEUE_FUZZ_STEPS`. The checked-in
///   defaults are sized for every-commit CI; crank these for a soak.
///
/// ## Acceptance-gate status
/// §6.3's FREE acceptance defect — the OPEN Tier-2 never-drop violation, seed
/// `0x5157000000000001`, a label-apply attributed to the wrong UID after a
/// renumber — is a RENUMBER-class defect. This scaffold has no renumber step
/// (see the ⛔ block above), so that gate is **not** claimed here and stays
/// open against `T0.7`, which owns the renumber dimension. What IS proven now
/// is that the scaffold is a detector rather than a green-always control: both
/// oracles were driven red against deliberately injected production defects
/// (recorded in `PLAN_IOS_REFACTOR_V3.md` §0.0 for T0.8), then restored.
///
/// `.processGlobalState` is REQUIRED, not decorative: this suite swaps
/// `AppDatabase.shared` and mutates `AccountManager.shared`'s provider
/// registry and overlay. `.serialized` alone orders tests only INSIDE one
/// suite (`ProcessGlobalTestState.swift:8-14`) — the plan's 🔒 rule.
@Suite("Provider-id durable queue fuzzer — Testing Rule 11 (T0.8 scaffold)", .serialized, .processGlobalState)
@MainActor
struct ProviderIdQueueFuzzTests {

    // MARK: - Config

    /// Ported from `v2final:…/UIDValidityPipelineFuzzTests.swift:109-131` and
    /// `…/IMAPProviderPoolFuzzTests.swift:243-286`. Every tunable lives here
    /// rather than inline at its use site (repo rule: no hardcoded numeric
    /// values — use a per-module config).
    enum FuzzConfig {
        /// Fixed seeds run in the default (bounded) suite pass.
        /// `QUEUE_FUZZ_REPLAY_SEED` overrides the WHOLE list with one seed.
        /// The `0x70D8…` prefix tags this suite (T0.8) the way the references
        /// tag theirs (`0x5157…` tier 2, `0xFA22…` tier 1) — deliberately NOT
        /// reusing `0x5157000000000001`, whose finding is a renumber-class
        /// defect this scaffold has no step for (see the type's doc comment).
        static var seeds: [UInt64] {
            if let raw = ProcessInfo.processInfo.environment["QUEUE_FUZZ_REPLAY_SEED"], let v = parseSeed(raw) {
                return [v]
            }
            return [0x70D8_0000_0000_0001, 0x70D8_0000_0000_0002]
        }

        /// Seeded rounds per seed. `QUEUE_FUZZ_ROUNDS` overrides for soak runs.
        static var rounds: Int {
            if let raw = ProcessInfo.processInfo.environment["QUEUE_FUZZ_ROUNDS"], let v = Int(raw), v > 0 { return v }
            return 2
        }

        /// Steps planned per round (the four single-shot gestures are always
        /// appended on top, so a round never has fewer than four intentions).
        /// `QUEUE_FUZZ_STEPS` overrides.
        static var stepsPerRound: Int {
            if let raw = ProcessInfo.processInfo.environment["QUEUE_FUZZ_STEPS"], let v = Int(raw), v > 0 { return v }
            return 8
        }

        /// Bound on every injected per-command delay. Small on purpose: the
        /// whole default pass has to stay inside an every-commit CI budget
        /// (reference: `setSeededLatencyInjection`'s own doc comment).
        static let latencyMaxMilliseconds = 12

        /// Seeded op START SPREAD, in ms. The reference's decisive knob: with
        /// every step firing at t=0, the fast steps (teardowns especially) all
        /// COMPLETE before any step with a real-latency runway reaches its
        /// interesting window, so the contract's mid-op windows are
        /// structurally unreachable by collision.
        static let startSpreadMs = 60

        /// Unregistered decoys seeded into INBOX every round — see invariant
        /// (a). They exist purely so the oracle has something to catch.
        static let bystanderCount = 3

        /// Whole EMPTY RESOLUTIONS one `.injectEmptySearchResolution` arm buys.
        /// The seam's unit is a RESOLUTION, not a `UID SEARCH` command:
        /// `IMAPProvider.searchByMessageId` issues the bracketed form and then
        /// the bare form, and `FakeIMAPServer` spends the credit only on the
        /// bare half — so one credit is exactly one whole empty resolution,
        /// indivisible by a teardown landing between the two commands. That
        /// indivisibility is what lets the non-vacuity assertion below be sound
        /// rather than probabilistic; the previous command-counting shape could
        /// spend two commands across two different attempts and fail no
        /// resolution at all.
        ///
        /// ⚠ One credit is NOT "exactly one thrown
        /// `ProviderError.uidResolutionFailed`", as this comment previously
        /// claimed. `resolveUID` is the only throw site but not
        /// `searchByMessageId`'s only caller — `move`'s destination probe,
        /// `currentUIDs`, `appendToSentFolder` and the draft-save legs all read
        /// empty as an ordinary answer. Consumption therefore BOUNDS the throws
        /// from above, which is why the post-round audit joins the wire and
        /// durable sides by identity and asserts an inequality per message
        /// rather than an equality.
        static let emptySearchResolutionsPerArm = 1

        /// Resolution failures a single message may be dealt in one round.
        ///
        /// DERIVED from the production budget rather than written as a literal,
        /// so the two can never drift: the drain drops the op on the failure
        /// that finds `uidResolutionRetryCount >= SyncConfig
        /// .maxUidResolutionRetries` (the drop guard in
        /// `AccountManager.executeSingleOp`'s non-move `uidResolutionFailed`
        /// leg) — i.e. the (budget + 1)-th. Staying one below the budget leaves
        /// a whole failure of headroom, so no legal schedule can tip a gesture
        /// into the drop leg this suite deliberately excludes. The headroom is
        /// exact, not hopeful: ONLY that leg touches this counter (its
        /// `uidResolutionRetryCount += 1`), while ordinary connection blips bump
        /// the separate `retryCount` in the same function's generic transient
        /// branch, so an unrelated fault cannot consume it.
        ///
        /// Cited by SYMBOL: the three line numbers this paragraph used to carry
        /// (`:591`, `:603`, `:661`) were each off by one against
        /// `AccountManagerQueue.swift` at the time they were written.
        ///
        /// **This is an UPPER BOUND on the injected pressure, not an equality**
        /// — the previous wording claimed the opposite ("the exact value the
        /// counter can reach … the post-round audit asserts that equality
        /// holds") and the audit never asserted any equality: it rejects
        /// `newCount > cap` and nothing else. Two legal schedules keep an
        /// admitted arm from ever becoming an increment: the freely-scheduled
        /// second arm can land AFTER its single-shot gesture has already
        /// settled, and a consumed credit can be spent by a `searchByMessageId`
        /// caller that is not `resolveUID` and therefore never throws. So
        /// admitted ≥ consumed ≥ incremented, and only the last two are joined
        /// tightly enough to compare. The audit below asserts the per-message
        /// bound that IS provable — increments ≤ credits actually consumed on
        /// the wire for that same message — plus this cap as the headroom check
        /// it always was.
        static var maxEmptySearchResolutionsPerMessage: Int {
            max(1, SyncConfig.maxUidResolutionRetries - 1)
        }

        /// Drain-barrier bound (`drainProviderQueue`). Ported verbatim from
        /// the reference's `0..<300` / 10ms.
        static let drainPollAttempts = 300
        static let drainPollIntervalMs = 10

        private static func parseSeed(_ raw: String) -> UInt64? {
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
                return UInt64(raw.dropFirst(2), radix: 16)
            }
            return UInt64(raw) ?? UInt64(raw, radix: 16)
        }
    }

    // MARK: - Adversarial layer (b): chaos-point scheduler

    /// Verbatim port of `v2final:TabMailTests/Providers/IMAPProviderPoolFuzzTests
    /// .swift:541-571` — a seeded, PCT-style ("priority change point")
    /// scheduling perturbation installed UNIFORMLY on every
    /// contract-enumerated race boundary. One seeded coin flip, one shared park
    /// distribution, zero per-hook weighting or ordering: at each boundary the
    /// flip decides whether to park the calling task for a small random number
    /// of job-hops, a short jittered sleep, or a deliberately WIDER park long
    /// enough for a concurrent teardown/acquire to land inside a resume gap
    /// that a 0-2ms jitter would usually miss.
    private final class ChaosScheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var rng: SplitMix64
        init(seed: UInt64) { rng = SplitMix64(seed: seed) }

        private func roll(_ bound: Int) -> Int {
            lock.lock(); defer { lock.unlock() }; return rng.pick(bound)
        }

        func point() async {
            guard roll(100) < 80 else { return }
            switch roll(3) {
            case 0:
                let hops = 1 + roll(6)
                for _ in 0..<hops { await Task.yield() }
            case 1:
                let ms = roll(9) // 0...8ms
                if ms > 0 {
                    try? await Task.sleep(for: .milliseconds(ms))
                } else {
                    await Task.yield()
                }
            default:
                let ms = 12 + roll(48) // 12...59ms
                try? await Task.sleep(for: .milliseconds(ms))
            }
        }
    }

    // MARK: - Step model

    /// One randomized step. The four gestures are SINGLE-SHOT (each fires at
    /// most once per round: repeating `markRead` on an already-read message
    /// degrades into a no-op the ledger would have to special-case, and two
    /// gestures contending for one message would make the end state
    /// order-dependent — an expected-value-on-a-schedule assertion, which
    /// Testing Rule 11 forbids). Everything else is freely repeatable infra or
    /// fault pressure.
    ///
    /// ⚑ NO REFERENCE — INVENTED (the CASE LIST only; the enum's
    /// single-shot/repeatable SHAPE is the reference's, `…/UIDValidityPipeline
    /// FuzzTests.swift:329-341`). The reference's own list is built around the
    /// epoch-reset reaction it drives — `.epochResetTrigger`, `.undo`,
    /// `.nseMerge`, `.draftSave` — and the first of those is exactly the
    /// dimension this tier must not have (see the type's ⛔ block), while the
    /// rest reach subsystems no v3 queue invariant depends on yet. The four
    /// gestures below are the durable action queue's own op types
    /// (`OperationType.markRead` / `.markUnread` / `.markFlagged` / `.move`)
    /// as they exist on `v3`.
    private enum Step: Sendable {
        // Single-shot gestures — each records exactly one ledger intention.
        case markRead
        case markUnread
        case markFlagged
        case archive
        // Repeatable infra / adversarial pressure — record nothing.
        case syncDrain
        case folderPoolRead
        case connectionTeardownDisconnect
        case connectionTeardownMarkDirty
        case injectTransientConnectionKill
        case injectLoginLimitFailure
        /// Arms ONE successful-but-empty `UID SEARCH` against one of the three
        /// FLAG gestures — the queue's identity-resolution phase, which was
        /// entirely unfuzzed before this step existed.
        ///
        /// **Why the flag gestures are accountable.** A `resolveUID` miss on a
        /// non-move op takes `AccountManager.executeSingleOp`'s non-move
        /// `ProviderError.uidResolutionFailed` leg: while
        /// `uidResolutionRetryCount < SyncConfig.maxUidResolutionRetries` the
        /// op is written back `.queued` with the counter bumped and the lane
        /// halted — the account is explicitly NOT marked failed, so the very
        /// next drain retries it. `FuzzConfig
        /// .maxEmptySearchResolutionsPerMessage` keeps every armed run strictly
        /// inside that budget, so the message (which never actually moved) is
        /// found on a later attempt and the gesture settles `EXECUTED` against
        /// the fake server's own end state. Nothing here asserts a drop.
        ///
        /// **Why `.archive` is excluded — the ACTUAL reason.** A `.move` op has
        /// no retry budget at all. Its resolution miss takes the destination
        /// probe in the same function's `type == .move` branch, and when the
        /// message is not in the destination either — which is exactly the state
        /// an armed false negative manufactures, since the message is still
        /// sitting in INBOX — the leg is "Confirmed stale … dropping" on the
        /// FIRST miss. The op
        /// row is deleted with the move never performed, so the intention has
        /// neither an achieved end state nor (until `T4.V8` builds the refusal
        /// channel) any way to be REPORTED. The ledger has no accepted
        /// disposition for that, and `settle()` would call it `UNACCOUNTED`.
        /// The exclusion is therefore about the MOVE leg's missing
        /// disposition, not about `UID SEARCH` being unfuzzable.
        ///
        /// ⚠️ That asymmetry — three retries for a flag op, zero for a move —
        /// is production behaviour this suite only observes; it is NOT asserted
        /// either way here, and changing it is out of scope for a test file.
        case injectEmptySearchResolution
    }

    /// Ported from `…/UIDValidityPipelineFuzzTests.swift:348-368`, INCLUDING
    /// the trigger-insertion half this file previously dropped ("there is no
    /// trigger in this tier"). There is one now: the reference inserts its
    /// `.epochResetTrigger` exactly once, at a seeded random index, precisely
    /// so an adversarial event that must definitely happen still lands at an
    /// unpredictable time — the same shape `.injectEmptySearchResolution`
    /// needs. The trailing `append(contentsOf: singleShot)` is the reference's
    /// own guarantee that every gesture fires exactly once regardless of how
    /// the coin flips fell.
    private static func planSteps(_ rng: inout SplitMix64, count: Int) -> [Step] {
        var singleShot: [Step] = [.markRead, .markUnread, .markFlagged, .archive]
        let repeatable: [Step] = [
            .syncDrain, .syncDrain,
            .folderPoolRead,
            .connectionTeardownDisconnect,
            .connectionTeardownMarkDirty,
            .injectTransientConnectionKill,
            .injectLoginLimitFailure,
            .injectEmptySearchResolution,
        ]
        var steps: [Step] = []
        let plannedCount = max(count, singleShot.count)
        for _ in 0..<plannedCount {
            if !singleShot.isEmpty, rng.pick(2) == 0 {
                steps.append(singleShot.remove(at: rng.pick(singleShot.count)))
            } else {
                steps.append(repeatable[rng.pick(repeatable.count)])
            }
        }
        steps.append(contentsOf: singleShot)
        // Seeded random trigger point, ported from the reference's
        // `steps.insert(.epochResetTrigger, at: triggerIndex)`. The round-setup
        // arm (see the test body) is what makes the fault's CONSUMPTION
        // guaranteed; this second, freely-scheduled arm is what makes its
        // TIMING adversarial — it can land before, during, or after the gesture
        // it targets. Both stay inside the same per-message budget.
        let triggerIndex = steps.count >= 2 ? 1 + rng.pick(steps.count - 1) : 0
        steps.insert(.injectEmptySearchResolution, at: triggerIndex)
        return steps
    }

    /// The command fragments a `.injectTransientConnectionKill` step may aim
    /// at. Every one of them fails the in-flight command as a DEAD TRANSPORT
    /// before the fake applies any mutation (the pre-dispatch failure check in
    /// `FakeIMAPServer.handleClient` breaks the client loop before the handler
    /// runs), so the queue sees a connection error and REQUEUES — the transient
    /// leg, never a drop leg.
    ///
    /// `UID SEARCH` is absent from THIS list for a mechanical reason, not a
    /// policy one: killing the socket on a SEARCH would produce exactly what
    /// killing it on any other command produces — a transport error — which
    /// this list already covers four times over. It could not produce the
    /// empty RESULT that makes the resolution phase interesting, because
    /// `ProviderError.uidResolutionFailed` is thrown only when a search
    /// SUCCEEDS and resolves to zero UIDs (`IMAPProvider.resolveUID`).
    /// That outcome needs a different seam and now has one —
    /// `Step.injectEmptySearchResolution`, via `FakeIMAPServer
    /// .returnEmptySearch(forMessageId:resolutionCount:)`.
    private static let killFragments = ["LOGIN", "SELECT", "UID STORE", "UID MOVE"]

    // MARK: - Round identities

    private struct RoundIdentities: Sendable {
        let markReadRfc: String
        let markReadUid: Int
        let markUnreadRfc: String
        let markUnreadUid: Int
        let markFlaggedRfc: String
        let markFlaggedUid: Int
        let archiveRfc: String
        let archiveUid: Int
        /// Never gestured on, never registered with `expectMutations` — see
        /// invariant (a).
        let bystanderRfcs: [String]
        let bystanderUids: [Int]

        var gestureRfcs: [String] { [markReadRfc, markUnreadRfc, markFlaggedRfc, archiveRfc] }

        /// The gestures `.injectEmptySearchResolution` may target: the three
        /// FLAG gestures only. `archiveRfc` is excluded — that step's doc
        /// comment carries the reason (the `.move` leg drops on the FIRST miss
        /// and has no accepted ledger disposition today).
        var emptySearchFaultTargetRfcs: [String] { [markReadRfc, markUnreadRfc, markFlaggedRfc] }
    }

    private struct RoundHeaders: Sendable {
        let markRead: MessageHeader
        let markUnread: MessageHeader
        let markFlagged: MessageHeader
        let archive: MessageHeader
    }

    // MARK: - Keying seam

    /// The identity the PRODUCTION enqueue sites write into
    /// `PendingOperation.messageIds` **today**: every one of them is
    /// `msgs.map(\.stableId)` (`AccountManagerActions.swift:88`, `:97`, `:255`,
    /// `:298`, `:371`, `:376`). The ledger takes whatever string it is handed
    /// verbatim and never classifies its shape (`IntentionLedger.swift:24-28`,
    /// `:186-192`), so the suite's invariant set is keying-AGNOSTIC — this one
    /// function is the entire surface that knows what the key is.
    ///
    /// ⚑ NO REFERENCE — INVENTED. The reference had no need for it: it keys by
    /// RFC 822 Message-ID by design and passes the RFC id straight through
    /// (`…/UIDValidityPipelineFuzzTests.swift:419`, `:438`). `T2.4` re-keys
    /// those 28 production sites onto the native provider id; when it does,
    /// this function is the ONLY line in this file that changes, and none of
    /// the three invariants moves.
    private static func durableIdentity(of header: MessageHeader) -> String {
        header.stableId
    }

    // MARK: - Identity-resolution fault budget

    /// Per-round keeper of how many successful-but-empty resolutions each
    /// message has been dealt, so the fault can pressure the resolution phase
    /// without ever tipping a gesture into the drop leg
    /// (`Step.injectEmptySearchResolution`).
    ///
    /// A class holding a `Mutex` rather than a bare `Mutex`, for a mechanical
    /// reason: `Mutex` is `~Copyable`, so it cannot be captured by the escaping
    /// `Task` closures the round's steps run in. `IntentionLedger` — this
    /// suite's other shared-state helper — has the same shape for the same
    /// reason (`IntentionLedger.swift:158`), so this follows the established
    /// idiom rather than reaching for `nonisolated(unsafe)`, which repo
    /// Resilience Rule 5 forbids outright.
    private final class EmptySearchArmBudget: Sendable {
        private let dealt = Mutex<[String: Int]>([:])

        /// Admits one more resolution failure for `messageId` while this round
        /// has dealt it fewer than
        /// `FuzzConfig.maxEmptySearchResolutionsPerMessage`; returns false once
        /// the cap is reached, which is what keeps the armed run inside the
        /// production retry budget.
        func admit(_ messageId: String) -> Bool {
            dealt.withLock { counts in
                let already = counts[messageId] ?? 0
                guard already < FuzzConfig.maxEmptySearchResolutionsPerMessage else { return false }
                counts[messageId] = already + 1
                return true
            }
        }

        /// Identity → arms this round actually ADMITTED for it.
        ///
        /// The post-round audit needs this because "the identities the fault was
        /// allowed to target" and "the identities the fault was actually armed
        /// against" are different sets, and attributing a durable failure to the
        /// former proves nothing: a round may admit arms for one message and
        /// none for another, and a failure recorded against the un-armed one
        /// would still be inside the permitted set. Admitted is still only an
        /// upper bound on consumed — an arm placed after its single-shot gesture
        /// settled is never spent — so the audit compares durable increments
        /// against the WIRE's consumption, and uses this only to state which
        /// identities the round could possibly have pressured.
        func admittedTargets() -> [String: Int] {
            dealt.withLock { $0 }
        }
    }

    /// Arm ONE successful-but-empty resolution against `messageId`, subject to
    /// `budget`'s per-message cap.
    ///
    /// ⚑ NO REFERENCE — INVENTED. The reference never fuzzed identity
    /// resolution at all: its tier-2 fuzzer injects NO command-level faults
    /// whatsoever (its adversarial dimension is the epoch reset, and a renumber
    /// PRESERVES every Message-ID, so an RFC-keyed SEARCH still resolves), and
    /// its tier-1 pool fuzzer aims only at `LOGIN` and `NOOP`. Neither its
    /// `FakeIMAPServer` nor ours had a successful-but-empty SEARCH seam before
    /// this change, so there was no budget-accounting shape to port.
    private static func armEmptySearchResolution(
        messageId: String,
        server: FakeIMAPServer,
        budget: EmptySearchArmBudget
    ) {
        guard budget.admit(messageId) else { return }
        server.returnEmptySearch(
            forMessageId: messageId,
            resolutionCount: FuzzConfig.emptySearchResolutionsPerArm
        )
    }

    // MARK: - Identity-resolution failure audit (the non-vacuity proof)

    /// Test-only audit of the ONE durable side effect the drain's non-move
    /// `uidResolutionFailed` branch leaves behind: `updated
    /// .uidResolutionRetryCount += 1` followed by `save`, in
    /// `AccountManager.executeSingleOp`'s non-move `uidResolutionFailed` leg.
    ///
    /// That statement is the only writer of that column in the app target, and
    /// it is reachable only from a thrown `ProviderError.uidResolutionFailed`
    /// on a single-message NON-move op. The `.move` leg drops or falls through
    /// without touching it (the `type == .move` destination-probe branch, and
    /// the fall-through re-queue after the non-move branch), and every ordinary
    /// transient bumps the separate `retryCount` in the same function's generic
    /// connection/transient-error branch. So a recorded increment proves two
    /// things at once: a resolution genuinely failed, AND the failure reached
    /// the queue's failure path and was committed.
    ///
    /// Cited by SYMBOL. The `` `:661` `` this block carried named a COMMENT
    /// line, not the `retryCount += 1` statement it claimed — a citation this
    /// same commit had just written while rewriting others for exactly that
    /// hazard.
    ///
    /// ## Why a trigger, and not a query after the round
    ///
    /// The round drives itself to an EMPTY queue on purpose (invariant (c)), so
    /// by the time any post-round `SELECT` could run, every row carrying the
    /// evidence has been deleted by its own eventual success. Sampling during
    /// the round would be a race, and widening a sampling window to close that
    /// race is exactly the bound-widening R6 forbids. A SQLite `AFTER UPDATE`
    /// trigger fires INSIDE the drain's own write transaction and writes to a
    /// separate table, so the evidence is captured at the instant it exists and
    /// outlives the row. It is also indifferent to which connection or pool
    /// object performed the write, because it lives in the schema rather than
    /// in the test's own read path.
    ///
    /// Nothing production-side changes for this. The table and trigger are
    /// created by the test, on the test's own temporary database, after the
    /// migrator has already run — the alternative considered and rejected was a
    /// `#if DEBUG` counter inside `AccountManagerQueue`, which would have been
    /// a production edit to observe a production write that SQLite can already
    /// observe for free.
    ///
    /// ⚑ NO REFERENCE — INVENTED (RULE R0) — the MECHANISM only; the PROOF
    /// TECHNIQUE is the reference's and is followed deliberately. `v2final`
    /// proves non-vacuity two-sidedly at
    /// `v2final:TabMailTests/ViewModels/StatefulIMAPActionPipelineTests
    /// .swift:2193-2194`: a WIRE-side consumption counter
    /// (`server.consumedInjectedFailureCount() > 0` — *"sanity (SF2): the
    /// injected failure was actually consumed by the attempt"*) paired with a
    /// DURABLE per-op counter read back out of the database (`claimSeq > 0` —
    /// *"the op must have actually been attempted before this point, otherwise
    /// this assertion proves nothing about retention"*). That shape transfers
    /// directly and is what the block after the drain barrier implements. What
    /// does NOT transfer is the reference's way of READING the durable side: it
    /// asserts RETENTION, so its row is still there when it looks. This suite
    /// asserts CONVERGENCE, so the row is gone — hence the trigger. The
    /// reference never fuzzed identity resolution at all, so it has no seam of
    /// this kind to port and no counter of its own to reuse.
    private static let resolutionFailureAuditTable = "queueFuzzUidResolutionFailureAudit"

    private func installResolutionFailureAudit(pool: DatabasePool) throws {
        let table = Self.resolutionFailureAuditTable
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TABLE \(table) (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    opId TEXT NOT NULL,
                    messageIdsJSON TEXT NOT NULL,
                    newCount INTEGER NOT NULL
                )
                """)
            // Deliberately NO `OF uidResolutionRetryCount` column list: GRDB's
            // `save` writes every column, so an `UPDATE OF` trigger would also
            // fire on writes that leave the counter alone. The `WHEN` clause is
            // the precise predicate — it fires only on an actual increase, so
            // the requeue-without-bump legs cannot forge evidence.
            try db.execute(sql: """
                CREATE TRIGGER \(table)_onIncrement
                AFTER UPDATE ON \(PendingOperation.databaseTableName)
                WHEN NEW.uidResolutionRetryCount > OLD.uidResolutionRetryCount
                BEGIN
                    INSERT INTO \(table) (opId, messageIdsJSON, newCount)
                    VALUES (NEW.id, NEW.messageIdsJSON, NEW.uidResolutionRetryCount);
                END
                """)
        }
    }

    /// Every recorded increment, oldest first, as (durable identity of the op's
    /// single message, the counter value the increment produced).
    private func recordedResolutionFailures(
        pool: DatabasePool
    ) async throws -> [(durableId: String, newCount: Int)] {
        let table = Self.resolutionFailureAuditTable
        return try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT messageIdsJSON, newCount FROM \(table) ORDER BY seq")
                .map { row in
                    let json: String = row["messageIdsJSON"]
                    let newCount: Int = row["newCount"]
                    let ids = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
                    return (durableId: ids.first ?? "<unparsable: \(json)>", newCount: newCount)
                }
        }
    }

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let inbox: Folder
        let archive: Folder
    }

    /// Mirrors `…/UIDValidityPipelineFuzzTests.swift:135-169`, adapted to the
    /// `v3` fixture idiom already used by every action-driving suite here
    /// (`AccountManagerQueueDrainTests.makeTestDB`).
    private func makeFixture(accountId: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prior = current
            current = appDatabase
            return prior
        }
        var account = Account(emailAddress: "\(accountId)@example.com", displayName: "Test", provider: .imap)
        account.id = accountId
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId)
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            try inbox.insert(db)
            try archive.insert(db)
        }
        // After the migrator, before any op can be enqueued — see
        // `installResolutionFailureAudit`.
        try installResolutionFailureAudit(pool: pool)
        return Fixture(pool: pool, directory: directory, previous: previous, inbox: inbox, archive: archive)
    }

    /// Mirrors the reference's `restore` (`:171-196`). The drain paths driven
    /// here fire unstructured background Tasks that can outlive the test body,
    /// so no earlier boundary can safely close the pool —
    /// `InstalledTestDatabaseLifetime.finish` is the `v3` policy for exactly
    /// that (`TestDatabaseTeardown.swift:740-769`).
    private func restore(_ fixture: Fixture) {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous,
            pool: fixture.pool,
            directory: fixture.directory
        )
    }

    /// Ported from `…/UIDValidityPipelineFuzzTests.swift:219-235`. Dates are
    /// derived from `Date()` (repo rule: never hardcode a date in a test).
    private func rfc822(messageId: String, subject: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return [
            "From: Test Sender <sender@example.com>",
            "To: Recipient <recipient@example.com>",
            "Subject: \(subject)",
            "Date: \(formatter.string(from: Date()))",
            "Message-ID: <\(messageId)>",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Queue fuzz body.",
            "",
        ].joined(separator: "\r\n")
    }

    /// Ported from `…/UIDValidityPipelineFuzzTests.swift:237-247`.
    private func makeHeader(folder: Folder, uid: Int, rfc822MessageId: String, subject: String) -> MessageHeader {
        var header = MessageHeader(
            messageId: String(uid), subject: subject, from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com", date: Date(),
            snippet: "body", folderId: folder.id, accountId: folder.accountId,
            folderPath: folder.path, isInInbox: true
        )
        header.headerComplete = true
        header.rfc822MessageId = rfc822MessageId
        return header
    }

    /// **VERBATIM port** of `v2final:TabMailTests/Services/
    /// UIDValidityPipelineFuzzTests.swift:249-259` — the only deviation is that
    /// the two loop constants moved into `FuzzConfig` (repo rule: no hardcoded
    /// numeric values), with the reference's own values.
    ///
    /// 🔒 T0.5 ACCEPTANCE CONDITION — do not hand-adapt this. The barrier
    /// samples BOTH halves of its predicate FIRST and only asks for a drain
    /// when `isQuiescent && !isEmpty`. The inverse ordering (drain, then look)
    /// is the self-re-arm bug the reference fixed in `f214c704a`: every poll
    /// would land on `drainPendingQueue()`'s `guard !isDraining else {
    /// needsRedrain = true }` (`AccountManagerQueue.swift:155-158`) and the
    /// barrier would keep its own re-arm alive forever. It terminates under a
    /// reaper redrive because the loop is bounded and the predicate it waits on
    /// is queue-emptiness, which a redrive can only advance. If this ever
    /// flakes, root-cause it — do NOT widen the bound, raise a timeout, or add
    /// retries.
    private func drainProviderQueue(pool: DatabasePool) async throws {
        for _ in 0..<FuzzConfig.drainPollAttempts {
            let isEmpty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            if isQuiescent && !isEmpty {
                await AccountManager.shared.drainPendingQueue()
            }
            try await Task.sleep(for: .milliseconds(FuzzConfig.drainPollIntervalMs))
        }
    }

    // MARK: - Step execution

    /// Runs ONE step. Ported from `…/UIDValidityPipelineFuzzTests.swift:398-535`.
    /// Throws only propagate a genuine setup failure — a gesture's own
    /// refusal/no-op path is never an error, it settles through the ledger.
    private func performStep(
        _ step: Step,
        archiveFolder: Folder,
        server: FakeIMAPServer, provider: IMAPProvider,
        ledger: IntentionLedger, ids: RoundIdentities, headers: RoundHeaders,
        rng: SeededDraw, round: Int, emptySearchBudget: EmptySearchArmBudget
    ) async {
        switch step {
        case .markRead:
            await AccountManager.shared.markRead([headers.markRead])
            ledger.record(
                label: "[round \(round)] markRead",
                durableIdentity: Self.durableIdentity(of: headers.markRead),
                reportIdentity: headers.markRead.id,
                endStateAchieved: { _ in
                    server.flags(in: "INBOX", rfc822MessageId: ids.markReadRfc)?.contains("\\Seen") == true
                }
            )

        case .markUnread:
            await AccountManager.shared.markUnread([headers.markUnread])
            ledger.record(
                label: "[round \(round)] markUnread",
                durableIdentity: Self.durableIdentity(of: headers.markUnread),
                reportIdentity: headers.markUnread.id,
                endStateAchieved: { _ in
                    // `.map` rather than `?.contains(…) == false`: a message
                    // that is not in INBOX at all yields `nil`, and "absent"
                    // must NOT read as "successfully marked unread".
                    server.flags(in: "INBOX", rfc822MessageId: ids.markUnreadRfc)
                        .map { !$0.contains("\\Seen") } == true
                }
            )

        case .markFlagged:
            await AccountManager.shared.markFlagged([headers.markFlagged], flagged: true)
            ledger.record(
                label: "[round \(round)] markFlagged",
                durableIdentity: Self.durableIdentity(of: headers.markFlagged),
                reportIdentity: headers.markFlagged.id,
                endStateAchieved: { _ in
                    server.flags(in: "INBOX", rfc822MessageId: ids.markFlaggedRfc)?.contains("\\Flagged") == true
                }
            )

        case .archive:
            await AccountManager.shared.archive([headers.archive])
            let destination = archiveFolder.path
            ledger.record(
                label: "[round \(round)] archive (move → \(destination))",
                durableIdentity: Self.durableIdentity(of: headers.archive),
                reportIdentity: headers.archive.id,
                endStateAchieved: { _ in
                    let brackets = CharacterSet(charactersIn: "<>")
                    return server.messageIDs(in: destination).contains {
                        $0.trimmingCharacters(in: brackets) == ids.archiveRfc
                    }
                }
            )

        case .syncDrain:
            await AccountManager.shared.drainPendingQueue()

        case .folderPoolRead:
            // Drives the FOLDER pool (a different lane from the action pool the
            // gestures use), so both chaos boundaries are live concurrently.
            _ = try? await provider.fetchMessages(folder: "INBOX", limit: 5, offset: 0)

        case .connectionTeardownDisconnect:
            try? await provider.disconnect()

        case .connectionTeardownMarkDirty:
            await provider.markDirty()

        case .injectTransientConnectionKill:
            server.killConnectionOnNextCommand(
                containing: Self.killFragments[rng.pick(Self.killFragments.count)]
            )

        case .injectLoginLimitFailure:
            // The real limit-error shape `IMAPProvider.parseAndApplyServerLimit`
            // parses — pushes connection creation into its limit branch
            // organically rather than via a bespoke pause hook (reference:
            // `IMAPProviderPoolFuzzTests.swift:770-777`).
            server.failNextCommand(
                containing: "LOGIN",
                message: "[UNAVAILABLE] Maximum number of connections from user+IP exceeded (mail_max_userip_connections=3)"
            )

        case .injectEmptySearchResolution:
            // Target drawn at FIRE time, not plan time — same reasoning as
            // `.injectTransientConnectionKill`'s fragment draw: a target chosen
            // 60ms earlier would correlate the fault with the plan rather than
            // with the live schedule.
            let targets = ids.emptySearchFaultTargetRfcs
            Self.armEmptySearchResolution(
                messageId: targets[rng.pick(targets.count)],
                server: server,
                budget: emptySearchBudget
            )
        }
    }

    /// Thread-safe seeded draw for values a spawned step needs AFTER the round's
    /// planning RNG has been consumed on the main planning path. Same lock+RNG
    /// shape as `ChaosScheduler`, so a replayed seed draws the same values.
    ///
    /// ⚑ NO REFERENCE — INVENTED. The reference draws every step-local value on
    /// the planning path before spawning (`…/UIDValidityPipelineFuzzTests
    /// .swift:679-681`) because its post-trigger steps need only one jitter
    /// each. This suite's `.injectTransientConnectionKill` needs a draw at the
    /// moment it fires — arming a fragment chosen 60ms earlier would correlate
    /// the fault with the plan rather than with the live schedule.
    private final class SeededDraw: @unchecked Sendable {
        private let lock = NSLock()
        private var rng: SplitMix64
        init(seed: UInt64) { rng = SplitMix64(seed: seed) }
        func pick(_ bound: Int) -> Int {
            lock.lock(); defer { lock.unlock() }; return rng.pick(bound)
        }
    }

    // MARK: - The fuzz test

    @Test(
        "T0.8 scaffold: seeded adversarial interleavings of durable-queue gestures + faults + pool teardowns hold the wire oracle, the intention ledger, and end-state convergence (Testing Rule 11)",
        arguments: FuzzConfig.seeds
    )
    @MainActor
    func providerIdQueueFuzz(seed: UInt64) async throws {
        let seedHex = "0x" + String(seed, radix: 16)
        var rng = SplitMix64(seed: seed)
        let chaos = ChaosScheduler(seed: seed ^ 0x9E37_79B9_7F4A_7C15)
        let draw = SeededDraw(seed: seed ^ 0xD1CE_D1CE_D1CE_D1CE)

        for round in 0..<FuzzConfig.rounds {
            let suffix = "\(String(seed, radix: 16))-r\(round)"
            let accountId = "queuefuzz-\(suffix)-\(UUID().uuidString)"
            let uidBase = 20_000 + rng.pick(60_000)

            var bystanderRfcs: [String] = []
            var bystanderUids: [Int] = []
            for index in 0..<FuzzConfig.bystanderCount {
                bystanderRfcs.append("queuefuzz-bystander-\(index)-\(UUID().uuidString)@example.com")
                bystanderUids.append(uidBase + 100 + index)
            }
            let ids = RoundIdentities(
                markReadRfc: "queuefuzz-markread-\(UUID().uuidString)@example.com", markReadUid: uidBase + 1,
                markUnreadRfc: "queuefuzz-markunread-\(UUID().uuidString)@example.com", markUnreadUid: uidBase + 2,
                markFlaggedRfc: "queuefuzz-markflagged-\(UUID().uuidString)@example.com", markFlaggedUid: uidBase + 3,
                archiveRfc: "queuefuzz-archive-\(UUID().uuidString)@example.com", archiveUid: uidBase + 4,
                bystanderRfcs: bystanderRfcs, bystanderUids: bystanderUids
            )

            var inboxMessages: [FakeIMAPServer.Message] = [
                FakeIMAPServer.makeMessage(uid: ids.markReadUid, rfc822Text: rfc822(messageId: ids.markReadRfc, subject: "Mark read")),
                FakeIMAPServer.makeMessage(uid: ids.markUnreadUid, rfc822Text: rfc822(messageId: ids.markUnreadRfc, subject: "Mark unread")),
                FakeIMAPServer.makeMessage(uid: ids.markFlaggedUid, rfc822Text: rfc822(messageId: ids.markFlaggedRfc, subject: "Mark flagged")),
                FakeIMAPServer.makeMessage(uid: ids.archiveUid, rfc822Text: rfc822(messageId: ids.archiveRfc, subject: "Archive")),
            ]
            for (index, rfc) in ids.bystanderRfcs.enumerated() {
                inboxMessages.append(
                    FakeIMAPServer.makeMessage(uid: ids.bystanderUids[index], rfc822Text: rfc822(messageId: rfc, subject: "Bystander \(index)"))
                )
            }

            let username = "queuefuzz-\(suffix)"
            let host = "127.0.0.1"
            let server = FakeIMAPServer(username: username, mailboxes: ["INBOX": inboxMessages, "Archive": []])
            // `.markUnread`'s target must START seen, or its intention is a
            // no-op the server can satisfy without ever being asked.
            server.setFlags(["\\Seen"], in: "INBOX", uid: ids.markUnreadUid)
            try server.start()
            defer { server.stop() }
            server.setSeededLatencyInjection(
                seed: seed ^ UInt64(round &+ 1),
                maxMilliseconds: FuzzConfig.latencyMaxMilliseconds
            )
            // ONLY the four gesture targets. The bystanders stay unregistered on
            // purpose — invariant (a).
            server.expectMutations(ids.gestureRfcs)

            // Identity-resolution fault, arm 1 of 2. This one is placed BEFORE
            // any step is spawned, which is what makes its consumption
            // GUARANTEED rather than schedule-dependent: the targeted gesture
            // always fires (single-shot), its op cannot resolve before the
            // round starts, and the drain barrier below does not return until
            // the queue is empty — so the armed resolution is necessarily
            // served. Its credit is indivisible (the fake spends it on the bare
            // half of the pair, so a teardown landing mid-pair leaves it intact
            // rather than stranding a half), which is what makes the
            // non-vacuity assertions after the barrier sound rather than
            // flaky. The freely-scheduled second arm lives in `planSteps`.
            let emptySearchBudget = EmptySearchArmBudget()
            let emptySearchTargets = ids.emptySearchFaultTargetRfcs
            Self.armEmptySearchResolution(
                messageId: emptySearchTargets[rng.pick(emptySearchTargets.count)],
                server: server,
                budget: emptySearchBudget
            )

            let fixture = try makeFixture(accountId: accountId)
            defer { restore(fixture) }
            // `.injectLoginLimitFailure` makes the provider persist a server
            // limit under a (host, username)-keyed default. Harmless if left —
            // the username is seed+round unique and nothing else reads it — but
            // tidy (reference: `IMAPProviderPoolFuzzTests.swift:866-869`).
            defer {
                UserDefaults.standard.removeObject(
                    forKey: IMAPProvider.serverLimitDefaultsKey(host: host, username: username)
                )
            }

            let provider = IMAPProvider(
                host: host, port: server.port, username: username, password: server.password,
                smtpHost: host, smtpPort: 587, useTLS: false
            )
            try await provider.connect()

            // Adversarial layer (b): the SAME uniform seeded closure on every
            // await/resume boundary the pool contract enumerates on `v3`.
            await provider.setActionConnectionTestHookForTesting { [chaos] in await chaos.point() }
            await provider.setFolderConnectionTestHookForTesting { [chaos] _ in await chaos.point() }
            await provider.setCreateFolderConnectionCreationTestHookForTesting { [chaos] in await chaos.point() }

            let ledger = IntentionLedger()

            let markReadHeader = makeHeader(folder: fixture.inbox, uid: ids.markReadUid, rfc822MessageId: ids.markReadRfc, subject: "Mark read")
            var markUnreadHeader = makeHeader(folder: fixture.inbox, uid: ids.markUnreadUid, rfc822MessageId: ids.markUnreadRfc, subject: "Mark unread")
            markUnreadHeader.isRead = true
            let markFlaggedHeader = makeHeader(folder: fixture.inbox, uid: ids.markFlaggedUid, rfc822MessageId: ids.markFlaggedRfc, subject: "Mark flagged")
            let archiveHeader = makeHeader(folder: fixture.inbox, uid: ids.archiveUid, rfc822MessageId: ids.archiveRfc, subject: "Archive")
            let insertable = [markReadHeader, markUnreadHeader, markFlaggedHeader, archiveHeader]
            try await fixture.pool.writeWithoutTransaction { db in
                for header in insertable { try header.insert(db) }
            }
            let headers = RoundHeaders(
                markRead: markReadHeader, markUnread: markUnreadHeader,
                markFlagged: markFlaggedHeader, archive: archiveHeader
            )

            await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)

            let steps = Self.planSteps(&rng, count: FuzzConfig.stepsPerRound)
            var spawned: [Task<Void, Never>] = []
            for step in steps {
                // Adversarial layer (c): seeded START SPREAD — without it every
                // step fires at t=0 and the fast ones complete before any step
                // with a real-latency runway reaches its interesting window.
                let startDelayMs = rng.pick(FuzzConfig.startSpreadMs)
                spawned.append(Task { [archiveFolder = fixture.archive] in
                    if startDelayMs > 0 {
                        try? await Task.sleep(for: .milliseconds(startDelayMs))
                    } else {
                        await Task.yield()
                    }
                    await self.performStep(
                        step, archiveFolder: archiveFolder,
                        server: server, provider: provider,
                        ledger: ledger, ids: ids, headers: headers,
                        rng: draw, round: round, emptySearchBudget: emptySearchBudget
                    )
                })
            }
            for task in spawned { await task.value }

            // Convergence. Two bounded barrier passes, mirroring the
            // reference's drain → backstop → drain ordering (`:737-745`): a
            // teardown step racing the first drain can leave an op requeued
            // behind `DrainContext.failedAccounts`, which is per-drain state,
            // so the second pass is what lets that account run again.
            try await drainProviderQueue(pool: fixture.pool)
            try await drainProviderQueue(pool: fixture.pool)

            // ---- Invariant (b): the intention ledger accounts for everything.
            // Empty `reportedIds`: `v3` has no production refusal channel until
            // T4.V8, so nothing can honestly be reported as refused.
            let outcomes = await ledger.settle(pool: fixture.pool, reportedIds: [])
            #expect(
                outcomes.count == ledger.recordedCount,
                "\(seedHex) round \(round): setup sanity — settle() must return one outcome per recorded intention"
            )
            #expect(
                outcomes.count == ids.gestureRfcs.count,
                "\(seedHex) round \(round): setup sanity — every single-shot gesture must have fired exactly once (got \(outcomes.count))"
            )

            // ---- Non-vacuity: the identity-resolution FAILURE PATH really ran.
            //
            // Two-sided, both sides load-bearing, and — the part an earlier
            // revision left out — JOINED BY IDENTITY. The reference's SF2 shape,
            // quoted in `installResolutionFailureAudit`. Neither half is a proof
            // on its own, and the pair is not a proof either unless both halves
            // name the same message:
            //
            //  * The WIRE side proves the fake served a whole empty resolution.
            //    It cannot prove the drain reacted to it.
            //  * The DURABLE side proves the drain's non-move
            //    `uidResolutionFailed` branch executed and COMMITTED its
            //    counter bump. Nothing else in the app target writes that
            //    column, and the round's other two faults (a killed socket, an
            //    injected LOGIN `NO`) are transport errors that take the
            //    generic branch and bump the SEPARATE `retryCount`, so they
            //    cannot forge it.
            //  * The JOIN is what turns "both numbers are non-zero" into "the
            //    durable failure belongs to the message whose empty resolution
            //    was armed". Previously the wire figure was a single aggregate
            //    carrying no identity at all, and the durable rows — which DO
            //    carry identity — were checked against the three ARMABLE
            //    identities rather than the ones actually armed and consumed.
            //    Neither comparison could distinguish the intended case from a
            //    round that pressured one message and failed a different one.
            //
            // ⚠ This replaced a guard that counted `UID SEARCH` COMMANDS and
            // claimed the count proved a resolution had failed. It did not: a
            // resolution is a bracketed-then-bare PAIR, so two consumed
            // commands are one failed resolution only if they belonged to the
            // same attempt. A teardown landing between them split the pair, a
            // later attempt spent the leftover on its own bracketed half and
            // then succeeded on its bare half, and the guard greened with ZERO
            // resolutions failed and `uidResolutionFailed` never thrown — the
            // exact vacuous-assertion trap this suite exists to avoid. The
            // seam is now resolution-granular (the credit is spent on the bare
            // half only), which removes that schedule; the assertion below no
            // longer depends on it having been removed.
            //
            // Soundness of the floor, not a tuned threshold: the guaranteed
            // setup arm is placed before any step spawns, its target gesture is
            // single-shot and always fires, the op cannot resolve before the
            // round starts, one credit is indivisible, and the barrier does not
            // return until the queue is empty. So at least one whole armed
            // resolution is necessarily served AND necessarily observed by the
            // drain.
            // ⚠ THE HALVES MUST BE JOINED BY IDENTITY. An aggregate wire count
            // paired with a durable failure recorded against *some* message
            // establishes only that each number is non-zero. It does NOT
            // establish "the durable failure belongs to the message whose empty
            // resolution was armed" — the sentence this block exists to prove.
            // A round that armed message A, served A's resolution, and recorded
            // a failure against B for an unrelated reason would satisfy both
            // one-sided halves and satisfy an attribution check written against
            // the three ARMABLE identities (B is armable; it was simply never
            // armed). Both sides are therefore read PER MESSAGE-ID and the
            // comparison is made on the same key.
            let consumedByIdentity = server.consumedEmptySearchResolutions()
            let servedEmptyResolutions = consumedByIdentity.values.reduce(0, +)
            #expect(
                servedEmptyResolutions >= FuzzConfig.emptySearchResolutionsPerArm,
                "\(seedHex) round \(round): no whole empty-SEARCH resolution was ever served on the wire (served \(servedEmptyResolutions)) — the identity-resolution dimension was not exercised"
            )
            // The keyed map and the aggregate counter are written in the same
            // locked mutation, so a divergence means the seam itself is broken.
            #expect(
                servedEmptyResolutions == server.consumedEmptySearchResolutionCount(),
                "\(seedHex) round \(round): the fake's keyed and aggregate empty-resolution counters disagree (\(servedEmptyResolutions) vs \(server.consumedEmptySearchResolutionCount())) — the wire seam is miscounting"
            )

            let resolutionFailures = try await recordedResolutionFailures(pool: fixture.pool)
            #expect(
                !resolutionFailures.isEmpty,
                "\(seedHex) round \(round): NO durable identity-resolution failure was recorded — \(servedEmptyResolutions) empty resolution(s) were served on the wire, but the drain's uidResolutionFailed branch never bumped uidResolutionRetryCount, so nothing in this round proves the production failure path executed"
            )

            // (1) ATTRIBUTION, against what was actually CONSUMED — not against
            // what was merely armable. Every durable increment must name a
            // message this round genuinely drove to an empty resolution on the
            // wire. `admittedTargets()` is reported in the failure message for
            // diagnosis but is deliberately NOT the comparison set: an arm can
            // be admitted and never spent (it may land after its single-shot
            // gesture has already settled), so admitted ⊋ consumed.
            let admitted = emptySearchBudget.admittedTargets()
            let consumedIdentities = Set(consumedByIdentity.keys)
            let misattributed = resolutionFailures.filter { !consumedIdentities.contains($0.durableId) }
            #expect(
                misattributed.isEmpty,
                "\(seedHex) round \(round): identity-resolution failure(s) recorded against message(s) whose resolution was never driven empty on the wire: \(misattributed.map(\.durableId)) — consumed=\(consumedByIdentity), admitted=\(admitted)"
            )

            // (2) THE JOIN ITSELF. At least one identity must appear on BOTH
            // sides. Without this the two `!isEmpty`/`>= 1` checks above can be
            // satisfied by disjoint messages, which is exactly the gap that made
            // the previous "two-sided" guard one-sided twice over.
            let failedIdentities = Set(resolutionFailures.map(\.durableId))
            #expect(
                !failedIdentities.intersection(consumedIdentities).isEmpty,
                "\(seedHex) round \(round): the wire and durable halves never named the same message — consumed \(consumedIdentities), failed \(failedIdentities). Both halves are non-empty, so each one-sided check passes, yet nothing links the drain's failure to the resolution this round actually armed"
            )

            // (3) PER-MESSAGE COUNT BOUND, replacing the bound against a
            // constant. Each durable increment for a message needs its own
            // consumed credit for that SAME message, so the highest
            // `uidResolutionRetryCount` a message reached can never exceed the
            // credits the wire spent on it. This is the tightest relation that
            // is actually provable: it is `<=` rather than `==` because a
            // consumed credit can be spent by a `searchByMessageId` caller that
            // is not `resolveUID` (`move`'s destination probe, `currentUIDs`,
            // `appendToSentFolder`, the draft-save legs) and therefore never
            // throws — see `FakeIMAPServer.consumedEmptySearchResolutionCount()`
            // caveat 2. Asserting equality here would pin a claim the system
            // does not make.
            var increments: [String: Int] = [:]
            for failure in resolutionFailures {
                increments[failure.durableId] = max(increments[failure.durableId] ?? 0, failure.newCount)
            }
            let unbacked = increments.filter { $0.value > (consumedByIdentity[$0.key] ?? 0) }
            #expect(
                unbacked.isEmpty,
                "\(seedHex) round \(round): uidResolutionRetryCount rose higher than the empty resolutions the wire actually served for that message: \(unbacked) vs consumed=\(consumedByIdentity) — an increment with no armed resolution behind it means something other than the injected fault is driving the failure path"
            )

            // (4) HEADROOM. Unchanged in force, corrected in description: this
            // is the arm budget's UPPER BOUND, never an equality (see
            // `FuzzConfig.maxEmptySearchResolutionsPerMessage`). A counter above
            // it means a gesture was walking toward the drop leg at
            // `SyncConfig.maxUidResolutionRetries` that this suite deliberately
            // excludes from its ledger.
            let overBudget = resolutionFailures.filter { $0.newCount > FuzzConfig.maxEmptySearchResolutionsPerMessage }
            #expect(
                overBudget.isEmpty,
                "\(seedHex) round \(round): uidResolutionRetryCount reached \(overBudget.map(\.newCount)) — above the per-message arm budget \(FuzzConfig.maxEmptySearchResolutionsPerMessage), i.e. a gesture was pushed toward the drop leg at SyncConfig.maxUidResolutionRetries=\(SyncConfig.maxUidResolutionRetries)"
            )

            // ---- Invariant (a): the wire oracle is clean. The ONE hard
            // invariant — never mutate the wrong message.
            let violations = server.wrongMessageViolations()
            #expect(
                violations.isEmpty,
                "\(seedHex) round \(round): wire oracle: \(violations.count) wrong-message violation(s):\n\(violations.map(\.description).joined(separator: "\n"))"
            )

            // ---- Invariant (c): end-state convergence. Read as "the round
            // settled", NEVER as evidence that anything was dropped — see the
            // type's ⛔ block.
            let remainingOps = try await fixture.pool.read { db in try PendingOperation.fetchCount(db) }
            #expect(
                remainingOps == 0,
                "\(seedHex) round \(round): \(remainingOps) durable op(s) still queued after two bounded drain passes — the round never converged"
            )

            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            await provider.setActionConnectionTestHookForTesting(nil)
            await provider.setFolderConnectionTestHookForTesting(nil)
            await provider.setCreateFolderConnectionCreationTestHookForTesting(nil)
            try? await provider.disconnect()
        }
    }
}
