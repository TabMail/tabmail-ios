# analysis/

Interactive engineering analyses of the iOS app. Each subfolder is a
self-contained static site (no build step, no external dependencies) — open the
`index.html` in a browser.

## boot/

Startup, foreground-return, and Notification Service Extension (NSE) performance.
A clickable swimlane timeline of every launch job (file:line, what it does,
whether it blocks the main thread, QoS), the NSE→inbox merge pathway, ranked
optimization hotspots, and before/after + on-device measured results for the
changes that landed.

```
open analysis/boot/index.html
```

Pages: `index.html` (overview), `cold_boot.html`, `warm_boot.html`, `nse_boot.html`.
Measurements come from a DEBUG-only `BootProfiler` (kernel-process-start timeline)
and the NSE's `os_log`; debug builds are slower than Release, so read the relative
shape (which step dominates), not absolute numbers.
