# iOS Mistakes — routed detail

Detail layer for `tabmail-ios/MISTAKES.md`. Entries carry stable `MIS-IOS-###` ids.

**Conventions, entry format, the `Retired/` rule, and the recording obligation live in the monorepo
root's Mistakes `README.md`** (sibling of the root `MISTAKES.md`, two levels above this repo) — one
definition, one place. This file adds only what is iOS-specific.

## Scope split

- **Root `Companion/Mistakes/`** — cross-cutting classes: design process, review discipline,
  citation and census, agent operations, testing, secrets. Most iOS defects are *instances* of those
  classes, so search the root tree too.
- **Here** — mistakes whose mechanism is iOS-specific: GRDB migrations, IMAP sync windows and
  identity, the action queue, XcodeGen/signing, and the test-bundle traps.

**Cross-references to root entries are written as plain ids (`root MIS-013`), never as relative
links** — and this rule covers *paths in prose* too, not just markdown links.
`Scripts/compact_companion_docs.rb verify` scans raw bytes for the substring `Companion/Mistakes/…`
and resolves every hit against the **iOS** repo root. A relative path to the monorepo root's tree
contains that substring, so it is reported as a broken reference even though it resolves correctly
on disk. Ids need no path — the root index is always loaded.

*(This README tripped that trap on its first draft, which is why the rule is stated here rather than
left implicit.)*

## Templates

Use the root tree's `TEMPLATE.md`. Write **the tell** first: the first-person symptom that precedes
the mistake, not the rule that forbids it.

## Before adding an entry

`rg -ni` both trees. If the mistake already has an entry, **increment its `Recurrences`** and append
the new instance rather than creating a second entry — a recurrence is evidence the existing
countermeasure does not work, which is worth more than a new file.

Regenerate `manifest.tsv` after any change so it cannot drift from the files.
