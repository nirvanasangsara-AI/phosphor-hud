import SwiftUI
import AppKit
import PhosphorCore

// MARK: - Root

struct RootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var registry = ThemeRegistry.shared
    var onResize: (CGSize) -> Void

    var body: some View {
        let theme = registry.theme(prefs.theme)
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            if prefs.hudUserSized, prefs.hudWidth >= 240, prefs.hudHeight >= 140 {
                ScrollView(.vertical, showsIndicators: false) {
                    panel(theme, now: ctx.date)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                panel(theme, now: ctx.date)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { onResize($0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "Logs 7D: 182M tokens · ≈$412 API-equivalent" for tools whose session logs Phosphor reads.
    private func loggedLine(_ id: String) -> String? {
        let waiting = id == "claude" ? store.claudeWaiting : nil
        guard ["claude", "codex"].contains(id), let w = store.logs.snapshot.week[id], w.tokens > 0 else { return waiting }
        if !store.logs.pricesReady && w.cost == 0 {
            let line = "Logs 7D: \(Fmt.compact(Double(w.tokens))) tokens · \(T.t("logs.priceMissing"))"
            return waiting.map { "\($0).\n\(line)" } ?? line
        }
        let cost = w.cost > 0 ? " · ≈\(Fmt.amount(w.cost, "usd")) API-equivalent" : ""
        let unpriced = store.logs.pricesReady && w.unpricedTokens > 0 ? " (\(Fmt.compact(Double(w.unpricedTokens))) unpriced)" : ""
        let line = "Logs 7D: \(Fmt.compact(Double(w.tokens))) tokens\(cost)\(unpriced)"
        return waiting.map { "\($0).\n\(line)" } ?? line
    }

    private func width(_ theme: Theme, count: Int) -> CGFloat {
        if theme.layout == .raid { return count > 3 ? 390 : 204 }
        return prefs.compact ? theme.compactWidth : theme.width
    }

    private func panelWidth(_ theme: Theme, count: Int) -> CGFloat {
        if prefs.hudUserSized, prefs.hudWidth >= 240 { return prefs.hudWidth }
        return width(theme, count: count)
    }

    @ViewBuilder
    private func panel(_ theme: Theme, now: Date) -> some View {
        let items = store.visible
        VStack(alignment: .leading, spacing: prefs.compact ? 6 : 10) {
            if prefs.showResetTicker {
                ResetTickerBar(feed: store.resetNews, theme: theme)
            }
            Header(theme: theme, store: store, now: now, count: items.count)
            if !store.logs.pricesReady {
                Button { store.logs.refreshPrices() } label: {
                    Text(theme.name(T.t("logs.priceBanner")))
                        .font(theme.font(10, .semibold))
                        .foregroundStyle(theme.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(T.t("logs.priceBanner"))
            } else if store.logs.priceOrigin == "bundle" {
                Text(theme.name(T.t("logs.bundledPrices", store.logs.bundledPriceDate ?? "")))
                    .font(theme.font(9)).foregroundStyle(theme.dim).lineLimit(1)
            }
            if prefs.showDevStats && theme.layout != .raid { DevStatsView(store: store, dev: store.dev, theme: theme) }
            if items.isEmpty {
                Text(theme.name("No providers yet. Log in to claude / codex / gemini, or add ~/.config/phosphor/providers.json"))
                    .font(theme.font(10))
                    .foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if theme.layout == .raid {
                RaidGrid(items: items, theme: theme, compact: prefs.compact, now: now, revivedAt: store.revivedAt)
                if !prefs.compact, let line = store.log.last { CombatLog(line: line, theme: theme) }
                if prefs.showChart { UsageChartView(logs: store.logs, theme: theme) }
            } else {
                let labelWidth = ProviderRow.labelWidth(items.flatMap(\.windows), theme: theme)
                let segments = HUDSegment.build(items)
                let scope = segments.map(\.id)
                ForEach(segments) { seg in
                    switch seg {
                    case .single(let s):
                        ProviderRow(snap: s, theme: theme, compact: prefs.compact, now: now, labelWidth: labelWidth,
                                    connect: Connect.supported.contains(s.id) ? { store.connect(s.id) } : nil,
                                    note: store.connectNotes[s.id], account: store.accounts[s.id],
                                    health: store.status.health[s.id], logged: loggedLine(s.id))
                            .reorderable(s.id, scope: scope, store: store, theme: theme)
                    case .group(let f, let members):
                        FamilyGroupView(family: f, members: members, theme: theme, compact: prefs.compact, now: now,
                                        labelWidth: labelWidth, store: store)
                            .reorderable(f.key, scope: scope, store: store, theme: theme)
                    }
                }
                if prefs.showChart { UsageChartView(logs: store.logs, theme: theme) }
            }
            PanelIdentity(theme: theme)
        }
        .id(prefs.language)   // redraw burn-rate lines and menus when the language changes
        .modifier(Glow(theme: theme))
        .padding(14)
        .frame(width: panelWidth(theme, count: items.count), alignment: .leading)
        .background {
            ZStack {
                BackdropView(theme: theme)
                if theme.rain { MatrixRain(color: theme.fg).allowsHitTesting(false) }   // behind the text
            }
        }
        .overlay(Effects(theme: theme))
        .clipShape(RoundedRectangle(cornerRadius: theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                .strokeBorder(theme.border ?? .clear, lineWidth: theme.borderWidth)
        )
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Header

struct Header: View {
    let theme: Theme
    @ObservedObject var store: UsageStore
    let now: Date
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(theme.headerText(online: count))
                    .font(theme.font(11, .semibold))
                    .foregroundStyle(theme.dim)
                if theme.cursor { BlinkCursor(color: theme.fg) }
                Spacer(minLength: 8)
                Text(status)
                    .font(theme.font(10))
                    .foregroundStyle(theme.dim)
                if !Prefs.shared.hidden.isEmpty {
                    HiddenServicesButton(theme: theme, store: store)
                }
                Button { Prefs.shared.showChart.toggle() } label: {
                    Image(systemName: Prefs.shared.showChart ? "chart.bar.fill" : "chart.bar")
                        .font(.system(size: 10)).foregroundStyle(theme.dim)
                }
                .buttonStyle(.plain)
                .help("Show or hide the 14-day usage chart (tokens and API-equivalent cost from local logs)")
            }
            if let t = store.monthlyTotal {
                HStack(spacing: 6) {
                    Text(theme.name("Monthly")).font(theme.font(10)).foregroundStyle(theme.dim)
                    Text(t.text).font(theme.font(12, .bold)).monospacedDigit().foregroundStyle(theme.fg)
                    Spacer(minLength: 4)
                    Text(theme.name("price read for \(t.read) of \(t.of)")).font(theme.font(9)).foregroundStyle(theme.dim)
                }
                .help("Sum of the monthly prices each service reported. Services whose price couldn't be read are left out, never guessed.")
            }
        }
    }

    private var status: String {
        if store.refreshing { return theme.name("sync…") }
        guard let t = store.lastRefresh else { return "" }
        let m = Int(now.timeIntervalSince(t) / 60)
        return theme.name(m < 1 ? "live" : "\(m)m ago")
    }
}

/// Quiet product mark at the bottom of the usage panel, so a screenshot names the app.
/// The leading box is reserved for a logo image; Φ is the text stand-in until one exists.
/// Color is each theme's `dim`, the same muted ink as secondary labels, so it stays
/// legible on Clean, Retro, Matrix, Glasses, and Raid without a second palette.
struct PanelIdentity: View {
    let theme: Theme

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Text("Φ")
                .font(theme.font(11, .medium))
                .foregroundStyle(theme.dim)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Text("Phosphor")
                .font(theme.font(9, .medium))
                .foregroundStyle(theme.dim)
            Text(Phosphor.version)
                .font(theme.font(9))
                .foregroundStyle(theme.dim)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Phosphor.identity)
        .help(Phosphor.identity)
    }
}

struct BlinkCursor: View {
    let color: Color
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
            Rectangle().fill(color.opacity(on ? 0.9 : 0)).frame(width: 6, height: 11)
        }
    }
}

// MARK: - List rows (Clean / Retro / Matrix / Glasses)

struct ProviderRow: View {
    let snap: ProviderSnapshot
    let theme: Theme
    let compact: Bool
    let now: Date
    var labelWidth: CGFloat = 34
    var connect: (() -> Void)? = nil
    var note: String? = nil
    var account: AccountInfo? = nil
    /// The provider's public status page reports a problem.
    var health: ProviderHealth? = nil
    /// Token totals from local session logs, for the hover card.
    var logged: String? = nil
    @StateObject private var hover = HoverState()
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Group {
            if compact { compactRow } else { fullRow }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            let h = hover
            h.inside = inside
            if inside {
                let ready = account != nil || logged != nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if h.inside && ready { h.showCard = true } }
            } else {
                h.showCard = false
            }
        }
        .popover(isPresented: $hover.showCard, arrowEdge: .leading) {
            if let account {
                AccountCard(name: snap.info.name, account: account, theme: theme, health: health, logged: logged)
                    .environment(\.colorScheme, .dark)
                    .presentationBackground(Color(white: 0.11))
            } else if let logged {
                Text(logged)
                    .font(.system(size: 11))
                    .padding(12)
                    .frame(width: 280, alignment: .leading)
                    .environment(\.colorScheme, .dark)
                    .presentationBackground(Color(white: 0.11))
            }
        }
        .contextMenu {
            Button(T.t("hide.button")) { Prefs.shared.hideProvider(snap.id) }
        }
        .overlay(alignment: .topTrailing) {
            if hover.inside {
                Button { Prefs.shared.hideProvider(snap.id) } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.dim.opacity(0.9))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help(T.t("hide.help"))
            }
        }
    }

    /// A coloured dot when the provider's status page reports trouble (hover for what).
    @ViewBuilder private var statusDot: some View {
        if let health {
            Circle()
                .fill(health.level >= .partialOutage ? theme.danger : theme.warn)
                .frame(width: 6, height: 6)
                .help("\(health.level.label): \(health.summary) — \(health.pageURL)")
        }
    }

    /// Reset / refill credits worth seeing at a glance (Grok Bot's extra credit already has its own bar).
    private var creditLines: [CreditInfo] {
        guard let account else { return [] }
        return account.credits.filter { !(snap.id == "grokbot" && $0.title == "Extra usage credit") }
    }

    private var title: String {
        (theme.prompt.map { $0 + " " } ?? "") + theme.name(snap.info.name)
    }

    private var compactRow: some View {
        HStack(spacing: 6) {
            Badge(info: snap.info, theme: theme, size: 14)
            Text(theme.name(snap.info.name))
                .font(theme.font(11, .semibold))
                .foregroundStyle(theme.tint(snap.info))
                .lineLimit(1)
            statusDot
            Spacer(minLength: 4)
            if case .idle = snap.state {
                Text(theme.name(T.t("status.signedIn"))).font(theme.font(10)).foregroundStyle(theme.dim)
            } else if snap.windows.isEmpty {
                Text(theme.name("off")).font(theme.font(10)).foregroundStyle(theme.dim)
            }
            ForEach(snap.windows.prefix(2)) { w in
                Text(w.gauged ? "\(Int(w.usedPercent.rounded()))%" : (w.amountText ?? ""))
                    .font(theme.font(11, .bold))
                    .monospacedDigit()
                    .foregroundStyle(w.forecast?.warnsBeforeReset == true ? theme.warn : color(for: w))
            }
        }
    }

    private var fullRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Badge(info: snap.info, theme: theme, size: 18)
                Text(title)
                    .font(theme.font(13, .semibold))
                    .foregroundStyle(theme.tint(snap.info))
                    .lineLimit(1)
                statusDot
                if let plan = snap.plan {
                    let stale = snap.planOverride != nil && account?.staleText != nil
                    Text(theme.name(stale ? "⚠︎ " + plan : plan)).font(theme.font(10))
                        .foregroundStyle(stale ? theme.warn : theme.dim)
                        .opacity(stale ? 0.55 : 1)
                        .help(stale ? (account?.staleText ?? "") : "")
                }
                Spacer(minLength: 0)
            }
            if let stale = account?.staleText {
                Text(theme.name("⚠︎ billing screen \(stale.lowercased())"))
                    .font(theme.font(9)).foregroundStyle(theme.warn).opacity(0.75).lineLimit(1)
            }
            switch snap.state {
            case .loading:
                Text("…").font(theme.font(10)).foregroundStyle(theme.dim)
            case .ok(let windows, _):
                ForEach(windows) { w in
                    WindowLine(w: w, theme: theme, tint: color(for: w), now: now, labelWidth: labelWidth)
                        .opacity(snap.staleNote != nil && w.gauged ? 0.6 : 1)
                }
                if let cached = snap.staleNote {
                    Text(theme.name("◷ " + T.stale(cached, now: now))).font(theme.font(9)).foregroundStyle(theme.dim).lineLimit(1)
                        .help(T.t("stale.help"))
                }
                ForEach(creditLines, id: \.self) { c in
                    Text(theme.name("↻ \(T.credit(c.title)) \(c.amount)" + (c.expires.map { " · until \(Fmt.shortDate($0))" } ?? "")))
                        .font(theme.font(9)).foregroundStyle(theme.tint(snap.info)).lineLimit(1)
                }
            case .idle(let m, _):
                // Signed in and fine: nothing to fix, so no Connect button.
                Text(theme.name(ClaudeSource.isWaiting(m) ? T.t("stale.logs") : m)).font(theme.font(9)).foregroundStyle(theme.dim).lineLimit(1)
            case .error(let m), .unavailable(let m):
                HStack(spacing: 8) {
                    if let note {
                        Text(note).font(theme.font(9)).foregroundStyle(theme.tint(snap.info))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(theme.name(m)).font(theme.font(9)).foregroundStyle(theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // Only for sign-in problems: not for rate limits or server errors.
                    if let connect, note != nil || snap.needsSignIn {
                        Button(action: connect) {
                            Text(theme.name(note != nil && Connect.pending.contains(snap.id) ? "Show" : "Connect")).font(theme.font(10, .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(theme.tint(snap.info).opacity(0.22)))
                                .foregroundStyle(theme.tint(snap.info))
                        }
                        .buttonStyle(.plain)
                        .help("Opens \(snap.info.name)'s official sign-in in Terminal. Phosphor connects when it's done.")
                    }
                }
            }
        }
    }

    /// Wide enough for the longest label on screen ("7D FABLE"), so every bar starts at the same x.
    static func labelWidth(_ windows: [UsageWindow], theme: Theme) -> CGFloat {
        let longest = windows.map { theme.name($0.label).count }.max() ?? 0
        return max(34, CGFloat(longest) * 7.2 + 4)
    }

    private func color(for w: UsageWindow) -> Color {
        guard w.gauged else { return theme.tint(snap.info) }
        let mode = IconColor.Mode(rawValue: prefs.iconColorMode) ?? .pace
        let band = IconColor.band(mode: mode, usedPercent: w.usedPercent,
                                  elapsedFraction: w.pacePercent.map { $0 / 100 }, forecast: w.forecast)
        guard band != .neutral else {
            return w.usedPercent >= 90 ? theme.danger : theme.tint(snap.info)
        }
        return Color(nsColor: CRTIcon.swatch(band))
    }
}

