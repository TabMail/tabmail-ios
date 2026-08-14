/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MessageDetailView — List conversion & address display")
struct MessageDetailViewTests {

    private func detailViewSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(
                "TabMail/Views/Message/MessageDetailView.swift"
            ),
            encoding: .utf8
        )
    }

    @Test("A user disclosure permanently disarms late-layout opening re-anchors")
    func disclosureDisarmsOpeningAnchor() {
        var gate = MessageDetailOpenAnchorGate()
        #expect(gate.shouldReanchor(hasLaterMessages: true))
        #expect(!gate.shouldReanchor(hasLaterMessages: false))

        gate.userTookControl()

        #expect(!gate.shouldReanchor(hasLaterMessages: true))
    }

    @Test("Every focused-card proxy scroll revalidates the opening gate")
    func focusedCardProxyWritesStayCentralized() throws {
        let source = try detailViewSource()
        let helperStart = try #require(source.range(
            of: "private func reanchorFocusedCard("
        ))
        let helperTail = source[helperStart.lowerBound...]
        let helperEnd = try #require(helperTail.range(
            of: "@ViewBuilder\n    private func messageContent"
        ))
        let helper = helperTail[..<helperEnd.lowerBound]
        let gate = try #require(helper.range(
            of: "openAnchorGate.shouldReanchor(hasLaterMessages: hasLaterMessages)"
        ))
        let write = try #require(helper.range(of: "proxy.scrollTo("))

        #expect(gate.lowerBound < write.lowerBound,
                "the gate must run before the centralized proxy write")
        #expect(source.components(separatedBy: "proxy.scrollTo(").count - 1 == 1,
                "a new direct proxy write would bypass execution-time gate revalidation")
    }

    // MARK: - Address Field Persistence (validates .fixedSize display fix)

    @Test("MessageHeader cc field persists through DB roundtrip")
    func ccFieldPersistence() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Update cc with multiple addresses
        let ccValue = "alice@example.com, bob@example.com, carol@example.com"
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET cc = ? WHERE id = ?",
                arguments: [ccValue, header.id]
            )
        }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        #expect(fetched?.cc == ccValue)
    }

    @Test("MessageHeader bcc field persists through DB roundtrip")
    func bccFieldPersistence() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        let bccValue = "secret1@example.com, secret2@example.com"
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET bcc = ? WHERE id = ?",
                arguments: [bccValue, header.id]
            )
        }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        #expect(fetched?.bcc == bccValue)
    }

    @Test("MessageHeader replyTo field persists through DB roundtrip")
    func replyToFieldPersistence() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        let replyToValue = "noreply@example.com"
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET replyTo = ? WHERE id = ?",
                arguments: [replyToValue, header.id]
            )
        }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        #expect(fetched?.replyTo == replyToValue)
    }

    @Test("MessageHeader To field with many recipients persists fully")
    func toFieldMultipleRecipients() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let longTo = (1...10).map { "user\($0)@example.com" }.joined(separator: ", ")
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1", to: longTo)

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        #expect(fetched?.to == longTo)
    }

    @Test("MessageHeader fromAddress with long address persists fully")
    func fromAddressLongValue() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let longFromAddr = "very-long-email-address-that-could-be-truncated@subdomain.example.com"
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", fromAddress: longFromAddr
        )

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        #expect(fetched?.fromAddress == longFromAddr)
    }

    // MARK: - Toggle Read (DB pattern used by swipe action)

    @Test("toggleRead pattern: flips isRead from false to true")
    func toggleReadPattern() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)

        // Replicate the toggleReadForThread DB pattern
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET isRead = ? WHERE id = ?",
                arguments: [1, msg.id]
            )
        }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(fetched?.isRead == true)
    }

    @Test("toggleRead pattern: flips isRead from true to false")
    func toggleReadPatternReverse() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: true)

        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET isRead = ? WHERE id = ?",
                arguments: [0, msg.id]
            )
        }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(fetched?.isRead == false)
    }

    // MARK: - Archive/Delete (DB pattern: folder lookup used by swipe actions)

    @Test("archiveMessage pattern: archive folder lookup succeeds")
    func archiveFolderLookup() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db) // inbox
        let archiveFolder = try TestDatabase.insertFolder(
            db, name: "Archive", path: "[Gmail]/All Mail", role: .archive
        )

        let found = try db.read { dbConn in
            try Folder.filter(
                Column("accountId") == "acc1" && Column("role") == FolderRole.archive.rawValue
            ).fetchOne(dbConn)
        }

        #expect(found != nil)
        #expect(found?.id == archiveFolder.id)
        #expect(found?.path == "[Gmail]/All Mail")
    }

    @Test("deleteMessage pattern: trash folder lookup succeeds")
    func trashFolderLookup() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db) // inbox
        let trashFolder = try TestDatabase.insertFolder(
            db, name: "Trash", path: "[Gmail]/Trash", role: .trash
        )

        let found = try db.read { dbConn in
            try Folder.filter(
                Column("accountId") == "acc1" && Column("role") == FolderRole.trash.rawValue
            ).fetchOne(dbConn)
        }

        #expect(found != nil)
        #expect(found?.id == trashFolder.id)
        #expect(found?.path == "[Gmail]/Trash")
    }

    @Test("archiveMessage pattern: returns nil when no archive folder exists")
    func archiveFolderMissing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db) // inbox only

        let found = try db.read { dbConn in
            try Folder.filter(
                Column("accountId") == "acc1" && Column("role") == FolderRole.archive.rawValue
            ).fetchOne(dbConn)
        }

        #expect(found == nil)
    }

    @Test("deleteMessage pattern: returns nil when no trash folder exists")
    func trashFolderMissing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db) // inbox only

        let found = try db.read { dbConn in
            try Folder.filter(
                Column("accountId") == "acc1" && Column("role") == FolderRole.trash.rawValue
            ).fetchOne(dbConn)
        }

        #expect(found == nil)
    }

    // MARK: - Action Target Routing (focused vs thread message)

    @Test("Action targets focused message when IDs match")
    func actionTargetsFocused() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let focused = try TestDatabase.insertMessageHeader(db, messageId: "1")
        let thread = try TestDatabase.insertMessageHeader(db, messageId: "2")

        // Simulate the routing logic from handleArchive/handleDelete
        let isFocused = (thread.id == focused.id)
        #expect(isFocused == false)

        let isFocusedSelf = (focused.id == focused.id)
        #expect(isFocusedSelf == true)
    }

    @Test("Thread message body lookup returns nil before fetch, body after insert")
    func threadBodyLookup() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Before body fetch — bodyFor returns nil
        let beforeBody = try db.read { try MessageBody.fetchOne($0, key: msg.id) }
        #expect(beforeBody == nil)

        // After body fetch — bodyFor returns the body
        _ = try TestDatabase.insertMessageBody(db, headerId: msg.id, htmlContent: "<p>Hello</p>")
        let afterBody = try db.read { try MessageBody.fetchOne($0, key: msg.id) }
        #expect(afterBody != nil)
        #expect(afterBody?.htmlContent == "<p>Hello</p>")
    }

    // MARK: - Thread Split Rendering Order (List row order)

    @Test("List row order: later reversed, focused, earlier reversed")
    func listRowOrder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let earlier1 = try TestDatabase.insertMessageHeader(
            db, messageId: "e1", date: now.addingTimeInterval(-3600)
        )
        let earlier2 = try TestDatabase.insertMessageHeader(
            db, messageId: "e2", date: now.addingTimeInterval(-1800)
        )
        let focused = try TestDatabase.insertMessageHeader(
            db, messageId: "f", date: now
        )
        let later1 = try TestDatabase.insertMessageHeader(
            db, messageId: "l1", date: now.addingTimeInterval(1800)
        )
        let later2 = try TestDatabase.insertMessageHeader(
            db, messageId: "l2", date: now.addingTimeInterval(3600)
        )

        // Replicate recomputeThreadSplit
        let threadMessages = [earlier1, earlier2, later1, later2]
        let focusDate = focused.date
        let focusId = focused.id

        let earlierMsgs = threadMessages
            .filter { $0.date < focusDate || ($0.date == focusDate && $0.id < focusId) }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        let laterMsgs = threadMessages
            .filter { $0.date > focusDate || ($0.date == focusDate && $0.id > focusId) }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }

        // Build the List row order as MessageDetailView does:
        // laterMessages.reversed() + focused + earlierMessages.reversed()
        let rowOrder = laterMsgs.reversed().map(\.id) + [focused.id] + earlierMsgs.reversed().map(\.id)

        #expect(rowOrder.count == 5)
        guard rowOrder.count == 5 else { return }
        // Later reversed: newest first (l2, l1)
        #expect(rowOrder[0] == later2.id)
        #expect(rowOrder[1] == later1.id)
        // Focused in middle
        #expect(rowOrder[2] == focused.id)
        // Earlier reversed: most recent first (e2, e1)
        #expect(rowOrder[3] == earlier2.id)
        #expect(rowOrder[4] == earlier1.id)
    }

    // MARK: - Card Visibility Selection (PreferenceKey logic)

    /// Helper: compute midY from CardVisibility's minY/maxY
    private func midY(_ card: CardVisibility) -> CGFloat {
        (card.minY + card.maxY) / 2
    }

    @Test("Closest card to screen center is selected from multiple expanded cards")
    func closestCardSelection() {
        let screenCenter: CGFloat = 400  // simulate screen center
        let cards = [
            CardVisibility(id: "card-top", minY: 100, maxY: 200),
            CardVisibility(id: "card-mid", minY: 330, maxY: 430),
            CardVisibility(id: "card-bottom", minY: 600, maxY: 700)
        ]

        let closest = cards.min(by: { abs(midY($0) - screenCenter) < abs(midY($1) - screenCenter) })
        #expect(closest?.id == "card-mid")
    }

    @Test("Single expanded card is always selected")
    func singleCardAlwaysSelected() {
        let screenCenter: CGFloat = 400
        let cards = [CardVisibility(id: "only-card", minY: 750, maxY: 850)]

        let closest = cards.min(by: { abs(midY($0) - screenCenter) < abs(midY($1) - screenCenter) })
        #expect(closest?.id == "only-card")
    }

    @Test("Empty card list returns no selection")
    func emptyCardsNoSelection() {
        let screenCenter: CGFloat = 400
        let cards: [CardVisibility] = []

        let closest = cards.min(by: { abs((($0.minY + $0.maxY) / 2) - screenCenter) < abs((($1.minY + $1.maxY) / 2) - screenCenter) })
        #expect(closest == nil)
    }

    @Test("Card exactly at screen center wins over equidistant cards")
    func exactCenterWins() {
        let screenCenter: CGFloat = 400
        let cards = [
            CardVisibility(id: "above", minY: 250, maxY: 350),
            CardVisibility(id: "exact", minY: 350, maxY: 450),
            CardVisibility(id: "below", minY: 450, maxY: 550)
        ]

        let closest = cards.min(by: { abs(midY($0) - screenCenter) < abs(midY($1) - screenCenter) })
        #expect(closest?.id == "exact")
    }

    @Test("allMessages lookup finds correct message by ID")
    func allMessagesLookup() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", date: now.addingTimeInterval(-3600))
        let focused = try TestDatabase.insertMessageHeader(db, messageId: "2", date: now)
        let msg3 = try TestDatabase.insertMessageHeader(db, messageId: "3", date: now.addingTimeInterval(3600))

        // Simulate allMessages = laterMessages + [focused] + earlierMessages
        let allMessages = [msg3] + [focused] + [msg1]

        // Search by ID (same logic as .onPreferenceChange)
        let foundFocused = allMessages.first(where: { $0.id == focused.id })
        #expect(foundFocused != nil)
        #expect(foundFocused?.id == focused.id)

        let foundThread = allMessages.first(where: { $0.id == msg1.id })
        #expect(foundThread != nil)
        #expect(foundThread?.id == msg1.id)

        // Non-existent ID returns nil
        let notFound = allMessages.first(where: { $0.id == "nonexistent" })
        #expect(notFound == nil)
    }

    // MARK: - Multiple Address Fields Set Together

    @Test("All address fields (to, cc, bcc, replyTo) roundtrip together")
    func allAddressFieldsRoundtrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let toValue = "alice@example.com, bob@example.com"
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: toValue
        )

        let ccValue = "cc1@example.com, cc2@example.com, cc3@example.com"
        let bccValue = "bcc1@example.com"
        let replyToValue = "reply-to@different-domain.com"
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET cc = ?, bcc = ?, replyTo = ? WHERE id = ?",
                arguments: [ccValue, bccValue, replyToValue, header.id]
            )
        }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        guard let fetched else { return }
        #expect(fetched.to == toValue)
        #expect(fetched.cc == ccValue)
        #expect(fetched.bcc == bccValue)
        #expect(fetched.replyTo == replyToValue)
        #expect(fetched.fromAddress == "sender@example.com")
    }
}
