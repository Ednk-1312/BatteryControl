import Foundation

/// The `batterycontrol` command-line client: pure parsing, dispatch and
/// rendering, unit-testable without XPC. The CLI is a *client only* — every
/// privileged operation goes through the daemon via `DaemonXPCClient`, which
/// re-validates everything at the boundary. Raw SMC access is never exposed
/// to the CLI (or to any client).
///
/// The command layer is pure: `parse` maps argv to a `Command`,
/// `Renderer` maps daemon responses to text. Only the thin executable in
/// `cli/batterycontrol` performs I/O.
public enum BatteryControlCLI {

    // MARK: - Exit codes (stable, script-friendly)

    public enum ExitCode: Int32, Sendable {
        case success = 0
        case invalidArguments = 2
        case daemonUnavailable = 3
        case unsupportedHardware = 4
        case authorizationFailure = 5
        case safetyRejection = 6
        case hardwareWriteFailure = 7
        case verificationFailure = 8
        case communicationFailure = 9
        case notFound = 10
    }

    // MARK: - Command model

    public enum Command: Equatable, Sendable {
        case status
        case limitStatus
        case limitSet(upper: Int, resume: Int?)
        case limitOff
        case dischargeStatus
        case dischargeStart(target: Int, floor: Int?, belowFloorConsent: Bool)
        case dischargeStop
        case chargeStart(target: Int?)
        case chargeStop
        case diagnostics
        case compatibility
        case version
        case help
    }

    // MARK: - Errors

    public struct UsageError: Error, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    // MARK: - Parsing

    /// Parse `argv` (without the program name) into a `Command`.
    /// Throws `UsageError` for anything malformed. No validation of
    /// percentages happens here beyond integer parsing — bounds are the
    /// daemon's job (the client reuses `FixedChargeLimit` only to offer
    /// early, clearer feedback, never as the authority).
    public static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else {
            return .help
        }
        var rest = Array(arguments.dropFirst())

        switch first {
        case "help", "--help", "-h":
            return .help
        case "version", "--version", "-V":
            return .version

        case "status":
            return .status

        case "limit":
            guard let sub = rest.first else {
                throw UsageError("missing subcommand: expected 'limit status', 'limit set <pct>' or 'limit off'")
            }
            rest.removeFirst()
            switch sub {
            case "status":
                return .limitStatus
            case "off":
                return .limitOff
            case "set":
                return try parseLimitSet(rest)
            default:
                throw UsageError("unknown 'limit' subcommand '\(sub)' — expected status, set, or off")
            }

        case "discharge":
            guard let sub = rest.first else {
                throw UsageError("missing subcommand: expected 'discharge status', 'discharge start <pct>' or 'discharge stop'")
            }
            rest.removeFirst()
            switch sub {
            case "status":
                return .dischargeStatus
            case "stop":
                return .dischargeStop
            case "start":
                return try parseDischargeStart(rest)
            default:
                throw UsageError("unknown 'discharge' subcommand '\(sub)' — expected status, start, or stop")
            }

        case "charge":
            guard let sub = rest.first else {
                throw UsageError("missing subcommand: expected 'charge start [pct]' or 'charge stop'")
            }
            rest.removeFirst()
            switch sub {
            case "stop":
                return .chargeStop
            case "start":
                return try parseChargeStart(rest)
            default:
                throw UsageError("unknown 'charge' subcommand '\(sub)' — expected start or stop")
            }

        case "diagnostics":
            return .diagnostics

        case "compatibility":
            return .compatibility

        default:
            throw UsageError("unknown command '\(first)' — try 'batterycontrol help'")
        }
    }

    private static func parseLimitSet(_ args: [String]) throws -> Command {
        var positional: [Int] = []
        var resume: Int?

        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--resume" {
                guard index + 1 < args.count, let value = Int(args[index + 1]) else {
                    throw UsageError("--resume requires an integer percentage")
                }
                resume = value
                index += 2
            } else if arg.hasPrefix("--resume=") {
                guard let value = Int(String(arg.dropFirst("--resume=".count))) else {
                    throw UsageError("--resume requires an integer percentage")
                }
                resume = value
                index += 1
            } else {
                guard let value = Int(arg) else {
                    throw UsageError("unexpected argument '\(arg)' — limit set expects a percentage")
                }
                positional.append(value)
                index += 1
            }
        }

        guard positional.count == 1 else {
            throw UsageError("limit set expects exactly one percentage, e.g. 'limit set 80'")
        }
        return .limitSet(upper: positional[0], resume: resume)
    }

    private static func parseDischargeStart(_ args: [String]) throws -> Command {
        var positional: [Int] = []
        var floor: Int?
        var consent = false

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--allow-below-floor":
                consent = true
                index += 1
            case "--floor":
                guard index + 1 < args.count, let value = Int(args[index + 1]) else {
                    throw UsageError("--floor requires an integer percentage")
                }
                floor = value
                index += 2
            default:
                guard let value = Int(arg) else {
                    throw UsageError("unexpected argument '\(arg)' — discharge start expects a percentage")
                }
                positional.append(value)
                index += 1
            }
        }

        guard positional.count == 1 else {
            throw UsageError("discharge start expects exactly one percentage, e.g. 'discharge start 60'")
        }
        return .dischargeStart(target: positional[0], floor: floor, belowFloorConsent: consent)
    }

    /// `charge start [pct]` — the target is optional and defaults to 100.
    /// Bounds are the daemon's job, as everywhere else.
    private static func parseChargeStart(_ args: [String]) throws -> Command {
        guard args.count <= 1 else {
            throw UsageError("charge start expects at most one percentage, e.g. 'charge start 90'")
        }
        guard let target = args.first else {
            return .chargeStart(target: nil)
        }
        guard let value = Int(target) else {
            throw UsageError("unexpected argument '\(target)' — charge start expects a percentage")
        }
        return .chargeStart(target: value)
    }

    // MARK: - Help

    public static let helpText: String = """
    BatteryControl — charge control for Apple Silicon Macs (M1–M5, macOS 14/15/26/27)

    USAGE: batterycontrol <command> [arguments]

    COMMANDS
      status                          Battery, power, limit and verification state
      limit status                    Current charge-limit policy and hardware state
      limit set <pct>                 Set the Fixed Charge Limit (e.g. 80)
        --resume <pct>                Optional custom lower limit (hysteresis)
      limit off                       Remove the limit (macOS default charging)
      discharge status                Force-discharge session state
      discharge start <pct>           Run on battery down to <pct> while on AC
        --floor <pct>                 Custom stop floor (default 20%)
        --allow-below-floor           DANGEROUS: allows draining below 20%
      discharge stop                  Stop an active discharge
      charge start [pct]              Charge past the limit to <pct> (default 100)
      charge stop                     Stop a force-charge and restore the limit
      diagnostics                     Full control/backend/verification report
      compatibility                   Hardware + firmware compatibility tier
      version                         Print the CLI and daemon versions
      help                            Show this help

    SAFETY
      The CLI is a client of the BatteryControl privileged daemon; it cannot
      write SMC keys directly. Every operation is validated and verified by
      the daemon, which never reports a limit as active without readback.

      Discharging below the 20% safety floor requires --allow-below-floor and
      accelerates battery degradation. Consent applies to that session only.

      Hardware/firmware that BatteryControl does not recognize stays in
      read-only diagnostics mode; controls report honestly instead of acting.

    EXIT CODES
      0 success   2 invalid arguments   3 daemon unavailable
      4 unsupported hardware          6 safety rejection
      7 hardware write failure        8 verification failure
      9 communication failure
    """
}
