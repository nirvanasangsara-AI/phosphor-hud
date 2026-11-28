//! GitHub PR counts, the LinearB tier, and subscription ROI.
//! Ported from `Sources/PhosphorCore/DevStats.swift`. The Windows app runs `gh`
//! only when the efficiency strip is turned on.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct GhQuery {
    pub key: String,
    pub endpoint: String,
    pub q: String,
}

pub fn github_queries(login: &str, now: f64, tz_offset_secs: i32) -> Vec<GhQuery> {
    let day = |ago: i64| -> String {
        let t = now - ago as f64 * 86_400.0;
        crate::timeutil::day_key(t, 0)
    };
    let local_midnight = crate::timeutil::day_number(now, tz_offset_secs) as f64 * 86_400.0
        - f64::from(tz_offset_secs);
    let t = iso_z(local_midnight);
    let range = |a: i64, b: i64| format!("{}..{}", day(a), day(b));
    let pr = format!("author:{login} type:pr");
    let cm = format!("author:{login}");
    let mut q = vec![
        GhQuery {
            key: "mergedToday".into(),
            endpoint: "search/issues".into(),
            q: format!("{pr} is:merged merged:>={t}"),
        },
        GhQuery {
            key: "merged7".into(),
            endpoint: "search/issues".into(),
            q: format!("{pr} is:merged merged:>={}", day(7)),
        },
        GhQuery {
            key: "merged30".into(),
            endpoint: "search/issues".into(),
            q: format!("{pr} is:merged merged:>={}", day(30)),
        },
        GhQuery {
            key: "openedToday".into(),
            endpoint: "search/issues".into(),
            q: format!("{pr} created:>={t}"),
        },
        GhQuery {
            key: "opened7".into(),
            endpoint: "search/issues".into(),
            q: format!("{pr} created:>={}", day(7)),
        },
        GhQuery {
            key: "opened30".into(),
            endpoint: "search/issues".into(),
            q: format!("{pr} created:>={}", day(30)),
        },
        GhQuery {
            key: "commitsToday".into(),
            endpoint: "search/commits".into(),
            q: format!("{cm} author-date:>={t}"),
        },
        GhQuery {
            key: "commits7".into(),
            endpoint: "search/commits".into(),
            q: format!("{cm} author-date:>={}", day(7)),
        },
        GhQuery {
            key: "commits30".into(),
            endpoint: "search/commits".into(),
            q: format!("{cm} author-date:>={}", day(30)),
        },
    ];
    for w in 1..=3 {
        q.push(GhQuery {
            key: format!("mergedW{w}"),
            endpoint: "search/issues".into(),
            q: format!("{pr} is:merged merged:{}", range(7 * w + 7, 7 * w + 1)),
        });
        q.push(GhQuery {
            key: format!("commitsW{w}"),
            endpoint: "search/commits".into(),
            q: format!("{cm} author-date:{}", range(7 * w + 7, 7 * w + 1)),
        });
    }
    q
}

fn iso_z(epoch: f64) -> String {
    chrono::DateTime::from_timestamp(epoch as i64, 0)
        .map(|d| d.format("%Y-%m-%dT%H:%M:%SZ").to_string())
        .unwrap_or_default()
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DevCounts {
    pub login: String,
    pub merged_today: i64,
    pub merged_7: i64,
    pub merged_30: i64,
    pub opened_today: i64,
    pub opened_7: i64,
    pub opened_30: i64,
    pub commits_today: i64,
    pub commits_7: i64,
    pub commits_30: i64,
    pub merged_weeks: Vec<i64>,
    pub commit_weeks: Vec<i64>,
    pub fetched_at: f64,
}

impl DevCounts {
    pub fn from_results(login: &str, results: &HashMap<String, i64>, at: f64) -> Self {
        let g = |k: &str| results.get(k).copied().unwrap_or(0);
        let merged_7 = g("merged7");
        let commits_7 = g("commits7");
        Self {
            login: login.into(),
            merged_today: g("mergedToday"),
            merged_7,
            merged_30: g("merged30"),
            opened_today: g("openedToday"),
            opened_7: g("opened7"),
            opened_30: g("opened30"),
            commits_today: g("commitsToday"),
            commits_7,
            commits_30: g("commits30"),
            merged_weeks: vec![merged_7, g("mergedW1"), g("mergedW2"), g("mergedW3")],
            commit_weeks: vec![commits_7, g("commitsW1"), g("commitsW2"), g("commitsW3")],
            fetched_at: at,
        }
    }

    pub fn prs_per_week(&self) -> f64 {
        self.merged_30 as f64 / (30.0 / 7.0)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Placement {
    pub tier: String,
    pub top_percent: Option<i64>,
    pub label: String,
}

pub fn place_prs(prs_per_week: f64) -> Placement {
    if prs_per_week > 2.0 {
        return Placement {
            tier: "Elite".into(),
            top_percent: None,
            label: format!("Elite band · {:.1} PR/wk (benchmark >2.0)", prs_per_week),
        };
    }
    let anchors = [(0.0_f64, 100.0_f64), (0.66, 60.0), (1.2, 30.0), (2.0, 10.0)];
    let mut top = 100.0_f64;
    for pair in anchors.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        if prs_per_week >= a.0 && prs_per_week <= b.0 {
            top = a.1 + (b.1 - a.1) * (prs_per_week - a.0) / (b.0 - a.0);
        }
    }
    let tier = if prs_per_week >= 1.2 {
        "Good"
    } else if prs_per_week >= 0.66 {
        "Fair"
    } else {
        "Needs focus"
    };
    let pct = top.round() as i64;
    let band = if prs_per_week >= 1.2 {
        "1.2-2.0"
    } else if prs_per_week >= 0.66 {
        "0.66-1.2"
    } else {
        "<0.66"
    };
    Placement {
        tier: tier.into(),
        top_percent: Some(pct),
        label: format!("{tier} band · {prs_per_week:.1} PR/wk (benchmark {band})"),
    }
}

pub fn usd(amounts: &HashMap<String, f64>, units_per_usd: &HashMap<String, f64>) -> Option<f64> {
    let mut total = 0.0;
    for (cur, v) in amounts {
        if cur.eq_ignore_ascii_case("USD") {
            total += v;
            continue;
        }
        let r = units_per_usd.get(&cur.to_uppercase()).copied()?;
        if r <= 0.0 {
            return None;
        }
        total += v / r;
    }
    Some(total)
}

pub fn roi_ratio(api_value_usd: f64, spend_usd: f64) -> Option<f64> {
    if spend_usd > 0.0 && api_value_usd > 0.0 {
        Some(api_value_usd / spend_usd)
    } else {
        None
    }
}

pub fn per_pr(value: f64, merged: i64) -> Option<f64> {
    if merged > 0 {
        Some(value / merged as f64)
    } else {
        None
    }
}
