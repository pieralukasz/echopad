import Foundation
import ScreenCaptureKit
import CoreMedia
import AVFoundation

// MARK: - WAV Writer

class WAVWriter {
    private let fileHandle: FileHandle
    private let filePath: String
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16 = 16
    private var dataSize: UInt32 = 0

    init(path: String, sampleRate: UInt32, channels: UInt16) throws {
        self.filePath = path
        self.sampleRate = sampleRate
        self.channels = channels
        FileManager.default.createFile(atPath: path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        writeHeader()
    }

    private func writeHeader() {
        var header = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }) // placeholder
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }) // placeholder

        fileHandle.write(header)
    }

    func writeSamples(_ data: Data) {
        fileHandle.write(data)
        dataSize += UInt32(data.count)
    }

    func finalize() {
        // Update RIFF chunk size
        fileHandle.seek(toFileOffset: 4)
        var riffSize = (36 + dataSize).littleEndian
        fileHandle.write(Data(bytes: &riffSize, count: 4))

        // Update data chunk size
        fileHandle.seek(toFileOffset: 40)
        var dataSizLE = dataSize.littleEndian
        fileHandle.write(Data(bytes: &dataSizLE, count: 4))

        fileHandle.closeFile()
    }
}

// MARK: - Audio Recorder

class AudioRecorder: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var writer: WAVWriter?
    private let sampleRate: UInt32
    private let outputPath: String
    private let includeMic: Bool

    init(outputPath: String, sampleRate: UInt32 = 16000, includeMic: Bool = true) {
        self.outputPath = outputPath
        self.sampleRate = sampleRate
        self.includeMic = includeMic
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            fputs("Error: No display found\n", stderr)
            exit(1)
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1
        // Minimal video — we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum

        if includeMic {
            if #available(macOS 15.0, *) {
                config.captureMicrophone = true
                config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
            } else {
                fputs("Warning: Microphone capture requires macOS 15+. Recording system audio only.\n", stderr)
            }
        }

        writer = try WAVWriter(path: outputPath, sampleRate: sampleRate, channels: 1)

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream!.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

        if includeMic {
            if #available(macOS 15.0, *) {
                try stream!.addStreamOutput(self, type: .microphone, sampleHandlerQueue: .global(qos: .userInteractive))
            }
        }

        try await stream!.startCapture()
        fputs("Recording started → \(outputPath)\n", stderr)
    }

    func stop() async {
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                fputs("Warning: Error stopping capture: \(error)\n", stderr)
            }
        }
        writer?.finalize()
        fputs("Recording saved → \(outputPath)\n", stderr)
    }

    // SCStreamOutput delegate
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        guard sampleBuffer.isValid else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard status == kCMBlockBufferNoErr, let pointer = dataPointer, length > 0 else { return }

        // Convert Float32 samples to Int16 PCM
        let floatCount = length / MemoryLayout<Float32>.size
        let floatPointer = UnsafeRawPointer(pointer).bindMemory(to: Float32.self, capacity: floatCount)

        var pcmData = Data(capacity: floatCount * MemoryLayout<Int16>.size)
        for i in 0..<floatCount {
            let sample = max(-1.0, min(1.0, floatPointer[i]))
            var int16Sample = Int16(sample * Float32(Int16.max))
            pcmData.append(Data(bytes: &int16Sample, count: 2))
        }

        writer?.writeSamples(pcmData)
    }
}

// MARK: - Main

let args = CommandLine.arguments
var outputPath = "recording.wav"
var sampleRate: UInt32 = 16000
var includeMic = true

var i = 1
while i < args.count {
    switch args[i] {
    case "--output", "-o":
        i += 1
        if i < args.count { outputPath = args[i] }
    case "--sample-rate", "-r":
        i += 1
        if i < args.count { sampleRate = UInt32(args[i]) ?? 16000 }
    case "--no-mic":
        includeMic = false
    case "--help", "-h":
        fputs("""
        Usage: audio-capture [options]
          --output, -o PATH    Output WAV file path (default: recording.wav)
          --sample-rate, -r N  Sample rate in Hz (default: 16000)
          --no-mic             Don't capture microphone, system audio only
          --help, -h           Show this help

        Send SIGINT (Ctrl+C) to stop recording.

        """, stderr)
        exit(0)
    default:
        fputs("Unknown option: \(args[i])\n", stderr)
        exit(1)
    }
    i += 1
}

let recorder = AudioRecorder(outputPath: outputPath, sampleRate: sampleRate, includeMic: includeMic)

// Handle SIGINT for clean shutdown
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigintSource.setEventHandler {
    fputs("\nStopping recording...\n", stderr)
    Task {
        await recorder.stop()
        exit(0)
    }
}
sigintSource.resume()

// Handle SIGTERM too
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
sigtermSource.setEventHandler {
    fputs("\nStopping recording...\n", stderr)
    Task {
        await recorder.stop()
        exit(0)
    }
}
sigtermSource.resume()

// Start recording
Task {
    do {
        try await recorder.start()
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

RunLoop.main.run()
