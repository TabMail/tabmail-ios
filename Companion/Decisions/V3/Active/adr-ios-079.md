## ADR-IOS-079: Scheduled Tasks Are Removed From iOS; Thunderbird Keeps Them

**Date:** 2026-08-26

**Status:** Active. Owner decision — the feature cannot be made reliable on this platform, so it is
deleted rather than left dormant.

**Context.** A scheduled task is a `- [Task] Schedule <days> <HH:MM> [<TZ>], <instruction>` line in
the shared knowledge base. Thunderbird runs them from a persistent desktop process using local
alarms; that is sound and unchanged. iOS tried to reproduce the same behaviour from a foreground
5-minute evaluation loop plus a server-scheduled background wake.

Neither leg is dependable here. Background execution is budgeted and can be withheld entirely;
background wake-up pushes are throttled and are not delivered on a guarantee. A task therefore fired
early, late, or not at all, with no way for the user to tell which.

The feature was already half-disabled: the settings entry point and the three agent tools were
commented out, so an iOS user could not create, see, edit, or disable a task. The execution engine
was not disabled — it defaulted to ON and would faithfully run a task synced from the desktop,
consuming the user's AI quota and posting a notification the user had no UI to stop. Keeping the
engine while the management surface stayed hidden was the worst of both states.

**Decision.**

1. **The iOS evaluation engine, scheduler, execution cache, KB task parser, settings view, and three
   agent tools are deleted outright**, along with the background wake registration and its
   notification-extension route. The foreground loop no longer starts, and nothing registers a wake.
2. **Thunderbird is unaffected and must stay that way.** It is the reference implementation for this
   feature. Nothing in the shared knowledge base, the `[Task]` line syntax, or the backend prompt
   tier the desktop client uses for unattended evaluation is touched by this change.
3. **`[Task]` lines are user data on this platform.** They keep syncing, keep appearing in the
   knowledge-base editor, and keep going to the model as ordinary knowledge-base prose. No code
   strips, rewrites, or migrates them. On iOS they are now inert text; on the desktop they are live
   feature input.
4. **The `taskCache` device-sync field is removed entirely** — the `SyncField` case, its
   `TimestampKey`, the `PromptStateData` property and timestamp, their `CodingKeys`, the
   initializer parameters and the decode. Keeping a decode for a field this platform can never act
   on would be keeping scheduled-task machinery, which is what this ADR removes. Dropping it is
   safe in both directions, and both halves are load-bearing:
   - **Inbound:** `PromptStateData` decodes through `container(keyedBy: CodingKeys.self)`, and a
     `KeyedDecodingContainer` reads only the keys it is asked for. A JSON key absent from
     `CodingKeys` is never read and cannot throw, so a desktop payload carrying `taskCache` still
     decodes cleanly and the fields this client acts on are unaffected.
   - **Outbound:** the desktop client gates its merge on the field being `undefined`, so an omitted
     key skips that merge. An empty map would instead read as a value and could clear entries this
     client knows nothing about — which is why the field must be *absent*, not empty.

   `PromptStateDataUnknownFieldTests` pins this as the general invariant — *an undeclared key is
   ignored* — rather than as a fact about `taskCache`: a desktop-shaped payload carrying
   `taskCache`, and one carrying an arbitrary unknown field, both decode with every acted-on field
   intact, against a no-extra-fields baseline control; and the outgoing payload names no task field
   at all.
5. **The `disabledReminders` field is untouched.** It still carries `t:`-prefixed task
   enable/disable state across devices. iOS no longer contributes those hashes to its freshness set,
   so its local 90-day GC may drop one; because merges never delete on absence, the desktop keeps
   its own entry and re-seeds iOS on the next broadcast. The user's choice is not lost.
6. **The `nse_pending_task_result` staging table stays.** It is a `CREATE TABLE IF NOT EXISTS` in
   the notification-extension staging bootstrap that both processes open, and test fixtures assert
   it. Only the producer and the consumer are removed. No cleanup or migration is written for
   stranded rows — the producer was already unreachable, so there should be none, and a migration
   would touch the live push staging path for no benefit.
7. **The `"task_result"` chat-turn type no longer renders.** The chat pill's assistant-turn
   predicate admits only `"normal"`, so turns left behind by earlier fires are not displayed. This
   is a **display** change: the `chatTurn` rows stay in the database exactly as they are. No
   migration, cleanup, backfill, or delete is written for them — user content is not removed, it is
   simply no longer surfaced, in keeping with there being no scheduled tasks on this platform.
8. **The `Reminder` struct keeps its schedule fields.** They are now always nil and have no
   producer. Removing them would touch every initializer in the app and its tests for no behavioural
   gain, so the fields stay and the task branches that read them are deleted instead.

**Consequences.**

- **A task created in Thunderbird no longer fires on iPhone.** This is the main user-observable
  loss: no notification, no chat turn, no iOS-side execution. It continues to run in Thunderbird.
- **Chat turns from earlier task fires disappear from iOS history.** The rows remain in the
  database and nothing deletes them, but the pill no longer renders them.
- The flip side is that iOS stops running a task the user cannot see, pause, or delete from the
  phone, and stops spending their AI quota on it.
- The `task.enabled` and `task.advance_minutes` settings are gone from the agent's settable list;
  asking for them now returns "unknown setting". No prompt or schema outside the deleted tool
  enumerated them.
- Notification-tap deep links for task results are gone. A stale delivered notification tapped after
  upgrade routes to the inbox instead, which is the existing fallback.
