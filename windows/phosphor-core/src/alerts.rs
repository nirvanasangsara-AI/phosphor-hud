//! Alert thresholds. Ported from `Sources/PhosphorCore/Alerts.swift`.

use crate::timeutil::{countdown, day_key, relative_day};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AlertSettings {
    pub warn_enabled: bool,
    pub warn_at: f64,
    pub critical_enabled: bool,
    pub critical_at: f64,
    pub reset_enabled: bool,
    pub reset_from: f64,
    pub bill_enabled: bool,
    pub bill_days_before: i64,
    pub credit_enabled: bool,
    pub credit_days_before: i64,
}

impl Default for AlertSettings {
    fn default() -> Self {
        Self {
            warn_enabled: true,
            warn_at: 70.0,
            critical_enabled: true,
            critical_at: 90.0,
            reset_enabled: true,
            reset_from: 50.0,
            bill_enabled: true,
            bill_days_before: 1,
            credit_enabled: true,
            credit_days_before: 3,
        }
    }
}

impl AlertSettings {
    /// Missing keys keep their defaults, matching `AlertSettings.decode`.
    pub fn decode(data: &[u8]) -> Self {
        let Ok(v) = serde_json::from_slice::<Value>(data) else {
            return Self::default();
        };
        let Some(o) = v.as_object() else {
            return Self::default();
        };
        let mut s = Self::default();
        if let Some(x) = o.get("warnEnabled").and_then(Value::as_bool) {
            s.warn_enabled = x;
        }
        if let Some(x) = o.get("warnAt").and_then(json_num) {
            s.warn_at = x;
        }
        if let Some(x) = o.get("criticalEnabled").and_then(Value::as_bool) {
            s.critical_enabled = x;
        }
        if let Some(x) = o.get("criticalAt").and_then(json_num) {
            s.critical_at = x;
        }
        if let Some(x) = o.get("resetEnabled").and_then(Value::as_bool) {
            s.reset_enabled = x;
        }
        if let Some(x) = o.get("resetFrom").and_then(json_num) {
            s.reset_from = x;
        }
        if let Some(x) = o.get("billEnabled").and_then(Value::as_bool) {
            s.bill_enabled = x;
        }
        if let Some(x) = o.get("billDaysBefore").and_then(json_num) {
            s.bill_days_before = x as i64;
        }
        if let Some(x) = o.get("creditEnabled").and_then(Value::as_bool) {
            s.credit_enabled = x;
        }
        if let Some(x) = o.get("creditDaysBefore").and_then(json_num) {
            s.credit_days_before = x as i64;
        }
        s
    }
}

