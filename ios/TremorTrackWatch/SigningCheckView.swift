// Step 1 screen: answers the one open question in the plan. Does HealthKit work under a free Apple ID?
// If authorisation succeeds, tracking uses HKWorkoutSession (motion with the wrist down, plus heart rate).
// If it fails, tracking falls back to WKExtendedRuntimeSession with no heart rate.
import HealthKit
import SwiftUI

struct SigningCheckView: View {
    @State private var status = "Not checked"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("TremorTrack+").font(.headline)
                Text("HealthKit: \(status)").font(.footnote)
                Button("Check HealthKit") { Task { await check() } }
            }
        }
    }

    private func check() async {
        guard HKHealthStore.isHealthDataAvailable() else { status = "not available on this device"; return }
        let store = HKHealthStore()
        do {
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [HKQuantityType(.heartRate)]
            )
            status = "authorised, so workout sessions will work"
        } catch {
            status = "failed: \(error.localizedDescription)"
        }
    }
}
