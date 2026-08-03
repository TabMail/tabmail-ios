
## ADR-IOS-004: ~~First Compute Wins for Cross-Instance Action Tags~~ (SUPERSEDED by ADR-IOS-036)

**Context:** Multiple TabMail instances (Thunderbird, iOS) can share the same IMAP account. When both instances process the same inbox message, both would independently compute the action via LLM, wasting tokens and potentially producing inconsistent results.

**Decision (superseded):** iOS / TB wrote `tm_*` IMAP keywords / Gmail labels / Exchange categories to the server so the other instance could adopt the tag on next sync without re-running the LLM.

**Why superseded:** Device Sync (the device-sync WSS relay) now exchanges `{summary, action, reply}` between connected peers via `ai_cache_probe` — this replaces the IMAP-keyword channel for the "both devices online" case. We accept losing async cross-device pickup (see ADR-IOS-036 tradeoff discussion). Removing the server-side label writes eliminates Gmail/Outlook/IMAP label-list pollution that users were seeing as `tm_reply` etc.

**Migration:** On-server `tm_*` keywords/labels from prior versions are left alone; they age out as inboxes churn. The iOS code no longer reads or writes them.

---
