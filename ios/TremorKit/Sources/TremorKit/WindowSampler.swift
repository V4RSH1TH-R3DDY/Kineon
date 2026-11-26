// Turns hours of recorded accelerometer data into a manageable number of windows: one 10-second window
// at most every `every` seconds, skipping times already covered by a live session.
// Used for all-day recording, where the watch's sensor recorder keeps 50 Hz data while the app is closed.
import Foundation

public struct WindowSampler: Sendable {
    /// shortcut: one window a minute is about 1,400 a day, enough to see dose cycles without flooding the phone.
    public static let defaultEvery: TimeInterval = 60

    public let every: TimeInterval
    private var buffer: WindowBuffer
    private var nextStart: Date = .distantPast

    public init(patientId: String, every: TimeInterval = WindowSampler.defaultEvery) {
        self.every = every
        buffer = WindowBuffer(patientId: patientId, source: .watch)
    }

    /// `date` is the sample's wall-clock time. `skip` marks samples inside a live session, which were already scored.
    public mutating func append(_ s: MotionSample, at date: Date, skip: Bool = false) -> MotionWindow? {
        if skip || date < nextStart {
            if buffer.count > 0 { buffer.reset() }
            return nil
        }
        guard let w = buffer.append(s, now: date) else { return nil }
        nextStart = w.startedAt.addingTimeInterval(every)
        return w
    }
}
