import Foundation
import Testing
@testable import TremorKit

/// Yields fixed samples and ends, or, with `hang`, then waits until cancelled.
private struct ArraySource: MotionSource {
    var recorded: [MotionSample]
    var hang = false

    func samples() -> AsyncThrowingStream<MotionSample, Error> {
        let recorded = recorded, hang = hang
        return AsyncThrowingStream { c in
            let task = Task {
                for s in recorded { c.yield(s) }
                if hang { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) } }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

/// Records the windows sent to the server and answers with a fixed result.
private actor FakeServer {
    var sent: [MotionWindow] = []
    let answer: Result<ScoreResult, APIError>

    init(_ answer: Result<ScoreResult, APIError>) { self.answer = answer }

    func score(_ w: MotionWindow) throws -> ScoreResult {
        sent.append(w)
        return try answer.get()
    }
}

private func still(seconds: Double, from t0: Double = 0) -> [MotionSample] {
    (0..<Int(seconds * 50)).map { MotionSample(t: t0 + Double($0) / 50, accel: Vec3(0, 0, 1)) }
}

private let ok = ScoreResult(status: .ok, activity: .resting, tremorScore: 40, bandLow: 35, bandHigh: 45, dominantHz: 6)

@MainActor
@Test func recordsThirtySecondsThenScoresOnce() async throws {
    let server = FakeServer(.success(ok))
    let test = PhoneTest(source: SyntheticMotionSource(pace: 0), score: { try await server.score($0) })
    await test.run(patientId: "p1")

    #expect(test.phase == .finished(.score(value: 40, low: 35, high: 45)))
    let sent = await server.sent
    let w = try #require(sent.first)
    #expect(sent.count == 1)
    #expect(w.source == .phone && w.patientId == "p1")
    #expect(abs(w.sampleRateHz - 50) < 0.01)
    #expect(w.accel.count == 1501)  // 30 s at 50 Hz, both ends included
    #expect(test.elapsed == PhoneTest.duration && test.remaining == 0)
}

@MainActor
@Test func refusalUsesPhoneWording() async {
    let server = FakeServer(.success(ScoreResult(status: .insufficientData, reason: "no_motion_signal")))
    let test = PhoneTest(source: ArraySource(recorded: still(seconds: 31)), score: { try await server.score($0) })
    await test.run(patientId: "p1")
    #expect(test.phase == .finished(.notEnoughData(reason: ScoreDisplay.reasonText("no_motion_signal", source: .phone))))
    #expect(ScoreDisplay.reasonText("no_motion_signal", source: .phone).contains("phone"))
}

@MainActor
@Test func sourceEndingEarlyScoresTheShortWindow() async throws {
    let server = FakeServer(.success(ok))
    let test = PhoneTest(source: ArraySource(recorded: still(seconds: 6)), score: { try await server.score($0) })
    await test.run(patientId: "p1")
    let w = try #require(await server.sent.first)
    #expect(w.accel.count == 300)
    #expect(abs(test.elapsed - 299.0 / 50) < 0.01)
}

@MainActor
@Test func sensorPauseRestartsTheRecording() async throws {
    let server = FakeServer(.success(ok))
    let samples = still(seconds: 5) + still(seconds: 31, from: 10)  // 5 s pause after the first 5 s
    let test = PhoneTest(source: ArraySource(recorded: samples), score: { try await server.score($0) })
    await test.run(patientId: "p1")
    #expect(test.restarts == 1)
    let w = try #require(await server.sent.first)
    #expect(w.accel.count == 1501)
}

@MainActor
@Test func serverErrorIsAFailureNotARefusal() async {
    let server = FakeServer(.failure(.http(status: 500, body: "")))
    let test = PhoneTest(source: ArraySource(recorded: still(seconds: 31)), score: { try await server.score($0) })
    await test.run(patientId: "p1")
    guard case .failed = test.phase else { Issue.record("expected .failed, got \(test.phase)"); return }
}

@MainActor
@Test func cancellingSendsNothing() async throws {
    let server = FakeServer(.success(ok))
    let test = PhoneTest(source: ArraySource(recorded: still(seconds: 3), hang: true), score: { try await server.score($0) })
    let run = Task { await test.run(patientId: "p1") }
    while test.elapsed < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(test.phase == .recording)
    run.cancel()
    await run.value
    #expect(test.phase == .ready)
    #expect(await server.sent.isEmpty)
}
