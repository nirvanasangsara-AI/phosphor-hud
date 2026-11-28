use phosphor_core::collect::{load_hud, HudOptions, Offline, TransportError, UsageTransport};
use phosphor_core::config::{parse_accounts, parse_providers};
use phosphor_core::devstats::{self, place_prs};
use phosphor_core::ledger::{matching_lines, LogScanner, UsageLedger};
use phosphor_core::paths::{self, LogFormat, LogSource, PATH_DOCS};
use phosphor_core::pricing::PriceTable;
use phosphor_core::timeutil::parse_iso;
use phosphor_core::token_refresh::{self, RefreshKind};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

fn temp() -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    let n = N.fetch_add(1, Ordering::Relaxed);
    let p = std::env::temp_dir().join(format!("phosphor-test-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).unwrap();
    p
}

#[test]
fn accounts_fixture_matches_macos_profile_rules() {
    let data = std::fs::read(fixtures().join("config/accounts.json")).unwrap();
    let home = Path::new("/Users/t");
    let r = parse_accounts(&data, home);
    let ids: Vec<_> = r.profiles.iter().map(|p| p.id()).collect();
    assert_eq!(ids, vec!["codex@work", "claude@side"]);
    assert_eq!(
        PathBuf::from(r.profiles[0].home.as_deref().unwrap()),
        Path::new("/Users/t").join(".codex-work")
    );
    assert_eq!(r.problems.len(), 3);
}

#[test]
fn providers_fixture_keeps_command_shape() {
    let data = std::fs::read(fixtures().join("config/providers.json")).unwrap();
    let list = parse_providers(&data);
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].id, "team-gateway");
    assert!(list[0].command.contains("manual.sh"));
}

#[test]
fn windows_paths_honor_env_and_check_both_codex_roots() {
    let home = PathBuf::from(r"C:\Users\me");
    let mut env = HashMap::new();
    env.insert("CLAUDE_CONFIG_DIR".into(), r"D:\claude-side".into());
    let cred = paths::claude_credential_file(&home, &env);
    assert!(cred.ends_with(".credentials.json"), "{cred:?}");
    assert!(cred.to_string_lossy().contains("claude-side"), "{cred:?}");
    env.insert("CLAUDE_CONFIG_DIR".into(), r"D:\one,E:\two".into());
    let roots = paths::claude_log_roots(&home, &env);
    assert!(
        roots
            .iter()
            .any(|p| p.to_string_lossy().contains("one") && p.ends_with("projects")),
        "{roots:?}"
    );
    assert!(
        roots
            .iter()
            .any(|p| p.to_string_lossy().contains("two") && p.ends_with("projects")),
        "{roots:?}"
    );

    let mut env = HashMap::new();
    env.insert("APPDATA".into(), r"C:\Users\me\AppData\Roaming".into());
    let homes = paths::codex_homes(&home, &env);
    assert_eq!(homes.len(), 2);
    assert!(homes.iter().any(|p| p.ends_with(".codex")));
    assert!(homes.iter().any(|p| p.ends_with("codex")));

    env.insert("CODEX_HOME".into(), r"D:\work-codex".into());
    let homes = paths::codex_homes(&home, &env);
    assert_eq!(homes, vec![PathBuf::from(r"D:\work-codex")]);
}

#[test]
fn path_docs_cover_confidence_and_the_readme() {
    let readme = include_str!("../../../README.md");
    assert!(PATH_DOCS
        .iter()
        .any(|d| d.confidence == paths::Confidence::Official));
    assert!(PATH_DOCS
        .iter()
        .any(|d| d.confidence == paths::Confidence::Assumption));
    assert!(PATH_DOCS
        .iter()
        .any(|d| d.confidence == paths::Confidence::Unknown));
    for doc in PATH_DOCS {
        assert!(
            readme.contains(doc.readme_needle),
            "README is missing {} ({})",
            doc.readme_needle,
            doc.provider
        );
    }
}

