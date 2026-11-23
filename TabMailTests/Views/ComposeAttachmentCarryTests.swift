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
            before: "private func discardDraftAndDismiss(_ scope: ComposeDraftGuards.DiscardScope) async {",
            in: composeSource())
        let claim = try #require(body.range(of: "isSavingDraft = true"))
        let wait = try #require(body.range(of: "await settledAttachmentSnapshot"))
        #expect(claim.lowerBound < wait.lowerBound,
                "the compose must become non-reentrant before the new carry suspension")
        #expect(body.contains("defer"),
                "every early return after the pre-wait claim must release it")
    }

    /// Discard's exclusions run in `ComposeDraftDiscardTests`.
    @Test("An in-flight explicit Save rejects competing close and send entries")
    func explicitSaveExcludesCompetingComposeActions() throws {
        let source = try composeSource()
        let close = try functionBody(
            "private func closeCompose() async {",
            before: "private func deleteClearedDraftAndDismiss() async {",
            in: source)
        let send = try functionBody(
            "private func send(chatViewActive: Bool) async {",
            before: "// MARK: - Discard-unsaved-edits confirmation",
            in: source)
        for (name, body) in [("close", close), ("send", send)] {
            #expect(body.contains("guard !isSavingDraft else { return }"),
                    "a save waiting on attachment carry must exclude the competing \(name) action")
        }
    }

    @Test("Explicit Save arbitrates with an already-running compose-agent edit")
    func explicitSaveClaimsAgentDispositionBeforeSnapshot() throws {
        let body = try functionBody(
            "private func saveDraftAndDismiss() async {",
            before: "private func discardDraftAndDismiss(_ scope: ComposeDraftGuards.DiscardScope) async {",
            in: composeSource())
        let claim = try #require(body.range(of: "agentSendFence.claimExclusiveDisposition()"))
        let snapshot = try #require(body.range(of: "await settledAttachmentSnapshot"))
        #expect(claim.lowerBound < snapshot.lowerBound,
                "an older Save snapshot must not race and overwrite an admitted agent edit")
        #expect(body.contains("agentSendFence.releaseExclusiveDisposition()"),
                "a failed or completed Save must release agent admission")
    }

    @Test("An in-flight Send rejects a competing close")
    func sendExcludesCompetingTerminalComposeActions() throws {
        let close = try functionBody(
            "private func closeCompose() async {",
            before: "private func deleteClearedDraftAndDismiss() async {",
            in: composeSource())
        #expect(close.contains("guard !isSending else { return }"),
                "an admitted send must exclude the competing close action")
    }

    @Test("Close arbitrates with a running compose-agent edit")
    func terminalComposeActionsClaimAgentDisposition() throws {
        let close = try functionBody(
            "private func closeCompose() async {",
            before: "private func deleteClearedDraftAndDismiss() async {",
            in: composeSource())
        #expect(close.contains("agentSendFence.claimExclusiveDisposition()"),
                "a running agent edit must exclude the competing close action")
        #expect(close.contains("agentSendFence.releaseExclusiveDisposition()"),
                "a failed or completed close must restore agent admission")
    }

    @Test("Close treats unsettled attachment preparation as unsaved content")
    func closeCannotSilentlyDropPendingAttachmentIntention() throws {
        let body = try functionBody(
            "private func closeCompose() async {",
            before: "private func deleteClearedDraftAndDismiss() async {",
            in: composeSource())
        #expect(body.contains(
            "let attachmentPreparationIsUnsettled = attachmentCarryGate.outstanding > 0"),
            "Close must account for selected attachment work before it becomes a realized chip")
        #expect(body.contains(
            "hasAttachments: !attachments.isEmpty || attachmentLoadFailed || attachmentPreparationIsUnsettled"),
            "pending attachment work is content and must not take the empty-delete path")
        #expect(body.contains(
            "hasUnsettledWork: attachmentPreparationIsUnsettled || hasVisibleSuggestion"),
            "pending attachment work is an unsaved change and must prompt before dismissal")
    }

    @Test("Explicit Save writes in order: read fail-closed, stage, save through the generation, clean up after commit, queue only when adopted")
    func explicitSaveWriteOrder() throws {
        let body = try functionBody(
            "private func saveDraftAndDismiss() async {",
            before: "private func discardDraftAndDismiss(_ scope: ComposeDraftGuards.DiscardScope) async {",
            in: composeSource())
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let writer = try String(
            contentsOf: root.appendingPathComponent("TabMail/Views/Compose/ComposeDraftSave.swift"), encoding: .utf8)
        let chat = try String(
            contentsOf: root.appendingPathComponent("TabMail/Views/Chat/ChatNewThread.swift"), encoding: .utf8)
        let writerSteps = [
            "try Draft.fetchOne(db, key: draftId)",
            "ComposeDraftGuards.saveMayMutate(",
            "DraftAttachmentStorage.saveAttachments(attachments, dirName: staging)",
            "ComposeDraftGuards.draftToSave(",
            "saveResult = try await admit(draft)",
            "saveApplied: saveResult == .applied",
            "guard saveResult == .applied else {",
            "return .committed(previousPushStatus:",
        ]
        let composeSteps = [
            "await ComposeDraftSave.run(",
            "admit: { draft in try await saveThroughGeneration(draft) })",
            "case .committed(let previousPushStatus):",
            "AccountManager.shared.queueDraftSave(",
        ]
        let chatSteps = [
            "await ComposeDraftSave.run(",
            "case .committed:",
            "guard await queueDraftSave(draftId, accountId) else {",
        ]
        for (name, source, steps) in [("writer", writer[...], writerSteps), ("compose", body, composeSteps), ("chat", chat[...], chatSteps)] {
            let found = steps.compactMap { source.range(of: $0)?.lowerBound }
            #expect(found.count == steps.count, "every step of the \(name)'s save is present")
            guard found.count == steps.count else { continue }
            #expect(found == found.sorted(), "the \(name)'s steps run in this order")
        }
        #expect(!body.contains("DraftAttachmentStorage.saveAttachments"), "compose writes only through the shared writer")
        #expect(!chat.contains("DraftAttachmentStorage.saveAttachments"), "the chat writes only through the shared writer")
        // Every way Save can fail tells the user, and stops there; a refused queue admission keeps
        // the compose open with its own message.
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let failures = [
            "case .readFailed: sendError = \"Couldn't save this draft — the database was busy. Try again in a moment.\" return",
            "case .attachmentsNotStaged(let reason): sendError = \"Failed to save attachments: \\(reason)\" return",
            "case .saveFailed(let reason): sendError = \"Failed to save draft: \\(reason)\" return",
            "case .superseded: sendError = \"Failed to save draft: \\(DraftStore.DraftEpochAdmissionError.staleOrReserved.localizedDescription)\" return",
            "onAdmissionFailure: { sendError = \"This draft couldn't be saved to your Drafts folder. Your message is still here — tap Save to try again.\" })",
        ]
        for failure in failures {
            #expect(flat.contains(failure), "compose's Save keeps this failure's message and stop: \(failure)")
        }
        // A save the queue admitted closes compose: the push, then the real dismissal, and the
        // refusal's message otherwise (`ComposeDraftGuards.runCheckedDurableSaveThenDismiss`, whose
        // own tests drive both arms).
        #expect(flat.contains("await ComposeDraftGuards.runCheckedDurableSaveThenDismiss( save: { await AccountManager.shared.queueDraftSave( draftId: draftId, accountId: account.id) }, dismiss: { dismiss() }, onAdmissionFailure: {"),
                "compose's Save pushes, then dismisses compose itself")
    }

    @Test("Photos-picker work joins the same attachment completion boundary")
    func photoPickerPreparationCannotBeSnapshottedMidImport() throws {
        let source = try composeSource()
        // The card's Photos button: its picker's items, loaded and typed by their first content
        // type, through the one step that adds picked photos; the selection clears afterward.
        let picker = try functionBody(
            "private func handlePhotoPickerItemsChange(_ items: [PhotosPickerItem]) {",
            before: "private func performLifecycleAppear()",
            in: source)
        let pickerFlat = picker.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(pickerFlat.contains("addPickedPhotos( items, load: { item in (try await item.loadTransferable(type: Data.self), item.supportedContentTypes.first) }, then: { photoPickerItems = [] })"),
                "the picker's items load whole, typed by their first content type, and the selection clears once they settled: \(pickerFlat)")
        #expect(!picker.contains("try? await item.loadTransferable"),
                "a selected attachment that fails to load must be surfaced, not silently omitted")

        let body = try functionBody(
            "private func addPickedPhotos<Item>(",
            before: "// MARK: - File Import",
            in: source)
        #expect(body.contains("guard !items.isEmpty else { return }"),
                "clearing the selection (no items) counts nothing into the gate")
        let begin = try #require(body.range(of: "attachmentCarryGate.begin(items.count)"))
        let load = try #require(body.range(of: "await DraftAttachmentImport.loadPicked("))
        let complete = try #require(body.range(of: "attachmentCarryGate.completeOne"))
        #expect(begin.lowerBound < load.lowerBound && load.lowerBound < complete.lowerBound,
                "every selected item must be counted before its async load and settled afterward")
        let publish = try #require(body.range(of: "publishAttachmentPreparationFailuresIfSettled()"))
        #expect(complete.lowerBound < publish.lowerBound, "failures are published once the item settles")
        let done = try #require(body.range(of: "done()"))
        #expect(publish.lowerBound < done.lowerBound, "what runs afterward (the selection clearing) runs after every item settled")
        // Inside the same task, after the loader returns: outside it, the selection would clear
        // while the items still load.
        let bodyFlat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(bodyFlat.contains("publishAttachmentPreparationFailuresIfSettled() }) done() } }"),
                "done() runs in the loading task, once the loader has returned: \(bodyFlat.suffix(160))")
        #expect(body.contains("load: load,"), "each item loads with its picker's own loader")
        #expect(body.contains("recordAttachmentPreparationFailure"), "a failed item is surfaced as compose's preparation failure")
        // What the loader gives compose lands in compose's own list, named by what is there.
        #expect(body.contains("existingCount: { attachments.count },"), "a picked item is named by the attachments already there")
        #expect(body.contains("add: { attachments.append($0) },"), "every item that loads is added to the compose")
        #expect(body.contains("fail: { recordAttachmentPreparationFailure($0) },"), "every item that does not load is surfaced")
        #expect(body.contains("attachmentCarryGate.completeOne(succeeded: succeeded)"),
                "each item settles the gate with its own result, so a failed pick holds Save until it is seen")
        // The whole closure, so nothing wraps the call: a failed item that skipped it would leave
        // the gate waiting for it forever, and Save with it.
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains("settled: { succeeded in attachmentCarryGate.completeOne(succeeded: succeeded) publishAttachmentPreparationFailuresIfSettled() })"),
                "every item settles the gate, failed or not, then failures are published")
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
        #expect(camera.contains("CameraPickerView { image in addCameraPhoto(image) }"),
                "the camera's photo is added by the one camera step")
        let addCamera = try functionBody(
            "private func addCameraPhoto(_ image: UIImage) {",
            before: "private func addAttachmentPick() {",
            in: source)
        #expect(addCamera.contains("recordAttachmentPreparationFailure(DraftAttachmentImport.cameraFailureLabel)"),
                "a failed camera-image conversion must be surfaced")
        #expect(addCamera.contains("publishAttachmentPreparationFailuresIfSettled()"),
                "and shown once nothing else is still being prepared")
    }
}
