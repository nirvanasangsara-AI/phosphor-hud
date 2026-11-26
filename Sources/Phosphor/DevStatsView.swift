import SwiftUI
import AppKit
import PhosphorCore

/// Compact strip: PRs and commits, ROI, cost per PR, velocity and the benchmark tier. Hover for details.
struct DevStatsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var dev: DevStatsService
    let theme: Theme
    @StateObject private var hover = HoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let e = Efficiency(store: store, dev: dev) {
                strip(e)
            } else {
                Text(theme.name(dev.problem ?? (dev.busy ? "Reading GitHub activity…" : "GitHub activity: waiting for gh")))
                    .font(theme.font(9)).foregroundStyle(theme.dim)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.fg.opacity(0.06)))
        .contentShape(Rectangle())
        .onHover { inside in
            let h = hover
            h.inside = inside
            if inside { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if h.inside { h.showCard = true } } }
            else { h.showCard = false }
        }
        .popover(isPresented: $hover.showCard, arrowEdge: .leading) {
            if let e = Efficiency(store: store, dev: dev) {
                DevStatsDetail(e: e, store: store, dev: dev, theme: theme)
                    .environment(\.colorScheme, .dark)
                    .presentationBackground(Color(white: 0.11))
            }
        }
    }

    @ViewBuilder private func strip(_ e: Efficiency) -> some View {
        let c = e.counts
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.dim)
            Text(theme.name("merged PRs")).foregroundStyle(theme.dim)
            Text("\(c.mergedToday)/\(c.merged7)/\(c.merged30)").foregroundStyle(theme.fg).fontWeight(.semibold)
                .help("Merged PRs today / last 7 days / last 30 days")
            Spacer(minLength: 2)
            Text(theme.name(e.placement.label))
                .font(theme.font(9, .bold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(theme.fg.opacity(e.placement.tier == "Elite" ? 0.22 : 0.12)))
                .foregroundStyle(theme.fg)
                .fixedSize()
                .help("vs \(PRBenchmark.source)")
        }
        .font(theme.font(10)).monospacedDigit().lineLimit(1)
        HStack(spacing: 6) {
            Text(theme.name("commits")).foregroundStyle(theme.dim)
            Text("\(c.commits7.formatted())/\(c.commits30.formatted())").foregroundStyle(theme.fg)
                .help("GitHub commits last 7 days / last 30 days")
            Spacer(minLength: 2)
            if let r = e.roi {
                Text(theme.name("ROI \(String(format: r >= 10 ? "%.0f" : "%.1f", r))x")).foregroundStyle(theme.fg).fontWeight(.semibold)
            }
            if let p = e.costPerPR { Text(theme.name("\(e.money(p, store: store))/PR")).foregroundStyle(theme.dim) }
        }
        .font(theme.font(10)).monospacedDigit().lineLimit(1)
        HStack(spacing: 6) {
            Text(theme.name("velocity \(String(format: "%.1f", c.prsPerWeek)) PR/wk · \(Int(c.commitsPerWeek.rounded())) commits/wk"))
                .foregroundStyle(theme.dim)
            if let t = DevCounts.trend(c.mergedWeeks), let ch = t.change {
                Text((ch >= 0 ? "▲" : "▼") + "\(Int(abs(ch * 100).rounded()))%")
                    .foregroundStyle(ch >= 0 ? theme.fg : theme.warn)
                    .help("Merged PRs in the last 7 days (\(t.current)) vs the 3 weeks before (avg \(String(format: "%.1f", t.previousAverage)))")
            }
            Spacer(minLength: 4)
            if let tp = e.tokensPerPR { Text(theme.name("\(Fmt.compact(tp)) tok/PR")).foregroundStyle(theme.dim) }
        }
        .font(theme.font(9)).monospacedDigit().lineLimit(1)
    }
}

struct DevStatsDetail: View {
    let e: Efficiency
    let store: UsageStore
    let dev: DevStatsService
    let theme: Theme

