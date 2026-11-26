import AppKit

/// "Connect" = run the service's own official sign-in (installing its CLI first if needed) in a
/// Terminal window the user can see, then pick the result up the moment it finishes.
/// Phosphor never handles the password, the OAuth code or the token itself: the official CLI does
/// the login and stores the credential exactly where it always does, and Phosphor reads it as usual.
enum Connect {
    struct Plan {
        let title: String          // first line shown in the Terminal window
        let script: String         // zsh, run as a login shell so Homebrew/npm PATHs are set up
    }

    /// Where the finished sign-in drops a marker for Phosphor to notice.
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phosphor/connect")
    }

    static let supported = ["claude", "codex", "antigravity", "grok", "copilot", "muse"]

    static func plan(for id: String) -> Plan? {
        let brew = Shell.which("brew")
        let npm = Shell.which("npm")
        func have(_ bin: String) -> String? { Shell.which(bin) }
        func install(_ name: String, brewPkg: String?, npmPkg: String?) -> String {
            if let brewPkg, let brew { return "\"\(brew)\" install \(brewPkg)" }
            if let npmPkg, let npm { return "\"\(npm)\" install -g \(npmPkg)" }
            return "echo 'Install \(name) first (Homebrew or npm not found).'; exit 1"
        }
        switch id {
        case "claude":
            let bin = have("claude")
            return Plan(title: "Sign in to Claude Code", script: """
                \(bin == nil ? install("Claude Code", brewPkg: "--cask claude-code", npmPkg: "@anthropic-ai/claude-code") : ":")
                claude auth login
                """)
        case "codex":
            let bin = have("codex")
            return Plan(title: "Sign in to Codex with ChatGPT", script: """
                \(bin == nil ? install("Codex CLI", brewPkg: "--cask codex", npmPkg: "@openai/codex") : ":")
                codex login
                """)
        case "antigravity":
            let bin = have("agy")
            let installer = brew != nil ? "\"\(brew!)\" install --cask antigravity-cli"
                : "curl -fsSL https://antigravity.google/cli/install.sh | bash"
            return Plan(title: "Sign in to Antigravity", script: """
                \(bin == nil ? installer + " || exit 1" : ":")
                export PATH="$HOME/.local/bin:$PATH"
                echo
                echo "  Sign in with Google in the browser."
                echo "  When agy is ready, type /quit here and Phosphor checks the connection."
                echo
                agy
                """)
        case "grok":
            // Absolute path on purpose: a shell function named `grok` (e.g. an API-key wrapper)
            // must not shadow the CLI's own login.
            guard let bin = have("grok") else {
                return Plan(title: "Grok CLI not found", script: "echo 'Install the Grok CLI from xAI, then press Connect again.'; exit 1")
            }
            return Plan(title: "Sign in to Grok", script: "\"\(bin)\" login")
        case "copilot":
            let bin = have("gh")
            return Plan(title: "Sign in to GitHub (Copilot)", script: """
                \(bin == nil ? install("GitHub CLI", brewPkg: "gh", npmPkg: nil) : ":")
                gh auth login --hostname github.com --web --git-protocol https
                """)
        case "muse":
            // Meta's own installer (checks the launcher's sha256) puts `muse` in ~/.local/bin.
            // `muse login` is a device-code flow: it shows a code, you approve it in the browser.
            let bin = have("muse")
            return Plan(title: "Sign in to Muse Code", script: """
                \(bin == nil ? "curl -fsSL https://dev.meta.ai/install.sh | bash || exit 1" : ":")
                export PATH="$HOME/.local/bin:$PATH"
                echo
                echo "  Open the link, check the code matches, and press Approve in the browser."
                echo "  Nothing happens until you press Approve."
                echo
                muse login
                """)
        default:
            return nil
        }
    }

    enum Started { case opened, alreadyOpen, unsupported }

    /// Opens Terminal running the plan, unless that sign-in is already open (then it's brought
    /// to the front instead of opening a second window).
    static func start(_ id: String, name: String) -> Started {
        if isRunning(id) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.activate()
            return .alreadyOpen
        }
        guard let plan = plan(for: id) else { return .unsupported }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: url(id, "failed"))
        let q = { (u: URL) in "\"" + u.path + "\"" }
        let work = dir.appendingPathComponent("workspace")
        let phosphor = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // Each step is visible; nothing is hidden from the user. The CLI exiting proves nothing,
        // so the script ends by asking Phosphor itself to read the usage with the new login.
        let body = """
            #!/bin/zsh -l
            echo $$ > \(q(url(id, "pid")))
            trap 'rm -f \(q(url(id, "pid")))' EXIT
            # Run from an empty folder: agent CLIs ask whether to trust the current directory,
            # and that question shouldn't be about the user's home folder.
            mkdir -p \(q(work)) && cd \(q(work))
            clear
            print -P "%B\(plan.title)%b  ·  started by Phosphor"
            echo
            (
            \(plan.script)
            )
            echo
            echo "Checking that \(name) is really connected…"
            for i in 1 2 3 4; do
              out="$(\(q(URL(fileURLWithPath: phosphor))) --check \(id) 2>&1)" && {
                print -P "%B$out%b"; echo; echo "You can close this window."; exit 0; }
              sleep 3
            done
            print -r -- "$out" > \(q(url(id, "failed")))
            print -P "%B$out%b"
            echo
            echo "Not connected yet. Press Connect in Phosphor to try again."
            """
        do {
            let file = url(id, "command")
            try body.write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            try Date().description.write(to: url(id, "started"), atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(file)
        } catch { return .unsupported }
        return .opened
    }

    private static func url(_ id: String, _ ext: String) -> URL { dir.appendingPathComponent("\(id).\(ext)") }

    /// The sign-in window for `id` is still running (its script wrote a pid and hasn't exited).
    static func isRunning(_ id: String) -> Bool {
        guard let text = try? String(contentsOf: url(id, "pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        if kill(pid, 0) == 0 { return true }
        try? FileManager.default.removeItem(at: url(id, "pid"))   // stale
        return false
    }

    /// The reason the post-sign-in check failed, once the script has given up.
    static func failure(_ id: String) -> String? {
        (try? String(contentsOf: url(id, "failed"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "✗ ", with: "")
    }

    /// Providers with a sign-in started in the last 15 minutes; Phosphor polls them quickly.
    static var pending: [String] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "started" }.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > 900 { try? fm.removeItem(at: url); return nil }
            return url.deletingPathExtension().lastPathComponent
        }
    }

    static func finish(_ id: String) {
        try? FileManager.default.removeItem(at: url(id, "started"))
        try? FileManager.default.removeItem(at: url(id, "failed"))
    }
}
