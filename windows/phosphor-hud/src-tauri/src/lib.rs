//! Windows shell. Reads local CLI files through phosphor-core and, when a token
//! file is already there, asks that provider's own usage API. Tokens are not
//! logged, stored, or shown.

use phosphor_core::collect::{load_hud, HudModel, HudOptions, TransportError, UsageTransport};
use phosphor_core::devstats::{self, DevCounts};
use phosphor_core::paths;
use phosphor_core::pricing::PriceTable;
use phosphor_core::timeutil;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, State, WebviewWindow};
use tauri_plugin_autostart::ManagerExt;

struct Prefs {
    demo: Mutex<bool>,
    show_dev: Mutex<bool>,
}

#[derive(Default, Serialize, Deserialize)]
struct PrefFile {
    #[serde(default)]
    demo: bool,
    #[serde(default)]
    show_dev: bool,
}

struct Net;

impl UsageTransport for Net {
    fn get_json(&self, url: &str, headers: &[(&str, String)]) -> Result<Value, TransportError> {
        if !allowed(url) {
            return Err(TransportError::Other(
                "that address is not a provider usage endpoint".into(),
            ));
        }
        let timeout = if url.starts_with("http://127.0.0.1") || url.starts_with("http://localhost")
        {
            Duration::from_secs(2)
        } else {
            Duration::from_secs(15)
        };
        let agent = ureq::AgentBuilder::new()
            .redirects(0)
            .timeout(timeout)
            .build();
        let mut req = agent.get(url);
        for (k, v) in headers {
            req = req.set(k, v);
        }
        match req.call() {
            Ok(resp) => resp
                .into_json()
                .map_err(|_| TransportError::Other("usage response was not JSON".into())),
            Err(ureq::Error::Status(code, _)) => Err(TransportError::Http(code)),
            Err(_) => Err(TransportError::Other(
                "could not reach the usage service".into(),
            )),
        }
    }

    fn command(&self, command: &str) -> Result<String, TransportError> {
        let output = if cfg!(windows) {
            Command::new("cmd").args(["/C", command]).output()
        } else {
            Command::new("sh").args(["-c", command]).output()
        }
        .map_err(|_| TransportError::Other("could not run the custom provider command".into()))?;
        if !output.status.success() {
            return Err(TransportError::Other(
                "custom provider command failed".into(),
            ));
        }
        String::from_utf8(output.stdout)
            .map_err(|_| TransportError::Other("custom provider command did not print text".into()))
    }

    fn gh_token(&self) -> Result<Option<String>, TransportError> {
        let Some(gh) = find_gh() else {
            return Ok(None);
        };
        let output = Command::new(gh)
            .args(["auth", "token"])
            .output()
            .map_err(|_| TransportError::Other("could not run gh".into()))?;
        if !output.status.success() {
            return Ok(None);
        }
        let token = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if token.is_empty() {
            Ok(None)
        } else {
            Ok(Some(token))
        }
    }
}

fn allowed(url: &str) -> bool {
    const PREFIXES: &[&str] = &[
        "https://api.anthropic.com/",
        "https://chatgpt.com/",
        "https://cli-chat-proxy.grok.com/",
        "https://api.github.com/",
        "http://127.0.0.1:",
        "http://localhost:",
    ];
    PREFIXES.iter().any(|p| url.starts_with(p))
}

fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn home_dir() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn env_map() -> HashMap<String, String> {
    std::env::vars().collect()
}

fn prefs_path(support: &Path) -> PathBuf {
    support.join("prefs.json")
}

fn read_prefs(support: &Path) -> PrefFile {
    std::fs::read(prefs_path(support))
        .ok()
        .and_then(|d| serde_json::from_slice(&d).ok())
        .unwrap_or_default()
}

fn write_prefs(support: &Path, prefs: &PrefFile) {
    if let Some(parent) = prefs_path(support).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(data) = serde_json::to_vec_pretty(prefs) {
        let _ = std::fs::write(prefs_path(support), data);
    }
}

fn support_dir() -> PathBuf {
    let env = env_map();
    paths::phosphor_support_dir(&env, &home_dir())
}

fn build_model(demo: bool, show_dev: bool) -> HudModel {
    let env = env_map();
    let home = home_dir();
    let now = now_secs();
    let tz = timeutil::local_offset_secs(now);
    let support = paths::phosphor_support_dir(&env, &home);
    let config = paths::phosphor_config_dir(&home);
    let prices = load_prices(&paths::price_cache_file(&env, &home));
    let fx = load_fx(&support.join("fx.json"));
    let dev = if show_dev && !demo {
        fetch_dev(&env, now, tz)
    } else {
        None
    };
    load_hud(&HudOptions {
        home: &home,
        env: &env,
        now,
        tz_offset_secs: tz,
        config_dir: &config,
        support_dir: &support,
        prices: &prices,
        fx: &fx,
        transport: &Net,
        demo,
        show_dev,
        dev_counts: dev.as_ref(),
        persist: !demo,
    })
}

fn load_prices(path: &Path) -> PriceTable {
    if stale(path) {
        let _ = std::fs::create_dir_all(path.parent().unwrap_or(Path::new(".")));
        let agent = ureq::AgentBuilder::new()
            .redirects(0)
            .timeout(Duration::from_secs(20))
            .build();
        if let Ok(resp) = agent.get(PriceTable::SOURCE_URL).call() {
            if let Ok(text) = resp.into_string() {
                if text.contains("input_cost_per_token") {
                    let _ = std::fs::write(path, text);
                }
            }
        }
    }
    std::fs::read(path)
        .ok()
        .and_then(|d| PriceTable::from_litellm_json(&d).ok())
        .unwrap_or_default()
}