struct WindowLine: View {
    let w: UsageWindow
    let theme: Theme
    let tint: Color
    let now: Date
    var labelWidth: CGFloat = 34
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(theme.name(w.label))
                    .font(theme.font(10, .medium))
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .leading)
                if w.gauged {
                    UsageBar(percent: w.usedPercent, pace: w.pacePercent, style: theme.bar, theme: theme, tint: tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(Int(w.usedPercent.rounded()))%")
                        .font(theme.font(12, .bold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .frame(width: 40, alignment: .trailing)
                } else {
                    // No limit to draw against: the number is the reading ("820K tokens", "$4.20 left").
                    Text(theme.name(w.amountText ?? ""))
                        .font(theme.font(12, .bold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if w.isWeekly {
                    UsageSparkline(values: w.sparkline.isEmpty ? [w.gauged ? w.usedPercent : 0] : w.sparkline,
                                   tint: tint)
                }
                Text(T.countdown(to: w.resetsAt, now: now))
                    .font(theme.font(10))
                    .monospacedDigit()
                    .foregroundStyle(theme.dim)
                    .frame(width: 46, alignment: .trailing)
            }
            if w.gauged, let amount = w.amountText {   // balance with a known total
                Text(theme.name(amount)).font(theme.font(10)).monospacedDigit().foregroundStyle(theme.dim)
                    .lineLimit(1).padding(.leading, labelWidth + 8)
            }
            if !w.tags.isEmpty {
                TagRow(tags: w.tags, theme: theme, tint: tint)
                    .padding(.leading, labelWidth + 8)
            } else if let detail = w.detail, !detail.isEmpty {
                Text(theme.name(T.detail(detail))).font(theme.font(9)).foregroundStyle(theme.dim)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, labelWidth + 8)
            }
            if let f = w.forecast {
                ForecastLine(f: f, theme: theme, now: now).padding(.leading, labelWidth + 8)
            }
        }
    }
}

/// Status under every quota bar: rate and run-out time, or a standing label when a slope
/// can't be fitted yet (measuring / steady / cap / no active session).
struct ForecastLine: View {
    let f: Forecast
    let theme: Theme
    let now: Date
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        HStack(spacing: 4) {
            Text(theme.name(caption))
                .foregroundStyle(emphasis ? theme.warn : theme.dim)
            Spacer(minLength: 0)
            if let rate {
                Text(theme.name(rate))
                    .foregroundStyle(emphasis ? theme.warn : theme.dim)
            }
        }
        .font(theme.font(10, emphasis ? .semibold : .regular))
        .monospacedDigit()
        .lineLimit(1)
    }

    private var emphasis: Bool { f.warnsBeforeReset || f.kind == .limitReached }

    private var caption: String {
        switch f.kind {
        case .rate:
            if f.warnsBeforeReset, let hits = f.hitsLimitAt {
                return T.t("forecast.limit", T.clock(hits, now: now), T.countdown(to: hits, now: now))
            }
            if let r = f.atReset {
                return T.t("forecast.atReset", "\(Int(r.rounded()))")
            }
            return T.t("forecast.rateOnly", rateValue)
        case .steady:
            if let r = f.atReset {
                return T.t("forecast.steadyAtReset", "\(Int(r.rounded()))")
            }
            return T.t("forecast.steady")
        case .measuring:
            return T.t("forecast.measuring")
        case .limitReached:
            if let r = f.resetsAt, r > now {
                return T.t("forecast.limitReachedIn", T.countdown(to: r, now: now))
            }
            return T.t("forecast.limitReached")
        case .noSession:
            return T.t("forecast.noSession")
        }
    }

    private var rate: String? {
        switch f.kind {
        case .rate: return T.t("forecast.rate", rateValue)
        case .steady, .measuring: return T.t("forecast.rateIdle")
        case .limitReached, .noSession: return nil
        }
    }

    private var rateValue: String {
        f.ratePerHour >= 10 ? String(Int(f.ratePerHour.rounded())) : String(format: "%.1f", f.ratePerHour)
    }
}

