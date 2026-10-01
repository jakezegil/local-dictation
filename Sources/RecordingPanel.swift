import AppKit

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class RecordingPanel {
    private let panel: DictationPanel
    private let title = NSTextField(labelWithString: "Recording…")
    private let detail = NSTextField(labelWithString: "Press Fn-Control again to stop")
    private let icon = NSImageView()

    init() {
        panel = DictationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 104),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        let content = NSVisualEffectView(frame: panel.contentView!.bounds)
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.masksToBounds = true
        icon.frame = NSRect(x: 22, y: 34, width: 36, height: 36)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.frame = NSRect(x: 76, y: 53, width: 264, height: 26)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 76, y: 28, width: 264, height: 20)
        for view in [icon, title, detail] { content.addSubview(view) }
        panel.contentView = content
    }

    func showRecording() {
        title.stringValue = "Recording…"
        detail.stringValue = "Press Fn-Control again to stop"
        icon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
        icon.contentTintColor = .systemRed
        show()
    }

    func showProcessing() {
        title.stringValue = "Transcribing locally…"
        detail.stringValue = "Phonon 2 · audio stays on this Mac"
        icon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcribing")
        icon.contentTintColor = .labelColor
        show()
    }

    private func show() {
        if !panel.isVisible, let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 64))
        }
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}
