# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in the TabMail iOS app, please report
it privately. **Do not open a public issue.**

Email **security@tabmail.ai** with:

- A description of the vulnerability and its impact
- Steps to reproduce (proof-of-concept if possible)
- The affected app version (Settings → About, or `MARKETING_VERSION` in
  `project.yml`)

We aim to acknowledge reports within 72 hours and to provide a remediation
timeline after triage.

## Scope

This repository covers the iOS client only. The Thunderbird add-on, the native
full-text-search host, and the backend service have their own repositories /
contact points; vulnerabilities in those should be reported to the same address
with the affected component named.

Note that the app authenticates to and exchanges data with the TabMail backend
over HTTPS. Issues in the hosted backend service should also be reported to
**security@tabmail.ai**.

## Disclosure

We follow coordinated disclosure. Please give us a reasonable window to ship a
fix before any public disclosure. There is no paid bug-bounty program at this
time; we are grateful for responsible reports and will credit reporters who wish
to be acknowledged.
