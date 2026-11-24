// The 30-second phone tremor test. On the simulator it plays a synthetic signal and says so on screen.
import SwiftUI
import TremorKit

struct PhoneTestView: View {
    let patientId: String
    let simulated: Bool
    @State private var test: PhoneTest
    @State private var run: Task<Void, Never>?

    init(api: APIClient, patientId: String) {
        self.patientId = patientId
        simulated = !PhoneMotionSource.isAvailable
        let source: any MotionSource = simulated ? SyntheticMotionSource() : PhoneMotionSource()
        _test = State(initialValue: PhoneTest(source: source, score: { try await api.postPhoneTest($0) }))
    }

    var body: some View {
        VStack(spacing: 24) {
            if simulated {
                Label("Simulated signal", systemImage: "waveform.badge.exclamationmark")
                    .font(.callout.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.orange.opacity(0.2), in: .capsule)
            }
            Spacer()
            content
            Spacer()
            Text("Tracking, not a diagnosis.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Tremor test")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(test.phase == .recording || test.phase == .scoring)
        .sensoryFeedback(trigger: test.phase) { _, new in new == .scoring ? .success : nil }
        .onChange(of: test.phase == .recording) { _, recording in
            UIApplication.shared.isIdleTimerDisabled = recording
        }
        .onDisappear {
            run?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    @ViewBuilder private var content: some View {
        switch test.phase {
        case .ready:
            VStack(spacing: 16) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Sit down and rest your forearm on your thigh or a table. Hold the phone loosely in the hand being tested and keep it there for 30 seconds.")
                    .multilineTextAlignment(.center)
                startButton("Start test")
            }
        case .recording:
            VStack(spacing: 16) {
                ZStack {
                    ProgressView(value: test.elapsed, total: PhoneTest.duration)
                        .progressViewStyle(.circular)
                        .scaleEffect(4)
                    Text(test.remaining.rounded(.up).formatted())
                        .font(.largeTitle.monospacedDigit().bold())
                        .contentTransition(.numericText(countsDown: true))
                }
                .frame(height: 160)
                Text("Keep your hand relaxed and resting.")
                if test.restarts > 0 {
                    Text("The sensor paused, so the recording started again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { run?.cancel() }
            }
        case .scoring:
            ProgressView("Scoring…")
        case let .finished(display):
            VStack(spacing: 16) {
                ResultSummary(display: display)
                startButton("Test again")
            }
        case let .failed(message):
            VStack(spacing: 16) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .multilineTextAlignment(.center)
                startButton("Try again")
            }
        }
    }

    private func startButton(_ title: LocalizedStringKey) -> some View {
        Button(title) {
            run = Task { await test.run(patientId: patientId) }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

/// A score with its likely range, or "Not enough data" with the reason. Never a zero for a refusal.
private struct ResultSummary: View {
    let display: ScoreDisplay

    var body: some View {
        switch display {
        case let .score(value, low, high):
            VStack(spacing: 8) {
                Text(value.formatted(.number.precision(.fractionLength(0))))
                    .font(.system(size: 72, weight: .bold).monospacedDigit())
                Text("Tremor score, 0 to 100")
                    .foregroundStyle(.secondary)
                if let low, let high {
                    Text("Likely between \(low.formatted(.number.precision(.fractionLength(0)))) and \(high.formatted(.number.precision(.fractionLength(0))))")
                        .font(.callout)
                }
            }
        case let .notEnoughData(reason):
            VStack(spacing: 8) {
                Text("Not enough data")
                    .font(.title2.bold())
                Text(reason)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PhoneTestView(api: APIClient(baseURL: URL(filePath: "/")), patientId: "preview")
    }
}
