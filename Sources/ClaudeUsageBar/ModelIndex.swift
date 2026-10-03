import Foundation

// ─── Token model ─────────────────────────────────────────────────────────────

struct TokenCounts: Codable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheCreate = 0
    var thinking = 0
    var requests = 0
    var subagent = 0

    var total: Int { input + output + cacheRead + cacheCreate }

    static func += (l: inout TokenCounts, r: TokenCounts) {
        l.input += r.input; l.output += r.output
        l.cacheRead += r.cacheRead; l.cacheCreate += r.cacheCreate
        l.thinking += r.thinking; l.requests += r.requests; l.subagent += r.subagent
    }

    static func -= (l: inout TokenCounts, r: TokenCounts) {
        l.input -= r.input; l.output -= r.output
        l.cacheRead -= r.cacheRead; l.cacheCreate -= r.cacheCreate
        l.thinking -= r.thinking; l.requests -= r.requests; l.subagent -= r.subagent
    }
}

struct BucketKey: Codable, Hashable, Sendable {
    let t: Int          // start of a 5-minute bucket, epoch seconds
    let model: String
    let project: String
}

struct Bucket: Codable, Sendable {
    let key: BucketKey
    let counts: TokenCounts
}

// ─── Summaries for the UI ────────────────────────────────────────────────────

struct ModelRow: Identifiable {
    let name: String
    let counts: TokenCounts
    var id: String { name }
}

struct ProjectRow: Identifiable {
    let name: String
    let tokens: Int
    var id: String { name }
}

struct ModelsSummary {
    var total = TokenCounts()
    var models: [ModelRow] = []
    var projects: [ProjectRow] = []

    var isEmpty: Bool { total.requests == 0 }

    /// Share of tokens served from the prompt cache.
    var cacheHitRate: Double? {
        let denom = total.cacheRead + total.cacheCreate + total.input
        return denom > 0 ? Double(total.cacheRead) / Double(denom) : nil
    }

    var thinkingShare: Double? {
        total.output > 0 ? Double(total.thinking) / Double(total.output) : nil
    }

    var subagentShare: Double? {
        total.requests > 0 ? Double(total.subagent) / Double(total.requests) : nil
    }

