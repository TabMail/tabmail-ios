## ADR-IOS-093: Email Search Query Text Reaches FTS5 as Text (port of ADR-NF-011)

**Status:** Active (2026-10-22, tabmail-ios #246)

**Context:** `SearchQueryParser.buildFTSMatch` was a Swift port of the query builder in the released
tabmail-native-fts 0.11.8 helper, with its failures: it quoted only words containing `- @ : + .`, so
other punctuation (`50% off`, `R&D`, `budget, plan`, `hello!`, `f(x)`) and the capital operators
(`NOT budget`, `invoice OR`, `invoice OR receipt` beside a synonym group) reached FTS5 as syntax, and a
phrase beside a synonym group (`"jane doe" meeting`) was an implicit AND next to parentheses. Each
failed with `fts5: syntax error`, which `EmailSearchTool` returned to the model as an error, and the
typed search showed nothing. It also deleted apostrophes (`Don't` searched `Dont*`, never finding
"Don't", which the tokenizer indexes as `don` `t`). Native-fts fixed all of this in #14 and #31
(ADR-NF-011, merged 2026-10-22 as 5a50d99); the owner asked for iOS to port the final rules once,
after both (2026-10-21).

**Decision:** `buildFTSMatch` is a line-for-line port of native-fts `fts::query::build_fts_match`,
with the mail columns (`QUERY_COLUMNS`) built in and synonyms always on, as every iOS caller used
them. Every rule of ADR-NF-011 applies, read on Unicode scalars as Rust reads chars, with lengths in
UTF-8 bytes:

- Every word and `"phrase"` is an FTS5 string; a word or phrase with nothing the tokenizer indexes
  (`L* N* Co`) is dropped; a NUL is a separator; any White_Space separates words.
- A capital `AND`/`OR`/`NOT` between two written terms stays the operator; anywhere else it is
  dropped. At most `SearchConfig.searchMaxKeptNots` (100) `NOT`s are kept (FTS5's depth limit).
- A word with an inner apostrophe as its only punctuation searches both spellings,
  `("don't" OR "dont"*)`; one possessive `'s` is removed; quote marks around a word are removed.
- The automatic prefix star is decided per run of words, from 4 UTF-8 bytes
  (`SearchConfig.autoPrefixMinBytes`), so `会議` and `Zür` are prefixes.
- Only `subject from from_ to to_ cc bcc body` scope, typed as `name:` (ASCII case-insensitive).

The hybrid column filter (`SearchIndex.extractColumnScopeFilter`) is ported too: it reads the
expression's UTF-8 bytes, as native-fts `extract_column_scope_filter` does, and cuts only at ASCII
bytes. It walked Characters, and once every word is a string a quote can share a Character with a
combining mark after it or a Prepend character (U+0600) before it, so the filter cut inside a string
and FTS5 refused it. `queryHasColumnScope` is deleted: an empty filter already means no field.

**Consequences:**
- Behaviour changes, all as in native-fts and approved there by the owner (2026-10-18/21/22):
  `msgId:` no longer scopes (undocumented, unused); `from :` with a space before the colon no longer
  scopes; a field's value keeps its apostrophe (`from:o'brien` searches `o'brien`, not `obrien`);
  `subject:*` and `subject:""` write nothing instead of a term that matched nothing.
- The kept-`NOT`-and-hybrid-vectors limitation of native-fts #21 applies here too: the column filter
  keeps only scoped terms, so a kept `NOT` is not applied to vector candidates.
- Tests: `SearchQueryBuilderTests` pins the expressions to the strings of native-fts
  `query::tests`; `SearchQueryTextSearchTests` runs native-fts' `db::tests` searches on real FTS5
  shards (a far-future year, bounded by date): punctuation and operator text never fails, both
  apostrophe spellings and never "Don took", possessives, `NOT` excluding only the word typed,
  operators, whitespace separators, private-use characters, the per-run prefix star, each
  documented field in keyword search and in the hybrid vector filter (also beside text that joins
  a quote into one Character, a partly typed value, and every typed field at once), `l'ét` finding "Létude",
  255 to 300 `NOT`s answering, and 3,000 seeded random queries through keyword and hybrid search.
- Known differences, filed: a word made only of a combining mark that native-fts's older Unicode
  category tables do not know (U+11F00, U+1CF2 and others) is written differently by the two
  builders (tabmail-ios #255); trimming many leading quote marks from one word takes quadratic time
  (#256). Both are rare input. A field name typed with the long s (`ſubject:`) was a field to the
  old builder and is a word to both builders now (#267), also rare input. A query with no
  searchable text (`_`, `""`, `subject:*`) writes an empty expression, and `SearchIndex.search`
  then runs no vector search, where the old builder's expression reached hybrid search and
  native-fts still runs one (#266).
- A change to the native-fts builder must be ported here in the same train (ADR-IOS-008).
