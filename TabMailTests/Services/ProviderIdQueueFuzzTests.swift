/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// T0.8 — the provider-id durable action queue's ADVERSARIAL fuzz suite
/// (global `CLAUDE.md` Testing Rule 11; `PLAN_IOS_REFACTOR_V3.md` §6.3).
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
/// **SUBTRACT:** the follow-up RFC `UID SEARCH` fault/audit from `64138810f`
/// has no reachable ordinary-action subject after T2.4. The four direct IMAP
/// producers now persist native UIDs and the provider mutates that admitted
/// UID set directly; retaining an RFC-resolution oracle here would preserve a
/// parallel compatibility path the forward-port intentionally removes. The
/// separate T0.7/T0.9 reset suites own drop-on-epoch-change coverage.
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
/// ## Adversarial, not merely random (Testing Rule 11's three layers)
/// (a) **Seeded fault + latency injection.** `setSeededLatencyInjection`
///     stretches every command's RTT (weighted to LOGIN/SELECT/NOOP —
///     `FakeIMAPServer.latencyChancePercent`), so the await windows the queue's
///     failure legs live in become routinely reachable. Two transient faults
///     remain reachable without RFC identity authority:
///     1. `killConnectionOnNextCommand` — a real dead transport.
///     2. An injected LOGIN connection-limit `NO`.
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

        /// Drain-barrier bound (`drainProviderQueue`). Ported verbatim from
        /// the reference's `0..<300` / 10ms.
        static let drainPollAttempts = 300
        static let drainPollIntervalMs = 10

        /// Bounded transcript carried by a diagnostic. Commands are synthetic
        /// FakeIMAPServer traffic, but keeping the tail small makes a rare
        /// failure readable and keeps one slow round from flooding the log.
        static let diagnosticCommandTailCount = 40

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
    }

    /// Ported from `…/UIDValidityPipelineFuzzTests.swift:348-368`. The trailing
    /// append guarantees every gesture fires exactly once regardless of the
    /// seeded repeatable-step choices.
    private static func planSteps(_ rng: inout SplitMix64, count: Int) -> [Step] {
        var singleShot: [Step] = [.markRead, .markUnread, .markFlagged, .archive]
        let repeatable: [Step] = [
            .syncDrain, .syncDrain,
            .folderPoolRead,
            .connectionTeardownDisconnect,
            .connectionTeardownMarkDirty,
            .injectTransientConnectionKill,
            .injectLoginLimitFailure,
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
        return steps
    }

    /// The command fragments a `.injectTransientConnectionKill` step may aim
    /// at. Every one of them fails the in-flight command as a DEAD TRANSPORT
    /// before the fake applies any mutation (the pre-dispatch failure check in
    /// `FakeIMAPServer.handleClient` breaks the client loop before the handler
    /// runs), so the queue sees a connection error and REQUEUES — the transient
    /// leg, never a drop leg.
    ///
    /// ⚠ CORRECTED (GitHub #115). This list carried `UID COPY` only, under a
    /// comment claiming T3.15 had removed the atomic route for good.
    /// `dd51c74ff` (2026-08-08) restored it: `IMAPProvider.move` issues one
    /// `UID MOVE` whenever the server advertises `MOVE`, which this suite's
    /// default-capability fake does — so the transient-kill step could never
    /// target the move at all, and the #115 drop surfaced only because a
    /// `.connectionTeardownDisconnect` happened to land in the SELECT→MOVE
    /// window. `UID COPY` stays for the owned COPY/STORE/EXPUNGE route, which
    /// is reached only when a fixture strips `MOVE` from the capabilities
    /// (none here does today).
    private static let killFragments = ["LOGIN", "SELECT", "UID STORE", "UID COPY", "UID MOVE"]

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
    }

    private struct RoundHeaders: Sendable {
        let markRead: MessageHeader
        let markUnread: MessageHeader
        let markFlagged: MessageHeader
        let archive: MessageHeader
    }

    /// T2.4 direct ordinary producers persist the source provider ID, not
    /// `stableId` (which prefers RFC identity). The ledger must watch the same
    /// durable key the production op carries.
    private static func durableIdentity(of header: MessageHeader) -> String {
        header.messageId
    }

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let inbox: Folder
        let archive: Folder
    }

    /// Sanitized durable-queue state captured only after a bounded drain has
    /// failed to converge. Every identity in this suite is synthetic.
    private struct PendingOperationDiagnostic: Sendable, CustomStringConvertible {
        let type: OperationType
        let status: String
        let retryCount: Int
        let everAttempted: Bool
        let messageIds: [String]
        let sourceFolder: String
        let destinationFolder: String?

        init(_ operation: PendingOperation) {
            type = operation.type
            status = operation.status
            retryCount = operation.retryCount
            everAttempted = operation.everAttempted
            messageIds = operation.messageIds
            sourceFolder = operation.folderPath
            destinationFolder = operation.destinationPath
        }

        var description: String {
            "type=\(type.rawValue) status=\(status) retryCount=\(retryCount) "
                + "everAttempted=\(everAttempted) ids=\(messageIds) "
                + "source=\(sourceFolder) destination=\(destinationFolder ?? "nil")"
        }
    }

    private struct DrainTimeoutDiagnostic: Sendable, CustomStringConvertible {
        let operations: [PendingOperationDiagnostic]
        let isQuiescent: Bool
        let commandTail: [String]

        var description: String {
            let operationDump = operations.isEmpty
                ? "  <no durable operations>"
                : operations.map { "  - \($0)" }.joined(separator: "\n")
            let commandDump = commandTail.isEmpty
                ? "  <no fake-server commands>"
                : commandTail.map { "  - \($0)" }.joined(separator: "\n")
            return """
            Provider-id queue fuzzer drain timed out: quiescent=\(isQuiescent), operations=\(operations.count)
            Queue snapshot:
            \(operationDump)
            Final \(FuzzConfig.diagnosticCommandTailCount) fake-server commands (or fewer):
            \(commandDump)
            """
        }
    }

    private enum HarnessDiagnostic: Error, CustomStringConvertible {
        case drainTimeout(DrainTimeoutDiagnostic)

        var description: String {
            switch self {
            case .drainTimeout(let diagnostic): diagnostic.description
            }
        }
    }

    private struct CapturedIssue: Sendable {
        let message: String
        let sourceLocation: Testing.SourceLocation
    }

    /// Intercepts the ledger's one generic issue so the fuzzer can publish one
    /// enriched issue rather than a generic issue plus a second diagnostic.
    private final class IssueRecorder: Sendable {
        private let storage = Mutex<[CapturedIssue]>([])

        var issues: [CapturedIssue] { storage.withLock { $0 } }

        var sink: IntentionLedger.IssueSink {
            { message, sourceLocation in
                self.storage.withLock {
                    $0.append(CapturedIssue(message: message, sourceLocation: sourceLocation))
                }
            }
        }
    }

    private final class ArchiveAdmissionTrace: Sendable {
        private let storage = Mutex<RoleMoveDisposition?>(nil)

        var disposition: RoleMoveDisposition? { storage.withLock { $0 } }

        func record(_ disposition: RoleMoveDisposition?) {
            storage.withLock { $0 = disposition }
        }
    }

    private struct RoundSettlement {
        let outcomes: [(label: String, outcome: IntentionLedger.Outcome)]
        let reportedDiagnostic: Bool
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
        // This fuzzer explores a post-first-sync IMAP folder. T2.4 admission
        // requires both the Folder's live epoch and the exact source observation
        // carried by each header; `makeHeader` stamps the latter from this value.
        var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        inbox.lastKnownUidValidity = 1 // FakeIMAPServer's default live epoch.
        var archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId)
        archive.lastKnownUidValidity = 1
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            try inbox.insert(db)
            try archive.insert(db)
        }
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
        header.observedUidValidity = folder.lastKnownUidValidity
        return header
    }

    /// The loop and empty/quiescent predicate are ported verbatim from
    /// `v2final:TabMailTests/Services/UIDValidityPipelineFuzzTests.swift:249-259`.
    /// The two loop constants live in `FuzzConfig`, and this fuzzer adds a
    /// typed, bounded diagnostic when that unchanged loop expires.
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
    private func drainProviderQueue(
        pool: DatabasePool,
        recordedCommands: @Sendable () -> [String],
        attempts: Int = FuzzConfig.drainPollAttempts,
        intervalMilliseconds: Int = FuzzConfig.drainPollIntervalMs
    ) async throws {
        for _ in 0..<attempts {
            let isEmpty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            if isQuiescent && !isEmpty {
                await AccountManager.shared.drainPendingQueue()
            }
            if intervalMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(intervalMilliseconds))
            } else {
                await Task.yield()
            }
        }

        let operations = try await pool.read { db in
            try PendingOperation.fetchAll(db).map(PendingOperationDiagnostic.init)
        }
        let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
        throw HarnessDiagnostic.drainTimeout(DrainTimeoutDiagnostic(
            operations: operations,
            isQuiescent: isQuiescent,
            commandTail: Array(recordedCommands().suffix(FuzzConfig.diagnosticCommandTailCount))
        ))
    }

    private nonisolated static func recordIssue(
        _ message: String,
        at sourceLocation: Testing.SourceLocation
    ) {
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }

    /// Provider registration, escaped-drain containment, chaos-hook removal,
    /// and disconnect are one awaited lifetime. The first body/cleanup error is
    /// preserved so a drain diagnostic is never replaced by teardown noise.
    private func withProviderLifetime(
        accountId: String,
        provider: any EmailProvider,
        imapProvider: IMAPProvider?,
        pool: DatabasePool,
        _ body: () async throws -> Void
    ) async throws {
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
            var firstError: (any Error)?
            do {
                try await body()
            } catch {
                firstError = error
            }

            do {
                try await EscapedDrainTransport.awaitPendingQueueSettled(pool: pool)
            } catch {
                if firstError == nil { firstError = error }
            }

            if let imapProvider {
                await imapProvider.setActionConnectionTestHookForTesting(nil)
                await imapProvider.setFolderConnectionTestHookForTesting(nil)
                await imapProvider.setCreateFolderConnectionCreationTestHookForTesting(nil)
            }
            do {
                try await provider.disconnect()
            } catch {
                if firstError == nil { firstError = error }
            }

            if let firstError { throw firstError }
        }
    }

    private func queueEvidence(
        pool: DatabasePool,
        server: FakeIMAPServer,
        archiveFolder: Folder,
        ids: RoundIdentities,
        admission: RoleMoveDisposition?
    ) async -> String {
        let operations = (try? await pool.read { db in
            try PendingOperation.fetchAll(db).map(PendingOperationDiagnostic.init)
        }) ?? []
        let operationDump = operations.isEmpty
            ? "<empty>"
            : operations.map(\.description).joined(separator: " | ")
        let brackets = CharacterSet(charactersIn: "<>")
        let sourceContainsArchive = server.messageIDs(in: "INBOX").contains {
            $0.trimmingCharacters(in: brackets) == ids.archiveRfc
        }
        let destinationContainsArchive = server.messageIDs(in: archiveFolder.path).contains {
            $0.trimmingCharacters(in: brackets) == ids.archiveRfc
        }
        let commands = Array(
            server.recordedCommands().suffix(FuzzConfig.diagnosticCommandTailCount)
        )
        return """
        admission=\(admission?.rawValue ?? "missing") queue=[\(operationDump)] \
        archiveSourcePresent=\(sourceContainsArchive) \
        archiveDestinationPresent=\(destinationContainsArchive) \
        finalCommands=\(commands)
        """
    }

    /// The admission receipt is evaluated before the ledger. If archive was
    /// not durably admitted, the generic post-admission oracle is inapplicable
    /// and the exact existing disposition is the single published diagnostic.
    /// Otherwise the ledger's generic issue is captured and enriched once.
    private func settleRound(
        ledger: IntentionLedger,
        ledgerIssues: IssueRecorder,
        admission: RoleMoveDisposition?,
        pool: DatabasePool,
        server: FakeIMAPServer,
        archiveFolder: Folder,
        ids: RoundIdentities,
        reportedIds: Set<String>,
        sourceLocation: Testing.SourceLocation = #_sourceLocation,
        issueSink: @escaping IntentionLedger.IssueSink = Self.recordIssue
    ) async -> RoundSettlement {
        guard admission == .durablyAdmitted else {
            let evidence = await queueEvidence(
                pool: pool, server: server, archiveFolder: archiveFolder,
                ids: ids, admission: admission)
            issueSink(
                "Provider-id queue fuzzer archive admission was not durable: \(evidence)",
                sourceLocation)
            return RoundSettlement(outcomes: [], reportedDiagnostic: true)
        }

        let outcomes = await ledger.settle(
            pool: pool, reportedIds: reportedIds, sourceLocation: sourceLocation)
        let captured = ledgerIssues.issues
        guard !captured.isEmpty else {
            return RoundSettlement(outcomes: outcomes, reportedDiagnostic: false)
        }

        let evidence = await queueEvidence(
            pool: pool, server: server, archiveFolder: archiveFolder,
            ids: ids, admission: admission)
        let generic = captured.map(\.message).joined(separator: "\n")
        issueSink(
            "Provider-id queue fuzzer converged but the intention ledger failed:\n\(generic)\n\(evidence)",
            captured[0].sourceLocation)
        return RoundSettlement(outcomes: outcomes, reportedDiagnostic: true)
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
        archiveAdmission: ArchiveAdmissionTrace,
        rng: SeededDraw, round: Int
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
            let admission = await AccountManager.shared.archive([headers.archive])
            archiveAdmission.record(admission.disposition(for: headers.archive.id))
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

            let ledgerIssues = IssueRecorder()
            let ledger = IntentionLedger(escalate: ledgerIssues.sink)
            let archiveAdmission = ArchiveAdmissionTrace()

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

            try await withProviderLifetime(
                accountId: accountId, provider: provider,
                imapProvider: provider, pool: fixture.pool
            ) {
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
                            archiveAdmission: archiveAdmission,
                            rng: draw, round: round
                        )
                    })
                }
                for task in spawned { await task.value }

                // Convergence. Two bounded barrier passes, mirroring the
                // reference's drain → backstop → drain ordering (`:737-745`): a
                // teardown step racing the first drain can leave an op requeued
                // behind `DrainContext.failedAccounts`, which is per-drain state,
                // so the second pass is what lets that account run again.
                try await drainProviderQueue(
                    pool: fixture.pool, recordedCommands: server.recordedCommands)
                try await drainProviderQueue(
                    pool: fixture.pool, recordedCommands: server.recordedCommands)

                // ---- Invariant (b): the intention ledger accounts for everything.
                // Empty `reportedIds`: `v3` has no production refusal channel until
                // T4.V8, so nothing can honestly be reported as refused.
                let settlement = await settleRound(
                    ledger: ledger, ledgerIssues: ledgerIssues,
                    admission: archiveAdmission.disposition,
                    pool: fixture.pool, server: server,
                    archiveFolder: fixture.archive, ids: ids,
                    reportedIds: [], sourceLocation: #_sourceLocation)
                if settlement.reportedDiagnostic { return }
                let outcomes = settlement.outcomes
                #expect(
                    outcomes.count == ledger.recordedCount,
                    "\(seedHex) round \(round): setup sanity — settle() must return one outcome per recorded intention"
                )
                #expect(
                    outcomes.count == ids.gestureRfcs.count,
                    "\(seedHex) round \(round): setup sanity — every single-shot gesture must have fired exactly once (got \(outcomes.count))"
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
            }
        }
    }

    // MARK: - Diagnostic contract tests

    private func diagnosticIdentities(uidBase: Int) -> RoundIdentities {
        RoundIdentities(
            markReadRfc: "diagnostic-read-\(UUID().uuidString)@example.com",
            markReadUid: uidBase + 1,
            markUnreadRfc: "diagnostic-unread-\(UUID().uuidString)@example.com",
            markUnreadUid: uidBase + 2,
            markFlaggedRfc: "diagnostic-flag-\(UUID().uuidString)@example.com",
            markFlaggedUid: uidBase + 3,
            archiveRfc: "diagnostic-archive-\(UUID().uuidString)@example.com",
            archiveUid: uidBase + 4,
            bystanderRfcs: [], bystanderUids: [])
    }

    private func installObservableHooks(on provider: IMAPProvider) async {
        await provider.setActionConnectionTestHookForTesting {}
        await provider.setFolderConnectionTestHookForTesting { _ in }
        await provider.setCreateFolderConnectionCreationTestHookForTesting {}
    }

    private func assertIMAPTeardown(
        accountId: String,
        provider: IMAPProvider,
        server: FakeIMAPServer,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) async {
        #expect(
            await AccountManager.shared.providers[accountId] == nil,
            "provider scope returned before unregister completed",
            sourceLocation: sourceLocation)
        #expect(
            await provider.actionConnectionTestHook == nil,
            "action-connection chaos hook survived teardown",
            sourceLocation: sourceLocation)
        #expect(
            await provider.folderConnectionTestHook == nil,
            "folder-connection chaos hook survived teardown",
            sourceLocation: sourceLocation)
        #expect(
            await provider.createFolderConnectionCreationTestHook == nil,
            "folder-creation chaos hook survived teardown",
            sourceLocation: sourceLocation)
        // `provider.disconnect()` returns once the CLIENT side has closed its
        // socket. The fake server drops the fd from `loggedInFds` on its own
        // `handleClient` thread, in `closeClientFd`, when it observes that close —
        // nothing synchronises the two, so reading the count immediately is a race
        // that a loaded machine loses. Measured on a full-suite run at load average
        // ~140: `liveSessionCount()` read 1 immediately, healed to 0 after 50ms,
        // with `abandonedSessionCount() == 0` — nothing had actually been
        // abandoned, the oracle had simply looked too early.
        //
        // So wait for the transport to settle, bounded: a session that is genuinely
        // left live never heals and still fails here. This does not weaken the
        // abandoned-session invariant, which `abandonedSessionCount()` pins exactly
        // and monotonically (it never heals, by construction) for the callers that
        // assert it.
        var live = server.liveSessionCount()
        var settleWaitMs = 0
        while live != 0 && settleWaitMs < 2000 {
            try? await Task.sleep(for: .milliseconds(25))
            settleWaitMs += 25
            live = server.liveSessionCount()
        }
        #expect(
            live == 0,
            "provider disconnect left a live fake-server session unclosed after \(settleWaitMs)ms",
            sourceLocation: sourceLocation)
    }

    @Test("Drain exhaustion reports queue state and a final-40 command tail, then tears down safely")
    func drainTimeoutIsDistinctAndTeardownSafe() async throws {
        let accountId = "queuefuzz-timeout-\(UUID().uuidString)"
        let ids = diagnosticIdentities(uidBase: 31_000)
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [FakeIMAPServer.makeMessage(
                uid: ids.markReadUid,
                rfc822Text: rfc822(messageId: ids.markReadRfc, subject: "Timeout"))],
            "Archive": [],
        ])
        try server.start()
        defer { server.stop() }

        let fixture = try makeFixture(accountId: accountId)
        defer { restore(fixture) }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        await installObservableHooks(on: provider)

        // Positive control: the fake-server transcript is genuinely longer
        // than the retained suffix.
        for _ in 0...FuzzConfig.diagnosticCommandTailCount {
            _ = try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0)
        }
        #expect(server.recordedCommands().count > FuzzConfig.diagnosticCommandTailCount)

        var operation = PendingOperation(
            type: .markRead, messageIds: [String(ids.markReadUid)],
            accountId: accountId, folderPath: fixture.inbox.path,
            observedUidValidity: fixture.inbox.lastKnownUidValidity)
        operation.retryCount = 2
        let insertedOperation = operation
        try await fixture.pool.writeWithoutTransaction { db in try insertedOperation.insert(db) }
        server.killConnectionOnNextCommand(containing: "UID STORE")

        let transcriptAtDiagnostic = Mutex<[String]?>(nil)
        var captured: DrainTimeoutDiagnostic?
        do {
            try await withProviderLifetime(
                accountId: accountId, provider: provider,
                imapProvider: provider, pool: fixture.pool
            ) {
                try await drainProviderQueue(
                    pool: fixture.pool,
                    recordedCommands: {
                        let transcript = server.recordedCommands()
                        transcriptAtDiagnostic.withLock { $0 = transcript }
                        return transcript
                    },
                    attempts: 1, intervalMilliseconds: 0)
            }
            Issue.record("expected a typed drain-timeout diagnostic")
        } catch HarnessDiagnostic.drainTimeout(let diagnostic) {
            captured = diagnostic
        }

        let diagnostic = try #require(captured)
        #expect(diagnostic.operations.count == 1)
        #expect(diagnostic.operations[0].type == .markRead)
        #expect(diagnostic.operations[0].status == PendingStatus.queued.rawValue)
        #expect(diagnostic.operations[0].retryCount == 3)
        #expect(diagnostic.operations[0].everAttempted)
        #expect(diagnostic.operations[0].messageIds == [String(ids.markReadUid)])
        #expect(diagnostic.commandTail.count == FuzzConfig.diagnosticCommandTailCount)
        let operationalTranscript = try #require(
            transcriptAtDiagnostic.withLock { $0 },
            "fixture never asked the fake server for the timeout transcript")
        #expect(
            diagnostic.commandTail
                == Array(operationalTranscript.suffix(FuzzConfig.diagnosticCommandTailCount)))

        let unattempted = try await fixture.pool.read { db in
            try PendingOperation.filter(Column("everAttempted") == false).fetchCount(db)
        }
        #expect(unattempted == 0, "fixture never entered the drain claim path")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting())
        await assertIMAPTeardown(accountId: accountId, provider: provider, server: server)
    }

    @Test("A real retainedForRetry archive bypasses ledger settlement and reports its exact admission")
    func retainedArchiveGetsAnAdmissionDiagnostic() async throws {
        let accountId = "queuefuzz-admission-\(UUID().uuidString)"
        let ids = diagnosticIdentities(uidBase: 32_000)
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [FakeIMAPServer.makeMessage(
                uid: ids.archiveUid,
                rfc822Text: rfc822(messageId: ids.archiveRfc, subject: "Retained"))],
            "Archive": [],
        ])
        try server.start()
        defer { server.stop() }

        let fixture = try makeFixture(accountId: accountId)
        defer { restore(fixture) }
        try await fixture.pool.writeWithoutTransaction { db in
            _ = try Folder.deleteOne(db, key: fixture.archive.id)
        }
        let archiveHeader = makeHeader(
            folder: fixture.inbox, uid: ids.archiveUid,
            rfc822MessageId: ids.archiveRfc, subject: "Retained")
        try await fixture.pool.writeWithoutTransaction { db in try archiveHeader.insert(db) }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        await installObservableHooks(on: provider)

        let ledgerIssues = IssueRecorder()
        let ledger = IntentionLedger(escalate: ledgerIssues.sink)
        let trace = ArchiveAdmissionTrace()
        let published = IssueRecorder()
        var settlement: RoundSettlement?
        try await withProviderLifetime(
            accountId: accountId, provider: provider,
            imapProvider: provider, pool: fixture.pool
        ) {
            let admission = await AccountManager.shared.archive([archiveHeader])
            trace.record(admission.disposition(for: archiveHeader.id))
            ledger.record(
                label: "retained archive", durableIdentity: archiveHeader.messageId,
                reportIdentity: archiveHeader.id, endStateAchieved: { _ in false })
            settlement = await settleRound(
                ledger: ledger, ledgerIssues: ledgerIssues,
                admission: trace.disposition, pool: fixture.pool, server: server,
                archiveFolder: fixture.archive, ids: ids, reportedIds: [],
                issueSink: published.sink)
        }

        #expect(trace.disposition == .retainedForRetry)
        #expect(try await fixture.pool.read { db in try PendingOperation.fetchCount(db) } == 0)
        #expect(server.recordedCommands().allSatisfy { command in
            let upper = command.uppercased()
            return !upper.contains("UID COPY") && !upper.contains("UID STORE")
        })
        #expect(ledgerIssues.issues.isEmpty, "ledger settlement ran despite non-durable admission")
        #expect(settlement?.reportedDiagnostic == true)
        #expect(settlement?.outcomes.isEmpty == true)
        #expect(published.issues.count == 1)
        #expect(published.issues[0].message.contains(RoleMoveDisposition.retainedForRetry.rawValue))
        #expect(try await fixture.pool.read { db in
            try PendingOperation.filter(Column("everAttempted") == false).fetchCount(db)
        } == 0, "retained admission intentionally starts no escaped drain")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting())
        await assertIMAPTeardown(accountId: accountId, provider: provider, server: server)
    }

    @Test("A converged admitted round emits one enriched ledger issue at the captured source location")
    func ledgerFailureIsEnrichedExactlyOnce() async throws {
        let accountId = "queuefuzz-ledger-\(UUID().uuidString)"
        let ids = diagnosticIdentities(uidBase: 33_000)
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [FakeIMAPServer.makeMessage(
                uid: ids.archiveUid,
                rfc822Text: rfc822(messageId: ids.archiveRfc, subject: "Ledger"))],
            "Archive": [],
        ])
        try server.start()
        defer { server.stop() }

        let fixture = try makeFixture(accountId: accountId)
        defer { restore(fixture) }
        let archiveHeader = makeHeader(
            folder: fixture.inbox, uid: ids.archiveUid,
            rfc822MessageId: ids.archiveRfc, subject: "Ledger")
        try await fixture.pool.writeWithoutTransaction { db in try archiveHeader.insert(db) }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        await installObservableHooks(on: provider)

        let ledgerIssues = IssueRecorder()
        let ledger = IntentionLedger(escalate: ledgerIssues.sink)
        let published = IssueRecorder()
        let expectedLocation: Testing.SourceLocation = #_sourceLocation
        var settlement: RoundSettlement?
        try await withProviderLifetime(
            accountId: accountId, provider: provider,
            imapProvider: provider, pool: fixture.pool
        ) {
            let admission = await AccountManager.shared.archive([archiveHeader])
            let disposition = admission.disposition(for: archiveHeader.id)
            #expect(disposition == .durablyAdmitted, "fixture never admitted the archive")
            try await drainProviderQueue(
                pool: fixture.pool, recordedCommands: server.recordedCommands)
            try await drainProviderQueue(
                pool: fixture.pool, recordedCommands: server.recordedCommands)
            #expect(try await fixture.pool.read { db in
                try PendingOperation.fetchCount(db)
            } == 0, "fixture did not genuinely converge")

            // Inject the exact post-admission anomaly the diagnostic path must
            // preserve; admission and drain themselves remain real.
            ledger.record(
                label: "injected unaccounted archive",
                durableIdentity: archiveHeader.messageId,
                reportIdentity: archiveHeader.id,
                endStateAchieved: { _ in false })
            settlement = await settleRound(
                ledger: ledger, ledgerIssues: ledgerIssues,
                admission: disposition, pool: fixture.pool, server: server,
                archiveFolder: fixture.archive, ids: ids, reportedIds: [],
                sourceLocation: expectedLocation, issueSink: published.sink)
        }

        let result = try #require(settlement)
        #expect(result.reportedDiagnostic)
        #expect(result.outcomes.count == 1)
        #expect(result.outcomes[0].outcome.isFailure)
        #expect(ledgerIssues.issues.count == 1, "ledger must emit one captured generic issue")
        #expect(published.issues.count == 1, "generic + enriched issues must not both be published")
        let issue = published.issues[0]
        #expect(issue.sourceLocation.fileID == expectedLocation.fileID)
        #expect(issue.sourceLocation.line == expectedLocation.line)
        #expect(issue.message.contains("durablyAdmitted"))
        #expect(issue.message.contains("archiveSourcePresent=false"))
        #expect(issue.message.contains("archiveDestinationPresent=true"))
        #expect(issue.message.contains("finalCommands="))

        let unattempted = try await fixture.pool.read { db in
            try PendingOperation.filter(Column("everAttempted") == false).fetchCount(db)
        }
        #expect(unattempted == 0)
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting())
        await assertIMAPTeardown(accountId: accountId, provider: provider, server: server)
    }

    @Test(
        "Either epoch-reset drain diagnostic still leaves its provider lifetime settled",
        arguments: [1, 2])
    func epochResetDrainDiagnosticIsTeardownSafe(diagnosticDrain: Int) async throws {
        let accountId = "queuefuzz-epoch-exit-\(diagnosticDrain)-\(UUID().uuidString)"
        let fixture = try makeFixture(accountId: accountId)
        defer { restore(fixture) }
        let provider = MockEmailProvider()
        await provider.setMoveThrows(ProviderError.notConnected)

        do {
            try await withProviderLifetime(
                accountId: accountId, provider: provider,
                imapProvider: nil, pool: fixture.pool
            ) {
                for index in 1...2 {
                    if index == diagnosticDrain {
                        let operation = PendingOperation(
                            type: .move,
                            messageIds: [String(34_000 + diagnosticDrain)],
                            accountId: accountId, folderPath: fixture.inbox.path,
                            destinationPath: fixture.archive.path,
                            observedUidValidity: fixture.inbox.lastKnownUidValidity)
                        try await fixture.pool.writeWithoutTransaction { db in
                            try operation.insert(db)
                        }
                    }
                    try await drainProviderQueue(
                        pool: fixture.pool,
                        recordedCommands: { ["epoch-reset-drain-\(index)"] },
                        attempts: 1, intervalMilliseconds: 0)
                }
            }
            Issue.record("expected drain \(diagnosticDrain) to emit a timeout diagnostic")
        } catch HarnessDiagnostic.drainTimeout {
            // Expected: the lifetime wrapper must still finish every teardown.
        }

        #expect(await AccountManager.shared.providers[accountId] == nil)
        #expect(await provider.callLog.contains("disconnect"))
        #expect(try await fixture.pool.read { db in
            try PendingOperation.filter(Column("everAttempted") == false).fetchCount(db)
        } == 0)
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting())
    }

    // MARK: - T0.7 epoch-reset extension

    private struct RecycledDecoy: Sendable {
        let mailbox: String
        let uid: Int
        let rfc: String
        let flags: Set<String>
    }

    /// PORT of v2final `systemFuzz`'s single seeded reset trigger: snapshot
    /// every current message with flags, renumber every real message, and
    /// carry its flags forward. The added decoy at EVERY recycled old UID is
    /// the plan-recorded closure that makes a stale native UID observable to
    /// FakeIMAPServer's wire oracle rather than a vacuous absent-UID no-op.
    private func performEpochReset(
        server: FakeIMAPServer,
        mailboxes: [String],
        newEpoch: Int,
        rng: inout SplitMix64
    ) -> [RecycledDecoy] {
        let renumberBase = 700_000 + rng.pick(10_001)
        var decoys: [RecycledDecoy] = []
        var nextOffset = 0
        for mailbox in mailboxes {
            let existing = server.snapshotMessagesWithFlags(in: mailbox)
            var replacements: [FakeIMAPServer.Message] = []
            var replacementFlags: [(Int, Set<String>)] = []
            for entry in existing {
                nextOffset += 1
                let newUid = renumberBase + nextOffset
                replacements.append(entry.message.replacingUID(newUid))
                replacementFlags.append((newUid, entry.flags))

                let decoyRfc = "queuefuzz-reset-decoy-\(mailbox)-\(entry.message.uid)-\(UUID().uuidString)@example.com"
                let decoy = FakeIMAPServer.makeMessage(
                    uid: entry.message.uid,
                    rfc822Text: rfc822(messageId: decoyRfc, subject: "Recycled UID decoy"))
                let flags: Set<String> = ["\\Seen", "\\Flagged", "$Decoy"]
                replacements.append(decoy)
                replacementFlags.append((entry.message.uid, flags))
                decoys.append(RecycledDecoy(
                    mailbox: mailbox, uid: entry.message.uid, rfc: decoyRfc, flags: flags))
            }
            server.setUidValidity(newEpoch, for: mailbox)
            server.setMessages(replacements, in: mailbox)
            for (uid, flags) in replacementFlags {
                server.setFlags(flags, in: mailbox, uid: uid)
            }
        }
        return decoys
    }

    /// T0.7's minimal provider-ID reset scenario. PORT: seed/replay/reset,
    /// faithful renumber-with-flags, ledger, oracle, fixture lifetime,
    /// `.processGlobalState`, and the exact check-first drain barrier.
    /// SUBTRACT: v2final quarantine/reaction/journal/F9/demotion/recovery,
    /// labels/drafts/outbox/Undo, RFC compatibility, and resync machinery.
    /// ⚑ NO REFERENCE — INVENTED: native-UID `durableIdentity` adaptation and
    /// compact no-quarantine A/B/producer disposition mapping; the exact
    /// v2final subsystem/call-site/history census contains no provider-ID
    /// counterpart.
    @Test(
        "Provider-ID queue fuzzer drops old-epoch IMAP actions without wrong-message mutation",
        arguments: FuzzConfig.seeds)
    @MainActor
    func providerIdQueueEpochReset(seed: UInt64) async throws {
        var rng = SplitMix64(seed: seed ^ 0x5157_0000_0000_0001)
        let accountId = "queuefuzz-reset-\(String(seed, radix: 16))-\(UUID().uuidString)"
        let oldEpoch = 30_000 + rng.pick(20_000)
        let newEpoch = oldEpoch + 1 + rng.pick(1_000)
        let uidBase = 10_000 + rng.pick(20_000)

        let checkpointARfc = "queuefuzz-reset-a-\(UUID().uuidString)@example.com"
        let checkpointBRfc = "queuefuzz-reset-b-\(UUID().uuidString)@example.com"
        let producerRfc = "queuefuzz-reset-producer-\(UUID().uuidString)@example.com"
        let checkpointAUid = uidBase + 1
        let checkpointBUid = uidBase + 2
        let producerUid = uidBase + 3

        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [
                FakeIMAPServer.makeMessage(
                    uid: checkpointAUid,
                    rfc822Text: rfc822(messageId: checkpointARfc, subject: "Checkpoint A")),
                FakeIMAPServer.makeMessage(
                    uid: producerUid,
                    rfc822Text: rfc822(messageId: producerRfc, subject: "Producer refusal")),
            ],
            "Archive": [
                FakeIMAPServer.makeMessage(
                    uid: checkpointBUid,
                    rfc822Text: rfc822(messageId: checkpointBRfc, subject: "Checkpoint B")),
            ],
        ])
        server.setUidValidity(oldEpoch, for: "INBOX")
        server.setUidValidity(oldEpoch, for: "Archive")
        server.setFlags(["\\Seen"], in: "Archive", uid: checkpointBUid)
        server.expectMutations([checkpointARfc, checkpointBRfc, producerRfc])
        try server.start()
        defer { server.stop() }

        let fixture = try makeFixture(accountId: accountId)
        defer { restore(fixture) }
        var configuredInbox = fixture.inbox
        configuredInbox.lastKnownUidValidity = oldEpoch
        let inbox = configuredInbox
        var configuredArchive = fixture.archive
        configuredArchive.lastKnownUidValidity = oldEpoch
        let archive = configuredArchive
        try await fixture.pool.writeWithoutTransaction { db in
            _ = try Folder.filter(key: inbox.id)
                .updateAll(db, Column("lastKnownUidValidity").set(to: oldEpoch))
            _ = try Folder.filter(key: archive.id)
                .updateAll(db, Column("lastKnownUidValidity").set(to: oldEpoch))
        }

        let checkpointA = makeHeader(
            folder: inbox, uid: checkpointAUid,
            rfc822MessageId: checkpointARfc, subject: "Checkpoint A")
        var configuredCheckpointB = makeHeader(
            folder: archive, uid: checkpointBUid,
            rfc822MessageId: checkpointBRfc, subject: "Checkpoint B")
        configuredCheckpointB.isRead = true
        let checkpointB = configuredCheckpointB
        let producerRefusal = makeHeader(
            folder: inbox, uid: producerUid,
            rfc822MessageId: producerRfc, subject: "Producer refusal")
        try await fixture.pool.writeWithoutTransaction { db in
            try checkpointA.insert(db)
            try checkpointB.insert(db)
            try producerRefusal.insert(db)
        }

        // Admit two E1 operations while no provider is registered. The single
        // seeded reset below then separates them: INBOX is recognized as E2,
        // so checkpoint A drops its op; Archive stays DB-E1 while wire-E2, so
        // checkpoint B drops its op after live SELECT.
        await AccountManager.shared.markRead([checkpointA])
        await AccountManager.shared.markUnread([checkpointB])
        let admittedBeforeReset = try await fixture.pool.read { db in
            try PendingOperation.fetchCount(db)
        }
        #expect(admittedBeforeReset == 2, "setup: both E1 operations must be durable before the reset trigger")

        let decoys = performEpochReset(
            server: server, mailboxes: ["INBOX", "Archive"],
            newEpoch: newEpoch, rng: &rng)
        try await fixture.pool.writeWithoutTransaction { db in
            _ = try Folder.filter(key: inbox.id)
                .updateAll(db, Column("lastKnownUidValidity").set(to: newEpoch))
        }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        try await withProviderLifetime(
            accountId: accountId, provider: provider,
            imapProvider: nil, pool: fixture.pool
        ) {
            try await drainProviderQueue(
                pool: fixture.pool, recordedCommands: server.recordedCommands)

            // A fresh gesture made after the reset but from a captured E1 row is
            // refused by the producer before local mutation/admission.
            await AccountManager.shared.markFlagged([producerRefusal], flagged: true)
            try await drainProviderQueue(
                pool: fixture.pool, recordedCommands: server.recordedCommands)

            // Intention records are deliberately created AFTER the reset boundary.
            // Their witness reads the fake-server authority under its lock.
            let ledger = IntentionLedger()
            for (label, header, mailbox) in [
                ("checkpoint A", checkpointA, "INBOX"),
                ("checkpoint B", checkpointB, "Archive"),
                ("producer refusal", producerRefusal, "INBOX"),
            ] {
                ledger.record(
                    label: "\(label) seed=0x\(String(seed, radix: 16))",
                    durableIdentity: Self.durableIdentity(of: header),
                    idResetDrop: .init(
                        epochAtGesture: oldEpoch,
                        epochAtSettle: { _ in server.uidValidity(for: mailbox) }),
                    endStateAchieved: { _ in false })
            }
            let outcomes = await ledger.settle(pool: fixture.pool, reportedIds: [])
            #expect(outcomes.count == 3)
            #expect(outcomes.allSatisfy { $0.outcome == .acceptedIdResetDrop })

            let mutationCommands = server.recordedCommands().filter { command in
                let upper = command.uppercased()
                return upper.contains("UID STORE") || upper.contains("UID MOVE")
                    || upper.contains("UID COPY") || upper.contains("UID EXPUNGE")
                    || upper.hasPrefix("STORE ") || upper == "EXPUNGE"
                    || upper.hasPrefix("EXPUNGE ")
            }
            #expect(mutationCommands.isEmpty)
            #expect(server.wrongMessageViolations().isEmpty)
            #expect(
                !server.recordedCommands().contains {
                    let upper = $0.uppercased()
                    return upper.contains("SELECT") && upper.contains("INBOX")
                },
                "checkpoint A and producer refusal must terminate before selecting INBOX")
            for decoy in decoys {
                #expect(server.messageIDs(in: decoy.mailbox).contains {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) == decoy.rfc
                })
                #expect(server.flags(in: decoy.mailbox, uid: decoy.uid) == decoy.flags)
            }
            let remaining = try await fixture.pool.read { db in try PendingOperation.fetchAll(db) }
            #expect(remaining.isEmpty, "the queue must converge with no split children")
        }
    }
}