    static func make(from buckets: [Bucket], since start: Date) -> ModelsSummary {
        let startT = Int(start.timeIntervalSince1970)
        var summary = ModelsSummary()
        var byModel: [String: TokenCounts] = [:]
        var byProject: [String: Int] = [:]

        for b in buckets where b.key.t + 300 > startT {
            summary.total += b.counts
            byModel[ModelNaming.display(b.key.model), default: TokenCounts()] += b.counts
            byProject[b.key.project, default: 0] += b.counts.total
        }
        summary.models = byModel.map { ModelRow(name: $0.key, counts: $0.value) }
            .sorted { $0.counts.total > $1.counts.total }
        summary.projects = byProject.map { ProjectRow(name: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
        return summary
    }
}

enum ModelNaming {
    /// "claude-sonnet-5-5" → "Sonnet 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5";
    /// anything that is not a Claude model is grouped as "Other".
    static func display(_ raw: String) -> String {
        guard raw.hasPrefix("claude-") else { return "Other" }
        var parts = raw.dropFirst("claude-".count).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        let numbers = parts.filter { $0.allSatisfy(\.isNumber) }
        guard let family = parts.first(where: { !$0.allSatisfy(\.isNumber) }) else { return "Other" }
        let version = numbers.joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}

// ─── Indexer ─────────────────────────────────────────────────────────────────
// Reads Claude Code transcripts (~/.claude/projects/**/*.jsonl) incrementally and
// keeps small per-5-minute token totals. The folder can be around a gigabyte, so:
//   • files not touched within the retention window are skipped entirely;
//   • each file remembers how many bytes were already read and only the new tail
//     is parsed;
//   • only lines that look like assistant messages with usage are JSON-decoded.
// One response is written as several lines sharing a message id, so records are
// de-duplicated by id (the last line wins, as it carries the final token counts).

private struct RecentRecord: Codable {
    let id: String
    let key: BucketKey
    let counts: TokenCounts
}

private struct FileState: Codable {
    var offset: Int = 0
    var recent: [RecentRecord] = []
}

private struct IndexFile: Codable {
    var version = 1
    var files: [String: FileState] = [:]
    var buckets: [Bucket] = []
}

actor TranscriptIndexer {
    private static let retention: TimeInterval = 10 * 86400
    private static let bucketSeconds = 300
    private static let recentLimit = 32
    private static let usageNeedle = Data("\"usage\"".utf8)

    private let root: URL
    private let storeURL: URL?
    private var files: [String: FileState] = [:]
    private var buckets: [BucketKey: TokenCounts] = [:]
    private var loaded = false
    private let dateParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(persistent: Bool) {
        root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects", isDirectory: true)
        if persistent, let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = base.appendingPathComponent("ClaudeUsageBar", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            storeURL = dir.appendingPathComponent("model-index.json")
        } else {
            storeURL = nil
        }
    }

    /// Indexes any new transcript data and returns all retained buckets.
    func refresh(progress: @Sendable (Double) -> Void) -> [Bucket] {
        loadIfNeeded()
        let cutoff = Date().addingTimeInterval(-Self.retention)

        var candidates: [(path: String, size: Int)] = []
        if let e = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) {
            for case let url as URL in e where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = v.contentModificationDate, mtime >= cutoff,
                      let size = v.fileSize else { continue }
                if size > (files[url.path]?.offset ?? 0) {
                    candidates.append((url.path, size))
                }
            }
        }

        let cutoffT = Int(cutoff.timeIntervalSince1970)
        for (i, c) in candidates.enumerated() {
            process(path: c.path, size: c.size, cutoffT: cutoffT)
            progress(Double(i + 1) / Double(candidates.count))
            if i % 25 == 24 { save() }
        }

        buckets = buckets.filter { $0.key.t >= cutoffT && $0.value.requests > 0 }
        if !candidates.isEmpty { save() }
        return buckets.map { Bucket(key: $0.key, counts: $0.value) }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let file = try? JSONDecoder().decode(IndexFile.self, from: data), file.version == 1
        else { return }
        files = file.files
        buckets = Dictionary(file.buckets.map { ($0.key, $0.counts) }, uniquingKeysWith: { $1 })
    }

    private func save() {
        guard let storeURL else { return }
        let file = IndexFile(files: files, buckets: buckets.map { Bucket(key: $0.key, counts: $0.value) })
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func process(path: String, size: Int, cutoffT: Int) {
        var state = files[path] ?? FileState()
        if size < state.offset { state = FileState() }   // file was rewritten
        guard size > state.offset, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(state.offset))

        let fallbackProject = Self.projectName(fromFolder: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)
        var pending = Data()
        var consumed = state.offset
        var batch: [String: RecentRecord] = [:]
        var order: [String] = []

        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: 10) else { continue }
            let complete = pending[pending.startIndex...lastNewline]
            for line in complete.split(separator: 10, omittingEmptySubsequences: true) {
                guard line.range(of: Self.usageNeedle) != nil,
                      let rec = record(from: Data(line), fallbackProject: fallbackProject, cutoffT: cutoffT)
                else { continue }
                if batch[rec.id] == nil { order.append(rec.id) }
                batch[rec.id] = rec
            }
            consumed += complete.count
            pending = Data(pending[pending.index(after: lastNewline)...])
        }

        for id in order {
            guard let rec = batch[id] else { continue }
            if let i = state.recent.firstIndex(where: { $0.id == id }) {
                let old = state.recent.remove(at: i)
                buckets[old.key, default: TokenCounts()] -= old.counts
            }
            buckets[rec.key, default: TokenCounts()] += rec.counts
            state.recent.append(rec)
        }
        if state.recent.count > Self.recentLimit {
            state.recent.removeFirst(state.recent.count - Self.recentLimit)
        }
        state.offset = consumed
        files[path] = state
    }

    private func record(from line: Data, fallbackProject: String, cutoffT: Int) -> RecentRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let model = msg["model"] as? String, model != "<synthetic>",
              let id = (msg["id"] as? String) ?? (obj["uuid"] as? String),
              let stamp = obj["timestamp"] as? String,
              let date = dateParser.date(from: stamp)
        else { return nil }

        let t = Int(date.timeIntervalSince1970)
        guard t >= cutoffT else { return nil }

        func n(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let thinking = ((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? NSNumber)?.intValue ?? 0
        let project = (obj["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallbackProject

        return RecentRecord(
            id: id,
            key: BucketKey(t: t / Self.bucketSeconds * Self.bucketSeconds, model: model, project: project),
            counts: TokenCounts(
                input: n("input_tokens"), output: n("output_tokens"),
                cacheRead: n("cache_read_input_tokens"), cacheCreate: n("cache_creation_input_tokens"),
                thinking: thinking, requests: 1,
                subagent: (obj["isSidechain"] as? Bool) == true ? 1 : 0))
    }

    /// "-Users-me-Project-app" → "app" (best effort; `cwd` is preferred when present).
    private static func projectName(fromFolder folder: String) -> String {
        folder.split(separator: "-").last.map(String.init) ?? folder
    }
}
