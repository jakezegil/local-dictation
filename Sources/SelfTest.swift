import AppKit
import Darwin
import Foundation

enum SelfTest {
    static func run(probePath: String) throws {
        var checks: [String: Any] = [:]
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(443).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("1.1.1.1"))
        var result: Int32 = -1
        if descriptor >= 0 {
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        let networkError = errno
        if descriptor >= 0 { close(descriptor) }
        let networkDenied = result == -1 && [EPERM, EACCES].contains(networkError)
        checks["network_denied"] = networkDenied
        checks["network_errno"] = networkError
        guard networkDenied else { throw TestError.failed("Network access was not denied by the sandbox") }

        let forbiddenFile = open(probePath, O_RDONLY)
        let fileError = errno
        if forbiddenFile >= 0 { close(forbiddenFile) }
        let fileDenied = forbiddenFile == -1 && [EPERM, EACCES].contains(fileError)
        checks["unrelated_file_read_denied"] = fileDenied
        checks["file_errno"] = fileError
        guard fileDenied else { throw TestError.failed("Unrelated file access was not denied by the sandbox") }

        guard let sample = Bundle.main.url(forResource: "test-speech", withExtension: "wav") else {
            throw TestError.failed("The bundled test sample is missing")
        }
        let started = Date()
        let engine = Transcriber()
        let transcript = try engine.transcribeSynchronously(sample)
        let normalized = transcript.lowercased()
        guard normalized.contains("green lantern"), normalized.contains("seven birds") else {
            throw TestError.failed("Local transcription did not recognize the generated sample")
        }
        checks["local_transcription_passed"] = true
        checks["model"] = "Phonon 2"
        checks["transcript"] = transcript
        checks["elapsed_seconds"] = Date().timeIntervalSince(started)
        guard Insertion.copy(transcript), NSPasteboard.general.string(forType: .string) == transcript else {
            throw TestError.failed("Clipboard output did not match the generated transcript")
        }
        checks["clipboard_passed"] = true
        checks["automatic_insertion_permission"] = Insertion.isAllowed
        if CommandLine.arguments.contains("--paste") {
            let posted = Insertion.postPaste()
            checks["paste_event_posted"] = posted
            guard posted else { throw TestError.failed("Allow automatic insertion before testing paste") }
        }
        let temporaryProbe = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("private temporary file".utf8).write(to: temporaryProbe)
        try FileManager.default.removeItem(at: temporaryProbe)
        checks["private_temporary_directory_accessible"] = true
        let workerChecks = try engine.sandboxChecks(probePath: probePath)
        guard workerChecks["network_denied"] as? Bool == true,
              workerChecks["unrelated_file_read_denied"] as? Bool == true else {
            throw TestError.failed("The speech worker did not inherit the sandbox")
        }
        checks["speech_worker_sandbox"] = workerChecks
        engine.shutdown()
        let data = try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private enum TestError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): return message }
        }
    }
}
