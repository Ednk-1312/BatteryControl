# BatteryControl

Reliable battery charge management for **Apple Silicon Macs (M1–M4) running macOS 15 Sequoia**.

BatteryControl's primary mode is the **Fixed Charge Limit** — "set my Mac to 80%" — with
one-tap presets (60/70/80/90/100% plus custom) and a configurable lower limit for
hysteresis. Under the hood it also offers a fixed charge target, force discharge with a hard
safety floor, a one-time "charge to 100%" override, and a guided gauge calibration — all
enforced by a small privileged daemon that keeps working when the app is closed, the
menu-bar icon is hidden, or the Mac has just woken up.

The project is optimized for a small number of controls that **actually work and verify
themselves** on macOS 15, rather than many features that only look like they work.

## How it works on your Mac

Install → BatteryControl detects your hardware and firmware → probes the SMC at runtime →
selects the best backend your machine actually supports → controls charging. You never need
to know your firmware version, SMC keys, or which backend is in use — Diagnostics shows it
if you are curious.

Because support is decided by **runtime capability probing plus a compatibility database of
hardware-verified profiles** — not by macOS version or model — the app is safe by default:
firmware whose key signature is unknown gets **read-only diagnostics**, never speculative
writes. See [Firmware compatibility library](#firmware-compatibility-library) and
[CONTRIBUTING.md](CONTRIBUTING.md) to help the library grow.

## Requirements

- Apple Silicon Mac: M1, M2, M3, or M4 (Pro/Max/Ultra variants included)
- macOS 15.x (Sequoia)
- Xcode 16+ to build from source

**Explicitly unsupported:** Intel Macs, M5-generation Macs, macOS 14 or earlier, macOS 26
(Tahoe) or newer. The app detects the platform at startup and refuses to touch battery
hardware outside the supported scope — it shows this instead:

> BatteryControl supports Apple Silicon Macs from M1 through M4 running macOS 15 Sequoia.

(M5 Macs ship with macOS 26 and cannot boot Sequoia, so there is no meaningful M5 + macOS 15
target. macOS 14 support may be added later; the code is structured so a scope change is a
one-line platform-gate change plus tests.)

## Feature summary

| Feature | What it does | Honest limitations |
|---|---|---|
| **Fixed Charge Limit** | The primary mode: "set my Mac to 80%" — one-tap presets (60/70/80/90/100%), custom limit, configurable lower limit | Charging may overshoot by a fraction of a percent; the gauge refreshes about once a minute |
| Lower limit | Charging resumes only after the battery falls to the lower limit (hysteresis; by default 2 points below the limit) | — |
| Fixed target | Maintains "about 80%" using a small internal band (±3%) | The dashboard shows the real state, not a fake exact number |
| Force discharge | Cuts adapter input so the Mac runs on battery down to a target on AC | Stops automatically at the target, at the 20% safety floor, on unplug, and before sleep; slow (~1%/5–10 min idle) |
| Charge to 100% | One-time override that bypasses the limit, then restores it | Also ends on unplug |
| Calibration | Guided full-cycle gauge refresh: discharge to 20% → charge to 100% → hold 3 hours → drop to your limit, with safety aborts | Re-trains the gauge's capacity estimate; it does **not** repair physical battery health |
| Diagnostics | Full system/control report, backend capabilities, readable log | — |

## Architecture

```
BatteryControl.app (SwiftUI, normal window + optional menu-bar icon)
        │  XPC (NSSecureCoding envelopes, validated DTOs)
        ▼
com.batterycontrol.daemon  (root LaunchDaemon, KeepAlive)
        │  ChargingBackend protocol
        ▼
Backends: Firmware-managed limit (bfF0/bfD0/bfE0 + CHIE/CH0J/CH0I discharge)
        │  SMC inhibit (CH0B/CH0C + CH0I)  │  CHWA (probed, off by default)
        │  Power assertions (unverified on 15.5+)  │  Observation-only fallback
        ▼
AppleSMC (IOKit user client, root-only writes)
```

Key properties:

- **The daemon enforces everything.** Closing the app, hiding the menu-bar icon, or logging
  out does not stop charge control. The daemon persists its policy in a root-owned JSON file
  and re-applies it on boot, wake, power-source change, and every 20-second tick.
- **Verified control.** Every write is followed by an observed state transition (charging
  flag, external-power flag, amperage). An action is never reported as applied just because
  the write was accepted. Unverified attempts are retried a bounded number of times, then
  reported honestly as not verified.
- **Capability detection at startup.** The daemon probes each backend's mechanism (key
  existence, accessibility) and selects the best verified one; if none is verified, it
  selects the observation-only backend and the UI disables controls instead of faking them.
