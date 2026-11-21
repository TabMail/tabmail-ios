/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// The chat a compose tool test asks from: the inbox's own chat, the host its pill stands for, and
/// the invocation of a turn sent there (ADR-IOS-053 Phase 2).
enum ComposeTestOrigin {
    static let inbox = ComposeOrigin(sessionKey: "inbox", screen: .inbox)
    static let inboxHost = AgentToolRouter.ComposeHost(screen: .inbox, sessionKeys: ["inbox"])
    static let invocation = ToolInvocation(composeOrigin: inbox)
}

// MARK: - ComposeRequest Tests

@Suite("AgentToolRouter.ComposeRequest")
struct ComposeRequestTests {

    @Test("ComposeRequest has unique IDs")
    func uniqueIds() {
        let r1 = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: [], cc: [], bcc: [],
            subject: nil, body: nil, origin: ComposeTestOrigin.inbox
        )
        let r2 = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: [], cc: [], bcc: [],
            subject: nil, body: nil, origin: ComposeTestOrigin.inbox
        )
        #expect(r1.id != r2.id)
    }

    @Test("ComposeRequest stores compose mode fields")
    func composeMode() {
        let request = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil,
            to: ["alice@test.com", "bob@test.com"],
            cc: ["cc@test.com"], bcc: [],
            subject: "Meeting Notes", body: "<p>Hello</p>", origin: ComposeTestOrigin.inbox
        )
        #expect(request.to == ["alice@test.com", "bob@test.com"])
        #expect(request.cc == ["cc@test.com"])
        #expect(request.bcc.isEmpty)
        #expect(request.subject == "Meeting Notes")
        #expect(request.body == "<p>Hello</p>")
        #expect(request.replyTo == nil)
    }

    @Test("ComposeRequest reply mode")
    func replyMode() {
        let request = AgentToolRouter.ComposeRequest(
            mode: .reply, replyTo: nil,
            to: ["sender@test.com"], cc: [], bcc: [],
            subject: "Re: Original", body: nil, origin: ComposeTestOrigin.inbox
        )
        // Mode is a value type — just verify it was set
        switch request.mode {
        case .reply: break // expected
        default: Issue.record("Expected reply mode")
        }
    }

    @Test("ComposeRequest forward mode")
    func forwardMode() {
        let request = AgentToolRouter.ComposeRequest(
            mode: .forward, replyTo: nil,
            to: ["fwd@test.com"], cc: [], bcc: ["secret@test.com"],
            subject: "Fwd: Important", body: "See below", origin: ComposeTestOrigin.inbox
        )
        switch request.mode {
        case .forward: break // expected
        default: Issue.record("Expected forward mode")
        }
        #expect(request.bcc == ["secret@test.com"])
    }

    @Test("ComposeRequest Mode enum has three cases")
    func modeEnumCases() {
        // Exhaustive switch verifies all cases exist
        let modes: [AgentToolRouter.ComposeRequest.Mode] = [.compose, .reply, .forward]
        #expect(modes.count == 3)
    }
}

// MARK: - ActionConfirmation Type Tests

@Suite("AgentToolRouter.ActionConfirmation Types")
struct ActionConfirmationTypeTests {

    @Test("ActionType enum has all expected cases")
    func actionTypeCases() {
        let types: [AgentToolRouter.ActionConfirmation.ActionType] = [
            .archive, .delete, .contactEdit, .contactDelete,
            .calendarEventCreate, .calendarEventEdit, .calendarEventDelete,
        ]
        #expect(types.count == 7)
    }

    @Test("EmailDetail stores all fields")
    func emailDetailFields() {
        let detail = AgentToolRouter.ActionConfirmation.EmailDetail(
            numericId: 42,
            subject: "Important Email",
            from: "sender@test.com",
            date: Date(timeIntervalSince1970: 1710000000)
        )
        #expect(detail.numericId == 42)
        #expect(detail.subject == "Important Email")
        #expect(detail.from == "sender@test.com")
        #expect(detail.date != nil)
    }

    @Test("EmailDetail with nil date")
    func emailDetailNilDate() {
        let detail = AgentToolRouter.ActionConfirmation.EmailDetail(
            numericId: 1, subject: "Test", from: "a@b.com", date: nil
        )
        #expect(detail.date == nil)
    }

