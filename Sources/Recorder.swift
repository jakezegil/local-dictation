import AVFoundation
import Foundation

final class Recorder {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "local-dictation.audio-capture", qos: .userInitiated, autoreleaseFrequency: .workItem)
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
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.recordingFailed }
        let capture = try AudioCapture(inputFormat: format, directory: directory)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [queue] buffer, _ in
            guard let copy = AudioCapture.copy(buffer) else { return }
            queue.async { capture.append(copy) }
        }
        do {
            engine.prepare()
            try engine.start()
            self.capture = capture
        } catch {
            engine.stop()
            input.removeTap(onBus: 0)
            queue.sync { capture.close() }
            try FileManager.default.removeItem(at: capture.url)
            throw error
        }
    }

    func snapshot() throws -> URL? {
        guard let capture else { return nil }
        return try queue.sync { try capture.snapshot() }
    }

    func stop() throws -> URL? {
        guard let capture = finishCapture() else { return nil }
        if let failure = capture.failure {
            try FileManager.default.removeItem(at: capture.url)
            throw failure
        }
        return capture.url
    }

    func cancel() throws {
        if let capture = finishCapture() { try FileManager.default.removeItem(at: capture.url) }
    }

    private func finishCapture() -> AudioCapture? {
        guard let capture else { return nil }
        self.capture = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        queue.sync { capture.close() }
        return capture
    }
}
