// What the watch and the iPhone send each other over WatchConnectivity. Only the iPhone talks to the backend:
// the watch sends finished windows and doses, the phone posts them and sends the score back.
// Payloads are the same JSON the backend uses, carried as Data so both ends share one encoder.
import Foundation

public enum WatchWire {
    /// Watch to phone: a finished MotionWindow.
    public static let window = "window"
    /// Watch to phone: a DoseEvent logged on the watch.
    public static let dose = "dose"
    /// Phone to watch: the ScoreResult for the most recent window.
    public static let score = "score"
    /// Phone to watch: when that score's window started.
    public static let scoredAt = "scoredAt"
    /// Phone to watch: the patient ID the watch should put in its windows. Absent until setup is done.
    public static let patientId = "patientId"
    /// Phone to watch: the patient's usual score (baseline median), so the watch can say when a reading is higher.
    public static let usual = "usual"

    public static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder.tremor.encode(value) }

    public static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder.tremor.decode(type, from: data)
    }
}

/// What the phone keeps on the watch through `updateApplicationContext`: always the whole state, never a diff.
public struct PhoneContext: Equatable, Sendable {
    public var patientId: String?
    public var latest: ScoreResult?
    public var latestAt: Date?
    public var usual: Double?

    public init(patientId: String?, latest: ScoreResult? = nil, latestAt: Date? = nil, usual: Double? = nil) {
        self.patientId = patientId; self.latest = latest; self.latestAt = latestAt; self.usual = usual
    }

    /// Property-list values only, as WatchConnectivity requires.
    public var dictionary: [String: Any] {
        var d: [String: Any] = [:]
        if let patientId { d[WatchWire.patientId] = patientId }
        if let latest, let data = WatchWire.encode(latest) { d[WatchWire.score] = data }
        if let latestAt { d[WatchWire.scoredAt] = latestAt }
        if let usual { d[WatchWire.usual] = usual }
        return d
    }

    public init(_ d: [String: Any]) {
        patientId = d[WatchWire.patientId] as? String
        latest = WatchWire.decode(ScoreResult.self, from: d[WatchWire.score])
        latestAt = d[WatchWire.scoredAt] as? Date
        usual = d[WatchWire.usual] as? Double
    }
}