    @Test("ContactDetail stores fields and changes")
    func contactDetailFields() {
        var detail = AgentToolRouter.ActionConfirmation.ContactDetail(
            contactId: "c1", name: "Alice", email: "alice@test.com"
        )
        detail.changes = ["name: Bob → Alice", "email: old@test.com → alice@test.com"]
        #expect(detail.contactId == "c1")
        #expect(detail.name == "Alice")
        #expect(detail.changes.count == 2)
    }

    @Test("ContactDetail default changes is empty")
    func contactDetailDefaultChanges() {
        let detail = AgentToolRouter.ActionConfirmation.ContactDetail(
            contactId: "c1", name: "Bob", email: "bob@test.com"
        )
        #expect(detail.changes.isEmpty)
    }

    @Test("CalendarEventDetail stores all fields including attendees")
    func calendarEventDetailFields() {
        var detail = AgentToolRouter.ActionConfirmation.CalendarEventDetail(
            eventId: "e1", calendarId: "cal1", title: "Standup",
            startDate: Date(timeIntervalSince1970: 1710000000),
            endDate: Date(timeIntervalSince1970: 1710003600),
            isAllDay: false
        )
        detail.changes = ["title: Meeting → Standup"]
        detail.attendees = ["alice@test.com", "bob@test.com"]
        #expect(detail.eventId == "e1")
        #expect(detail.calendarId == "cal1")
        #expect(detail.title == "Standup")
        #expect(detail.isAllDay == false)
        #expect(detail.changes.count == 1)
        #expect(detail.attendees.count == 2)
    }

    @Test("CalendarEventDetail all-day event")
    func calendarEventAllDay() {
        let detail = AgentToolRouter.ActionConfirmation.CalendarEventDetail(
            eventId: "e2", calendarId: "cal1", title: "Holiday",
            startDate: Date(), endDate: Date(), isAllDay: true
        )
        #expect(detail.isAllDay == true)
    }

    @Test("CalendarEventDetail default changes and attendees are empty")
    func calendarEventDefaults() {
        let detail = AgentToolRouter.ActionConfirmation.CalendarEventDetail(
            eventId: "e1", calendarId: "c1", title: "T",
            startDate: Date(), endDate: Date(), isAllDay: false
        )
        #expect(detail.changes.isEmpty)
        #expect(detail.attendees.isEmpty)
    }
}

// MARK: - ResponseState Tests

@Suite("AgentToolRouter.ActionConfirmation.ResponseState")
struct ResponseStateTests {

    @Test("ResponseState initial values")
    @MainActor func initialValues() {
        let state = AgentToolRouter.ActionConfirmation.ResponseState()
        #expect(state.responded == false)
        #expect(state.accepted == false)
    }

    @Test("ResponseState can be set to accepted")
    @MainActor func setAccepted() {
        let state = AgentToolRouter.ActionConfirmation.ResponseState()
        state.responded = true
        state.accepted = true
        #expect(state.responded == true)
        #expect(state.accepted == true)
    }

    @Test("ResponseState can be set to declined")
    @MainActor func setDeclined() {
        let state = AgentToolRouter.ActionConfirmation.ResponseState()
        state.responded = true
        state.accepted = false
        #expect(state.responded == true)
        #expect(state.accepted == false)
    }
}


// MARK: - ActionConfirmation Identifiable Tests

@Suite("AgentToolRouter.ActionConfirmation Identifiable")
struct ActionConfirmationIdentifiableTests {

    @Test("ActionConfirmation has unique ID")
    @MainActor func uniqueId() {
        let c1 = AgentToolRouter.ActionConfirmation(
            action: .archive, emails: [], contacts: [], calendarEvents: [], templates: [],
            onRespond: { _ in }
        )
        let c2 = AgentToolRouter.ActionConfirmation(
            action: .archive, emails: [], contacts: [], calendarEvents: [], templates: [],
            onRespond: { _ in }
        )
        #expect(c1.id != c2.id)
    }

