/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import UIKit
@testable import TabMail

/// Unit tests for `CaretAwareUIScrollView.contentOffsetThatShows` — the pure
/// scroll-offset math that computes where to scroll so a target rect lands
/// inside the visible rect, while clamping to the valid scroll range.
///
/// These tests pin the behavior that the compose view depends on:
/// - If the target is already inside the visible area, the offset must not move.
/// - If the target is above the visible area, scroll up (decrease y) just enough.
/// - If the target is below the visible area, scroll down just enough.
/// - The resulting offset must stay within [-insets.top, contentSize.height + insets.bottom - boundsHeight].
@MainActor
@Suite("CaretAwareUIScrollView — contentOffsetThatShows")
struct CaretAwareScrollViewTests {

    // Shared baseline: 2000pt content, 600pt viewport, no insets.
    private let contentSize = CGSize(width: 320, height: 2000)
    private let boundsHeight: CGFloat = 600
    private let zeroInsets = UIEdgeInsets.zero

    @Test("Target already inside visible rect → offset unchanged")
    func targetAlreadyVisibleDoesNotMove() {
        // Visible: y=200…800. Target: y=400…440 (inside).
        let current = CGPoint(x: 0, y: 200)
        let visible = CGRect(x: 0, y: 200, width: 320, height: 600)
        let target = CGRect(x: 0, y: 400, width: 320, height: 40)

        let result = CaretAwareUIScrollView.contentOffsetThatShows(
            target: target,
            within: visible,
            currentOffset: current,
            contentSize: contentSize,
            boundsHeight: boundsHeight,
            insets: zeroInsets
        )
        #expect(result == current)
    }

    @Test("Target above visible rect → scroll up by the gap")
    func targetAboveScrollsUp() {
        // Visible: y=500…1100. Target at y=400, height=20. Gap above = 100.
        let current = CGPoint(x: 0, y: 500)
        let visible = CGRect(x: 0, y: 500, width: 320, height: 600)
        let target = CGRect(x: 0, y: 400, width: 320, height: 20)

        let result = CaretAwareUIScrollView.contentOffsetThatShows(
            target: target,
            within: visible,
            currentOffset: current,
            contentSize: contentSize,
            boundsHeight: boundsHeight,
            insets: zeroInsets
        )
        // Should scroll up by 100: 500 - 100 = 400.
        #expect(result.y == 400)
    }

    @Test("Target below visible rect → scroll down by the overhang")
    func targetBelowScrollsDown() {
        // Visible: y=200…800. Target at y=900, height=40. Overhang = 900+40 - 800 = 140.
        let current = CGPoint(x: 0, y: 200)
        let visible = CGRect(x: 0, y: 200, width: 320, height: 600)
        let target = CGRect(x: 0, y: 900, width: 320, height: 40)

        let result = CaretAwareUIScrollView.contentOffsetThatShows(
            target: target,
            within: visible,
            currentOffset: current,
            contentSize: contentSize,
            boundsHeight: boundsHeight,
            insets: zeroInsets
        )
        // Should scroll down by 140: 200 + 140 = 340.
        #expect(result.y == 340)
    }

    @Test("Scroll down is clamped to max valid offset")
    func scrollDownClampedToMax() {
        // Content 2000pt, bounds 600pt, no insets → max offset = 2000 - 600 = 1400.
        // Target below visible by way more than the max allows.
        let current = CGPoint(x: 0, y: 1300)
        let visible = CGRect(x: 0, y: 1300, width: 320, height: 600)
        let target = CGRect(x: 0, y: 10_000, width: 320, height: 40) // absurdly far

        let result = CaretAwareUIScrollView.contentOffsetThatShows(
            target: target,
            within: visible,
            currentOffset: current,
            contentSize: contentSize,
            boundsHeight: boundsHeight,
            insets: zeroInsets
        )
        #expect(result.y == 1400)
    }

