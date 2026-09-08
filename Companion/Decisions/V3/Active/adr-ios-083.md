## ADR-IOS-083: Drafts Never Enter Ordinary Archive or Move

**Status:** Active

**Context:** A Drafts-row Archive followed by Undo can change the message's
provider address without preserving the local draft's editing authority. The
result is a row that appears to be in Drafts but cannot be opened or deleted
through its prior native address. The defect begins when a draft enters the
ordinary role-move pipeline; repairing every possible aftermath is both larger
and less reliable than preventing that transition.

**Decision:** A message positively located in a folder whose role is `.drafts`
must never enter ordinary Archive or user-chosen Move. The restriction is
enforced both at UI/ViewModel surfaces and at `AccountManager.move` after fresh
header resolution, so search, agent tools, thread cards, and future callers
cannot bypass it. A Drafts-source move to a positively identified Trash-role
destination remains eligible because draft deletion has an established,
provider-specific pipeline and is not redesigned here.

The shared boundary uses only positive folder-role facts. A missing folder row
does not manufacture a Drafts classification and does not reintroduce V1's
tri-state per-header classifier.

**Consequences:**

- The existing draft-delete pipeline remains unchanged.
- No migration, new queue state, ownership classifier, stale-draft sweep, or
  legacy address-repair mechanism is introduced.
- Existing drafts stranded by historical Archive/Undo behavior are a separate
  recovery problem tracked outside this change.
- The unavailable-draft full-screen Close control is also independent and is
  tracked separately.

**Invariant:** A positively identified Drafts-role source may reach Trash, but
never an ordinary Archive or Move destination.

**Relates:** ADR-IOS-018, ADR-IOS-068, issue #133, issue #135, issue #136.

**Follow-up:** The Drafts list exposes Delete as its first and only trailing
swipe action, so full swipe invokes the existing draft-delete route. Ordinary
mail keeps Archive followed by Trash. Archive/Move refusal remains in force.
For pushed IMAP drafts, deleting a uniquely owned native header also deletes
the local authored Draft using its complete folder/UID/UIDVALIDITY address and
instance generation. The writer rechecks the address before committing. A fresh
reply then has no saved body to restore and can offer the parent's cached reply
as an unaccepted suggestion again; the cached suggestion itself is preserved.