    @Test("ActionConfirmation stores correct action type and details")
    @MainActor func storesFields() {
        let emails = [
            AgentToolRouter.ActionConfirmation.EmailDetail(
                numericId: 1, subject: "S1", from: "a@b.com", date: nil
            ),
            AgentToolRouter.ActionConfirmation.EmailDetail(
                numericId: 2, subject: "S2", from: "c@d.com", date: Date()
            ),
        ]
        var responded = false
        let confirmation = AgentToolRouter.ActionConfirmation(
            action: .delete, emails: emails, contacts: [], calendarEvents: [], templates: [],
            onRespond: { accepted in responded = accepted }
        )

        switch confirmation.action {
        case .delete: break
        default: Issue.record("Expected delete action")
        }
        #expect(confirmation.emails.count == 2)
        #expect(confirmation.contacts.isEmpty)
        #expect(confirmation.calendarEvents.isEmpty)

        // Verify onRespond callback works
        confirmation.onRespond(true)
        #expect(responded == true)
    }

    @Test("ActionConfirmation ResponseState is shared reference")
    @MainActor func responseStateShared() {
        let confirmation = AgentToolRouter.ActionConfirmation(
            action: .archive, emails: [], contacts: [], calendarEvents: [], templates: [],
            onRespond: { _ in }
        )
        let state1 = confirmation.responseState
        let state2 = confirmation.responseState
        state1.responded = true
        state1.accepted = true
        // state2 is the same object
        #expect(state2.responded == true)
        #expect(state2.accepted == true)
    }
}

// MARK: - Sendable Conformance Tests

@Suite("AgentToolRouter Detail Sendable")
struct AgentToolRouterSendableTests {

    @Test("EmailDetail is Sendable across isolation boundaries")
    func emailDetailSendable() async {
        let detail = AgentToolRouter.ActionConfirmation.EmailDetail(
            numericId: 1, subject: "Test", from: "a@b.com", date: Date()
        )
        let result = await Task.detached {
            // Access from different isolation
            detail.numericId
        }.value
        #expect(result == 1)
    }

    @Test("ContactDetail is Sendable across isolation boundaries")
    func contactDetailSendable() async {
        var detail = AgentToolRouter.ActionConfirmation.ContactDetail(
            contactId: "c1", name: "Alice", email: "alice@test.com"
        )
        detail.changes = ["name changed"]
        let result = await Task.detached {
            detail.name
        }.value
        #expect(result == "Alice")
    }

    @Test("CalendarEventDetail is Sendable across isolation boundaries")
    func calendarEventDetailSendable() async {
        var detail = AgentToolRouter.ActionConfirmation.CalendarEventDetail(
            eventId: "e1", calendarId: "c1", title: "Standup",
            startDate: Date(), endDate: Date(), isAllDay: false
        )
        detail.attendees = ["alice@test.com"]
        let result = await Task.detached {
            detail.title
        }.value
        #expect(result == "Standup")
    }
}

// MARK: - Compose FIFO Queue Tests (ADR-IOS-030, taken by the asking screen per ADR-IOS-053 Phase 2)

