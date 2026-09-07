# Pre-compaction catalog bullets — `DECISIONS.md` post-`v1.6.38` records (2026-09-06 pass)

**Status:** Historical (preserved source text) · **Routed:** 2026-09-06 `companion-compact` ·
**Source:** `tabmail-ios/DECISIONS.md` at `2e4a16c35`

`tabmail-ios/DECISIONS.md` was **28995 B, 15% over its 25,000 B budget**. The bullets below had
regrown into second copies of their own ADR bodies — ADR-IOS-076 and ADR-IOS-077 for the second
time, having already been compacted on 2026-08-13. The catalog now carries a shortened bullet
for each; the text below is what those bullets were compressed from, kept **byte-for-byte** so
nothing a past plan, review prompt, audit round or commit body quoted has become unsearchable.
**The normative record is the linked ADR body**, which this pass did not touch.

Each fragment is inside a ```text fence. That is deliberate and load-bearing: the bullets contain
links written **relative to `DECISIONS.md`**, and `Scripts/compact_companion_docs.rb`'s
`verify_markdown_links` strips fenced code blocks before resolving links — so fencing preserves
the bytes exactly rather than rewriting the paths to suit this directory (`MIS-IOS-009`).

---

## Source line 127 — `ADR-IOS-026B`

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-026B -->

```text
- **[ADR-IOS-026B — the v3 supersession record](Companion/Decisions/V3/Superseded/adr-ios-026b-v3-superseded-by-068.md)** — *PendingOperation Uses Stable IDs (rfc822MessageId)*, **SUPERSEDED 2026-08-02 by ADR-IOS-068** and retained verbatim as evidence: `MessageHeader.stableId`, `IMAPProvider.resolveUID`'s Message-ID `SEARCH`, dual-match pending-op filtering, the UIDVALIDITY rationale. **Only its durable-mutation-authority layer is superseded** — fetch, normalize, dedup, stage, the AI cross-device cache probe, threading/`References`, and Outbox send de-duplication all SURVIVE; ADR-IOS-068's exempt list is normative. Authored under the colliding number `ADR-IOS-026`, so both search terms find it. The byte-identical `v1.6.38` twin, without the supersession banner, is [`Companion/Decisions/Superseded/adr-ios-026b.md`](Companion/Decisions/Superseded/adr-ios-026b.md).
```

<!-- END VERBATIM FRAGMENT ADR-IOS-026B -->

---

## Source line 143 — `ADR-IOS-071`

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-071 -->

```text
- **[ADR-IOS-071](Companion/Decisions/V3/Active/adr-ios-071.md)** — Active. No backward compatibility for the action queue: migration v74 purged it predicate-free, and **as of the 2026-09-06 owner-approved amendment the purge is a STANDING APP-RELEASE BOUNDARY, not one-time** — `AppDatabase.retirePreviousReleaseActionQueue` deletes every `pendingOperation` row without decoding it, marks every account full-sync-due and records the release in `appReleaseStamp` (migration `v89`), in ONE transaction inside `AppDatabase.init` before the pool is published; an unchanged release does not purge. Lifecycle carve-out, not a fifth exit (`never-drop-user-intention.md`); cost registered as `IOS-ACTION-003`. Authored drafts/outbox/content remain never-drop.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-071 -->

---

## Source line 148 — `ADR-IOS-076`

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-076 -->

