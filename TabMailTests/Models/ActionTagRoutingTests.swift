/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ActionTag Routing — resolveAction")
struct ActionTagRoutingTests {

    // MARK: - Main message (isMainMessage = true)

    @Test("Reply tag on main message returns .reply")
    func replyMainMessage() {
        let result = ActionTag.reply.resolveAction(isMainMessage: true)
        #expect(result == .reply)
    }

    @Test("Archive tag on main message returns .archiveAndDismiss")
    func archiveMainMessage() {
        let result = ActionTag.archive.resolveAction(isMainMessage: true)
        #expect(result == .archiveAndDismiss)
    }

    @Test("Delete tag on main message returns .deleteAndDismiss")
    func deleteMainMessage() {
        let result = ActionTag.delete.resolveAction(isMainMessage: true)
        #expect(result == .deleteAndDismiss)
    }

    @Test("None tag on main message returns .noop")
    func noneMainMessage() {
        let result = ActionTag.none.resolveAction(isMainMessage: true)
        #expect(result == .noop)
    }

    // MARK: - Thread message (isMainMessage = false)

    @Test("Reply tag on thread message returns .reply")
    func replyThreadMessage() {
        let result = ActionTag.reply.resolveAction(isMainMessage: false)
        #expect(result == .reply)
    }

    @Test("Archive tag on thread message returns .archiveInPlace (no dismiss)")
    func archiveThreadMessage() {
        let result = ActionTag.archive.resolveAction(isMainMessage: false)
        #expect(result == .archiveInPlace)
    }

    @Test("Delete tag on thread message returns .deleteInPlace (no dismiss)")
    func deleteThreadMessage() {
        let result = ActionTag.delete.resolveAction(isMainMessage: false)
        #expect(result == .deleteInPlace)
    }

    @Test("None tag on thread message returns .noop")
    func noneThreadMessage() {
        let result = ActionTag.none.resolveAction(isMainMessage: false)
        #expect(result == .noop)
    }

    // MARK: - Reply is always .reply regardless of context

    @Test("Reply action is the same for main and thread messages")
    func replyConsistentAcrossContexts() {
        let mainResult = ActionTag.reply.resolveAction(isMainMessage: true)
        let threadResult = ActionTag.reply.resolveAction(isMainMessage: false)
        #expect(mainResult == threadResult)
        #expect(mainResult == .reply)
    }

    // MARK: - Archive/Delete differ between main and thread

    @Test("Archive routes differently for main vs thread")
    func archiveDiffersForMainVsThread() {
        let mainResult = ActionTag.archive.resolveAction(isMainMessage: true)
        let threadResult = ActionTag.archive.resolveAction(isMainMessage: false)
        #expect(mainResult != threadResult)
    }

    @Test("Delete routes differently for main vs thread")
    func deleteDiffersForMainVsThread() {
        let mainResult = ActionTag.delete.resolveAction(isMainMessage: true)
        let threadResult = ActionTag.delete.resolveAction(isMainMessage: false)
        #expect(mainResult != threadResult)
    }
}
