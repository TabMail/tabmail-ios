## Keyboard Dismiss Rule

**Tapping anywhere outside the keyboard MUST dismiss the keyboard. This is a fundamental UX design rule — no exceptions.**

- Every screen with text input MUST apply `.dismissKeyboardOnTap()` (defined in `KeyboardDismiss.swift`) on its root container.
- ScrollViews with text input should also use `.scrollDismissesKeyboard(.interactively)`.
- The keyboard reappears naturally when the user taps a text field — no special handling needed.
- Do NOT add manual keyboard dismiss buttons (toolbar chevrons, floating buttons, etc.). The tap-outside gesture handles everything.

---
