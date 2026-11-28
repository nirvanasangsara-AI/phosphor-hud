//! Pure parsers for the usage JSON each official client already understands.
//! No network calls live here.

use crate::timeutil::{capitalized, epoch_from_value, json_f64};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParsedWindow {
    pub label: String,
    pub used_percent: f64,
    pub resets_at: Option<f64>,
    pub window_seconds: Option<f64>,
    pub active_session: bool,
    pub kind: WindowKind,
    pub left: Option<f64>,
    pub total: Option<f64>,
    pub unit: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WindowKind {
    Quota,
    Balance,
    Meter,
}

impl ParsedWindow {
    pub fn quota(
        label: impl Into<String>,
        used: f64,
        resets_at: Option<f64>,
        window_seconds: Option<f64>,
        active: bool,
    ) -> Self {
        Self {
            label: label.into(),
            used_percent: used,
            resets_at,
            window_seconds,
            active_session: active,
            kind: WindowKind::Quota,
            left: None,
            total: None,
            unit: None,
        }
    }

    pub fn balance(
        label: impl Into<String>,
        left: f64,
        total: Option<f64>,
        unit: impl Into<String>,
        resets_at: Option<f64>,
        window_seconds: Option<f64>,
    ) -> Self {
        let used = total
            .filter(|t| *t > 0.0)
            .map(|t| ((t - left) / t * 100.0).clamp(0.0, 100.0))
            .unwrap_or(0.0);
        Self {
            label: label.into(),
            used_percent: used,
            resets_at,
            window_seconds,
            active_session: true,
            kind: WindowKind::Balance,
            left: Some(left),
            total,
            unit: Some(unit.into()),
        }
    }

    pub fn meter(
        label: impl Into<String>,
        used: f64,
        unit: impl Into<String>,
        resets_at: Option<f64>,
        window_seconds: Option<f64>,
    ) -> Self {
        Self {
            label: label.into(),
            used_percent: 0.0,
            resets_at,
            window_seconds,
            active_session: true,
            kind: WindowKind::Meter,
            left: None,
            total: Some(used),
            unit: Some(unit.into()),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ParsedQuota {
    pub windows: Vec<ParsedWindow>,
    pub plan: Option<String>,
}

pub fn window_label(seconds: Option<f64>) -> String {
    let Some(s) = seconds.filter(|s| *s > 0.0) else {
        return "LIM".into();
    };
    if (s - 18000.0).abs() < 60.0 {
        return "5H".into();
    }
    if (s - 604800.0).abs() < 600.0 {
        return "7D".into();
    }
    if (s - 86400.0).abs() < 600.0 {
        return "1D".into();
    }
    if s >= 86400.0 {
        return format!("{}D", (s / 86400.0).round() as i64);
    }
    if s >= 3600.0 {
        return format!("{}H", (s / 3600.0).round() as i64);
    }
    format!("{}M", (s / 60.0).round() as i64)
}

/// Claude Code `api/oauth/usage` body.
pub fn claude_usage(obj: &Value) -> ParsedQuota {
    let mut out = Vec::new();
    let five = obj.get("five_hour").filter(|v| v.is_object());
    out.push(ParsedWindow::quota(
        "5H",
        five.and_then(|w| w.get("utilization"))
            .and_then(json_f64)
            .unwrap_or(0.0),
        five.and_then(|w| w.get("resets_at"))
            .and_then(epoch_from_value),
        Some(18000.0),
        five.is_some(),
    ));
    if let Some(w) = obj.get("seven_day").filter(|v| v.is_object()) {
        if let Some(u) = w.get("utilization").and_then(json_f64) {
            out.push(ParsedWindow::quota(
                "7D",
                u,
                w.get("resets_at").and_then(epoch_from_value),
                Some(604800.0),
                true,
            ));
        }
    }
    for (key, label) in [
        ("seven_day_opus", "7D OPUS"),
        ("seven_day_sonnet", "7D SONNET"),
        ("seven_day_oauth_apps", "7D APPS"),
        ("seven_day_cowork", "7D COWORK"),
    ] {
        let Some(w) = obj.get(key).filter(|v| v.is_object()) else {
            continue;
        };
        let Some(u) = w.get("utilization").and_then(json_f64) else {
            continue;
        };
        out.push(ParsedWindow::quota(
            label,
            u,
            w.get("resets_at").and_then(epoch_from_value),
            Some(604800.0),
            true,
        ));
    }
    if let Some(limits) = obj.get("limits").and_then(Value::as_array) {
        for l in limits {
            if l.get("kind").and_then(Value::as_str) != Some("weekly_scoped") {
                continue;
            }
            let Some(u) = l.get("percent").and_then(json_f64) else {
                continue;
            };
            let scope = l.get("scope");
            let model = scope
                .and_then(|s| s.get("model"))
                .and_then(|m| m.get("display_name"))
                .and_then(Value::as_str)
                .or_else(|| {
                    scope
                        .and_then(|s| s.get("surface"))
                        .and_then(|m| m.get("display_name"))
                        .and_then(Value::as_str)
                })
                .unwrap_or("scoped");
            let label = format!("7D {}", model.to_uppercase());
            if out.iter().any(|w| w.label == label) {
                continue;
            }
            out.push(ParsedWindow::quota(
                label,
                u,
                l.get("resets_at").and_then(epoch_from_value),
                Some(604800.0),
                true,
            ));
        }
    }
    ParsedQuota {
        windows: out,
        plan: None,
    }
}

/// Codex `chatgpt.com/backend-api/wham/usage` body.
pub fn codex_usage(obj: &Value, now: f64) -> ParsedQuota {
    let rl = obj.get("rate_limit").cloned().unwrap_or(Value::Null);
    let mut windows = Vec::new();
    for key in ["primary_window", "secondary_window"] {
        let Some(w) = rl.get(key).filter(|v| v.is_object()) else {
            continue;
        };
        let Some(u) = w.get("used_percent").and_then(json_f64) else {
            continue;
        };
        let secs = w.get("limit_window_seconds").and_then(json_f64);
        let mut reset = w.get("reset_at").and_then(epoch_from_value);
        if reset.is_none() {
            if let Some(after) = w.get("reset_after_seconds").and_then(json_f64) {
                reset = Some(now + after);
            }
        }
        windows.push(ParsedWindow::quota(
            window_label(secs),
            u,
            reset,
            secs,
            true,
        ));
    }
    if !windows.iter().any(|w| w.label == "5H")
        && (rl
            .get("primary_window")
            .map(Value::is_null)
            .unwrap_or(false)
            || rl
                .get("secondary_window")
                .map(Value::is_null)
                .unwrap_or(false))
    {
        windows.insert(
            0,
            ParsedWindow::quota("5H", 0.0, None, Some(18000.0), false),
        );
    }
    let plan = obj
        .get("plan_type")
        .and_then(Value::as_str)
        .map(capitalized);
    ParsedQuota { windows, plan }
}

/// GitHub Copilot `copilot_internal/user` body.
pub fn copilot_usage(obj: &Value) -> ParsedQuota {
    let snaps = obj.get("quota_snapshots").cloned().unwrap_or(Value::Null);
    let reset = obj
        .get("quota_reset_date_utc")
        .and_then(epoch_from_value)
        .or_else(|| obj.get("quota_reset_date").and_then(epoch_from_value));
    let mut windows = Vec::new();
    for (key, label) in [
        ("premium_interactions", "PREMIUM"),
        ("chat", "CHAT"),
        ("completions", "COMPL"),
    ] {
        let Some(q) = snaps.get(key).filter(|v| v.is_object()) else {
            continue;
        };
        if q.get("unlimited").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(entitled) = q.get("entitlement").and_then(json_f64) else {
            continue;
        };
        if entitled <= 0.0 {
            continue;
        }
        let Some(left) = q.get("percent_remaining").and_then(json_f64) else {
            continue;
        };
        windows.push(ParsedWindow::quota(
            label,
            (100.0 - left).max(0.0),
            reset,
            Some(30.0 * 86400.0),
            true,
        ));
    }
    let plan = if obj
        .get("access_type_sku")
        .and_then(Value::as_str)
        .map(|s| s.starts_with("free"))
        .unwrap_or(false)
    {
        Some("Free".into())
    } else {
        obj.get("copilot_plan").and_then(Value::as_str).map(|s| {
            if s == "individual" {
                "Individual".into()
            } else {
                capitalized(s)
            }
        })
    };
    ParsedQuota { windows, plan }
}

/// Grok CLI billing body (`format=credits`).
pub fn grok_usage(obj: &Value, now: f64) -> ParsedQuota {
    let cfg = obj.get("config").filter(|v| v.is_object()).unwrap_or(obj);
    let mut used = cfg.get("creditUsagePercent").and_then(json_f64);
    if used.is_none() {
        let u = cfg
            .get("onDemandUsed")
            .and_then(|v| v.get("val"))
            .and_then(json_f64);
        let cap = cfg
            .get("onDemandCap")
            .and_then(|v| v.get("val"))
            .and_then(json_f64);
        if let (Some(u), Some(cap)) = (u, cap) {
            if cap > 0.0 {
                used = Some(u / cap * 100.0);
            }
        }
    }
    let period = cfg.get("currentPeriod");
    let end = period
        .and_then(|p| p.get("end"))
        .and_then(epoch_from_value)
        .or_else(|| cfg.get("billingPeriodEnd").and_then(epoch_from_value));
    let start = period
        .and_then(|p| p.get("start"))
        .and_then(epoch_from_value)
        .or_else(|| cfg.get("billingPeriodStart").and_then(epoch_from_value));
    if used.is_none() {
        if let (Some(start), Some(end)) = (start, end) {
            if start <= now && now < end {
                used = Some(0.0);
            }
        }
    }
    let Some(used) = used else {
        return ParsedQuota {
            windows: Vec::new(),
            plan: None,
        };
    };
    let secs = match (start, end) {
        (Some(s), Some(e)) => Some(e - s),
        _ => None,
    };
    let plan = obj
        .get("subscription_tier")
        .and_then(Value::as_str)
        .or_else(|| cfg.get("subscriptionTier").and_then(Value::as_str))
        .map(capitalized);
    ParsedQuota {
        windows: vec![ParsedWindow::quota(
            window_label(secs),
            used,
            end,
            secs,
            true,
        )],
        plan,
    }
}

/// `agy -p /usage --output-format json`. Parsed so the shape stays tested.
/// The Windows HUD does not run `agy`; the row stays unavailable.
pub fn antigravity_usage(obj: &Value) -> Result<ParsedQuota, String> {
    if obj.get("status").and_then(Value::as_str) != Some("SUCCESS") {
        let why = obj
            .get("response")
            .and_then(Value::as_str)
            .unwrap_or("no usage report");
        return Err(format!("Antigravity: {why}"));
    }
    let groups = obj
        .pointer("/command/data/groups")
        .and_then(Value::as_array)
        .ok_or_else(|| "no usage report".to_string())?;
    let mut windows = Vec::new();
    for (gi, group) in groups.iter().enumerate() {
        let name = group
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_lowercase();
        let suffix = if gi == 0 || name.contains("gemini") {
            "".to_string()
        } else if name.contains("claude") || name.contains("gpt") {
            " CL·GPT".to_string()
        } else {
            format!(" {}", gi + 1)
        };
        let mut buckets = group
            .get("buckets")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        buckets.sort_by_key(|b| {
            if b.get("window").and_then(Value::as_str) == Some("5h") {
                0
            } else {
                1
            }
        });
        for bucket in buckets {
            let Some(left) = bucket.get("remaining_fraction").and_then(json_f64) else {
                continue;
            };
            let w = bucket.get("window").and_then(Value::as_str).unwrap_or("");
            let (label, secs) = if w == "5h" {
                ("5H".to_string(), Some(18000.0))
            } else if w == "weekly" {
                ("7D".to_string(), Some(604800.0))
            } else {
                (w.to_uppercase(), None)
            };
            let mut reset = bucket.get("reset_time").and_then(epoch_from_value);
            if reset.is_some_and(|r| r < 86400.0) {
                reset = None;
            }
            windows.push(ParsedWindow::quota(
                format!("{label}{suffix}"),
                ((1.0 - left) * 100.0).clamp(0.0, 100.0),
                reset,
                secs,
                true,
            ));
        }
    }
    if windows.is_empty() {
        return Err("no Antigravity quota on this account".into());
    }
    Ok(ParsedQuota {
        windows,
        plan: None,
    })
}

/// `muse usage --json`. Parsed for compatibility; Windows does not shell out to Muse.
pub fn muse_usage(obj: &Value) -> Result<ParsedQuota, String> {
    let Some(allowance) = obj.get("allowance").filter(|v| v.is_object()) else {
        let extra = muse_balance_or_meter(obj);
        if !extra.is_empty() {
            return Ok(ParsedQuota {
                windows: extra,
                plan: None,
            });
        }
        let reason = obj
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("no allowance");
        return Err(reason.replace('_', " "));
    };
    let mut windows = Vec::new();
    for (key, label, secs) in [("window", "5H", 18000.0), ("weekly", "7D", 604800.0)] {
        let w = allowance.get(key).filter(|v| v.is_object());
        let u = w
            .and_then(|w| w.get("usedPercent"))
            .and_then(json_f64)
            .or_else(|| if key == "window" { Some(0.0) } else { None });
        let Some(u) = u else { continue };
        let reset = w
            .and_then(|w| w.get("resetsAtMs"))
            .and_then(json_f64)
            .map(|ms| ms / 1000.0);
        windows.push(ParsedWindow::quota(label, u, reset, Some(secs), true));
    }
    windows.extend(muse_balance_or_meter(obj));
    let plan = allowance
        .get("tier")
        .and_then(Value::as_str)
        .map(|t| t.replace("Muse Code ", "").replace(" Usage", ""));
    Ok(ParsedQuota { windows, plan })
}

fn muse_balance_or_meter(obj: &Value) -> Vec<ParsedWindow> {
    if let Some(b) = obj.get("balance").filter(|v| v.is_object()) {
        if let Some(left) = b
            .get("remaining")
            .and_then(json_f64)
            .or_else(|| b.get("left").and_then(json_f64))
            .or_else(|| b.get("balance").and_then(json_f64))
        {
            return vec![ParsedWindow::balance(
                "BAL",
                left,
                b.get("total")
                    .and_then(json_f64)
                    .or_else(|| b.get("limit").and_then(json_f64)),
                b.get("unit").and_then(Value::as_str).unwrap_or("credits"),
                b.get("resetsAt")
                    .and_then(epoch_from_value)
                    .or_else(|| b.get("resetsAtMs").and_then(epoch_from_value)),
                None,
            )];
        }
    }
    if let Some(u) = obj.get("usage").filter(|v| v.is_object()) {
        if let Some(used) = u
            .get("tokens")
            .and_then(json_f64)
            .or_else(|| u.get("used").and_then(json_f64))
        {
            let secs = u
                .get("windowSeconds")
                .and_then(json_f64)
                .unwrap_or(604800.0);
            return vec![ParsedWindow::meter(
                window_label(Some(secs)),
                used,
                u.get("unit").and_then(Value::as_str).unwrap_or("tokens"),
                u.get("resetsAt")
                    .and_then(epoch_from_value)
                    .or_else(|| u.get("resetsAtMs").and_then(epoch_from_value)),
                Some(secs),
            )];
        }
    }
    Vec::new()
}

/// One window from `providers.json` command output.
pub fn custom_windows(obj: &Value) -> Result<ParsedQuota, String> {
    let list = obj
        .get("windows")
        .and_then(Value::as_array)
        .ok_or("no windows")?;
    let mut windows = Vec::new();
    for w in list {
        let secs = w.get("windowSeconds").and_then(json_f64);
        let label = w
            .get("label")
            .and_then(Value::as_str)
            .map(|s| s.to_string())
            .unwrap_or_else(|| window_label(secs));
        let reset = w.get("resetsAt").and_then(epoch_from_value);
        let unit = w.get("unit").and_then(Value::as_str).unwrap_or("");
        let kind = w.get("kind").and_then(Value::as_str).unwrap_or("quota");
        let parsed = match kind {
            "balance" => {
                let left = w
                    .get("left")
                    .and_then(json_f64)
                    .ok_or("balance needs left")?;
                ParsedWindow::balance(
                    label,
                    left,
                    w.get("total").and_then(json_f64),
                    unit,
                    reset,
                    secs,
                )
            }
            "meter" => {
                let used = w.get("used").and_then(json_f64).ok_or("meter needs used")?;
                ParsedWindow::meter(label, used, unit, reset, secs)
            }
            _ => {
                let u = w.get("used").and_then(json_f64).ok_or("quota needs used")?;
                ParsedWindow::quota(label, u, reset, secs, true)
            }
        };
        windows.push(parsed);
    }
    if windows.is_empty() {
        return Err("no windows".into());
    }
    Ok(ParsedQuota {
        windows,
        plan: obj
            .get("plan")
            .and_then(Value::as_str)
            .map(|s| s.to_string()),
    })
}
