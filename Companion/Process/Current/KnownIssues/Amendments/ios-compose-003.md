# IOS-COMPOSE-003 — a subject that is literally shaped like an encoded-word is sent unencoded and decoded by the recipient

**Class:** `open` · **Opened:** 2026-08-12 · **Attribution:** **pre-existing** — not introduced by
`1d28552c1`. The previous non-ASCII-only trigger reached the same code with the same outcome.
**Registered, not fixed** — cosmetic, recoverable, and not minimal to fix; half the remedy is upstream.
Classed `open` rather than `accepted` because it is a conformance defect to be closed eventually, not a
deliberate limitation.

## What is wrong

RFC 2047 §5 says an encoded-word is recognised **anywhere** in an unstructured field body. So a
subject the user typed *as literal text* that happens to spell valid encoded-word syntax —
`Re: =?UTF-8?B?SGVsbG8=?= explained` — must be protected before it is emitted, or the recipient
decodes it and shows text the sender never wrote (here, `Re: Hello explained`).

**All three encoders on the outbound path let it through unchanged**, because each triggers only on
content the header cannot carry, and such a subject is pure printable ASCII:

| encoder | trigger | verdict on an encoded-word-shaped ASCII subject |
|---|---|---|
| `RFC2047.encodeHeaderValue` (Gmail builders) | non-ASCII **or** a C0/C1/DEL control | returned unchanged |
| `RFC2047.encodeIfNotEmittableLiterally` (IMAP/SMTP boundary) | a C0/C1/DEL control only | returned unchanged |
| SwiftMail `String.rfc2047EncodedHeader()` | `!$0.isASCII` | returned unchanged |

The conformant remedy is to encode the whole value whenever it contains the literal sequence `=?`,
so the encoded-word carries the user's text and the recipient reassembles exactly what was typed.

## Blast radius

**Display fidelity of one header, in the recipient's client.** It cannot forge a header field, add a
recipient, or change the message structure — none of that is reachable without a control character,
and the control half is already closed on every path (that was `1d28552c1`'s fix). The reverse
direction is symmetric and already handled: our own reader, `RFC5322Parse.decodeRFC2047`, is exactly
the "receiving decoder" that interprets such a subject, so TabMail-to-TabMail shows the effect too.

Worst realistic case: a subject renders as something other than what the sender typed, and a reply
carries the decoded text onward. The sender's original text is not destroyed anywhere durable — it is
in the sender's own Sent copy verbatim.

## Why it is registered rather than fixed

Owner directive, 2026-08-12: *"these fixes … should really be security fixes, minimal — and if it's
not minimal, it's OK to have it into known issues."* This is not a security fix and it is not minimal:
widening the trigger to `=?` changes the wire bytes of every ordinary subject that contains that
sequence, on every provider, and the same widening is needed **inside SwiftMail** for the IMAP/SMTP
path — an upstream PR, not a fork edit (`IOS-IMAP-016`).

## When revisited

1. Widen both `RFC2047` triggers to *"non-ASCII, or a forbidden literal, **or the literal sequence
   `=?`**"*, and mirror it in the upstream SwiftMail PR.
2. Red-first test: a literal `Re: =?UTF-8?B?SGVsbG8=?= explained` must survive
   `encode → RFC5322Parse.decodeRFC2047` **byte-identically**. Assert the round-trip, not that the
   encoder was called.
3. Non-vacuity twin: an ordinary ASCII subject with no `=?` must still be emitted unchanged, so the
   widening does not start Base64-ing all outbound mail.
4. Note that this and the 75-octet ceiling (`IOS-IMAP-016`) share one function on both sides; if both
   are taken, take them in the same PR.

## Related

- `IOS-IMAP-016` — the SwiftMail half of the same encoder, which also carries the 75-octet
  encoded-word ceiling defect.
- `IOS-COMPOSE-002` — the other open outbound-conformance cost (MIME parameter quoting).
- `1d28552c1` — the fix that closed the control-character half of this encoder's trigger.
