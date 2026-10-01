import AppKit
import AVFoundation

enum PreviewTest {
    static func run(sample: URL, transcriber: Transcriber) throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictationRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let input = try AVAudioFile(forReading: sample)
        let hardwareFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = AVAudioConverter(from: input.processingFormat, to: hardwareFormat)!
        converter.primeMethod = .none
        let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))!
        try input.read(into: source)
        let hardware = AVAudioPCMBuffer(pcmFormat: hardwareFormat, frameCapacity: source.frameLength * 3 + 64)!
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: hardware, error: &conversionError) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true
            state.pointee = .haveData
            return source
        }
        guard status != .error else { throw conversionError ?? DictationError.invalidAudio as NSError }
        let capture = try AudioCapture(inputFormat: hardwareFormat, directory: directory)
        var previews: [URL] = []
        defer {
            capture.close()
            for url in previews + [capture.url] { try? FileManager.default.removeItem(at: url) }
        }
        func appendSample() throws {
            var offset: AVAudioFrameCount = 0
            while offset < hardware.frameLength {
                let count = min(4096, hardware.frameLength - offset)
                let buffer = AVAudioPCMBuffer(pcmFormat: hardwareFormat, frameCapacity: count)!
                buffer.frameLength = count
                buffer.floatChannelData![0].update(from: hardware.floatChannelData![0] + Int(offset), count: Int(count))
                guard let copy = AudioCapture.copy(buffer) else { throw DictationError.recordingFailed }
                capture.append(copy)
                offset += count
            }
            if let failure = capture.failure { throw failure }
        }
        try appendSample()
        guard let first = try capture.snapshot() else { throw DictationError.transcriptionFailed }
        previews.append(first)
        var previewResult: Result<String, Error>?
        transcriber.transcribe(first, removingAudio: true) { previewResult = $0 }
        let deadline = Date().addingTimeInterval(10)
        while previewResult == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard let result = previewResult, !FileManager.default.fileExists(atPath: first.path) else {
            throw DictationError.transcriptionFailed
        }
        let transcript = try result.get()
        guard transcript.lowercased().contains("green lantern"), transcript.lowercased().contains("seven birds") else {
            throw DictationError.transcriptionFailed
        }
        for _ in 0..<3 { try appendSample() }
        guard let recent = try capture.snapshot() else { throw DictationError.transcriptionFailed }
        previews.append(recent)
        let window = try AVAudioFile(forReading: recent)
        guard window.length == Int64(16_000 * AudioCapture.previewSeconds) else { throw DictationError.invalidAudio }
        capture.close()
        let complete = try AVAudioFile(forReading: capture.url)
        guard complete.length > window.length, abs(complete.length - input.length * 4) < 256 else {
            throw DictationError.invalidAudio
        }
        if CommandLine.arguments.contains("--preview-panel") {
            let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let panel = RecordingPanel()
            panel.showRecording()
            panel.updatePreview(transcript)
            RunLoop.current.run(until: Date().addingTimeInterval(5))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else {
                panel.close()
                throw DictationError.recordingFailed
            }
            panel.close()
        }
        var checks: [String: Any] = ["live_preview_passed": true, "capture_resampling_passed": true,
                                   "preview_window_seconds": AudioCapture.previewSeconds,
                                   "complete_recording_preserved": true, "preview_audio_deleted": true]
        if CommandLine.arguments.contains("--microphone") {
            let recorder = Recorder()
            var files: [URL] = []
            defer {
                try? recorder.cancel()
                for url in files { try? FileManager.default.removeItem(at: url) }
            }
            try recorder.start()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            guard let preview = try recorder.snapshot() else { throw DictationError.recordingFailed }
            files.append(preview)
            guard let recording = try recorder.stop() else { throw DictationError.recordingFailed }
            files.append(recording)
            for url in files {
                let audio = try AVAudioFile(forReading: url)
                guard audio.length >= 8_000, audio.processingFormat.sampleRate == 16_000,
                      audio.processingFormat.channelCount == 1 else { throw DictationError.invalidAudio }
            }
            checks["microphone_capture_passed"] = true
        }
        return checks
    }
}
