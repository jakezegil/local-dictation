import AVFoundation
import Foundation

final class Recorder {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalDictationRecordings", isDirectory: true)

    var isRecording: Bool { recorder?.isRecording == true }

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
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw DictationError.microphoneDenied
        }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.prepareToRecord(), recorder.record() else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            throw DictationError.recordingFailed
        }
        self.recorder = recorder
        fileURL = url
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        let result = fileURL
        fileURL = nil
        return result
    }

    func cancel() throws {
        if let url = stop() { try FileManager.default.removeItem(at: url) }
    }
}
