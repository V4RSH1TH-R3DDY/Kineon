// Codable mirrors of backend/app/schemas.py, as published in contracts/openapi.json.
// Each model lists its keys in a CaseIterable CodingKeys enum so ContractTests can check them against the contract.
import Foundation

/// A type whose wire keys can be compared with a schema in contracts/openapi.json.
public protocol ContractModel: Codable {
    static var schemaName: String { get }
    static var wireKeys: [String] { get }
}

extension ContractModel where Self: Codable {
    static func keys<K: CodingKey & CaseIterable>(_: K.Type) -> [String] { K.allCases.map(\.stringValue) }
}

public enum Lang: String, Codable, CaseIterable, Sendable { case en, hi, kn }

public enum Activity: String, Codable, Sendable { case resting, walking, eating, writing, brushing, unknown }

public enum ScoreStatus: String, Codable, Sendable {
    case ok
    case insufficientData = "insufficient_data"
}

public enum Source: String, Codable, Sendable { case watch, phone }

public enum DoseTag: String, Codable, CaseIterable, Sendable {
    case caffeine, stress
    case sleepPoor = "sleep_poor"
}

/// One accelerometer or gyroscope reading. Encoded as `[x, y, z]`, matching the schema's 3-tuple.
public struct Vec3: Codable, Equatable, Sendable {
    public var x, y, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        self.init(try c.decode(Double.self), try c.decode(Double.self), try c.decode(Double.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(z)
    }
}

/// Accelerometer samples in g, gravity included. The scorer needs at least 25 Hz and 5 seconds.
public struct MotionWindow: ContractModel, Sendable {
    public var patientId: String
    public var startedAt: Date
    public var sampleRateHz: Double
    public var accel: [Vec3]
    public var gyro: [Vec3]?
    public var heartRateBpm: Double?
    public var source: Source

    public init(patientId: String, startedAt: Date, sampleRateHz: Double, accel: [Vec3],
                gyro: [Vec3]? = nil, heartRateBpm: Double? = nil, source: Source = .watch) {
        self.patientId = patientId; self.startedAt = startedAt; self.sampleRateHz = sampleRateHz
        self.accel = accel; self.gyro = gyro; self.heartRateBpm = heartRateBpm; self.source = source
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case patientId = "patient_id", startedAt = "started_at", sampleRateHz = "sample_rate_hz"
        case accel, gyro, heartRateBpm = "heart_rate_bpm", source
    }
    public static let schemaName = "MotionWindow"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

/// A scored window. When `status` is `.insufficientData`, show "not enough data" and the reason. Never show zero.
public struct ScoreResult: ContractModel, Equatable, Sendable {
    public var status: ScoreStatus
    public var reason: String?
    public var activity: Activity?
    public var tremorScore: Double?
    public var bandLow: Double?
    public var bandHigh: Double?
    public var dominantHz: Double?

    public init(status: ScoreStatus, reason: String? = nil, activity: Activity? = nil, tremorScore: Double? = nil,
                bandLow: Double? = nil, bandHigh: Double? = nil, dominantHz: Double? = nil) {
        self.status = status; self.reason = reason; self.activity = activity; self.tremorScore = tremorScore
        self.bandLow = bandLow; self.bandHigh = bandHigh; self.dominantHz = dominantHz
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case status, reason, activity, tremorScore = "tremor_score"
        case bandLow = "band_low", bandHigh = "band_high", dominantHz = "dominant_hz"
    }
    public static let schemaName = "ScoreResult"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

public struct DoseEvent: ContractModel, Equatable, Sendable {
    public var takenAt: Date
    public var label: String
    public var tags: [DoseTag]

    public init(takenAt: Date, label: String, tags: [DoseTag] = []) {
        self.takenAt = takenAt; self.label = label; self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        takenAt = try c.decode(Date.self, forKey: .takenAt)
        label = try c.decode(String.self, forKey: .label)
        tags = try c.decodeIfPresent([DoseTag].self, forKey: .tags) ?? []
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case takenAt = "taken_at", label, tags }
    public static let schemaName = "DoseEvent"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

public struct TimelinePoint: ContractModel, Equatable, Sendable {
    public var at: Date
    public var result: ScoreResult

