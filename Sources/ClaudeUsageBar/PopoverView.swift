import SwiftUI

// ─── Design tokens ────────────────────────────────────────────────────────────

private let bgMain   = Color(red: 0.08, green: 0.08, blue: 0.10)
private let bgCard   = Color(red: 0.14, green: 0.14, blue: 0.17)

private let clGreen  = Color(red: 0.20, green: 0.84, blue: 0.29)
private let clOrange = Color(red: 1.00, green: 0.62, blue: 0.04)
private let clRed    = Color(red: 1.00, green: 0.27, blue: 0.23)

private let popoverWidth: CGFloat = 320

/// `CUB_RENDER` snapshots can't draw a SwiftUI Menu, so a static gear stands in.
private let snapshotMode = ProcessInfo.processInfo.environment["CUB_RENDER"] != nil

/// Colour by usage level; an API `severity` that says otherwise wins.
private func usageColor(_ pct: Double, severity: String? = nil) -> Color {
    if let s = severity?.lowercased() {
        if s.contains("crit") || s.contains("danger") || s.contains("high") { return clRed }
        if s.contains("warn") || s.contains("elev") { return clOrange }
    }
    if pct >= 86 { return clRed }
    if pct >= 61 { return clOrange }
    return clGreen
}

private extension View {
    func card(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(bgCard))
    }
}

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.4))
            .tracking(1.1)
    }
}

// ─── Progress bar ─────────────────────────────────────────────────────────────

private struct UsageBar: View {
    let percent: Double
    let active: Bool
    var color: Color? = nil
    var marker: Double? = nil
    var height: CGFloat = 6

    var body: some View {
        let tint = color ?? usageColor(percent)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                if active {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.65), tint],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geo.size.width * min(percent, 100) / 100))
                }
                if let marker {
                    Capsule()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 2, height: height + 4)
                        .offset(x: geo.size.width * min(max(marker, 0), 100) / 100 - 1)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 4)
    }
}

// ─── Session ring ─────────────────────────────────────────────────────────────

private struct RingGauge: View {
    let percent: Double
    let active: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: 9)
            if active {
                Circle()
                    .trim(from: 0, to: max(0.015, min(percent, 100) / 100))
                    .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: percent)
            }
            VStack(spacing: 0) {
                Text(active ? "\(Int(percent.rounded()))%" : "—")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(active ? color : .white.opacity(0.25))
                Text("5H LIMIT")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                    .tracking(0.9)
            }
        }
        .frame(width: 92, height: 92)
    }
}

// ─── Chart frame: 0–100% axis + gridlines, shared by both trend charts ────────

private let chartLeading: CGFloat = 32

private struct ChartFrame<Content: View>: View {
    static var height: CGFloat { 96 }
    private static var levels: [Int] { [100, 80, 60, 40, 20, 0] }

    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            GeometryReader { geo in
                ForEach(Self.levels, id: \.self) { level in
                    Text("\(level)%")
                        .font(.system(size: 8, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.3))
                        .frame(width: 26, alignment: .trailing)
                        .position(x: 13, y: min(max(geo.size.height * (1 - CGFloat(level) / 100), 5), geo.size.height - 5))
                }
            }
            .frame(width: 26, height: Self.height)

            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    ForEach(Self.levels, id: \.self) { level in
                        let y = min(max(size.height * (1 - CGFloat(level) / 100), 0.5), size.height - 0.5)
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        .stroke(Color.white.opacity(level == 0 ? 0.12 : 0.06),
                                style: StrokeStyle(lineWidth: 1, dash: level == 0 ? [] : [2, 4]))
                    }
                    content(size)
                }
            }
            .frame(height: Self.height)
        }
    }
}

private struct ShowMoreButton: View {
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? "Show less" : "Show more")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.4))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// ─── Sparkline (session window) ───────────────────────────────────────────────

private struct Sparkline: View {
    let samples: [UsageSample]
    let window: ClosedRange<Date>
    let projection: UsageProjection.Outcome
    let color: Color

