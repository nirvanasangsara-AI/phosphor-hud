//! Builds the HUD model from local files. Tokens from credential files are used
//! only as request headers and are never copied onto the model.

use crate::alerts::{staleness, AlertEngine, AlertMemory, BillingReading, Credit, QuotaReading};
use crate::catalog::{self, meta};
use crate::config::{self, ScreenReading};
use crate::devstats::{self, DevCounts};
use crate::forecast::{self, ForecastSample, QuotaForecast};
use crate::ledger::{LogScanner, UsageLedger};
use crate::paths::{self, LogFormat, LogSource};
use crate::pricing::PriceTable;
use crate::quota::{self, ParsedWindow};
use crate::timeutil::{self, compact_number};
use crate::token_refresh::{self, needs_refresh};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

pub const CLAUDE_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
pub const CODEX_USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
pub const GROK_BILLING_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
pub const COPILOT_USAGE_URL: &str = "https://api.github.com/copilot_internal/user";

#[derive(Debug)]
pub enum TransportError {
    Http(u16),
    Disabled,
    Other(String),
}

impl TransportError {
    pub fn public_message(&self) -> String {
        match self {
            Self::Http(401) | Self::Http(403) => "login expired".into(),
            Self::Http(code) => format!("HTTP {code}"),
            Self::Disabled => "live quota was not requested".into(),
            Self::Other(s) => s.clone(),
        }
    }
}

pub trait UsageTransport {
    fn get_json(&self, url: &str, headers: &[(&str, String)]) -> Result<Value, TransportError>;
    fn command(&self, command: &str) -> Result<String, TransportError> {
        let _ = command;
        Err(TransportError::Disabled)
    }
    fn gh_token(&self) -> Result<Option<String>, TransportError> {
        Ok(None)
    }
}

pub struct Offline;

impl UsageTransport for Offline {
    fn get_json(&self, _url: &str, _headers: &[(&str, String)]) -> Result<Value, TransportError> {
        Err(TransportError::Disabled)
    }
}

