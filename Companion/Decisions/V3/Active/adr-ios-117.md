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
   emptied, sent, started dictating) is newer, stays, and is what is written. A read that fails changes
   nothing and writes nothing, so the stored words stay and the next pill to show the chat reads them
   again (a failed read never becomes "no words", which would delete them). The read runs on its own task,
   so a pill left with Back while it runs does not end it; only the chat's current read lands, so a demo's
   exit makes its reads obsolete.
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
and another account never show them, a new store after a restart, two pills on one chat, a failed or left
read, an emptying before the read lands, a pill moving between chats while reads are held, the email
screen's pill and the inbox control, a demo's words through `DemoModeService.exit`, a chat opened from the Search sheet over the sheet's dismissal), `ChatFieldWordsTests`
(store restart, keying, clearing on send and on an emptied field, every newer intention against a held
read, a late read, a failed read, reads landing only on their own chat, writes during a write and a failed
write, a removed account's or ended demo's words never handed to a write again, no words in failure logs, purge with the thread's AI data per account and for a threadless email,
account removal, demo wipe).
