## An email's TabMail chat is its thread's (2026-11-16)

**What:** the Chat pill's history for an email is stored and read per THREAD, not per email
(ADR-IOS-114 decision 14).

- Key: `thread:<accountId>:<threadId>` (`ChatThreadKey.key(for:)`), threadId = `computedThreadId`, or
  the header id when it is empty; `demo:` prefix while a demo runs (`DemoModeStore.scopedSessionId`).
  The in-process `ChatPillState.session(for:)`, `ActiveAgentTracker` working keys, the inbox row's
  agent glow and the agent toast all use the bare key. `ChatThreadKey.parse` reads a key back
  (split at the first colon after the prefix: account ids hold no colon, thread ids may).
- Context: every request names the thread's NEWEST email (`MessageDetailViewModel.chatNewest` on the
  email screen, `ChatThread.newest` in the chat view); writes go to that email's current key. A request
  running when a newer email lands keeps its context; nothing special is done.
  *Changed 2026-11-16:* only the chat view uses the newest email. The email screen's pill is about
  the OPEN email, as before the thread chat (`chatContextMessage ?? message`); `chatNewest` is
  deleted. Its turns still go under that email's current thread key, so the thread stays one chat.
- Reader: `ThreadChatReader` is the ONE place that builds both what the pill shows (`messages(keys:)`)
  and the model history (`history(keys:)`). Its keys (`keys(about:)`, was `keys(newest:)`) are the chat's email's own key
  first, then every other key among the thread's members (`ThreadDetection.related`, all accounts,
  copies included). Turns merge by time; each session keeps its own live card; the budget is
  `ChatStore.maxExchanges` / `charsPerExchange`, newest first. Never send `sessionTurns` alone for an
  email's chat: it misses the thread's other keys.
- `ChatPillState.Session.loadStoredTurns(sessionId:)` loads a key's stored turns once per session
  (a shared Task), prepending turns the session does not hold yet.
- Pills: `ChatIdTranslator` is global and remapped on moves, so `[Email](N)` from any merged session
  resolves; no per-chat remap.
- Eviction: `ChatStore.evictMessageDetailSessions` walks `thread:%` sessions and exempts a thread with
  any Inbox email of its account (`isThreadInInbox`, `ChatThreadKey.memberSQL`).
  `inboxSessionScopeSQL` keeps `thread:` and leftover `msg:` keys out of the inbox list.
- Migration `v107_rekeyChatSessionsByThread` moved `msg:`/`demo:msg:` rows of both `chatTurn` and
  `chatHistory`; rows whose email was not on the device keep their `msg:` key; thread eviction counts
  and clears those leftovers as chats with no Inbox email, as before. Memory index rows keep their old `sessionId` text; their
  turn ids are unchanged.
- Trap, fenced (2026-11-16): a chat is keyed by `computedThreadId`, so rewriting it on an existing
  row strands that thread's chat. The only such write is the fragment merge
  (`ThreadUtils.runFragmentMergeOnce`), run only by `v54`, before `v107` made thread keys, so nothing
  moves chats. `ThreadIdWriteFenceTests` fails any other caller of the merge (anything but a
  migration before v107) and any other write of `computedThreadId` to an existing row; a new one
  must move the thread chats to their new key in the same change.
