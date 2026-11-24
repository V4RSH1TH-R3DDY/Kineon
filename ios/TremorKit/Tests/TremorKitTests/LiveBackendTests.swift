// End-to-end against a running backend. Skipped unless TREMORKIT_LIVE_URL is set, e.g.
//   (cd backend && KINEON_DB=/tmp/live.sqlite3 uv run uvicorn app.main:app --port 8000) &
//   TREMORKIT_LIVE_URL=http://localhost:8000 swift test
// Use a throwaway KINEON_DB: these tests write windows, doses and consents for a test patient.
import Foundation
import Testing
@testable import TremorKit

private let liveURL = ProcessInfo.processInfo.environment["TREMORKIT_LIVE_URL"].flatMap(URL.init(string:))

@Suite(.enabled(if: liveURL != nil, "set TREMORKIT_LIVE_URL to run against a backend"))
struct LiveBackendTests {
    let api = APIClient(baseURL: liveURL!)
    let pid = "tremorkit-test-\(UUID().uuidString.prefix(8))"

    @Test func tremorWindowIsScored() async throws {
        let r = try await api.postWindow(SyntheticSignal.window(patientId: pid, tremorHz: 6, tremorAmp: 0.1))
        #expect(r.status == .ok)
        #expect((r.dominantHz ?? 0) > 5 && (r.dominantHz ?? 0) < 7)
        let low = try #require(r.bandLow), high = try #require(r.bandHigh), s = try #require(r.tremorScore)
        #expect(low <= s && s <= high)
    }

    @Test func stillWindowIsRefusedNotZero() async throws {
        // Off the wrist: perfectly flat signal.
        let w = MotionWindow(patientId: pid, startedAt: Date(), sampleRateHz: 50,
                             accel: Array(repeating: Vec3(0, 0, 1), count: 500))
        let r = try await api.postWindow(w)
        #expect(r.status == .insufficientData && r.reason == "no_motion_signal" && r.tremorScore == nil)
    }

    @Test func walkingIsWithheld() async throws {
        let w = MotionWindow(patientId: pid, startedAt: Date(), sampleRateHz: SyntheticSignal.sampleRate,
                             accel: SyntheticSignal.walking(), source: .phone)
        let r = try await api.postPhoneTest(w)
        #expect(r.status == .insufficientData && r.reason == "voluntary_movement")
    }

    @Test func doseTimelineBaselineConsentRoundTrip() async throws {
        _ = try await api.postWindow(SyntheticSignal.window(patientId: pid, tremorHz: 6, tremorAmp: 0.1))
        try await api.postDose(patientId: pid, DoseEvent(takenAt: Date(), label: "Test dose", tags: [.caffeine]))
        let t = try await api.timeline(patientId: pid)
        #expect(t.points.count >= 1 && t.doses.first?.tags == [.caffeine] && !t.illustrative)
        _ = try await api.baseline(patientId: pid)
        let c = try await api.giveConsent(patientId: pid)
        try await api.withdrawConsent(patientId: pid, consentId: c.consentId)
        await #expect(throws: APIError.notFound) {
            try await api.withdrawConsent(patientId: pid, consentId: c.consentId)
        }
    }

    @Test func manualCalmGivesEpisodeAndAcceptsOutcome() async throws {
        _ = try await api.postWindow(SyntheticSignal.window(patientId: pid, tremorHz: 6, tremorAmp: 0.1))
        let d = try await api.evaluateCalm(patientId: pid, CalmEvaluateRequest(recentScore: 20, baselineScore: 20, manual: true))
        let id = try #require(d.episodeId)
        #expect(d.trigger && !d.tips.isEmpty)
        try await api.postCalmOutcome(patientId: pid, CalmOutcome(episodeId: id, tremorSettled: true))
    }

    @MainActor
    @Test func phoneTestScoresAndLandsOnTimeline() async throws {
        let api = api, pid = pid
        let test = PhoneTest(source: SyntheticMotionSource(pace: 0), score: { try await api.postPhoneTest($0) })
        await test.run(patientId: pid)
        guard case let .finished(.score(value, _, _)) = test.phase else {
            Issue.record("expected a score, got \(test.phase)"); return
        }
        #expect(value > 0)
        #expect(try await api.timeline(patientId: pid).points.count == 1)
    }

    @Test func unknownPatientIs404() async {
        await #expect(throws: APIError.notFound) { try await api.timeline(patientId: "nobody-\(UUID())") }
    }
}