    private func point(_ t: TimeInterval, _ pct: Double, in size: CGSize) -> CGPoint {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let x = (t - window.lowerBound.timeIntervalSince1970) / span
        return CGPoint(x: size.width * CGFloat(min(max(x, 0), 1)),
                       y: size.height * (1 - CGFloat(min(max(pct, 0), 100)) / 100))
    }

    private func projectionEnd(from last: UsageSample) -> (t: TimeInterval, pct: Double)? {
        switch projection {
        case .hitsLimit(let secs):
            return (Date().timeIntervalSince1970 + secs, 100)
        case .lastsPastReset(let pct):
            return (window.upperBound.timeIntervalSince1970, pct)
        default:
            return nil
        }
    }

    var body: some View {
        ChartFrame { size in
            if samples.count >= 2, let last = samples.last {
                let pts = samples.map { point($0.t, $0.session, in: size) }

                Path { p in
                    p.move(to: CGPoint(x: pts[0].x, y: size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))

                Path { p in
                    p.move(to: pts[0])
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                if let end = projectionEnd(from: last) {
                    Path { p in
                        p.move(to: pts.last!)
                        p.addLine(to: point(end.t, end.pct, in: size))
                    }
                    .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }

                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .position(pts.last!)
            } else {
                Text("Collecting history…")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// ─── Projection line ──────────────────────────────────────────────────────────

private struct ProjectionLine: View {
    let outcome: UsageProjection.Outcome

    private var content: (icon: String, text: String, color: Color) {
        switch outcome {
        case .collecting:
            return ("waveform", "Learning your pace…", .white.opacity(0.35))
        case .idle:
            return ("moon.zzz", "Idle — no recent usage", .white.opacity(0.45))
        case .limitReached:
            return ("exclamationmark.octagon.fill", "5-hour limit reached", clRed)
        case .lastsPastReset:
            return ("checkmark.circle.fill", "Lasts past reset", clGreen)
        case .hitsLimit(let secs):
            let urgent = secs < 30 * 60
            return ("flame.fill", "~\(UsageManager.duration(secs)) to limit", urgent ? clRed : clOrange)
        }
    }

    var body: some View {
        let c = content
        HStack(spacing: 5) {
            Image(systemName: c.icon).font(.system(size: 10))
            Text(c.text).font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(c.color)
    }
}

// ─── Cards ────────────────────────────────────────────────────────────────────

private struct TrendCaption: View {
    let window: ClosedRange<Date>
    let color: Color

    private func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Window started \(time(window.lowerBound))")
                Spacer()
                Text("Resets \(time(window.upperBound))")
            }
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.3))

            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Capsule().fill(color).frame(width: 12, height: 2)
                    Text("Used so far")
                }
                HStack(spacing: 5) {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 1))
                        p.addLine(to: CGPoint(x: 12, y: 1))
                    }
                    .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .frame(width: 12, height: 2)
                    Text("Forecast at your current pace")
                }
            }
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.4))
        }
    }
}

private struct WeeklyCaption: View {
    let window: ClosedRange<Date>
    let color: Color

    private var dayStart: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: window.lowerBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Capsule().fill(color).frame(width: 12, height: 2)
                    Text("Used so far")
                }
                HStack(spacing: 5) {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 1))
                        p.addLine(to: CGPoint(x: 12, y: 1))
                    }
                    .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .frame(width: 12, height: 2)
                    Text("Even pace")
                }
            }
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.4))

            Text("Numbers show how much of your weekly limit each day used. Days start at the weekly reset (\(dayStart)); days before the app was running show –.")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.3))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WaitingCard: View {
    let failed: Bool
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: failed ? "wifi.exclamationmark" : "hourglass")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(failed ? clOrange : .white.opacity(0.4))
            Text(failed ? "Couldn't load usage yet" : "Loading usage…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            if failed {
                Text(isLoading ? "Retrying…" : "Retries automatically every 2 minutes, or tap refresh.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: 14).fill(bgCard))
    }
}

private struct SessionCard: View {
    @ObservedObject var manager: UsageManager
    @AppStorage("showTrend") private var showTrend = false

