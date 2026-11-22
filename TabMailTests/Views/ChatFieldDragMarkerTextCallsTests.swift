/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import Foundation
import Observation
import ObjectiveC
import Testing
import UIKit
@testable import TabMail

/// The swipe UI tests' records in the drag marker (debug builds only): what the text under a drag
/// is asked to do after its let-go (`ChatFieldDragMarker.TextCalls`), the field's pan record and
/// the back swipe's watch (`ChatFieldDragMarker.PopWatch`).
///
/// THE PROPERTY pinned here:
/// - every wrapped call, all six, runs the implementation the method had, once, with its own
///   selector and every argument unchanged, and returns its answer, whichever it is;
/// - a call is noted only for the watched text, once however many times the wrappers are
///   installed;
/// - a class that only inherits a method gets the wrapper as its own, for the scroll calls and the
///   text calls alike, and its superclass, its sibling classes and UIKit's own classes are left
///   untouched;
/// - a launch the swipe UI tests did not make wraps neither UIKit class;
/// - a pan or back-swipe note never updates the marker inside the call that notes it, and shows
///   after it;
/// - the back swipe's watch records only real turnings on or off, timed from its own binding,
///   ignores a stop by another owner, records nothing once stopped, and starts empty under a new
///   owner.
@MainActor
@Suite("Drag marker text calls", .serialized)
struct ChatFieldDragMarkerTextCallsTests {
    /// Has the six stand-ins as its own methods (`FixtureOriginals`), so the wrapper replaces them.
    final class ForwardingText: UITextView {}

    /// Has the six stand-ins as its own methods; the child and the sibling only inherit them.
    class ParentText: UITextView {}
    final class ChildText: ParentText {}
    final class SiblingText: ParentText {}

    private static let offsetSelector = #selector(UIScrollView.setContentOffset(_:animated:))
    private static let selectedRangeSelector = #selector(setter: UITextView.selectedRange)
    private static let frame = CGRect(x: 0, y: 0, width: 200, height: 40)
    /// How many main-actor turns a deferred showing may take.
    private static let publishTurns = 20
    /// How long, in milliseconds, a back-swipe watch's clock is left to age before it is bound.
    private static let staleClockMilliseconds = 300

    @MainActor private final class Flag { var fired = false }

    /// The names of the calls the marker's `calls=` holds, in order (`<name>@+<ms>`).
    private static func calls(in label: String) -> [String] {
        let field = label.split(separator: " ").first { $0.hasPrefix("calls=") }.map { String($0.dropFirst("calls=".count)) }
        guard let field, field != "none" else { return [] }
        return field.split(separator: ",").map { String($0.split(separator: "@").first ?? "") }
    }

