# IOS-PRIVACY-001 — T5 is OPEN: the message render view uses the shared PERSISTENT website data store, one cookie jar across every message and every sender

**Status:** 📋 ACCEPTED LIMITATION (2026-08-12) — **OPEN by explicit owner decision, taken against the
implementing side's recommendation.** Registered here because an open risk nobody wrote down is the
failure mode this file exists to prevent.

## What is exposed

`HTMLWebView.makeUIView` does **not** set `config.websiteDataStore`, so the message web view uses
`WKWebsiteDataStore.default()` — the process-wide, **persistent** store. Concretely:

- **One cookie / localStorage / cache jar is shared by every rendered message and every sender**, and
  by any other `WKWebView` in the app that also uses the default store.
- **It survives app launches.** State written while reading sender A's mail is still there when
  sender B's mail is rendered next week.
- **It needs no sender script.** `allowsContentJavaScript = false` and the twelve-directive CSP do
  not touch this: a remote **subresource** — an `<img>`, a stylesheet, a font — is enough for a
  sender-controlled host to set and later read a cookie. Two different senders whose mail loads
  subresources from the same host can correlate the same reader across messages, and across sessions.

That is threat **T5** in `ADR-IOS-076` / `PLAN_EMAIL_RENDER_SECURITY.md`. It is **not mitigated**. Do
not describe the message render path as "isolated", "sandboxed per message", or "ephemeral"; none of
those is true.

## Why it is open

P1b (`5112fcb5d`) closed T5 with a per-view `config.websiteDataStore = .nonPersistent()`. The owner
reversed it on 2026-08-12 under the standing directive applied to every P1b setting that removed
shipped behaviour:

> *"no behaviour changes, just security"*

**This reversal was made against the implementing side's explicit recommendation.** The
recommendation was to keep `.nonPersistent()` precisely because it closes T5; the owner chose the
shipped store anyway, and that is the decision. It is recorded here rather than re-argued, and it is
recorded *as* a disagreement rather than smoothed over, because the next reader needs to know the
exposure was seen, priced, and accepted — not missed.

Two compromises were considered and are **also** not adopted: a per-view ephemeral store (P1b's
shape) and a single shared ephemeral singleton. Neither is in the tree. Do not add either without
asking the owner.

`v1.7.8` — and every release before it — shipped the symbol **absent** from the file, so the restore
is to **unset**, not to an explicit assignment of the default. Verified:
`git show v1.7.8:TabMail/Views/Shared/AutoSizingHTMLView.swift | grep -c 'websiteDataStore'` → `0`.

## Interaction with the other open render records

- **`IOS-UI-003`** (long-press link preview) compounds this one: a preview fetch runs against this
  same shared persistent jar, so a long-press can write state that a later message reads.
- **`IOS-UI-002`** (data detectors) is independent of it.
- The P1d work in `ADR-IOS-076` decision 5 — binding view identity to the body `ContentKey` — was
  partly motivated by narrowing the store to a message. With no per-view store there is nothing for
  it to narrow; its remaining value is the **asset-ownership** half, not a data boundary.

## Recovery, under THE MANTRA

There is no in-app recovery for correlation that has already happened — the reader was already
correlated. What exists is the ordinary iOS remedy: deleting and reinstalling the app clears the
data store. The exposure is a **privacy** cost, not a data-loss, wrong-message-mutation, dropped-
intention or brick class, which is why it is registered and accepted rather than mechanised.

## Reachability and attribution

Reachable on every rendered message body containing any remote subresource, for every user,
immediately. Not an edge. Attribution class: deliberate accepted privacy exposure, chosen by the
owner over a behaviour change, against advice. Not a defect and not a regression for a later agent to
"fix" from the diff — anyone re-adding a data store here is reversing an owner directive and must ask
first.

## Pinned by

`EmailRenderSecurityCanaryTests.productionConfiguration`, positively and in two directions, because
`isPersistent` alone cannot distinguish the three candidate designs:

- `cfg.websiteDataStore.isPersistent == true` for both the `headerId != nil` and `headerId == nil`
  render paths — a per-view ephemeral store and a shared ephemeral singleton would both report
  `false` here.
- `hostedAsset…websiteDataStore === hostedNil…websiteDataStore` — the **identity** assertion, which
  is what actually measures the sharing. A shared-singleton refactor would keep every `isPersistent`
  assertion green while changing the exposure, so identity is pinned directly.

`AutoSizingHTMLView.logRenderSecurityPosture` additionally prints `persistentStore=` per load in
debug builds, read back off the live `configuration` rather than restated from the source.