/// Each test owns a fresh `AgentToolRouter` — no `.shared` access. This makes
/// the suite safe to run in parallel with anything else that touches the
/// singleton (compose tool tests, blocking-helper tests below, etc.). See
/// `EmailReplyToolTests` suite header for the original cross-suite flake story.
///
/// THE SYSTEM PROPERTIES pinned here: one compose window at a time, in FIFO order per screen
/// (ADR-IOS-030); and a request is only ever taken by the kind of screen that asked, showing the
/// chat that asked, whichever screens look first; a request whose screen is not showing never
/// holds another screen's request (ADR-IOS-053 Phase 2).
@Suite("AgentToolRouter Compose Queue")
@MainActor
struct AgentToolRouterComposeQueueTests {
    private static let chatKey = "thread:acc1:t-1"
    private static let chat = ComposeOrigin(sessionKey: chatKey, screen: .chat)
    private static let chatHost = AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: [chatKey])
    private static let inboxHost = ComposeTestOrigin.inboxHost

    /// Build a unique ComposeRequest for queue tests, asked from `origin`.
    private func makeRequest(_ subject: String, origin: ComposeOrigin = ComposeTestOrigin.inbox) -> AgentToolRouter.ComposeRequest {
        AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil,
            to: ["test@example.com"], cc: [], bcc: [],
            subject: subject, body: nil, origin: origin
        )
    }

    @Test("A request is taken at once by the screen that asked when no compose is on screen")
    func takenImmediatelyWhenIdle() {
        let router = AgentToolRouter()
        let req = makeRequest("First")

        router.enqueueCompose(req)
        let taken = router.takeCompose(for: Self.inboxHost)

        #expect(taken?.id == req.id)
        #expect(router.composeQueueDepth == 0)
        #expect(router.composeAwaitingAppear, "its window has not appeared yet")
    }

    @Test("A request waits in the queue while a compose is on screen")
    func holdsWhenPresented() {
        let router = AgentToolRouter()
        // Simulate that a ComposeView is currently on screen (manual or agent).
        router.composePresentationDidBegin()

        let req = makeRequest("Held")
        router.enqueueCompose(req)

        let taken = router.takeCompose(for: Self.inboxHost)
        #expect(taken == nil, "nothing is taken while a compose is on screen")
        #expect(router.composeQueueDepth == 1)
    }

    @Test("The queue is taken in FIFO order as each compose closes")
    func drainsFIFOOnDismiss() {
        let router = AgentToolRouter()
        router.composePresentationDidBegin()

        let r1 = makeRequest("First")
        let r2 = makeRequest("Second")
        let r3 = makeRequest("Third")
        router.enqueueCompose(r1)
        router.enqueueCompose(r2)
        router.enqueueCompose(r3)
        #expect(router.composeQueueDepth == 3)

        // The manual compose closes: the first request is taken, and its window appears.
        router.composePresentationDidEnd()
        let first = router.takeCompose(for: Self.inboxHost)
        #expect(first?.id == r1.id)
        router.composePresentationDidBegin()
        let whileFirstShows = router.takeCompose(for: Self.inboxHost)
        #expect(whileFirstShows == nil, "r2 and r3 wait while r1 is on screen")
        #expect(router.composeQueueDepth == 2)

        router.composePresentationDidEnd()
        let second = router.takeCompose(for: Self.inboxHost)
        #expect(second?.id == r2.id)
        router.composePresentationDidBegin()
        router.composePresentationDidEnd()
        let third = router.takeCompose(for: Self.inboxHost)
        #expect(third?.id == r3.id)
        #expect(router.composeQueueDepth == 0)

        router.composePresentationDidBegin()
        router.composePresentationDidEnd()
        let none = router.takeCompose(for: Self.inboxHost)
        #expect(none == nil, "the queue is empty")
    }

    @Test("A manual compose holds queued agent requests until it closes")
    func manualComposeBlocksAgentQueue() {
        let router = AgentToolRouter()
        // User opens compose manually — ComposeView.onAppear fires
        router.composePresentationDidBegin()

        let r1 = makeRequest("Agent 1")
        let r2 = makeRequest("Agent 2")
        router.enqueueCompose(r1)
        router.enqueueCompose(r2)
        let held = router.takeCompose(for: Self.inboxHost)
        #expect(held == nil)
        #expect(router.composeQueueDepth == 2)

        // User closes their manual compose: the first agent request is taken.
        router.composePresentationDidEnd()
        let taken = router.takeCompose(for: Self.inboxHost)
        #expect(taken?.id == r1.id)
        #expect(router.composeQueueDepth == 1)
    }

    @Test("A request queued between a take and its window appearing waits, and is taken after that window closes")
    func raceBetweenTakeAndAppear() {
        // The take ↔ onAppear window: r1 is taken, its cover is still presenting
        // (presentationCount == 0), and r2 arrives. r2 must wait, not open a second window.
        let router = AgentToolRouter()
        let r1 = makeRequest("First")
        let r2 = makeRequest("Second")

        router.enqueueCompose(r1)
        let first = router.takeCompose(for: Self.inboxHost)
        #expect(first?.id == r1.id)
        #expect(router.composeAwaitingAppear == true)

        router.enqueueCompose(r2)
        let early = router.takeCompose(for: Self.inboxHost)
        #expect(early == nil, "r2 must not open while r1's window is still presenting")
        #expect(router.composeQueueDepth == 1, "r2 must be queued")

        // r1's ComposeView appears, then closes.
        router.composePresentationDidBegin()
        #expect(router.composeAwaitingAppear == false)
        #expect(router.composePresentationCount == 1)
        router.composePresentationDidEnd()

        let second = router.takeCompose(for: Self.inboxHost)
        #expect(second?.id == r2.id)
        #expect(router.composeQueueDepth == 0)
        #expect(router.composeAwaitingAppear == true)
    }

    @Test("presentationCount never goes negative")
    func presentationCountClamped() {
        let router = AgentToolRouter()
        // Defensive: even if End is called more times than Begin
        router.composePresentationDidEnd()
        router.composePresentationDidEnd()
        #expect(router.composePresentationCount == 0)

        router.composePresentationDidBegin()
        #expect(router.composePresentationCount == 1)

        router.composePresentationDidEnd()
        #expect(router.composePresentationCount == 0)
    }

    @Test("Only the kind of screen that asked, showing the chat that asked, takes a request, whichever screens look first")
    func onlyTheAskingScreenTakes() {
        let router = AgentToolRouter()
        let req = makeRequest("Reply", origin: Self.chat)
        router.enqueueCompose(req)

        // Every other screen looks first: the inbox, the email screen of the same thread, another chat.
        let inbox = router.takeCompose(for: Self.inboxHost)
        #expect(inbox == nil, "the inbox never takes the chat's request")
        let email = router.takeCompose(for: AgentToolRouter.ComposeHost(screen: .email, sessionKeys: [Self.chatKey]))
        #expect(email == nil, "the email screen of the same thread never takes it")
        let otherChat = router.takeCompose(for: AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: ["thread:acc1:other"]))
        #expect(otherChat == nil, "another chat never takes it")
        #expect(router.composeQueueDepth == 1, "the request is still waiting")
        #expect(router.composeAwaitingAppear == false, "a take that found nothing holds nothing")

        // The chat that asked takes it, by any key of its thread.
        let host = AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: ["thread:acc1:newer", Self.chatKey])
        let taken = router.takeCompose(for: host)
        #expect(taken?.id == req.id)
    }

    @Test("A request whose screen is not showing never holds another screen's request")
    func otherScreensRequestIsNotBlocked() {
        let router = AgentToolRouter()
        let forChat = makeRequest("For the chat", origin: Self.chat)
        let forInbox = makeRequest("For the inbox")
        router.enqueueCompose(forChat)
        router.enqueueCompose(forInbox)

        // Only the inbox shows: it takes its own request, behind the chat's.
        let inbox = router.takeCompose(for: Self.inboxHost)
        #expect(inbox?.id == forInbox.id)
        #expect(router.composeQueueDepth == 1, "the chat's request waits for its chat")
        #expect(router.firstQueuedRequestForTesting?.id == forChat.id)

        // The inbox's compose comes and goes; the chat shows again and takes its request.
        router.composePresentationDidBegin()
        router.composePresentationDidEnd()
        let chat = router.takeCompose(for: Self.chatHost)
        #expect(chat?.id == forChat.id)
    }

    @Test("A screen takes its own requests oldest first")
    func oneScreenIsFIFO() {
        let router = AgentToolRouter()
        let r1 = makeRequest("First", origin: Self.chat)
        let r2 = makeRequest("Second", origin: Self.chat)
        router.enqueueCompose(r1)
        router.enqueueCompose(r2)

        let first = router.takeCompose(for: Self.chatHost)
        #expect(first?.id == r1.id)
        router.composePresentationDidBegin()
        router.composePresentationDidEnd()
        let second = router.takeCompose(for: Self.chatHost)
        #expect(second?.id == r2.id)
    }

    @Test("The offer moves when a request is queued and when the last compose closes, so the screens look again")
    func offerMovesWhenTakeable() {
        let router = AgentToolRouter()
        let start = router.composeOffer

        router.enqueueCompose(makeRequest("First"))
        #expect(router.composeOffer == start + 1, "a queued request is offered")

        router.composePresentationDidBegin()
        router.composePresentationDidBegin()
        #expect(router.composeOffer == start + 1, "a compose appearing offers nothing")
        router.composePresentationDidEnd()
        #expect(router.composeOffer == start + 1, "one compose is still on screen")
        router.composePresentationDidEnd()
        #expect(router.composeOffer == start + 2, "the last compose closed: the queue is offered again")
    }

    @Test("Two compose windows on screen need two closes before a request is taken")
    func twoSimultaneousPresentations() {
        // E.g. two screens briefly have a ComposeView mounted during a transition.
        let router = AgentToolRouter()
        router.composePresentationDidBegin()
        router.composePresentationDidBegin()

        let req = makeRequest("Pending")
        router.enqueueCompose(req)

        router.composePresentationDidEnd()
        let early = router.takeCompose(for: Self.inboxHost)
        #expect(early == nil, "one compose is still on screen")
        #expect(router.composeQueueDepth == 1)

        router.composePresentationDidEnd()
        let taken = router.takeCompose(for: Self.inboxHost)
        #expect(taken?.id == req.id)
        #expect(router.composeQueueDepth == 0)
    }
}