// MARK: - Bars

struct UsageBar: View {
    let percent: Double
    let pace: Double?
    let style: BarStyle
    let theme: Theme
    let tint: Color

    private var p: Double { min(max(percent, 0), 100) / 100 }

    var body: some View {
        switch style {
        case .blocks:
            // As many cells as fit (10 pt monospaced ≈ 6.02 pt per glyph).
            GeometryReader { g in
                let n = max(6, Int(g.size.width / 6.1))
                let f = Int((p * Double(n)).rounded())
                Text(String(repeating: "█", count: f) + String(repeating: "░", count: n - f))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
        case .segments:
            let n = 16
            let f = Int((p * Double(n)).rounded())
            HStack(spacing: 2) {
                ForEach(0..<n, id: \.self) { i in
                    Rectangle().fill(i < f ? tint : theme.track).frame(height: 7)
                }
            }
            .overlay(paceTick)
        case .hairline:
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().stroke(tint.opacity(0.6), lineWidth: 0.8)
                    Rectangle().fill(tint).frame(width: max(0, (g.size.width - 3) * p)).padding(1.5)
                }
            }
            .frame(height: 7)
            .overlay(paceTick)
        case .capsule, .health:
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track)
                    if p > 0 { Capsule().fill(tint).frame(width: max(5, g.size.width * p)) }
                }
            }
            .frame(height: 6)
            .overlay(paceTick)
        }
    }

    /// Thin marker showing where an even pace would be right now.
    @ViewBuilder private var paceTick: some View {
        if let pace {
            GeometryReader { g in
                ZStack {
                    Rectangle()
                        .fill(theme.fg.opacity(0.75))
                        .frame(width: 1.5, height: g.size.height + 4)
                    Color.clear   // wider hover target than the 1.5 pt line
                        .frame(width: 12, height: g.size.height + 10)
                        .contentShape(Rectangle())
                        .help(Self.paceHelp(used: percent, pace: pace))
                }
                .offset(x: g.size.width * pace / 100 - g.size.width / 2)
                .frame(width: g.size.width, height: g.size.height)
            }
        }
    }

    static func paceHelp(used: Double, pace: Double) -> String {
        let diff = Int((used - pace).rounded())
        let verdict = diff > 2 ? T.t("pace.ahead", "\(diff)")
            : diff < -2 ? T.t("pace.under", "\(-diff)")
            : T.t("pace.on")
        return T.t("pace.help", "\(Int(pace.rounded()))", "\(Int(used.rounded()))", verdict)
    }
}

