## ADR-IOS-117: A Chat's Unsent Words Are Kept on This iPhone, Keyed by the Thread's Chat

**Status:** Active (2026-11-18, iOS #979). Built on the chat-view train (ADR-IOS-114). The owner chose A
on the board question cv-unsent-words: unsent words are kept like Messages keeps them, also after the app
was closed. The coordinator ruled the storage (2026-11-18): a local on-device store keyed by the thread's
chat key, not a mail draft.

**Context:** The words typed in a pill's field lived only in the view's own state (`@State fieldFill`,
`ChatFieldFill`). Close kept them because the view stayed alive; Back tore the screen down and the words
were lost, in the chat view and on the email screen alike. Messages and WhatsApp keep unsent words in that
chat's field, also after the app is closed.

**Decision:**
1. **One owner per chat, `ChatFieldWords`** (`TabMail/Services/AI/ChatFieldWords.swift`), for every pill
   that is about an email: the chat view's reply field and the email screen's Chat pill. The store holds
   each chat's ONE `ChatFieldFill` (`fill(for:)`); every pill on the chat reads it and changes it through
   `apply(_:to:)` (the pill's `fieldFill` handle, `ChatFieldWords.Field`), so two pills mounted on one chat
   (the chat view's field under the email card's pill) never hold two drafts. The store is `@Observable`,
   so every mounted pill shows a change at once. The inbox's own chat (about no email) and a compose's edit
   pill keep their own fill and nothing is kept: they have no thread, and a compose keeps its own draft.
   (Review r1, 2026-11-18: the first build kept a per-view copy that went stale under a second pill.)
2. **Keyed by the thread's chat key, the one the chat history uses** (`ChatFieldWords.key(for:)` =
   `DemoModeStore.scopedSessionId(ChatThreadKey.key(for:))`, `thread:<accountId>:<threadId>`, `demo:` while
   a demo runs). No second identity scheme: a newer email in the thread has the same key, so it never drops
   the words, and another thread or another account's copy of the thread has another key, so its field
   never shows them. A pill whose email moves to another chat changes that chat's fill from the moment its
   key changes; nothing typed on it can land in the earlier chat.
3. **What is kept:** the field's words that have not been sent (`ChatFieldFill.unsent`). A send takes them
   out at once (the words of a send in flight are not kept), and an emptied field removes the row.
   **Reading them back (`load`):** a chat's stored words are read once per app run, as a pill shows the
   chat, and land only if nothing changed the chat in this run: whatever the user did first (typed,
   emptied, sent, started dictating) is newer, stays, and is what is written. A cloud dictation counts
   from its transcript, not its start, so one started in the milliseconds before the read lands adds
   to the restored words (ios#1225, P4: rare; the user's own words, shown before any Send). A read that fails changes
   nothing and writes nothing, so the stored words stay and the next pill to show the chat reads them
   again (a failed read never becomes "no words", which would delete them). The read runs on its own task,
   so a pill left with Back while it runs does not end it; only the chat's current read lands, so a demo's
   exit makes its reads obsolete.
4. **On this iPhone only.** Table `chatFieldWords` (`sessionId` primary key, `words`, `updatedAt`), migration
   `v109_addChatFieldWords` (v108 is taken in the same train by `v108_addReplyChangeCommand`). Never
   synced, never sent anywhere by the store (no request reads the table), never indexed for
   search or memory, never logged (a failed write logs only the error's type, behind the debug gate).
   Once shown, the words are the field's words like typed ones: a request the user starts reads them as
   it reads typed words, their Send, and a dictation into the field, whose cleanup context is the
   field's text (`DynamicIslandChat.dictationContext`) (2026-11-22: the user's own words on screen, in a
   request the user starts; not a store leak). A dictation that starts by itself (Auto-Enable
   Dictation, which the user turned on, as a pill opens or after an answer) is the user's dictation
   into the field too and reads the field's text the same way, restored words included (2026-11-22,
   later: no request reads the stored words apart from what the field shows). The table is part of the app's database, which the
   device's own backup carries like the rest of it (the chat history, the Outbox, drafts): "on this
   iPhone only" means the app never syncs or sends the words, not that they are kept out of the
   user's own device backup (2026-11-22, later).
   Within the app run the store's memory is the source the field reads; writes go behind it in order, the
   newest words of a key winning, so Back and an immediate reopen never race the disk.
5. **Lifetime: the thread's AI data rule.** A thread's words stay while any email of that thread (its
   account, its thread id: `ChatThreadKey.memberSQL`) is on the device. A row whose thread no
   maintenance pass has seen with an email for `SyncConfig.aiCacheOrphanGraceDays` is deleted; every pass
   first re-stamps the rows whose thread still has an email (`ChatFieldWords.restampLive`, one row at a
   time as the AI cache re-stamps its kept entries, so no statement binds more than one key and no
   number of rows meets SQLite's bound-variable limit; 2026-11-22, later), so emails briefly gone (a UIDVALIDITY resync re-walking, a
   move between folders) never cost the words. Every transaction that deletes emails for a resync
   runs the same re-stamp before the headers go: Delete All Email Index Data
   (`SettingsView.localIndexWipeTxn`, 2026-11-22), an account's Reset Message Data
   (`AccountDetailView.resetMessageDataTxn`) and a folder's UIDVALIDITY purge
   (`AccountManager.uidValidityResetPurgeTxn`) (both 2026-11-22, later), so the grace for the
   resync counts from the reset, however long ago the last pass ran. The purge runs in the same maintenance
   pass that purges orphaned AI results (`SyncEngine.runPurgeOrphanedChatFieldWords`, next to
   `runPurgeOrphanedAICache`). Removing an account deletes its rows in the account's row-delete transaction
   (`AccountManager.removeAccountRowsTxn`), with its AI cache. A demo's rows go with the demo's chat
   (`DemoSeed.wipe`).

**Review r1 (2026-11-20):** words a failed write left unsaved are written by the one writer at the
next save point: a change, the app going to the background, a pill showing a chat (no timer, no retry
count). A read checks the chat's demo admission and account removal as it starts and again before it
lands, so a read started during a demo's exit never fills the next demo's field.

**Review r7 (2026-11-20): one fence inside the write, not a removal lifecycle.** The words' write
transaction itself checks that the key's account row still exists (`EXISTS(SELECT 1 FROM account WHERE
id = ?)`, `ChatFieldWords.Storage.admits`) beside the demo run's admission (`DemoModeStore.admits`), as
`AccountFieldPersistenceStore.persist` guards account writes. The account's removal deletes its row and
its words in ONE transaction (`removeAccountRowsTxn`; `DemoSeed.wipe` for the demo), so a write lands
before it and is deleted by it, or runs after it and is refused and dropped; a removal that rolls back
leaves the row, so the write lands. Overlapping removals, the gap before the store hears of the commit,
and the demo's fixed account seeded anew need no extra state. Replaced: the per-attempt removal holds
(`Lifetimes`, `beginRemoval`/`commitRemoval`/`rollBackRemoval`/`reopenAccount`) and the re-queue of
refused words. After the commit the store only forgets the account's words in memory and takes no new
ones for it (`forgetAccount`; a real account id is never reused, the demo's chats are fenced by admission).

**Why not a mail draft:** the field's words are an instruction to the agent ("tell her Tuesday works",
"decline politely"), not an email body. Saved as a draft they would sit in the user's Drafts folder on the
mail server, synced to every client, as a message nobody wrote, and Q22 (the chat ignores drafts) would
need an exception. The compose card keeps its own drafts as before.

**Why this is not new retention of email content (ADR-004):** nothing leaves the iPhone. ADR-004 governs
what TabMail's servers keep; this table holds only the user's own unsent words on the device, next to the
chat history the same key already keeps, and goes with that thread's AI data and with the account.

**Consequences:**
- ios-978 (a new email started as a chat) reuses this store for its field's words.
- A thread whose key changes (a `computedThreadId` rewrite, fenced by `ThreadIdWriteFenceTests`) strands
  its words as it strands its chat; the purge deletes them once the old key has no email.
- Words typed in a field whose send is still in flight are not kept until the send completes; a send
  that then fails keeps its own retry in the chat.
- A cut-off field request whose sent words are still in the field, unedited (`ChatFieldFill.holdsSentWords`), shows the field's Retry (`chatRetry`) in Send's place only when the cut-off request is the field's own request (its recovery carries the field's words key); it resumes that request with no new user turn. Another request's cut-off (a sheet re-send) leaves the held words on Send. Any edit turns it back into Send, which sends the new words.
- A reply compose card that opened for the field's send and closed unsent (2026-11-20 ruling, review r7
  N1): the agent's answer, which comes once the card is done, empties nothing and hands the words back
  to the user (`ChatFieldFill.apply(.answered)` clears `atSend`, `holdsSentWords` and `composing`), so
  they are kept like typed words and show again after a relaunch. Before, they showed for the run but
  were never kept. The field's own reply card is a reply to the email the field showed, any copy of it
  in any account (`ChatFieldReply.isOwnReply`, amended 2026-11-22), the card of an edit of its AI
  Suggestion included; it is decided apart from the audience, which applies only in the same account
  (`audienceApplies`). A compose or forward card, or a reply to another email, is not the field's own:
  its answer empties the sent words. A confirmation card the same request raises once the field's own
  card opened empties nothing either (`apply(.confirmationCard)` checks `composing` as the answer does,
  2026-11-22): the card owns the completion, so the words a closed card hands back are never lost to a
  confirmation for another step of the request. A confirmation card that comes BEFORE the field's own
  card opened takes the sent words off the field (the request shows in the sheet) but they stay the
  send's (`ChatFieldFill.sentWordsTaken`, until any edit of the words or the send's end): if the own card
  then closes unsent, the answer hands them back as it does when they stayed on the field (2026-11-22,
  later). An edit since then is the user's, and nothing comes back over it.
- A request that opens several cards (a reply and a forward, say): any card's Send completes the
  field's send (`enqueueComposeAndAwaitOutcome` applies `.completed` for every sent card carrying the
  field key), also after the field's own reply card closed unsent. Part of what the words asked for
  went out; handed back, the same words sent again would send that part a second time (2026-11-22,
  later).
- A chat's words the orphan pass deletes stay in the running app's memory if it read them earlier, and
  show again if the thread comes back in that run (ios#1222, P5: rare and harmless, the user's own words
  on their own chat).
- Settings' "Delete All Email Index Data" (`SettingsView.localIndexWipeStatements`) keeps the unsent field
  words (2026-11-20, review r7 R1): its alert promises unsent drafts are kept, and the words live while
  the thread's emails are on the device, so after the resync each thread's unsent words show again even
  though its chat history is gone. Deliberate; not a leftover. The wipe re-stamps them first (decision 5).
- A field send's transitions (confirmation card, the agent's answer, a compose card opening, its reply
  going out) are applied by the request lifecycle to the chat key captured at send
  (`ToolInvocation.fieldWordsKey`, `SessionUISink.fieldWordsKey`,
  `AgentToolRouter.enqueueComposeAndAwaitOutcome(fieldWordsKey:)`), never by a view to the chat it
  shows then. Reason (review 2026-11-20): applied on the displayed key, an earlier request's card
  emptied and deleted ANOTHER chat's unsent words after the pill moved; delivered through a view
  counter, an answer after Back never reached the store and the sent words came back on reopen. The
  view counter (`ChatReplyField.clearCount`) is gone; the view keeps only presentation (sheet rising).

**Tests:** `ChatFieldWordsRuntimeTests` (Back and reopen, the newer email of the thread, another thread
and another account never show them, a new store after a restart, two pills on one chat, a failed or left
read, an emptying before the read lands, a pill moving between chats while reads are held, the email
screen's pill and the inbox control, a demo's words through `DemoModeService.exit`, a chat opened from the Search sheet over the sheet's dismissal, an earlier request's card and answer after the pill moved to another chat, an answer after the chat was torn down, newer words typed while the agent works, a closed card then the answer with and without an AI Suggestion shown at Send, the field's own card closed unsent with a confirmation of the same request after it or before it, then the answer; the own card closed unsent then a forward of the same request sent, which completes the send), `ChatReplyRecoveryTests` (`fieldEditCardClosedUnsentKeepsTheWords`: a field edit of the AI Suggestion whose card the agent's real `email_reply` opens, closed unsent, hands the words back, kept and shown again after a relaunch; `resumedFieldRequestCompletesTheFieldWords`: the field's Retry on the unchanged sent words resumes with one stored user turn; `editedFieldWordsSendAnew`: an edit, even to the same text, turns Retry into Send and sends a new request; `newerSendEndsTheRecovery`: Retry on the unchanged words only for a cut-off, Send after a plain failure; `inboxPillWordsAfterCutOffOfferSend`: the inbox pill's own words after a cut-off offer Send; `cutOffRecoveryNamesTheFieldOnlyForItsOwnRequest`: a sheet send's recovery names no field words), `SearchChatWordsUITests` (the real Search route: type, Back, Done, reopen), `ChatFieldWordsTests`
(store restart, keying, clearing on send and on an emptied field, every newer intention against a held
read, a late read, a failed read, a failed read after an edit, reads landing only on their own chat, writes during a write and a failed
write, a removed account's or ended demo's words never handed to a write again, no words in failure logs, purge with the thread's AI data per account and for a threadless email,
a re-stamp inside the grace, every resync (index wipe, Reset Message Data, UIDVALIDITY purge) with a
last pass partway through the grace or none since the words aged keeping live words for the full grace
from the reset and no longer, while an orphan past the grace goes, a re-stamp of more live chats than
the connection's bound-variable limit, account removal, demo wipe), `SyncMaintenanceTests.maintenanceRunsThePurge` (the real
maintenance pass purges an orphan's words and keeps a live thread's),
`FieldReplyCardWordsTests` (the field's own card: the suggestion edit, a copy in another account or
folder; not its own: another email, an older email of the same thread chat), `ChatReplyFieldTests` (a confirmation
card after the field's own card opened; one before it, handing the words back unless edited since), `ChatReplyFieldRuntimeTests.sheetResendsSendWithNoField` (the
sheet's re-sends send with no field, and a send's field key comes from its field alone).
