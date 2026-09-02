# MIS-IOS-009 — I amended a hash-pinned Companion fragment in place, and the verifier died on line one

**Class:** documentation / verification
**Severity:** high
**First seen:** 2026-08-04 · **Recurrences:** 9 (**9: edited the preserved body of `Companion/Memory/Current/030-backfill-fast-sync-completion-gate-on-pendingbodycount-never-a-server-to.md` to correct a `pendingBodyCount` predicate the oversized-quarantine stop-gap had changed — a FACTUALLY CORRECT amendment in the WRONG PLACE. `verify` aborted on its first gate (`hash mismatch:`), hiding nine downstream checks. Caught by a round-5 review specialist, not by me; see "Instance 9" at the end.** **8: appended a two-line citation note as BARE MARKDOWN to the GENERATED, byte-frozen `Companion/Process/Current/KnownIssues/ios-billing-001.md` (`a6f395517`), breaking `compact_known_issues.rb verify` from 2026-08-18 until `fb5d498a2` this morning — and `Companion/Memory/Current/115-known-issues-register-is-byte-frozen-and-has-no-append-path.md` ALREADY DOCUMENTED THAT EXACT HAZARD. The knowledge existed and was not reachable at the moment it was needed; see "Instance 8" at the end.** **7: killed `verify` with a GLOB — `…/KnownIssues/ios-*.md` written into a Ruby comment, by the exact mechanism the note below this line already describes; see "Instance 7" at the end.** **6: broke again the DAY AFTER instance 5 was repaired — see "Instance 6" at the end.** 5: was fail-open for two days — `345c04a6f` edited a preserved body and `verify` aborted on its FIRST check from 2026-08-10 to 2026-08-12, silently disabling the ADR census, routing, link, pointer and budget checks. ✅ REPAIRED 2026-08-12 the prescribed way — body restored byte-for-byte from the pinned source, amendment moved into a `COMPANION-CURRENT-NOTE` wrapper, SHA **not** re-pinned. See "Instance 5 — resolution" at the end of this file**) · **Status:** Active
**Related:** [MIS-IOS-006](MIS-IOS-006-stale-test-bundle-reported-a-wrong-count.md); **MIS-023** and
**MIS-027** in the monorepo-root tree (`rg -n 'MIS-023|MIS-027' ../MISTAKES.md`) — both are the same
shape: reading a number instead of reading how far the run got.

> Those two ids are given as bare ids on purpose. `verify_repository_companion_references` scans every
> tracked and untracked file for the literal substring `Companion/<Tree>/…​.md` and resolves each hit
> against `tabmail-ios/`, ignoring any `../` prefix — so a *correct* relative path to the root tree
> written out in full aborts the verifier. That is this very mistake, one level up: the first draft of
> this file broke `verify` the same afternoon it was written to describe breaking `verify`.

## The tell

I have found a false claim in a routed `Companion/` file. I am writing the correction **inline, right
next to the sentence it refutes**, because that is where a reader will see it — and adding a pointer
to that sentence so nobody can read the claim without the refutation. Every word of that instinct is
right. I have not asked whether the file's **bytes** are load-bearing.

## What actually happened

`9430ef418` (2026-08-04, "Close the register: every id now carries exactly one disposition") added a
well-written `⚠️ EMPIRICAL CORRECTION` to `Companion/Decisions/Active/adr-ios-031.md`, refuting the
ADR's claim that `.medium` sits "below iOS's priority-inversion detection threshold" with measured
Thread Performance Checker output. It also appended a one-line pointer to the falsified sentence.

That file is one of **173** fragments whose SHA-256 is pinned in a `Companion/**/manifest.tsv`.
`ruby Scripts/compact_companion_docs.rb verify` reconstructs `v1.6.38:PROJECT_MEMORY.md` and
`v1.6.38:DECISIONS.md` byte-for-byte from those fragments — it is the proof that the compaction lost
nothing. It `abort`s on the **first** mismatch:

```
hash mismatch: Companion/Decisions/Active/adr-ios-031.md
```

`adr-ios-031.md` is row 33 of the Decisions manifest, so from that commit the verifier died before
reaching **any** later check. Silently not running, for a full day: the DECISIONS reconstruction, the
55-ADR census, the 9 ported-decision hashes, the 91-fragment memory routing census, the 2 ported
memory topics, the 212-file Markdown link check, the 279 repository-pointer check, and the budget
report. The budget report is the part that mattered — it was holding a live **38% over-budget**
finding on `CLAUDE.md` that nobody saw until the verifier was repaired.

The outage was even worked *around* without being noticed: the agent that landed the
`PROJECT_MEMORY.md` compaction the next day re-implemented `verify_markdown_links` by hand, because
`verify` aborted before reaching it, and treated that as a normal amount of friction.

## Instance 2 (2026-08-05) — a SIBLING shape, recorded here rather than as a new id: the invisible constraint was the file's own GRAMMAR, not a hash