    var body: some View {
        let usage = manager.usage
        let color = usageColor(usage.sessionPercent, severity: usage.sessionSeverity)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                RingGauge(percent: usage.sessionPercent, active: usage.sessionActive, color: color)

                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "5-HOUR LIMIT")
                    if usage.sessionActive {
                        Text(usage.sessionResetIn)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.white.opacity(0.9))
                        Text("until reset")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                        ProjectionLine(outcome: manager.projection)
                            .padding(.top, 2)
                    } else {
                        Text("No active 5-hour window")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                        Text("Start a conversation to begin tracking")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            if usage.sessionActive, let window = manager.sessionWindow {
                ShowMoreButton(expanded: $showTrend)

                if showTrend {
                    Sparkline(samples: manager.sessionSamples, window: window,
                              projection: manager.projection, color: color)
                    TrendCaption(window: window, color: color)
                }
            }
        }
        .card()
    }
}

private struct WeeklyChart: View {
    let samples: [UsageSample]
    let window: ClosedRange<Date>
    let color: Color

    private func point(_ t: TimeInterval, _ pct: Double, in size: CGSize) -> CGPoint {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let x = (t - window.lowerBound.timeIntervalSince1970) / span
        return CGPoint(x: size.width * CGFloat(min(max(x, 0), 1)),
                       y: size.height * (1 - CGFloat(min(max(pct, 0), 100)) / 100))
    }

    var body: some View {
        ChartFrame { size in
            ForEach(1..<7, id: \.self) { day in
                Path { p in
                    p.move(to: CGPoint(x: size.width * CGFloat(day) / 7, y: 0))
                    p.addLine(to: CGPoint(x: size.width * CGFloat(day) / 7, y: size.height))
                }
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }

            Path { p in
                p.move(to: CGPoint(x: 0, y: size.height))
                p.addLine(to: CGPoint(x: size.width, y: 0))
            }
            .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            if samples.count >= 2 {
                let pts = samples.map { point($0.t, $0.weekly, in: size) }

                Path { p in
                    p.move(to: CGPoint(x: pts[0].x, y: size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))

                Path { p in
                    p.move(to: pts[0])
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                Circle().fill(color).frame(width: 6, height: 6).position(pts.last!)
            } else {
                Text("Collecting history…")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct WeeklyDaysRow: View {
    let days: [DayUsage]

    private func label(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func value(_ day: DayUsage) -> String {
        guard let delta = day.delta else { return day.isFuture ? "" : "–" }
        return delta < 0.5 ? "0%" : "+\(Int(delta.rounded()))%"
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                VStack(spacing: 2) {
                    Text(label(day.start))
                        .font(.system(size: 9, weight: day.isToday ? .bold : .medium))
                        .foregroundColor(.white.opacity(day.isToday ? 0.8 : 0.4))
                    Text(value(day))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(day.delta == nil ? .white.opacity(0.2) : .white.opacity(day.isToday ? 0.9 : 0.65))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(day.isToday ? 0.07 : 0)))
            }
        }
        .padding(.leading, chartLeading)
    }
}

private struct WeeklyCard: View {
    @ObservedObject var manager: UsageManager
    @AppStorage("showWeeklyTrend") private var showTrend = false

    private var paceNote: String? {
        let usage = manager.usage
        guard let pace = manager.weeklyPacePercent, let perDay = manager.weeklyPerDayLeft else { return nil }
        let status = usage.weeklyPercent > pace + 10 ? "Ahead of pace"
            : usage.weeklyPercent < pace - 10 ? "Under pace" : "On pace"
        return "\(status) · ~\(Int(perDay.rounded()))%/day left"
    }

    var body: some View {
        let usage = manager.usage
        let color = usageColor(usage.weeklyPercent, severity: usage.weeklySeverity)

        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "WEEKLY")
                Spacer()
                Text(usage.weeklyActive ? "\(Int(usage.weeklyPercent.rounded()))%" : "0%")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(usage.weeklyActive ? color : .white.opacity(0.2))
            }
            UsageBar(percent: usage.weeklyPercent, active: usage.weeklyActive,
                     color: color, marker: manager.weeklyPacePercent)
            if usage.weeklyActive {
                HStack {
                    Text("Resets \(usage.weeklyResetsAt)")
                    Spacer()
                    if let paceNote { Text(paceNote) }
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
            } else {
                Label("No weekly usage recorded yet", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.28))
            }

            if usage.weeklyActive, let window = manager.weeklyWindow {
                ShowMoreButton(expanded: $showTrend)

                if showTrend {
                    WeeklyChart(samples: manager.weeklySamples, window: window, color: color)
                    WeeklyDaysRow(days: manager.weeklyDays)
                    WeeklyCaption(window: window, color: color)
                }
            }
        }
        .card()
    }
}

private struct LimitRowsCard: View {
    let rows: [LimitRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                        Spacer()
                        Text("\(Int(row.percent.rounded()))%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(usageColor(row.percent, severity: row.severity))
                    }
                    UsageBar(percent: row.percent, active: row.active || row.percent > 0,
                             color: usageColor(row.percent, severity: row.severity), height: 4)
                    if let reset = row.resetsAt {
                        Text("Resets \(UsageManager.absoluteReset(reset))")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .card()
    }
}

private struct CreditsCard: View {
    let credits: CreditsInfo?
    let allowance: AllowanceInfo?