    @Test("Scroll up is clamped to min valid offset")
    func scrollUpClampedToMin() {
        // Min offset = -insets.top = 0 (no insets here).
        // Target above visible by a lot — clamp prevents negative scroll.
        let current = CGPoint(x: 0, y: 100)
        let visible = CGRect(x: 0, y: 100, width: 320, height: 600)
        let target = CGRect(x: 0, y: -500, width: 320, height: 40)

        let result = CaretAwareUIScrollView.contentOffsetThatShows(
            target: target,
            within: visible,
            currentOffset: current,
            contentSize: contentSize,
            boundsHeight: boundsHeight,
            insets: zeroInsets
        )
        #expect(result.y == 0)
    }

    @Test("Top inset shifts the allowed minimum offset negative")
    func topInsetShiftsMinOffset() {
        // With insets.top = 44 (nav bar), the valid min offset is -44.
        let insets = UIEdgeInsets(top: 44, left: 0, bottom: 0, right: 0)
        let current = CGPoint(x: 0, y: 0)
        let visible = CGRect(x: 0, y: 0, width: 320, height: 600)
        let target = CGRect(x: 0, y: -200, width: 320, height: 20)

        let result = CaretAwareUIScrollView.contentOffsetThatShows(
            target: target,
            within: visible,
            currentOffset: current,
            contentSize: contentSize,
            boundsHeight: boundsHeight,
            insets: insets
        )
        // Should clamp to -44 (the top inset), not 0.
        #expect(result.y == -44)
    }

    @Test("Bottom inset extends max scrollable offset")
    func bottomInsetExtendsMaxOffset() {
        // With insets.bottom = 100, max offset = 2000 + 100 - 600 = 1500 (vs 1400 without).
        let insets = UIEdgeInsets(top: 0, left: 0, bottom: 100, right: 0)
        let current = CGPoint(x: 0, y: 1400)
        let visible = CGRect(x: 0, y: 1400, width: 320, height: 600)
        let target = CGRect(x: 0, y: 5000, width: 320, height: 40)

        let result = CaretAwareUIScrollView.contentOffsetThatShows(
            target: target,
            within: visible,
            currentOffset: current,
            contentSize: contentSize,
            boundsHeight: boundsHeight,
            insets: insets
        )
        #expect(result.y == 1500)
    }

    @Test("Content shorter than bounds → max offset is -insets.top, not negative")
    func contentShorterThanBoundsClampsToZero() {
        // contentSize.height (400) < boundsHeight (600) → no scrolling possible.
        // Expected: result equals current, not some negative clamped value.
        let shortContent = CGSize(width: 320, height: 400)
        let current = CGPoint(x: 0, y: 0)
        let visible = CGRect(x: 0, y: 0, width: 320, height: 600)
        let target = CGRect(x: 0, y: 100, width: 320, height: 20) // already visible

        let result = CaretAwareUIScrollView.contentOffsetThatShows(
            target: target,
            within: visible,
            currentOffset: current,
            contentSize: shortContent,
            boundsHeight: boundsHeight,
            insets: zeroInsets
        )
        #expect(result == current)
    }

    @Test("Target exactly matches top edge of visible → no scroll")
    func targetAtTopEdgeDoesNotScroll() {
        // Target sits flush with the top edge of the visible area. Already visible → no-op.
        let current = CGPoint(x: 0, y: 500)
        let visible = CGRect(x: 0, y: 500, width: 320, height: 600)
        let target = CGRect(x: 0, y: 500, width: 320, height: 20)

        let result = CaretAwareUIScrollView.contentOffsetThatShows(
            target: target,
            within: visible,
            currentOffset: current,
            contentSize: contentSize,
            boundsHeight: boundsHeight,
            insets: zeroInsets
        )
        #expect(result == current)
    }

    @Test("Target crosses bottom edge by 1pt → scrolls down by exactly 1pt")
    func targetOverhangsByOnePointScrollsOnePoint() {
        // Visible: y=200…800. Target: y=781…801 (1pt overhang).
        let current = CGPoint(x: 0, y: 200)
        let visible = CGRect(x: 0, y: 200, width: 320, height: 600)
        let target = CGRect(x: 0, y: 781, width: 320, height: 20)

        let result = CaretAwareUIScrollView.contentOffsetThatShows(
            target: target,
            within: visible,
            currentOffset: current,
            contentSize: contentSize,
            boundsHeight: boundsHeight,
            insets: zeroInsets
        )
        #expect(result.y == 201)
    }
}

