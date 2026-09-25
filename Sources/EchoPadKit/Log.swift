import os

/// Unified logging. Read with: log stream --predicate 'subsystem == "io.github.pieralukasz.echopad"'
enum Log {
    static let recording = Logger(subsystem: "io.github.pieralukasz.echopad", category: "recording")
    static let transcription = Logger(subsystem: "io.github.pieralukasz.echopad", category: "transcription")
}
