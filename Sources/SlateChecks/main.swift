import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
Harness.filter = arguments.first

runSegmentChecks()
runRationalChecks()
runFrameTableChecks()
runFrameGridChecks()
runPlannerChecks()
runRetimerChecks()
runTimeMapChecks()
await runProbeChecks()

Harness.finish()