The register-closure pass appended adjudication prose to eleven `KNOWN_ISSUES.md` Status/Notes cells.
Four of those additions quoted a shell command containing a literal `|` — `git show <tag>:<path> | rg
-c 'deleted'`, `rg -c 'v81_|v82_'`, and two more. `KNOWN_ISSUES.md` is one enormous GFM table in which
**one row is one physical line**, so an unescaped `|` inside a cell does not render as a pipe: it
**splits the cell**, silently shifting every field to its right by one and moving prose into the wrong
column. The prose read correctly in the editor, in the diff, and in every `rg` of the row.

It was caught before commit, and only because the pass happened to verify structurally rather than
visually — counting pipe-delimited fields per row against `git show HEAD:KNOWN_ISSUES.md`:

```
IOS-NSE-004 6→7 · IOS-GRAPH-004 7→8 · IOS-DRAFT-012 6→8 · IOS-MIGRATION-003 6→8
```

The fix is the convention the file already used everywhere: write `\|`. Cost: zero, because the check
ran. Had it not, four register rows would have silently lost their Subsystem/Notes columns.

**Why this belongs on MIS-IOS-009 instead of a new id.** The mechanism is different — a SHA-256
manifest versus a Markdown table's field separator — but the failure is the same one, and stating it
generally is what makes the entry reusable:

> **The constraint that governs an edit is often invisible at the point of the edit.** A hash-pinned
> body looks like ordinary Markdown; a table cell looks like ordinary prose. In both cases the file
> is read by a MACHINE with a grammar (the manifest verifier; the GFM table parser) that the
> surrounding text does not advertise, and in both cases a perfectly correct-looking amendment breaks
> it without any local signal.

**So the rule below generalises: before amending any file, ask what reads it besides a human.** If the
answer is a verifier, a table parser, a link checker, or a census script, find that reader's grammar
first — usually by looking at what the file already does (`\|` appears throughout `KNOWN_ISSUES.md`;
the `COMPANION-CURRENT-NOTE` markers appear in already-amended fragments) — and imitate it.

**And verify structurally, not visually.** The diff of instance 1 looked correct; the diff of instance
2 looked correct. Both were caught (or missed) by running the file's machine reader, or a stand-in for
it, before and after.

```bash
# Stand-in for the table parser: per-row field count, current vs HEAD. Any delta is an injected pipe.
python3 - <<'EOF'
import re, subprocess
def f(t): return {r[1].strip(): len(r) for l in t.split('\n') if l.startswith('| IOS-')
                  for r in [re.split(r'(?<!\\)\|', l)]}
a = f(subprocess.run(['git','show','HEAD:KNOWN_ISSUES.md'],capture_output=True,text=True).stdout)
b = f(open('KNOWN_ISSUES.md',encoding='utf-8').read())
print([k for k in b if a.get(k) != b.get(k)] or 'NONE')
EOF
```

## Why it is not obvious

**The tree provides a designed amendment surface, and nothing at the edit site says so.** The
compaction script defines `<!-- COMPANION-CURRENT-NOTE-BEGIN -->` / `<!-- COMPANION-CURRENT-NOTE-END -->`,
and `exact_body` strips exactly one such block from the **head** of a file before hashing. An
amendment placed there is fully visible to every reader and to `rg`, while the preserved body stays
byte-identical. `Companion/README.md` even says the intent outright — *"`verify` is the landing proof
against that source revision, not a permanent ban on later documented amendments"*. But the marker
appears nowhere in the file you are editing unless that file already has one, so a correct-looking
inline edit never encounters it.

**An `abort`-on-first-failure verifier is fail-open for every check after the first.** Its message
names one file, which reads as one small local problem. It is not: it is a total outage of the tool,
and the tool's own silence about the other checks is indistinguishable from those checks passing.
This is the same shape as MIS-023 and MIS-027 — reading a number (or an error line) instead of
reading how far the run actually got.

**The amendment itself was correct and followed repo convention.** Supersede-don't-delete is the
standing rule here, the correction cites measurements, and it explicitly preserves the falsified text
verbatim. Nothing about reviewing the diff would flag it. The defect is entirely in the *location*.

## The rule

**Before editing any file under `Companion/`, ask whether its bytes are pinned.** If the path appears
in a `manifest.tsv` with a `sha256` column, its body is immutable: amend it by **prepending** a
`COMPANION-CURRENT-NOTE` wrapper containing the whole amendment, never by editing inside the body,
and never by touching the preserved text (not even to append a pointer to it — put the pointer in the
wrapper and quote the sentence it refers to).

**And run the verifiers before and after every Companion edit**, reading their *last* line rather
than their first:

```bash
ruby Scripts/compact_companion_docs.rb verify ; echo "rc=$?"
ruby Scripts/compact_ios_rules.rb verify      ; echo "rc=$?"
```

A green run ends with the budget/verdict block. If the output stops early, the checks below the stop
did not run — say so, rather than reporting the one named file.

## Mechanical check