- **Firmware-managed limit on modern Macs.** On 20xxx-firmware Apple Silicon (where the
  classic CH0B/CH0C/CH0I keys were removed), the daemon programs Apple's own firmware
  charge limit through three SMC keys: `bfF0` (activate, ui8), `bfD0` (upper %, ui32
  little-endian), `bfE0` (lower %, ui32 little-endian). Once written and read-back
  verified, the **SMC itself enforces the band** — during sleep, with the daemon stopped,
  and across reboots. Forced discharge rides the adapter-cut key (`CHIE`/`CH0J`/`CH0I`,
  detected at runtime; CHIE's cut value is 0x08, unlike the older keys' 0x01).
  Note: on this firmware generation the SMC reports size-0 (unpopulated) metadata for
  live keys, so key presence is decided by direct reads, never by metadata alone.

## Firmware compatibility library

BatteryControl is built as a general-purpose Apple Silicon battery-control utility backed
by a growing library of verified firmware profiles. Capability is always decided at
runtime by probing the SMC keys actually present — never by macOS version or Mac model —
and every profile records the hardware evidence behind it.

### Confidence tiers

| Tier | Meaning |
|---|---|
| **Verified firmware profile** | Exercised on real hardware with readback verification and observed battery-state enforcement. Documented with full evidence. |
| **Compatible by capability** | The detected SMC key signature matches a known mechanism, but this exact firmware build has not itself been exercised. Runtime verification still gates every action. |
| **Untested firmware** | No profile matches and the key signature is novel. Read-only diagnostics only until evidence is collected. |
| **Unsupported** | Outside the platform gate (M1–M4, macOS 15), or no control mechanism detected. |

The tier is shown in the app's Diagnostics page and in `--diag-smc` output.

### Current compatibility status (honest)

**BatteryControl does not claim to support every Mac on macOS 15 yet.** The architecture
covers the entire Apple Silicon + macOS 15 ecosystem, and the compatibility library grows
with community evidence:

- **Verified (writes enabled):** M3 MacBook Air (Mac15,13) on mBoot-20457.1.29 /
  macOS 15.8 (24H23), firmware-managed limit + CHIE discharge.
- **Probable (writes enabled, per-action verified):** machines whose SMC key signature
  matches a known family — e.g. other 20xxx-firmware Macs exposing bfF0/bfD0/bfE0, or
  older-firmware Macs exposing CH0B/CH0C/CH0I. These run with the same per-write readback
  and observed-state verification; if a machine does not honor a write, BatteryControl
  reports it honestly and falls back rather than pretending.
- **Untested (read-only):** novel key signatures. The app shows diagnostics and an export
  command; it will not attempt control writes until the profile is verified.

