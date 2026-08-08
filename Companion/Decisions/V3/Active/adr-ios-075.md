## ADR-IOS-075: Body Processing Acknowledges Only Committed Cache State

**Date:** 2026-08-08

**Status:** Active.

**Context.** `BodyFetchProcessor.process` translates a fetched body into two coupled results: durable
`MessageBody` cache state and an outcome consumed by the body queues. For text and attachment-only
messages, a database suspension abort was logged quietly but execution fell through to `.success`
with a `ProcessedItem`. For a confirmed-empty message, an aborted combined body/header transaction
fell through to `.confirmedEmpty`. Those outcomes acknowledged work that had not committed: the
caller could advance FTS/body-complete processing or retire the empty fetch even though the cache
still contained no corresponding body. This contradicted ADR-IOS-046's abandon-on-suspend contract;
quiet logging was correct, but quiet acknowledgement was not.

**Decision.** Every `MessageBody` insertion failure returns `(.retry, nil)`, including expected GRDB
suspension aborts. The attachment-only branch follows the same rule, so it cannot mint an FTS
placeholder for cache bytes that did not land. The confirmed-empty branch returns `.confirmedEmpty`
only after its combined `MessageBody` insertion and `messageHeader` flag update transaction commits;
any abort returns `(.retry, nil)`. The header remains `bodyComplete = 0`, preserving ordinary queue
re-admission on the next wake. Genuine errors remain logged; expected suspension aborts remain quiet.

**Rationale.** A process outcome is an acknowledgement boundary, not a description of fetched bytes.
Fetched bytes may be retried; a success or confirmed-empty disposition can cause downstream state to
advance and therefore must be backed by the durable state it claims. Returning retry is conservative,
idempotent and already the contract used by address refusals and unresolved content.

**Consequences.** A suspension after a provider fetch may repeat that fetch on the next wake, but it
cannot create FTS/body-complete state ahead of the body cache or permanently confirm an empty body
whose transaction never committed. No schema, provider authority or retry budget changes.

**Tests / evidence.** Red checkpoint `cb338d1d8` uses real GRDB suspension notifications to prove the
old text-body and confirmed-empty outcomes were false acknowledgements. Implementation `0ff56514f`
makes both tests green; the complete focused receipt contains 34 passing tests across
`WriteTierRoutingTests`, `ComposeAttachmentCarryTests` and `DraftGenerationSafetyTests` at
`Test-TabMail-2026.08.08_11-03-10--0700.xcresult`.

**Relates:** ADR-IOS-046 (abandon-on-suspend), ADR-IOS-056 (body-queue write tiers),
ADR-IOS-072 (content ownership), never-mark-unfetched-as-fetched.
