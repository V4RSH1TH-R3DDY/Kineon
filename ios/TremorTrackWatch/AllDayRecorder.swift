// All-day measurement without draining the battery. A workout session can't run all day, so instead the watch's
// sensor recorder (CMSensorRecorder) keeps 50 Hz accelerometer data while the app is closed, for up to 12 hours
// per request, and holds it for 3 days. The app collects it in background refreshes and when it is opened,
// samples one 10-second window a minute, and sends those to the phone like live windows.
// Recorded data has no gyroscope or heart rate, and arrives up to 3 minutes late. Live readings need a live session.
import CoreMotion
import Foundation
import TremorKit
import WatchKit

extension CMSensorDataList: @retroactive Sequence {
    public func makeIterator() -> NSFastEnumerationIterator { NSFastEnumerationIterator(self) }
}

final class AllDayRecorder: @unchecked Sendable {
    static let refreshTask = "kineon.allday"
    /// The recorder's own limit per request. Re-armed well before it runs out.
    static let recordSpan: TimeInterval = 12 * 3600
    static let rearmAfter: TimeInterval = 6 * 3600
    /// Data is available up to 3 minutes after it was recorded.
    static let settle: TimeInterval = 3 * 60

    static var isAvailable: Bool { CMSensorRecorder.isAccelerometerRecordingAvailable() }

    private let defaults = UserDefaults.standard
    private let recorder = CMSensorRecorder()
    private let lock = NSLock()

    var enabled: Bool {
        get { defaults.bool(forKey: "allDay.enabled") }
        set { defaults.set(newValue, forKey: "allDay.enabled") }
    }
    var lastCollected: Date? { date("allDay.collected") }

    /// Starts recording, or extends it if the last request is getting old. Safe to call often.
    func arm() {
        guard enabled, Self.isAvailable else { return }
        let armed = date("allDay.armed")
        if let armed, Date().timeIntervalSince(armed) < Self.rearmAfter { return }
        recorder.recordAccelerometer(forDuration: Self.recordSpan)
        defaults.set(Date().timeIntervalSince1970, forKey: "allDay.armed")
        if lastCollected == nil { defaults.set(Date().timeIntervalSince1970, forKey: "allDay.collected") }
    }

    /// Live sessions are scored already, so their time is skipped when collecting.
    func noteLive(from start: Date, to end: Date) {
        lock.withLock {
            var spans = defaults.array(forKey: "allDay.live") as? [[Double]] ?? []
            spans.append([start.timeIntervalSince1970, end.timeIntervalSince1970])
            let cutoff = Date().addingTimeInterval(-3 * 86_400).timeIntervalSince1970
            defaults.set(spans.filter { $0[1] > cutoff }, forKey: "allDay.live")
        }
    }

    /// Reads recorded data since the last collection, up to `maxSpan` seconds of it, off the main thread.
    /// Enumerating 50 Hz data is slow on a watch, so background refreshes use a short span.
    func collect(patientId: String, maxSpan: TimeInterval) async -> [MotionWindow] {
        guard enabled, Self.isAvailable, let from = lastCollected else { return [] }
        let to = min(Date().addingTimeInterval(-Self.settle), from.addingTimeInterval(maxSpan))
        guard to > from else { return [] }
        let live = (defaults.array(forKey: "allDay.live") as? [[Double]] ?? []).map { $0[0]...$0[1] }
        let windows = await Task.detached(priority: .utility) { [recorder] in
            guard let list = recorder.accelerometerData(from: from, to: to) else { return [MotionWindow]() }
            var sampler = WindowSampler(patientId: patientId)
            var out: [MotionWindow] = []
            for case let d as CMRecordedAccelerometerData in list {
                let a = d.acceleration
                let at = d.startDate.timeIntervalSince1970
                if let w = sampler.append(MotionSample(t: d.timestamp, accel: Vec3(a.x, a.y, a.z)),
                                          at: d.startDate, skip: live.contains { $0.contains(at) }) {
                    out.append(w)
                }
            }
            return out
        }.value
        defaults.set(to.timeIntervalSince1970, forKey: "allDay.collected")
        return windows
    }

    /// Asks watchOS to wake the app in about 30 minutes. The system decides the exact time.
    @MainActor static func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(30 * 60),
                                                        userInfo: refreshTask as NSString) { _ in }
    }

    private func date(_ key: String) -> Date? {
        let v = defaults.double(forKey: key)
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }
}
