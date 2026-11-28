import SwiftUI
import Charts
import PhosphorCore

/// Last 14 days of tokens (or API-equivalent cost) from local session logs, stacked by tool.
struct UsageChartView: View {
    @ObservedObject var logs: UsageLogs
    @ObservedObject var prefs = Prefs.shared
    let theme: Theme

    private var days: [String] {
        (0..<14).reversed().map { DayKey.of(Date().addingTimeInterval(-Double($0) * 86_400)) }
    }

    private var rows: [UsageLedger.DayTotal] {
        let keep = Set(days)
        return logs.daily.filter { keep.contains($0.day) }
    }

    /// Dollars only when a price table is actually loaded. An empty table must not draw a $0 chart.
    private var showCost: Bool { prefs.chartCost && logs.pricesReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(theme.dim.opacity(0.18)).frame(height: 1).padding(.bottom, 2)
            HStack(spacing: 6) {
                Text(theme.name(showCost ? "API-equivalent cost · 14 days" : "Tokens · 14 days"))
                    .font(theme.font(10, .semibold)).foregroundStyle(theme.dim)
                Spacer(minLength: 4)
                Button { prefs.chartCost.toggle() } label: {
                    Text(theme.name(showCost ? "tokens" : "cost")).font(theme.font(9, .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(theme.fg.opacity(0.12)))
                        .foregroundStyle(theme.fg)
                }
                .buttonStyle(.plain)
                .help("Switch between tokens and estimated API-equivalent cost")
            }
            if rows.isEmpty {
                Text(theme.name(logs.scanning ? "Reading local logs… (first scan can take a few minutes)" : "No token usage in local logs yet"))
                    .font(theme.font(9)).foregroundStyle(theme.dim)
            } else {
                Chart(rows) { r in
                    BarMark(x: .value("Day", DayKey.date(r.day) ?? Date(), unit: .day),
                            y: .value(showCost ? "USD" : "Tokens", showCost ? r.cost : Double(r.tokens)))
                        .foregroundStyle(by: .value("Tool", ProviderInfo.lookup(r.source).name))
                }
                .chartForegroundStyleScale(domain: sourcesShown.map { ProviderInfo.lookup($0).name },
                                           range: sourcesShown.map { theme.tint(ProviderInfo.lookup($0)) })
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 3)) { v in
                        AxisValueLabel(centered: true) {
                            if let d = v.as(Date.self) {
                                Text(Self.axisDay.string(from: d)).font(theme.font(8)).foregroundStyle(theme.dim)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(theme.dim.opacity(0.25))
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(showCost ? (d == d.rounded() ? "$" + Fmt.compact(d) : Fmt.amount(d, "usd")) : Fmt.compact(d)).font(theme.font(8)).foregroundStyle(theme.dim)
                            }
                        }
                    }
                }
                .chartLegend(position: .bottom, spacing: 4) {
                    HStack(spacing: 8) {
                        ForEach(sourcesShown, id: \.self) { id in
                            HStack(spacing: 3) {
                                Circle().fill(theme.tint(ProviderInfo.lookup(id))).frame(width: 6, height: 6)
                                Text(theme.name(ProviderInfo.lookup(id).name)).font(theme.font(8)).foregroundStyle(theme.dim)
                            }
                        }
                    }
                }
                .frame(height: 110)
            }
            Group {
                if !logs.pricesReady && logs.total(days: 30).cost == 0 {
                    Text(theme.name(T.t("logs.priceMissing")))
                        .font(theme.font(9, .semibold)).foregroundStyle(theme.warn).lineLimit(1)
                } else {
                    HStack(spacing: 8) {
                        summary("Today", logs.total(days: 1))
                        summary("7D", logs.total(days: 7))
                        summary("30D", logs.total(days: 30))
                    }
                }
            }
            .help("Tokens counted from Claude Code / Codex / Gemini CLI / Cline / Roo Code logs on this Mac, priced at "
                  + "API list rates (LiteLLM's public price table). Subscriptions don't bill this way: it shows what the same "
                  + "use would cost on the API. Models without a list price are counted but not priced.")
        }
    }

    /// "11/14" in every locale (the system's "11. 14." reads oddly on a tiny axis).
    private static let axisDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M/d"; return f
    }()

    private var sourcesShown: [String] {
        UsageLogs.sources.filter { s in rows.contains { $0.source == s } }
    }

    private func summary(_ label: String, _ s: UsageLedger.Summary) -> some View {
        HStack(spacing: 3) {
            Text(theme.name(label)).font(theme.font(9)).foregroundStyle(theme.dim)
                .lineLimit(1).fixedSize()
            Text(Fmt.amount(s.cost, "usd")).font(theme.font(10, .bold)).monospacedDigit().foregroundStyle(theme.fg)
                .lineLimit(1).fixedSize()
            Text(Fmt.compact(Double(s.tokens))).font(theme.font(9)).monospacedDigit().foregroundStyle(theme.dim)
                .lineLimit(1).fixedSize()
        }
    }
}