// MARK: - Raid frames (MMO-style unit frames: HP = quota left)

struct RaidGrid: View {
    let items: [ProviderSnapshot]
    let theme: Theme
    let compact: Bool
    let now: Date
    let revivedAt: [String: Date]

    var body: some View {
        let cols = items.count > 3 ? 2 : 1
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(176), spacing: 6), count: cols),
                  alignment: .leading, spacing: 6) {
            ForEach(items) {
                RaidFrame(snap: $0, theme: theme, compact: compact, now: now, revivedAt: revivedAt[$0.id])
            }
        }
    }
}

struct RaidFrame: View {
    let snap: ProviderSnapshot
    let theme: Theme
    let compact: Bool
    let now: Date
    let revivedAt: Date?

    static let reviveDuration: TimeInterval = 2.4

    private var primary: UsageWindow? { snap.gauges.first }
    private var secondary: UsageWindow? { snap.gauges.dropFirst().first }
    private var online: Bool { primary != nil }
    private var hp: Double { primary?.remainingPercent ?? 0 }
    private var critical: Bool { snap.windows.contains { $0.usedPercent >= 90 } }
    private var doom: Forecast? {
        snap.windows.compactMap(\.forecast).filter(\.warnsBeforeReset)
            .min { ($0.hitsLimitAt ?? .distantFuture) < ($1.hitsLimitAt ?? .distantFuture) }
    }

