// The iPhone end of WatchConnectivity. Receives windows and doses from the watch (transferUserInfo, guaranteed
// delivery) and keeps the watch up to date with the patient ID and the latest score.
import Foundation
import Observation
import TremorKit
import WatchConnectivity

@MainActor @Observable
final class PhoneWatchLink: NSObject {
    private(set) var supported = WCSession.isSupported()
    private(set) var activated = false
    private(set) var paired = false
    private(set) var watchAppInstalled = false
    private(set) var reachable = false

    @ObservationIgnored var onWindow: ((MotionWindow) -> Void)?
    @ObservationIgnored var onDose: ((DoseEvent) -> Void)?
    @ObservationIgnored var onActivated: (() -> Void)?

    override init() {
        super.init()
        guard supported else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the whole state. Application context survives until the watch next runs; the message is just faster.
    func push(_ c: PhoneContext) {
        guard activated, paired, watchAppInstalled else { return }
        let d = c.dictionary
        try? WCSession.default.updateApplicationContext(d)
        if reachable { WCSession.default.sendMessage(d, replyHandler: nil, errorHandler: nil) }
    }

    private func apply(_ state: WatchState) {
        let firstActivation = !activated && state.activated
        activated = state.activated
        paired = state.paired
        watchAppInstalled = state.installed
        reachable = state.reachable
        if firstActivation || state.installed { onActivated?() }
    }

    private func receive(_ r: Received) {
        if let w = r.window { onWindow?(w) }
        if let d = r.dose { onDose?(d) }
    }
}

/// A Sendable snapshot, read on the delegate's queue so the WCSession itself never crosses to the main actor.
private struct WatchState: Sendable {
    let activated, paired, installed, reachable: Bool
    init(_ s: WCSession) {
        activated = s.activationState == .activated
        paired = s.isPaired; installed = s.isWatchAppInstalled; reachable = s.isReachable
    }
}

private struct Received: Sendable {
    let window: MotionWindow?
    let dose: DoseEvent?
    init(_ d: [String: Any]) {
        window = WatchWire.decode(MotionWindow.self, from: d[WatchWire.window])
        dose = WatchWire.decode(DoseEvent.self, from: d[WatchWire.dose])
    }
}

extension PhoneWatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let s = WatchState(session)
        Task { @MainActor in apply(s) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()  // the user switched watches
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let s = WatchState(session)
        Task { @MainActor in apply(s) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let s = WatchState(session)
        Task { @MainActor in apply(s) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let r = Received(userInfo)
        Task { @MainActor in receive(r) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let r = Received(message)
        Task { @MainActor in receive(r) }
    }
}
