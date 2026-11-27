/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// A chat's send bubbles (`ChatSendBubbles`): a bubble follows its email from the outbox item to
/// its Sent copy and on, through the posted moves, and stays, "Sent", once its email was filed,
/// until the chat shows that email, though the send's cleanup deletes its row first. A row that
/// goes with no move (Undo, a discard) ends its bubble at once.
@MainActor
struct ChatSendBubblesTests {
    private static func reply(_ id: String, sentAt: Date? = nil, holdUntil: Date? = nil) -> ChatUnsentReply {
        ChatUnsentReply(outboxId: id, status: .queued, sentAt: sentAt, holdUntil: holdUntil,
                        draftId: "draft-\(id)", instanceEpoch: "epoch-\(id)", filed: false,
                        textMessage: "I said Tuesday works.")
    }

    private static func filed(_ outboxId: String, copy: String?) -> MailPointerMoves {
        MailPointerMoves([.sent(outboxId: outboxId, copyHeaderId: copy)])
    }

    private static func rowMove(_ from: String, to: String) -> MailPointerMoves {
        MailPointerMoves([.row(HeaderRekeyRecord(
            oldHeaderId: from, newHeaderId: to, newProviderMessageId: to, newObservedUidValidity: nil))])
    }

    @Test("A row that goes with no move ends its bubble at once: Undo and a discard show nothing more")
    func rowGoneWithNoMoveEnds() {
        var sends = ChatSendBubbles()
        sends.read([Self.reply("a")])
        #expect(sends.replies(showing: []).map(\.id) == ["a"], "control: the row shows")
        #expect(sends.replies(showing: []).first?.caption == "Sending", "control: sending")

        let left = sends.read([])
        #expect(left, "a row of the last read has gone: the chat reloads its emails")
        #expect(sends.replies(showing: []).isEmpty, "undone: the bubble ends")
    }

    @Test("A move that names another send leaves the bubble as it was")
    func anotherSendsMoveLeavesTheBubble() {
        var sends = ChatSendBubbles()
        sends.read([Self.reply("a")])
        sends.follow(Self.filed("b", copy: "copy-b"))
        sends.read([])
        #expect(sends.replies(showing: []).isEmpty, "not filed: the row's going ends it")
    }

    @Test("A filed send's bubble stays, Sent, after its row has gone, until the chat shows its Sent copy, and is hidden in the same pass that shows it")
    func filedSendStaysUntilItsCopyShows() {
        var sends = ChatSendBubbles()
        sends.read([Self.reply("a")])
        sends.follow(Self.filed("a", copy: "copy-a"))
        let shownWhileRowWaits = sends.replies(showing: [])
        #expect(shownWhileRowWaits.map(\.isSent) == [true], "filed: Sent while the row waits for its cleanup")

        let left = sends.read([])
        #expect(left, "the row has gone: the chat reloads its emails")
        let kept = sends.replies(showing: ["parent"])
        #expect(kept.map(\.id) == ["a"], "the send's cleanup deleted the row; the bubble stays")
        #expect(kept.first?.caption == "Sent", "and reads Sent")
        #expect(kept.first?.textMessage == "I said Tuesday works.", "with the user's words")
        #expect(sends.replies(showing: ["parent", "copy-a"]).isEmpty, "the chat shows the copy: the bubble is hidden in that pass")

        let again = sends.read([])
        #expect(!again, "no row left since the last read: no further reload")
    }

    @Test("A send that wrote no Sent copy stays Sent")
    func sendWithNoCopyStaysSent() {
        var sends = ChatSendBubbles()
        sends.read([Self.reply("a")])
        sends.follow(Self.filed("a", copy: nil))
        sends.read([])
        sends.end(shownIn: ["parent"])
        #expect(sends.replies(showing: ["parent"]).map(\.caption) == ["Sent"], "no copy to show: it stays")
    }

    @Test("The bubble follows its email from the Sent copy to the server's copy that replaced it")
    func followsTheChainOfMoves() {
        var sends = ChatSendBubbles()
        sends.read([Self.reply("a")])
        sends.follow(Self.filed("a", copy: "copy-a"))
        sends.read([])
        sends.follow(Self.rowMove("copy-a", to: "server-a"))
        #expect(sends.replies(showing: ["copy-a"]).map(\.id) == ["a"], "the copy it was filed as is no longer its email")
        #expect(sends.replies(showing: ["server-a"]).isEmpty, "the server's copy shows: the bubble is hidden")
    }

    @Test("Once the chat showed its email, the bubble never comes back: not when that email leaves the chat, nor while its row is still read")
    func endedNeverComesBack() {
        var sends = ChatSendBubbles()
        sends.read([Self.reply("a")])
        sends.follow(Self.filed("a", copy: "copy-a"))
        sends.end(shownIn: ["copy-a"])
        #expect(sends.replies(showing: []).isEmpty, "the row still waits (append pending), the email showed: ended")

        sends.read([Self.reply("a")])
        #expect(sends.replies(showing: []).isEmpty, "its row read again: still ended")
        sends.follow(Self.rowMove("copy-a", to: "trash-a"))
        sends.read([])
        #expect(sends.replies(showing: []).isEmpty, "its email moved out of the chat and its row went: still ended")
    }

    @Test("Bubbles keep their order: a kept Sent bubble stays where it was, a new row comes after")
    func keepsTheOrder() {
        var sends = ChatSendBubbles()
        sends.read([Self.reply("a"), Self.reply("b")])
        sends.follow(Self.filed("a", copy: "copy-a"))
        sends.read([Self.reply("b"), Self.reply("c")])
        let shown = sends.replies(showing: [])
        #expect(shown.map(\.id) == ["a", "b", "c"], "oldest first")
        #expect(shown.map(\.isSent) == [true, false, false], "only the filed one reads Sent")
    }

    @Test("A Sent bubble offers no Undo and looks delivered, though its row's hold has not ended")
    func sentBubbleOffersNoUndo() {
        let now = Date()
        let holdUntil = now.addingTimeInterval(SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds)
        var sending = Self.reply("a", holdUntil: holdUntil)
        #expect(sending.undoSecondsLeft(at: now) != nil, "control: the unsent row offers Undo")
        #expect(!sending.deliverySettled, "control: not settled while sending")

        sending.isSent = true
        #expect(sending.undoSecondsLeft(at: now) == nil, "Sent: nothing to undo")
        #expect(sending.deliverySettled, "Sent: delivered")
        #expect(sending.undoLook(at: now, reduceMotion: false) == .solid, "the bubble is solid")
        #expect(sending.undoLook(at: now, reduceMotion: true) == .solid, "and under Reduce Motion")
        #expect(sending.caption == "Sent", "it reads Sent")
    }
}
