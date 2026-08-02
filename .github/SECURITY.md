# Security Policy

## Scope and threat model

hdhrVCRplus's LAN web server (`WebServer.swift`, off by default, opt-in in Settings) is designed for a **trusted home network**, not the public internet. It authenticates requests only by checking that the caller's IP is on the same local subnet — there is no login, no API key, no per-user access control. Anyone who can reach the configured port on your LAN can view the guide, schedule/edit/delete recordings, and toggle favorites.

This is a deliberate design tradeoff for a single-user home DVR, not an oversight — but it means:

- **Do not port-forward the web server to the internet.** It was never designed to be exposed outside your LAN, and doing so would let anyone who finds it control your recordings.
- If your home network includes untrusted devices (e.g. IoT devices you don't fully trust, a guest network bridged to your main LAN), be aware they can reach this server too if it's enabled.

Within that trusted-LAN scope, input validation (path traversal, injection, etc.) on mutating endpoints is still treated as a real security boundary — see the "WebServer.swift is ~half JavaScript" note in `CLAUDE.md` for the escaping discipline the code follows.

## Supported versions

Only the most recent release is supported. This is a small, single-maintainer project — please update to the latest release before reporting an issue, in case it's already fixed.

## Reporting a vulnerability

Please **do not open a public GitHub issue** for a security vulnerability. Instead, use GitHub's private reporting:

**[Report a vulnerability](https://github.com/identd113/hdhr_VCR_swift/security/advisories/new)** (Security tab → "Report a vulnerability")

This opens a private conversation with the maintainer, not a public issue. Please include:

- What the vulnerability is and its potential impact
- Steps to reproduce
- Affected version

There's no dedicated security team behind this project — response time is best-effort, but reports will be taken seriously and acknowledged as soon as possible.