    private func dollars(_ v: Double) -> String {
        v.rounded() == v ? "$\(Int(v))" : String(format: "$%.2f", v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let credits {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        SectionLabel(text: "USAGE CREDITS")
                        Spacer()
                        Text(credits.enabled ? "ON" : "OFF")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(credits.enabled ? .black : .white.opacity(0.5))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(credits.enabled ? clGreen : Color.white.opacity(0.1)))
                    }
                    if credits.enabled {
                        let spent = credits.spent ?? "$0.00"
                        Text(credits.limit.map { "\(spent) of \($0) spent" } ?? "\(spent) spent")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.8))
                        if credits.limitReached {
                            Label("Spend limit reached", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(clRed)
                        }
                    } else {
                        Text("Covers you when you hit plan limits")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
            if let allowance {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel(text: "ALLOWANCE")
                        Spacer()
                        Text("\(dollars(allowance.used)) / \(dollars(allowance.limit))")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.white.opacity(0.75))
                    }
                    let pct = allowance.used / allowance.limit * 100
                    UsageBar(percent: pct, active: pct > 0, height: 4)
                    if let reset = allowance.resetsAt {
                        Text("Resets \(UsageManager.absoluteReset(reset))")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .card()
    }
}

// ─── Setup screen ─────────────────────────────────────────────────────────────
// Shown when no Claude Code OAuth token is found. The app reads usage from the
// credentials that Claude Code (CLI or VS Code extension) writes after sign-in,
// so the fix is to install one of those — not to log in on the web.

private struct SetupStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(clOrange)
                .frame(width: 20, height: 20)
                .background(Circle().fill(clOrange.opacity(0.15)))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct SetupView: View {
    let onRetry: () -> Void

    private static let claudeCodeURL = URL(string: "https://claude.com/claude-code")!
    private static let extensionURL = URL(string: "https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code")!

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill(clOrange.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(clOrange)
            }
            .padding(.bottom, 16)

            Text("Connect Claude Code")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 6)

            Text("Usage is read from Claude Code. Install it — or the VS Code extension — and sign in to start tracking.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 12) {
                SetupStep(number: 1, text: "Install Claude Code or the VS Code extension")
                SetupStep(number: 2, text: "Sign in with your Claude account")
                SetupStep(number: 3, text: "Click Try Again below")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(bgCard))
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Button {
                NSWorkspace.shared.open(Self.claudeCodeURL)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Install Claude Code")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(clOrange))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Button {
                NSWorkspace.shared.open(Self.extensionURL)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension.fill")
                    Text("Get VS Code Extension")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(bgCard))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Button("Try Again", action: onRetry)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Spacer(minLength: 12)
        }
        .frame(width: popoverWidth, height: 440)
        .background(bgMain)
    }
}

// ─── Expired / locked screen ──────────────────────────────────────────────────
// Shown when credentials exist but the token is rejected (401) or can't be read
// (Keychain locked). The user is still signed in — the token just needs a refresh,
// which Claude Code does automatically the next time it runs.

