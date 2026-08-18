# IOS-AI-004

- Register classification: `accepted`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED PRODUCT LIMITATION (2026-08-17).** AI output is derived content, not a
user-authored intention. TabMail processes only the newest `SyncConfig.maxRecentEmails` Inbox
messages. A message outside that population is deliberately not made eligible merely because it is
opened, pushed, or moved into Inbox. The message remains readable and the detail view shows a quiet
suppression notice instead of an AI spinner.

This supersedes the earlier attempt to make direct events durable beyond the automatic window. PR
#39's `aiDirectPending` columns, triggers, cache mirror, re-key carry and direct-event redrive widened
the queue state space for a hypothetical derived-work recovery. In ordinary use that complexity made
old incomplete rows repeatedly reachable by the AI/body drains. The owner chose the prior bounded
policy and everyday liveness over preserving that derived work.

## Governing behavior

- `ActiveAIQueue.recentInboxWindowContains` is the shared admission decision for direct enqueue,
  opened-message processing, job execution and `SummaryBubbleView`.
- The newest window is selected before cached-work filtering. Completed recent messages therefore do
  not cause the queue to reach farther back for replacement work.
- A job that ages out after enqueue is retired as a scope exit; it is not interpreted as incomplete
  work that should retry.
- Existing v85/v86 migration identifiers remain immutable. Forward migration
  `v87_retireDirectAIPending` drops their triggers, sparse index and marker columns.
- No provider fetch, stored email body, authored data or user action is discarded by this policy.

## Residual and reopening rule

An older moved/opened message may have no AI summary/action/reply. That is the accepted outcome. Reopen
only if measured product usage justifies changing `SyncConfig.maxRecentEmails` itself; do not add a
second durable exception class, identity mapping or relaunch redrive for derived work.

## Search terms

`IOS-AI-004`; `SyncConfig.maxRecentEmails`; `recentInboxWindowContains`;
`repopulationCandidates`; `SummaryBubbleView`; `v85_addDirectAIPending`;
`v86_retireDirectAIOnInboxRoleExit`; `v87_retireDirectAIPending`; PR #39; large inbox;
AI work suppressed