// MARK: - A3.2 — account-scoped-id lane fuzzer, Testing Rule 11
//
// Everything above this line exercises `.imap` fixtures only, and every
// planned gesture in `providerIdQueueFuzz` targets a DIFFERENT uid — so that
// fuzzer never creates an account-scoped-id account and never creates two
// cross-folder ops naming ONE provider resource. Reverting only the
// account-scoped arm of `AccountManagerQueue.buildLanes`'s `laneKey`
// (folder-qualifying it unconditionally) therefore leaves the whole suite
// above green. This extension closes that gap.
//
// ## The invariant under test
//
// `buildLanes(_:accountScopedIdAccountIds:)` keys an account whose provider id
// names ONE MESSAGE PER ACCOUNT by `"accountId:msgId"` — folder deliberately
// EXCLUDED, because such an id is folder-independent. Everything else — IMAP
// and iCloud — keys `"accountId:folderPath:msgId"`, the same folder-local key
// IMAP always used; that is the SAFE DEFAULT for a mailbox-local UID.
//
// The account-qualified side is Gmail, Outlook, and the demo account
// (`DemoSeed.demoAccountId`, stored as `.imap` but carved out the same way
// admission already does). Gmail and the demo account get ids that are also
// IMMUTABLE. Outlook does not: Microsoft Graph REALLOCATES a message's default
// id on every move (`IOS-GRAPH-002`; this tree sends no
// `Prefer: IdType="ImmutableId"`), which is why Outlook was excluded from this
// set until 2026-09-04 — account-qualifying it made an INHERITED race
// DETERMINISTIC, because a follower queued before an in-flight move was
// guaranteed to run AFTER it against the id the move had just invalidated,
// 404, and the conflict arm deleted the follower. Outlook is admitted now
// because `MessageHeaderRekey.finishMove` readdresses every queued follower
// inside the transaction that retires the move (`IOS-GRAPH-005`), so
// "runs after the move" now means "runs at the address the move PROVED".
// That is why this fuzzer alternates the provider per round: the Gmail rounds
// exercise the immutable-id shape, the Outlook rounds exercise the
// churn-plus-handoff shape, and only the second can catch a handoff regression.
//
// `IOS-QUEUE-008`: on Gmail, delete → undo → re-delete produced
// `TRASH→INBOX` and `INBOX→TRASH` on ONE message; under a uniformly
// folder-qualified key they land in different connected components,
// `drainPendingQueue` launches one Task per lane CONCURRENTLY, and the
// inverse can finish last — the deleted message reappears. See
// `AccountManagerQueueDrainTests
// .drainPendingQueueRealStableIdSameMessageOpsNeverOverlapAndRunInIssueOrder`,
// the deterministic pin this fuzzer generalizes with seeded adversarial
// scheduling and a retryable fault.
//
// ## ACCEPTANCE BAR (Testing Rule 11)
//
// With the account-scoped arm of `buildLanes`'s local `laneKey` reverted —
//     func laneKey(_ op: PendingOperation, _ id: String) -> String {
//         accountScopedIdAccountIds.contains(op.accountId)
//             ? "\(op.accountId):\(id)"
//             : "\(op.accountId):\(op.folderPath):\(id)"
//     }
// → body replaced with the unconditional `"\(op.accountId):\(op.folderPath):\(id)"`
// — `stableIdQueueLaneFuzz` must fail on its wire oracle (`overlapped` — two
// `move()` calls for one `(account, id)` observed concurrently), independent
// of scheduling luck: the two target ops land in different lanes, each lane
// is its own concurrently-launched Task, and the hook's own bounded window
// makes a genuine overlap provable rather than merely likely. The failure
// message embeds the replay seed (`seedHex`, `0x…`) and round index, exactly
// like every other assertion in this file — reproduce with
// `QUEUE_FUZZ_REPLAY_SEED=0x… xcodebuild test …` (`TEST_RUNNER_` prefix on
// the CLI; see `FuzzConfig`'s doc comment above).
extension ProviderIdQueueFuzzTests {

