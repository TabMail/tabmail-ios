# Deferred Navigation-Stack Shell Experiment

**Status:** Deferred historical WIP snapshot — not merge-ready
**Preserved on:** 2026-08-15
**Branch:** `deferred/nav-stack-shell`
**Branch base:** current public `main` at the time of preservation

This directory preserves a local experiment that replaced the iPhone root
`NavigationSplitView` with a path-driven `NavigationStack`. It exists so the
idea, implementation attempt, investigation trail, and validation checklist can
be revisited without depending on any other checkout or repository.

## Preserved artifacts

- [`NAV_STACK_SHELL_WIP.patch`](NAV_STACK_SHELL_WIP.patch) — the exact two-file
  source diff from the implementation attempt.
- [`PLAN_NAV_STACK_SHELL.md`](PLAN_NAV_STACK_SHELL.md) — the original design,
  route inventory, risks, and physical-device validation matrix.
- [`KNOWN_NAVIGATIONSPLITVIEW_BUG.md`](KNOWN_NAVIGATIONSPLITVIEW_BUG.md) — the
  original investigation, failed mitigations, and compact-mode race evidence.

The plan's header says "not started", but the preserved patch shows that an
implementation was attempted. Its validation checklist remained incomplete, so
neither the claimed framework-bug resolution nor behavioral parity is proven.

## What the experiment tried

The experiment removed SwiftUI's collapsed split-view state machine on iPhone
by making the sidebar the root of one `NavigationStack`. Mailboxes and message
details became path destinations, and navigation deep links replaced the whole
path atomically.

The attempted source change touched only:

- `TabMail/Views/MailNavigationView.swift`
- `TabMail/Views/Previews/Tooltips/RemindersMenuTip+Preview.swift`

## Why this is deferred rather than a candidate change

The source patch predates the current public repository history and is preserved
as data instead of being applied to current source. Since the experiment,
navigation acquired additional contracts, including real programmatic pushes,
account-scoped notification resolution, unresolved-tap handling, richer draft
open authority, and additional settings/template routes. Applying the patch
blindly would discard those later behaviors.

The current application still uses `NavigationSplitView`, so the architectural
idea may remain useful if compact-mode navigation defects recur. The patch is
evidence and a starting point, not an implementation to cherry-pick.

## Revisit protocol

1. Start a fresh branch from the then-current `main`.
2. Read the investigation and plan, then inspect the current navigation code and
   ADR-IOS-054 before designing the replacement.
3. Re-inventory every route and presentation surface. At minimum include sidebar
   mailbox cases, inbox row taps, chat/email pills, notification taps and their
   sentinel/account-scoped resolution, agent toasts, account/settings/plan
   routes, templates, locally-authored/server drafts, sheets, and covers.
4. Prefer a typed route model over a heterogeneous path containing raw
   `String` values.
5. Preserve current route semantics first; only then remove split-view-specific
   state and workarounds that are proven unnecessary.
6. Add route-transition tests and complete the physical-iPhone rapid-navigation
   matrix. The original failure was device/framework timing-sensitive.
7. Run the full current test suite and require a warning-clean build before
   considering a merge.

No current production source is modified by this preservation branch.
