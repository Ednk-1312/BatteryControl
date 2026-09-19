# BatteryControl

Reliable battery charge management for **Apple Silicon Macs (M1–M4) running macOS 15 (Sequoia)**.

BatteryControl is a native macOS app that lets you set a fixed charge limit — "keep my
battery around 80%" — and enforces it with a small privileged daemon. It works where
menu-bar-only utilities stop working: when the app is closed, the menu-bar icon is hidden,
the Mac is asleep, or it has just woken up.

---

## What it does

- **Fixed Charge Limit** (the primary mode): pick 60/70/80/90/100% or a custom value, and
  BatteryControl keeps charging in a hysteresis band around your limit — charging stops at
  the upper limit and resumes at the lower limit, without micro-cycling.
- **Force discharge**: cuts adapter input so the Mac runs on battery down to a target while
  plugged in, with a hard 20% safety floor (lower only with explicit, session-scoped consent).
- **Charge to 100%**: a one-time override that bypasses the limit, then restores it.
- **Gauge calibration**: a guided full-cycle battery-gauge refresh with safety aborts.
- **Diagnostics**: full control/backend/verification report, compatibility tier, and an
  anonymized hardware report you can submit to grow the compatibility database.

Everything runs through **one privileged daemon**; the GUI and the CLI are both just
clients of it.

## Features

| Feature | What it does | Honest limitations |
|---|---|---|
| **Fixed Charge Limit** | The primary mode: "set my Mac to 80%" — one-tap presets (60/70/80/90/100%), custom limit, configurable lower limit | Charging may overshoot by a fraction of a percent; the gauge refreshes about once a minute |
| Lower limit | Charging resumes only after the battery falls to the lower limit (hysteresis; by default 2 points below the limit) | — |
| Fixed target | Maintains "about 80%" using a small internal band (±3%) | The dashboard shows the real state, not a fake exact number |
| Force discharge | Cuts adapter input so the Mac runs on battery down to a target on AC | Stops automatically at the target, at the 20% safety floor, on unplug, and before sleep; slow (~1%/5–10 min idle) |
| Below-floor discharge (opt-in) | A red "Remove safety floor" switch allows deliberately draining below the floor for calibration or storage experiments | **Accelerates battery degradation** — the UI requires an explicit confirmation and says so; the daemon independently validates the consent flag |
| Charge to 100% | One-time override that bypasses the limit, then restores it | Also ends on unplug |
| Calibration | Guided full-cycle gauge refresh: discharge to 20% → charge to 100% → hold 3 hours → drop to your limit, with safety aborts | Re-trains the gauge's capacity estimate; it does **not** repair physical battery health |
| Diagnostics | Full system/control report, backend capabilities, readable log | — |

## Supported platform

- **Apple Silicon Macs: M1, M2, M3, or M4** (Pro/Max/Ultra variants included)
- **macOS 15.x (Sequoia)**

**Explicitly unsupported:** Intel Macs, M5-generation Macs, macOS 14 or earlier, macOS 26
(Tahoe) or newer. The app detects the platform at startup and refuses to touch battery
hardware outside the supported scope — it shows this instead:

> BatteryControl supports Apple Silicon Macs from M1 through M4 running macOS 15 Sequoia.

(M5 Macs ship with macOS 26 and cannot boot Sequoia, so there is no meaningful M5 + macOS 15
target. macOS 14 support may be added later; the code is structured so a scope change is a
one-line platform-gate change plus tests.)

## Installation

Two editions ship from one codebase and share the same privileged daemon:

