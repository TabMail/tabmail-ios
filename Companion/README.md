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
