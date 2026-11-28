//! Instants are Unix seconds, the same unit as PhosphorCore's `TimeInterval`.

use chrono::TimeZone;
use serde_json::Value;

pub fn parse_iso(s: &str) -> Option<f64> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    if let Ok(n) = s.parse::<f64>() {
        return Some(normalize_epoch(n));
    }
    if let Some(t) = parse_rfc3339(s) {
        return Some(t);
    }
    // Microsecond fractions trip a strict parser. Keep milliseconds, then try
    // the timestamp with the fraction removed (same fallback as the Swift code).
    if let Some((start, end)) = frac_span(s) {
        let digits = &s[start + 1..end];
        let mut millis = String::new();
        millis.push_str(&s[..start]);
        millis.push('.');
        millis.push_str(&digits[..digits.len().min(3)]);
        millis.push_str(&s[end..]);
        if let Some(t) = parse_rfc3339(&millis) {
            return Some(t);
        }
        let mut plain = String::new();
        plain.push_str(&s[..start]);
        plain.push_str(&s[end..]);
        if let Some(t) = parse_rfc3339(&plain) {
            return Some(t);
        }
    }
    None
}

fn parse_rfc3339(s: &str) -> Option<f64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|d| d.timestamp() as f64 + f64::from(d.timestamp_subsec_nanos()) / 1e9)
}

fn frac_span(s: &str) -> Option<(usize, usize)> {
    let bytes = s.as_bytes();
    let dot = bytes.iter().position(|b| *b == b'.')?;
    let mut end = dot + 1;
    while end < bytes.len() && bytes[end].is_ascii_digit() {
        end += 1;
    }
    if end == dot + 1 {
        return None;
    }
    Some((dot, end))
}

pub fn normalize_epoch(n: f64) -> f64 {
    if n > 10_000_000_000.0 {
        n / 1000.0
    } else {
        n
    }
}

pub fn json_f64(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

pub fn json_i64(v: &Value) -> i64 {
    json_f64(v).map(|n| n as i64).unwrap_or(0)
}

pub fn epoch_from_value(v: &Value) -> Option<f64> {
    match v {
        Value::String(s) => parse_iso(s),
        Value::Number(n) => n.as_f64().filter(|x| *x > 0.0).map(normalize_epoch),
        _ => None,
    }
}

/// A date-time, or a plain `yyyy-mm-dd` at midnight in `offset_secs` (east of UTC).
pub fn parse_date_flexible(v: &Value, offset_secs: i32) -> Option<f64> {
    if let Value::String(s) = v {
        if s.len() == 10 && s.as_bytes().get(4) == Some(&b'-') && s.as_bytes().get(7) == Some(&b'-')
        {
            let y: i32 = s[0..4].parse().ok()?;
            let m: u32 = s[5..7].parse().ok()?;
            let d: u32 = s[8..10].parse().ok()?;
            let naive = chrono::NaiveDate::from_ymd_opt(y, m, d)?.and_hms_opt(0, 0, 0)?;
            return Some(naive.and_utc().timestamp() as f64 - f64::from(offset_secs));
        }
    }
    epoch_from_value(v)
}

pub fn day_number(epoch: f64, offset_secs: i32) -> i64 {
    (epoch as i64)
        .saturating_add(i64::from(offset_secs))
        .div_euclid(86_400)
}

pub fn day_key(epoch: f64, offset_secs: i32) -> String {
    let midnight = day_number(epoch, offset_secs) * 86_400;
    chrono::DateTime::from_timestamp(midnight, 0)
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| "0000-00-00".into())
}

pub fn day_diff(from: f64, to: f64, offset_secs: i32) -> i32 {
    (day_number(to, offset_secs) - day_number(from, offset_secs)) as i32
}

pub fn countdown(target: f64, now: f64) -> String {
    let s = (target - now).max(0.0) as i64;
    let days = s / 86_400;
    let h = (s % 86_400) / 3600;
    let m = (s % 3600) / 60;
    if days > 0 {
        format!("{days}d {h}h")
    } else if h > 0 {
        format!("{h}h {m}m")
    } else {
        format!("{m}m")
    }
}

pub fn relative_day(target: f64, now: f64, offset_secs: i32) -> String {
    match day_diff(now, target, offset_secs) {
        0 => "today".into(),
        1 => "tomorrow".into(),
        d => format!("in {d} days"),
    }
}

pub fn clock(epoch: f64, now: f64, offset_secs: i32) -> String {
    let local = (epoch as i64).saturating_add(i64::from(offset_secs));
    let sod = local.rem_euclid(86_400);
    let hh = sod / 3600;
    let mm = (sod % 3600) / 60;
    if day_number(epoch, offset_secs) == day_number(now, offset_secs) {
        format!("{hh:02}:{mm:02}")
    } else {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        // Unix day 0 (1970-01-01) is a Thursday, index 4 if Sunday is 0.
        let idx = (day_number(epoch, offset_secs) + 4).rem_euclid(7) as usize;
        format!("{} {hh:02}:{mm:02}", names[idx])
    }
}

pub fn capitalized(s: &str) -> String {
    s.split_whitespace()
        .map(|w| {
            let mut chars = w.chars();
            match chars.next() {
                None => String::new(),
                Some(first) => {
                    let mut out: String = first.to_uppercase().collect();
                    out.push_str(&chars.as_str().to_lowercase());
                    out
                }
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn compact_number(n: f64) -> String {
    let sign = if n < 0.0 { "-" } else { "" };
    let a = n.abs();
    let (div, suf) = if a >= 1_000_000_000.0 {
        (1e9, "B")
    } else if a >= 1_000_000.0 {
        (1e6, "M")
    } else if a >= 10_000.0 {
        (1e3, "K")
    } else {
        return format!("{sign}{}", a.round() as i64);
    };
    let v = a / div;
    if (v - v.round()).abs() < 0.05 {
        format!("{sign}{}{suf}", v.round() as i64)
    } else {
        format!("{sign}{v:.1}{suf}")
    }
}

pub fn local_offset_secs(now: f64) -> i32 {
    let local = chrono::Local;
    let dt = chrono::DateTime::from_timestamp(now as i64, 0).unwrap_or_else(chrono::Utc::now);
    local
        .offset_from_utc_datetime(&dt.naive_utc())
        .local_minus_utc()
}
