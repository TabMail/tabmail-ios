# IOS-UI-006

- Register classification: `resolved`
- New post-freeze record (2026-08-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **RESOLVED (2026-08-13).** The generic bridge census no longer writes banner state, so the
specific outgoing-coordinator race registered below has no user-visible sink.

## Resolution

`userContentController(_:didReceive:)` still validates and one-shot-gates `imageLoadFailure`, but
classifies it through `ImageLoadFailureReportDisposition` and logs it as
`notice=none diagnostic-only=true`. `AutoSizingHTMLView` owns no image-failure notice state or
binding, so an outgoing coordinator has nothing user-visible to mutate. No
`dismantleUIView` timing assumption is needed.

## Subsystem and search terms

`AutoSizingHTMLView`; `HTMLWebView`; `RenderedDocumentIdentity`; `bodyContentKey`; `.id`; `@State`;
`failedImageCount`; `WKScriptMessageHandler`; `ImageLoadFailureReportDisposition`; outgoing
coordinator; late census; wrong-message banner; SwiftUI remount

## Historical mechanism (generic census before resolution)

`AutoSizingHTMLView` owns `imageFailure` as outer SwiftUI state. When `documentIdentity` changes, its
`.onChange` resets that state. A `bodyContentKey` change also changes `.id(...)`, causing SwiftUI to
dismantle the old `HTMLWebView` and construct a new one. The outgoing coordinator, however, was
created with a binding to `imageFailure.failedCount`; there is no `dismantleUIView`, no dismantled
flag in `userContentController(_:didReceive:)`, and no rendered-document identity carried with the
binding write.

Therefore a census from the outgoing committed document that is already queued for main-actor
delivery could, in principle, arrive after the outer reset and write its count into state now shown
above the incoming document. `CommittedDocumentGate` does not solve this boundary: it correctly
keeps the message attributed to the outgoing committed generation until the new load commits, but
the binding itself does not say which document its value describes.

## What is and is not established

- **Established from code:** the old coordinator holds the shared binding and no explicit teardown
  guard exists.
- **Not established:** that WebKit can deliver the callback after SwiftUI performs the reset/remount,
  or that this has happened on a device.
- **Potential effect:** a temporary or persistent banner over the next message, falsely describing
  the previous message's failed images. Dismissal or the next identity change clears it; no message
  content, server state, or durable user intention is mutated.

## Historical proof that was required before changing the old runtime path

Build a hosted SwiftUI/remount seam that queues an outgoing `imageLoadFailure` callback, changes the
identity, observes the reset, then releases the callback. The red condition is a nonzero count on the
incoming document. Only after that proof should the outgoing path be invalidated—most likely by
removing isolated-world script handlers and marking the coordinator dismantled in
`dismantleUIView`—with a negative control proving the live coordinator still publishes.

## Related

`ADR-IOS-076`; `IOS-UI-004`; `ImageLoadFailureNoticePolicyTests`;
`CommittedDocumentGateTests.aLateRequestFromTheOldDocumentIsAttributedToIt`
