import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
Harness.filter = arguments.first

runSegmentChecks()

Harness.finish()
