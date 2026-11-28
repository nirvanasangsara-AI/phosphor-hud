//! Display names and which rows the Windows HUD always shows.

#[derive(Clone, Copy, Debug)]
pub struct Meta {
    pub id: &'static str,
    pub name: &'static str,
    pub monogram: &'static str,
    pub color: &'static str,
    /// Always present, so a missing Windows source is visible.
    pub show_always: bool,
    /// No data source on Windows. The row says this and does not probe.
    pub fixed_unavailable: Option<&'static str>,
}

pub static CATALOG: &[Meta] = &[
    Meta { id: "claude", name: "Claude Code", monogram: "C", color: "#D97757", show_always: true, fixed_unavailable: None },
    Meta { id: "codex", name: "Codex", monogram: "Cx", color: "#10A37F", show_always: true, fixed_unavailable: None },
    Meta { id: "antigravity", name: "Antigravity", monogram: "A", color: "#34A853", show_always: true, fixed_unavailable: Some("Unavailable on Windows. Antigravity is read on macOS via the agy CLI, and its Windows data location is not known.") },
    Meta { id: "gemini", name: "Gemini CLI", monogram: "G", color: "#4796E3", show_always: true, fixed_unavailable: None },
    Meta { id: "grok", name: "Grok CLI", monogram: "X", color: "#E5E7EB", show_always: true, fixed_unavailable: None },
    Meta { id: "grokbot", name: "Grok Bot", monogram: "GB", color: "#7DD3FC", show_always: true, fixed_unavailable: Some("Unavailable on Windows. The Grok Bot cache path is not known, so nothing is read.") },
    Meta { id: "copilot", name: "Copilot", monogram: "Co", color: "#8B5CF6", show_always: true, fixed_unavailable: None },
    Meta { id: "muse", name: "Muse Code", monogram: "M", color: "#0866FF", show_always: true, fixed_unavailable: Some("Unavailable on Windows. The Muse CLI login location is not known here.") },
    Meta { id: "cline", name: "Cline", monogram: "Cl", color: "#F5F5F5", show_always: true, fixed_unavailable: None },
    Meta { id: "roo", name: "Roo Code", monogram: "Ro", color: "#FACC15", show_always: true, fixed_unavailable: None },
    Meta { id: "cursor", name: "Cursor", monogram: "Cu", color: "#9CA3AF", show_always: false, fixed_unavailable: None },
    Meta { id: "windsurf", name: "Windsurf", monogram: "Ws", color: "#0EA5E9", show_always: false, fixed_unavailable: None },
    Meta { id: "kiro", name: "Kiro", monogram: "Kr", color: "#7C3AED", show_always: false, fixed_unavailable: None },
    Meta { id: "warp", name: "Warp", monogram: "W", color: "#01A4FF", show_always: false, fixed_unavailable: None },
    Meta { id: "zed", name: "Zed", monogram: "Z", color: "#084CCF", show_always: false, fixed_unavailable: None },
    Meta { id: "amp", name: "Amp", monogram: "Am", color: "#EF4444", show_always: false, fixed_unavailable: None },
    Meta { id: "kimi", name: "Kimi Code", monogram: "K", color: "#6366F1", show_always: false, fixed_unavailable: None },
    Meta { id: "droid", name: "Droid", monogram: "Dr", color: "#F97316", show_always: false, fixed_unavailable: None },
    Meta { id: "opencode", name: "OpenCode", monogram: "Oc", color: "#A3A3A3", show_always: false, fixed_unavailable: None },
    Meta { id: "aider", name: "Aider", monogram: "Ai", color: "#14B8A6", show_always: false, fixed_unavailable: None },
    Meta { id: "gemini-app", name: "Gemini app (web)", monogram: "Gw", color: "#8AB4F8", show_always: false, fixed_unavailable: None },
    Meta { id: "google-ai-credits", name: "Google AI credits", monogram: "Gc", color: "#FBBC04", show_always: false, fixed_unavailable: None },
    Meta { id: "gemini-api", name: "Gemini API", monogram: "Gk", color: "#1A73E8", show_always: false, fixed_unavailable: None },
    Meta { id: "vertex", name: "Vertex AI", monogram: "Vx", color: "#4285F4", show_always: false, fixed_unavailable: None },
    Meta { id: "openrouter", name: "OpenRouter", monogram: "OR", color: "#94A3B8", show_always: false, fixed_unavailable: None },
    Meta { id: "openai-api", name: "OpenAI API", monogram: "OA", color: "#74AA9C", show_always: false, fixed_unavailable: None },
    Meta { id: "anthropic-api", name: "Anthropic API", monogram: "An", color: "#CC785C", show_always: false, fixed_unavailable: None },
    Meta { id: "ollama", name: "Ollama", monogram: "Ol", color: "#E5E5E5", show_always: false, fixed_unavailable: None },
    Meta { id: "lmstudio", name: "LM Studio", monogram: "LM", color: "#6D28D9", show_always: false, fixed_unavailable: None },
    Meta { id: "jetbrains", name: "JetBrains AI", monogram: "JB", color: "#FE2857", show_always: false, fixed_unavailable: None },
];

pub fn meta(id: &str) -> Option<&'static Meta> {
    let base = id.split('@').next().unwrap_or(id);
    CATALOG.iter().find(|m| m.id == base)
}

pub fn display_name(id: &str) -> String {
    if let Some((base, profile)) = id.split_once('@') {
        let name = meta(base).map(|m| m.name).unwrap_or(base);
        return format!("{name} · {profile}");
    }
    meta(id)
        .map(|m| m.name.to_string())
        .unwrap_or_else(|| id.to_string())
}

/// Google AI is one subscription. Only the Antigravity billing entry counts toward the monthly total.
pub fn counts_toward_monthly(id: &str) -> bool {
    let base = id.split('@').next().unwrap_or(id);
    !matches!(
        base,
        "gemini" | "gemini-app" | "google-ai-credits" | "gemini-api" | "vertex"
    )
}

pub fn api_key_env(id: &str) -> Option<&'static str> {
    match id {
        "openrouter" => Some("OPENROUTER_API_KEY"),
        "openai-api" => Some("OPENAI_ADMIN_KEY"),
        "anthropic-api" => Some("ANTHROPIC_ADMIN_KEY"),
        "gemini-api" => Some("GEMINI_API_KEY"),
        _ => None,
    }
}