#[test]
fn scanner_counts_a_fixture_once_and_dedupes() {
    let dir = temp().join("scan");
    std::fs::create_dir_all(&dir).unwrap();
    let line = r#"{"timestamp":"2026-11-25T03:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":20}}}"#;
    std::fs::write(dir.join("a.jsonl"), format!("{line}\n")).unwrap();
    std::fs::write(dir.join("b.jsonl"), format!("{line}\n")).unwrap();
    let src = LogSource {
        id: "claude".into(),
        format: LogFormat::Claude,
        roots: vec![dir.clone()],
        needles: vec!["\"usage\"".into()],
        file_suffix: ".jsonl".into(),
        whole_file: false,
    };
    let now = parse_iso("2026-11-26T00:00:00Z").unwrap();
    let scanner = LogScanner {
        sources: vec![src],
        window_days: 3650,
        initial_days: 3650,
        tz_offset_secs: 0,
    };
    let mut ledger = UsageLedger::default();
    scanner.scan(&mut ledger, now);
    let row = &ledger.days["2026-11-25"]["claude|claude-sonnet-5"];
    assert_eq!(row.input, 10);
    assert_eq!(row.output, 20);

    let extra = r#"{"timestamp":"2026-11-25T04:00:00Z","requestId":"r2","message":{"id":"m2","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":2}}}"#;
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .append(true)
        .open(dir.join("a.jsonl"))
        .unwrap();
    writeln!(f, "{extra}").unwrap();
    writeln!(f, r#"{{"timestamp":"#).unwrap();
    drop(f);
    scanner.scan(&mut ledger, now);
    let row = &ledger.days["2026-11-25"]["claude|claude-sonnet-5"];
    assert_eq!((row.input, row.output), (11, 22));
    scanner.scan(&mut ledger, now);
    let row = &ledger.days["2026-11-25"]["claude|claude-sonnet-5"];
    assert_eq!((row.input, row.output), (11, 22));
}

#[test]
fn matching_lines_keep_order() {
    let buf = b"a token_count 1\nnoise\nb turn_context\nc token_count 2\n";
    let lines = matching_lines(buf, &[b"turn_context", b"token_count"]);
    let text: Vec<_> = lines
        .iter()
        .map(|l| std::str::from_utf8(l).unwrap())
        .collect();
    assert_eq!(
        text,
        vec!["a token_count 1", "b turn_context", "c token_count 2"]
    );
}

#[test]
fn token_refresh_rules_match_macos() {
    let jwt = token_refresh::fake_jwt(1_700_000_000);
    assert_eq!(token_refresh::jwt_expiry(&jwt), Some(1_700_000_000.0));
    assert!(token_refresh::jwt_expiry("not-a-jwt").is_none());
    let now = 1_700_000_000.0;
    assert!(!token_refresh::needs_refresh(
        None,
        now,
        token_refresh::DEFAULT_LEEWAY
    ));
    assert!(!token_refresh::needs_refresh(
        Some(now + 600.0),
        now,
        token_refresh::DEFAULT_LEEWAY
    ));
    assert!(token_refresh::needs_refresh(
        Some(now + 300.0),
        now,
        token_refresh::DEFAULT_LEEWAY
    ));
    assert_eq!(token_refresh::classify(200, ""), RefreshKind::Success);
    assert_eq!(
        token_refresh::classify(401, "invalid_grant"),
        RefreshKind::Permanent
    );
    assert_eq!(
        token_refresh::classify(400, "invalid_request"),
        RefreshKind::Transient
    );
    assert_eq!(
        token_refresh::classify(0, "network down"),
        RefreshKind::Transient
    );
    assert_eq!(
        token_refresh::CODEX_CLIENT_ID,
        "app_EMoamEEZ73f0CkXaXp7hrann"
    );
    let svc = token_refresh::claude_keychain_service("/Users/t/.claude-side");
    assert!(svc.starts_with("Claude Code-credentials-"));
    assert_eq!(svc.len(), "Claude Code-credentials-".len() + 8);
}

#[test]
fn benchmark_and_roi_match_the_published_bands() {
    let elite = place_prs(2.1);
    assert_eq!(elite.tier, "Elite");
    assert!(elite.top_percent.is_none());
    assert!(elite.label.contains("2.1"));
    assert!(!elite.label.contains("Top 10%"));
    let higher = place_prs(18.0);
    assert_ne!(elite.label, higher.label);
    let fair = place_prs(0.0);
    assert_eq!(fair.tier, "Needs focus");
    let mut sums = HashMap::new();
    sums.insert("USD".into(), 20.0);
    sums.insert("KRW".into(), 290_000.0);
    let mut fx = HashMap::new();
    fx.insert("KRW".into(), 1450.0);
    let total = devstats::usd(&sums, &fx).unwrap();
    assert!((total - (20.0 + 290_000.0 / 1450.0)).abs() < 1e-9);
    assert!(devstats::roi_ratio(84.0, 10.0).unwrap() > 8.0);
    assert_eq!(devstats::per_pr(30.0, 0), None);
}

struct Recording {
    token: &'static str,
    hit: Mutex<bool>,
}

impl UsageTransport for Recording {
    fn get_json(&self, url: &str, headers: &[(&str, String)]) -> Result<Value, TransportError> {
        assert!(url.starts_with("https://api.anthropic.com/"));
        let auth = headers
            .iter()
            .find(|(k, _)| *k == "Authorization")
            .map(|(_, v)| v.clone());
        assert!(auth.unwrap().contains(self.token));
        *self.hit.lock().unwrap() = true;
        Ok(json!({
            "five_hour": {"utilization": 12, "resets_at": "2026-11-26T08:00:00Z"},
            "seven_day": {"utilization": 40, "resets_at": "2026-12-03T00:00:00Z"}
        }))
    }
}

#[test]
fn hud_reads_local_files_and_does_not_keep_the_token() {
    let root = temp().join("hud");
    let home = root.join("home");
    let support = root.join("support");
    let config = home.join(".config").join("phosphor");
    std::fs::create_dir_all(home.join(".claude").join("projects").join("demo")).unwrap();
    std::fs::create_dir_all(&support).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    let token = "SECRET-TOKEN-VALUE-XYZ";
    std::fs::write(
        home.join(".claude").join(".credentials.json"),
        json!({
            "claudeAiOauth": {
                "accessToken": token,
                "refreshToken": "ALSO-SECRET",
                "expiresAt": 9_000_000_000_000_i64,
                "subscriptionType": "max"
            }
        })
        .to_string(),
    )
    .unwrap();
    let line = r#"{"timestamp":"2026-11-25T03:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":20}}}"#;
    std::fs::write(
        home.join(".claude")
            .join("projects")
            .join("demo")
            .join("a.jsonl"),
        format!("{line}\n"),
    )
    .unwrap();
    let prices = PriceTable::from_litellm_json(
        &std::fs::read(fixtures().join("pricing/litellm.json")).unwrap(),
    )
    .unwrap();
    let env = HashMap::new();
    let fx = HashMap::new();
    let transport = Recording {
        token,
        hit: Mutex::new(false),
    };
    let now = parse_iso("2026-11-26T12:00:00Z").unwrap();
    let model = load_hud(&HudOptions {
        home: &home,
        env: &env,
        now,
        tz_offset_secs: 0,
        config_dir: &config,
        support_dir: &support,
        prices: &prices,
        fx: &fx,
        transport: &transport,
        demo: false,
        show_dev: false,
        dev_counts: None,
        persist: true,
    });
    assert!(*transport.hit.lock().unwrap());
    let dumped = serde_json::to_string(&model).unwrap();
    assert!(!dumped.contains(token), "token leaked into the HUD model");
    assert!(!dumped.contains("ALSO-SECRET"));
    let claude = model.rows.iter().find(|r| r.id == "claude").unwrap();
    assert_eq!(claude.status, "ok");
    assert_eq!(claude.plan.as_deref(), Some("Max"));
    assert!(claude
        .windows
        .iter()
        .any(|w| w.label == "5H" && (w.used_percent - 12.0).abs() < 0.01));
    assert!(claude.detail.as_deref().unwrap_or("").contains("Logs 7D"));
    let agy = model.rows.iter().find(|r| r.id == "antigravity").unwrap();
    assert_eq!(agy.status, "unavailable");
    assert!(agy.message.as_deref().unwrap_or("").contains("not known"));
    let codex = model.rows.iter().find(|r| r.id == "codex").unwrap();
    assert!(codex
        .message
        .as_deref()
        .unwrap_or("")
        .contains("Credential Manager"));
}

#[test]
fn offline_hud_does_not_panic_on_an_empty_home() {
    let root = temp().join("empty");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let prices = PriceTable::new();
    let env = HashMap::new();
    let fx = HashMap::new();
    let model = load_hud(&HudOptions {
        home: &home,
        env: &env,
        now: 1_700_000_000.0,
        tz_offset_secs: 0,
        config_dir: &home.join(".config").join("phosphor"),
        support_dir: &root.join("support"),
        prices: &prices,
        fx: &fx,
        transport: &Offline,
        demo: false,
        show_dev: false,
        dev_counts: None,
        persist: false,
    });
    assert!(model
        .rows
        .iter()
        .any(|r| r.id == "grokbot" && r.status == "unavailable"));
    assert!(model
        .rows
        .iter()
        .any(|r| r.id == "muse" && r.status == "unavailable"));
}
