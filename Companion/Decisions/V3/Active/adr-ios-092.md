## ADR-IOS-092: Compose Recipient Fields Are Lists of Addresses, Never Free Text

**Status:** Active (2026-10-18)

**Context:** Compose kept each To/Cc/Bcc chip as whatever text the user typed or pasted, and a
chip was made only on Return, a contact pick or leaving the field. One chip could therefore hold
`a@example.com, b@example.com`, a Reply-To list, or text naming no address at all, and every
writer had to re-read it: IMAP send through `IMAPProvider.sendableRecipients` (one mailbox per
chip, otherwise a fatal `invalidEmailAddress`), Gmail's raw RFC 822 writer, Graph's recipient
list, the Drafts APPEND. They disagreed at the edges, so each fix moved the failure to the next
path (the Bcc train's Tier 1 r6 finding: a Gmail reply to a two-mailbox Reply-To failed once Gmail
send ran the same per-chip check as IMAP). The 2026-10-03 rule "drafts keep recipients as typed"
(memory 126, #245/#246) made that free text the stored form. Owner, 2026-10-18: "it should be
separated as list as you type or paste, basically. It should never be a plain text field. That's a
bad decision and probably the cause of all the headaches."

**Decision:** Every way text enters a recipient field goes through ONE splitter,
`RecipientEntry` (`TabMail/Helpers/RecipientEntry.swift`), which reads it with SwiftMail's
address-list parser (the parser every send uses) and keeps each mailbox `isValidEmailAddress`
accepts as its own recipient, with its display name. That parser splits on commas only, so,
outside quotes, angle brackets and comments, a line break, a `;` (other than the one ending a
group), and spaces or tabs after an address (a word holding an unquoted `@`, or a closing `>`) are
read as commas first. People separate addresses with `;`, as Outlook does, or one per line, and a
single-line text field turns a pasted column's line breaks into spaces (observed on iOS 26.5);
`Ann Lee <a@example.com>` and `a@example.com (work)` stay one mailbox:
- typing or pasting: a paste (more than one character inserted at once, over a selection or not;
  the inserted text is what differs between the old and new line once their common start and end
  are set aside, never the change in length) is split whole. While typing, only a
  keystroke that adds `,`, `;` or a line break splits, and then the text up to the last separator
  is split (`ComposeDraftGuards.inputToSplit`, `committing`); the text after it is still being
  typed and is left alone, so `bob, carol@example.c` never adds a half-typed address. A keystroke
  that adds no separator splits nothing, so fixing leftover text where it is (as Send's refusal
  asks) never commits it half-fixed: re-splitting on every keystroke turned `bob, ` +
  `@example.com` into `bob@example.c` and pushed `om` into the next address. Return, leaving the
  field, saving and Send split the whole line;
- a contact pick (`ComposeDraftGuards.picking`): the contact's email text is split like typed
  text (a contact's email value can hold a list), and the contact's name goes with the address only
  when the text names exactly one; text TabMail cannot send to replaces the typed query in the input
  line instead of the tap doing nothing;
- prefill (mailto, AI), a reopened draft, reply seeding (`RecipientEntry.reply(to:)`: every
  Reply-To mailbox, or the sender under the sender's name) and AI recipient edits
  (`ComposeDraftGuards.applying`, applied at once, not after the text fade). An address waiting in
  the input line (over the recipient cap, or typed) is one Send would add, so an AI clear empties
  the input line too and an AI removal also removes the address there, keeping the rest: otherwise
  Send restored a recipient the user had just removed;
- reply-all (`buildReplyAllRecipients`) uses the same reply target, and passes its text that names
  no sendable address on to the To input line, as Reply does. Entries of the original To and Cc
  that are not sendable mailboxes are still never offered (owner decision 2026-10-03).

A group contributes its members. An entry that names nobody (an empty group such as
`undisclosed-recipients:;`, or a lone comment) is kept as text like any other, never dropped. An
address already in the field is not repeated (case-insensitive); typing it again moves it to the
end. Typing, a paste or a contact pick past `SyncConfig.outboxMaxRecipients` leaves the extra
addresses in the input line. Fills (a reopened draft, a prefill, reply-all), AI adds and the
commit on Save, close or Send are not capped; Send then refuses with the cap message.

The compose holds its three fields as one value, `ComposeDraftGuards.Recipients`
(`ComposeRecipients.swift`). Every change by role (typing, a pick, a prefill or reopened draft, an
AI edit) and every read (save, the agent's autosave, Send) goes through it, so the role mapping
that keeps Bcc recipients out of To and Cc is one tested switch instead of view code no test runs.

Text that names no sendable address never becomes a recipient. It stays in the field's input line,
visible, followed by `, ` (`ComposeDraftGuards.inputLine`), so the next address typed or pasted
starts a new entry and is never joined to it (`bob` + `dave@example.com` must never become
`bobdave@example.com`). Contact suggestions match only the entry being typed (`typedEntry`), and a
picked contact replaces only that entry; an entry kept this way is the text as it was written,
never a decoded or rewritten form, so reading the line again never turns it, or part of a display
name, into a recipient. Send is refused with `"<text>" in <field> is not an email address. Fix or remove it
before sending.` (`ComposeDraftGuards.sendRecipients`, which also holds Send's recipient cap). Saving a draft still stores
that text beside the addresses (`committedRecipients`), so nothing typed is lost; reopening puts it
back in the input line. This overrides the 2026-10-03 "drafts keep recipients as typed" rule for
the compose UI: the stored list is addresses plus any leftover text, and the UI shows the
leftover only as editable input, never as a chip.

**Rationale:** The defect class was a recipient with no single meaning. Splitting once, at entry,
with the send path's own parser and validity rule, gives every writer the same list of single
addresses, so the per-chip send check can no longer refuse a chip the user sees as valid, and no
provider re-interprets free text. Validation moves from Send (where the user learns late, or a
queued send fails) to the moment of entry. `IMAPProvider.sendableRecipients` stays as the send
boundary check; it is no longer the first place bad text is caught. It reads each recipient as a
comma-separated list, so a send queued by an earlier version with `a@example.com, b@example.com` in
one recipient still goes to both, on IMAP and Gmail; a recipient holding text that is not a
mailbox is refused as before.

**Consequences:**
- A pasted list, a Reply-To list and an old draft whose single recipient holds a list all become
  separate chips.
- Text such as `bob` or `local@localhost` stays in the input line and blocks Send with a message
  naming it, instead of failing in the Outbox.
- A display-name comma inside an unfinished quote (`"Doe, J`) does not split: the parser reads it
  as no address, so the field is unchanged until the quote closes.
- Thunderbird's compose is its own address widget and is not changed here; ADR-IOS-008 parity
  covers AI processing, not compose entry.
- Tests: `TabMailTests/Views/RecipientEntryTests.swift` pins the property (every recipient a
  field holds is accepted by `sendableRecipients`), splitting (pasted spaces and tabs included),
  replies and reply-all, contact picks, the input line, the cap, the draft round trip and Send;
  `ComposeThrottleTests` pins Send's cap through `sendRecipients`; `BccRecipientsTests` pins a
  queued list recipient.
- The agent's autosave (`DynamicIslandChat.autoSaveDraft`) is a draft writer too: both its first
  save and its updates store the To, Cc and Bcc the compose shows when it writes
  (`composeRecipients`, the same `committedRecipients` lists Save uses), never the To-only context
  the agent's turn began with. Pinned by `AgentAutoSaveRecipientsTests`.

**Amendment (owner, 2026-10-19): split first, then read; never rewrite.** Raw recipient text is
split into entries by `RecipientEntry`'s quote-aware splitter BEFORE anything reads it, and an entry
is never replaced by a decoded or rewritten form. An entry becomes recipients only when everything
in it is a sendable mailbox; otherwise the whole entry, as written, is input-line text and Send
refuses it. Tier 2 found three routes that read or rewrote text before splitting, and a census found
three more; all now follow the order:
- the invalid-entry branch kept the parser's DECODED text (`"extra@example.com"` became
  `extra@example.com`, which the next commit or a save and reopen made a recipient with no edit);
- AI edits (`AIService.parseDeltaForField`) pre-parsed each comma piece by its first `<...>`, so a
  `;`- or space-separated list added or removed only its first mailbox and a removed Bcc recipient
  was sent. `RecipientDelta.adds` is now a `RecipientEntry` of the raw `+Field:` line; removals are
  the raw `-Field:` line's addresses (`*` still clears). `splitNameAndEmail`,
  `splitCommaRespectingQuotes` and `ParsedRecipient` are deleted;
- a contact pick wrapped the contact's name around the whole email value before splitting;
- `MailtoRequest` split every value on commas (breaking `"Doe, John" <...>`); values are now kept
  whole for compose to split (closes tabmail-ios #223);
- the agent reply tool (`EmailReplyTool.applyRecipientDelta`) compared removals as raw strings, so
  `"Bob" <bob@...>` or a list in one string removed nothing; removals are now read with
  `RecipientEntry`;
- an address over the cap went back to the input line as a bare address, losing its name.
Kept as is, failing closed: leftover text with an unclosed quote or `<` can absorb an address typed
after it, but the result is still input-line text that Send refuses. Tests:
`RecipientSplitFirstTests` (raw input to the recipients Send sends, and a captured Gmail request; 9
red on the previous code, 2 positive controls).
