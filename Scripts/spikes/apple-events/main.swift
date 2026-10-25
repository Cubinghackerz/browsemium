import AppKit

@objc(SpikeOpenLocation)
final class SpikeOpenLocation: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let value = directParameter as? String ?? "<none>"
        let line = "open location \(value)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spike-received.txt")
        try? line.write(to: url, atomically: true, encoding: .utf8)
        return "received:" + value
    }
}

extension NSApplication {
    @objc var tabTitles: [String] { ["Example", "Second"] }
}

final class Delegate: NSObject, NSApplicationDelegate {}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