    private var hpColor: Color {
        if !online { return Color.gray }
        if hp > 50 { return theme.hpHigh }
        if hp > 20 { return theme.hpMid }
        return theme.hpLow
    }

    var body: some View {
        // Animate only while something is happening; idle frames stay static.
        let reviving = revivedAt.map { Date().timeIntervalSince($0) < Self.reviveDuration + 0.2 } ?? false
        if (critical && online) || reviving {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in frame(at: tl.date) }
        } else {
            frame(at: nil)
        }
    }

    /// 0…1 while the revive animation runs, nil otherwise.
    private func reviveProgress(_ t: Date?) -> Double? {
        guard let t, let r = revivedAt else { return nil }
        let p = t.timeIntervalSince(r) / Self.reviveDuration
        return (0..<1).contains(p) ? p : nil
    }

    private func frame(at t: Date?) -> some View {
        let revive = reviveProgress(t)
        // Pulse ~0.8 Hz between 35% and 100%.
        let pulse = t.map { 0.35 + 0.65 * (0.5 + 0.5 * sin($0.timeIntervalSinceReferenceDate * 2 * .pi / 1.25)) } ?? 1
        let fill = revive.map { hp * (1 - pow(1 - min(1, $0 / 0.7), 3)) } ?? hp   // ease-out refill

        return VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .leading) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(theme.track)
                        Rectangle()
                            .fill(LinearGradient(colors: [hpColor, hpColor.opacity(0.6)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: g.size.width * fill / 100)
                        if let p = revive {   // golden wash sweeping across the bar
                            LinearGradient(colors: [.clear, Color(hex: "#FFF3B0").opacity(0.9), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: g.size.width * 0.45)
                                .offset(x: g.size.width * (p * 1.5 - 0.45))
                                .blendMode(.screen)
                        }
                    }
                }
                HStack(spacing: 5) {
                    Rectangle().fill(online ? snap.info.color : .gray).frame(width: 3)
                        .padding(.vertical, 3)
                    Badge(info: snap.info, theme: theme, size: 16)
                    Text(snap.info.name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(online ? Color.white : .gray)
                        .shadow(color: .black, radius: 0, x: 1, y: 1)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(online ? "\(Int(hp.rounded()))%" : "—")
                        .font(.system(size: 11, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 0, x: 1, y: 1)
                }
                .padding(.trailing, 4)
            }
            .frame(height: 24)

            if !compact, let s = secondary {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(theme.track)
                        Rectangle().fill(theme.mana).frame(width: g.size.width * s.remainingPercent / 100)
                    }
                }
                .frame(height: 5)
            }

            if !compact {
                HStack {
                    status(revive: revive != nil || recentlyRevived(t))
                    Spacer()
                    Text(T.countdown(to: primary?.resetsAt, now: now))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.dim)
                }
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.4))
        .overlay(Rectangle().stroke((theme.border ?? .gray).opacity(0.6), lineWidth: 1))
        .overlay {
            if critical && online {
                Rectangle()
                    .stroke(theme.danger.opacity(pulse), lineWidth: 2)
                    .shadow(color: theme.danger.opacity(pulse * 0.9), radius: 5)
            }
        }
        .overlay {
            if let p = revive {   // halo + rising cross
                Rectangle().stroke(Color(hex: "#FFD966").opacity(1 - p), lineWidth: 2)
                    .shadow(color: Color(hex: "#FFD966").opacity(1 - p), radius: 8)
                Text("✚")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color(hex: "#FFE98A").opacity(1 - p))
                    .shadow(color: Color(hex: "#FFD966"), radius: 4)
                    .offset(y: -14 * p)
            }
        }
        .opacity(online ? 1 : 0.55)
    }

    private func recentlyRevived(_ t: Date?) -> Bool {
        guard let r = revivedAt else { return false }
        return (t ?? Date()).timeIntervalSince(r) < 30
    }

    private func status(revive: Bool) -> some View {
        let (text, color): (String, Color) = {
            guard online else {
                // Connected but nothing with a limit: show the reading, not "Offline".
                if let w = snap.windows.first, let t = w.amountText { return ("\(w.label) \(t)", theme.dim) }
                if case .idle = snap.state { return (T.t("raid.signedIn"), theme.dim) }
                return ("Offline", theme.dim)
            }
            if revive { return ("Resurrected", Color(hex: "#FFD966")) }
            if snap.windows.contains(where: { $0.usedPercent >= 95 }) { return ("Exhausted", theme.danger) }
            if let f = doom, let hits = f.hitsLimitAt { return (T.t("raid.outBy", T.clock(hits, now: now)), theme.warn) }
            if snap.windows.allSatisfy({ $0.usedPercent < 10 }) { return ("Rested", theme.hpHigh) }
            return (snap.plan ?? "", theme.dim)
        }()
        return Text(text)
            .font(.system(size: 9, weight: .semibold, design: .serif))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// One line of MMO-style combat log under the raid frames.
struct CombatLog: View {
    let line: LogLine
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Text("[\(Fmt.clock(line.at))]")
                .foregroundStyle(theme.dim)
            Text(line.text)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 10, weight: .medium, design: .serif))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.45))
        .overlay(Rectangle().stroke((theme.border ?? .gray).opacity(0.35), lineWidth: 1))
        .id(line.id)
        .transition(.opacity)
    }

    private var color: Color {
        switch line.kind {
        case .info: return theme.fg
        case .heal: return Color(hex: "#FFD966")
        case .warn: return theme.warn
        case .danger: return theme.danger
        }
    }
}

