import AppKit
import ApplicationServices

enum Insertion {
    static func copy(_ transcript: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(transcript, forType: .string)
    }

    static var isAllowed: Bool { CGPreflightPostEventAccess() }

    static func paste(into target: NSRunningApplication?, completion: @escaping (Bool) -> Void) {
        guard isAllowed, let target, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            completion(false)
            return
        }
        target.activate(options: [.activateIgnoringOtherApps])
        attemptPaste(into: target, deadline: Date().addingTimeInterval(2), completion: completion)
    }

    private static func attemptPaste(
        into target: NSRunningApplication, deadline: Date, completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let held = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn])
            guard held.isEmpty, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                if Date() < deadline { attemptPaste(into: target, deadline: deadline, completion: completion) }
                else { completion(false) }
                return
            }
            completion(postPaste())
        }
    }

    static func postPaste() -> Bool {
        guard isAllowed, let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    static func requestPermission() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