```bash
# 1. Is this file hash-pinned?  (bounded to Companion/ — never grep the repo root unbounded)
rg -n --fixed-strings "$REL_PATH" Companion/*/manifest.tsv Companion/*/*/manifest.tsv

# 2. If it is, the ONLY legal amendment shape — prepended, stripped before hashing:
#    <!-- COMPANION-CURRENT-NOTE-BEGIN -->
#    > **Current routing note — …**
#    <!-- COMPANION-CURRENT-NOTE-END -->
#    <preserved body, byte-for-byte>

# 3. Sweep every manifest at once rather than trusting the first abort:
#    (checks each row's sha against both the raw file and the wrapper-stripped body)
ruby -e 'require "digest"; B="<!-- COMPANION-CURRENT-NOTE-BEGIN -->"; E="<!-- COMPANION-CURRENT-NOTE-END -->"
bad=0; Dir.glob("Companion/**/*manifest.tsv").sort.each{|m| h=File.readlines(m,chomp:true)
 cols=h.first.split("\t"); pi=cols.index("path"); si=cols.index("sha256"); next unless pi&&si
 h.drop(1).each{|r| f=r.split("\t"); raw=File.binread(f[pi]) rescue (puts("MISSING #{f[pi]}"); bad+=1; next)
  s=raw.sub(/\A#{Regexp.escape(B)}\n.*?\n#{Regexp.escape(E)}\n/m,"")
  next if [raw,s].map{|x|Digest::SHA256.hexdigest(x)}.include?(f[si])
  puts "MISMATCH #{m}: #{f[pi]}"; bad+=1}}
puts "mismatched=#{bad}"'
```

## Instance 3 (2026-08-07) — the SAME file class, twice more, one of them by the supervisor; and the cascade it had been hiding

Two more in-body amendments to hash-pinned fragments, found by running the mechanical sweep in this
entry rather than by `verify` naming them (it `abort`s on the first, so it named only one):

- **`Companion/Decisions/Active/adr-ios-024.md`** (`7c143daa5`, 2026-08-06) — the four-tools→twelve-tools
  correction, written inline exactly as instance 1 was. Correct content, correct convention, wrong location.
- **memory fragment **111** (`the-address-problem`, `Companion/Memory/Current/`)** — **mine, this session**, while retiring
  THE ADDRESS PROBLEM's alarm. I had read this entry earlier in the same session. Reading the rule is not
  the countermeasure; running the sweep is.

**What the abort had been hiding for a day is the point.** With `adr-ios-024` fixed, `verify` advanced and
immediately failed on checks nobody had seen since 2026-08-06: **14 broken Markdown links** (13 in
history fragment **110** (`pre-compaction-index-row-abstracts`), 1 in `Companion/Process/Current/project-memory-index-usage-protocol.md`)
and **1 unresolvable repository pointer**. The links broke for a mechanical reason worth knowing: that text
was cut **byte-for-byte out of `PROJECT_MEMORY.md`**, where `Companion/Memory/manifest.tsv` is a correct
root-relative path. Routing it into a nested directory silently invalidated every such link, and the
byte-for-byte fidelity rule is what preserved the breakage. **Compaction that moves a file deeper must
re-resolve its relative links; the no-content-loss rule does not make a moved link correct.**

## THE DISTINCTION THAT DECIDES WHETHER YOU RE-PIN — learned 2026-08-07, and it is invisible at the edit site

There are **two** pinning conventions in this tree, and the required repair is opposite in each:

| manifest | hashes | on amendment |
|---|---|---|
| `Companion/{Memory,Decisions}/manifest.tsv` | `exact_body` — wrapper **stripped** | **NEVER re-pin.** The row also asserts `preserved_body == source.lines[start..end]` and the concatenation must reproduce `v1.6.38:PROJECT_MEMORY.md` / `DECISIONS.md`. Re-pinning the sha just moves the abort to `source-range mismatch`. Prepend a wrapper — the only legal repair. |
| `Companion/{Memory,Decisions}/ported-manifest.tsv`, `Companion/**/amendments-manifest.tsv`, `Companion/Decisions/V3/manifest.tsv` | the **raw** file, wrapper included | **Re-pin.** These pin provenance, not a reconstruction; six ported files already carry wrappers *inside* their hash. |

⚠️ **I nearly "fixed" that as a bug.** `verify_ported_decisions` hashes the raw `body` while calling
`exact_body(body)` on the very next line for its ADR-id scan — which reads exactly like an oversight. It is
not: `adr-ios-058/060/061/067` and memory `090/092` already carry wrappers counted **inside** their pinned
hash, so applying `exact_body` there would have broken six green rows. **The regression check —
"does any row this change touches already depend on the current behaviour?" — is what caught it, and it
cost one command.** A consistency argument about two lines of code is not evidence about the data.

Also note `Companion/Decisions/V3/manifest.tsv` and `Companion/Memory/amendments-manifest.tsv` are
**tracked, documented in `Companion/README.md`, and read by NO verifier.** Their drift is invisible to
`verify` by construction; only this entry's sweep sees it.

## Instance 4 (2026-08-08) — byte-faithful routing preserved a broken root-relative link

During `MISTAKES.md` compaction, I moved the old `MIS-IOS-009` index line byte-for-byte into this
nested detail file. Its Markdown target still began with `Companion/Mistakes/Active/`, which was
correct from the repository-root index and wrong from inside that directory. The post-edit
`compact_companion_docs.rb verify` caught it as a broken link before completion.

