/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@Suite("Compose attachment carry boundary")
@MainActor
struct ComposeAttachmentCarryTests {
    private func draft() -> Draft {
        Draft(
            id: "forward:source", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "Fwd: report", body: "See attached",
            replyToId: "source", isForward: true,
            editHistoryJSON: nil, createdAt: 1, updatedAt: 1,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil)
    }

    @Test("Send waits rather than snapshotting a partial forward carry")
    func sendWaitsForCarry() {
        #expect(ComposeDraftGuards.attachmentSnapshotGate(
            producer: .send, outstandingCarryCount: 1) == .wait)
        #expect(ComposeDraftGuards.attachmentSnapshotGate(
            producer: .send, outstandingCarryCount: 0) == .ready)
    }

    @Test("Explicit save waits rather than persisting a partial forward carry")
    func explicitSaveWaitsForCarry() {
        #expect(ComposeDraftGuards.attachmentSnapshotGate(
            producer: .explicitSave, outstandingCarryCount: 1) == .wait)
        #expect(ComposeDraftGuards.attachmentSnapshotGate(
            producer: .explicitSave, outstandingCarryCount: 0) == .ready)
    }

    @Test("Agent autosave waits rather than creating a partial forward draft")
    func autoSaveWaitsForCarry() {
        #expect(ComposeDraftGuards.attachmentSnapshotGate(
            producer: .autoSave, outstandingCarryCount: 1) == .wait)
        #expect(ComposeDraftGuards.attachmentSnapshotGate(
            producer: .autoSave, outstandingCarryCount: 0) == .ready)
    }

    @Test("The completion boundary releases only after every fetch settles")
    func completionBoundaryDoesNotReleaseEarly() async {
        let gate = ComposeAttachmentCarryGate()
        gate.begin(2)
        var released = false
        let waiter = Task { @MainActor in
            await gate.waitUntilSettled()
            released = true
        }

        await Task.yield()
        #expect(!released)
        gate.completeOne()
        await Task.yield()
        #expect(!released)
        gate.completeOne()
        await waiter.value
        #expect(released)
    }

    @Test("Autosave adopts the completed carry's staged attachment directory")
    func autoSaveAdoptsCompletedAttachmentSnapshot() {
        let updated = ComposeDraftGuards.applyingAttachmentSnapshotDirectory(
            "complete-carry", to: draft())
        #expect(updated.attachmentsDirName == "complete-carry")
        #expect(updated.subject == "Fwd: report",
                "adopting attachments must not alter authored fields")
    }
}
