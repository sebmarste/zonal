# Security policy

## Reporting a vulnerability

Email **zonal@sebmarste.de** with a description, affected version, reproduction
steps and likely impact. Do not publish exploit details or sensitive diagnostics
in a public issue. Share only the minimum data needed; never send passwords,
signing keys or an entire Zonal data folder.

GitHub private vulnerability reporting can also be used once enabled on this
repository. Email remains the private reporting route if that feature is unavailable.
The maintainer will coordinate investigation and disclosure; there is no guaranteed
response time or bug-bounty program.

## Supported versions and boundaries

Security fixes target the latest public beta and current development source.
Older betas are not maintained.

Zonal intentionally uses Accessibility and Input Monitoring to manage windows
and receive global shortcuts. Its local automation interface accepts commands
from the same macOS user; it is not a security boundary against other software
running as that user. No network API or automatic telemetry uploader is provided.

See [bugs and privacy](README.md#bugs-and-privacy) for reviewing diagnostics
and [compatibility](CONTRIBUTING.md#code-map-and-platform-boundaries) for the private macOS API boundary.
