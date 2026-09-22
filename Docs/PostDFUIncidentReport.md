# BatteryControl — Post-DFU Root-Cause Investigation, Recovery, and Deployment Hardening

## Purpose

This document records the complete root-cause investigation performed after a DFU Revive on the BatteryControl development/test Mac.

The purpose is to provide a future coding agent, maintainer, or developer with a precise technical record of:

- what was initially suspected;
- what was actually broken;
- what was verified healthy;
- how the failure was isolated;
- how the runtime was recovered;
- what was explicitly ruled out;
- and what operational rules must be followed going forward.

This is an evidence-driven diagnosis. Do not reinterpret the DFU Revive as the cause merely because the problem was noticed afterward.

---

# 1. Machine Context

The development/test machine is:

- MacBook Air
- Apple M3
- 8 GB RAM
- Model identifier: `Mac15,13`
- macOS Sequoia 15.8
- Build: `24H23`
- Darwin: `24.6.0`
- ARM64

Battery:

- AppleSmartBattery
- Battery controller: `bq40z651`
- Approximately 205 cycles at the time of final verification
- Apple-reported maximum capacity: approximately 98%
- Battery condition: Normal

Security configuration:

- SIP enabled
- Secure Boot: Full Security
- Signed System Volume enabled
- Kernel CTRR enabled
- Boot Arguments Filtering enabled
- No all-KEXT mode
- No privileged MDM

The system is considered a normal, fully secured Apple Silicon configuration.

There is no evidence that the Mac has damaged firmware.

---

# 2. DFU Revive Context

A DFU Revive was previously performed on this Mac.

The Revive was **not** performed because of BatteryControl.

It was performed during a separate investigation into a Virtualization.framework problem.

That separate investigation involved:

- macOS Sequoia host
- macOS Tahoe guest failing
- macOS Sequoia guest working

The investigation therefore did not establish a BatteryControl-related firmware defect.

The Mac returned to normal operation after the Revive.

The existence of the Revive must never be treated as proof of causality.

Do not:

- perform another DFU operation;
- introduce DFU functionality into BatteryControl;
- introduce MobileDevice.framework;
- introduce AMRestore;
- introduce RecoveryOS APIs;
- introduce Virtualization.framework merely because this investigation occurred after a Revive.

---

# 3. BatteryControl Architecture

BatteryControl is a native SwiftUI macOS battery charge-control utility.

The architecture is deliberately separated:

```text
GUI
 │
 ▼
XPC / IPC
 │
 ▼
Privileged daemon
 │
 ▼
BatteryCore / ControlEngine
 │
 ▼
Hardware backend
 │
 ▼
SMC / battery subsystem
 │
 ▼
Battery hardware
```

The GUI and CLI are clients.

There is one authoritative privileged daemon.

The daemon owns the actual control loop.

BatteryCore/ControlEngine owns policy and safety logic.

The hardware backend owns low-level control.

The GUI must never claim that charge control is active unless hardware state has been successfully verified.

---

# 4. Initial Investigation Requirements

When BatteryControl appears to stop working after a system-level operation, update, reboot, recovery, or DFU-related event:

**Do not immediately assume the system operation caused the problem.**

Do not immediately:

- reinstall BatteryControl;
- rewrite SMC values;
- restore firmware-limit registers;
- perform another DFU;
- modify launchd;
- disable SIP;
- change Secure Boot;
- delete persisted state;
- rewrite the daemon;
- redesign the backend.

First establish the actual failure.

The investigation must distinguish between:

1. GUI failure
2. XPC failure
3. daemon failure
4. BatteryCore/ControlEngine failure
5. backend failure
6. capability-detection failure
7. persistence/state failure
8. deployment/version mismatch
9. duplicate daemon execution
10. genuine hardware/firmware state change
11. unrelated software regression

---

# 5. Critical Lesson: Process Existence Is Not Health

A launchd-managed daemon being alive does not prove the entire application stack is healthy.

Likewise:

```text
launchd → daemon PID exists
```

does not automatically establish:

```text
daemon → BatteryCore initialized
daemon → XPC listener healthy
daemon → backend initialized
daemon → hardware control verified
```

Always trace the complete path.

---

# 6. Critical Lesson: Exactly One Authoritative Daemon

BatteryControl must have exactly one authoritative daemon instance.

The following is **invalid**:

```text
launchd
   ↓
daemon A

manual sudo invocation
   ↓
daemon B
```

Both processes may contain independent ControlEngine instances.

Both may:

- read the same policy;
- write the same SMC registers;
- perform periodic reassertion;
- restore charging;
- change policy state;
- race with each other;
- generate confusing logs;
- create inconsistent runtime state.