    // MARK: - Config

    /// Tunables for the stable-id lane fuzzer, kept separate from the
    /// IMAP-shaped `FuzzConfig` above (which this extension still reuses for
    /// `seeds`/`rounds`/`drainPollAttempts`/`drainPollIntervalMs` — same
    /// knobs, same spelling, same env vars).
    private enum StableFuzzConfig {
        /// How long the move-hook's wire oracle holds its window open after
        /// its own seeded chaos park. `ChaosScheduler.point()` is a NO-OP
        /// ~20% of the time (its `roll(100) < 80` guard), so relying on it
        /// alone would make overlap detection a matter of luck. This widens
        /// the window deterministically, mirroring
        /// `AccountManagerQueueDrainTests`'s fixed 250ms wire-oracle sleep —
        /// shorter here because at most one pair of moves is ever in flight
        /// per round (kept the default-runtime bound tight).
        static let moveOverlapWindowMs = 80
        /// Bystander count range (inclusive), seeded per round.
        static let bystanderCountMin = 2
        static let bystanderCountRange = 3 // picks 0..<3, so count is 2...4
    }

    /// A retryable fault injected on the target id's `move()` calls
    /// (Testing Rule 11(a) — fault injection). An EXPLICIT `@Test(arguments:)`
    /// dimension, not a seeded draw: the round-2 test-coverage review found
    /// both checked-in seeds drew only `.none`/`.permanentThisRound`, so the
    /// `.transientThenClears` arm never executed.
    ///
    /// Not `private`: it is a parameter type of a `@Test(arguments:)`
    /// function, and Swift requires a method to be at least as accessible as
    /// its parameter types (same as `AccountManagerQueueDrainTests.StableIdAccountCase`).
    enum StableFaultMode: Sendable {
        /// No fault this round.
        case none
        /// Armed at round start and cleared by the TEST only after the first
        /// failed attempt has been observed as DURABLE queue state
        /// (predecessor requeued with `retryCount == 1`) — never by a timer,
        /// so the failure provably manifests before the blip resolves. The
        /// round must then fully CONVERGE on re-drive.
        case transientThenClears
        /// Armed and never cleared this round — the queue must NOT drop the
        /// intention; it must retain EXACTLY the retry state the failure
        /// justifies (one attempted-and-failed op, one halted-ahead-of-it
        /// op, both still durably queued).
        case permanentThisRound
    }

