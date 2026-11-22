/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import Foundation
import Observation
import ObjectiveC
import Synchronization
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
/// - one installation wraps the scroll calls on its scroll class and the text calls on its text
///   class; a class that only inherits a method gets the wrapper as its own, and its superclass, its
///   sibling classes and UIKit's own classes are left untouched;
/// - a launch the swipe UI tests did not make wraps neither of UIKit's classes, at a let-go or
///   when a text is watched;
/// - a pan or back-swipe note never updates the marker inside the call that notes it, and shows
///   after it;
/// - the reply field's build counts belong to their own drag: the finger-down count shows from that
///   drag's let-go, a new drag's shows as pending until its own let-go;
/// - the back swipe's watch records only real turnings on or off, each binding timed from that
///   binding and starting empty, ignores a stop by an owner it no longer has, and records nothing
///   once its own owner stops it.
@MainActor
@Suite("Drag marker text calls", .serialized)
struct ChatFieldDragMarkerTextCallsTests {
    /// Has the six stand-ins as its own methods (`FixtureOriginals`), so the wrapper replaces them.
    final class ForwardingText: UITextView {}

    /// Has the six stand-ins as its own methods; its subclasses only inherit them. One installation
    /// takes the scroll class and the text class.
    class ParentText: UITextView {}
    final class ScrollChild: ParentText {}
    final class TextChild: ParentText {}
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

    /// The marker's `builds=<down>:<after>` value.
    private static func builds(in label: String) -> String? {
        label.split(separator: " ").first { $0.hasPrefix("builds=") }.map { String($0.dropFirst("builds=".count)) }
    }

    /// The milliseconds a back-swipe entry (`<name>@+<ms>ms…`) is timed at; nil when it has none.
    private static func elapsed(of entry: String) -> Double? {
        let parts = entry.split(separator: "@")
        guard parts.count > 1, parts[1].hasPrefix("+"), parts[1].hasSuffix("ms") else { return nil }
        return Double(parts[1].dropFirst().dropLast("ms".count))
    }

