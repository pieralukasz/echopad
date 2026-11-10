import Foundation

/// Gives up waiting for work that stops making progress. Each progress report moves the
/// deadline, so a long recording that keeps advancing is never cut off.
///
/// The work runs in its own unstructured task. A task group would not do: it waits for every
/// child before returning, and a CoreML call that never returns ignores cancellation. After a
/// timeout the work is only cancelled; whatever it holds natively (a stuck model load or
/// prediction) is not freed, so callers must stop using the object it ran on.
public enum Watchdog {
    public struct TimedOut: LocalizedError, Equatable {
        public let seconds: Int
        public let stage: String

        public var errorDescription: String? {
            "\(stage) made no progress for \(seconds) s and was stopped."
        }
    }

    /// Moves the deadline of the running work.
    public final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var due: ContinuousClock.Instant
        private var budget: Duration
        private var stage: String

        init(budget: Duration, stage: String) {
            self.budget = budget
            self.stage = stage
            due = .now + budget
        }

        /// Progress was made: the work gets `budget` (or the current one) from now.
        public func advance(stage: String? = nil, budget: Duration? = nil) {
            lock.withLock {
                if let stage { self.stage = stage }
                if let budget { self.budget = budget }
                due = .now + self.budget
            }
        }

        var state: (due: ContinuousClock.Instant, budget: Duration, stage: String) {
            lock.withLock { (due, budget, stage) }
        }
    }

    /// Runs `work` until it returns or the deadline passes without progress, whichever comes first.
    public static func run<T: Sendable>(budget: Duration, stage: String,
                                        _ work: @escaping @Sendable (Progress) async throws -> T) async throws -> T {
        let progress = Progress(budget: budget, stage: stage)
        let outcome = Outcome<T>()
        return try await withCheckedThrowingContinuation { continuation in
            outcome.continuation = continuation
            let worker = Task {
                do { outcome.finish(.success(try await work(progress))) } catch { outcome.finish(.failure(error)) }
            }
            Task {
                while !outcome.isFinished {
                    let state = progress.state
                    let wait = state.due - .now
                    if wait <= .zero {
                        worker.cancel()
                        outcome.finish(.failure(TimedOut(seconds: Int(state.budget.components.seconds), stage: state.stage)))
                        return
                    }
                    try? await Task.sleep(for: min(wait, .seconds(1)))
                }
            }
        }
    }

    /// Resumes the caller exactly once: with the result, or with the timeout.
    private final class Outcome<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        var continuation: CheckedContinuation<T, Error>?

        var isFinished: Bool { lock.withLock { finished } }

        func finish(_ result: Result<T, Error>) {
            let continuation: CheckedContinuation<T, Error>? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }
    }
}

/// How long the saved transcript's steps may go without progress before EchoPad gives up.
enum TranscriptionBudget {
    /// Loading Parakeet: a cold Neural Engine compile took 12 s on an M1 Max; download
    /// progress moves the deadline, so a slow first download is not cut off.
    static let MODEL_LOAD: Duration = .seconds(180)
    /// Fixed part of each transcription step, plus a share of the audio length: a 40 s
    /// recording was saved 3 to 6 s after Stop (measured), so 0.5 s per second of audio is far
    /// above a working run and still ends a stuck one.
    static let STEP_BASE: TimeInterval = 120
    static let STEP_PER_AUDIO_SECOND: TimeInterval = 0.5

    static func step(audioSeconds: TimeInterval) -> Duration {
        .seconds(STEP_BASE + max(0, audioSeconds) * STEP_PER_AUDIO_SECOND)
    }
}
