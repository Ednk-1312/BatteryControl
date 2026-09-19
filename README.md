# BatteryControl

I wanted my MacBook Air to stop sitting at 100% all day, and the existing charge-limit
tools kept failing on my M3. So I wrote my own. BatteryControl lets you set a charge
limit on Apple Silicon Macs and actually holds it — while the app is closed, the
menu-bar icon is hidden, the Mac is asleep, or it just woke up.

It's a normal macOS app plus a `batterycontrol` command. A small privileged daemon does
the hardware work; the app and CLI just talk to it.

## What it does

- **Charge limit.** Pick a preset (60/70/75/80/85/90/95/100%) or a custom value. Charging
  stops at your limit and resumes at a lower limit (default: 2 points below). No micro-cycling.
  Limits below 80% are the point — Apple's own built-in Charge Limit only spans 80–100%.
- **Force discharge.** Cuts adapter input so the Mac runs on battery down to a target
  while plugged in. Stops at the target, at the 20% floor, on unplug, and before sleep.
- **Charge to 100%.** One-time override, then the limit comes back.
- **Calibration.** Guided full-cycle gauge refresh. This retrains the gauge's estimate;
  it does not repair the battery.
- **Diagnostics.** What backend your Mac uses, whether control is verified right now,
  and an anonymized hardware report you can submit to the compatibility database.

## Features

| Feature | What it does | Caveats |
|---|---|---|
| Fixed Charge Limit | "Set my Mac to 80%" — presets (60–100%), custom, configurable lower limit | Charging can overshoot by a fraction of a percent; the gauge refreshes about once a minute |
| Lower limit | Charging resumes only after the battery falls to it (hysteresis) | — |
| Fixed target | Holds "about 80%" with a small internal band (±3%) | The dashboard shows the real state, not a fake exact number |
| Force discharge | Runs on battery down to a target on AC | Slow (~1% per 5–10 min idle); auto-stops at target/floor/unplug/sleep |
| Below-floor discharge (opt-in) | Red "Remove safety floor" switch allows draining below 20% | Wears the battery out faster. Explicit confirmation required; the daemon checks the consent itself |
| Charge to 100% | One-time override, then restores the limit | Also ends on unplug |
| Calibration | Discharge to 20% → charge to 100% → hold 3 hours → drop to your limit, with safety aborts | Re-trains the gauge estimate; does not fix physical battery health |
| Diagnostics | Backend capabilities, verification state, readable log | — |

## Supported Macs

- Apple Silicon M1, M2, M3, M4, M5 (Pro/Max/Ultra included)
- macOS 14 Sonoma, 15 Sequoia, 26 Tahoe, or 27

Intel Macs, macOS 13 or earlier, and macOS 28 or newer are out of scope. The app checks
at startup and refuses to touch battery hardware outside that range — it shows this
instead:

> BatteryControl supports Apple Silicon Macs from M1 through M5 running macOS 14 Sonoma, macOS 15 Sequoia, macOS 26 Tahoe, or macOS 27.

Chip generation is admission, not capability — an M5 Mac is treated exactly like any
other machine: runtime probing decides what it can do, and nothing is claimed as
verified without evidence. (macOS 14 support may be refined as machines become
available to test on.)

**One important distinction:** a supported OS version gets you in the door — nothing
more. What BatteryControl can actually control is decided at runtime by probing which
SMC mechanisms your firmware exposes, and every write is read back and verified. A Mac
on macOS 27 with an unknown key signature gets read-only diagnostics, exactly like a
Mac on macOS 15 with the same signature. The OS never grants capability.

On macOS 26.4 and later, Apple ships its own Charge Limit (80–100%) in System Settings.
BatteryControl never writes that setting. When no BatteryControl limit is active, the
app and CLI tell you who is actually managing charging; when you set a BatteryControl
limit, the daemon verifies it against the real battery state, and it's the authoritative
controller. Turn BatteryControl off and macOS default charging (including Apple's limit,
if you enabled it) applies again.

## Installation

Two editions, same codebase, same daemon:

| | BatteryControl (GUI + CLI) | BatteryControl CLI |
|---|---|---|
| Best for | Most people | Scripting, SSH, headless Macs |
| App + menu bar | ✓ | — |
| `batterycontrol` command | ✓ | ✓ |
| Privileged daemon | installed by the app's setup flow | uses the daemon if present, read-only status otherwise |
| Package | `BatteryControl-<version>.pkg` | `BatteryControlCLI-<version>.pkg` |

To install the GUI edition:

1. Grab `BatteryControl-1.0.0.pkg` from the
   [latest release](https://github.com/Ednk-1312/BatteryControl/releases/latest)
   (check it against `SHA256SUMS` if you want).
2. Run the installer. It puts the app in `/Applications` and the CLI in `/usr/local/bin`.
3. Launch the app. Click **Install Helper** and type your administrator password when
   macOS asks. That's one `SMAppService` registration — one password prompt, and the
   password is never stored. No sudoers entries.
4. The setup banner goes away once the daemon is up. `batterycontrol status` should
   say `Connected`.
5. Set a limit and watch the dashboard until it says the limit is active and
   hardware-verified.

The packages aren't signed installers, so Gatekeeper may ask you to approve the app
under System Settings → Privacy & Security on first launch. See
[Signing status](#creating-release-artifacts).

## How the daemon works

```
BatteryControl.app (SwiftUI, window + optional menu-bar icon)
        │  XPC (secure-coded, validated objects)
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

The daemon lives at `/Library/PrivilegedHelperTools/com.batterycontrol.daemon` with its
launchd plist in `/Library/LaunchDaemons`. It runs as root and holds the policy in a
root-owned JSON file, re-applying it on boot, wake, power-source change, and every
20-second tick. Kill the daemon and launchd brings it back; it re-verifies and re-applies
the persisted policy on its own.

The GUI and CLI never touch hardware. XPC exposes a fixed set of named operations with
validated objects — no raw SMC access. The daemon also re-validates every value it
receives, and it checks who's calling (same signing team, or same bundle for ad-hoc
developer builds).

Closing the app changes nothing about enforcement. The menu bar is just a window into
the daemon.

## GUI

- Dashboard: battery level, power state, your limit, and whether control is verified on
  hardware *right now*. If the daemon can't verify, the app says so — it doesn't show
  "active" on faith.
- Charging settings: the presets and the lower limit. Setting a limit is one click.
- Discharge controls: with the safety floor. Below the floor needs the red
  "Remove safety floor" switch plus a confirmation dialog.
- Diagnostics: detected backend, compatibility tier, verification matrix, recent daemon log.
- The app lives in the menu bar, not the Dock. Closing the window is fine. Settings →
  **Show menu bar icon** hides the icon if you want — that's cosmetic, the daemon keeps
  working. If you hide the icon, just launch BatteryControl again to get the window back.
- **Repair Helper…** reinstalls the daemon if it's missing or outdated; **Remove
  Helper…** uninstalls it and hands charging back to macOS.

## CLI

Same daemon, so same rules. The commands:

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

`discharge start` takes `--floor <pct>` (default 20%) and `--allow-below-floor` for
draining below the floor. The output warns you it wears the battery out, and the daemon
enforces the consent requirement itself — a client can't skip it.

Exit codes for scripting: `0` ok, `2` bad arguments, `3` daemon unavailable, `4`
unsupported hardware, `5` authorization failure, `6` safety rejection, `7` write
failure, `8` verification failure, `9` communication failure.

## Safety

The short version: the daemon never trusts a write.

- Every hardware write is read back and checked against the actual battery state
  (charging flag, power source, amperage) after a settle window. If the hardware
  doesn't report the expected state, BatteryControl doesn't pretend the change worked —
  it retries a few times, then reports "not verified" and deactivates the mechanism.
- The discharge floor is checked in the UI, at the XPC boundary, and again in the
  daemon. Adapter cuts are released on daemon start, shutdown, sleep, and SMC failure,
  so a crashed session can't leave your Mac off wall power. Below-floor consent only
  lives as long as the discharge session.
- Invalid policies fail toward "normal charging". If anything is ambiguous, the
  default is the safe state.
- One `SMAppService` registration, no sudoers entries, no stored passwords, no
  permanent root shells.

## Compatibility

This is the part you should actually read.

macOS has no public API for capping charge, so every tool in this space (this one
included) talks to the SMC directly. Which SMC keys exist varies by firmware — newer
Apple firmware removed the old charging keys and added its own firmware-managed limit.
So support is decided at runtime, by probing which keys your firmware actually exposes.
Not by model number, not by macOS version.

There's a small compatibility database of hardware profiles behind that:

| Tier | Meaning |
|---|---|
| Verified | Exercised on that exact machine and firmware build, with readback and observed enforcement |
| Compatible by capability | Key signature matches a known family; that exact build hasn't been exercised. Every write is still verified at runtime |
| Untested | Unknown key signature. Read-only diagnostics, no control writes |
| Unsupported | Outside the platform gate, or no usable mechanism |

Where things stand:

- **Physically tested: one machine.** My M3 MacBook Air (Mac15,13), mBoot-20457.1.29,
  macOS 15.8 (24H23). The firmware-managed limit and CHIE discharge both work on it,
  with full write/readback evidence recorded in the profile.
- **Probably works:** Macs whose SMC signature matches a known family — other 20xxx
  firmware, or older-firmware Macs with the CH0B/CH0C/CH0I keys. Those get control with
  per-write verification. If the hardware doesn't honor a write, the app says so
  instead of claiming success.
- **Doesn't claim to work:** everything else, whichever OS or chip it's running. It
  runs, it diagnoses, it stays read-only until there's evidence. There are portability
  and capability tests in the suite, but those prove the software decides correctly —
  they are not a substitute for testing real hardware.
- **OS versions beyond 15 and M5-generation Macs are admitted but unverified.** The
  classification logic is OS- and chip-agnostic and is tested for macOS 14/26/27 and
  M5, and the per-write verification is exactly the same everywhere. But no macOS
  14/26/27 machine and no M5 Mac has physically run BatteryControl yet — treat those
  as capability-tested only until someone actually does.

You can check what your Mac got: `batterycontrol compatibility`, or the Diagnostics page.

The one verified profile, with the actual evidence:

| Profile | Hardware | Firmware | What was proven |
|---|---|---|---|
| `apple-silicon-20xxx-firmware-limit` (bfF0/bfD0/bfE0 + CHIE/CH0J) | MacBook Air M3 (Mac15,13) | mBoot-20457.1.29 · macOS 15.8 (24H23) | Programmed 80/70; every write readback-verified; charging refused above the limit on wall power (−390 mA at 92% on AC); the SMC enforces the band by itself, across processes |

For that profile: `bfF0` is `0x00` inactive / `0x02` active, `bfD0`/`bfE0` are the
upper/lower percentages (ui32, little-endian — unlike normal SMC ui32 keys), written in
the order deactivate → upper → lower → activate, with readback after every write and
automatic deactivation if anything doesn't check out.

One verified profile doesn't mean every 20xxx firmware behaves the same. That's why
unknown firmware stays read-only.

Nothing in the control path is machine-specific — no model IDs, firmware builds, or
test values in the backend/engine/XPC code (there's a structural test that fails if
that ever changes). Machine facts live only in the evidence database. A community
database at `/Library/Application Support/BatteryControl/compatibility.json` (schema in
`Support/CompatibilityDatabase.json`) can add profiles without an app update.

If your Mac reports as untested and you want to help: run the read-only export and
open an issue with the JSON.

```sh
sudo com.batterycontrol.daemon --export-compat-report ~/Desktop/bc-compat-report.json
```

It contains your chip, model identifier, OS and firmware builds, and the SMC key
signature. No serial numbers, UUIDs, username, or paths. More in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Building from source

You need Xcode 16+ on Apple Silicon.

```sh
git clone https://github.com/Ednk-1312/BatteryControl.git
cd BatteryControl
open BatteryControl.xcodeproj     # then Cmd+R
```

or:

```sh
xcodebuild -project BatteryControl.xcodeproj -scheme BatteryControl -destination 'platform=macOS' build
```

The app bundle embeds the daemon and its launchd plist at
`Contents/Library/LaunchDaemons/`.

## Testing

```sh
xcodebuild -project BatteryControl.xcodeproj -scheme BatteryControl \
    -destination 'platform=macOS' test
```

207 tests in `Tests/BatteryCoreTests`: policy engine, backend selection, verification,
firmware-limit semantics, calibration, CLI parsing, XPC envelopes, the platform gate,
portability, and the failure paths (wrong key width, readback mismatch, activation that
doesn't stick, unknown signatures). The control logic that matters lives in `BatteryCore`
so it can be tested without hardware.

## Release artifacts

`scripts/build-release.sh 1.0.0` builds everything into `dist/`:

| File | Contents |
|---|---|
| `BatteryControl-1.0.0.pkg` | App + CLI + embedded daemon |
| `BatteryControlCLI-1.0.0.pkg` | Just the CLI, no daemon |
| `BatteryControl-1.0.0.zip` | The app + CLI as a zip |
| `SHA256SUMS` | Hashes of all three |

The script also expands the packages and checks their contents (the CLI package must
not contain a daemon, and it fails the build if it does).

#### Signing status

The binaries are signed with an Apple Development certificate when one is in the
keychain (the CLI falls back to ad-hoc). The `.pkg` installers are **unsigned** and
nothing is notarized — that needs a paid Apple Developer account and Developer ID
certificates, which this project doesn't have yet. I'm not going to fake it. Practical
consequence: Gatekeeper may ask you to approve the app on first install, and
`SHA256SUMS` is there so you can check what you downloaded.

## Uninstalling

Use the app: Settings → **Remove Helper…**. That unregisters the daemon, removes it
from `/Library/PrivilegedHelperTools` and `/Library/LaunchDaemons`, restores macOS
default charging, and quits. Do this before deleting the app bundle — you don't want a
launchd job pointing at a missing binary.

Then delete `/Applications/BatteryControl.app` (and `/usr/local/bin/batterycontrol` if
you installed the CLI edition). Leftovers, all safe to remove:
`/var/log/batterycontrol-daemon.log` and `/Library/Application Support/BatteryControl/`.

## Troubleshooting

- **CLI says daemon unavailable (exit 3).** The helper isn't installed or isn't
  running. Repair Helper in the app, or check
  `sudo launchctl print system/com.batterycontrol.daemon`.
- **Dashboard shows unavailable.** The app can't reach the daemon. It won't claim
  anything is enforced while it can't verify — that's on purpose. Fix the daemon and
  the dashboard catches up.
- **A limit is set but "hardware verified" is missing.** The daemon couldn't confirm
  the hardware state (common right after wake). It retries on its tick. If it doesn't
  clear, look at `batterycontrol diagnostics`.
- **Limit doesn't seem to hold.** Check `batterycontrol compatibility` first. On
  untested firmware it stays read-only by design. On known firmware, check the
  hardware directly: `sudo com.batterycontrol.daemon --read-firmware-limit`.
- **Mac won't charge after a crash or discharge.** `batterycontrol discharge stop`, or
  reboot. BatteryControl releases adapter cuts on daemon start and shutdown, so this
  should be rare. `sudo com.batterycontrol.daemon --disable-firmware-limit` turns off a
  firmware limit.
- **Logs.** `/var/log/batterycontrol-daemon.log` (empty is good), or Diagnostics →
  Recent helper log, or
  `log show --predicate 'subsystem == "com.batterycontrol.daemon"' --last 1h`.
- **Check charging yourself:**

  ```sh
  ioreg -rn AppleSmartBattery | grep -i -e IsCharging -e ExternalConnected
  ```

  With a limit set, battery above it, on AC: `IsCharging` should be `No`.

For poking at hardware directly (root required):

```sh
sudo com.batterycontrol.daemon --diag-smc                # which control families this firmware exposes
sudo com.batterycontrol.daemon --read-firmware-limit     # bfF0/bfD0/bfE0 state (read-only)
sudo com.batterycontrol.daemon --program-firmware-limit 80 70   # program + verify a band
sudo com.batterycontrol.daemon --disable-firmware-limit  # deactivate, restore normal charging
```

`--program-firmware-limit` runs the full safety chain and refuses to run on machines
whose tier doesn't allow control writes (`--experimental` exists for supervised
verification sessions only). `--diag-smc` is read-only and reports the detected family:
`firmwareLimit` (bf* keys + adapter cut), `legacy` (CH0B/CH0C + CH0I), `legacyTahoe`
(CHTE + CHIE), or `none`.

## Known limitations

- No public macOS API for this, so it's undocumented SMC interfaces all the way down.
  Apple can change them whenever. That's exactly why every operation is verified and
  the app degrades to "unverified" instead of guessing.
- The CHWA backend is probed but never selected — no verified probe for it yet; the SMC
  inhibit mechanism covers the same ground. The old BCLM trick doesn't work on macOS
  15+ at all (kernel blocks it).
- Physically validated on one machine (mine). Everything else is capability-based with
  per-write verification. Compatibility reports are how this gets better.
- Firmware limits are a band, not an exact pin. That's the firmware's design and it's
  what avoids micro-cycling.
- Force discharge is slow, and it stops before sleep. That's deliberate.
- Unsigned installers, no notarization (see above).

## Contributing

The most useful thing you can send me is a compatibility report — run the export
command above and open an issue with the JSON. That's what grows the list of machines
this actually works on.

Code contributions are welcome too. The rules that matter: capability detection at
runtime only (never model/OS-based), readback verification on every write path, honest
state reporting, and tests for anything that touches selection/classification/validation.
Details in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).

## Attribution

Pieces of this adapt or build on MIT-licensed projects: SMCKit (the SMC user-client
basics), battery-limiter (the CH0B/CH0C/CH0I semantics and the daemon/app split),
smctl (verify-after-write discipline), bclm, actuallymentor/battery, and BatFi. The
firmware-limit implementation is my own, written from documented behavioral research —
no GPL code (the `batt` project) was used. Full detail in
[ATTRIBUTION.md](ATTRIBUTION.md).
