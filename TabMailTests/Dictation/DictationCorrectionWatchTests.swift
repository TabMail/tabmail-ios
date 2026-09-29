/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Learns the user's corrections of a dictation in the chat pill's input field: the one it settles
/// on, or the input sent, when the watch ends (ADR-IOS-086). The polls are driven by hand: the watch's own
/// interval is an hour, except where the timing itself is tested.
@MainActor
struct DictationCorrectionWatchTests {
    private let pasted = "Please forward the Zivora contract today."
    private let corrected = "Please forward the Xyvora contract today."

    @MainActor
    private final class Field {
        var text: String
        var reads = 0
        init(_ text: String) { self.text = text }
    }

    @MainActor
    private final class Learned {
        var words: [[String]] = []
    }

    private func setup(_ initial: String? = nil, interval: Duration = .seconds(3600), duration: Duration = .seconds(7200))
        -> (Field, Learned, DictationCorrectionWatch, @MainActor () -> String)
    {
        let field = Field(initial ?? pasted)
        let learned = Learned()
        let watch = DictationCorrectionWatch(learn: { learned.words.append($0) }, interval: interval, duration: duration)
        let read: @MainActor () -> String = {
            field.reads += 1
            return field.text
        }
        return (field, learned, watch, read)
    }

    /// A correction that has stayed for an interval is learned once the watch ends (here, the next
    /// dictation or the pill going away), and only once.
    @Test func learnsACorrectionThatStayedWhenTheWatchEnds() {
        let (field, learned, watch, read) = setup()
        watch.watch(pasted: pasted, field: read)
        field.text = corrected
        watch.poll()
        watch.poll()
        watch.poll()
        #expect(learned.words.isEmpty)
        watch.stop()
        #expect(learned.words == [["Xyvora"]])
        watch.stop()
        #expect(learned.words == [["Xyvora"]])
    }

    /// A pause in the middle of an edit settles the field too; only the edit it ends on is learned,
    /// never a spelling on the way to it, and an edit undone teaches nothing.
    @Test(arguments: [
        ("Sync the tab mail inbox.", ["Sync the tabmail inbox."], "Sync the TabMail inbox.", ["TabMail"]),
        ("Please forward the Zivora contract today.", ["Please forward the Xyvor contract today."], "Please forward the Xyvora contract today.", ["Xyvora"]),
        ("Please forward the Zivora contract today.", ["Please forward the Ziv contract today."], "Please forward the Xyvora contract today.", ["Xyvora"]),
        ("Please forward the Zivora contract today.", ["Please forward the Xyvora contract today."], "Please forward the Zivora contract today.", []),
    ])
    func onlyTheEditTheFieldEndsOnIsLearned(text: String, steps: [String], final: String, words: [String]) {
        let (field, learned, watch, read) = setup(text)
        watch.watch(pasted: text, field: read)
        for step in steps + [final] {
            field.text = step
            watch.poll()
            watch.poll()
        }
        watch.stop()
        #expect(learned.words == (words.isEmpty ? [] : [words]))
    }

    /// A correction kept is learned though the field is then cleared or shows other text, read or
    /// sent; undone, with words added after it, it teaches nothing.
    @Test(arguments: [
        ("", false, ["Xyvora"]),
        ("Something else entirely.", false, ["Xyvora"]),
        ("Something else entirely.", true, ["Xyvora"]),
        ("Please forward the Zivora contract today. Thanks!", false, []),
        ("Please forward the Zivora contract today. Thanks!", true, []),
    ])
    func aCorrectionKeptIsLearnedThoughTheFieldMovesOn(after: String, sent: Bool, words: [String]) {
        let (field, learned, watch, read) = setup()
        watch.watch(pasted: pasted, field: read)
        field.text = corrected
        watch.poll()
        watch.poll()
        if sent {
            watch.finish(field: after)
        } else {
            field.text = after
            watch.poll()
            watch.poll()
            watch.stop()
        }
        #expect(learned.words == (words.isEmpty ? [] : [words]))
    }

    /// A spelling paused on, then changed or undone and cleared or sent before that change stayed,
    /// teaches nothing: only a spelling the field held at the end of the edit is learned.
    @Test(arguments: [
        ("Please forward the Xyvor contract today.", "Please forward the Xyvora contract today."),
        ("Please forward the Xyvora contract today.", "Please forward the Zivora contract today."),
    ])
    func aSpellingPausedOnThenChangedAtOnceTeachesNothing(paused: String, last: String) {
        let (field, learned, watch, read) = setup()
        watch.watch(pasted: pasted, field: read)
        field.text = paused
        watch.poll()
        watch.poll()
        field.text = last
        watch.poll()
        field.text = ""
        watch.poll()
        watch.poll()
        watch.stop()
        #expect(learned.words.isEmpty)
    }

