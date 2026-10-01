import AppKit

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class RecordingPanel {
    private let panel: DictationPanel
    private let title = NSTextField(labelWithString: "Recording…")
    private let detail = NSTextField(labelWithString: "Fn-Control to stop and paste")
    private let caption = NSTextField(labelWithString: "Live preview · last 20 seconds")
    private let placeholder = NSTextField(labelWithString: "Speak to see a live preview…")
    private let preview = NSTextView()
    private let icon = NSImageView()

    init() {
        panel = DictationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 244),
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
        icon.frame = NSRect(x: 22, y: 183, width: 36, height: 36)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.frame = NSRect(x: 76, y: 203, width: 380, height: 26)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 76, y: 181, width: 380, height: 20)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: 24, y: 148, width: 432, height: 18)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 22, width: 432, height: 120))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        preview.frame = scroll.contentView.bounds
        preview.autoresizingMask = [.width]
        preview.isEditable = false
        preview.isSelectable = false
        preview.isRichText = false
        preview.drawsBackground = false
        preview.font = .systemFont(ofSize: 16)
        preview.textColor = .labelColor
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = false
        preview.textContainer?.widthTracksTextView = true
        preview.textContainerInset = NSSize(width: 0, height: 4)
        scroll.documentView = preview
        placeholder.font = .systemFont(ofSize: 16)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.frame = NSRect(x: 24, y: 111, width: 432, height: 24)
        for view in [icon, title, detail, caption, scroll, placeholder] { content.addSubview(view) }
        panel.contentView = content
    }

    func showRecording() {
        title.stringValue = "Recording…"
        detail.stringValue = "Fn-Control to stop and paste"
        caption.stringValue = "Live preview · last 20 seconds"
        placeholder.stringValue = "Speak to see a live preview…"
        placeholder.isHidden = false
        preview.string = ""
        icon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
        icon.contentTintColor = .systemRed
        show()
    }

    func updatePreview(_ text: String) {
        guard !text.isEmpty else { return }
        placeholder.isHidden = true
        caption.stringValue = "Live preview · last 20 seconds"
        preview.string = text
        preview.scrollRangeToVisible(NSRange(location: preview.string.utf16.count, length: 0))
    }

    func previewUnavailable() {
        caption.stringValue = "Preview unavailable · final transcription runs when you stop"
    }

    func showProcessing() {
        title.stringValue = "Transcribing locally…"
        detail.stringValue = "Finishing the full recording"
        caption.stringValue = "Preparing the final transcript…"
        placeholder.stringValue = "Preparing the final transcript…"
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
