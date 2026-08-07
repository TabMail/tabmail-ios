# `PROJECT_MEMORY.md` § How to use this index — preserved wording

**Status:** Current (preserved source text) · **Routed:** 2026-08-06 by `companion-compact`
**Source:** `tabmail-ios/PROJECT_MEMORY.md` § *How to use this index*

Routed under the skill's Stage 3 *duplicated invariants* rule: the five-step protocol below is a
near-verbatim duplicate of root [`../../../../CLAUDE.md`](../../../../CLAUDE.md)
§ *Companion Routing (MANDATORY BEFORE EVERY TASK)*, which is itself an always-loaded file — so the
requirement is still in every agent's context on every task, stated once instead of twice. The
**normative** location is root `CLAUDE.md`; where the two differ, root `CLAUDE.md` wins. This file
exists so the iOS-specific wording (its `rg -ni` invocation naming `PROJECT_MEMORY.md DECISIONS.md
MISTAKES.md Companion/`, and the "do not grow this file into an unconditional archive" clause) stays
searchable. Nothing was summarised, merged, or dropped.

<!-- BEGIN VERBATIM -->
**This file is a router, not an archive.** Every topic below is preserved in full under
[`Companion/Memory/`](Companion/Memory/manifest.tsv); the manifest carries a `sha256` per fragment.
Load only the topics your task mechanically matches.

1. Build search terms from the request, named files/symbols, subsystem, provider, invariant, and likely defect class.
2. Run `rg -ni '<terms>' PROJECT_MEMORY.md DECISIONS.md MISTAKES.md Companion/` and a code census with `rg`.
3. Read each matched detailed topic, ADR, process, rule, and mistake document completely before acting.
4. Record every required routed path in any plan, implementation brief, or review prompt.
5. Update the relevant detail file and its index row when durable knowledge changes; do not grow this file into an unconditional archive.

Current entries govern. Historical entries preserve evidence but do not override current rules or active ADRs.
Do not use Markdown imports as a context shortcut; imported text still consumes startup context.
<!-- END VERBATIM -->
