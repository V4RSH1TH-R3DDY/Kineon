// The iPhone accelerometer as a MotionSource. Raw accelerometer data is in g with gravity included,
// which is what the scorer expects. No permission prompt is needed for the accelerometer.
import CoreMotion
import TremorKit

struct PhoneMotionSource: MotionSource {
    static let requestedHz = 50.0

    /// False on the simulator, which has no motion sensor.
    static var isAvailable: Bool { CMMotionManager().isAccelerometerAvailable }

    func samples() -> AsyncThrowingStream<MotionSample, Error> {
        AsyncThrowingStream { continuation in
            let sensor = Accelerometer()
            sensor.start(hz: Self.requestedHz) { result in
                switch result {
                case let .success(s): continuation.yield(s)
                case let .failure(e): continuation.finish(throwing: e)
                }
            }
            continuation.onTermination = { _ in sensor.stop() }
        }
    }
}

/// Owns one CMMotionManager for the length of a recording. CMMotionManager is not Sendable, but it is
/// only started and stopped here and its handler runs on the private queue, so sharing the reference is safe.
private final class Accelerometer: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    init() { queue.maxConcurrentOperationCount = 1 }

    func start(hz: Double, handler: @escaping @Sendable (Result<MotionSample, Error>) -> Void) {
        manager.accelerometerUpdateInterval = 1 / hz
        manager.startAccelerometerUpdates(to: queue) { data, error in
            if let error { handler(.failure(error)); return }
            guard let d = data else { return }
            let a = d.acceleration
            handler(.success(MotionSample(t: d.timestamp, accel: Vec3(a.x, a.y, a.z))))
        }
    }

    func stop() { manager.stopAccelerometerUpdates() }
}
