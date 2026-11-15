# Outlook records a reply / reply-all / forward on the ORIGINAL through two last-verb properties (#915)

**Measured (#890 live table, row 4):** a reply sent through Graph `POST /me/sendMail` leaves the
original untouched: no `Integer 0x1081`, no `SystemTime 0x1082`, `lastModifiedDateTime` and
`changeKey` unchanged, nothing in the Inbox delta. A reply from Outlook on the web sets
`0x1081 = 102` on the original. So `sendMail` (TabMail's send path, ADR-IOS-043 threading via
`String 0x1042`/`0x1039`) never marks the original replied or forwarded; the app must write it.

**The properties (MS-OXOMSG):**
- `Integer 0x1081` = `PidTagLastVerbExecuted`: **102** reply to sender, **103** reply all, **104** forward.
  Outlook stores only the LAST verb (a reply after a forward reads back as 102).
- `SystemTime 0x1082` = `PidTagLastVerbExecutionTime`: when the verb ran ("You replied on ...").
- `Integer 0x1080` = `PidTagIconIndex` (0x105 replied, 0x106 forwarded): not written; add only if a
  live check shows an Outlook client needs it for the arrow.

**How TabMail writes them (option B, #915):** the existing durable `.markReplied` / `.markForwarded`
op, admitted only in `AccountManager.deleteCompletedSendAtomic` after the send is confirmed, reaches
`ExchangeProvider.performMessageAction`, which PATCHes `/me/messages/{id}` with
`singleValueExtendedProperties` `[0x1081, 0x1082]` (`ExchangeProvider.lastVerbPatchBody`, using the
one shared definition in `Shared/API/GraphAPI.swift`: `lastVerbPropertyId`, `lastVerbTimePropertyId`,
`lastVerbReplyToSender/ReplyToAll/Forward`, which #890's change reader also reads) through
`patchEachMessage`. Absolute values, so a retry is idempotent and can never
re-send mail. The send time is `OutboxMessage.sentAt`, carried on `PendingOperation.sentAt` (v104;
pre-v104 rows use `createdAt`, stamped in the completion transaction: `PendingOperation.verbTime`).
Reply-all is a generic kind from compose to the op: `ComposeView.isReplyAll` (set by the Reply All
entries) → `Draft.isReplyAll` (every draft writer, Save, Send and each agent autosave, stores the open compose's entry kind, so under the shared `reply:` key the latest entry decides; kept on the Undo-Send reopen, like `isForward`,
`IOS-OUTBOX-004`) → `OutboxMessage.isReplyAll` → `PendingOperation.replyAll` →
`ProviderMessageAction.replied(all:at:)`. IMAP maps reply-all to `\Answered` like reply; Gmail has
no remote representation. The tags stay in `GraphAPI.swift` and `ExchangeProvider*` (ADR-IOS-060 boundary;
fenced over `TabMail/` and `Shared/` by `ExchangeLastVerbMarkTests.lastVerbTagsStayInsideExchangeProvider`).

**Original moved:** an in-app move re-addresses queued followers (`MessageHeaderRekey`
`readdressQueuedOperations`) and re-keys the header, so reply-then-archive inside TabMail marks the
moved message. A move made elsewhere before the mark drains leaves a stale Graph id → 404 →
authoritative no-op (the mark is lost on Outlook; local `isReplied` stays). Registered as
`IOS-GRAPH-006` (accepted, 2026-11-15). Resolving it by `internetMessageId` was proposed and
REJECTED by ruling: ADR-IOS-068 D4 stays (no search result is a mutation target). Do not re-propose
it; Graph immutable ids (#117) are the structural fix.

Not yet measured live: whether Outlook on the web / mobile render the arrow from a client-written
0x1081 (row B1 of the #915 design's live check).

The AI reply tool (`EmailReplyTool`) builds the reply-all recipient set, so its
`AgentToolRouter.ComposeRequest.isReplyAll` records reply-all (103) like the Reply All button. A refused
mark leaves the queue only through the ordinary exit-5 counted-failure limit, like every other action.

Tests: `EmailReplyToolTests.requestIsReplyAll`, `AgentAutoSaveRecipientsTests.laterAutosaveFollowsTheCompose`, `OutlookChangeReadingTests.appReplyMarkIsWrittenAndReadBack`, `ExchangeLastVerbMarkTests`, `ProviderMessageActionTests.graphCommandsPreserveNativeIdentityAndDestination`,
`ComposeSendReplyTargetTests.replyAllReopenedThroughUndoIsResentAsReplyAll`,
`NeverDropExitClosureTests.completedReplyAllAnswersItsParentOnTheServer`.