private struct ExpiredView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill(clOrange.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(clOrange)
            }
            .padding(.bottom, 16)

            Text("Session expired")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 6)

            Text("Your Claude Code token expired or the Keychain is locked. Run any Claude Code command to refresh it, then try again.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)

            Button(action: onRetry) {
                Text("Try Again")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(clOrange))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)

            Spacer(minLength: 12)
        }
        .frame(width: popoverWidth, height: 440)
        .background(bgMain)
    }
}

// ─── Popover root ─────────────────────────────────────────────────────────────

private enum PopoverTab: String, CaseIterable, Identifiable {
    case usage, models

    var id: String { rawValue }
    var label: String { self == .usage ? "Usage" : "Models" }
}

// ─── Tabs ─────────────────────────────────────────────────────────────────────

private struct TabBar: View {
    @Binding var selection: PopoverTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PopoverTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(selection == tab ? .white.opacity(0.9) : .white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(selection == tab ? Color.white.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(bgCard))
    }
}

// ─── Models tab ───────────────────────────────────────────────────────────────

private func formatTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1_000_000_000)
    case 1_000_000...:     return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...:         return String(format: "%.1fK", Double(n) / 1_000)
    default:               return "\(n)"
    }
}

private func percentText(_ fraction: Double) -> String {
    let pct = fraction * 100
    return pct > 0 && pct < 1 ? "<1%" : "\(Int(pct.rounded()))%"
}

private func modelColor(_ name: String) -> Color {
    let family = name.lowercased()
    if family.hasPrefix("opus") { return Color(red: 0.69, green: 0.52, blue: 1.00) }
    if family.hasPrefix("sonnet") { return Color(red: 0.35, green: 0.65, blue: 1.00) }
    if family.hasPrefix("haiku") { return Color(red: 0.20, green: 0.80, blue: 0.70) }
    if family.hasPrefix("fable") { return Color(red: 1.00, green: 0.45, blue: 0.65) }
    return Color.white.opacity(0.45)
}

private struct RangePicker: View {
    @Binding var selection: ModelRange

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ModelRange.allCases) { range in
                Button {
                    selection = range
                } label: {
                    Text(range.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(selection == range ? .black : .white.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(selection == range ? Color.white.opacity(0.85) : Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

private struct ModelsTab: View {
    @ObservedObject var manager: UsageManager
    @AppStorage("modelRange") private var range: ModelRange = .fiveHour
    @State private var showAllProjects = false

    private static let projectPreview = 3

    private func since(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return "since \(f.string(from: date))"
    }

    var body: some View {
        let summary = manager.modelsSummary(range)

        VStack(alignment: .leading, spacing: 10) {
            RangePicker(selection: $range)

            if !manager.modelsLoadedOnce {
                IndexingCard(progress: manager.indexProgress)
            } else if summary.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.3))
                    Text("No Claude Code activity")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                    Text(since(manager.modelRangeStart(range)))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(RoundedRectangle(cornerRadius: 14).fill(bgCard))
            } else {
                totals(summary)
                modelsCard(summary)
                if !summary.projects.isEmpty { projectsCard(summary) }
                statsCard(summary)
            }

            HStack(spacing: 5) {
                if manager.modelsIndexing && manager.modelsLoadedOnce {
                    ProgressView().controlSize(.mini)
                    Text("Updating…")
                } else {
                    Text(manager.multipleAccounts
                         ? "Claude Code activity on this Mac, all accounts"
                         : "Claude Code activity on this Mac only")
                }
            }
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.28))
        }
        .onAppear { manager.refreshModels() }
    }

    private func totals(_ s: ModelsSummary) -> some View {
        let fresh = s.total.input + s.total.output + s.total.cacheCreate
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(formatTokens(s.total.total))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.92))
                Text("tokens")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(s.total.requests) requests")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Text(since(manager.modelRangeStart(range)))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            Text("New \(formatTokens(fresh)) · Cached \(formatTokens(s.total.cacheRead))")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
        }
        .card()
    }

    private func modelsCard(_ s: ModelsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "MODELS")
            ForEach(s.models) { row in
                let share = s.total.total > 0 ? Double(row.counts.total) / Double(s.total.total) : 0
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Circle().fill(modelColor(row.name)).frame(width: 7, height: 7)
                        Text(row.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text(formatTokens(row.counts.total))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.white.opacity(0.8))
                        Text(percentText(share))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundColor(.white.opacity(0.35))
                            .frame(width: 30, alignment: .trailing)
                    }
                    UsageBar(percent: share * 100, active: true, color: modelColor(row.name), height: 4)
                    Text("\(row.counts.requests) requests")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.28))
                }
            }
        }
        .card()
    }

    private func projectsCard(_ s: ModelsSummary) -> some View {
        let shown = showAllProjects ? Array(s.projects.prefix(8)) : Array(s.projects.prefix(Self.projectPreview))
        let maxTokens = max(s.projects.first?.tokens ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "PROJECTS")
            ForEach(shown) { project in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(project.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(formatTokens(project.tokens))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.white.opacity(0.7))
                    }
                    UsageBar(percent: Double(project.tokens) / Double(maxTokens) * 100, active: true,
                             color: .white.opacity(0.4), height: 3)
                }
            }
            if s.projects.count > Self.projectPreview {
                ShowMoreButton(expanded: $showAllProjects)
            }
        }
        .card()
    }

    private func statsCard(_ s: ModelsSummary) -> some View {
        let stats: [(String, Double?)] = [
            ("CACHE HIT", s.cacheHitRate),
            ("THINKING", s.thinkingShare),
            ("SUBAGENTS", s.subagentShare),
        ]
        return HStack(spacing: 0) {
            ForEach(stats.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: stats[i].0)
                    Text(stats[i].1.map(percentText) ?? "–")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }
}

