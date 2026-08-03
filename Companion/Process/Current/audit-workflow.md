<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note:** The following post-compaction replacements are current authority; their frozen predecessor lines remain in the preserved body below.

4. **Implementation on THIS repo: a fresh Codex SUBAGENT implements; Claude Opus reviews.** The main Codex session supervises and may edit only process/governance artifacts (`CLAUDE.md`, `PLAN_*.md`, memory, skills). A fresh, narrow Codex subagent writes the fix and invariant tests, builds, red-proofs, runs the required suite with zero warnings except the one exact benign App Intents diagnostic defined in `CLAUDE.md` and `Companion/Rules/Active/development-rules.md` (which must still be counted and reported), and commits only when the coordinator's brief authorizes it. Claude receives read-only audit questions through `$ask-claude` and exact-candidate reviews through `$claude-review`; Claude never writes the live tree. The main session independently reads and verifies the landed code and evidence.

4b. **THE DIFF REVIEW MUST RUN ON THE EXACT COMMIT CANDIDATE — re-run it after every fix round.** A fix for review findings routinely grows the diff beyond what was reviewed, and the new surface is *unreviewed*. Real case (F2b L6 items 1+2, 2026-07-25): round 1 reviewed 7 files / +1045; fixing its 3 blockers grew the diff to 10 files / +1731 **including a brand-new schema migration (v87) that the gate had never seen**. Reviewing round 1's version would have been reviewing code that no longer existed. Rule: after each red-first logical round is green, create its separate signed local commit so unrelated rounds cannot accumulate into an unreviewable pile; review that exact commit/range before counting a clean round. If review produces a fix, commit the fix separately, compare the new range to what the reviewer actually read, and re-run the gate. Fix rounds are where NEW risk enters, not where risk is only removed.

4c. **COMMIT BODIES NEED EXECUTIVE SUMMARIES.** A terse subject plus sign-off is not an adequate durable handoff. Every substantive commit body must concisely state the outcome, user-visible or invariant impact, verification performed, and any accepted limitations/follow-ups. When compacting local history, preserve that information per logical unit instead of replacing it with subject-only squash commits. DCO sign-off and cryptographic signing remain mandatory.

**Database-performance audit lens (mandatory).** Every plan, exact-diff review, and full-range review that changes a database query, transaction, schema, or index must enumerate this lens and compare the parent plus `v1.6.38`: mechanically census changed query count and placement; prove bounded cardinality, index coverage with `EXPLAIN QUERY PLAN` on the current schema, and realistic row-count sensitivity; inspect N+1/full-scan/hot-path risk; account for async reader/writer transaction hold time and QoS/UI contention; and explicitly justify every migration or index addition. A round is not CLEAN with a candidate-attributable unjustified hot-path scan, extra per-row query, longer blocking write, or measurable regression.
<!-- COMPANION-CURRENT-NOTE-END -->
## Cross-Model Audit Workflow — STANDARD (current owner-directed role assignment 2026-07-27)

**CURRENT OVERRIDE — this role assignment supersedes every older model-specific noun in the historical rules below.** The safety lessons remain binding, but the actors are now:

1. **Codex is the coordinator, primary driver, plan/spec owner, verifier, and final judge.** The main session supervises; fresh, narrow Codex subagents implement source changes and run builds/tests. Codex never pushes or releases.
2. **Claude Code Opus is the independent adversarial reviewer only.** Use `$ask-claude` for behavior audits and plan vets and `$claude-review` for the exact candidate after every implementation/fix round. Both run fresh, non-persistent, non-writing `xhigh` review sessions. Always invoke their wrappers outside the Codex sandbox with `DISPLAY` unset; the sandbox cannot see the owner's Claude.ai login. Do not create or use a Claude implementation workflow.
2a. **Codex verifies every Claude finding against current code and `v1.6.38` before acting.** A Claude claim is a lead, never a verdict. Record why each finding is confirmed, rejected, or unresolved.

