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
- typing or pasting: a paste (more than one character at once) is split whole. While typing, when
  the input line gains `,`, `;` or a line break, the text up to the last separator is split
  (`ComposeDraftGuards.inputToSplit`, `committing`); the text after it is still being typed and
  is left alone, so `bob, carol@example.c` never adds a half-typed address. Return, leaving the
  field, saving and Send split the whole line;
- a contact pick (`ComposeDraftGuards.picking`): an address TabMail cannot send to replaces the
  typed query in the input line instead of the tap doing nothing;
- prefill (mailto, AI), a reopened draft, reply seeding (`RecipientEntry.reply(to:)`: every
  Reply-To mailbox, or the sender under the sender's name) and AI recipient edits
  (`applyRecipientDelta`);
- reply-all (`buildReplyAllRecipients`) uses the same reply target, and passes its text that names
  no sendable address on to the To input line, as Reply does. Entries of the original To and Cc
  that are not sendable mailboxes are still never offered (owner decision 2026-10-03).

A group contributes its members; an empty group (`undisclosed-recipients:;`) names nobody. An
address already in the field is not repeated (case-insensitive); typing it again moves it to the
end. Addresses past `SyncConfig.outboxMaxRecipients` stay in the input line.

Text that names no sendable address never becomes a recipient. It stays in the field's input line,
visible; a named mailbox kept this way is written with its name quoted
(`IMAPFetchMapping.mailboxText`), so reading the line again never turns part of a display name into
a recipient. Send is refused with `"<text>" in <field> is not an email address. Fix or remove it
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
