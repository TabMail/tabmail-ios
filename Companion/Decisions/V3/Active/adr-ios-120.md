## ADR-IOS-120: Every Address Field Is Read Whole by SwiftMail's Parser

**Status:** Active (2026-11-25). Amends memory 053's note that Gmail leaves From/To/Cc names
undecoded.

**Context:** IMAP stores the sender and recipients from SwiftMail's structured entries
(`MessageInfo.fromAddresses` and the others), and every reader of a stored address field (reply,
reply-all, the summary's Cc status, names, Copy Address) reads it with SwiftMail's `AddressParser`
(#214). Gmail (`GmailParse.parseMessage`, sync and the notification extension) and raw RFC 5322
headers (`RFC5322Parse.buildMetadata`) used the app's own code instead: `EmailAddress.parse` took
the text between the first `<` and the next `>` as the address and the text before it as the name,
two private `splitAddressList` copies split a list at every comma outside a `"` toggle, and
`RFC5322Parse` decoded encoded-words before either ran. A display name can hold any text, `<`, `>`,
`,`, `"` and `@` included, quoted, in a comment or inside an encoded-word, so part of a name could be
read as the sender's address, or split off as a recipient.

**Decision:**
1. **One parser.** Every address field the app reads goes through SwiftMail's
   `AddressParser.parseAddressList` on the field's raw value: Gmail and raw headers call it, IMAP
   gets its entries from SwiftMail. It reads the structure first (quoted-strings with quoted-pairs,
   nested comments, angle-addrs, list commas outside all of these), decodes an encoded-word only
   as a whole display-name word after that (literal inside a quoted-string, RFC 2047 §5), and
   returns malformed text as `.invalid` text, never guessing an address out of it.
2. **One sender rule.** `EmailAddress.sender(of:)` (moved from `IMAPFetchMapping.sender(from:)`,
   unchanged): the first mailbox of the From field, a group by its first member, by display name or
   its address when it has none; no mailbox = the field's text with no address; no From = nil.
   `EmailAddress.mailboxes(of:)` lists a field's mailboxes, groups by their members.
3. **No address code of our own.** `EmailAddress.parse`, both `splitAddressList` copies and
   `GmailProvider.parseFromHeader` (tests only) are deleted. `RFC5322Parse` decodes only the Subject.

**Consequences:**
- A Gmail sender is stored as an IMAP sender already is: encoded names decoded; a comment is not
  part of the name (`Team (Engineering) <eng@example.com>` is `Team`); addresses in canonical form
  (`"john"@example.com` is `john@example.com`); text that is not one mailbox (two angle-addrs, a
  stray `<` or `>` before the address, `MAILER-DAEMON`) is stored as a name with no address; a From
  naming several mailboxes is listed under the first, so `Doe, John <john@example.com>` is `John`.
  Rows stored earlier change on the next full sync, which refreshes from/to/cc/bcc/replyTo.
- Gmail's stored To/Cc/Bcc/Reply-To stay the raw header text and are read back by the same parser.
- Whether the Gmail API hands header values decoded is not documented (memory 053); the parser
  reads the value Gmail returns.
- **Thunderbird parity note** (ADR-IOS-008 makes Thunderbird the reference; TB ADR-033 has
  Thunderbird read every address with its own parser, JSMime). These differences are intended:
  - A comment before an angle-addr is part of Thunderbird's display name (`Team (Engineering)`);
    here it is syntax (`Team`).
  - With several angle-addrs outside quotes (`Name <a@example.com> <b@example.net>`), Thunderbird
    takes the last as the address; here the text names no address, because no part of malformed
    text is guessed to be one.
  - Thunderbird keeps a local-part as written (`taro.@example.org`); SwiftMail quotes it
    (`"taro."@example.org`).
  - For `Doe, John <john@example.com>` Thunderbird's first entry is `Doe` with no address; here the
    sender is the first mailbox, `John`.
  Neither parser reads text inside a well-formed name as an address.