Even if the battery happens to be in a correct state, this topology is unsafe and invalid.

---

# 7. The Actual Runtime Defect

The investigation discovered two daemon instances.

The legitimate process was:

```text
PID 548
launchd-managed
com.batterycontrol.daemon
```

A second process was manually launched with:

```text
sudo /Library/PrivilegedHelperTools/com.batterycontrol.daemon
```

This produced:

```text
PID 1635
```

The parent chain demonstrated that it was manually launched from a shell through `sudo`.

Both processes were actively producing control activity.

Daemon logs showed interleaved periodic reassertions, including activity from both PID 548 and PID 1635.

This established that the system had two active ControlEngine instances controlling the same hardware.

This was the primary concrete runtime defect.

---

# 8. Corrective Action for Duplicate Daemon

Only the manually launched process was terminated.

Specifically:

- PID 1635 was terminated.
- Its `sudo` parent was terminated.
- The launchd-managed daemon was never stopped.
- The launchd service remained active.
- The launchd-managed daemon survived the cleanup.

After cleanup:

```text
Exactly one daemon
        ↓
launchd
        ↓
BatteryControl daemon
```

The launchd-managed process remained healthy.

---

# 9. Hardware State Was Not Broken

After removing the duplicate daemon, the system continued to report:

```text
Battery: 84%
Power: Connected
Charging: Not charging

Charge Limit: 80%
Resumes At: 78%

Limit State: Active
Hardware Verified: Yes
```

Raw SMC readback:

```text
bfF0 = 2
bfD0 = 80
bfE0 = 78
```

Interpretation:

```text
bfF0 = active
bfD0 = upper limit
bfE0 = resume threshold
```

The values matched the BatteryControl status output exactly.

This demonstrated that the underlying firmware-limit mechanism was functioning.

---

# 10. SMC Capability Findings

The Mac did not expose the legacy charge-control keys:

```text
CH0B
CH0C
CH0I
```

However, the firmware-limit mechanism was available through:

```text
bfF0
bfD0
bfE0
```

The modern adapter-related keys were also present:

```text
CH0J
CHIE
```

but inactive.

The compatibility profile identified the machine as:

```text
Apple M3
Mac15,13
macOS 15.8
firmware-limit backend
compatibility tier: verified
```

This distinction is important:

**Battery telemetry availability is not equivalent to charge-control capability.**

BatteryControl must always distinguish:

- battery telemetry;
- charging state;
- hardware capability;
- writable control capability;
- verified active control.

---

# 11. Independent Battery Verification

BatteryControl was not the only source used to establish battery health.

Independent macOS telemetry reported:

```text
AC attached
Battery: 84%
IsCharging: No
Cycle Count: 205
Voltage: approximately 12.52 V
Condition: Normal
Maximum Capacity: 98%
```

`system_profiler SPPowerDataType` independently reported:

```text
Device Name: bq40z651
Charging: No
State of Charge: 84%
Cycle Count: 205
Condition: Normal
Maximum Capacity: 98%
```

The Mac was connected to a 35W USB-C power adapter.

The battery subsystem was therefore reporting coherent data independently of BatteryControl.

---

# 12. XPC Verification

A read-only CLI request successfully communicated with the daemon.

The CLI returned:

```text
Battery:              84%
Power:                Connected
Charging:             Not charging
Charge Limit:         80%
Resumes At:           78%
Limit State:          Active
Hardware Verified:    Yes
Backend:              Firmware-managed charge limit
```

This established:

```text
CLI
 ↓
XPC
 ↓
daemon
 ↓
status response
```

was functioning.

The daemon endpoint was active.

The request reached the daemon.

The reply was serialized successfully.

The daemon was not generally unreachable.

---

# 13. Code-Signing and Deployment Findings

The installed application initially reported:

```text
Version: 1.2.0
```

The installed helper also reported:

```text
Version: 1.2.0
```

The repository, however, contained:

```text
Project MARKETING_VERSION: 1.3.0
BatteryXPC.expectedHelperVersion: 1.3.0
```

Therefore:

```text
Repository = 1.3.0
Installed product = 1.2.0
```

This was a deployment mismatch.

Importantly, the installed application and installed helper matched each other at 1.2.0.

This was **not** an internal GUI/helper protocol mismatch.

It simply meant the current checkout was newer than the product actually running on the Mac.

The installed app and helper passed strict code-signature verification.

The same development team was used.

No code-signing failure was established as the cause of the battery-control problem.

---

# 14. Deployment Recovery

The 1.3.0 package was checksum-verified.

