# IOS-DRAFT-025

- Register classification: `accepted`
- New post-freeze record (2026-10-24) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-10-24, owner, #309).** GitHub [#311](https://github.com/TabMail/tabmail-ios/issues/311) (P5).
Proposed during the #309 fix; the owner accepted it: no ADR-IOS-030 hold during the draft's
server read; if an agent-made compose takes the screen in that window, the draft does not open
and the user taps it again.

## The behaviour

Since #309 a saved draft opens prepared: `DraftOpenPreparation.prepare` resolves the row, runs the
ADR-IOS-091 reload (`ExternalDraftAdoption.refreshBeforeOpen`, capped by
`ExternalDraftOpenConfig.reloadTimeoutSeconds`) and reads the draft while the list stays on screen
with a busy mark (`DraftOpeningMark`). Only then does `DraftComposePresenter` appear, and its
`onAppear` begins the ADR-IOS-030 compose presentation. No hold is taken during preparation,
because holding it for the whole read could stall the agent compose queue.

If an agent-made compose is presented while the preparation runs, it takes the full-screen cover
and the prepared draft is not shown.

Recovery: one ordinary gesture. Nothing is written or lost; the draft stays in Drafts and a second
tap opens it.

## Subsystem and search terms

`DraftOpenPreparation`; `PreparedDraftOpen`; `InboxView.openDraft`; `ComposeToolbarButton`;
`DraftComposePresenter`; `composePresentationDidBegin`; ADR-IOS-030; ADR-IOS-091; agent compose;
busy row mark; draft open dropped

## Related

`ADR-IOS-091` (amendment "Drafts open prepared, with no blank frame"); `ADR-IOS-030`.
