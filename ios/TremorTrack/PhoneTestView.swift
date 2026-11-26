// The 30-second phone tremor test. On the simulator it plays a synthetic signal and says so on screen.
import SwiftUI
import TremorKit

struct PhoneTestView: View {
    let patientId: String
    let simulated: Bool
    @State private var test: PhoneTest
    @State private var run: Task<Void, Never>?

    /// `onResult` gets each score the server returns, with the window's start time.
    init(api: APIClient, patientId: String, onResult: @escaping @MainActor @Sendable (ScoreResult, Date) -> Void = { _, _ in }) {
        self.patientId = patientId
        simulated = !PhoneMotionSource.isAvailable
        let source: any MotionSource = simulated ? SyntheticMotionSource() : PhoneMotionSource()
        _test = State(initialValue: PhoneTest(source: source, score: { w in
            let r = try await api.postPhoneTest(w)
            await onResult(r, w.startedAt)
            return r
        }))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            content.frame(maxWidth: .infinity)
            Spacer()
            if simulated {
                Label("Simulated signal", systemImage: "waveform.badge.exclamationmark")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 28)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Tremor Test")
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
            VStack(spacing: 28) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.teal)
                VStack(spacing: 10) {
                    Text("Rest your arm").font(.title.weight(.bold))
                    Text("Sit down and rest your forearm on your leg or a table. Hold the phone loosely in the hand you're testing, and keep still for 30 seconds.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        case .recording:
            VStack(spacing: 28) {
                ZStack {
                    Circle().stroke(Color(.systemFill), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: test.elapsed / PhoneTest.duration)
                        .stroke(.teal, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: test.elapsed)
                    Text(test.remaining.rounded(.up).formatted())
                        .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(countsDown: true))
                }
                .frame(width: 200, height: 200)
                VStack(spacing: 6) {
                    Text("Keep your hand relaxed").font(.title3.weight(.semibold))
                    if test.restarts > 0 {
                        Text("The sensor paused, so the recording started again.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        case .scoring:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Scoring").font(.headline).foregroundStyle(.secondary)
            }
        case let .finished(display):
            VStack(spacing: 20) {
                ResultSummary(display: display)
                Disclaimer()
            }
        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Couldn't finish the test").font(.title3.weight(.semibold))
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        Group {
            switch test.phase {
            case .ready: primary("Start Test")
            case .recording: Button("Cancel", role: .cancel) { run?.cancel() }.buttonStyle(.glass).controlSize(.large)
            case .scoring: EmptyView()
            case .finished: primary("Test Again")
            case .failed: primary("Try Again")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private func primary(_ title: LocalizedStringKey) -> some View {
        Button {
            run = Task { await test.run(patientId: patientId) }
        } label: {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
}

#Preview {
    NavigationStack {
        PhoneTestView(api: APIClient(baseURL: URL(filePath: "/")), patientId: "preview")
    }
}
