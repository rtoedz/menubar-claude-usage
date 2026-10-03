import Foundation

struct UsageSample: Codable {
    let t: TimeInterval
    let session: Double
    let weekly: Double
}

enum UsageProjection {
    enum Outcome: Equatable {
        case collecting
        case idle
        case limitReached
        case lastsPastReset(projectedAtReset: Double)
        case hitsLimit(in: TimeInterval)
    }

    /// Fits a line through the last 45 minutes of session samples and extrapolates.
    /// `samples` must already be restricted to the current session window.
    static func evaluate(samples: [UsageSample], now: Date, resetsAt: Date) -> Outcome {
        guard let last = samples.last else { return .collecting }
        if last.session >= 100 { return .limitReached }

        let cutoff = now.timeIntervalSince1970 - 45 * 60
        let recent = samples.filter { $0.t >= cutoff }
        guard recent.count >= 2,
              let first = recent.first,
              last.t - first.t >= 300
        else { return .collecting }

        let n = Double(recent.count)
        let meanT = recent.map(\.t).reduce(0, +) / n
        let meanP = recent.map(\.session).reduce(0, +) / n
        var num = 0.0, den = 0.0
        for s in recent {
            num += (s.t - meanT) * (s.session - meanP)
            den += (s.t - meanT) * (s.t - meanT)
        }
        guard den > 0 else { return .collecting }

        let perSecond = num / den
        if perSecond * 3600 < 0.1 { return .idle }

        let secondsToLimit = (100 - last.session) / perSecond
        let hitAt = last.t + secondsToLimit
        if hitAt > resetsAt.timeIntervalSince1970 {
            let projected = last.session + perSecond * (resetsAt.timeIntervalSince1970 - last.t)
            return .lastsPastReset(projectedAtReset: min(projected, 100))
        }
        return .hitsLimit(in: max(0, hitAt - now.timeIntervalSince1970))
    }
}

@MainActor
final class UsageHistoryStore {
    private static let retention: TimeInterval = 7 * 24 * 3600
    private static let minGap: TimeInterval = 30

    private let fileURL: URL?
    private(set) var samples: [UsageSample] = []

    init(persistent: Bool = true, fileName: String = "history.json") {
        guard persistent,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            fileURL = nil
            return
        }
        let dir = base.appendingPathComponent("ClaudeUsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        fileURL = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([UsageSample].self, from: data) {
            samples = decoded
        }
    }

    func seed(_ seeded: [UsageSample]) {
        samples = seeded
    }

    func record(session: Double, weekly: Double, at date: Date = Date()) {
        let t = date.timeIntervalSince1970
        if let last = samples.last, t - last.t < Self.minGap { return }
        samples.append(UsageSample(t: t, session: session, weekly: weekly))
        let cutoff = t - Self.retention
        samples.removeAll { $0.t < cutoff }
        save()
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
