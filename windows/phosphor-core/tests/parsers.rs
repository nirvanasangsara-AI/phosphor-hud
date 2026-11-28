use phosphor_core::parsers::{LogParsers, TokenUsage};
use phosphor_core::pricing::PriceTable;
use phosphor_core::quota;
use phosphor_core::timeutil::parse_iso;
use serde_json::Value;
use std::path::PathBuf;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

fn lines(name: &str) -> Vec<Value> {
    std::fs::read_to_string(fixtures().join(name))
        .unwrap()
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

#[test]
fn claude_fixture_keeps_usage_and_drops_prompts() {
    let rows = lines("logs/claude.jsonl");
    let e = LogParsers::claude(&rows[0]).unwrap();
    assert_eq!(e.usage, TokenUsage::new(10, 20, 300, 40, None));
    assert_eq!(e.model, "claude-sonnet-5");
    assert_eq!(e.dedupe_key.as_deref(), Some("claude:msg_1:req_1"));
    assert!(parse_iso("2026-11-25T03:00:00.000Z").is_some());
    assert!(LogParsers::claude(&rows[1]).is_none());
    assert!(LogParsers::claude(&rows[2]).is_none());
    assert!(LogParsers::claude(&rows[3]).is_none());
    let dumped = format!("{e:?}");
    assert!(!dumped.contains("prompt text"));
}

#[test]
fn codex_fixture_is_cumulative() {
    let rows = lines("logs/codex.jsonl");
    let mut state = phosphor_core::parsers::CodexState::default();
    assert!(LogParsers::codex(&rows[0], &mut state).is_none());
    assert_eq!(state.model.as_deref(), Some("gpt-6-astra"));
    let a = LogParsers::codex(&rows[1], &mut state).unwrap();
    assert_eq!(a.usage, TokenUsage::new(600, 50, 400, 0, None));
    assert_eq!(a.model, "gpt-6-astra");
    let b = LogParsers::codex(&rows[2], &mut state).unwrap();
    assert_eq!(b.usage, TokenUsage::new(0, 30, 500, 0, None));
    assert!(LogParsers::codex(&rows[3], &mut state).is_none());
    assert!(LogParsers::codex(&rows[4], &mut state).is_none());
}

#[test]
fn gemini_fixture_splits_cached_and_thoughts() {
    let rows = lines("logs/gemini.jsonl");
    let e = LogParsers::gemini(&rows[0]).unwrap();
    assert_eq!(e.usage, TokenUsage::new(400, 150, 600, 0, None));
    assert!(LogParsers::gemini(&rows[1]).is_none());
}

#[test]
fn cline_fixture_uses_logged_cost() {
    let data = std::fs::read(fixtures().join("logs/cline/t1/ui_messages.json")).unwrap();
    let msgs: Vec<Value> = serde_json::from_slice(&data).unwrap();
    let ev = LogParsers::cline_task(&msgs, "cline", "t1");
    assert_eq!(ev.len(), 1);
    assert_eq!(ev[0].usage.logged_cost, Some(0.0123));
    assert_eq!(ev[0].dedupe_key.as_deref(), Some("cline:t1:1764039600000"));
    assert!(!format!("{ev:?}").contains("hello from the user"));
}

#[test]
fn price_table_fixture_matches_macos_lookup() {
    let data = std::fs::read(fixtures().join("pricing/litellm.json")).unwrap();
    let table = PriceTable::from_litellm_json(&data).unwrap();
    assert_eq!(table.len(), 3);
    assert!(table.price_for("claude-sonnet-5-20261001").is_some());
    assert!(table.price_for("anthropic/claude-sonnet-5").is_some());
    assert!(table.price_for("claude-sonnet-5[1m]").is_some());
    assert!(table.price_for("gemini-3-pro").is_some());
    assert!(table.price_for("mystery-model").is_none());
    let c = table
        .cost(
            &TokenUsage::new(1000, 1000, 10000, 1000, None),
            "claude-sonnet-5",
        )
        .unwrap();
    assert!((c - (0.003 + 0.015 + 0.003 + 0.00375)).abs() < 1e-12);
    let g = table
        .cost(&TokenUsage::new(0, 0, 1000, 0, None), "gpt-6-astra")
        .unwrap();
    assert!((g - 0.01).abs() < 1e-12);
    assert_eq!(
        table.cost(&TokenUsage::new(5, 0, 0, 0, Some(0.5)), "mystery"),
        Some(0.5)
    );
    assert_eq!(
        table.cost(&TokenUsage::new(5, 0, 0, 0, None), "mystery"),
        None
    );

    let dotted = PriceTable::from_litellm_json(
        br#"{"openai.gpt-6.1-terra":{"input_cost_per_token":1e-06,"output_cost_per_token":5e-06}}"#,
    )
    .unwrap();
    let cost = dotted
        .cost(&TokenUsage::new(1_000_000, 0, 0, 0, None), "gpt-6.1-terra")
        .unwrap();
    assert!((cost - 1.0).abs() < 1e-9);
}

#[test]
fn quota_fixtures_match_provider_shapes() {
    let claude: Value =
        serde_json::from_slice(&std::fs::read(fixtures().join("quota/claude_usage.json")).unwrap())
            .unwrap();
    let parsed = quota::claude_usage(&claude);
    assert_eq!(parsed.windows[0].label, "5H");
    assert_eq!(parsed.windows[0].used_percent, 62.0);
    assert!(parsed.windows[0].active_session);
    assert_eq!(parsed.windows[1].label, "7D");
    assert_eq!(parsed.windows[2].label, "7D OPUS");
    assert_eq!(parsed.windows[2].used_percent, 12.0);

    let codex: Value =
        serde_json::from_slice(&std::fs::read(fixtures().join("quota/codex_usage.json")).unwrap())
            .unwrap();
    let parsed = quota::codex_usage(&codex, 1_700_000_000.0);
    assert_eq!(parsed.plan.as_deref(), Some("Pro"));
    assert_eq!(parsed.windows.len(), 1);
    assert_eq!(parsed.windows[0].label, "5H");
    assert!(parsed.windows[0].active_session);
    assert_eq!(parsed.windows[0].used_percent, 18.0);
    let both_null = serde_json::json!({"rate_limit": {"primary_window": null, "secondary_window": {"used_percent": 40, "limit_window_seconds": 604800}}});
    let parsed = quota::codex_usage(&both_null, 1_700_000_000.0);
    assert!(!parsed.windows[0].active_session);
    assert_eq!(parsed.windows[0].label, "5H");
    assert_eq!(parsed.windows[1].label, "7D");

    let copilot: Value =
        serde_json::from_slice(&std::fs::read(fixtures().join("quota/copilot_user.json")).unwrap())
            .unwrap();
    let parsed = quota::copilot_usage(&copilot);
    assert_eq!(parsed.plan.as_deref(), Some("Individual"));
    assert_eq!(parsed.windows.len(), 2);
    assert!((parsed.windows[0].used_percent - 54.0).abs() < 0.01);
    assert!((parsed.windows[1].used_percent - 12.0).abs() < 0.01);
}

#[test]
fn null_five_hour_is_an_inactive_session() {
    let v = serde_json::json!({"five_hour": null, "seven_day": {"utilization": 4, "resets_at": "2026-12-01T00:00:00Z"}});
    let parsed = quota::claude_usage(&v);
    assert!(!parsed.windows[0].active_session);
    assert_eq!(parsed.windows[0].used_percent, 0.0);
    assert_eq!(parsed.windows[1].label, "7D");
}
