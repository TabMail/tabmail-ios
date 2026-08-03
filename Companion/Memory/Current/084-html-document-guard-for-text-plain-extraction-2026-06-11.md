
## HTML-Document Guard for text/plain Extraction (2026-06-11)

- Some senders put the **full HTML document inside the text/plain MIME part** (observed: survey-platform mail, `multipart/alternative` with identical HTML in both parts). iOS was immune for snippets/FTS only because `EmailFilter.extractPlainText` prefers `htmlBody`; the single-part-mislabeled variant was not covered.
- `EmailFilter.looksLikeHTMLDocument(_:)` (Shared/Parse/EmailFilter.swift) now guards the textBody fallback in `extractPlainText` and the inlined Tier-2 snippet fallback (`InboxViewModel.loadSnippetBatch`). Document-start markers ONLY (`<!DOCTYPE` / `<html` + ws/`>`): never matches prose with angle brackets (`<user@example.com>`, `List<String>`, `a < b`). Do NOT broaden into a generic tag heuristic — `BodyRenderer`'s display path deliberately avoids that (double-escape saga); the display path is unchanged.
- TB addon counterpart: `fts/bodyExtract.js looksLikeHtmlDocument` + HTML-first flip — see `tabmail-thunderbird/DECISIONS.md` ADR-018. Keep the two markers in sync.
- Tests: `TabMailTests/Helpers/EmailFilterHTMLTests.swift` (suites `EmailFilter.looksLikeHTMLDocument`, `EmailFilter.extractPlainText HTML-document guard`).

---