2h. **GPT-5.6 Sol model-effort operating rule.** Use Sol `xhigh` for the coordinating main session, audit/spec synthesis, adversarial review, release gates, shipped-release comparisons, and any work whose correctness spans concurrency, identity, durability, migrations, or state-machine invariants. Use Sol `high` for a fresh implementation subagent only after it receives an exact, independently vetted brief with explicit tests and completion criteria. Use `medium` (or Terra where available) only for bounded mechanical support such as grep/census work, file mapping, and routine test updates. Sol `max` is exception-only for a demonstrated unresolved quality-first blocker; it is not the default. Choose the lowest tier that fits the role, but never downgrade a quality gate merely to save latency or tokens.

2i. **HARD CAP: at most FIVE plan-vet rounds before implementation** (owner directive 2026-07-27). One round means one frozen plan candidate submitted for independent review; parallel reviewers examining that same exact candidate count as one round, not several. After the fifth round returns, freeze the plan permanently: fold every confirmed concrete finding into the implementation checklist, then implement with red-first invariant tests. Do not create a sixth plan version or request another plan-only vet. Resolve subsequent uncertainty against the actual code, failing tests, shipped-release sequence, and exact-diff review. The mandatory independent review continues on the implemented candidate, where findings are concrete and executable rather than another hypothetical-plan loop.

Where older examples below say “Claude” as author/coordinator, read **Codex**. Where they say “GPT/Codex” as reviewer, read **Claude Opus**. Where they say “Claude subagent,” read **fresh Codex implementation subagent**. This mapping changes the actors, not the release bar, verification burden, test discipline, or never-drop invariants.

2b. **DO NOT ask Claude for ready-to-apply spec patches by default. Codex RE-AUTHORS the spec from Claude's findings** (role-swapped 2026-07-27). Ask Claude for findings, failing scenarios, and *recommendations* — not replacement text to apply verbatim.

    **Rationale (the important part): the "lossiness" of Codex restating Claude's findings is a FEATURE, not a cost.** Re-authoring forces Codex to re-think the problem instead of transcribing a conclusion, and that friction is where the coordinator contributes — recognizing that an enumerated fix needs to become a closure invariant, settling design choices left as "either/or", and spotting a defect pattern recurring across layers. Patch mode short-circuits exactly that thinking: a large patch gets applied with only its load-bearing claims spot-checked, which makes Codex an applier rather than the owner of the design.

    The historical failure mode patch mode was meant to fix (the coordinator restating "RFC is corroboration only" as an RFC *veto*, inverting the intent) is real but SELF-CORRECTING — the next adversarial round caught it. Blind application of a large authored patch has no equivalent safety net. Prefer the loop with friction and a safety net over the fast loop without one.

2d. 🔄 **WHEN REPEATED ATTEMPTS AREN'T CONVERGING, ASK CLAUDE TO AUTHOR THE PROPOSED ARTIFACT, THEN CODEX VERIFIES** (role-swapped escape hatch 2026-07-27).

    Rule 2b (Claude gives FINDINGS ONLY, Codex re-authors) is the DEFAULT and stays the default — the friction of restating is what forces re-thinking. 2d is its escape hatch, not its replacement.

    **Trigger:** the same artifact has taken ~3+ gate rounds without converging, and each round's findings are landing on MY re-authoring rather than on the underlying design. At that point the bottleneck is my model of the problem, and restating it again just reproduces the same gap. Symptom to watch for: the verdicts keep changing shape (too big → underspecified → wrong premise) instead of shrinking.

    **The swap:** ask Claude, in a read-only response, to AUTHOR the proposed artifact (spec or patch text). Then Codex does the verification job — grep every symbol it cites, check every premise against real code and `v1.6.38`, and reject anything unproven. A fresh Codex subagent applies only the verified spec; Claude never writes the live tree.

    **Do NOT swap by default.** Patch mode as a standing rule was tried and reversed the same day (`b81a9e4` → `175484a`) precisely because always-patching removes the re-thinking that catches bad premises. Swap when stuck, then swap back.

