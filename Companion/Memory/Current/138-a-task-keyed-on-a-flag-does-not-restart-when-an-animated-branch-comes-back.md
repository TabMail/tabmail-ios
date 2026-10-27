# A `.task(id:)` keyed on a flag does not restart when its animated branch comes back

Found 2026-10-26 (guided tutorial, Codex review round c4 follow-up; ADR-IOS-038 c4 bullet).

## What happened

`RootView` shows `DemoSeedingSplash` in the demo branch of `routedContent` and ran the demo setup
from `.task(id: demoStore.isActive)` on it. `RootView` also animates that flag:
`.animation(.spring(response: 0.4, dampingFraction: 0.85), value: demoStore.isActive)`.

When a demo ended and the next one started while the ended run's splash was still animating out,
SwiftUI brought the SAME splash back instead of inserting a new one. The task's id read `true`
before and after (the `false` in between never reached the disappearing view), so SwiftUI did not
restart the task. The finished task of the ended run stayed, the new run's setup never ran, and the
splash stayed up. Route prints showed `routedContent` re-evaluated four times with the demo on and
the splash branch chosen, and no task start.

In the unit-test fixture (a notification tap during the splash ends the tutorial, then the next run
starts) it failed about 1 run in 5, more often under load, with the scene active. Restarting at
once made it fail every time.

## The rule

Key a `.task(id:)` by the IDENTITY of the work it does (the run, the message, the account), never by
a flag that can return to its old value. An off-then-on flip that lands inside a removal transition
is invisible to the view that comes back. Here the key is `demoStore.chatAdmission`, the demo run.

Related: memory 074 (stable anchors for `.task` on conditionals; it listed the `RootView` demo
seeding task as "terminal, left as-is", which this disproves), MIS-IOS-017.

## How to diagnose the next one

Print in the `@ViewBuilder` (`let _ = print(...)`) and at the top of the task. Body evaluations with
the branch selected but no task start mean SwiftUI kept the view's identity. Then look for an
`.animation(value:)` or `withAnimation` on the flag.