    enum CodingKeys: String, CodingKey, CaseIterable { case at, result }
    public static let schemaName = "TimelinePoint"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

public struct Timeline: ContractModel, Sendable {
    public var patientId: String
    /// True for the seeded demo patient. Show an "Illustrative" banner whenever it is set.
    public var illustrative: Bool
    public var points: [TimelinePoint]
    public var doses: [DoseEvent]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        patientId = try c.decode(String.self, forKey: .patientId)
        illustrative = try c.decodeIfPresent(Bool.self, forKey: .illustrative) ?? false
        points = try c.decode([TimelinePoint].self, forKey: .points)
        doses = try c.decode([DoseEvent].self, forKey: .doses)
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case patientId = "patient_id", illustrative, points, doses }
    public static let schemaName = "Timeline"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

public struct Baseline: ContractModel, Equatable, Sendable {
    public var patientId: String
    /// Nil until the patient has enough good windows.
    public var medianScore: Double?
    public var typicalHz: Double?
    public var windowsSeen: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case patientId = "patient_id", medianScore = "median_score", typicalHz = "typical_hz", windowsSeen = "windows_seen"
    }
    public static let schemaName = "Baseline"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

public struct CalmEvaluateRequest: ContractModel, Sendable {
    public var recentScore: Double
    public var baselineScore: Double
    public var heartRateBpm: Double?
    public var baselineHeartRateBpm: Double?
    public var manual: Bool

    public init(recentScore: Double, baselineScore: Double, heartRateBpm: Double? = nil,
                baselineHeartRateBpm: Double? = nil, manual: Bool = false) {
        self.recentScore = recentScore; self.baselineScore = baselineScore; self.heartRateBpm = heartRateBpm
        self.baselineHeartRateBpm = baselineHeartRateBpm; self.manual = manual
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case recentScore = "recent_score", baselineScore = "baseline_score", heartRateBpm = "heart_rate_bpm"
        case baselineHeartRateBpm = "baseline_heart_rate_bpm", manual
    }
    public static let schemaName = "CalmEvaluateRequest"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

public struct CalmDecision: ContractModel, Equatable, Sendable {
    public var trigger: Bool
    /// Set when `trigger` is true. Send it back in `CalmOutcome`.
    public var episodeId: String?
    public var reason: String
    public var tips: [String]
    /// Never medicine advice.
    public var suggestContactClinician: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try c.decode(Bool.self, forKey: .trigger)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId)
        reason = try c.decode(String.self, forKey: .reason)
        tips = try c.decodeIfPresent([String].self, forKey: .tips) ?? []
        suggestContactClinician = try c.decodeIfPresent(Bool.self, forKey: .suggestContactClinician) ?? false
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case trigger, episodeId = "episode_id", reason, tips, suggestContactClinician = "suggest_contact_clinician"
    }
    public static let schemaName = "CalmDecision"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

public struct CalmOutcome: ContractModel, Sendable {
    public var episodeId: String
    public var tremorSettled: Bool
    public var heartRateSettled: Bool?

    public init(episodeId: String, tremorSettled: Bool, heartRateSettled: Bool? = nil) {
        self.episodeId = episodeId; self.tremorSettled = tremorSettled; self.heartRateSettled = heartRateSettled
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case episodeId = "episode_id", tremorSettled = "tremor_settled", heartRateSettled = "heart_rate_settled"
    }
    public static let schemaName = "CalmOutcome"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

public struct Consent: ContractModel, Equatable, Sendable {
    public var consentId: String

    enum CodingKeys: String, CodingKey, CaseIterable { case consentId = "consent_id" }
    public static let schemaName = "Consent"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

public struct Report: ContractModel, Sendable {
    public var patientId: String
    public var summary: String
    public var disclaimer: String
    public var lang: Lang

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        patientId = try c.decode(String.self, forKey: .patientId)
        summary = try c.decode(String.self, forKey: .summary)
        disclaimer = try c.decodeIfPresent(String.self, forKey: .disclaimer) ?? "Tracking report, not a diagnosis."
        lang = try c.decodeIfPresent(Lang.self, forKey: .lang) ?? .en
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case patientId = "patient_id", summary, disclaimer, lang }
    public static let schemaName = "Report"
    public static var wireKeys: [String] { keys(CodingKeys.self) }
}

/// Every model the apps send or receive, for the contract test.
public let contractModels: [any ContractModel.Type] = [
    MotionWindow.self, ScoreResult.self, DoseEvent.self, TimelinePoint.self, Timeline.self, Baseline.self,
    CalmEvaluateRequest.self, CalmDecision.self, CalmOutcome.self, Consent.self, Report.self,
]