fn load_fx(path: &Path) -> HashMap<String, f64> {
    if stale(path) {
        let _ = std::fs::create_dir_all(path.parent().unwrap_or(Path::new(".")));
        let agent = ureq::AgentBuilder::new()
            .redirects(0)
            .timeout(Duration::from_secs(15))
            .build();
        if let Ok(resp) = agent.get("https://open.er-api.com/v6/latest/USD").call() {
            if let Ok(text) = resp.into_string() {
                let _ = std::fs::write(path, text);
            }
        }
    }
    let Ok(data) = std::fs::read(path) else {
        return HashMap::new();
    };
    let Ok(v) = serde_json::from_slice::<Value>(&data) else {
        return HashMap::new();
    };
    let Some(rates) = v.get("rates").and_then(Value::as_object) else {
        return HashMap::new();
    };
    rates
        .iter()
        .filter_map(|(k, n)| n.as_f64().map(|n| (k.to_uppercase(), n)))
        .collect()
}

fn stale(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else {
        return true;
    };
    meta.modified()
        .ok()
        .and_then(|t| t.elapsed().ok())
        .map(|d| d.as_secs() > 86_400)
        .unwrap_or(true)
}

fn find_gh() -> Option<PathBuf> {
    let env = env_map();
    if let Some(found) = paths::which(&["gh"], &env) {
        return Some(found);
    }
    for key in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(dir) = env.get(key) {
            let candidate = PathBuf::from(dir).join("GitHub CLI").join("gh.exe");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

fn fetch_dev(env: &HashMap<String, String>, now: f64, tz: i32) -> Option<DevCounts> {
    let gh = find_gh()?;
    let login = command_text(&gh, &["api", "user", "--jq", ".login"])?;
    let login = login.trim();
    if login.is_empty() {
        return None;
    }
    let mut results = HashMap::new();
    for q in devstats::github_queries(login, now, tz) {
        let flag = format!("q={}", q.q);
        let text = command_text(
            &gh,
            &["api", &q.endpoint, "-f", &flag, "--jq", ".total_count"],
        )?;
        results.insert(q.key, text.trim().parse().unwrap_or(0));
    }
    let _ = env;
    Some(DevCounts::from_results(login, &results, now))
}

fn command_text(program: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).to_string())
}

fn hud(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window("hud")
}

fn show_hud_window(app: &AppHandle) {
    if let Some(window) = hud(app) {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

fn hide_hud_window(app: &AppHandle) {
    if let Some(window) = hud(app) {
        let _ = window.hide();
    }
}

#[tauri::command]
fn hud_state(prefs: State<Prefs>) -> HudModel {
    let demo = *prefs.demo.lock().unwrap_or_else(|e| e.into_inner());
    let show_dev = *prefs.show_dev.lock().unwrap_or_else(|e| e.into_inner());
    build_model(demo, show_dev)
}

#[tauri::command]
fn hide_hud(app: AppHandle) {
    hide_hud_window(&app);
}

#[tauri::command]
fn show_hud(app: AppHandle) {
    show_hud_window(&app);
}

#[tauri::command]
fn set_demo(prefs: State<Prefs>, enabled: bool) {
    if let Ok(mut demo) = prefs.demo.lock() {
        *demo = enabled;
    }
    let show_dev = prefs.show_dev.lock().map(|g| *g).unwrap_or(false);
    let demo = prefs.demo.lock().map(|g| *g).unwrap_or(enabled);
    write_prefs(&support_dir(), &PrefFile { demo, show_dev });
}

#[tauri::command]
fn set_show_dev(prefs: State<Prefs>, enabled: bool) {
    if let Ok(mut flag) = prefs.show_dev.lock() {
        *flag = enabled;
    }
    let demo = prefs.demo.lock().map(|g| *g).unwrap_or(false);
    let show_dev = prefs.show_dev.lock().map(|g| *g).unwrap_or(enabled);
    write_prefs(&support_dir(), &PrefFile { demo, show_dev });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let saved = read_prefs(&support_dir());
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(Prefs {
            demo: Mutex::new(saved.demo),
            show_dev: Mutex::new(saved.show_dev),
        })
        .setup(|app| {
            if let Some(window) = app.get_webview_window("hud") {
                let hidden = window.clone();
                window.on_window_event(move |event| {
                    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        let _ = hidden.hide();
                    }
                });
            }
            let show = MenuItem::with_id(app, "show", "Show HUD", true, None::<&str>)?;
            let hide = MenuItem::with_id(app, "hide", "Hide HUD", true, None::<&str>)?;
            let login = MenuItem::with_id(app, "login", "Start at login", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &hide, &login, &quit])?;
            let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/32x32.png"))?;
            let _tray = TrayIconBuilder::with_id("phosphor")
                .menu(&menu)
                .tooltip("Phosphor")
                .icon(icon)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_hud_window(app),
                    "hide" => hide_hud_window(app),
                    "quit" => app.exit(0),
                    "login" => {
                        let auto = app.autolaunch();
                        if auto.is_enabled().unwrap_or(false) {
                            let _ = auto.disable();
                        } else {
                            let _ = auto.enable();
                        }
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("hud") {
                            if window.is_visible().unwrap_or(false) {
                                let _ = window.hide();
                            } else {
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                        }
                    }
                })
                .build(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            hud_state,
            hide_hud,
            show_hud,
            set_demo,
            set_show_dev
        ])
        .run(tauri::generate_context!())
        .expect("error while running Phosphor");
}
