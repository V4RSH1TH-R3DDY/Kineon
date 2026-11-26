// Live tremor from the iPhone accelerometer: a scrolling waveform, frequency and intensity once a second,
// and every 10 seconds of signal posted to the server as a phone window, so live readings join the history.
// On the simulator a synthetic signal is used and labelled as such.
import Foundation
import Observation
import TremorKit
import UIKit

@MainActor @Observable
final class LiveTremor {
    nonisolated static let rate = 50.0
    nonisolated static let traceSeconds = 10.0
    /// Recording stops on its own after this long, to bound memory and battery.
    nonisolated static let maxSeconds = 15.0 * 60
    /// Below this RMS (milli-g) the hand is effectively still and no frequency is shown.
    /// shortcut: chosen from typical phone sensor noise (1–3 mg); not tuned on patients.
    nonisolated static let stillMg = 4.0

    enum State: Equatable { case idle, running, stopped }

    struct WindowScore: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let result: ScoreResult?
        /// Saved on the phone because the server couldn't be reached; it uploads later.
        let queued: Bool
    }

    struct Session: Equatable {
        let start: Date
        var end: Date?
        var scores: [WindowScore] = []
        /// High-passed acceleration magnitude in milli-g at 50 Hz. Filled when the recording stops.
        var signal: [Double] = []
        var frequencies: [Double] = []
        var intensities: [Double] = []

        var duration: TimeInterval { (end ?? .now).timeIntervalSince(start) }
        var medianFrequency: Double? { frequencies.median }
        var medianIntensity: Double? { intensities.median }
    }

    let simulated = !PhoneMotionSource.isAvailable

    private(set) var state: State = .idle
    /// The last 10 seconds of signal, milli-g, for the waveform.
    private(set) var trace: [Double] = []
    private(set) var frequencyHz: Double?
    private(set) var intensityMg: Double?
    private(set) var session: Session?

    /// Posts a finished window. Returns the score (nil if refused by the server or queued) and whether it was queued.
    @ObservationIgnored var onWindow: (@MainActor (MotionWindow) async -> (ScoreResult?, Bool))?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var filter = HighPass()
    @ObservationIgnored private var recent: [Double] = []
    @ObservationIgnored private var signal: [Double] = []
    @ObservationIgnored private var frequencies: [Double] = []
    @ObservationIgnored private var intensities: [Double] = []
    @ObservationIgnored private var buffer: WindowBuffer?
    @ObservationIgnored private var count = 0

    func start(patientId: String) {
        guard state != .running else { return }
        let source: any MotionSource = simulated ? LiveSyntheticSource() : PhoneMotionSource()
        filter = HighPass(); recent = []; signal = []; frequencies = []; intensities = []; count = 0
        trace = []; frequencyHz = nil; intensityMg = nil
        buffer = WindowBuffer(patientId: patientId, seconds: WindowBuffer.defaultSeconds, source: .phone)
        session = Session(start: .now)
        state = .running
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            do {
                for try await s in source.samples() {
                    if Task.isCancelled { break }
                    consume(s)
                }
            } catch {}
            finish()
        }
    }

    func stop() { task?.cancel() }

    /// The recording so far, including its signal, for export.
    func snapshot() -> Session? {
        guard var s = session else { return nil }
        if state == .running { s.signal = signal; s.frequencies = frequencies; s.intensities = intensities }
        return s
    }

    private func consume(_ s: MotionSample) {
        let a = s.accel
        let v = filter.next((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()) * 1000
        signal.append(v)
        recent.append(v)
        let keep = Int(Self.traceSeconds * Self.rate)
        if recent.count > keep { recent.removeFirst(recent.count - keep) }
        count += 1
        if count % 4 == 0 { trace = recent }                    // about 12 updates a second
        if count % Int(Self.rate) == 0 { updateMetrics() }    // once a second
        if let w = buffer?.append(s, now: .now) { send(w) }
        if Double(count) / Self.rate >= Self.maxSeconds { task?.cancel() }
    }

    private func updateMetrics() {
        let n = 256
        guard recent.count >= n else { return }
        let x = Array(recent.suffix(n))
        let mean = x.reduce(0, +) / Double(n)
        let rms = (x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)).squareRoot()
        intensityMg = rms
        guard rms >= Self.stillMg else { frequencyHz = nil; return }
        frequencyHz = Self.dominantFrequency(x.map { $0 - mean }, rate: Self.rate)
        intensities.append(rms)
        if let f = frequencyHz { frequencies.append(f) }
    }

    private func send(_ w: MotionWindow) {
        guard let onWindow else { return }
        Task {
            let (r, queued) = await onWindow(w)
            session?.scores.append(WindowScore(at: w.startedAt, result: r, queued: queued))
        }
    }

    private func finish() {
        // A last partial window is sent only if it's long enough for the scorer (5 s).
        if var b = buffer, b.elapsed >= 5, let w = b.flush() { send(w) }
        buffer = nil
        session?.end = .now
        session?.signal = signal
        session?.frequencies = frequencies
        session?.intensities = intensities
        state = .stopped
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// The strongest frequency between 2.5 and 12.5 Hz, by a direct Fourier sum at 0.25 Hz steps.
    nonisolated static func dominantFrequency(_ x: [Double], rate: Double) -> Double? {
        var best: (f: Double, p: Double)?
        for f in stride(from: 2.5, through: 12.5, by: 0.25) {
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * f / rate
            for (i, v) in x.enumerated() { re += v * cos(w * Double(i)); im += v * sin(w * Double(i)) }
            let p = re * re + im * im
            if p > (best?.p ?? 0) { best = (f, p) }
        }
        return best?.f
    }
}

/// A one-pole high-pass at about 1 Hz: removes gravity and slow arm movement, keeps tremor (3–12 Hz).
struct HighPass {
    private let alpha = 0.888
    private var lastX: Double?
    private var lastY = 0.0

    mutating func next(_ x: Double) -> Double {
        defer { lastX = x }
        guard let px = lastX else { return 0 }
        lastY = alpha * (lastY + x - px)
        return lastY
    }
}

/// A continuous synthetic tremor for the simulator: about 5 Hz, waxing and waning, with sensor noise.
struct LiveSyntheticSource: MotionSource {
    func samples() -> AsyncThrowingStream<MotionSample, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var i = 0
                let rate = LiveTremor.rate
                while !Task.isCancelled {
                    for _ in 0..<5 {
                        let t = Double(i) / rate
                        let amp = 0.035 + 0.025 * sin(2 * .pi * t / 9)
                        let wobble = amp * sin(2 * .pi * 5.2 * t)
                        let noise = Double.random(in: -0.003...0.003)
                        continuation.yield(MotionSample(t: t, accel: Vec3(wobble * 0.6 + noise, wobble * 0.3, 1 + wobble * 0.7 + noise)))
                        i += 1
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Array where Element == Double {
    var median: Double? {
        guard !isEmpty else { return nil }
        let s = sorted()
        return count % 2 == 1 ? s[count / 2] : (s[count / 2 - 1] + s[count / 2]) / 2
    }
}