    /// Whether `condition` holds within `publishTurns` main-actor turns.
    private static func published(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<publishTurns {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    /// Lets every pending showing run.
    private static func settle() async {
        for _ in 0..<publishTurns { await Task.yield() }
    }

    /// A flag that is set the moment `read`'s observed values are about to change.
    private static func watchChange(of read: () -> Void) -> Flag {
        let flag = Flag()
        withObservationTracking {
            read()
        } onChange: { @Sendable in
            // Observation calls this inside the change, on the main thread that makes it.
            MainActor.assumeIsolated { flag.fired = true }
        }
        return flag
    }

    @Test("Every wrapped call runs its original once, with its selector, arguments and answer, and is noted once, only for the watched text")
    func forwardsEveryWrappedCallAndNotesOnlyTheWatchedText() throws {
        let added = FixtureOriginals.add(to: ForwardingText.self)
        #expect(added, "control: the six stand-ins are the class's own methods")
        // Installed twice: each class is wrapped once, so each call is noted once.
        ChatFieldDragMarker.TextCalls.install(scrollView: ForwardingText.self, textView: ForwardingText.self)
        ChatFieldDragMarker.TextCalls.install(scrollView: ForwardingText.self, textView: ForwardingText.self)

        let watched = ForwardingText(frame: Self.frame)
        let control = ForwardingText(frame: Self.frame)
        watched.text = "abcdef"
        let made = watched.textRange(from: watched.beginningOfDocument, to: watched.endOfDocument)
        let range = try #require(made)
        let probe = ChatFieldDragMarker.Probe.shared
        probe.watchText(watched, lastMoved: 0)
        defer { probe.watchText(nil, lastMoved: 0) }
        FixtureOriginals.reset()

        // Called as UIKit calls them, through the Objective-C runtime.
        let scroll: UIScrollView = watched
        let text: UITextView = watched
        let responder: UIResponder = watched
        scroll.setContentOffset(CGPoint(x: 3, y: 7), animated: false)
        scroll.setContentOffset(CGPoint(x: 4, y: 8), animated: true)
        scroll.scrollRectToVisible(CGRect(x: 1, y: 2, width: 30, height: 40), animated: false)
        scroll.scrollRectToVisible(CGRect(x: 5, y: 6, width: 70, height: 80), animated: true)
        text.scrollRangeToVisible(NSRange(location: 2, length: 3))
        text.selectedTextRange = range
        text.selectedTextRange = nil
        text.selectedRange = NSRange(location: 1, length: 4)
        FixtureOriginals.answer = true
        let yes = responder.becomeFirstResponder()
        FixtureOriginals.answer = false
        let no = responder.becomeFirstResponder()
        let controlScroll: UIScrollView = control
        controlScroll.setContentOffset(CGPoint(x: 9, y: 10), animated: true)

        #expect(FixtureOriginals.asked(by: watched) == [
            "setContentOffset:animated: 3.0,7.0 false",
            "setContentOffset:animated: 4.0,8.0 true",
            "scrollRectToVisible:animated: 1.0,2.0,30.0,40.0 false",
            "scrollRectToVisible:animated: 5.0,6.0,70.0,80.0 true",
            "scrollRangeToVisible: 2,3",
            "setSelectedTextRange: range",
            "setSelectedTextRange: nil",
            "setSelectedRange: 1,4",
            "becomeFirstResponder",
            "becomeFirstResponder",
        ], "each original ran once, with its own selector and every argument")
        let passed = FixtureOriginals.textRanges
        #expect(passed.count == 2, "control: the text range setter's original ran twice")
        guard passed.count == 2 else { return }
        #expect(passed[0] === range, "the text range itself was passed on")
        #expect(passed[1] == nil, "a nil text range was passed on as nil")
        #expect(yes, "the wrapper returned the original's yes")
        #expect(!no, "the wrapper returned the original's no")
        #expect(FixtureOriginals.asked(by: control) == ["setContentOffset:animated: 9.0,10.0 true"],
                "control: the other text's original ran too")
        #expect(Self.calls(in: probe.label) == [
            "offset", "offsetAnimated", "rect", "rectAnimated", "rangeToVisible",
            "selectedTextRange", "selectedTextRange", "selectedRange", "becomeFirstResponder", "becomeFirstResponder",
        ], "only the watched text's calls are noted, each once: \(probe.label)")
    }

    @Test("A class that only inherits the wrapped methods gets the wrappers as its own; its superclass, its sibling and UIKit are untouched")
    func inheritedMethodsAreWrappedOnTheClassAlone() {
        let added = FixtureOriginals.add(to: ParentText.self)
        #expect(added, "control: the six stand-ins are the parent's own methods")
        let families = [Self.offsetSelector, Self.selectedRangeSelector]
        let baseline = families.map { class_getMethodImplementation(ParentText.self, $0) }
        let uikitBefore = [class_getMethodImplementation(UIScrollView.self, Self.offsetSelector),
                           class_getMethodImplementation(UITextView.self, Self.selectedRangeSelector)]
        let childBefore = families.map { class_getMethodImplementation(ChildText.self, $0) }
        #expect(childBefore == baseline, "control: the child inherits the parent's methods")

        ChatFieldDragMarker.TextCalls.install(scrollView: ChildText.self, textView: ChildText.self)

        let childAfter = families.map { class_getMethodImplementation(ChildText.self, $0) }
        let parentAfter = families.map { class_getMethodImplementation(ParentText.self, $0) }
        let siblingAfter = families.map { class_getMethodImplementation(SiblingText.self, $0) }
        let uikitAfter = [class_getMethodImplementation(UIScrollView.self, Self.offsetSelector),
                          class_getMethodImplementation(UITextView.self, Self.selectedRangeSelector)]
        #expect(childAfter[0] != baseline[0], "the child has the scroll call's wrapper as its own")
        #expect(childAfter[1] != baseline[1], "the child has the text call's wrapper as its own")
        #expect(parentAfter == baseline, "the parent's methods are untouched")
        #expect(siblingAfter == baseline, "the sibling still inherits the parent's methods")
        #expect(uikitAfter == uikitBefore, "UIKit's own methods are untouched")

        let probe = ChatFieldDragMarker.Probe.shared
        defer { probe.watchText(nil, lastMoved: 0) }
        let child = ChildText(frame: Self.frame)
        let sibling = SiblingText(frame: Self.frame)
        FixtureOriginals.reset()
        probe.watchText(child, lastMoved: 0)
        let childScroll: UIScrollView = child
        let childText: UITextView = child
        childScroll.setContentOffset(CGPoint(x: 2, y: 5), animated: false)
        childText.selectedRange = NSRange(location: 1, length: 2)
        #expect(FixtureOriginals.asked(by: child) == ["setContentOffset:animated: 2.0,5.0 false", "setSelectedRange: 1,2"],
                "the inherited originals ran once, with their arguments")
        #expect(Self.calls(in: probe.label) == ["offset", "selectedRange"], "the child's calls are noted: \(probe.label)")

        probe.watchText(sibling, lastMoved: 0)
        let siblingScroll: UIScrollView = sibling
        let siblingText: UITextView = sibling
        siblingScroll.setContentOffset(CGPoint(x: 6, y: 7), animated: true)
        siblingText.selectedRange = NSRange(location: 3, length: 1)
        #expect(FixtureOriginals.asked(by: sibling) == ["setContentOffset:animated: 6.0,7.0 true", "setSelectedRange: 3,1"],
                "control: the sibling's originals ran")
        #expect(Self.calls(in: probe.label).isEmpty, "the sibling is not wrapped, so nothing is noted: \(probe.label)")
    }

    @Test("A launch the swipe UI tests did not make wraps neither UIKit class at a let-go")
    func anInactiveLaunchWrapsNothing() {
        #expect(!ChatFieldDragMarker.Probe.isActive, "control: the unit test host is not the swipe UI tests' launch")
        let before = [class_getMethodImplementation(UIScrollView.self, Self.offsetSelector),
                      class_getMethodImplementation(UITextView.self, Self.selectedRangeSelector)]
        ChatFieldDragMarker.textLetGo(UITextView(frame: Self.frame), lastMoved: 0)
        let after = [class_getMethodImplementation(UIScrollView.self, Self.offsetSelector),
                     class_getMethodImplementation(UITextView.self, Self.selectedRangeSelector)]
        #expect(after[0] == before[0], "the scroll calls are not wrapped")
        #expect(after[1] == before[1], "the text calls are not wrapped")
    }

    @Test("A pan note shows after the call that notes it, never inside it")
    func panNotesShowAfterTheirCall() async {
        let probe = ChatFieldDragMarker.Probe()
        let changed = Self.watchChange { _ = probe.panEvents }
        probe.notePan("off:began")
        probe.notePan("cancelled")
        #expect(!changed.fired, "the marker is not updated inside the notes' own call")
        #expect(probe.panEvents.isEmpty, "nothing shows inside the notes' own call")
        let shown = await Self.published { probe.panEvents == ["off:began", "cancelled"] }
        #expect(shown, "the notes show, in order, after the call: \(probe.panEvents)")
        #expect(changed.fired, "control: the marker is updated once they show")
    }

    @Test("The back swipe's watch records real turnings on or off from its binding, until its own owner stops it")
    func backSwipeWatchRecordsUntilItsOwnerStops() async throws {
        let probe = ChatFieldDragMarker.Probe.shared
        let watch = ChatFieldDragMarker.PopWatch()
        let swipe = UIPanGestureRecognizer()
        let ownerA = NSObject()
        let ownerB = NSObject()
        // The watch's clock ages before it is bound: a binding restarts it.
        try await Task.sleep(for: .milliseconds(Self.staleClockMilliseconds))
        watch.watch(swipe, for: ObjectIdentifier(ownerA))
        defer { watch.stop(for: ObjectIdentifier(ownerB)) }

        let changed = Self.watchChange { _ = probe.popEntries }
        swipe.isEnabled = false
        #expect(!changed.fired, "the marker is not updated inside the turning off")
        let off = await Self.published { probe.popEntries.count == 1 }
        #expect(off, "the turning off shows after it: \(probe.popEntries)")
        let first = probe.popEntries
        guard first.count == 1 else { return }
        let parts = first[0].split(separator: "@")
        #expect(parts.first == "en:0", "the turning off is recorded: \(first[0])")
        guard parts.count > 1 else { return }
        let elapsed = Double(parts[1].dropFirst().dropLast("ms".count))
        let limit = Double(Self.staleClockMilliseconds)
        #expect(elapsed.map { $0 < limit } == true, "timed from the binding, not the watch's older clock: \(first[0])")

        swipe.isEnabled = false
        await Self.settle()
        #expect(probe.popEntries.count == 1, "setting the value it has records nothing: \(probe.popEntries)")

        watch.stop(for: ObjectIdentifier(ownerB))
        swipe.isEnabled = true
        let on = await Self.published { probe.popEntries.count == 2 }
        #expect(on, "another owner's stop leaves the watch on: \(probe.popEntries)")
        #expect(probe.popEntries.last?.hasPrefix("en:1@") == true, "the turning on is recorded: \(probe.popEntries)")

        watch.stop(for: ObjectIdentifier(ownerA))
        let cleared = await Self.published { probe.popEntries.isEmpty }
        #expect(cleared, "its own owner's stop clears the record: \(probe.popEntries)")
        swipe.isEnabled = false
        await Self.settle()
        #expect(probe.popEntries.isEmpty, "a stopped watch records nothing: \(probe.popEntries)")

        watch.watch(swipe, for: ObjectIdentifier(ownerB))
        await Self.settle()
        #expect(probe.popEntries.isEmpty, "a new owner's watch starts empty: \(probe.popEntries)")
        swipe.isEnabled = true
        let rebound = await Self.published { probe.popEntries.count == 1 }
        #expect(rebound, "the new owner's watch records: \(probe.popEntries)")
        #expect(probe.popEntries.first?.hasPrefix("en:1@") == true, "the turning on is recorded: \(probe.popEntries)")
    }
}

