# IOS-TLS-002

> Routed from `KNOWN_ISSUES.md` line 111 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `attribution-first`
- Original row SHA-256: `c23dbd78bf5e35c48d5f129a8d807e99f57aaabab4149e3470053e8ffc26d5a1`

## Status

Accepted user-visible consequence of the TLS 1.2 floor; its stated REQUIREMENT was UNMET at the tip and is ✅ **FIXED by `b150f7ee6`**

## Subsystem and search terms

TLS 1.0; TLS 1.1; legacy IMAP server; self-hosted; connect failure; error message

## Full detail

A server that cannot negotiate TLS 1.2 no longer connects. This is a **minimum**, not a pin — any server supporting 1.2/1.3 is unaffected, and modern servers already negotiate 1.3. Affected servers are genuinely unsafe (a network attacker on a TLS 1.0 session can realistically reach mail credentials). Requirement: the failure must surface as a **clear, actionable error naming the TLS floor**, never a silent or generic connection failure.

✅ **FIXED by `b150f7ee6`, "Name the TLS floor when a server is refused for being below it". The requirement above was a REQUIREMENT, and it was UNMET at the tip** — no TLS-floor string existed anywhere in `TabMail/`, `Shared/` or the NSE, so both halves of the promise were broken: the user got `"The operation couldn't be completed. (NIOSSL.NIOSSLError error 0.)"`, which names nothing and suggests nothing while describing a PERMANENT condition no retry can clear, and on the send path `isTransientSendError` read the connection/TLS shape as transient, so a message addressed to a server that can never accept it stayed `.queued` indefinitely with none of the Retry/Discard agency Outbox Rules 7/9 promise. **The invariant that now holds:** a below-floor server produces `IMAPTransportSecurityError.tlsFloorNotMet(host:)` at both connect sites this provider owns (`createServer`'s IMAP connect and `send(draft:)`'s SMTP connect), rendering the same human sentence on both surfaces — it is `CustomStringConvertible` *and* `LocalizedError`, because `OutboxView` prints `errorMessage` (stored as `String(describing:)`) while the account-connect views render `userFacingDescription` — and `isTransientSendError` classifies it explicitly and FIRST, so the send stops silently retrying and the actionable message reaches the Outbox row.

🔎 **THE MATCHER IS DELIBERATELY ONE TOKEN WIDE, AND THAT IS THE FINDING — not an implementation shortcut.** The failure shapes were **measured**, against local `openssl s_server` endpoints, rather than guessed: a TLS 1.0-only server and a TLS 1.1-only server both yield `handshakeFailed(…sslError…TLSV1_ALERT_PROTOCOL_VERSION…)` — **and so does a TLS 1.3 server presenting an untrusted certificate**, arriving in the byte-identical `handshakeFailed(...sslError...)` wrapper and differing ONLY in the BoringSSL reason token (`CERTIFICATE_VERIFY_FAILED`). So the outer shape is not the discriminator: a `handshakeFailed`-or-error-domain matcher would have told a user whose certificate merely expired that **their server is too old**. `IMAPProvider.mapTransportSecurityFailure` therefore matches `TLSV1_ALERT_PROTOCOL_VERSION` and nothing else, in the rendered description rather than by importing NIOSSL so a re-wrapped rethrow still carries it — the technique `SyncEngine.isConnectionError` already uses for NIO's error families — and every unrecognised shape is returned **UNCHANGED**. Fail-to-generic is the deliberate direction: recognising too little leaves a send retrying, recognising too much labels a recoverable failure permanent and stops a send that would have gone through.

⚠️ **THE DELIBERATE NON-COVERAGE, STATED because an absolute needs its negative case (MIS-019):** a below-floor server that answers a version mismatch by returning a **lower ServerHello** instead of a `protocol_version` alert produces a different BoringSSL reason (`UNSUPPORTED_PROTOCOL`). **That case was not reproducible here, so it is NOT matched** and keeps its existing generic, retryable treatment rather than being matched on an unverified string. A user on such a server still gets the generic failure this row's requirement forbids. That is accepted: guessing the token would risk mapping something else onto the TLS-floor sentence, and this row's whole point is that the wrong confident message is worse than a vague one. Also accepted: the version named in the sentence tracks SwiftMail's `MailTLSMinimumVersion` default (`.tlsv12`), so if that default moves the sentence must move with it — a comment at the string says so.
