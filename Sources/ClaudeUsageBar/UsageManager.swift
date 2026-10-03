import Foundation
import ServiceManagement
// import UserNotifications — disabled, see MARK: Notifications

// ─── Raw API shape ───────────────────────────────────────────────────────────
// Mirrors https://api.anthropic.com/api/oauth/usage (the same endpoint that
// claudeusage-mcp wraps). The endpoint is undocumented and carries many
// obfuscated keys, so every optional section is decoded with `try?` — an
// unexpected shape must never take the whole response down.

private struct RawWindow: Decodable {
    let utilization: Double?
    let resets_at: String?
    let limit_dollars: Double?
    let used_dollars: Double?
}

private struct RawLimit: Decodable {
    let kind: String
    let percent: Double?
    let severity: String?
    let resets_at: String?
    let is_active: Bool?
}

private struct RawMoney: Decodable {
    let amount_minor: Double?
    let currency: String?
    let exponent: Int?
}

private struct RawSpend: Decodable {
    let used: RawMoney?
    let limit: RawMoney?
    let balance: RawMoney?
    let enabled: Bool?
}

private struct RawExtraUsage: Decodable {
    let is_enabled: Bool?
    let spend_limit_reached: Bool?
}

private struct RawUsageResponse: Decodable {
    let five_hour: RawWindow
    let seven_day: RawWindow
    let seven_day_opus: RawWindow?
    let seven_day_sonnet: RawWindow?
    let seven_day_cowork: RawWindow?
    let seven_day_oauth_apps: RawWindow?
    let iguana_necktie: RawWindow?
    let extra_usage: RawExtraUsage?
    let limits: [RawLimit]?
    let spend: RawSpend?

    private enum CodingKeys: String, CodingKey {
        case five_hour, seven_day, seven_day_opus, seven_day_sonnet, seven_day_cowork
        case seven_day_oauth_apps, iguana_necktie, extra_usage, limits, spend
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        five_hour = try c.decode(RawWindow.self, forKey: .five_hour)
        seven_day = try c.decode(RawWindow.self, forKey: .seven_day)
        seven_day_opus = try? c.decodeIfPresent(RawWindow.self, forKey: .seven_day_opus)
        seven_day_sonnet = try? c.decodeIfPresent(RawWindow.self, forKey: .seven_day_sonnet)
        seven_day_cowork = try? c.decodeIfPresent(RawWindow.self, forKey: .seven_day_cowork)
        seven_day_oauth_apps = try? c.decodeIfPresent(RawWindow.self, forKey: .seven_day_oauth_apps)
        iguana_necktie = try? c.decodeIfPresent(RawWindow.self, forKey: .iguana_necktie)
        extra_usage = try? c.decodeIfPresent(RawExtraUsage.self, forKey: .extra_usage)
        limits = try? c.decodeIfPresent([RawLimit].self, forKey: .limits)
        spend = try? c.decodeIfPresent(RawSpend.self, forKey: .spend)
    }
}

// ─── Display model ───────────────────────────────────────────────────────────

struct LimitRow: Identifiable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?
    let active: Bool
    let severity: String?
}

struct CreditsInfo {
    var enabled: Bool
    var spent: String?
    var limit: String?
    var balance: String?
    var limitReached: Bool
}

struct AllowanceInfo {
    var used: Double
    var limit: Double
    var resetsAt: Date?
}

/// One day of the weekly window (days start at the weekly reset time).
struct DayUsage: Identifiable {
    let id: Int
    let start: Date
    /// Percentage points of the weekly limit used that day; nil when nothing was recorded.
    let delta: Double?
    let isToday: Bool
    let isFuture: Bool
}

enum ModelRange: String, CaseIterable, Identifiable {
    case fiveHour, today, week

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveHour: return "5h"
        case .today:    return "Today"
        case .week:     return "Week"
        }
    }
}

enum TitleMode: String, CaseIterable, Identifiable {
    case session, weekly, worst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: return "5-hour limit"
        case .weekly:  return "Weekly"
        case .worst:   return "Highest of both"
        }
    }
}

struct UsageData {
    var sessionPercent: Double      // 61.0
    var sessionResetIn: String      // "2h 8m"
    var sessionActive: Bool         // false when resets_at is nil (no active session)
    var sessionSeverity: String?
    var weeklyPercent: Double       // 14.0
    var weeklyResetsAt: String      // "Sat 9:00 AM"
    var weeklyResetIn: String       // "6d 3h"
    var weeklyActive: Bool          // false when resets_at is nil
    var weeklySeverity: String?
    var extraRows: [LimitRow]
    var credits: CreditsInfo?
    var allowance: AllowanceInfo?
    var lastUpdated: String         // "just now"

