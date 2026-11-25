# Security Policy

Please report vulnerabilities privately via GitHub:
**Security → Report a vulnerability** on this repository.

Do not open public issues for security problems. Expect a first response within 7 days.
Only the latest release is supported with security fixes.

## Update signing

In-app updates (Sparkle) are verified with an EdDSA (Ed25519) signature on both
the appcast and each update archive. The public key is baked into release builds.
The private key is kept as a GitHub Actions secret with an offline backup; if it
is lost, existing installs cannot verify new updates until a build with a new key
is installed manually.
