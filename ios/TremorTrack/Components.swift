// Shared pieces of the iPhone UI, in the style of Apple's Health app: content on plain grouped backgrounds,
// Liquid Glass only on floating controls (tab bar, toolbar buttons, primary actions).
import Charts
import SwiftUI
import TremorKit

/// A content panel on the grouped background. Content is not glass; glass is for controls that float above it.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }
}

/// A Health-style card header: tinted symbol and title on the left, a detail (usually a time) on the right.
struct CardHeader: View {
    let title: String
    let symbol: String
    var tint: Color = .teal
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Spacer()
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// A large rounded number with a small unit, as in Health and Fitness.
struct BigValue: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit).font(.headline).foregroundStyle(.secondary)
        }
    }
}

/// Scores as a line over a soft gradient fill, with the patient's usual level dashed and doses as small marks.
struct TrendChart: View {
    let points: [(at: Date, score: Double)]
    let usual: Double?
    var doses: [Date] = []
    var tint: Color = .teal
    var height: CGFloat = 90
    var showsAxes = false

    var body: some View {
        Chart {
            ForEach(points, id: \.at) { p in
                AreaMark(x: .value("Time", p.at), yStart: .value("Base", 0), yEnd: .value("Score", p.score))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.at), y: .value("Score", p.score))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(tint)
            }
            if let last = points.last {
                PointMark(x: .value("Time", last.at), y: .value("Score", last.score))
                    .symbolSize(70)
                    .foregroundStyle(tint)
                PointMark(x: .value("Time", last.at), y: .value("Score", last.score))
                    .symbolSize(18)
                    .foregroundStyle(.white)
            }
            if let usual {
                RuleMark(y: .value("Usual", usual))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            ForEach(doses, id: \.self) { d in
                RuleMark(x: .value("Dose", d))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.indigo.opacity(0.35))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(showsAxes ? .automatic : .hidden)
        .chartYAxis(showsAxes ? .automatic : .hidden)
        .frame(height: height)
        .accessibilityLabel("Tremor scores over time")
    }
}

/// An Activity-style ring: the arc fills to the score out of 100, with the number in the middle.
struct ScoreRing: View {
    let score: Double?
    var tint: Color = .teal
    var size: CGFloat = 116
    var lineWidth: CGFloat = 13

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, min(1, (score ?? 0) / 100)))
                .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, (score ?? 0) / 100))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(score == nil ? 0 : 1)
            VStack(spacing: -2) {
                Text(score.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("of 100").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.8), value: score)
    }
}

/// A rounded-square symbol tile, as in Settings and Health's category list.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// A small stat: caption, rounded value, optional note.
struct StatTile: View {
    let title: String
    let value: String
    var note: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
    }
}

/// A capsule label for "Higher than your usual" and similar.
struct StatusPill: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.14), in: .capsule)
    }
}

extension UsualComparison {
    var tint: Color { switch self { case .higher: .orange; case .lower: .green; case .usual: .teal } }
    var symbol: String { switch self { case .higher: "arrow.up.right"; case .lower: "arrow.down.right"; case .usual: "equal" } }
    var short: String { switch self { case .higher: "Above usual"; case .lower: "Below usual"; case .usual: "About usual" } }
}

/// A soft tint behind the large title that fades into the grouped background, like Health's summary.
struct HeaderWash: ViewModifier {
    var tint: Color = .teal
    func body(content: Content) -> some View {
        content.background(alignment: .top) {
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground)
                LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.06), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 380)
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    func headerWash(_ tint: Color = .teal) -> some View { modifier(HeaderWash(tint: tint)) }
}

/// A score with its likely range, or "Not enough data" with the reason. Never a zero for a refusal.
struct ResultSummary: View {
    let display: ScoreDisplay

    var body: some View {
        switch display {
        case let .score(value, low, high):
            VStack(spacing: 6) {
                Text(value.formatted(.number.precision(.fractionLength(0))))
                    .font(.system(size: 80, weight: .semibold, design: .rounded).monospacedDigit())
                Text("Tremor score out of 100").font(.subheadline).foregroundStyle(.secondary)
                if let low, let high {
                    Text("Likely between \(Int(low.rounded())) and \(Int(high.rounded()))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        case let .notEnoughData(reason):
            VStack(spacing: 8) {
                Image(systemName: "waveform.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Not enough data").font(.title2.weight(.semibold))
                Text(reason).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        }
    }
}

struct Disclaimer: View {
    var body: some View {
        Text("Kineon tracks tremor. It doesn't diagnose.")
            .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

extension Source {
    var label: String { self == .watch ? "Apple Watch" : "Phone test" }
    var icon: String { self == .watch ? "applewatch" : "iphone" }
}

extension Date {
    /// "Now", "5 min ago", "Yesterday, 18:20".
    var shortAgo: String {
        let s = Date().timeIntervalSince(self)
        if s < 60 { return "Now" }
        if Calendar.current.isDateInToday(self) { return formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) }
        return formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