2e. 🚨 **SPOT COMPENSATING-MECHANISM DEVIATIONS EARLY — BEFORE WRITING THE CODE, NOT AFTER 10K LINES** (owner directive 2026-07-25: *"if you encounter any such deviations make sure you spot them early before writing 10k lines of code"*).

    **The tell:** a mechanism whose PURPOSE is to restore, re-derive, or undo state that a SIBLING PATH destroyed eagerly. That is a compensating mechanism, and compensating mechanisms are where complexity explodes — every edge case of the destruction becomes an edge case of the restoration.

    **Ask BEFORE building, not after it fails review:** *"what would this cost if the sibling simply didn't do that yet?"* If the honest answer is "this mechanism would not need to exist", the deviation is the sibling's timing, not the missing mechanism. Fix the timing.

    **The case that produced this rule (F2b L6, 2026-07-25).** Undo Send grew a durable reservation CAS, an `undoReserved`/`undoHandedOff` state pair, a derived-E₂ identity, a five-field `EditableComposition` snapshot with new columns, tombstones and resource-ownership activation — roughly 10k lines and EIGHT adversarial review rounds, all to reconstruct a draft that the send path had deleted while the send was merely QUEUED. The send is already held (`holdUntil`; the drain refuses to claim until it expires) and the LOCAL draft row was already correctly preserved until finalize. Only the SERVER copy was deleted early. Moving that one call to the normal send-completion path makes Undo what it always should have been — cancel the queued send, reopen the untouched draft — and retires the entire apparatus. The owner: *"the previous model is correct. The bug was draft deletion timing. It should've just been the normal send routine, and NOT different."*

    **The asymmetry was visible in the code comments the whole time**: the same function that says *"DraftStore.delete is deferred to drain-claim time … if the user taps Undo, the Draft row is still there"* deletes the server copy three lines later. **When two halves of one operation disagree about timing, that disagreement IS the bug** — do not build machinery to bridge them.

    Relationship to 2c: 2c fires when a design SPIRALS (3+ blocker rounds). 2e fires EARLIER — at design time, on the shape of the thing being proposed. Ask 2e's question before the first line of code; by the time 2c triggers you have already paid for the mistake.

2f. 🔄 **AUDIT-FIX WORK: CODEX AUTHORS; CLAUDE REVIEWS THE EXACT CANDIDATE** (role-swapped 2026-07-27).

    **Scope: fixing CONFIRMED audit findings.** Codex writes the complete spec, including invariant-level
    tests and red-proof requirements, then delegates implementation to one fresh, narrow Codex subagent.
    Claude Opus reviews the resulting exact diff through `$claude-review`; it does not implement.

    **The verification burden moves, it does not disappear:**
    - Codex independently greps every symbol and checks every premise against current code and the exact
      owning sequence in `v1.6.38` before dispatch.
    - The implementation subagent writes, builds, red-proofs, runs the required suite, checks warnings,
      and reports honest partial state if interrupted.
    - Codex reads the landed diff and test evidence rather than trusting the report.
    - Claude reviews the exact current candidate. Any subsequent fix invalidates that review and requires
      a fresh Claude session on the new candidate.
    - Claude authoring is only rule 2d's non-convergence escape hatch, never the default.

2c. **WHEN A DESIGN SPIRALS, GO READ THE LAST SHIPPED RELEASE** (owner directive 2026-07-24). If a plan/spec needs repeated adversarial rounds — say 3+ vet rounds still returning blockers, or each fix creating the next problem — **both Codex and Claude must stop and independently compare against the behavior of the previous release tag** (`git show <release-tag>:<path>`), and the vet prompt must explicitly instruct Claude to do so.

    **Why this works:** the shipped release is *proven-adequate behavior*. It was smoke-tested by the owner and real users, so it is a hard empirical floor that no amount of on-paper reasoning can override. A design that is much more complicated than the shipped code is carrying a burden of proof: what defect in the shipped behavior justifies the complexity? If nobody can name one, the complexity is speculative.

    **Real case (F2b L6, 2026-07-24):** the undo/drafts redesign consumed 15 vet rounds and escalated to a SQLite C-API enforcement substrate (custom trace hook + per-connection permit + schema triggers) before anyone checked the release. At `v1.6.38` (`65dd7b3`), `instanceEpoch` **did not exist at all**, and `PendingSendService.undo()` simply discarded the outbox row, deleted the Draft, and reopened compose from a content snapshot — i.e. the shipped app already did "retire + recreate", including for Gmail drafts, and it worked. That single `git show` reframed the whole problem and the owner chose the retire direction. Fifteen rounds of review never asked the question a two-minute command answered.

    Corollary: state the release-behavior comparison in the plan itself, so the burden of proof for extra complexity is visible to every later reader.

