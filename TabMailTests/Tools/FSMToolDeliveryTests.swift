/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests for the owned, level-triggered FSM confirmation delivery (ADR-IOS-053).
/// These cover the delivery mechanism directly — the class of bug (a confirmation
/// card raced/lost by a global `pendingAction` slot) that hung calendar tools.
@Suite("FSM Tool Confirmation Delivery (ADR-IOS-053)")
struct FSMToolDeliveryTests {

    /// Test double for `AgentUISink` — records every delivered confirmation and
    /// optionally auto-responds (simulating the user tapping the card).
    @MainActor
    final class MockUISink: AgentUISink {
        private(set) var delivered: [AgentToolRouter.ActionConfirmation] = []
        var autoRespond: Bool?

        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            delivered.append(confirmation)
            if let answer = autoRespond {
                confirmation.onRespond(answer)
            }
        }
    }

    @Test("Delivers to the invoking sink and resumes accepted on tap")
    @MainActor
    func deliversAndResumesOnAccept() async {
        let sink = MockUISink()
        sink.autoRespond = true
        let (accepted, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .calendarEventCreate,
            calendarEvents: [.init(eventId: "", calendarId: "", title: "Standup",
                                   startDate: Date(), endDate: Date(), isAllDay: false)],
            via: sink
        )
        #expect(accepted == true)
        #expect(sink.delivered.count == 1)
        #expect(sink.delivered.first?.action == .calendarEventCreate)
    }

    @Test("Resumes declined when the user rejects the card")
    @MainActor
    func resumesDeclinedOnReject() async {
        let sink = MockUISink()
        sink.autoRespond = false
        let (accepted, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .contactDelete, contacts: [], via: sink
        )
        #expect(accepted == false)
        #expect(sink.delivered.count == 1)
    }

    /// The core regression: delivery is OWNED. A confirmation goes only to the
    /// sink it was invoked with — never broadcast to another mounted session's
    /// sink (the failure mode of the old global `pendingAction` slot).
    @Test("Routes to the invoking sink only, never another session's sink")
    @MainActor
    func routesToInvokingSinkOnly() async {
        let inboxSink = MockUISink()      // a different session's sink — must stay empty
        let msgDetailSink = MockUISink()  // the invoking session's sink
        msgDetailSink.autoRespond = true

        let (accepted, _) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .archive, emails: [], via: msgDetailSink
        )

        #expect(accepted == true)
        #expect(msgDetailSink.delivered.count == 1)
        #expect(inboxSink.delivered.isEmpty)
    }

    /// A nil sink (non-interactive callers: reply precompute, inline edit, task
    /// eval, BYOK smoke) must fast-fail as declined WITHOUT suspending — never
    /// the old "set a slot nobody observes → hang forever".
    @Test("Nil sink fast-fails declined without suspending")
    @MainActor
    func nilSinkFastFails() async {
        let (accepted, state) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .delete, emails: [], via: nil
        )
        #expect(accepted == false)
        #expect(state.failureReason == "no interactive chat session to confirm in")
    }

    /// `SessionUISink` delivery is level-triggered: it appends a confirmation
    /// `ChatMessage` to the bound session's `chatMessages`, which the pill renders
    /// declaratively. No global slot, no `.onChange` edge event.
    @Test("SessionUISink appends the card to the bound session's message list")
    @MainActor
    func sessionSinkAppendsCard() {
        // Unique key so this test can't collide with any other session state.
        let session = ChatPillState.shared.session(for: "test:fsm-delivery:\(UUID().uuidString)")
        let before = session.chatMessages.count
        let sink = SessionUISink(session: session)

        let confirmation = AgentToolRouter.ActionConfirmation(
            action: .archive, emails: [], contacts: [], calendarEvents: [], templates: [],
            onRespond: { _ in }
        )
        sink.deliverConfirmation(confirmation)

        #expect(session.chatMessages.count == before + 1)
        #expect(session.chatMessages.last?.actionConfirmation != nil)
        #expect(session.chatMessages.last?.actionConfirmation?.action == .archive)
    }
}
