use phosphor_core::sync::{self, HttpRead, PhoneRow, PhoneSnapshot, PhoneWindow, SyncInner};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

fn empty_state(code: &str, until: f64) -> SyncInner {
    SyncInner {
        code: code.into(),
        code_until: until,
        tokens: Default::default(),
        host_name: "Demo".into(),
        snapshot: sample_body(),
        token_file: None,
    }
}

fn sample_body() -> String {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/sync/sample-snapshot.json");
    std::fs::read_to_string(path).unwrap()
}

#[test]
fn sample_snapshot_is_the_demo_shape() {
    let snap: PhoneSnapshot = serde_json::from_str(&sample_body()).unwrap();
    assert_eq!(snap.version, 1);
    assert_eq!(snap.host_name, "Demo");
    assert_eq!(snap.rows[0].name, "Claude Code");
    assert_eq!(snap.rows[0].windows[0].used_percent, 62.0);
    assert!(!snap.rows[0].windows[0].warns);
}

#[test]
fn bad_code_and_missing_token_are_refused() {
    let mut state = empty_state("482913", 1_000.0);
    let bad = sync::RawRequest {
        method: "POST".into(),
        path: "/v1/pair".into(),
        headers: Default::default(),
        body: br#"{"code":"000000"}"#.to_vec(),
    };
    let (status, _) = sync::handle(&bad, &mut state, 10.0, || "tok".into());
    assert_eq!(status, 401);
    assert!(state.tokens.is_empty());

    let snap = sync::RawRequest {
        method: "GET".into(),
        path: "/v1/snapshot".into(),
        headers: Default::default(),
        body: Vec::new(),
    };
    let (status, body) = sync::handle(&snap, &mut state, 10.0, || "tok".into());
    assert_eq!(status, 401);
    assert!(!body.contains("Claude"));
}

#[test]
fn pair_once_then_snapshot_and_code_is_spent() {
    let mut state = empty_state("482913", 1_000.0);
    let req = sync::RawRequest {
        method: "POST".into(),
        path: "/v1/pair".into(),
        headers: Default::default(),
        body: br#"{"code":"482913"}"#.to_vec(),
    };
    let (status, body) = sync::handle(&req, &mut state, 10.0, || "phone-token".into());
    assert_eq!(status, 200);
    assert!(body.contains("phone-token"));
    assert!(state.code.is_empty());
    let (again, _) = sync::handle(&req, &mut state, 10.0, || "other".into());
    assert_eq!(again, 401);

    let mut headers = std::collections::HashMap::new();
    headers.insert("authorization".into(), "Bearer phone-token".into());
    let snap = sync::RawRequest {
        method: "GET".into(),
        path: "/v1/snapshot".into(),
        headers,
        body: Vec::new(),
    };
    let (status, body) = sync::handle(&snap, &mut state, 10.0, || "nope".into());
    assert_eq!(status, 200);
    let parsed: PhoneSnapshot = serde_json::from_str(&body).unwrap();
    assert_eq!(parsed.rows[1].windows[0].used_percent, 18.0);
}

#[test]
fn health_has_no_usage() {
    let mut state = empty_state("111111", 10.0);
    let req = sync::RawRequest {
        method: "GET".into(),
        path: "/v1/health".into(),
        headers: Default::default(),
        body: Vec::new(),
    };
    let (status, body) = sync::handle(&req, &mut state, 1.0, || "x".into());
    assert_eq!(status, 200);
    assert!(body.contains("phosphor"));
    assert!(!body.contains("Claude"));
}

#[test]
fn http_parser_waits_for_the_body() {
    let partial = b"POST /v1/pair HTTP/1.1\r\nContent-Length: 16\r\n\r\n";
    assert!(matches!(sync::read_http(partial), HttpRead::NeedMore));
    let full = b"POST /v1/pair HTTP/1.1\r\nContent-Length: 16\r\n\r\n{\"code\":\"482913\"}";
    match sync::read_http(full) {
        HttpRead::Ready(req) => {
            assert_eq!(req.method, "POST");
            assert_eq!(req.path, "/v1/pair");
            assert_eq!(req.body.len(), 16);
        }
        _ => panic!("expected a full request"),
    }
}

#[test]
fn listener_pairs_on_localhost() {
    let dir = std::env::temp_dir().join(format!("phosphor-sync-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let file = dir.join("phone-sync.json");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    let server = sync::PhoneSync::start("127.0.0.1:0", &file, "Demo", now).unwrap();
    let port = server.port;
    let (code, _) = server.pairing();
    server.set_rows(
        vec![PhoneRow {
            id: "claude".into(),
            name: "Claude Code".into(),
            monogram: "C".into(),
            color: "#D97757".into(),
            plan: Some("Max".into()),
            status: "ok".into(),
            windows: vec![PhoneWindow {
                label: "5H".into(),
                used_percent: 62.0,
                kind: "quota".into(),
                resets_in: Some("1h 40m".into()),
                forecast_text: Some("measuring pace".into()),
                warns: false,
                amount: None,
            }],
        }],
        1_700_000_000.0,
    );
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    let body = format!(r#"{{"code":"{code}"}}"#);
    let req = format!(
        "POST /v1/pair HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(req.as_bytes()).unwrap();
    let mut buf = Vec::new();
    let _ = stream.read_to_end(&mut buf);
    let text = String::from_utf8_lossy(&buf);
    assert!(text.contains("200"), "{text}");
    let token = text.split("\"token\":\"").nth(1).unwrap().split('"').next().unwrap().to_string();
    drop(stream);

    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    let req = format!("GET /v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n\r\n");
    stream.write_all(req.as_bytes()).unwrap();
    let mut buf = Vec::new();
    let _ = stream.read_to_end(&mut buf);
    let text = String::from_utf8_lossy(&buf);
    assert!(text.contains("Claude Code"), "{text}");
    assert!(!text.contains(&token));
}
