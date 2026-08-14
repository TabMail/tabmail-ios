# Pre-compaction catalog bullets — `DECISIONS.md` v3 records

**Status:** Historical (preserved source text) · **Routed:** 2026-08-13 `companion-compact` ·
**Source:** `tabmail-ios/DECISIONS.md` at `b0f628a92`

`tabmail-ios/DECISIONS.md` was **27,720 B, 10% over its 25,000 B budget**, and 7,110 B of that —
26% of an always-loaded file — sat in exactly two catalog bullets. ADR-IOS-076's bullet had reached
**5,489 B** and ADR-IOS-077's **1,621 B**, against roughly 200 B for each of their ADR-IOS-068…075
siblings: they had stopped being routing lines and become second copies of their own ADR bodies.

The catalog now carries a shortened bullet for each; the text below is what those bullets were
compressed from, kept **byte-for-byte** so nothing a past plan, review prompt, audit round, or
commit body quoted has become unsearchable. **The normative record is the linked ADR body**
(`Companion/Decisions/V3/Active/adr-ios-076.md`, `…-077.md`), which was not touched by this pass;
read this file only to recover the exact pre-compaction catalog wording.

Each bullet is inside a ```text fence. That is deliberate and load-bearing: the bullets contain
links written **relative to `DECISIONS.md`**, and `Scripts/compact_companion_docs.rb`'s
`verify_markdown_links` strips fenced code blocks before resolving links — so fencing preserves the
bytes exactly rather than rewriting the paths to suit this directory (`MIS-IOS-009`).


---

## Source line 148 — `ADR-IOS-076`

<!-- BEGIN VERBATIM BULLET ADR-IOS-076 -->

```text
- **[ADR-IOS-076](Companion/Decisions/V3/Active/adr-ios-076.md)** — Active. ⚠️ **PARTIALLY IMPLEMENTED.** Shipped: decision 9 (`.eml` traversal, T11 — `1820a4fb3` + `05200112d` + `7ce64e44b` + `a50e378fe`; adjacent debug-gated render diagnostics in `71c19d554` + `cb46bc46c`), and **P1b (2026-08-12) — decision 1 (`allowsContentJavaScript = false` + the full 12-directive `<meta>` CSP in `EmailHTMLWrapper.contentSecurityPolicy`) (⚠️ **`font-src` RELAXED 2026-08-12 — owner directed `'none'` → `https:` after a device smoke test showed it broke sender web fonts; the FOURTH owner reversal of a P1b hardening and the only partial one; font leg of T9 OPEN and accepted, `IOS-PRIVACY-002`; `media-src 'none'` RETAINED**), `dataDetectorTypes = []` (⚠️ **REVERSED 2026-08-12 — owner restored `[.link, .phoneNumber]`; `IOS-UI-002` now registers the security exception: detectors dispatch OUTSIDE `decidePolicyFor`**), `allowsLinkPreview = false` (⚠️ **REVERSED 2026-08-12 — owner restored the unset WebKit default (ON); `IOS-UI-003` registers the SECOND allowlist exception: long-press preview fetches OUTSIDE `decidePolicyFor`**), and the per-view `nonPersistent()` store (⚠️ **REVERSED 2026-08-12 — owner restored the unset shared PERSISTENT default store, against the implementing side's recommendation; T5 is OPEN and owner-accepted, `IOS-PRIVACY-001` — one cookie jar across every message and sender, so this render path is NOT isolated**)**, so **sender JavaScript NO LONGER executes in the message webview**, and **P1c (2026-08-12) — decision 2's per-load navigation permit (`RenderNavigationPolicy.swift`: `RenderDocumentURL` mints a 128-bit nonce in the base-URL PATH `tabmail-asset://asset/_tm-document/<32-hex>/` used UNCONDITIONALLY at every call site, `NavigationPermitState` consumed at policy time by exact string equality, `decidePolicyFor` default-deny, `WKNavigation` captured for correlation), decision 4's `http`/`https` allowlist before `UIApplication.shared.open` (`RenderLinkPolicy`, which also stopped routing in-document `#fragment` clicks to the system opener), and decision 7's Swift-side bridge validation (`RenderBridgeInput`: finite/non-negative heights with NO ceiling, gutter clamped `[0,16]`, bounded+escaped `consoleLog`, `requestFit`/`requestWidthRefit` one-shot in Swift)**. **P2 (2026-08-12) — T8: `deferredImageLoadJS`'s `swap()` withholds `src`/`srcset` from images our own view-mode CSS hides (`hiddenByViewMode`), inside `swap()` so BOTH the `post-paint` and `failsafe-1500ms` arms inherit it — closing the main-view leak (every attached `.eml`'s pixels fired on opening an ORDINARY message) and the preview-sheet leak (parent body + every non-selected section). Deliberately NOT a general visibility test: a general one is ruled out by the `.tm-quote-wrapper.tm-collapsed` in-document reveal and by `fitViewportJS`'s breakpoint-crossing widen — see `IOS-PRIVACY-003`, which also records what it does not catch.** **P4 (2026-08-13) — image-failure banner: `postImageWidthRecheckJS` counts the `error` fires among the images WE deferred and posts `{failed, deferred}` ONCE on a FOURTH bridge channel `imageLoadFailure` (validated by `RenderBridgeInput.imageFailureReport`, dropped whole never clamped); `ImageFailureBannerState.isVisible` raises a dismiss-only `ImageLoadFailureBanner` in SwiftUI ABOVE the web view. OBSERVATIONAL ONLY — no retry/probe/HEAD, nothing changes which images load — so it is NOT the block-with-banner design reverted 2026-06-17, and that revert is not precedent against it. Count comes from the LISTENER (a broken `<img>` reports `complete === true`); "did we defer this" captured at ARM time in a per-iteration IIFE. Dead zone accepted: no banner while any image is withheld by `hiddenByViewMode` (keeps `data-tmsrc` ⇒ `pendingImgs()` never 0) — `IOS-UI-004`.** Still spec only: the asset-ownership/view-identity binding (P1d). ⚠️ **P1b did NOT close main-frame navigation** — `<meta http-equiv="refresh">` still navigates with JS off; P1c's nonce permit closes it, and its regression guard is `metaRefreshIsRefusedByTheProductionCoordinator` (the older `metaRefreshForgesAnAppLoadShape` canary still passes BY DESIGN — it probes raw WebKit, not the coordinator's decision). P1c does NOT prevent same-document `location.hash`/`history.pushState` mutation (never reaches `decidePolicyFor`). Do not cite this ADR as evidence any unshipped decision is closed; re-derive status from `git log`, not from the ADR's status paragraph. The message document is untrusted content, enforced at the WebKit boundary: `allowsContentJavaScript = false` + full `<meta>` CSP (`script-src 'none'`) while app-injected `WKUserScript`s keep running; a main-frame navigation permit keyed to an unguessable per-load nonce (`.linkActivated` never proves a user gesture, `<meta http-equiv="refresh">` forges a fixed-shape permit with no script), consumed at policy time and correlated by `WKNavigation`; `WKURLSchemeHandler` asset serving bound to manifest ownership by `MessageBody.id`/`ContentKey` with view identity recreating the `WKWebView` on key change; `http`/`https` allowlist before `UIApplication.shared.open`; per-message `nonPersistent()` store (⚠️ **NOT shipped — reversed by the owner 2026-08-12; the shared persistent default store is live and T5 is OPEN**); `.eml` attachment path traversal (`tabmail-asset`, `BodyAssetSchemeHandler`, `EmailHTMLWrapper.wrapHTML`).
```

<!-- END VERBATIM BULLET ADR-IOS-076 -->

---

## Source line 149 — `ADR-IOS-077`

<!-- BEGIN VERBATIM BULLET ADR-IOS-077 -->

```text
- **[ADR-IOS-077](Companion/Decisions/V3/Active/adr-ios-077.md)** — Active. Hostile attachment filenames are **REJECTED, not reduced** (`c35cfdca2`, net −476): one shared `AttachmentFilename.isSafeFileComponent` predicate, throw before `createDirectory` on save and refuse before the fetch on download, generic `"Unsupported file name"` for all six rules. Reducer + co-edit twin DELETED — five confirmed defects in three rounds all lived in the *transformation*, none in the classification. ⚠️ **Rejecting at save does NOT make the loaders safe** — `metaBase`/`afterIndexPrefix` stay load-bearing because a leading combining mark or trailing `Prepend` scalar PASSES the predicate and still grapheme-merges with the `_` prefix or `.meta` suffix. Type-spoof stays bounded, not closed (legitimate `דוח.pdf` reorders identically to a crafted name; isolates at display sites are the follow-up). Retains the swept fact that the combining test is `ccc != 0` on NFD, **not** category `Mn`/`Mc`/`Me`. ⚠️ **Consequence 5 (2026-08-12) retracts the MIGRATION GUARANTEE — there was never a reducer to migrate FROM**: `v1.7.6`/`v1.7.7`/`v1.7.8` have neither `safeAttachmentFileComponent` nor `isSafeFileComponent` and write the name verbatim, so legacy on-disk names are RAW sender-authored. Such a draft still LOADS; every re-SAVE throws; recovery is removing the attachment; an outbox row queued BEFORE the upgrade still sends. Stranded set = refused ∩ writable-by-v1.7.8, measured as 3 narrow shapes. `IOS-ATTACH-001` — forward-only by owner verdict: **no migration, rename-on-load or grandfathering path.**
```

<!-- END VERBATIM BULLET ADR-IOS-077 -->
