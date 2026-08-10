# IOS-IMAP-010

> Routed from `KNOWN_ISSUES.md` line 104 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `a1b2467088290c42a9005960da8ecfd5bd37d8fff3c71ad35716c6d8bcc18a7a`

## Status

📋 **ACCEPTED LIMITATION (2026-08-05)** — registered under THE MANTRA; recoverable, zero wire mutation, **do not build a mechanism for it**

## Subsystem and search terms

IMAP; `IMAPProvider.mailboxConfirmedAbsent`; `server.listMailboxes(wildcard:)`; SwiftMail `Namespace.listingPatterns(for:)`; namespace prefix; `INBOX.`; exact-name existence probe; destination absent; `IMAPActionMailboxAbsent`; whole-op no-op; `IMAPProvider.move` destination SELECT

## Full detail

**What this row registers.** `mailboxConfirmedAbsent(_:server:)` decides whether a failed destination SELECT means *"this mailbox does not exist"* by issuing `server.listMailboxes(wildcard: folder)` and testing `!mailboxes.contains { $0.name == folder }`. That is an EXACT-NAME test against a listing whose patterns SwiftMail builds through `Namespace.listingPatterns(for:)`, which **namespace-prefixes them** — so on a server with a personal namespace of `INBOX.`, the probe for `INBOX.Archive` can go out as `INBOX.` + `INBOX.Archive`. **Why it is accepted rather than fixed: (a)** SwiftMail falls back to the literal, unprefixed pattern when the prefixed ones return nothing, and the app builds its own folder list through the same namespace-aware call, so the paths the app stores and the paths it probes are consistent **by construction**; **(b)** the cost if it ever did fire is **zero wire mutation** — this probe runs BEFORE any source mutation (`IMAPProvider.move` probes the destination first, deliberately, so a missing destination costs the source nothing), so the worst case is that the op retires as `IMAPActionMailboxAbsent` having touched nothing, the message stays exactly where it is, and sync plus one ordinary user gesture recovers it. Recoverable ⇒ fail closed and let it be. **Re-raise rule:** only with evidence that a real server's listing consistency actually broke — a wrong-namespace probe that produced a WIRE MUTATION, or a folder path the app stored through a path other than the namespace-aware listing. A theoretical prefix mismatch is this row, not a new finding. Found by round-5 Angle 2.
