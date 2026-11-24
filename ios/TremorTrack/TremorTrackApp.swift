import SwiftUI

@main
struct TremorTrackApp: App {
    @State private var watch = PhoneWatchLink()

    var body: some Scene {
        WindowGroup {
            SetupCheckView()
                .environment(watch)
        }
    }
}
