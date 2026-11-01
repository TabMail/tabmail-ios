# Optional trial feedback

The real inbox offers a passive feedback row only after current authoritative account data says the signup trial ended, access is inactive, and a real session is present. Demo mode and other folders do not offer it. There is no modal on startup, account-linked attribution or automatic submission.

The optional form starts without a selection. Six categorical reasons map to the fixed `trial-v1` questionnaire. Explicit Submit sends exactly that version and one reason through a dedicated ephemeral URLSession, with no app credentials, cookies, account/device identifiers, free text, redirects or app-level retry. Transport errors do not claim confirmed delivery. Cloudflare necessarily processes network metadata; the form discloses this and links the existing privacy policy. Do not describe the transport as completely anonymous.

Not now defers the invitation in memory for this process. Don't ask again and a confirmed submission store only a device-level boolean in UserDefaults, never an account key, selected answer or submission identifier. Dismissal cancels the form's structured task; an already delivered request cannot be undone. Only HTTP 204 confirms acceptance.

The usage service must separately deploy and enable its bounded, aggregate-only endpoint with an expiry and constant-key rate limiter before releasing this client. Collection remains off during held PR preparation. Verify actual edge/log/export retention, aggregate cleanup and App Store disclosures before activation. No new Terms/privacy policy date or consent gate is introduced by this change.

Tests inspect the actual URLSession request, error and cancellation behavior, local suppression state, and mounted form/inbox surfaces. Native verification and the canonical review gate are required before signoff. This change is stacked on the held inbox-reminder branch and does not alter payment timing or entitlements.
