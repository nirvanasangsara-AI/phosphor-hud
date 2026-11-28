//! Same-Wi-Fi snapshot server for the Android app.
//!
//! The listener is off until the desktop turns it on. Usage numbers stay in
//! memory. The only thing written down is the pairing token list, so a phone
//! that already paired keeps working after a restart.

use crate::collect::{HudModel, WindowView};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

pub const DEFAULT_PORT: u16 = 47321;
const CODE_TTL: f64 = 10.0 * 60.0;
const MAX_TOKENS: usize = 8;
const MAX_HTTP: usize = 65_536;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhoneWindow {
    pub label: String,
    pub used_percent: f64,
    pub kind: String,
    pub resets_in: Option<String>,
    pub forecast_text: Option<String>,
    pub warns: bool,
    pub amount: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhoneRow {
    pub id: String,
    pub name: String,
    pub monogram: String,
    pub color: String,
    pub plan: Option<String>,
    pub status: String,
    pub windows: Vec<PhoneWindow>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhoneSnapshot {
    pub version: i32,
    pub generated_at: String,
    pub host_name: String,
    pub rows: Vec<PhoneRow>,
}

impl PhoneSnapshot {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".into())
    }
}

/// Rows the phone is allowed to see. Desktop messages and paths stay behind.
pub fn rows_from_hud(model: &HudModel) -> Vec<PhoneRow> {
    model
        .rows
        .iter()
        .filter(|r| r.status == "ok" || r.status == "idle")
        .filter(|r| !r.windows.is_empty())
        .take(12)
        .map(|r| PhoneRow {
            id: r.id.clone(),
            name: r.name.clone(),
            monogram: r.monogram.clone(),
            color: r.color.clone(),
            plan: r.plan.clone(),
            status: r.status.clone(),
            windows: r.windows.iter().take(6).map(window_from_view).collect(),
        })
        .collect()
}

fn window_from_view(w: &WindowView) -> PhoneWindow {
    PhoneWindow {
        label: w.label.clone(),
        used_percent: w.used_percent,
        kind: w.kind.clone(),
        resets_in: w.resets_in.clone(),
        forecast_text: w.forecast_text.clone(),
        warns: w.warns,
        amount: w.amount.clone(),
    }
}

pub fn iso_utc(epoch: f64) -> String {
    chrono::DateTime::from_timestamp(epoch as i64, 0)
        .map(|d| d.format("%Y-%m-%dT%H:%M:%SZ").to_string())
        .unwrap_or_else(|| "1970-01-01T00:00:00Z".into())
}

#[derive(Clone, Debug)]
pub struct SyncInner {
    pub code: String,
    pub code_until: f64,
    pub tokens: HashSet<String>,
    pub host_name: String,
    pub snapshot: String,
    pub token_file: Option<std::path::PathBuf>,
}

#[derive(Clone, Debug)]
pub struct RawRequest {
    pub method: String,
    pub path: String,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

pub enum HttpRead {
    NeedMore,
    Bad,
    Ready(RawRequest),
}

pub fn read_http(buf: &[u8]) -> HttpRead {
    if buf.len() > MAX_HTTP {
        return HttpRead::Bad;
    }
    let Some(split) = find_header_end(buf) else {
        return HttpRead::NeedMore;
    };
    let head = &buf[..split];
    let rest = &buf[split + 4..];
    let text = String::from_utf8_lossy(head);
    let mut lines = text.split("\r\n");
    let Some(start) = lines.next() else {
        return HttpRead::Bad;
    };
    let mut parts = start.split(' ');
    let (Some(method), Some(target)) = (parts.next(), parts.next()) else {
        return HttpRead::Bad;
    };
    let path = target.split('?').next().unwrap_or(target).to_string();
    let mut headers = HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let need = headers
        .get("content-length")
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(0);
    if need > MAX_HTTP {
        return HttpRead::Bad;
    }
    if rest.len() < need {
        return HttpRead::NeedMore;
    }
    HttpRead::Ready(RawRequest {
        method: method.to_string(),
        path,
        headers,
        body: rest[..need].to_vec(),
    })
}

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

pub fn handle(req: &RawRequest, state: &mut SyncInner, now: f64, issue_token: impl FnOnce() -> String) -> (u16, String) {
    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/v1/health") => (200, json!({"ok": true, "service": "phosphor"}).to_string()),
        ("POST", "/v1/pair") => pair(req, state, now, issue_token),
        ("GET", "/v1/snapshot") => snapshot(req, state),
        _ => (404, json!({"error": "not_found"}).to_string()),
    }
}

fn pair(req: &RawRequest, state: &mut SyncInner, now: f64, issue_token: impl FnOnce() -> String) -> (u16, String) {
    let Ok(body) = serde_json::from_slice::<Value>(&req.body) else {
        return (400, json!({"error": "bad_code"}).to_string());
    };
    let Some(code) = body.get("code").and_then(Value::as_str) else {
        return (400, json!({"error": "bad_code"}).to_string());
    };
    if state.code.is_empty() || now > state.code_until || !ct_eq(code, &state.code) {
        return (401, json!({"error": "bad_code"}).to_string());
    }
    let token = issue_token();
    state.code.clear();
    state.code_until = 0.0;
    if state.tokens.len() >= MAX_TOKENS {
        if let Some(old) = state.tokens.iter().next().cloned() {
            state.tokens.remove(&old);
        }
    }
    state.tokens.insert(token.clone());
    save_tokens(state);
    (200, json!({"token": token}).to_string())
}

fn snapshot(req: &RawRequest, state: &SyncInner) -> (u16, String) {
    let header = req.headers.get("authorization").map(String::as_str).unwrap_or("");
    let Some(token) = header.strip_prefix("Bearer ") else {
        return (401, json!({"error": "unauthorized"}).to_string());
    };
    if !state.tokens.iter().any(|t| ct_eq(t, token.trim())) {
        return (401, json!({"error": "unauthorized"}).to_string());
    }
    (200, state.snapshot.clone())
}

fn ct_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.bytes().zip(b.bytes()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn save_tokens(state: &SyncInner) {
    let Some(path) = &state.token_file else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let list: Vec<&String> = state.tokens.iter().collect();
    if let Ok(data) = serde_json::to_vec(&json!({"tokens": list})) {
        let _ = fs::write(path, data);
    }
}

pub fn load_tokens(path: &Path) -> HashSet<String> {
    let Ok(data) = fs::read(path) else {
        return HashSet::new();
    };
    let Ok(v) = serde_json::from_slice::<Value>(&data) else {
        return HashSet::new();
    };
    v.get("tokens")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default()
}

pub fn random_code() -> String {
    let mut b = [0u8; 4];
    let _ = getrandom::getrandom(&mut b);
    let n = u32::from_le_bytes(b) % 1_000_000;
    format!("{n:06}")
}

pub fn random_token() -> String {
    let mut b = [0u8; 32];
    let _ = getrandom::getrandom(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub fn encode_response(status: u16, body: &str) -> Vec<u8> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        _ => "Not Found",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let mut out = head.into_bytes();
    out.extend_from_slice(body.as_bytes());
    out
}

pub struct PhoneSync {
    inner: Arc<Mutex<SyncInner>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    pub port: u16,
}

impl PhoneSync {
    pub fn start(bind: &str, token_file: &Path, host_name: &str, now: f64) -> std::io::Result<Self> {
        let listener = TcpListener::bind(bind)?;
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        let code = random_code();
        let inner = Arc::new(Mutex::new(SyncInner {
            code: code.clone(),
            code_until: now + CODE_TTL,
            tokens: load_tokens(token_file),
            host_name: host_name.to_string(),
            snapshot: PhoneSnapshot {
                version: 1,
                generated_at: iso_utc(now),
                host_name: host_name.to_string(),
                rows: Vec::new(),
            }
            .to_json(),
            token_file: Some(token_file.to_path_buf()),
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let inner_t = inner.clone();
        let stop_t = stop.clone();
        let thread = thread::spawn(move || accept_loop(listener, inner_t, stop_t));
        Ok(Self {
            inner,
            stop,
            thread: Some(thread),
            port,
        })
    }

    pub fn set_rows(&self, rows: Vec<PhoneRow>, now: f64) {
        if let Ok(mut g) = self.inner.lock() {
            let snap = PhoneSnapshot {
                version: 1,
                generated_at: iso_utc(now),
                host_name: g.host_name.clone(),
                rows,
            };
            g.snapshot = snap.to_json();
        }
    }

    pub fn pairing(&self) -> (String, f64) {
        self.inner
            .lock()
            .map(|g| (g.code.clone(), g.code_until))
            .unwrap_or_default()
    }

    pub fn rotate_code(&self, now: f64) {
        if let Ok(mut g) = self.inner.lock() {
            g.code = random_code();
            g.code_until = now + CODE_TTL;
        }
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for PhoneSync {
    fn drop(&mut self) {
        self.stop();
    }
}

fn accept_loop(listener: TcpListener, inner: Arc<Mutex<SyncInner>>, stop: Arc<AtomicBool>) {
    while !stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => {
                let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
                let _ = stream.set_write_timeout(Some(Duration::from_secs(3)));
                serve_one(stream, &inner);
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(40));
            }
            Err(_) => thread::sleep(Duration::from_millis(40)),
        }
    }
}

fn serve_one(mut stream: TcpStream, inner: &Mutex<SyncInner>) {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 2048];
    let req = loop {
        match stream.read(&mut tmp) {
            Ok(0) => return,
            Ok(n) => {
                buf.extend_from_slice(&tmp[..n]);
                match read_http(&buf) {
                    HttpRead::NeedMore => continue,
                    HttpRead::Bad => return,
                    HttpRead::Ready(req) => break req,
                }
            }
            Err(_) => return,
        }
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let (status, body) = {
        let Ok(mut state) = inner.lock() else {
            return;
        };
        handle(&req, &mut state, now, random_token)
    };
    let _ = stream.write_all(&encode_response(status, &body));
}

pub fn lan_ip() -> String {
    let Ok(sock) = std::net::UdpSocket::bind("0.0.0.0:0") else {
        return "127.0.0.1".into();
    };
    if sock.connect("192.0.2.1:80").is_err() {
        return "127.0.0.1".into();
    }
    match sock.local_addr() {
        Ok(addr) => addr.ip().to_string(),
        Err(_) => "127.0.0.1".into(),
    }
}

pub fn pair_link(host: &str, port: u16, code: &str) -> String {
    format!("phosphor://pair?v=1&host={host}&port={port}&code={code}")
}
