/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// One email can change place while a view shows it (a send filed as the
/// app's Sent copy, that copy replaced by the server's, a provider move, a UID
/// repair). Every holder follows the same posted moves through
/// `MailPointerMoves`; these tests pin what a holder learns from one post.
@Suite("Mail pointer moves")
struct MailPointerMovesTests {

    static func row(_ old: String, _ new: String, authority: Bool = true) -> MailPointerMove {
        .row(HeaderRekeyRecord(
            oldHeaderId: old, newHeaderId: new, newProviderMessageId: "p-\(new)",
            carriesProviderAuthority: authority))
    }

    @Test("A stored row follows its move; a row no move names stays")
    func storedRowFollowsItsMove() {
        let moves = MailPointerMoves([Self.row("a:Sent:sent-1", "a:Sent:500")])
        #expect(moves.following(header: "a:Sent:sent-1") == "a:Sent:500")
        #expect(moves.following(header: "a:Sent:other") == "a:Sent:other")
        #expect(moves.following(.header("a:Sent:sent-1")) == .header("a:Sent:500"))
        #expect(moves.following(.header("a:Sent:other")) == .header("a:Sent:other"))
        #expect(moves.row(movedFrom: "a:Sent:sent-1")?.newProviderMessageId == "p-a:Sent:500")
        #expect(moves.following(headers: ["a:Sent:sent-1", "a:Sent:other"])
            == ["a:Sent:500", "a:Sent:other"])
    }

    @Test("When two moves name one row, the first wins")
    func firstMoveWins() {
        let moves = MailPointerMoves([
            Self.row("a:INBOX:1", "a:Archive:7"),
            Self.row("a:INBOX:1", "a:Trash:9"),
        ])
        #expect(moves.following(header: "a:INBOX:1") == "a:Archive:7")
    }

    @Test("A filed send leads to its Sent copy, or to nothing when no copy was written")
    func filedSendLeadsToItsCopy() {
        let filed = MailPointerMoves([.sent(outboxId: "out-1", copyHeaderId: "a:Sent:sent-out-1")])
        #expect(filed.following(.outbox("out-1")) == .header("a:Sent:sent-out-1"))
        #expect(filed.following(.outbox("out-2")) == .outbox("out-2"))

        let noCopy = MailPointerMoves([.sent(outboxId: "out-1", copyHeaderId: nil)])
        #expect(noCopy.move(for: .outbox("out-1")) != nil, "a filed send is told apart from an undone one")
        #expect(noCopy.following(.outbox("out-1")) == nil)
    }

    @Test("A send's filing never re-keys a stored row")
    func sendNeverReKeysARow() {
        // An outbox id and a header id can be the same string; they are
        // different pointers.
        let moves = MailPointerMoves([.sent(outboxId: "x", copyHeaderId: "a:Sent:sent-x")])
        #expect(moves.following(header: "x") == "x")
        #expect(moves.row(movedFrom: "x") == nil)
    }

    @Test("Only provider-proven moves carry action state")
    func onlyProvenMovesCarryActionState() {
        let moves = MailPointerMoves([
            Self.row("a:INBOX:1", "a:Archive:7"),
            Self.row("a:Sent:sent-2", "a:Sent:500", authority: false),
            .sent(outboxId: "out-3", copyHeaderId: "a:Sent:sent-out-3"),
        ])
        let proven = moves.withProviderAuthority
        #expect(proven.following(header: "a:INBOX:1") == "a:Archive:7")
        #expect(proven.following(header: "a:Sent:sent-2") == "a:Sent:sent-2")
        #expect(proven.move(for: .outbox("out-3")) == nil)
    }

    @Test("A post carries its moves to every observer, and an empty post is not made")
    @MainActor func postDeliversTheMoves() {
        let marker = Self.row("t:INBOX:post-1", "t:INBOX:post-2")
        let received = Mutex<[MailPointerMoves]>([])
        let token = NotificationCenter.default.addObserver(
            forName: .mailPointersMoved, object: nil, queue: nil
        ) { notification in
            // Other suites may post at the same time: keep this test's post
            // and any empty one.
            guard let moves = notification.object as? MailPointerMoves,
                  moves.isEmpty || moves.moves.contains(marker) else { return }
            received.withLock { $0.append(moves) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        MailPointerMoves.post(MailPointerMoves([]))
        let moves = MailPointerMoves([marker])
        MailPointerMoves.post(moves)

        let delivered = received.withLock { $0 }
        #expect(delivered == [moves], "delivered synchronously, once, and never empty")
    }
}

/// The open detail's SwiftUI identity is the id it was opened with, so a move
/// of its email never rebuilds it: the user's scroll, an open compose cover
/// with unsaved text, a sheet and the chat input stay. It shows the moved
/// email. The input is the selection (which follows the move through
/// `HeaderRekeyReceiver`) or a pushed id (which keeps the id it was opened
/// with); both must give the same identity and the same row.
@Suite("An open detail across a move of its email")
struct OpenedMessageTests {

    static let placeholder = "a:Sent:sent-1"
    static let copy = "a:Sent:500"
    static let moved = "a:Archive:77"

    /// The move the sync posts when the server's copy replaces the placeholder.
    static func replaced() throws -> MailPointerMoves {
        let record = SyncEngine.placeholderReplacement(
            of: header(messageId: "sent-1"), by: header(messageId: "500"))
        return MailPointerMoves([.row(try #require(record))])
    }

    static func header(messageId: String) -> MessageHeader {
        MessageHeader(
            messageId: messageId, subject: "s", from: "f", fromAddress: "f@example.com",
            to: "t@example.com", date: Date(), snippet: "", folderId: "a:Sent", accountId: "a",
            folderPath: "Sent", isInInbox: false)
    }

    @Test("A pushed detail keeps its identity and shows the server's copy")
    func pushedDetailKeepsItsIdentity() throws {
        var opened = OpenedMessage()
        let pushed = Self.placeholder
        let identityBefore = opened.identity(for: pushed)

        let moves = try Self.replaced()
        opened.follow(moves, input: pushed)

        #expect(opened.identity(for: pushed) == identityBefore, "the detail is not rebuilt")
        #expect(opened.currentId(for: pushed) == Self.copy, "it shows the server's copy")
    }

    @Test("A selected detail keeps its identity when the selection follows the move")
    @MainActor func selectedDetailKeepsItsIdentity() throws {
        var opened = OpenedMessage()
        var selected: String? = Self.placeholder
        var dismissed: Set<String> = []
        var fading: Set<String> = []
        let identityBefore = opened.identity(for: Self.placeholder)

        // Both observers of the one post: the detail follows with the input it
        // last rendered, and the receiver moves the selection.
        let moves = try Self.replaced()
        opened.follow(moves, input: Self.placeholder)
        HeaderRekeyReceiver.apply(
            moves, dismissedMessages: &dismissed, swipeFadingMessages: &fading,
            selectedMessageId: &selected)

        guard let input = selected else {
            Issue.record("the selection must stay set")
            return
        }
        #expect(input == Self.copy, "the list's selection names the row that exists")
        #expect(opened.identity(for: input) == identityBefore, "the detail is not rebuilt")
        #expect(opened.currentId(for: input) == Self.copy)
    }

    @Test("A chain of moves ends on the last row with the first identity")
    func chainEndsOnTheLastRow() throws {
        var opened = OpenedMessage()
        let then = MailPointerMoves([.row(HeaderRekeyRecord(
            oldHeaderId: Self.copy, newHeaderId: Self.moved, newProviderMessageId: "77"))])

        let replaced = try Self.replaced()
        opened.follow(replaced, input: Self.placeholder)
        opened.follow(then, input: Self.placeholder)

        #expect(opened.identity(for: Self.placeholder) == Self.placeholder)
        #expect(opened.currentId(for: Self.placeholder) == Self.moved)
        #expect(opened.identity(for: Self.moved) == Self.placeholder, "the followed selection too")
    }

    @Test("Opening another email forgets the move; reopening the first id reads that id")
    func anotherOpenForgetsTheMove() throws {
        var opened = OpenedMessage()
        opened.follow(try Self.replaced(), input: Self.placeholder)
        opened.open(Self.copy)
        #expect(opened.currentId(for: Self.copy) == Self.copy, "the followed selection stays on its open")

        opened.open("a:INBOX:3")
        #expect(opened.identity(for: Self.placeholder) == Self.placeholder)
        #expect(opened.currentId(for: Self.placeholder) == Self.placeholder,
                "a later open of the first id reads that id, not where it went")
    }

    @Test("A move of another email changes nothing; another open is a new detail")
    func otherEmailsAreUntouched() throws {
        var opened = OpenedMessage()
        let unrelated = MailPointerMoves([.row(HeaderRekeyRecord(
            oldHeaderId: "a:INBOX:9", newHeaderId: "a:Archive:9", newProviderMessageId: "9"))])
        opened.follow(unrelated, input: Self.placeholder)
        #expect(opened == OpenedMessage())

        let replaced = try Self.replaced()
        opened.follow(replaced, input: Self.placeholder)
        #expect(opened.identity(for: "a:INBOX:3") == "a:INBOX:3")
        #expect(opened.currentId(for: "a:INBOX:3") == "a:INBOX:3")
    }
}
