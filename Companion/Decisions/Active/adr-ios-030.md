
## ADR-IOS-030: Agent Compose Tool FIFO Queue

**Context:** Agent tools `email_compose`, `email_reply`, and `email_forward` set `AgentToolRouter.pendingCompose`, which `InboxView` and `MessageDetailView` observe via `onChange` and present as a `fullScreenCover`. There was no coordination with already-presented compose windows:

- If the user had a compose window open (manually, or from a prior agent call), a new agent compose request was silently dropped — SwiftUI cannot stack two `fullScreenCover`s from the same source view, and the local `@State` set during `onChange` is not re-evaluated when the prior cover dismisses.
- If two agent tools fired back-to-back, the second overwrote the first in the single-slot router state and was lost before any view captured it.
- The LLM still received `"Opening compose window..."` as the tool result, so the model thought the operation succeeded — confidently wrong, no retry, no user-visible failure.

**Decision:** Compose tool requests go through an in-memory FIFO queue on `AgentToolRouter`. Only one `ComposeView` is presented at a time. **A manually-opened compose window counts as the head of the queue** — agent requests wait until it dismisses, then play one after another with no gaps.

**Mechanism:**

1. Tools call `AgentToolRouter.shared.enqueueCompose(request)` (synchronous, fire-and-forget). The request is appended to `composeQueue`. Tools' return strings are unchanged — the LLM gets the same response it always did.
2. `dispatchNextIfIdle()` runs synchronously after enqueue. The dispatch guard checks four conditions: `awaitingAppear == false`, `pendingCompose == nil`, `presentationCount == 0`, and `!composeQueue.isEmpty`. If all are satisfied, it pops the front of the queue, sets `awaitingAppear = true`, and assigns the request to `pendingCompose`.
3. The existing `onChange(of: pendingCompose?.id)` in `InboxView`/`MessageDetailView` captures the request into local `@State` and presents the cover via the existing `.fullScreenCover(item:)` plumbing.
4. `ComposeView.onAppear` calls `composePresentationDidBegin()` which increments `presentationCount` AND clears `awaitingAppear`. `ComposeView.onDisappear` calls `composePresentationDidEnd()` which decrements (clamped at 0) and dispatches the next queued request if count returns to 0.
5. Because the lifecycle hook lives **inside `ComposeView` itself**, it fires for **every** presentation path automatically — manual compose toolbar button, contact compose, reply, replyAll, forward, agent compose, agent draft re-open via `DraftComposePresenter`. No per-cover-site instrumentation, no risk of forgetting one. (`DraftComposePresenter` also has the same hook on its body root — see "Loading wrapper race" below.)

**The `awaitingAppear` flag closes the dispatch race.**

Without it, there is a brief window between "router sets `pendingCompose = A`" and "the new `ComposeView`'s `onAppear` fires `composePresentationDidBegin`" during which:
- The view's `onChange` handler has already captured `A` into local `@State` and synchronously nilled `pendingCompose` (the original pre-queue housekeeping pattern, preserved in this change).
- The `fullScreenCover` is mid-presentation but `composePresentationDidBegin` hasn't yet fired.
- `pendingCompose == nil` AND `presentationCount == 0` are both true.

If a second `enqueueCompose(B)` arrived in this window, the dispatch guard would falsely succeed, set `pendingCompose = B`, and the view's `onChange` would fire again — replacing the in-flight `agentCompose` `@State` value from A to B mid-presentation. SwiftUI's `fullScreenCover(item:)` does not gracefully transition between two non-nil identifiable values (per Apple docs and observed behavior on iOS 18+), so A would be silently dropped.

`awaitingAppear` is set to `true` at dispatch time and cleared in `composePresentationDidBegin`. The dispatch guard tests it. A second `enqueueCompose` during the race window finds `awaitingAppear == true` and queues instead. The window is microseconds in normal SwiftUI runloops, but the race is real when two LLM tool calls return in the same runloop tick.

**Loading wrapper race (DraftComposePresenter).**

`DraftComposePresenter` is a wrapper that loads a draft from GRDB before rendering `ComposeView`. It is presented in two places: (a) `InboxView`'s `showAgentDraft` cover, set by tapping an agent toast; (b) `ComposeToolbarButton`'s `showDraft` cover, set when re-opening an in-progress agent draft. During the brief loading state (synchronous GRDB read, microseconds), `ComposeView` has not yet rendered, so the queue's `presentationCount` is still 0. Without a hook on `DraftComposePresenter` itself, a queued agent compose could try to present from the same source view during this window — and SwiftUI would silently drop the second cover.

