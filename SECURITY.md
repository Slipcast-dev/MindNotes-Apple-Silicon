# Security Policy

## Supported versions

Only the latest release receives security fixes.

| Version | Supported |
|---|---|
| 1.x (macOS and Windows) | ✅ |
| older | ❌ |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Use GitHub's private reporting: **Security → Report a vulnerability** on
<https://github.com/Slipcast-dev/Grizzly/security/advisories/new>.

Include the affected version and platform, steps to reproduce (a sample file helps), and the impact you expect.
You can expect an acknowledgement within 7 days. Fixes are released as a new version and credited in the
advisory unless you prefer to stay anonymous.

## Scope

In scope: crashes or code execution triggered by a crafted document, path or encoding handling bugs, weaknesses in
the Electron configuration (sandbox, preload bridge, CSP), the update mechanism (check, download, checksum verification, installation), and problems in the build scripts.

Out of scope: the lack of Apple notarization / Windows code signing (known and documented), and issues that
require an attacker who already controls the user's machine.

## Verifying downloads

Every release lists SHA-256 checksums. Verify them before running a downloaded file — see
[docs/en/installation.md](docs/en/installation.md).