This is the exact recurrence already documented by instance 3: byte fidelity preserves relative-link
syntax, not the link's meaning after a move. The repair normalizes only the moved target to this
file's basename; the pre-pass line remains mechanically reconstructable by restoring the original
root-relative target during the round-trip check. The root-only link check then found five older
copies of the same defect in the two mistake-detail files touched by this pass; those historical
self-links were normalized mechanically to their local basenames as well.

## Index-line detail (routed 2026-08-08 by `companion-compact`, pass 12)

The prior iOS-index prose is preserved verbatim below; only its Markdown self-link target is
normalized to the local basename so it resolves after routing. The round-trip check restores the
original target before hashing. Nothing was summarised, merged, or dropped.

> - **[MIS-IOS-009](MIS-IOS-009-amended-a-hash-pinned-fragment-and-killed-the-verifier.md)** — wrote a correct amendment **inside** a hash-pinned routed fragment (`adr-ios-031.md`, `9430ef418`), so `compact_companion_docs.rb verify` aborted at `hash mismatch:` on manifest row 33 and **every later check silently stopped running for a day** — the ADR census, 91-fragment memory routing, 212-file link check, 279 pointer check, and the budget report that was holding a live 38%-over `CLAUDE.md` finding. The tree has a designed amendment surface (`<!-- COMPANION-CURRENT-NOTE-BEGIN/END -->`, stripped by `exact_body` before hashing) but the marker is invisible at the edit site. **A file whose path appears in a `manifest.tsv` with a `sha256` column has immutable bytes: prepend the wrapper, never edit the body — not even to append a pointer.** An `abort`-on-first-failure verifier is fail-open for everything after the abort; read its LAST line, not its first. **Instance 2 is the same failure with a different grammar:** four unescaped `|` quoted from shell commands into `KNOWN_ISSUES.md` table cells silently SPLIT those rows' fields (`\|` is the file's own convention). Generalised: **before amending any file, ask what MACHINE reads it besides a human — a manifest verifier, a GFM table parser, a census script — and verify STRUCTURALLY (per-row field count vs `HEAD`), not visually.** ⚠️ **TWO pinning conventions decide the repair:** `{Memory,Decisions}/manifest.tsv` hashes the **stripped** body and must NEVER be re-pinned (it also asserts a source-line range + full-document reconstruction); `ported-manifest.tsv` / `amendments-manifest.tsv` / `Decisions/V3/manifest.tsv` hash the **raw** file and MUST be re-pinned. Fixing the first abort revealed 14 broken links + 1 dead pointer hidden behind it since 2026-08-06 — **routing a file deeper silently breaks its root-relative links, and byte-for-byte fidelity preserves the breakage.** (×3)

---

## Instance 5 (found 2026-08-12; live since 2026-08-10) — the verifier has been fail-open for TWO DAYS, and nobody noticed because nothing announces it

**Found by:** a documentation subagent doing an unrelated job (authoring ADR-IOS-076), which tried to run
the verifier to check its own edit and could not get past the first check. **Not found by any gate** —
there is no gate; `verify` is run by hand.

**State.** `ruby Scripts/compact_companion_docs.rb verify` aborts immediately with:

```
hash mismatch: Companion/Memory/Current/089-action-queue-coalesces-gesture-intents-to-latest-per-field-adr-ios-057-2.md
```

Because `abort` is the first statement to fire, **every downstream check has silently not run since
2026-08-10**: the ADR census, memory routing/status, the linked-exactly-once check, the pointer check,
and the index budget report. Two days of companion edits — including a new ADR and several `Mistakes/`
entries written the same day this was found — went in unverified.

**Cause.** Commit `345c04a6f` (2026-08-10, *"fix(ios): coalesce immediate move undo"*) edited the
**preserved body** of a routed memory file: one bullet replaced by two, +2/−1. The knowledge itself is
real and worth keeping — a genuine move/undo coalescing update. It was written into the wrong kind of
surface.

**Why the obvious fix is WRONG, and this is the part worth remembering.** The instinct is to re-pin:
recompute the SHA, paste it into `Companion/Memory/manifest.tsv`, watch `verify` go green. That would
**destroy the proof rather than repair it.** The manifest hash is not a checksum, it is one leg of a
no-content-loss argument:

```
actual_sha == expected_sha                      # leg 1 — the hash
preserved_body == source.lines[start..end]      # leg 2 — byte-identity with v1.6.38:PROJECT_MEMORY.md
reconstructed == source                         # leg 3 — the whole file rebuilds byte-for-byte
```

`exact_body` strips only a leading current-note block; **everything else in a routed file must remain
byte-identical to its historical source range.** So re-pinning the hash merely moves the abort from
leg 1 to leg 2, and if someone "fixed" leg 2 as well, leg 3 — the actual guarantee that compaction lost
nothing — would be gone with no error to show for it. **A green verifier obtained by editing the
expectations is worth less than a red one.**

