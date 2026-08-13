/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Which DOCUMENT a banner state is a statement about.
///
/// The banner says "the images THIS message asked for did not arrive", so its
/// scope is the rendered CONTENT — not "the web view reloaded", and not "this
/// SwiftUI view was re-evaluated". Membership is therefore exactly the inputs
/// that decide WHICH content is on screen, and deliberately excludes the ones
/// that decide only HOW it is drawn:
///
///   * `html` — the body bytes.
///   * `reloadToken` — the caller saying "same view, freshly fetched body".
///     `MessageDetailViewModel` bumps it only after a body REFETCH landed, and
///     `updateUIView` reloads on `html || reloadToken`, so a refetch that
///     returned identical bytes still replaces the document and still re-posts a
///     census. A banner surviving that would be a stale claim about a census
///     that has since been retaken.
///   * `bodyContentKey` — which persisted body this view is bound to. A row
///     re-keyed by a move rebinds the view to a different message; the `.id(…)`
///     on the web view dismantles the platform view, but `@State` on the
///     enclosing `AutoSizingHTMLView` survives it, so nothing else would clear
///     the count. This is the wrong-message direction and the expensive one.
///
/// EXCLUDED, on purpose: the colour scheme. `updateUIView` reloads the document
/// on a light↔dark flip (so `fixDarkModeColorsJS` re-runs), which is a genuine
/// reload of the SAME content. Scoping the banner to reloads rather than to
/// content would re-raise a notice the user had dismissed on the message they
/// are still looking at, every time the appearance changed. Also excluded:
/// `previewFilename`, which does not itself trigger a reload — see the
/// `.eml`-sheet note in `deferredImageLoadJS`'s doc comment.
struct RenderedDocumentIdentity: Equatable {
    let html: String
    let reloadToken: Int
    let bodyContentKey: ContentKey?
}

/// Everything `AutoSizingHTMLView` knows about the image-failure banner, in one
/// value so the DOCUMENT-scoped reset is a single named operation with a single
/// test — rather than two loose `@State` writes a later edit can clear by halves.
///
/// Pinned by `ImageFailureBannerStateTests`.
struct ImageFailureBannerState: Equatable {
    /// How many of the remote images THIS document deferred ended in `error`, as
    /// reported once by `postImageWidthRecheckJS` via the `imageLoadFailure`
    /// bridge channel. 0 until the page settles, and 0 forever if nothing failed.
    var failedCount = 0

    /// Whether the user dismissed the notice for THIS document.
    var dismissed = false

    /// The banner is on screen iff at least one remote image ended in `error`
    /// and the user has not dismissed it.
    ///
    /// Says nothing about timing on purpose: `failedCount` is written only once
    /// the last armed image has settled, so a nonzero value cannot exist before
    /// then and no "have we finished loading?" term is needed here.
    var isVisible: Bool { failedCount > 0 && !dismissed }

    /// What a view showing `old` should publish now that it is showing `new`.
    ///
    /// ⚠️ Both fields are document-scoped and MUST clear together. Carrying
    /// `dismissed` across a document change would silently suppress the banner on
    /// the NEXT message the user opens — the one failure mode a purely
    /// observational notice cannot absorb, because it has no second channel to
    /// tell the user anything. Carrying `failedCount` across would be worse
    /// still: a message that lost nothing would accuse its sender's server. That
    /// is why this returns a whole value rather than clearing fields: there is no
    /// way to write "clear one half" through it.
    ///
    /// TOTAL on purpose — it answers for `old == new` as well — so the call site
    /// is one unconditional assignment with no branch of its own to get wrong.
    ///
    /// ⚠️ This replaced `mutating func documentChanged()`, which took no
    /// argument and so could not express WHICH change it was reacting to. The
    /// caller supplied that, as `.onChange(of: html)`, and `html` is only one of
    /// the three inputs that select a document — so a body refetch that returned
    /// identical bytes, and a row re-keyed onto a different message, both left
    /// the previous document's count and dismissal in place. Making the identity
    /// an argument is what moves that decision somewhere a test can reach it.
    static func carried(
        _ state: ImageFailureBannerState,
        describing old: RenderedDocumentIdentity,
        into new: RenderedDocumentIdentity
    ) -> ImageFailureBannerState {
        old == new ? state : ImageFailureBannerState()
    }
}

/// Dismiss-only notice shown above a rendered message when at least one of the
/// remote images that message asked for ended in `error` (P4, ADR-IOS-076).
///
/// Driven by `ImageFailureBannerState.isVisible`, which is fed by the
/// `imageLoadFailure` bridge channel — a count `postImageWidthRecheckJS` posts
/// ONCE, after the last deferred image has settled.
///
/// ⚠️ **Observational only, and this is the whole design.** Nothing here — and
/// nothing on the path that raises it — retries, probes, HEAD-checks or otherwise
/// re-requests a failed URL, and nothing changes which images load or when. There
/// is deliberately no "Load anyway" action: there is no per-image runtime ATS
/// opt-out on iOS, and the three things that would work are all worse than the
/// problem (a global `NSAllowsArbitraryLoadsInWebContent` weakens web-content ATS
/// for *every* message; static per-domain exceptions cannot be written for
/// arbitrary senders; an image proxy is new infrastructure that relays the
/// tracking hit through us, against ADR-004). Dismiss is the only affordance.
///
/// ⚠️ **This is NOT the 2026-06-17 block-with-banner design** (Memory/037 bullet
/// 30), which BLOCKED remote images and then explained itself, was smoke-tested,
/// broke every message whose layout depends on images loading, and was REVERTED.
/// That revert is not precedent against this: this banner appears strictly after
/// the fact and alters no load behaviour at all.
///
/// ⚠️ **The copy must not be strengthened.** `onerror` fires for far more than an
/// ATS/TLS refusal — 404s, DNS failures, malformed image bytes and a plain offline
/// device are all indistinguishable to the page — so the message says "may not",
/// names no domain, and states no count. Anyone tempted to make it more specific
/// has to first find a signal WebKit does not give us.
struct ImageLoadFailureBanner: View {
    let onDismiss: () -> Void

    /// The single source of the user-visible sentence, so a test can pin the
    /// hedge rather than re-typing it.
    ///
    /// `nonisolated` is load-bearing, not decoration: `View` conformance makes
    /// this type `@MainActor`-isolated under Swift 6, so a plain `static let`
    /// here is main-actor property that `ImageLoadFailureBannerTests` — a
    /// nonisolated suite — cannot read without a warning. The string is an
    /// immutable `Sendable` constant with no actor state, so opting it out is
    /// correct rather than a suppression. Dropping the keyword reintroduces the
    /// warning at every reference.
    nonisolated static let message = "Some images couldn't be loaded. The sender's image server may not support a secure connection."

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(Self.message)
                .font(.caption2)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.textMuted)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .accessibilityElement(children: .contain)
    }
}