// MARK: - Blocking Compose Helper Tests

/// Tests the outcome-awaiting helper `enqueueComposeAndAwaitOutcome` — the
/// entry point the three email_* tools use to block on the user's send/cancel
/// decision and return a real outcome string to the LLM.
///
/// Each test owns a fresh `AgentToolRouter` so there's no shared state to
/// reset and no contention with parallel suites that touch the singleton.
@Suite("AgentToolRouter Blocking Compose Helper")
@MainActor
struct AgentToolRouterBlockingComposeTests {

    /// Shared helper: wraps the cancellation-before-dispatch setup used by
    /// `composeOutcomeOnTaskCancellation` and `staleCancelledRequestSkippedOnDispatch`.
    /// Returns only after the cancellation has propagated and the task has
    /// completed — leaves the router with a resolved request sitting at the
    /// head of the queue and `presentationCount == 1`.
    private func enqueueAndCancelTaskForTesting(router: AgentToolRouter) async -> ComposeOutcome {
        // Block the queue so the helper's request stays queued, not dispatched.
        router.composePresentationDidBegin()

        let task = Task { @MainActor () -> ComposeOutcome in
            await router.enqueueComposeAndAwaitOutcome { onOutcome, state in
                AgentToolRouter.ComposeRequest(
                    mode: .compose, replyTo: nil,
                    to: ["t@example.com"], cc: [], bcc: [],
                    subject: "Queued", body: nil,
                    origin: ComposeTestOrigin.inbox,
                    onOutcome: onOutcome, outcomeState: state
                )
            }
        }
        // Let the helper reach the withCheckedContinuation suspension and
        // enqueue its request before we cancel.
        await Task.yield()
        await Task.yield()
        task.cancel()
        return await task.value
    }