| | **BatteryControl** (GUI + CLI) | **BatteryControl CLI** |
|---|---|---|
| Best for | Most users | Automation, scripting, SSH/headless Macs |
| Native app + menu bar | ✓ | — |
| `batterycontrol` command | ✓ | ✓ |
| Privileged daemon | ✓ (installed by the app's setup flow) | uses the daemon if present, read-only status otherwise |
| Package | `BatteryControl-<version>.pkg` | `BatteryControlCLI-<version>.pkg` |

### Standard install (GUI edition)

1. Download `BatteryControl-1.0.0.pkg` from the
   [latest release](https://github.com/Ednk-1312/BatteryControl/releases/latest) and verify
   it against `SHA256SUMS` if you wish.
2. Run the installer. It places `BatteryControl.app` in `/Applications` and the
   `batterycontrol` CLI in `/usr/local/bin`.
3. Launch BatteryControl. It opens in **setup mode** and shows a setup banner — click
   **Install Helper** and authorize with an administrator password when macOS asks. This
   registers the privileged daemon via `SMAppService`; macOS shows **one** administrator
   prompt. BatteryControl **never stores your password** and creates **no sudoers entries**.
4. Verify the daemon: the setup banner disappears and the dashboard shows live battery
   state. `batterycontrol status` should report `Connected`.
5. Configure your charge limit (see [GUI usage](#gui-usage)) and confirm the dashboard
   reports the limit as **active and hardware-verified** before trusting it.

The packages are currently unsigned installers; on first launch macOS Gatekeeper may ask
you to approve the app under System Settings → Privacy & Security. See
[Signing status](#creating-release-artifacts).

## How the privileged helper/daemon works

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

- **The daemon is the only privileged component.** Installed to
  `/Library/PrivilegedHelperTools/com.batterycontrol.daemon` with its launchd plist at
  `/Library/LaunchDaemons/com.batterycontrol.daemon.plist`, it runs as root with KeepAlive
  and enforces charging policy independently of the app.
- **GUI and CLI can never touch hardware directly.** XPC exposes only named operations with
  validated value objects — no raw SMC access, no generic write primitives. Connections are
  validated (same-team code signing, or same-bundle for ad-hoc developer builds), and the
  daemon re-validates every value at the boundary regardless of who sent it.
- **Closing the app does not stop control.** The daemon persists policy in a root-owned JSON
  file and re-applies it on boot, wake, power-source change, and every 20-second tick. If
  the daemon itself is killed, launchd restarts it and it re-verifies and re-applies the
  persisted policy automatically.
- **Idle efficiency.** Between enforcement decisions the daemon sleeps; redundant SMC
  maintenance traffic and idle GUI churn are gated so an enforcing machine does a small
  periodic hardware confirmation rather than continuous polling.

## GUI usage

- The **dashboard** shows live battery level, power state, your charge limit, and whether
  control is currently **verified on hardware** — it derives everything from the daemon, so
  it never shows "active" unless the daemon can actually verify the hardware.
- **Charging settings** offer the Fixed Charge Limit presets (60/70/80/90/100% + custom) and
  a configurable lower limit (hysteresis). The primary interaction is one tap: "Set my Mac
  to 80%".
- **Discharge controls** start/stop forced discharge with the safety floor; draining below
  the floor requires the red "Remove safety floor" switch plus an explicit confirmation.
- **Diagnostics** shows the detected backend, compatibility tier, verification matrix, and
  the recent daemon log. **Battery information** shows gauge/health data.
- The app lives in the **menu bar**, not the Dock. Closing the window keeps everything
  working; the menu-bar icon is the primary way back in. Settings → **Show menu bar icon**
  toggles the icon (hiding it is cosmetic — the daemon keeps enforcing). If the icon is
  hidden, launching BatteryControl again reopens the window (macOS reopen path).
- Settings also offers **Repair Helper…** (re-runs daemon installation if it is missing or
  outdated) and **Remove Helper…** (uninstalls the daemon and restores macOS default
  charging).

## CLI usage

The CLI is a client of the same daemon — it cannot write SMC keys directly and cannot bypass
any safety rule. These are the actual commands:

```bash
batterycontrol status                     # battery, power, limit, verification state
batterycontrol limit status               # current limit policy and hardware state
batterycontrol limit set 80               # Fixed Charge Limit at 80% (default hysteresis)
batterycontrol limit set 80 --resume 70   # custom lower limit
batterycontrol limit off                  # hand charging back to macOS
batterycontrol discharge status           # force-discharge session state
batterycontrol discharge start 60         # run on battery down to 60% while on AC
batterycontrol discharge stop             # end the discharge, restore adapter input
batterycontrol diagnostics                # full control/backend/verification report
batterycontrol compatibility              # which control mechanisms this Mac supports
batterycontrol version                    # CLI and daemon versions
batterycontrol help                       # usage
```

`discharge start` accepts `--floor <pct>` for a custom stop floor (default 20%) and
`--allow-below-floor`, which permits draining below the floor (it accelerates battery
degradation — the output says so). Consent applies to that discharge session only, and the
daemon independently enforces the requirement even if a client tries to omit it.

Exit codes are script-friendly: `0` success, `2` invalid arguments, `3` daemon unavailable,
`4` unsupported hardware, `5` authorization failure, `6` safety rejection, `7` hardware
write failure, `8` verification failure, `9` communication failure.

## Safety model

- **One authoritative daemon.** All privileged decisions happen in the daemon; clients
  cannot elevate themselves and all values are re-validated at the XPC boundary.
- **Minimal privileged surface.** XPC exposes named operations with typed, secure-coded
  payloads only — no raw SMC reads/writes, no shell-outs, no generic write primitives.
- **Capability detection, not assumption.** At startup the daemon probes which SMC
  mechanisms this firmware actually exposes and selects the best verified backend. Support
  is never inferred from macOS version or model name.
- **Hardware readback verification.** Every write is followed by an observed state
  transition (charging flag, external-power flag, amperage) after a settle window. An action
  is never reported as applied just because the write was accepted; unverified attempts are
  retried a bounded number of times, then reported honestly as not verified. On verification
  failure the daemon deactivates the mechanism rather than leaving unknown state.
- **Fixed-limit hysteresis.** Charging stops at the upper limit and resumes at the lower
  limit; the band is programmed into the firmware where supported, so the SMC itself
  enforces it even during sleep or while the daemon is stopped.
- **Discharge safety.** The discharge floor (default 20%, hard-capped) is enforced in the
  UI, at the XPC boundary, and again in the daemon. Adapter cuts are released on daemon
  start, shutdown, sleep, and SMC failure, so a wedged session can never leave the Mac off
  wall power. Below-floor draining requires explicit, session-scoped consent that expires
  with the session and is re-checked by the daemon independently.
- **Fail-safe defaults.** Invalid policies fail toward "normal charging"; calibration aborts
  on battery-fault reports or floor violations; unknown firmware stays read-only.
- **No permanent privilege.** One `SMAppService` registration at setup; no sudoers entries,
  no stored passwords, no permanent root shells.

## Compatibility and hardware support

BatteryControl is built as a general-purpose Apple Silicon battery-control utility backed by
a growing library of verified firmware profiles. Capability is always decided at runtime by
probing the SMC keys actually present — never by macOS version or Mac model — and every
profile records the hardware evidence behind it.

**Portability:** nothing in the control path is machine-specific. No model identifier,
firmware build, or test value (80/70 or otherwise) appears in the backend, engine, or XPC
code — those live only in the evidence database. A fresh install on another M1–M4 Mac
probes the SMC at runtime and either (a) matches a known key signature and gets full
control with per-action verification, or (b) finds unknown keys and gets read-only
diagnostics. The two known profiles (20xxx firmware-limit, legacy SMC inhibit) are built
into the binary; a community database at `/Library/Application Support/BatteryControl/
compatibility.json` (schema: `Support/CompatibilityDatabase.json`) can add profiles or
refresh evidence without an app update, and grows as users submit reports.

### Confidence tiers

| Tier | Meaning |
|---|---|
| **Verified firmware profile** | Exercised on real hardware with readback verification and observed battery-state enforcement. Documented with full evidence. |
| **Compatible by capability** | The detected SMC key signature matches a known mechanism, but this exact firmware build has not itself been exercised. Runtime verification still gates every action. |
| **Untested firmware** | No profile matches and the key signature is novel. Read-only diagnostics only until evidence is collected. |
| **Unsupported** | Outside the platform gate (M1–M4, macOS 15), or no control mechanism detected. |

The tier is shown in the app's Diagnostics page, in `batterycontrol compatibility`, and in
the daemon's `--diag-smc` output.

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

BatteryControl is designed for Apple Silicon M1–M4 systems running macOS 15.x. Physical
validation has been performed on the project author's M3 MacBook Air; additional hardware
validation is still encouraged. Check your tier in the app's Diagnostics page or with
`sudo com.batterycontrol.daemon --diag-smc`.

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
sudo com.batterycontrol.daemon --export-compat-report ~/Desktop/bc-compat-report.json
```

The report contains hardware identity (chip, model identifier, OS + boot firmware builds)
and the SMC capability signature — no serial numbers, hardware UUIDs, usernames, or paths.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the submission workflow.

## Building from source

Requirements: macOS 15.x on Apple Silicon, Xcode 16+.

```sh
git clone https://github.com/Ednk-1312/BatteryControl.git
cd BatteryControl
open BatteryControl.xcodeproj     # then Cmd+R
```

Or from the command line:

```sh
xcodebuild -project BatteryControl.xcodeproj -scheme BatteryControl -destination 'platform=macOS' build
```

The build produces `BatteryControl.app` with the privileged daemon and its LaunchDaemon
plist embedded at `Contents/Library/LaunchDaemons/`.

## Running tests

```sh
xcodebuild -project BatteryControl.xcodeproj -scheme BatteryControl \
    -destination 'platform=macOS' test
```

The suite (207 tests in `Tests/BatteryCoreTests`) covers the policy engine, backend
selection, verification logic, firmware-limit semantics, calibration, CLI parsing, XPC
envelopes, platform gate, portability, and the failure/recovery negative paths. Pure control
logic lives in `BatteryCore` precisely so it is unit-testable without hardware.

## Creating release artifacts

One script builds everything, signs what it can, and verifies package contents:

```sh
scripts/build-release.sh 1.0.0
```

Artifacts in `dist/`:

| File | Contents |
|---|---|
| `BatteryControl-1.0.0.pkg` | GUI app + CLI + embedded daemon (installs to `/Applications` and `/usr/local/bin/batterycontrol`) |
| `BatteryControlCLI-1.0.0.pkg` | CLI only (`/usr/local/bin/batterycontrol`), **no daemon** — it uses the daemon installed by the GUI edition and reports honestly when none is present |
| `BatteryControl-1.0.0.zip` | Developer-friendly archive of the app + CLI |
| `SHA256SUMS` | SHA-256 hashes of all artifacts |

The CLI-only package never installs privileged components; the one privileged daemon comes
only from the GUI edition's setup flow (`SMAppService`, one administrator authorization).

#### Signing status

The binaries (app, daemon, CLI) are signed with an **Apple Development** certificate when
one is available in the keychain; the CLI falls back to ad-hoc signing otherwise. The
`.pkg` installers themselves are currently **unsigned**: signing them requires a *Developer
ID Installer* certificate and notarization requires a *Developer ID Application*
certificate plus a paid Apple Developer account and network access at release time. Neither
is faked. Until a signed/notarized release is produced, users installing the `.pkg` need to
approve it in System Settings → Privacy & Security on first install (standard Gatekeeper
flow for unsigned packages). `SHA256SUMS` provides integrity verification in the meantime.

## Uninstalling

All privileged components are removed by the app itself:

- **In the app:** Settings → **Remove Helper…** unregisters the daemon, removes it from
  `/Library/PrivilegedHelperTools` and `/Library/LaunchDaemons`, restores macOS default
  charging, then quits. This is the recommended path because it also clears any active
  charge limit safely.
- **Then:** delete `BatteryControl.app` from `/Applications` (and, if you installed the CLI
  edition separately, `/usr/local/bin/batterycontrol`).
- Residual files, all safe to delete: the daemon log at `/var/log/batterycontrol-daemon.log`
  and the preferences/compatibility files under
  `/Library/Application Support/BatteryControl/`.
- Do **not** simply delete the app bundle while the daemon is installed — remove the helper
  first so no launchd job points at a missing binary.

## Troubleshooting

- **The CLI says "daemon unavailable" (exit 3).** The helper isn't installed or isn't
  running: open the app and use **Repair Helper…**, or check
  `sudo launchctl print system/com.batterycontrol.daemon`.
- **The dashboard shows "unavailable" or a stale banner.** The GUI cannot reach the daemon.
  Controls stay honest — nothing is claimed as enforced. Repair the helper; the dashboard
  converges back to authoritative state automatically once the daemon responds.
- **"Hardware verified" is missing while a limit is set.** The daemon could not confirm the
  hardware state (e.g. right after wake). It retries on its enforcement tick; if it persists,
  check `batterycontrol diagnostics` for the verification matrix.
- **The limit doesn't seem to hold.** Confirm the tier: `batterycontrol compatibility`.
  On untested firmware BatteryControl stays read-only by design. On verified/probable
  firmware, check that the firmware limit is actually programmed:
  `sudo com.batterycontrol.daemon --read-firmware-limit`.
- **The Mac won't charge at all after a crash/discharge.** BatteryControl releases adapter
  cuts on daemon start and shutdown, but as a manual escape hatch run
  `batterycontrol discharge stop`, or reboot. `sudo com.batterycontrol.daemon
  --disable-firmware-limit` deactivates a firmware limit.
- **Logs:** `/var/log/batterycontrol-daemon.log` (an empty log is good news), the same
  entries under Diagnostics → Recent helper log, or
  `log show --predicate 'subsystem == "com.batterycontrol.daemon"' --last 1h`.
- **Verify charging behavior yourself:**

  ```sh
  ioreg -rn AppleSmartBattery | grep -i -e IsCharging -e ExternalConnected
  ```

  With a limit set and the battery above it on AC, `IsCharging` should read `No`.

### Advanced hardware diagnostics (daemon binary, root required)

```sh
sudo com.batterycontrol.daemon --diag-smc                # which control families this firmware exposes
sudo com.batterycontrol.daemon --read-firmware-limit     # bfF0/bfD0/bfE0 state (read-only)
sudo com.batterycontrol.daemon --program-firmware-limit 80 70   # program + verify a band
sudo com.batterycontrol.daemon --disable-firmware-limit  # deactivate, restore normal charging
```

`--program-firmware-limit` runs the full safety chain (validation → pre-readback → required
write order → post-readback verify → automatic deactivation on mismatch) and is **blocked**
on machines whose compatibility tier does not allow control writes (`--experimental`
overrides only for supervised verification sessions). `--diag-smc` is read-only and reports
the detected control family: `firmwareLimit` (bf* keys + adapter cut), `legacy`
(CH0B/CH0C + CH0I), `legacyTahoe` (CHTE + CHIE), or `none`.

## Limitations

- **No public macOS API exists for capping charge.** Control uses undocumented SMC
  interfaces, which Apple can change in any release — exactly why every operation is
  verified and the app degrades to "unverified/unsupported" instead of pretending.
- **The CHWA backend is present and probed but intentionally never selected** until a
  verified, machine-specific probe exists; the SMC inhibit mechanism covers the same need.
  The `bclm`-style BCLM mechanism is documented as **not viable on macOS 15+** (kernel
  entitlement enforcement — see bclm's own README) and is represented only as a non-selected
  legacy ID. See `ATTRIBUTION.md`.
- **Physical hardware validation is limited to the author's machine** (see the verified
  profile above). Other machines run under capability-based classification with per-action
  verification; community compatibility reports are how the verified list grows.
- Firmware limits enforce a **band** (upper/lower), not a pinned exact percentage; that is
  the firmware's design and avoids micro-cycling.
- Force discharge is intentionally slow and stops before sleep, on unplug, at the floor, or
  at the target.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The highest-value contribution is a
**compatibility report** — an anonymized hardware/firmware/SMC-capability export from the
Diagnostics page or `--export-compat-report` — which grows the verified profile library that
decides what is safe on real machines. Code contributions follow the architecture rules in
that file: runtime capability detection only, readback verification on every write path,
honest state reporting, and tests for changes to selection/classification/validation logic.

## License

MIT — see [LICENSE](LICENSE).

## Attribution

Portions of BatteryControl adapt or are informed by permissively licensed open-source
projects (SMCKit, battery-limiter, smctl, bclm, actuallymentor/battery, BatFi); the
firmware-limit implementation is an independent implementation from documented behavioral
research. Full licensing detail is in [ATTRIBUTION.md](ATTRIBUTION.md).
