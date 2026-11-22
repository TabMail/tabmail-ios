import Foundation
@testable import TabMail

/// A listing a test expects to have reached its merge: its result, whatever
/// the classifier made of it. A listing that never got there fails the test.
struct ListingReachedNoMerge: Error, CustomStringConvertible {
    let outcome: SyncEngine.ListingOutcome
    var description: String { "the listing reached no merge: \(outcome)" }
}

extension SyncEngine.ListingOutcome {
    func requireResult() throws -> SyncEngine.SyncMessagesResult {
        guard let result else { throw ListingReachedNoMerge(outcome: self) }
        return result
    }
}