    var body: some View {
        let c = e.counts
        VStack(alignment: .leading, spacing: 6) {
            Text(theme.name("GitHub · \(c.login)")).font(theme.font(12, .bold)).foregroundStyle(theme.fg)
            grid([("", "today", "7D", "30D"),
                  ("PRs merged", "\(c.mergedToday)", "\(c.merged7)", "\(c.merged30)"),
                  ("PRs opened", "\(c.openedToday)", "\(c.opened7)", "\(c.opened30)"),
                  ("Commits (GitHub)", "\(c.commitsToday)", "\(c.commits7)", "\(c.commits30)")])
            if let l7 = c.localCommits7, let l30 = c.localCommits30 {
                Text(theme.name("Local git commits (your email, \(c.localRepos ?? 0) repos in ~/Projects etc., not deduped with GitHub): 7D \(l7) · 30D \(l30)"))
                    .font(theme.font(9)).foregroundStyle(theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            weekly("Merged PRs / week", c.mergedWeeks)
            weekly("Commits / week", c.commitWeeks)
            Divider()
            Text(theme.name("Efficiency (\(e.days)D local logs)")).font(theme.font(10, .semibold)).foregroundStyle(theme.fg)
            line("API-equivalent value", Fmt.amount(e.apiValue, "usd") + " · \(Fmt.compact(Double(e.tokens))) tokens")
            line("Subscriptions / month", e.spendText + (e.spendUSD.map { " ≈ " + Fmt.amount($0, "usd") } ?? ""))
            if let r = e.roi { line("Subscription ROI", String(format: "%.1fx", r) + " (value ÷ \(e.days)/30 of monthly spend)") }
            if let p = e.costPerPR { line("Cost per merged PR", e.money(p, store: store) + " (monthly spend ÷ 30D PRs)") }
            if let v = e.valuePerPR { line("API value per PR", Fmt.amount(v, "usd")) }
            if let t = e.tokensPerPR { line("Tokens per PR", Fmt.compact(t)) }
            Divider()
            Text(theme.name("\(e.placement.label) · \(String(format: "%.1f", c.prsPerWeek)) merged PRs/week"))
                .font(theme.font(10, .semibold)).foregroundStyle(theme.fg)
            Text(theme.name("vs " + PRBenchmark.source))
                .font(theme.font(8)).foregroundStyle(theme.dim).fixedSize(horizontal: false, vertical: true)
            Text(theme.name("Not a live leaderboard. GitHub counts via gh api search (your gh login). "
                            + "FX: open.er-api.com" + (dev.fxDate.map { " (\($0))" } ?? "") + ". Updated \(Fmt.clock(c.fetchedAt, now: Date()))."))
                .font(theme.font(8)).foregroundStyle(theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 340)
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(theme.name(k)).foregroundStyle(theme.dim)
            Spacer(minLength: 6)
            Text(theme.name(v)).foregroundStyle(theme.fg).multilineTextAlignment(.trailing)
        }
        .font(theme.font(9)).monospacedDigit()
    }

    private func grid(_ rows: [(String, String, String, String)]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 2) {
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                GridRow {
                    Text(theme.name(r.0)).gridColumnAlignment(.leading).foregroundStyle(theme.dim)
                    Text(r.1); Text(r.2); Text(r.3)
                }
                .foregroundStyle(i == 0 ? theme.dim : theme.fg)
            }
        }
        .font(theme.font(9)).monospacedDigit()
    }

    private func weekly(_ title: String, _ weeks: [Int]) -> some View {
        let maxV = max(1, weeks.max() ?? 1)
        return VStack(alignment: .leading, spacing: 2) {
            Text(theme.name(title + " (oldest → newest)")).font(theme.font(8)).foregroundStyle(theme.dim)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(weeks.reversed().enumerated()), id: \.offset) { _, v in
                    VStack(spacing: 1) {
                        Text("\(v)").font(theme.font(8)).foregroundStyle(theme.fg)
                        RoundedRectangle(cornerRadius: 2).fill(theme.fg.opacity(0.6))
                            .frame(width: 34, height: max(2, 22 * CGFloat(v) / CGFloat(maxV)))
                    }
                }
            }
        }
    }
}

/// A shareable card for the month so far, saved as PNG and copied to the clipboard.
@MainActor
enum Receipt {
    static func text(_ e: Efficiency, store: UsageStore) -> String {
        let c = e.counts
        var t = """
        PHOSPHOR · \(c.login) · last 30 days
        PRs merged \(c.merged30) · opened \(c.opened30) · commits \(c.commits30)
        Velocity \(String(format: "%.1f", c.prsPerWeek)) PRs/wk · \(Int(c.commitsPerWeek.rounded())) commits/wk
        API-equivalent value (\(e.days)D logs) \(Fmt.amount(e.apiValue, "usd")) · \(Fmt.compact(Double(e.tokens))) tokens
        Subscriptions \(e.spendText)/mo
        """
        if let r = e.roi { t += "\nROI \(String(format: "%.1f", r))x" }
        if let p = e.costPerPR { t += " · \(e.money(p, store: store))/PR" }
        t += "\n\(e.placement.label) vs LinearB 2026 merge-frequency benchmark"
        return t
    }

    static func save(store: UsageStore) {
        guard let e = Efficiency(store: store, dev: store.dev) else { return }
        let body = text(e, store: store)
        let card = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(body.split(separator: "\n").enumerated()), id: \.offset) { i, l in
                Text(String(l)).font(.system(size: i == 0 ? 15 : 12, weight: i == 0 ? .bold : .regular, design: .monospaced))
            }
        }
        .foregroundStyle(Color.green)
        .padding(20)
        .background(Color.black)
        let r = ImageRenderer(content: card)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let dir = Paths.support.appendingPathComponent("receipts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        let url = dir.appendingPathComponent("phosphor-\(f.string(from: Date())).png")
        try? png.write(to: url, options: .atomic)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img, body as NSString])
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
