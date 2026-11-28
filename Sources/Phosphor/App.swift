import AppKit
import SwiftUI
import Combine
import ServiceManagement
import PhosphorCore

@main
struct PhosphorMain {
    // NSApplication.delegate is weak — keep a strong reference for the app's lifetime.
    @MainActor static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-themes") {
            let dir = args.count > i + 1 ? URL(fileURLWithPath: args[i + 1]) : ThemeRegistry.userDir
            do {
                try ThemeRegistry.export(to: dir)
                print("✓ wrote built-in themes to \(dir.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("export failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if let i = args.firstIndex(of: "--check"), i + 1 < args.count {
            // Used by Connect after a sign-in: is this provider really readable now?
            let id = args[i + 1]
            Task {
                guard let src = nativeSource(id), let snap = await src.fetch().first else {
                    print("✗ unknown provider \(id)"); exit(2)
                }
                switch snap.state {
                case .ok(let windows, let plan):
                    let list = windows.prefix(3).map { "\($0.label) \($0.amountText ?? "\(Int($0.usedPercent.rounded()))%")" }
                        .joined(separator: " · ")
                    print("✓ \(snap.info.name) connected\(plan.map { " (\($0))" } ?? "") — \(list)")
                    exit(0)
                case .idle(let m, let plan):
                    print("✓ \(snap.info.name) connected\(plan.map { " (\($0))" } ?? "") — \(m)")
                    exit(0)
                case .error(let m), .unavailable(let m):
                    print("✗ \(snap.info.name): \(m)"); exit(1)
                case .loading:
                    print("✗ \(snap.info.name): no answer"); exit(1)
                }
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--account"), i + 1 < args.count {
            // Prints what Phosphor reads about a subscription (plan, price, next bill, credits).
            let id = args[i + 1]
            Task {
                guard let a = await Accounts.fetch(id, claude: ClaudeSource()) else { print("✗ unknown provider \(id)"); exit(2) }
                print("plan: \(a.plan ?? "– (\(a.planNote ?? "not reported"))")")
                print("monthly: \(a.monthlyPrice.map { Fmt.amount($0, a.currency) } ?? "– (\(a.priceNote ?? "not reported"))")")
                print("next bill: \(a.nextBill.map { Fmt.shortDate($0) } ?? "– (\(a.billNote ?? "not reported"))")")
                for c in a.credits { print("credit: \(c.title) \(c.amount)\(c.expires.map { " · expires \(Fmt.shortDate($0))" } ?? "")") }
                if let n = a.creditsNote { print("credits note: \(n)") }
                print("source: \(a.source)")
                exit(0)
            }
            RunLoop.main.run()
        }
        if args.contains("--detect") {   // which catalog providers this Mac has
            let found = Detector().detected()
            for s in ProviderCatalog.all {
                print("\(found[s.id] != nil ? "●" : "○") \(s.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(found[s.id] ?? "—")")
            }
            print("\(found.count) of \(ProviderCatalog.all.count) catalog providers found")
            exit(0)
        }
        if args.contains("--scan-logs") {   // incremental scan; prints per-tool totals (numbers only)
            var ledger = UsageLedger()
            if let d = try? Data(contentsOf: UsageLogs.ledgerFile), let l = try? JSONDecoder().decode(UsageLedger.self, from: d) { ledger = l }
            let t0 = Date()
            LogScanner().scan(&ledger)
            if let data = try? JSONEncoder().encode(ledger) {
                try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
                try? data.write(to: UsageLogs.ledgerFile, options: .atomic)
            }
            let prices = (try? Data(contentsOf: UsageLogs.pricesFile)).flatMap { try? PriceTable(litellmJSON: $0) } ?? PriceTable()
            print(String(format: "scanned in %.1fs · %d files tracked · %d priced models", Date().timeIntervalSince(t0), ledger.files.count, prices.prices.count))
            for src in UsageLogs.sources {
                let d = ledger.summary(lastDays: 1, source: src, prices: prices), w = ledger.summary(lastDays: 7, source: src, prices: prices)
                let m = ledger.summary(lastDays: 30, source: src, prices: prices)
                guard m.tokens > 0 else { continue }
                print(String(format: "%-7@ today %8@ $%9.2f · 7d %8@ $%9.2f · 30d %8@ $%10.2f · unpriced 30d %@", src as NSString,
                             Fmt.compact(Double(d.tokens)) as NSString, d.cost, Fmt.compact(Double(w.tokens)) as NSString, w.cost,
                             Fmt.compact(Double(m.tokens)) as NSString, m.cost, Fmt.compact(Double(m.unpricedTokens)) as NSString))
            }
            exit(0)
        }
        if args.contains("--fetch-logos") {   // non-interactive: download official logos and exit
            Task {
                let got = await Logos.download()
                print(got.isEmpty ? "nothing new (already present or unreachable)" : "✓ " + got.joined(separator: ", "))
                exit(0)
            }
            RunLoop.main.run()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        PhosphorMain.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        app.run()
    }
}

/// Borderless, non-activating, always-on-top panel that follows you across Spaces.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let demo = CommandLine.arguments.contains("--demo")
        || ProcessInfo.processInfo.environment["PHOSPHOR_DEMO"] != nil
    private lazy var store = UsageStore(demo: demo)
    private let prefs = Prefs.shared
    private var panel: HUDPanel!
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    /// `--stage`: screenshot mode — fixed position on a wallpaper window, saved position untouched.
    private let staged = CommandLine.arguments.contains("--stage")
    private var stage: NSWindow?
    private var optionPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = HUDPanel()
        panel.onUserResize = { [weak self] size in
            guard let self else { return }
            self.prefs.hudUserSized = true
            self.prefs.hudWidth = size.width
            self.prefs.hudHeight = size.height
        }
        if self.prefs.hudUserSized, self.prefs.hudWidth >= HUDPanel.minWidth, self.prefs.hudHeight >= HUDPanel.minHeight {
            var f = panel.frame
            f.size = NSSize(width: self.prefs.hudWidth, height: self.prefs.hudHeight)
            panel.setFrame(f, display: false)
        }
        let host = NSHostingView(rootView: RootView(store: store) { [weak self] size in
            self?.resize(to: size)
        })
        host.sizingOptions = []   // we size the panel ourselves (see resize)
        host.menu = makeMenu()
        panel.contentView = host

        if staged {
            setUpStage()
        } else {
            if !panel.setFrameUsingName("PhosphorHUD") {
                placeTopRight()
            }
            panel.setFrameAutosaveName("PhosphorHUD")
        }
        applyPrefs()
        panel.orderFrontRegardless()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.image = CRTIcon.image(fill: 0, band: .neutral)
        statusItem.menu = makeMenu()

        store.$snapshots.receive(on: RunLoop.main).sink { [weak self] snaps in
            self?.updateStatusIcon(snaps)
            guard let self, self.prefs.phoneSync else { return }
            PhoneSyncService.shared.replaceSnapshot(phoneSnapshot(snaps, host: PhoneSyncService.shared.hostName))
            PhoneSyncPanel.shared.noteSnapshots()
        }.store(in: &bag)
        prefs.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyPrefs() }
        }.store(in: &bag)

