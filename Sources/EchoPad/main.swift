import AppKit
import EchoPadKit

// With a command, run the CLI and exit: no window, no speech models.
let arguments = Array(CommandLine.arguments.dropFirst())
if EchoPadCLI.isCLIInvocation(arguments) {
    exit(EchoPadCLI.run(arguments))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
