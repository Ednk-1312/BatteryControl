# Contributing to BatteryControl

Thank you for helping build a general-purpose, hardware-evidence-backed battery-control
utility for Apple Silicon Macs on macOS 14, 15, 26, or 27. There are two very different ways to
contribute, and both matter:

1. **Compatibility reports** — tell us what your Mac's firmware actually supports.
   This is the single most valuable contribution: it grows the verified profile
   library that decides what is safe on real machines.
2. **Code contributions** — backend implementations, UI, tests, documentation.

## Compatibility reports: grow the profile library

BatteryControl never assumes what your Mac supports from its macOS version or model
name. It probes the SMC at runtime and classifies your firmware into a tier:

| Tier | Meaning | Control writes |
|---|---|---|
| **VERIFIED** | Exercised on this exact machine + firmware build with readback verification and observed enforcement | Allowed |
| **COMPATIBLE / PROBABLE** | Key signature matches a known mechanism family; this exact build not yet exercised (every action still verified at runtime) | Allowed |
| **UNTESTED** | Novel key signature not in the library | **Disabled — read-only** |
| **UNSUPPORTED** | Outside the platform gate (M1–M5, macOS 14/15/26/27) or no mechanism | Never |

### 1. Export your report (read-only, safe)

```sh
sudo /Library/PrivilegedHelperTools/com.batterycontrol.daemon --export-compat-report ~/Desktop/bc-compat-report.json
```

(If the helper is not installed, you can run the same flag from a debug build of the
daemon binary.)

The export is **read-only** — it performs SMC reads only and never writes.

### 2. Check the privacy content

The report contains:

- Chip generation, Mac model identifier (e.g. `Mac15,13`)
- macOS version and build (e.g. `15.8`, `24H23`)
- System (boot) firmware build (e.g. `20457.1.29`)
- The SMC capability signature: which charging/adapter/limit keys are present, with a
  4-byte value snapshot of control keys only
- The detected control family and the tier BatteryControl assigned

It does **not** contain: serial numbers, hardware UUIDs, your username, file paths,
network information, or battery-identity data. You can open the JSON in any editor to
confirm before submitting. If you spot anything you would rather not share, redact it —
but please keep the model identifier, builds, and key signature, since those are what
make the report useful.

### 3. Submit

Open a GitHub issue titled `Compatibility report: <model> <firmware>` and paste the
JSON (or attach it). Maintainers will:

1. Add your machine to the database as **COMPATIBLE** (signature matches a known family).
2. If you volunteer for a supervised verification session (a controlled charge-limit
   write observed end-to-end), promote it to **VERIFIED** with the recorded evidence.

New verified profiles are added to `Support/CompatibilityDatabase.json` (and mirrored
into the built-in library), so every future release recognizes your configuration.

## Code contributions

- **Architecture rules**: capability detection happens at runtime by probing keys —
  never from macOS version or model. New backends implement `ChargingBackend`
  (and `ChargingPolicyConfigurable` when the mechanism holds persistent state) and are
  registered in the engine's probe list. Do not add model-specific special cases.
- **Honesty invariants**: never report an action as applied unless an observed battery
  state confirmed it; verification failures must deactivate and report; every write
  path needs readback verification with a settle window.
- **Safety invariants**: adapter cuts are released on start/shutdown/sleep/failure;
  the discharge floor is hard-capped; invalid policies fail toward normal charging;
  untested firmware stays read-only.
- **Licensing**: this project is MIT. Do not copy code from GPL-licensed projects
  (e.g. `batt`); documented behavioral research is fine — record it in ATTRIBUTION.md.
- **Tests**: pure logic lives in BatteryCore with unit tests; changes to selection,
  classification, or validation must come with tests. Run:

  ```sh
  xcodebuild -project BatteryControl.xcodeproj -scheme BatteryControl test
  ```

## Releasing

1. Update `Support/CompatibilityDatabase.json` with any newly verified profiles.
2. Bump `BatteryXPC.expectedHelperVersion` if the XPC protocol changed.
3. Tag the release; attach the built `BatteryControl.app` to the GitHub release.
