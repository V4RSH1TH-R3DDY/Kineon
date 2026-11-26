import SwiftUI

@main
struct TremorTrackApp: App {
    @State private var model = AppModel()

    init() { Alerts.shared.install() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.teal)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    /// Debug builds can open a tab with the launch argument `-uiTab N` (used for screenshots).
    @State private var tab = RootView.launchTab

    var body: some View {
        Group {
            if model.account == nil {
                LoginView()
            } else if model.isSetUp {
                TabView(selection: $tab) {
                    Tab("Summary", systemImage: "heart.text.square", value: 0) { TodayView() }
                    Tab("Tremor", systemImage: "waveform.path", value: 1) { HistoryView() }
                    Tab("Account", systemImage: "person.crop.circle", value: 2) { AccountView() }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
            } else {
                OnboardingView()
            }
        }
        .animation(.default, value: model.isSetUp)
        .animation(.default, value: model.account == nil)
        // Retry queued readings while the app is open.
        .task(id: phase) {
            guard phase == .active, model.isSetUp, model.account != nil else { return }
            await model.refresh()
            while !Task.isCancelled && model.isSetUp && model.account != nil {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard model.isSetUp, model.account != nil else { return }
                await model.sendPending()
            }
        }
    }
}

extension RootView {
    static func launchFlag(_ key: String) -> Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: key)
        #else
        false
        #endif
    }

    static var launchTab: Int {
        #if DEBUG
        UserDefaults.standard.integer(forKey: "uiTab")
        #else
        0
        #endif
    }
}
