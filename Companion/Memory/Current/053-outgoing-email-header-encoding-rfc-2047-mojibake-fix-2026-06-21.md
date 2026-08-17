<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current note — PR #37:** TabMail's app encoder now owns the complete raw Subject boundary for
> both Gmail builders and `IMAPProvider.buildEmail`; it is deliberately no longer byte-identical to
> SwiftMail's encoder. This supersedes the historical "keep the two byte-for-byte identical"
> instruction retained below. It protects complete substrings consumed by the shipped unanchored
> Gmail/SwiftMail decoders, plus complete SP/HTAB-delimited composer words (including malformed
> `=?=`), while bare/unterminated shapes remain literal. It splits between Unicode scalars and uses
> 39-byte first / 45-byte continuation budgets so encoded-words stay within 75 octets and encoded
> physical Subject lines within 76. SwiftMail's equivalent library defects and
> MIME parameter interpolation remain open upstream work under `IOS-IMAP-016` / issue #10; the fork
> remains deviation-free.
<!-- COMPANION-CURRENT-NOTE-END -->

### Outgoing email header encoding — RFC 2047 (mojibake fix, 2026-06-21)
- **Header fields MUST be 7-bit ASCII.** Non-ASCII Subject/display-name text must be wrapped in an RFC 2047 encoded-word (`=?UTF-8?B?…?=`). Injecting raw 8-bit UTF-8 into a header (the old behavior) lets downstream agents charset-guess and mojibake it (Korean `가` → `ÃªÂ°Â…` = double UTF-8-as-Latin-1). Bodies were never affected — they carry `charset=UTF-8` + Content-Transfer-Encoding; headers have no mechanism except RFC 2047.
- **Encoder lives in TWO places (cannot share — SwiftMail is a remote SPM pin, not a local path):** iOS app `TabMail/Helpers/RFC2047.swift` (`RFC2047.encodeHeaderValue`, used by `GmailProvider.buildRFC822`/`buildMIMEMessage`); SwiftMail fork `String.rfc2047EncodedHeader()` (used by `Email+Content.writeHeaders` Subject + `EmailAddress.headerString()` for From/To/Cc names, + `EMLSerializer`). Keep the two byte-for-byte identical. ≤45 UTF-8 bytes/word (≤75-octet word), split on char boundaries, folded with `CRLF SPACE`.
- **Gmail API decode is UNDOCUMENTED** — the REST reference does not say whether `payload.headers[].value` is RFC 2047-decoded. So `GmailParse.parseMessage` decodes the Subject **defensively** via `RFC5322Parse.decodeRFC2047` (idempotent no-op when there's no `=?…?=`). This guarantees our own encoded sent subjects (and any encoded incoming subject) render clean instead of literal `=?UTF-8?B?…?=`. Note: `GmailParse` deliberately does NOT decode From/To/Cc *names* (the `parseFromHeader` test asserts the raw encoded displayName) — out of scope; subject-only.
- **`RFC5322Parse.decodeRFC2047` merges adjacent encoded-words** (drops fold whitespace between two `=?…?=`, preserves whitespace around plain text) — required so folded long subjects decode without a stray `\r\n `. SwiftMail's `decodeMIMEHeader()` already did this.
- **Exchange/Outlook is unaffected** — `ExchangeProvider` sends `message["subject"]` as a structured JSON field to Graph `/sendMail`; Graph builds the MIME and encodes the header server-side. Never hand-builds a header.
- **Fork changes need push + Package.resolved re-pin to reach IMAP/iCloud builds.** The iOS GmailProvider fix is app code → live on next build.