**The real repair is a routing decision, not a hash edit:** preserved bodies are immutable history;
new current knowledge needs an append-safe surface (a current-note block, or a new routed topic with
its own index line). That decision belongs to the owner, so it is recorded here and deliberately not
made unilaterally.

**The tell:** *I edited a file under `Companion/` and did not run `verify` afterwards* — and the
second-order tell, which is the one that cost two days: *`verify` printed one line and stopped, and I
read that as "one problem" rather than "all remaining checks are now disabled."* An `abort`-on-first-
failure verifier does not degrade gracefully; it goes from proving everything to proving nothing, and
the output looks almost identical.

**Countermeasure:** run `verify` **before and after** any `Companion/` edit, and treat a non-zero exit
as *"verification is OFF"*, never as *"one file is wrong."* ⚠️ In this repo's zsh, a piped
`ruby … | head` reports `head`'s status — `${PIPESTATUS[0]}` is a bash-ism and reads empty here — so
check the exit code unpiped or the abort will look like a success.

## Instance 5 — resolution (2026-08-12), and the SECOND defect the outage was hiding

The owner authorised the routing repair this entry deferred. It was carried out exactly as the rule
above prescribes, and the cost of getting it wrong is worth restating: the tempting fix — recompute
the SHA and paste it into the manifest — would have moved the abort to the byte-identity leg, and
"fixing" that too would have destroyed leg 3, the proof that compaction lost nothing, with no error
left to show for it.

**What was done.** Routed memory fragment **089** (`action-queue-coalesces-gesture-intents…`, in
`Companion/Memory/Current/`) was restored byte-for-byte from
`v1.6.38:PROJECT_MEMORY.md` lines 1005-1035 (the restored body hashes to the manifest's pinned
`18d40fdb…`, unchanged), and `345c04a6f`'s move/undo amendment was reproduced verbatim inside a
prepended `COMPANION-CURRENT-NOTE` wrapper. **No manifest hash was re-pinned.** No knowledge was
lost: the amendment is still present, still `rg`-findable, and now carries its own provenance.

**And then the outage turned out to be hiding a defect in the verifier itself.** With the abort
cleared, `verify` advanced and immediately failed on 27 repository pointers across two `PLAN_*.md`
files — every one of them a FALSE POSITIVE. `verify_repository_companion_references` scanned for
`Companion/<Tree>/….md` starting at `Companion/`, which discards a leading `../`, then resolved the
hit against `tabmail-ios/`. So a **correct** reference to the monorepo-root companion tree was
reported broken. A standalone probe resolved all 144 such references in the `PLAN_*.md` set with the
prefix honoured: **144 ok, 0 broken.** The scan now matches an optional `../` and resolves those
against the parent directory; `verify` reports 453 pointers checked, all existing.

That bug is documented in this entry's own preamble — the first draft of this file broke `verify` by
writing a correct root-tree path in full — and the standing workaround was to cite root-tree files by
bare id and explain why. **The workaround outlived the need for it by long enough to become
convention.** Nobody fixed the tool because the tool's output was never seen: it had been aborting
before that check on most days it mattered.

**The compounding lesson, which is the one to keep.** An `abort`-on-first-failure verifier does not
merely stop early — it *preserves* every later defect in amber. Two days of hidden checks concealed a
tool bug that had been mis-teaching the repo's own citation convention. When you repair the first
abort, do not stop at green: **read what the newly-reached checks say, and treat their first report
as evidence about how long they have been silent**, not as a fresh problem introduced by your fix.

**Also repaired in the same pass, found by looking rather than by any verifier:**
`Companion/Mistakes/manifest.tsv` listed `MIS-IOS-001`–`006` while the directory held `001`–`012`.
Six entries — including this one — were missing from their own index. That manifest has no `sha256`
column, so the mechanical sweep in this entry skips it (`next unless pi && si`), and **no script
reads it at all**; only `MISTAKES.md`, which was current, points at it. An index nothing verifies
drifts silently, which is the same failure mode as the one above with the alarm removed. Rows for
`007`–`012` were added and checked structurally: 12 ids matching the directory exactly, uniform
7-field rows, every path resolving.

---

## Instance 6 (2026-08-12, found and repaired 2026-08-13) — broke again the DAY AFTER instance 5's repair, by the session that had just read this entry

**Commit `458863e86`** ("Withhold remote image URLs from hidden email sections", the T8 / `IOS-PRIVACY-003`
fix) appended **one bullet** to the preserved body of
`Companion/Memory/Current/037-html-email-render-pipeline-autosizinghtmlview-must-stay-idempotent-adr-i.md`.
One line. `verify` aborted at `hash mismatch:` from that commit until the repair.

**Provenance, established by hashing rather than by reading the diff:**

| rev | `exact_body` SHA | |
|---|---|---|
| manifest pin | `8c614322…` | |
| `7172743b2` (pre-commit) | `8c614322…` | green |
| **`458863e86`** | `61368a99…` | **broke here** |

**Why this instance is worth its own section rather than a tally bump.**

- **Instance 5 was repaired on 2026-08-12 and this landed on 2026-08-12.** The countermeasure did not
  survive one day. The repairing session and the breaking session were both in this repo, hours apart.
