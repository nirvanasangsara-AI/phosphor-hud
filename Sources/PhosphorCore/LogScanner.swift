import Foundation

/// Daily token totals per "source|model", plus what the scanner needs to pick up where it left off.
public struct UsageLedger: Codable, Sendable {
    public struct FileMark: Codable, Sendable {
        public var size: Int64
        public var mtime: Double
        public var offset: Int64
        public var codex: LogParsers.CodexState?
    }
    public var version = 1
    public var files: [String: FileMark] = [:]
    /// day ("yyyy-MM-dd") → "source|model" → usage
    public var days: [String: [String: TokenUsage]] = [:]
    /// day → hashes of de-duplication keys already counted
    public var seen: [String: [UInt64]] = [:]
    public var scannedAt: Date?
    /// Oldest moment this ledger covers. The first scan only goes back `initialDays` so it stays
    /// light; history then grows forward day by day.
    public var since: Date?

    public init() {}

    public mutating func add(_ e: UsageEvent, tz: TimeZone = .current, seenSet: inout Set<UInt64>) {
        let day = DayKey.of(e.date, in: tz)
        if let k = e.dedupeKey {
            let h = Self.fnv(k)
            guard seenSet.insert(h).inserted else { return }
            seen[day, default: []].append(h)
        }
        days[day, default: [:]]["\(e.source)|\(e.model)", default: TokenUsage()] += e.usage
    }

    public mutating func prune(keepDays: Int, now: Date = Date(), tz: TimeZone = .current) {
        let cutoff = DayKey.of(now.addingTimeInterval(-Double(keepDays) * 86_400), in: tz)
        days = days.filter { $0.key >= cutoff }
        seen = seen.filter { $0.key >= cutoff }
    }

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    // MARK: Reading the totals

    public struct DayTotal: Sendable, Hashable, Identifiable {
        public var id: String { "\(day)|\(source)" }
        public var day: String
        public var source: String
        public var tokens: Int
        public var cost: Double         // priced part only
        public var unpricedTokens: Int  // tokens of models with no list price
        public init(day: String, source: String, tokens: Int, cost: Double, unpricedTokens: Int) {
            self.day = day; self.source = source; self.tokens = tokens; self.cost = cost; self.unpricedTokens = unpricedTokens
        }
    }

    public func dailyTotals(prices: PriceTable) -> [DayTotal] {
        var out: [DayTotal] = []
        for (day, rows) in days {
            var bySource: [String: DayTotal] = [:]
            for (key, u) in rows {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                let source = parts.first ?? key, model = parts.count > 1 ? parts[1] : "unknown"
                var t = bySource[source] ?? DayTotal(day: day, source: source, tokens: 0, cost: 0, unpricedTokens: 0)
                t.tokens += u.total
                if let c = prices.cost(u, model: model) { t.cost += c } else { t.unpricedTokens += u.total }
                bySource[source] = t
            }
            out += bySource.values
        }
        return out.sorted { ($0.day, $0.source) < ($1.day, $1.source) }
    }

    public struct Summary: Sendable, Hashable {
        public var tokens = 0
        public var cost = 0.0
        public var unpricedTokens = 0
        public init(tokens: Int = 0, cost: Double = 0, unpricedTokens: Int = 0) {
            self.tokens = tokens; self.cost = cost; self.unpricedTokens = unpricedTokens
        }
    }

    /// Totals for the last `days` days including today, optionally for one source.
    public func summary(lastDays n: Int, source: String? = nil, prices: PriceTable, now: Date = Date(),
                        tz: TimeZone = .current) -> Summary {
        let cutoff = DayKey.of(now.addingTimeInterval(-Double(n - 1) * 86_400), in: tz)
        var s = Summary()
        for t in dailyTotals(prices: prices) where t.day >= cutoff && (source == nil || t.source == source) {
            s.tokens += t.tokens; s.cost += t.cost; s.unpricedTokens += t.unpricedTokens
        }
        return s
    }