2g. 🚨 **SEARCH THE PREVIOUS RELEASE FIRST. AUTHOR ONLY IF ITS ARCHITECTURE IS INAPPLICABLE OR NONEXISTENT** (owner directive 2026-07-27: *"missing directive was to first search for prev release architecture on the problem, and only author if inapplicable or nonexistent"*).

    **This supersedes rule 2c's TRIGGER.** 2c fires after a design has already spiralled (3+ blocker rounds). 2g fires **before the first line of thought**: for ANY fix, the first move is `git show <release-tag>:<path>` on the code that owns the problem. Authoring is the FALLBACK, not the default.

    **The order is:**
    1. Find how the shipped release handled this problem. It is proven-adequate — smoke-tested by the owner and real users. That is empirical evidence no on-paper reasoning outranks.
    2. If it handled it and the approach still applies ⇒ **restore that behaviour**, keeping any genuine improvement HEAD added on top. State explicitly what you kept and why.
    3. Author something new ONLY if the shipped architecture is genuinely inapplicable (the surrounding design has changed such that it cannot work) or nonexistent (the shipped release never did this). Say which, in the plan.

    **Why this is not optional.** On 2026-07-27 it went 4-for-4 in one session, and every miss was expensive:
    - **F3 (Undo Send sends the cancelled message):** I wrote TWO specs and started a role-swap authoring run — a park-first CAS, an outcome enum, a hold-arming restructure. Then `git show v1.6.38:PendingSendService.swift` showed the shipped `undo()` **cancelled first and never had the defect**. All three attempts were designing a mechanism for a bug the shipped code does not have.
    - **F1 / F14 (drafts undeletable / unopenable):** the shipped release needed no Gmail draft RESOURCE id at all — one fallback (`?? serverDraftHeader?.stableId`) plus a provider fallback that is **still in HEAD, unchanged, simply never reached**.
    - **F2 (undo loses read state):** I read HEAD, found no read-state restoration anywhere, and told the owner no undo path had ever done it. The owner said the shipped release does. It does — a full-row `save(db)` of the captured header, with a comment saying so. **I was wrong because I searched HEAD instead of the release.**
    - **F1b (notification action dropped):** the shipped enum doc states the principle outright — *"the alternative (dropping the tap) violates never-drop-user-intention"* — and the whole recovery ladder is still in HEAD.

    **The tell that you skipped this step:** you are designing a mechanism, weighing trade-offs, and the design keeps growing. Stop and run the `git show`. A fix grounded in shipped behaviour needs no trade-off analysis, because the trade-off was already decided by a release that worked.

    **Applies to plan files too:** every fix plan opens with a "SHIPPED BEHAVIOUR" section quoting the release with file:line, before any proposal. A plan that does not have one is not ready to vet.

    **AND THE VET MUST BE TOLD TO CHECK IT INDEPENDENTLY** (owner directive 2026-07-27: *"also for the vett, also tell it to check for the same 'does this solution already exist in prev release'"*). Every vet prompt must include a question of the form:

    > *Does this solution already exist in the previous release? Check `git show <release-tag>:<path>` yourself. Is the plan's account of shipped behaviour TRUE, is it quoting the function that actually owns the problem, and did the release solve this in a way the plan has not considered?*

    **Why the reviewer, not just the author:** my own grounding was WRONG once even while working under 2g — the F1/F14 plan quoted `?? serverDraftHeader?.stableId` as the shipped OPEN path, but that line lives in `queueSend`; the shipped open passed the header with **no id seed at all** and was permissive only because it lacked HEAD's guard. The vet caught it. An unchecked "SHIPPED BEHAVIOUR" section is an assertion, and assertions from the author are exactly what adversarial review exists to test.

    **Corollary 1 — quote the function that OWNS the problem**, not an adjacent one that merely mentions the same field. Grounding in the wrong shipped line is worse than not grounding at all, because it carries false authority.

    **Corollary 2 — quote the SEQUENCE, do not paraphrase the intent.** Both of my grounding errors on 2026-07-27 were summaries that read as faithful and were not. For F3 I wrote "shipped cancelled first"; shipped actually cleared the *toast* first, then loaded the Draft, then attachments, and only *then* discarded. The real property was not ordering at all — it was that **the discard was attempted unconditionally even when reconstruction failed**. A one-line summary of shipped behaviour is a hypothesis; the numbered order of operations is the evidence. Write the steps.

    **Corollary 3 — the shipped release is a floor, not a ceiling.** Confirm what shipped actually GUARANTEED before citing it as authority. Shipped `discardOutboxMessage` returned no confirmation, refused `.sending`, swallowed errors and printed a success-shaped log after a refusal — so it never established the absolute guarantee my plan claimed for it. Restore the property shipped genuinely had; do not inherit its weaknesses or credit it with strengths it lacked.

