// The main watch screen: the latest score (or why there isn't one), Start/Stop, all-day recording,
// and whether readings reach the phone. Liquid Glass controls over a soft teal background.
import SwiftUI
import TremorKit

struct LiveView: View {
    @Binding var page: TremorTrackWatchApp.Page
    @Environment(WatchLink.self) private var link
    @Environment(WatchTracker.self) private var tracker

    var body: some View {
        Group {
            if link.patientId == nil {
                SetupNeeded()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        if link.higherThanUsual { higherBanner }
                        ScoreRing(display: display, progress: tracker.isTracking ? tracker.progress : nil)
                            .frame(width: 116, height: 116)
                            .padding(.top, 4)
                        caption
                        trackButton
                        allDayToggle
                        footer
                    }
                }
            }
        }
        .navigationTitle("Kineon")
        .containerBackground(LinearGradient(colors: [.teal.opacity(0.55), .black], startPoint: .top, endPoint: .bottom),
                             for: .tabView)
        .onAppear { link.refreshWaiting() }
    }

    private var display: ScoreDisplay? { link.context.latest.map { ScoreDisplay($0, source: .watch) } }

    private var higherBanner: some View {
        Button {
            link.higherThanUsual = false
            page = .calm
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label("Higher than usual", systemImage: "waveform.path.ecg").font(.footnote.bold())
                Text("Rest your arm. Try Calm?").font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glassProminent)
        .tint(.orange)
    }

    @ViewBuilder private var caption: some View {
        switch (display, tracker.state) {
        case let (.notEnoughData(reason)?, _):
            Text(reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case let (.score(v, low?, high?)?, _):
            VStack(spacing: 1) {
                if let cmp = UsualComparison(score: v, baseline: link.context.usual) {
                    Text(cmp.text).font(.footnote.bold()).foregroundStyle(cmp == .higher ? .orange : .primary)
                }
                Text("Likely \(Int(low.rounded()))–\(Int(high.rounded()))").font(.caption2).foregroundStyle(.secondary)
                if let at = link.context.latestAt {
                    Text("\(at, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case let (_, .stopped(why)):
            Text(why).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
        case (_, .tracking):
            Text("First reading in about 10 seconds. Keep your arm resting.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        default:
            Text("Start a live session, or turn on all-day recording.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var trackButton: some View {
        Button {
            if tracker.isTracking { tracker.stop() } else { Task { await tracker.start() } }
        } label: {
            Label(tracker.isTracking ? "Stop live" : "Start live",
                  systemImage: tracker.isTracking ? "stop.fill" : "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(tracker.isTracking ? .red : .teal)
        .disabled(tracker.state == .starting)
    }

    @ViewBuilder private var allDayToggle: some View {
        if AllDayRecorder.isAvailable || tracker.simulated {
            Toggle(isOn: Binding(get: { tracker.allDayOn }, set: { tracker.setAllDay($0) })) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("All day").font(.footnote.bold())
                    Text(tracker.collecting ? "Collecting…" : "1 reading a minute, low battery use")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .disabled(!AllDayRecorder.isAvailable)
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            if tracker.simulated {
                Label("Simulated signal", systemImage: "waveform.badge.exclamationmark")
                    .font(.caption2.bold()).foregroundStyle(.orange)
            }
            HStack(spacing: 4) {
                Circle().fill(link.phoneReachable ? .green : .secondary).frame(width: 6, height: 6)
                Text(link.phoneReachable ? "iPhone connected" : "iPhone away, readings saved")
            }
            .font(.caption2).foregroundStyle(.secondary)
            if link.waiting > 0 {
                Text("\(link.waiting) waiting to send").font(.caption2).foregroundStyle(.secondary)
            }
            if let bpm = tracker.heartRate {
                Label("\(Int(bpm)) bpm", systemImage: "heart.fill").font(.caption2).foregroundStyle(.pink)
            }
            if tracker.sessionKind == .foreground {
                Text("Keep the app open: background tracking isn't available.")
                    .font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
    }
}

/// Score 0–100 as an arc with its likely range behind it, on a glass disc. While measuring, a thin outer ring
/// fills over 10 seconds.
struct ScoreRing: View {
    let display: ScoreDisplay?
    let progress: Double?

    var body: some View {
        ZStack {
            Circle().fill(.clear).glassEffect(.regular, in: .circle)
            Circle().inset(by: 9).stroke(.white.opacity(0.12), lineWidth: 9)
            if case let .score(v, low, high) = display {
                if let low, let high {
                    Circle().inset(by: 9).trim(from: low / 100, to: high / 100)
                        .stroke(.teal.opacity(0.4), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Circle().inset(by: 9).trim(from: 0, to: max(0.01, v / 100))
                    .stroke(AngularGradient(colors: [.mint, .teal, .cyan], center: .center),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let progress {
                Circle().inset(by: 2).trim(from: 0, to: progress)
                    .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            }
            VStack(spacing: 0) {
                switch display {
                case let .score(v, _, _)?:
                    Text("\(Int(v.rounded()))").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("tremor").font(.caption2).foregroundStyle(.secondary)
                case .notEnoughData?:
                    Image(systemName: "exclamationmark.circle").font(.title2).foregroundStyle(.orange)
                    Text("Not enough\ndata").font(.caption2).multilineTextAlignment(.center)
                case nil:
                    Image(systemName: "waveform.path").font(.title2).foregroundStyle(.teal)
                    Text("No reading").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .animation(.smooth, value: display)
    }
}

private struct SetupNeeded: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward").font(.title).foregroundStyle(.teal)
                .frame(width: 56, height: 56).glassEffect(.regular, in: .circle)
            Text("Finish setup on your iPhone").font(.headline).multilineTextAlignment(.center)
            Text("Open Kineon on your iPhone and enter your patient ID. This watch picks it up automatically.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}
