// The watch end of WatchConnectivity. Windows and doses go to the phone with transferUserInfo, which the system
// queues and delivers even if the phone is away or asleep, so nothing is lost and nothing is sent twice.
// The phone posts them to the backend and sends back the score, by message (fast) and application context (lasting).
import Foundation
import Observation
import TremorKit
import WatchConnectivity
import WatchKit

@MainActor @Observable
final class WatchLink: NSObject {
    private(set) var context = PhoneContext(patientId: nil)
    private(set) var phoneReachable = false
    /// Windows and doses handed to the system that the phone has not picked up yet.
    private(set) var waiting = 0
    private(set) var sentThisSession = 0
    /// Set when a fresh reading is clearly higher than the patient's usual. The live screen offers Calm Mode.
    var higherThanUsual = false
    private var lastAlert = Date.distantPast

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var patientId: String? { context.patientId }

    func send(_ w: MotionWindow) {
        guard let data = WatchWire.encode(w) else { return }
        WCSession.default.transferUserInfo([WatchWire.window: data])
        sentThisSession += 1
        refreshWaiting()
    }

    func logDose(_ d: DoseEvent) {
        guard let data = WatchWire.encode(d) else { return }
        WCSession.default.transferUserInfo([WatchWire.dose: data])
        refreshWaiting()
    }

    func refreshWaiting() {
        waiting = WCSession.default.outstandingUserInfoTransfers.count
        phoneReachable = WCSession.default.isReachable
    }

    fileprivate func apply(_ c: PhoneContext) {
        let isNew = c.latestAt != nil && c.latestAt != context.latestAt
        context = c
        refreshWaiting()
        // Buzz once for a fresh high reading, at most every 15 minutes.
        guard isNew, let at = c.latestAt, Date().timeIntervalSince(at) < 120,
              let score = c.latest?.tremorScore, c.latest?.status == .ok,
              UsualComparison(score: score, baseline: c.usual) == .higher,
              Date().timeIntervalSince(lastAlert) > 15 * 60 else { return }
        lastAlert = .now
        higherThanUsual = true
        WKInterfaceDevice.current().play(.notification)
    }
}

/// The dictionary's values are property-list types; decode before leaving the delegate queue.
private func snapshot(_ d: [String: Any]) -> PhoneContext { PhoneContext(d) }

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let c = snapshot(s.receivedApplicationContext)
        Task { @MainActor in apply(c) }
    }

    nonisolated func session(_ s: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        let c = snapshot(ctx)
        Task { @MainActor in apply(c) }
    }

    nonisolated func session(_ s: WCSession, didReceiveMessage message: [String: Any]) {
        let c = snapshot(message)
        Task { @MainActor in apply(c) }
    }

    nonisolated func session(_ s: WCSession, didFinish transfer: WCSessionUserInfoTransfer, error: Error?) {
        Task { @MainActor in refreshWaiting() }
    }

    nonisolated func sessionReachabilityDidChange(_ s: WCSession) {
        Task { @MainActor in refreshWaiting() }
    }
}