Check your tier in the app's Diagnostics page or with `sudo com.batterycontrol.daemon
--diag-smc`.

### Verified profiles

| # | Profile | Hardware | Firmware | Evidence |
|---|---|---|---|---|
| 1 | `apple-silicon-20xxx-firmware-limit` (bfF0/bfD0/bfE0 + CHIE/CH0J discharge) | MacBook Air M3 (Mac15,13) | mBoot-20457.1.29 · macOS 15.8 (24H23) | Programmed 80/70, every write readback-verified, charging refused above the upper limit on wall power (−390 mA discharge at 92% while AC attached); limit enforced autonomously by the SMC across processes |

**Verified semantics of profile 1** (the exact behaviors proven on hardware):
- `bfF0`: `0x00` inactive / `0x02` active (ui8 activation)
- `bfD0`: upper percentage; `bfE0`: lower percentage (ui32, little-endian)
- Write sequence: deactivate (`bfF0=0`) → upper → lower → activate (`bfF0=2`)
- Per-write readback verification, and automatic deactivation on any verification failure

**Scope warning:** one verified profile does not mean every 20xxx firmware behaves
identically. New firmware builds are classified as compatible-by-capability until they are
exercised on hardware; unknown signatures degrade to read-only diagnostics.

### Contributing a profile

Run the read-only export and open an issue with the JSON:

```sh
sudo com.batterycontrol.daemon --export-compat-report
```

The report contains hardware identity (chip, model identifier, OS + boot firmware builds)
and the SMC capability signature — no serial numbers, hardware UUIDs, usernames, or
paths.
- **Minimal privileged surface.** XPC exposes only named operations with validated value
  objects — no raw SMC access, no generic write primitives. Connections are validated
  (same-team code signing, or same-bundle for ad-hoc developer builds).
- **Safety interlocks.** Discharge floor (default 20%, hard-capped), adapter cut released on
  daemon start, shutdown, sleep, and SMC failure; calibration aborts on battery-fault reports
  or floor violations; invalid policies fail toward "normal charging".

## Building and running

```sh
xcodebuild -project BatteryControl.xcodeproj -scheme BatteryControl -destination 'platform=macOS' build
xcodebuild -project BatteryControl.xcodeproj -scheme BatteryControl -destination 'platform=macOS' test
```

Or open `BatteryControl.xcodeproj` in Xcode and press Cmd+R. The build produces
`BatteryControl.app` with the privileged daemon and its LaunchDaemon plist embedded at
`Contents/Library/LaunchDaemons/`.

### First launch

1. The app opens in **setup mode** (menu-bar-only, no Dock icon) and shows the setup banner.
2. Click **Install Helper** and authorize with an administrator password. The app registers
   the daemon via `SMAppService`, verifies it is running, and establishes XPC.
3. Pick an upper limit and lower threshold. Done — you can close the window.

If installation fails or the daemon is missing/outdated/not running, the setup banner offers
**Repair Helper**, which re-runs the install flow (including an explicit
administrator-authenticated fallback). **Remove Helper** in Settings uninstalls the daemon
and restores macOS default charging.

### Logs

- Helper log (user-readable): `/var/log/batterycontrol-daemon.log` — an empty log is good news
- The same entries appear in Diagnostics → Recent helper log
- Unified log: `log show --predicate 'subsystem == "com.batterycontrol.daemon"' --last 1h`

### Verifying charge control yourself

```sh
ioreg -rn AppleSmartBattery | grep -i -e IsCharging -e ExternalConnected
sudo launchctl print system/com.batterycontrol.daemon   # daemon alive?
```

With a limit set and the battery above it on AC, `IsCharging` should read `No`.

### Hardware diagnostics CLI (advanced)

The daemon binary doubles as a hardware-validation tool (root required):

```sh
sudo com.batterycontrol.daemon --diag-smc   # which control families this firmware exposes
sudo com.batterycontrol.daemon --read-firmware-limit    # bfF0/bfD0/bfE0 state (read-only)
sudo com.batterycontrol.daemon --program-firmware-limit 80 70   # program + verify a band
sudo com.batterycontrol.daemon --disable-firmware-limit # deactivate, restore normal charging
```

`--program-firmware-limit` runs the full safety chain (validation → pre-readback → required
write order → post-readback verify → automatic deactivation on mismatch) and is **blocked**
on machines whose compatibility tier does not allow control writes (`--experimental`
overrides only for supervised verification sessions). `--diag-smc` is read-only and reports
the detected control family: `firmwareLimit` (bf* keys + adapter cut), `legacy`
(CH0B/CH0C + CH0I), `legacyTahoe` (CHTE + CHIE), or `none`.

Export an anonymized compatibility report for the public database:

```sh
sudo com.batterycontrol.daemon --export-compat-report ~/Desktop/bc-compat-report.json
```

Read-only; contains no serial numbers, UUIDs, usernames, or paths. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the submission workflow.

## Project layout

```
BatteryCore/            Shared package: models, policy engine, validation, backend
                        selection, verification logic, calibration state machine,
                        platform gate, XPC protocol + envelopes (app + daemon + tests)
BatteryControl/         SwiftUI app: UI, daemon client, helper installer, monitoring
Helper/                 Privileged daemon: SMC layer, backends, control engine,
                        XPC server, event monitor, policy store, logging
Tests/BatteryCoreTests/ 104 unit tests for all pure control logic
Support/                LaunchDaemon plist + CompatibilityDatabase.json
                        (the distributable verified-profile database)
```

## Scope notes

- The `CHWA` backend is present and probed but intentionally never selected until a
  verified, machine-specific probe exists; the SMC inhibit mechanism covers the same need.
- The `bclm`-style BCLM backend is documented as **not viable on macOS 15+** (kernel
  entitlement enforcement — see bclm's own README) and is therefore represented as a
  non-selected legacy ID for completeness. See `ATTRIBUTION.md`.
- Charging control requires root SMC writes; there is no public macOS API for capping
  charge. Apple can change undocumented SMC behavior in any release — which is exactly why
  this project verifies every operation and degrades to "unverified/unsupported" instead of
  pretending.

## License

MIT — see [LICENSE](LICENSE). Portions adapted from MIT-licensed open-source projects are
credited in [ATTRIBUTION.md](ATTRIBUTION.md).
