import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
if let i = arguments.firstIndex(of: "--strict") {
    Harness.strict = true
    arguments.remove(at: i)
}
if arguments.first == "phase0" {
    exit(await Phase0.run(arguments: Array(arguments.dropFirst())))
}
Harness.filter = arguments.first

runSegmentChecks()
runModelChecks()
runProjectEditorChecks()
runPresentationChecks()
runRationalChecks()
runFrameTableChecks()
runFrameGridChecks()
runPlannerChecks()
runPlannerBlockerChecks()
runRetimerChecks()
runTimeMapChecks()
runExpectedPTSChecks()
await runProbeChecks()
await runProjectFileChecks()
await runAutosaveChecks()
await runProjectDocumentChecks()
await runValidatorChecks()
await runCompositionChecks()
await runReencoderChecks()
await runExporterChecks()
await runValidationCancelChecks()

Harness.finish()