    @Test("Outcome fires exactly once (send + onDisappear double-call dedupes)")
    func composeOutcomeFiresOnce() async {
        let router = AgentToolRouter()

        let task = Task { @MainActor () -> ComposeOutcome in
            await router.enqueueComposeAndAwaitOutcome { onOutcome, state in
                AgentToolRouter.ComposeRequest(
                    mode: .reply, replyTo: nil,
                    to: ["a@b.com"], cc: [], bcc: [],
                    subject: "Re: test", body: nil,
                    origin: ComposeTestOrigin.inbox,
                    onOutcome: onOutcome, outcomeState: state
                )
            }
        }
        // Wait for the helper to enqueue (queue is idle, so the asking
        // screen can take the request on the same run).
        await Task.yield()
        await Task.yield()

        guard let req = router.takeCompose(for: ComposeTestOrigin.inboxHost) else {
            Issue.record("the asking screen should take the request after the helper enqueues")
            task.cancel()
            _ = await task.value
            return
        }

        // Simulate ComposeView.send() firing .sent followed by .onDisappear
        // firing .cancelled. Only the first should register.
        req.onOutcome(.sent)
        req.onOutcome(.cancelled)

        let outcome = await task.value
        switch outcome {
        case .sent: break  // expected
        default: Issue.record("Expected .sent, got \(outcome)")
        }
    }

    @Test("Task cancellation resumes with .cancelled and flips outcomeState")
    func composeOutcomeOnTaskCancellation() async {
        let router = AgentToolRouter()

        let outcome = await enqueueAndCancelTaskForTesting(router: router)

        switch outcome {
        case .cancelled: break  // expected
        default: Issue.record("Expected .cancelled, got \(outcome)")
        }
        // Request is still in the queue (the presentation held it), and
        // the onCancel handler flipped its resolved flag via tryResolve.
        #expect(router.composeQueueDepth == 1)
        #expect(router.firstQueuedRequestResolvedForTesting == true)
    }

