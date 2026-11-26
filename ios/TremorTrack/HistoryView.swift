// The Tremor tab: a live accelerometer waveform at the top, whose 10-second windows are scored and added to the
// history below it (the recording is highlighted on the history chart). Then tremor after doses, by time of day,
// and the medication log. Both can be exported as a PDF or chart image.
import Charts
import SwiftUI
import TremorKit

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var range: Span = .week
    @State private var selected: Date?
    @State private var shareURL: ShareItem?
    @State private var exportFailed = false

    struct ShareItem: Identifiable { let url: URL; var id: URL { url } }

    enum Span: String, CaseIterable, Identifiable {
        case day = "D", week = "W", month = "M"
        var id: Self { self }
        var seconds: TimeInterval { switch self { case .day: 86_400; case .week: 7 * 86_400; case .month: 30 * 86_400 } }
    }

    private struct Point: Identifiable { var id: Date { at }; let at: Date; let score: Double; let low: Double?; let high: Double? }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LiveCard()

                    sectionTitle("History")
                    Picker("Range", selection: $range) {
                        ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Card {
                        headline
                        if points.isEmpty {
                            ContentUnavailableView("No readings", systemImage: "chart.xyaxis.line",
                                                   description: Text("Readings from your watch, live recordings and the phone test appear here."))
                                .frame(height: 220)
                        } else {
                            chart
                            legend
                        }
                    }

                    if afterDose.count >= 3 {
                        sectionTitle("After a dose")
                        AfterDoseCard(buckets: afterDose, usual: model.usual)
                    }

                    if range != .day, pattern.count >= 3 {
                        sectionTitle("By time of day")
                        PatternCard(buckets: pattern, usual: model.usual)
                    }

                    if !doses.isEmpty {
                        sectionTitle("Medication")
                        Card {
                            ForEach(Array(doses.prefix(8).enumerated()), id: \.element.takenAt) { i, d in
                                if i > 0 { Divider().padding(.leading, 44) }
                                HStack(spacing: 12) {
                                    IconTile(symbol: "pills.fill", tint: .indigo, size: 32)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(d.label).font(.body.weight(.medium))
                                        if !d.tags.isEmpty {
                                            Text(d.tags.map(\.title).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(d.takenAt, format: .dateTime.weekday(.abbreviated).hour().minute())
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if model.timeline?.illustrative == true {
                        Label("Illustrative data from an invented demo patient.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 8)
                    }
                    Disclaimer().padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .headerWash()
            .navigationTitle("Tremor")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        Button("PDF Report", systemImage: "doc.richtext") { export(.pdf) }
                        Button("Chart Image", systemImage: "photo") { export(.image) }
                    }
                    .disabled(model.live.state == .running)
                }
            }
            .sheet(item: $shareURL) { ShareSheet(url: $0.url).presentationDetents([.medium, .large]) }
            .alert("Couldn't create the export", isPresented: $exportFailed) { Button("OK") {} }
            .refreshable { await model.refresh() }
            .onChange(of: range) { selected = nil }
            .task { await debugAutoRecord() }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.title3.weight(.bold)).padding(.top, 10).padding(.leading, 4)
    }

    private func fmt(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "–" }

    @ViewBuilder private var headline: some View {
        let shown = selectedPoint
        VStack(alignment: .leading, spacing: 0) {
            Text(shown == nil || range != .day ? "AVERAGE" : "READING").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            BigValue(value: shown.map { "\(Int($0.score.rounded()))" } ?? fmt(average), unit: "/ 100")
            Text(shown.map { $0.at.formatted(.dateTime.weekday().hour().minute()) } ?? rangeText)
                .font(.subheadline).foregroundStyle(.secondary)
            if shown == nil, !points.isEmpty {
                Text("\(points.count) readings · lowest \(fmt(points.map(\.score).min())) · highest \(fmt(points.map(\.score).max()))"
                     + (withheld > 0 ? " · \(withheld) not enough data" : ""))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(zip(plotted, Gaps.segments(plotted.map(\.at)))), id: \.0.at) { p, seg in
                AreaMark(x: .value("Time", p.at), yStart: .value("Base", 0), yEnd: .value("Score", p.score),
                         series: .value("Run", seg))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [.teal.opacity(0.3), .teal.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.at), y: .value("Score", p.score), series: .value("Run", seg))
                    .foregroundStyle(.teal)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let usual = model.usual {
                RuleMark(y: .value("Usual", usual))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            if let live = liveSpan {
                RectangleMark(xStart: .value("Live start", live.lowerBound), xEnd: .value("Live end", live.upperBound),
                              yStart: .value("Low", 0), yEnd: .value("High", 100))
                    .foregroundStyle(.red.opacity(0.12))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Live").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    }
            }
            ForEach(range == .day ? doses : [], id: \.takenAt) { d in
                RuleMark(x: .value("Dose", d.takenAt))
                    .foregroundStyle(.indigo.opacity(0.25))
                PointMark(x: .value("Dose", d.takenAt), y: .value("Dose", 100))
                    .symbol { Image(systemName: "pills.fill").font(.system(size: 9)).foregroundStyle(.indigo) }
            }
            if let s = selectedPoint {
                if let low = s.low, let high = s.high {
                    RectangleMark(x: .value("Selected", s.at), yStart: .value("Low", low), yEnd: .value("High", high), width: 8)
                        .foregroundStyle(.teal.opacity(0.25))
                        .clipShape(.capsule)
                }
                RuleMark(x: .value("Selected", s.at)).foregroundStyle(.secondary.opacity(0.4))
                PointMark(x: .value("Selected", s.at), y: .value("Score", s.score)).foregroundStyle(.teal).symbolSize(70)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: since...Date())
        .chartYAxis { AxisMarks(position: .trailing, values: [0, 50, 100]) }
        .chartXSelection(value: $selected)
        .frame(height: 230)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label("Tremor", systemImage: "circle.fill").foregroundStyle(.teal)
            if range == .day, !doses.isEmpty { Label("Dose", systemImage: "pills.fill").foregroundStyle(.indigo) }
            if model.usual != nil { Text("‒ ‒  Your usual").foregroundStyle(.secondary) }
            if liveSpan != nil { Label("Live", systemImage: "square.fill").foregroundStyle(.red.opacity(0.5)) }
            Spacer()
        }
        .font(.caption.weight(.medium))
        .labelStyle(LegendLabelStyle())
    }

    private var since: Date { Date().addingTimeInterval(-range.seconds) }

    /// The latest live recording's time span, at least a few minutes wide so it's visible on a week or month chart.
    private var liveSpan: ClosedRange<Date>? {
        guard let s = model.live.session, s.start >= since else { return nil }
        let end = s.end ?? .now
        let minWidth = range.seconds / 150
        return s.start...max(end, s.start.addingTimeInterval(minWidth))
    }

    /// Average score by hours since the most recent dose (within 6 hours), from all readings in the range.
    private var afterDose: [AfterDoseCard.Bucket] {
        let times = (model.timeline?.doses ?? []).map(\.takenAt).sorted()
        guard !times.isEmpty else { return [] }
        var groups: [Int: [Double]] = [:]
        for p in points {
            guard let last = times.last(where: { $0 <= p.at }) else { continue }
            let h = Int(p.at.timeIntervalSince(last) / 3600)
            if h < 6 { groups[h, default: []].append(p.score) }
        }
        return groups.map { .init(hour: $0.key, score: $0.value.reduce(0, +) / Double($0.value.count), count: $0.value.count) }
            .sorted { $0.hour < $1.hour }
    }

    /// Debug builds only: `-uiLive YES` records for 25 s, stops, and opens the PDF export (used for screenshots).
    private func debugAutoRecord() async {
        guard RootView.launchFlag("uiLive"), model.live.state == .idle, let pid = model.patientId else { return }
        model.live.start(patientId: pid)
        try? await Task.sleep(for: .seconds(25))
        model.live.stop()
        try? await Task.sleep(for: .seconds(3))
        if RootView.launchFlag("uiExport") { export(.pdf) }
    }

    private func export(_ kind: ReportExport.Kind) {
        let data = TremorReportData(
            patientName: model.account?.name,
            patientId: model.patientId ?? "unknown",
            session: model.live.snapshot(),
            simulated: model.live.simulated && model.live.session != nil,
            history: points.map { ($0.at, $0.score) },
            historyLabel: rangeText,
            doses: doses.map(\.takenAt),
            usual: model.usual,
            illustrative: model.timeline?.illustrative == true)
        if let url = ReportExport.file(data, kind: kind) { shareURL = ShareItem(url: url) } else { exportFailed = true }
    }

    private var rangeText: String {
        range == .day ? "Last 24 hours" : "\(since.formatted(.dateTime.day().month())) – \(Date().formatted(.dateTime.day().month()))"
    }

    /// Every ok reading in the range.
    private var points: [Point] {
        (model.timeline?.points ?? []).compactMap { p in
            guard p.at >= since, p.result.status == .ok, let s = p.result.tremorScore else { return nil }
            return Point(at: p.at, score: s, low: p.result.bandLow, high: p.result.bandHigh)
        }
        .sorted { $0.at < $1.at }
    }

    /// What the chart draws: raw readings for a day, 4-hour averages for a week, daily averages for a month.
    private var plotted: [Point] {
        let block: TimeInterval = switch range { case .day: 0; case .week: 4 * 3600; case .month: 86_400 }
        guard block > 0 else { return points }
        let tz = TimeInterval(TimeZone.current.secondsFromGMT())
        let groups = Dictionary(grouping: points) { (($0.at.timeIntervalSince1970 + tz) / block).rounded(.down) }
        return groups.map { k, v in
            Point(at: Date(timeIntervalSince1970: k * block - tz + block / 2),
                  score: v.map(\.score).reduce(0, +) / Double(v.count),
                  low: v.map(\.score).min(), high: v.map(\.score).max())
        }
        .sorted { $0.at < $1.at }
    }

    /// Average score per three-hour block of the day, across the selected range.
    private var pattern: [PatternCard.Bucket] {
        let groups = Dictionary(grouping: points) { Calendar.current.component(.hour, from: $0.at) / 3 }
        return groups.map { k, v in .init(hour: k * 3, score: v.map(\.score).reduce(0, +) / Double(v.count)) }
            .sorted { $0.hour < $1.hour }
    }

    private var selectedPoint: Point? {
        guard let selected else { return nil }
        return plotted.min { abs($0.at.timeIntervalSince(selected)) < abs($1.at.timeIntervalSince(selected)) }
    }

    private var average: Double? {
        points.isEmpty ? nil : points.map(\.score).reduce(0, +) / Double(points.count)
    }

    private var withheld: Int {
        (model.timeline?.points ?? []).filter { $0.at >= since && $0.result.status != .ok }.count
    }

    private var doses: [DoseEvent] {
        (model.timeline?.doses ?? []).filter { $0.takenAt >= since }.sorted { $0.takenAt > $1.takenAt }
    }
}

private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 7)); configuration.title.foregroundStyle(.secondary) }
    }
}