- **The commit body is ~120 lines of unusually careful engineering prose** — it enumerates rejected
  alternatives, states failure direction, separates a foreign test census term, and names every new
  test. The author was demonstrably not being careless. **Care about the CONTENT is not care about
  the CONTAINER**, and this entry's tell is precisely that the container's constraint is invisible at
  the edit site.
- **It was found by a subagent doing an unrelated job** (authoring the P4 image-failure banner), which
  ran `verify` to check its *own* Companion edit — the same way instance 5 was found. **Twice now the
  finder has been an unrelated agent's incidental check, and never a gate**, because there is no gate.
- **The agent that found it then nearly made the mirror mistake**: it checked `Decisions/manifest.tsv`
  and `ported-manifest.tsv` for its own ADR, concluded "not pinned", and had **not** checked
  `Decisions/V3/manifest.tsv` — the *other* convention, which would have required the **opposite**
  repair (re-pin, not wrap). It got the right answer by luck and said so. **The two-convention table
  above is the part of this entry that most needs reading, and it is the part most easily skipped.**
- **`rc` was masked twice.** `ruby … | tail` reports `tail`'s status in this zsh, so a casual piped run
  showed `RC=0` while the real exit was `1`. Run it unpiped. This is the same trap already recorded in
  instance 5.

**The repair, done exactly as the rule prescribes.** The body was restored byte-for-byte from
`7172743b2` (proved identical to `v1.6.38:PROJECT_MEMORY.md` lines 399-434, hashing to the pinned
`8c614322…`), and the bullet was reproduced **verbatim** — extracted mechanically from
`git diff -U0`, never retyped — inside a prepended `COMPANION-CURRENT-NOTE` wrapper. **No manifest
hash was re-pinned.** Full mechanical sweep across every manifest afterwards: `mismatched=0`.

**And clearing the abort revealed a false claim the outage had preserved, which is this entry's
compounding lesson holding for the third time.** The restored bullet asserts that selecting a
different `.eml` is a fresh load *"(the coordinator reloads on `loadedPreviewFilename` change)"*.
**That mechanism does not exist:** `HTMLWebView.updateUIView`'s predicate is `htmlChanged ||
reloadChanged`, and `loadedPreviewFilename` is **assigned** inside that branch and **never compared**
anywhere in the tree. The bullet's *conclusion* is still true by a different route — the sheet is
`.sheet(item:)` over an `Identifiable` state, so each presentation remounts and loads via
`makeUIView` — so the T8 fix is unaffected and this is a documentation defect, not a behaviour one.
The correction is recorded in the wrapper alongside the verbatim bullet rather than by editing it.

**Newly-reached checks, reported per this entry's rule that their first output is evidence of how
long they were silent, not a fresh problem:** with the abort cleared, `verify` advanced through all
nine checks — PROJECT_MEMORY and DECISIONS both reconstructing byte-identical, ADR census 55, ported
decisions 9, memory routing 91, ported memory topics 2, 398 Markdown links, 484 repository pointers,
0 un-routed duplicate bodies — and now exits 1 **only** on the budget verdict: root `MISTAKES.md`
**+87%**, `CLAUDE.md` +5%, iOS `PROJECT_MEMORY.md` +24%, iOS `DECISIONS.md` +10%, iOS `MISTAKES.md`
+36%, scope total over. That verdict had been invisible for the whole outage.

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-009](Companion/Mistakes/Active/MIS-IOS-009-amended-a-hash-pinned-fragment-and-killed-the-verifier.md)** — edited a hash-pinned fragment in place, killed `compact_companion_docs.rb verify`, and hid later checks; inspect manifest grammar, use the correct wrapper/re-pin convention, escape GFM table pipes, and re-resolve links after routing. **×6 broke it again the DAY AFTER ×5's repair** — one bullet appended to pinned memory `037` by `458863e86`, found by an unrelated subagent's incidental `verify`, never by a gate; **`ruby … | tail` masks rc in zsh — run it UNPIPED**; and the finder had checked two manifests but not `Decisions/V3/manifest.tsv`, the convention needing the OPPOSITE repair. (×6)
```

---

## Instance 7 (2026-08-13) — I killed the verifier with a GLOB in a code comment, by the exact mechanism the header of this file warns about

The Phase-1 countermeasure for root `MIS-039` instance 2 was a warning comment above
`Scripts/compact_known_issues.rb`'s `generate`, describing its second destruction mechanism. One
sentence of it read:

```text
# silently deleted, and the script exits 0 printing a success line. It also `File.delete`s every
# `…/KnownIssues/ios-*.md` absent from the archive (the `Amendments/`
# subdirectory escapes only because that glob does not descend into it).
```

`verify_repository_companion_references` scans every `.md`/`.rb`/`.swift`/`.sh`/`.ya?ml` file for
anything shaped like `Companion/{Memory,Decisions,Process,Rules,Mistakes}/….md` and aborts the whole
run when the target is not a file. **A glob is not a file.** So `verify` began failing with

```text
broken repository companion references:
Scripts/compact_known_issues.rb: …/KnownIssues/ios-*.md
```

