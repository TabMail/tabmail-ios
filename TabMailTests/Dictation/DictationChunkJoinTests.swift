/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Ported from TabMail Voice's `joinChunkTexts` tests with the join itself (ADR-IOS-087).
struct DictationChunkJoinTests {
    private func paused(_ text: String) -> DictationChunkJoin.Part { .init(text: text, overlapped: false) }
    private func overlapping(_ text: String) -> DictationChunkJoin.Part { .init(text: text, overlapped: true) }
    private func join(_ parts: DictationChunkJoin.Part...) -> String { DictationChunkJoin.join(parts) }

    @Test func oneChunkIsItsOwnTextUntouchedButForTheWhitespaceAroundIt() {
        #expect(join(paused("  Hello there... and then.  ")) == "Hello there... and then.")
        #expect(join() == "")
    }

    @Test func chunksCutAtAPauseAreJoinedWithASpaceNothingElseChanged() {
        #expect(join(paused("First part."), paused("Second part,"), paused("and the Third.")) == "First part. Second part, and the Third.")
    }

    @Test func anEllipsisWhereTwoChunksMeetIsTakenOutOneInsideAChunkStays() {
        #expect(join(paused("So I was thinking…"), paused("… that we could wait... maybe."), paused("...Or not")) == "So I was thinking that we could wait... maybe. Or not")
        #expect(join(paused("Ends here ... …"), paused("next")) == "Ends here next")
    }

    @Test func anEllipsisAtTheVeryStartOrEndOfTheWholeDictationStays() {
        #expect(join(paused("…well"), paused("then...")) == "…well then...")
    }

    @Test func anEmptyOrEllipsisOnlyChunkAddsNothingAndLeavesNoDoubleSpace() {
        #expect(join(paused("One."), paused("   "), paused("…"), paused("Two.")) == "One. Two.")
        #expect(join(paused(""), paused("Only this.")) == "Only this.")
    }

    @Test func scriptsWrittenWithoutSpacesAreJoinedWithoutOne() {
        #expect(join(paused("今日は会議があります。"), paused("明日は休みです。")) == "今日は会議があります。明日は休みです。")
        #expect(join(paused("我们明天见"), paused("好的")) == "我们明天见好的")
        #expect(join(paused("สวัสดีครับ"), paused("ขอบคุณครับ")) == "สวัสดีครับขอบคุณครับ")
        #expect(join(paused("Meeting at 3."), paused("会議です")) == "Meeting at 3.会議です")
        #expect(join(paused("안녕하세요."), paused("반갑습니다.")) == "안녕하세요. 반갑습니다.")
    }

    @Test func overlappingChunksAreJoinedWhereTheirWordsRunTogetherTheSharedWordsKeptOnce() {
        let left = "We should ship the release on Friday because the tests are gre"
        let right = "release on Friday because the tests are green and the notes are ready."
        #expect(join(paused(left), overlapping(right)) == "We should ship the release on Friday because the tests are green and the notes are ready.")
    }

    @Test func theOverlapMatchIgnoresTheCapitalsAndPunctuationACutChanges() {
        let left = "Then we talked about the budget, and the plan for. Next"
        let right = "About the budget and the plan for next quarter."
        #expect(join(paused(left), overlapping(right)) == "Then we talked about the budget and the plan for next quarter.")
    }

    /// A later chunk's text starts with a capital, as any text does, though its first words are
    /// mid-sentence: the shared run starts as the earlier chunk wrote it (owner, 2026-10-03:
    /// "capitalization mid breaks"), and a name keeps its capital, as both wrote it.
    @Test func anOverlapJoinKeepsTheEarlierTextsCaseWhereTheLaterOneStarts() {
        let left = "I want to read something long again so that you can test the forced"
        let right = "Something long again so that you can test the forced cuts and how well it does."
        #expect(join(paused(left), overlapping(right)) == "I want to read something long again so that you can test the forced cuts and how well it does.")
        #expect(join(paused("we asked Robin about the budget for next"), overlapping("Robin about the budget for next quarter.")) == "we asked Robin about the budget for next quarter.")
    }

    @Test func overlappingChunksWithNoSharedRunAreJoinedWhole() {
        #expect(join(paused("Alpha beta gamma delta"), overlapping("delta epsilon zeta")) == "Alpha beta gamma delta delta epsilon zeta")
        // A run shorter than `chunkOverlapMinimumRun` words is not trusted.
        let short = (0..<(DictationConfig.chunkOverlapMinimumRun - 1)).map { "w\($0)" }.joined(separator: " ")
        #expect(join(paused("one two \(short)"), overlapping("\(short) three")) == "one two \(short) \(short) three")
    }

    @Test func anOverlapJoinKeepsTheEarlierTextsLineBreaks() {
        let left = "Dear team,\n\nThe launch moved to next week because the build is late"
        let right = "because the build is late and QA needs two more days."
        #expect(join(paused(left), overlapping(right)) == "Dear team,\n\nThe launch moved to next week because the build is late and QA needs two more days.")
    }

    /// A forced cut comes after about 105 s of speech, so the earlier text is far longer than the
    /// window searched for the overlap: the words before the window are all kept.
    @Test func anOverlapJoinKeepsAllOfALongEarlierTextBeforeTheWindowSearched() {
        let filler = (0..<(DictationConfig.chunkOverlapSearchWords * 2 + 40)).map { "word\($0)" }.joined(separator: " ")
        let earlier = "\(filler) and then we agreed to ship the beta on Fri"
        #expect(join(paused(earlier), overlapping("we agreed to ship the beta on Friday after the review.")) == "\(filler) and then we agreed to ship the beta on Friday after the review.")
    }

    @Test func anOverlapIsMatchedOnlyNearTheSeam() {
        let filler = (0..<DictationConfig.chunkOverlapSearchWords).map { "f\($0)" }.joined(separator: " ")
        // The shared words sit further than `chunkOverlapSearchWords` from the end of the earlier text.
        let left = "red green blue \(filler)"
        let right = "red green blue again"
        #expect(join(paused(left), overlapping(right)) == "\(left) \(right)")
    }

    @Test func anOverlapIsMatchedOnlyNearTheSeamInTheLaterTextToo() {
        let filler = (0..<DictationConfig.chunkOverlapSearchWords).map { "f\($0)" }.joined(separator: " ")
        // The shared words sit further than `chunkOverlapSearchWords` from the start of the later text.
        let left = "we start with red green blue"
        let right = "\(filler) red green blue again"
        #expect(join(paused(left), overlapping(right)) == "\(left) \(right)")
    }

    /// A chunk overlaps only the one just before it. After an empty one (a long silence not sent, or
    /// nothing heard), matching it against an earlier chunk's words would cut out the speech between.
    @Test(arguments: ["", "  ", "…"])
    func aChunkOverlappingAnEmptyOneIsJoinedWholeNotMatchedAgainstTheChunkBeforeThat(empty: String) {
        let first = "I think that one of the main points is the travel cost and the hotel."
        let last = "Okay, back again. I think that one of the main points we missed is staffing."
        #expect(join(paused(first), overlapping(empty), overlapping(last)) == "\(first) \(last)")
    }

    @Test func anOverlapAndAnEllipsisTogetherTheEllipsisGoesThenTheWordsAreMatched() {
        #expect(join(paused("we will meet on the second floor..."), overlapping("…on the second floor at noon")) == "we will meet on the second floor at noon")
    }

    @Test func aWholeEarlierChunkRepeatedInTheOverlapIsKeptOnce() {
        #expect(join(paused("one two three"), overlapping("one two three four five")) == "one two three four five")
    }
}
