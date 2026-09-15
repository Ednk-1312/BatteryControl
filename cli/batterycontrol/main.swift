import BatteryCore
import Foundation

/// `batterycontrol` — CLI client of the BatteryControl privileged daemon.
/// Thin on purpose: parsing, output rendering, and exit-code mapping live in
/// BatteryCore (`BatteryControlCLI`, `CLIRunner`) where both editions share
/// them. This executable only wires argv/stdout to the shared layer. It
/// never talks to hardware directly — the daemon is the authority.
let arguments = Array(CommandLine.arguments.dropFirst())

do {
    let command = try BatteryControlCLI.parse(arguments)
    let (output, exitCode) = await CLIRunner.run(command)
    print(output)
    exit(exitCode.rawValue)
} catch let error as BatteryControlCLI.UsageError {
    fputs("batterycontrol: error: \(error.message)\n\n", stderr)
    fputs("Run 'batterycontrol help' for usage.\n", stderr)
    exit(BatteryControlCLI.ExitCode.invalidArguments.rawValue)
} catch {
    fputs("batterycontrol: unexpected error: \(error)\n", stderr)
    exit(BatteryControlCLI.ExitCode.communicationFailure.rawValue)
}
