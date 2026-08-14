import CoreMedia
import Foundation
import ScreenCaptureKit

private final class SystemAudioWAVWriter: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16 = 16
    private var dataSize: UInt32 = 0
    private let writeQueue = DispatchQueue(label: "com.echopad.system-audio-writer")

    init(path: String, sampleRate: UInt32, channels: UInt16) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        writeHeader()
    }

    private func writeHeader() {
        var header = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        fileHandle.write(header)
    }

    func write(_ data: Data, pipeToStandardOutput: Bool) {
        writeQueue.sync {
            fileHandle.write(data)
            dataSize += UInt32(data.count)
            if pipeToStandardOutput { FileHandle.standardOutput.write(data) }
        }
    }

    func finalize() {
        writeQueue.sync {
            fileHandle.seek(toFileOffset: 4)
            var riffSize = (36 + dataSize).littleEndian
            fileHandle.write(Data(bytes: &riffSize, count: 4))
            fileHandle.seek(toFileOffset: 40)
            var littleEndianDataSize = dataSize.littleEndian
            fileHandle.write(Data(bytes: &littleEndianDataSize, count: 4))
            try? fileHandle.close()
        }
    }
}

private final class SystemAudioRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: SystemAudioWAVWriter?
    private let sampleRate: UInt32
    private let outputPath: String
    private let pipeMode: Bool

    init(outputPath: String, sampleRate: UInt32, pipeMode: Bool) {
        self.outputPath = outputPath
        self.sampleRate = sampleRate
        self.pipeMode = pipeMode
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "EchoPad", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nie znaleziono ekranu do przechwytywania"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(sampleRate)
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        writer = try SystemAudioWAVWriter(path: outputPath, sampleRate: sampleRate, channels: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        self.stream = stream
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        FileHandle.standardError.write(Data("System audio recording started\n".utf8))
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        writer?.finalize()
        FileHandle.standardError.write(Data("System audio recording saved\n".utf8))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer, length > 0 else { return }

        let floatCount = length / MemoryLayout<Float32>.size
        let floats = UnsafeRawPointer(dataPointer).bindMemory(to: Float32.self, capacity: floatCount)
        var pcm = Data(capacity: floatCount * MemoryLayout<Int16>.size)
        for index in 0..<floatCount {
            var sample = Int16(max(-1, min(1, floats[index])) * Float32(Int16.max))
            pcm.append(Data(bytes: &sample, count: MemoryLayout<Int16>.size))
        }
        writer?.write(pcm, pipeToStandardOutput: pipeMode)
    }
}

func runSystemAudioCaptureCommand(arguments: [String]) -> Never {
    var outputPath = "recording.wav"
    var sampleRate: UInt32 = 16_000
    var pipeMode = false
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--audio-capture", "--no-mic": break
        case "--output", "-o":
            index += 1
            if index < arguments.count { outputPath = arguments[index] }
        case "--sample-rate", "-r":
            index += 1
            if index < arguments.count { sampleRate = UInt32(arguments[index]) ?? 16_000 }
        case "--pipe": pipeMode = true
        default:
            FileHandle.standardError.write(Data("Unknown audio capture option: \(arguments[index])\n".utf8))
            exit(2)
        }
        index += 1
    }

    let recorder = SystemAudioRecorder(outputPath: outputPath, sampleRate: sampleRate, pipeMode: pipeMode)
    signal(SIGPIPE, SIG_IGN)
    let signalSources = [SIGINT, SIGTERM].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            Task {
                await recorder.stop()
                exit(0)
            }
        }
        source.resume()
        return source
    }
    withExtendedLifetime(signalSources) {
        Task {
            do {
                try await recorder.start()
            } catch {
                FileHandle.standardError.write(Data("System audio error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
    fatalError("dispatchMain returned unexpectedly")
}
