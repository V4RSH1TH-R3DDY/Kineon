import SwiftUI

@main
struct TremorTrackWatchApp: App {
    @State private var link: WatchLink
    @State private var tracker: WatchTracker
    @State private var page = Page.live
    @Environment(\.scenePhase) private var phase

    enum Page: Hashable { case live, dose, calm }

    init() {
        let link = WatchLink()
        _link = State(initialValue: link)
        _tracker = State(initialValue: WatchTracker(link: link))
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $page) {
                LiveView(page: $page).tag(Page.live)
                DoseView().tag(Page.dose)
                CalmView().tag(Page.calm)
            }
            .tabViewStyle(.verticalPage)
            .environment(link)
            .environment(tracker)
            .task(id: phase) {
                if phase == .active { await tracker.collectAllDay(background: false) }
            }
        }
        // watchOS wakes the app here roughly every 30 minutes while all-day recording is on.
        .backgroundTask(.appRefresh(AllDayRecorder.refreshTask)) {
            await tracker.collectAllDay(background: true)
        }
    }
}
