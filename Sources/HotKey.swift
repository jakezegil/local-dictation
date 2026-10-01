import AppKit

final class HotKey {
    private let onToggle: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var chordDown = false

    init(onToggle: @escaping () -> Void) { self.onToggle = onToggle }

    func register() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event.modifierFlags)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event.modifierFlags)
            return event
        }
    }

    private func handle(_ flags: NSEvent.ModifierFlags) {
        let pressed = flags.contains(.function) && flags.contains(.control)
            && flags.intersection([.command, .option, .shift]).isEmpty
        if pressed && !chordDown { onToggle() }
        chordDown = pressed
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        chordDown = false
    }
}
