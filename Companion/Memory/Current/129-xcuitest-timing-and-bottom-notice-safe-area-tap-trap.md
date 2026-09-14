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