private struct IndexingCard: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(clGreen)
                .frame(maxWidth: 180)
            Text("Reading your Claude Code history…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            Text("First run only — later updates take a moment.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(RoundedRectangle(cornerRadius: 14).fill(bgCard))
    }
}

private struct UsageContent: View {
    @ObservedObject var manager: UsageManager
    @AppStorage("popoverTab") private var tab: PopoverTab = .usage

    private var usage: UsageData { manager.usage }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Header
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Claude Usage")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    if let plan = manager.plan {
                        Text(plan.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .foregroundColor(clOrange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(clOrange.opacity(0.15)))
                    }
                    Spacer()
                    Button {
                        Task { await manager.fetch(force: true) }
                    } label: {
                        if manager.isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .tint(.white.opacity(0.8))
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .buttonStyle(.plain)
                }
                if manager.multipleAccounts, let name = manager.accountName {
                    Label(name, systemImage: "person.crop.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            .padding(.bottom, 2)

            TabBar(selection: $tab)

            if tab == .models {
                ModelsTab(manager: manager)
            } else if manager.hasLoaded {
                SessionCard(manager: manager)
                WeeklyCard(manager: manager)

                if !usage.extraRows.isEmpty {
                    LimitRowsCard(rows: usage.extraRows)
                }
                if usage.credits != nil || usage.allowance != nil {
                    CreditsCard(credits: usage.credits, allowance: usage.allowance)
                }
            } else {
                WaitingCard(failed: manager.errorMessage != nil || manager.rateLimitedUntil != nil, isLoading: manager.isLoading)
            }

            if let until = manager.rateLimitedUntil, until > Date() {
                Label("Rate limited by Anthropic — retrying in \(UsageManager.duration(until.timeIntervalSinceNow))",
                      systemImage: "clock")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = manager.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(clRed.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Footer
            HStack(spacing: 10) {
                Text("Updated \(usage.lastUpdated)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.28))
                Spacer()
                if snapshotMode {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                } else {
                    Menu {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { manager.launchAtLogin },
                            set: { manager.setLaunchAtLogin($0) }
                        ))
                        Picker("Menu Bar Shows", selection: $manager.titleMode) {
                            ForEach(TitleMode.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(width: popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(bgMain)
    }
}

struct PopoverView: View {
    @ObservedObject var manager: UsageManager
    /// Reports the content height so the host can resize the popover itself.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        Group {
            if manager.tokenMissing {
                SetupView { Task { await manager.fetch(force: true) } }
            } else if manager.tokenExpired {
                ExpiredView { Task { await manager.fetch(force: true) } }
            } else {
                UsageContent(manager: manager)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if height > 0 { onHeightChange(height) }
        }
    }
}
