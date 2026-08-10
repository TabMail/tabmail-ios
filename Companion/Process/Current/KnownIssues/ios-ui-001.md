# IOS-UI-001

> Routed from `KNOWN_ISSUES.md` line 1450 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `0fce4091d0a99bf945316a99ec39788173f12d41de66d9b0ffa52300a7e38de7`

## Status

📋 **ACCEPTED LIMITATION (2026-08-09)** — several optional/read-only surfaces collapse a transient load or re-authentication error to empty, stale, or indefinitely loading UI with only a diagnostic log

## Subsystem and search terms

UI error surface; BYOK model catalog; contacts container; user-label menu; Agent Chat history; remote search; calendar re-authentication; retry by reopen

## Full detail

**ENUMERATED SITES.** `TabMailSettingsView.loadModelCatalog` leaves the existing “Loading models…” placeholder when its fetch fails; `ContactContainerPickerView` leaves the container list empty; `UserLabelMenuModel` can leave labels empty/stale; `DynamicIslandChatButton.loadSessionHistory` leaves only the new-session page; provider-side remote search catches and returns `[]`; and `CalendarPickerView.grantCalendarAccess` logs a failed Gmail/Outlook re-authentication while leaving the existing “Calendar Access Required” state/button in place. Each owning feature has a direct retry — close/reopen, repeat search, or press the same re-auth button — and none of these paths commits a provider mutation before failure. This row is an error-visibility census, not permission to hide failures on send, move, delete, purchase, attachment preparation, or any other user-authored mutation.
