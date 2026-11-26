// Start/stop tracking on the watch: the session that keeps it running, the motion capture, and the relay to the phone.
import Foundation
import Observation
import TremorKit
import WatchKit

@MainActor @Observable
final class WatchTracker {
    enum State: Equatable { case idle, starting, tracking, stopped(String) }

    private(set) var state: State = .idle
    private(set) var sessionKind: TrackingSession.Kind?
    /// 0...1 through the current 10-second window.
    private(set) var progress = 0.0
    private(set) var heartRate: Double?
    let simulated = !MotionCapture.hasSensor

    let link: WatchLink
    let allDay = AllDayRecorder()
    private(set) var allDayOn: Bool
    private(set) var collecting = false
    private var liveSince: Date?
    private let capture = MotionCapture()
    private let session = TrackingSession()

    init(link: WatchLink) {
        self.link = link
        allDayOn = allDay.enabled
        session.onHeartRate = { [weak self] bpm in
            self?.heartRate = bpm
            self?.capture.setHeartRate(bpm)
        }
        session.onEnded = { [weak self] why in self?.finish(why) }
    }

    var isTracking: Bool { state == .tracking || state == .starting }

    func start() async {
        guard !isTracking, let patientId = link.patientId else { return }
        state = .starting
        sessionKind = await session.start()
        guard state == .starting else { return }  // stopped while starting
        capture.start(
            patientId: patientId,
            onWindow: { [weak self] w in Task { @MainActor in self?.link.send(w) } },
            onProgress: { [weak self] p in Task { @MainActor in self?.progress = p } }
        )
        state = .tracking
        liveSince = .now
        WKInterfaceDevice.current().play(.start)
    }

    func stop() {
        guard isTracking else { return }
        finish(nil)
        WKInterfaceDevice.current().play(.stop)
    }

    // MARK: All-day recording

    func setAllDay(_ on: Bool) {
        allDay.enabled = on
        allDayOn = on
        if on { allDay.arm(); AllDayRecorder.scheduleRefresh() }
    }

    /// Collects recorded data and sends it to the phone. Foreground calls catch up further than background ones.
    func collectAllDay(background: Bool) async {
        guard allDay.enabled, !collecting, !isTracking, let patientId = link.patientId else { return }
        collecting = true
        defer { collecting = false }
        allDay.arm()
        let windows = await allDay.collect(patientId: patientId, maxSpan: background ? 3600 : 4 * 3600)
        windows.forEach(link.send)
        AllDayRecorder.scheduleRefresh()
    }

    private func finish(_ why: String?) {
        if let liveSince { allDay.noteLive(from: liveSince, to: .now) }
        liveSince = nil
        capture.stop()
        session.stop()
        progress = 0
        heartRate = nil
        sessionKind = nil
        state = why.map(State.stopped) ?? .idle
        if why != nil { WKInterfaceDevice.current().play(.failure) }
    }
}
