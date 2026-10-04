# Received-mail charset labels decode as their WHATWG superset (gb2312 → GB18030, euc-kr → CP949)

## Symptom (2026-10-03)

A received subject showed raw `=?gb2312?B?…?=` followed by correctly decoded text from
the next encoded-word. The first word's bytes contained `A8 43`, the en dash in GBK/GB18030. Strict
GB2312 has no such character.

## Root cause

- CoreFoundation's `CFStringConvertIANACharSetNameToEncoding` maps the labels `gb2312`, `euc-cn`,
  `csgb2312`, `chinese` and `iso-ir-58` to **strict EUC-CN** (`0x930`), `gbk`/`x-gbk` to GBK_95
  (`0x631`), `cp936`/`windows-936` to DOSChineseSimplif (`0x421`), and `euc-kr` to strict EUC-KR
  (`0x940`). SwiftCross's `String.Encoding(ianaCharsetName:)` uses that table on Apple platforms.
- Senders label GBK text `gb2312` all the time; the WHATWG Encoding Standard (what browsers and
  Thunderbird follow) decodes every GBK label with the gb18030 decoder, and `euc-kr` with
  Windows-949.
- SwiftMail's `decodeMIMEHeader()` keeps the ORIGINAL encoded-word text when the charset decode fails,
  so one GBK-only character put the whole raw word on screen. (The IMAP envelope subject is decoded in
  SwiftMail's `FetchMessageInfoHandler`, not in the app.)
- The app's own Gmail-path decoder `RFC5322Parse.decodeRFC2047` had a separate hand table
  (`charsetFor`) that mapped every label except UTF-8 / ISO-8859-1 / ASCII / UTF-16 to **UTF-8** —
  a gb2312, windows-1252, shift_jis, koi8-r … word failed and showed its raw base64/Q payload.

## Fix

- SwiftMail: `String.Encoding(mimeCharset:)` (public, `Extensions/String.Encoding+MIMECharset.swift`)
  resolves through `ianaCharsetName`, then swaps EUC-CN / GBK_95 / CP936 → GB18030 and EUC-KR → CP949.
  Every SwiftMail decode site uses it: encoded-words, `detectCharsetEncoding`,
  `decodeQuotedPrintableContent`, `MessagePart.textContent`, RFC 2231 `filename*`, and the `.msg`
  RTF code-page map. Fork branch `fix/mime-charset-supersets`, upstream PR
  [#248](https://github.com/Cocoanetics/SwiftMail/pull/248); carried on fork `main` until merged (memory 126).
- App: `RFC5322Parse.charsetFor` deleted; `decodeRFC2047` resolves with
  `String.Encoding(mimeCharset:) ?? .utf8`, so the Gmail and IMAP paths decode identically.

## Evidence that the swap cannot break text that decodes today

Exhaustive check over every 1- and 2-byte sequence on macOS CoreFoundation:

| strict → superset | sequences the strict decoder accepts | lost | different |
|---|---|---|---|
| EUC-CN → GB18030 | all | 0 | 2 within A1–FE (`A1A4` U+30FB→U+00B7, `A1AA` U+2015→U+2014, as browsers); others are CF EUC-CN accepting non-EUC trail bytes, which GB18030 reads as GBK |
| GBK_95 → GB18030 | all | 0 | 24, all GBK private-use → characters GB18030 assigned (`A3A0`→U+3000, `A6D9…`→vertical forms) |
| CP936 → GB18030 | all | 0 | 24, same private-use class |
| EUC-KR → CP949 | all | 0 | 0 |

**Big5 is deliberately NOT widened**: Apple's Big5-HKSCS decoder (`0xA06`) maps 22 common Big5
punctuation sequences differently, some to two-scalar sequences ending in private-use `U+F87D`/`U+F87E`
(e.g. `A14D` → U+FF0C U+F87D). Do not "complete the WHATWG table" by adding it.

## Rules derived

- Decode received mail through `String.Encoding(mimeCharset:)`, never through a hand-written charset
  table and never through `ianaCharsetName` directly.
- It is for DECODING only; an encoder must not emit superset bytes under a narrower label.
- Non-Apple (swift-corelibs) is unchanged: SwiftCross maps those labels to a `.utf8` placeholder there.
- **The declared charset wins (owner decision 2026-10-03).** Bytes that are really UTF-8 but labelled
  `gb2312` now decode as GB18030 mojibake (every well-formed UTF-8 sequence is also valid GB18030)
  instead of the strict decoder failing and falling through. That is what browsers and Thunderbird
  show; do not add UTF-8 sniffing ahead of the label.

## Already-stored mail (owner decision 2026-10-03: fix going forward only)

- **Subjects stored broken stay broken — accepted.** Nothing rewrites an existing header's `subject`:
  the `SyncEngineFullSync` existing-header update refreshes from/to/cc/bcc/replyTo and flags only, and
  pull-to-refresh in the message view (`MessageDetailViewModel.refetchBody` →
  `AccountManager.fetchBody(replaceExistingBody: true)` → `BodyFetchProcessor`) rewrites only the body.
  Only a re-sync of the account replaces them. No migration was built.
- **Bodies stored as mojibake are user-recoverable**: the same message-view pull-to-refresh re-fetches
  and replaces the body, now decoded with the superset charset.