fn json_num(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct QuotaReading {
    pub provider: String,
    pub provider_name: String,
    pub window: String,
    pub used: f64,
    pub resets_at: Option<f64>,
}

impl QuotaReading {
    pub fn key(&self) -> String {
        format!("{}.{}", self.provider, self.window)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Credit {
    pub title: String,
    pub amount: Option<String>,
    pub expires: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct BillingReading {
    pub provider: String,
    pub provider_name: String,
    pub next_bill: Option<f64>,
    pub price: Option<String>,
    pub credits: Vec<Credit>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AlertKind {
    Warning,
    Critical,
    Reset,
    Bill,
    CreditExpiry,
}

impl AlertKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Warning => "warning",
            Self::Critical => "critical",
            Self::Reset => "reset",
            Self::Bill => "bill",
            Self::CreditExpiry => "creditExpiry",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct UsageAlert {
    pub kind: AlertKind,
    pub key: String,
    pub title: String,
    pub body: String,
}

#[derive(Clone, Debug, Default)]
pub struct AlertMemory {
    pub sent: HashMap<String, f64>,
    pub last: HashMap<String, QuotaReading>,
}

pub struct AlertEngine;

impl AlertEngine {
    fn bucket(d: Option<f64>) -> String {
        d.map(|t| format!("{}", (t / 3600.0) as i64))
            .unwrap_or_else(|| "x".into())
    }

    pub fn evaluate(
        quotas: &[QuotaReading],
        bills: &[BillingReading],
        settings: &AlertSettings,
        memory: &mut AlertMemory,
        now: f64,
        tz_offset_secs: i32,
    ) -> Vec<UsageAlert> {
        let mut out = Vec::new();
        let mut fire = |a: UsageAlert, memory: &mut AlertMemory| {
            if memory.sent.contains_key(&a.key) {
                return;
            }
            memory.sent.insert(a.key.clone(), now);
            out.push(a);
        };

        for q in quotas {
            let prev = memory.last.get(&q.key()).cloned();
            let cycle = Self::bucket(q.resets_at);
            let reset_in = q
                .resets_at
                .map(|t| format!(" Resets in {}.", countdown(t, now)))
                .unwrap_or_default();
            if settings.critical_enabled && q.used >= settings.critical_at {
                fire(
                    UsageAlert {
                        kind: AlertKind::Critical,
                        key: format!("crit.{}.{}", q.key(), cycle),
                        title: format!("{} {} at {}%", q.provider_name, q.window, q.used as i64),
                        body: format!("Critical (≥{}%).{reset_in}", settings.critical_at as i64),
                    },
                    memory,
                );
                memory
                    .sent
                    .entry(format!("warn.{}.{}", q.key(), cycle))
                    .or_insert(now);
            } else if settings.warn_enabled && q.used >= settings.warn_at {
                fire(
                    UsageAlert {
                        kind: AlertKind::Warning,
                        key: format!("warn.{}.{}", q.key(), cycle),
                        title: format!("{} {} at {}%", q.provider_name, q.window, q.used as i64),
                        body: format!("Passed {}%.{reset_in}", settings.warn_at as i64),
                    },
                    memory,
                );
            }
            if settings.reset_enabled {
                if let Some(p) = prev {
                    if p.used >= settings.reset_from && q.used < p.used {
                        let passed_reset = p.resets_at.map(|t| now >= t).unwrap_or(false);
                        let big_drop = p.used - q.used >= 40.0 && q.used <= 10.0;
                        if passed_reset || big_drop {
                            fire(
                                UsageAlert {
                                    kind: AlertKind::Reset,
                                    key: format!(
                                        "reset.{}.{}.{}",
                                        q.key(),
                                        Self::bucket(p.resets_at),
                                        p.used as i64
                                    ),
                                    title: format!("{} {} reset", q.provider_name, q.window),
                                    body: format!(
                                        "Back to {}% used (was {}%).",
                                        q.used as i64, p.used as i64
                                    ),
                                },
                                memory,
                            );
                        }
                    }
                }
            }
            memory.last.insert(q.key(), q.clone());
        }

        for b in bills {
            if settings.bill_enabled {
                if let Some(bill) = b.next_bill {
                    let left = bill - now;
                    if left > 0.0 && left <= settings.bill_days_before as f64 * 86_400.0 {
                        fire(
                            UsageAlert {
                                kind: AlertKind::Bill,
                                key: format!(
                                    "bill.{}.{}",
                                    b.provider,
                                    day_key(bill, tz_offset_secs)
                                ),
                                title: format!(
                                    "{} bills {}",
                                    b.provider_name,
                                    relative_day(bill, now, tz_offset_secs)
                                ),
                                body: b
                                    .price
                                    .as_ref()
                                    .map(|p| format!("Renews at {p}."))
                                    .unwrap_or_else(|| "Subscription renews.".into()),
                            },
                            memory,
                        );
                    }
                }
            }
            if !settings.credit_enabled {
                continue;
            }
            for c in &b.credits {
                let left = c.expires - now;
                if left > 0.0 && left <= settings.credit_days_before as f64 * 86_400.0 {
                    let amount = c
                        .amount
                        .as_ref()
                        .map(|a| format!(" {a}"))
                        .unwrap_or_default();
                    fire(
                        UsageAlert {
                            kind: AlertKind::CreditExpiry,
                            key: format!(
                                "credit.{}.{}.{}",
                                b.provider,
                                c.title,
                                day_key(c.expires, tz_offset_secs)
                            ),
                            title: format!(
                                "{}: {}{amount} expires {}",
                                b.provider_name,
                                c.title,
                                relative_day(c.expires, now, tz_offset_secs)
                            ),
                            body: format!("Use it before {} runs out.", countdown(c.expires, now)),
                        },
                        memory,
                    );
                }
            }
        }

        let horizon = now - 40.0 * 86_400.0;
        memory.sent.retain(|_, t| *t >= horizon);
        out
    }
}

/// Why a billing-screen reading should be dimmed. Ported from `Staleness`.
#[derive(Clone, Debug, PartialEq)]
pub enum StaleReason {
    BillDatePassed(f64),
    Old { days: i64 },
    UnknownAge,
}

pub fn staleness(
    next_bill: Option<f64>,
    checked_at: Option<f64>,
    now: f64,
    max_age_days: i64,
) -> Vec<StaleReason> {
    let mut out = Vec::new();
    if let Some(bill) = next_bill {
        if bill < now {
            out.push(StaleReason::BillDatePassed(bill));
        }
    }
    if let Some(checked) = checked_at {
        let days = ((now - checked) / 86_400.0) as i64;
        if days > max_age_days {
            out.push(StaleReason::Old { days });
        }
    } else {
        out.push(StaleReason::UnknownAge);
    }
    out
}
