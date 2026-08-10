# TabMail iOS Known Issues

This is the executive index for released `v1.7.5` (`50e8f63a4`). The governing policy is simple: server sync/reopen/retry is valid recovery for a fail-closed edge; guessing identity, mutating the wrong item, losing local-only authored data, exposing a secret, or wedging a durable lane is not.

**Current executive census (2026-08-09):** 17 user-impacting records — Open **2** · Accepted recoverable limitation **15**. The full register contains 138 main records and 2 historical D4 records; its 121 fixed, settled-decision, non-defect, decomposed, historical, or provenance-only main records are intentionally omitted from this dashboard.

The full records are split into [`Companion/Process/Current/KnownIssues/`](Companion/Process/Current/KnownIssues/README.md). The exact pre-split register—including all superseded reasoning, corrections, audit history, predicates, and old counts—is preserved byte-for-byte in [`Companion/Process/History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt`](Companion/Process/History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`), with row-level integrity in [`Companion/Process/Current/KnownIssues/manifest.tsv`](Companion/Process/Current/KnownIssues/manifest.tsv).

## Executive summary

- The 2026-08-09 refresh covered all 423 production Swift files in `Shared/`, `TabMail/`, and `TabMailNotificationService/`, plus the released SwiftMail resolution and current PR boundary.
- Four differently shaped passes covered durable/crash recovery, UI/lifecycle and swallowed errors, provider/dependency boundaries, then local-only ownership/privacy/terminal-state readers. The fourth pass produced no new issue class.
- This top-level file lists only current open or accepted user-impacting limitations. All fixed and non-problem records remain available through the companion directory and hash-pinned archive.
- The audit added seven records. Five are explicitly recoverable accepted limitations; two remain open because removal/reset can silently become partial and stale remote push state can survive account removal.
- Atomic MOVE remains intentionally conservative: uncertain crash recovery may drop the gesture and let sync restore server truth (`IOS-MOVE-003`); it does not blindly replay or guess a destination identity.

## Open issues requiring attention

- [IOS-CLEANUP-001](Companion/Process/Current/KnownIssues/ios-cleanup-001.md): 🔓 OPEN (2026-08-09) — several live destructive settings paths swallow the authoritative GRDB transaction and continue with later cleanup or success presentation, so a database failure can leave a partial local reset/removal
- [IOS-PUSH-001](Companion/Process/Current/KnownIssues/ios-push-001.md): 🔓 OPEN (2026-08-09) — account removal and the latent factory-reset path treat remote push unsubscribe, consent revocation, and device unregister as best-effort with no durable retry; a stale push can still produce an old-account warning…

## Issue index

### BILLING (1)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-BILLING-001](Companion/Process/Current/KnownIssues/ios-billing-001.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-09) — failure to present Apple's subscription-management sheet is log-only on both account surfaces, leaving the button with no visible result |

### BODY (5)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-BODY-001](Companion/Process/Current/KnownIssues/ios-body-001.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-08) — bodies ALREADY corrupted by shipped v1.6.38 keep their wrong content; the gate protects new fetches only, and there is no remediation pass |
| [IOS-BODY-002](Companion/Process/Current/KnownIssues/ios-body-002.md) | `accepted` | 📋 ACCEPTED LIMITATION (re-baselined 2026-08-09 at released v1.7.5) — pull-to-refresh on a message whose address is mid-move is still DECLINED rather than performed; ordinary refresh no longer deletes the readable body first |
| [IOS-BODY-003](Companion/Process/Current/KnownIssues/ios-body-003.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-08) — the BATCH body path still pays one provider round trip per retry cycle while a move stays undrained |
| [IOS-BODY-004](Companion/Process/Current/KnownIssues/ios-body-004.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-08) — an open message whose row is re-keyed by finishMove WHILE the detail view is polling for its body stops loading until the user leaves and reopens it; the automatic recovery was removed rather than… |
| [IOS-BODY-005](Companion/Process/Current/KnownIssues/ios-body-005.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-08) — tapping an attachment on a message whose address is mid-move shows "This message is still being moved. Go back to the message list and open it again in a moment." instead of downloading it |

### CAL (1)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-CAL-007](Companion/Process/Current/KnownIssues/ios-cal-007.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-07, round-17 R17-4) — registered under THE MANTRA, not deferred and not a defect. TabMail has no persistent surface for a terminally-failed calendar operation. Delivery of the failure reason is in-memory… |

### CHAT (1)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-CHAT-001](Companion/Process/Current/KnownIssues/ios-chat-001.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-09) — Agent Chat deliberately keeps the live conversation usable when local chat persistence fails, so the visible session and durable history can diverge until reopen |

### CLEANUP (1)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-CLEANUP-001](Companion/Process/Current/KnownIssues/ios-cleanup-001.md) | `open` | 🔓 OPEN (2026-08-09) — several live destructive settings paths swallow the authoritative GRDB transaction and continue with later cleanup or success presentation, so a database failure can leave a partial local reset/removal |

### IMAP (2)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-IMAP-009](Companion/Process/Current/KnownIssues/ios-imap-009.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-05) — registered under THE MANTRA, not deferred and not a defect. The disposition has been verified and accepted by the coordinator; do not re-litigate it, and do not "fix" it locally |
| [IOS-IMAP-010](Companion/Process/Current/KnownIssues/ios-imap-010.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-05) — registered under THE MANTRA; recoverable, zero wire mutation, do not build a mechanism for it |

### MOVE (1)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-MOVE-003](Companion/Process/Current/KnownIssues/ios-move-003.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-09, released v1.7.5 / 9d10c65d1) — a process death can drop a MOVE that was durably claimed but had not yet emitted any provider command; sync restores server truth and the user may repeat the move |

### OUTBOX (1)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-OUTBOX-007](Companion/Process/Current/KnownIssues/ios-outbox-007.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-07, round-18 item E) — an account whose IMAP server advertises no SPECIAL-USE and names its Sent folder outside the four-name English fallback gets no recognized .sent Folder row, so a successful SMTP send… |

### PUSH (1)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-PUSH-001](Companion/Process/Current/KnownIssues/ios-push-001.md) | `open` | 🔓 OPEN (2026-08-09) — account removal and the latent factory-reset path treat remote push unsubscribe, consent revocation, and device unregister as best-effort with no durable retry; a stale push can still produce an old-account warning… |

### REMINDER (1)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-REMINDER-001](Companion/Process/Current/KnownIssues/ios-reminder-001.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-09) — one thrown GRDB reminder observation silently ends reminder refresh for that in-memory chat-pill session |

### SETTINGS (1)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-SETTINGS-002](Companion/Process/Current/KnownIssues/ios-settings-002.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-09) — account-field and folder-role edits can appear accepted in Settings even when their synchronous GRDB write failed |

### UI (1)

| ID | Class | Executive statement |
|---|---|---|
| [IOS-UI-001](Companion/Process/Current/KnownIssues/ios-ui-001.md) | `accepted` | 📋 ACCEPTED LIMITATION (2026-08-09) — several optional/read-only surfaces collapse a transient load or re-authentication error to empty, stale, or indefinitely loading UI with only a diagnostic log |