    private struct StableIdFixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let inbox: Folder
        let trash: Folder
    }

    /// Mirrors `ProviderIdQueueFuzzTests.makeFixture`, parameterized by
    /// `AccountProvider` (that one hardcodes `.imap`) and by folder shape
    /// (INBOX + TRASH, the two folders a delete/undo/re-delete cycle
    /// addresses, rather than INBOX + Archive).
    private func makeStableIdFixture(accountId: String, provider: AccountProvider) throws -> StableIdFixture {
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
        var account = Account(emailAddress: "\(accountId)@example.com", displayName: "Test", provider: provider)
        account.id = accountId
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        let trash = Folder(name: "TRASH", path: "TRASH", role: .trash, accountId: accountId)
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            try inbox.insert(db)
            try trash.insert(db)
        }
        return StableIdFixture(pool: pool, directory: directory, previous: previous, inbox: inbox, trash: trash)
    }

    /// Mirrors `ProviderIdQueueFuzzTests.restore` exactly (same overlay/NSE
    /// bridge reset, same `InstalledTestDatabaseLifetime.finish` retention
    /// rationale — the drain fires unstructured background Tasks that can
    /// outlive the round, so no earlier boundary can safely close the pool).
    private func restoreStableIdFixture(_ fixture: StableIdFixture) {
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

    // MARK: - The fuzz test

    @Test(
        "A3.2: on an account-scoped-id account (Gmail and Outlook, alternating per round), cross-folder gestures on ONE message never overlap on the wire, land in createdAt order, the latest destination wins, disjoint work still converges, and a retryable fault yields exactly the retry state it justifies (Testing Rule 11)",
        arguments: FuzzConfig.seeds, [StableFaultMode.none, .transientThenClears, .permanentThisRound]
    )
    @MainActor
    func stableIdQueueLaneFuzz(seed: UInt64, faultMode: StableFaultMode) async throws {
        let seedHex = "0x" + String(seed, radix: 16)
        var rng = SplitMix64(seed: seed ^ 0xB1AB_0000_0000_0001)
        // Same class, same shape as `ProviderIdQueueFuzzTests.ChaosScheduler`
        // usage above — a distinct seed derivation only so this round's
        // parking sequence doesn't shadow the IMAP round's.
        let chaos = ChaosScheduler(seed: seed ^ 0xB1AB_79B9_7F4A_7C15)

        for round in 0..<FuzzConfig.rounds {
            // ALTERNATING, and the alternation is the point (`IOS-GRAPH-005`).
            // Both providers are now on the account-qualified side of
            // `buildLanes`, but for DIFFERENT reasons, and only one of them can
            // catch a handoff regression:
            //  * Gmail's ids are genuinely immutable across a move, so
            //    `addressChangesOnMove` is false, `finishMove` returns `.empty`
            //    and the handoff is a no-op there BY CONSTRUCTION. A Gmail-only
            //    fuzzer therefore stays green with the handoff reverted — which
            //    is exactly what makes these rounds the two-sided NON-VACUITY
            //    leg rather than dead weight.
            //  * Microsoft Graph REALLOCATES the id on every move
            //    (`IOS-GRAPH-002`), so an Outlook round only converges if the
            //    move's retirement re-addresses the follower still naming the
            //    old id. Reverting the handoff must fail these rounds.
            let provider: AccountProvider = round.isMultiple(of: 2) ? .gmail : .outlook
            let tag = "\(seedHex) round \(round) [\(provider.rawValue), fault=\(faultMode)]"
            if provider == .outlook {
                let outlookBystanders = StableFuzzConfig.bystanderCountMin
                    + rng.pick(StableFuzzConfig.bystanderCountRange)
                try await runOutlookStableIdRound(
                    seed: seed, round: round, faultMode: faultMode, tag: tag,
                    bystanderCount: outlookBystanders)
                continue
            }
            let bystanderCount = StableFuzzConfig.bystanderCountMin + rng.pick(StableFuzzConfig.bystanderCountRange)

            let accountId = "stablefuzz-\(String(seed, radix: 16))-\(faultMode)-r\(round)-\(UUID().uuidString)"
            let fixture = try makeStableIdFixture(accountId: accountId, provider: provider)
            defer { restoreStableIdFixture(fixture) }

            let mockProvider = MockEmailProvider()

            // ---- The race: an undo inverse (TRASH→INBOX) and a re-delete
            // (INBOX→TRASH) of the SAME stable id, exactly the IOS-QUEUE-008
            // shape — "two or more cross-folder gestures on ONE stable id".
            let targetId = "stablefuzz-target-\(UUID().uuidString)"
            let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
            // Bound with `let` (built inside an immediately-applied closure
            // because `createdAt` is set after init): these are captured by the
            // `@Sendable` drain closure below, and Swift 6 rejects capturing a
            // `var` in concurrently-executing code.
            let opInverse: PendingOperation = {
                var op = PendingOperation(
                    type: .move, messageIds: [targetId], accountId: accountId,
                    folderPath: fixture.trash.path, destinationPath: fixture.inbox.path)
                op.createdAt = t0
                return op
            }()
            let opRedelete: PendingOperation = {
                var op = PendingOperation(
                    type: .move, messageIds: [targetId], accountId: accountId,
                    folderPath: fixture.inbox.path, destinationPath: fixture.trash.path)
                op.createdAt = t0.addingTimeInterval(1)
                return op
            }()

            // ---- Disjoint bystander work — different ids, different lanes,
            // no fault — proves the target lane's fencing/fault never
            // strands unrelated intentions on the same account.
            // Same reason as `opInverse`/`opRedelete` above — captured by the
            // concurrent closure, so both must be `let` by the time they are.
            // `bystanderIds` is DERIVED from the ops rather than accumulated in
            // parallel, so the two can never disagree about membership.
            let bystanderOps: [PendingOperation] = (0..<bystanderCount).map { index in
                let bystanderId = "stablefuzz-bystander-\(index)-\(UUID().uuidString)"
                let type: OperationType = index.isMultiple(of: 2) ? .markRead : .markFlagged
                return PendingOperation(
                    type: type, messageIds: [bystanderId], accountId: accountId,
                    folderPath: fixture.inbox.path)
            }
            let bystanderIds: [String] = bystanderOps.compactMap(\.messageIds.first)

            // ---- Exact wire shapes. `MockEmailProvider.move` appends
            // `"move(ids:\(ids),from:\(from),to:\(to))"` to `callLog` BEFORE its
            // hook and BEFORE its throw check, so a FAILED attempt is logged
            // too — `callLog` is the attempt ledger, `movedIds` the success ledger.
            let inverseCall = "move(ids:[\"\(targetId)\"],from:\(fixture.trash.path),to:\(fixture.inbox.path))"
            let redeleteCall = "move(ids:[\"\(targetId)\"],from:\(fixture.inbox.path),to:\(fixture.trash.path))"
            let isTargetMoveCall: @Sendable (String) -> Bool = { $0.hasPrefix("move(ids:") && $0.contains(targetId) }

            if faultMode != .none {
                await mockProvider.setMoveThrowsOnId(targetId, error: ProviderError.notConnected)
            }

            // Adversarial layer (a)+(b): the SAME seeded ChaosScheduler this
            // file already uses, installed on every provider-call seam
            // `MockEmailProvider` exposes for the calls this round makes
            // (`move`, `markRead` — it has no `markFlagged`/`markUnread`
            // hook, so those calls go unperturbed; documented limitation,
            // not a gap in coverage of THIS invariant, which is about `move`).
            let wireState = Mutex<(inFlight: Int, overlapped: Bool)>((inFlight: 0, overlapped: false))
            await mockProvider.setMoveHook { [chaos, mockProvider, bystanderIds] in
                wireState.withLock { state in
                    state.inFlight += 1
                    if state.inFlight > 1 { state.overlapped = true }
                }
                // Bystander head start. `DrainContext.failedAccounts` is
                // account-WIDE by design, so a same-account bystander lane
                // that reaches its `failedAccounts` check only AFTER the
                // target's failure is (correctly) parked for the rest of that
                // drain. The exact-once bystander oracle below must measure
                // the queue, not Task scheduling, so no target move — success
                // or failure — may complete before every bystander has reached
                // the provider. Bounded: on timeout the hook proceeds and the
                // oracle reports the shortfall. The mock actor is reentrant at
                // this suspension point, so the bystanders' calls proceed.
                for _ in 0..<FuzzConfig.drainPollAttempts {
                    let readIds = await mockProvider.markedReadIds.flatMap { $0.ids }
                    let flaggedIds = await mockProvider.markedFlaggedIds.flatMap { $0.ids }
                    let reached = Set(readIds + flaggedIds)
                    if bystanderIds.allSatisfy({ reached.contains($0) }) { break }
                    try? await Task.sleep(for: .milliseconds(FuzzConfig.drainPollIntervalMs))
                }
                await chaos.point()
                try? await Task.sleep(for: .milliseconds(StableFuzzConfig.moveOverlapWindowMs))
                wireState.withLock { $0.inFlight -= 1 }
            }
            await mockProvider.setMarkReadHook { [chaos] in await chaos.point() }

            try await withProviderLifetime(
                accountId: accountId, provider: mockProvider,
                imapProvider: nil, pool: fixture.pool
            ) {
                try await fixture.pool.writeWithoutTransaction { db in
                    try opInverse.insert(db)
                    try opRedelete.insert(db)
                    for op in bystanderOps { try op.insert(db) }
                }

                switch faultMode {
                case .none:
                    // Two bounded barrier passes, mirroring the IMAP round's
                    // drain → backstop → drain ordering above.
                    try await drainProviderQueue(pool: fixture.pool, recordedCommands: { () -> [String] in [] })
                    try await drainProviderQueue(pool: fixture.pool, recordedCommands: { () -> [String] in [] })
                case .transientThenClears, .permanentThisRound:
                    // ONE direct drain while the fault is armed. Polling to
                    // emptiness would burn the whole barrier bound and throw
                    // a spurious timeout diagnostic. One direct call is
                    // provably sufficient: lanes run to completion (all
                    // Tasks awaited) before `drainPendingQueue()` returns,
                    // and the outer pass loop breaks itself once the target
                    // account's ops become unclaimable (`failedAccounts`).
                    await AccountManager.shared.drainPendingQueue()
                    let settled = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
                    #expect(settled, "\(tag): the armed drain must be quiescent before its retry state is read")

                    // ---- Invariant (armed fault, both modes): EXACTLY one wire
                    // attempt, carried by the predecessor; the successor was
                    // claimed and requeued UNTOUCHED (status back to queued,
                    // retryCount still 0). `everAttempted` is set at CLAIM
                    // time for every op of the lane (the claim loop in
                    // `AccountManager.drainPendingQueue`), so it is true for
                    // BOTH — the conservative evidence
                    // `drainPendingQueueRealFirstOpFailureGatesRestOfLane` pins.
                    let armedTargetCalls = (await mockProvider.callLog).filter(isTargetMoveCall)
                    #expect(
                        armedTargetCalls == [inverseCall],
                        "\(tag): exactly ONE target move must have been attempted while the fault was armed, got \(armedTargetCalls)"
                    )
                    let armedTargetMoves = (await mockProvider.movedIds).filter { $0.ids.contains(targetId) }
                    #expect(
                        armedTargetMoves.isEmpty,
                        "\(tag): a failing move must never record a successful call, got \(armedTargetMoves.map { "\($0.from)→\($0.to)" })"
                    )

                    let predecessor = try await fixture.pool.read { db in try PendingOperation.fetchOne(db, key: opInverse.id) }
                    let successor = try await fixture.pool.read { db in try PendingOperation.fetchOne(db, key: opRedelete.id) }
                    #expect(predecessor != nil, "\(tag): the failed predecessor must remain durably queued")
                    #expect(successor != nil, "\(tag): the halted successor must remain durably queued")
                    if let predecessor = predecessor, let successor = successor {
                        #expect(predecessor.status == PendingStatus.queued.rawValue,
                                "\(tag): predecessor status must be queued, got \(predecessor.status)")
                        #expect(predecessor.retryCount == 1,
                                "\(tag): predecessor must carry exactly ONE failed attempt, got retryCount=\(predecessor.retryCount)")
                        #expect(predecessor.everAttempted,
                                "\(tag): the predecessor was claimed, so everAttempted must be true")
                        #expect(successor.status == PendingStatus.queued.rawValue,
                                "\(tag): successor must be requeued to queued, got \(successor.status)")
                        #expect(successor.retryCount == 0,
                                "\(tag): the halted successor must never be attempted, got retryCount=\(successor.retryCount)")
                        #expect(successor.everAttempted,
                                "\(tag): the successor was claimed in the same pass, so everAttempted must be true (claim-time evidence, not a wire attempt)")
                    }
                    let accountOps = try await fixture.pool.read { db in
                        try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db)
                    }
                    #expect(
                        accountOps.count == 2,
                        "\(tag): only the two halted target ops may remain on the account, got \(accountOps.map { "\($0.type.rawValue)\($0.messageIds)" })"
                    )
                    #expect(
                        Set(accountOps.map(\.id)) == Set([opInverse.id, opRedelete.id]),
                        "\(tag): the remaining ops must be exactly the two target ops"
                    )

                    if faultMode == .transientThenClears {
                        // The blip resolves only AFTER its first failure was
                        // observed above — deterministic, no timer. Then the
                        // same two barrier passes as `.none`.
                        await mockProvider.clearMoveThrowsOnId()
                        try await drainProviderQueue(pool: fixture.pool, recordedCommands: { () -> [String] in [] })
                        try await drainProviderQueue(pool: fixture.pool, recordedCommands: { () -> [String] in [] })
                    }
                }

                // ---- Invariant: max in-flight per (account, id) == 1 — the
                // wire oracle. Timing-independent: a genuine concurrent pair
                // is provably observed inside the hook's own window,
                // regardless of which one happens to finish first.
                let overlapped = wireState.withLock { $0.overlapped }
                #expect(!overlapped, "\(tag): two cross-folder moves on ONE stable id executed concurrently on the wire")

                let allMoves = await mockProvider.movedIds
                let targetMoves = allMoves.filter { $0.ids.contains(targetId) }
                let landed = targetMoves.map { "\($0.from)→\($0.to)" }
                let targetCalls = (await mockProvider.callLog).filter(isTargetMoveCall)

                switch faultMode {
                case .none, .transientThenClears:
                    // ---- Invariant: successful calls on one id follow
                    // createdAt order, and the LATEST destination wins.
                    #expect(targetMoves.count == 2, "\(tag): both cross-folder moves must reach the provider, got \(landed)")
                    if targetMoves.count == 2 {
                        let expected = [
                            "\(fixture.trash.path)→\(fixture.inbox.path)",
                            "\(fixture.inbox.path)→\(fixture.trash.path)",
                        ]
                        #expect(landed == expected, "\(tag): moves must land in createdAt (issue) order, got \(landed)")
                        #expect(targetMoves[1].to == fixture.trash.path,
                                "\(tag): the user's LATEST destination must win on the wire, got \(targetMoves[1].to)")
                    }
                    // ---- Invariant: the attempt ledger is exact. `.none` = the
                    // two successes in issue order; transient = the ONE failed
                    // attempt first, then the two successes.
                    let expectedCalls = (faultMode == .transientThenClears ? [inverseCall] : []) + [inverseCall, redeleteCall]
                    #expect(targetCalls == expectedCalls, "\(tag): target move calls must be exactly \(expectedCalls), got \(targetCalls)")
                    // ---- Invariant: the durable queue converges.
                    let remaining = try await fixture.pool.read { db in try PendingOperation.fetchCount(db) }
                    #expect(remaining == 0, "\(tag): queue did not converge — \(remaining) op(s) remain")
                case .permanentThisRound:
                    #expect(targetMoves.isEmpty, "\(tag): a permanently-failing move must never record a successful call, got \(landed)")
                    #expect(targetCalls == [inverseCall], "\(tag): a permanent fault must leave exactly ONE (failed) target call, got \(targetCalls)")
                }

                // ---- Invariant: disjoint work progresses EXACTLY once per
                // bystander, regardless of the target lane's fault mode
                // (never dropped, never duplicated).
                let readCalls = await mockProvider.markedReadIds
                let flaggedCalls = await mockProvider.markedFlaggedIds
                for (index, bystanderId) in bystanderIds.enumerated() {
                    let hits = index.isMultiple(of: 2)
                        ? readCalls.filter { $0.ids == [bystanderId] }.count
                        : flaggedCalls.filter { $0.ids == [bystanderId] }.count
                    #expect(hits == 1, "\(tag): disjoint bystander \(bystanderId) must reach the provider exactly once, got \(hits)")
                }
            }
        }
    }

    // MARK: - The Outlook round (IOS-GRAPH-005)

    /// One round of the same invariant against a REAL `ExchangeProvider` and a
    /// Graph server that reallocates the message id on every move.
    ///
    /// **Why this cannot reuse the Gmail round's body.** The Gmail round's
    /// oracles are `MockEmailProvider`'s ledgers (`callLog`, `movedIds`), which
    /// exist because the mock never changes an address. The question here is
    /// precisely what happens to an address, so the oracle has to be the SERVER:
    /// which folder the message is in, at which id, and how many copies exist.
    ///
    /// **Fault injection differs, deliberately.** The Gmail round scopes its
    /// fault to the target id (`setMoveThrowsOnId`). The Graph fixture's
    /// equivalent is `failAllMutations(_:)`, which is account-wide, so under a
    /// fault the bystanders fail too. The bystander oracle is adapted to match
    /// rather than weakened: with the fault cleared every bystander must land
    /// EXACTLY once, and under a permanent fault every bystander operation must
    /// still be DURABLY QUEUED — never dropped. Both are the never-drop
    /// invariant; only the observable differs.
    @MainActor
    private func runOutlookStableIdRound(
        seed: UInt64, round: Int, faultMode: StableFaultMode, tag: String, bystanderCount: Int
    ) async throws {
        let accountId = "stablefuzz-graph-\(String(seed, radix: 16))-\(faultMode)-r\(round)-\(UUID().uuidString)"
        let fixture = try makeStableIdFixture(accountId: accountId, provider: .outlook)
        defer { restoreStableIdFixture(fixture) }

        let targetId = "graph/target+\(UUID().uuidString)="
        let targetRfc = "stablefuzz-target-\(UUID().uuidString)@example.com"
        let bystanderIds = (0..<bystanderCount).map { "graph/bystander+\($0)+\(UUID().uuidString)=" }
        let bystanderRfcs = (0..<bystanderCount).map { "stablefuzz-bystander-\($0)-\(UUID().uuidString)@example.com" }

        var seeds: [StatefulExchangeActionServer.Seed] = [
            .init(rfc822MessageId: targetRfc, providerMessageId: targetId,
                  folderId: fixture.trash.path),
        ]
        for (index, bystanderId) in bystanderIds.enumerated() {
            seeds.append(.init(
                rfc822MessageId: bystanderRfcs[index], providerMessageId: bystanderId,
                folderId: fixture.inbox.path))
        }
        let server = StatefulExchangeActionServer(messages: seeds, churnsIdOnMove: true)
        defer { server.close() }

        // The local row the re-key follows. Seeded in TRASH, where the undo
        // inverse starts, exactly as a sync would have left it.
        var header = MessageHeader(
            messageId: targetId,
            subject: "stablefuzz graph target",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "\(accountId)@example.com",
            date: Date(),
            snippet: "stablefuzz graph body",
            folderId: MessageIdentity.folderId(
                accountId: accountId, folderPath: fixture.trash.path),
            accountId: accountId,
            folderPath: fixture.trash.path,
            isInInbox: false)
        header.rfc822MessageId = targetRfc
        let seededHeader = header

        // The IOS-QUEUE-008 shape: an undo inverse (TRASH→INBOX) and a
        // re-delete (INBOX→TRASH) of ONE message, in issue order.
        let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
        let opInverse: PendingOperation = {
            var op = PendingOperation(
                type: .move, messageIds: [targetId], accountId: accountId,
                folderPath: fixture.trash.path, destinationPath: fixture.inbox.path)
            op.createdAt = t0
            return op
        }()
        let opRedelete: PendingOperation = {
            var op = PendingOperation(
                type: .move, messageIds: [targetId], accountId: accountId,
                folderPath: fixture.inbox.path, destinationPath: fixture.trash.path)
            op.createdAt = t0.addingTimeInterval(1)
            return op
        }()
        let bystanderOps: [PendingOperation] = bystanderIds.enumerated().map { index, bystanderId in
            PendingOperation(
                type: index.isMultiple(of: 2) ? .markRead : .markFlagged,
                messageIds: [bystanderId], accountId: accountId,
                folderPath: fixture.inbox.path)
        }

        try await withProviderLifetime(
            accountId: accountId, provider: server.provider(),
            imapProvider: nil, pool: fixture.pool
        ) {
            try await fixture.pool.writeWithoutTransaction { db in
                try seededHeader.insert(db)
                try opInverse.insert(db)
                try opRedelete.insert(db)
                for op in bystanderOps { try op.insert(db) }
            }
            let totalOps = 2 + bystanderOps.count

            // ---- Phase A: the armed fault. Nothing may reach the server, and
            // nothing may leave the queue.
            if faultMode != .none {
                server.failAllMutations(true)
                await AccountManager.shared.drainPendingQueue()
                let settled = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
                #expect(settled, "\(tag): the armed drain must be quiescent before its retry state is read")

                #expect(server.snapshot(providerMessageId: targetId)?.folderId == fixture.trash.path,
                        "\(tag): a move landed while every mutation was supposed to fail")
                let armedOps = try await fixture.pool.read { db in
                    try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db)
                }
                #expect(armedOps.count == totalOps, """
                    \(tag): a failed attempt DROPPED an intention — \(armedOps.count) of \
                    \(totalOps) operations survive. A transient refusal is never an exit.
                    """)
                #expect(armedOps.allSatisfy { $0.status == PendingStatus.queued.rawValue },
                        "\(tag): an operation was left inFlight by the armed drain")

                if faultMode == .permanentThisRound {
                    // ---- Invariant: a permanent fault retains EXACTLY the
                    // halted-lane state, and nothing on the wire moved.
                    #expect(Set(armedOps.map(\.id))
                        == Set([opInverse.id, opRedelete.id] + bystanderOps.map(\.id)),
                            "\(tag): the retained operations are not the ones that were issued")
                    #expect(server.snapshots(rfc822MessageId: targetRfc).map(\.folderId)
                        == [fixture.trash.path],
                            "\(tag): the target moved under a permanent fault")
                    #expect(!server.moveOverlapObserved(), """
                        \(tag): two cross-folder moves on ONE Graph id entered the wire \
                        concurrently (peak \(server.peakConcurrentMoves()))
                        """)
                    return
                }
                server.failAllMutations(false)
            }

            // ---- Phase B: converge, with the first move parked so a genuinely
            // concurrent pair is OBSERVED rather than inferred.
            let release = server.holdNextMove()
            let drain = Task { await AccountManager.shared.drainPendingQueue() }
            var held = false
            for _ in 0..<FuzzConfig.drainPollAttempts where !held {
                held = server.heldMoveCount() >= 1
                if !held { try await Task.sleep(for: .milliseconds(FuzzConfig.drainPollIntervalMs)) }
            }
            #expect(held, "\(tag): no move was parked, so the overlap oracle below is vacuous")
            // The parked move holds the window open indefinitely, so this wait
            // only has to be long enough for a SEPARATE lane's Task — launched
            // in the same loop iteration — to reach the route. Four times the
            // Gmail round's window, because here the cost of waiting is paid
            // once per round rather than once per move.
            try await Task.sleep(for: .milliseconds(4 * StableFuzzConfig.moveOverlapWindowMs))
            #expect(!server.moveOverlapObserved(), """
                \(tag): two cross-folder moves on ONE Graph id executed concurrently on \
                the wire (peak \(server.peakConcurrentMoves())) — raced, the OLDER \
                gesture can land last and the user's latest intention is reverted
                """)
            release()
            _ = await drain.value
            try await drainProviderQueue(pool: fixture.pool, recordedCommands: { () -> [String] in [] })

            // ---- Invariant: the latest destination wins, at whatever id Graph
            // reallocated along the way, with no duplicate left behind.
            let copies = server.snapshots(rfc822MessageId: targetRfc)
            #expect(copies.count == 1, "\(tag): the target was duplicated — \(copies.map(\.folderId))")
            #expect(copies.map(\.folderId) == [fixture.trash.path], """
                \(tag): the user's LATEST destination did not win — the message is at \
                \(copies.map(\.folderId)). On Graph the re-delete names the id the \
                inverse's move invalidated unless the retirement re-addressed it.
                """)
            #expect(copies.first?.providerMessageId != targetId,
                    "\(tag): Graph did not reallocate the id, so this round is not exercising the churn")

            // ---- Invariant: the durable queue converges.
            let remaining = try await fixture.pool.read { db in try PendingOperation.fetchCount(db) }
            #expect(remaining == 0, "\(tag): queue did not converge — \(remaining) op(s) remain")

            // ---- Invariant: disjoint work progresses exactly once, never
            // dropped and never duplicated, whatever the target lane did.
            for (index, bystanderId) in bystanderIds.enumerated() {
                let landed = server.snapshot(providerMessageId: bystanderId)
                #expect(landed != nil, "\(tag): bystander \(bystanderId) vanished from the server")
                let applied = index.isMultiple(of: 2) ? landed?.isRead : landed?.isFlagged
                #expect(applied == true, """
                    \(tag): disjoint bystander \(bystanderId) never reached the provider — \
                    a halted target lane starved an unrelated intention (IOS-QUEUE-001)
                    """)
            }
            #expect(Set(bystanderIds).count == bystanderIds.count,
                    "\(tag): the round generated a duplicate bystander id, so the oracle above is ambiguous")
        }
    }
}
