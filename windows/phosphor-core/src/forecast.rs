//! Burn-rate slope. Ported from `Sources/PhosphorCore/Forecast.swift`.

use crate::timeutil::{clock, countdown};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ForecastSample {
    pub t: f64,
    pub u: f64,
    pub r: Option<f64>,
}

impl ForecastSample {
    pub fn new(t: f64, u: f64, r: Option<f64>) -> Self {
        Self { t, u, r }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ForecastKind {
    Rate,
    Steady,
    Measuring,
    LimitReached,
    NoSession,
}

impl ForecastKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rate => "rate",
            Self::Steady => "steady",
            Self::Measuring => "measuring",
            Self::LimitReached => "limitReached",
            Self::NoSession => "noSession",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Forecast {
    pub kind: ForecastKind,
    pub hits_limit_at: Option<f64>,
    pub rate_per_hour: f64,
    pub before_reset: bool,
    pub at_reset: Option<f64>,
    pub resets_at: Option<f64>,
}

impl Forecast {
    pub fn warns_before_reset(&self) -> bool {
        self.kind == ForecastKind::Rate && self.before_reset && self.hits_limit_at.is_some()
    }
}

pub struct QuotaForecast;

impl QuotaForecast {
    pub const LOOKBACK: f64 = 60.0 * 60.0;
    pub const LONG_LOOKBACK: f64 = 6.0 * 3600.0;
    pub const MIN_SPAN: f64 = 5.0 * 60.0;
    pub const MIN_RATE: f64 = 0.25;
    pub const MIN_SAMPLES: usize = 2;

    pub fn make(
        used_percent: f64,
        resets_at: Option<f64>,
        window_seconds: Option<f64>,
        active_session: bool,
        samples: &[ForecastSample],
        now: f64,
    ) -> Forecast {
        if !active_session {
            return Forecast {
                kind: ForecastKind::NoSession,
                hits_limit_at: None,
                rate_per_hour: 0.0,
                before_reset: false,
                at_reset: None,
                resets_at,
            };
        }
        if used_percent >= 100.0 {
            return Forecast {
                kind: ForecastKind::LimitReached,
                hits_limit_at: Some(now),
                rate_per_hour: 0.0,
                before_reset: false,
                at_reset: Some(100.0),
                resets_at,
            };
        }

        let long = window_seconds.unwrap_or(0.0) >= 86_400.0;
        let lookback = if long {
            Self::LONG_LOOKBACK
        } else {
            Self::LOOKBACK
        };
        let mut pts: Vec<ForecastSample> = Vec::new();
        for s in samples {
            if s.t < now - lookback || s.t > now + 1.0 {
                continue;
            }
            if let (Some(a), Some(b)) = (s.r, resets_at) {
                if (a - b).abs() > 300.0 {
                    continue;
                }
            }
            if let Some(last) = pts.last() {
                if s.u < last.u - 1.0 {
                    pts.clear();
                }
            }
            pts.push(*s);
        }

        let at_used = resets_at.map(|_| used_percent);
        if pts.len() < Self::MIN_SAMPLES {
            return measuring(at_used, resets_at);
        }
        let first = pts[0];
        let last = pts[pts.len() - 1];
        if last.t - first.t < Self::MIN_SPAN {
            return measuring(at_used, resets_at);
        }

        let xs: Vec<f64> = pts.iter().map(|p| (p.t - first.t) / 3600.0).collect();
        let ys: Vec<f64> = pts.iter().map(|p| p.u).collect();
        let n = pts.len() as f64;
        let mx = xs.iter().sum::<f64>() / n;
        let my = ys.iter().sum::<f64>() / n;
        let mut num = 0.0;
        let mut den = 0.0;
        for (x, y) in xs.iter().zip(ys.iter()) {
            num += (x - mx) * (y - my);
            den += (x - mx) * (x - mx);
        }
        let rate = if den > 0.0 { num / den } else { 0.0 };
        if rate < Self::MIN_RATE {
            return Forecast {
                kind: ForecastKind::Steady,
                hits_limit_at: None,
                rate_per_hour: 0.0,
                before_reset: false,
                at_reset: at_used,
                resets_at,
            };
        }

        let hits = now + (100.0 - used_percent) / rate * 3600.0;
        let mut at_reset = None;
        let mut before = true;
        if let Some(r) = resets_at {
            before = hits < r;
            let projected = used_percent + rate * (r - now).max(0.0) / 3600.0;
            at_reset = Some(projected.min(100.0));
        }
        Forecast {
            kind: ForecastKind::Rate,
            hits_limit_at: Some(hits),
            rate_per_hour: rate,
            before_reset: before,
            at_reset,
            resets_at,
        }
    }
}

fn measuring(at_reset: Option<f64>, resets_at: Option<f64>) -> Forecast {
    Forecast {
        kind: ForecastKind::Measuring,
        hits_limit_at: None,
        rate_per_hour: 0.0,
        before_reset: false,
        at_reset,
        resets_at,
    }
}

pub fn rate_value(rate: f64) -> String {
    if rate >= 10.0 {
        format!("{}", rate.round() as i64)
    } else {
        format!("{rate:.1}")
    }
}

/// English HUD line, the same copy as `L10n` `forecast.*` on macOS.
pub fn caption(f: &Forecast, now: f64, tz_offset_secs: i32) -> (Option<String>, String) {
    let rate = match f.kind {
        ForecastKind::Rate => Some(format!("+{}%/h", rate_value(f.rate_per_hour))),
        ForecastKind::Steady | ForecastKind::Measuring => Some("0%/h".into()),
        ForecastKind::LimitReached | ForecastKind::NoSession => None,
    };
    let text = match f.kind {
        ForecastKind::Rate => {
            if f.warns_before_reset() {
                if let Some(hits) = f.hits_limit_at {
                    format!(
                        "▲ limit {} · in {}",
                        clock(hits, now, tz_offset_secs),
                        countdown(hits, now)
                    )
                } else {
                    format!("+{}%/h", rate_value(f.rate_per_hour))
                }
            } else if let Some(r) = f.at_reset {
                format!("≈ {}% at reset", r.round() as i64)
            } else {
                format!("+{}%/h", rate_value(f.rate_per_hour))
            }
        }
        ForecastKind::Steady => {
            if let Some(r) = f.at_reset {
                format!("steady · ≈ {}% at reset", r.round() as i64)
            } else {
                "steady".into()
            }
        }
        ForecastKind::Measuring => "measuring pace".into(),
        ForecastKind::LimitReached => {
            if let Some(r) = f.resets_at {
                if r > now {
                    return (rate, format!("▲ limit reached · in {}", countdown(r, now)));
                }
            }
            "▲ limit reached".into()
        }
        ForecastKind::NoSession => "no active session".into(),
    };
    (rate, text)
}