pub struct HudOptions<'a> {
    pub home: &'a Path,
    pub env: &'a HashMap<String, String>,
    pub now: f64,
    pub tz_offset_secs: i32,
    pub config_dir: &'a Path,
    pub support_dir: &'a Path,
    pub prices: &'a PriceTable,
    pub fx: &'a HashMap<String, f64>,
    pub transport: &'a dyn UsageTransport,
    pub demo: bool,
    pub show_dev: bool,
    pub dev_counts: Option<&'a DevCounts>,
    pub persist: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowView {
    pub label: String,
    pub used_percent: f64,
    pub kind: String,
    pub amount: Option<String>,
    pub active_session: bool,
    pub resets_at: Option<f64>,
    pub window_seconds: Option<f64>,
    pub resets_in: Option<String>,
    pub forecast_rate: Option<String>,
    pub forecast_text: Option<String>,
    pub warns: bool,
    #[serde(default)]
    pub gauged: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRow {
    pub id: String,
    pub name: String,
    pub monogram: String,
    pub color: String,
    pub plan: Option<String>,
    pub status: String,
    pub message: Option<String>,
    pub confidence: String,
    pub windows: Vec<WindowView>,
    pub detail: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DevStrip {
    pub login: String,
    pub merged_today: i64,
    pub merged_7: i64,
    pub merged_30: i64,
    pub commits_7: i64,
    pub commits_30: i64,
    pub prs_per_week: f64,
    pub tier_label: String,
    pub cost_per_pr: Option<f64>,
    pub tokens_per_pr: Option<f64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Footer {
    pub tokens: i64,
    pub api_value: f64,
    pub unpriced: i64,
    pub days: i64,
    pub monthly_usd: Option<f64>,
    pub roi: Option<f64>,
    pub note: String,
    pub dev: Option<DevStrip>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HudModel {
    pub rows: Vec<ProviderRow>,
    pub alerts: Vec<String>,
    pub footer: Footer,
    pub generated_at: f64,
    pub demo: bool,
    pub show_dev: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Sample {
    t: f64,
    p: String,
    w: String,
    u: f64,
    #[serde(default)]
    r: Option<f64>,
}

pub fn load_hud(opt: &HudOptions<'_>) -> HudModel {
    if opt.demo {
        return demo_model(opt.now, opt.tz_offset_secs);
    }

    let accounts = read_accounts(opt);
    let screens = read_screens(opt);
    let mut sources = paths::log_sources(opt.home, opt.env);
    push_profile_sources(&mut sources, &accounts, opt.home, opt.env);

    let mut ledger = if opt.persist {
        UsageLedger::load(&opt.support_dir.join("usage-ledger.json"))
    } else {
        UsageLedger::default()
    };
    LogScanner {
        sources,
        window_days: 35,
        initial_days: 7,
        tz_offset_secs: opt.tz_offset_secs,
    }
    .scan(&mut ledger, opt.now);
    if opt.persist {
        ledger.save(&opt.support_dir.join("usage-ledger.json"));
    }

    let mut rows = Vec::new();
    rows.push(claude_row(opt, &ledger, None));
    for p in accounts.iter().filter(|p| p.provider == "claude") {
        rows.push(claude_row(opt, &ledger, Some(p)));
    }
    rows.push(codex_row(opt, &ledger, None));
    for p in accounts.iter().filter(|p| p.provider == "codex") {
        rows.push(codex_row(opt, &ledger, Some(p)));
    }
    rows.push(gemini_row(opt, &ledger));
    rows.push(grok_row(opt, &ledger));
    rows.push(copilot_row(opt));
    for id in ["antigravity", "muse", "grokbot"] {
        rows.push(fixed_row(id));
    }
    rows.push(task_row(opt, &ledger, "cline"));
    rows.push(task_row(opt, &ledger, "roo"));
    rows.extend(extra_rows(opt, &screens));
    rows.extend(custom_rows(opt));

    for row in &mut rows {
        apply_screen(row, screens.get(&base_id(&row.id)), opt.now);
    }

    let mut history = load_history(&opt.support_dir.join("history.jsonl"), opt.now);
    let mut fresh = Vec::new();
    apply_forecasts(&mut rows, &history, opt.now, opt.tz_offset_secs, &mut fresh);
    if opt.persist && !fresh.is_empty() {
        history.extend(fresh.iter().cloned());
        save_history(&opt.support_dir.join("history.jsonl"), &history, opt.now);
    }

    let alerts = evaluate_alerts(opt, &rows, &screens);
    sort_rows(&mut rows);
    let footer = footer(opt, &ledger, &screens);

    HudModel {
        rows,
        alerts,
        footer,
        generated_at: opt.now,
        demo: false,
        show_dev: opt.show_dev,
    }
}

fn base_id(id: &str) -> String {
    id.split('@').next().unwrap_or(id).to_string()
}

fn blank(id: &str) -> ProviderRow {
    let m = meta(id.split('@').next().unwrap_or(id));
    ProviderRow {
        id: id.into(),
        name: catalog::display_name(id),
        monogram: m.map(|m| m.monogram).unwrap_or("?").into(),
        color: m.map(|m| m.color).unwrap_or("#94A3B8").into(),
        plan: None,
        status: "unavailable".into(),
        message: None,
        confidence: "unknown".into(),
        windows: Vec::new(),
        detail: None,
    }
}

fn fixed_row(id: &str) -> ProviderRow {
    let mut row = blank(id);
    row.message = meta(id)
        .and_then(|m| m.fixed_unavailable)
        .map(|s| s.to_string());
    row.confidence = "unknown".into();
    row
}

fn claude_row(
    opt: &HudOptions<'_>,
    ledger: &UsageLedger,
    profile: Option<&config::Profile>,
) -> ProviderRow {
    let id = profile.map(|p| p.id()).unwrap_or_else(|| "claude".into());
    let mut row = blank(&id);
    row.confidence = "official".into();
    let cred_path = if let Some(p) = profile {
        PathBuf::from(p.config_dir.clone().unwrap_or_default()).join(".credentials.json")
    } else {
        paths::claude_credential_file(opt.home, opt.env)
    };
    let source = if profile.is_some() {
        id.clone()
    } else {
        "claude".into()
    };
    let logs = log_line(ledger, &source, opt);
    match read_claude(&cred_path, opt.now) {
        ClaudeCred::Ready { token, plan } => {
            row.plan = plan;
            match opt.transport.get_json(
                CLAUDE_USAGE_URL,
                &[
                    ("Authorization", format!("Bearer {token}")),
                    ("anthropic-beta", "oauth-2025-04-20".into()),
                    ("User-Agent", "phosphor-hud/0.1".into()),
                    ("Accept", "application/json".into()),
                ],
            ) {
                Ok(body) => {
                    let parsed = quota::claude_usage(&body);
                    if parsed.windows.is_empty() {
                        row.status = "error".into();
                        row.message = Some("Claude usage response had no windows.".into());
                    } else {
                        row.status = "ok".into();
                        row.windows = parsed.windows.into_iter().map(view_of).collect();
                    }
                }
                Err(e) => {
                    row.status =
                        if matches!(e, TransportError::Http(401) | TransportError::Http(403)) {
                            "error".into()
                        } else if matches!(e, TransportError::Disabled) {
                            "idle".into()
                        } else {
                            "error".into()
                        };
                    row.message = Some(e.public_message());
                }
            }
        }
        ClaudeCred::Waiting { plan } => {
            row.plan = plan;
            row.status = "idle".into();
            row.message = Some(
                "Waiting for token refresh · local logs active. Claude Code renews its own token; Phosphor does not write it."
                    .into(),
            );
        }
        ClaudeCred::Expired => {
            row.status = "unavailable".into();
            row.message = Some(
                "Claude Code login expired, and the credentials file has no refresh token.".into(),
            );
        }
        ClaudeCred::Missing => {
            row.status = "unavailable".into();
            row.message = Some(format!(
                "Claude Code is not logged in. Looked for {} (official).",
                cred_path.display()
            ));
        }
        ClaudeCred::Unreadable => {
            row.status = "error".into();
            row.message = Some("The Claude credentials file has no access token.".into());
        }
    }
    if let Some(line) = logs {
        if row.windows.is_empty() {
            row.windows = vec![meter_window(&line)];
            if row.status == "unavailable" {
                row.status = "ok".into();
            }
        }
        row.detail = Some(line);
    }
    row
}

enum ClaudeCred {
    Missing,
    Unreadable,
    Expired,
    Waiting { plan: Option<String> },
    Ready { token: String, plan: Option<String> },
}

fn read_claude(path: &Path, now: f64) -> ClaudeCred {
    if !path.is_file() {
        return ClaudeCred::Missing;
    }
    let Ok(data) = fs::read(path) else {
        return ClaudeCred::Unreadable;
    };
    let Ok(v) = serde_json::from_slice::<Value>(&data) else {
        return ClaudeCred::Unreadable;
    };
    let oauth = v
        .get("claudeAiOauth")
        .filter(|x| x.is_object())
        .unwrap_or(&v);
    let Some(token) = oauth
        .get("accessToken")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    else {
        return ClaudeCred::Unreadable;
    };
    let plan = oauth
        .get("subscriptionType")
        .and_then(Value::as_str)
        .map(timeutil::capitalized);
    let exp = oauth.get("expiresAt").and_then(timeutil::epoch_from_value);
    if let Some(exp) = exp {
        if exp < now {
            let refresh = oauth
                .get("refreshToken")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty());
            return if refresh.is_some() {
                ClaudeCred::Waiting { plan }
            } else {
                ClaudeCred::Expired
            };
        }
    }
    ClaudeCred::Ready {
        token: token.to_string(),
        plan,
    }
}

fn codex_row(
    opt: &HudOptions<'_>,
    ledger: &UsageLedger,
    profile: Option<&config::Profile>,
) -> ProviderRow {
    let id = profile.map(|p| p.id()).unwrap_or_else(|| "codex".into());
    let mut row = blank(&id);
    let homes: Vec<PathBuf> = if let Some(p) = profile {
        vec![PathBuf::from(p.home.clone().unwrap_or_default())]
    } else {
        paths::codex_homes(opt.home, opt.env)
    };
    let auth = homes
        .iter()
        .map(|h| h.join("auth.json"))
        .find(|p| p.is_file());
    let source = if profile.is_some() {
        id.clone()
    } else {
        "codex".into()
    };
    let logs = log_line(ledger, &source, opt);
    row.confidence = if auth.is_some() {
        "official"
    } else {
        "inferred"
    }
    .into();
    match auth {
        None => {
            row.status = "unavailable".into();
            row.message = Some(
                "No Codex auth.json. On Windows the CLI often keeps the login in Credential Manager unless cli_auth_credentials_store is file. Credential Manager is not read."
                    .into(),
            );
        }
        Some(path) => match read_codex_auth(&path, opt.now) {
            CodexCred::Ready { token, account } => {
                let mut headers = vec![
                    ("Authorization".into(), format!("Bearer {token}")),
                    ("User-Agent".into(), "codex-cli".into()),
                    ("Accept".into(), "application/json".into()),
                ];
                if let Some(acct) = account {
                    headers.push(("ChatGPT-Account-Id".into(), acct));
                }
                let header_refs: Vec<(&str, String)> = headers
                    .iter()
                    .map(|(k, v): &(String, String)| (k.as_str(), v.clone()))
                    .collect();
                match opt.transport.get_json(CODEX_USAGE_URL, &header_refs) {
                    Ok(body) => {
                        let parsed = quota::codex_usage(&body, opt.now);
                        if parsed.windows.is_empty() {
                            row.status = "error".into();
                            row.message =
                                Some("Codex usage response had no rate-limit windows.".into());
                        } else {
                            row.status = "ok".into();
                            row.plan = parsed.plan;
                            row.windows = parsed.windows.into_iter().map(view_of).collect();
                        }
                    }
                    Err(e) => {
                        row.status = if matches!(e, TransportError::Disabled) {
                            "idle"
                        } else {
                            "error"
                        }
                        .into();
                        row.message = Some(e.public_message());
                    }
                }
            }
            CodexCred::NearExpiry => {
                row.status = "idle".into();
                row.message = Some(
                    "Codex access token is expired or about to expire. This Windows build does not refresh it, and it does not read Credential Manager."
                        .into(),
                );
            }
            CodexCred::Unreadable => {
                row.status = "error".into();
                row.message = Some("Codex auth.json has no access token.".into());
            }
        },
    }
    if let Some(line) = logs {
        if row.windows.is_empty() {
            row.windows = vec![meter_window(&line)];
            if row.status == "unavailable" {
                row.status = "ok".into();
            }
        }
        row.detail = Some(line);
    }
    row
}

enum CodexCred {
    Unreadable,
    NearExpiry,
    Ready {
        token: String,
        account: Option<String>,
    },
}

fn read_codex_auth(path: &Path, now: f64) -> CodexCred {
    let Ok(data) = fs::read(path) else {
        return CodexCred::Unreadable;
    };
    let Ok(v) = serde_json::from_slice::<Value>(&data) else {
        return CodexCred::Unreadable;
    };
    let Some(token) = v
        .pointer("/tokens/access_token")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    else {
        return CodexCred::Unreadable;
    };
    let exp = token_refresh::codex_access_expiry(&v);
    if needs_refresh(exp, now, token_refresh::DEFAULT_LEEWAY) {
        return CodexCred::NearExpiry;
    }
    let account = v
        .pointer("/tokens/account_id")
        .and_then(Value::as_str)
        .map(|s| s.to_string());
    CodexCred::Ready {
        token: token.to_string(),
        account,
    }
}

fn gemini_row(opt: &HudOptions<'_>, ledger: &UsageLedger) -> ProviderRow {
    let mut row = blank("gemini");
    row.confidence = "official".into();
    if let Some(line) = log_line(ledger, "gemini", opt) {
        row.status = "ok".into();
        row.windows = vec![meter_window(&line)];
        row.detail =
            Some("API-equivalent from local logs. Gemini CLI has no separate quota file.".into());
        row.message = Some(line);
    } else {
        row.status = "unavailable".into();
        row.message = Some(format!(
            "No Gemini CLI session logs in {} (official).",
            paths::gemini_tmp(opt.home).display()
        ));
    }
    row
}

fn grok_row(opt: &HudOptions<'_>, ledger: &UsageLedger) -> ProviderRow {
    let mut row = blank("grok");
    row.confidence = "assumption".into();
    let path = paths::grok_auth(opt.home);
    if !path.is_file() {
        row.status = "unavailable".into();
        row.message = Some(format!(
            "No Grok CLI auth file at {} (unverified path).",
            path.display()
        ));
        return row;
    }
    let Ok(data) = fs::read(&path) else {
        row.status = "error".into();
        row.message = Some("Grok auth.json could not be read.".into());
        return row;
    };
    let Ok(v) = serde_json::from_slice::<Value>(&data) else {
        row.status = "error".into();
        row.message = Some("Grok auth.json is not JSON.".into());
        return row;
    };
    let Some((_key, entry)) = token_refresh::grok_entry(&v) else {
        row.status = "error".into();
        row.message = Some("Grok auth.json has no access token.".into());
        return row;
    };
    let exp = token_refresh::grok_expiry(&entry);
    if needs_refresh(exp, opt.now, token_refresh::DEFAULT_LEEWAY) {
        row.status = "idle".into();
        row.message = Some(
            "Grok access token is expired or about to expire. This Windows build does not refresh it.".into(),
        );
        return row;
    }
    let Some(token) = entry.get("key").and_then(Value::as_str) else {
        row.status = "error".into();
        row.message = Some("Grok auth.json has no access token.".into());
        return row;
    };
    match opt.transport.get_json(
        GROK_BILLING_URL,
        &[
            ("Authorization", format!("Bearer {token}")),
            ("x-xai-token-auth", "xai-grok-cli".into()),
            ("Accept", "application/json".into()),
        ],
    ) {
        Ok(body) => {
            let parsed = quota::grok_usage(&body, opt.now);
            if parsed.windows.is_empty() {
                row.status = "error".into();
                row.message = Some("Grok billing response had no credit usage.".into());
            } else {
                row.status = "ok".into();
                row.plan = parsed.plan;
                row.windows = parsed.windows.into_iter().map(view_of).collect();
            }
        }
        Err(e) => {
            row.status = if matches!(e, TransportError::Disabled) {
                "idle"
            } else {
                "error"
            }
            .into();
            row.message = Some(e.public_message());
        }
    }
    let _ = ledger;
    row
}

fn copilot_row(opt: &HudOptions<'_>) -> ProviderRow {
    let mut row = blank("copilot");
    row.confidence = "official".into();
    let token = match opt.transport.gh_token() {
        Ok(Some(t)) if !t.trim().is_empty() => t,
        Ok(_) => {
            row.message = Some(
                "GitHub CLI is not logged in. Install gh and run gh auth login. Phosphor asks gh for a token and does not read browser cookies."
                    .into(),
            );
            return row;
        }
        Err(e) => {
            row.status = "error".into();
            row.message = Some(e.public_message());
            return row;
        }
    };
    match opt.transport.get_json(
        COPILOT_USAGE_URL,
        &[
            ("Authorization", format!("token {}", token.trim())),
            ("User-Agent", "phosphor-hud".into()),
            ("Accept", "application/json".into()),
        ],
    ) {
        Ok(body) => {
            let parsed = quota::copilot_usage(&body);
            if parsed.windows.is_empty() {
                row.status = "unavailable".into();
                row.message = Some("No Copilot plan on this GitHub account.".into());
            } else {
                row.status = "ok".into();
                row.plan = parsed.plan;
                row.windows = parsed.windows.into_iter().map(view_of).collect();
            }
        }
        Err(e) => {
            row.status = if matches!(e, TransportError::Disabled) {
                "idle"
            } else {
                "error"
            }
            .into();
            row.message = Some(e.public_message());
        }
    }
    row
}

fn task_row(opt: &HudOptions<'_>, ledger: &UsageLedger, id: &str) -> ProviderRow {
    let mut row = blank(id);
    row.confidence = "assumption".into();
    let ext = if id == "roo" {
        "rooveterinaryinc.roo-cline"
    } else {
        "saoudrizwan.claude-dev"
    };
    if let Some(line) = log_line(ledger, id, opt) {
        row.status = "ok".into();
        row.windows = vec![meter_window(&line)];
        row.detail = Some(format!(
            "Task logs under %APPDATA% ({ext}, unverified path)."
        ));
        row.message = Some(line);
        return row;
    }
    let roots = paths::extension_task_roots(opt.env, ext);
    if roots.iter().any(|p| p.is_dir()) {
        row.status = "idle".into();
        row.message = Some(format!(
            "Found {ext} storage, but no task usage yet (unverified path)."
        ));
    } else {
        row.status = "unavailable".into();
        row.message = Some(format!(
            "No {ext} tasks under %APPDATA%\\<host>\\User\\globalStorage (unverified path)."
        ));
    }
    row
}

fn extra_rows(opt: &HudOptions<'_>, screens: &HashMap<String, ScreenReading>) -> Vec<ProviderRow> {
    let mut out = Vec::new();
    for m in catalog::CATALOG.iter().filter(|m| !m.show_always) {
        let screen = screens.get(m.id).filter(|s| s.checked_at.is_some());
        let evidence = install_evidence(m.id, opt.home, opt.env);
        let key_set = catalog::api_key_env(m.id)
            .map(|k| env_nonempty(opt.env, k))
            .unwrap_or(false);
        if screen.is_none() && evidence.is_none() && !key_set {
            continue;
        }
        let mut row = blank(m.id);
        row.confidence = "assumption".into();
        if m.id == "ollama" || m.id == "lmstudio" {
            out.push(local_server_row(opt, m.id));
            continue;
        }
        if let Some(env_key) = catalog::api_key_env(m.id) {
            if key_set {
                row.status = "idle".into();
                row.message = Some(format!(
                    "{env_key} is set. This Windows build does not call that spend API, and it does not store the key."
                ));
            }
        }
        if row.message.is_none() {
            row.status = "idle".into();
            let where_ = evidence.unwrap_or_else(|| "billing-screens.json".into());
            row.message = Some(format!(
                "Installed ({where_}). No usage API on Windows. Plan and price come from billing-screens.json when you fill that in."
            ));
        }
        if let Some(s) = screen {
            if let Some(plan) = &s.plan {
                row.plan = Some(plan.clone());
            }
        }
        out.push(row);
    }
    out
}

fn local_server_row(opt: &HudOptions<'_>, id: &str) -> ProviderRow {
    let mut row = blank(id);
    row.confidence = "assumption".into();
    let url = if id == "ollama" {
        "http://127.0.0.1:11434/api/tags"
    } else {
        "http://127.0.0.1:1234/v1/models"
    };
    match opt.transport.get_json(url, &[]) {
        Ok(body) => {
            let names = model_names(&body);
            row.status = "ok".into();
            row.message = Some(if names.is_empty() {
                "Local server is up. No model names in the response.".into()
            } else {
                format!("{} models on this machine.", names.len())
            });
            if !names.is_empty() {
                row.detail = Some(names.join(", "));
            }
        }
        Err(_) => {
            row.status = "idle".into();
            row.message = Some(format!(
                "Looks installed, but {url} did not answer. Nothing is guessed."
            ));
        }
    }
    row
}

fn model_names(body: &Value) -> Vec<String> {
    let list = body
        .get("models")
        .and_then(Value::as_array)
        .or_else(|| body.get("data").and_then(Value::as_array));
    let Some(list) = list else { return Vec::new() };
    list.iter()
        .filter_map(|m| {
            m.get("name")
                .and_then(Value::as_str)
                .or_else(|| m.get("id").and_then(Value::as_str))
                .map(|s| s.to_string())
        })
        .take(8)
        .collect()
}

fn custom_rows(opt: &HudOptions<'_>) -> Vec<ProviderRow> {
    let path = opt.config_dir.join("providers.json");
    let Ok(data) = fs::read(&path) else {
        return Vec::new();
    };
    let mut rows = Vec::new();
    for entry in config::parse_providers(&data) {
        let mut row = blank(&entry.id);
        if let Some(name) = entry.name.clone() {
            row.name = name;
        }
        if let Some(color) = entry.color.clone() {
            row.color = color;
        }
        row.confidence = "official".into();
        let command = paths::expand_tilde(&entry.command, opt.home);
        let command = command.to_string_lossy().to_string();
        match opt.transport.command(&command) {
            Ok(raw) => match serde_json::from_str::<Value>(&raw) {
                Ok(v) => match quota::custom_windows(&v) {
                    Ok(parsed) => {
                        row.status = "ok".into();
                        row.plan = parsed.plan;
                        row.windows = parsed.windows.into_iter().map(view_of).collect();
                    }
                    Err(_) => {
                        row.status = "error".into();
                        row.message =
                            Some("Custom provider command did not print usage JSON.".into());
                    }
                },
                Err(_) => {
                    row.status = "error".into();
                    row.message = Some("Custom provider command did not print usage JSON.".into());
                }
            },
            Err(e) => {
                row.status = "idle".into();
                row.message = Some(match e {
                    TransportError::Disabled => "Custom provider command was not run.".into(),
                    other => other.public_message(),
                });
            }
        }
        rows.push(row);
    }
    rows
}

fn view_of(w: ParsedWindow) -> WindowView {
    let amount = match w.kind {
        crate::quota::WindowKind::Quota => None,
        crate::quota::WindowKind::Balance => Some(balance_text(
            w.left.unwrap_or(0.0),
            w.total,
            w.unit.as_deref().unwrap_or(""),
        )),
        crate::quota::WindowKind::Meter => Some(format!(
            "{} {}",
            compact_number(w.total.unwrap_or(0.0)),
            w.unit.as_deref().unwrap_or("tokens")
        )),
    };
    let gauged = match w.kind {
        crate::quota::WindowKind::Quota => true,
        crate::quota::WindowKind::Balance => w.total.unwrap_or(0.0) > 0.0,
        crate::quota::WindowKind::Meter => false,
    };
    WindowView {
        label: w.label,
        used_percent: w.used_percent,
        kind: match w.kind {
            crate::quota::WindowKind::Quota => "quota",
            crate::quota::WindowKind::Balance => "balance",
            crate::quota::WindowKind::Meter => "meter",
        }
        .into(),
        amount,
        active_session: w.active_session,
        resets_at: w.resets_at,
        window_seconds: w.window_seconds,
        resets_in: None,
        forecast_rate: None,
        forecast_text: None,
        warns: false,
        gauged,
    }
}

fn balance_text(left: f64, total: Option<f64>, unit: &str) -> String {
    let unit = if unit.is_empty() { "credits" } else { unit };
    if let Some(total) = total.filter(|t| *t > 0.0) {
        format!(
            "{} of {} {unit} left",
            compact_number(left),
            compact_number(total)
        )
    } else {
        format!("{} {unit} left", compact_number(left))
    }
}

fn meter_window(line: &str) -> WindowView {
    WindowView {
        label: "7D".into(),
        used_percent: 0.0,
        kind: "meter".into(),
        amount: Some(line.to_string()),
        active_session: true,
        resets_at: None,
        window_seconds: Some(604800.0),
        resets_in: None,
        forecast_rate: None,
        forecast_text: None,
        warns: false,
        gauged: false,
    }
}

fn log_line(ledger: &UsageLedger, source: &str, opt: &HudOptions<'_>) -> Option<String> {
    let s = ledger.summary(7, Some(source), opt.prices, opt.now, opt.tz_offset_secs);
    if s.tokens == 0 && s.cost == 0.0 {
        return None;
    }
    let mut line = format!("Logs 7D: {} tokens", compact_number(s.tokens as f64));
    if s.cost > 0.0 {
        line.push_str(&format!(" · ≈${:.2} API-equivalent", s.cost));
    }
    if s.unpriced_tokens > 0 {
        line.push_str(&format!(
            " · {} unpriced",
            compact_number(s.unpriced_tokens as f64)
        ));
    }
    Some(line)
}

fn apply_screen(row: &mut ProviderRow, screen: Option<&ScreenReading>, now: f64) {
    let Some(s) = screen else { return };
    let Some(checked) = s.checked_at else { return };
    let override_plan = s.override_fields.iter().any(|f| f == "plan");
    if row.plan.is_none() || override_plan {
        if let Some(plan) = &s.plan {
            row.plan = Some(plan.clone());
        }
    }
    let bill = if s.next_bill.is_some() {
        s.next_bill
    } else {
        None
    };
    let reasons = staleness(bill, Some(checked), now, 30);
    if !reasons.is_empty() {
        let note = "Billing screen needs a refresh.";
        row.message = Some(match &row.message {
            Some(m) => format!("{m} {note}"),
            None => note.into(),
        });
    }
}

fn apply_forecasts(
    rows: &mut [ProviderRow],
    history: &[Sample],
    now: f64,
    tz: i32,
    fresh: &mut Vec<Sample>,
) {
    for row in rows {
        if row.status != "ok" && row.status != "idle" {
            continue;
        }
        for w in &mut row.windows {
            if let Some(r) = w.resets_at {
                if r > now {
                    w.resets_in = Some(timeutil::countdown(r, now));
                }
            }
            if !w.gauged {
                continue;
            }
            let samples: Vec<ForecastSample> = history
                .iter()
                .filter(|s| s.p == row.id && s.w == w.label)
                .map(|s| ForecastSample::new(s.t, s.u, s.r))
                .collect();
            let f = QuotaForecast::make(
                w.used_percent,
                w.resets_at,
                w.window_seconds,
                w.active_session,
                &samples,
                now,
            );
            let (rate, text) = forecast::caption(&f, now, tz);
            w.forecast_rate = rate;
            w.forecast_text = Some(text);
            w.warns = f.warns_before_reset();
            if row.status == "ok" {
                fresh.push(Sample {
                    t: now,
                    p: row.id.clone(),
                    w: w.label.clone(),
                    u: w.used_percent,
                    r: w.resets_at,
                });
            }
        }
    }
}

fn evaluate_alerts(
    opt: &HudOptions<'_>,
    rows: &[ProviderRow],
    screens: &HashMap<String, ScreenReading>,
) -> Vec<String> {
    let settings = config::load_alerts(&opt.config_dir.join("alerts.json"));
    let mut memory = load_memory(&opt.support_dir.join("alert-memory.json"));
    let mut quotas = Vec::new();
    for row in rows {
        for w in &row.windows {
            if !w.gauged {
                continue;
            }
            quotas.push(QuotaReading {
                provider: row.id.clone(),
                provider_name: row.name.clone(),
                window: w.label.clone(),
                used: w.used_percent,
                resets_at: w.resets_at,
            });
        }
    }
    let mut bills = Vec::new();
    for (id, s) in screens {
        if s.checked_at.is_none() {
            continue;
        }
        bills.push(BillingReading {
            provider: id.clone(),
            provider_name: catalog::display_name(id),
            next_bill: s.next_bill,
            price: s.monthly_price.map(|n| format!("${n}")),
            credits: s
                .credits
                .iter()
                .filter_map(|c| {
                    c.expires.map(|exp| Credit {
                        title: c.title.clone(),
                        amount: c.amount.clone(),
                        expires: exp,
                    })
                })
                .collect(),
        });
    }
    let fired = AlertEngine::evaluate(
        &quotas,
        &bills,
        &settings,
        &mut memory,
        opt.now,
        opt.tz_offset_secs,
    );
    if opt.persist {
        save_memory(&opt.support_dir.join("alert-memory.json"), &memory);
    }
    fired.into_iter().map(|a| a.title).collect()
}

fn footer(
    opt: &HudOptions<'_>,
    ledger: &UsageLedger,
    screens: &HashMap<String, ScreenReading>,
) -> Footer {
    let covered = ledger
        .since
        .map(|t| (opt.now - t) / 86_400.0)
        .unwrap_or(0.0);
    let days = if covered >= 29.5 { 30 } else { 7 };
    let summary = ledger.summary(days, None, opt.prices, opt.now, opt.tz_offset_secs);
    let mut sums: HashMap<String, f64> = HashMap::new();
    for (id, s) in screens {
        if s.checked_at.is_none() || s.monthly_price.is_none() {
            continue;
        }
        if !catalog::counts_toward_monthly(id) {
            continue;
        }
        *sums.entry(s.currency.clone()).or_default() += s.monthly_price.unwrap_or(0.0);
    }
    let monthly = if sums.is_empty() {
        None
    } else {
        devstats::usd(&sums, opt.fx)
    };
    let roi =
        monthly.and_then(|spend| devstats::roi_ratio(summary.cost, spend * days as f64 / 30.0));
    let note = if opt.prices.is_empty() && summary.tokens > 0 {
        "Token counts are local. API-equivalent cost needs the public LiteLLM price table, which is not cached yet.".into()
    } else if sums.is_empty() {
        "Plan prices come from .config/phosphor/billing-screens.json. Nothing is typed in by Phosphor.".into()
    } else if monthly.is_none() {
        "A plan price is in a currency with no FX rate, so ROI is left blank.".into()
    } else {
        "ROI is API list price for local logs, divided by the plan cost for the same days.".into()
    };
    let dev = if opt.show_dev {
        opt.dev_counts.map(|c| {
            let placement = devstats::place_prs(c.prs_per_week());
            let merged = if days == 30 { c.merged_30 } else { c.merged_7 };
            DevStrip {
                login: c.login.clone(),
                merged_today: c.merged_today,
                merged_7: c.merged_7,
                merged_30: c.merged_30,
                commits_7: c.commits_7,
                commits_30: c.commits_30,
                prs_per_week: c.prs_per_week(),
                tier_label: placement.label,
                cost_per_pr: monthly.and_then(|spend| devstats::per_pr(spend, c.merged_30)),
                tokens_per_pr: devstats::per_pr(summary.tokens as f64, merged),
            }
        })
    } else {
        None
    };
    Footer {
        tokens: summary.tokens,
        api_value: summary.cost,
        unpriced: summary.unpriced_tokens,
        days,
        monthly_usd: monthly,
        roi,
        note,
        dev,
    }
}

fn sort_rows(rows: &mut [ProviderRow]) {
    fn rank(status: &str) -> i32 {
        match status {
            "ok" => 0,
            "idle" => 1,
            "error" => 2,
            _ => 3,
        }
    }
    fn index(id: &str) -> usize {
        let base = id.split('@').next().unwrap_or(id);
        catalog::CATALOG
            .iter()
            .position(|m| m.id == base)
            .unwrap_or(999)
    }
    rows.sort_by(|a, b| {
        rank(&a.status)
            .cmp(&rank(&b.status))
            .then(index(&a.id).cmp(&index(&b.id)))
            .then(a.id.cmp(&b.id))
    });
}

fn read_accounts(opt: &HudOptions<'_>) -> Vec<config::Profile> {
    let path = opt.config_dir.join("accounts.json");
    let Ok(data) = fs::read(path) else {
        return Vec::new();
    };
    config::parse_accounts(&data, opt.home).profiles
}

fn read_screens(opt: &HudOptions<'_>) -> HashMap<String, ScreenReading> {
    let path = opt.config_dir.join("billing-screens.json");
    let Ok(data) = fs::read(path) else {
        return HashMap::new();
    };
    config::parse_billing_screens(&data, opt.tz_offset_secs)
}

fn push_profile_sources(
    sources: &mut Vec<LogSource>,
    profiles: &[config::Profile],
    home: &Path,
    env: &HashMap<String, String>,
) {
    let default_claude = paths::claude_config_dirs(home, env);
    let default_codex = paths::codex_homes(home, env);
    for p in profiles {
        if p.provider == "claude" {
            if let Some(dir) = &p.config_dir {
                let dir = PathBuf::from(dir);
                if default_claude.iter().any(|d| d == &dir) {
                    continue;
                }
                sources.push(LogSource {
                    id: p.id(),
                    format: LogFormat::Claude,
                    roots: vec![dir.join("projects")],
                    needles: vec!["\"usage\"".into()],
                    file_suffix: ".jsonl".into(),
                    whole_file: false,
                });
            }
        } else if p.provider == "codex" {
            if let Some(h) = &p.home {
                let h = PathBuf::from(h);
                if default_codex.iter().any(|d| d == &h) {
                    continue;
                }
                sources.push(LogSource {
                    id: p.id(),
                    format: LogFormat::Codex,
                    roots: vec![h.join("sessions")],
                    needles: vec!["\"turn_context\"".into(), "\"token_count\"".into()],
                    file_suffix: ".jsonl".into(),
                    whole_file: false,
                });
            }
        }
    }
}

fn install_evidence(id: &str, home: &Path, env: &HashMap<String, String>) -> Option<String> {
    let bins: &[&str] = match id {
        "cursor" => &["cursor", "cursor-agent"],
        "windsurf" => &["windsurf"],
        "kiro" => &["kiro", "kiro-cli"],
        "zed" => &["zed"],
        "amp" => &["amp"],
        "kimi" => &["kimi"],
        "droid" => &["droid"],
        "opencode" => &["opencode"],
        "aider" => &["aider"],
        "ollama" => &["ollama"],
        "lmstudio" => &["lms"],
        "vertex" => &["gcloud"],
        "jetbrains" => &["idea", "pycharm", "webstorm"],
        _ => &[],
    };
    if let Some(p) = paths::which(bins, env) {
        return Some(format!("bin {}", p.file_name()?.to_string_lossy()));
    }
    let local = env.get("LOCALAPPDATA").map(PathBuf::from);
    let mut paths = Vec::new();
    match id {
        "cursor" => {
            if let Some(l) = &local {
                paths.push(l.join("Programs").join("cursor").join("Cursor.exe"));
            }
        }
        "windsurf" => {
            paths.push(home.join(".codeium").join("windsurf"));
            if let Some(l) = &local {
                paths.push(l.join("Programs").join("Windsurf").join("Windsurf.exe"));
            }
        }
        "ollama" => paths.push(home.join(".ollama")),
        "lmstudio" => paths.push(home.join(".lmstudio")),
        "aider" => paths.push(home.join(".aider.conf.yml")),
        "kiro" => paths.push(home.join(".kiro")),
        "amp" => paths.push(home.join(".config").join("amp")),
        "kimi" => paths.push(home.join(".kimi")),
        "droid" => paths.push(home.join(".factory")),
        "vertex" => paths.push(home.join(".config").join("gcloud")),
        _ => {}
    }
    paths
        .into_iter()
        .find(|p| p.exists())
        .map(|p| format!("{} (unverified)", p.display()))
}

fn env_nonempty(env: &HashMap<String, String>, key: &str) -> bool {
    env.get(key).map(|s| !s.trim().is_empty()).unwrap_or(false)
}

fn load_history(path: &Path, now: f64) -> Vec<Sample> {
    let Ok(data) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let cutoff = now - 8.0 * 3600.0;
    data.lines()
        .filter_map(|l| serde_json::from_str::<Sample>(l).ok())
        .filter(|s| s.t >= cutoff && s.t <= now + 1.0)
        .collect()
}

fn save_history(path: &Path, samples: &[Sample], now: f64) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let cutoff = now - 30.0 * 86_400.0;
    let mut kept: Vec<&Sample> = samples.iter().filter(|s| s.t >= cutoff).collect();
    kept.sort_by(|a, b| a.t.partial_cmp(&b.t).unwrap_or(std::cmp::Ordering::Equal));
    let mut body = String::new();
    for s in kept {
        if let Ok(line) = serde_json::to_string(s) {
            body.push_str(&line);
            body.push('\n');
        }
    }
    let _ = fs::write(path, body);
}

#[derive(Serialize, Deserialize)]
struct MemFile {
    sent: HashMap<String, f64>,
    last: Vec<SavedQuota>,
}

#[derive(Serialize, Deserialize)]
struct SavedQuota {
    provider: String,
    provider_name: String,
    window: String,
    used: f64,
    resets_at: Option<f64>,
}

fn load_memory(path: &Path) -> AlertMemory {
    let Ok(data) = fs::read(path) else {
        return AlertMemory::default();
    };
    let Ok(file) = serde_json::from_slice::<MemFile>(&data) else {
        return AlertMemory::default();
    };
    let mut memory = AlertMemory {
        sent: file.sent,
        last: HashMap::new(),
    };
    for q in file.last {
        let reading = QuotaReading {
            provider: q.provider,
            provider_name: q.provider_name,
            window: q.window,
            used: q.used,
            resets_at: q.resets_at,
        };
        memory.last.insert(reading.key(), reading);
    }
    memory
}

fn save_memory(path: &Path, memory: &AlertMemory) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let file = MemFile {
        sent: memory.sent.clone(),
        last: memory
            .last
            .values()
            .map(|q| SavedQuota {
                provider: q.provider.clone(),
                provider_name: q.provider_name.clone(),
                window: q.window.clone(),
                used: q.used,
                resets_at: q.resets_at,
            })
            .collect(),
    };
    if let Ok(data) = serde_json::to_vec(&file) {
        let _ = fs::write(path, data);
    }
}

fn demo_model(now: f64, tz: i32) -> HudModel {
    let specs = [
        (
            "claude",
            "Max",
            [
                ("5H", 62.0, 6000.0, 18000.0),
                ("7D", 41.0, 300_000.0, 604_800.0),
            ],
        ),
        (
            "codex",
            "Pro",
            [
                ("5H", 18.0, 14_000.0, 18_000.0),
                ("7D", 77.0, 90_000.0, 604_800.0),
            ],
        ),
        (
            "gemini",
            "",
            [("1D", 23.0, 40_000.0, 86_400.0), ("", 0.0, 0.0, 0.0)],
        ),
        (
            "copilot",
            "Pro",
            [
                ("PREMIUM", 54.0, 1_200_000.0, 2_592_000.0),
                ("CHAT", 12.0, 1_200_000.0, 2_592_000.0),
            ],
        ),
        (
            "grok",
            "SuperGrok",
            [("2H", 93.0, 1500.0, 7200.0), ("", 0.0, 0.0, 0.0)],
        ),
    ];
    let mut rows = Vec::new();
    for (id, plan, wins) in specs {
        let mut row = blank(id);
        row.status = "ok".into();
        row.plan = if plan.is_empty() {
            None
        } else {
            Some(plan.into())
        };
        row.confidence = "official".into();
        row.message = Some("Demo data".into());
        for (label, used, reset_in, window) in wins {
            if label.is_empty() {
                continue;
            }
            let resets_at = Some(now + reset_in);
            let mut view = WindowView {
                label: label.into(),
                used_percent: used,
                kind: "quota".into(),
                amount: None,
                active_session: true,
                resets_at,
                window_seconds: Some(window),
                resets_in: Some(timeutil::countdown(now + reset_in, now)),
                forecast_rate: None,
                forecast_text: None,
                warns: false,
                gauged: true,
            };
            let samples = [
                ForecastSample::new(now - 3600.0, (used - 4.0).max(0.0), resets_at),
                ForecastSample::new(now, used, resets_at),
            ];
            let f = QuotaForecast::make(used, resets_at, Some(window), true, &samples, now);
            let (rate, text) = forecast::caption(&f, now, tz);
            view.forecast_rate = rate;
            view.forecast_text = Some(text);
            view.warns = f.warns_before_reset();
            row.windows.push(view);
        }
        rows.push(row);
    }
    rows.push(fixed_row("antigravity"));
    rows.push(fixed_row("muse"));
    rows.push(fixed_row("grokbot"));
    sort_rows(&mut rows);
    HudModel {
        rows,
        alerts: Vec::new(),
        footer: Footer {
            tokens: 1_200_000,
            api_value: 18.4,
            unpriced: 0,
            days: 7,
            monthly_usd: Some(100.0),
            roi: Some(18.4 / (100.0 * 7.0 / 30.0)),
            note: "Demo data. No files were read.".into(),
            dev: None,
        },
        generated_at: now,
        demo: true,
        show_dev: false,
    }
}
