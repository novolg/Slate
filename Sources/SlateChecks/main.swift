import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "phase0" {
    exit(await Phase0.run(arguments: Array(arguments.dropFirst())))
}
if let i = arguments.firstIndex(of: "--strict") {
    Harness.strict = true
    arguments.remove(at: i)
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
