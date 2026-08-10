# Known-issue detail routing

`KNOWN_ISSUES.md` is the fast executive index for the 17 current open or accepted limitations. This directory preserves one readable detail file per known-issue id: 138 main-register records plus 2 historical “Fixed by D4” records, including fixed, settled, non-defect, decomposed, historical, and provenance-only entries intentionally omitted from the top-level dashboard.

Integrity is anchored to [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt), the byte-exact pre-hierarchy source (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`). [`manifest.tsv`](manifest.tsv) binds every id to its original source line, exact row hash, disposition class, and routed path.

Regenerate or verify with:

```sh
ruby Scripts/compact_known_issues.rb verify
```

The verifier rebuilds every routed file and the executive index in memory from the archive, checks byte identity, checks all links/ids, and rejects orphan or duplicate detail files.
