// Calm Mode on the wrist: haptic breathing, one tap to breathe in, two taps to breathe out. One minute.
// Works without the phone or the server. Not a treatment; it helps some people settle when tremor rises with stress.
import SwiftUI
import WatchKit

struct CalmView: View {
    private static let inhale = 4.0, exhale = 6.0, cycles = 6

    @State private var running: Task<Void, Never>?
    @State private var breathingIn = false
    @State private var cycle = 0

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.clear).glassEffect(.regular, in: .circle)
                Circle().fill(.purple.gradient.opacity(0.8))
                    .scaleEffect(breathingIn ? 1 : 0.45)
                    .animation(.easeInOut(duration: breathingIn ? Self.inhale : Self.exhale), value: breathingIn)
                Text(running == nil ? "Calm" : (breathingIn ? "In" : "Out"))
                    .font(.headline)
            }
            .frame(width: 100, height: 100)
            if running == nil {
                Text("Rest your arm. Feel one tap: breathe in. Two taps: breathe out.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Start, 1 minute") { start() }.tint(.purple).buttonStyle(.glassProminent)
            } else {
                Text("Breath \(cycle) of \(Self.cycles)").font(.caption2).foregroundStyle(.secondary)
                Button("Stop", role: .cancel) { running?.cancel() }.buttonStyle(.glass)
            }
        }
        .padding(.horizontal)
        .navigationTitle("Calm")
        .containerBackground(LinearGradient(colors: [.purple.opacity(0.5), .black], startPoint: .top, endPoint: .bottom),
                             for: .tabView)
        .onDisappear { running?.cancel() }
    }

    private func start() {
        running = Task {
            let device = WKInterfaceDevice.current()
            for i in 1...Self.cycles {
                cycle = i
                breathingIn = true
                device.play(.directionUp)
                guard (try? await Task.sleep(for: .seconds(Self.inhale))) != nil else { break }
                breathingIn = false
                device.play(.directionDown)
                try? await Task.sleep(for: .milliseconds(300))
                device.play(.directionDown)
                guard (try? await Task.sleep(for: .seconds(Self.exhale - 0.3))) != nil else { break }
            }
            breathingIn = false
            running = nil
            if !Task.isCancelled { device.play(.success) }
        }
    }
}
