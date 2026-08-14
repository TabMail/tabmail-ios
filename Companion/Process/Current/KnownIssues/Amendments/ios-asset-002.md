# IOS-ASSET-002 — During the cross-database move window a just-moved message's inline images fail closed until the view is reopened

**Status:** 📋 ACCEPTED LIMITATION (2026-08-12) — recoverable by one ordinary user gesture, so
registered under THE MANTRA rather than mechanised.

## Subsystem and search terms

Body assets; render security P1d; `BodyAssetSchemeHandler`; `BodyAssetServePolicy.authorize`;
`BodyAssetStore.assetManifestRow`; `BodyAssetStore.rekeyContentKey`; `AccountManagerQueue`
`publishRekeys` / `publishMoveFinish`; `MessageHeaderRekey.finishMove`; `ContentKey`;
`tabmail-asset://`; asset ownership; moved message; broken inline images; `IOS-ASSET-001` sibling;
`PLAN_EMAIL_RENDER_SECURITY.md` §10.2 / §11.1; ADR-IOS-076 decision 5.

## What this record is

P1d bound the `tabmail-asset://` scheme handler to the rendered body's `MessageBody.id`
(`ContentKey`): an asset is served only when the manifest row's `headerId` column equals the
document's owner key. That closed the cross-message read — before it, the handler served **any**
asset id the document named, and asset ids are not secrets.

The predicate reads a **mutable column**, and a move rewrites it. `AccountManagerQueue` publishes
the message-header re-key and the asset-manifest re-key as two steps, and the header re-key
notification can arrive first. In the window between them a view can already be rebound to the
**destination** `ContentKey` while the `bodyAsset` rows still carry the **source** key. Every asset
request in that window resolves a real row, fails the ownership comparison, and is refused as
`not-owned`.

**User-visible effect:** for the moment after archiving or moving a message you had just read, its
cached inline images render as broken images. Nothing else changes — no wrong image is ever shown,
no other message's asset becomes reachable, and no data is lost or deleted.

## Why it is accepted rather than fixed

THE MANTRA's test is recoverability, and this passes it twice over:

1. The manifest re-key lands immediately after, and any subsequent load of that message re-requests
   the assets against the now-corrected rows.
2. Reopening the message — one ordinary user gesture — is sufficient on its own.

`PLAN_EMAIL_RENDER_SECURITY.md` §10.2 assessed this window before P1d landed and reached the same
conclusion: *"Result is temporary broken images, not cross-message disclosure … Consistent with THE
MANTRA — recoverable, so it does not gate."* §11.1 lists it under *filed separately*, as
**registered, not gated**. This record is that registration.

## The direction that is NOT acceptable, stated so it is not "fixed" the wrong way

The tempting compensation is to widen the ownership predicate — accept the source key too, fall back
to an unrestricted lookup, or re-derive ownership from the URL's `headerHash`. **All three are
forbidden**, and the third is also simply wrong:

- Widening to "source or destination" re-opens the cross-message read for exactly the pair of keys an
  attacker-controlled document would most like, and `PLAN_EMAIL_RENDER_SECURITY.md` §10.1 C5 forbids
  compensating with an unrestricted lookup outright.
- Re-deriving from the URL cannot work at all: `BodyAssetStore.rekeyContentKey(from:to:)` deliberately
  re-points the row while preserving the row `id` and the bytes on disk, so the URL baked into the
  cached HTML keeps the **old** `headerHash` forever. A computed `headerHash(currentKey)` would
  reject the legitimate assets of **every** moved message, not merely those inside this window.

The correct narrowing, if it is ever worth doing, is on the **publisher** side: order the asset-manifest
re-key before the header re-key notification, so no view can be rebound to the destination key while
the rows still name the source. That is a change to `AccountManagerQueue`'s publish ordering, not to
the authorization predicate.

## Verification

`BodyAssetOwnershipTests.movedMessageAssetsStayServableUnderTheDestinationKey` pins both sides of the
move: after `rekeyContentKey`, the **unchanged** baked URL is served under the destination key
(non-vacuity — the moved message's images keep working once the manifest has caught up), and the same
URL is refused under the source key (the fail-closed direction this record describes). The window is
the interval in which a view holds the destination key and the rows have not moved yet, which is the
mirror of that second assertion.
