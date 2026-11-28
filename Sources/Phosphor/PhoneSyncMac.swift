import AppKit
import CoreImage
import Darwin
import PhosphorCore

/// LAN listener for the Android app. Off until Phone sync is turned on.
final class PhoneSyncService {
    static let shared = PhoneSyncService()

    private let lock = NSLock()
    private var session: SyncSession
    private var snapshot = Data(#"{"version":1,"generatedAt":"","hostName":"","rows":[]}"#.utf8)
    private var listenFD: Int32 = -1
    private var generation = 0
    private let queue = DispatchQueue(label: "phosphor.phone-sync")
    private(set) var port: UInt16 = 0
    let hostAddress: String
    let hostName: String

    private init() {
        hostAddress = Self.lanIPv4()
        hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let tokens = Self.loadTokens()
        let now = Date().timeIntervalSince1970
        session = SyncSession(code: PhoneSyncProtocol.randomCode(), codeUntil: now + PhoneSyncProtocol.codeTTL, tokens: tokens)
    }

    var code: String {
        lock.lock(); defer { lock.unlock() }
        return session.code
    }

    func link() -> String {
        lock.lock(); defer { lock.unlock() }
        return PhoneSyncProtocol.pairLink(host: hostAddress, port: port == 0 ? PhoneSyncProtocol.defaultPort : port, code: session.code)
    }

    func rotateCode() {
        lock.lock(); defer { lock.unlock() }
        session.code = PhoneSyncProtocol.randomCode()
        session.codeUntil = Date().timeIntervalSince1970 + PhoneSyncProtocol.codeTTL
    }

    func replaceSnapshot(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        snapshot = data
    }

    @discardableResult
    func start() -> Bool {
        if listenFD >= 0 { return true }
        generation += 1
        let gen = generation
        for candidate in PhoneSyncProtocol.defaultPort..<(PhoneSyncProtocol.defaultPort + 10) {
            if openPort(candidate) {
                port = candidate
                queue.async { [weak self] in self?.loop(gen) }
                return true
            }
        }
        return false
    }

    func stop() {
        generation += 1
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    func forgetPhones() {
        lock.lock()
        session.tokens.removeAll()
        lock.unlock()
        Self.saveTokens([])
    }

    private func openPort(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bound != 0 || listen(fd, 8) != 0 {
            close(fd)
            return false
        }
        listenFD = fd
        return true
    }

    private func loop(_ gen: Int) {
        while generation == gen && listenFD >= 0 {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, nfds_t(1), 200)
            if rc <= 0 { continue }
            let client = accept(listenFD, nil, nil)
            if client >= 0 {
                serve(client)
                close(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        var request: RawHTTPRequest?
        while buf.count < 65_536 {
            let n = read(fd, &tmp, size_t(tmp.count))
            if n <= 0 { break }
            buf.append(contentsOf: tmp.prefix(n))
            switch PhoneSyncProtocol.read(buf) {
            case .needMore: continue
            case .bad: return
            case .ready(let req):
                request = req
            }
            if request != nil { break }
        }
        guard let request else { return }
        lock.lock()
        let before = session.tokens
        let result = PhoneSyncProtocol.handle(method: request.method, path: request.path,
                                              authorization: request.headers["authorization"],
                                              body: request.body, now: Date().timeIntervalSince1970,
                                              session: &session, snapshot: snapshot,
                                              issueToken: { PhoneSyncProtocol.randomToken() })
        let tokens = session.tokens
        lock.unlock()
        if tokens != before { Self.saveTokens(tokens) }
        let reason = result.status == 200 ? "OK" : (result.status == 401 ? "Unauthorized" : "Error")
        var head = "HTTP/1.1 \(result.status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(result.json.count)\r\nConnection: close\r\n\r\n"
        var bytes = Data(head.utf8)
        bytes.append(result.json)
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = Darwin.write(fd, base, raw.count) }
        }
        _ = head
    }

    static func lanIPv4() -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return "127.0.0.1" }
        defer { freeifaddrs(list) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        var fallback: String?
        while let ifa = ptr?.pointee {
            defer { ptr = ifa.ifa_next }
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("lo") || name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if name == "en0" { return ip }
                fallback = fallback ?? ip
            }
        }
        return fallback ?? "127.0.0.1"
    }

    private static var tokenFile: URL { Paths.support.appendingPathComponent("phone-sync.json") }

    private static func loadTokens() -> Set<String> {
        guard let data = try? Data(contentsOf: tokenFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["tokens"] as? [String] else { return [] }
        return Set(list)
    }

    private static func saveTokens(_ tokens: Set<String>) {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let obj: [String: Any] = ["tokens": Array(tokens)]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: tokenFile, options: .atomic)
        }
    }
}

