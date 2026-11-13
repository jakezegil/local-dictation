import AVFoundation
import Foundation

enum DictationError: LocalizedError {
    case unavailableModel, invalidAudio, transcriptionFailed, microphoneDenied, recordingFailed

    var errorDescription: String? {
        switch self {
        case .unavailableModel: return "The bundled Phonon 2 speech engine could not be loaded."
        case .invalidAudio: return "The recording could not be read as mono 16 kHz audio."
        case .transcriptionFailed: return "The local speech engine could not transcribe this recording."
        case .microphoneDenied: return "Allow microphone access in System Settings to record your voice."
        case .recordingFailed: return "The microphone could not start recording."
        }
    }
}

final class Transcriber {
    /// Recordings stop at ten minutes; allow a few seconds of slack for the stop to land.
    static let maximumSeconds = 610
    private let queue = DispatchQueue(label: "local-dictation.transcription", qos: .userInitiated)
    private var worker: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private var stopping = false
    private var lastRestart = Date.distantPast

    deinit { closeWorker() }

    func prepare(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result { try self.startWorker() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Pages model weights back into memory (macOS swaps them out while idle) while the user is still speaking.
    func warm() {
        queue.async { _ = try? self.request(["command": "warm"]) }
    }

    func transcribe(_ url: URL, removingAudio: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Transcribing dictation")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var result = Result { try self.transcribeSynchronously(url) }
            if removingAudio, FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch { result = .failure(error) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func startWorker() throws {
        if worker?.isRunning == true { return }
        closeWorker()
        stopping = false
        guard let resources = Bundle.main.resourceURL else { throw DictationError.unavailableModel }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("Python/bin/python3.12")
        process.arguments = ["-I", "-B", resources.appendingPathComponent("PhononRuntime/worker.py").path]
        var environment = [
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PYTHONDONTWRITEBYTECODE": "1",
            "OPENBLAS_NUM_THREADS": "1",
            "VECLIB_MAXIMUM_THREADS": "4"
        ]
        // Decoded weights are cached in the app's sandbox container so later launches skip decoding.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            environment["LOCAL_DICTATION_CACHE"] = caches.appendingPathComponent("PhononWeights", isDirectory: true).path
        }
        process.environment = environment
        process.qualityOfService = .userInitiated
        process.currentDirectoryURL = resources
        // If the worker dies while idle, restart it right away so the next dictation does not wait for a load.
        process.terminationHandler = { [weak self] ended in
            guard let self else { return }
            self.queue.async {
                guard self.worker === ended, !self.stopping else { return }
                self.closeWorker()
                // A worker that keeps crashing is restarted on the next request instead of in a loop.
                guard Date().timeIntervalSince(self.lastRestart) > 30 else { return }
                self.lastRestart = Date()
                try? self.startWorker()
            }
        }
        let writePipe = Pipe(), readPipe = Pipe()
        process.standardInput = writePipe
        process.standardOutput = readPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        worker = process
        input = writePipe.fileHandleForWriting
        output = readPipe.fileHandleForReading
        guard try readResponse()["ready"] as? Bool == true else {
            closeWorker()
            throw DictationError.unavailableModel
        }
    }

    private func readResponse() throws -> [String: Any] {
        while pending.firstIndex(of: 10) == nil {
            guard let output else { throw DictationError.transcriptionFailed }
            let data = output.availableData
            guard !data.isEmpty, pending.count + data.count <= 1_000_000 else {
                closeWorker()
                throw DictationError.transcriptionFailed
            }
            pending.append(data)
        }
        let end = pending.firstIndex(of: 10)!
        let line = pending[..<end]
        pending.removeSubrange(...end)
        guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              response["error"] == nil else { throw DictationError.transcriptionFailed }
        return response
    }

    private func request(_ values: [String: String]) throws -> [String: Any] {
        try startWorker()
        var data = try JSONSerialization.data(withJSONObject: values)
        data.append(10)
        guard let input else { throw DictationError.transcriptionFailed }
        try input.write(contentsOf: data)
        return try readResponse()
    }

    func transcribeSynchronously(_ url: URL) throws -> String {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length >= 0, file.length <= Int64(16_000 * Self.maximumSeconds) else { throw DictationError.invalidAudio }
        guard file.length >= 4_000 else { return "" }
        guard let text = try request(["audio": url.path])["text"] as? String else {
            throw DictationError.transcriptionFailed
        }
        return text
    }

    func sandboxChecks(probePath: String) throws -> [String: Any] {
        try request(["command": "sandbox-check", "probe": probePath])
    }

    func shutdown() {
        queue.sync {
            stopping = true
            closeWorker()
        }
    }

    private func closeWorker() {
        let ending = worker
        worker = nil
        ending?.terminationHandler = nil
        try? input?.close()
        try? output?.close()
        if ending?.isRunning == true { ending?.terminate() }
        input = nil
        output = nil
        pending.removeAll()
    }
}
