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
1. **One store, `ChatFieldWords`** (`TabMail/Services/AI/ChatFieldWords.swift`), used by every pill that is
   about an email: the chat view's reply field and the email screen's Chat pill. The inbox's own chat
   (about no email) and a compose's edit pill keep nothing: they have no thread, and a compose keeps its
   own draft.
2. **Keyed by the thread's chat key, the one the chat history uses** (`ChatFieldWords.key(for:)` =
   `DemoModeStore.scopedSessionId(ChatThreadKey.key(for:))`, `thread:<accountId>:<threadId>`, `demo:` while
   a demo runs). No second identity scheme: a newer email in the thread has the same key, so it never drops
   the words, and another thread or another account's copy of the thread has another key, so its field
   never shows them. The pill shows the field's words only while they belong to its current key
   (`DynamicIslandChat.wordsOwner`); a pill whose email moves to another thread empties first
   (`ChatFieldFill.Change.otherChat`) and then shows that thread's words.
3. **What is kept:** the field's words that have not been sent (`ChatFieldFill.unsent`). A send takes them
   out at once (the words of a send in flight are not kept), and an emptied field removes the row. Kept
   words come back only into an untouched field (`ChatFieldFill.Change.restore`), so typing during the read
   is never overwritten.
4. **On this iPhone only.** Table `chatFieldWords` (`sessionId` primary key, `words`, `updatedAt`), migration
   `v109_addChatFieldWords` (v108 is taken in the same train by `v108_addReplyChangeCommand`). Never
   synced, never sent anywhere (no request carries it until the user presses Send), never indexed for
   search or memory, never logged (a failed write logs only the error's type, behind the debug gate).
   Within the app run the store's memory is the source the field reads; writes go behind it in order, the
   newest words of a key winning, so Back and an immediate reopen never race the disk.
5. **Lifetime: the thread's AI data rule.** A thread's words stay while any email of that thread (its
   account, its thread id: `ChatThreadKey.memberSQL`) is on the device. A row untouched for
   `SyncConfig.aiCacheOrphanGraceDays` whose thread has no email left is deleted by the same maintenance
   pass that purges orphaned AI results (`SyncEngine.runPurgeOrphanedChatFieldWords`, next to
   `runPurgeOrphanedAICache`). Removing an account deletes its rows in the account's row-delete transaction
   (`AccountManager.removeAccountRowsTxn`), with its AI cache. A demo's rows go with the demo's chat
   (`DemoSeed.wipe`).

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

**Tests:** `ChatFieldWordsRuntimeTests` (Back and reopen, the newer email of the thread, another thread
and another account never show them, a new store after a restart), `ChatFieldWordsTests` (store restart,
keying, clearing on send and on an emptied field, purge with the thread's AI data, account removal, demo
wipe).
