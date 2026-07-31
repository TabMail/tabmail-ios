/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail
#if canImport(Glibc)
import Glibc
#endif

/// A minimal IMAP4rev1 server for provider-level tests, adapted from
/// `IMAPTestServer.swift` in the SwiftMail fork's `Tests/SwiftIMAPTests/`
/// (github.com/TabMail/SwiftMail).
/// Uses POSIX sockets directly because `Network.framework`'s NWListener has
/// known issues in the iOS simulator.
///
/// Differences from the SwiftMail reference:
/// - Accepts an in-memory `[Message]` array instead of loading from a Maildir.
/// - BODYSTRUCTURE builder will grow to emit nested `message/rfc822` parts as
///   test coverage expands. Today it emits single-part
///   BODYSTRUCTURE for flat messages only — enough to prove the IMAPProvider
///   round-trip works against a fake server on localhost:ephemeral-port.
///
/// Wire format references (for every response this server emits):
/// - RFC 3501 §6.4.5 (FETCH), §7.4.2 (FETCH response), §7.1 (OK/BAD/NO/BYE)
/// - RFC 9051 (IMAP4rev2)
/// - RFC 2087 (QUOTA), RFC 2177 (IDLE) — if/when added
///
/// Discipline: do NOT invent response shapes. Every literal below is checked
/// against the cited RFC sections in `TabMailTests/Fixtures/README.md`.
final class FakeIMAPServer: @unchecked Sendable {
    struct Message: Sendable {
        let uid: Int
        let raw: Data            // full RFC 2822 message bytes (must use CRLF line endings)
        let subject: String
        let from: String
        let to: String
        let date: String          // RFC 2822 Date header value
        let internalDate: String  // IMAP format: "DD-Mon-YYYY HH:MM:SS +ZZZZ"
        let messageID: String
        let contentType: String
        let charset: String
        let body: Data
        let headerData: Data
        /// When set, the fake server emits this raw BODYSTRUCTURE literal
        /// instead of its auto-generated flat single-part structure. Used by
        /// tests that need multipart or nested `message/rfc822` BODYSTRUCTURE
        /// shapes.
        /// The literal must be a valid RFC 3501 §7.4.2 body-type-1part or
        /// body-type-mpart — no outer parentheses added by the server.
        let customBodystructure: String?
        /// When set, requests for `BODY[N]` / `BODY.PEEK[N]` look up the raw
        /// bytes here (keyed by section string, e.g. `"1"`, `"2"`, `"2.1"`).
        /// Falls back to slicing `body` only when nil.
        let partBodies: [String: Data]?

        func replacingUID(_ uid: Int) -> Message {
            Message(
                uid: uid,
                raw: raw,
                subject: subject,
                from: from,
                to: to,
                date: date,
                internalDate: internalDate,
                messageID: messageID,
                contentType: contentType,
                charset: charset,
                body: body,
                headerData: headerData,
                customBodystructure: customBodystructure,
                partBodies: partBodies
            )
        }
    }

    /// One queued injected failure: skip this many further matches of the
    /// fragment before firing, then respond with `message` (default: the
    /// original generic "Injected test failure" text). The optional custom
    /// message lets a test manufacture a server-reported error whose text a
    /// production classifier keys off (e.g. `max_userip_connections=N`,
    /// ADR-IOS-061 item B/R8-F2's limit-retry path) without needing a real
    /// server that actually enforces a connection cap.
    private struct InjectedFailure {
        var skip: Int
        let message: String
        /// Two-tier fuzzer (Testing Rule 11) seam — see
        /// `killConnectionOnNextCommand(containing:)`'s doc comment.
        var killConnection: Bool = false
    }

    /// One deterministic mailbox reset applied only after the matching
    /// command's successful response has been written to the client. This
    /// models an epoch change at an await boundary without pausing either
    /// side of the socket.
    private struct PostResponseMailboxReset {
        let commandFragment: String
        let mailbox: String
        let uidValidity: Int
        let messages: [Message]
        let flagsByUID: [Int: Set<String>]
    }

    private struct State {
        var messagesByMailbox: [String: [Message]]
        var flagsByMailbox: [String: [Int: Set<String>]] = [:]
        var commandLog: [String] = []
        var injectedFailureCountdowns: [String: [InjectedFailure]] = [:]
        var consumedInjectedFailureCount = 0
        /// Identity-resolution fault seam (Testing Rule 11) — bare (angle-
        /// bracket-stripped) Message-ID → how many further whole RESOLUTIONS
        /// of it must answer SUCCESSFULLY with zero UIDs. Unlike
        /// `injectedFailureCountdowns` above this is consumed inside the SEARCH
        /// handler, not in the pre-dispatch failure check, because the whole
        /// point is that the command SUCCEEDS. The unit is a resolution and not
        /// a command; see `returnEmptySearch(forMessageId:resolutionCount:)`
        /// for why that distinction is load-bearing rather than cosmetic.
        var emptySearchResolutionCountdowns: [String: Int] = [:]
        /// Whole resolutions this fake has actually driven to empty — i.e. the
        /// number of times it served the BARE half of a bracketed-then-bare
        /// pair with zero UIDs.
        ///
        /// ⚠ That is a statement about the WIRE, not about
        /// `uidResolutionFailed`. `IMAPProvider.searchByMessageId` has several
        /// direct callers besides `IMAPProvider.resolveUID` — `move`'s
        /// destination probe, `currentUIDs`, `appendToSentFolder`'s dedup
        /// check, and the draft-save/stale-draft legs — and NONE of those
        /// throws `uidResolutionFailed` on an empty result. Only `resolveUID`
        /// does. So a served empty resolution is a NECESSARY, not a sufficient,
        /// condition for the throw, and the count is an upper bound on the
        /// throws it can have caused.
        var consumedEmptySearchResolutionCount = 0
        /// The same events keyed by bare Message-ID. The aggregate above is
        /// unjoinable: it cannot say WHICH message was driven empty, so pairing
        /// it with a durable side effect recorded against some message proves
        /// only that both numbers are non-zero, never that they describe the
        /// same message. Every consumer that needs a two-sided proof reads this.
        var consumedEmptySearchResolutionsByMessageId: [String: Int] = [:]
        var postResponseMailboxResets: [PostResponseMailboxReset] = []
        /// Mailboxes SELECT must reject as gone. Value = whether the NO
        /// response carries the RFC 5530 `[NONEXISTENT]` response code (the
        /// "hint" shape) or is a plain unstructured NO (the non-RFC-5530
        /// shape some real servers send). LIST also excludes these names
        /// regardless of shape — the LIST probe is the authority either way.
        var deletedMailboxes: [String: Bool] = [:]
        /// Per-mailbox UIDVALIDITY reported by SELECT/EXAMINE (RFC 3501
        /// §2.3.1.1). Missing entry defaults to 1 — every pre-existing test
        /// relies on that fixed value, so this is purely additive. ADR-IOS-060
        /// residual-closure tests (`setUidValidity`) bump it to simulate a
        /// server-side mailbox reset without this fake needing to model full
        /// mailbox recreation (message list churn is separately simulated via
        /// `setMessages`).
        var uidValidityByMailbox: [String: Int] = [:]
        /// Mailboxes whose SELECT/EXAMINE response OMITS the
        /// `* OK [UIDVALIDITY n]` line entirely (T1.2b, `suppressSelectUidValidity`).
        /// RFC 3501 §6.3.1 says a server SHOULD send it, not MUST, and SwiftMail
        /// therefore defaults `Mailbox.Selection.uidValidity` to `UIDValidity(0)` —
        /// so this models the one wire shape that can hand the app a `0` and let
        /// it be mistaken for a real epoch. Empty for every pre-existing test.
        var selectUidValiditySuppressed: Set<String> = []
        /// Invariant test layer (2026-07-16) — wrong-message wire oracle,
        /// deliverable 1. The rfc822 Message-ID(s) the CURRENT test's user
        /// intention(s) target, registered via `expectMutation(rfc822MessageId:)`.
        /// OPT-IN: while this stays empty (every pre-existing test — nothing
        /// before this addition ever calls the registration API), every
        /// mutating-command check below is a single `isEmpty` branch — zero
        /// behavioral change to the other ~7,900 tests.
        var expectedMutationRfcs: Set<String> = []
        /// Every wrong-message violation recorded so far: a mutating command
        /// (STORE/MOVE/COPY/EXPUNGE) resolved its target UID to a CURRENT
        /// occupant whose Message-ID was not in `expectedMutationRfcs` at
        /// that instant.
        var wrongMessageViolations: [WrongMessageViolation] = []
        /// Two-tier fuzzer (Testing Rule 11), tier-1 invariant (d) — fds that
        /// have completed a successful LOGIN and have not since sent LOGOUT
        /// (or had their socket closed). A connection `IMAPProvider` creates
        /// but then loses track of WITHOUT logging out (the leak class R6-1
        /// Part 2 / R8-F1 fix) stays in this set forever — `liveSessionCount()`
        /// is the oracle a fuzz round asserts drops to 0 once every
        /// `IMAPProvider` connection lane has been torn down.
        ///
        /// R12-F1 CORRECTION: this set is cleared by `closeClientFd` the
        /// instant ANY close happens — a clean LOGOUT and an abandoned
        /// session's own socket EOF-closing (the class R11-H2 fixed) are
        /// INDISTINGUISHABLE to `liveSessionCount()`, which reads 0 either
        /// way once the fd is gone. It genuinely catches a *different*, still
        /// real leak class (a connection whose socket is STILL OPEN and
        /// still logged in, nothing ever having closed it at all — e.g. a
        /// pool slot the provider still thinks is live). The abandoned-and-
        /// already-disconnected class needs `sessionsEndedWithoutLogout`
        /// below, which is NOT cleared on close — see that field's and
        /// `closeClientFd`'s doc comments.
        var loggedInFds: Set<Int32> = []
        /// R12-F1: every fd that has EVER completed a successful LOGIN —
        /// unlike `loggedInFds` above (which `closeClientFd` unconditionally
        /// clears on ANY close, logout or not), this one is only consulted
        /// (and removed) inside `closeClientFd` itself, at the moment the fd
        /// is actually torn down, so it still reads "yes, this fd logged in"
        /// even for a session that jumped straight from LOGIN to socket-EOF
        /// with no LOGOUT in between — the abandoned-session class
        /// `liveSessionCount()` cannot see (its doc comment above).
        var everLoggedInFds: Set<Int32> = []
        /// R12-F1: every fd whose LOGOUT command was actually processed
        /// (set in the `LOGOUT` command handler, consulted+removed in
        /// `closeClientFd`) — the "ended cleanly" half of the
        /// `sessionsEndedWithoutLogout` predicate.
        var loggedOutFds: Set<Int32> = []
        /// R12-F1 exclusions: fds whose upcoming close is TEST-INITIATED, not
        /// something a production leak could ever trigger for a real
        /// abandoned session. Marked BEFORE the actual close in exactly two
        /// seams (audited — see `sessionsEndedWithoutLogout`'s doc comment
        /// for why each is excluded): `killConnectionOnNextCommand`'s kill
        /// branch, and `stop()`'s test-teardown sweep. Consulted+removed in
        /// `closeClientFd`.
        var testInitiatedCloseFds: Set<Int32> = []
        /// R12-F1 (Round 12 finding F1) — the wire-level "abandoned logged-in
        /// session" oracle. `liveSessionCount()` (`loggedInFds.count` above)
        /// cannot distinguish "logged out cleanly" from "abandoned, then the
        /// transport eventually tore down" — both clear `loggedInFds` via
        /// `closeClientFd`, so `liveSessionCount() == 0` passes even with
        /// R11-H2's fix reverted. This counter is MONOTONIC (never reset,
        /// never self-heals) and increments in `closeClientFd` exactly when a
        /// session reached LOGIN and closed WITHOUT ever receiving LOGOUT —
        /// EXCLUDING the two test-initiated closes tracked in
        /// `testInitiatedCloseFds` above. Exposed via `abandonedSessionCount()`.
        ///
        /// ⚠️ SOUND ONLY IN CHURN-FREE (deterministic) ENVIRONMENTS — R12
        /// verification-pass finding: under fault/latency injection,
        /// SwiftMail's TRANSPARENT RECONNECT layer ("Channel is nil,
        /// re-establishing…" / "not authenticated; re-authenticating…")
        /// legitimately opens N channels over one `IMAPServer` object's life
        /// and silently closes every superseded channel WITHOUT a LOGOUT
        /// line — a mid-life re-auth channel that completed LOGIN and was
        /// then replaced increments this counter even though the OBJECT was
        /// never abandoned (it logs out later, on a newer channel). So the
        /// pool FUZZER must NOT assert on this counter (it false-positives
        /// at a seed-dependent rate); it uses the client-side
        /// object-lifecycle oracle instead (`IMAPProvider`'s
        /// `serverCreatedTestHook`/`logoutAttemptTestHook` + the fuzzer's
        /// `CreatedServerRegistry`: every created instance must mark a
        /// disposition (logout attempt / explicit proved-dead drop) before
        /// it deinits — instance-identity-based,
        /// immune to channel churn). This counter remains load-bearing in
        /// the DETERMINISTIC R11-H2 pin (`IMAPProviderPoolInvariantTests`),
        /// which runs with no injection and therefore no reconnect churn.
        var sessionsEndedWithoutLogout = 0
        /// Round 9 item D (NO-LOGOUT-WHILE-HELD oracle): the fd every LOGOUT
        /// command arrives on, in wire order. Supplementary wire-level
        /// evidence — the suite's PRIMARY detection for this oracle is
        /// client-side (`IMAPProvider`'s `beforeLogoutTestHook`, which fires
        /// with the exact `IMAPServer` instance about to be logged out,
        /// checked against a full-body holder registry): correlating a raw
        /// fd back to a specific client-side instance would need either a
        /// brittle accept/LOGIN ordering assumption (concurrent connection
        /// creations can complete LOGIN out of order) or protocol-level
        /// changes to this fake outside what a real IMAP server would do —
        /// both worse than the client-side seam for a false-positive-free
        /// oracle. Kept for diagnostics (a violation's surrounding context)
        /// and as a building block for any future wire-only oracle.
        var logoutFdLog: [Int32] = []
        /// Owner-directed adversarial fuzzer addendum (Testing Rule 11):
        /// seeded per-command latency injection. `nil` (the default) means
        /// off — zero behavioral change for every pre-existing test. When
        /// installed via `setSeededLatencyInjection`, EVERY command reply is
        /// delayed by a seeded random amount, weighted toward LOGIN/NOOP —
        /// the commands whose real round-trip HOSTS the pool's known narrow
        /// windows (`createServer()`'s connect+LOGIN RTT; the liveness-check
        /// /keepalive NOOP RTT) — turning a lottery-rare race into a
        /// routinely-reproducible one via REAL latency, not a pause hook.
        var latencyInjection: LatencyInjection?
    }