and — this is the damage, not the message — **every check after it stopped running**: the ADR
census, memory routing, ported-decision hashes, the 405-file link check, and the budget report. The
Phase-1 commit therefore landed with the verifier fail-open, exactly as instances 5 and 6 did.

**What makes this a recurrence and not a new id:** the header block of *this file*, written after
instance 4, already states the mechanism verbatim — *"`verify_repository_companion_references` scans
every tracked and untracked file for the literal substring `Companion/<Tree>/…​.md` … so a correct
relative path to the root tree written out in full aborts the verifier. That is this very mistake,
one level up: the first draft of this file broke `verify` the same afternoon it was written to
describe breaking `verify`."* I read this entry during the same session — it is one of the 13 index
lines I routed — and still wrote a bare `…/KnownIssues/ios-*.md` into a Ruby comment forty
minutes later. The countermeasure is documented, correct, and did not fire, which is the property
that matters.

**Second-order detail worth keeping:** the shape that broke it was not a *wrong* path. It was a path
that is not a path at all — a glob standing in for a set of files, in prose describing what a
command deletes. Instance 4's variant was a byte-faithful *correct* link resolved from the wrong
base. Both are "the checker is a substring scanner and does not know what your sentence meant".

**Repair (2026-08-13):** the sentence now names the directory through its constant,
`DETAIL_DIR_REL`, and describes the glob in words. The comment also now carries a note explaining
*why* it is written that way, so the next editor does not helpfully expand it back.

**Detection:** not by a gate. It surfaced because the `companion-compact` Stage-4 protocol requires
running `compact_companion_docs.rb verify` **unpiped** and reading its output — the same route that
found instance 6. Three of the last four instances were found by someone running `verify` for an
unrelated reason.

### Mechanical check

Before committing any file that mentions a `Companion/` path in prose or a comment:

