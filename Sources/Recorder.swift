import AVFoundation
import Foundation

final class Recorder {
    private let queue = DispatchQueue(label: "local-dictation.audio-capture", qos: .userInitiated, autoreleaseFrequency: .workItem)
    // A new engine is built for every recording. A long-lived AVAudioEngine keeps a stale input format after the
    // audio device changes (headphones, displays, Bluetooth), and installTap then raises an Objective-C exception.
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var capture: AudioCapture?
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalDictationRecordings", isDirectory: true)

    var isRecording: Bool { capture != nil }

    func removeAbandonedRecordings() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func start() throws {
        guard capture == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw DictationError.microphoneDenied
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let capture = try AudioCapture(directory: directory)
        do {
            try startEngine(feeding: capture)
        } catch {
            queue.sync { capture.close() }
            try? FileManager.default.removeItem(at: capture.url)
            throw error
        }
        self.capture = capture
    }

    private func startEngine(feeding capture: AudioCapture) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // The hardware-side format is the one the tap must match.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.recordingFailed }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [queue] buffer, _ in
            guard let copy = AudioCapture.copy(buffer) else { return }
            queue.async { capture.append(copy) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restartAfterConfigurationChange() }
    }

    private func stopEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let engine else { return }
        self.engine = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// The input device changed mid-recording. Keep the audio captured so far and continue on the new device.
    private func restartAfterConfigurationChange() {
        guard let capture else { return }
        stopEngine()
        do {
            try startEngine(feeding: capture)
        } catch {
            queue.async { capture.fail(error) }
        }
    }

    func snapshot() throws -> URL? {
        guard let capture else { return nil }
        return try queue.sync { try capture.snapshot() }
    }

    func stop() throws -> URL? {
        guard let capture = finishCapture() else { return nil }
        if let failure = capture.failure, capture.frameCount < 4_000 {
            try? FileManager.default.removeItem(at: capture.url)
            throw failure
        }
        return capture.url
    }

    func cancel() throws {
        guard let capture = finishCapture() else { return }
        if FileManager.default.fileExists(atPath: capture.url.path) {
            try FileManager.default.removeItem(at: capture.url)
        }
    }

    private func finishCapture() -> AudioCapture? {
        guard let capture else { return nil }
        self.capture = nil
        stopEngine()
        queue.sync { capture.close() }
        return capture
    }
}