    /// Whether `cls`'s `selector` runs a wrapper: an implementation made from a block
    /// (`imp_implementationWithBlock`), as every `TextCalls` wrapper is and no class's own code is.
    private static func isWrapped(_ cls: AnyClass, _ selector: Selector) -> Bool {
        guard let imp = class_getMethodImplementation(cls, selector) else { return false }
        return imp_getBlock(imp) != nil
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
        let wrappedBefore = Self.isWrapped(ForwardingText.self, Self.offsetSelector)
        #expect(!wrappedBefore, "control: before the wrap, the class runs its own stand-in")
        // Installed twice: each class is wrapped once, so each call is noted once.
        ChatFieldDragMarker.TextCalls.install(scrollView: ForwardingText.self, textView: ForwardingText.self)
        ChatFieldDragMarker.TextCalls.install(scrollView: ForwardingText.self, textView: ForwardingText.self)
        let wrappedAfter = Self.isWrapped(ForwardingText.self, Self.offsetSelector)
        #expect(wrappedAfter, "control: a wrapper is told apart from the class's own code")

        let watched = ForwardingText(frame: Self.frame)
        let control = ForwardingText(frame: Self.frame)
        watched.text = "abcdef"
        let made = watched.textRange(from: watched.beginningOfDocument, to: watched.endOfDocument)
        let range = try #require(made)
        let probe = ChatFieldDragMarker.Probe.shared
        probe.watchText(watched, lastMoved: 0)
        defer { probe.watchText(nil, lastMoved: 0) }
        FixtureOriginals.reset()

        // The other text first, while the watch is open and nothing is noted yet.
        let controlScroll: UIScrollView = control
        controlScroll.setContentOffset(CGPoint(x: 9, y: 10), animated: true)
        #expect(FixtureOriginals.asked(by: control) == ["setContentOffset:animated: 9.0,10.0 true"],
                "control: the other text's original ran")
        #expect(Self.calls(in: probe.label).isEmpty, "the other text's call is not noted: \(probe.label)")

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
        FixtureOriginals.setAnswer(true)
        let yes = responder.becomeFirstResponder()
        FixtureOriginals.setAnswer(false)
        let no = responder.becomeFirstResponder()

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
        let rangeIdentity = ObjectIdentifier(range)
        #expect(passed[0] == rangeIdentity, "the text range itself was passed on")
        #expect(passed[1] == nil, "a nil text range was passed on as nil")
        #expect(yes, "the wrapper returned the original's yes")
        #expect(!no, "the wrapper returned the original's no")
        #expect(Self.calls(in: probe.label) == [
            "offset", "offsetAnimated", "rect", "rectAnimated", "rangeToVisible",
            "selectedTextRange", "selectedTextRange", "selectedRange", "becomeFirstResponder", "becomeFirstResponder",
        ], "only the watched text's calls are noted, each once: \(probe.label)")
    }

    @Test("One installation wraps the scroll calls on its scroll class and the text calls on its text class, each as the class's own; no other class changes")
    func eachFamilyIsWrappedOnItsOwnClassAlone() {
        let added = FixtureOriginals.add(to: ParentText.self)
        #expect(added, "control: the six stand-ins are the parent's own methods")
        let families = [Self.offsetSelector, Self.selectedRangeSelector]
        let children: [AnyClass] = [ScrollChild.self, TextChild.self, SiblingText.self]
        let baseline = families.map { class_getMethodImplementation(ParentText.self, $0) }
        let uikitBefore = [class_getMethodImplementation(UIScrollView.self, Self.offsetSelector),
                           class_getMethodImplementation(UITextView.self, Self.selectedRangeSelector)]
        let childrenBefore = children.map { child in families.map { class_getMethodImplementation(child, $0) } }
        let allInherit = childrenBefore.allSatisfy { $0 == baseline }
        #expect(allInherit, "control: every child inherits the parent's methods")

        ChatFieldDragMarker.TextCalls.install(scrollView: ScrollChild.self, textView: TextChild.self)

        let scrollChild = families.map { class_getMethodImplementation(ScrollChild.self, $0) }
        let textChild = families.map { class_getMethodImplementation(TextChild.self, $0) }
        let parentAfter = families.map { class_getMethodImplementation(ParentText.self, $0) }
        let siblingAfter = families.map { class_getMethodImplementation(SiblingText.self, $0) }
        let uikitAfter = [class_getMethodImplementation(UIScrollView.self, Self.offsetSelector),
                          class_getMethodImplementation(UITextView.self, Self.selectedRangeSelector)]
        #expect(scrollChild[0] != baseline[0], "the scroll class has the scroll call's wrapper as its own")
        #expect(scrollChild[1] == baseline[1], "the scroll class's text calls are not wrapped")
        #expect(textChild[1] != baseline[1], "the text class has the text call's wrapper as its own")
        #expect(textChild[0] == baseline[0], "the text class's scroll calls are not wrapped")
        #expect(parentAfter == baseline, "the parent's methods are untouched")
        #expect(siblingAfter == baseline, "the sibling still inherits the parent's methods")
        #expect(uikitAfter == uikitBefore, "UIKit's own methods are untouched")

        // Made before the record is reset, so nothing their setup asks for is counted.
        let cases: [(text: ParentText, noted: [String], what: String)] = [
            (ScrollChild(frame: Self.frame), ["offset"], "the scroll class notes its scroll call alone"),
            (TextChild(frame: Self.frame), ["selectedRange"], "the text class notes its text call alone"),
            (SiblingText(frame: Self.frame), [], "the sibling is not wrapped, so nothing is noted"),
        ]
        let probe = ChatFieldDragMarker.Probe.shared
        defer { probe.watchText(nil, lastMoved: 0) }
        FixtureOriginals.reset()
        for (text, noted, what) in cases {
            probe.watchText(text, lastMoved: 0)
            let scroll: UIScrollView = text
            let textView: UITextView = text
            scroll.setContentOffset(CGPoint(x: 2, y: 5), animated: false)
            textView.selectedRange = NSRange(location: 1, length: 2)
            #expect(FixtureOriginals.asked(by: text) == ["setContentOffset:animated: 2.0,5.0 false", "setSelectedRange: 1,2"],
                    "control: both originals ran once, with their arguments (\(what))")
            #expect(Self.calls(in: probe.label) == noted, "\(what): \(probe.label)")
        }
    }

    @Test("A launch the swipe UI tests did not make wraps neither UIKit class, at a let-go or when a text is watched")
    func anInactiveLaunchWrapsNothing() {
        #expect(!ChatFieldDragMarker.Probe.isActive, "control: the unit test host is not the swipe UI tests' launch")
        let text = UITextView(frame: Self.frame)
        ChatFieldDragMarker.textLetGo(text, lastMoved: 0)
        let probe = ChatFieldDragMarker.Probe.shared
        probe.watchText(text, lastMoved: 0)
        defer { probe.watchText(nil, lastMoved: 0) }
        let scrollWrapped = Self.isWrapped(UIScrollView.self, Self.offsetSelector)
        let textWrapped = Self.isWrapped(UITextView.self, Self.selectedRangeSelector)
        #expect(!scrollWrapped, "the scroll calls are not wrapped")
        #expect(!textWrapped, "the text calls are not wrapped")
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

    @Test("The reply field's builds count for their own drag: while the finger is down, from its let-go, and never the last drag's")
    func buildCountsBelongToTheirDrag() {
        let probe = ChatFieldDragMarker.Probe()
        let before = Self.builds(in: probe.label)
        #expect(before == "pending:0", "control: no drag yet: \(probe.label)")
        probe.textTouchDown(end: nil, handedOff: false)
        probe.dragChanged(true)
        probe.inputFieldBuilt()
        probe.inputFieldBuilt()
        let held = Self.builds(in: probe.label)
        #expect(held == "pending:0", "the finger is still down: its count is not shown yet")
        probe.watchText(UITextView(frame: Self.frame), lastMoved: 0)
        probe.inputFieldBuilt()
        let afterLetGo = Self.builds(in: probe.label)
        #expect(afterLetGo == "2:1", "two builds while the finger was down, one after its let-go")
        probe.dragChanged(false)
        probe.textTouchDown(end: nil, handedOff: false)
        probe.dragChanged(true)
        let next = Self.builds(in: probe.label)
        #expect(next == "pending:0", "a new drag never shows the last one's counts")
        probe.watchText(nil, lastMoved: 0)
        let nextLetGo = Self.builds(in: probe.label)
        #expect(nextLetGo == "0:0", "the new drag's own count, from its first touch")
    }

    @Test("The back swipe's watch records real turnings on or off, each binding timed from itself, until its own owner stops it")
    func backSwipeWatchRecordsUntilItsOwnerStops() async throws {
        let probe = ChatFieldDragMarker.Probe.shared
        let watch = ChatFieldDragMarker.PopWatch()
        let swipe = UIPanGestureRecognizer()
        let ownerA = NSObject()
        let ownerB = NSObject()
        let limit = Double(Self.staleClockMilliseconds)
        defer { watch.stop(for: ObjectIdentifier(ownerB)) }

        // The watch's clock ages before it is bound: the binding restarts it.
        try await Task.sleep(for: .milliseconds(Self.staleClockMilliseconds))
        watch.watch(swipe, for: ObjectIdentifier(ownerA))
        await Self.settle()
        let changed = Self.watchChange { _ = probe.popEntries }
        swipe.isEnabled = false
        #expect(!changed.fired, "the marker is not updated inside the turning off")
        let off = await Self.published { probe.popEntries.count == 1 }
        #expect(off, "the turning off shows after it: \(probe.popEntries)")
        #expect(changed.fired, "control: the marker is updated once it shows")
        let first = probe.popEntries
        guard first.count == 1 else { return }
        #expect(first[0].hasPrefix("en:0@"), "the turning off is recorded: \(first[0])")
        let firstTime = Self.elapsed(of: first[0])
        let firstMs = try #require(firstTime, "the turning off is timed: \(first[0])")
        let firstFresh = firstMs >= 0 && firstMs < limit
        #expect(firstFresh, "timed from the binding, not the watch's older clock: \(first[0])")

        swipe.isEnabled = false
        await Self.settle()
        #expect(probe.popEntries.count == 1, "setting the value it has records nothing: \(probe.popEntries)")

        // A new owner takes the same swipe over, after the first binding's clock has aged.
        try await Task.sleep(for: .milliseconds(Self.staleClockMilliseconds))
        watch.watch(swipe, for: ObjectIdentifier(ownerB))
        await Self.settle()
        #expect(probe.popEntries.isEmpty, "the new owner's watch starts empty: \(probe.popEntries)")
        swipe.isEnabled = true
        let on = await Self.published { probe.popEntries.count == 1 }
        #expect(on, "the new owner's watch records: \(probe.popEntries)")
        let second = probe.popEntries
        guard second.count == 1 else { return }
        #expect(second[0].hasPrefix("en:1@"), "the turning on is recorded: \(second[0])")
        let secondTime = Self.elapsed(of: second[0])
        let secondMs = try #require(secondTime, "the turning on is timed: \(second[0])")
        let secondFresh = secondMs >= 0 && secondMs < limit
        #expect(secondFresh, "timed from the new binding, not the one it replaced: \(second[0])")

        watch.stop(for: ObjectIdentifier(ownerA))
        swipe.isEnabled = false
        let kept = await Self.published { probe.popEntries.count == 2 }
        #expect(kept, "a stop by the owner it no longer has leaves the watch on: \(probe.popEntries)")
        #expect(probe.popEntries.last?.hasPrefix("en:0@") == true, "the turning off is recorded: \(probe.popEntries)")

        watch.stop(for: ObjectIdentifier(ownerB))
        let cleared = await Self.published { probe.popEntries.isEmpty }
        #expect(cleared, "its own owner's stop clears the record: \(probe.popEntries)")
        swipe.isEnabled = true
        await Self.settle()
        #expect(probe.popEntries.isEmpty, "a stopped watch records nothing: \(probe.popEntries)")
    }
}

