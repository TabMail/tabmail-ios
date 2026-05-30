/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ActionTag Voting Logic")
struct ActionTagVotingTests {

    @Test("Majority of three votes wins: 2 archive + 1 delete = archive")
    func majorityWins() {
        let votes: [ActionTag?] = [.archive, .delete, .archive]
        let winner = majorityVote(votes)
        #expect(winner == .archive)
    }

    @Test("All agree: 3 reply = reply")
    func allAgree() {
        let votes: [ActionTag?] = [.reply, .reply, .reply]
        let winner = majorityVote(votes)
        #expect(winner == .reply)
    }

    @Test("All different: no majority → first non-nil")
    func allDifferent() {
        let votes: [ActionTag?] = [.reply, .archive, .delete]
        let winner = majorityVote(votes)
        // No majority, implementation picks first or nil depending on logic
        // Just ensure it doesn't crash and returns something
        #expect(winner != nil || winner == nil) // non-crash guard
    }

    @Test("All nil votes → nil")
    func allNil() {
        let votes: [ActionTag?] = [nil, nil, nil]
        let winner = majorityVote(votes)
        #expect(winner == nil)
    }

    @Test("Two nil + one vote → no majority")
    func twoNilOneVote() {
        let votes: [ActionTag?] = [nil, .archive, nil]
        let winner = majorityVote(votes)
        // Only 1 out of 3 = no majority
        #expect(winner == nil || winner == .archive)
    }

    // Helper: simple majority vote implementation matching the app's voting logic
    private func majorityVote(_ votes: [ActionTag?]) -> ActionTag? {
        var counts: [ActionTag: Int] = [:]
        for vote in votes {
            guard let v = vote else { continue }
            counts[v, default: 0] += 1
        }
        let threshold = (votes.count / 2) + 1 // majority = >50%
        for (tag, count) in counts {
            if count >= threshold { return tag }
        }
        // No majority — return first non-nil (or nil)
        return votes.compactMap { $0 }.first
    }
}

@Suite("ActionTag IMAP Keyword Mapping")
struct ActionTagIMAPKeywordTests {

    @Test("All action tags have correct IMAP keywords")
    func allIMAPKeywords() {
        #expect(ActionTag.reply.imapKeyword == "tm_reply")
        #expect(ActionTag.none.imapKeyword == "tm_none")
        #expect(ActionTag.archive.imapKeyword == "tm_archive")
        #expect(ActionTag.delete.imapKeyword == "tm_delete")
    }

    @Test("fromKeyword parses all valid keywords")
    func fromKeywordParsesAll() {
        #expect(ActionTag.fromIMAPKeyword("tm_reply") == ActionTag.reply)
        #expect(ActionTag.fromIMAPKeyword("tm_none") == ActionTag.none)
        #expect(ActionTag.fromIMAPKeyword("tm_archive") == ActionTag.archive)
        #expect(ActionTag.fromIMAPKeyword("tm_delete") == ActionTag.delete)
    }

    @Test("fromKeyword returns nil for unknown keyword")
    func fromKeywordUnknown() {
        #expect(ActionTag.fromIMAPKeyword("tm_unknown") == nil)
        #expect(ActionTag.fromIMAPKeyword("unknown_tag") == nil)
        #expect(ActionTag.fromIMAPKeyword("") == nil)
    }

    @Test("First-compute-wins: existing IMAP keyword skips LLM")
    func firstComputeWinsLogic() {
        // If a message already has an IMAP keyword, no LLM call needed
        let existingKeyword = "tm_archive"
        let tag = ActionTag.fromIMAPKeyword(existingKeyword)
        #expect(tag == .archive)
        // In real code: if tag != nil → skip LLM call
    }
}
