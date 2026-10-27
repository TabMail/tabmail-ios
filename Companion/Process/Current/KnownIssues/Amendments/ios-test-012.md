# IOS-TEST-012

- Register classification: `accepted`
- New post-freeze record (2026-10-26) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-10-26, owner; extended the same day after review round c4)** — eight
guided-tutorial hooks that live in SwiftUI view code have no committed test. A unit test cannot reach a view's private function, so deleting one
of these calls leaves every unit suite green.

## Subsystem and search terms

Guided tutorial; ADR-IOS-038; `TutorialCoordinator`; `TutorialDiscovery`; view wiring; SwiftUI view
not unit-testable; `DynamicIslandChat.sendTutorialPrompt`; `sendAgentChat(_:script:)`;
`ComposeView.send`; `holdsForUndo`; `isTutorialPracticeReply`; `InboxView.executeTaggedAction`;
`MessageDetailView.executeTaggedAction`; `discovered(.tagTap)`; `discovered(.inboxChat)`;
`ComposeView.suggestionBubble`; Use Suggestion; `admits(.useSuggestion)`; `acceptVisibleSuggestionIfOffered`;
`DynamicIslandChat.sendTutorialEdit`; `runPracticeReplyEdit`; `onDraftUpdate`; `TutorialMessageHost`;
`messageOpened`; `.askAnythingDone`; mutation survived; Codex review round c2 TC1; Codex review round
c4 TC1 TC2 TC3

## The eight hooks

| Hook | If the call is lost |
|---|---|
| `DynamicIslandChat.sendTutorialPrompt` passes the chosen prompt to `sendAgentChat(_:script:)` | The tutorial question goes to the model. The backend refuses it during the tutorial, so part 3 shows an error instead of the scripted answer |
| `ComposeView.send` passes `holdsForUndo: !snapshot.isTutorialPracticeReply` | The practice reply waits out the ordinary undo-send hold before it reaches Sent. Part 2 still moves on after the hold |
| `InboxView.executeTaggedAction` records `discovered(.tagTap)` | A tag tap in the inbox outside the tutorial no longer counts towards part 1. The person is offered part 1 again |
| `MessageDetailView.executeTaggedAction` records `discovered(.tagTap)` | The same, for a tag tap in the message view |
| `DynamicIslandChat.sendMessage` (inbox chat) records `discovered(.inboxChat)` | An inbox chat outside the tutorial no longer counts as part 3. The person is offered part 3 again |
| `ComposeView.suggestionBubble(text:)`: Use Suggestion asks `TutorialCoordinator.admits(.useSuggestion, …)` before `acceptVisibleSuggestionIfOffered()` | During part 2, Use Suggestion works before the scripted edit, so the person can send the reply without the edit step. The reply still goes only to the demo account |
| `DynamicIslandChat.sendTutorialEdit` runs `runPracticeReplyEdit` and passes the edited reply to `onDraftUpdate` (`ComposeView.applyInlineEdit`) | The scripted edit does not reach the practice draft: part 2 waits at the edit, or the unedited reply is offered. The person taps Skip |
| `TutorialMessageHost.body(content:)`: the message view's task calls `TutorialCoordinator.messageOpened(accountId:messageId:)` | Opening Jordan's flight email no longer finishes part 3: the card keeps asking for it and the person taps Skip |

## What is tested

- The decisions behind each hook, at the coordinator and service: `TutorialChatScript.response(for:invocation:model:)`
  answers a tutorial prompt from the script and never calls the model, and a typed turn does
  (`TutorialPracticeTests`); `AccountManager.queueSend(holdsForUndo: false)` queues with no hold and
  drains at once, online and offline (`TutorialLifecycleTests`); `TutorialCoordinator.discovered(_:)`
  and `TutorialProgress.markDiscovered(_:)` complete a part once all of its moves are found, and ignore
  them while the tutorial runs (`TutorialProgressTests`, `TutorialLifecycleTests`). The re-tag discovery
  is recorded in the view models and is tested there (`InboxGestureActionTests`,
  `MessageDetailViewModelMoveTests`). For the c4 hooks: `TutorialCoordinator.allows(.useSuggestion, …)`
  admits Use Suggestion only on the practice reply once its edit ran; `runPracticeReplyEdit` applies the
  scripted reply and unlocks it; `messageOpened` completes part 3 only for Jordan's email during the
  flight step (`TutorialLifecycleTests`; the gesture table in `TutorialCoachContentTests`).
- The flows run end to end in a local UI walkthrough of all three parts, kept outside the repository
  and run on each smoke-test round. It covers the scripted answer and the practice send. It does not
  cover the found-on-their-own hooks, which only count outside the tutorial.

## Why it is accepted

Codex review round c2 (2026-10-26) proved each gap with a surviving mutation (C2-M01 to C2-M05). The
only test that kills those mutations is a UI test. The owner chose to accept the gap rather than
commit a UI test or move the hooks out of the views (2026-10-26). Codex review round c4 (2026-10-26)
found three more hooks of the same kind (surviving mutations C4-M07, C4-M13 and C4-M12); the owner
extended this acceptance to them rather than add hosted-view tests (2026-10-26). If a hook is lost, the result is a
recoverable product defect: a part is taught again, a send is delayed, part 2's edit step is skipped
or stalls, or part 3 shows an error or does not finish and the person taps Skip. Nothing is lost and no real mail is touched.

## Reopening

Reopen when a committed UI test target for the tutorial exists, or when one of these hooks is
reported broken.
