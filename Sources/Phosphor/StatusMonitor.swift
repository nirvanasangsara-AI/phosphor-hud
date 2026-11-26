import Foundation
import PhosphorCore

/// Polls the public status pages that cover the providers on screen (every 5 minutes).
@MainActor
final class StatusMonitor: ObservableObject {
    /// provider id (or "codex@work"-style profile id) → current problem; absent = operational.
    @Published private(set) var health: [String: ProviderHealth] = [:]
    @Published private(set) var checkedAt: Date?
    private var busy = false

    func refreshIfDue(ids: [String]) {
        guard !busy, checkedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        busy = true
        let refs: [(String, StatusRef)] = ids.compactMap { id in
            let base = id.split(separator: "@").first.map(String.init) ?? id
            return ProviderCatalog.spec(base)?.status.map { (id, $0) }
        }
        let feeds = Set(refs.map(\.1.feed))
        Task {
            var parsed: [StatusRef.Feed: FeedStatus] = [:]
            await withTaskGroup(of: (StatusRef.Feed, FeedStatus?).self) { g in
                for f in feeds {
                    g.addTask {
                        var r = URLRequest(url: StatusFeeds.url(f)); r.timeoutInterval = 15
                        guard let (d, resp) = try? await URLSession.shared.data(for: r),
                              (resp as? HTTPURLResponse)?.statusCode == 200 else { return (f, nil) }
                        return (f, try? StatusFeeds.parse(d, feed: f))
                    }
                }
                for await (f, s) in g { if let s { parsed[f] = s } }
            }
            var out: [String: ProviderHealth] = [:]
            for (id, ref) in refs {
                if let feed = parsed[ref.feed], let h = StatusFeeds.health(for: ref, in: feed) { out[id] = h }
            }
            health = out
            checkedAt = Date()
            busy = false
        }
    }
}