```text
- **[ADR-IOS-076](Companion/Decisions/V3/Active/adr-ios-076.md)** — Active. ⚠️ **PARTIALLY IMPLEMENTED.** The message document is untrusted content, enforced at the WebKit boundary: `allowsContentJavaScript = false` + the 12-directive `<meta>` CSP in `EmailHTMLWrapper.contentSecurityPolicy`; a per-load main-frame navigation permit keyed to an unguessable nonce (`RenderNavigationPolicy`, `RenderDocumentURL`, default-deny `decidePolicyFor`, `metaRefreshIsRefusedByTheProductionCoordinator`); an `http`/`https` allowlist before `UIApplication.shared.open` (`RenderLinkPolicy`); Swift-side bridge validation (`RenderBridgeInput`); `.eml` path traversal (`tabmail-asset`, `BodyAssetSchemeHandler`); deferred-image withholding for `hiddenByViewMode`; and a diagnostic-only `imageLoadFailure` census with no banner. ⚠️ **FOUR owner REVERSALS are registered exceptions, not defects** — `dataDetectorTypes` (`IOS-UI-002`), `allowsLinkPreview` (`IOS-UI-003`), the per-view `nonPersistent()` store (`IOS-PRIVACY-001`, T5 OPEN — one cookie jar across every sender), `font-src 'none'` → `https:` (`IOS-PRIVACY-002`); see also `IOS-PRIVACY-003`. P1d (asset-ownership/view-identity binding) is still spec only, and P1c does not stop same-document `location.hash`/`history.pushState`. `WKWebView` exposes no exact `<img>` ATS error or supported per-resource timeout, so no security-specific notice or timing heuristic is shipped. **Do not cite this ADR as evidence that an unshipped decision is closed — re-derive status from `git log`, not from its status paragraph.** Pre-compaction bullet, byte-for-byte: [pre-compaction-index-lines.md](Companion/Decisions/V3/pre-compaction-index-lines.md).
```

<!-- END VERBATIM FRAGMENT ADR-IOS-076 -->

---

## Source line 149 — `ADR-IOS-077`

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-077 -->

```text
- **[ADR-IOS-077](Companion/Decisions/V3/Active/adr-ios-077.md)** — Active. Hostile attachment filenames are **REJECTED, not reduced** (`c35cfdca2`, net −476): one shared `AttachmentFilename.isSafeFileComponent` predicate, throw before `createDirectory` on save and refuse before the fetch on download, generic `"Unsupported file name"` for all six rules. Reducer + co-edit twin DELETED — all five confirmed defects lived in the *transformation*, none in the classification. ⚠️ **Rejecting at save does NOT make the loaders safe** — `metaBase`/`afterIndexPrefix` stay load-bearing; type-spoof is bounded, not closed; the combining test is `ccc != 0` on NFD, **not** category `Mn`/`Mc`/`Me`. ⚠️ **Consequence 5 retracts the MIGRATION GUARANTEE — there was never a reducer to migrate FROM** (`v1.7.6`/`v1.7.7`/`v1.7.8` write the name verbatim, so legacy on-disk names are RAW sender-authored; stranded set = refused ∩ writable-by-v1.7.8, 3 narrow shapes). `IOS-ATTACH-001` — forward-only by owner verdict: **no migration, rename-on-load or grandfathering path.** Pre-compaction bullet, byte-for-byte: [pre-compaction-index-lines.md](Companion/Decisions/V3/pre-compaction-index-lines.md).
```

<!-- END VERBATIM FRAGMENT ADR-IOS-077 -->

---

## Source line 152 — `ADR-IOS-081`

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-081 -->

