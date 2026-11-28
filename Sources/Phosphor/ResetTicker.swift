import AppKit
import Combine
import SwiftUI
import PhosphorCore

/// Reset news for the top strip. A configured feed URL is tried first. If it is blank or
/// unreachable, the three public status feeds are read directly. Failures stay quiet.
@MainActor
final class ResetFeedService: ObservableObject {
    @Published private(set) var items: [ResetFeed.Item] = []
    private let demo: Bool
    private var last: Date?
    private var task: Task<Void, Never>?

    init(demo: Bool) {
        self.demo = demo
        if demo { items = Self.demoItems }
    }

    func visible(includeRumors: Bool) -> [ResetFeed.Item] {
        ResetFeed.filtered(items, includeRumors: includeRumors)
    }

    func refreshIfDue(force: Bool = false) {
        guard !demo, Prefs.shared.showResetTicker else { return }
        guard force || last.map { Date().timeIntervalSince($0) >= ResetFeed.refreshInterval } ?? true else { return }
        last = Date()
        task?.cancel()
        task = Task { await load() }
    }

    private func load() async {
        let raw = Prefs.shared.resetFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            if let data = try? await fetch(url), let parsed = try? ResetFeed.parse(json: data) {
                guard !Task.isCancelled else { return }
                items = parsed
                return
            }
        }
        var batches: [[ResetFeed.Item]] = []
        for url in ResetFeed.statusFeedURLs {
            if let data = try? await fetch(url) {
                batches.append(ResetFeed.parseRSS(data, source: url))
            }
        }
        guard !Task.isCancelled, !batches.isEmpty else { return }
        items = ResetFeed.mergeStatus(batches)
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static var demoItems: [ResetFeed.Item] {
        let now = Date()
        return [
            .init(id: "demo-codex", source: "x", handle: "Tibo", text: "Codex limits reset early",
                  url: "https://x.com", postedAt: now.addingTimeInterval(-3600), kind: .official,
                  expectedResetAt: now.addingTimeInterval(5 * 3600), expiresAt: now.addingTimeInterval(86_400),
                  confidence: 0.9, official: true, product: "codex"),
            .init(id: "demo-claude", source: "x", handle: "someone", text: "Claude free reset usable until tonight",
                  url: "https://status.claude.com", postedAt: now.addingTimeInterval(-1800), kind: .rumor,
                  expectedResetAt: now.addingTimeInterval(8 * 3600), expiresAt: now.addingTimeInterval(86_400),
                  confidence: 0.3, official: false, product: "claude"),
        ]
    }
}

struct ResetTickerBar: View {
    @ObservedObject var feed: ResetFeedService
    @ObservedObject private var prefs = Prefs.shared
    let theme: Theme
    @State private var index = 0
    @State private var paused = false

    var body: some View {
        let items = feed.visible(includeRumors: prefs.includeRumors)
        if items.isEmpty {
            EmptyView()
        } else {
            let item = items[index % items.count]
            Button {
                if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
            } label: {
                line(item)
            }
            .buttonStyle(.plain)
            .onHover { paused = $0 }
            .onReceive(Timer.publish(every: ResetFeed.rotateInterval, on: .main, in: .common).autoconnect()) { _ in
                guard !paused, items.count > 1 else { return }
                index = (index + 1) % items.count
            }
            .help(T.t("ticker.help"))
        }
    }

    private func line(_ item: ResetFeed.Item) -> some View {
        let ink = item.isRumor ? theme.dim : theme.fg
        return HStack(spacing: 6) {
            if item.isRumor {
                Text(theme.name(T.t("ticker.rumor")))
                    .font(theme.font(8, .semibold))
                    .foregroundStyle(theme.dim)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(theme.fg.opacity(0.1)))
            }
            Text(theme.name(item.text))
                .font(theme.font(10, .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("@\(item.handle)")
                .foregroundStyle(theme.dim)
            Text(T.ago(item.postedAt))
                .foregroundStyle(theme.dim)
            if let until = item.expectedResetAt, until > Date() {
                Text(theme.name(T.t("ticker.until", T.countdown(to: until))))
                    .foregroundStyle(ink)
            }
        }
        .font(theme.font(9))
        .lineLimit(1)
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
    }
}