    @Test("A request cancelled before it was taken is dropped, never taken")
    func staleCancelledRequestSkippedOnDispatch() async {
        let router = AgentToolRouter()

        // Same setup as the previous test — leaves a resolved request in queue.
        _ = await enqueueAndCancelTaskForTesting(router: router)
        #expect(router.composeQueueDepth == 1)

        // Now drop presentationCount to 0. The asking screen looks: the
        // resolved request is dropped, not taken.
        router.composePresentationDidEnd()
        let taken = router.takeCompose(for: ComposeTestOrigin.inboxHost)

        #expect(taken == nil)
        #expect(router.composeQueueDepth == 0)
        #expect(router.composeAwaitingAppear == false, "nothing waits for a window that will not open")
    }

    @Test("Task already cancelled before helper entry resumes cleanly (no hang)")
    func composeOutcomeOnAlreadyCancelledTask() async {
        let router = AgentToolRouter()

        // Pre-cancel the task wrapper so `withTaskCancellationHandler` sees
        // isCancelled==true at entry. Per Swift docs, onCancel fires BEFORE
        // the operation closure in this case, so the in-operation
        // `Task.isCancelled` branch must still resume the continuation —
        // previously `tryResolve` returned false (already flipped by onCancel)
        // and the guard's resume was skipped, leaking the continuation.
        let task = Task { @MainActor () -> ComposeOutcome in
            await router.enqueueComposeAndAwaitOutcome { onOutcome, state in
                AgentToolRouter.ComposeRequest(
                    mode: .reply, replyTo: nil,
                    to: ["a@b.com"], cc: [], bcc: [],
                    subject: "Pre-cancelled", body: nil,
                    origin: ComposeTestOrigin.inbox,
                    onOutcome: onOutcome, outcomeState: state
                )
            }
        }
        task.cancel()  // fires before the helper's operation closure runs
        // If this test times out waiting, the bug has regressed. Swift
        // Testing doesn't offer a timeout primitive here, so a hang would
        // surface as the entire test process hanging (manually terminable).
        let outcome = await task.value
        switch outcome {
        case .cancelled: break  // expected
        default: Issue.record("Expected .cancelled, got \(outcome)")
        }
        // No request should have been enqueued.
        #expect(router.composeQueueDepth == 0)
    }

    @Test("queueSend failure (.failed) prevents later .cancelled from overwriting")
    func failedOutcomeBlocksLaterCancel() async {
        let router = AgentToolRouter()

        let task = Task { @MainActor () -> ComposeOutcome in
            await router.enqueueComposeAndAwaitOutcome { onOutcome, state in
                AgentToolRouter.ComposeRequest(
                    mode: .compose, replyTo: nil,
                    to: ["x@y.com"], cc: [], bcc: [],
                    subject: nil, body: nil,
                    origin: ComposeTestOrigin.inbox,
                    onOutcome: onOutcome, outcomeState: state
                )
            }
        }
        await Task.yield()
        await Task.yield()
        guard let req = router.takeCompose(for: ComposeTestOrigin.inboxHost) else {
            Issue.record("the asking screen should take the request")
            task.cancel(); _ = await task.value; return
        }

        // Simulate send() catch-block firing .failed, then user closing →
        // .onDisappear firing .cancelled. The .failed must win.
        req.onOutcome(.failed("queueSend: out of disk"))
        req.onOutcome(.cancelled)

        let outcome = await task.value
        switch outcome {
        case .failed(let reason):
            #expect(reason.contains("queueSend"))
        default:
            Issue.record("Expected .failed, got \(outcome)")
        }
    }
}

// MARK: - ComposeLifecycleTracker Tests

@Suite("ComposeLifecycleTracker deinit fallback")
struct ComposeLifecycleTrackerTests {

