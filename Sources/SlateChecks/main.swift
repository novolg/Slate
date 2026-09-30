import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "phase0" {
    exit(await Phase0.run(arguments: Array(arguments.dropFirst())))
}
Harness.filter = arguments.first

runSegmentChecks()
runRationalChecks()
runFrameTableChecks()
runFrameGridChecks()
runPlannerChecks()
runRetimerChecks()
runTimeMapChecks()
await runProbeChecks()
await runValidatorChecks()
await runCompositionChecks()
await runReencoderChecks()
await runExporterChecks()

Harness.finish()