// MARK: - CaretAwareUIScrollView runtime contract

/// Verifies the runtime invariants required by the `object_setClass` swap that
/// upgrades the SwiftUI ScrollView's underlying UIScrollView to
/// `CaretAwareUIScrollView`: the subclass must have the same instance size and
/// must override `scrollRectToVisible`.
@Suite("CaretAwareUIScrollView — runtime contract")
struct CaretAwareRuntimeContractTests {

    @Test("CaretAwareUIScrollView has the same instance size as UIScrollView")
    func caretAwareInstanceSizeMatches() {
        let baseSize = class_getInstanceSize(UIScrollView.self)
        let subSize = class_getInstanceSize(CaretAwareUIScrollView.self)
        #expect(baseSize == subSize, "CaretAwareUIScrollView must have the same instance size as UIScrollView for object_setClass to be safe")
    }

    @Test("CaretAwareUIScrollView overrides scrollRectToVisible with a different IMP than UIScrollView")
    func caretAwareOverridesScrollRectToVisible() {
        let selector = #selector(UIScrollView.scrollRectToVisible(_:animated:))
        let baseIMP = class_getMethodImplementation(UIScrollView.self, selector)
        let subIMP = class_getMethodImplementation(CaretAwareUIScrollView.self, selector)
        #expect(baseIMP != nil)
        #expect(subIMP != nil)
        #expect(baseIMP != subIMP, "CaretAwareUIScrollView must provide its own scrollRectToVisible IMP")
    }
}

// MARK: - UIView.enclosingUIScrollView

/// Tests for the superview-walking helper used by `DisableAutoScrollToVisible`
/// to locate the enclosing SwiftUI ScrollView's underlying UIScrollView.
@MainActor
@Suite("UIView.enclosingUIScrollView")
struct EnclosingUIScrollViewTests {

    @Test("Returns nil for a lone view with no superview")
    func loneViewReturnsNil() {
        let view = UIView()
        #expect(view.enclosingUIScrollView() == nil)
    }

    @Test("Returns nil when no scroll view is in the ancestor chain")
    func noScrollViewAncestorReturnsNil() {
        let root = UIView()
        let mid = UIView()
        let leaf = UIView()
        root.addSubview(mid)
        mid.addSubview(leaf)
        #expect(leaf.enclosingUIScrollView() == nil)
    }

    @Test("Finds an immediate parent scroll view")
    func findsImmediateParent() {
        let scroll = UIScrollView()
        let child = UIView()
        scroll.addSubview(child)
        #expect(child.enclosingUIScrollView() === scroll)
    }

    @Test("Walks up multiple levels to find a scroll view")
    func walksMultipleLevels() {
        let scroll = UIScrollView()
        let mid = UIView()
        let leaf = UIView()
        scroll.addSubview(mid)
        mid.addSubview(leaf)
        #expect(leaf.enclosingUIScrollView() === scroll)
    }

    @Test("Returns the nearest scroll view when nested scroll views exist")
    func nestedScrollViewsReturnsInnermost() {
        let outer = UIScrollView()
        let inner = UIScrollView()
        let child = UIView()
        outer.addSubview(inner)
        inner.addSubview(child)
        // Walking up from child hits `inner` first, not `outer`.
        #expect(child.enclosingUIScrollView() === inner)
    }

    @Test("Returns self's direct scroll view parent, not a cousin scroll view")
    func siblingScrollViewIsNotFound() {
        // A scroll view that is a sibling (not an ancestor) of our target
        // should NOT be returned. Walking up the chain only goes through
        // ancestors.
        let rootContainer = UIView()
        let sibling = UIScrollView()
        let targetContainer = UIView()
        let leaf = UIView()
        rootContainer.addSubview(sibling)
        rootContainer.addSubview(targetContainer)
        targetContainer.addSubview(leaf)
        #expect(leaf.enclosingUIScrollView() == nil)
    }
}

// MARK: - CaretAwareUIScrollView.visibleAreaAboveKeyboard

