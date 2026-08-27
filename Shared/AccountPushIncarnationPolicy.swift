/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Pure account-incarnation admission rule shared by the main app and NSE.
///
/// 🚨 THE WORLD HAS THREE ANSWERS, NOT TWO. Comparing a payload's incarnation
/// against the mirrored account map can come out **proven current**, **proven
/// superseded**, or **not determined** — and the third is not a shade of either
/// neighbour. This type existed with only two outcomes, so every undetermined
/// case was silently folded into whichever neighbour was nearest: a missing
/// mirror became "replaced account" (and terminally stripped a VALID
/// notification), while a missing incarnation became "match" (and admitted a
/// push routed from an incarnation that no longer exists). Both folds are the
/// same defect the never-drop contract names as the single most repeated one in
/// this codebase's history — *"we could not determine the answer" is not "the
/// provider told us it is stale"*, and it is not "the provider told us it is
/// fine" either.
///
/// The rule for consumers, therefore:
///
///   * `.current` is the ONLY verdict that binds an identity. It carries the
///     account id that was actually checked, so a caller acts on the identity
///     it proved rather than re-reading a map that can change underneath it.
///   * `.superseded` is the ONLY verdict that refuses anything. It is a
///     positive fact — the mirror answered for this address and named a
///     different row — so a refusal derived from it stays true when replayed.
///   * `.undetermined` must be neither. It may not strip a notification, may
///     not persist a refusal marker, and may not supply an identity to act on.
enum AccountPushIncarnationPolicy {
    private static let knownAccountProviders: Set<String> = [
        "gmail", "outlook", "imap", "imap_new_mail", "imap_reconnect", "consent_error",
    ]

    /// Marker the NSE stamps on a payload it stripped, so the main app refuses
    /// the same push again without re-deriving the reason. Defined once here
    /// because both targets compile `Shared`.
    ///
    /// Only a `.superseded` verdict may stamp this. That is what makes replaying
    /// it sound: the marker now replays a PROVEN fact rather than whichever
    /// guess produced it.
    static let refusedPushMarkerKey = "tabmail.rejectedAccountPush"

    /// Why a verdict could not be reached. Carried for the log line only —
    /// every reason has identical consequences (admit, bind nothing).
    enum Reason: String, Sendable {
        /// Not an account-scoped push at all (task alarms, local notifications).
        case notAccountScoped = "not account scoped"
        /// The payload never carried the field. No deployed push emits it yet,
        /// so this is the overwhelmingly common case — see `ACCEPTED
        /// LIMITATION` on `verdict(provider:accountEmail:...)`.
        case incarnationAbsent = "incarnation absent"
        /// The mirror could not answer for this address: absent suite, absent
        /// JSON, undecodable JSON, an address the map does not carry (a
        /// not-yet-mirrored account, a casing gap left by an upgrade), or the
        /// briefly-empty map an interrupted account-removal commit leaves
        /// behind. NOT evidence that the account was replaced.
        case mirrorUnavailable = "account mirror unavailable"
        /// A known account provider sent a payload with no account address, so
        /// there is no address to scope the question by. Malformed, but
        /// malformed is not proof of supersession.
        case unscopedAccountPayload = "unscoped account payload"
    }

    enum Verdict: Equatable, Sendable {
        /// PROVEN CURRENT. The mirror answered for this address and named
        /// exactly the incarnation the payload was routed from. `accountId` is
        /// the identity that was checked — and the only identity a caller may
        /// act on for this push.
        case current(accountId: String)
        /// PROVEN SUPERSEDED. The mirror answered for this address and named a
        /// DIFFERENT row: the account was removed and re-added. The only
        /// verdict that refuses anything.
        case superseded
        /// NOT DETERMINED. Never authoritative in either direction.
        case undetermined(Reason)

        /// The identity this push was proved against, or nil when nothing was
        /// proved. Callers that mutate must treat nil as "I have no checked
        /// identity to carry", never as "any identity will do".
        var boundAccountId: String? {
            if case .current(let id) = self { return id }
            return nil
        }

        /// The single question every refusal site asks. Deliberately not
        /// `!isCurrent` — that would re-fold `.undetermined` into a refusal,
        /// which is the defect this type exists to prevent.
        var isSuperseded: Bool { self == .superseded }

        /// Log-line text. `.current` is not loggable as a refusal, so it has no
        /// reason string.
        var reasonDescription: String {
            switch self {
            case .current: return "current"
            case .superseded: return "account replaced"
            case .undetermined(let reason): return reason.rawValue
            }
        }
    }

    /// Judge one account-scoped push against the mirrored account map.
    ///
    /// `accountId` is the mirror lookup: it returns the local row id this
    /// lowercased address currently maps to, or nil when the mirror cannot
    /// answer. **nil means "could not answer", never "no such account"** — the
    /// caller cannot distinguish an absent suite from an absent key, and
    /// neither is proof.
    ///
    /// ACCEPTED LIMITATION (read before "tightening" this): `.undetermined` is
    /// admitted for display and enrichment at every call site, and
    /// `.incarnationAbsent` is currently EVERY deployed push, because the
    /// push-worker does not echo the field yet. Refusing undetermined pushes
    /// would therefore not be the "occasional missed push in a transient state"
    /// this project accepts — it would be a total smart-push outage. The
    /// residual that buys: a long-delayed push routed from a superseded
    /// incarnation can still surface one stale message belonging to the
    /// REPLACEMENT account. That is bounded to mail the user does have, is
    /// shown as that account's own message, and an ordinary sync corrects the
    /// list. What it can never do is mutate a message the user was not shown —
    /// see `EmailNotificationBuilder.fill`, which stamps the single identity a
    /// notification is bound to, and `NotificationDelegate.tapRoute`, which
    /// refuses every action path on a payload whose identity is contradicted or
    /// proven superseded.
    static func verdict(
        provider: String?,
        accountEmail: String,
        accountIncarnation: String?,
        accountId: (String) -> String?
    ) -> Verdict {
        let normalizedProvider = provider?.lowercased() ?? ""
        let normalizedEmail = accountEmail.lowercased()
        if normalizedEmail.isEmpty {
            // Local/unscoped notifications carry neither an account address nor
            // a known account provider. A malformed account push does not get
            // to use that escape hatch as PROOF of anything — it is simply a
            // question we cannot ask, so it binds no identity.
            return knownAccountProviders.contains(normalizedProvider)
                ? .undetermined(.unscopedAccountPayload)
                : .undetermined(.notAccountScoped)
        }
        // ABSENT IS NOT PROVEN-CURRENT. A payload that never named an
        // incarnation cannot vouch for the one it was routed from, so it can
        // never be bound to the row this address happens to resolve to today.
        guard let accountIncarnation, !accountIncarnation.isEmpty else {
            return .undetermined(.incarnationAbsent)
        }
        // ABSENT MIRROR IS NOT PROVEN-STALE. Only a map that actually answered
        // for this address can prove the row was replaced.
        guard let localAccountId = accountId(normalizedEmail), !localAccountId.isEmpty else {
            return .undetermined(.mirrorUnavailable)
        }
        return localAccountId == accountIncarnation ? .current(accountId: localAccountId) : .superseded
    }
}
