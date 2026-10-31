## ADR-IOS-098: The Knowledge Base and the Rules Sync as Labelled Bullets

**Status:** Active (2026-10-30). The same protocol ships in the TabMail Thunderbird add-on (its ADR-028)
and TabMail Voice; the three apps run one set of conformance vectors and one default catalog,
byte-identical and SHA-256 pinned in each repository. Closes tabmail-ios#341, #342, #343, #344.

**Context:** Device Sync sent the knowledge base and the composition and action rules as whole texts and
merged them three ways against a stored peer base. A text says what a device has, not what its user
removed, so a device that was offline, restored from a backup or newly installed could remove or bring
back bullets nobody had touched.

**Decision:**
- **Labelled bullets.** All three fields are stored in one `UserDefaults` value, `device_sync_bullets`
  (`UserDefaultsBulletStore`): each field's bullets, each with a label (a writer name and a counter), and a
  `seen` map. A commit of several fields is one write. Each field's rendered text is written right after to
  the key every reader reads (`user_prompts:user_<field>.md`), including the notification extension's
  read-only mirror (`NSEDataBridge.mirrorPrompts`), which has no sync code and takes no hold.
- **Observed-remove merge** (`Bullets.merge`): a device removes a bullet only when the sender has seen its
  label and no longer holds it. Duplicates of one text keep the smallest label. Merging is deterministic,
  so devices converge.
- **One door, one semaphore** (`PromptStore.withPromptStore`, `PromptSemaphore`). Every read and write of
  the three fields and their history happens in a hold. Callers join ONE first-in-first-out line, wait at
  most `acquireWaitSeconds` (6 s) and are then refused as busy; release and lease expiry (15 s) hand the
  semaphore to the head, so the user's later gesture never lands before an earlier one. A call made inside
  a hold is refused at once through a task-local mark. No retry backoff.
- **Displayed removal.** An editor shows bullets with the labels they carry and deletes exactly those
  (`deleteShown`), never a bullet found again by its text. An AI writer reads in one hold, calls the model
  holding nothing, and writes in a second hold that carries the change counter, refused (`dropped`) when the
  counter moved (`readBeforeAI`, `writeAfterRead`).
- **Writer names are memory only**, one per process for the three fields, abandoned on a reset or a failed
  save. Default bullets carry fixed `default:<id>` labels from the bundled catalog; a reset stores the
  defaults with a seen map of the defaults only, so it never advertises the deletion of a bullet another
  device holds. Nothing is kept per account and nothing is wiped on sign-in or sign-out.
- **Wire.** `bullet_state` messages carry a field's whole state in parts under the relay's budget
  (`BulletSyncConfig.messageMaxBytes`); a snapshot is merged only when complete. Received messages are
  applied one after another in arrival order; one the store refuses as busy is applied again after
  `busyReapplySeconds`; at most `maxWaitingReceives` messages, counting the parts held for incomplete
  snapshots, wait on one connection, and past that the connection is renewed, which drops them. A message
  the socket read after its connection was replaced is never applied. `prompt_state` keeps the other
  legacy fields; this app sends the three texts empty at epoch zero, which released apps skip, and imports
  a released app's text as additions only.
- **No section marker in a rule.** A rule holding the END marker or the section-header mark would be read
  back as the end of the rules or a header, so no writer saves one (`ActionPatchApplier`).
- **Demo mode** shows an overlay under `demo.` keys and writes nothing to the bullets or their history; a
  **history restore** is one captured edit of the shown sections. Entering or leaving the demo is one
  operation on the prompt semaphore, and an operation belongs to the mode it started in: a call counts the
  switches when it is made and the prompt store compares the count when it gets its turn, so a gesture or
  tool that waited behind a switch is refused ("could not save"), and an AI, download or confirmation
  writer that awaited carries the change counter and is refused when it moved. Nothing is saved across a
  switch, in either direction (ADR-IOS-038, amendment 2026-10-31, which replaced the earlier captured
  demo-or-real target). Inside one hold the live mode is stable, so reads of the live setting are right
  where a slot holds the overlay (the shown text, the shown templates, the background snapshots) or where
  Device Sync does not run in the demo.

**Consequences:** No bullet a user did not delete is lost by syncing, in any order of delivery, loss,
restart, restore or new install; this is fuzzed with seeded runs and checked against the shared vectors.
The legacy merge keys are discarded at the upgrade. Edits made on a released app arrive as additions only.
The old merge, its parser and their tests are removed.
