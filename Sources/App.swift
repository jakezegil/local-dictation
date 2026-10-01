import AppKit
import AVFoundation

final class AppController: NSObject, NSApplicationDelegate {
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private let recordingPanel = RecordingPanel()
    private var insertionTarget: NSRunningApplication?
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "Ready — press Fn-Control", action: nil, keyEquivalent: "")
    private let recordItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
    private let copyItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript), keyEquivalent: "")
    private let insertItem = NSMenuItem(title: "Automatic Insertion", action: #selector(toggleInsertion), keyEquivalent: "")
    private var processing = false
    private var lastTranscript: String?
    private var limitTimer: Timer?
    private var previewTimer: Timer?
    private var recordingID: UUID?
    private var previewInFlight = false
    private var permissionWindow: NSWindow?
    private var automaticInsertion: Bool {
        get { UserDefaults.standard.object(forKey: "automaticInsertion") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "automaticInsertion") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        do {
            try recorder.removeAbandonedRecordings()
            hotKey = HotKey { [weak self] in self?.toggleRecording() }
            hotKey?.register()
        } catch { showError(error) }
        updateStatus("Loading local model…", symbol: "waveform")
        transcriber.prepare { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.showError(error)
            case .success:
                if !self.recorder.isRecording && !self.processing {
                    self.updateStatus("Ready — press Fn-Control", symbol: "mic")
                }
            }
        }
        if !UserDefaults.standard.bool(forKey: "openedBefore") || !Insertion.isAllowed {
            UserDefaults.standard.set(true, forKey: "openedBefore")
            showPermissions()
        }
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        for item in [recordItem, copyItem, insertItem] {
            item.target = self
            menu.addItem(item)
        }
        copyItem.isEnabled = false
        insertItem.state = automaticInsertion ? .on : .off
        menu.addItem(.separator())
        let permissions = NSMenuItem(title: "Permissions…", action: #selector(showPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)
        let quit = NSMenuItem(title: "Quit Local Dictation", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        updateStatus("Ready — press Fn-Control", symbol: "mic")
    }

    private func updateStatus(_ title: String, symbol: String) {
        stateItem.title = title
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        statusItem.button?.toolTip = "Local Dictation: " + title
    }

    private func startRecording() {
        guard !processing, !recorder.isRecording else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            showPermissions()
            return
        }
        do {
            insertionTarget = NSWorkspace.shared.frontmostApplication
            try recorder.start()
            recordingID = UUID()
            previewInFlight = false
            recordingPanel.showRecording()
            recordItem.title = "Stop Recording"
            updateStatus("Recording — press Fn-Control to stop", symbol: "mic.fill")
            limitTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
                self?.stopRecording()
            }
            previewTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { [weak self] _ in
                self?.refreshPreview()
            }
        } catch { showError(error) }
    }

    private func refreshPreview() {
        guard let id = recordingID, recorder.isRecording, !previewInFlight, !processing else { return }
        do {
            guard let url = try recorder.snapshot() else { return }
            previewInFlight = true
            transcriber.transcribe(url, removingAudio: true) { [weak self] result in
                guard let self, self.recordingID == id, self.recorder.isRecording else { return }
                self.previewInFlight = false
                switch result {
                case .success(let text): self.recordingPanel.updatePreview(text)
                case .failure: self.recordingPanel.previewUnavailable()
                }
            }
        } catch { stopRecording() }
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        recordingID = nil
    }

    private func stopRecording() {
        limitTimer?.invalidate()
        limitTimer = nil
        stopPreview()
        let url: URL
        do {
            guard let recording = try recorder.stop() else { return }
            url = recording
        } catch {
            recordItem.title = "Start Recording"
            showError(error)
            return
        }
        processing = true
        recordItem.title = "Start Recording"
        recordItem.isEnabled = false
        updateStatus("Transcribing locally…", symbol: "waveform")
        recordingPanel.showProcessing()
        transcriber.transcribe(url, removingAudio: true) { [weak self] result in
            guard let self else { return }
            self.recordItem.isEnabled = true
            self.recordingPanel.close()
            switch result {
            case .failure(let error):
                self.processing = false
                self.showError(error)
            case .success(let transcript):
                guard !transcript.isEmpty else {
                    self.processing = false
                    self.updateStatus("No speech detected — press Fn-Control", symbol: "mic")
                    return
                }
                self.lastTranscript = transcript
                self.copyItem.isEnabled = true
                guard Insertion.copy(transcript) else {
                    self.processing = false
                    self.showError(NSError(domain: "LocalDictation", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "The transcript could not be copied to the clipboard."
                    ]))
                    return
                }
                guard self.automaticInsertion else {
                    self.processing = false
                    self.updateStatus("Copied — paste with ⌘V", symbol: "mic")
                    return
                }
                guard Insertion.isAllowed else {
                    self.processing = false
                    self.updateStatus("Copied — enable Accessibility to paste", symbol: "mic")
                    self.showPermissions()
                    return
                }
                Insertion.paste(into: self.insertionTarget) { pasted in
                    self.processing = false
                    self.updateStatus(pasted ? "Ready — press Fn-Control" : "Copied — paste with ⌘V", symbol: "mic")
                }
            }
        }
    }

    @objc private func toggleRecording() {
        if recorder.isRecording { stopRecording() } else { startRecording() }
    }

    @objc private func copyLastTranscript() {
        if let lastTranscript { _ = Insertion.copy(lastTranscript) }
    }

    @objc private func toggleInsertion() {
        automaticInsertion.toggle()
        insertItem.state = automaticInsertion ? .on : .off
        if automaticInsertion && !Insertion.isAllowed { showPermissions() }
    }

    @objc private func showPermissions() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 250))
        let title = NSTextField(labelWithString: "Local Dictation")
        title.font = .boldSystemFont(ofSize: 22)
        title.frame = NSRect(x: 24, y: 196, width: 390, height: 30)
        content.addSubview(title)
        let description = NSTextField(wrappingLabelWithString:
            "Press Fn-Control to start. Press it again to transcribe and paste. Enable Accessibility for the shortcut and automatic insertion. Your transcript stays on the clipboard."
        )
        description.frame = NSRect(x: 24, y: 128, width: 390, height: 58)
        content.addSubview(description)
        let microphone = NSButton(title: "Allow Microphone", target: self, action: #selector(requestMicrophone))
        microphone.frame = NSRect(x: 24, y: 84, width: 190, height: 32)
        microphone.isEnabled = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
        content.addSubview(microphone)
        let insertion = NSButton(title: "Allow Automatic Insertion", target: self, action: #selector(requestInsertion))
        insertion.frame = NSRect(x: 222, y: 84, width: 194, height: 32)
        insertion.isEnabled = !Insertion.isAllowed
        content.addSubview(insertion)
        let done = NSButton(title: "Done", target: self, action: #selector(closePermissions))
        done.bezelStyle = .rounded
        done.frame = NSRect(x: 326, y: 24, width: 90, height: 32)
        content.addSubview(done)
        if permissionWindow == nil {
            permissionWindow = NSWindow(
                contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            permissionWindow?.title = "Local Dictation"
            permissionWindow?.isReleasedWhenClosed = false
            permissionWindow?.center()
        }
        permissionWindow?.contentView = content
        NSApp.activate(ignoringOtherApps: true)
        permissionWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.showPermissions() }
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func requestInsertion() { Insertion.requestPermission() }
    @objc private func closePermissions() {
        permissionWindow?.close()
        hotKey?.register()
    }
    @objc private func quit() {
        if processing {
            updateStatus("Finish transcription before quitting", symbol: "waveform")
            return
        }
        do { try recorder.cancel() }
        catch { showError(error); return }
        stopPreview()
        limitTimer?.invalidate()
        hotKey?.stop()
        transcriber.shutdown()
        NSApp.terminate(nil)
    }

    private func showError(_ error: Error) {
        recordingPanel.close()
        updateStatus("Needs attention", symbol: "exclamationmark.circle")
        let alert = NSAlert()
        alert.messageText = "Local Dictation"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPreview()
        limitTimer?.invalidate()
        hotKey?.stop()
        transcriber.shutdown()
        try? recorder.cancel()
    }
}