Fix: `DraftComposePresenter` carries the same `composePresentationDidBegin/End` hook on its body root. When the cover presents, count increments immediately even before the inner `ComposeView` loads. When the cover dismisses, both `ComposeView.onDisappear` and `DraftComposePresenter.onDisappear` fire (inner first), decrementing the count from 2 → 1 → 0, with the dispatch trigger firing on the second decrement. `ServerDraftComposeLoader` (a navigation destination, not a cover) doesn't need this hook because it's not a `fullScreenCover` and an agent compose can present on top of it without conflict.

**Lifecycle hooks are safe against ComposeView's internal modals.**

ComposeView contains `.alert`, `.popover`, `.photosPicker`, `.fileImporter`, and a `.fullScreenCover` for the camera. Confirmed via Apple Developer Forums (thread 655338) that a parent view's `onAppear`/`onDisappear` do **not** fire when the parent itself presents any of these. The parent stays in the view hierarchy; only the inner presentation is layered on top. So `presentationCount` does not drift when the user opens the camera or picks a photo from inside `ComposeView`.

**In-memory only.** App kill loses the queue. Agent compose requests are session-scoped UI intent, not durable user actions like outbox sends (ADR-IOS-019) or pending operations (ADR-IOS-018). Persistence would add complexity for negligible benefit — if the app dies, the agent task that produced the request is also gone.

**Stop button is not relevant.** The user cannot tap Stop while a compose `fullScreenCover` is presented (the inbox/chat surface is hidden behind it). The queue therefore needs no cancellation semantics — by the time the user could possibly cancel, the compose window has already appeared and the request has already left the queue.

**Consequences:**

- Multiple back-to-back agent compose requests are presented in order, each waiting for the previous to dismiss. The user may be "bombarded" with compose confirmations — accepted as the lesser evil compared to silently losing requests.
- A manually-opened compose window blocks queued agent compose requests until the user dismisses it. The agent waits patiently. When the user closes their compose, the queued agent compose appears immediately.
- The InboxView/MessageDetailView observer race (both views observe `pendingCompose`; whichever wins captures and nils the slot) is unchanged — the queue layer is orthogonal to which view presents. Whichever view wins each dispatch round presents that round's request.
- If neither `InboxView` nor `MessageDetailView` is alive when the queue dispatches (e.g., user is deep in Settings), `pendingCompose` stays set and the queue stalls. Acceptable — these are the only views that observe, and at least one is always alive when an agent runs from a chat surface.
- The queue has no priority and no deduplication. If the agent fires three "compose to alice@x.com" requests in a row, the user sees three compose windows in sequence. By design — we can't second-guess the agent's intent.

**Out of scope (deliberately):**

- Persistence across app kill.
- A user-visible queue indicator (e.g. "2 more compose drafts pending"). Easy follow-up if needed.
- Queueing of `ActionConfirmation` (archive/delete/calendar prompts) — separate single-slot system, separate concern.
- Coordinating with non-`ComposeView` UI surfaces.
- Telling the LLM that a request is queued vs. dispatched. Tool return string is unchanged.

**Files:**

- `TabMail/Services/AI/AgentToolRouter.swift` — `composeQueue`, `presentationCount`, `awaitingAppear`, `enqueueCompose`, `composePresentationDidBegin/End`, `dispatchNextIfIdle`. New private fields are `@ObservationIgnored` so they don't create observation dependencies.
- `TabMail/Services/AI/Tools/EmailComposeTool.swift`, `EmailReplyTool.swift`, `EmailForwardTool.swift` — call `enqueueCompose` instead of writing `pendingCompose` directly
- `TabMail/Views/Compose/ComposeView.swift` — `onAppear`/`onDisappear` lifecycle hooks on the body root
- `TabMail/Views/Compose/DraftComposePresenter.swift` — same hooks on its body root, to close the loading-window race before the inner `ComposeView` renders

**PARTIALLY SUPERSEDED (routing) by ADR-IOS-053:** the InboxView/MessageDetailView `pendingCompose` observer race noted in the Consequences is slated to be fixed (Phase 2) by re-homing compose routing to the owned `AgentUISink`. The cover-serialization FIFO (`composeQueue`/`presentationCount`/`awaitingAppear`) is retained — it solves the distinct "SwiftUI can't stack two fullScreenCovers" constraint, which owned routing does not address.

---
