/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// What the user's edit of a dictation teaches the dictionary (ADR-IOS-086): respellings within the
/// dictated text, nothing else. TabMail Voice's `learnedCorrections` cases (ADR-DESK-038), ported.
struct DictationCorrectionsTests {
    private let pasted = "Please forward the Zivora contract to Keelthorn Draszek before Friday."

    /// The words learned when the user edits the dictated text, alone in its field, into `edited`.
    private func learned(_ edited: String, before: String? = nil) -> [String] {
        let before = before ?? pasted
        return DictationCorrections.learned(pasted: pasted, before: before, after: before.replacingOccurrences(of: pasted, with: edited))
    }

    private func learned(_ text: String, _ before: String, _ after: String) -> [String] {
        DictationCorrections.learned(pasted: text, before: before, after: after)
    }

    @Test func learnsARespelledWord() {
        #expect(learned("Please forward the Xyvora contract to Keelthorn Draszek before Friday.") == ["Xyvora"])
    }

    @Test func learnsEachRespellingOfOneEditOnce() {
        #expect(learned("Please forward the Xyvora contract to Kaelthorne Draszek before Friday.") == ["Xyvora", "Kaelthorne"])
        let twice = "Zivora met the team, and the team met Zivora."
        #expect(learned(twice, twice, twice.replacingOccurrences(of: "Zivora", with: "Xyvora")) == ["Xyvora"])
    }

    /// A name heard as two words, or two words heard as one, is learned whole.
    @Test func learnsARespellingAcrossWords() {
        #expect(learned("Sync the tab mail inbox.", "Sync the tab mail inbox.", "Sync the TabMail inbox.") == ["TabMail"])
        #expect(learned("Ask Kaelthornedraszek today.", "Ask Kaelthornedraszek today.", "Ask Kaelthorne Draszek today.") == ["Kaelthorne Draszek"])
    }

    @Test func thePunctuationAroundAWordIsNotPartOfIt() {
        #expect(learned("Meet Zivora.", "Meet Zivora.", "Meet Xyvora!") == ["Xyvora"])
        #expect(learned("Meet (Zivora)", "Meet (Zivora)", "Meet (Xyvora)") == ["Xyvora"])
    }

    /// The field holds other text too: an edit of the dictated part counts, one elsewhere doesn't.
    @Test func onlyAnEditWithinTheDictatedTextCounts() {
        let field = "Earlier text about Zivora.\n\(pasted)\nSigned, Zivora"
        #expect(learned("Please forward the Xyvora contract to Keelthorn Draszek before Friday.", before: field) == ["Xyvora"])
        #expect(learned(pasted, field, field.replacingOccurrences(of: "Earlier text about Zivora", with: "Earlier text about Xyvora")) == [])
        #expect(learned(pasted, field, field.replacingOccurrences(of: "Signed, Zivora", with: "Signed, Xyvora")) == [])
    }

    /// Of two copies of the dictated text, the one the edit is in.
    @Test func findsTheCopyThatWasEdited() {
        let text = "Meet Zivora."
        #expect(learned(text, "\(text) \(text)", "\(text) Meet Xyvora.") == ["Xyvora"])
    }

    @Test func anEditReachingOutsideTheDictatedTextTeachesNothing() {
        let field = "Intro. \(pasted) Outro."
        let edited = field.replacingOccurrences(of: "Intro. Please", with: "Hello. Kindly").replacingOccurrences(of: "Zivora", with: "Xyvora")
        #expect(learned(pasted, field, edited) == [])
    }

    @Test func textAddedAfterOrWordsDeletedTeachNothing() {
        #expect(learned(pasted, pasted, "\(pasted) Thanks, Xyvora") == [])
        #expect(learned("Please forward the contract to Keelthorn Draszek before Friday.") == [])
    }

    @Test func noEditOrNoDictatedTextTeachesNothing() {
        #expect(learned(pasted, pasted, pasted) == [])
        #expect(learned(pasted, "Something else entirely.", "Something else, Xyvora.") == [])
        #expect(learned("", "Meet Zivora.", "Meet Xyvora.") == [])
    }

    /// More than `correctionMaxChangedShare` of the words changed: a rewrite, not a correction.
    @Test func aRewriteTeachesNothing() {
        let text = "Zivora and Keelthorn sent Draszek notes"
        #expect(learned(text, text, "Xyvora and Kaelthorne sent Draszek notes") == ["Xyvora", "Kaelthorne"])
        #expect(learned(text, text, "Xyvora und Kaelthorne sendet Draszek notes") == [])
        #expect(DictationConfig.correctionMaxChangedShare == 0.5)
    }

