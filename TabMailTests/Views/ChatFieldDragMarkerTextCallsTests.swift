/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import Foundation
import ObjectiveC
import Testing
import UIKit
@testable import TabMail

/// The swipe UI tests' record of what the text under a drag is asked to do after its let-go
/// (`ChatFieldDragMarker.TextCalls`, debug builds only).
///
/// THE PROPERTY pinned here: a wrapped call is noted only for the watched text, once however many
/// let-gos install the wrappers; every wrapped call still runs the method's own implementation
/// once, with its arguments, and returns its answer; a class that only inherits a method gets the
/// wrapper as its own, so its superclass is untouched; and a launch the swipe UI tests did not make
/// wraps nothing.
@MainActor
@Suite("Drag marker text calls")
struct ChatFieldDragMarkerTextCallsTests {
    /// Its own implementation of the wrapped methods it is asked, each recording what it was asked
    /// and touching nothing else, so the record is the original's exact arguments.
    final class RecordingText: UITextView {
        var asked: [String] = []

        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            asked.append("offset \(contentOffset.y) \(animated)")
        }

        override var selectedRange: NSRange {
            get { NSRange(location: 0, length: 0) }
            set { asked.append("selectedRange \(newValue.location)") }
        }

        override func becomeFirstResponder() -> Bool {
            asked.append("becomeFirstResponder")
            return true
        }
    }

    /// Only inherits every wrapped method.
    final class InheritingText: UITextView {}

    private static let offsetSelector = #selector(UIScrollView.setContentOffset(_:animated:))
    private static let selectedRangeSelector = #selector(setter: UITextView.selectedRange)
    private static let frame = CGRect(x: 0, y: 0, width: 200, height: 40)

    /// The names of the calls the marker's `calls=` holds, in order (`<name>@+<ms>`).
    private static func calls(in label: String) -> [String] {
        let field = label.split(separator: " ").first { $0.hasPrefix("calls=") }.map { String($0.dropFirst("calls=".count)) }
        guard let field, field != "none" else { return [] }
        return field.split(separator: ",").map { String($0.split(separator: "@").first ?? "") }
    }

    @Test("A wrapped call is noted once, only for the watched text, and runs its original once with its arguments and answer")
    func notesOnlyTheWatchedTextAndRunsTheOriginal() {
        let watched = RecordingText(frame: Self.frame)
        let control = RecordingText(frame: Self.frame)
        let probe = ChatFieldDragMarker.Probe.shared

        // A launch the swipe UI tests did not make: the let-go wraps nothing.
        #expect(!ChatFieldDragMarker.Probe.isActive, "control: the unit test host is not the swipe UI tests' launch")
        let untouched = class_getMethodImplementation(UIScrollView.self, Self.offsetSelector)
        ChatFieldDragMarker.textLetGo(watched, lastMoved: 0)
        #expect(class_getMethodImplementation(UIScrollView.self, Self.offsetSelector) == untouched,
                "a launch the swipe UI tests did not make wraps nothing")

        // Two let-gos over the same text, and the test's own class installed twice: each class is
        // wrapped once, so each call is noted once.
        probe.watchText(watched, lastMoved: 0)
        probe.watchText(watched, lastMoved: 0)
        ChatFieldDragMarker.TextCalls.install(scrollView: RecordingText.self, textView: RecordingText.self)
        ChatFieldDragMarker.TextCalls.install(scrollView: RecordingText.self, textView: RecordingText.self)
        watched.asked = []
        control.asked = []

        // Called as UIKit calls them, through the Objective-C runtime.
        let watchedScroll: UIScrollView = watched
        let controlScroll: UIScrollView = control
        let watchedText: UITextView = watched
        let watchedResponder: UIResponder = watched
        watchedScroll.setContentOffset(CGPoint(x: 0, y: 7), animated: false)
        controlScroll.setContentOffset(CGPoint(x: 0, y: 9), animated: true)
        watchedText.selectedRange = NSRange(location: 2, length: 0)
        let answer = watchedResponder.becomeFirstResponder()

        #expect(watched.asked == ["offset 7.0 false", "selectedRange 2", "becomeFirstResponder"],
                "each original ran once, with its arguments")
        #expect(answer, "the wrapper returned the original's answer")
        #expect(control.asked == ["offset 9.0 true"], "control: the other text's original ran too")
        #expect(Self.calls(in: probe.label) == ["offset", "selectedRange", "becomeFirstResponder"],
                "only the watched text's calls are noted, each once: \(probe.label)")
    }

    @Test("A class that only inherits a wrapped method gets the wrapper as its own; its superclass is untouched and the original still runs")
    func inheritedMethodsAreWrappedOnTheClassAlone() {
        let text = InheritingText(frame: Self.frame)
        text.text = "abc"
        let scrollBefore = class_getMethodImplementation(UIScrollView.self, Self.offsetSelector)
        let textBefore = class_getMethodImplementation(UITextView.self, Self.selectedRangeSelector)

        ChatFieldDragMarker.TextCalls.install(scrollView: InheritingText.self, textView: InheritingText.self)

        #expect(class_getMethodImplementation(UIScrollView.self, Self.offsetSelector) == scrollBefore,
                "the scroll view's own method is untouched")
        #expect(class_getMethodImplementation(UITextView.self, Self.selectedRangeSelector) == textBefore,
                "the text view's own method is untouched")
        #expect(class_getMethodImplementation(InheritingText.self, Self.offsetSelector) != scrollBefore,
                "control: the class has the wrapper as its own")

        let scroll: UIScrollView = text
        let textView: UITextView = text
        scroll.setContentOffset(CGPoint(x: 0, y: 5), animated: false)
        textView.selectedRange = NSRange(location: 1, length: 0)
        #expect(text.contentOffset.y == 5, "the inherited original ran with its arguments")
        #expect(text.selectedRange.location == 1, "the inherited setter ran with its argument")
    }
}
#endif