3. **Codex owns the plan, specs, reconciliation, and final judgment — but EVERY implementation plan/spec is VETTED BY CLAUDE OPUS (`$ask-claude`) BEFORE source code is written.** This is mandatory: dispatching implementation against an unvetted plan is a process violation. Claude must independently check rule 2g and the class census. Codex verifies and reconciles the review, revises the plan when needed, and only then dispatches a fresh implementation subagent. Plans converge through independent agreement by Codex and Claude, subject to the handoff's current release scope.
4. **Implementation on THIS repo: a fresh Codex SUBAGENT implements; Claude Opus reviews.** The main Codex session supervises and may edit only process/governance artifacts (`CLAUDE.md`, `PLAN_*.md`, memory, skills). A fresh, narrow Codex subagent writes the fix and invariant tests, builds, red-proofs, runs the required suite with zero warnings, and commits only when the coordinator's brief authorizes it. Claude receives read-only audit questions through `$ask-claude` and exact-candidate reviews through `$claude-review`; Claude never writes the live tree. The main session independently reads and verifies the landed code and evidence.

4b. **THE DIFF REVIEW MUST RUN ON THE EXACT COMMIT CANDIDATE — re-run it after every fix round.** A fix for review findings routinely grows the diff beyond what was reviewed, and the new surface is *unreviewed*. Real case (F2b L6 items 1+2, 2026-07-25): round 1 reviewed 7 files / +1045; fixing its 3 blockers grew the diff to 10 files / +1731 **including a brand-new schema migration (v87) that the gate had never seen**. Reviewing round 1's version would have been reviewing code that no longer existed. Rule: after any fix round, `git diff --stat` and compare against what the reviewer actually read; if the surface changed, re-run the gate on the current tree before committing. Fix rounds are where NEW risk enters, not where risk is only removed.

4e. 🚨 **THE MAIN SESSION IS A SUPERVISOR — IT DOES NOT IMPLEMENT** (owner directive 2026-07-25, repeated: *"again, your job is the top-level supervisor, use subagents for actual work"*). **This gets forgotten after every compaction — re-read it on resume.**

    Spec the change, delegate it, verify the result. Do NOT hand-edit source, fix a compile error inline, run a red-proof yourself, or "just quickly" restore something because delegating feels slower. Editing directly is how the coordinator's context fills with implementation detail and stops being able to coordinate at all. The exceptions are narrow: process/governance files (`CLAUDE.md`, `PLAN_*.md`, memory), and reading code to VERIFY an agent's work.

    **Implementation subagents use a correctness-capable Codex model and high reasoning for source changes.** Lightweight read-only inventory work may use a smaller Codex model. Never trade away reasoning quality on concurrency, identity, durability, migrations, red-proofing, or release blockers merely to save tokens. A prior weaker-agent run declared a red-proof complete on a FALSE GREEN (a Swift Testing method-level `-only-testing` filter selected ZERO tests and still exited 0 — `Companion/Memory/History/090-historical-intention-journal-fold-at-drain-adr-ios-058-2026-07-11-queue.md`) while leaving deliberately inverted code in the tree.

    **Supervising means verifying, not trusting.** Read the landed code, not just the agent's report — every significant finding this session came from reading the diff, not from a report.