    public func modelBreakdown(lastDays n: Int, source: String, now: Date = Date(), tz: TimeZone = .current) -> [(model: String, usage: TokenUsage)] {
        let cutoff = DayKey.of(now.addingTimeInterval(-Double(n - 1) * 86_400), in: tz)
        var acc: [String: TokenUsage] = [:]
        for (day, rows) in days where day >= cutoff {
            for (key, u) in rows where key.hasPrefix("\(source)|") {
                acc[String(key.dropFirst(source.count + 1)), default: TokenUsage()] += u
            }
        }
        return acc.map { ($0.key, $0.value) }.sorted { $0.usage.total > $1.usage.total }
    }
}

/// One family of log files and how to read them.
public struct LogSource: Sendable {
    public enum Format: Sendable { case claude, codex, gemini, cline }
    public var id: String
    public var format: Format
    public var roots: [String]
    /// Lines that do not contain one of these byte strings are skipped without decoding.
    public var needles: [String]
    public var fileSuffix: String
    /// Whole-file JSON (re-read on change) instead of append-only JSONL.
    public var wholeFile: Bool

    public init(id: String, format: Format, roots: [String], needles: [String], fileSuffix: String, wholeFile: Bool = false) {
        self.id = id; self.format = format; self.roots = roots; self.needles = needles
        self.fileSuffix = fileSuffix; self.wholeFile = wholeFile
    }

    public static func standard(home: String = NSHomeDirectory(), env: [String: String] = ProcessInfo.processInfo.environment) -> [LogSource] {
        var claudeRoots = ["\(home)/.claude/projects", "\(home)/.config/claude/projects"]
        if let d = env["CLAUDE_CONFIG_DIR"] { claudeRoots += d.split(separator: ",").map { "\($0)/projects" } }
        let codexHome = env["CODEX_HOME"] ?? "\(home)/.codex"
        let hosts = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Kiro"]
        return [
            .init(id: "claude", format: .claude, roots: claudeRoots, needles: ["\"usage\""], fileSuffix: ".jsonl"),
            .init(id: "codex", format: .codex, roots: ["\(codexHome)/sessions"],
                  needles: ["\"turn_context\"", "\"token_count\""], fileSuffix: ".jsonl"),
            .init(id: "gemini", format: .gemini, roots: ["\(home)/.gemini/tmp"], needles: ["\"tokens\""], fileSuffix: ".jsonl"),
            .init(id: "cline", format: .cline,
                  roots: hosts.map { "\(home)/Library/Application Support/\($0)/User/globalStorage/saoudrizwan.claude-dev/tasks" },
                  needles: [], fileSuffix: "ui_messages.json", wholeFile: true),
            .init(id: "roo", format: .cline,
                  roots: hosts.map { "\(home)/Library/Application Support/\($0)/User/globalStorage/rooveterinaryinc.roo-cline/tasks" },
                  needles: [], fileSuffix: "ui_messages.json", wholeFile: true),
        ]
    }
}

/// Reads session logs incrementally (byte offsets per file), read-only.
public struct LogScanner: Sendable {
    public var sources: [LogSource]
    public var windowDays: Int
    /// How far back a brand-new ledger reaches on its first scan.
    public var initialDays: Int
    public var tz: TimeZone
    public init(sources: [LogSource] = LogSource.standard(), windowDays: Int = 35, initialDays: Int = 7,
                tz: TimeZone = .current) {
        self.sources = sources; self.windowDays = windowDays; self.initialDays = initialDays; self.tz = tz
    }

