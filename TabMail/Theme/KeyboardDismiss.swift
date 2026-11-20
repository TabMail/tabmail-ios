/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Dismisses the keyboard when the user taps outside of text inputs.
///
/// Uses a UIKit `UITapGestureRecognizer` with `cancelsTouchesInView = false`
/// so child views still receive their touches. A delegate filter prevents
/// the gesture from firing on a touch inside a `UITextField` / `UITextView`
/// (which handle their own focus), including their internal subviews.
///
/// Apply once near the root of a screen (e.g. on NavigationStack).
private struct KeyboardDismissOnTapModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(KeyboardDismissHelper())
    }
}

private struct KeyboardDismissHelper: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = KeyboardDismissView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_: UIView, context: Context) {}
}

private final class KeyboardDismissView: UIView {
    private var tapRecognizer: UITapGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard tapRecognizer == nil, let window else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        tapRecognizer = tap
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil, let tap = tapRecognizer {
            window?.removeGestureRecognizer(tap)
            tapRecognizer = nil
        }
    }

    @objc private func handleTap() {
        window?.endEditing(true)
    }
}

extension KeyboardDismissView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        // Don't dismiss when tapping inside a text input — it handles focus itself. A tap in a field
        // being edited lands on an internal subview (the field editor, the text view inside a
        // multi-line SwiftUI TextField or TextEditor, selection handles), so walk the superviews.
        if sequence(first: view, next: \.superview).contains(where: { $0 is UITextField || $0 is UITextView }) {
            return false
        }
        // A control drawn inside a text field's own box (a clear button, a token's remove) counts as
        // a tap on the field. SwiftUI draws those controls without a UIView of their own, so the box is
        // marked (`textInputBox()`), and UIKit's own hit testing says whether the marked box is what
        // the touch hits: frontmost, not covered, not clipped away.
        return !TextInputBoxMarkerView.isHit(by: touch, in: window)
    }

    /// The dismiss tap only watches (`cancelsTouchesInView = false`), so it runs alongside every other
    /// recognizer: a SwiftUI gesture that begins on touch down, or a closer that takes the tap, must not
    /// shut it out, or a tap outside a text input leaves the keyboard up (the keyboard dismiss rule).
    func gestureRecognizer(_: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Covers a text field's own box, laid over it so it is exactly as large and sits above the box's
/// own controls but below anything drawn later over the box. It never takes a touch: its hit test
/// answers only while the dismiss tap probes, so the box's controls get every real touch.
private final class TextInputBoxMarkerView: UIView {
    /// Set only for the duration of one `isHit` probe, on the main thread.
    private static var probing = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard Self.probing else { return nil }
        return super.hitTest(point, with: event)
    }

    /// Whether UIKit's hit testing, at the touch's point in `window`, lands on a marked box. A view
    /// drawn over the box takes the hit first, and a box scrolled or clipped out of its container
    /// is outside its ancestors' bounds, so neither counts.
    static func isHit(by touch: UITouch, in window: UIWindow?) -> Bool {
        guard let window else { return false }
        probing = true
        defer { probing = false }
        return window.hitTest(touch.location(in: window), with: nil) is TextInputBoxMarkerView
    }
}

private struct TextInputBoxMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        TextInputBoxMarkerView()
    }

    func updateUIView(_: UIView, context: Context) {}
}

extension View {
    /// Marks this view as a text field's own box: a tap on a control inside it (a clear button, a
    /// token's remove) counts as a tap on the field and keeps the keyboard (the keyboard dismiss rule).
    func textInputBox() -> some View {
        overlay(TextInputBoxMarker())
    }

    /// Dismiss the keyboard when the user taps outside any text input.
    func dismissKeyboardOnTap() -> some View {
        modifier(KeyboardDismissOnTapModifier())
    }
}