4d. **ONE SMALL CONFINED JOB PER AGENT — NEVER resume an agent across review rounds** (owner directive 2026-07-25). Implementation subagents get ONE narrow, self-contained task and then finish. **Do not `SendMessage`-resume the same agent for round after round of review fixes.**

    **Why:** doing exactly that in this repo grew a single agent from 192k → 436k → 622k → 691k → 932k tokens across six fix rounds until it WEDGED mid-edit (active, but unable to make tool calls; a queued `SendMessage` never delivered). Recovery cost a full stall investigation. By contrast a fresh, narrowly-scoped verification agent for the same codebase used **76k tokens** and self-recovered from two tool timeouts.

    **The rule:** continuity lives in the BRIEF, not in the agent's context. Each round = a NEW agent whose brief states the current state, the exact change wanted, and the scope boundary ("touch only X", "do not refactor", "if you find a bug, STOP and report — do not fix"). A side benefit: a fresh agent re-reads the CURRENT code instead of trusting a stale memory of what it wrote earlier.

    **Only the main session coordinates.** Subagents never own the review loop, never decide design, never chain their own follow-ups. They implement a specified change, verify it, report, and stop.

4c. **STALL DISCIPLINE — check agents every turn, and make agents check themselves** (owner directive 2026-07-25). Subagent stalls have been the single largest time sink in this repo's long sessions (three in one session; one went 76 minutes unnoticed).

    **Coordinator side — verify liveness EVERY turn while work is in flight.** Do not wait for a completion notification to discover a stall. Cheap 3-signal check:
    ```
    ls -la <task-output>.output | awk '{print $6,$7,$8}'   # transcript mtime — silence > ~10 min with no build running = wedged
    pgrep -fl xcodebuild                                    # is a build actually running?
    ls -lat /tmp/*.done | head                              # last completed build marker
    ```
    A queued-not-delivered `SendMessage` means the agent is ACTIVE but not making tool calls — that is wedged, not finished. On any suspected stall: (a) run the inversion sweep immediately (a mid-red-proof stall strands deliberately-sabotaged code that COMPILES — see `feedback_stalled_subagent_leaves_inverted_code`), (b) establish the tree's build state yourself rather than assuming, (c) nudge with an explicit poll-your-marker instruction.

    **Agent side — every implementation brief MUST include a self-stall clause.** Required text: never end your turn waiting for a build notification; poll your marker file in successive calls; if two consecutive polls show no progress, report that explicitly instead of going silent; and before ending any turn, state what is DONE / IN PROGRESS / NOT STARTED. A partial honest report is far more useful than silence.

**Never point Claude or any external reviewer at secret-bearing files** (credentials, environment files, ignored signing configuration, private keys — PRIME DIRECTIVE); everything Claude reads is sent to Anthropic. `tabmail-ios` is a public repo, so app-source egress for review is acceptable. Preflight `command -v claude`; always invoke the wrapper outside the Codex sandbox with `DISPLAY` unset so the owner's host-visible Claude.ai login is available. If authentication still fails, ask the owner to run `claude auth` in their own terminal (do not auto-install or auto-login). Claude CLI has no OS-level read-only sandbox: `$ask-claude`/`$claude-review` use non-interactive `dontAsk` mode (never plan mode), omit write tools, allowlist narrow read commands, disable slash commands, require explicit `opus[1m]`, and require a post-call Git-state check.

---
