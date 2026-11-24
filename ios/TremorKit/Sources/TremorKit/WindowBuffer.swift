// Collects motion samples into fixed-length windows for the backend scorer.
// The sample rate sent is measured from the timestamps, not the requested rate, because CoreMotion
// can deliver slower than asked. A gap in the stream drops the partial window rather than stitching across it.
import Foundation

public struct MotionSample: Sendable {
    /// Seconds, monotonic (CoreMotion's `timestamp`, time since boot).
    public var t: TimeInterval
    public var accel: Vec3
    public var gyro: Vec3?

    public init(t: TimeInterval, accel: Vec3, gyro: Vec3? = nil) {
        self.t = t; self.accel = accel; self.gyro = gyro
    }
}

public struct WindowBuffer: Sendable {
    public static let defaultSeconds: TimeInterval = 10
    /// The longest pause between samples before the partial window is thrown away.
    public static let maxGap: TimeInterval = 0.5

    public let patientId: String
    public let seconds: TimeInterval
    public let source: Source

    private var samples: [MotionSample] = []
    private var startedAt: Date?

    public init(patientId: String, seconds: TimeInterval = WindowBuffer.defaultSeconds, source: Source = .watch) {
        self.patientId = patientId; self.seconds = seconds; self.source = source
    }

    public var count: Int { samples.count }

    /// Seconds of signal collected so far in the current window.
    public var elapsed: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.t - first.t
    }

    /// Adds a sample. Returns a finished window once `seconds` of signal have been collected.
    /// `now` is the wall-clock time of this sample, used for `started_at`.
    public mutating func append(_ s: MotionSample, now: Date = Date(), heartRateBpm: Double? = nil) -> MotionWindow? {
        if let last = samples.last, s.t - last.t > Self.maxGap || s.t <= last.t {
            reset()
        }
        if samples.isEmpty { startedAt = now }
        samples.append(s)
        guard elapsed >= seconds else { return nil }
        let w = makeWindow(heartRateBpm: heartRateBpm)
        reset()
        return w
    }

    /// Returns whatever has been collected, even if shorter than `seconds`, and clears the buffer.
    /// Used when the phone test stops. Nil if fewer than two samples.
    public mutating func flush(heartRateBpm: Double? = nil) -> MotionWindow? {
        defer { reset() }
        return makeWindow(heartRateBpm: heartRateBpm)
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        startedAt = nil
    }

    private func makeWindow(heartRateBpm: Double?) -> MotionWindow? {
        guard samples.count >= 2, let startedAt, elapsed > 0 else { return nil }
        let rate = Double(samples.count - 1) / elapsed
        let gyro = samples.allSatisfy { $0.gyro != nil } ? samples.map { $0.gyro! } : nil
        return MotionWindow(patientId: patientId, startedAt: startedAt, sampleRateHz: rate,
                            accel: samples.map(\.accel), gyro: gyro, heartRateBpm: heartRateBpm, source: source)
    }
}