The installer initially failed because it was invoked from an inaccessible working directory due to macOS TCC behavior before the package path was processed.

The package was copied to `/tmp` and the installation was performed from `/`.

The upgrade then succeeded.

A stale 1.2.0 daemon process survived the package replacement because the launchd job points into the application bundle.

That stale process was terminated.

launchd then respawned the daemon from the upgraded application bundle.

Final state:

```text
Application = 1.3.0
Helper = 1.3.0
Daemon = 1.3.0
```

This is an important deployment lesson:

**Replacing an application bundle does not necessarily mean the already-running daemon has automatically become the new binary.**

After replacing an application containing a launchd-managed daemon, explicitly verify the running daemon's version.

---

# 15. Final Runtime State

After cleanup and deployment:

```text
Application version: 1.3.0
Daemon/helper version: 1.3.0

Daemon count: exactly one

XPC:
GUI 1.3.0
    ↓
daemon 1.3.0
    ↓
successful handshake

Battery:
84%

Power:
Connected

Charging:
Not charging

Charge limit:
80%

Resume:
78%

Limit:
Active

Hardware:
Verified

SMC:
bfF0 = 2
bfD0 = 80
bfE0 = 78
```

The GUI and CLI agreed.

No GUI/XPC reconnect loop was observed.

No hardware-control discrepancy was observed.

---

# 16. Verification Results

Automated tests:

```text
285 passed
0 failed
```

Debug build:

```text
SUCCEEDED
0 real warnings
```

Release build:

```text
SUCCEEDED
0 real warnings
```

The final installation was therefore validated at:

- source level;
- test level;
- Debug build level;
- Release build level;
- XPC level;
- daemon level;
- backend level;
- SMC readback level;
- GUI/CLI agreement level.

---

# 17. Final Root-Cause Conclusion

The evidence does **not** establish that the DFU Revive damaged BatteryControl, the SMC, or the battery-control firmware mechanism.

The actual concrete runtime defect was:

```text
A manually launched privileged daemon was running
simultaneously with the launchd-managed daemon.
```

This created two independent control engines operating on the same hardware.

A second, separate deployment problem was:

```text
Installed product = 1.2.0
Repository = 1.3.0
```

After:

1. removing only the manually launched duplicate daemon;
2. verifying the launchd-managed daemon;
3. deploying 1.3.0;
4. restarting the stale daemon through launchd;
5. verifying XPC;
6. verifying GUI/CLI agreement;
7. verifying SMC readback;
8. running the full test suite;
9. completing Debug and Release builds;

BatteryControl was confirmed operational.

---

# 18. DFU Revive Relationship

The correct classification is:

## No evidence

There is no direct evidence that the DFU Revive caused the BatteryControl problem.

Evidence against a firmware-damage explanation includes:

- the system firmware is detected normally;
- the expected Mac15,13/M3 compatibility profile is recognized;
- the firmware-limit keys exist;
- `bfF0`, `bfD0`, and `bfE0` are readable;
- SMC readback works;
- the firmware-managed charge limit is active;
- battery telemetry is coherent;
- XPC works;
- the daemon initializes normally;
- GUI and CLI agree;
- the final 1.3.0 build works correctly.

The temporal relationship between the Revive and the investigation is therefore not sufficient to establish causality.

---

# 19. Safety Assessment

The final verified state showed no evidence of uncontrolled charging.

At 84%:

```text
AC = connected
Charging = no
bfF0 = active
bfD0 = 80
bfE0 = 78
Hardware verified = yes
```

This is consistent with the intended firmware-managed charge limit.

The duplicate daemon was nevertheless a legitimate safety concern because multiple control engines can compete over physical battery state.

BatteryControl must therefore treat multiple daemon instances as an invalid runtime condition.

---

# 20. Operational Rule

## Never manually launch the privileged daemon.

Do not run:

```bash
sudo /Library/PrivilegedHelperTools/com.batterycontrol.daemon
```

The daemon is owned by launchd.

The correct topology is:

```text
launchd
   ↓
com.batterycontrol.daemon
   ↓
ControlEngine
   ↓
Battery backend
```

For debugging:

- inspect the launchd-managed daemon;
- inspect its logs;
- inspect its process;
- inspect its XPC endpoint;
- inspect its state.

Do not create a second daemon process.

---

# 21. Future Diagnostic Procedure

If BatteryControl appears broken again, use this order:

## Phase 1 — Reproduce

Determine exactly what the user-facing failure is.

Do not assume "BatteryControl isn't working" means charge control is broken.

Check:

