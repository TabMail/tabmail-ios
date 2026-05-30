/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Dismisses the keyboard when the user taps outside of text inputs.
///
/// Uses a UIKit `UITapGestureRecognizer` with `cancelsTouchesInView = false`
/// so child views still receive their touches. A delegate filter prevents
/// the gesture from firing on `UITextField` / `UITextView` (which handle
/// their own focus).
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
        // Don't dismiss when tapping text inputs — they handle focus themselves
        return !(view is UITextField || view is UITextView)
    }
}

extension View {
    /// Dismiss the keyboard when the user taps outside any text input.
    func dismissKeyboardOnTap() -> some View {
        modifier(KeyboardDismissOnTapModifier())
    }
}
