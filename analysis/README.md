# analysis/

Interactive engineering analyses of the iOS app. Each subfolder is a
self-contained static site (no build step, no external dependencies) — open the
`index.html` in a browser.

**Folders are dated (`<topic>-YYYY-MM-DD`) on purpose.** Each is a point-in-time
snapshot of the code as it was on that date — measurements, file:line
references, and "what changed" notes go stale as the code moves on. The date in
the name is the signal: treat anything inside as historical once the code has
diverged. A newer snapshot supersedes an older one; old snapshots are kept for
the record, not maintained.

## boot-2026-06-26/

Startup, foreground-return, and Notification Service Extension (NSE) performance.
A clickable swimlane timeline of every launch job (file:line, what it does,
whether it blocks the main thread, QoS), the NSE→inbox merge pathway, ranked
optimization hotspots, and before/after + on-device measured results for the
changes that landed (gradual NSE staging, foreground reorder, cold-boot first
paint, and the 2026-06-26 NSE→inbox merge streamlining — the privileged
single-threaded merge: coordinator, synchronous FTS flip, one debounce-bypassing
post, merge-before-herd).

```
open analysis/boot-2026-06-26/index.html
```

Pages: `index.html` (overview), `cold_boot.html`, `warm_boot.html`, `nse_boot.html`.
Measurements come from a DEBUG-only `BootProfiler` (kernel-process-start timeline)
and the NSE's `os_log`; debug builds are slower than Release, so read the relative
shape (which step dominates), not absolute numbers.
