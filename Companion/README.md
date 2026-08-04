# iOS Companion Document Hierarchy

The mandatory root files `CLAUDE.md`, `PROJECT_MEMORY.md`, and `DECISIONS.md` are compact routing indexes. Detailed source material lives here and remains mechanically searchable with `rg`.

## Preservation record

- Source revision: `v1.6.38`
- Original `PROJECT_MEMORY.md`: 1039 lines, 347488 bytes
- Original `DECISIONS.md`: 2000 lines, 311795 bytes
- Memory fragments: 91
- Decision fragments (including foundation and template): 57
- Forward-ported decision bodies absent from `v1.6.38`: 9 (see `Companion/Decisions/ported-manifest.tsv`)
- Forward-ported memory topics absent from `v1.6.38`: 2 (see `Companion/Memory/ported-manifest.tsv`)

`Scripts/compact_companion_docs.rb verify` reconstructs both source documents in original order from the manifests, verifies every fragment hash, checks ADR-definition/index uniqueness, confirms every detailed memory topic is linked, validates local Markdown links, and checks every repository `Companion/…md` pointer. The explicitly delimited current-routing notes in three detail files are index wrappers: verification removes only those wrappers before comparing the preserved source bodies. The forward-ported ADR bodies are hash-verified against `ported-manifest.tsv` and excluded from the source-document census, because they are not part of `v1.6.38:DECISIONS.md`. The process/rule hierarchy is generated and byte-verified separately by `Scripts/compact_ios_rules.rb`.

## Maintenance

Search the mandatory indexes and the complete hierarchy before acting. Read every matched topic, ADR, process, or rule in full. Preserve stable ADR identifiers. Put superseded or historical material in its routed directory rather than deleting it. Do not move the same material into unconditional rule files or Markdown imports.

`generate` is the one-time, revision-pinned extraction command for this compaction and destructively rebuilds `Companion/` from `v1.6.38`. Do not run it after the compaction lands. `verify` is the landing proof against that source revision, not a permanent ban on later documented amendments; future knowledge updates edit the routed detail and compact index normally.

## Post-`v1.6.38` amendments (2026-08-04 compaction pass)

Knowledge authored **after** `v1.6.38` has no byte-identical twin at the pinned source revision, so it
cannot live in `Companion/Memory/manifest.tsv` or `Companion/Decisions/manifest.tsv` — those two
manifests reconstruct `v1.6.38:PROJECT_MEMORY.md` and `v1.6.38:DECISIONS.md` **exactly**, and an extra
row breaks the reconstruction. Such material is routed with its own manifest instead:

- `Companion/Memory/amendments-manifest.tsv` — fragments `094`–`099`, cut byte-for-byte from
  `508e0e468:PROJECT_MEMORY.md` lines 141–347 (the former *Retained inline* section).
- `Companion/Decisions/V3/manifest.tsv` — the v3-authored records, cut byte-for-byte from
  `508e0e468:DECISIONS.md` lines 123–162 and 173–667: the ADR-IOS-026B supersession record and
  **ADR-IOS-068 … ADR-IOS-072**.

**`Companion/Decisions/V3/` deliberately sits outside `Companion/Decisions/{Active,Superseded,Deferred}/`.**
That triple is the ADR *census surface*: `verify_adr_census` requires the set of `## ADR-IOS-…`
definitions found there to equal the set defined by `v1.6.38:DECISIONS.md`. ADR-IOS-068–072 are not in
that source document, so filing them under `Active/` would fail the census. Status is preserved one
level down (`V3/Active/`, `V3/Superseded/`). Do not "tidy" these files up into the census directories.

