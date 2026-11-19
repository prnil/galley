import AppKit

// Galley opens files named on the command line itself; stop AppKit treating flags and output paths as files.
UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])

let app = NSApplication.shared
Theme.registerFonts()
Theme.applyAppearance()
Prefs.probing = !Set(CommandLine.arguments).isDisjoint(with: ["--selftest", "--snapshot"])
let appDelegate = AppDelegate()
app.delegate = appDelegate
// The first document controller made becomes the shared one.
_ = GalleyDocumentController()

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

app.setActivationPolicy(.regular)
app.run()
