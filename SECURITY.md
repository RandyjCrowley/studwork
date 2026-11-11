# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub's private vulnerability reporting:
open the repository's **Security** tab and choose **Report a vulnerability**, or go directly to
<https://github.com/RandyjCrowley/studwork/security/advisories/new>.

Please do **not** open a public issue, pull request or discussion for a vulnerability.

Include the StudWork version (tag), the affected module or tool, steps or a spec that reproduces
it, and the impact you expect.

## What counts

Problems in StudWork itself (the framework, the kits, the UI kit, the tools) such as:

- **Purchase and receipt handling:** a double grant, granting without payment, taking payment
  without granting, or a receipt recorded without its grant.
- **Data loss or corruption:** paths that lose or corrupt save data, write defaults over a profile,
  or break migrations.
- **Save and session bypasses:** writes after a session is lost, or two servers writing the same
  profile.
- **Compliance bypasses:** undisclosed or wrong odds, paid rolls without disclosed odds or luck,
  players restricted by `PolicyService` receiving paid random items, forged paid tags, trading or
  mailing paid copies.
- **Server-authority bypasses:** client input that skips validation or rate limits, or reaches
  another player's data.
- Guardrail evasions that let one of the above slip through `tools/lint`.

Bugs in a game built with StudWork are that game's to fix, unless the cause is in StudWork.

## Supported versions

| Version | Supported |
|---|---|
| latest 1.x minor | yes |
| older | no (upgrade within 1.x; the module API is additive) |

## What to expect

This is a small project maintained in spare time. I aim to acknowledge reports within a week,
keep you updated while it is investigated, and credit you in the advisory and changelog if you
wish. Fixes ship as a patch release.
