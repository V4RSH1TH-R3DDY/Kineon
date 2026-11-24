// How a ScoreResult is shown to a patient. A refused window always reads "Not enough data", never zero.
// English source strings; the apps localise them through their String Catalog.
import Foundation

public enum ScoreDisplay: Equatable, Sendable {
    case score(value: Double, low: Double?, high: Double?)
    case notEnoughData(reason: String)

    /// `source` picks the wording of refusal reasons, so a phone test never tells the patient to check their watch.
    public init(_ r: ScoreResult, source: Source = .watch) {
        if r.status == .ok, let v = r.tremorScore {
            self = .score(value: v, low: r.bandLow, high: r.bandHigh)
        } else {
            self = .notEnoughData(reason: ScoreDisplay.reasonText(r.reason, source: source))
        }
    }

    /// Plain-language text for each refusal reason in backend/app/sense/score.py.
    public static func reasonText(_ reason: String?, source: Source = .watch) -> String {
        switch (reason, source) {
        case ("no_motion_signal", .watch): "The watch is not picking up movement. Check it is on your wrist and snug."
        case ("no_motion_signal", .phone): "The phone is not picking up movement. Hold it in the hand being tested, not on a table."
        case ("voluntary_movement", _): "You were moving your arm, so tremor could not be measured."
        case ("motion_artefact_or_noise", .watch): "The signal was too noisy. Check the watch is not loose."
        case ("motion_artefact_or_noise", .phone): "The signal was too noisy. Hold the phone without tapping or shifting your grip."
        case ("sensor_saturated", _): "The movement was too strong for the sensor."
        case ("sample_rate_too_low", _): "The sensor was too slow for this reading."
        case ("window_too_short", _): "The reading was too short."
        case ("malformed_data", _): "The reading could not be read."
        default: "The reading could not be scored."
        }
    }
}
