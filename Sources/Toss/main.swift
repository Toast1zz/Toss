import AppKit

// `Toss --import-credentials <file>` stores TELEGRAM_API_ID / TELEGRAM_API_HASH
// from an env-style file in Toss's Keychain items and exits. Used once by
// scripts/import-credentials.sh; values are never printed.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--import-credentials") {
    exit(CredentialImport.run(path: arguments.indices.contains(flag + 1) ? arguments[flag + 1] : nil))
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
