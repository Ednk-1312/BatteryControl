# Security policy

BatteryControl ships a root-level daemon that writes to the SMC, so security
reports are taken seriously. This page explains what's supported, how to
report a problem privately, and what a useful report looks like.

## Supported versions

Security fixes only go to the latest release on the
[releases page](https://github.com/Ednk-1312/BatteryControl/releases) and to
`main`. Older releases don't get patches — please update first and retest
before reporting. Note that older daemons keep running until you update, so
an upgrade is the fix, not just the advisory.

| Version | Security fixes |
|---|---|
| Latest release | yes |
| Earlier releases | no — upgrade |
| `main` | yes (pre-release) |

**Final release note:** BatteryControl is discontinued and 1.3.4 is its final release;
`main` will not see further development. Private reports are still read, but with no
planned releases a fix can no longer be promised — state the impact plainly, because a
serious report is also the most likely thing to bring the project back for one more fix.
The table above describes how the project handled security while it was active.

## Reporting a vulnerability

Please do **not** open a public issue for anything you believe is a security
problem — a public issue can turn a local bug into a working recipe before
there's a fix.

Use GitHub's private vulnerability reporting instead:

**https://github.com/Ednk-1312/BatteryControl/security/advisories/new**

Only the maintainer sees the report. If that link doesn't work for some
reason, open a regular issue saying only "I'd like to report a security
issue" (no details) and I'll follow up another way.

This is a one-person, unpaid project. Reports get a best-effort response —
usually within a week, sometimes faster. There's no bug bounty.

## What to include

The more of this you can provide, the faster I can act:

- BatteryControl version (and whether you installed the GUI or CLI edition)
- `batterycontrol version` and `batterycontrol diagnostics` output
- macOS version, chip, and firmware build (from `system_profiler SPHardwareDataType`)
- Clear steps to reproduce, starting from a default install
- What you expected vs. what happened
- Relevant daemon log lines from the app's Diagnostics tab
- Your own assessment of the impact, if you have one

## What to leave out

- Passwords, private keys, tokens, or any other secrets
- Your Mac's serial number or other personal information
- Files from your home directory

The `batterycontrol compatibility --report` output is fine to attach — it's
built to exclude identifying information.

## Scope

In scope:

- Anything that breaks the privilege boundary: an unprivileged process (GUI,
  CLI, or third-party app) getting the daemon to perform writes it should
  refuse, or reaching SMC access directly
- XPC validation bypasses — forged, replayed, or malformed messages that the
  daemon accepts
- The daemon executing anything other than its fixed operation set
- Policy or compatibility-database files causing writes outside the
  documented safety checks (floor bypass, unverified-state claims, missing
  readback)
- The daemon leaving hardware in a non-default state after failure paths
  that are supposed to restore normal charging

Out of scope:

- Gatekeeper warnings from the unsigned, unnotarized installers — that's a
  known, documented tradeoff, not a vulnerability
- Attacks that require physical access, or an attacker who already has root
- Disabling SIP or other system protections first
- "The app can drain my battery" — the discharge feature is deliberate,
  consent-gated, and documented
- Denial of service against your own machine

If you're unsure whether something is in scope, report it privately anyway
and I'll tell you honestly.

## Safe harbor

If you follow this policy and make a good-faith effort to avoid privacy and
service disruption, I won't pursue action against you for researching or
reporting what you find.
