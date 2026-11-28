//! OAuth token helpers that do not touch the network.
//! Ported from `Sources/PhosphorCore/TokenRefresh.swift`.
//!
//! The Windows HUD does not refresh Codex or Grok tokens: writing `auth.json`
//! back would rotate a login the CLI owns, and a Credential Manager login has
//! no file to update. These functions stay so the JSON merge rules match macOS
//! when a refresh is added later.

use crate::timeutil::{json_f64, parse_iso};
use base64::engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

pub const CODEX_TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
pub const CODEX_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const GROK_TOKEN_URL: &str = "https://auth.x.ai/oauth2/token";
pub const DEFAULT_LEEWAY: f64 = 5.0 * 60.0;
pub const PERMANENT_HOLD: f64 = 6.0 * 3600.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RefreshKind {
    Success,
    Transient,
    Permanent,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Cooldown {
    pub last_attempt: Option<f64>,
    pub consecutive_failures: i64,
    pub permanent_until: Option<f64>,
}

impl Default for Cooldown {
    fn default() -> Self {
        Self {
            last_attempt: None,
            consecutive_failures: 0,
            permanent_until: None,
        }
    }
}

impl Cooldown {
    pub fn delay_after(failures: i64) -> f64 {
        const TABLE: [f64; 5] = [0.0, 60.0, 300.0, 900.0, 3600.0];
        let i = failures.clamp(0, TABLE.len() as i64 - 1) as usize;
        TABLE[i]
    }

    pub fn can_attempt(&self, now: f64) -> bool {
        if let Some(until) = self.permanent_until {
            if now < until {
                return false;
            }
        }
        let Some(last) = self.last_attempt else {
            return true;
        };
        now >= last + Self::delay_after(self.consecutive_failures)
    }

    pub fn record_success(&mut self, now: f64) {
        self.last_attempt = Some(now);
        self.consecutive_failures = 0;
        self.permanent_until = None;
    }

    pub fn record_transient(&mut self, now: f64) {
        self.last_attempt = Some(now);
        self.consecutive_failures += 1;
    }

    pub fn record_permanent(&mut self, now: f64, hold: f64) {
        self.last_attempt = Some(now);
        self.consecutive_failures += 1;
        self.permanent_until = Some(now + hold);
    }
}

pub fn classify(status: i32, body: &str) -> RefreshKind {
    if (200..300).contains(&status) {
        return RefreshKind::Success;
    }
    let lower = body.to_lowercase();
    let revoked = lower.contains("invalid_grant")
        || lower.contains("refresh_token_expired")
        || lower.contains("refresh_token_reused")
        || lower.contains("refresh_token_invalidated");
    if status == 401 || status == 403 {
        return RefreshKind::Permanent;
    }
    if status == 400 && revoked {
        return RefreshKind::Permanent;
    }
    if revoked {
        return RefreshKind::Permanent;
    }
    RefreshKind::Transient
}

pub fn jwt_expiry(jwt: &str) -> Option<f64> {
    let mut parts = jwt.split('.');
    let _header = parts.next()?;
    let mid = parts.next()?;
    if parts.next().is_none() && jwt.split('.').count() < 2 {
        return None;
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(mid)
        .or_else(|_| URL_SAFE.decode(mid))
        .ok()?;
    let obj: Value = serde_json::from_slice(&bytes).ok()?;
    let exp = obj.get("exp")?;
    let n = json_f64(exp).or_else(|| exp.as_str().and_then(|s| s.parse().ok()))?;
    Some(n)
}

pub fn needs_refresh(expiry: Option<f64>, now: f64, leeway: f64) -> bool {
    match expiry {
        None => false,
        Some(exp) => exp - now <= leeway,
    }
}

pub fn applying_codex_refresh(auth: &Value, response: &Value, now: f64) -> Option<Value> {
    let access = response.get("access_token")?.as_str()?;
    if access.is_empty() {
        return None;
    }
    let mut auth = auth.as_object()?.clone();
    let mut tokens = auth
        .get("tokens")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(Map::new);
    tokens.insert("access_token".into(), json!(access));
    if let Some(id) = response.get("id_token").and_then(Value::as_str) {
        if !id.is_empty() {
            tokens.insert("id_token".into(), json!(id));
        }
    }
    if let Some(refresh) = response.get("refresh_token").and_then(Value::as_str) {
        if !refresh.is_empty() {
            tokens.insert("refresh_token".into(), json!(refresh));
        }
    }
    auth.insert("tokens".into(), Value::Object(tokens));
    auth.insert("last_refresh".into(), json!(iso(now, false)));
    Some(Value::Object(auth))
}

pub fn grok_entry(auth: &Value) -> Option<(String, Map<String, Value>)> {
    let obj = auth.as_object()?;
    for (k, v) in obj {
        let Some(entry) = v.as_object() else { continue };
        let Some(token) = entry.get("key").and_then(Value::as_str) else {
            continue;
        };
        if token.is_empty() {
            continue;
        }
        return Some((k.clone(), entry.clone()));
    }
    None
}

pub fn grok_client_id(entry_key: &str, entry: &Map<String, Value>) -> Option<String> {
    if let Some(id) = entry.get("oidc_client_id").and_then(Value::as_str) {
        if !id.is_empty() {
            return Some(id.to_string());
        }
    }
    if let Some(i) = entry_key.find("::") {
        let id = entry_key[i + 2..].trim();
        if !id.is_empty() {
            return Some(id.to_string());
        }
    }
    None
}

pub fn codex_access_expiry(auth: &Value) -> Option<f64> {
    let token = auth.get("tokens")?.get("access_token")?.as_str()?;
    jwt_expiry(token)
}

pub fn grok_expiry(entry: &Map<String, Value>) -> Option<f64> {
    if let Some(s) = entry.get("expires_at").and_then(Value::as_str) {
        if let Some(t) = parse_iso(s) {
            return Some(t);
        }
    }
    entry
        .get("key")
        .and_then(Value::as_str)
        .and_then(jwt_expiry)
}

pub fn iso(epoch: f64, fractional: bool) -> String {
    let secs = epoch as i64;
    let nanos = ((epoch - secs as f64) * 1e9).max(0.0) as u32;
    let dt = chrono::DateTime::from_timestamp(secs, nanos)
        .unwrap_or_else(|| chrono::DateTime::from_timestamp(0, 0).unwrap());
    if fractional {
        dt.format("%Y-%m-%dT%H:%M:%S%.fZ").to_string()
    } else {
        dt.format("%Y-%m-%dT%H:%M:%SZ").to_string()
    }
}

pub fn claude_keychain_service(config_dir: &str) -> String {
    let hex = Sha256::digest(config_dir.as_bytes());
    let hex: String = hex.iter().map(|b| format!("{b:02x}")).collect();
    format!("Claude Code-credentials-{}", &hex[..8])
}

/// A JWT whose payload is `{"exp": exp}` and whose header is `{"alg":"none"}`.
pub fn fake_jwt(exp: i64) -> String {
    fn b64(v: &Value) -> String {
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(v).unwrap())
    }
    format!(
        "{}.{}.sig",
        b64(&json!({"alg": "none", "typ": "JWT"})),
        b64(&json!({"exp": exp}))
    )
}
