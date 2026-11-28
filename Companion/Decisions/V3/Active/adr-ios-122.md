## ADR-IOS-122: IMAP Push Credentials Are Sealed to the Push Proxy's Public Key; the App Carries No Key That Opens Them

**Status:** Active (2026-11-27). Replaces the legacy `v2:` envelope, sealed with a symmetric key shared
by the app and the proxy, that `IMAPCredCrypto` used since the unified subscribe.

**Context:** For an IMAP account with push on, the app (and the notification service extension's silent
reconnect) sends the account's IMAP credentials, once per subscribe, through the push worker to the IMAP
push proxy, which logs in and watches the inbox. They travelled in the legacy `v2:` envelope, whose key
both ends held. With a key pair, the standard construction for sealing to one recipient, the sender needs
only the public key and only the recipient holds the key that opens.

**Decision:**
1. **HPKE base mode (RFC 9180) to the proxy's public key.** Suite DHKEM(X25519, HKDF-SHA256),
   HKDF-SHA256, ChaCha20-Poly1305: CryptoKit's `HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly`, one seal
   per envelope. Only the proxy holds the private key; the app holds the public key, which is not a
   secret, so nothing in the app opens an envelope.
2. **Envelope `v3:`** = `"v3:" + base64(keyId[8] ‖ enc[32] ‖ ciphertext ‖ tag[16])`.
   - `keyId` = the first 8 bytes of SHA-256 over the raw public key (`IMAPCredCrypto.keyId(of:)`),
     derived, never configured. The HPKE info is `"tabmail-imap-subscribe-v3" ‖ 0x00 ‖ keyId`
     (`envelopeInfo(keyId:)`), which binds it; the proxy picks its key by it while it holds two.
   - The authenticated data is the unchanged subscribe context (`IMAPSubscribeContext.credentialContext()`,
     whose leading label stays `tabmail-imap-subscribe-v2`: it names the context format, not the envelope).
     The envelope stays bound to user, device, account, device token, sandbox flag and NSE capability.
   - `IMAPSubscribeContext.requestBody` refuses any envelope that is not `v3:`.
3. **One key, shipped in the app.** `IMAPCredCrypto.proxyPublicKey` (raw X25519, base64) in `Shared/Crypto/`,
   used by the app and the extension. Every build uses it, Debug included, because the app always talks
   to the prod push worker and proxy. It is not fetched from the push worker, so the recipient is fixed
   when the app is built.
4. **The legacy envelope's symmetric key leaves the app and its build template.** No symmetric path is
   left in the app, and there is no fallback to it.
5. **Rotation = an app release.** A new key pair goes to the proxy first, which then holds the new key
   and the previous one; an app release ships the new public key; the proxy drops the previous key only
   once clients have moved.

**Order:** the proxy that opens `v3:` and a push worker that forwards it are live before an app build
that seals `v3:` reaches anyone (TestFlight included). The server side keeps accepting the old `v2:`
envelope for a period after the release, so builds that are not yet updated keep working.

**Consequences:** No key in the app can open a credential envelope. A build made before the key pair
existed cannot seal, and an app with an old public key stops working with the proxy once it drops that
key: hence the order above. `IMAPAuthorityCredentialTests` pins the layout against an envelope made the
same way that the proxy's own tests open, checks the shipped key seals, and fences the removed key out of
each target's sources (C included), headers, plists and entitlements and the template. Tests bind the task-local
`IMAPCredCrypto.sealingKey` to a synthetic key, so the app's and the extension's real subscribe paths
are opened end to end with the fields each request carries; `shippedProxyKeySeals` is the one test that
reads the shipped key.