    /// Past `correctionMaxEditShare` of the longer spelling, it's another word, not a respelling.
    @Test func aDifferentWordTeachesNothing() {
        #expect(learned("Meet Zivora today.", "Meet Zivora today.", "Meet Bartholomew today.") == [])
        // "Shunade" → "Sinead": 4 edits of 7, within the share.
        #expect(learned("Ask Shunade today.", "Ask Shunade today.", "Ask Sinead today.") == ["Sinead"])
        // At the share exactly, 13 edits of 20, a respelling; one more, another word.
        let (heard, at, past) = ("Abcdefghijklmnopqrst", "Àáâãäåæçèéêëìnopqrst", "Àáâãäåæçèéêëìíopqrst")
        #expect(learned("Ask \(heard) today.", "Ask \(heard) today.", "Ask \(at) today.") == [at])
        #expect(learned("Ask \(heard) today.", "Ask \(heard) today.", "Ask \(past) today.") == [])
    }

    @Test func shortAndEverydayWordsAreNotLearned() {
        #expect(learned("Ask Al today.", "Ask Al today.", "Ask Ai today.") == [])
        #expect(learned("Better then ever.", "Better then ever.", "Better than ever.") == [])
        // Capitalised, so not taken for another form of a lowercase word: only its being everyday refuses it.
        #expect(learned("Wood you send it?", "Wood you send it?", "Would you send it?") == [])
    }

    /// A capital at a word's start alone is a sentence's or a style's, not a spelling; one inside a
    /// word, or a changed spacing, is.
    /// A lowercase word changed at its end alone is another form of it, a grammar or wording fix; a
    /// capitalised name changed there, or a word in a script without case, is a respelling.
    @Test(arguments: [("report", "reports"), ("call", "called"), ("meeting", "meetings"), ("review", "revise"), ("send", "sent"), ("reports", "report"), ("file", "fire")])
    func anotherFormOfALowercaseWordIsNotLearned(heard: String, corrected: String) {
        let text = "Please \(heard) it today."
        #expect(learned(text, text, text.replacingOccurrences(of: heard, with: corrected)) == [])
    }

    @Test func aRespelledNameOrUncasedWordIsLearnedWhereverItChanged() {
        #expect(learned("Ask Steven today.", "Ask Steven today.", "Ask Stephen today.") == ["Stephen"])
        #expect(learned("Ask brevale today.", "Ask brevale today.", "Ask Brevalle today.") == ["Brevalle"])
        #expect(learned("내일 김민수 회의", "내일 김민수 회의", "내일 김민서 회의") == ["김민서"])
        // A change within the start is a respelling, lowercase or not.
        #expect(learned("run cubectl today", "run cubectl today", "run kubectl today") == ["kubectl"])
    }

    @Test func aChangeOfCaseIsLearnedOnlyInsideAWord() {
        #expect(learned("meet zivora today", "meet zivora today", "meet Zivora today") == [])
        #expect(learned("sync with tabmail", "sync with tabmail", "sync with TabMail") == ["TabMail"])
    }

    @Test func aWordTheBackendWouldRefuseIsNotLearned() {
        #expect(learned("Meet Zivora today.", "Meet Zivora today.", "Meet Xyv<ora today.") == [])
        let long = String(repeating: "x", count: DictationConfig.dictionaryWordMaxChars)
        #expect(learned("Meet X\(long)y today.", "Meet X\(long)y today.", "Meet X\(long)z today.") == [])
    }

    @Test func aRespellingOfMoreWordsThanADictionaryWordHoldsIsNotLearned() {
        let heard = "a1 b2 c3 d4 e5 f6 g7"
        let text = "\(heard) \(String(repeating: "word ", count: 20))"
        #expect(learned(text, text, text.replacingOccurrences(of: heard, with: "A1x B2x C3x D4x E5x F6x G7x")) == [])
    }

    /// Hangul and other scripts: the words are split on spaces alike.
    @Test func learnsInAnyScript() {
        #expect(learned("내일 테브메일 회의", "내일 테브메일 회의", "내일 탭메일 회의") == ["탭메일"])
    }
}
