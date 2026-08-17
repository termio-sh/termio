# Security Policy

## Supported versions

Security fixes target the latest released version of Termio and the `main`
branch. Older releases may not receive a backport, so please confirm an issue
against the latest release when practical.

## Reporting a vulnerability

Please report suspected vulnerabilities privately. Do not open a public issue,
discussion, or pull request before a fix is available.

Use GitHub's **Report a vulnerability** form in the repository's Security tab
when it is available. Otherwise, email the maintainer at
[ji-weiyuan@outlook.com](mailto:ji-weiyuan@outlook.com) with the subject
`termio security report`. If the report contains especially sensitive material,
send only a summary first and ask for a secure channel.

Include as much of the following as possible:

- The affected component, release, commit, and platform.
- The security impact and who could be affected.
- Reproduction steps or a minimal proof of concept.
- Relevant logs, screenshots, or crash reports with credentials and personal
  data removed.
- Any known mitigations or suggested fixes.
- A safe way to contact you about follow-up questions and disclosure timing.

Never include active credentials or data belonging to another person. Revoke an
exposed credential before reporting it and identify it only by provider and
type.

You should receive an acknowledgement within three business days. The
maintainer will validate the report, coordinate a fix and release, and keep you
updated while the issue remains active. Please allow a reasonable remediation
period before publishing details.

## Scope

Reports are in scope when they affect the Termio macOS app, iOS companion,
shared packages, landing site, release/update mechanism, or first-party
infrastructure used to distribute Termio.

Reports about an upstream dependency should normally go to that dependency's
maintainer unless Termio uses it in a way that creates a termio-specific
vulnerability. Social engineering, physical attacks, and availability-only
traffic floods are out of scope. Automated scanner output without a
demonstrated security impact is not sufficient on its own.

While researching, avoid privacy violations, service disruption, persistence,
and access to data that is not your own. Stop testing and report immediately if
you encounter sensitive user data.
