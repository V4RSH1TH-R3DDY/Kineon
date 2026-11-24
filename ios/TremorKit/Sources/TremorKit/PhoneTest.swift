// The 30-second phone tremor test: record one window from a motion source, then score it once.
// Sensor-agnostic so it runs under `swift test`; the CoreMotion source lives in the iPhone app.
import Foundation
import Observation

/// A stream of motion samples. Ending the stream (or cancelling the consumer) must stop the sensor.
public protocol MotionSource: Sendable {
    func samples() -> AsyncThrowingStream<MotionSample, Error>
}

@MainActor @Observable
public final class PhoneTest {
    public nonisolated static let duration: TimeInterval = 30

    public enum Phase: Equatable, Sendable {
        case ready
        case recording
        case scoring
        case finished(ScoreDisplay)
        /// The test could not produce a result, e.g. the server was unreachable. Not a refusal by the scorer.
        case failed(String)
    }

    public private(set) var phase: Phase = .ready
    /// Seconds of signal recorded so far. Updated about ten times a second.
    public private(set) var elapsed: TimeInterval = 0
    /// How many times a sensor pause threw away the recording and started it again.
    public private(set) var restarts = 0

    private let source: any MotionSource
    private let score: @Sendable (MotionWindow) async throws -> ScoreResult

    public init(source: any MotionSource, score: @escaping @Sendable (MotionWindow) async throws -> ScoreResult) {
        self.source = source
        self.score = score
    }

    public var remaining: TimeInterval { max(0, Self.duration - elapsed) }

    /// Records and scores one test. Cancel the calling task to abandon it; nothing is sent and the phase returns to `.ready`.
    public func run(patientId: String) async {
        var buffer = WindowBuffer(patientId: patientId, seconds: Self.duration, source: .phone)
        var window: MotionWindow?
        phase = .recording
        elapsed = 0
        restarts = 0

        do {
            for try await s in source.samples() {
                let before = buffer.count
                if let w = buffer.append(s) { window = w; break }
                // WindowBuffer starts again from this sample after a gap.
                if before > 1 && buffer.count == 1 { restarts += 1 }
                if abs(buffer.elapsed - elapsed) >= 0.1 || buffer.count == 1 { elapsed = buffer.elapsed }
            }
        } catch {
            phase = Task.isCancelled ? .ready : .failed("The motion sensor stopped: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled { phase = .ready; return }

        // The source ended before 30 seconds: score what there is. The server refuses it if it is too short.
        guard let w = window ?? buffer.flush() else {
            phase = .failed("The motion sensor sent no readings.")
            return
        }
        elapsed = min(Self.duration, Double(w.accel.count - 1) / w.sampleRateHz)
        phase = .scoring
        do {
            let r = try await score(w)
            phase = Task.isCancelled ? .ready : .finished(ScoreDisplay(r, source: .phone))
        } catch {
            phase = Task.isCancelled ? .ready : .failed("Could not reach the server: \(error.localizedDescription)")
        }
    }

    public func reset() {
        phase = .ready
        elapsed = 0
        restarts = 0
    }
}

/// Plays a synthetic signal at real-time pace, for the simulator, which has no motion sensor.
/// Anything recorded from it must be labelled "Simulated signal" on screen.
public struct SyntheticMotionSource: MotionSource {
    public var tremorHz: Double?
    public var tremorAmp: Double
    /// Seconds between yielded batches. Zero plays the whole signal at once, for tests.
    public var pace: TimeInterval

    public init(tremorHz: Double? = 6, tremorAmp: Double = 0.1, pace: TimeInterval = 0.1) {
        self.tremorHz = tremorHz; self.tremorAmp = tremorAmp; self.pace = pace
    }

    public func samples() -> AsyncThrowingStream<MotionSample, Error> {
        let accel = SyntheticSignal.samples(seconds: PhoneTest.duration + 1, tremorHz: tremorHz, tremorAmp: tremorAmp)
        let rate = SyntheticSignal.sampleRate
        let batch = max(1, Int(pace * rate))
        let pace = pace
        return AsyncThrowingStream { continuation in
            let task = Task {
                for (i, a) in accel.enumerated() {
                    if Task.isCancelled { break }
                    continuation.yield(MotionSample(t: Double(i) / rate, accel: a))
                    if pace > 0, i % batch == batch - 1 { try? await Task.sleep(for: .seconds(pace)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
