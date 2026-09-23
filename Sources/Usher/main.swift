import Foundation

// `classify` runs headless and exits; anything else launches the menubar app.
let arguments = Array(CommandLine.arguments.dropFirst())

// Headless runs must not block on a keychain access dialog nobody can click.
KeyStore.allowInteractiveKeychain = !["classify", "watch", "rename"].contains(arguments.first ?? "")

if arguments.first == "classify" {
    let status = await CLI.run(arguments: Array(arguments.dropFirst()))
    exit(status)
} else if arguments.first == "rename" {
    let status = await CLIRename.run(arguments: Array(arguments.dropFirst()))
    exit(status)
} else if arguments.first == "log" {
    // The logs are encrypted at rest. This is the one way to read them:
    // decrypted to stdout, on demand, never to a file.
    let which = arguments.dropFirst().first ?? "journal"
    let file = which == "renames" ? Paths.renames : Paths.journal
    guard let key = LogCipher.key() else {
        FileHandle.standardError.write(Data("Could not read the log key from the keychain.\n".utf8))
        exit(1)
    }
    for line in LogCipher.readLines(file, key: key) {
        FileHandle.standardOutput.write(line + Data([0x0A]))
    }
    exit(0)
} else if arguments.first == "watch" {
    let status = await CLI.watch()
    exit(status)
} else {
    UsherApp.main()
}
