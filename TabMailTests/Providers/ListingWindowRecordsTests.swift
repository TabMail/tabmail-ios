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
}
