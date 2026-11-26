// Home, laid out like the Health app's summary: the latest tremor reading, today's trend, the watch, and the test.
import SwiftUI
import TremorKit

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var loggingDose = false
    @State private var testing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Greeting(name: model.account?.firstName)
                    if !model.outbox.isEmpty { QueueRow() }
                    TremorCard()
                    if let week = WeekCompare(timeline: model.timeline) {
                        sectionTitle("Highlights")
                        WeekCard(week: week)
                    }
                    sectionTitle("Medication")
                    DoseCard(doses: model.timeline?.doses ?? [], next: model.medical.nextDose()) { loggingDose = true }
                    sectionTitle("Measure")
                    TestRow { testing = true }
                    WatchRow()
                    if model.timeline?.illustrative == true {
                        Label("Illustrative data from an invented demo patient.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 12)
                    }
                    Disclaimer().padding(.top, model.timeline?.illustrative == true ? 0 : 16)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .headerWash()
            .navigationTitle("Summary")
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log dose", systemImage: "pills") { loggingDose = true }
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $loggingDose) { DoseLogView() }
            .navigationDestination(isPresented: $testing) {
                if let api = model.api, let pid = model.patientId {
                    PhoneTestView(api: api, patientId: pid) { r, at in model.notePhoneTest(r, at: at) }
                }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.title3.weight(.bold)).padding(.top, 10).padding(.leading, 4)
    }
}

/// "Good evening, Aniket" under today's date. Updates on the minute so it changes with the time of day.
private struct Greeting: View {
    let name: String?

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 2) {
                Text(ctx.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(name.map { "\(Self.greeting(at: ctx.date)), \($0)" } ?? Self.greeting(at: ctx.date))
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2).minimumScaleFactor(0.8)
            }
            .padding(.leading, 4)
            .padding(.top, 4)
        }
    }

    static func greeting(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }
}

