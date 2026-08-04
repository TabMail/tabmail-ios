## v3 provider-id action-queue forward-port — authoritative resume state (2026-08-02)

**The plan is now hierarchical. Load only what your task needs.**

| file | load it |
|---|---|
| `PLAN_IOS_REFACTOR_V3.md` (62 KB) | **always, first** — live state, board census, rules R0–R4, verification baseline, build recipe, retained lessons, and the ROUTING INDEX |
| `PLAN_IOS_REFACTOR_V3/PLAN_V3_*.md` (11 files, 350 KB) | **on demand only** — the frozen §0–§11, split by section and by §4 tier, plus the live Stage D/E1 inputs |

The root file's ROUTING INDEX says which part answers which question. Do not read the parts
speculatively and **do not re-merge them** — the whole point is that a routine turn loads ~62 KB
instead of ~690 KB. A dispatch brief must name the part file it required; "I read the plan" is no
longer a meaningful claim on its own.

**The per-commit history is NOT in the plan.** It was removed on 2026-08-02 (~277 KB: BFT build
cycles, freeze/refreeze SHA-256 chains, run tallies, superseded R3A/R3B/R3C review rounds,
per-item landing reports). Every `v3` commit carries a full executive-summary body instead —
outcome, invariant impact, verification counts, and per-change PORT/SUBTRACT/INVENT. To reconstruct
any landed item: `git log 07a4bb703..HEAD`, `git show --stat <sha>`, `git log --all --grep='T2\.8'`.
The `/tmp/r3c-*.log` and `/tmp/*-freeze-report.md` artifacts those deleted paragraphs cited are
gone (tmpfs); do not chase them.

**Current state.** Branch `v3`, HEAD `583de7a5d`, never pushed, index empty, no build running.
**PAUSED BY OWNER — resume only on explicit owner direction.** R3C is landed (as the v74 blanket
purge). Last landed: **T4.T2** `583de7a5d` (test-only). Next recommended: **T5.9** — scoped in the
plan root, NOT STARTED. Then **T4.T1**. T4.O5 deferred (premise stale/unreachable). The full
verification gate and the cross-model audit train have **not** run.

**Verification baseline: 7,994 tests / 1,085 suites / 0 hard failures / 1 known issue @ `35d5b2814`,
0 production warnings.** ⚠ That is the last *measured* full suite — T3.11, T4.O3, T4.O1, T4.O4,
T4.O2, T3.6 and T4.T2 each deferred theirs to the final broad gate, so the tree's true green state
is unmeasured across seven landed commits. Counting traps (macro-expansion warnings fall in neither
path bucket; two suites share one display name; reconcile the TOTAL count because a `fatalError`
truncates a run that still reads clean) are in the plan root.

**Durable discipline, unchanged.** Every dispatch and review reads the exact relevant `v2final`
code **and history** first, and classifies each change **PORT** / **SUBTRACT** / census-proven
**INVENT** (marked `⚑ NO REFERENCE — INVENTED`). Reject "R0 checked" without exact paths, enclosing
symbols/control flow, and commit hashes. Prove reachability before escalating an edge case into
architecture; use a sound `v2final` answer rather than parallel authority, lifecycle, recovery, or
compatibility machinery. **C3 — never mutate the wrong message — is absolute**; fail closed and let
sync reconcile. Legacy `pendingOperation` compatibility is not required, but authored
Draft/body/recipient/attachment/ChatTurn bytes and Outbox sends are never migration-discardable.
The surviving invention census is exactly **two**: the minimal agent-versus-Send fence with its
immutable snapshot, and the v74 blanket `PendingOperation` purge. No third invention is authorized.

Roles are defined once in `../CLAUDE.md` § *Common Cross-Model Workflow* — the main session
orchestrates, implements via its own subagents, and judges; the other model is the read-only
adversarial vetter. Do not restate them per-project or pin them to a model.

Preserve every logical commit and hash: no rebase, squash, fixup, amend, or history rewrite. Every commit is cryptographically
signed, DCO `-s`, carries an executive-summary body, and is **never pushed by an agent**.

---

