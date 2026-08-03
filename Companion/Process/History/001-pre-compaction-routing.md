## Companion Routing (MANDATORY BEFORE EVERY TASK)

Before starting any task in this project, always read these files in full:

**Global (parent directory):**
- **`../CLAUDE.md`** — Global rules that apply to all subprojects.
- **`../PROJECT_STRUCTURE.md`** — Monorepo layout, tech stack, component relationships.
- **`../PROJECT_MEMORY.md`** — compact cross-cutting knowledge and workflows.
- **`../DECISIONS.md`** — compact cross-cutting architectural decisions.

**This project:**
- **`PROJECT_STRUCTURE.md`** — Directory tree, entry points, sub-component map.
- **`PROJECT_MEMORY.md`** — compact mandatory iOS memory index and routing table.
- **`DECISIONS.md`** — compact mandatory active-ADR catalog and routing table.

After loading those indexes, derive search terms from the request, named files/symbols, subsystem, provider, invariant, failure mode, and referenced plans/ADR IDs. Run a mechanical `rg -ni` search across `PROJECT_MEMORY.md`, `DECISIONS.md`, `Companion/Memory`, and `Companion/Decisions`, plus a code census. **Read every matched topic and ADR file in full before planning, editing, reviewing, or answering.** Follow related entries when they govern the same invariant.

Every plan, implementation brief, and review prompt MUST enumerate the exact routed topic/ADR files required for its scope. Update the relevant detail file and its index row when durable knowledge changes. Preserve superseded/history material in its routed directory. Do not use Markdown `@imports` as a context shortcut; imported text still consumes startup context. The old requirement to read every historical companion byte on every task is replaced by this mandatory index-plus-search protocol; universal safety rules remain always loaded.

---