/// Tests for the keyboard-aware visible-area calculation. Requires a real
/// UIView hierarchy inside a UIWindow so that `convert(_:from:)` can resolve
/// window-coordinate input. We do NOT call `makeKeyAndVisible()` — the scroll
/// view only needs a window ancestor for `window != nil` and coordinate
/// conversion to work.
///
/// Serialized because this suite mutates the class-level
/// `CaretAwareUIScrollView.currentKeyboardFrame` static, which is shared
/// across all instances.
///
/// # WINDOW-DEPRECATION NOTE (`IOS-TEST-004`, the 9th warning pair)
///
/// `UIWindow.init(frame:)` is deprecated in iOS 26 in favour of
/// `init(windowScene:)`, and this target's deployment target is 26.0, so every
/// use warns. There is no test-safe replacement: `UIWindow()` carries the
/// identical `API_DEPRECATED(..., ios(2.0, 26.0))` attribute, and
/// `init(windowScene:)` requires a live `UIWindowScene` that a unit test has no
/// guaranteed access to — obtaining one would change what these tests construct,
/// which is the thing under test.
///
/// So the diagnostic is suppressed **locally and by declaration**, never by a
/// project-wide flag (Swift has no per-group `-Wno`; `-suppress-warnings` would
/// hide every other warning in the file, and warnings are errors here). Swift
/// does not diagnose a deprecated API used from a context that is itself
/// deprecated at the same version, so the `@available(iOS, deprecated: 26.0)`
/// below marks exactly the declarations that participate in constructing the
/// window and nothing else — the helper, and each `@Test` that calls it. Every
/// other declaration in this file is still fully checked.
///
/// ⚠️ **These annotations do NOT mean the tests are obsolete.** They are
/// suppression scope, and they must be removed the moment a non-deprecated
/// window construction becomes available to a unit test. A suite-level
/// annotation was rejected: Swift Testing refuses `@Suite`/`@Test` on a
/// declaration marked `@available(..., deprecated:)`, and it would also silence
/// unrelated future deprecations across the whole suite.
@MainActor
@Suite("CaretAwareUIScrollView — visibleAreaAboveKeyboard", .serialized)
struct VisibleAreaAboveKeyboardTests {

