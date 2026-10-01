import AVFoundation
import Foundation

final class AudioCapture {
    static let previewSeconds = 20
    let url: URL
    private(set) var failure: Error?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let converter: AVAudioConverter
    private var file: AVAudioFile?
    private var recentSamples: [Float] = []
    private var frames: Int64 = 0
    private var previewFrames: Int64 = 0

    init(inputFormat: AVAudioFormat, directory: URL) throws {
        url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw DictationError.recordingFailed
        }
        self.converter = converter
        converter.primeMethod = .none
        file = try Self.makeFile(at: url)
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (input, output) in zip(source, destination) {
            guard let from = input.mData, let to = output.mData else { return nil }
            memcpy(to, from, Int(input.mDataByteSize))
        }
        return copy
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let file, failure == nil else { return }
        do {
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate)) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw DictationError.recordingFailed
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                guard !supplied else { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            guard status != .error else { throw error ?? DictationError.recordingFailed as NSError }
            guard converted.frameLength > 0, let samples = converted.floatChannelData?[0] else { return }
            try file.write(from: converted)
            recentSamples.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
            let excess = recentSamples.count - 16_000 * Self.previewSeconds
            if excess > 0 { recentSamples.removeFirst(excess) }
            frames += Int64(converted.frameLength)
        } catch { failure = error }
    }

    func snapshot() throws -> URL? {
        if let failure { throw failure }
        guard file != nil, recentSamples.count >= 8_000, frames - previewFrames >= 4_000 else { return nil }
        let preview = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        do {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(recentSamples.count)),
                  let samples = buffer.floatChannelData?[0] else { throw DictationError.recordingFailed }
            buffer.frameLength = AVAudioFrameCount(recentSamples.count)
            recentSamples.withUnsafeBufferPointer { samples.update(from: $0.baseAddress!, count: $0.count) }
            let output = try Self.makeFile(at: preview)
            try output.write(from: buffer)
            previewFrames = frames
            return preview
        } catch {
            if FileManager.default.fileExists(atPath: preview.path) { try FileManager.default.removeItem(at: preview) }
            throw error
        }
    }

    func close() {
        file = nil
        recentSamples.removeAll()
    }

    private static func makeFile(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}
