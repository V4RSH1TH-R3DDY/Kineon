// Reads the watch's motion sensor at 50 Hz and cuts it into 10-second windows, all on one private serial queue,
// so the main thread wakes only when a window is finished or the progress changes.
// Acceleration is sent in g with gravity included (gravity + userAcceleration), which is what the scorer expects.
// The simulator has no motion sensor: it plays a synthetic tremor instead, and the UI must say "Simulated signal".
import CoreMotion
import Foundation
import TremorKit

final class MotionCapture: @unchecked Sendable {
    static let hz = 50.0

    /// False on the simulator.
    static var hasSensor: Bool {
        let m = CMMotionManager()
        return m.isDeviceMotionAvailable || m.isAccelerometerAvailable
    }

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "kineon.motion")
    private let opQueue = OperationQueue()
    private let manager = CMMotionManager()
    private var buffer: WindowBuffer?
    private var heartRate: Double?
    private var timer: DispatchSourceTimer?
    private var lastProgress = -1.0

    init() {
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
    }

    /// `onWindow` and `onProgress` (0...1 of the current window) are called on the private queue.
    func start(patientId: String,
               onWindow: @escaping @Sendable (MotionWindow) -> Void,
               onProgress: @escaping @Sendable (Double) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            buffer = WindowBuffer(patientId: patientId, source: .watch)
            lastProgress = -1
            let ingest: (MotionSample) -> Void = { [self] s in
                guard var b = buffer else { return }
                let w = b.append(s, heartRateBpm: heartRate)
                buffer = b
                if let w { onWindow(w) }
                let p = min(1, b.elapsed / b.seconds)
                if abs(p - lastProgress) >= 0.05 || w != nil { lastProgress = p; onProgress(w != nil ? 0 : p) }
            }
            if manager.isDeviceMotionAvailable {
                manager.deviceMotionUpdateInterval = 1 / Self.hz
                manager.startDeviceMotionUpdates(to: opQueue) { m, _ in
                    guard let m else { return }
                    let g = m.gravity, u = m.userAcceleration, r = m.rotationRate
                    ingest(MotionSample(t: m.timestamp, accel: Vec3(g.x + u.x, g.y + u.y, g.z + u.z), gyro: Vec3(r.x, r.y, r.z)))
                }
            } else if manager.isAccelerometerAvailable {
                manager.accelerometerUpdateInterval = 1 / Self.hz
                manager.startAccelerometerUpdates(to: opQueue) { d, _ in
                    guard let d else { return }
                    ingest(MotionSample(t: d.timestamp, accel: Vec3(d.acceleration.x, d.acceleration.y, d.acceleration.z)))
                }
            } else {
                startSynthetic(ingest)
            }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    func setHeartRate(_ bpm: Double?) { queue.async { [self] in heartRate = bpm } }

    private func stopOnQueue() {
        manager.stopDeviceMotionUpdates()
        manager.stopAccelerometerUpdates()
        timer?.cancel()
        timer = nil
        buffer = nil
    }

    /// Ten batches a second of a 6 Hz synthetic tremor, timed like the real sensor.
    private func startSynthetic(_ ingest: @escaping (MotionSample) -> Void) {
        let signal = SyntheticSignal.samples(seconds: 60, tremorHz: 6, tremorAmp: 0.08, seed: UInt64.random(in: 0...1000))
        let start = ProcessInfo.processInfo.systemUptime
        var i = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler {
            for _ in 0..<5 {
                ingest(MotionSample(t: start + Double(i) / Self.hz, accel: signal[i % signal.count]))
                i += 1
            }
        }
        timer = t
        t.resume()
    }
}
