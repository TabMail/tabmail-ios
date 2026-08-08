# MIS-IOS-009 — I amended a hash-pinned Companion fragment in place, and the verifier died on line one

**Class:** documentation / verification
**Severity:** high
**First seen:** 2026-08-04 · **Recurrences:** 4 · **Status:** Active
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
