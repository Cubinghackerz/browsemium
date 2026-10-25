import BrowsemiumCore
import Foundation

// browsemium-ctl: navigate Browsemium from a script, Alfred, Raycast or a
// terminal. It builds a browsemium:// link and asks the system to open it;
// the app validates the link again before doing anything.

switch AppCommandLine.interpret(Array(CommandLine.arguments.dropFirst())) {
case .info(let text):
    print(text)
case .failure(let message, let status):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
case .send(let url):
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    do {
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus)
    } catch {
        FileHandle.standardError.write(Data("Could not ask macOS to open the link: \(error.localizedDescription)\n".utf8))
        exit(69)
    }
}