    @Test("Fallback fires on deinit when .onDisappear didn't mark the tracker")
    func fallbackFiresWhenDisappearMissed() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = 0
            var value: Int { lock.withLock { _value } }
            func increment() { lock.withLock { _value += 1 } }
        }
        let counter = Counter()

        // Create + release the tracker inside a scope so deinit runs
        // immediately on scope exit.
        do {
            let tracker = ComposeLifecycleTracker()
            tracker.armFallback {
                counter.increment()
            }
            // Note: we do NOT call markDisappearedNormally — simulating the
            // SwiftUI-didn't-fire-onDisappear case.
            _ = tracker
        }

        // deinit runs synchronously on the releasing thread (here:
        // whichever thread ARC released on). The fallback itself may
        // dispatch to MainActor — our counter increment is sync + thread-
        // safe, so we can read immediately.
        #expect(counter.value == 1)
    }

    @Test("Fallback does NOT fire on deinit when markDisappearedNormally was called")
    func fallbackSkippedWhenDisappearFired() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = 0
            var value: Int { lock.withLock { _value } }
            func increment() { lock.withLock { _value += 1 } }
        }
        let counter = Counter()

        do {
            let tracker = ComposeLifecycleTracker()
            tracker.armFallback {
                counter.increment()
            }
            tracker.markDisappearedNormally()  // simulates .onDisappear
            _ = tracker
        }

        #expect(counter.value == 0)
    }

    @Test("armFallback on re-appearance resets the disappeared flag")
    func rearmAfterDisappearResetsFlag() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = 0
            var value: Int { lock.withLock { _value } }
            func increment() { lock.withLock { _value += 1 } }
        }
        let counter = Counter()

        do {
            let tracker = ComposeLifecycleTracker()
            tracker.armFallback { counter.increment() }
            tracker.markDisappearedNormally()  // first disappear
            tracker.armFallback { counter.increment() }  // re-appearance
            // Do NOT call markDisappearedNormally again — simulating the
            // view being destroyed silently after re-appearance.
            _ = tracker
        }

        #expect(counter.value == 1)
    }
}

// MARK: - Recently-Completed Compose Cache Tests

@Suite("RecentlyCompletedComposeCache")
@MainActor
struct RecentlyCompletedComposeCacheTests {

    private func makeKey(_ stableId: String, _ mode: AgentToolRouter.ComposeRequest.Mode = .reply) -> RecentlyCompletedComposeCache.Key {
        .init(accountId: "acc1", stableId: stableId, mode: mode)
    }

    @Test("Fresh cache reports nothing recently sent")
    func freshCacheEmpty() {
        let cache = RecentlyCompletedComposeCache()
        #expect(cache.isRecentlySent(makeKey("msg1")) == false)
        #expect(cache.countForTesting == 0)
    }

    @Test("markSent → isRecentlySent returns true for same key")
    func markedKeyIsRecent() {
        let cache = RecentlyCompletedComposeCache()
        cache.markSent(makeKey("msg1"))
        #expect(cache.isRecentlySent(makeKey("msg1")) == true)
    }

    @Test("Different stableId is not a hit")
    func differentStableIdMisses() {
        let cache = RecentlyCompletedComposeCache()
        cache.markSent(makeKey("msg1"))
        #expect(cache.isRecentlySent(makeKey("msg2")) == false)
    }

    @Test("Different mode is not a hit (reply vs forward)")
    func differentModeMisses() {
        let cache = RecentlyCompletedComposeCache()
        cache.markSent(makeKey("msg1", .reply))
        #expect(cache.isRecentlySent(makeKey("msg1", .forward)) == false)
    }

    @Test("TTL expiry: entry beyond TTL reports false and evicts")
    func ttlExpirationEvictsEntry() async throws {
        let cache = RecentlyCompletedComposeCache(ttlSeconds: 0.05)  // 50ms
        cache.markSent(makeKey("msg1"))
        #expect(cache.isRecentlySent(makeKey("msg1")) == true)
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        #expect(cache.isRecentlySent(makeKey("msg1")) == false)
        // Eviction side-effect: key is gone from the internal map.
        #expect(cache.countForTesting == 0)
    }
}

// MARK: - ComposeOutcome Describe Tests

@Suite("ComposeOutcome.describeForLLM")
struct ComposeOutcomeDescribeTests {

    @Test("sent → 'Email sent successfully.'")
    func sentDescription() {
        #expect(ComposeOutcome.sent.describeForLLM == "Email sent successfully.")
    }

    @Test("cancelled → 'User closed the compose window without sending.'")
    func cancelledDescription() {
        #expect(ComposeOutcome.cancelled.describeForLLM == "User closed the compose window without sending.")
    }

    @Test("failed(reason) → 'Failed: <reason>'")
    func failedDescription() {
        let desc = ComposeOutcome.failed("invalid unique_id").describeForLLM
        #expect(desc == "Failed: invalid unique_id")
        #expect(desc.hasPrefix("Failed: "))
    }
}
