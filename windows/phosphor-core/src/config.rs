//! `providers.json`, `accounts.json`, `billing-screens.json`, and `alerts.json`.
//! Field names match the macOS files so a copy of `~/.config/phosphor` still loads.

use crate::alerts::AlertSettings;
use crate::paths::expand_tilde;
use crate::timeutil::{json_f64, parse_date_flexible, parse_iso};
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;

#[derive(Clone, Debug, PartialEq)]
pub struct Profile {
    pub provider: String,
    pub name: String,
    pub home: Option<String>,
    pub config_dir: Option<String>,
    pub keychain_service: Option<String>,
}

impl Profile {
    pub fn id(&self) -> String {
        format!("{}@{}", self.provider, slug(&self.name))
    }
}

pub fn slug(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c
            } else {
                '-'
            }
        })
        .collect()
}

#[derive(Clone, Debug, Default)]
pub struct ProfilesParse {
    pub profiles: Vec<Profile>,
    pub problems: Vec<String>,
}

pub fn parse_accounts(data: &[u8], home: &Path) -> ProfilesParse {
    let Ok(v) = serde_json::from_slice::<Value>(data) else {
        return ProfilesParse {
            profiles: Vec::new(),
            problems: vec!["accounts.json is not a JSON object".into()],
        };
    };
    let Some(o) = v.as_object() else {
        return ProfilesParse {
            profiles: Vec::new(),
            problems: vec!["accounts.json is not a JSON object".into()],
        };
    };
    let mut out = ProfilesParse::default();
    let mut ids = std::collections::HashSet::new();
    let list = o
        .get("profiles")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for (n, raw) in list.iter().enumerate() {
        let provider = raw
            .get("provider")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_lowercase();
        let name = raw.get("name").and_then(Value::as_str).unwrap_or("");
        if provider.is_empty() || name.is_empty() {
            out.problems
                .push(format!("profile {}: needs provider and name", n + 1));
            continue;
        }
        if provider != "claude" && provider != "codex" {
            out.problems.push(format!(
                "profile {}: {provider} has no multi-account support yet",
                n + 1
            ));
            continue;
        }
        let home_p = raw
            .get("home")
            .and_then(Value::as_str)
            .map(|p| expand_tilde(p, home).to_string_lossy().to_string());
        let config_dir = raw
            .get("configDir")
            .and_then(Value::as_str)
            .map(|p| expand_tilde(p, home).to_string_lossy().to_string());
        let keychain = raw
            .get("keychainService")
            .and_then(Value::as_str)
            .map(|s| s.to_string());
        let p = Profile {
            provider: provider.clone(),
            name: name.to_string(),
            home: home_p,
            config_dir,
            keychain_service: keychain,
        };
        if provider == "codex" && p.home.is_none() {
            out.problems
                .push(format!("{}: set \"home\" (its CODEX_HOME)", p.id()));
            continue;
        }
        if provider == "claude" && p.config_dir.is_none() && p.keychain_service.is_none() {
            out.problems.push(format!(
                "{}: set \"configDir\" or \"keychainService\"",
                p.id()
            ));
            continue;
        }
        if !ids.insert(p.id()) {
            out.problems.push(format!("{}: duplicate", p.id()));
            continue;
        }
        out.profiles.push(p);
    }
    out
}

#[derive(Clone, Debug, Deserialize)]
pub struct CustomProvider {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
    pub command: String,
}

pub fn parse_providers(data: &[u8]) -> Vec<CustomProvider> {
    let Ok(list) = serde_json::from_slice::<Vec<Value>>(data) else {
        return Vec::new();
    };
    list.into_iter()
        .filter_map(|v| {
            let id = v.get("id")?.as_str()?.to_string();
            let command = v.get("command")?.as_str()?.to_string();
            if id.is_empty() || command.is_empty() {
                return None;
            }
            Some(CustomProvider {
                id,
                name: v.get("name").and_then(Value::as_str).map(|s| s.to_string()),
                color: v
                    .get("color")
                    .and_then(Value::as_str)
                    .map(|s| s.to_string()),
                command,
            })
        })
        .collect()
}

#[derive(Clone, Debug)]
pub struct ScreenCredit {
    pub title: String,
    pub amount: Option<String>,
    pub expires: Option<f64>,
}

#[derive(Clone, Debug)]
pub struct ScreenReading {
    pub provider: String,
    pub checked_at: Option<f64>,
    pub source: Option<String>,
    pub plan: Option<String>,
    pub monthly_price: Option<f64>,
    pub currency: String,
    pub next_bill: Option<f64>,
    pub credits: Vec<ScreenCredit>,
    pub override_fields: Vec<String>,
}

pub fn parse_billing_screens(data: &[u8], tz_offset_secs: i32) -> HashMap<String, ScreenReading> {
    let Ok(root) = serde_json::from_slice::<Value>(data) else {
        return HashMap::new();
    };
    let Some(obj) = root.as_object() else {
        return HashMap::new();
    };
    let mut out = HashMap::new();
    for (id, v) in obj {
        let Some(o) = v.as_object() else { continue };
        let checked_at = o
            .get("checkedAt")
            .and_then(|v| parse_date_flexible(v, tz_offset_secs))
            .or_else(|| {
                o.get("checkedAt")
                    .and_then(Value::as_str)
                    .and_then(parse_iso)
            });
        let credits = o
            .get("credits")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|c| {
                        let title = c.get("title")?.as_str()?.to_string();
                        Some(ScreenCredit {
                            title,
                            amount: c
                                .get("amount")
                                .and_then(Value::as_str)
                                .map(|s| s.to_string()),
                            expires: c
                                .get("expires")
                                .and_then(|v| parse_date_flexible(v, tz_offset_secs)),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        out.insert(
            id.clone(),
            ScreenReading {
                provider: id.clone(),
                checked_at,
                source: o
                    .get("source")
                    .and_then(Value::as_str)
                    .map(|s| s.to_string()),
                plan: o
                    .get("plan")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string()),
                monthly_price: o.get("monthlyPrice").and_then(json_f64),
                currency: o
                    .get("currency")
                    .and_then(Value::as_str)
                    .unwrap_or("USD")
                    .to_uppercase(),
                next_bill: o
                    .get("nextBill")
                    .and_then(|v| parse_date_flexible(v, tz_offset_secs)),
                credits,
                override_fields: o
                    .get("override")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(|v| v.as_str().map(|s| s.to_string()))
                            .collect()
                    })
                    .unwrap_or_default(),
            },
        );
    }
    out
}

pub fn load_alerts(path: &Path) -> AlertSettings {
    match std::fs::read(path) {
        Ok(data) => AlertSettings::decode(&data),
        Err(_) => AlertSettings::default(),
    }
}

pub fn read_json(path: &Path) -> Option<Value> {
    let data = std::fs::read(path).ok()?;
    serde_json::from_slice(&data).ok()
}
