# A Swift `String` comparison does not reproduce SQLite's BINARY collation — and is not even a total order

**Status:** Current · **Authored:** 2026-08-06 · **Landed:** `33b4d3cf6`
**Related:** [[106-a-filter-after-the-limit-narrows-the-page-instead-of-selecting-it]] (`IOS-SCROLL-002`,
the defect a loose keyset cursor recreates) · `InboxOrdering` · `InboxListReader.gather`

## The invariant

Wherever Swift code and a SQL `ORDER BY` must produce **the same arrangement of the same rows**, the
Swift comparator has to compare **UTF-8 bytes**, not `String`s:

```swift
a.id.utf8.lexicographicallyPrecedes(b.id.utf8)   // matches SQLite BINARY
a.id < b.id                                       // DOES NOT
```

## Why — three separate facts, each sufficient on its own

1. **SQLite's default collation for a `TEXT` primary key is BINARY**, i.e. byte-wise over the UTF-8
   encoding. Verified directly: `pragma_index_xinfo('sqlite_autoindex_messageHeader_1')` reports
   `coll=BINARY`, and `ORDER BY id` matches `ORDER BY id COLLATE BINARY` byte-for-byte.

2. **Swift `String` uses Unicode canonical ordering, and strict opposites exist** — this is not a
   theoretical edge about exotic code points:
   - `U+212B` ANGSTROM SIGN (canonically `U+00C5`) sorts **before** `U+0100` in Swift and **after**
     it in bytes.
   - Decomposed Hangul `U+1100 U+1161` (canonically `U+AC00`) behaves the same way.

3. **Swift's order is not even antisymmetric over this domain.** NFC `é` (`U+00E9`) and NFD `e´`
   (`e U+0301`) are **two distinct BINARY primary keys** that Swift reports **equal**. So no SQLite
   collation can reproduce Swift's ordering while `id` remains a usable primary key — the mismatch is
   only fixable on the Swift side.

**This is reachable, not hypothetical.** Message ids are composed from folder paths, and APFS/HFS+
hand back **NFD** for non-ASCII names, so a Japanese, Cyrillic, or accented folder is enough.
(Honest bound: every provider whose folder identifiers TabMail controls emits ASCII today, so this
closed a latent hole rather than an observed field defect.)

## Why the fix went on the Swift side and not the SQL side

Stated as the counterfactual, because "change the SQL to a Unicode collation" is the obvious
alternative and it is wrong four ways:

1. **Not expressible** — see fact 3. Swift's relation is not antisymmetric here, so no collation
   reproduces it.
2. **Index regression** — a non-BINARY `ORDER BY`/keyset cannot use the primary-key index, which
   collapses the reader's deliberately sargable `range AND (range OR tie)` predicate into a
   full-folder scan plus a temp B-tree.
3. **Cross-process hazard** — custom collations are registered per-`Configuration`, and the NSE opens
   its own pool. A collation the main app registers does not exist for the extension.
4. **Wrong direction of safety** — BINARY is what is already *persisted*; the Swift comparison is
   pure computation. Move the derived thing, never the stored thing.

## What it costs when it is wrong

`InboxViewModel.loadMoreMessages` reads its keyset cursor from `loadedMessages.last`. If the Swift
arrangement disagrees with the reader's, `last` is not the maximal row under the reader's order, the
cursor predicate goes **loose**, already-loaded rows are re-admitted, they consume slots in the
per-folder SQL `LIMIT`, and are discarded only afterwards — recreating `IOS-SCROLL-002`. The short
page then sets `hasMoreMessages = false` and **the rest of the mailbox stops being reachable by
scrolling.**

## Mechanical check

```bash
# Any Swift comparator that must agree with a SQL ORDER BY on a TEXT column.
rg -n 'lexicographicallyPrecedes|\.id <|\.id >' TabMail/ Shared/ TabMailNotificationService/
```
The generalisation, which is the reason this is a memory topic and not a code comment: **any**
Swift-side ordering that must agree with a SQLite `ORDER BY` over `TEXT` has this bug by default,
because `<` on `String` is the obvious thing to write and is silently wrong.
