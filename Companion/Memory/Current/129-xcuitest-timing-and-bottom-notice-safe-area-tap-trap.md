# 129 — XCUITest timing budgets for auto-dismissing notices, and the bottom safe-area tap trap

**Search terms:** XCUITest, fullSwipe, waitForNonExistence, toast, notice, auto-dismiss,
displayDuration, safeAreaInset, ignoresSafeArea, tap swallowed, oracle escape, #147,
`DraftSwipeDeleteUITests`, `ServerDraftCloseTestScene`, `InboxNoticeCapsule`.

## Measured (2026-09-14, iPhone 17 Pro simulator, #147 train)

- A `press(forDuration:thenDragTo:)` full swipe takes **~1.5 s** from launch of the gesture to
  the point where the row's full-swipe action fires, and ~2 s to return.
- Every element query (`exists`, `waitForExistence`, `tap`) costs **0.4–1.2 s** of latency.
- A `waitForNonExistence(timeout: T)` window therefore slops to roughly `T + 1 s`.

Consequence: to observe that a **second** gesture's notice outlives the **first** gesture's timer,
the display duration has to exceed (gap between swipes ≈ 2.5 s) + (gesture ≈ 1.5 s) + (assertion
window + slop ≈ 3 s). At 4 s the first deadline had already passed before the retry fired and the
replacement was unobservable; at **6 s** it is observable with ~1 s to spare. Design the duration
and the assertion window together, and keep the tap-dismissal window **shorter than the timer** or a
dead tap handler passes on expiry (the reviewer's oracle escape, reproduced: the first green tap
run was expiry, not dismissal).

## The trap

A bottom notice that uses `.ignoresSafeArea(.container, edges: .bottom)` + negative bottom padding
(the agent-toast capsule pattern, shared by `InboxNoticeCapsule`) sits INSIDE the bottom safe
area. Any fixture `.safeAreaInset(edge: .bottom)` control bar therefore renders **on top of it** and
swallows `XCUIElement.tap()` — the element still `exists`, so existence assertions pass while the
tap does nothing. `ServerDraftCloseTestScene` keeps its bar at the **top** in `--draft-delete-refused`
mode for exactly this reason. In production nothing occupies that region, so this is a
harness-only hazard.

## The reverse trap: content drawn out of a `.safeAreaBar` cannot be touched (2026-11-25)

**Search terms:** safeAreaBar, bar slot, overflow, hit test, `_UIFloatingBarContainerView`,
`_UITouchPassthroughView`, panel won't scroll, Close falls through to the dim, `TouchWatch`.

SwiftUI hosts a `.safeAreaBar` bar's content in UIKit's floating bar container
(`_UIFloatingBarContainerView` / `_UITouchPassthroughView`), which hit-tests only inside the bar's
own bounds. The chat view's bar was a fixed slot of the collapsed field's height with the field
drawn as an unclipped overlay that grew upward when the TabMail panel opened. The open panel was
visible, but touches above the slot went to the page's hosting view underneath. Its history did
not scroll, and a tap on its Close button fell through to the page's dim, which closed the panel,
so "Close works" was a false pass. A debug window recognizer that records the touched view chain
(`ChatFieldDragMarker.TouchWatch`, `touch=` in the marker) showed it: the only recognizers reached
were the page's and the system's, with no scroll view pan.

Rule: a `.safeAreaBar` may hold only what stays inside its bounds. To keep a fixed inset while
something grows out of the bar, keep a clear slot in the bar and draw the control in a
bottom-aligned overlay on the page right after it; both sit on the same safe-area or keyboard
bottom (ADR-IOS-114 decision 20, amendment 2026-11-25). In a UI test, prove a tap was taken by its
own control, not by something behind it that does the same thing (count the dim's taps).