    /// Shown before the first successful fetch.
    static let placeholder = UsageData(
        sessionPercent: 0, sessionResetIn: "—", sessionActive: false, sessionSeverity: nil,
        weeklyPercent: 0, weeklyResetsAt: "—", weeklyResetIn: "—", weeklyActive: false,
        weeklySeverity: nil, extraRows: [], credits: nil, allowance: nil,
        lastUpdated: "never"
    )

    /// Used by `CUB_MOCK=1` so the UI is testable without a live fetch.
    static let mock = UsageData(
        sessionPercent: 61, sessionResetIn: "2h 8m", sessionActive: true, sessionSeverity: nil,
        weeklyPercent: 38, weeklyResetsAt: "Sat 9:00 AM", weeklyResetIn: "3d 4h",
        weeklyActive: true, weeklySeverity: nil,
        extraRows: [
            LimitRow(id: "opus", title: "Opus · weekly", percent: 72,
                     resetsAt: Date().addingTimeInterval(3 * 86400), active: true, severity: nil),
            LimitRow(id: "sonnet", title: "Sonnet · weekly", percent: 21,
                     resetsAt: Date().addingTimeInterval(3 * 86400), active: true, severity: nil),
        ],
        credits: CreditsInfo(enabled: true, spent: "$4.20", limit: "$20.00",
                             balance: nil, limitReached: false),
        allowance: AllowanceInfo(used: 12, limit: 100,
                                 resetsAt: Date().addingTimeInterval(30 * 86400)),
        lastUpdated: "mock data"
    )

    /// 🟢 0–60 · 🟠 61–85 · 🔴 86–100
    static func emoji(for percent: Double) -> String {
        if percent >= 86 { return "🔴" }
        if percent >= 61 { return "🟠" }
        return "🟢"
    }

    private var sessionTitle: String {
        "\(Self.emoji(for: sessionPercent)) \(Int(sessionPercent.rounded()))% · \(sessionResetIn)"
    }

    private var weeklyTitle: String {
        "\(Self.emoji(for: weeklyPercent)) \(Int(weeklyPercent.rounded()))% wk · \(weeklyResetIn.split(separator: " ").first ?? "")"
    }

    /// e.g. "🟠 61% · 2h 8m", or "○ No 5h limit" when nothing is active.
    func menuBarTitle(_ mode: TitleMode) -> String {
        switch mode {
        case .session:
            return sessionActive ? sessionTitle : "○ No 5h limit"
        case .weekly:
            return weeklyActive ? weeklyTitle : "○ No 5h limit"
        case .worst:
            switch (sessionActive, weeklyActive) {
            case (true, true):   return weeklyPercent > sessionPercent ? weeklyTitle : sessionTitle
            case (true, false):  return sessionTitle
            case (false, true):  return weeklyTitle
            case (false, false): return "○ No 5h limit"
            }
        }
    }
}

// ─── Manager ─────────────────────────────────────────────────────────────────

@MainActor
final class UsageManager: ObservableObject {

    @Published private(set) var usage: UsageData = .placeholder
    @Published private(set) var plan: String?
    @Published private(set) var hasLoaded = false
    @Published private(set) var rateLimitedUntil: Date?
    @Published private(set) var accountName: String?
    @Published private(set) var multipleAccounts = false
    @Published private(set) var modelBuckets: [Bucket] = []
    @Published private(set) var modelsIndexing = false
    @Published private(set) var indexProgress = 0.0
    @Published private(set) var modelsLoadedOnce = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var tokenMissing = false
    @Published private(set) var tokenExpired = false

    @Published var titleMode: TitleMode {
        didSet {
            UserDefaults.standard.set(titleMode.rawValue, forKey: Self.titleModeKey)
            onUpdate?(statusTitle)
        }
    }

    /// Called on the main actor after every state change with the menu-bar
    /// title so the AppDelegate can refresh the status item.
    var onUpdate: ((String) -> Void)?

    /// Menu-bar text that reflects auth state, so it never shows stale usage
    /// while the token is missing or expired.
    private var statusTitle: String {
        if tokenMissing { return "○ Sign in" }
        if tokenExpired { return "⚠ Expired" }
        if !hasLoaded { return "◌ …" }
        return usage.menuBarTitle(titleMode)
    }

