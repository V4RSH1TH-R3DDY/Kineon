// The exportable tremor report: the live recording's waveform and scores, then the history chart.
// Rendered on the phone to a PDF and a PNG image and shared with the share sheet.
// It is not signed: the verified, signed report comes from the clinic dashboard (export with consent).
import Charts
import SwiftUI
import TremorKit
import UIKit

struct TremorReportData {
    var patientName: String?
    var patientId: String
    var session: LiveTremor.Session?
    var simulated: Bool
    var history: [(at: Date, score: Double)]
    var historyLabel: String
    var doses: [Date]
    var usual: Double?
    var illustrative: Bool
    var created = Date()
}

struct TremorReportView: View {
    let data: TremorReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kineon tremor report").font(.system(size: 22, weight: .bold))
                    Text([data.patientName, "Patient ID \(data.patientId)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(data.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if data.simulated || data.illustrative {
                VStack(alignment: .leading, spacing: 4) {
                    if data.simulated { flag("Live recording uses a SIMULATED signal (no motion sensor on this device).") }
                    if data.illustrative { flag("History is ILLUSTRATIVE data from an invented demo patient.") }
                }
            }

            if let s = data.session, !s.signal.isEmpty { liveSection(s) }

            VStack(alignment: .leading, spacing: 8) {
                section("Tremor history", data.historyLabel)
                if data.history.isEmpty {
                    Text("No scored readings in this period.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Chart {
                        ForEach(Array(zip(data.history, Gaps.segments(data.history.map(\.at)))), id: \.0.at) { p, seg in
                            LineMark(x: .value("Time", p.at), y: .value("Score", p.score), series: .value("Run", seg))
                                .interpolationMethod(.monotone).foregroundStyle(.teal)
                        }
                        if let u = data.usual {
                            RuleMark(y: .value("Usual", u)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.gray)
                        }
                        ForEach(data.doses, id: \.self) { d in
                            RuleMark(x: .value("Dose", d)).foregroundStyle(.indigo.opacity(0.3))
                        }
                        if let s = data.session {
                            let span = (data.history.last?.at ?? data.created).timeIntervalSince(data.history.first?.at ?? data.created)
                            RectangleMark(xStart: .value("Start", s.start),
                                          xEnd: .value("End", max(s.end ?? data.created, s.start.addingTimeInterval(span / 120))),
                                          yStart: .value("Low", 0), yEnd: .value("High", 100))
                                .foregroundStyle(.red.opacity(0.25))
                                .annotation(position: .top) { Text("Live").font(.system(size: 9, weight: .semibold)).foregroundStyle(.red) }
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 170)
                    let scores = data.history.map(\.score)
                    Text("\(scores.count) readings · average \(Int((scores.reduce(0, +) / Double(scores.count)).rounded())) · lowest \(Int(scores.min()!.rounded())) · highest \(Int(scores.max()!.rounded()))"
                         + (data.usual.map { " · usual \(Int($0.rounded()))" } ?? "")
                         + (data.doses.isEmpty ? "" : " · \(data.doses.count) doses (purple lines)"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Divider()
            Text("Scores are 0–100 tremor intensity from 10-second windows; refusals (\"not enough data\") are never shown as zero. Kineon tracks tremor. It doesn't diagnose. This file was exported from the patient's phone and is not signed; for a verified report use the clinic dashboard.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: 612)
        .background(.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    private func liveSection(_ s: LiveTremor.Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Live recording",
                    "\(s.start.formatted(date: .abbreviated, time: .shortened)) · \(Duration.seconds(s.duration).formatted(.time(pattern: .minuteSecond)))")
            let points = Self.downsample(s.signal, to: 1600)
            let peak = max(LiveTremor.stillMg * 3, (points.map { abs($0.v) }.max() ?? 0) * 1.1)
            Chart(points, id: \.t) { p in
                LineMark(x: .value("Seconds", p.t), y: .value("mg", p.v))
                    .lineStyle(StrokeStyle(lineWidth: 0.6)).foregroundStyle(.teal)
            }
            .chartYScale(domain: -peak...peak)
            .chartXAxisLabel("seconds")
            .chartYAxisLabel("milli-g")
            .frame(height: 150)
            HStack(spacing: 22) {
                stat("Typical frequency", s.medianFrequency.map { "\($0.formatted(.number.precision(.fractionLength(1)))) Hz" } ?? "–")
                stat("Typical intensity", s.medianIntensity.map { "\(Int($0.rounded())) mg" } ?? "–")
                stat("Windows scored", "\(s.scores.filter { $0.result?.status == .ok }.count) of \(s.scores.count)")
            }
            if !s.scores.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(s.scores) { w in
                        HStack {
                            Text(w.at.formatted(date: .omitted, time: .standard)).frame(width: 90, alignment: .leading)
                            Text(Self.scoreText(w))
                        }
                        .font(.system(size: 10).monospacedDigit())
                    }
                }
            }
        }
    }

    static func scoreText(_ w: LiveTremor.WindowScore) -> String {
        if w.queued { return "Saved on phone, not yet scored" }
        guard let r = w.result else { return "Not scored" }
        switch ScoreDisplay(r, source: .phone) {
        case let .score(v, low, high):
            return "Score \(Int(v.rounded()))" + (low.flatMap { l in high.map { " (likely \(Int(l.rounded()))–\(Int($0.rounded())))" } } ?? "")
        case let .notEnoughData(reason):
            return "Not enough data: \(reason)"
        }
    }

    private func section(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold))
        }
    }

    private func flag(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
    }

    /// Keeps the shape of a long signal: for each bucket, the sample furthest from zero.
    static func downsample(_ x: [Double], to n: Int, rate: Double = LiveTremor.rate) -> [(t: Double, v: Double)] {
        guard x.count > n else { return x.enumerated().map { (Double($0.offset) / rate, $0.element) } }
        let size = Double(x.count) / Double(n)
        return (0..<n).map { i in
            let lo = Int(Double(i) * size), hi = min(x.count, Int(Double(i + 1) * size))
            let v = x[lo..<max(hi, lo + 1)].max { abs($0) < abs($1) } ?? 0
            return (Double(lo) / rate, v)
        }
    }
}

enum ReportExport {
    enum Kind { case pdf, image }

    /// Renders the report to a file in the temporary directory and returns its URL.
    @MainActor
    static func file(_ data: TremorReportData, kind: Kind) -> URL? {
        let renderer = ImageRenderer(content: TremorReportView(data: data))
        renderer.scale = 3
        let stamp = data.created.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + "-"
            + data.created.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let safeId = data.patientId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "Kineon-\(safeId)-\(stamp.replacingOccurrences(of: ":", with: "")).\(kind == .pdf ? "pdf" : "png")")
        switch kind {
        case .pdf:
            var ok = false
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
                ctx.beginPDFPage(nil)
                draw(ctx)
                ctx.endPDFPage()
                ctx.closePDF()
                ok = true
            }
            return ok ? url : nil
        case .image:
            guard let png = renderer.uiImage?.pngData(), (try? png.write(to: url)) != nil else { return nil }
            return url
        }
    }
}

/// The system share sheet for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Splits readings into runs so chart lines don't join across long gaps with no data.
enum Gaps {
    static let maxGap: TimeInterval = 8 * 3600

    static func segments(_ times: [Date]) -> [Int] {
        var seg = 0
        return times.enumerated().map { i, t in
            if i > 0, t.timeIntervalSince(times[i - 1]) > maxGap { seg += 1 }
            return seg
        }
    }
}
