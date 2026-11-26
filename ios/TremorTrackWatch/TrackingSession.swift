// Keeps the watch app running, and the motion sensor on, while the wrist is down.
// First choice: an HKWorkoutSession, which also gives heart rate for Calm Mode.
// If HealthKit is not allowed (for example the signing team has no HealthKit capability, or the user said no),
// it falls back to a WKExtendedRuntimeSession (physical therapy, up to an hour, no heart rate).
// If both fail, tracking still runs while the app is on screen.
import Foundation
import HealthKit
import WatchKit

@MainActor
final class TrackingSession: NSObject {
    enum Kind: String { case workout = "Workout session", extended = "Extended session", foreground = "Screen on only" }

    private(set) var kind: Kind?
    var onHeartRate: ((Double) -> Void)?
    /// The system ended the session (time limit, another workout app, an error). The tracker stops.
    var onEnded: ((String) -> Void)?

    private let store = HKHealthStore()
    private var workout: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var runtime: WKExtendedRuntimeSession?
    private var stopping = false

    func start() async -> Kind {
        stopping = false
        if await startWorkout() { kind = .workout; return .workout }
        let r = WKExtendedRuntimeSession()
        r.delegate = self
        r.start()
        runtime = r
        kind = .extended
        return .extended
    }

    func stop() {
        stopping = true
        if let workout, let builder {
            workout.end()
            Task {
                try? await builder.endCollection(at: .now)
                // Tracking sessions are not exercise, so they are not saved to the Health app.
                builder.discardWorkout()
            }
        }
        runtime?.invalidate()
        workout = nil; builder = nil; runtime = nil; kind = nil
    }

    private func startWorkout() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [HKQuantityType(.heartRate)])
        } catch {
            return false
        }
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else { return false }
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = session.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            b.delegate = self
            session.startActivity(with: .now)
            try await b.beginCollection(at: .now)
            workout = session
            builder = b
            return true
        } catch {
            workout?.end()
            return false
        }
    }

    private func ended(_ why: String) {
        guard !stopping else { return }
        stop()
        onEnded?(why)
    }
}

extension TrackingSession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date) {
        guard to == .ended || to == .stopped else { return }
        Task { @MainActor in ended("The watch ended the tracking session.") }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in ended("Tracking stopped: \(message)") }
    }
}

extension TrackingSession: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ b: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        let hr = HKQuantityType(.heartRate)
        guard types.contains(hr),
              let q = b.statistics(for: hr)?.mostRecentQuantity() else { return }
        let bpm = q.doubleValue(for: .count().unitDivided(by: .minute()))
        Task { @MainActor in onHeartRate?(bpm) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ b: HKLiveWorkoutBuilder) {}
}

extension TrackingSession: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ s: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ s: WKExtendedRuntimeSession) {
        Task { @MainActor in WKInterfaceDevice.current().play(.notification) }
    }

    nonisolated func extendedRuntimeSession(_ s: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        let id = ObjectIdentifier(s)
        Task { @MainActor in
            guard let current = self.runtime, ObjectIdentifier(current) == id else { return }
            switch reason {
            case .none: return  // we ended it
            case .expired: ended("The one-hour session ended. Start again to keep tracking.")
            default:
                // Refused or cut short: keep tracking while the app is on screen.
                self.runtime = nil
                self.kind = .foreground
            }
        }
    }
}