    /// See `State.latencyInjection`'s doc comment.
    private struct LatencyInjection {
        var rng: SplitMix64
        let maxMilliseconds: Int
    }

    /// One wrong-message wire oracle hit (invariant test layer, deliverable
    /// 1). Motivating history: ADR-IOS-061's Round-2 nil-stamp regression let
    /// an OLD-epoch token UID execute a STORE against whatever NEW-epoch
    /// message the reaction's resync had since planted at that UID — a unit
    /// test pinning the stamp function's mechanism stayed green throughout,
    /// because it never drove a mutating command against a live decoy. This
    /// oracle is that missing "did a mutation ever land on the wrong
    /// message" check, made mechanical instead of relying on every test
    /// author to hand-write `server.flags(in:uid:)`/`server.messageIDs(in:)`
    /// assertions (see `UIDValidityResetReactionTests
    /// .barrierE2EGestureSurvivesPurgeAndExecutesPostResync`, which does
    /// exactly that by hand today).
    struct WrongMessageViolation: Sendable, CustomStringConvertible {
        let command: String
        let mailbox: String
        let uid: Int
        let expectedRfcs: Set<String>
        let actualRfc: String

        var description: String {
            "[FakeIMAPServer oracle] \(command) mailbox=\(mailbox) uid=\(uid) mutated rfc822MessageId=\"\(actualRfc)\" — NOT in expected set \(expectedRfcs.sorted())"
        }
    }

    let host: String
    let username: String
    let password: String
    private(set) var port: Int