    private static let titleModeKey = "titleMode"
    private static let sessionLength: TimeInterval = 5 * 3600
    private static let weekLength: TimeInterval = 7 * 24 * 3600

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let useMock = ProcessInfo.processInfo.environment["CUB_MOCK"] != nil
    private var timer: Timer?
    private var countdownTimer: Timer?
    private var lastFetch: Date?
    private var nextAllowedFetch: Date?
    private var rateBackoff: TimeInterval = 0
    private var history: UsageHistoryStore
    private let indexer: TranscriptIndexer
    private var lastIndexRun: Date?
    // History and the cached response are kept per Claude account. "default" is the
    // pre-account file name (history.json / last-usage.json) and is adopted by the
    // first account that gets identified.
    private var accountKey: String
    private var knownToken: String?
    private var profileRetryAt: Date?

    private static let accountKeyDefaults = "currentAccountKey"
    private static let knownAccountsDefaults = "knownAccounts"

    private static var supportDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClaudeUsageBar", isDirectory: true)
    }

    private static func historyFileName(_ key: String) -> String {
        key == "default" ? "history.json" : "history-\(key).json"
    }

    private static func cacheFileName(_ key: String) -> String {
        key == "default" ? "last-usage.json" : "last-usage-\(key).json"
    }

    private var cacheURL: URL? {
        Self.supportDir?.appendingPathComponent(Self.cacheFileName(accountKey))
    }
    // Store raw reset dates so we can recompute display strings without re-fetching.
    private var sessionResetsAt: Date?
    private var weeklyResetsAt: Date?

    // private var notified80 = false  // disabled, see MARK: Notifications
    // private var notified95 = false

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.titleModeKey)
        titleMode = stored.flatMap(TitleMode.init(rawValue:)) ?? .session
        let persistent = ProcessInfo.processInfo.environment["CUB_MOCK"] == nil
        let key = UserDefaults.standard.string(forKey: Self.accountKeyDefaults) ?? "default"
        accountKey = key
        history = UsageHistoryStore(persistent: persistent, fileName: Self.historyFileName(key))
        indexer = TranscriptIndexer(persistent: persistent)
        let known = UserDefaults.standard.dictionary(forKey: Self.knownAccountsDefaults) as? [String: String] ?? [:]
        accountName = known[key]
        multipleAccounts = known.count > 1
        if !useMock { restoreCache() }
    }

    // MARK: Accounts

    /// Identifies the signed-in account through the profile endpoint, so switching
    /// Claude accounts switches to that account's own history instead of mixing
    /// the two. Only runs when the token changes (account switch or token refresh).
    private func resolveAccount(token: String) async {
        guard !useMock, token != knownToken else { return }
        if let retry = profileRetryAt, Date() < retry { return }
        guard let profile = await Self.fetchProfile(token: token) else {
            profileRetryAt = Date().addingTimeInterval(600)
            return
        }
        profileRetryAt = nil
        knownToken = token

        var known = UserDefaults.standard.dictionary(forKey: Self.knownAccountsDefaults) as? [String: String] ?? [:]
        known[profile.uuid] = profile.name
        UserDefaults.standard.set(known, forKey: Self.knownAccountsDefaults)
        multipleAccounts = known.count > 1
        accountName = profile.name
        if profile.uuid != accountKey { switchAccount(to: profile.uuid) }
    }

    private func switchAccount(to key: String) {
        if accountKey == "default", let dir = Self.supportDir {
            // First identified account adopts the data recorded before accounts existed.
            let fm = FileManager.default
            for (old, new) in [(Self.historyFileName("default"), Self.historyFileName(key)),
                               (Self.cacheFileName("default"), Self.cacheFileName(key))] {
                let dest = dir.appendingPathComponent(new)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: dir.appendingPathComponent(old), to: dest)
                }
            }
        }
        accountKey = key
        UserDefaults.standard.set(key, forKey: Self.accountKeyDefaults)
        history = UsageHistoryStore(persistent: true, fileName: Self.historyFileName(key))

        usage = .placeholder
        hasLoaded = false
        lastFetch = nil
        sessionResetsAt = nil
        weeklyResetsAt = nil
        plan = nil
        rateLimitedUntil = nil
        rateBackoff = 0
        nextAllowedFetch = nil
        restoreCache()
        publish()
    }

    private static func fetchProfile(token: String) async -> (uuid: String, name: String)? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeUsageBar/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["account"] as? [String: Any],
              let uuid = account["uuid"] as? String, !uuid.isEmpty
        else { return nil }
        let display = (account["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let emailName = (account["email"] as? String)?.split(separator: "@").first.map(String.init)
        return (uuid, display ?? emailName ?? "Account")
    }

    /// Shows the last good response right away, so a rate-limited or offline launch
    /// displays slightly old numbers (with its real age) instead of an empty state.
    private func restoreCache() {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(RawUsageResponse.self, from: data),
              let saved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return }
        apply(raw, at: saved)
    }

    private func apply(_ raw: RawUsageResponse, at date: Date) {
        sessionResetsAt = Self.parseDate(raw.five_hour.resets_at)
        weeklyResetsAt  = Self.parseDate(raw.seven_day.resets_at)
        usage = Self.map(raw)
        lastFetch = date
        hasLoaded = true
        usage.lastUpdated = Self.relativeSince(date)
    }

    // MARK: Lifecycle

    func start() {
        // requestNotificationAuthorization() — disabled, see MARK: Notifications below
        Task { await fetch() }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            refreshModels()
        }
        // Fetch fresh data from the API every 2 minutes.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { await self?.fetch() }
            Task { @MainActor in self?.refreshModels() }
        }
        // Update the countdown display every 60s without hitting the API.
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshCountdown()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Recomputes the reset-time strings and menu bar title from cached dates.
    private func refreshCountdown() {
        guard lastFetch != nil else { return }
        if let d = sessionResetsAt {
            usage.sessionResetIn = Self.relativeUntil(d)
        }
        if let d = weeklyResetsAt {
            usage.weeklyResetsAt = Self.absoluteReset(d)
            usage.weeklyResetIn = Self.relativeUntil(d)
        }
        usage.lastUpdated = lastFetch.map { Self.relativeSince($0) } ?? usage.lastUpdated
        onUpdate?(statusTitle)
    }

    // MARK: Launch at login

    /// Whether the app is registered to launch at login.
    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Toggles the login-item registration. Returns the resulting state.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            errorMessage = "Login item: \(error.localizedDescription)"
        }
        objectWillChange.send()
        return launchAtLogin
    }

    // MARK: Models

    /// Reads any new Claude Code transcript data in the background. The first run
    /// over a large `~/.claude/projects` takes a while; later runs only read what
    /// was appended.
    func refreshModels() {
        guard !useMock, !modelsIndexing else { return }
        if let last = lastIndexRun, Date().timeIntervalSince(last) < 20 { return }
        lastIndexRun = Date()
        modelsIndexing = true
        indexProgress = 0
        let indexer = self.indexer
        Task.detached(priority: .utility) { [self] in
            let buckets = await indexer.refresh { fraction in
                Task { @MainActor in self.indexProgress = fraction }
            }
            await MainActor.run {
                self.modelBuckets = buckets
                self.modelsIndexing = false
                self.modelsLoadedOnce = true
            }
        }
    }

    func modelRangeStart(_ range: ModelRange) -> Date {
        switch range {
        case .fiveHour: return sessionWindow?.lowerBound ?? Date().addingTimeInterval(-5 * 3600)
        case .today:    return Calendar.current.startOfDay(for: Date())
        case .week:     return weeklyWindow?.lowerBound ?? Date().addingTimeInterval(-Self.weekLength)
        }
    }

    func modelsSummary(_ range: ModelRange) -> ModelsSummary {
        ModelsSummary.make(from: modelBuckets, since: modelRangeStart(range))
    }

    // MARK: Pace & projection

    /// Samples recorded during the current 5-hour session window.
    var sessionSamples: [UsageSample] {
        guard let r = sessionResetsAt else { return [] }
        let start = r.addingTimeInterval(-Self.sessionLength).timeIntervalSince1970
        return history.samples.filter { $0.t >= start }
    }

    var sessionWindow: ClosedRange<Date>? {
        guard let r = sessionResetsAt else { return nil }
        return r.addingTimeInterval(-Self.sessionLength)...r
    }

    var projection: UsageProjection.Outcome {
        guard usage.sessionActive, let r = sessionResetsAt else { return .collecting }
        return UsageProjection.evaluate(samples: sessionSamples, now: Date(), resetsAt: r)
    }

    var weeklyWindow: ClosedRange<Date>? {
        guard let r = weeklyResetsAt else { return nil }
        return r.addingTimeInterval(-Self.weekLength)...r
    }

    /// Samples recorded during the current 7-day window.
    var weeklySamples: [UsageSample] {
        guard let w = weeklyWindow else { return [] }
        let start = w.lowerBound.timeIntervalSince1970
        return history.samples.filter { $0.t >= start }
    }

    /// Per-day weekly usage, from recorded history. Days before the app started
    /// recording have no data.
    var weeklyDays: [DayUsage] {
        guard let w = weeklyWindow else { return [] }
        let samples = weeklySamples
        let now = Date()
        return (0..<7).map { i in
            let start = w.lowerBound.addingTimeInterval(Double(i) * 86400)
            let end = start.addingTimeInterval(86400)
            let inDay = samples.filter { $0.t >= start.timeIntervalSince1970 && $0.t < end.timeIntervalSince1970 }
            var delta: Double?
            if let first = inDay.first, let last = inDay.last {
                let baseline = samples.last { $0.t < start.timeIntervalSince1970 } ?? first
                delta = max(0, last.weekly - baseline.weekly)
            }
            return DayUsage(id: i, start: start, delta: delta,
                            isToday: start <= now && now < end, isFuture: start > now)
        }
    }

    /// 0–100: how far through the weekly window we are, for the pace marker.
    var weeklyPacePercent: Double? {
        guard usage.weeklyActive, let r = weeklyResetsAt else { return nil }
        let elapsed = Self.weekLength - max(0, r.timeIntervalSinceNow)
        return min(100, max(0, elapsed / Self.weekLength * 100))
    }

    /// Percent of the weekly limit that can be spent per remaining day.
    var weeklyPerDayLeft: Double? {
        guard usage.weeklyActive, let r = weeklyResetsAt else { return nil }
        let days = r.timeIntervalSinceNow / 86400
        guard days > 0.04 else { return nil }
        return max(0, 100 - usage.weeklyPercent) / days
    }

    // MARK: Fetch

    /// `force` skips the 45-second minimum gap (manual refresh) but never overrides
    /// a rate-limit wait: asking again while the server said "wait" only prolongs it.
    func fetch(force: Bool = false) async {
        guard !isLoading else { return }
        if let until = rateLimitedUntil, Date() < until { return }
        if !force, let next = nextAllowedFetch, Date() < next { return }
        isLoading = true
        defer { isLoading = false; publish() }

        if useMock {
            loadMock()
            return
        }

        guard let creds = Self.readCredentials() else {
            // Credentials present but unreadable (e.g. Keychain locked) is an
            // expired/locked state, not a sign-out — keep them apart.
            if Self.credentialsExist() {
                tokenExpired = true
                tokenMissing = false
            } else {
                tokenMissing = true
                tokenExpired = false
            }
            errorMessage = nil
            return
        }
        tokenMissing = false
        tokenExpired = false
        await resolveAccount(token: creds.token)
        plan = creds.plan

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeUsageBar/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = "No HTTP response"; return
            }
            guard http.statusCode == 200 else {
                switch http.statusCode {
                case 429:
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    rateBackoff = retryAfter ?? min(max(rateBackoff * 2, 120), 900)
                    rateLimitedUntil = Date().addingTimeInterval(rateBackoff)
                    errorMessage = nil
                case 401:
                    // The token expired — Claude Code refreshes it on next use.
                    tokenExpired = true
                    errorMessage = nil
                default:
                    errorMessage = "API error \(http.statusCode)"
                }
                return
            }
            let raw = try JSONDecoder().decode(RawUsageResponse.self, from: data)
            apply(raw, at: Date())
            errorMessage = nil
            rateBackoff = 0
            rateLimitedUntil = nil
            nextAllowedFetch = Date().addingTimeInterval(45)
            if let cacheURL {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
            if usage.sessionActive {
                history.record(session: usage.sessionPercent, weekly: usage.weeklyPercent)
            }
            // checkNotifications(usage.sessionPercent) — disabled, see MARK: Notifications below
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publish() {
        if let last = lastFetch {
            usage.lastUpdated = Self.relativeSince(last)
        }
        onUpdate?(statusTitle)
    }

    /// Debug aid (`CUB_MOCK=1`): fixed sample data with a synthetic 3-hour history.
    private func loadMock() {
        let now = Date()
        sessionResetsAt = now.addingTimeInterval(2 * 3600 + 8 * 60)
        weeklyResetsAt = now.addingTimeInterval(3 * 86400 + 4 * 3600)
        usage = .mock
        plan = "Max 5x"
        if ProcessInfo.processInfo.environment["CUB_MOCK_ACCOUNTS"] != nil {
            accountName = "Work account"
            multipleAccounts = true
        }
        lastFetch = now
        hasLoaded = true
        errorMessage = nil
        // Debug aid: `CUB_MOCK_STATE=missing|expired` shows the auth screens.
        let forced = ProcessInfo.processInfo.environment["CUB_MOCK_STATE"]
        tokenMissing = forced == "missing"
        tokenExpired = forced == "expired"

        let sessionStart = now.addingTimeInterval(-172 * 60)
        let weekStart = weeklyResetsAt!.addingTimeInterval(-Self.weekLength)
        let elapsedDays = now.timeIntervalSince(weekStart) / 86400
        // Cumulative weekly % at the start of each day, ending at today's 38%.
        let knots: [(day: Double, pct: Double)] = [(0, 0), (1, 9), (2, 23), (3, 29), (elapsedDays, 38)]
        func weekly(at day: Double) -> Double {
            for (lo, hi) in zip(knots, knots.dropFirst()) where day <= hi.day {
                return lo.pct + (hi.pct - lo.pct) * (day - lo.day) / max(hi.day - lo.day, 0.001)
            }
            return 38
        }
        var samples: [UsageSample] = []
        var t = weekStart
        while t < now {
            let session = t >= sessionStart
                ? min(61.0 * t.timeIntervalSince(sessionStart) / now.timeIntervalSince(sessionStart), 61) : 0
            samples.append(UsageSample(t: t.timeIntervalSince1970, session: session,
                                       weekly: weekly(at: t.timeIntervalSince(weekStart) / 86400)))
            t = t.addingTimeInterval(t < sessionStart ? 3600 : 240)
        }
        history.seed(samples)

        let mix: [(model: String, project: String, input: Int, output: Int, read: Int, create: Int)] = [
            ("claude-sonnet-5-5", "menubar-claude-usage", 1_200, 90_000, 2_100_000, 380_000),
            ("claude-sonnet-5-5", "gl-web-js", 900, 60_000, 900_000, 210_000),
            ("claude-opus-5-5", "gl-web-js", 700, 41_000, 640_000, 150_000),
            ("claude-haiku-4-5-20251001", "custom-touchbar", 300, 12_000, 120_000, 40_000),
            ("deepseek-v4-pro", "my-portfolio", 400, 20_000, 0, 0),
        ]
        var mockBuckets: [Bucket] = []
        for (i, hoursAgo) in [0.5, 1.5, 2.5, 8.0, 30.0, 70.0, 100.0].enumerated() {
            let t = Int(now.addingTimeInterval(-hoursAgo * 3600).timeIntervalSince1970) / 300 * 300
            for (j, m) in mix.enumerated() where (i + j) % 3 != 2 || i < 3 {
                let k = Double(1 + (i + j) % 3)
                mockBuckets.append(Bucket(
                    key: BucketKey(t: t, model: m.model, project: m.project),
                    counts: TokenCounts(
                        input: Int(Double(m.input) * k), output: Int(Double(m.output) * k),
                        cacheRead: Int(Double(m.read) * k), cacheCreate: Int(Double(m.create) * k),
                        thinking: Int(Double(m.output) * k * 0.12), requests: Int(18 * k),
                        subagent: Int(5 * k))))
            }
        }
        modelBuckets = mockBuckets
        modelsLoadedOnce = true
    }

    // MARK: Mapping

    private static func map(_ raw: RawUsageResponse) -> UsageData {
        // API returns utilization already as a 0–100 percentage (not a 0.0–1.0 fraction).
        let sessionReset = parseDate(raw.five_hour.resets_at)
        let weeklyReset = parseDate(raw.seven_day.resets_at)
        let limits = raw.limits ?? []
        func severity(_ kind: String) -> String? {
            limits.first { $0.kind == kind }?.severity
        }

        return UsageData(
            sessionPercent: raw.five_hour.utilization ?? 0,
            sessionResetIn: relativeUntil(sessionReset),
            sessionActive: sessionReset.map { $0.timeIntervalSinceNow > 0 } ?? false,
            sessionSeverity: severity("session"),
            weeklyPercent: raw.seven_day.utilization ?? 0,
            weeklyResetsAt: absoluteReset(weeklyReset),
            weeklyResetIn: relativeUntil(weeklyReset),
            weeklyActive: weeklyReset.map { $0.timeIntervalSinceNow > 0 } ?? false,
            weeklySeverity: severity("weekly_all"),
            extraRows: extraRows(raw),
            credits: credits(raw),
            allowance: allowance(raw),
            lastUpdated: "just now"
        )
    }

    /// Per-model and other limit rows. Named `seven_day_*` fields win; any other
    /// `limits[]` entry is shown generically so new limit kinds appear without an update.
    private static func extraRows(_ raw: RawUsageResponse) -> [LimitRow] {
        let named: [(key: String, title: String, window: RawWindow?)] = [
            ("opus", "Opus · weekly", raw.seven_day_opus),
            ("sonnet", "Sonnet · weekly", raw.seven_day_sonnet),
            ("cowork", "Cowork · weekly", raw.seven_day_cowork),
            ("oauth", "OAuth apps · weekly", raw.seven_day_oauth_apps),
        ]
        var rows: [LimitRow] = []
        for item in named {
            guard let w = item.window else { continue }
            let reset = parseDate(w.resets_at)
            rows.append(LimitRow(
                id: item.key, title: item.title, percent: w.utilization ?? 0, resetsAt: reset,
                active: reset.map { $0.timeIntervalSinceNow > 0 } ?? false, severity: nil))
        }
        let covered = named.filter { $0.window != nil }.map(\.key)
        for l in raw.limits ?? [] {
            let kind = l.kind.lowercased()
            if kind == "session" || kind == "weekly_all" { continue }
            if covered.contains(where: { kind.contains($0) }) { continue }
            rows.append(LimitRow(
                id: "limit-\(l.kind)",
                title: l.kind.replacingOccurrences(of: "_", with: " ").capitalized,
                percent: l.percent ?? 0, resetsAt: parseDate(l.resets_at),
                active: l.is_active ?? true, severity: l.severity))
        }
        return rows
    }

    private static func credits(_ raw: RawUsageResponse) -> CreditsInfo? {
        let enabled = raw.spend?.enabled ?? raw.extra_usage?.is_enabled
        guard let enabled else { return nil }
        return CreditsInfo(
            enabled: enabled,
            spent: raw.spend?.used.flatMap(formatMoney),
            limit: raw.spend?.limit.flatMap(formatMoney),
            balance: raw.spend?.balance.flatMap(formatMoney),
            limitReached: raw.extra_usage?.spend_limit_reached ?? false)
    }

    private static func allowance(_ raw: RawUsageResponse) -> AllowanceInfo? {
        guard let w = raw.iguana_necktie, let limit = w.limit_dollars, limit > 0 else { return nil }
        return AllowanceInfo(used: w.used_dollars ?? 0, limit: limit, resetsAt: parseDate(w.resets_at))
    }

    private static func formatMoney(_ m: RawMoney) -> String? {
        guard let minor = m.amount_minor else { return nil }
        let exponent = m.exponent ?? 2
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = m.currency ?? "USD"
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = exponent
        f.maximumFractionDigits = exponent
        return f.string(from: NSNumber(value: minor / pow(10, Double(exponent))))
    }

    // MARK: Date helpers

    /// Parses ISO-8601 timestamps, tolerating fractional seconds of any length
    /// (the API emits microseconds: "...:00.377755+00:00").
    private static func parseDate(_ string: String?) -> Date? {
        guard var s = string else { return nil }
        if let regex = try? NSRegularExpression(pattern: "\\.[0-9]+") {
            s = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    /// "2h 8m" / "47m" / "3d 4h" — time remaining until a Date.
    static func relativeUntil(_ date: Date?) -> String {
        guard let date else { return "—" }
        return duration(date.timeIntervalSinceNow)
    }

    /// "2h 8m" / "47m" / "3d 4h" — a length of time.
    static func duration(_ seconds: TimeInterval) -> String {
        let mins = max(0, Int(seconds / 60))
        let h = mins / 60, m = mins % 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// "Sat 9:00 AM" — absolute weekday + time of the reset.
    static func absoluteReset(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = date.timeIntervalSinceNow > 8 * 86400 ? "MMM d" : "EEE h:mm a"
        return f.string(from: date)
    }

    /// "just now" / "2m ago" / "1h 30m ago" — how long since the last successful fetch.
    private static func relativeSince(_ date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 10 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m ago" }
        let h = mins / 60, m = mins % 60
        return m > 0 ? "\(h)h \(m)m ago" : "\(h)h ago"
    }

    // MARK: Token

    private struct Credentials {
        let token: String
        let plan: String?
    }

    /// Reads the Claude Code OAuth credentials from the credentials file or
    /// the macOS Keychain (same locations claudeusage-mcp uses).
    private static func readCredentials() -> Credentials? {
        for path in credentialFilePaths() {
            if let data = FileManager.default.contents(atPath: path),
               let creds = parseCredentials(data) {
                return creds
            }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return parseCredentials(out.fileHandleForReading.readDataToEndOfFile())
    }

    /// Candidate `.credentials.json` locations, in priority order. Honors
    /// `CLAUDE_CONFIG_DIR` — the same override Claude Code itself respects —
    /// before falling back to the default `~/.claude` directory.
    private static func credentialFilePaths() -> [String] {
        var paths: [String] = []
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !dir.isEmpty {
            paths.append((dir as NSString).expandingTildeInPath + "/.credentials.json")
        }
        paths.append(NSHomeDirectory() + "/.claude/.credentials.json")
        return paths
    }

    /// True when a credentials file or the Keychain item exists, even if the
    /// token itself can't currently be read (e.g. Keychain locked, expired).
    /// Distinguishes "expired / locked" from "never signed in". Reads only the
    /// item's metadata (no `-w`), so it never triggers an unlock prompt.
    private static func credentialsExist() -> Bool {
        for path in credentialFilePaths() where FileManager.default.fileExists(atPath: path) {
            return true
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func parseCredentials(_ data: Data) -> Credentials? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = obj["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        // Return nil for expired tokens so the caller shows the "Session expired"
        // screen instead of sending a request the API will reject.
        if let raw = oauth["expiresAt"] as? Double {
            // expiresAt may be milliseconds (>1e12) or seconds — normalise to seconds.
            let secs = raw > 1e12 ? raw / 1000 : raw
            if Date(timeIntervalSince1970: secs) < Date() { return nil }
        }
        return Credentials(
            token: token,
            plan: planLabel(subscription: oauth["subscriptionType"] as? String,
                            tier: oauth["rateLimitTier"] as? String))
    }

    /// "Pro" / "Max 5x" / "Max 20x" from the credential's subscription fields.
    private static func planLabel(subscription: String?, tier: String?) -> String? {
        let tier = tier?.lowercased() ?? ""
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        guard let subscription, !subscription.isEmpty else { return nil }
        return subscription.capitalized
    }

    // MARK: Notifications
    //
    // ⚠️  DISABLED — requires a Developer ID certificate to work on macOS.
    //
    // macOS suppresses UserNotifications for ad-hoc-signed apps (codesign --sign -).
    // To enable: sign the app with a Developer ID certificate (Apple Developer Program,
    // $99/year), then uncomment the two call sites above and re-enable the methods below.
    //
    // Contributors with a Developer ID can re-enable this by:
    //   1. Uncommenting `requestNotificationAuthorization()` in start()
    //   2. Uncommenting `checkNotifications(...)` in fetch()
    //   3. Signing with: codesign --force --deep --sign "Developer ID Application: ..." ClaudeUsageBar.app

//    private func requestNotificationAuthorization() {
//        guard Bundle.main.bundleIdentifier != nil else { return }
//        UNUserNotificationCenter.current()
//            .requestAuthorization(options: [.alert, .sound]) { granted, error in
//                if let error { NSLog("ClaudeUsageBar notif auth: %@", error.localizedDescription) }
//                else if !granted { NSLog("ClaudeUsageBar: notifications not permitted") }
//            }
//    }
//
//    private func checkNotifications(_ pct: Double) {
//        if pct < 80 {
//            notified80 = false
//            notified95 = false
//        } else if pct < 95 {
//            notified95 = false
//            if !notified80 {
//                notify(title: "Claude usage at \(Int(pct))%",
//                       body: "You've used 80% of your 5-hour session.")
//                notified80 = true
//            }
//        } else {
//            notified80 = true
//            if !notified95 {
//                notify(title: "Claude usage at \(Int(pct))%",
//                       body: "You're nearly at your session limit.")
//                notified95 = true
//            }
//        }
//    }
//
//    func sendTestNotification() {
//        notify(title: "Claude usage at 80%",
//               body: "Notification test — thresholds 80% and 95% are wired up.")
//    }
//
//    private func notify(title: String, body: String) {
//        guard Bundle.main.bundleIdentifier != nil else { return }
//        let content = UNMutableNotificationContent()
//        content.title = title
//        content.body = body
//        content.sound = .default
//        let request = UNNotificationRequest(
//            identifier: UUID().uuidString, content: content, trigger: nil)
//        UNUserNotificationCenter.current().add(request) { error in
//            if let error { NSLog("ClaudeUsageBar notif: %@", error.localizedDescription) }
//        }
//    }
}
