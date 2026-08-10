# IOS-IMAP-009

> Routed from `KNOWN_ISSUES.md` line 103 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `0fa6bc9921edba7d9d1a2330a63192fbc39711caee5087846433ab58313cc3b2`

## Status

📋 **ACCEPTED LIMITATION (2026-08-05)** — registered under THE MANTRA, not deferred and not a defect. The disposition has been verified and accepted by the coordinator; **do not re-litigate it**, and do not "fix" it locally

## Subsystem and search terms

IMAP; COPY; `COPYUID`; `IMAPProvider.move`; H3; `6f7c6a532`; `IMAPError.commandFailed`; `CapabilityHandler`; lazy re-auth; reconnect; `refreshCapabilities`; catch precondition too broad; `\Deleted` source residue; structurally unreachable expunge; SwiftMail upstream; `CopyHandler`

## Full detail

**What this row registers.** H3 (`6f7c6a532`) makes `IMAPProvider.move` catch `IMAPError.commandFailed` around `server.copy(messages:to:)` and continue with `copyEvidence = nil`. **The fix is correct and stays.** Its in-code comment already states, honestly, that the catch's precondition is **broader than "the `COPYUID` did not parse"** — and this row is the durable registration of that breadth rather than a claim it does not exist. `CapabilityHandler.handleTaggedErrorResponse` also raises `.commandFailed`, and it is reachable inside `server.copy(...)` through `IMAPServer.executeCommand`'s lazy re-authentication and `IMAPConnection.executeCommandBody`'s reconnect, both of which call `refreshCapabilities` → `CAPABILITY`; `IMAPCommandQueue.acquire` is re-entrant for the same task, so the nesting is not blocked.

🔒 **STRUCTURAL BOUND — the irreversible `UID EXPUNGE` is UNREACHABLE on this path. Re-verified by reading the code at HEAD, not inherited from the brief.** With `copyEvidence == nil`, `copyProvenSourceUIDs` returns `UIDSet()` at its first guard (`guard let evidence, evidence.destinationUIDValidity.value > 0`), so `copyProvenUIDs` is empty. **Both arms of the branch below it then yield an empty `purgeAuthorizedUIDs`:** if `sourceUIDs` is non-empty, `copyProvenUIDs.count != sourceUIDs.count` takes the `else` arm and `purgeAuthorizedUIDs` is the `liveValues` filter of an **empty** set; if `sourceUIDs` were empty, `0 == 0` takes the `then` arm and `purgeAuthorizedUIDs = copyProvenUIDs`, also empty. Either way `if serverSupportsUIDPlus, !purgeAuthorizedUIDs.isEmpty` never fires, so `server.expunge(messages:)` is never issued. ⚠️ **Stated negatively:** the bound is on the EXPUNGE only. It does **not** claim the path is inert, and it does **not** extend to any other irreversible wire operation — the three draft-family operations (`deleteDraftStrong`, `saveDraft`'s old-copy replacement, Gmail's `DELETE /drafts/{id}`) are out of this row's scope entirely and are not protected by anything asserted here.

**WHAT CAN ACTUALLY HAPPEN.** On that narrow door the COPY never ran, yet the `else` arm still sets `authorizedUIDs = live` and applies the **reversible** `\Deleted` STORE to the source members the source still holds; every member then reaches an exit and the op **retires**. Net observable state: one message flagged `\Deleted` in the source folder and absent from the destination. Nothing is destroyed — the message is still on the server.

**WHY THAT IS ACCEPTABLE UNDER THE MANTRA.** `\Deleted`-but-present presentation is already handled (`IOS-IMAP-001` / D3), and the state recovers by an ordinary sync pass plus **one ordinary user gesture** — so it is a recoverable edge, which the mantra says to fail closed on and register rather than build a mechanism for. Compare what it replaces: a **confirmed, non-recoverable wedge** in which the op never retires, the lane stays halted, and every drain issues another `UID COPY` — one more duplicate at the destination per drain, forever. Trading a non-recoverable defect for a recoverable edge on a nonconforming server is exactly what the mantra prescribes.

**TRIGGER — a conjunction, all of which are required:** (1) a lost authentication or a dead channel landing between two adjacent `await`s (A3's `selectMailboxTracked` went through the same lazy-auth/reconnect logic one round trip earlier), **and** (2) a server answering `CAPABILITY` with a tagged NO/BAD, **and** (3) that same server omitting `[CAPABILITY]` from **both** its greeting **and** its LOGIN OK.

🔧 **THE DURABLE REMEDY IS UPSTREAM, and it is named as such.** At the pinned fork revision `078a09b8`, `CopyHandler.handleTaggedOKResponse` calls `extractCopyUID(from:)` → `CopyUID(nio:)` and re-raises whatever it throws via `failWithError(error)`; `CopyUID.init(nio:)` has exactly **three** `throw IMAPError.commandFailed` sites (cardinality mismatch, invalid UID range, expansion over 1,000,000 UIDs). Meanwhile `CopyHandler.handleTaggedErrorResponse` maps a genuine tagged NO/BAD to `IMAPError.copyFailed`. So the handler **already has the tagged response in hand** and should raise a **distinct error case** for "tagged OK + unparseable `COPYUID`" instead of reusing `.commandFailed`; that would make the catch's precondition exactly its intent and retire this row. ⚠️ **Symbol, not filename (`MIS-008`): `CopyHandler` is a type declared in `Sources/SwiftMail/IMAP/IMAP/Handler/ServerHandlers.swift` — there is NO `CopyHandler.swift`, and grepping for one returns nothing.** ⛔ **Do NOT open or attempt that PR from this repo's work:** SwiftMail PRs go **upstream to Cocoanetics**, never to the fork, the fork sync has its own skill (`tabmail-swiftmailfork-sync`), and the PR is the owner's per `feedback_swiftmail_pr_upstream`. This is a note for later, not work for now.

**Cross-reference:** this is the accepted residual of the fix recorded in `IOS-IMAP-005`, whose two falsified premises H3 corrected.
