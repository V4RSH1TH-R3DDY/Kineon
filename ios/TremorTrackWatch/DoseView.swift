// One-tap dose logging. The dose goes to the phone with guaranteed delivery and appears on the timeline.
import SwiftUI
import TremorKit

struct DoseView: View {
    @Environment(WatchLink.self) private var link
    @AppStorage("lastDose") private var lastDose: Double = 0
    @State private var coffee = false
    @State private var saved = false

    var body: some View {
        VStack(spacing: 10) {
            Button(action: log) {
                Image(systemName: saved ? "checkmark" : "pills.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 92, height: 92)
                    .glassEffect(.regular.tint(saved ? .green : .indigo).interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(link.patientId == nil)
            Text(saved ? "Dose logged" : "Log a dose").font(.headline)
            Toggle("Had coffee", isOn: $coffee).font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
            if lastDose > 0 {
                Text("Last: \(Date(timeIntervalSince1970: lastDose), style: .time)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .navigationTitle("Dose")
        .containerBackground(LinearGradient(colors: [.indigo.opacity(0.5), .black], startPoint: .top, endPoint: .bottom),
                             for: .tabView)
        .sensoryFeedback(.success, trigger: saved) { _, new in new }
    }

    private func log() {
        let now = Date()
        link.logDose(DoseEvent(takenAt: now, label: "Dose", tags: coffee ? [.caffeine] : []))
        lastDose = now.timeIntervalSince1970
        coffee = false
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saved = false
        }
    }
}
