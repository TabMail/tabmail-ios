import Foundation
import SwiftMail
import Testing
@testable import TabMail

/// A window listing hands on only the records of the window it asked for: an
/// unsolicited FETCH outside the window, a record without a UID or a repeat of
/// a UID never reaches the rows or the sweep bounds, the same set the proof
/// counts.
@Suite("Window listing: only the requested window's records")
struct ListingWindowRecordsTests {

    private func info(_ seq: UInt32, uid: UInt32?) -> MessageInfo {
        MessageInfo(sequenceNumber: SequenceNumber(seq), uid: uid.map { UID($0) })
    }

    @Test("Records outside the window, without a UID or repeated are dropped; the proof counts the kept set")
    func onlyInWindowRecordsAreKept() {
        let infos = [
            info(8, uid: 80), info(9, uid: 90), info(10, uid: 100),
            info(2, uid: 20),     // unsolicited, below the window: would widen the sweep's lower bound
            info(9, uid: 90),     // repeated
            info(10, uid: nil),   // no UID
        ]
        let kept = IMAPProvider.inWindow(infos, from: 8, through: 10)
        #expect(kept.compactMap { $0.uid?.value } == [80, 90, 100])
        #expect(kept.allSatisfy { (8...10).contains(Int($0.sequenceNumber.value)) })
        #expect(IMAPProvider.answeredInWindow(infos, from: 8, through: 10) == 3)
        #expect(IMAPProvider.inWindow(infos, from: 5, through: 4).isEmpty)
    }

    @Test("A CONDSTORE SELECT refused by the server or by the client's capability check renegotiates; other failures do not")
    func condStoreSelectRefusals() {
        #expect(IMAPProvider.isCondStoreSelectRefusal(.selectFailed("NO")))
        #expect(IMAPProvider.isCondStoreSelectRefusal(.commandNotSupported("CONDSTORE")))
        #expect(!IMAPProvider.isCondStoreSelectRefusal(.timeout))
        #expect(!IMAPProvider.isCondStoreSelectRefusal(.connectionFailed("closed")))
    }

    @Test("A windowed sweep never judges a UID at or above its own SELECT's UIDNEXT, even when its FETCH returned it flagged \\Deleted")
    func windowedSweepStopsBelowItsOwnUidNext() {
        func row(_ uid: Int) -> MessageHeader {
            MessageHeader(
                messageId: String(uid), subject: "window \(uid)", from: "Sender",
                fromAddress: "sender@example.com", to: "recipient@example.com",
                date: Date().addingTimeInterval(-86_400), snippet: "window fixture",
                folderId: "acct:Archive", accountId: "acct", folderPath: "Archive", isInInbox: false)
        }
        // SELECT reported UIDNEXT 10; before the FETCH, UID 10 arrived (and an
        // older message went), so the FETCH returned 6...10 with 10 \Deleted at
        // that moment. Another listing has since stored 10 as live.
        var fetched = (6...10).map { ChangeApplyTests.info(String($0)) }
        fetched[4].isDeletedOnServer = true
        let coverage = FetchCoverage(
            serverRecordCount: 5, spansEntireFolder: false, unmaterialisedIds: [],
            counters: ListingCounters(messageCount: 5, uidNext: 10, highestModSeq: nil))
        let stale = SyncEngine.selectStaleHeaders(
            candidates: [row(7), row(10)], fetched: fetched.filter { $0.messageId != "7" },
            coverage: coverage, windowMode: .uid)
        #expect(Set(stale.map(\.messageId)) == ["7"], "10 is above the SELECT: never removal evidence; 7, inside and absent, is")
    }

    @Test("A window's records are consistent only with each sequence number once and UIDs rising with it")
    func windowRecordConsistency() {
        #expect(IMAPProvider.windowRecordsAreConsistent([info(8, uid: 80), info(9, uid: 90), info(10, uid: 100)]))
        #expect(!IMAPProvider.windowRecordsAreConsistent([info(8, uid: 80), info(9, uid: 90), info(10, uid: 100), info(8, uid: 2)]),
                "two UIDs for sequence 8")
        #expect(!IMAPProvider.windowRecordsAreConsistent([info(8, uid: 80), info(9, uid: 70)]), "UID falls as the sequence rises")
        #expect(!IMAPProvider.windowRecordsAreConsistent([info(8, uid: nil)]), "a record without a UID")
        #expect(IMAPProvider.windowRecordsAreConsistent([]))
    }
}