/// Stand-ins for the wrapped methods' own implementations, added to a test's own text view class
/// as plain C functions: each records the receiver, the selector it was called with and every
/// argument, and touches nothing else, so a record is exactly what the wrapper passed on.
private enum FixtureOriginals {
    struct State {
        var records: [(receiver: ObjectIdentifier, call: String)] = []
        /// The text ranges the text range setter's stand-in was given, by identity; nil for none.
        var textRanges: [ObjectIdentifier?] = []
        /// What the responder stand-in answers.
        var answer = true
    }

    /// Written by the stand-ins, which the Objective-C runtime calls, and read by the tests: one lock.
    static let state = Mutex(State())

    static func reset() {
        state.withLock { $0 = State() }
    }

    static func setAnswer(_ answer: Bool) {
        state.withLock { $0.answer = answer }
    }

    static var textRanges: [ObjectIdentifier?] {
        state.withLock { $0.textRanges }
    }

    static func asked(by receiver: AnyObject) -> [String] {
        let identity = ObjectIdentifier(receiver)
        return state.withLock { $0.records.filter { $0.receiver == identity }.map(\.call) }
    }

    static func record(_ receiver: AnyObject, _ selector: Selector, _ arguments: String) {
        let identity = ObjectIdentifier(receiver)
        let call = NSStringFromSelector(selector) + (arguments.isEmpty ? "" : " " + arguments)
        state.withLock { $0.records.append((identity, call)) }
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
            let identity = value.map { ObjectIdentifier($0) }
            FixtureOriginals.state.withLock { $0.textRanges.append(identity) }
            FixtureOriginals.record(receiver, selector, value == nil ? "nil" : "range")
        }
        let answer: @convention(c) (AnyObject, Selector) -> ObjCBool = { receiver, selector in
            FixtureOriginals.record(receiver, selector, "")
            return ObjCBool(FixtureOriginals.state.withLock { $0.answer })
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
