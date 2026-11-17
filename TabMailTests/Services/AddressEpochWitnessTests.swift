/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
import UserNotifications
@testable import TabMail

/// tabmail-ios #538: a message with no usable Message-ID is witnessed by the
/// UIDVALIDITY its address was proven under. The witness refuses only a row
/// whose PROVEN epoch differs; it never refuses an unproven (nil) epoch, and a
/// usable Message-ID stays the sole witness when present.
@Suite("ExpectedMessageIdentity — address-epoch witness for rows with no Message-ID")
struct AddressEpochWitnessTests {

    private func row(rfc: String?, epoch: Int?, id: String = "acc1:INBOX:7") -> MessageHeader {
        var h = MessageHeader(
            messageId: "7", subject: "s", from: "f", fromAddress: "f@example.com",
            to: "t@example.com", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        h.id = id
        h.rfc822MessageId = rfc
        h.observedUidValidity = epoch
        return h
    }

    @Test("a witness-less row with a proven epoch is refused when the row at its address has a different proven epoch")
    func refusesADifferentProvenEpoch() throws {
        let captured = try #require(ExpectedMessageIdentity(header: row(rfc: nil, epoch: 5)))
        #expect(!captured.matches(row(rfc: nil, epoch: 6)))
        #expect(captured.matches(row(rfc: nil, epoch: 5)))
        #expect(captured.matches(row(rfc: nil, epoch: nil)), "an unproven epoch is not evidence of a re-seat")
    }

    @Test("partition refuses the re-seated witness-less row and keeps the matching one")
    func partitionUsesTheEpochArm() {
        let a = row(rfc: nil, epoch: 5, id: "acc1:INBOX:7")
        let b = row(rfc: nil, epoch: 5, id: "acc1:INBOX:8")
        let witnesses = ExpectedMessageIdentity.map([a, b])
        #expect(witnesses.count == 2)
        let (matched, refused) = ExpectedMessageIdentity.partition(
            [row(rfc: nil, epoch: 9, id: a.id), b], against: witnesses)
        #expect(refused == [a.id])
        #expect(matched.map(\.id) == [b.id])
    }

    @Test("a usable Message-ID stays the only witness: the same message re-seated under a new epoch is admitted")
    func rfcWitnessWinsOverEpoch() throws {
        let captured = try #require(ExpectedMessageIdentity(header: row(rfc: "<a@example.com>", epoch: 5)))
        #expect(captured.matches(row(rfc: "<a@example.com>", epoch: 6)))
        #expect(!captured.matches(row(rfc: "<b@example.com>", epoch: 5)))
    }

    @Test("no Message-ID and no proven epoch: still no witness, so nothing is refused")
    func noWitnessAtAll() {
        #expect(ExpectedMessageIdentity(header: row(rfc: nil, epoch: nil)) == nil)
        #expect(ExpectedMessageIdentity(header: row(rfc: "<>", epoch: 0)) == nil)
        #expect(ExpectedMessageIdentity.map([row(rfc: nil, epoch: nil)]).isEmpty)
    }

    @Test("an undo member takes its address epoch only from a snapshot whose id names its own address")
    func undoMemberAddressEpoch() {
        let own = UndoMember(header: row(rfc: nil, epoch: 5))
        #expect(own.addressObservedUidValidity == 5)
        let moved = UndoMember(header: row(rfc: nil, epoch: 5, id: "acc1:Archive:7"))
        #expect(moved.addressObservedUidValidity == nil, "a source epoch says nothing about another address")
        var rekeyed = own
        rekeyed.rekey(accountId: "acc1", newHeaderId: "acc1:Archive:30",
                      newProviderMessageId: "30", newObservedUidValidity: 77)
        #expect(rekeyed.addressObservedUidValidity == 77)
    }

    @Test("the notification records the observed epoch of its UID, and only a positive one")
    func notificationCarriesTheEpoch() {
        let signal = EmailNotificationBuilder.Signal(senderName: "Eve", subject: "Hi")
        let content = UNMutableNotificationContent()
        _ = EmailNotificationBuilder.fill(
            content, signal: signal, accountId: "acc1", messageId: "7", observedUidValidity: 41)
        #expect(EmailNotificationBuilder.observedUidValidity(from: content.userInfo) == 41)

        let bare = UNMutableNotificationContent()
        _ = EmailNotificationBuilder.fill(
            bare, signal: signal, accountId: "acc1", messageId: "7", observedUidValidity: nil)
        #expect(bare.userInfo[EmailNotificationBuilder.observedUidValidityUserInfoKey] == nil)
        #expect(EmailNotificationBuilder.observedUidValidity(from: ["observedUidValidity": 0]) == nil)
    }

    @Test("the NSE partial-delivery holder keeps the epoch with the address it publishes")
    func partialHolderKeepsTheEpoch() throws {
        let holder = PartialSignalHolder()
        holder.set(EmailNotificationBuilder.Signal(senderName: "Eve", subject: "Hi"),
                   accountId: "acc1", messageId: "7", observedUidValidity: 41)
        let partial = try #require(holder.get())
        #expect(partial.observedUidValidity == 41)
        #expect(partial.messageId == "7")
    }
}