private struct TremorCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let display = model.latest.map { ScoreDisplay($0, source: model.latestSource ?? .watch) }
        Card {
            CardHeader(title: "Tremor", symbol: "waveform.path", detail: model.latestAt?.shortAgo)
            HStack(spacing: 20) {
                switch display {
                case let .score(v, low, high)?:
                    let cmp = UsualComparison(score: v, baseline: model.usual)
                    ScoreRing(score: v, tint: cmp?.tint ?? .teal)
                    VStack(alignment: .leading, spacing: 8) {
                        if let cmp { StatusPill(text: cmp.short, symbol: cmp.symbol, tint: cmp.tint) }
                        if let low, let high {
                            detail("Likely range", "\(Int(low.rounded()))–\(Int(high.rounded()))")
                        }
                        if let usual = model.usual { detail("Your usual", "\(Int(usual.rounded()))") }
                    }
                case let .notEnoughData(reason)?:
                    ScoreRing(score: nil, tint: .secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not enough data").font(.headline)
                        Text(reason).font(.subheadline).foregroundStyle(.secondary)
                    }
                case nil:
                    ScoreRing(score: nil)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No readings yet").font(.headline)
                        Text("Take the 30-second test, or start tracking on your Apple Watch.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            if recent.count >= 2 {
                TrendChart(points: recent, usual: model.usual, doses: recentDoses).padding(.top, 6)
                HStack {
                    Text(recentLabel)
                    Spacer()
                    if model.usual != nil { Text("‒ ‒  Your usual") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
        }
    }

    /// The 24 hours up to the latest reading, so a day without readings still shows the last ones.
    private var end: Date { model.latestAt.map { max($0, Date().addingTimeInterval(-86_400 * 30)) } ?? Date() }
    private var recent: [(at: Date, score: Double)] {
        (model.timeline?.points ?? [])
            .filter { $0.at > end.addingTimeInterval(-86_400) && $0.at <= end && $0.result.status == .ok }
            .compactMap { p in p.result.tremorScore.map { (p.at, $0) } }
            .sorted { $0.at < $1.at }
    }
    private var recentDoses: [Date] {
        (model.timeline?.doses ?? []).map(\.takenAt).filter { $0 > end.addingTimeInterval(-86_400) && $0 <= end }
    }
    private var recentLabel: String {
        Calendar.current.isDateInToday(end) ? "Last 24 hours" : "24 hours to \(end.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }
}

/// This week's average against last week's, as two bars (Health's highlight style).
private struct WeekCompare {
    let this: Double
    let last: Double

    init?(timeline: Timeline?) {
        guard let t = timeline else { return nil }
        let now = Date()
        func avg(_ from: Date, _ to: Date) -> Double? {
            let s = t.points.filter { $0.at >= from && $0.at < to && $0.result.status == .ok }.compactMap(\.result.tremorScore)
            return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
        }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        guard let a = avg(weekAgo, now), let b = avg(weekAgo.addingTimeInterval(-7 * 86_400), weekAgo) else { return nil }
        this = a; last = b
    }

    var cmp: UsualComparison? { UsualComparison(score: this, baseline: last) }
    var sentence: String {
        switch cmp {
        case .higher?: "Your tremor has been higher this week than last week."
        case .lower?: "Your tremor has been lower this week than last week."
        default: "Your tremor this week has been about the same as last week."
        }
    }
}

private struct WeekCard: View {
    let week: WeekCompare

    var body: some View {
        Card {
            CardHeader(title: "Tremor", symbol: "waveform.path", detail: "Weekly average")
            Text(week.sentence).font(.headline)
            VStack(spacing: 10) {
                bar("This week", week.this, tint: week.cmp?.tint ?? .teal)
                bar("Last week", week.last, tint: Color(.systemGray3))
            }
            .padding(.top, 4)
        }
    }

    private func bar(_ label: String, _ v: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(v.rounded()))").font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
                Text("avg").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                Capsule().fill(tint.gradient).frame(width: max(12, g.size.width * v / 100))
            }
            .frame(height: 10)
        }
    }
}

private struct DoseCard: View {
    let doses: [DoseEvent]
    let next: (name: String, at: Date)?
    let log: () -> Void

    private var today: [DoseEvent] {
        doses.filter { Calendar.current.isDateInToday($0.takenAt) }.sorted { $0.takenAt < $1.takenAt }
    }

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(symbol: "pills.fill", tint: .indigo)
                VStack(alignment: .leading, spacing: 1) {
                    if let last = today.last {
                        Text(last.label).font(.headline)
                        Text("Last taken \(last.takenAt.shortAgo.lowercased())").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("No dose logged today").font(.headline)
                        Text("Logging doses shows how tremor follows them").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button("Log", systemImage: "plus", action: log)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .tint(.indigo)
                    .accessibilityLabel("Log dose")
            }
            DayStrip(doses: today.map(\.takenAt)).padding(.top, 6)
            if let next {
                Divider()
                HStack {
                    Label("Next", systemImage: "clock").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(next.name) at \(next.at.formatted(date: .omitted, time: .shortened))").fontWeight(.medium)
                }
                .font(.subheadline)
            }
            if let tags = today.last?.tags, !tags.isEmpty {
                Text(tags.map(\.title).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Today from midnight to midnight, with a dot per dose and a marker for now.
private struct DayStrip: View {
    let doses: [Date]

    var body: some View {
        let start = Calendar.current.startOfDay(for: Date())
        VStack(spacing: 4) {
            GeometryReader { g in
                let x = { (d: Date) in g.size.width * min(1, max(0, d.timeIntervalSince(start) / 86_400)) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemFill)).frame(height: 6)
                    Capsule().fill(Color.indigo.opacity(0.25)).frame(width: x(Date()), height: 6)
                    ForEach(doses, id: \.self) { d in
                        Circle().fill(.indigo).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2.5))
                            .offset(x: x(d) - 7)
                    }
                }
                .frame(height: 14)
            }
            .frame(height: 14)
            HStack {
                Text("12 am"); Spacer(); Text("6 am"); Spacer(); Text("12 pm"); Spacer(); Text("6 pm"); Spacer(); Text("12 am")
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(doses.count) doses today")
    }
}

/// A tappable row like the ones in Health's "Get More from Health" section.
private struct RowCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
        .contentShape(.rect)
    }
}

private struct TestRow: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            RowCard(symbol: "hand.raised.fill", tint: .teal, title: "30-second tremor test",
                    subtitle: "Rest your arm and hold the phone")
        }
        .buttonStyle(.plain)
    }
}

private struct WatchRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let w = model.watch
        let subtitle: String =
            if !w.paired { "Pair an Apple Watch to measure through the day" }
            else if !w.watchAppInstalled { "Install Kineon from the Watch app" }
            else if let last = model.lastWatchWindowAt { "Last reading \(last.shortAgo.lowercased())" }
            else if w.reachable { "Connected. Start tracking on the watch." }
            else { "Not in range. Readings are kept on the watch." }
        RowCard(symbol: "applewatch", tint: w.watchAppInstalled ? .green : .gray,
                title: "Apple Watch", subtitle: subtitle, showsChevron: false)
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.outbox.count) waiting to upload").font(.subheadline.weight(.semibold))
                Text("Saved on this iPhone. They'll send when the server is back.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Retry") { Task { await model.drain() } }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }
}