```bash
ruby Scripts/compact_companion_docs.rb verify   # UNPIPED — `| tail` masks rc in zsh
# and specifically:
rg -n 'Companion/(Memory|Decisions|Process|Rules|Mistakes)/[^ `"'"'"']*\*' -g '!Companion/**'
```

A `*` anywhere inside a `Companion/…​.md`-shaped substring means the reference checker will try to
`File.file?` a glob and abort.

---

## Pre-compaction index line (verbatim, 2026-08-20, pass 5)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 19% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced
block so its index-relative link is not re-resolved from this directory, because the index
line had accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-009](Companion/Mistakes/Active/MIS-IOS-009-amended-a-hash-pinned-fragment-and-killed-the-verifier.md)** — edited a hash-pinned fragment in place, killed `compact_companion_docs.rb verify`, and hid every later check behind its `abort`. **×6 broke it again the DAY AFTER ×5's repair**, found by an unrelated subagent's incidental `verify`, never by a gate. **`ruby … | tail` masks rc in zsh — run it UNPIPED.** ⚠️ **TWO pinning conventions decide the repair:** `{Memory,Decisions}/manifest.tsv` hash the **stripped** body and must NEVER be re-pinned; `ported-manifest.tsv` / `amendments-manifest.tsv` / `Decisions/V3/manifest.tsv` hash the **raw** file and MUST be re-pinned. ⚠️ **a GLOB in a comment aborts it too** — `Companion/…/ios-*.md` is not a file. (×7)
```

---

## Instance 8 (2026-08-18, repaired 2026-08-20) — the SECOND verifier, and the routed file that already warned about it

**Commit `a6f395517`** ("Cover the subscription-presentation deletion gate and drop dead imports")
appended a two-line *citation freshness* note to
`Companion/Process/Current/KnownIssues/ios-billing-001.md` — as **bare Markdown**, with no
`KNOWN-ISSUES-AMENDMENT-BEGIN` / `-END` wrapper. That file is **generated and byte-frozen**: it is
regenerated from a hash-pinned archive and byte-compared by `Scripts/compact_known_issues.rb verify`,
which failed from that commit until `fb5d498a2` on 2026-08-20.

**Content was, once again, not the problem.** The note is true and useful: it records that the
`AppStore.showManageSubscriptions(in:)` `catch` moved into
`StoreKitManager.presentManageSubscriptions()` and that both views now reach it through
`SubscriptionManagementPresentation.failed`, substance unchanged. It is exactly the kind of citation
refresh this repo asks for. It was written into the wrong kind of surface — instance 1's defect, five
instances later, in a **different tree with a different verifier**.

**What makes this instance worth its own section rather than a tally bump.**

- **A second byte-frozen tree now exists, and this entry only ever named the first.** Everything above
  is about `Companion/{Memory,Decisions}` and `compact_companion_docs.rb`. The KnownIssues register is
  governed by a *separate* script with a *separate* archive hash, and the mechanical sweep in this
  entry does not look at it (`Companion/Process/Current/KnownIssues/manifest.tsv` is matched by the
  glob, but the sweep's `next unless pi && si` skips manifests without a `sha256` column). **Asking
  "is this file hash-pinned?" of the wrong manifest returns a true answer to the wrong question.**
- 🚨 **The knowledge existed, in this repo, in a routed file, and was not consulted.**
  `Companion/Memory/Current/115-known-issues-register-is-byte-frozen-and-has-no-append-path.md`
  documents the freeze, the append path, and the wrapper by name. It is `rg`-findable on
  `known.issues`, `byte-frozen`, `AMENDMENT-BEGIN`, and `ios-billing`. The routing protocol that would
  have surfaced it — derive terms from the files you are about to touch, `rg -ni` the companion tree,
  read every match in full — is mandatory and was not run for a two-line documentation edit. **The
  failure here is not ignorance of the rule; it is that a small edit does not feel like a task that
  needs the protocol.** Instance 7 is the same shape (the countermeasure was in this file's own
  header, read the same session, and did not fire). That is now twice, and it is the strongest
  argument in this entry for a *gate* rather than more prose.
- **It was found by neither verifier's owner.** `compact_companion_docs.rb verify` stayed green
  throughout — it does not read the KnownIssues tree — so the repo's most-run verifier gave a clean
  bill of health for two days across a broken one. **A green verifier is evidence only about the tree
  it reads.**

**The repair (`fb5d498a2`)** wrapped the existing note in the sentinels, byte-for-byte, without
touching the generated body. The shape it had to use is *not* the shape the tree's nine other
amendment blocks use, and that difference is recorded in
`Companion/Memory/Current/115-known-issues-register-is-byte-frozen-and-has-no-append-path.md`:
head-position blocks open with content directly, because the `# TITLE\n\n` above supplies the blank
line; a **tail**-position block needs a blank line *inside* the block and none before `BEGIN`, the
shape `KNOWN_ISSUES.md`'s own *Post-freeze amendments* block uses. Copying the nine-file majority
shape into a tail position fails the byte comparison.

### Mechanical check — updated for the second tree

The sweep earlier in this file is necessary and **no longer sufficient**. Before committing any edit
under `Companion/`, run **both** verifiers, **unpiped**:

```bash
ruby Scripts/compact_companion_docs.rb verify ; echo "rc=$?"   # Memory/Decisions trees
ruby Scripts/compact_known_issues.rb   verify ; echo "rc=$?"   # KnownIssues register  <- added by instance 8
```

And before editing a file under `Companion/Process/Current/KnownIssues/`, treat it as generated:

```bash
# Is this file regenerated + byte-compared?  (the register's own manifest, not the Memory sweep's)
rg -n --fixed-strings "$(basename "$REL_PATH")" Companion/Process/Current/KnownIssues/manifest.tsv

# The ONLY legal amendment shape.  Head position (content follows BEGIN directly):
#   <!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->
#   > the amendment
#   <!-- KNOWN-ISSUES-AMENDMENT-END -->
# Tail position needs a blank line INSIDE the block and none before BEGIN — see memory topic 115.
```


---

## Instance 9 — 2026-09-02, and the tell was *"this line is now wrong"*

**What happened.** The oversized-metadata quarantine stop-gap added a fourth conjunct to
`pendingBodyCount`'s predicate and changed how an oversized body terminates. Memory fragment
`030-backfill-fast-sync-completion-gate-…md` stated the OLD predicate and said oversized bodies
"confirm-empty" — a conflation that is now a data-integrity-rule-1 violation. So I edited the two
lines in place. Both edits were correct; the location was not. The fragment is row `order 30` of
`Companion/Memory/manifest.tsv` with `sha256 a4cd0ab1…`, and `exact_body` strips only a LEADING
`COMPANION-CURRENT-NOTE` wrapper, so my bytes were hashed. `verify` `abort`ed at
`verify_manifest("PROJECT_MEMORY.md", …)` — its FIRST gate — so the `DECISIONS.md` manifest, the ADR
census, ported-decision and ported-memory checks, memory links, Markdown links, repository companion
references and the index-budget report all silently stopped running.

**The tell, and it is the same tell every time:** *"this documented line is now wrong, and I am the
one who made it wrong."* That is exactly the moment the wrapper exists for, and exactly the moment
the urge to just fix the sentence is strongest. Being RIGHT about the content is not evidence that
the edit is legal — instances 5 and 8 were both correct content too.

**Repair (the prescribed one, unchanged since instance 5).** Restore the preserved body byte-for-byte
from the pinned source, move the amendment into a LEADING
`<!-- COMPANION-CURRENT-NOTE-BEGIN --> … <!-- COMPANION-CURRENT-NOTE-END -->` block, do **not**
re-pin `manifest.tsv`. Verified: the stripped body hashes back to `a4cd0ab1…`, and `verify` now
reports both trees `byte-identical` with `grep -c "hash mismatch"` = 0.

⚠️ **One trap while verifying this repair:** run the verifier from the PRIMARY checkout, or expect a
false failure. `verify`'s Markdown-link check resolves `PROJECT_MEMORY.md`'s `../CLAUDE.md` against
the monorepo root, which exists at `tabmail-ios/../CLAUDE.md` but NOT at
`.worktrees/<name>/../CLAUDE.md`. In a worktree that link check fails and `rc=1` even when every hash
is clean — so read the failure lines, never just the return code.