/// Bars for each three-hour block; blocks clearly above the usual level are orange.
private struct PatternCard: View {
    struct Bucket: Identifiable { var id: Int { hour }; let hour: Int; let score: Double }
    let buckets: [Bucket]
    let usual: Double?

    var body: some View {
        Card {
            if let peak = buckets.max(by: { $0.score < $1.score }) {
                Text("Highest around \(label(peak.hour))").font(.headline)
                Text("Average score for each part of the day").font(.subheadline).foregroundStyle(.secondary)
            }
            Chart(buckets) { b in
                BarMark(x: .value("Time", label(b.hour)), y: .value("Score", b.score), width: .ratio(0.6))
                    .foregroundStyle(tint(b).gradient)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                if let usual {
                    RuleMark(y: .value("Usual", usual))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
            }
            .chartYScale(domain: 0...max(50, (buckets.map(\.score).max() ?? 0) + 10))
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .frame(height: 160)
            .padding(.top, 4)
        }
    }

    private func tint(_ b: Bucket) -> Color {
        UsualComparison(score: b.score, baseline: usual) == .higher ? .orange : .teal
    }

    private func label(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
            .formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }
}

/// Average score for each hour after a dose; hours clearly above the usual level are orange.
private struct AfterDoseCard: View {
    struct Bucket: Identifiable { var id: Int { hour }; let hour: Int; let score: Double; let count: Int }
    let buckets: [Bucket]
    let usual: Double?

