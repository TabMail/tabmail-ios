
## ADR-IOS-031: Background Tasks Touching GRDB MUST Use `.medium` Priority (Never `.low` / `.utility` / `.background`)

**Context:** iOS Thread Performance Checker caught a priority inversion during a reported blank-inbox-during-rapid-nav symptom. Stack trace:

```
Thread Performance Checker: Thread running at User-initiated quality-of-service
class waiting on a lower QoS thread running at Default quality-of-service class.
Investigate ways to avoid priority inversions

... GRDB.Pool.get
... GRDB.DatabasePool.read
... SearchIndex.headerIdsWithEmptyFolderId
... SyncEngine.backfillFolderIdsIfNeeded  ← Task(priority: .low) { … }
```

MainActor (user-initiated QoS 25) was blocked waiting on a GRDB reader held by a `.low`-priority backfill task (= utility QoS 17). The 8-level QoS gap was large enough for iOS to stall MainActor's execution while the backfill read completed. Body evaluation produced the correct view tree (`normalListView body eval — OK loaded=50 groups=38 visible=38`) seconds before MainActor could actually commit the render. Visible symptom: stuck blank inbox until the reader released (self-recovery in 1–2 s). Same mechanism also manifests as lagged sync-status pill updates after foreground return — every `@Observable` state change and NotificationCenter handler hops through MainActor and queues up behind the same block.

**Decision:** Any background `Task { … }` that touches GRDB (any `dbPool.read` / `dbPool.write` on the main DB OR the FTS DB OR any other `DatabasePool` we own) MUST use `priority: .medium` (= `.default` QoS 21) or higher. Never `.low`, never `.utility`, never `.background`. This is a hard invariant with no exceptions — the GRDB reader pool is a finite resource shared with MainActor, and any QoS gap of more than 4 levels below MainActor (`.userInitiated` == 25) triggers priority inversion that stalls the render thread.

**QoS reference (Task.Priority → QoS numeric):**

| TaskPriority | QoS            | QoS # | Use |
|---|---|---|---|
| `.userInitiated` / `.high` | userInitiated | 25 | User-triggered sync (pull-to-refresh, foreground poll) |
| `.medium` (default) | default | 21 | **Background tasks that touch GRDB — FLOOR** |
| `.low` / `.utility` | utility | 17 | ❌ NEVER for GRDB work |
| `.background` | background | 9 | ❌ NEVER for GRDB work |

`.medium` stays below `.userInitiated` so user-triggered operations retain priority, but only by 4 QoS levels — below iOS's priority-inversion detection threshold, and close enough that the scheduler won't stall MainActor waiting on it.

**Rationale:**

- GRDB's `DatabasePool` has a finite reader pool (default 5). When all readers are busy, additional readers — including MainActor — must wait.
- iOS's Thread Performance Checker flags any situation where a higher-QoS thread waits on a lower-QoS thread's resource. The warning is not just noise: iOS's scheduler genuinely throttles the higher-priority thread's execution in this state (priority promotion *helps* but doesn't fully compensate for large QoS gaps).
- The practical effect is indistinguishable from MainActor being frozen — SwiftUI body has produced the correct view tree, but the commit-to-screen phase waits on the blocked MainActor.
- `.low` / `.utility` are superficially appealing for "low-priority background work", but their 8-level QoS gap below MainActor is exactly the range that triggers inversion. They're appropriate for CPU-only tasks with no shared resources, not for anything touching GRDB.
- `.medium` is the minimum safe floor. Further bumping to `.userInitiated` is wrong — that matches MainActor priority and defeats the purpose of "background" designation; user-triggered syncs should still outrank background ones.

**Consequences:**

- All sync-engine background tasks (header backfill, FTS bulk index, folderId backfill) use `.medium`.
- Any new Task created in the data layer must explicitly set `.medium` or higher when it will touch GRDB. Inheriting from the caller is NOT acceptable because the caller's QoS is often MainActor → inheriting creates a different problem (the task blocks the caller).
- Pure CPU background work (e.g., in-memory threading heuristic, text processing with no DB access) may still use `.low` / `.utility` / `.background`. The rule is scoped to GRDB-touching code specifically.
- PR review checklist item: grep `Task(priority:` on all new Tasks and verify none use `.low` / `.utility` / `.background` in files that touch GRDB.

**Out of scope:**

- Raising GRDB's `maximumReaderCount` as an alternative fix. Considered but rejected — more readers increase SQLite contention, and doesn't address the underlying rule that background work must not cause priority inversion.
- Converting all MainActor sync GRDB reads to async. Worth doing for MainActor-specific hot paths independently, but doesn't address the root cause (the priority inversion would still fire if background tasks run at `.low`).
- `DispatchQueue.global(qos:)` usage. The same rule applies: GRDB-touching dispatches must be at `.default` QoS or higher.

**Files:**

- `TabMail/Services/Sync/SyncEngineBackfill.swift:208` — header backfill (was `.low`, now `.medium`)
- `TabMail/Services/Sync/SyncEngineFTS.swift:184` — FTS bulk index (was `.low`, now `.medium`)
- `TabMail/Services/Sync/SyncEngineFTS.swift:270` — FTS folderId backfill (was `.low`, now `.medium`)
