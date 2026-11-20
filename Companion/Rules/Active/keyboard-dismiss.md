## Keyboard Dismiss Rule

**Tapping anywhere outside the keyboard MUST dismiss the keyboard. This is a fundamental UX design rule — no exceptions.**

- Every screen with text input MUST apply `.dismissKeyboardOnTap()` (defined in `KeyboardDismiss.swift`) on its root container.
- ScrollViews with text input should also use `.scrollDismissesKeyboard(.interactively)`.
- The keyboard reappears naturally when the user taps a text field — no special handling needed.
- The dismiss tap runs alongside every other recognizer (`shouldRecognizeSimultaneouslyWith` returns true), so a tap on a button, chip or bubble also drops the keyboard; only a touch inside a text field or text view (the view itself or any of its subviews, such as the field editor) is excluded (2026-11-19), so a tap that moves the caret in a field being edited keeps the keyboard.
- A control whose action deliberately focuses an input (a template's plus, a bullet list's Add, a rejected recipient chip, "Fork and re-send", opening search) keeps or moves the keyboard focus to that input: UIKit documents no order between the dismiss tap's `endEditing` and a Button action setting `@FocusState`; as observed, `endEditing` runs first in the same tap and the action's focus wins, and that outcome (not the order) is pinned by `KeyboardFocusRaceUITests` (2026-11-19).
- Do NOT add manual keyboard dismiss buttons (toolbar chevrons, floating buttons, etc.). The tap-outside gesture handles everything.

---