    var body: some View {
        Card {
            if let low = buckets.min(by: { $0.score < $1.score }), let high = buckets.max(by: { $0.score < $1.score }) {
                Text("Lowest \(label(low.hour)) after a dose, highest \(label(high.hour)) after")
                    .font(.headline)
                Text("Average score by time since your last dose").font(.subheadline).foregroundStyle(.secondary)
            }
            Chart(buckets) { b in
                BarMark(x: .value("Hours after dose", label(b.hour)), y: .value("Score", b.score), width: .ratio(0.6))
                    .foregroundStyle((UsualComparison(score: b.score, baseline: usual) == .higher ? Color.orange : .indigo).gradient)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                    .annotation(position: .top) {
                        Text("\(Int(b.score.rounded()))").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                if let usual {
                    RuleMark(y: .value("Usual", usual))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
            }
            .chartYScale(domain: 0...max(50, (buckets.map(\.score).max() ?? 0) + 12))
            .chartYAxis(.hidden)
            .frame(height: 160)
            .padding(.top, 4)
            Text("A rise before the next dose is worth showing your neurologist.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func label(_ h: Int) -> String { h == 0 ? "0–1 h" : "\(h)–\(h + 1) h" }
}

/// The live recording: waveform, frequency, intensity and the latest 10-second score, with Start / Stop.
private struct LiveCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.live
        Card {
            HStack {
                Label("Live", systemImage: "waveform.badge.magnifyingglass")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                Spacer()
                if live.state == .running, let start = live.session?.start {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                            .phaseAnimator([1.0, 0.3]) { c, o in c.opacity(o) } animation: { _ in .easeInOut(duration: 0.7) }
                        Text(start, style: .timer).monospacedDigit()
                    }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.red)
                } else if live.simulated {
                    Text("Simulated signal").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                }
            }

            Waveform(trace: live.trace, active: live.state == .running)
                .frame(height: 140)
                .overlay {
                    if live.state == .idle {
                        Text("Rest your forearm on a table or your leg and hold the phone in the hand you're testing.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }

            HStack(spacing: 0) {
                metric("Frequency", live.frequencyHz.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–", "Hz")
                metric("Intensity", live.intensityMg.map { "\(Int($0.rounded()))" } ?? "–", "mg")
                metric("Score", lastScore, "/ 100")
            }
            .padding(.vertical, 2)

            if let scores = live.session?.scores, !scores.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(scores) { w in chip(w).id(w.id) }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: scores.count) { if let last = scores.last { withAnimation { proxy.scrollTo(last.id) } } }
                }
            }

            Group {
                if live.state == .running {
                    Button { live.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glass).tint(.red)
                } else {
                    Button {
                        if let pid = model.patientId { live.start(patientId: pid) }
                    } label: {
                        Label(live.state == .stopped ? "Record Again" : "Start Live Recording", systemImage: "record.circle")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent).tint(.red)
                    .disabled(model.patientId == nil)
                }
            }
            .controlSize(.large)

            Text(live.state == .stopped
                 ? "This recording is highlighted in your history below. Use Export to share it as a PDF or chart."
                 : "Every 10 seconds is scored and added to your history below.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .sensoryFeedback(.start, trigger: live.state == .running) { _, new in new }
    }

    private var lastScore: String {
        guard let w = model.live.session?.scores.last else { return model.live.state == .running ? "…" : "–" }
        if case let .score(v, _, _)? = w.result.map({ ScoreDisplay($0, source: .phone) }) { return "\(Int(v.rounded()))" }
        return "–"
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ w: LiveTremor.WindowScore) -> some View {
        let text: String
        let tint: Color
        if w.queued { text = "Saved"; tint = .orange }
        else if case let .score(v, _, _)? = w.result.map({ ScoreDisplay($0, source: .phone) }) {
            text = "\(Int(v.rounded()))"
            tint = UsualComparison(score: v, baseline: model.usual)?.tint ?? .teal
        } else { text = "No data"; tint = .gray }
        return VStack(spacing: 1) {
            Text(text).font(.footnote.weight(.bold)).monospacedDigit()
            Text(w.at, format: .dateTime.hour().minute().second()).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(tint.opacity(0.14), in: .rect(cornerRadius: 10, style: .continuous))
        .foregroundStyle(tint)
    }
}

/// A scrolling line of the last 10 seconds of signal, drawn with Canvas so it can redraw many times a second.
private struct Waveform: View {
    let trace: [Double]
    let active: Bool

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            var grid = Path()
            for f in [0.25, 0.5, 0.75] { grid.move(to: CGPoint(x: 0, y: size.height * f)); grid.addLine(to: CGPoint(x: size.width, y: size.height * f)) }
            ctx.stroke(grid, with: .color(.secondary.opacity(0.15)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            guard trace.count > 1 else {
                var flat = Path(); flat.move(to: CGPoint(x: 0, y: mid)); flat.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(flat, with: .color(.secondary.opacity(0.3)), lineWidth: 1.5)
                return
            }
            let total = Int(LiveTremor.traceSeconds * LiveTremor.rate)
            let peak = max(LiveTremor.stillMg * 4, (trace.map(abs).max() ?? 0) * 1.15)
            let dx = size.width / CGFloat(total - 1)
            let offset = CGFloat(total - trace.count) * dx
            var line = Path()
            for (i, v) in trace.enumerated() {
                let p = CGPoint(x: offset + CGFloat(i) * dx, y: mid - CGFloat(v / peak) * mid)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            ctx.stroke(line, with: .linearGradient(Gradient(colors: [.red.opacity(0.35), .red]),
                                                   startPoint: CGPoint(x: offset, y: 0), endPoint: CGPoint(x: size.width, y: 0)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .background(Color(.tertiarySystemFill).opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .opacity(active || !trace.isEmpty ? 1 : 0.6)
        .accessibilityLabel("Live tremor waveform")
    }
}
