
## BYOK Model Picker — Two-Section Query-All (ADR-026, 2026-07-08)

- The backend catalog (`GET /byok/models`) is now the **"Recommended" list only** — the backend accepts any well-formed model id on the user's own key (global ADR-026). `BYOKTierRows` (Views/Settings/ProviderSettingsView.swift) renders the model Picker with two Sections: `"Recommended"` (catalog order; first entry = default, newest tier-appropriate family first — Haiku for Light, Sonnet for Heavy; Opus listed but never default) and `"All models (from your API key)"` (live `POST /byok/list-models`, fetched only when a Keychain key exists, cached per provider for the view's lifetime, failure = debug-gated log + Recommended-only).
- Shared pure helpers on `BYOKProviderInfo`: `liveIdMatches(_:recommendedId:)` (exact or `<id>-<digits>` dated-variant match; digits-only guard prevents `gpt-5.5` matching `gpt-5.5-pro`), `isAvailable(_:in:)` (hoisted from APIKeysView's ProviderTestRunner — both call sites now share it), `mergeModels(recommended:available:)` → `(recommended, additional)` with dedupe. Tests: `BYOKModelMergeTests` suite in `TabMailTests/Services/BYOKProviderInfoTests.swift` (placeholder ids only — never assert real catalog contents).
- Group labels must stay **byte-identical to the TB addon's** (`config/modules/byokSettings.js` optgroups): "Recommended" / "All models (from your API key)".
- A stored model id that's live-only (or no longer in the catalog) stays selected — `ensureDefaultModel()` only auto-picks when the stored value is empty; do not "clean up" unknown stored ids, the backend accepts them.

---
