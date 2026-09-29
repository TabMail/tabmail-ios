# MIS-IOS-025 — I called a content-key read a bug from a note, without reading the key's mint

**Class:** identity / keying · evidence
**Severity:** low (caught by a test I wrote to prove the bug, before commit; cost one build cycle and a false mistake entry)
**First seen:** 2026-09-29 · **Recurrences:** 1 · **Status:** Active
**Related:** memory `project_stable_id_keying_invariant` (now carries a stage check) · `Shared/Keys/ContentKey.swift` `ContentKey.forHeader` · `MessageContentStore.capture` · ADR-IOS-086

## The tell

A remembered architectural fact ("headers are UID-keyed, FTS is RFC-keyed") says the line in front
of me is wrong, and I start writing the fix and the postmortem before opening the function that
mints the key. The fact is phrased as settled; the code implementing it is staged.

## What actually happened

ADR-IOS-086 reads the related email's body from the search index with
`ContentKey(rawValue: message.id)`. From the note, I concluded the read missed every IMAP message
(RFC-keyed content), routed it through `MessageContentStore.capture`, and wrote a test asserting
the IMAP key differs from the header id and carries the RFC Message-ID. The test failed:
`ContentKey.forHeader` is at "STAGE B", byte-identical to the header id, its `rfc822MessageId` and
`space` parameters deliberately unread until Stage E1. The original read found the body.

Kept: the read through `MessageContentStore.capture` (the key the stores write under, today and
after E1), with a test that the key is the one `capture` mints, for an IMAP and a Gmail account.
Dropped: the claims that the header id misses.

## The rule

Before calling a key, id or address wrong, read the function that mints it in the tree you are
changing, and write the test that shows the miss. A note about keying describes a target unless it
names the stage. Still read content stores for a header via `MessageContentStore.capture`, never
`ContentKey(rawValue: header.id)`, so the read follows the migration.