        store.start()
        if prefs.phoneSync { _ = PhoneSyncService.shared.start() }
        startThemeCycle()
        if !demo && !staged && !UserDefaults.standard.bool(forKey: "logoPromptAnswered") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.askAboutLogos() }
        } else if !demo && !staged && Logos.hasDownloaded {
            downloadLogos()   // already agreed: fetch logos for new providers and updated sources
        }
    }

    // MARK: Official logos (asked once; never bundled)

    private func askAboutLogos() {
        let a = NSAlert()
        a.messageText = "Use official logos?"
        a.informativeText = "Phosphor doesn't ship other companies' logos. It can download each service's icon from "
            + "its own website (claude.com, chatgpt.com, gemini.google.com, …) into ~/.config/phosphor/icons.\n\n"
            + "You can remove them any time from Providers → Remove Downloaded Logos."
        a.addButton(withTitle: "Download Logos")
        a.addButton(withTitle: "Keep Monograms")
        NSApp.activate(ignoringOtherApps: true)
        let yes = a.runModal() == .alertFirstButtonReturn
        UserDefaults.standard.set(true, forKey: "logoPromptAnswered")
        if yes { downloadLogos() }
    }

    @objc private func downloadLogos() {
        Task { @MainActor in
            _ = await Logos.download()
            IconCache.reset()
            prefs.objectWillChange.send()   // redraw with the new icons
        }
    }

    @objc private func removeLogos() {
        Logos.removeDownloaded()
        IconCache.reset()
        prefs.objectWillChange.send()
    }

    // MARK: Screenshot helpers (demo only)

    private func setUpStage() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = NSSize(width: 960, height: 1240)
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        let w = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        w.contentView = NSHostingView(rootView: StageWallpaper())
        w.ignoresMouseEvents = true
        w.orderFrontRegardless()
        stage = w
        panel.setFrameTopLeftPoint(NSPoint(x: origin.x + 60, y: origin.y + size.height - 60))
    }

    /// `PHOSPHOR_CYCLE=<seconds>` with --demo: rotate through every theme (for the README GIF).
    private func startThemeCycle() {
        guard demo, let s = ProcessInfo.processInfo.environment["PHOSPHOR_CYCLE"].flatMap(Double.init), s > 0 else { return }
        Timer.scheduledTimer(withTimeInterval: s, repeats: true) { _ in
            Task { @MainActor in
                let ids = ThemeRegistry.shared.themes.map(\.id)
                let i = ids.firstIndex(of: Prefs.shared.theme) ?? -1
                Prefs.shared.theme = ids[(i + 1) % ids.count]
            }
        }
    }

    // MARK: Window

    private func placeTopRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.maxX - 320, y: screen.maxY - 240))
    }

    /// Keep the top-left corner fixed while the content grows or shrinks.
    /// Once the user has resized the panel themselves, we stop fighting their frame.
    private func resize(to size: CGSize) {
        guard !prefs.hudUserSized else { return }
        guard size.width > 0, size.height > 0 else { return }
        var f = panel.frame
        guard abs(f.width - size.width) > 0.5 || abs(f.height - size.height) > 0.5 else { return }
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    private func applyPrefs() {
        panel.alphaValue = prefs.opacity
        updateMouseThrough()
        if statusItem != nil { updateStatusIcon(store.snapshots) }
        // Click-through: holding ⌥ makes the HUD grabbable again (drag / right-click).
        // NSEvent.modifierFlags needs no Accessibility permission, so poll it while the mode is on.
        optionPoll?.invalidate()
        optionPoll = nil
        if prefs.clickThrough {
            optionPoll = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMouseThrough() }
            }
        }
    }

    private func updateMouseThrough() {
        let through = prefs.clickThrough && !NSEvent.modifierFlags.contains(.option)
        if panel.ignoresMouseEvents != through { panel.ignoresMouseEvents = through }
    }

    private func updateStatusIcon(_ snaps: [ProviderSnapshot]) {
        let gauges = snaps.filter { !prefs.hidden.contains($0.id) }.flatMap { snap in
            snap.gauges.map { (snap: snap, window: $0) }
        }
        let primary = gauges.max { $0.window.usedPercent < $1.window.usedPercent }
        let fill = (primary?.window.usedPercent ?? 0) / 100
        let mode = IconColor.Mode(rawValue: prefs.iconColorMode) ?? .pace
        let band: IconColor.Band
        if let window = primary?.window {
            band = IconColor.band(mode: mode, usedPercent: window.usedPercent,
                                  elapsedFraction: window.pacePercent.map { $0 / 100 },
                                  forecast: window.forecast)
        } else {
            band = .neutral
        }
        let key = "\(Int((fill * 100).rounded()))-\(band.rawValue)-\(mode.rawValue)"
        if key != iconKey {
            iconKey = key
            statusItem.button?.image = CRTIcon.image(fill: fill, band: band)
        }
        if let window = primary?.window {
            statusItem.button?.toolTip = "\(Int(window.usedPercent.rounded()))% · \(mode.rawValue)"
        } else {
            statusItem.button?.toolTip = "Phosphor"
        }
    }

    private var iconKey = ""

    // MARK: Menu (shared by the menu bar item and right-click on the HUD)

    private func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let pt = panel.lastRightClick, let key = panel.providerKey(at: pt), !key.hasPrefix("group:") {
            let name = store.snapshots.first { $0.id == key }?.info.name ?? ProviderInfo.lookup(key).name
            let hide = item(T.t("menu.hideProvider", name), #selector(hideProvider(_:)))
            hide.representedObject = key
            menu.addItem(hide)
            menu.addItem(.separator())
        }

        let versionItem = NSMenuItem(title: Phosphor.identity, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        menu.addItem(item(panel.isVisible ? T.t("menu.hideHUD") : T.t("menu.showHUD"), #selector(toggleHUD), key: "h"))
        menu.addItem(item(T.t("menu.refreshNow"), #selector(refreshNow), key: "r"))
        menu.addItem(.separator())

        let registry = ThemeRegistry.shared
        registry.reload()   // pick up new/edited files in ~/.config/phosphor/themes
        let themes = NSMenu()
        for t in registry.themes {
            let i = item(t.name, #selector(pickTheme(_:)))
            i.representedObject = t.id
            i.state = registry.theme(prefs.theme).id == t.id ? .on : .off
            themes.addItem(i)
        }
        themes.addItem(.separator())
        for p in registry.problems {
            let i = NSMenuItem(title: "⚠︎ \(p)", action: nil, keyEquivalent: "")
            i.isEnabled = false
            themes.addItem(i)
        }
        themes.addItem(item(T.t("menu.openThemes"), #selector(openThemes)))
        menu.addItem(submenu(T.t("menu.theme"), themes))

        let compact = item(T.t("menu.compact"), #selector(toggleCompact), key: "c")
        compact.state = prefs.compact ? .on : .off
        menu.addItem(compact)

        let opacity = NSMenu()
        for v in [1.0, 0.85, 0.7, 0.5, 0.3] {
            let i = item("\(Int(v * 100))%", #selector(pickOpacity(_:)))
            i.representedObject = v
            i.state = abs(prefs.opacity - v) < 0.01 ? .on : .off
            opacity.addItem(i)
        }
        menu.addItem(submenu(T.t("menu.opacity"), opacity))

        let through = item(T.t("menu.clickThrough"), #selector(toggleClickThrough))
        through.state = prefs.clickThrough ? .on : .off
        menu.addItem(through)

        let langs = NSMenu()
        for lang in AppLanguage.allCases {
            let title: String
            switch lang {
            case .english: title = T.t("lang.english")
            case .korean: title = T.t("lang.korean")
            case .system: title = T.t("lang.system")
            }
            let i = item(title, #selector(pickLanguage(_:)))
            i.representedObject = lang.rawValue
            i.state = prefs.appLanguage == lang ? .on : .off
            langs.addItem(i)
        }
        menu.addItem(submenu(T.t("menu.language"), langs))
        menu.addItem(.separator())

        let providers = NSMenu()
        let visibleHdr = NSMenuItem(title: T.t("menu.visibleServices"), action: nil, keyEquivalent: "")
        visibleHdr.isEnabled = false
        providers.addItem(visibleHdr)
        if prefs.hudUserSized {
            providers.addItem(item(T.t("menu.resetWindowSize"), #selector(resetWindowSize)))
        }
        var lastFamily: String?
        for s in store.snapshots {
            let fam = ProviderFamilies.family(of: s.id)
            if let fam, fam.id != lastFamily {
                let h = NSMenuItem(title: fam.name, action: nil, keyEquivalent: ""); h.isEnabled = false
                providers.addItem(h)
            }
            lastFamily = fam?.id
            let label: String
            switch s.state {
            case .unavailable(let why): label = "\(s.info.name) — \(why)"
            case .error(let why): label = "\(s.info.name) — ⚠︎ \(why)"
            default: label = s.info.name
            }
            let stale = store.accounts[s.id]?.staleText.map { " — ⚠︎ \($0.lowercased())" } ?? ""
            let down = store.status.health[s.id].map { " — ● \($0.level.label.lowercased())" } ?? ""
            let i = item(label + stale + down, #selector(toggleProvider(_:)))
            i.indentationLevel = fam == nil ? 0 : 1
            i.representedObject = s.id
            i.state = prefs.hidden.contains(s.id) ? .off : .on
            providers.addItem(i)
        }
        let offline = store.snapshots.filter {
            !$0.isConnected && Connect.supported.contains($0.id)
        }
        if !offline.isEmpty {
            providers.addItem(.separator())
            for s in offline {
                let i = item(T.t("menu.connect", s.info.name), #selector(connectProvider(_:)))
                i.representedObject = s.id
                providers.addItem(i)
            }
        }
        if !store.snapshots.isEmpty { providers.addItem(.separator()) }

        // Catalog: everything Phosphor knows, on when installed; toggle any of them.
        let more = NSMenu()
        let reg = store.registry
        let groups: [(String, [ProviderSpec])] = [
            (T.t("menu.installedOnMac"), groupedFirst(reg.extras.filter { reg.detected[$0.id] != nil })),
            (T.t("menu.notFound"), groupedFirst(reg.extras.filter { reg.detected[$0.id] == nil })),
        ]
        for (title, specs) in groups where !specs.isEmpty {
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: ""); h.isEnabled = false
            more.addItem(h)
            for spec in specs {
                let how = reg.detected[spec.id] ?? (spec.sources.contains(.apiKey) ? APIKeys.howTo(spec) : T.t("menu.notInstalled"))
                let fam = ProviderFamilies.family(of: spec.id).map { "\($0.name) › " } ?? ""
                let i = item("\(fam)\(spec.name) — \(how)", #selector(toggleCatalogProvider(_:)))
                i.representedObject = spec.id
                i.state = reg.isEnabled(spec.id) ? .on : .off
                more.addItem(i)
            }
            more.addItem(.separator())
        }
        more.addItem(item(T.t("menu.rescan"), #selector(rescanProviders)))
        providers.addItem(submenu(T.t("menu.moreProviders", "\(reg.detected.filter { !ProviderRegistry.native.contains($0.key) }.count)", "\(reg.extras.count)"), more))

        let accountsMenu = NSMenu()
        for p in reg.profiles {
            let i = NSMenuItem(title: "\(ProviderInfo.lookup(p.id).name) — \(p.home ?? p.configDir ?? p.keychainService ?? "")", action: nil, keyEquivalent: "")
            i.isEnabled = false; accountsMenu.addItem(i)
        }
        for problem in reg.profileProblems {
            let i = NSMenuItem(title: "⚠︎ \(problem)", action: nil, keyEquivalent: ""); i.isEnabled = false
            accountsMenu.addItem(i)
        }
        if !reg.profiles.isEmpty || !reg.profileProblems.isEmpty { accountsMenu.addItem(.separator()) }
        accountsMenu.addItem(item(T.t("menu.editAccounts"), #selector(openAccounts)))
        providers.addItem(submenu(T.t("menu.extraAccounts", "\(reg.profiles.count)"), accountsMenu))
        providers.addItem(.separator())
        let showOff = item(T.t("menu.showUnavailable"), #selector(toggleShowUnavailable))
        showOff.state = prefs.showUnavailable ? .on : .off
        providers.addItem(showOff)
        providers.addItem(item(T.t("menu.addCustom"), #selector(openConfig)))
        let reset = item(T.t("menu.resetOrder"), #selector(resetOrder))
        reset.isEnabled = !prefs.rowOrder.isEmpty
        providers.addItem(reset)
        let resets = item(T.t("menu.claudeResets"), #selector(toggleClaudeResets))
        resets.state = prefs.claudeResetCredits ? .on : .off
        providers.addItem(resets)
        providers.addItem(.separator())
        providers.addItem(item(T.t("menu.downloadLogos"), #selector(downloadLogos)))
        if Logos.hasDownloaded { providers.addItem(item(T.t("menu.removeLogos"), #selector(removeLogos))) }
        menu.addItem(submenu(T.t("menu.providers"), providers))

        let chart = item(T.t("menu.chart"), #selector(toggleChart))
        chart.state = prefs.showChart ? .on : .off
        menu.addItem(chart)
        let devStats = item(T.t("menu.devStats"), #selector(toggleDevStats))
        devStats.state = prefs.showDevStats ? .on : .off
        menu.addItem(devStats)
        menu.addItem(githubAccountItem())
        menu.addItem(item(T.t("menu.repoRoots"), #selector(pickRepoRoots)))
        if !prefs.localRepoRoots.isEmpty {
            menu.addItem(item(T.t("menu.repoRootsReset"), #selector(resetRepoRoots)))
        }
        let phone = item(T.t("menu.phoneSync"), #selector(showPhoneSync))
        phone.state = prefs.phoneSync ? .on : .off
        menu.addItem(phone)
        let ticker = item(T.t("menu.showResetTicker"), #selector(toggleResetTicker))
        ticker.state = prefs.showResetTicker ? .on : .off
        menu.addItem(ticker)
        let rumors = item(T.t("menu.includeRumors"), #selector(toggleRumors))
        rumors.state = prefs.includeRumors ? .on : .off
        menu.addItem(rumors)
        menu.addItem(item(T.t("menu.resetFeedURL"), #selector(editResetFeedURL)))
        let colours = NSMenu()
        for (title, mode) in [(T.t("menu.iconPace"), IconColor.Mode.pace.rawValue),
                              (T.t("menu.iconUsage"), IconColor.Mode.usage.rawValue)] {
            let i = item(title, #selector(pickIconColor(_:)))
            i.representedObject = mode
            i.state = prefs.iconColorMode == mode ? .on : .off
            colours.addItem(i)
        }
        menu.addItem(submenu(T.t("menu.iconColor"), colours))
        if prefs.showDevStats, store.dev.counts != nil {
            menu.addItem(item(T.t("menu.saveReceipt"), #selector(saveReceipt)))
        }

        let a = store.alertSettings
        let notes = NSMenu()
        let billKey = a.billDaysBefore == 1 ? "menu.billDueOne" : "menu.billDue"
        for (title, key, on) in [(T.t("menu.warnAt", "\(Int(a.warnAt))"), "warn", a.warnEnabled),
                                 (T.t("menu.criticalAt", "\(Int(a.criticalAt))"), "critical", a.criticalEnabled),
                                 (T.t("menu.windowReset", "\(Int(a.resetFrom))"), "reset", a.resetEnabled),
                                 (T.t(billKey, "\(a.billDaysBefore)"), "bill", a.billEnabled),
                                 (T.t("menu.creditExpiry", "\(a.creditDaysBefore)"), "credit", a.creditEnabled)] {
            let i = item(title, #selector(toggleAlert(_:)))
            i.representedObject = key
            i.state = on ? .on : .off
            notes.addItem(i)
        }
        notes.addItem(.separator())
        notes.addItem(item(T.t("menu.editAlerts"), #selector(openAlerts)))
        menu.addItem(submenu(T.t("menu.notifications"), notes))

        let stale = store.snapshots.filter { store.accounts[$0.id]?.staleText != nil }
        if !stale.isEmpty {
            let i = NSMenuItem(title: T.t("menu.billingStale", stale.map(\.info.name).joined(separator: ", ")), action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        menu.addItem(item(T.t("menu.calendarExport", "\(store.exportedEvents)"), #selector(openExport)))
        menu.addItem(.separator())

        let every = NSMenu()
        for (title, secs) in [(T.t("menu.every1"), 60.0), (T.t("menu.every3"), 180.0),
                              (T.t("menu.every5"), 300.0), (T.t("menu.every10"), 600.0)] {
            let i = item(title, #selector(pickInterval(_:)))
            i.representedObject = secs
            i.state = prefs.refreshSeconds == secs ? .on : .off
            every.addItem(i)
        }
        menu.addItem(submenu(T.t("menu.refreshEvery"), every))

        let login = item(T.t("menu.launchAtLogin"), #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item(T.t("menu.quit"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func githubAccountItem() -> NSMenuItem {
        let shown = prefs.devAccount.isEmpty ? (store.dev.counts?.login ?? "") : prefs.devAccount
        let title = shown.isEmpty ? T.t("menu.githubAccountUnset") : T.t("menu.githubAccount", shown)
        let accounts = NSMenu()
        let current = item(T.t("menu.githubCurrent"), #selector(pickGitHubAccount(_:)))
        current.representedObject = ""
        current.state = prefs.devAccount.isEmpty ? .on : .off
        accounts.addItem(current)
        for login in store.dev.knownAccounts {
            let i = item("@\(login)", #selector(pickGitHubAccount(_:)))
            i.representedObject = login
            i.state = prefs.devAccount.caseInsensitiveCompare(login) == .orderedSame ? .on : .off
            accounts.addItem(i)
        }
        accounts.addItem(.separator())
        accounts.addItem(item(T.t("menu.githubOther"), #selector(editGitHubAccount)))
        return submenu(title, accounts)
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    // MARK: Actions

    @objc private func toggleHUD() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
    @objc private func refreshNow() { store.refresh(); store.refreshAccounts() }
    @objc private func connectProvider(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { store.connect(id) }
    }
    @objc private func pickTheme(_ s: NSMenuItem) {
        if let id = s.representedObject as? String { prefs.theme = id }
    }
    @objc private func pickLanguage(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, AppLanguage(rawValue: raw) != nil {
            prefs.language = raw
        }
    }
    @objc private func toggleCompact() { prefs.compact.toggle() }
    @objc private func pickOpacity(_ s: NSMenuItem) { if let v = s.representedObject as? Double { prefs.opacity = v } }
    @objc private func toggleClickThrough() { prefs.clickThrough.toggle() }
    @objc private func toggleShowUnavailable() { prefs.showUnavailable.toggle() }
    @objc private func toggleClaudeResets() { prefs.claudeResetCredits.toggle(); store.refreshAccounts() }
    @objc private func toggleProvider(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        if prefs.hidden.contains(id) { prefs.hidden.remove(id) } else { prefs.hidden.insert(id) }
        updateStatusIcon(store.snapshots)
    }
    @objc private func hideProvider(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        prefs.hidden = ProviderVisibility.hiding(id, in: prefs.hidden)
        updateStatusIcon(store.snapshots)
    }
    @objc private func resetWindowSize() {
        prefs.hudUserSized = false
        prefs.hudWidth = 0
        prefs.hudHeight = 0
        prefs.objectWillChange.send()
    }
    @objc private func pickInterval(_ s: NSMenuItem) {
        if let v = s.representedObject as? Double { prefs.refreshSeconds = v; store.reschedule() }
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSSound.beep()
        }
    }
    @objc private func openConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.config.appendingPathComponent("icons"), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Paths.customProviders.path) {
            let sample = """
            [
              {
                "id": "perplexity",
                "name": "Perplexity",
                "color": "#20B8CD",
                "command": "echo '{\\"plan\\":\\"Pro\\",\\"windows\\":[{\\"label\\":\\"1D\\",\\"used\\":12,\\"windowSeconds\\":86400}]}'"
              }
            ]
            """
            try? sample.write(to: Paths.customProviders, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([Paths.customProviders])
    }
    @objc private func openThemes() {
        let dir = ThemeRegistry.userDir
        if !FileManager.default.fileExists(atPath: dir.path) { try? ThemeRegistry.export(to: dir.appendingPathComponent("built-in")) }
        NSWorkspace.shared.open(dir)
    }
    @objc private func toggleCatalogProvider(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        store.registry.toggle(id)
        prefs.hidden.remove(id)
        store.refresh()
    }
    /// Family members (Google AI) listed together, ahead of the rest.
    private func groupedFirst(_ specs: [ProviderSpec]) -> [ProviderSpec] {
        let fam = specs.filter { ProviderFamilies.family(of: $0.id) != nil }
        return fam + specs.filter { ProviderFamilies.family(of: $0.id) == nil }
    }
    @objc private func resetOrder() { store.resetOrder() }
    @objc private func rescanProviders() { Task { await store.registry.rescan(); store.refresh() } }
    @objc private func saveReceipt() { Receipt.save(store: store) }
    @objc private func toggleDevStats() {
        prefs.showDevStats.toggle()
        if prefs.showDevStats { store.dev.refreshIfDue(force: true); store.logs.refreshIfDue() }
    }
    @objc private func pickGitHubAccount(_ sender: NSMenuItem) {
        store.dev.useAccount((sender.representedObject as? String) ?? "")
    }
    @objc private func editGitHubAccount() {
        let alert = NSAlert()
        alert.messageText = T.t("menu.githubAccountTitle")
        alert.informativeText = T.t("menu.githubAccountHelp")
        alert.addButton(withTitle: T.t("menu.githubSave"))
        alert.addButton(withTitle: T.t("menu.githubCancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = prefs.devAccount
        field.placeholderString = "login"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.dev.useAccount(field.stringValue)
    }
    @objc private func pickRepoRoots() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = T.t("menu.githubSave")
        guard panel.runModal() == .OK else { return }
        store.dev.useRepoRoots(panel.urls.map(\.path))
    }
    @objc private func resetRepoRoots() {
        store.dev.useRepoRoots([])
    }
    @objc private func toggleResetTicker() {
        prefs.showResetTicker.toggle()
        if prefs.showResetTicker { store.resetNews.refreshIfDue(force: true) }
    }
    @objc private func toggleRumors() { prefs.includeRumors.toggle() }
    @objc private func editResetFeedURL() {
        let alert = NSAlert()
        alert.messageText = T.t("menu.resetFeedTitle")
        alert.informativeText = T.t("menu.resetFeedHelp")
        alert.addButton(withTitle: T.t("menu.githubSave"))
        alert.addButton(withTitle: T.t("menu.githubCancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = prefs.resetFeedURL
        field.placeholderString = ResetFeed.feedURLPlaceholder
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        prefs.resetFeedURL = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        store.resetNews.refreshIfDue(force: true)
    }
    @objc private func pickIconColor(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        prefs.iconColorMode = mode
        updateStatusIcon(store.snapshots)
    }
    @objc private func showPhoneSync() { PhoneSyncPanel.shared.show(store: store) }
    @objc private func toggleChart() { prefs.showChart.toggle(); if prefs.showChart { store.logs.refreshIfDue() } }
    @objc private func toggleAlert(_ s: NSMenuItem) {
        guard let key = s.representedObject as? String else { return }
        var a = store.alertSettings
        switch key {
        case "warn": a.warnEnabled.toggle()
        case "critical": a.criticalEnabled.toggle()
        case "reset": a.resetEnabled.toggle()
        case "bill": a.billEnabled.toggle()
        case "credit": a.creditEnabled.toggle()
        default: return
        }
        store.alertSettings = a
    }
    private func reveal(_ url: URL, sample: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try? sample.write(to: url, atomically: true, encoding: .utf8) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func openAlerts() {
        if !FileManager.default.fileExists(atPath: UsageStore.alertSettingsFile.path) { store.alertSettings = store.alertSettings }
        reveal(UsageStore.alertSettingsFile, sample: "{}")
    }
    @objc private func openAccounts() {
        // The example sits next to an empty list, so no made-up account ever shows as a row.
        let example = Paths.config.appendingPathComponent("accounts.example.json")
        if !FileManager.default.fileExists(atPath: example.path) {
            try? """
            {
              "profiles": [
                { "provider": "codex",  "name": "work", "home": "~/.codex-work" },
                { "provider": "claude", "name": "work", "configDir": "~/.claude-work" }
              ]
            }
            """.write(to: example, atomically: true, encoding: .utf8)
        }
        reveal(Paths.config.appendingPathComponent(ProfilesConfig.fileName), sample: "{ \"profiles\": [] }\n")
    }
    @objc private func openExport() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.config.appendingPathComponent(EventsExport.fileName)])
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