    /// Wire-order CAPABILITY tokens this server advertises, both in the
    /// connection greeting and the `CAPABILITY` command response. Defaults
    /// to the original hardcoded set. SPEC-B4 constructs a server WITHOUT
    /// `MOVE`/`UIDPLUS` to force SwiftMail's COPY+STORE+EXPUNGE fallback
    /// (RFC 6851 — see `IMAPServer+Manipulation.swift`'s `move` in the
    /// pinned SwiftMail fork).
    static let defaultCapabilities = ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "UIDPLUS", "MOVE", "IDLE"]
    private let capabilities: [String]

    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "FakeIMAPServer")
    private let stateLock = NSLock()
    private var state: State
    private var clientFds: [Int32] = []

    init(
        host: String = "localhost", port: Int = 0, username: String = "testuser", password: String = "testpass",
        capabilities: [String] = FakeIMAPServer.defaultCapabilities, messages: [Message]
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.capabilities = capabilities
        self.state = State(messagesByMailbox: ["INBOX": messages])
    }

    init(
        host: String = "localhost", port: Int = 0, username: String = "testuser", password: String = "testpass",
        capabilities: [String] = FakeIMAPServer.defaultCapabilities, mailboxes: [String: [Message]]
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.capabilities = capabilities
        self.state = State(messagesByMailbox: mailboxes)
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&state)
    }

    // MARK: - Client fd lifecycle (exactly-once close)

    /// `clientFds` is touched from three contexts (the accept source's
    /// `queue`, each client's global-queue `handleClient`, and `stop()`'s
    /// caller thread) — every access goes through `stateLock`. More
    /// importantly, close is EXACTLY-ONCE: `handleClient` used to `close(fd)`
    /// directly on LOGOUT/EOF while `stop()` later closed every fd still in
    /// `clientFds` — a double close. When the kernel had re-used the fd
    /// number in between (e.g. for one of GRDB's GUARDED SQLite descriptors),
    /// the second `close` raised `EXC_GUARD` and killed the whole test host
    /// (observed repeatedly once a test disconnected its provider mid-test
    /// and kept doing GRDB work before `stop()`). Untracking under the lock
    /// BEFORE closing makes whichever side arrives second a no-op.
    private func trackClientFd(_ fd: Int32) {
        stateLock.lock()
        clientFds.append(fd)
        stateLock.unlock()
    }

    /// Close `fd` iff it is still tracked. Returns silently otherwise.
    private func closeClientFd(_ fd: Int32) {
        stateLock.lock()
        let wasTracked = clientFds.contains(fd)
        clientFds.removeAll { $0 == fd }
        stateLock.unlock()
        // A connection whose socket closes without ever sending LOGOUT
        // (a dropped/killed connection, or a leaked-but-abandoned one whose
        // underlying transport eventually tears down) must not stay "live"
        // forever — defensive cleanup alongside the LOGOUT command handler.
        withState { state in
            _ = state.loggedInFds.remove(fd)
            // R12-F1: the REAL abandoned-logged-in-session oracle. Deliberately
            // keyed off `everLoggedInFds`/`loggedOutFds`, NOT the `loggedInFds`
            // removal just above — `loggedInFds` is ALREADY cleared by the
            // LOGOUT command handler and by the kill-connection branch below
            // before this ever runs, so checking IT here would silently
            // exclude exactly the sessions this oracle exists to catch (a
            // clean LOGOUT and a same-fd abandonment would both already read
            // "not present").
            let wasLoggedIn = state.everLoggedInFds.remove(fd) != nil
            let receivedLogout = state.loggedOutFds.remove(fd) != nil
            // Exclusions (i)/(ii) — see `testInitiatedCloseFds`'s doc comment.
            let isTestInitiated = state.testInitiatedCloseFds.remove(fd) != nil
            if wasLoggedIn && !receivedLogout && !isTestInitiated {
                state.sessionsEndedWithoutLogout += 1
            }
        }
        if wasTracked { close(fd) }
    }

    /// Snapshot-and-clear for `stop()` — the returned fds are no longer
    /// tracked, so a concurrent `closeClientFd` from a client loop no-ops.
    private func takeAllClientFds() -> [Int32] {
        stateLock.lock()
        let fds = clientFds
        clientFds.removeAll()
        stateLock.unlock()
        return fds
    }

    func messageIDs(in mailbox: String) -> [String] {
        withState { state in
            (state.messagesByMailbox[mailbox] ?? []).map(\.messageID)
        }
    }

    func flags(in mailbox: String, uid: Int) -> Set<String> {
        withState { state in
            state.flagsByMailbox[mailbox]?[uid] ?? []
        }
    }

    /// Test convenience: resolve the CURRENT uid holding `rfc822MessageId`
    /// in `mailbox` (bracket-or-bare match) and return its flags, or `nil`
    /// when no message with that identity currently exists there. Lets a
    /// caller assert "the op's server-side mutation landed" without needing
    /// to separately track a renumbered UID.
    func flags(in mailbox: String, rfc822MessageId: String) -> Set<String>? {
        withState { state -> Set<String>? in
            let bracketSet = CharacterSet(charactersIn: "<>")
            let target = rfc822MessageId.trimmingCharacters(in: bracketSet)
            guard let msg = (state.messagesByMailbox[mailbox] ?? []).first(where: {
                $0.messageID.trimmingCharacters(in: bracketSet) == target
            }) else { return nil }
            return state.flagsByMailbox[mailbox]?[msg.uid] ?? []
        }
    }

    func recordedCommands() -> [String] {
        withState { $0.commandLog }
    }

    /// Two-tier fuzzer (Testing Rule 11), tier-1 invariant (d) — number of
    /// connections currently past a successful LOGIN with no LOGOUT/close
    /// observed since. A fuzz round's final teardown must drive this to 0:
    /// any provider-side leaked connection (planted-over-without-logout,
    /// the class of bug R6-1 Part 2 / R8-F1 fixed) leaves a positive residual
    /// here even after every `IMAPProvider`-tracked slot has been cleared.
    ///
    /// R12-F1 CORRECTION: this reads 0 the instant `closeClientFd` runs for
    /// ANY reason — a clean LOGOUT and an abandoned session's socket
    /// eventually EOF-closing are indistinguishable to it. It catches a
    /// STILL-OPEN leaked/logged-in socket, not an already-abandoned one.
    /// Use `abandonedSessionCount()` for the latter.
    func liveSessionCount() -> Int {
        withState { $0.loggedInFds.count }
    }

    /// R12-F1: the REAL "abandoned logged-in session" oracle — see
    /// `State.sessionsEndedWithoutLogout`'s and `closeClientFd`'s doc
    /// comments for the exact predicate (logged in, no LOGOUT, not a
    /// test-initiated close) and why `liveSessionCount()` structurally
    /// cannot make this claim. Monotonic: once a session is counted here it
    /// stays counted, even after this same test's own final `disconnect()`
    /// sweep — unlike `liveSessionCount()`, nothing "heals" this back to 0.
    func abandonedSessionCount() -> Int {
        withState { $0.sessionsEndedWithoutLogout }
    }

    /// Round 9 item D — see `State.logoutFdLog`'s doc comment for why this
    /// is supplementary/diagnostic rather than the oracle's primary signal.
    func logoutFdLog() -> [Int32] {
        withState { $0.logoutFdLog }
    }

    func consumedInjectedFailureCount() -> Int {
        withState { $0.consumedInjectedFailureCount }
    }

    func failNextCommand(containing fragment: String, message: String = "Injected test failure") {
        failCommand(containing: fragment, onMatch: 1, message: message)
    }

    func failCommand(containing fragment: String, onMatch: Int, message: String = "Injected test failure") {
        withState { state in
            state.injectedFailureCountdowns[fragment.uppercased(), default: []]
                .append(InjectedFailure(skip: max(0, onMatch - 1), message: message))
        }
    }

    /// Apply one complete mailbox epoch replacement immediately after the
    /// next successful response for `fragment` is written. The replacement
    /// includes flags because flags, like UIDs, belong to the mailbox epoch.
    func resetMailboxAfterNextSuccessfulResponse(
        containing fragment: String,
        mailbox: String,
        uidValidity: Int,
        messages: [Message],
        flagsByUID: [Int: Set<String>] = [:]
    ) {
        withState { state in
            state.postResponseMailboxResets.append(PostResponseMailboxReset(
                commandFragment: fragment.uppercased(),
                mailbox: mailbox,
                uidValidity: uidValidity,
                messages: messages,
                flagsByUID: flagsByUID
            ))
        }
    }

    /// Two-tier fuzzer (Testing Rule 11) seam. UNLIKE `failNextCommand`
    /// (which sends a protocol-level NO response and leaves the connection
    /// otherwise healthy — the R8-F2 `max_userip_connections` scenario, an
    /// otherwise-fine connection rejecting ONE command), this closes the
    /// socket outright the next time `fragment` matches, with NO response
    /// sent at all — a real dead TCP connection. `IMAPProvider`'s four
    /// "NOOP/command failed ⇒ assume already dead, discard tracking WITHOUT
    /// an explicit logout()" sites (the action pool's dead-recreate branch,
    /// the folder pool's branch-1 dead-recreate leg, and both of
    /// `keepAlivePinnedConnections`'s failure legs) all rely on that
    /// precondition — a plain injected NO response leaves the fake server's
    /// session genuinely alive (this test infra never actually closes the
    /// socket for a plain NO), so `liveSessionCount()` would show a
    /// permanent, never-self-healing residual that is a fidelity gap in the
    /// simulated failure, not a real `IMAPProvider` leak. Use this instead of
    /// `failNextCommand`/`failCommand` whenever a test wants to drive one of
    /// those four "dead connection" branches.
    func killConnectionOnNextCommand(containing fragment: String) {
        withState { state in
            state.injectedFailureCountdowns[fragment.uppercased(), default: []]
                .append(InjectedFailure(skip: 0, message: "", killConnection: true))
        }
    }

    /// Two-tier fuzzer (Testing Rule 11) seam — the IDENTITY-RESOLUTION fault,
    /// and the only one of this fake's three that a *successful* command
    /// carries. The next `resolutionCount` whole RESOLUTIONS of `messageId`
    /// answer `* SEARCH` with an EMPTY UID list and a tagged `OK`, while the
    /// message itself stays exactly where it is.
    ///
    /// ⚑ NO REFERENCE — INVENTED (RULE R0). `v2final`'s `FakeIMAPServer` has no
    /// successful-but-empty SEARCH seam and no state field of this shape: the
    /// reference's only injected faults are the tagged-`NO` and socket-kill
    /// pair above, because it never fuzzed identity resolution at all (its
    /// tier-2 adversarial dimension is the epoch reset, and a renumber
    /// PRESERVES every Message-ID, so an RFC-keyed SEARCH still resolves).
    /// There was therefore no reference seam to port and no reference
    /// consumption-accounting shape to match.
    ///
    /// **Why neither existing fault can express this.** `failNextCommand` sends
    /// a tagged `NO`; `killConnectionOnNextCommand` closes the socket with no
    /// response at all. Both are consumed in the dispatch loop BEFORE
    /// `handleCommand` runs, so both surface at the client as a THROWN error.
    /// `IMAPProvider.resolveUID` throws `ProviderError.uidResolutionFailed`
    /// only when a search that SUCCEEDED resolved to zero UIDs — an outcome
    /// neither can produce. Without this seam the drain's entire
    /// identity-resolution phase is unreachable from any wire-level test.
    ///
    /// **Fidelity.** The reply is byte-identical to the one a genuine miss
    /// produces — same `* SEARCH ` line, same tagged OK, emitted from the same
    /// `return` as the ordinary no-match case — so nothing downstream can tell
    /// an armed miss from a real one. That is what makes it a faithful model of
    /// the transient false negative `resolveUID`'s own contract names ("the
    /// message likely exists but SEARCH couldn't find it (server quirk, timing
    /// issue)").
    ///
    /// **The unit is a RESOLUTION, not a command — and that is the whole
    /// point.** `IMAPProvider.searchByMessageId` issues up to TWO searches for
    /// one resolution: the bracketed form first, then the bare form only when
    /// the bracketed one came back empty. An earlier version of this seam
    /// counted COMMANDS, and that made the fault splittable: the bracketed
    /// half could consume one armed miss, a concurrent teardown could break the
    /// connection before the bare half, and a LATER attempt could then spend
    /// the leftover on ITS bracketed half and succeed on its bare one — two
    /// armed misses served, ZERO resolutions failed, `uidResolutionFailed`
    /// never thrown. A fuzzer's non-vacuity guard counting those commands would
    /// green with the dimension it exists to exercise entirely unexercised.
    ///
    /// So the credit is consumed on the BARE half only. The bracketed half is
    /// served empty while a credit is outstanding but spends nothing, which
    /// makes the pair ATOMIC with respect to teardown: a connection that dies
    /// mid-pair leaves the credit intact and the next attempt is dealt a whole
    /// fresh pair. One credit therefore buys exactly one whole EMPTY RESOLUTION
    /// — one indivisible wire event — which is what both the injected-fault
    /// budget and `consumedEmptySearchResolutions()` count.
    ///
    /// **⚠ A whole empty resolution is not the same thing as a thrown
    /// `ProviderError.uidResolutionFailed`, and this comment used to say it
    /// was.** `IMAPProvider.resolveUID` is the only site in the app target that
    /// throws it, but it is NOT `IMAPProvider.searchByMessageId`'s only caller:
    /// `move`'s destination probe (which wraps the call in `try?` and reads
    /// empty as "not yet copied"), `currentUIDs`, `appendToSentFolder`'s dedup
    /// check and the draft-save/stale-draft legs all call it directly, and every
    /// one of them treats an empty result as an ordinary answer rather than a
    /// failure. A credit is therefore consumed by whichever caller reaches the
    /// bare half first, and only the `resolveUID` ones become
    /// `uidResolutionFailed`. Consumption BOUNDS the throws from above; it does
    /// not equal them. A test that needs the throw itself must observe the
    /// throw's own durable side effect and join it to this seam BY IDENTITY.
    ///
    /// `messageId` is matched with angle brackets stripped from both sides, so
    /// either form may be passed.
    ///
    /// Symbol-level citations on purpose: `IMAPProvider.swift` is under active
    /// growth on this branch, so a line range written here is a latent false
    /// claim (this doc comment previously carried three of them). The symbols
    /// are `IMAPProvider.searchByMessageId` (the bracketed-then-bare pair) and
    /// `IMAPProvider.resolveUID` (the sole `uidResolutionFailed` throw site in
    /// the whole app target).
    func returnEmptySearch(forMessageId messageId: String, resolutionCount: Int) {
        let bare = messageId.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        withState { $0.emptySearchResolutionCountdowns[bare, default: 0] += max(0, resolutionCount) }
    }

    /// How many whole armed resolutions this fake has actually driven to empty
    /// — i.e. how many times it served the BARE half of a bracketed-then-bare
    /// pair with zero UIDs. A fuzzer asserts this is non-zero so that an arming
    /// path which silently stopped firing cannot leave the suite a green-always
    /// control.
    ///
    /// ⚠ Two things this does NOT say.
    ///
    /// 1. It is a WIRE-side observation and proves only that the fake did its
    ///    job — never that the drain's failure branch ran. That needs a durable,
    ///    production-written observation, which is why `ProviderIdQueueFuzzTests`
    ///    pairs it with the queue's own `uidResolutionRetryCount` side effect
    ///    rather than resting on it alone.
    /// 2. A served empty bare search is NOT equivalent to a thrown
    ///    `ProviderError.uidResolutionFailed`. `IMAPProvider.resolveUID` is the
    ///    only throw site, but it is not `IMAPProvider.searchByMessageId`'s only
    ///    caller — `move`'s destination probe, `currentUIDs`,
    ///    `appendToSentFolder` and the draft-save legs all call it directly and
    ///    all treat empty as an ordinary answer. So this counts the wire event
    ///    that ENABLES the throw, and bounds the throws from above; it does not
    ///    count throws.
    ///
    /// Use `consumedEmptySearchResolutions()` when the two sides have to be
    /// joined by identity rather than merely both being non-zero.
    func consumedEmptySearchResolutionCount() -> Int {
        withState { $0.consumedEmptySearchResolutionCount }
    }

    /// The same consumption, keyed by bare Message-ID: identity → how many whole
    /// armed resolutions of THAT message this fake drove empty.
    ///
    /// This is what makes a two-sided non-vacuity proof actually two-sided. An
    /// aggregate wire count paired with a durable failure recorded against some
    /// message establishes only that each side is non-zero — the durable failure
    /// may belong to a message whose resolution was never armed, and the served
    /// resolution may belong to a message that never failed durably. Comparing
    /// per identity closes that gap, and gives a per-message upper bound
    /// (see this type's `consumedEmptySearchResolutionCount()` caveat 2 for why
    /// it is a bound and not an equality).
    func consumedEmptySearchResolutions() -> [String: Int] {
        withState { $0.consumedEmptySearchResolutionsByMessageId }
    }

    /// Owner-directed adversarial fuzzer addendum — see `State
    /// .latencyInjection`'s doc comment. `maxMilliseconds` bounds every
    /// injected delay (a fuzzer keeps this small — tens of ms — so a whole
    /// run still finishes within its wall-clock budget even under heavy
    /// concurrent connection churn).
    func setSeededLatencyInjection(seed: UInt64, maxMilliseconds: Int = 50) {
        withState { $0.latencyInjection = LatencyInjection(rng: SplitMix64(seed: seed), maxMilliseconds: maxMilliseconds) }
    }

    /// Per-command chance (out of 100) of a nonzero injected delay — LOGIN
    /// and NOOP are the commands whose REAL round-trip hosts the pool's
    /// documented narrow windows (`createServer()`, the liveness/keepalive
    /// checks), so they are weighted heavily; everything else gets an
    /// occasional smaller chance so the whole wire isn't uniformly slow.
    private static func latencyChancePercent(for command: String) -> Int {
        switch command {
        case "LOGIN": return 95
        case "NOOP": return 60
        case "CAPABILITY": return 30
        case "SELECT", "EXAMINE": return 25
        default: return 8
        }
    }

    /// Draws (and persists the RNG advance for) one delay decision for
    /// `command`, or `nil` when latency injection is off or the coin flip
    /// missed. Called from inside an already-held `withState` closure.
    private func drawLatencyDelayMs(command: String, state: inout State) -> Int? {
        guard var injection = state.latencyInjection else { return nil }
        defer { state.latencyInjection = injection }
        let chance = Self.latencyChancePercent(for: command)
        guard injection.rng.pick(100) < chance else { return nil }
        return 1 + injection.rng.pick(injection.maxMilliseconds)
    }

    func setFlags(_ flags: Set<String>, in mailbox: String, uid: Int) {
        withState { state in
            state.flagsByMailbox[mailbox, default: [:]][uid] = flags
        }
    }

    /// Simulate a mailbox deleted remotely between enqueue and drain: SELECT
    /// (and EXAMINE) of `name` now fails with a NO response, and LIST no
    /// longer reports it present. `includeNonexistentCode`:
    ///   - `true` — NO response carries `[NONEXISTENT]` (RFC 5530 §3), the
    ///     shape some servers send.
    ///   - `false` — plain unstructured `NO select failed` with no response
    ///     code, the non-RFC-5530 shape other real servers send. The provider
    ///     adapter must not rely on parsing this shape at all — the LIST
    ///     probe is the sole authority in both cases.
    func markMailboxDeleted(_ name: String, includeNonexistentCode: Bool) {
        withState { $0.deletedMailboxes[name] = includeNonexistentCode }
    }

    /// Undo `markMailboxDeleted` — the name exists again. Models the second half
    /// of the delete/re-create lifecycle: RFC 3501 §2.3.1.1 requires a re-created
    /// mailbox to report a NEW UIDVALIDITY, which the caller sets with
    /// `setUidValidity(_:for:)`.
    func markMailboxRestored(_ name: String) {
        // `state.…[name] = nil` (assignment ⇒ Void) rather than `removeValue(forKey:)`
        // (⇒ `Bool?`): `withState` is generic in its closure's result and is NOT
        // `@discardableResult` — several call sites genuinely consume the value — so a
        // value-returning body here produced "result of call to 'withState' is unused".
        withState { state in state.deletedMailboxes[name] = nil }
    }

    /// Test seam (ADR-IOS-060 residual closure — UIDVALIDITY reset,
    /// 2026-07-16): set the UIDVALIDITY a mailbox's SELECT/EXAMINE reports
    /// going forward, simulating a server-side reset noticed live by a
    /// client's next SELECT — independent of whatever the local `Folder`
    /// row's `lastKnownUidValidity` still says (that only updates when sync
    /// runs). RFC 3501 requires UIDVALIDITY to be non-decreasing across a
    /// mailbox's lifetime, so callers should only ever raise it.
    func setUidValidity(_ value: Int, for mailbox: String) {
        withState { $0.uidValidityByMailbox[mailbox] = value }
    }

    /// Test seam (T1.2b): make this mailbox's SELECT/EXAMINE omit the
    /// `* OK [UIDVALIDITY n]` untagged response entirely. RFC 3501 §6.3.1 lists
    /// it as SHOULD, not MUST, which is exactly why SwiftMail's
    /// `Mailbox.Selection.uidValidity` is non-optional with a `UIDValidity(0)`
    /// default — a client that trusts that default persists `0` as though it
    /// were an epoch, and every later epoch comparison becomes `0 == 0`.
    /// This is the only seam that produces the OMITTED-line wire shape;
    /// `setUidValidity(0, for:)` would instead send a literal `UIDVALIDITY 0`,
    /// which is not a shape any RFC-conformant server can produce (§2.3.1.1
    /// types UIDVALIDITY as `nz-number`).
    func suppressSelectUidValidity(for mailbox: String) {
        withState { state in _ = state.selectUidValiditySuppressed.insert(mailbox) }
    }

    /// Test seam: replace a mailbox's entire message list. Used to simulate
    /// the renumbering half of a UIDVALIDITY reset — a previously-meaningful
    /// UID now names a completely different ("decoy") message. Flags are
    /// NOT touched here; call `setFlags` separately to give a decoy message a
    /// known baseline distinct from whatever UID it now occupies.
    func setMessages(_ messages: [Message], in mailbox: String) {
        withState { $0.messagesByMailbox[mailbox] = messages }
    }

    /// Two-tier fuzzer (Testing Rule 11), tier-2 seam: every message
    /// CURRENTLY in `mailbox` paired with its current flags, in mailbox
    /// order. Lets a caller simulate a UIDVALIDITY reset FAITHFULLY —
    /// renumbering every message actually present (not just a hardcoded
    /// subset the caller already knows about) while carrying each one's
    /// flags forward to its new UID via `setFlags` — rather than a naive
    /// `setMessages([...fixed list...])` that silently drops (a) any
    /// message a concurrent gesture already placed in the mailbox the
    /// caller didn't account for (e.g. an undo's move-back landing just
    /// before the simulated reset) and (b) every flag already applied
    /// against the pre-reset UID (a real IMAP client addressing a message
    /// under its NEW post-reset UID would still see flags a persisting
    /// message accumulated — the fake losing them was a decoy-construction
    /// bug, not real UIDVALIDITY-reset semantics).
    func snapshotMessagesWithFlags(in mailbox: String) -> [(message: Message, flags: Set<String>)] {
        withState { state in
            (state.messagesByMailbox[mailbox] ?? []).map { msg in
                (msg, state.flagsByMailbox[mailbox]?[msg.uid] ?? [])
            }
        }
    }

    // MARK: - Invariant test layer, deliverable 1: wrong-message wire oracle

    /// Register the rfc822 Message-ID a test's current user intention
    /// targets, BEFORE performing the gesture that admits it. Accepts either
    /// a bracketed (`<id@host>`) or bare (`id@host`) form. OPT-IN — while no
    /// registration has ever been made on this server instance, every
    /// mutating command's check below is a no-op (see `State
    /// .expectedMutationRfcs`'s doc comment).
    ///
    /// Careful with legitimate multi-target ops: sibling expansion by rfc
    /// (the same message's Sent+INBOX copies) shares one rfc — register it
    /// once. A move's destination-append is the SAME message continuing
    /// under a new UID, not a second identity. A dedup delete ahead of an
    /// APPEND (draft re-save) targets the draft's OWN rfc — register that.
    func expectMutation(rfc822MessageId: String) {
        withState { state in _ = state.expectedMutationRfcs.insert(Self.normalizeOracleRfc(rfc822MessageId)) }
    }

    /// Batch convenience for `expectMutation(rfc822MessageId:)`.
    func expectMutations(_ rfc822MessageIds: some Sequence<String>) {
        withState { state in
            for id in rfc822MessageIds { state.expectedMutationRfcs.insert(Self.normalizeOracleRfc(id)) }
        }
    }

    /// Clears every registration — an empty set returns the oracle to
    /// silent. Call between phases/cells that want independently-scoped
    /// registrations (a stale registration from an earlier phase would mask
    /// a later phase's genuine violation by accident).
    func resetMutationExpectations() {
        withState { $0.expectedMutationRfcs = [] }
    }

    /// Every violation recorded since server start (or the last
    /// `clearWrongMessageViolations()`) — the "violations property" tests
    /// assert empty in teardown.
    func wrongMessageViolations() -> [WrongMessageViolation] {
        withState { $0.wrongMessageViolations }
    }

    /// Clears the violations log (distinct from `resetMutationExpectations()`,
    /// which only clears registrations). Rarely needed — most callers just
    /// assert `wrongMessageViolations().isEmpty` once, at the end.
    func clearWrongMessageViolations() {
        withState { $0.wrongMessageViolations = [] }
    }

    private static func normalizeOracleRfc(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    /// Core check, called from INSIDE an already-held `withState` closure at
    /// every mutating command (STORE/MOVE/COPY/EXPUNGE, plain or
    /// UID-addressed), BEFORE the mutation is applied to `state`. Resolves
    /// each targeted UID to `mailbox`'s CURRENT occupant — the message about
    /// to be mutated — and records a violation when that occupant's
    /// Message-ID isn't in the registered set. A UID with no current
    /// occupant (e.g. a STORE racing an already-EXPUNGEd UID) has nothing to
    /// check and is silently skipped.
    ///
    /// ADR-IOS-061 item E (R4 hygiene): the checked-site set above
    /// (STORE/MOVE/COPY/EXPUNGE) is exhaustive only as long as every
    /// sequence-number/UID-mutating command routes through here — any
    /// FUTURE command handler this fake gains that reassigns/removes a
    /// message at a UID (e.g. a new STORE variant, RENAME with implicit UID
    /// reassignment) MUST call `recordOracleCheck` too, or the oracle goes
    /// silently blind to that command's wrong-message hazard.
    private func recordOracleCheck(command: String, mailbox: String, uids: some Sequence<Int>, state: inout State) {
        guard !state.expectedMutationRfcs.isEmpty else { return }
        let messages = state.messagesByMailbox[mailbox] ?? []
        let byUid = Dictionary(uniqueKeysWithValues: messages.map { ($0.uid, $0) })
        for uid in uids {
            guard let msg = byUid[uid] else { continue }
            let actualRfc = Self.normalizeOracleRfc(msg.messageID)
            guard !state.expectedMutationRfcs.contains(actualRfc) else { continue }
            state.wrongMessageViolations.append(WrongMessageViolation(
                command: command, mailbox: mailbox, uid: uid,
                expectedRfcs: state.expectedMutationRfcs, actualRfc: actualRfc
            ))
        }
    }

    enum ServerError: Error {
        case setup(String)
    }

    func start() throws {
        #if os(Linux)
        listenFd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        listenFd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard listenFd >= 0 else { throw ServerError.setup("socket() failed: \(errno)") }

        var yes: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        #if !os(Linux)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenFd)
            throw ServerError.setup("bind() failed: \(errno)")
        }

        guard listen(listenFd, 5) == 0 else {
            close(listenFd)
            throw ServerError.setup("listen() failed: \(errno)")
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFd, $0, &addrLen)
            }
        }
        self.port = Int(UInt16(bigEndian: boundAddr.sin_port))

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFd, fd >= 0 {
                close(fd)
                self?.listenFd = -1
            }
        }
        self.acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        let fds = takeAllClientFds()
        // R12-F1 exclusion (ii): mark these fds test-initiated BEFORE the
        // raw `close(fd)` below — this is test teardown tearing down every
        // still-open connection (including perfectly healthy, still-in-use
        // ones), not an abandoned session a production leak forgot to log
        // out. `handleClient`'s client-loop-exit path still runs
        // `closeClientFd(fd)` asynchronously once it notices the socket
        // closed (this only cleared `clientFds`, so that later call is a
        // close no-op but still does the `sessionsEndedWithoutLogout`
        // bookkeeping) — marking here, before that happens, is what lets it
        // see the exclusion.
        withState { state in
            for fd in fds { _ = state.testInitiatedCloseFds.insert(fd) }
        }
        for fd in fds { close(fd) }
    }

    // MARK: - Message Builder

    /// Build a `Message` from an RFC 2822 text document with CRLF line endings.
    /// Parses a minimum set of headers and splits header/body on the first
    /// `CRLF CRLF`. `contentType` defaults to text/plain when the Content-Type
    /// header is missing.
    static func makeMessage(uid: Int, rfc822Text: String) -> Message {
        let raw = Data(rfc822Text.utf8)
        let headerEnd = raw.range(of: Data("\r\n\r\n".utf8))
            ?? raw.range(of: Data("\n\n".utf8))
        let headerData: Data
        let body: Data
        if let r = headerEnd {
            headerData = Data(raw[..<r.upperBound])
            body = Data(raw[r.upperBound...])
        } else {
            headerData = raw
            body = Data()
        }
        let headers = String(data: headerData, encoding: .utf8) ?? ""

        func header(_ name: String) -> String {
            let pattern = "(?m)^\(name):[ \t]*(.+?)[ \t]*$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..., in: headers)),
                  let range = Range(match.range(at: 1), in: headers) else { return "" }
            return String(headers[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let ctRaw = header("Content-Type")
        let ct: String
        let charset: String
        if ctRaw.contains(";") {
            let parts = ctRaw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            ct = parts[0]
            charset = parts.first(where: { $0.lowercased().hasPrefix("charset=") })
                .map { String($0.dropFirst("charset=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } ?? "utf-8"
        } else {
            ct = ctRaw.isEmpty ? "text/plain" : ctRaw
            charset = "utf-8"
        }

        let dateStr = header("Date")
        let internalDate: String
        // Use the shared RFC 2822 parser — accepts both "1 Oct" and "01 Oct"
        // (single-digit and zero-padded days), per RFC 5322 §3.3.
        if let date = EmailDateParsing.rfc2822.date(from: dateStr) {
            let imap = DateFormatter()
            imap.locale = Locale(identifier: "en_US_POSIX")
            imap.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
            internalDate = imap.string(from: date)
        } else {
            internalDate = "01-Jan-2026 00:00:00 +0000"
        }

        return Message(
            uid: uid,
            raw: raw,
            subject: header("Subject"),
            from: header("From"),
            to: header("To"),
            date: dateStr,
            internalDate: internalDate,
            messageID: header("Message-ID"),
            contentType: ct,
            charset: charset,
            body: body,
            headerData: headerData,
            customBodystructure: nil,
            partBodies: nil
        )
    }

    /// Build a `Message` with a custom multipart/rfc822 BODYSTRUCTURE and
    /// per-section body bodies. Use when the auto-parsed flat shape from
    /// `makeMessage(uid:rfc822Text:)` is insufficient — e.g., multipart
    /// bodies or nested `message/rfc822` parts.
    ///
    /// `headerData` is the top-level RFC 2822 headers (the part the client
    /// gets when it asks for `BODY[HEADER]`). `raw` is the full message bytes.
    static func makeMultipartMessage(
        uid: Int,
        subject: String,
        from: String,
        to: String,
        date: String,
        internalDate: String,
        messageID: String,
        rawHeader: String,
        fullMessage: Data,
        bodystructure: String,
        partBodies: [String: Data]
    ) -> Message {
        let header = Data(rawHeader.utf8)
        return Message(
            uid: uid,
            raw: fullMessage,
            subject: subject,
            from: from,
            to: to,
            date: date,
            internalDate: internalDate,
            messageID: messageID,
            contentType: "multipart/mixed",
            charset: "utf-8",
            body: Data(),
            headerData: header,
            customBodystructure: bodystructure,
            partBodies: partBodies
        )
    }

    // MARK: - Connection Handling

    private func acceptClient() {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFd, $0, &addrLen)
            }
        }
        guard clientFd >= 0 else { return }
        trackClientFd(clientFd)

        DispatchQueue.global().async { [weak self] in
            self?.handleClient(fd: clientFd)
        }
    }

    private func handleClient(fd: Int32) {
        sendLine(fd: fd, "* OK [CAPABILITY \(capabilities.joined(separator: " "))] FakeIMAP ready\r\n")

        var buffer = Data()
        var authenticated = false
        var selectedMailbox: String?
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { readBuf.deallocate() }

        var idleTag: String? = nil

        /// Blocking read of more bytes into `buffer`. Returns false when the
        /// connection closed (caller must stop processing this client).
        func readMore() -> Bool {
            let n = read(fd, readBuf, 65536)
            guard n > 0 else { return false }
            buffer.append(readBuf, count: n)
            return true
        }

        clientLoop: while true {
            if !readMore() { break }

            while let crlfRange = buffer.range(of: Data("\r\n".utf8)) {
                var lineData = buffer[buffer.startIndex..<crlfRange.lowerBound]
                var consumedThrough = crlfRange.upperBound

                // IMAP literal handling (RFC 3501 §4.3, RFC 7888 non-
                // synchronizing literals). NIOIMAP switches a long/otherwise
                // "unsafe" quoted-string argument (e.g. a HEADER search
                // criterion value) to a trailing `{N}` / `{N+}` literal
                // marker followed by exactly N raw bytes, then the command's
                // own terminating CRLF. This fake only ever needs to splice
                // ONE trailing literal per logical command line back in as a
                // quoted string — the CAPABILITY response above already
                // advertises LITERAL+, so a client is entitled to send one.
                while let spec = Self.trailingLiteralSpec(lineData) {
                    if spec.needsContinuationResponse {
                        sendLine(fd: fd, "+ OK\r\n")
                    }
                    while buffer.count < consumedThrough + spec.length {
                        if !readMore() { break clientLoop }
                    }
                    let literalBytes = buffer[consumedThrough..<(consumedThrough + spec.length)]
                    let literalString = String(data: literalBytes, encoding: .utf8) ?? ""
                    var afterLiteral = consumedThrough + spec.length
                    while buffer.count < afterLiteral + 2 {
                        if !readMore() { break clientLoop }
                    }
                    // The literal's raw bytes are followed by the command's
                    // own terminating CRLF (RFC 3501 literal syntax — no
                    // other separator is valid here).
                    guard buffer[afterLiteral] == 0x0D, buffer[afterLiteral + 1] == 0x0A else { break clientLoop }
                    afterLiteral += 2
                    lineData = Self.splicingLiteral(into: lineData, literal: literalString)
                    consumedThrough = afterLiteral
                }

                buffer = Data(buffer[consumedThrough...])
                guard let line = String(data: lineData, encoding: .utf8) else { continue }

                if let tag = idleTag, line.uppercased() == "DONE" {
                    // Recorded like any command (DONE is an IDLE
                    // continuation line, RFC 2177 — it never reaches the
                    // tagged-command parser below, so it must be logged
                    // here). Lets a test assert the "teardown sends DONE
                    // for an active IDLE session" invariant (the
                    // markDirty-IDLE fix's pin).
                    withState { $0.commandLog.append("DONE") }
                    sendLine(fd: fd, "\(tag) OK IDLE terminated\r\n")
                    idleTag = nil
                    continue
                }

                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else {
                    sendLine(fd: fd, "* BAD Invalid command\r\n")
                    continue
                }

                let tag = parts[0]
                let command = parts[1].uppercased()
                let args = parts.count > 2 ? parts[2] : ""
                let recordedCommand = ([command] + (args.isEmpty ? [] : [args])).joined(separator: " ")
                let matchedFailure: InjectedFailure? = withState { state -> InjectedFailure? in
                    state.commandLog.append(recordedCommand)
                    let upper = recordedCommand.uppercased()
                    guard let key = state.injectedFailureCountdowns.keys.sorted().first(where: {
                        upper.contains($0) && !(state.injectedFailureCountdowns[$0] ?? []).isEmpty
                    }), var countdowns = state.injectedFailureCountdowns[key]
                    else { return nil }
                    if countdowns[0].skip == 0 {
                        let failure = countdowns[0]
                        countdowns.removeFirst()
                        state.injectedFailureCountdowns[key] = countdowns
                        state.consumedInjectedFailureCount += 1
                        return failure
                    }
                    countdowns[0].skip -= 1
                    state.injectedFailureCountdowns[key] = countdowns
                    return nil
                }
                if let matchedFailure {
                    if matchedFailure.killConnection {
                        // Real dead TCP connection, not a protocol-level NO
                        // — no response at all. `loggedInFds` drops here too
                        // (not just in `closeClientFd`'s defensive cleanup)
                        // so `liveSessionCount()` reflects the death
                        // immediately, matching the wire reality this
                        // simulates.
                        // R12-F1 exclusion (i): this is the fuzzer's own
                        // deliberate fault injection simulating a genuinely
                        // dead transport, not an abandoned-but-still-alive
                        // `IMAPServer` a leak forgot to log out — excluded
                        // from `sessionsEndedWithoutLogout` via
                        // `testInitiatedCloseFds` (checked in
                        // `closeClientFd`, which the client-loop-exit path
                        // below still reaches after `break clientLoop`).
                        withState { state in
                            _ = state.loggedInFds.remove(fd)
                            _ = state.testInitiatedCloseFds.insert(fd)
                        }
                        break clientLoop
                    }
                    sendLine(fd: fd, "\(tag) NO \(matchedFailure.message)\r\n")
                    continue
                }

                if command == "IDLE" {
                    sendLine(fd: fd, "+ idling\r\n")
                    idleTag = tag
                    continue
                }

                // Owner-directed adversarial fuzzer addendum: seeded
                // per-command latency (see `State.latencyInjection`) —
                // BLOCKING is fine here (this client's own dedicated
                // `DispatchQueue.global()` task, already blocking in
                // `readMore()` between commands; delaying its response
                // doesn't stall any OTHER connection).
                if let delayMs = withState({ drawLatencyDelayMs(command: command, state: &$0) }) {
                    usleep(UInt32(delayMs * 1000))
                }
                let response = handleCommand(
                    tag: tag, command: command, args: args, fd: fd,
                    authenticated: &authenticated, selectedMailbox: &selectedMailbox
                )
                sendLine(fd: fd, response)
                if response.uppercased().contains("\(tag.uppercased()) OK") {
                    withState { state in
                        let upper = recordedCommand.uppercased()
                        guard let index = state.postResponseMailboxResets.firstIndex(where: {
                            upper.contains($0.commandFragment)
                        }) else { return }
                        let reset = state.postResponseMailboxResets.remove(at: index)
                        state.messagesByMailbox[reset.mailbox] = reset.messages
                        state.flagsByMailbox[reset.mailbox] = reset.flagsByUID
                        state.uidValidityByMailbox[reset.mailbox] = reset.uidValidity
                    }
                }

                if command == "LOGOUT" {
                    closeClientFd(fd)
                    return
                }
            }
        }

        closeClientFd(fd)
    }

    private func sendLine(fd: Int32, _ text: String) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, ptr + sent, data.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    // MARK: - Command Handling

    private func handleCommand(tag: String, command: String, args: String, fd: Int32, authenticated: inout Bool, selectedMailbox: inout String?) -> String {
        switch command {
        case "CAPABILITY":
            return "* CAPABILITY \(capabilities.joined(separator: " "))\r\n\(tag) OK CAPABILITY completed\r\n"
        case "LOGIN":
            authenticated = true
            withState { state in
                _ = state.loggedInFds.insert(fd)
                // R12-F1: recorded separately from `loggedInFds` — see that
                // field's doc comment for why (it gets cleared early by
                // LOGOUT/kill, so it can't answer "did this fd EVER log in").
                _ = state.everLoggedInFds.insert(fd)
            }
            return "\(tag) OK LOGIN completed\r\n"
        case "SELECT", "EXAMINE":
            guard authenticated else { return "\(tag) NO Not authenticated\r\n" }
            let mailbox = args.trimmingCharacters(in: .init(charactersIn: "\" "))
            if let includeNonexistentCode = withState({ $0.deletedMailboxes[mailbox] }) {
                // Deliberately two distinct real-world shapes: `[NONEXISTENT]`
                // (RFC 5530 §3) is a fast-path HINT the adapter may use, but
                // never the sole authority — a plain, code-less NO is exactly
                // as authoritative-refusable once the adapter's LIST probe
                // (not this response text) confirms absence.
                return includeNonexistentCode
                    ? "\(tag) NO [NONEXISTENT] Mailbox does not exist\r\n"
                    : "\(tag) NO Mailbox does not exist\r\n"
            }
            selectedMailbox = mailbox
            let (messages, uidValidity, suppressUidValidity) = withState { state in
                (
                    state.messagesByMailbox[mailbox] ?? [],
                    state.uidValidityByMailbox[mailbox] ?? 1,
                    state.selectUidValiditySuppressed.contains(mailbox)
                )
            }
            let count = messages.count
            let uidnext = (messages.map(\.uid).max() ?? 0) + 1
            // `suppressSelectUidValidity` drops the line entirely rather than
            // sending `UIDVALIDITY 0` — a real server never sends 0 (it is an
            // `nz-number`), so omission is the only faithful way to reach the
            // client-side default of `UIDValidity(0)`.
            let uidValidityLine = suppressUidValidity
                ? ""
                : "* OK [UIDVALIDITY \(uidValidity)] UIDs valid\r\n"
            return """
            * \(count) EXISTS\r
            * 0 RECENT\r
            \(uidValidityLine)* OK [UIDNEXT \(uidnext)] Predicted next UID\r
            * FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r
            * OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft \\*)] Flags permitted\r
            \(tag) OK [READ-WRITE] SELECT completed\r

            """
        case "STATUS":
            guard authenticated else { return "\(tag) NO Not authenticated\r\n" }
            return handleStatus(tag: tag, args: args)
        case "UID":
            guard let selectedMailbox else { return "\(tag) NO No mailbox selected\r\n" }
            return handleUID(tag: tag, args: args, mailbox: selectedMailbox)
        case "FETCH":
            guard let selectedMailbox else { return "\(tag) NO No mailbox selected\r\n" }
            return handleFetch(tag: tag, args: args, uidMode: false, mailbox: selectedMailbox)
        case "NAMESPACE":
            return "* NAMESPACE ((\"\" \"/\")) NIL NIL\r\n\(tag) OK NAMESPACE completed\r\n"
        case "LIST":
            // Reflects actual mailbox presence (unlike the old static "always
            // INBOX" stub) so `mailboxConfirmedAbsent`'s LIST probe is
            // meaningfully exercised: a name is "present" only if it has a
            // `messagesByMailbox` entry and was never `markMailboxDeleted`.
            let pattern = args.replacingOccurrences(of: "\"", with: "")
                .split(separator: " ").map(String.init).last ?? "*"
            let matches: [String] = withState { state in
                state.messagesByMailbox.keys
                    .filter { state.deletedMailboxes[$0] == nil }
                    .filter { Self.imapListPatternMatches(pattern: pattern, name: $0) }
                    .sorted()
            }
            var response = matches.map { "* LIST (\\HasNoChildren) \"/\" \"\($0)\"\r\n" }.joined()
            response += "\(tag) OK LIST completed\r\n"
            return response
        case "ID":
            return "* ID NIL\r\n\(tag) OK ID completed\r\n"
        case "EXPUNGE":
            // Plain (non-UID) EXPUNGE — RFC 3501 §6.4.3. Mailbox-WIDE: removes
            // every \Deleted-flagged message in the SELECTed mailbox, not just
            // a targeted set. This is what SwiftMail's MOVE fallback issues
            // when UIDPLUS is absent (`expungeMoveFallback`, SPEC-B4).
            guard let selectedMailbox else { return "\(tag) NO No mailbox selected\r\n" }
            withState { state in
                let sourceMessages = state.messagesByMailbox[selectedMailbox] ?? []
                let mailboxFlags = state.flagsByMailbox[selectedMailbox] ?? [:]
                let deletedUIDs = Set(sourceMessages.map(\.uid).filter { mailboxFlags[$0]?.contains("\\Deleted") ?? false })
                recordOracleCheck(command: "EXPUNGE", mailbox: selectedMailbox, uids: deletedUIDs, state: &state)
                state.messagesByMailbox[selectedMailbox] = sourceMessages.filter { !deletedUIDs.contains($0.uid) }
                for uid in deletedUIDs {
                    state.flagsByMailbox[selectedMailbox]?.removeValue(forKey: uid)
                }
            }
            return "\(tag) OK EXPUNGE completed\r\n"
        case "NOOP":
            return "\(tag) OK NOOP completed\r\n"
        case "LOGOUT":
            withState {
                _ = $0.loggedInFds.remove(fd)
                $0.logoutFdLog.append(fd)
                // R12-F1: marks this session as "ended cleanly" for
                // `sessionsEndedWithoutLogout`'s predicate (consulted in
                // `closeClientFd`).
                _ = $0.loggedOutFds.insert(fd)
            }
            return "* BYE IMAP server shutting down\r\n\(tag) OK LOGOUT completed\r\n"
        case "APPEND":
            guard authenticated else { return "\(tag) NO Not authenticated\r\n" }
            return handleAppend(tag: tag, args: args)
        default:
            return "\(tag) BAD Unknown command \(command)\r\n"
        }
    }

    /// STATUS (RFC 3501 §6.3.10) — the command IMAP delta sync uses to decide
    /// whether a folder changed WITHOUT selecting it. Answers only the
    /// attributes the client actually requested, so a capability the fake does
    /// not advertise stays genuinely absent from the reply (CONDSTORE's
    /// `HIGHESTMODSEQ` is the case that matters: SwiftMail only asks for it
    /// when the server advertises CONDSTORE, and inventing it here would let a
    /// test pass against a server shape that cannot exist). Does NOT change the
    /// connection's selected mailbox — that is the whole point of STATUS.
    private func handleStatus(tag: String, args: String) -> String {
        guard let openParen = args.firstIndex(of: "(") else {
            return "\(tag) BAD STATUS requires an attribute list\r\n"
        }
        let mailbox = args[args.startIndex..<openParen]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: .init(charactersIn: "\""))
        if withState({ $0.deletedMailboxes[mailbox] }) != nil {
            return "\(tag) NO Mailbox does not exist\r\n"
        }
        let closeParen = args.firstIndex(of: ")") ?? args.endIndex
        let requested = args[args.index(after: openParen)..<closeParen]
            .split(separator: " ")
            .map { $0.uppercased() }

        let (count, unseen, uidNext, uidValidity) = withState { state -> (Int, Int, Int, Int) in
            let messages = state.messagesByMailbox[mailbox] ?? []
            let flags = state.flagsByMailbox[mailbox] ?? [:]
            let unseen = messages.filter { !(flags[$0.uid]?.contains("\\Seen") ?? false) }.count
            return (
                messages.count,
                unseen,
                (messages.map(\.uid).max() ?? 0) + 1,
                state.uidValidityByMailbox[mailbox] ?? 1
            )
        }

        var parts: [String] = []
        for attribute in requested {
            switch attribute {
            case "MESSAGES": parts.append("MESSAGES \(count)")
            case "RECENT": parts.append("RECENT 0")
            case "UNSEEN": parts.append("UNSEEN \(unseen)")
            case "UIDNEXT": parts.append("UIDNEXT \(uidNext)")
            case "UIDVALIDITY": parts.append("UIDVALIDITY \(uidValidity)")
            default: continue // an attribute this fake does not model — never invent one
            }
        }
        return "* STATUS \"\(mailbox)\" (\(parts.joined(separator: " ")))\r\n\(tag) OK STATUS completed\r\n"
    }

    /// RFC 3501 §6.3.11 APPEND — `mailbox [(flags)] ["date-time"] {N}<literal>`.
    /// By the time this runs, the outer line-reader has already spliced the
    /// trailing `{N}` literal back in as an escaped quoted string
    /// (`splicingLiteral`), so `args` is one flat string to hand-parse.
    /// Reuses `makeMessage(uid:rfc822Text:)` to build the stored `Message`
    /// from the literal's raw bytes — the SAME parser real fixture messages
    /// go through, so an appended draft round-trips with a correctly
    /// populated `messageID`/subject/etc.
    private func handleAppend(tag: String, args: String) -> String {
        var remaining = Substring(args)

        let mailbox: String
        if remaining.first == "\"" {
            remaining = remaining.dropFirst()
            guard let closeIdx = remaining.firstIndex(of: "\"") else {
                return "\(tag) BAD malformed APPEND (mailbox)\r\n"
            }
            mailbox = String(remaining[remaining.startIndex..<closeIdx])
            remaining = remaining[remaining.index(after: closeIdx)...]
        } else {
            guard let spaceIdx = remaining.firstIndex(of: " ") else {
                return "\(tag) BAD malformed APPEND (mailbox)\r\n"
            }
            mailbox = String(remaining[remaining.startIndex..<spaceIdx])
            remaining = remaining[spaceIdx...]
        }
        remaining = remaining.drop { $0 == " " }

        var flags: Set<String> = []
        if remaining.first == "(" {
            guard let closeIdx = remaining.firstIndex(of: ")") else {
                return "\(tag) BAD malformed APPEND (flags)\r\n"
            }
            let inside = remaining[remaining.index(after: remaining.startIndex)..<closeIdx]
            flags = Set(inside.split(separator: " ").map(String.init))
            remaining = remaining[remaining.index(after: closeIdx)...]
            remaining = remaining.drop { $0 == " " }
        }

        // Optional quoted date-time — present iff ANOTHER quoted token
        // (the message literal) follows it.
        if remaining.first == "\"" {
            let afterOpen = remaining.index(after: remaining.startIndex)
            if let closeIdx = remaining[afterOpen...].firstIndex(of: "\"") {
                let afterThis = remaining[remaining.index(after: closeIdx)...].drop { $0 == " " }
                if afterThis.first == "\"" {
                    remaining = afterThis
                }
            }
        }

        guard remaining.first == "\"" else {
            return "\(tag) BAD malformed APPEND (message)\r\n"
        }
        let afterOpen = remaining.index(after: remaining.startIndex)
        guard let closeIdx = remaining[afterOpen...].lastIndex(of: "\"") else {
            return "\(tag) BAD malformed APPEND (message)\r\n"
        }
        let raw = String(remaining[afterOpen..<closeIdx])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")

        let (newUID, uidvalidity) = withState { state -> (Int, Int) in
            let existing = state.messagesByMailbox[mailbox] ?? []
            let nextUID = (existing.map(\.uid).max() ?? 0) + 1
            let message = Self.makeMessage(uid: nextUID, rfc822Text: raw)
            state.messagesByMailbox[mailbox, default: []].append(message)
            if !flags.isEmpty { state.flagsByMailbox[mailbox, default: [:]][nextUID] = flags }
            return (nextUID, state.uidValidityByMailbox[mailbox] ?? 1)
        }

        // RFC 4315 UIDPLUS — the APPENDUID response code is only advertisable
        // by a server that supports the UIDPLUS extension. Mirrors the UID
        // EXPUNGE vs. plain-EXPUNGE branch this fake and IMAPProvider already
        // apply for the destructive-delete path (`server.supportsUIDPlus`):
        // UID assignment/bookkeeping above is IDENTICAL either way — only the
        // wire advertisement changes, so a no-UIDPLUS fixture faithfully
        // forces IMAPProvider's saveDraft into its no-APPENDUID search-verify
        // fallback arm instead of silently still handing it APPENDUID.
        guard capabilities.contains("UIDPLUS") else {
            return "\(tag) OK APPEND completed\r\n"
        }
        return "\(tag) OK [APPENDUID \(uidvalidity) \(newUID)] APPEND completed\r\n"
    }

    private func handleUID(tag: String, args: String, mailbox: String) -> String {
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard let subcmd = parts.first?.uppercased() else {
            return "\(tag) BAD Missing UID subcommand\r\n"
        }
        let subargs = parts.count > 1 ? parts[1] : ""
        switch subcmd {
        case "FETCH":
            return handleFetch(tag: tag, args: subargs, uidMode: true, mailbox: mailbox)
        case "SEARCH":
            // Honor HEADER "Message-ID" "<...>" criterion when present; otherwise
            // return all UIDs (legacy behavior). Minimal filter to support
            // IMAPProvider's messageExistsInFolder / idempotentMove probe path.
            let upper = subargs.uppercased()
            if let range = upper.range(of: "HEADER \"MESSAGE-ID\"") {
                // Next quoted string after the criterion is the Message-ID pattern.
                let after = subargs[range.upperBound...]
                let quoted = Self.firstQuoted(String(after)) ?? ""
                // Strip any angle brackets on both sides. `messageID` comes
                // from the raw header value and typically includes "<...>".
                let bracketSet = CharacterSet(charactersIn: "<>")
                let bareQuery = quoted.trimmingCharacters(in: bracketSet)
                // `IMAPProvider.searchByMessageId` asks the bracketed form
                // (`"<id>"`) first and the bare form (`"id"`) only when that
                // came back empty, so the presence of the angle brackets IS
                // which half of the resolution pair this command is.
                let isBracketedHalf = quoted.hasPrefix("<")
                // Identity-resolution fault seam — see
                // `returnEmptySearch(forMessageId:resolutionCount:)`. Consumed
                // HERE rather than in the pre-dispatch injected-failure check
                // because this fault's defining property is that the command
                // SUCCEEDS: it takes the same `return` below as a genuine miss,
                // so the two are indistinguishable on the wire.
                //
                // Both halves are answered empty while a credit is outstanding,
                // but only the BARE half SPENDS it. That keeps the pair atomic
                // against a teardown landing between the two commands: the
                // credit survives, the next attempt is dealt a whole fresh
                // pair, and one credit still means exactly one thrown
                // `uidResolutionFailed`. Spending on the bracketed half instead
                // would let a broken pair strand a half-credit that a later
                // attempt consumes without ever failing a resolution — see the
                // seam's doc comment.
                let armedEmpty = withState { state -> Bool in
                    guard let remaining = state.emptySearchResolutionCountdowns[bareQuery], remaining > 0 else {
                        return false
                    }
                    if !isBracketedHalf {
                        state.emptySearchResolutionCountdowns[bareQuery] = remaining - 1
                        state.consumedEmptySearchResolutionCount += 1
                        // Same event, recorded WITH its identity. The aggregate
                        // counter above cannot be joined to anything: a durable
                        // side effect attributed to message A is not evidence
                        // that A's resolution was the one driven empty when the
                        // only wire figure available is a total across all
                        // messages. Keyed, the two halves of a non-vacuity proof
                        // can be compared per identity instead of merely both
                        // being non-zero.
                        state.consumedEmptySearchResolutionsByMessageId[bareQuery, default: 0] += 1
                    }
                    return true
                }
                let matched: [String]
                if armedEmpty {
                    matched = []
                } else {
                    matched = withState { $0.messagesByMailbox[mailbox] ?? [] }
                        .filter {
                            $0.messageID.trimmingCharacters(in: bracketSet).contains(bareQuery)
                        }
                        .map { String($0.uid) }
                }
                return "* SEARCH \(matched.joined(separator: " "))\r\n\(tag) OK UID SEARCH completed\r\n"
            }
            let uids = withState { $0.messagesByMailbox[mailbox] ?? [] }
                .map { String($0.uid) }
                .joined(separator: " ")
            return "* SEARCH \(uids)\r\n\(tag) OK UID SEARCH completed\r\n"
        case "STORE":
            let components = subargs.split(separator: " ", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return "\(tag) BAD Invalid UID STORE\r\n" }
            let uids = parseUIDSet(components[0])
            let operation = components[1].uppercased()
            let flags = Self.parenthesizedTokens(components[1])
            withState { state in
                recordOracleCheck(command: "UID STORE \(operation)", mailbox: mailbox, uids: uids, state: &state)
                var mailboxFlags = state.flagsByMailbox[mailbox] ?? [:]
                for uid in uids {
                    var current = mailboxFlags[uid] ?? []
                    if operation.contains("+FLAGS") {
                        current.formUnion(flags)
                    } else if operation.contains("-FLAGS") {
                        current.subtract(flags)
                    } else {
                        current = flags
                    }
                    mailboxFlags[uid] = current
                }
                state.flagsByMailbox[mailbox] = mailboxFlags
            }
            return "\(tag) OK UID STORE completed\r\n"
        case "MOVE":
            let components = subargs.split(separator: " ", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return "\(tag) BAD Invalid UID MOVE\r\n" }
            let uids = Set(parseUIDSet(components[0]))
            let destination = components[1].trimmingCharacters(in: .init(charactersIn: "\""))
            withState { state in
                recordOracleCheck(command: "UID MOVE", mailbox: mailbox, uids: uids, state: &state)
                let sourceMessages = state.messagesByMailbox[mailbox] ?? []
                let moving = sourceMessages.filter { uids.contains($0.uid) }
                state.messagesByMailbox[mailbox] = sourceMessages.filter { !uids.contains($0.uid) }

                var destinationMessages = state.messagesByMailbox[destination] ?? []
                var nextUID = (destinationMessages.map(\.uid).max() ?? 0) + 1
                var sourceFlags = state.flagsByMailbox[mailbox] ?? [:]
                var destinationFlags = state.flagsByMailbox[destination] ?? [:]
                for message in moving {
                    destinationMessages.append(message.replacingUID(nextUID))
                    destinationFlags[nextUID] = sourceFlags.removeValue(forKey: message.uid) ?? []
                    nextUID += 1
                }
                state.messagesByMailbox[destination] = destinationMessages
                state.flagsByMailbox[mailbox] = sourceFlags
                state.flagsByMailbox[destination] = destinationFlags
            }
            return "\(tag) OK UID MOVE completed\r\n"
        case "EXPUNGE":
            let uids = Set(parseUIDSet(subargs))
            withState { state in
                recordOracleCheck(command: "UID EXPUNGE", mailbox: mailbox, uids: uids, state: &state)
                let sourceMessages = state.messagesByMailbox[mailbox] ?? []
                state.messagesByMailbox[mailbox] = sourceMessages.filter { !uids.contains($0.uid) }
                for uid in uids {
                    state.flagsByMailbox[mailbox]?.removeValue(forKey: uid)
                }
            }
            return "\(tag) OK UID EXPUNGE completed\r\n"
        case "COPY":
            // RFC 3501 §6.4.7 — leaves the SOURCE untouched, unlike MOVE.
            // This is the first step of SwiftMail's no-MOVE-capability
            // fallback (COPY + STORE \Deleted + EXPUNGE, SPEC-B4).
            let components = subargs.split(separator: " ", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return "\(tag) BAD Invalid UID COPY\r\n" }
            let uids = Set(parseUIDSet(components[0]))
            let destination = components[1].trimmingCharacters(in: .init(charactersIn: "\""))
            withState { state in
                recordOracleCheck(command: "UID COPY", mailbox: mailbox, uids: uids, state: &state)
                let sourceMessages = state.messagesByMailbox[mailbox] ?? []
                let copying = sourceMessages.filter { uids.contains($0.uid) }
                var destinationMessages = state.messagesByMailbox[destination] ?? []
                var nextUID = (destinationMessages.map(\.uid).max() ?? 0) + 1
                let sourceFlags = state.flagsByMailbox[mailbox] ?? [:]
                var destinationFlags = state.flagsByMailbox[destination] ?? [:]
                for message in copying {
                    destinationMessages.append(message.replacingUID(nextUID))
                    destinationFlags[nextUID] = sourceFlags[message.uid] ?? []
                    nextUID += 1
                }
                state.messagesByMailbox[destination] = destinationMessages
                state.flagsByMailbox[destination] = destinationFlags
            }
            return "\(tag) OK UID COPY completed\r\n"
        default:
            return "\(tag) BAD Unknown UID subcommand\r\n"
        }
    }

    private func parseUIDSet(_ value: String) -> [Int] {
        value.split(separator: ",").flatMap { component -> [Int] in
            let bounds = component.split(separator: ":").compactMap { Int($0) }
            // `bounds[0] <= bounds[1]` is NOT redundant with the count check.
            // `Array(5...2)` is a `fatalError`, not a thrown error, so a
            // descending range — syntactically valid IMAP, and reachable from
            // any randomized/fuzzed command stream — would kill the ENTIRE test
            // process and take every unrelated result with it, rather than
            // failing one case. A malformed set resolves to no UIDs instead.
            if bounds.count == 2, bounds[0] <= bounds[1] {
                return Array(bounds[0]...bounds[1])
            }
            return bounds.first.map { [$0] } ?? []
        }
    }

    private static func parenthesizedTokens(_ value: String) -> Set<String> {
        guard let open = value.firstIndex(of: "("),
              let close = value[open...].firstIndex(of: ")") else { return [] }
        return Set(value[value.index(after: open)..<close].split(separator: " ").map(String.init))
    }

    /// Extract the first quoted token from a fragment. Used to parse
    /// `HEADER "Message-ID" "<id>"` arguments without a full tokenizer.
    private static func firstQuoted(_ s: String) -> String? {
        guard let open = s.firstIndex(of: "\"") else { return nil }
        let afterOpen = s.index(after: open)
        guard let close = s[afterOpen...].firstIndex(of: "\"") else { return nil }
        return String(s[afterOpen..<close])
    }

    /// Detects a trailing IMAP literal marker (`{N}` or `{N+}`, RFC 3501
    /// §4.3 / RFC 7888) at the end of a not-yet-terminated command line.
    /// `needsContinuationResponse` is true for the synchronizing `{N}` form
    /// (server must send `+ OK` before the client sends the N bytes) and
    /// false for the non-synchronizing `{N+}` form (client sends immediately
    /// — this fake's CAPABILITY advertises LITERAL+, so real clients use
    /// this form here).
    private static func trailingLiteralSpec(_ lineData: Data) -> (length: Int, needsContinuationResponse: Bool)? {
        guard let line = String(data: lineData, encoding: .utf8), line.hasSuffix("}"),
              let open = line.lastIndex(of: "{") else { return nil }
        var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        let needsContinuationResponse: Bool
        if digits.hasSuffix("+") {
            needsContinuationResponse = false
            digits = digits.dropLast()
        } else {
            needsContinuationResponse = true
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let length = Int(digits) else { return nil }
        return (length, needsContinuationResponse)
    }

    /// Replace a trailing `{N[+]}` literal marker with a quoted, escaped
    /// form of its now-known bytes, so the existing quoted-string-based
    /// command handlers (SELECT/SEARCH/etc.) parse the reconstructed line
    /// exactly as they would a client that chose quoted-string encoding.
    private static func splicingLiteral(into lineData: Data, literal: String) -> Data {
        guard let line = String(data: lineData, encoding: .utf8),
              let open = line.lastIndex(of: "{") else { return lineData }
        let prefix = line[line.startIndex..<open]
        let escaped = literal
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return Data("\(prefix)\"\(escaped)\"".utf8)
    }

    /// Minimal IMAP LIST pattern match (RFC 3501 §6.3.8): `*` matches any run
    /// of characters (including none), `%` likewise (this fake has no
    /// mailbox hierarchy to distinguish them from `*`). Every mailbox name
    /// this test infra uses is a flat identifier with no wildcard
    /// metacharacters of its own, so an exact match is used whenever the
    /// pattern itself has none.
    private static func imapListPatternMatches(pattern: String, name: String) -> Bool {
        guard !pattern.isEmpty, pattern != "*" else { return true }
        guard pattern.contains("*") || pattern.contains("%") else { return pattern == name }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\%", with: ".*")
        guard let regex = try? NSRegularExpression(pattern: "^" + escaped + "$") else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private func handleFetch(tag: String, args: String, uidMode: Bool, mailbox: String) -> String {
        let seqStr: String
        let itemsStr: String

        if let parenOpen = args.firstIndex(of: "("),
           let parenClose = args.lastIndex(of: ")") {
            seqStr = String(args[args.startIndex..<parenOpen]).trimmingCharacters(in: .whitespaces)
            itemsStr = String(args[args.index(after: parenOpen)..<parenClose]).uppercased()
        } else {
            let fetchParts = args.split(separator: " ", maxSplits: 1).map(String.init)
            guard fetchParts.count == 2 else { return "\(tag) BAD Invalid FETCH arguments\r\n" }
            seqStr = fetchParts[0]
            itemsStr = fetchParts[1].uppercased()
        }

        let snapshot = withState { state in
            (
                messages: state.messagesByMailbox[mailbox] ?? [],
                flags: state.flagsByMailbox[mailbox] ?? [:]
            )
        }
        let matched = parseSequenceSet(seqStr, uidMode: uidMode, messages: snapshot.messages)
        var response = ""

        for msg in matched {
            let seqnum = (snapshot.messages.firstIndex(where: { $0.uid == msg.uid }) ?? 0) + 1
            var fetchItems: [String] = []

            if itemsStr.contains("UID") || uidMode {
                fetchItems.append("UID \(msg.uid)")
            }
            if itemsStr.contains("FLAGS") {
                let flags = (snapshot.flags[msg.uid] ?? []).sorted().joined(separator: " ")
                fetchItems.append("FLAGS (\(flags))")
            }
            if itemsStr.contains("ENVELOPE") {
                fetchItems.append("ENVELOPE \(buildEnvelope(msg))")
            }
            if itemsStr.contains("INTERNALDATE") {
                fetchItems.append("INTERNALDATE \"\(msg.internalDate)\"")
            }
            if itemsStr.contains("RFC822.SIZE") {
                fetchItems.append("RFC822.SIZE \(msg.raw.count)")
            }
            if itemsStr.contains("BODYSTRUCTURE") {
                let bs = msg.customBodystructure ?? buildBodystructure(msg)
                fetchItems.append("BODYSTRUCTURE \(bs)")
            }
            if itemsStr.contains("BODY[]") || itemsStr.contains("BODY.PEEK[]") {
                let rawStr = String(data: msg.raw, encoding: .utf8) ?? ""
                fetchItems.append("BODY[] {\(msg.raw.count)}\r\n\(rawStr)")
            }
            if itemsStr.contains("BODY[HEADER]") || itemsStr.contains("BODY.PEEK[HEADER]") {
                let headerStr = String(data: msg.headerData, encoding: .utf8) ?? ""
                fetchItems.append("BODY[HEADER] {\(msg.headerData.count)}\r\n\(headerStr)")
            }
            if itemsStr.contains("BODY[TEXT]") || itemsStr.contains("BODY.PEEK[TEXT]") {
                let bodyStr = String(data: msg.body, encoding: .utf8) ?? ""
                fetchItems.append("BODY[TEXT] {\(msg.body.count)}\r\n\(bodyStr)")
            }
            // BODY[N] / BODY.PEEK[N] / BODY[N.M] — numeric section specifier.
            // Match sections registered in partBodies; emit literal-length bytes.
            if let sections = msg.partBodies {
                for (section, bytes) in sections {
                    // RFC 3501 §7.4.2: BODY[section] response echoes the section.
                    // Both peek and non-peek forms get the same BODY[<s>] key on
                    // the response side.
                    let patterns = [
                        "BODY[\(section)]",
                        "BODY.PEEK[\(section)]"
                    ]
                    if patterns.contains(where: { itemsStr.contains($0) }) {
                        let str = String(data: bytes, encoding: .utf8) ?? ""
                        fetchItems.append("BODY[\(section)] {\(bytes.count)}\r\n\(str)")
                    }
                }
            }

            response += "* \(seqnum) FETCH (\(fetchItems.joined(separator: " ")))\r\n"
        }

        response += "\(tag) OK \(uidMode ? "UID " : "")FETCH completed\r\n"
        return response
    }

    private func parseSequenceSet(_ seqStr: String, uidMode: Bool, messages: [Message]) -> [Message] {
        var results: [Message] = []
        for part in seqStr.split(separator: ",").map(String.init) {
            if part.contains(":") {
                let range = part.split(separator: ":").map(String.init)
                let start = Int(range[0]) ?? 1
                let end: Int
                if range.count > 1, range[1] != "*" {
                    end = Int(range[1]) ?? messages.count
                } else {
                    end = uidMode ? (messages.last?.uid ?? 0) : messages.count
                }
                for (index, msg) in messages.enumerated() {
                    let val = uidMode ? msg.uid : (index + 1)
                    if val >= start && val <= end { results.append(msg) }
                }
            } else if part == "*" {
                if let last = messages.last { results.append(last) }
            } else if let num = Int(part) {
                for (index, msg) in messages.enumerated() {
                    let val = uidMode ? msg.uid : (index + 1)
                    if val == num { results.append(msg) }
                }
            }
        }
        return results
    }

    // MARK: - Response Builders

    private func buildEnvelope(_ msg: Message) -> String {
        let date = quote(msg.date)
        let subject = quote(msg.subject)
        let fromAddr = buildAddrList(msg.from)
        let toAddr = buildAddrList(msg.to)
        let msgID = quote(msg.messageID)
        return "(\(date) \(subject) \(fromAddr) \(fromAddr) \(fromAddr) \(toAddr) NIL NIL NIL \(msgID))"
    }

    private func buildAddrList(_ header: String) -> String {
        guard !header.isEmpty else { return "NIL" }
        let name: String
        let email: String
        if let angleOpen = header.firstIndex(of: "<"),
           let angleClose = header.firstIndex(of: ">") {
            name = String(header[header.startIndex..<angleOpen]).trimmingCharacters(in: .whitespaces)
            email = String(header[header.index(after: angleOpen)..<angleClose])
        } else {
            name = ""
            email = header.trimmingCharacters(in: .whitespaces)
        }
        guard email.contains("@") else { return "NIL" }
        let parts = email.split(separator: "@")
        let local = String(parts[0])
        let domain = String(parts[1])
        let nameQ = name.isEmpty ? "NIL" : quote(name)
        return "((\(nameQ) NIL \(quote(local)) \(quote(domain))))"
    }

    private func buildBodystructure(_ msg: Message) -> String {
        let ct = msg.contentType
        let parts = ct.split(separator: "/")
        let maintype = parts.first.map(String.init)?.uppercased() ?? "TEXT"
        let subtype = parts.count > 1 ? String(parts[1]).uppercased() : "PLAIN"
        let charset = msg.charset.uppercased()
        let size = msg.body.count
        let lines = msg.body.filter { $0 == UInt8(ascii: "\n") }.count
        return "(\"\(maintype)\" \"\(subtype)\" (\"CHARSET\" \"\(charset)\") NIL NIL \"7BIT\" \(size) \(lines))"
    }

    private func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