    public func scan(_ ledger: inout UsageLedger, now: Date = Date()) {
        let fm = FileManager.default
        if ledger.since == nil {
            // Ledgers written before `since` existed already covered the full window.
            ledger.since = ledger.scannedAt.map { $0.addingTimeInterval(-Double(windowDays) * 86_400) }
                ?? now.addingTimeInterval(-Double(initialDays) * 86_400)
        }
        let cutoffDate = max(ledger.since!, now.addingTimeInterval(-Double(windowDays) * 86_400))
        var seenSet = Set(ledger.seen.values.joined())
        var live = Set<String>()
        for src in sources {
            for root in src.roots where fm.fileExists(atPath: root) {
                guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                             includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in en where url.lastPathComponent.hasSuffix(src.fileSuffix) {
                    guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                          rv.isRegularFile == true, let mdate = rv.contentModificationDate, mdate >= cutoffDate else { continue }
                    let path = url.path
                    live.insert(path)
                    let size = Int64(rv.fileSize ?? 0), mtime = mdate.timeIntervalSince1970
                    var mark = ledger.files[path] ?? .init(size: 0, mtime: 0, offset: 0, codex: nil)
                    if mark.size == size && mark.mtime == mtime { continue }
                    if size < mark.offset { mark.offset = 0; mark.codex = nil }       // replaced or truncated
                    let keep = { (e: UsageEvent) in
                        if e.date >= cutoffDate { ledger.add(e, tz: tz, seenSet: &seenSet) }
                    }
                    if src.wholeFile {
                        readWhole(url: url, src: src, emit: keep)
                        mark.offset = size
                    } else {
                        var codex = mark.codex ?? LogParsers.CodexState()
                        mark.offset = readLines(path: path, from: mark.offset, src: src, codex: &codex, emit: keep)
                        if src.format == .codex { mark.codex = codex }
                    }
                    mark.size = size; mark.mtime = mtime
                    ledger.files[path] = mark
                }
            }
        }
        ledger.files = ledger.files.filter { live.contains($0.key) }
        ledger.prune(keepDays: max(windowDays, 60), now: now, tz: tz)
        ledger.scannedAt = now
    }

    private func readWhole(url: URL, src: LogSource, emit: (UsageEvent) -> Void) {
        autoreleasepool { readWholeFile(url: url, src: src, emit: emit) }
    }

    private func readWholeFile(url: URL, src: LogSource, emit: (UsageEvent) -> Void) {
        guard let data = try? Data(contentsOf: url),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let task = url.deletingLastPathComponent().lastPathComponent
        LogParsers.clineTask(arr, source: src.id, taskID: task).forEach(emit)
    }

    /// Returns the offset just past the last complete line read.
    private func readLines(path: String, from start: Int64, src: LogSource, codex: inout LogParsers.CodexState,
                           emit: (UsageEvent) -> Void) -> Int64 {
        guard let fh = FileHandle(forReadingAtPath: path) else { return start }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: UInt64(start)) } catch { return start }
        let needles = src.needles.map { Array($0.utf8) }
        var offset = start
        var carry = Data()
        while true {
            // Foundation objects from JSONSerialization are autoreleased: drain them every 8 MB
            // chunk, or a multi-GB first scan piles them all up until the pass ends.
            let more: Bool = autoreleasepool {
                guard let chunk = try? fh.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
                carry.append(chunk)
                guard let lastNL = carry.lastIndex(of: 0x0A) else { return true }
                let complete = carry[carry.startIndex...lastNL]
                for line in Self.matchingLines(complete, needles: needles) {
                    guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    let e: UsageEvent?
                    switch src.format {
                    case .claude: e = LogParsers.claude(obj)
                    case .codex: e = LogParsers.codex(obj, state: &codex)
                    case .gemini: e = LogParsers.gemini(obj)
                    case .cline: e = nil
                    }
                    if let e { emit(e) }
                }
                offset += Int64(complete.count)
                carry = Data(carry[carry.index(after: lastNL)...])
                return true
            }
            if !more { break }
        }
        return offset
    }

    /// Lines (in file order) containing any needle; found with memmem so the rest is never decoded.
    static func matchingLines(_ buf: Data, needles: [[UInt8]]) -> [Data] {
        if needles.isEmpty { return buf.split(separator: 0x0A).map { Data($0) } }
        var ranges: [Range<Int>] = []
        buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let n = raw.count
            var starts = Set<Int>()
            for needle in needles {
                var pos = 0
                while pos < n {
                    guard let hit = needle.withUnsafeBufferPointer({ memmem(base + pos, n - pos, $0.baseAddress, $0.count) }) else { break }
                    let at = base.distance(to: UnsafeRawPointer(hit))
                    var s = at
                    while s > 0 && raw[s - 1] != 0x0A { s -= 1 }
                    var e = at
                    while e < n && raw[e] != 0x0A { e += 1 }
                    if starts.insert(s).inserted { ranges.append(s..<e) }
                    pos = e + 1
                }
            }
        }
        let base = buf.startIndex
        return ranges.sorted { $0.lowerBound < $1.lowerBound }.map { buf[(base + $0.lowerBound)..<(base + $0.upperBound)] }.map { Data($0) }
    }
}