/// The pairing window: QR, code, and the on/off switch. Sync stays off until this is turned on.
@MainActor
final class PhoneSyncPanel: NSObject {
    static let shared = PhoneSyncPanel()
    private var window: NSWindow?
    private weak var store: UsageStore?
    private let image = NSImageView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let addressLabel = NSTextField(labelWithString: "")
    private let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    func show(store: UsageStore) {
        self.store = store
        if window == nil { build() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func noteSnapshots() { if window?.isVisible == true { refresh() } }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = T.t("phone.title")
        w.isReleasedWhenClosed = false
        let root = NSView(frame: w.contentRect(forFrameRect: w.frame))
        toggle.title = T.t("phone.enable")
        toggle.target = self
        toggle.action = #selector(toggleSync)
        toggle.frame = NSRect(x: 24, y: 400, width: 310, height: 24)
        image.frame = NSRect(x: 90, y: 180, width: 180, height: 180)
        image.imageScaling = .scaleProportionallyUpOrDown
        codeLabel.frame = NSRect(x: 24, y: 140, width: 312, height: 28)
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        codeLabel.alignment = .center
        addressLabel.frame = NSRect(x: 24, y: 96, width: 312, height: 40)
        addressLabel.font = .systemFont(ofSize: 12)
        addressLabel.alignment = .center
        addressLabel.maximumNumberOfLines = 2
        let help = NSTextField(wrappingLabelWithString: T.t("phone.help"))
        help.frame = NSRect(x: 24, y: 48, width: 312, height: 44)
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        let newer = NSButton(title: T.t("phone.newCode"), target: self, action: #selector(newCode))
        newer.frame = NSRect(x: 24, y: 12, width: 150, height: 28)
        let forget = NSButton(title: T.t("phone.forget"), target: self, action: #selector(forget))
        forget.frame = NSRect(x: 186, y: 12, width: 150, height: 28)
        root.addSubview(toggle)
        root.addSubview(image)
        root.addSubview(codeLabel)
        root.addSubview(addressLabel)
        root.addSubview(help)
        root.addSubview(newer)
        root.addSubview(forget)
        w.contentView = root
        w.center()
        window = w
    }

    private func refresh() {
        let on = Prefs.shared.phoneSync
        toggle.state = on ? .on : .off
        publish()
        let svc = PhoneSyncService.shared
        let link = on ? svc.link() : ""
        codeLabel.stringValue = on ? svc.code : "—"
        addressLabel.stringValue = on ? "\(svc.hostAddress):\(svc.port)" : T.t("phone.off")
        image.image = on ? qrImage(link) : nil
    }

    func publish() {
        guard let store else { return }
        PhoneSyncService.shared.replaceSnapshot(phoneSnapshot(store.snapshots, host: PhoneSyncService.shared.hostName))
    }

    @objc private func toggleSync() {
        Prefs.shared.phoneSync = toggle.state == .on
        if Prefs.shared.phoneSync {
            _ = PhoneSyncService.shared.start()
            PhoneSyncService.shared.rotateCode()
        } else {
            PhoneSyncService.shared.stop()
        }
        refresh()
    }

    @objc private func newCode() {
        guard Prefs.shared.phoneSync else { return }
        PhoneSyncService.shared.rotateCode()
        refresh()
    }

    @objc private func forget() {
        PhoneSyncService.shared.forgetPhones()
    }

    private func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

func phoneSnapshot(_ snaps: [ProviderSnapshot], host: String) -> Data {
    let now = Date()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    var rows: [PhoneRow] = []
    for snap in snaps {
        let windows = snap.windows.prefix(6).map { w -> PhoneWindow in
            let (text, warns) = forecastLine(w, now: now)
            let kind: String
            switch w.measure {
            case .quota: kind = "quota"
            case .balance: kind = "balance"
            case .meter: kind = "meter"
            }
            return PhoneWindow(label: w.label, usedPercent: w.usedPercent, kind: kind,
                               resetsIn: w.resetsAt.map { Fmt.countdown(to: $0, now: now) }.flatMap { $0.isEmpty ? nil : $0 },
                               forecastText: text, warns: warns, amount: w.amountText)
        }
        guard !windows.isEmpty, snap.isConnected || snap.stateIsIdle else { continue }
        rows.append(PhoneRow(id: snap.id, name: snap.info.name, monogram: snap.info.monogram,
                             color: snap.info.colorHex, plan: snap.plan, status: snap.isConnected ? "ok" : "idle",
                             windows: Array(windows)))
        if rows.count == 12 { break }
    }
    return PhoneSnapshot(generatedAt: iso.string(from: now), hostName: host, rows: rows).json()
}

private func forecastLine(_ w: UsageWindow, now: Date) -> (String?, Bool) {
    guard let f = w.forecast else { return (nil, false) }
    let rate = f.ratePerHour >= 10 ? String(Int(f.ratePerHour.rounded())) : String(format: "%.1f", f.ratePerHour)
    let text: String
    switch f.kind {
    case .rate:
        if f.warnsBeforeReset, let hits = f.hitsLimitAt {
            text = T.t("forecast.limit", T.clock(hits, now: now), T.countdown(to: hits, now: now))
        } else if let r = f.atReset {
            text = T.t("forecast.atReset", "\(Int(r.rounded()))")
        } else {
            text = T.t("forecast.rateOnly", rate)
        }
    case .steady:
        text = f.atReset.map { T.t("forecast.steadyAtReset", "\(Int($0.rounded()))") } ?? T.t("forecast.steady")
    case .measuring:
        text = T.t("forecast.measuring")
    case .limitReached:
        if let r = f.resetsAt, r > now { text = T.t("forecast.limitReachedIn", T.countdown(to: r, now: now)) }
        else { text = T.t("forecast.limitReached") }
    case .noSession:
        text = T.t("forecast.noSession")
    }
    return (text, f.warnsBeforeReset)
}

private extension ProviderSnapshot {
    var stateIsIdle: Bool {
        if case .idle = state { return true }
        return false
    }
}
