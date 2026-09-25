import AVFoundation
import Foundation

/// Converts any audio or video file AVFoundation can read into a 16 kHz mono WAV.
enum AudioConverter {
    enum Failure: LocalizedError {
        case noAudio(String)

        var errorDescription: String? {
            switch self {
            case .noAudio(let name): return "\(name) has no audio track EchoPad can read."
            }
        }
    }

    static func convertToWAV(_ source: URL, to target: URL) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw Failure.noAudio(source.lastPathComponent)
        }
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: target, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let converter = AVAudioConverter(from: input.processingFormat, to: outputFormat) else {
            throw Failure.noAudio(source.lastPathComponent)
        }
        let chunk: AVAudioFrameCount = 32_768
        let ratio = outputFormat.sampleRate / input.processingFormat.sampleRate
        var finished = false
        while !finished {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                   frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 1024)
            else { break }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk),
                      (try? input.read(into: inBuffer, frameCount: chunk)) != nil, inBuffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError { throw conversionError }
            if outBuffer.frameLength > 0 { try output.write(from: outBuffer) }
            if status == .endOfStream || status == .error { finished = true }
        }
    }

    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