// MARK: - Account card (hover)

final class HoverState: ObservableObject {
    @Published var inside = false
    @Published var showCard = false
}

struct AccountCard: View {
    let name: String
    let account: AccountInfo
    let theme: Theme
    var health: ProviderHealth? = nil
    var logged: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name).font(.system(size: 13, weight: .semibold))
            if let stale = account.staleText {
                Text("⚠︎ \(stale). Re-read the billing screen to update billing-screens.json.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let health {
                Text("● \(health.level.label): \(health.summary)")
                    .font(.system(size: 11)).foregroundStyle(health.level >= .partialOutage ? .red : .yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field("Plan", account.plan.map { $0 + mark("plan") }, account.planNote)
            field("Monthly price", account.monthlyPrice.map { p in
                (p == 0 ? "Free" : Fmt.money(p, account.currency) + " / month") + mark("price")
            }, account.priceNote)
            field("Next bill", account.nextBill.map { Fmt.shortDate($0) + mark("bill") }, account.billNote)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reset & refill credits").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(account.credits, id: \.self) { c in
                    Text("\(T.credit(c.title)) \(c.amount)" + (c.expires.map { " · expires \(Fmt.shortDate($0))" } ?? ""))
                        .font(.system(size: 12))
                }
                if let note = account.creditsNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if account.credits.isEmpty && account.creditsNote == nil {
                    Text("None").font(.system(size: 12))
                }
            }
            if let logged {
                Text(logged).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Read from: \(account.source)").font(.system(size: 10)).foregroundStyle(.secondary)
            if let checked = account.screenCheckedAt {
                Text("* from \(account.screenSource ?? "the service's settings screen") · last checked \(Fmt.shortDate(checked))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    private func mark(_ f: String) -> String { account.fromScreen.contains(f) ? " *" : "" }

    @ViewBuilder
    private func field(_ label: String, _ value: String?, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            if let value {
                Text(value).font(.system(size: 12, weight: .medium))
            } else {
                Text("Couldn't read: \(note ?? "not reported")").font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Badge (monogram, or user-supplied icon)

enum IconCache {
    private static var store: [String: NSImage?] = [:]
    static func reset() { store = [:] }
    /// Repo screenshots (--stage) never show third-party logos, even if this Mac has them.
    private static let disabled = CommandLine.arguments.contains("--stage")

    static func image(_ id: String) -> NSImage? {
        if disabled { return nil }
        if let hit = store[id] { return hit }
        // A file in ~/.config/phosphor/icons wins (user's own or downloaded), then the installed
        // app's own icon, else the monogram.
        let img = NSImage(contentsOf: Paths.icon(for: id)) ?? Logos.localAppIcon(id)
        store[id] = img
        return img
    }
}

struct Badge: View {
    let info: ProviderInfo
    let theme: Theme
    let size: CGFloat

    var body: some View {
        if let img = IconCache.image(info.id) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(theme.layout == .raid ? size * 0.12 : 0)
                .frame(width: size, height: size)
                .background {   // on a coloured HP bar, logos need a dark plate to stay visible
                    if theme.layout == .raid {
                        RoundedRectangle(cornerRadius: size * 0.28).fill(Color.black.opacity(0.6))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
                .saturation(theme.monochrome ? 0 : 1)
                .colorMultiply(theme.monochrome ? theme.fg : .white)
        } else {
            let tint = theme.tint(info)
            ZStack {
                if theme.layout == .raid {   // sits on a coloured HP bar: give it a dark plate
                    RoundedRectangle(cornerRadius: size * 0.28).fill(Color.black.opacity(0.6))
                }
                RoundedRectangle(cornerRadius: size * 0.28)
                    .fill(tint.opacity(theme.monochrome ? 0.08 : 0.22))
                RoundedRectangle(cornerRadius: size * 0.28)
                    .strokeBorder(tint.opacity(0.85), lineWidth: 1)
                Text(info.monogram)
                    .font(.system(size: size * (info.monogram.count > 1 ? 0.4 : 0.52), weight: .bold,
                                  design: theme.design))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Backdrops & effects

struct BackdropView: View {
    let theme: Theme
    var body: some View {
        switch theme.backdrop {
        case .material(let shade): ZStack { VisualEffect(); Color.black.opacity(shade) }
        case .solid(let c): c
        case .clear(let a): Color.black.opacity(a)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.appearance = NSAppearance(named: .vibrantDark)   // stay dark over white windows
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct Effects: View {
    let theme: Theme
    var body: some View {
        ZStack {
            if theme.scanlines { Scanlines() }
            if theme.vignette {
                GeometryReader { g in
                    let r = max(g.size.width, g.size.height)
                    RadialGradient(colors: [.clear, .black.opacity(0.4)], center: .center,
                                   startRadius: r * 0.3, endRadius: r * 0.75)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct Glow: ViewModifier {
    let theme: Theme
    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.glow {
            content.shadow(color: theme.fg.opacity(0.55), radius: theme.glowRadius)
        } else {
            content
        }
    }
}

struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.28)))
                y += 3
            }
        }
    }
}

struct MatrixRain: View {
    let color: Color
    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉ0123456789:=*+<>")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let cell: CGFloat = 11
                let cols = Int(size.width / cell) + 1
                let rows = Int(size.height / cell) + 1
                let glyphs = MatrixRain.glyphs
                for c in 0..<cols {
                    let seed = (c &* 40503 &+ 7919) & 0xFFFF
                    let speed = 3.0 + Double(seed % 7)
                    let span = Double(rows + 14)
                    let head = Int((t * speed + Double(seed % 97)).truncatingRemainder(dividingBy: span))
                    for k in 0..<12 {
                        let r = head - k
                        guard r >= 0, r < rows else { continue }
                        let gi = (seed &+ r &* 31 &+ Int(t * 3)) % glyphs.count
                        let alpha = k == 0 ? 0.95 : 0.6 * (1 - Double(k) / 12)
                        ctx.draw(Text(String(glyphs[gi]))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(color.opacity(alpha)),
                                 at: CGPoint(x: CGFloat(c) * cell + cell / 2, y: CGFloat(r) * cell + cell / 2))
                    }
                }
            }
        }
        .opacity(0.28)
    }
}

// MARK: - Stage wallpaper (`--stage`, screenshots only)

struct StageWallpaper: View {
    /// PHOSPHOR_STAGE=white: a plain white "document" behind the HUD, to check contrast.
    private let white = ProcessInfo.processInfo.environment["PHOSPHOR_STAGE"] == "white"

    var body: some View {
        if white {
            ZStack(alignment: .topLeading) {
                Color.white
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<24, id: \.self) { i in
                        Text("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor \(i)")
                            .font(.system(size: 13)).foregroundStyle(.black.opacity(0.75))
                    }
                }
                .padding(30)
            }
        } else {
            wallpaper
        }
    }

    private var wallpaper: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#0F1B3D"), Color(hex: "#2A1745"), Color(hex: "#0B2A36")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(hex: "#FF7A59")).frame(width: 340).blur(radius: 90).offset(x: -260, y: -170)
            Circle().fill(Color(hex: "#3F8CFF")).frame(width: 380).blur(radius: 110).offset(x: 240, y: 120)
            Circle().fill(Color(hex: "#18C29C")).frame(width: 260).blur(radius: 90).offset(x: -120, y: 260)
        }
    }
}


// MARK: - Weekly sparkline

struct UsageSparkline: View {
    let values: [Double]
    let tint: Color
    var width: CGFloat = 52
    var helpText: String? = nil
    var body: some View {
        let pts = SparklineSeries.normalize(values)
        Canvas { ctx, size in
            guard let first = pts.first, pts.count >= 1 else { return }
            var line = Path()
            var fill = Path()
            func pt(_ i: Int, _ v: Double) -> CGPoint {
                let x = pts.count == 1 ? size.width / 2 : size.width * CGFloat(i) / CGFloat(pts.count - 1)
                let y = size.height - CGFloat(v) * (size.height - 2) - 1
                return CGPoint(x: x, y: y)
            }
            let start = pt(0, first)
            line.move(to: start)
            fill.move(to: CGPoint(x: start.x, y: size.height))
            fill.addLine(to: start)
            for (i, v) in pts.enumerated().dropFirst() {
                let p = pt(i, v)
                line.addLine(to: p)
                fill.addLine(to: p)
            }
            if let lastI = pts.indices.last {
                fill.addLine(to: CGPoint(x: pt(lastI, pts[lastI]).x, y: size.height))
                fill.closeSubpath()
            }
            ctx.fill(fill, with: .color(tint.opacity(0.22)))
            ctx.stroke(line, with: .color(tint.opacity(0.95)), lineWidth: 1.15)
        }
        .frame(width: width, height: 16)
        .help(helpText ?? T.t("sparkline.help"))
        .accessibilityLabel(T.t("sparkline.access"))
    }
}

struct TagRow: View {
    let tags: [String]
    let theme: Theme
    let tint: Color
    var body: some View {
        // Compact wrapping badges so every installed / loaded model name is visible.
        VStack(alignment: .leading, spacing: 3) {
            FlowTags(tags: tags, theme: theme, tint: tint)
        }
    }
}

/// Simple left-to-right wrapping row of name badges (no third-party layout helpers).
struct FlowTags: View {
    let tags: [String]
    let theme: Theme
    let tint: Color
    var body: some View {
        // A wrapping HStack via `+` text would truncate; use a flexible LazyVGrid with
        // adaptive columns so names stay readable even when many models are installed.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4, alignment: .leading)],
                  alignment: .leading, spacing: 4) {
            ForEach(tags, id: \.self) { name in
                Text(name)
                    .font(theme.font(8, .medium))
                    .foregroundStyle(theme.fg)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.18)))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Hidden providers (restore)

struct HiddenServicesButton: View {
    let theme: Theme
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs = Prefs.shared
    @StateObject private var pop = HoverFlag()

    var body: some View {
        Button { pop.on.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9, weight: .semibold))
                Text(theme.name(T.t("hidden.count", "\(prefs.hidden.count)")))
                    .font(theme.font(9, .medium))
            }
            .foregroundStyle(theme.dim)
        }
        .buttonStyle(.plain)
        .help(T.t("hidden.help"))
        .popover(isPresented: $pop.on, arrowEdge: .bottom) {
            HiddenServicesList(theme: theme, store: store)
                .environment(\.colorScheme, .dark)
                .presentationBackground(Color(white: 0.11))
        }
    }
}

struct HiddenServicesList: View {
    let theme: Theme
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T.t("hidden.title")).font(.system(size: 12, weight: .semibold))
            Text(T.t("hidden.body"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let ids = (store.snapshots.map(\.id) + prefs.hidden.sorted()).uniqued()
            ForEach(ids, id: \.self) { id in
                let on = !prefs.hidden.contains(id)
                let name = store.snapshots.first { $0.id == id }?.info.name ?? ProviderInfo.lookup(id).name
                Button {
                    if on { prefs.hideProvider(id) } else { prefs.showProvider(id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? theme.tint(ProviderInfo.lookup(id)) : .secondary)
                        Text(name).foregroundStyle(.primary)
                        Spacer()
                        if !on { Text(T.t("hidden.badge")).font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
