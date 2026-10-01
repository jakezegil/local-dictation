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
    private let queue = DispatchQueue(label: "local-dictation.transcription", qos: .userInitiated)
    private var worker: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()

    deinit { closeWorker() }

    func prepare(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result { try self.startWorker() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func transcribe(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let result = Result { try self.transcribeSynchronously(url) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func startWorker() throws {
        if worker?.isRunning == true { return }
        closeWorker()
        guard let resources = Bundle.main.resourceURL else { throw DictationError.unavailableModel }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("Python/bin/python3.12")
        process.arguments = ["-I", "-B", resources.appendingPathComponent("PhononRuntime/worker.py").path]
        process.environment = [
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PYTHONDONTWRITEBYTECODE": "1",
            "OPENBLAS_NUM_THREADS": "1",
            "VECLIB_MAXIMUM_THREADS": "4"
        ]
        process.currentDirectoryURL = resources
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
              file.length >= 0, file.length <= 16_000 * 600 else { throw DictationError.invalidAudio }
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
        queue.sync { closeWorker() }
    }

    private func closeWorker() {
        try? input?.close()
        try? output?.close()
        if worker?.isRunning == true { worker?.terminate() }
        worker = nil
        input = nil
        output = nil
        pending.removeAll()
    }
}
