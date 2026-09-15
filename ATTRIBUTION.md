# Attribution and licensing

BatteryControl is MIT-licensed (see `LICENSE`). This file documents which parts are original
and which were adapted from permissively licensed open-source projects, as their licenses
require.

## Adapted from MIT-licensed projects

### SMCKit — beltex/SMCKit (MIT)

`Helper/SMCLayer.swift` contains a minimal SMC client (IOKit `AppleSMC` user client, the
80-byte `SMCParamStruct`, single-byte read/write, key-info queries) that is **adapted from
[SMCKit](https://github.com/beltex/SMCKit)** (MIT, © 2014–2017 beltex), via the trimmed
variant in [battery-limiter](https://github.com/MlayKlayer/battery-limiter) (MIT). The
following notice is retained as required:

> The MIT License (MIT)
>
> Copyright (c) 2014-2017 beltex (https://github.com/beltex)
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this
> software and associated documentation files (the "Software"), to deal in the Software
> without restriction, including without limitation the rights to use, copy, modify, merge,
> publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
> to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
> INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
> PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
> FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
> OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
> DEALINGS IN THE SOFTWARE.

### battery-limiter — MlayKlayer/battery-limiter (MIT)

Design elements informed by [battery-limiter](https://github.com/MlayKlayer/battery-limiter)
(MIT, © 2026 Mlayklayer):

- The **CH0B/CH0C charge-inhibit semantics** (value `2` = inhibit, `0` = normal) and the
  **CH0I adapter-input cut** (`1` = cut, `0` = restore), with the safety analysis of why a
  stuck adapter cut is the dangerous failure mode and must be cleared on daemon start,
  shutdown, sleep, and SMC failure. (Those key semantics ultimately derive from the
  MIT-licensed [BatFi](https://github.com/rurza/BatFi) project, as battery-limiter
  documents; no BatFi source is included.)
- The **root-LaunchDaemon + user-app split**, with the daemon enforcing policy
  independently of the app's lifetime.
- The ** LaunchDaemon install-via-administrator-prompt fallback** approach.

### Concepts studied but not copied

The following projects were studied as references; their code was **not** copied:

- **[batt](https://github.com/charlie0129/batt)** (**GPL-2.0** — no code used) — the
  **behavioral documentation** of the firmware-managed charge-limit mechanism on 20xxx
  firmware: `bfF0` (ui8 activation, 0x00 = off / 0x02 = active), `bfD0`/`bfE0` (ui32
  percentages, **little-endian** unlike conventional SMC ui32 keys), the required write
  order (deactivate → upper → lower → activate), idempotent skip when state already
  matches, and the Tahoe-era key set (`CHTE` inhibit as ui32 first-byte-0x01, `CHIE`
  adapter cut with value 0x08 — unlike CH0I/CH0J's 0x01). BatteryControl's
  `FirmwareLimitBackend`, SMC layer extensions, and validation logic are an **independent
  Swift implementation** from that behavioral specification; no Go source was copied,
  translated, or transformed. Hardware evidence collected by BatteryControl (the verified
  M3 / mBoot-20457.1.29 profile) is original to this project and recorded in the
  firmware compatibility library (`BatteryCore/Services/FirmwareProfiles.swift`).
- **[smctl](https://github.com/leaperone/smctl)** (MIT) — verified-write discipline
  (read-back with a settle window for firmware that applies SMC writes asynchronously),
  runtime capability detection with explicit degradation, and daemon recovery invariants.
- **[bclm](https://github.com/zackelia/bclm)** (MIT) — the BCLM/CHWA firmware-limit
  mechanism. bclm's own documentation states it **does not work on macOS ≥ 15.0** due to
  kernel entitlement enforcement, which is why BatteryControl treats a BCLM-style backend as
  legacy-only and never selects it on macOS 15.
- **[actuallymentor/battery](https://github.com/actuallymentor/battery)** (MIT) —
  maintain-band behavior, force-discharge concepts, and the hysteresis-band rationale.
- **[BatFi](https://github.com/rurza/BatFi)** (MIT) — charge-inhibit key semantics as
  documented through battery-limiter (no source included).

## Original work

Everything else in this repository is original to BatteryControl, including:

- The BatteryCore policy engine (hysteresis/fixed-target/override decisions), validation,
  backend-selection, verification matrix, and calibration state machine
- The multi-backend capability-probe architecture and the observation-only fallback
- The XPC protocol, secure-coding envelopes, and client-validation scheme
- The control engine's verify/retry/recover loop and persistence model
- The entire SwiftUI application and setup/repair flows
- All unit tests
