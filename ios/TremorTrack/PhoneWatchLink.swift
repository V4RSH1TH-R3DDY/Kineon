// The iPhone end of WatchConnectivity. For now it only reports whether the watch app is installed and reachable.
// Step 4 adds receiving motion windows from the watch and replying with their scores.
import Observation
import WatchConnectivity

@MainActor @Observable
final class PhoneWatchLink: NSObject {
    private(set) var supported = WCSession.isSupported()
    private(set) var paired = false
    private(set) var watchAppInstalled = false
    private(set) var reachable = false

    override init() {
        super.init()
        guard supported else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func apply(_ state: WatchState) {
        paired = state.paired
        watchAppInstalled = state.installed
        reachable = state.reachable
    }
}

/// A Sendable snapshot, read on the delegate's queue so the WCSession itself never crosses to the main actor.
struct WatchState: Sendable {
    let paired, installed, reachable: Bool
    init(_ s: WCSession) { paired = s.isPaired; installed = s.isWatchAppInstalled; reachable = s.isReachable }
}

extension PhoneWatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let snapshot = WatchState(session)
        Task { @MainActor in apply(snapshot) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()  // the user switched watches
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let snapshot = WatchState(session)
        Task { @MainActor in apply(snapshot) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let snapshot = WatchState(session)
        Task { @MainActor in apply(snapshot) }
    }
}
