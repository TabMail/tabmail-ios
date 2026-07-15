/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Helpers

/// Builds a minimal single-account, single-member `UndoableAction` — stack
/// mechanics tests (push/evict/currentAction) only need a distinguishable
/// identity per entry, not a real header/DB. Payload SHAPE (grouping,
/// admission, label text) is covered by `TabMailTests/Models/UndoableActionTests.swift`.
private func makeMoveAction(
    rfc822MessageId: String = "msg-100@example.com",
    originalHeaderId: String = "acc1:INBOX:100",
    accountId: String = "acc1",
    sourceFolderPath: String = "INBOX",
    forwardDestinationPath: String = "Trash"
) -> UndoableAction {
    UndoableAction(commands: [
        UndoAccountCommand(
            accountId: accountId,
            forwardDestinationPath: forwardDestinationPath,
            members: [
                UndoMember(
                    memberIdentity: rfc822MessageId,
                    sourceFolderPath: sourceFolderPath,
                    originalHeaderId: originalHeaderId
                ),
            ]
        ),
    ])
}

// MARK: - UndoService State Tests

@Suite("UndoService State Management", .processGlobalState)
struct UndoServiceStateTests {

    @MainActor
    private func resetService() {
        UndoService.shared.dismissAll()
    }

    @Test("Initial state - empty stack and no toast")
    @MainActor
    func initialState() {
        resetService()
        let service = UndoService.shared
        #expect(service.undoStack.isEmpty)
        #expect(service.currentAction == nil)
        #expect(service.showToast == false)
    }

    @Test("currentAction is nil when stack is empty")
    @MainActor
    func currentActionNilOnEmpty() {
        resetService()
        #expect(UndoService.shared.currentAction == nil)
    }

    @Test("dismissAll clears stack and hides toast")
    @MainActor
    func dismissAllClearsStack() {
        resetService()
        let service = UndoService.shared
        service.dismissAll()
        #expect(service.undoStack.isEmpty)
        #expect(service.showToast == false)
    }

    @Test("dismissToast hides toast without clearing stack")
    @MainActor
    func dismissToastHidesToast() {
        resetService()
        let service = UndoService.shared
        service.dismissToast()
        #expect(service.showToast == false)
        // Stack should still be empty (was empty to begin with)
        #expect(service.undoStack.isEmpty)
    }

    @Test("dismissAll is idempotent - multiple calls do not crash")
    @MainActor
    func dismissAllIdempotent() {
        resetService()
        let service = UndoService.shared
        service.dismissAll()
        service.dismissAll()
        service.dismissAll()
        #expect(service.undoStack.isEmpty)
        #expect(service.showToast == false)
    }

    @Test("dismissToast is idempotent - multiple calls do not crash")
    @MainActor
    func dismissToastIdempotent() {
        resetService()
        let service = UndoService.shared
        service.dismissToast()
        service.dismissToast()
        service.dismissToast()
        #expect(service.showToast == false)
    }

    @Test("push evicts the oldest actions beyond max size and keeps the newest current")
    @MainActor
    func realPushEvictsOldestBeyondMaxSize() {
        resetService()
        defer { UndoService.shared.dismissAll() }
        let service = UndoService.shared
        let total = SyncConfig.undoStackMaxSize + 2
        var rfcIds: [String] = []
        for i in 0..<total {
            let rfcId = "evict-\(i)@example.com"
            let action = makeMoveAction(rfc822MessageId: rfcId, originalHeaderId: "acc1:INBOX:evict-\(i)")
            rfcIds.append(rfcId)
            service.push(action)
        }
        #expect(service.undoStack.count == SyncConfig.undoStackMaxSize,
                "stack is bounded at max size after \(total) pushes")
        #expect(service.currentAction?.commands.first?.members.first?.memberIdentity == rfcIds.last,
                "the just-pushed action survives eviction as currentAction")
        let expectedOldestSurvivor = rfcIds.dropFirst(2).first
        #expect(
            service.undoStack.first?.commands.first?.members.first?.memberIdentity == expectedOldestSurvivor,
            "the oldest two entries (and only those) were evicted"
        )
        #expect(
            service.undoStack.compactMap { $0.commands.first?.members.first?.memberIdentity }
                == Array(rfcIds.dropFirst(2)),
            "walk order is preserved oldest-to-newest after eviction"
        )
    }

    @Test("undoStackMaxSize config is within reasonable range")
    func undoStackMaxSizeReasonable() {
        #expect(SyncConfig.undoStackMaxSize >= 5)
        #expect(SyncConfig.undoStackMaxSize <= 50)
    }

    @Test("undoStackMaxSize matches expected value of 20")
    func undoStackMaxSizeValue() {
        #expect(SyncConfig.undoStackMaxSize == 20)
    }
}

// MARK: - UndoService Undo on Empty Stack

@Suite("UndoService Empty Stack Behavior", .processGlobalState)
struct UndoServiceEmptyStackTests {

    @MainActor
    private func resetService() {
        UndoService.shared.dismissAll()
    }

    @Test("undo on empty stack does not crash")
    @MainActor
    func undoOnEmptyStack() async {
        resetService()
        let service = UndoService.shared
        // undo() when empty should just log and return gracefully
        // It accesses AccountManager.shared so we just verify no crash on empty guard
        #expect(service.undoStack.isEmpty)
        // The guard at the top of undo() returns early if stack is empty,
        // before touching AccountManager or dbPool
        await service.undo()
        #expect(service.undoStack.isEmpty)
    }
}