```text
- **[ADR-IOS-081](Companion/Decisions/V3/Active/adr-ios-081.md)** — Active. **Account-scoped ≠ immutable**, and the drain needs the first while a moved address needs the second: `immutableIdAccountIds` → `accountScopedIdAccountIds` admits `.outlook` to account-qualified lanes, and `MessageHeaderRekey.finishMove` re-addresses every non-cancelled same-account queued op naming a proven source id in the SAME transaction that retires the move (`readdressQueuedOperations`). On an account-scoped provider the re-key FOLLOWS THE ROW by `(accountId, messageId)`; G3's folder clause stays byte-identical on IMAP, where it is the C3 guard. Requeues write columns (`PendingOperation.markQueued`), the lane loop re-reads by primary key with NO `?? op` fallback, and `accountScopedIds:` is non-defaulted at EVERY call site (no count — the compiler enumerates them; the "thirteen" this line used to state went stale in a day). Amends ADR-IOS-018 + ADR-IOS-068 §6; supersedes `IOS-QUEUE-008`'s Outlook exclusion (met, not waived — the lane change and the handoff are ONE fix and must never be split). Accepted: the crash window between Graph's 2xx and the retirement commit (owner 2026-09-04; #117 / #116). ⚠️ **AMENDED by ADR-IOS-082** — its "no schema, migration or drain-ordering change" consequence is HISTORICAL (that follow-up landed: `queuePosition`, migration v90, `queuePosition ASC`), and every "lane"/"lane loop" here now means a related CHAIN (`buildLanes` → `buildRelatedChains`), dispatched one operation at a time. `IOS-GRAPH-005`, #114, `MIS-IOS-003` instance 6.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-081 -->

---

## Source line 153 — `ADR-IOS-082`

<!-- BEGIN VERBATIM FRAGMENT ADR-IOS-082 -->

```text
- **[ADR-IOS-082](Companion/Decisions/V3/Active/adr-ios-082.md)** — Active. **The action queue is drained by a GLOBAL SINGLE-OPERATION FIFO EXECUTOR** ordered by a durable `queuePosition` (migration **v90**, `NOT NULL CHECK(queuePosition > 0)`, **no DEFAULT** so an omitting writer FAILS instead of admitting at the head, indexed), allocated after the current maximum in the SAME transaction that admits the row — `PendingOperation` is a `MutablePersistableRecord` for that reason, and `createdAt` is demoted to AGE ONLY, so equal stamps and a backward clock step cannot reorder anything. One owner claims the live front row (`claimFrontierOperation`), executes and commits before claiming again; **the protected-frontier law** stops the walk at an `inFlight` row. Lane DISPATCH is retired, the lane RELATION survives as `buildRelatedChains`/`addressKey` and now scopes a DEFERRAL: a failed attempt moves the whole related chain to the TAIL (`deferRelatedChainToTail`, one attempt per drain), an unclaimable frontier is skipped IN MEMORY (no position change, no retry charge), and unrelated mail on every account keeps draining. One member per attempt is ORDINARY traffic (`MIS-IOS-022`), so a narrowing is STRICT PROGRESS — `.proceed` plus tail movement, N members in ONE drain — guarded by the strict-progress check that routes a report narrowing NOTHING to the ordinary retryable disposition. 🚨 **THE `.proceed` INVARIANT: no arm may return `.proceed` unless the claimed row is provably GONE, provably NARROWED, or provably OWNED by `pendingRequeues`/`pendingRetirements`** — a `try? await retryWrite { deleteOne }` followed by `.proceed` leaves the row `inFlight` and wedges every account's drain for the life of the process (the wedge corollary → a DROPPED intention); the fix is `do`/`catch` + `requeueOrRetain` + `.stopDrain`, and the census is a falsifiable COUNT — SEVEN `.proceed` sites before the fix (3 provably resolved + the 3 arms + the outcome-box default), SIX after, all provably resolved. Deletes `pendingRetirementSuffixes` and `laneDiagnosticSummary`. This is the follow-up ADR-IOS-081 routed to the owner.
```

<!-- END VERBATIM FRAGMENT ADR-IOS-082 -->

---

## Source line 131 — Numbering note

<!-- BEGIN VERBATIM FRAGMENT Numbering note -->

```text
> **Numbering note.** This file jumps from ADR-IOS-057 to ADR-IOS-068. That gap is deliberate and is
> itself a record: **ADR-IOS-058, 059, 060, 061, 062, 063, 064, 065, 066 and 067 were authored on a
> line that never shipped to a user device.** They are not missing and must not be re-created here.
> **ADR-IOS-070 is their disposition record** — read it before concluding that any of those numbers
> is available, unrecorded, or lost. `v2final` (`e28dd4edb`) holds their bodies and remains readable
> with `git show v2final:Companion/Decisions/…`; that branch is preserved precisely so this history
> stays searchable.
```

<!-- END VERBATIM FRAGMENT Numbering note -->
