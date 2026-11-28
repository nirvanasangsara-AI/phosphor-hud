//! Where each provider keeps its files on Windows, and how sure we are.
//!
//! WSL homes are not searched. A Windows process only looks at `%USERPROFILE%`,
//! `%APPDATA%`, `%LOCALAPPDATA%`, and the environment variables documented below.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Confidence {
    /// Official docs or the tool's own documented environment variable.
    Official,
    /// Layout taken from the macOS reader or the CLI's published source, not a Windows doc.
    Inferred,
    /// A reasonable Windows location that has not been confirmed.
    Assumption,
    /// No known location. The HUD says unavailable.
    Unknown,
}

impl Confidence {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Official => "official",
            Self::Inferred => "inferred",
            Self::Assumption => "assumption",
            Self::Unknown => "unknown",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Official => "official docs",
            Self::Inferred => "inferred",
            Self::Assumption => "unverified",
            Self::Unknown => "unknown on Windows",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct PathDoc {
    pub provider: &'static str,
    pub what: &'static str,
    pub template: &'static str,
    pub confidence: Confidence,
    pub note: &'static str,
    /// A unique snippet the README must contain.
    pub readme_needle: &'static str,
}

pub static PATH_DOCS: &[PathDoc] = &[
    PathDoc {
        provider: "Claude Code",
        what: "OAuth credentials",
        template: "%USERPROFILE%\\.claude\\.credentials.json",
        confidence: Confidence::Official,
        note: "Claude Code's credentials file. CLAUDE_CONFIG_DIR replaces the default directory when it is set (comma-separated list; the first entry wins for the token).",
        readme_needle: "%USERPROFILE%\\.claude\\.credentials.json",
    },
    PathDoc {
        provider: "Claude Code",
        what: "Session logs",
        template: "%USERPROFILE%\\.claude\\projects\\**\\*.jsonl",
        confidence: Confidence::Inferred,
        note: "Same layout the macOS build reads, plus %USERPROFILE%\\.config\\claude\\projects and each CLAUDE_CONFIG_DIR\\projects. Not a separately documented Windows path.",
        readme_needle: "%USERPROFILE%\\.claude\\projects",
    },
    PathDoc {
        provider: "Codex",
        what: "Session logs",
        template: "%CODEX_HOME%\\sessions\\YYYY\\MM\\DD\\rollout-*.jsonl",
        confidence: Confidence::Inferred,
        note: "CODEX_HOME is honored when set. Otherwise both %USERPROFILE%\\.codex\\sessions and %APPDATA%\\codex\\sessions are scanned, because third-party notes disagree on which one Windows uses.",
        readme_needle: "%APPDATA%\\codex",
    },
    PathDoc {
        provider: "Codex",
        what: "Login file",
        template: "%USERPROFILE%\\.codex\\auth.json",
        confidence: Confidence::Official,
        note: "Present only when the CLI's cli_auth_credentials_store is file. The Windows Credential Manager store is not read.",
        readme_needle: "cli_auth_credentials_store",
    },
    PathDoc {
        provider: "Gemini CLI",
        what: "Session logs",
        template: "%USERPROFILE%\\.gemini\\tmp\\<project>\\chats\\session-*.jsonl",
        confidence: Confidence::Official,
        note: "Gemini CLI documents this tmp/chats layout.",
        readme_needle: "%USERPROFILE%\\.gemini\\tmp",
    },
    PathDoc {
        provider: "Grok CLI",
        what: "Login file",
        template: "%USERPROFILE%\\.grok\\auth.json",
        confidence: Confidence::Assumption,
        note: "Medium confidence: this is where the macOS build and community notes look. No official Windows path was confirmed.",
        readme_needle: "%USERPROFILE%\\.grok\\auth.json",
    },
    PathDoc {
        provider: "Copilot",
        what: "GitHub CLI token",
        template: "gh.exe auth token",
        confidence: Confidence::Official,
        note: "The token is requested from GitHub CLI and held in memory for one API call. It is not written to disk.",
        readme_needle: "gh.exe auth token",
    },
    PathDoc {
        provider: "Cline",
        what: "Task logs",
        template: "%APPDATA%\\Code\\User\\globalStorage\\saoudrizwan.claude-dev\\tasks\\*\\ui_messages.json",
        confidence: Confidence::Assumption,
        note: "Also checked under Code - Insiders, Cursor, Windsurf, VSCodium, and Kiro. Unverified.",
        readme_needle: "saoudrizwan.claude-dev",
    },
    PathDoc {
        provider: "Roo Code",
        what: "Task logs",
        template: "%APPDATA%\\<host>\\User\\globalStorage\\rooveterinaryinc.roo-cline\\tasks\\*\\ui_messages.json",
        confidence: Confidence::Assumption,
        note: "Same VS Code globalStorage guess as Cline. Unverified.",
        readme_needle: "rooveterinaryinc.roo-cline",
    },
    PathDoc {
        provider: "Phosphor",
        what: "Shared config",
        template: "%USERPROFILE%\\.config\\phosphor\\",
        confidence: Confidence::Official,
        note: "providers.json, accounts.json, billing-screens.json, alerts.json, and themes use the same shapes as on macOS.",
        readme_needle: ".config\\phosphor",
    },
    PathDoc {
        provider: "Antigravity / Muse / Grok Bot",
        what: "Usage",
        template: "(none)",
        confidence: Confidence::Unknown,
        note: "No Windows path is known. The row says unavailable instead of guessing.",
        readme_needle: "unknown on Windows",
    },
    PathDoc {
        provider: "WSL",
        what: "Linux home",
        template: "(not read)",
        confidence: Confidence::Official,
        note: "Files under \\\\wsl$\\ or a Linux home are left alone. Run the Linux build inside WSL if that is where the CLIs live.",
        readme_needle: "WSL",
    },
];

pub const VSCODE_HOSTS: &[&str] = &[
    "Code",
    "Code - Insiders",
    "Cursor",
    "Windsurf",
    "VSCodium",
    "Kiro",
];

pub fn env_path(env: &HashMap<String, String>, key: &str) -> Option<PathBuf> {
    env.get(key)
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
}

pub fn claude_config_dirs(home: &Path, env: &HashMap<String, String>) -> Vec<PathBuf> {
    if let Some(raw) = env.get("CLAUDE_CONFIG_DIR") {
        let dirs: Vec<PathBuf> = raw
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .collect();
        if !dirs.is_empty() {
            return dirs;
        }
    }
    vec![home.join(".claude")]
}

pub fn claude_credential_file(home: &Path, env: &HashMap<String, String>) -> PathBuf {
    claude_config_dirs(home, env)
        .into_iter()
        .next()
        .unwrap_or_else(|| home.join(".claude"))
        .join(".credentials.json")
}

pub fn claude_log_roots(home: &Path, env: &HashMap<String, String>) -> Vec<PathBuf> {
    let mut roots = vec![
        home.join(".claude").join("projects"),
        home.join(".config").join("claude").join("projects"),
    ];
    if let Some(raw) = env.get("CLAUDE_CONFIG_DIR") {
        for part in raw.split(',') {
            let p = part.trim();
            if !p.is_empty() {
                roots.push(PathBuf::from(p).join("projects"));
            }
        }
    }
    dedupe(roots)
}

/// Codex homes to scan. `CODEX_HOME` wins and is the only home when it is set.
/// Otherwise both the dotfile and `%APPDATA%\codex` are included.
pub fn codex_homes(home: &Path, env: &HashMap<String, String>) -> Vec<PathBuf> {
    if let Some(h) = env_path(env, "CODEX_HOME") {
        return vec![h];
    }
    let mut homes = vec![home.join(".codex")];
    if let Some(app) = env_path(env, "APPDATA") {
        homes.push(app.join("codex"));
    }
    dedupe(homes)
}

pub fn gemini_tmp(home: &Path) -> PathBuf {
    home.join(".gemini").join("tmp")
}

pub fn grok_auth(home: &Path) -> PathBuf {
    home.join(".grok").join("auth.json")
}

pub fn phosphor_config_dir(home: &Path) -> PathBuf {
    home.join(".config").join("phosphor")
}

pub fn phosphor_support_dir(env: &HashMap<String, String>, home: &Path) -> PathBuf {
    if let Some(app) = env_path(env, "APPDATA") {
        app.join("Phosphor")
    } else {
        home.join(".config").join("phosphor")
    }
}

pub fn price_cache_file(env: &HashMap<String, String>, home: &Path) -> PathBuf {
    if let Some(local) = env_path(env, "LOCALAPPDATA") {
        local.join("Phosphor").join("litellm-prices.json")
    } else {
        phosphor_support_dir(env, home).join("litellm-prices.json")
    }
}

pub fn extension_task_roots(env: &HashMap<String, String>, extension_id: &str) -> Vec<PathBuf> {
    let Some(app) = env_path(env, "APPDATA") else {
        return Vec::new();
    };
    VSCODE_HOSTS
        .iter()
        .map(|host| {
            app.join(host)
                .join("User")
                .join("globalStorage")
                .join(extension_id)
                .join("tasks")
        })
        .collect()
}

#[derive(Clone, Debug)]
pub struct LogSource {
    pub id: String,
    pub format: LogFormat,
    pub roots: Vec<PathBuf>,
    pub needles: Vec<String>,
    pub file_suffix: String,
    pub whole_file: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogFormat {
    Claude,
    Codex,
    Gemini,
    Cline,
}

pub fn log_sources(home: &Path, env: &HashMap<String, String>) -> Vec<LogSource> {
    let mut codex_roots = Vec::new();
    for h in codex_homes(home, env) {
        codex_roots.push(h.join("sessions"));
    }
    vec![
        LogSource {
            id: "claude".into(),
            format: LogFormat::Claude,
            roots: claude_log_roots(home, env),
            needles: vec!["\"usage\"".into()],
            file_suffix: ".jsonl".into(),
            whole_file: false,
        },
        LogSource {
            id: "codex".into(),
            format: LogFormat::Codex,
            roots: codex_roots,
            needles: vec!["\"turn_context\"".into(), "\"token_count\"".into()],
            file_suffix: ".jsonl".into(),
            whole_file: false,
        },
        LogSource {
            id: "gemini".into(),
            format: LogFormat::Gemini,
            roots: vec![gemini_tmp(home)],
            needles: vec!["\"tokens\"".into()],
            file_suffix: ".jsonl".into(),
            whole_file: false,
        },
        LogSource {
            id: "cline".into(),
            format: LogFormat::Cline,
            roots: extension_task_roots(env, "saoudrizwan.claude-dev"),
            needles: Vec::new(),
            file_suffix: "ui_messages.json".into(),
            whole_file: true,
        },
        LogSource {
            id: "roo".into(),
            format: LogFormat::Cline,
            roots: extension_task_roots(env, "rooveterinaryinc.roo-cline"),
            needles: Vec::new(),
            file_suffix: "ui_messages.json".into(),
            whole_file: true,
        },
    ]
}

pub fn which(names: &[&str], env: &HashMap<String, String>) -> Option<PathBuf> {
    let path = env.get("PATH").cloned().unwrap_or_default();
    for dir in std::env::split_paths(&path) {
        for name in names {
            let direct = dir.join(name);
            if direct.is_file() {
                return Some(direct);
            }
            if !name.to_ascii_lowercase().ends_with(".exe") {
                let exe = dir.join(format!("{name}.exe"));
                if exe.is_file() {
                    return Some(exe);
                }
            }
        }
    }
    None
}

fn dedupe(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for p in paths {
        if !out.iter().any(|e: &PathBuf| e == &p) {
            out.push(p);
        }
    }
    out
}

pub fn expand_tilde(p: &str, home: &Path) -> PathBuf {
    if p == "~" {
        home.to_path_buf()
    } else if let Some(rest) = p.strip_prefix("~/") {
        home.join(rest)
    } else if let Some(rest) = p.strip_prefix("~\\") {
        home.join(rest)
    } else {
        PathBuf::from(p)
    }
}
