import Foundation
import Testing
@testable import TremorKit

// MARK: Dates as FastAPI writes them

@Test(arguments: [
    ("2026-11-24T10:00:00.123456+00:00", 1_795_514_400.123456),
    ("2026-11-24T10:00:00+00:00", 1_795_514_400.0),
    ("2026-11-24T10:00:00Z", 1_795_514_400.0),
    ("2026-11-24T10:00:00.5", 1_795_514_400.5),
    ("2026-11-24T15:30:00+05:30", 1_795_514_400.0),
])
func parsesBackendDates(_ s: String, _ expected: Double) throws {
    let d = try #require(WireDate.parse(s))
    #expect(abs(d.timeIntervalSince1970 - expected) < 1e-6)
}

@Test func rejectsGarbageDates() {
    #expect(WireDate.parse("yesterday") == nil)
    #expect(WireDate.parse("2026-11-24T10:00:00.") == nil)
}

// MARK: Wire format

@Test func decodesScoreAndRefusal() throws {
    let ok = try JSONDecoder.tremor.decode(ScoreResult.self, from: Data(#"""
    {"status":"ok","reason":null,"activity":"resting","tremor_score":42.1,"band_low":38.0,"band_high":46.2,"dominant_hz":5.9}
    """#.utf8))
    #expect(ok.status == .ok && ok.tremorScore == 42.1 && ok.activity == .resting)

    let refused = try JSONDecoder.tremor.decode(ScoreResult.self, from: Data(#"""
    {"status":"insufficient_data","reason":"voluntary_movement","activity":"unknown"}
    """#.utf8))
    #expect(ScoreDisplay(refused) == .notEnoughData(reason: ScoreDisplay.reasonText("voluntary_movement")))
}

@Test func refusalNeverShowsZero() {
    // Even if a refused result somehow carried a number, it must not be shown as a score.
    let r = ScoreResult(status: .insufficientData, reason: "no_motion_signal", tremorScore: 0)
    guard case .notEnoughData = ScoreDisplay(r) else { Issue.record("refusal shown as a score"); return }
}

@Test func encodesMotionWindowAsSnakeCaseWithTuples() throws {
    let w = MotionWindow(patientId: "p1", startedAt: Date(timeIntervalSince1970: 0), sampleRateHz: 50,
                         accel: [Vec3(0, 0, 1)], source: .phone)
    let obj = try JSONSerialization.jsonObject(with: JSONEncoder.tremor.encode(w)) as! [String: Any]
    #expect(obj["patient_id"] as? String == "p1")
    #expect(obj["started_at"] as? String == "1970-01-01T00:00:00.000Z")
    #expect(obj["source"] as? String == "phone")
    #expect((obj["accel"] as? [[Double]]) == [[0, 0, 1]])
}

@Test func decodesTimelineWithDefaults() throws {
    let t = try JSONDecoder.tremor.decode(Timeline.self, from: Data(#"""
    {"patient_id":"demo-patient","points":[{"at":"2026-11-20T08:00:00+00:00","result":{"status":"ok","tremor_score":30}}],
     "doses":[{"taken_at":"2026-11-20T07:30:00+00:00","label":"Levodopa"}]}
    """#.utf8))
    #expect(t.illustrative == false)
    #expect(t.doses.first?.tags == [])
    #expect(t.points.count == 1)
}

// MARK: Window buffer

@Test func bufferEmitsTenSecondWindowAtMeasuredRate() throws {
    var b = WindowBuffer(patientId: "p1")
    var out: MotionWindow?
    // 45 Hz actual delivery, slower than the 50 Hz asked for.
    for i in 0...460 where out == nil {
        out = b.append(MotionSample(t: Double(i) / 45, accel: Vec3(0, 0, 1)))
    }
    let w = try #require(out)
    #expect(abs(w.sampleRateHz - 45) < 0.01)
    #expect(w.accel.count == 451)
    #expect(w.gyro == nil)
    #expect(b.count == 0)
}

@Test func bufferDropsPartialWindowOnGap() {
    var b = WindowBuffer(patientId: "p1")
    for i in 0..<100 { _ = b.append(MotionSample(t: Double(i) / 50, accel: Vec3(0, 0, 1))) }
    _ = b.append(MotionSample(t: 10, accel: Vec3(0, 0, 1)))  // 8 s pause
    #expect(b.count == 1)
}

@Test func flushReturnsShortWindowForPhoneTest() throws {
    var b = WindowBuffer(patientId: "p1", seconds: 30, source: .phone)
    for i in 0..<300 { _ = b.append(MotionSample(t: Double(i) / 50, accel: Vec3(0, 0, 1), gyro: Vec3(0, 0, 0))) }
    let flushed = b.flush()
    let w = try #require(flushed)
    #expect(w.source == .phone && w.accel.count == 300 && w.gyro?.count == 300)
}

// MARK: Synthetic signal

@Test func syntheticSignalIsRepeatableAndHasGravity() {
    let a = SyntheticSignal.samples(seconds: 2, tremorHz: 6, tremorAmp: 0.1, seed: 7)
    let b = SyntheticSignal.samples(seconds: 2, tremorHz: 6, tremorAmp: 0.1, seed: 7)
    #expect(a == b)
    #expect(a.count == 100)
    let meanZ = a.map(\.z).reduce(0, +) / Double(a.count)
    #expect(abs(meanZ - 1) < 0.05)
}