- GUI launch;
- menu-bar state;
- battery telemetry;
- AC state;
- charging state;
- capability;
- configured policy;
- hardware verification;
- GUI responsiveness.

## Phase 2 — Process Topology

Immediately verify that exactly one daemon exists.

Check:

```text
launchd
daemon PID
parent process
duplicate daemon processes
```

If more than one daemon exists, identify why before changing anything else.

## Phase 3 — XPC

Verify:

```text
GUI → XPC → daemon
```

Check:

- connection;
- identity verification;
- requests;
- replies;
- callbacks;
- invalidations;
- protocol/version compatibility.

## Phase 4 — Daemon

Verify:

```text
daemon → ControlEngine/BatteryCore
```

Check:

- initialization;
- backend selection;
- policy state;
- persistence;
- capability discovery.

## Phase 5 — Hardware

Verify:

```text
ControlEngine
    ↓
backend
    ↓
SMC / battery subsystem
```

Use read-only diagnostics first.

## Phase 6 — Deployment

Verify:

- installed application version;
- running daemon version;
- helper version;
- embedded daemon version;
- signatures;
- entitlements.

Never assume the installed product matches the current source checkout.

## Phase 7 — Hardware Readback

Only if appropriate, verify existing hardware state.

Do not write SMC values merely to see whether something works.

## Phase 8 — Code

Only after the runtime evidence points to a source defect should code be modified.

---

# 22. Evidence Classification

Future investigations must distinguish:

### FACT

Directly observed through runtime behavior, logs, commands, source inspection, or hardware readback.

### CODE FACT

Directly established by inspecting source code.

### INFERENCE

A conclusion supported by multiple observations but not directly observed.

### HYPOTHESIS

A possible explanation that has not yet been established.

Never present an inference or hypothesis as a fact.

For example:

Bad:

> The DFU broke the SMC.

Correct:

> The failure was observed after the Revive, but the relevant firmware-limit keys remained present and readable, the existing limit remained active, and the control path continued to work. No evidence established that the Revive caused the problem.

---

# 23. Design Principle Reinforced by This Incident

BatteryControl should prefer:

```text
Verified unsupported
```

over:

```text
Unverified active
```

False-positive hardware capability is more dangerous than correctly reporting unsupported capability.

The application must never claim:

```text
Charge limit active
```

unless the actual hardware state has been verified.

Likewise, the application must not silently:

- write unsupported registers;
- force discharge;
- force charge;
- bypass safety floors;
- manipulate undocumented hardware state.

---

# 24. Recommended Future Hardening

The investigation did not identify a backend code defect.

No backend redesign is required.

However, the incident suggests several potential future hardening improvements:

### Duplicate-daemon detection

The daemon could detect whether another instance is already controlling the hardware and fail safely rather than allowing multiple control engines to operate simultaneously.

### Better operator diagnostics

Diagnostics could explicitly report:

```text
Daemon topology:
1 authoritative daemon
```

and flag abnormal duplicate instances.

### Version visibility

The GUI could expose:

```text
GUI version
Daemon version
Helper version
```

to make deployment mismatches immediately visible.

### Running-binary verification

Development diagnostics could show the exact executable path and version of the currently running daemon.

### Upgrade handling

The installer/update process should ensure that a running daemon is refreshed cleanly after an application bundle replacement.

These are hardening opportunities, not evidence that the existing battery-control backend is fundamentally broken.

---

# 25. Final Status

The investigation is complete.

Final verified architecture:

```text
BatteryControl 1.3.0
        │
        ▼
       XPC
        │
        ▼
launchd-managed daemon 1.3.0
        │
        ▼
   ControlEngine
        │
        ▼
FirmwareLimitBackend
        │
        ▼
 bfF0 / bfD0 / bfE0
        │
        ▼
Battery hardware
```

Final verified state:

```text
Battery: 84%
AC: Connected
Charging: No

Upper limit: 80%
Resume: 78%
Limit: Active
Hardware verified: Yes

Daemon count: 1
GUI/CLI: Agree
XPC: Working
Tests: 285/285
Debug build: Passed
Release build: Passed
```

## Conclusion

BatteryControl was not shown to have been damaged by the DFU Revive.

The concrete runtime problem was an invalid duplicate-daemon topology caused by manually launching the privileged daemon alongside the launchd-managed instance.

The separate deployment mismatch was an installed 1.2.0 product running while the repository had advanced to 1.3.0.

Both issues have been resolved.

No SMC restoration was required.

No firmware modification was required.

No additional DFU operation was required.

No BatteryCore/backend code change was required.

The verified BatteryControl 1.3.0 control path is functioning normally.