    /// Text typed after a correction, read before it stays, keeps the correction.
    @Test func aCorrectionThenWordsAddedAndClearedAtOnceIsLearned() {
        let (field, learned, watch, read) = setup()
        watch.watch(pasted: pasted, field: read)
        field.text = corrected
        watch.poll()
        watch.poll()
        field.text = "\(corrected) Thanks"
        watch.poll()
        field.text = ""
        watch.poll()
        watch.poll()
        watch.stop()
        #expect(learned.words == [["Xyvora"]])
    }

    /// While the user is still typing the field changes at every read: nothing is compared until it
    /// holds still.
    @Test func aFieldStillChangingIsNotCompared() {
        let (field, learned, watch, read) = setup()
        watch.watch(pasted: pasted, field: read)
        for partial in ["Please forward the X contract today.", "Please forward the Xy contract today.", "Please forward the Xyv contract today."] {
            field.text = partial
            watch.poll()
        }
        #expect(learned.words.isEmpty)
        field.text = corrected
        watch.poll()
        watch.poll()
        watch.stop()
        #expect(learned.words == [["Xyvora"]])
    }

    /// The input sent is compared at once, though the edit had no time to stay; then the watch ends.
    @Test func theInputSentIsCompared() {
        let (_, learned, watch, read) = setup()
        watch.watch(pasted: pasted, field: read)
        watch.finish(field: corrected)
        #expect(learned.words == [["Xyvora"]])
        #expect(!watch.isWatching)
    }

    /// The input sent is what is learned, not the edit settled before it.
    @Test func theInputSentReplacesTheEditSettledBeforeIt() {
        let (field, learned, watch, read) = setup()
        watch.watch(pasted: pasted, field: read)
        field.text = "Please forward the Xyvor contract today."
        watch.poll()
        watch.poll()
        watch.finish(field: corrected)
        #expect(learned.words == [["Xyvora"]])
    }

    @Test func anEditThatRespellsNothingTeachesNothing() {
        let (field, learned, watch, read) = setup()
        watch.watch(pasted: pasted, field: read)
        field.text = "\(pasted) Thanks!"
        watch.poll()
        watch.poll()
        watch.finish(field: field.text)
        #expect(learned.words.isEmpty)
    }

    /// A field that doesn't hold the dictation (sent already, or cleared) isn't watched.
    @Test func aFieldWithoutTheDictationIsNotWatched() {
        let (field, learned, watch, read) = setup("")
        watch.watch(pasted: pasted, field: read)
        #expect(!watch.isWatching)
        field.text = corrected
        watch.poll()
        watch.poll()
        watch.finish(field: corrected)
        #expect(learned.words.isEmpty)
    }

    /// `stop` (the next dictation, the pill going away) ends the watch: nothing after it is learned.
    @Test func stopEndsTheWatch() {
        let (field, learned, watch, read) = setup()
        watch.watch(pasted: pasted, field: read)
        watch.stop()
        field.text = corrected
        watch.poll()
        watch.poll()
        watch.finish(field: corrected)
        #expect(learned.words.isEmpty)
    }

    /// A new watch replaces the last, learning what the last settled on; its own dictation is the
    /// one compared after.
    @Test func aNewWatchEndsTheLast() {
        let (field, learned, watch, read) = setup()
        watch.watch(pasted: pasted, field: read)
        field.text = corrected
        watch.poll()
        watch.poll()
        field.text = "Meet Brevale."
        watch.watch(pasted: "Meet Brevale.", field: read)
        #expect(learned.words == [["Xyvora"]])
        field.text = "Meet Brevalle."
        watch.finish(field: field.text)
        #expect(learned.words == [["Xyvora"], ["Brevalle"]])
    }

    /// The watch reads the field every `interval` and stops after `duration`; a correction after
    /// it is not learned.
    @Test func readsEveryIntervalAndStopsAfterItsDuration() async {
        let (field, learned, watch, read) = setup(interval: .milliseconds(10), duration: .milliseconds(50))
        watch.watch(pasted: pasted, field: read)
        let deadline = ContinuousClock.now + .seconds(10)
        while watch.isWatching, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }

        #expect(!watch.isWatching)
        // One read at the start, then one per interval.
        #expect(field.reads == 1 + 5)
        field.text = corrected
        watch.finish(field: corrected)
        #expect(learned.words.isEmpty)
    }

    /// An edit that stays is compared through the watch's own reads and learned when its duration
    /// ends.
    @Test func learnsThroughItsOwnReadsWhenItsDurationEnds() async {
        let (field, learned, watch, read) = setup(interval: .milliseconds(10), duration: .milliseconds(100))
        watch.watch(pasted: pasted, field: read)
        field.text = corrected
        let deadline = ContinuousClock.now + .seconds(10)
        while watch.isWatching, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }

        #expect(!watch.isWatching)
        #expect(learned.words == [["Xyvora"]])
    }
}
