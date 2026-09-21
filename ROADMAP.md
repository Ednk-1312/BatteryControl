# Roadmap

This is a plan, not a promise. The 1.0.2 validation pass produced a list of
worthwhile next steps and a list of things deliberately left alone. Scope
decisions follow the same rules as 1.0.2: no compatibility claim without
evidence, no features that sound better than they test, and the safety model
is not negotiable.

**Status after 1.1.0:** the compatibility-report workflow (generator, CLI,
GUI export, issue template), the daemon-validated database install, the
calibration CLI surface, and the passive update check shipped. Native Charge
Limit awareness remains hardware-gated (see
[Docs/NativeChargeLimitTestPlan.md](Docs/NativeChargeLimitTestPlan.md)).
The 1.1.x list below is still open.

## Where 1.1 effort should go

The 1.0.2 audit kept surfacing the same four things:

1. **Hardware evidence is the bottleneck.** One machine is physically verified.
   Everything about making evidence collection easier compounds.
2. **Surface parity.** The GUI, CLI, and daemon should expose the same
   capabilities. Force-charge had a CLI gap (fixed in 1.0.2); calibration has
   the same gap today.
3. **The update experience.** The stale-GUI-after-upgrade fix in 1.0.2 treated
   the symptom. Users still have to discover releases by hand.
4. **Coexistence with Apple's native Charge Limit on macOS 26.4+.** The
   ownership model is code-tested; the real-hardware behavior is not, and the
   UI for "something else is enforcing" needs work before it matters.

## 1.1.0 — proposed contents

### ✅ Compatibility database updates decoupled from app releases (shipped in 1.1.0)

`/Library/Application Support/BatteryControl/compatibility.json` already
overrides the built-in profiles by id, but it only changes when the pkg does.
Today a brand-new Mac that matches a freshly-verified profile needs an app
update to be recognized. Ship updated databases (release asset, or fetched by
the update check below) so hardware support can move at its own pace.

Constraints, in order:

- The file is root-owned; any delivery path must validate integrity (hash or
  signature) before it can influence classification.
- A new profile still has to pass runtime capability probing before it grants
  any control. A database entry broadens *recognition*, never bypasses the
  probe.
- Bad or hostile database content must degrade to built-in profiles, loudly.

### ✅ Compatibility report generation, end to end (shipped in 1.1.0)

- `batterycontrol compatibility --report` emits exactly the JSON the database
  needs: model identifier, chip generation, macOS version/build, firmware
  build, SMC capability map, detected family, tier, matching profile ids.
  No serial numbers, no user names, no locations — a privacy gate refuses
  to emit PII-shaped keys.
- A GitHub issue template (`.github/ISSUE_TEMPLATE/compatibility-report.yml`)
  whose fields match that JSON, so a report lands ready to review and merge
  into `Support/CompatibilityDatabase.json`.
- The app's Diagnostics tab has an "Export Compatibility Report…" action
  using the same generator. One code path, three surfaces (CLI, GUI,
  daemon flag).

### ✅ Calibration in the CLI (shipped in 1.1.0)

`batterycontrol calibration status | start | cancel`, mirroring the
discharge/charge command shape. The daemon owns the sequence; the CLI adds
no validation of its own and reuses the existing XPC calls.

### Native Charge Limit awareness on macOS 26.4+ (hardware-gated)

The ownership model (`OwnershipDecisions`, read-only observation of Apple's
limit state) exists and is unit-tested. Missing pieces:

- UI that says who is enforcing what, in every state: BatteryControl custom
  limit, Apple native limit only, both configured, neither.
- A documented physical test plan for a real macOS 26.4+ machine: does the
  observation probe find Apple's actual registry keys? Does the reported
  ownership match observable behavior?
- Until that machine exists, this stays behind its current honest fallback
  ("could not be read" rather than a guess). **Blocked on hardware access;
  ships unverified or not at all.**

### Update check (passive, no auto-install) — ✅ shipped in 1.1.0 (default on, with a setting)

A daily plain-HTTPS lookup of the project's GitHub releases, shown in the
app's Settings and available as the opt-in `batterycontrol update-check`.
Constraints:

- No auto-download, no auto-install. The 1.0.2 stale-process fix exists
  precisely because in-place upgrades are disruptive; updates stay a
  deliberate user action.
- No telemetry, no identifiers in the request beyond what any fetch exposes.
- Decided: default on with a visible setting (the audience expects a plain
  link, not silence); disabling it stops all update-related requests.

## 1.2.0 — daily-use foundations

The first 1.2 work is intentionally conservative. These pieces are now in the
working tree and use the existing daemon/XPC boundary rather than adding a
second control path:

- **Battery health presentation.** The Info tab labels capacity ratio as an
  estimate, keeps missing values unavailable, and filters malformed telemetry.
- **Named presets.** Daily (80/70), Battery Saver (70/60), Full Charge, and
  Custom all map to the existing validated policy engine. The menu bar exposes
  the same actions through AppState/XPC.
- **Local history.** A bounded, privacy-conscious event store stays on the
  Mac and can be cleared from Settings.
- **Support bundle.** Diagnostics can export a small sanitized JSON manifest
  containing the compatibility report and bounded local history. It does not
  include raw system logs or upload anything.

Still deliberately deferred for a later 1.2.x pass:

- **Native Apple optimization status.** BatteryControl observes the native
  charge-limit state where the existing telemetry can prove it, but it does
  not infer Optimized Battery Charging or compete with Apple's controller.
- **Honest-state notifications.** Reuse `DiagnosticEntry` severity only after
  a user-notification policy is designed and tested.

## Explicitly deferred (and why)

- **CHWA backend selection.** Probed but never selected. Needs evidence of
  its write semantics before any write path exists. Revisit when a machine
  that exposes it can be tested.
- **Speculative backends for unverified firmware families.** The read-only
  fallback is the feature; guessing is the anti-feature.
- **Anything Intel, pre-macOS 14, or post-macOS 27.** Out of scope by charter.
- **Multi-adapter power-level behavior.** Real devices needed to even design
  the test; noted from the 1.0.2 charger-reconnect plan.
- **Cloud anything, accounts, analytics.** Charter exclusions, not roadmap
  items.

## Release discipline carried forward from 1.0.2

- Every compatibility statement in docs and UI matches the evidence tiers.
- The full suite (267 tests after 1.1.0) stays green, zero warnings, Release
  build clean, and the M3 verified profile is physically re-validated before
  any 1.1 release is cut.
- A 1.1.x release that would need to weaken a safety property to ship, waits.