/// Stand-ins for the wrapped methods' own implementations, added to a test's own text view class
/// as plain C functions: each records the receiver, the selector it was called with and every
/// argument, and touches nothing else, so a record is exactly what the wrapper passed on.
private enum FixtureOriginals {
    nonisolated(unsafe) static var records: [(receiver: ObjectIdentifier, call: String)] = []
    nonisolated(unsafe) static var textRanges: [UITextRange?] = []
    /// What the responder stand-in answers.
    nonisolated(unsafe) static var answer = true

    static func reset() {
        records = []
        textRanges = []
        answer = true
    }

    static func asked(by receiver: AnyObject) -> [String] {
        records.filter { $0.receiver == ObjectIdentifier(receiver) }.map(\.call)
    }

    static func record(_ receiver: AnyObject, _ selector: Selector, _ arguments: String) {
        let call = NSStringFromSelector(selector) + (arguments.isEmpty ? "" : " " + arguments)
        records.append((ObjectIdentifier(receiver), call))
    }

    /// Adds the six stand-ins to `cls` as its own methods, each with UIKit's type encoding;
    /// whether all six were added.
    static func add(to cls: AnyClass) -> Bool {
        let pointAndFlag: @convention(c) (AnyObject, Selector, CGPoint, ObjCBool) -> Void = { receiver, selector, point, animated in
            FixtureOriginals.record(receiver, selector, "\(point.x),\(point.y) \(animated.boolValue)")
        }
        let rectAndFlag: @convention(c) (AnyObject, Selector, CGRect, ObjCBool) -> Void = { receiver, selector, rect, animated in
            FixtureOriginals.record(receiver, selector, "\(rect.minX),\(rect.minY),\(rect.width),\(rect.height) \(animated.boolValue)")
        }
        let range: @convention(c) (AnyObject, Selector, NSRange) -> Void = { receiver, selector, value in
            FixtureOriginals.record(receiver, selector, "\(value.location),\(value.length)")
        }
        let textRange: @convention(c) (AnyObject, Selector, UITextRange?) -> Void = { receiver, selector, value in
            FixtureOriginals.textRanges.append(value)
            FixtureOriginals.record(receiver, selector, value == nil ? "nil" : "range")
        }
        let answer: @convention(c) (AnyObject, Selector) -> ObjCBool = { receiver, selector in
            FixtureOriginals.record(receiver, selector, "")
            return ObjCBool(FixtureOriginals.answer)
        }
        let standIns: [(Selector, AnyClass, IMP)] = [
            (#selector(UIScrollView.setContentOffset(_:animated:)), UIScrollView.self, unsafeBitCast(pointAndFlag, to: IMP.self)),
            (#selector(UIScrollView.scrollRectToVisible(_:animated:)), UIScrollView.self, unsafeBitCast(rectAndFlag, to: IMP.self)),
            (#selector(UITextView.scrollRangeToVisible(_:)), UITextView.self, unsafeBitCast(range, to: IMP.self)),
            (#selector(setter: UITextView.selectedTextRange), UITextView.self, unsafeBitCast(textRange, to: IMP.self)),
            (#selector(setter: UITextView.selectedRange), UITextView.self, unsafeBitCast(range, to: IMP.self)),
            (#selector(UITextView.becomeFirstResponder), UITextView.self, unsafeBitCast(answer, to: IMP.self)),
        ]
        let added = standIns.map { selector, source, imp -> Bool in
            guard let method = class_getInstanceMethod(source, selector) else { return false }
            return class_addMethod(cls, selector, imp, method_getTypeEncoding(method))
        }
        return added.allSatisfy { $0 }
    }
}
#endif
