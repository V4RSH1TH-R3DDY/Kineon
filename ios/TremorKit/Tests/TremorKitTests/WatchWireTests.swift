import Foundation
import Testing
@testable import TremorKit

@Test func phoneContextRoundTrips() {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let ctx = PhoneContext(patientId: "p1", latest: ScoreResult(status: .ok, tremorScore: 42, bandLow: 38, bandHigh: 47), latestAt: at)
    #expect(PhoneContext(ctx.dictionary) == ctx)
}

@Test func emptyContextHasNoPatient() {
    #expect(PhoneContext([:]).patientId == nil)
    #expect(PhoneContext(patientId: nil).dictionary.isEmpty)
}

@Test func windowSurvivesTheWire() throws {
    let w = SyntheticSignal.window(patientId: "p1", tremorHz: 6, tremorAmp: 0.1)
    let back = try #require(WatchWire.decode(MotionWindow.self, from: WatchWire.encode(w)))
    #expect(back.accel.count == w.accel.count)
    #expect(back.patientId == "p1")
}

@Test func outboxDrainsInOrderAndStopsAtFailure() async {
    var box = Outbox()
    for i in 0..<3 { box.append(.dose(patientId: "p", DoseEvent(takenAt: .now, label: "d\(i)"))) }
    var seen: [String] = []
    let sent = await box.drain { item in
        guard case let .dose(_, d) = item else { return }
        if d.label == "d2" { throw URLError(.notConnectedToInternet) }
        seen.append(d.label)
    }
    #expect(sent == 2)
    #expect(seen == ["d0", "d1"])
    #expect(box.count == 1)
}

@Test func outboxDropsOldestWindowsNotDoses() {
    var box = Outbox()
    box.append(.dose(patientId: "p", DoseEvent(takenAt: .now, label: "keep")))
    for _ in 0..<(Outbox.limit + 5) { box.append(.window(SyntheticSignal.window(patientId: "p", seconds: 0.1))) }
    #expect(box.count == Outbox.limit)
    guard case .dose = box.items.first else { Issue.record("dose was dropped"); return }
}

@Test func outboxPersists() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var box = Outbox()
    box.append(.window(SyntheticSignal.window(patientId: "p", seconds: 1)))
    box.append(.dose(patientId: "p", DoseEvent(takenAt: .now, label: "x", tags: [.caffeine])))
    box.save(to: url)
    #expect(Outbox.load(from: url).count == 2)
}

@Test(arguments: [(20.0, UsualComparison.usual), (40.0, .usual), (45.0, .higher), (10.0, .lower)])
func comparesWithUsual(_ score: Double, _ want: UsualComparison) {
    #expect(UsualComparison(score: score, baseline: 30) == want)
}

@Test func noBaselineNoComparison() {
    #expect(UsualComparison(score: 50, baseline: nil) == nil)
    #expect(UsualComparison(score: 5, baseline: 60) == .lower)
}

@Test func contextCarriesUsual() {
    let c = PhoneContext(patientId: "p", usual: 31)
    #expect(PhoneContext(c.dictionary).usual == 31)
}

@Test func samplerTakesOneWindowPerMinute() {
    var sampler = WindowSampler(patientId: "p")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let accel = SyntheticSignal.samples(seconds: 300, tremorHz: 6, tremorAmp: 0.1)
    var windows: [MotionWindow] = []
    for (i, a) in accel.enumerated() {
        let t = Double(i) / 50
        if let w = sampler.append(MotionSample(t: t, accel: a), at: start.addingTimeInterval(t)) { windows.append(w) }
    }
    #expect(windows.count == 5)
    #expect(abs(windows[1].startedAt.timeIntervalSince(windows[0].startedAt) - 60) < 0.1)
    #expect(windows.allSatisfy { $0.accel.count == 501 })
}

@Test func samplerSkipsLiveSessions() {
    var sampler = WindowSampler(patientId: "p")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var n = 0
    for i in 0..<(50 * 120) {
        let t = Double(i) / 50
        // The first 100 seconds were a live session.
        if sampler.append(MotionSample(t: t, accel: Vec3(0, 0, 1)), at: start.addingTimeInterval(t), skip: t < 100) != nil { n += 1 }
    }
    #expect(n == 1)
}
