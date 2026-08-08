/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@Suite("Compose attachment carry boundary")
@MainActor
struct ComposeAttachmentCarryTests {
    private func composeSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectRoot
            .appendingPathComponent("TabMail/Views/Compose/ComposeView.swift"),
            encoding: .utf8)
    }

    private func functionBody(
        _ signature: String,
        before nextSignature: String,
        in source: String
    ) throws -> Substring {
        let start = try #require(source.range(of: signature))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: nextSignature))
        return tail[..<end.lowerBound]
    }

    private func sourceSlice(
        _ startMarker: String,
        before endMarker: String,
        in source: String
    ) throws -> Substring {
        let start = try #require(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: endMarker))
        return tail[..<end.lowerBound]
    }

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
        gate.completeOne(succeeded: true)
        await Task.yield()
        #expect(!released)
        gate.completeOne(succeeded: true)
        await waiter.value
        #expect(released)
    }

    @Test("A failed carry blocks every snapshot until the user acknowledges it")
    func failedCarryBlocksEveryProducer() async {
        let gate = ComposeAttachmentCarryGate()
        gate.begin(1)
        gate.completeOne(succeeded: false)

        for producer in ComposeDraftGuards.AttachmentSnapshotProducer.allCases {
            #expect(ComposeDraftGuards.attachmentSnapshotGate(
                producer: producer,
                outstandingCarryCount: gate.outstanding,
                hasUnacknowledgedFailure: gate.hasUnacknowledgedFailure
            ) == .blockedByFailure)
        }

        gate.acknowledgeFailures()
        for producer in ComposeDraftGuards.AttachmentSnapshotProducer.allCases {
            #expect(ComposeDraftGuards.attachmentSnapshotGate(
                producer: producer,
                outstandingCarryCount: gate.outstanding,
                hasUnacknowledgedFailure: gate.hasUnacknowledgedFailure
            ) == .ready)
        }
    }

    @Test("Autosave adopts the completed carry's staged attachment directory")
    func autoSaveAdoptsCompletedAttachmentSnapshot() {
        let updated = ComposeDraftGuards.applyingAttachmentSnapshotDirectory(
            "complete-carry", to: draft())
        #expect(updated.attachmentsDirName == "complete-carry")
        #expect(updated.subject == "Fwd: report",
                "adopting attachments must not alter authored fields")
    }

    @Test("Explicit Save claims the compose before waiting for attachment carry")
    func explicitSaveClaimsBeforeCarryWait() throws {
        let body = try functionBody(
            "private func saveDraftAndDismiss() async {",
            before: "private func discardDraftAndDismiss() async {",
            in: composeSource())
        let claim = try #require(body.range(of: "isSavingDraft = true"))
        let wait = try #require(body.range(of: "await settledAttachmentSnapshot"))
        #expect(claim.lowerBound < wait.lowerBound,
                "the compose must become non-reentrant before the new carry suspension")
        #expect(body.contains("defer"),
                "every early return after the pre-wait claim must release it")
    }

    @Test("An in-flight explicit Save rejects competing close, discard, and send entries")
    func explicitSaveExcludesCompetingComposeActions() throws {
        let source = try composeSource()
        let close = try functionBody(
            "private func closeCompose() async {",
            before: "private func deleteClearedDraftAndDismiss() async {",
            in: source)
        let discard = try functionBody(
            "private func discardDraftAndDismiss() async {",
            before: "private func typedDeleteIdentity(for draft: Draft) async",
            in: source)
        let send = try functionBody(
            "private func send() async {",
            before: "// MARK: - Discard-unsaved-edits confirmation",
            in: source)
        for (name, body) in [("close", close), ("discard", discard), ("send", send)] {
            #expect(body.contains("guard !isSavingDraft else { return }"),
                    "a save waiting on attachment carry must exclude the competing \(name) action")
        }
    }

    @Test("Explicit Save arbitrates with an already-running compose-agent edit")
    func explicitSaveClaimsAgentDispositionBeforeSnapshot() throws {
        let body = try functionBody(
            "private func saveDraftAndDismiss() async {",
            before: "private func discardDraftAndDismiss() async {",
            in: composeSource())
        let claim = try #require(body.range(of: "agentSendFence.claimExclusiveDisposition()"))
        let snapshot = try #require(body.range(of: "await settledAttachmentSnapshot"))
        #expect(claim.lowerBound < snapshot.lowerBound,
                "an older Save snapshot must not race and overwrite an admitted agent edit")
        #expect(body.contains("agentSendFence.releaseExclusiveDisposition()"),
                "a failed or completed Save must release agent admission")
    }

    @Test("An in-flight Send rejects competing close and discard entries")
    func sendExcludesCompetingTerminalComposeActions() throws {
        let source = try composeSource()
        let close = try functionBody(
            "private func closeCompose() async {",
            before: "private func deleteClearedDraftAndDismiss() async {",
            in: source)
        let discard = try functionBody(
            "private func discardDraftAndDismiss() async {",
            before: "private func typedDeleteIdentity(for draft: Draft) async",
            in: source)
        for (name, body) in [("close", close), ("discard", discard)] {
            #expect(body.contains("guard !isSending else { return }"),
                    "an admitted send must exclude the competing \(name) action")
        }
    }

    @Test("Close and Discard arbitrate with a running compose-agent edit")
    func terminalComposeActionsClaimAgentDisposition() throws {
        let source = try composeSource()
        let close = try functionBody(
            "private func closeCompose() async {",
            before: "private func deleteClearedDraftAndDismiss() async {",
            in: source)
        let discard = try functionBody(
            "private func discardDraftAndDismiss() async {",
            before: "private func typedDeleteIdentity(for draft: Draft) async",
            in: source)
        for (name, body) in [("close", close), ("discard", discard)] {
            #expect(body.contains("agentSendFence.claimExclusiveDisposition()"),
                    "a running agent edit must exclude the competing \(name) action")
            #expect(body.contains("agentSendFence.releaseExclusiveDisposition()"),
                    "a failed or completed \(name) must restore agent admission")
        }
    }

    @Test("Photos-picker work joins the same attachment completion boundary")
    func photoPickerPreparationCannotBeSnapshottedMidImport() throws {
        let body = try functionBody(
            "private func handlePhotoPickerItemsChange(_ items: [PhotosPickerItem]) {",
            before: "private func performLifecycleAppear()",
            in: composeSource())
        let begin = try #require(body.range(of: "attachmentCarryGate.begin"))
        let load = try #require(body.range(of: "await item.loadTransferable"))
        let complete = try #require(body.range(of: "attachmentCarryGate.completeOne"))
        #expect(begin.lowerBound < load.lowerBound && load.lowerBound < complete.lowerBound,
                "every selected item must be counted before its async load and settled afterward")
        #expect(!body.contains("try? await item.loadTransferable"),
                "a selected attachment that fails to load must be surfaced, not silently omitted")
    }

    @Test("File and camera attachment preparation failures are surfaced")
    func synchronousAttachmentPreparationFailuresAreNotSilent() throws {
        let source = try composeSource()
        let fileImport = try functionBody(
            "private func handleFileImport(_ result: Result<[URL], Error>) {",
            before: "// MARK: - Send",
            in: source)
        #expect(!fileImport.contains("try? Data(contentsOf:"),
                "a selected file read failure must not disappear")
        #expect(fileImport.contains("recordAttachmentPreparationFailure"))

        let camera = try sourceSlice(
            ".fullScreenCover(isPresented: $showCamera)",
            before: ".dismissKeyboardOnTap()",
            in: source)
        #expect(camera.contains("recordAttachmentPreparationFailure"),
                "a failed camera-image conversion must be surfaced")
    }
}