    /// Builds a scroll view hosted in a window, at a specific screen position.
    /// The window and scroll view are returned so the caller can keep them
    /// alive for the duration of a single test.
    ///
    /// Deprecation-suppression scope only — see the WINDOW-DEPRECATION NOTE above.
    @available(iOS, deprecated: 26.0, message: "Suppression scope for UIWindow.init(frame:) — see WINDOW-DEPRECATION NOTE. Not obsolete.")
    private func makeScrollViewInWindow(
        scrollViewFrame: CGRect,
        windowFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 800)
    ) -> (UIWindow, CaretAwareUIScrollView) {
        let scroll = CaretAwareUIScrollView(frame: scrollViewFrame)
        let window = UIWindow(frame: windowFrame)
        window.addSubview(scroll)
        return (window, scroll)
    }

    @available(iOS, deprecated: 26.0, message: "Suppression scope for UIWindow.init(frame:) — see WINDOW-DEPRECATION NOTE. Not obsolete.")
    @Test("Returns full bounds minus insets when keyboard frame is .zero")
    func noKeyboardReturnsFullBounds() {
        CaretAwareUIScrollView.currentKeyboardFrame = .zero
        let (_, scroll) = makeScrollViewInWindow(
            scrollViewFrame: CGRect(x: 0, y: 0, width: 320, height: 600)
        )
        let result = scroll.visibleAreaAboveKeyboard()
        let expected = scroll.bounds.inset(by: scroll.adjustedContentInset)
        #expect(result == expected)
    }

    @Test("Returns full bounds when the view has no window")
    func noWindowReturnsFullBounds() {
        // Set a non-zero keyboard — but because the scroll view isn't in a
        // window, we should still return the full bounds (can't convert).
        CaretAwareUIScrollView.currentKeyboardFrame = CGRect(x: 0, y: 400, width: 400, height: 300)
        let scroll = CaretAwareUIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        #expect(scroll.window == nil)
        let result = scroll.visibleAreaAboveKeyboard()
        let expected = scroll.bounds.inset(by: scroll.adjustedContentInset)
        #expect(result == expected)
        CaretAwareUIScrollView.currentKeyboardFrame = .zero
    }

    @available(iOS, deprecated: 26.0, message: "Suppression scope for UIWindow.init(frame:) — see WINDOW-DEPRECATION NOTE. Not obsolete.")
    @Test("Returns full bounds when the keyboard does not intersect the scroll view")
    func keyboardBelowScrollViewReturnsFullBounds() {
        // Scroll view is at window y=0..400. Keyboard is at window y=600..900
        // — entirely below the scroll view, no intersection.
        let (_, scroll) = makeScrollViewInWindow(
            scrollViewFrame: CGRect(x: 0, y: 0, width: 320, height: 400)
        )
        CaretAwareUIScrollView.currentKeyboardFrame = CGRect(x: 0, y: 600, width: 320, height: 300)
        let result = scroll.visibleAreaAboveKeyboard()
        let expected = scroll.bounds.inset(by: scroll.adjustedContentInset)
        #expect(result == expected)
        CaretAwareUIScrollView.currentKeyboardFrame = .zero
    }

    @available(iOS, deprecated: 26.0, message: "Suppression scope for UIWindow.init(frame:) — see WINDOW-DEPRECATION NOTE. Not obsolete.")
    @Test("Shrinks visible rect to end at keyboard top when keyboard overlaps bottom")
    func keyboardOverlappingBottomShrinksVisible() {
        // Scroll view: window y=0..600. Keyboard: y=400..800 (overlaps bottom 200pt).
        // Expected visible = y=0..400, height=400.
        let (_, scroll) = makeScrollViewInWindow(
            scrollViewFrame: CGRect(x: 0, y: 0, width: 320, height: 600)
        )
        CaretAwareUIScrollView.currentKeyboardFrame = CGRect(x: 0, y: 400, width: 320, height: 400)
        let result = scroll.visibleAreaAboveKeyboard()
        // The resulting height should be the distance from scroll view top (0)
        // to keyboard top in scroll view coords (400). Width unchanged.
        #expect(result.origin == scroll.bounds.inset(by: scroll.adjustedContentInset).origin)
        #expect(result.height == 400)
        CaretAwareUIScrollView.currentKeyboardFrame = .zero
    }

    @available(iOS, deprecated: 26.0, message: "Suppression scope for UIWindow.init(frame:) — see WINDOW-DEPRECATION NOTE. Not obsolete.")
    @Test("Visible rect is unaffected when keyboard is entirely above the scroll view")
    func keyboardAboveScrollViewReturnsFullBounds() {
        // Scroll view at window y=400..700. Keyboard at y=0..300 (entirely above).
        // The keyboard doesn't intersect; return full bounds.
        let (_, scroll) = makeScrollViewInWindow(
            scrollViewFrame: CGRect(x: 0, y: 400, width: 320, height: 300)
        )
        CaretAwareUIScrollView.currentKeyboardFrame = CGRect(x: 0, y: 0, width: 320, height: 300)
        let result = scroll.visibleAreaAboveKeyboard()
        let expected = scroll.bounds.inset(by: scroll.adjustedContentInset)
        #expect(result == expected)
        CaretAwareUIScrollView.currentKeyboardFrame = .zero
    }
}

// MARK: - CaretAwareUIScrollView does not gate text input
//
// Regression tests for the keystrokes-eaten bug. A previous version of
// CaretAwareUIScrollView class-swapped the focused UITextView to a
// `GatedUITextView` subclass on every scroll-into-view and dropped
// insertText/deleteBackward/paste for 500 ms. UIKit fires scrollRectToVisible
// on every line wrap / Enter / keyboard frame change during normal typing —
// so a fast typist lost 4-6 keystrokes per scroll. These tests pin the
// post-fix invariant: the focused text view must keep its identity and must
// keep accepting input across a scroll-to-cursor event.

@MainActor
@Suite("CaretAwareUIScrollView — does not gate text input", .serialized)
struct CaretAwareDoesNotGateInputTests {

