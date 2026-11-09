# Pre-compaction index rows (2026-11-09)

**Status:** Historical (preserved source text) · **Routed:** 2026-11-09 `companion-compact` · **Source:** `tabmail-ios/PROJECT_MEMORY.md` at `6597c3a7`

The `companion-compact` pass of 2026-11-09 shortened these lines of `PROJECT_MEMORY.md`
(33077 B against its 30 KB budget); topic cells had regrown detail inline. Each line is kept
here byte-for-byte, in source order, fenced so its index-relative links are not re-resolved
from this directory. The linked detail files are unchanged, and none of the 91 frozen
`manifest.tsv` rows was touched.

---

## Source lines 17-17 — HTML-to-text Markdown links, href destinations in FTS and ag

<!-- BEGIN VERBATIM LINES 17-17 -->

```text
- [HTML-to-text Markdown links, href destinations in FTS and agent reads; forward-only (#100); snippet link window `snippetLinkScanChars` 32K + linear `unwrapMarkdownLinks` scanner replacing the quadratic regex, image-heavy newsletter `[](https://` preview (#162, PR #163); draft `keepingSpacing` mode (no space around links/inline tags, `&nbsp;`, `<pre>`) and the link-label trailing-space-drop crash guard (#217 round 5); `HTMLText` streaming byte scanner + `HTMLTextStyle` CSS reader (display none, white-space, margins; `<style>` only in drafts), joiners kept only between non-ASCII (#251)](Companion/Memory/Current/125-html-links-in-converted-text.md).
```

<!-- END VERBATIM LINES 17-17 -->

---

## Source lines 18-18 — Archived mail "comes back" without a snippet on a weak conne

<!-- BEGIN VERBATIM LINES 18-18 -->

```text
- 🚨 [Archived mail "comes back" without a snippet on a weak connection = the #106 ghost re-insert, NOT a queue drop; `recentlyCompleted` protection set is now a `Mutex` read INSIDE every sync write transaction via `liveRecentlyCompleted()`, never snapshotted before the listing fetch](Companion/Memory/Current/127-sync-protection-set-is-read-inside-the-write-transaction.md).
```

<!-- END VERBATIM LINES 18-18 -->

---

## Source lines 152-152 — ⚠️ **SEVEN irreversible wire operations (2026-10-21, #217 Gr

<!-- BEGIN VERBATIM LINES 152-152 -->

```text
| Current | ⚠️ **SEVEN irreversible wire operations (2026-10-21, #217 Graph draft attachment `DELETE`; six at `967e5b3c5`), not one** — deletion family + `CalDAVProvider.splitSeries` cap `PUT` + `replaceDraftAttachments`; membership = **no per-item recovery**, NOT the verb | [read in full](Companion/Memory/Current/102-there-are-four-irreversible-wire-operations-not-one.md) |
```

<!-- END VERBATIM LINES 152-152 -->

---

## Source lines 162-162 — 🚨 uidValidityResetPendingAt STAYS ARMED ON PURPOSE

<!-- BEGIN VERBATIM LINES 162-162 -->

```text
| Current | 🚨 `uidValidityResetPendingAt` STAYS ARMED ON PURPOSE — never demand proof of transience; `crawlWalkWriteAllowed` was the LAST consumer writing under it (`16ecafd93`) | [read in full](Companion/Memory/Current/112-uidvalidityresetpendingat-is-a-redrive-flag-that-stays-armed-on-purpose.md) |
```

<!-- END VERBATIM LINES 162-162 -->

---

## Source lines 163-163 — 🚨 **BOTH UIDVALIDITY RE-DRIVE OWNERS ITERATED syncableFolde

<!-- BEGIN VERBATIM LINES 163-163 -->

```text
| Current | 🚨 **BOTH UIDVALIDITY RE-DRIVE OWNERS ITERATED `syncableFolders`** (`fullSync` + `imapDeltaSync`) — an armed CUSTOM NON-FAVOURITE folder had NO re-drive: 145,754 rows | [read in full](Companion/Memory/Current/114-both-uidvalidity-redrive-owners-iterate-syncablefolders.md) |
```

<!-- END VERBATIM LINES 163-163 -->

---

## Source lines 164-164 — ✅ **KNOWN_ISSUES.md APPEND PATH

<!-- BEGIN VERBATIM LINES 164-164 -->

```text
| Current | ✅ **`KNOWN_ISSUES.md` APPEND PATH — RESOLVED 2026-08-12** — strip-before-compare `KNOWN-ISSUES-AMENDMENT-BEGIN`/`-END` + `KnownIssues/Amendments/`; `IOS-IMAP-015` | [read in full](Companion/Memory/Current/115-known-issues-register-is-byte-frozen-and-has-no-append-path.md) |
```

<!-- END VERBATIM LINES 164-164 -->

---

## Source lines 165-165 — 🚨 **ATTACHMENT FILENAMES REJECTED, NOT REDUCED**

<!-- BEGIN VERBATIM LINES 165-165 -->

```text
| Current | 🚨 **ATTACHMENT FILENAMES REJECTED, NOT REDUCED** — `AttachmentFilename.isSafeFileComponent`; **255 NFD UTF-16 unit** path-component cap (NOT bytes, NOT `Character`s) | [read in full](Companion/Memory/Current/116-a-path-component-is-capped-in-nfd-utf16-units-not-bytes-or-characters.md) |
```

<!-- END VERBATIM LINES 165-165 -->

---

## Source lines 166-166 — SwiftMail PR #208 MOVE post-completion contract

<!-- BEGIN VERBATIM LINES 166-166 -->

```text
| Current | SwiftMail PR #208 MOVE post-completion contract — only the COPYUID-bearing form is non-retryable; `moveFailedAfterPossiblePartialCompletion` without COPYUID is a retryable refusal (#115) | [read in full](Companion/Memory/Current/117-swiftmail-move-post-completion-contract.md) |
```

<!-- END VERBATIM LINES 166-166 -->

---

## Source lines 167-167 — 🚨 **"TRIAL ENDED" IS DERIVED, NEVER A NEW /whoami FLAG**

<!-- BEGIN VERBATIM LINES 167-167 -->

```text
| Current | 🚨 **"TRIAL ENDED" IS DERIVED, NEVER A NEW `/whoami` FLAG** — `has_subscription:false` + the `trial` KEY present; `.active` REQUIRES `plan_tier == "Trial"`; `AccountInfo.trialState(now:)`, `AISubscriptionGate.trialHasEnded`; #55 | [read in full](Companion/Memory/Current/118-trial-ended-is-derived-never-a-new-whoami-flag.md) |
```

<!-- END VERBATIM LINES 167-167 -->

---

## Source lines 168-168 — 🚨 **POST-LOGIN ROUTING WAITS FOR AN AUTHORITATIVE /whoami*

<!-- BEGIN VERBATIM LINES 168-168 -->

```text
| Current | 🚨 **POST-LOGIN ROUTING WAITS FOR AN AUTHORITATIVE `/whoami`** (issue #56) — `PendingPlanNavigationLatch` / `pending_plan_navigation`, `AISubscriptionGate.lastAuthoritativeApplyAt`, `signInGeneration`/`applyIfCurrentEpoch` | [read in full](Companion/Memory/Current/119-post-login-routing-waits-for-an-authoritative-whoami.md) |
```

<!-- END VERBATIM LINES 168-168 -->

---

## Source lines 169-169 — 🚨 **AFFORDANCE LIFETIME COMES FROM THE DURABLE HOLD, NEVER F

<!-- BEGIN VERBATIM LINES 169-169 -->

```text
| Current | 🚨 **AFFORDANCE LIFETIME COMES FROM THE DURABLE HOLD, NEVER FROM WHEN THE UI APPEARED** — undo-send anchor drift = presentation latency Δ; same-name-different-instant `queuedAt` (#76) | [read in full](Companion/Memory/Current/120-an-affordance-is-bounded-by-the-durable-state.md) |
```

<!-- END VERBATIM LINES 169-169 -->

---

## Source lines 171-171 — 🚨 **A DURABLE WRITE TO A MIRRORED IDENTITY COLUMN MUST REFRE

<!-- BEGIN VERBATIM LINES 171-171 -->

```text
| Current | 🚨 **A DURABLE WRITE TO A MIRRORED IDENTITY COLUMN MUST REFRESH THE NSE MIRRORS** — `nse.accountMap`/`nse.imapAccounts`, `mirrorAccountIdentity()`, `IOS-NSE-008` | [read in full](Companion/Memory/Current/123-a-durable-write-to-a-mirrored-identity-column-must-refresh-the-nse-mirrors.md) |
```

<!-- END VERBATIM LINES 171-171 -->

---

## Source lines 172-172 — 🚨 **ORDINARY SIGN-OUT RELEASES THE DEVICE PUSH REGISTRATION 

<!-- BEGIN VERBATIM LINES 172-172 -->

```text
| Current | 🚨 **ORDINARY SIGN-OUT RELEASES THE DEVICE PUSH REGISTRATION AND ENDS THE AUTH SESSION** — `unregisterDeviceForSignOut()` + `logout?scope=local`, both always | [read in full](Companion/Memory/Current/124-ordinary-sign-out-releases-the-device-push-registration-and-ends-the-auth-session.md) |
```

<!-- END VERBATIM LINES 172-172 -->

---

## Source lines 174-174 — 🚨 **RECEIVED-MAIL CHARSETS DECODE AS THEIR WHATWG SUPERSET**

<!-- BEGIN VERBATIM LINES 174-174 -->

```text
| Current | 🚨 **RECEIVED-MAIL CHARSETS DECODE AS THEIR WHATWG SUPERSET** — gb2312 → GB18030, euc-kr → CP949 via `String.Encoding(mimeCharset:)`; iOS GBK aliases #257, fork b14f52a, upstream #278 | [read in full](Companion/Memory/Current/132-received-mail-charset-labels-decode-as-their-whatwg-superset.md) |
```

<!-- END VERBATIM LINES 174-174 -->

---

## Source lines 176-176 — 🚨 **A HOSTED SWIFTUI BUTTON CANNOT BE TAPPED FROM A UNIT TES

<!-- BEGIN VERBATIM LINES 176-176 -->

```text
| Current | 🚨 **A HOSTED SWIFTUI BUTTON CANNOT BE TAPPED FROM A UNIT TEST** — `UIHostingController` exposes no elements; drive a model entry point (`SignOutButtonModel.activate`); #110 | [read in full](Companion/Memory/Current/128-hosted-swiftui-buttons-cannot-be-tapped-from-unit-tests-drive-a-model-entry-point.md) |
```

<!-- END VERBATIM LINES 176-176 -->

---

## Source lines 177-177 — Background credential refresh shares grant ownership

<!-- BEGIN VERBATIM LINES 177-177 -->

```text
| Current | Background credential refresh shares grant ownership — `ProviderCredentialStore`, `CredentialRefreshGate`, `TabMailSessionRefresh`; NSE cancellation, rotation, and foreground repair (#129) | [read in full](Companion/Memory/Current/125-background-refresh-shares-grant-ownership.md) |
```

<!-- END VERBATIM LINES 177-177 -->

---

## Source lines 178-178 — ADR-IOS-092

<!-- BEGIN VERBATIM LINES 178-178 -->

```text
| Current | SwiftMail upstream sync and fork train — fork main = upstream + ALL our PRs, app pins fork main (2026-10-24); 2026-11-08 fork/app 4da3876 = upstream d16534f + 8bit body CRLF/998-octet fix #286 (#437, stricter isSafe8BitContent, literal crlfNormalized); 2026-10-26 b14f52a carried GBK aliases #278 on ffcaf0a; previous merges #268, #271-#274, empty multipart subtype; exact app/NSE pin, fork deviations and upstream PRs (#233, #238, #248/#249, #263), RFC 2231, charsets, Bcc (ADR-IOS-092, PR B #220), format/delsp | [read in full](Companion/Memory/Current/126-swiftmail-upstream-sync-and-oversized-train.md) |
```

<!-- END VERBATIM LINES 178-178 -->

---

## Source lines 179-179 — ADR-IOS-088

<!-- BEGIN VERBATIM LINES 179-179 -->

```text
| Current | `attachment_read_pdf` chat tool — bundled pdf.js in a hidden WKWebView (ADR-IOS-088, `PDFTextHost`, `tabmail-pdf://`), earlier PDFKit path, `PDFStreamBudget`, `PDFPageGlyphCounter`, `IOS-AI-009`/`010` | [read in full](Companion/Memory/Current/131-pdf-attachment-text-tool-pdfkit.md) |
```

<!-- END VERBATIM LINES 179-179 -->

---

## Source lines 180-180 — 🚨 **PERMISSION USAGE STRINGS MUST DISCLOSE SERVER UPLOAD**

<!-- BEGIN VERBATIM LINES 180-180 -->

```text
| Current | 🚨 **PERMISSION USAGE STRINGS MUST DISCLOSE SERVER UPLOAD** — Guideline 5.1.2 rejection of 1.9.1: `NSContactsUsageDescription` vs AI `contacts_search` (PR #204); privacy, consent | [read in full](Companion/Memory/Current/133-permission-usage-strings-must-disclose-server-upload.md) |
```

<!-- END VERBATIM LINES 180-180 -->

---

## Source lines 181-181 — Age and terms screen (COPPA, root ADR-034)

<!-- BEGIN VERBATIM LINES 181-181 -->

```text
| Current | Age and terms screen (COPPA, root ADR-034) — `ConsentGateView`, DOB never stored, `POST /account/age-ineligible` deletion handshake, `AppStoreAgeCheck` Declared Age Range | [read in full](Companion/Memory/Current/134-age-and-terms-screen-and-app-store-age-check.md) |
```

<!-- END VERBATIM LINES 181-181 -->

---

## Source lines 183-183 — Dark mode keeps a rule hidden behind text (fixDarkModeColor

<!-- BEGIN VERBATIM LINES 183-183 -->

```text
| Current | Dark mode keeps a rule hidden behind text (`fixDarkModeColorsJS` `hidesAncestorBorder`, `shownThrough`, `AutoSizingHTMLView(backdrop:)`) and an over-wide table fills its column less its margins (`-webkit-fill-available`, not `auto` or `100%`; `constrainWidthsJS`); border-bottom line-height rule behind a centred date, newsletter; transparent border, border-image, currentColor, exact edge, partial overlap of a thick stroke, mask marked `data-tm-panel`, wrapper forces div/table/p `box-sizing: border-box !important` (fixture heights include the border), `__tmRuleEdges` + `ruleCount` + per-pass `ruleRects` cost, body rule included, outer ruled ancestor, longhand `background-color` mask, `paintBox` background-clip (#307); gradient panel edge #316; CSS Color 4 edge #317; recoloured currentColor edge #318; border-image-width edge #319; compose quote backdrop untested #320; html-element rule edge #321; transform scale edge #322; non-painting ancestor fill edge #323 | [read in full](Companion/Memory/Current/136-dark-mode-keeps-a-rule-hidden-behind-text.md) |
```

<!-- END VERBATIM LINES 183-183 -->

---

## Source lines 184-184 — An expanded quote fits a wide forwarded table (fitQuoteCont

<!-- BEGIN VERBATIM LINES 184-184 -->

```text
| Current | An expanded quote fits a wide forwarded table (`fitQuoteContentJS`, `tmFitQuoteContent`, `transform: scale()` not CSS `zoom` (minimum logical font size clamps zoomed text), `QuoteFitConfig`, clipped `.tm-quote-content`, page fit never sees collapsed quotes, `tmQuoteFitLeaves` sender `overflow-x` scroller / authored `transform` `scale` `rotate` left alone, negative margin uses `offsetHeight` not rect height) and quote levels are capped coloured bars (`QuoteLevelConfig`, `maxIndentedDepth`, blockquote indent, Gmail inline quote style, Gmail Indent `border:none`); #327 | [read in full](Companion/Memory/Current/137-an-expanded-quote-fits-a-wide-table-and-quote-levels-are-capped-bars.md) |
```

<!-- END VERBATIM LINES 184-184 -->

---

## Source lines 185-185 — A .task(id:) keyed on a flag does not restart when its ani

<!-- BEGIN VERBATIM LINES 185-185 -->

```text
| Current | A `.task(id:)` keyed on a flag does not restart when its animated branch comes back (off-then-on inside a removal transition; SwiftUI reinstates the same view); key by the work's identity (`RootView` demo splash setup, `DemoSeedingSplash`, `demoStore.chatAdmission`, `.animation(value: demoStore.isActive)`, stuck splash) | [read in full](Companion/Memory/Current/138-a-task-keyed-on-a-flag-does-not-restart-when-an-animated-branch-comes-back.md) |
```

<!-- END VERBATIM LINES 185-185 -->

---

## Source lines 186-186 — A system permission prompt in the unit-test host shows once 

<!-- BEGIN VERBATIM LINES 186-186 -->

```text
| Current | A system permission prompt in the unit-test host shows once per erased simulator (first full run fails, rerun passes; TCC.db `auth_reason 13` = cancelled prompt recorded as denied; Contacts from `ComposeView` onAppear `ContactSearchService.requestAccess`, `DraftOpenReloadTests`; inactive scene stops `.task`; `TestPermissionPrompts`, `simctl erase`) | [read in full](Companion/Memory/Current/139-a-system-permission-prompt-in-the-unit-test-host-shows-once-per-erased-simulator.md) |
```

<!-- END VERBATIM LINES 186-186 -->
