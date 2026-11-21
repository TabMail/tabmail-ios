/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

// MARK: - ComposeOutcome

/// Outcome of a compose window opened by an agent tool. Used by
/// `enqueueComposeAndAwaitOutcome` to resume the tool's continuation so the
/// LLM sees what actually happened (send / cancel / setup failure), instead
/// of the old fire-and-forget "Opening…" placeholder.
enum ComposeOutcome: Sendable {
    case sent
    case cancelled
    case failed(String)
}

extension ComposeOutcome {
    /// LLM-facing string representation. Shared by `email_compose`,
    /// `email_reply`, and `email_forward` so the three tools return a uniform
    /// shape whether the outcome came from the user or a pre-window error.
    var describeForLLM: String {
        switch self {
        case .sent:               return "Email sent successfully."
        case .cancelled:          return "User closed the compose window without sending."
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

/// Shared reference-type state attached to each `AgentToolRouter.ComposeRequest`.
/// Gives the helper's outcome closure a stable identity to guard against
/// double-resume (ComposeView's `send()` + `.onDisappear` both firing) and
/// also lets `takeCompose(for:)` drop requests whose Task was cancelled
/// before the window ever appeared.
///
/// Thread-safe: `tryResolve(_:)` is invoked from MainActor ComposeView callbacks
/// AND from `withTaskCancellationHandler`'s onCancel handler (arbitrary thread).
/// NSLock matches the style of the existing `ContinuationGuard` in this file.
final class ComposeOutcomeState: @unchecked Sendable {
    private let lock = NSLock()
    private var _resolved = false
    private var _outcome: ComposeOutcome = .cancelled

    var resolved: Bool { lock.withLock { _resolved } }
    var outcome: ComposeOutcome { lock.withLock { _outcome } }

    init() {}

    /// Atomically transition to resolved. Returns `true` only on the first
    /// call; every subsequent call returns `false` without mutating state.
    /// Callers use the return value to gate a one-shot continuation resume.
    func tryResolve(_ outcome: ComposeOutcome) -> Bool {
        lock.withLock {
            guard !_resolved else { return false }
            _resolved = true
            _outcome = outcome
            return true
        }
    }
}

/// Short-TTL in-memory cache of `(accountId, stableId, mode)` tuples whose
/// compose tool recently resolved with `.sent`. Consulted by
/// `EmailReplyTool` and `EmailForwardTool` before opening a compose window;
/// on a hit, the tool returns a no-op "already sent" string instead of
/// prompting the user a second time.
///
/// Motivation: when a Round 2 HTTP POST fails after a successful send, the
/// chat's Retry button re-runs the turn from the user's original message.
/// The LLM re-emits the same tool_call, which without this cache would
/// re-open a compose window for a message that's already in the outbox —
/// inviting the user to send twice. Cache TTL is deliberately short
/// (`SyncConfig.composeRecentlySentTTLSeconds`, default 120s) so that
/// legitimate "send another reply to the same email a few minutes later"
/// intent is not suppressed.
///
/// In-memory only; lost on app kill. That's fine: the retry race is a
/// single-session phenomenon. MainActor-isolated so no locking needed.
@MainActor
final class RecentlyCompletedComposeCache {
    struct Key: Hashable {
        let accountId: String
        let stableId: String
        let mode: AgentToolRouter.ComposeRequest.Mode
    }

    private var entries: [Key: Date] = [:]
    private let ttl: TimeInterval

    init(ttlSeconds: TimeInterval = 120) {
        self.ttl = ttlSeconds
    }

    func markSent(_ key: Key) {
        entries[key] = Date()
    }

    /// Returns true if the key is present and within TTL. Evicts stale
    /// entries lazily as a side effect (no background reaper needed).
    func isRecentlySent(_ key: Key) -> Bool {
        guard let timestamp = entries[key] else { return false }
        if Date().timeIntervalSince(timestamp) > ttl {
            entries.removeValue(forKey: key)
            return false
        }
        return true
    }

    /// Test-only: clear all entries.
    func clearForTesting() {
        entries.removeAll()
    }

    /// Test-only: current entry count.
    var countForTesting: Int { entries.count }
}

/// Router for FSM-style agent tools that trigger UI actions (compose/reply/forward).
/// Matching TB's FSM pattern: tool fires → UI opens → tool returns status message.
/// On iOS, a compose tool queues a `ComposeRequest` stamped with the chat that asked
/// (`ComposeOrigin`); that chat's pill takes it (`takeCompose(for:)`) and its screen
/// presents ComposeView (ADR-IOS-053 Phase 2).
@MainActor @Observable
final class AgentToolRouter {
    static let shared = AgentToolRouter()

    /// Bumped whenever a queued compose request may have become takeable: a request
    /// was queued, or the last compose window closed. The only observable compose
    /// state: every host pill watches it and asks `takeCompose(for:)` for its own
    /// requests, so no view ever takes another screen's request (ADR-IOS-053 Phase 2,
    /// replacing the global `pendingCompose` slot that the first observer took).
    private(set) var composeOffer = 0

    /// Short-TTL cache of recently-successful sends keyed by the replied/forwarded
    /// message. See `RecentlyCompletedComposeCache` for rationale.
    /// `@ObservationIgnored` — it's an internal dedup table, not observable state.
    @ObservationIgnored let recentlySentCompose = RecentlyCompletedComposeCache()

    // MARK: - Compose FIFO Queue (ADR-IOS-030)

    /// FIFO queue of agent compose requests waiting for the compose UI to be free
    /// and for the screen that asked to take them. In-memory only; lost on app kill
    /// (acceptable — agent compose tool calls are transient session intent, not
    /// durable user actions). See ADR-IOS-030.
    /// Marked `@ObservationIgnored` because no view should observe queue contents —
    /// only `composeOffer` is observable.
    @ObservationIgnored private var composeQueue: [ComposeRequest] = []

    /// Number of currently-presented `ComposeView` instances, tracked via the
    /// `composePresentationDidBegin/End` hooks called from `ComposeView.onAppear/onDisappear`.
    /// While > 0 the queue holds — both manually-opened and agent-opened compose windows
    /// increment the count, so a manual compose blocks queued agent compose requests.
    @ObservationIgnored private var presentationCount: Int = 0

    /// True between the moment a host takes a request (`takeCompose(for:)`) and the
    /// moment its `ComposeView` actually appears on screen (`composePresentationDidBegin`).
    /// Closes a race window: the host's cover is still presenting, so
    /// `presentationCount == 0` even though a request is mid-dispatch. Without this
    /// flag, another host could take a second request in that window and present a
    /// second compose window over the first.
    @ObservationIgnored private var awaitingAppear: Bool = false

    /// Whether an account's removal has committed: `AccountManager`'s runtime fence
    /// (`isRuntimeRemoved`), set synchronously by `disconnectAccount` before it first suspends.
    /// A request that depends on such an account ends instead of queueing or being taken.
    @ObservationIgnored private let isAccountRemoved: @Sendable (String) -> Bool

    /// What a compose tool tells the model when an account its request depends on was removed
    /// while the request waited for its screen.
    static let removedAccountReason = "the email account was removed before the compose window opened"

    init(isAccountRemoved: @escaping @Sendable (String) -> Bool = { AccountManager.shared.isRuntimeRemoved($0) }) {
        self.isAccountRemoved = isAccountRemoved
    }

    /// The screen a host pill stands for, asking for its compose requests: its screen
    /// kind and the keys of the chat it shows (own key first, then the thread's).
    struct ComposeHost: Equatable {
        let screen: ComposeOrigin.Screen
        let sessionKeys: [String]

        /// Whether `origin` asked this host: the same kind of screen showing the chat that asked.
        func asked(_ origin: ComposeOrigin) -> Bool {
            origin.screen == screen && sessionKeys.contains(origin.sessionKey)
        }
    }

    /// Enqueue a compose request from an agent tool. The request waits in FIFO order
    /// until no compose UI is presented and the screen that asked takes it
    /// (`takeCompose(for:)`); the offer tells every host pill to look. See ADR-IOS-030.
    func enqueueCompose(_ request: ComposeRequest) {
        if dependsOnRemovedAccount(request) {
            request.onOutcome(.failed(Self.removedAccountReason))
            return
        }
        composeQueue.append(request)
        composeOffer += 1
    }

    /// Ends every queued request that depends on an account whose removal has committed
    /// (`ComposeRequest.accountIds`, read against the fence): its card would open with a gone
    /// email or a From address it can no longer send from, or wait under a chat key the screens
    /// no longer read. Each request's tool returns
    /// `.failed(removedAccountReason)` and nothing opens. Scheduled by `disconnectAccount` right
    /// after it sets the fence, which refuses every later request (`enqueueCompose`) and every
    /// take (`takeCompose(for:)`) in between.
    func endComposeRequestsOfRemovedAccounts() {
        let ended = composeQueue.filter { dependsOnRemovedAccount($0) }
        guard !ended.isEmpty else { return }
        composeQueue.removeAll { dependsOnRemovedAccount($0) }
        for request in ended {
            request.onOutcome(.failed(Self.removedAccountReason))
        }
    }

    private func dependsOnRemovedAccount(_ request: ComposeRequest) -> Bool {
        request.accountIds.contains(where: isAccountRemoved)
    }

    /// The oldest queued request `host` asked for, removed from the queue, or nil.
    /// Nil while a compose UI is presented (`presentationCount > 0`) or a taken
    /// request's window has not appeared yet (`awaitingAppear`): one compose window at
    /// a time (ADR-IOS-030). Requests other screens asked for are left in place and
    /// never block this one; a request whose screen is not showing waits until it is,
    /// or until its tool is cancelled.
    ///
    /// First drops every queued request whose Task was cancelled before it was taken
    /// (`outcomeState.resolved`, flipped by `enqueueComposeAndAwaitOutcome`'s
    /// `onCancel` handler): presenting a compose window for a tool that already
    /// returned would leave the user confused and the follow-on `onOutcome` calls
    /// dangling. Then ends every request whose account was removed
    /// (`endComposeRequestsOfRemovedAccounts`), so none is handed out between the fence and
    /// its scheduled drain.
    func takeCompose(for host: ComposeHost) -> ComposeRequest? {
        guard !awaitingAppear, presentationCount == 0 else { return nil }
        composeQueue.removeAll { $0.outcomeState.resolved }
        endComposeRequestsOfRemovedAccounts()
        guard let index = composeQueue.firstIndex(where: { host.asked($0.origin) }) else { return nil }
        awaitingAppear = true
        return composeQueue.remove(at: index)
    }

    /// Called by `ComposeView.onAppear`. Marks the compose UI as busy so the queue holds
    /// any pending requests until this window dismisses, and clears the `awaitingAppear`
    /// guard so the next dispatch can proceed once this cover dismisses.
    func composePresentationDidBegin() {
        presentationCount += 1
        awaitingAppear = false
    }

    /// Called by `ComposeView.onDisappear`. When all compose UI is gone, offers the
    /// queue again so the next request presents right after the previous window's
    /// dismissal, on the screen that asked for it.
    func composePresentationDidEnd() {
        presentationCount = max(0, presentationCount - 1)
        if presentationCount == 0 {
            composeOffer += 1
        }
    }

    /// Test-only: number of requests currently waiting in the FIFO queue.
    var composeQueueDepth: Int { composeQueue.count }

    /// Test-only: current presentation count (number of `ComposeView`s on screen).
    var composePresentationCount: Int { presentationCount }

    /// Test-only: whether a request is mid-dispatch (taken, but cover not yet appeared).
    var composeAwaitingAppear: Bool { awaitingAppear }

    /// Test-only: is the head-of-queue request already resolved (cancelled before
    /// it was taken)? Returns `nil` when the queue is empty. Exposes what tests need
    /// to verify the stale-drop behavior in `takeCompose(for:)` without leaking
    /// the full `ComposeRequest` type across the test boundary.
    var firstQueuedRequestResolvedForTesting: Bool? {
        composeQueue.first?.outcomeState.resolved
    }

    /// Test-only: the request at the head of the queue, as the compose that takes it will read it.
    var firstQueuedRequestForTesting: ComposeRequest? { composeQueue.first }

    /// Test-only: reset queue + counters between tests.
    func resetComposeQueueForTesting() {
        composeQueue.removeAll()
        presentationCount = 0
        awaitingAppear = false
    }

    /// A request to open the compose UI, produced by email_compose/reply/forward tools.
    ///
    /// Carries an outcome callback + shared state so agent-initiated compose
    /// windows can report their resolution back to the tool's continuation.
    /// Both `onOutcome` and `outcomeState` default to no-op values so that
    /// non-agent callers (manual compose, legacy tests) don't have to supply
    /// them. Every agent-initiated request goes through
    /// `enqueueComposeAndAwaitOutcome`, which replaces the defaults with a
    /// real callback wired to a `withCheckedContinuation`.
    struct ComposeRequest: Identifiable {
        let id = UUID()
        let mode: Mode
        let replyTo: MessageHeader?
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String?
        let body: String?
        /// The chat that asked (ADR-IOS-053 Phase 2): only a pill of that screen kind
        /// showing that chat takes the request (`takeCompose(for:)`), so the card opens
        /// on the screen that asked, built by that screen.
        let origin: ComposeOrigin
        /// A `.reply` built from the reply-all recipient set (the AI reply
        /// tool). Carried into ComposeView so the send records reply-all on
        /// the original, like the Reply All button (#915).
        let isReplyAll: Bool
        /// A reply asked for in the chat's reply field, to the email the field replies to: who the
        /// user chose in Reply to when the request was sent (ADR-IOS-114 decision 11). Nil for
        /// every other request, whose compose keeps the recipients above.
        let fieldReply: ChatFieldReply?

        /// Fires once when the user's compose session reaches a terminal state
        /// (send / cancel / persist-failure). Invoked on MainActor from
        /// ComposeView. Repeat invocations are silently dropped via
        /// `outcomeState.tryResolve`.
        let onOutcome: @MainActor (ComposeOutcome) -> Void

        /// Shared idempotence + staleness flag. Threaded into the request by
        /// `enqueueComposeAndAwaitOutcome` so `takeCompose(for:)` can drop
        /// requests whose Task was cancelled before they were taken.
        let outcomeState: ComposeOutcomeState

        init(
            mode: Mode,
            replyTo: MessageHeader?,
            to: [String],
            cc: [String],
            bcc: [String],
            subject: String?,
            body: String?,
            origin: ComposeOrigin,
            isReplyAll: Bool = false,
            fieldReply: ChatFieldReply? = nil,
            onOutcome: @escaping @MainActor (ComposeOutcome) -> Void = { _ in },
            outcomeState: ComposeOutcomeState = ComposeOutcomeState()
        ) {
            self.mode = mode
            self.replyTo = replyTo
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.subject = subject
            self.body = body
            self.origin = origin
            self.isReplyAll = isReplyAll
            self.fieldReply = fieldReply
            self.onOutcome = onOutcome
            self.outcomeState = outcomeState
        }

        enum Mode {
            case compose
            case reply
            case forward
        }

        /// The account a new email is sent from, bound when the turn started
        /// (`ComposeOrigin.fromAccountId`). Nil for a reply or forward, sent from its email's
        /// account, and for a new email asked in the inbox, whose card picks its account.
        var fromAccountId: String? { mode == .compose ? origin.fromAccountId : nil }

        /// The accounts the request depends on: the account of the email it replies to or
        /// forwards, the account its new email is sent from, and the account whose thread key
        /// the asking turn ran under (the chat view or the email screen; the inbox's key names
        /// none). Removing one of them ends the request: its email or its From address is gone,
        /// and the removed account's key is not among the keys a screen reads once that
        /// account's emails are gone, even where the merged thread's chat still shows through a
        /// surviving account's emails (ADR-IOS-114 decision 14). A new email asked in the inbox
        /// depends on none.
        var accountIds: [String] {
            [replyTo?.accountId, fromAccountId, ChatThreadKey.parse(origin.sessionKey)?.accountId].compactMap { $0 }
        }
    }

    /// A destructive action awaiting user confirmation (ADR-IOS-024).
    /// The tool suspends via `withCheckedContinuation` until the user responds.
    struct ActionConfirmation: Identifiable {
        let id = UUID()
        let action: ActionType
        let emails: [EmailDetail]
        let contacts: [ContactDetail]
        let calendarEvents: [CalendarEventDetail]
        let templates: [TemplateDetail]
        /// Resume the tool's continuation. `true` = accept, `false` = decline.
        /// Safe to call multiple times — only the first call takes effect.
        let onRespond: @MainActor (Bool) -> Void
        /// Shared reference-type state so response persists across view re-creation
        /// (e.g., when chat pill is collapsed and re-expanded). Created BEFORE
        /// the continuation is set up so `awaitConfirmation` callers can hold a
        /// reference and mutate `failureReason` after the queued op fails.
        let responseState: ResponseState

        init(
            action: ActionType,
            emails: [EmailDetail],
            contacts: [ContactDetail],
            calendarEvents: [CalendarEventDetail],
            templates: [TemplateDetail],
            onRespond: @escaping @MainActor (Bool) -> Void,
            responseState: ResponseState = ResponseState()
        ) {
            self.action = action
            self.emails = emails
            self.contacts = contacts
            self.calendarEvents = calendarEvents
            self.templates = templates
            self.onRespond = onRespond
            self.responseState = responseState
        }

        @Observable @MainActor
        final class ResponseState {
            var responded = false
            var accepted = false
            /// Set by the tool when an accepted action's queued execution
            /// permanently fails (provider 4xx, validation, etc.). Drives the
            /// card's red/⚠ failure state. Nil until set; nil-on-accept means
            /// the action succeeded (or is still in flight under optimistic UI).
            var failureReason: String? = nil
            /// Created from any isolation domain — the SwiftUI card observes
            /// it on MainActor, the tool mutates it via `await MainActor.run`.
            nonisolated init() {}
        }

        enum ActionType {
            case archive
            case delete
            case contactEdit
            case contactDelete
            case calendarEventCreate
            case calendarEventEdit
            case calendarEventDelete
            case templateCreate
            case templateEdit
            case templateDelete
            case templateShare
            case templateDownload
        }

        struct EmailDetail: Sendable {
            let numericId: Int
            let subject: String
            let from: String
            let date: Date?
        }

        struct ContactDetail: Sendable {
            let contactId: String
            let name: String
            let email: String
            /// Human-readable change descriptions for edit confirmations (e.g., "name: John → Jane").
            var changes: [String] = []
        }

        struct CalendarEventDetail: Sendable {
            let eventId: String
            let calendarId: String
            let title: String
            let startDate: Date
            let endDate: Date
            let isAllDay: Bool
            /// Human-readable change descriptions for edit confirmations (e.g., "title: Meeting → Standup").
            var changes: [String] = []
            /// Attendee emails for display in confirmation card (invitations will be sent).
            var attendees: [String] = []
            /// IANA timezone identifier for display (e.g., "Asia/Tokyo"). Nil = device timezone.
            var timeZoneId: String?
            /// Event notes/description body. Surfaced verbatim in the card so the
            /// user can verify meeting links, dial-ins, agenda text, etc. before
            /// accepting. Nil = no description argument provided (event keeps
            /// existing notes on edit; empty on create).
            var notes: String?
        }

        struct TemplateDetail: Sendable {
            let templateId: String
            let name: String
            let instructionCount: Int
            let exampleReplyPreview: String
            /// Human-readable change descriptions for edit confirmations.
            var changes: [String] = []
        }

        /// Suspends the calling tool until the user accepts or declines (email actions).
        /// Handles task cancellation (Stop button) and double-resume safely.
        /// Uses `withTaskCancellationHandler` per ADR-IOS-020 pattern.
        ///
        /// Returns the user's response AND a reference to the card's
        /// `ResponseState`. After the call returns the tool may mutate
        /// `state.failureReason` to flip the card to its red/⚠ failure
        /// rendering when the queued execution fails downstream (e.g. provider
        /// 4xx). Mutate on the MainActor — the state is `@Observable` and
        /// drives the SwiftUI card immediately.
        static func awaitConfirmation(
            action: ActionType,
            emails: [EmailDetail],
            via sink: (any AgentUISink)?
        ) async -> (accepted: Bool, state: ResponseState) {
            await awaitConfirmationInternal(action: action, emails: emails, contacts: [], calendarEvents: [], templates: [], via: sink)
        }

        /// Suspends the calling tool until the user accepts or declines (contact actions).
        static func awaitConfirmation(
            action: ActionType,
            contacts: [ContactDetail],
            via sink: (any AgentUISink)?
        ) async -> (accepted: Bool, state: ResponseState) {
            await awaitConfirmationInternal(action: action, emails: [], contacts: contacts, calendarEvents: [], templates: [], via: sink)
        }

        /// Suspends the calling tool until the user accepts or declines (calendar event actions).
        static func awaitConfirmation(
            action: ActionType,
            calendarEvents: [CalendarEventDetail],
            via sink: (any AgentUISink)?
        ) async -> (accepted: Bool, state: ResponseState) {
            await awaitConfirmationInternal(action: action, emails: [], contacts: [], calendarEvents: calendarEvents, templates: [], via: sink)
        }

        /// Suspends the calling tool until the user accepts or declines (template actions).
        static func awaitConfirmation(
            action: ActionType,
            templates: [TemplateDetail],
            via sink: (any AgentUISink)?
        ) async -> (accepted: Bool, state: ResponseState) {
            await awaitConfirmationInternal(action: action, emails: [], contacts: [], calendarEvents: [], templates: templates, via: sink)
        }

        private static func awaitConfirmationInternal(
            action: ActionType,
            emails: [EmailDetail],
            contacts: [ContactDetail],
            calendarEvents: [CalendarEventDetail],
            templates: [TemplateDetail],
            via sink: (any AgentUISink)?
        ) async -> (accepted: Bool, state: ResponseState) {
            // Build the state up front so the caller's tuple carries the same
            // instance the card observes — letting the tool flip `failureReason`
            // after the user accepts and the queued execution later fails.
            let state = ResponseState()

            // Nil sink → no interactive chat session to confirm in (reply
            // precompute, inline edit, task eval, BYOK smoke). Fast-fail as
            // declined WITHOUT suspending — the tool's decline branch returns
            // `ok:false`. A preset `failureReason` lets a tool surface a
            // distinct message if it chooses to read it. See ADR-IOS-053.
            guard let sink else {
                await MainActor.run { state.failureReason = "no interactive chat session to confirm in" }
                return (false, state)
            }

            let guard_ = ContinuationGuard()
            let accepted = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    guard_.store(continuation)
                    // If already cancelled before setup, resume immediately
                    if Task.isCancelled {
                        guard_.resume(returning: false)
                        return
                    }
                    let confirmation = ActionConfirmation(
                        action: action,
                        emails: emails,
                        contacts: contacts,
                        calendarEvents: calendarEvents,
                        templates: templates,
                        onRespond: { accepted in
                            guard_.resume(returning: accepted)
                        },
                        responseState: state
                    )
                    // Deliver to the invoking session's owned channel (ADR-IOS-053).
                    // Replaces the old global `AgentToolRouter.shared.pendingAction`
                    // slot: no cross-view race, rendered level-triggered by the pill
                    // bound to that session.
                    Task { @MainActor in
                        sink.deliverConfirmation(confirmation)
                    }
                }
            } onCancel: {
                guard_.resume(returning: false)
            }
            return (accepted, state)
        }
    }

    /// Thread-safe single-resume guard for CheckedContinuation.
    /// Prevents double-resume crashes when both onRespond and onCancel fire.
    /// Uses NSLock per ADR-IOS-020 pattern (@unchecked Sendable + lock).
    private final class ContinuationGuard: @unchecked Sendable {
        private var continuation: CheckedContinuation<Bool, Never>?
        private let lock = NSLock()

        func store(_ c: CheckedContinuation<Bool, Never>) {
            lock.withLock { continuation = c }
        }

        func resume(returning value: Bool) {
            let c: CheckedContinuation<Bool, Never>? = lock.withLock {
                let c = continuation
                continuation = nil
                return c
            }
            c?.resume(returning: value)
        }
    }

    /// Thread-safe single-resume guard for `CheckedContinuation<ComposeOutcome, Never>`.
    /// Sibling of `ContinuationGuard` (Bool-only) above. Kept as a separate
    /// typed class rather than generifying the Bool variant — the two are
    /// used in unrelated flows and the duplication is three lines.
    fileprivate final class ComposeContinuationGuard: @unchecked Sendable {
        private var continuation: CheckedContinuation<ComposeOutcome, Never>?
        private let lock = NSLock()

        func store(_ c: CheckedContinuation<ComposeOutcome, Never>) {
            lock.withLock { continuation = c }
        }

        func resume(returning value: ComposeOutcome) {
            let c: CheckedContinuation<ComposeOutcome, Never>? = lock.withLock {
                let c = continuation
                continuation = nil
                return c
            }
            c?.resume(returning: value)
        }
    }
}

// MARK: - Compose Outcome Helper

extension AgentToolRouter {
    /// Enqueue a compose request from an agent tool and suspend the caller
    /// until the user sends, dismisses, or the owning Task is cancelled
    /// (chat pill's Stop button). The returned `ComposeOutcome` is what the
    /// LLM-facing tool string should reflect — see `ComposeOutcome.describeForLLM`.
    ///
    /// The `make` closure receives both a one-shot `onOutcome` callback and
    /// the shared `ComposeOutcomeState` instance; threading both into the
    /// returned `ComposeRequest` keeps the idempotence machinery intact and
    /// lets `takeCompose(for:)` drop requests whose Task was cancelled
    /// before they were taken.
    ///
    /// Exactly-once resume is guaranteed by:
    ///   - `ComposeOutcomeState.tryResolve` — atomic first-wins flag
    ///   - `ComposeContinuationGuard.resume` — NSLock-serialized resume
    func enqueueComposeAndAwaitOutcome(
        make: (@escaping @MainActor (ComposeOutcome) -> Void, ComposeOutcomeState) -> ComposeRequest
    ) async -> ComposeOutcome {
        let state = ComposeOutcomeState()
        let guard_ = ComposeContinuationGuard()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ComposeOutcome, Never>) in
                guard_.store(continuation)
                // Task may have been cancelled before we got here. Per Swift's
                // `withTaskCancellationHandler` contract, if the task is
                // already cancelled when the helper enters, `onCancel` fires
                // *before* this operation closure runs — at which point
                // `state.tryResolve(.cancelled)` has already flipped the flag
                // but `guard_.resume` was a no-op (continuation not yet
                // stored). So we must ALWAYS resume the guard here when
                // cancelled, regardless of `tryResolve`'s return value.
                // `ComposeContinuationGuard.resume` is lock-protected and
                // idempotent, so a second call after `onCancel`'s first is
                // harmless.
                if Task.isCancelled {
                    _ = state.tryResolve(.cancelled)
                    guard_.resume(returning: .cancelled)
                    return
                }
                let request = make({ outcome in
                    // Called from ComposeView send()/onDisappear/failure path
                    // (MainActor). `tryResolve` is atomic so we don't depend
                    // on that isolation for correctness.
                    guard state.tryResolve(outcome) else { return }
                    guard_.resume(returning: outcome)
                }, state)
                enqueueCompose(request)
            }
        } onCancel: {
            // Invoked on an arbitrary thread by the cooperative cancellation
            // machinery, potentially *before* the operation closure runs (see
            // cancellation-before-entry case above). `tryResolve` flips
            // `resolved` atomically so the stale-drop in
            // `takeCompose(for:)` sees a consistent value, and
            // `ComposeContinuationGuard.resume` is idempotent — so we always
            // call resume rather than gating on tryResolve (which the
            // in-operation path may have already flipped).
            _ = state.tryResolve(.cancelled)
            guard_.resume(returning: .cancelled)
        }
    }
}
