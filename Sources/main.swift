import AppKit
import Foundation

if let position = CommandLine.arguments.firstIndex(of: "--self-test") {
    do {
        guard CommandLine.arguments.count > position + 1 else {
            throw NSError(domain: "LocalDictation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Provide the harmless sandbox probe file path."
            ])
        }
        try SelfTest.run(probePath: CommandLine.arguments[position + 1])
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data(("Self-test failed: " + error.localizedDescription + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.run()