    /// Builds the real hierarchy used in compose: a CaretAwareUIScrollView
    /// in a key window, a UITextView taller than the scroll view as its
    /// child, and the text view as first responder. Returns everything so
    /// the caller can keep it alive for the duration of one test.
    ///
    /// Deprecation-suppression scope only — see the WINDOW-DEPRECATION NOTE on
    /// `VisibleAreaAboveKeyboardTests` above for why `UIWindow.init(frame:)` has no
    /// test-safe replacement and why the scope is per-declaration.
    @available(iOS, deprecated: 26.0, message: "Suppression scope for UIWindow.init(frame:) — see WINDOW-DEPRECATION NOTE. Not obsolete.")
    private func makeFirstResponderTextView()
        -> (UIWindow, CaretAwareUIScrollView, UITextView)
    {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let scroll = CaretAwareUIScrollView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 400)
        )
        scroll.contentSize = CGSize(width: 400, height: 2000)
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 400, height: 1000))
        scroll.addSubview(textView)
        window.addSubview(scroll)
        window.makeKeyAndVisible()
        _ = textView.becomeFirstResponder()
        return (window, scroll, textView)
    }

    @available(iOS, deprecated: 26.0, message: "Suppression scope for UIWindow.init(frame:) — see WINDOW-DEPRECATION NOTE. Not obsolete.")
    @Test("scrollRectToVisible does not swap the focused UITextView's class")
    func doesNotSwapTextViewClass() {
        let (window, scroll, textView) = makeFirstResponderTextView()
        defer {
            _ = textView.resignFirstResponder()
            window.isHidden = true
        }

        let classBefore: AnyClass? = object_getClass(textView)
        // Off-screen rect, smaller than the visible area, so the early-return
        // path (focusRect already inside visibleRect) is bypassed AND the
        // caret-substitution path doesn't kick in. This is the exact code path
        // that used to engage the input gate.
        scroll.scrollRectToVisible(
            CGRect(x: 0, y: 800, width: 100, height: 20),
            animated: false
        )
        let classAfter: AnyClass? = object_getClass(textView)

        #expect(
            classBefore == classAfter,
            "scrollRectToVisible must not swap the focused UITextView's class — re-introducing a Gated subclass would silently drop keystrokes"
        )
    }

    @available(iOS, deprecated: 26.0, message: "Suppression scope for UIWindow.init(frame:) — see WINDOW-DEPRECATION NOTE. Not obsolete.")
    @Test("Text input lands immediately after a scrollRectToVisible call")
    func textInputSurvivesScrollEvent() {
        let (window, scroll, textView) = makeFirstResponderTextView()
        defer {
            _ = textView.resignFirstResponder()
            window.isHidden = true
        }

        textView.text = ""
        textView.insertText("a")
        // Trigger a scroll-into-view that, in the regression case, would
        // arm a 500 ms input block. We then immediately try to type — the
        // keystroke must NOT be dropped.
        scroll.scrollRectToVisible(
            CGRect(x: 0, y: 800, width: 100, height: 20),
            animated: false
        )
        textView.insertText("b")

        #expect(
            textView.text == "ab",
            "insertText after scrollRectToVisible must not be dropped — got \(textView.text ?? "<nil>")"
        )
    }

    @available(iOS, deprecated: 26.0, message: "Suppression scope for UIWindow.init(frame:) — see WINDOW-DEPRECATION NOTE. Not obsolete.")
    @Test("deleteBackward lands immediately after a scrollRectToVisible call")
    func deleteBackwardSurvivesScrollEvent() {
        let (window, scroll, textView) = makeFirstResponderTextView()
        defer {
            _ = textView.resignFirstResponder()
            window.isHidden = true
        }

        textView.text = "abc"
        // Place caret at end so deleteBackward removes 'c'.
        textView.selectedRange = NSRange(location: 3, length: 0)
        scroll.scrollRectToVisible(
            CGRect(x: 0, y: 800, width: 100, height: 20),
            animated: false
        )
        textView.deleteBackward()

        #expect(
            textView.text == "ab",
            "deleteBackward after scrollRectToVisible must not be dropped — got \(textView.text ?? "<nil>")"
        )
    }
}
