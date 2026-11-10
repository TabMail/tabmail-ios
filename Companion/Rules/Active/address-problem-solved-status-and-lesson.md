### The address problem: solved status (copyProvenSourceUIDs, MessageHeaderRekey.finishMove, undoMove) and the granularity lesson

Routed out of `CLAUDE.md` by the `companion-compact` skill (2026-11-10). A short form stays inline in `CLAUDE.md`; below is the original text, byte-for-byte (sha256 of the block: `c926743f905439026619a0541be03f13c068b25a0ae001f25fde629cf21f4e39`).

<!-- preserved-block-begin -->
**The problem itself is fixed — do not re-derive it, and do not design around it as if it were still
open.** `copyProvenSourceUIDs` now returns `destinationProviderId` / `destinationUidValidity`, and
`MessageHeaderRekey.finishMove` re-keys the row to the destination UID and epoch at drain time from
the `COPYUID` already in hand. Undo is an ordinary reverse move (`AccountManager.undoMove`), not a
rollback and not a Message-ID `SEARCH`; the two surviving `searchByMessageId` callers (`currentUIDs`,
`appendToSentFolder`) are both **non-mutating**, so the banned D4 direction — a SEARCH selecting a
mutation target (ADR-IOS-068, `IOS-IMAP-002`) — no longer exists in the tree.

**The lesson worth keeping:** four audit rounds argued about *which evidence retires an operation*
when the real defect was decision **granularity** — the wire had already proved the destination
address and the code threw it away. Before designing a receipt, alias table, two-door identity scheme
or outcome enum, ask first whether the wire already handed you the answer.
<!-- preserved-block-end -->
