use phosphor_core::alerts::{
    AlertEngine, AlertMemory, AlertSettings, BillingReading, Credit, QuotaReading,
};
use phosphor_core::forecast::{ForecastSample, QuotaForecast};
use phosphor_core::timeutil::parse_iso;
use serde_json::Value;
use std::path::PathBuf;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

fn near(a: f64, b: f64) -> bool {
    (a - b).abs() < 0.01
}

#[test]
fn forecast_matches_macos_golden_cases() {
    let data = std::fs::read(fixtures().join("forecast/cases.json")).unwrap();
    let cases: Vec<Value> = serde_json::from_slice(&data).unwrap();
    assert!(cases.len() >= 14, "expected every ForecastTests case");
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let now = case["now"].as_f64().unwrap();
        let used = case["usedPercent"].as_f64().unwrap();
        let resets = case["resetsAt"].as_f64();
        let window = case["windowSeconds"].as_f64();
        let active = case["activeSession"].as_bool().unwrap_or(true);
        let samples: Vec<ForecastSample> = case["samples"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| {
                ForecastSample::new(
                    s["t"].as_f64().unwrap(),
                    s["u"].as_f64().unwrap(),
                    s["r"].as_f64(),
                )
            })
            .collect();
        let f = QuotaForecast::make(used, resets, window, active, &samples, now);
        let expect = &case["expect"];
        assert_eq!(
            f.kind.as_str(),
            expect["kind"].as_str().unwrap(),
            "{name} kind"
        );
        if let Some(rate) = expect["ratePerHour"].as_f64() {
            assert!(
                near(f.rate_per_hour, rate),
                "{name} rate {} != {rate}",
                f.rate_per_hour
            );
        }
        if let Some(warns) = expect["warnsBeforeReset"].as_bool() {
            assert_eq!(f.warns_before_reset(), warns, "{name} warns");
        }
        if let Some(at) = expect["atReset"].as_f64() {
            assert!(
                near(f.at_reset.unwrap_or(f64::NAN), at),
                "{name} atReset {:?}",
                f.at_reset
            );
        }
        if let Some(hits) = expect["hitsLimitAt"].as_f64() {
            assert!(near(f.hits_limit_at.unwrap(), hits), "{name} hits");
        }
        if let Some(has) = expect["hasHitsLimitAt"].as_bool() {
            assert_eq!(f.hits_limit_at.is_some(), has, "{name} has hits");
        }
    }
}

#[test]
fn alerts_match_macos_golden_cases() {
    let data = std::fs::read(fixtures().join("alerts/cases.json")).unwrap();
    let root: Value = serde_json::from_slice(&data).unwrap();
    let now = parse_iso(root["now"].as_str().unwrap()).unwrap();
    let tz = root["tzOffsetSecs"].as_i64().unwrap() as i32;
    for case in root["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let settings = AlertSettings::decode(case["settings"].to_string().as_bytes());
        let mut memory = AlertMemory::default();
        for (i, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let quotas = step["quotas"]
                .as_array()
                .unwrap()
                .iter()
                .map(|q| QuotaReading {
                    provider: q["provider"].as_str().unwrap().into(),
                    provider_name: q["providerName"].as_str().unwrap().into(),
                    window: q["window"].as_str().unwrap().into(),
                    used: q["used"].as_f64().unwrap(),
                    resets_at: q
                        .get("resetsAt")
                        .and_then(|v| v.as_str())
                        .and_then(parse_iso),
                })
                .collect::<Vec<_>>();
            let bills = step["bills"]
                .as_array()
                .unwrap()
                .iter()
                .map(|b| BillingReading {
                    provider: b["provider"].as_str().unwrap().into(),
                    provider_name: b["providerName"].as_str().unwrap().into(),
                    next_bill: b
                        .get("nextBill")
                        .and_then(|v| v.as_str())
                        .and_then(parse_iso),
                    price: b
                        .get("price")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string()),
                    credits: b
                        .get("credits")
                        .and_then(|v| v.as_array())
                        .map(|list| {
                            list.iter()
                                .filter_map(|c| {
                                    Some(Credit {
                                        title: c["title"].as_str()?.into(),
                                        amount: c
                                            .get("amount")
                                            .and_then(|v| v.as_str())
                                            .map(|s| s.to_string()),
                                        expires: parse_iso(c["expires"].as_str()?)?,
                                    })
                                })
                                .collect()
                        })
                        .unwrap_or_default(),
                })
                .collect::<Vec<_>>();
            let fired = AlertEngine::evaluate(&quotas, &bills, &settings, &mut memory, now, tz);
            let kinds: Vec<_> = fired.iter().map(|a| a.kind.as_str()).collect();
            let titles: Vec<_> = fired.iter().map(|a| a.title.as_str()).collect();
            let want_kinds: Vec<_> = step["kinds"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|v| v.as_str())
                .collect();
            let want_titles: Vec<_> = step["titles"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|v| v.as_str())
                .collect();
            assert_eq!(kinds, want_kinds, "{name} step {i} kinds");
            assert_eq!(titles, want_titles, "{name} step {i} titles");
        }
    }
}

#[test]
fn alert_settings_keep_defaults() {
    let data = std::fs::read(fixtures().join("config/alerts.json")).unwrap();
    let s = AlertSettings::decode(&data);
    assert_eq!(s.warn_at, 60.0);
    assert!(!s.bill_enabled);
    assert_eq!(s.critical_at, 90.0);
    assert_eq!(s.credit_days_before, 3);
}
