# Native Charge Limit (macOS 26.4+) — hardware test plan

BatteryControl's ownership model for Apple's built-in Charge Limit is
implemented and unit-tested (`OwnershipDecisions`), but it has **never been
exercised on real macOS 26.4+ hardware**. Until that happens, the daemon
reports Apple's native limit state as "could not be read" rather than
guessing, and this document is the plan for closing the gap.

Status: **blocked on hardware access.** Nothing here is claimed as verified.

## What is already established in code (no hardware claims)

- `OwnershipDecisions` keeps exactly one authoritative controller: when a
  BatteryControl policy is active, the daemon verifies against real battery
  state, so BatteryControl is authoritative; when no BatteryControl policy
  is set and Apple's limit is engaged, macOS is.
- The daemon observes Apple's limit state read-only from the IOKit battery
  registry each tick. The keys are undocumented; an unreadable state is
  reported as "could not be read", never guessed.
- BatteryControl never writes Apple's setting. `limit off` (with
  `--confirm` while a limit is active) restores macOS default charging
  (including Apple's limit if the user set one).
- The CLI `compatibility` output reports who is enforcing what, per state.

## Open questions only hardware can answer

1. Does the observation probe actually find Apple's limit keys in the
   AppleSmartBattery registry on 26.4+? (If not: which keys, or which
   service, carries the state?)
2. Does the reported ownership match observable charging behavior in each
   combination below?
3. Does engaging Apple's native limit while a BatteryControl custom limit
   is active cause any hardware-level conflict (e.g. conflicting inhibit
   requests), or does the firmware simply take the stricter bound?
4. What does `pmset -g` / system settings show after each transition?

## Test matrix (each cell: read state, set state, observe charge behavior)

| # | Apple native limit | BatteryControl policy | Expected owner |
|---|--------------------|-----------------------|----------------|
| 1 | off | off | macOS default |
| 2 | off | 80/78 | BatteryControl (verified active) |
| 3 | 80% | off | Apple (native) |
| 4 | 80% | 60/55 | BatteryControl; verify no fight, charging stops at 60 |
| 5 | 80% | off→on transition live | ownership flips cleanly, no stale "verified" |

For each row, record: the daemon's observed native-limit state, the
compatibility tier line, actual `IsCharging`/amperage behavior across the
band edges, and any log anomalies over at least one full hysteresis cycle.

## Procedure

1. Machine: any M-series Mac running macOS 26.4 or newer with the bf*
   (or equivalent) firmware-limit signature present.
2. Run `batterycontrol compatibility --report` before starting; attach the
   output to the results.
3. Work through the matrix in order, one state at a time, letting each
   state settle for at least 10 minutes (the firmware taper takes ~2 min —
   see the 1.0.2 verification-latency finding).
4. Collect: `batterycontrol status`, `batterycontrol diagnostics`, and the
   daemon log for each row.
5. File results as a compatibility report issue with the matrix filled in.

## What ships depending on the result

- Probe works and matches behavior → the existing ownership UI ships as
  capability-tested with a verified example.
- Probe fails → keep the honest "could not be read" fallback permanently
  for that OS generation and document the actual carrier of the state.
- Any sign of fighting between controllers → BatteryControl defers
  (read-only) whenever Apple's limit is engaged, and the UI says so.
