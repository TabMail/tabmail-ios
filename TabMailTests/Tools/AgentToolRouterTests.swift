/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - ComposeRequest Tests

@Suite("AgentToolRouter.ComposeRequest")
struct ComposeRequestTests {

    @Test("ComposeRequest has unique IDs")
    func uniqueIds() {
        let r1 = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: [], cc: [], bcc: [],
            subject: nil, body: nil
        )
        let r2 = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: [], cc: [], bcc: [],
            subject: nil, body: nil
        )
        #expect(r1.id != r2.id)
    }

    @Test("ComposeRequest stores compose mode fields")
    func composeMode() {
        let request = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil,
            to: ["alice@test.com", "bob@test.com"],
            cc: ["cc@test.com"], bcc: [],
            subject: "Meeting Notes", body: "<p>Hello</p>"
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
            subject: "Re: Original", body: nil
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
            subject: "Fwd: Important", body: "See below"
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

// MARK: - Compose FIFO Queue Tests (ADR-IOS-030)

/// Each test owns a fresh `AgentToolRouter` — no `.shared` access. This makes
/// the suite safe to run in parallel with anything else that touches the
/// singleton (compose tool tests, blocking-helper tests below, etc.). See
/// `EmailReplyToolTests` suite header for the original cross-suite flake story.
@Suite("AgentToolRouter Compose Queue")
@MainActor
struct AgentToolRouterComposeQueueTests {

    /// Build a unique ComposeRequest for queue tests.
    private func makeRequest(_ subject: String) -> AgentToolRouter.ComposeRequest {
        AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil,
            to: ["test@example.com"], cc: [], bcc: [],
            subject: subject, body: nil
        )
    }

    @Test("enqueueCompose dispatches immediately when idle")
    func dispatchesImmediatelyWhenIdle() {
        let router = AgentToolRouter()
        let req = makeRequest("First")

        router.enqueueCompose(req)

        // No compose UI presented, no prior pending → should dispatch immediately
        #expect(router.pendingCompose?.id == req.id)
        #expect(router.composeQueueDepth == 0)
    }

    @Test("enqueueCompose holds in queue when compose UI is presented")
    func holdsWhenPresented() {
        let router = AgentToolRouter()
        // Simulate that a ComposeView is currently on screen (manual or agent).
        router.composePresentationDidBegin()

        let req = makeRequest("Held")
        router.enqueueCompose(req)

        // Should NOT dispatch — pendingCompose stays nil, request stays in queue
        #expect(router.pendingCompose == nil)
        #expect(router.composeQueueDepth == 1)
    }

    @Test("Queue drains in FIFO order when compose UI dismisses")
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
        #expect(router.pendingCompose == nil)

        // Manual compose dismisses → queue dispatches first request
        router.composePresentationDidEnd()
        #expect(router.pendingCompose?.id == r1.id)
        #expect(router.composeQueueDepth == 2)

        // Simulate view capturing the request and the new ComposeView appearing
        router.pendingCompose = nil
        router.composePresentationDidBegin()

        // While r1 is presented, r2 and r3 still wait
        #expect(router.composeQueueDepth == 2)
        #expect(router.pendingCompose == nil)

        // r1 dismisses → r2 dispatches
        router.composePresentationDidEnd()
        #expect(router.pendingCompose?.id == r2.id)
        #expect(router.composeQueueDepth == 1)

        router.pendingCompose = nil
        router.composePresentationDidBegin()

        // r2 dismisses → r3 dispatches
        router.composePresentationDidEnd()
        #expect(router.pendingCompose?.id == r3.id)
        #expect(router.composeQueueDepth == 0)

        // r3 dismisses → queue empty, nothing more to dispatch
        router.pendingCompose = nil
        router.composePresentationDidBegin()
        router.composePresentationDidEnd()
        #expect(router.pendingCompose == nil)
        #expect(router.composeQueueDepth == 0)
    }

    @Test("Manual compose blocks queued agent requests until dismissed")
    func manualComposeBlocksAgentQueue() {
        let router = AgentToolRouter()
        // User opens compose manually — ComposeView.onAppear fires
        router.composePresentationDidBegin()

        // Agent fires three compose tools while user's compose is up
        let r1 = makeRequest("Agent 1")
        let r2 = makeRequest("Agent 2")
        router.enqueueCompose(r1)
        router.enqueueCompose(r2)

        // All requests queued — none dispatched
        #expect(router.pendingCompose == nil)
        #expect(router.composeQueueDepth == 2)

        // User closes their manual compose
        router.composePresentationDidEnd()

        // First agent request appears immediately
        #expect(router.pendingCompose?.id == r1.id)
        #expect(router.composeQueueDepth == 1)
    }

    @Test("Back-to-back enqueue while idle: only first dispatches, second waits")
    func backToBackEnqueueWhileIdle() {
        let router = AgentToolRouter()
        let r1 = makeRequest("First")
        let r2 = makeRequest("Second")

        router.enqueueCompose(r1)
        // r1 dispatched, view hasn't yet captured (pendingCompose still set)
        #expect(router.pendingCompose?.id == r1.id)

        router.enqueueCompose(r2)
        // r2 must wait — pendingCompose != nil so dispatch is gated
        #expect(router.pendingCompose?.id == r1.id)
        #expect(router.composeQueueDepth == 1)

        // View captures r1 and nils the slot. Cover hasn't yet finished presenting.
        router.pendingCompose = nil

        // r2 stays queued because awaitingAppear is still true (the dispatch flag
        // is only cleared by composePresentationDidBegin). This is the race-window
        // guard — see ADR-IOS-030.
        #expect(router.composeAwaitingAppear == true)
        #expect(router.composeQueueDepth == 1)

        router.composePresentationDidBegin()
        #expect(router.composeAwaitingAppear == false)
        router.composePresentationDidEnd()

        #expect(router.pendingCompose?.id == r2.id)
        #expect(router.composeQueueDepth == 0)
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

    @Test("Race: enqueue between view-capture and onAppear queues, doesn't overwrite")
    func raceBetweenCaptureAndAppear() {
        // Reproduces the dispatch ↔ onAppear race window:
        // 1. enqueue r1 → router dispatches → pendingCompose=r1
        // 2. view's onChange fires → captures into local @State, nils router slot
        // 3. (race window: pendingCompose==nil, presentationCount==0)
        // 4. enqueue r2 arrives during the window → MUST queue, not overwrite r1
        // 5. r1's ComposeView finally appears → composePresentationDidBegin
        // 6. r1 dismisses → r2 dispatches
        let router = AgentToolRouter()

        let r1 = makeRequest("First")
        let r2 = makeRequest("Second")

        router.enqueueCompose(r1)
        #expect(router.pendingCompose?.id == r1.id)
        #expect(router.composeAwaitingAppear == true)

        // Simulate the view's onChange handler: capture r1 into local @State,
        // nil the router slot. The cover hasn't yet finished presenting.
        router.pendingCompose = nil

        // Race window. Without the awaitingAppear guard, the next dispatch would
        // see pendingCompose==nil + count==0 + queue=[r2] and overwrite the
        // in-flight r1. WITH the guard, r2 must queue.
        router.enqueueCompose(r2)
        #expect(router.pendingCompose == nil, "r2 must NOT have replaced in-flight r1")
        #expect(router.composeQueueDepth == 1, "r2 must be queued")

        // r1's ComposeView finally appears
        router.composePresentationDidBegin()
        #expect(router.composeAwaitingAppear == false)
        #expect(router.composePresentationCount == 1)

        // r1 dismisses → r2 dispatches
        router.composePresentationDidEnd()
        #expect(router.pendingCompose?.id == r2.id)
        #expect(router.composeQueueDepth == 0)
        #expect(router.composeAwaitingAppear == true)
    }

    @Test("Loser in dual-observer race captures nil and presents nothing")
    func dualObserverLoserCapturesNil() {
        // Both InboxView and MessageDetailView observe pendingCompose?.id and race to
        // capture. The first to run sets its local @State and nils the router slot.
        // The second reads nil and captures nothing. This test verifies that the
        // nil-after-capture pattern works with the new queue: even after the loser
        // captures nil, the queue's awaitingAppear flag still gates further dispatches.
        let router = AgentToolRouter()

        let r1 = makeRequest("First")
        let r2 = makeRequest("Second")

        router.enqueueCompose(r1)
        #expect(router.pendingCompose?.id == r1.id)

        // Winner captures r1 and nils the slot
        router.pendingCompose = nil

        // Loser reads nil — captures nothing locally (we don't simulate, just verify
        // the router state is unchanged by repeated reads)
        _ = router.pendingCompose
        #expect(router.composeAwaitingAppear == true)

        // A second tool fires immediately. The queue must hold r2 because awaitingAppear
        // is still true (winner's ComposeView hasn't fired onAppear yet).
        router.enqueueCompose(r2)
        #expect(router.composeQueueDepth == 1)
        #expect(router.pendingCompose == nil)

        // Winner's ComposeView appears
        router.composePresentationDidBegin()
        #expect(router.composeAwaitingAppear == false)

        router.composePresentationDidEnd()
        #expect(router.pendingCompose?.id == r2.id)
    }

    @Test("Two simultaneous compose presentations require two dismisses to drain queue")
    func twoSimultaneousPresentations() {
        // E.g. InboxView and MessageDetailView both have a ComposeView mounted briefly
        // during a transition. Queue should only drain when count returns to 0.
        let router = AgentToolRouter()
        router.composePresentationDidBegin()
        router.composePresentationDidBegin()

        let req = makeRequest("Pending")
        router.enqueueCompose(req)
        #expect(router.composeQueueDepth == 1)
        #expect(router.pendingCompose == nil)

        // Only one dismissed — count is still 1
        router.composePresentationDidEnd()
        #expect(router.pendingCompose == nil)
        #expect(router.composeQueueDepth == 1)

        // Second dismissed — count is 0, dispatch fires
        router.composePresentationDidEnd()
        #expect(router.pendingCompose?.id == req.id)
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
                    onOutcome: onOutcome, outcomeState: state
                )
            }
        }
        // Wait for the helper to enqueue + dispatch (queue is idle, so the
        // request promotes straight to pendingCompose on the same run).
        await Task.yield()
        await Task.yield()

        guard let req = router.pendingCompose else {
            Issue.record("pendingCompose should be set after helper enqueues")
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
        // Request is still in the queue (presentation blocked dispatch), and
        // the onCancel handler flipped its resolved flag via tryResolve.
        #expect(router.composeQueueDepth == 1)
        #expect(router.firstQueuedRequestResolvedForTesting == true)
    }

    @Test("Stale cancelled request at queue head is skipped by dispatcher")
    func staleCancelledRequestSkippedOnDispatch() async {
        let router = AgentToolRouter()

        // Same setup as the previous test — leaves a resolved request in queue.
        _ = await enqueueAndCancelTaskForTesting(router: router)
        #expect(router.composeQueueDepth == 1)

        // Now drop presentationCount to 0. The dispatcher's stale-skip
        // while-loop should consume the resolved request without promoting
        // it to pendingCompose.
        router.composePresentationDidEnd()

        #expect(router.pendingCompose == nil)
        #expect(router.composeQueueDepth == 0)
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
                    onOutcome: onOutcome, outcomeState: state
                )
            }
        }
        await Task.yield()
        await Task.yield()
        guard let req = router.pendingCompose else {
            Issue.record("pendingCompose should be set")
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
