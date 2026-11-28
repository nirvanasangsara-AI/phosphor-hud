//! Incremental log scan. Ported from `Sources/PhosphorCore/LogScanner.swift`.
//!
//! File marks for sessions that are merely old are kept, so a later append does
//! not count Codex lines twice. Marks for files that disappeared are dropped.

use crate::parsers::{fnv64, CodexState, LogParsers, TokenUsage, UsageEvent};
use crate::paths::{LogFormat, LogSource};
use crate::pricing::PriceTable;
use crate::timeutil::day_key;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FileMark {
    pub size: u64,
    pub mtime_ms: i64,
    pub offset: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex: Option<CodexState>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UsageLedger {
    pub version: i32,
    pub files: HashMap<String, FileMark>,
    pub days: HashMap<String, HashMap<String, TokenUsage>>,
    pub seen: HashMap<String, Vec<u64>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scanned_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<f64>,
}

impl Default for UsageLedger {
    fn default() -> Self {
        Self {
            version: 1,
            files: HashMap::new(),
            days: HashMap::new(),
            seen: HashMap::new(),
            scanned_at: None,
            since: None,
        }
    }
}

impl UsageLedger {
    pub fn load(path: &Path) -> Self {
        let Ok(data) = fs::read(path) else {
            return Self::default();
        };
        serde_json::from_slice(&data).unwrap_or_default()
    }

    pub fn save(&self, path: &Path) {
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(data) = serde_json::to_vec_pretty(self) {
            let _ = fs::write(path, data);
        }
    }

    pub fn add(&mut self, e: &UsageEvent, tz_offset_secs: i32, seen_set: &mut HashSet<u64>) {
        let day = day_key(e.date, tz_offset_secs);
        if let Some(k) = &e.dedupe_key {
            let h = fnv64(k);
            if !seen_set.insert(h) {
                return;
            }
            self.seen.entry(day.clone()).or_default().push(h);
        }
        let row = self.days.entry(day).or_default();
        let key = format!("{}|{}", e.source, e.model);
        row.entry(key).or_default().add(&e.usage);
    }

    pub fn prune(&mut self, keep_days: i64, now: f64, tz_offset_secs: i32) {
        let cutoff = day_key(now - keep_days as f64 * 86_400.0, tz_offset_secs);
        self.days.retain(|k, _| k.as_str() >= cutoff.as_str());
        self.seen.retain(|k, _| k.as_str() >= cutoff.as_str());
    }

    pub fn summary(
        &self,
        last_days: i64,
        source: Option<&str>,
        prices: &PriceTable,
        now: f64,
        tz_offset_secs: i32,
    ) -> UsageSummary {
        let cutoff = day_key(
            now - (last_days - 1).max(0) as f64 * 86_400.0,
            tz_offset_secs,
        );
        let mut s = UsageSummary::default();
        for t in self.daily_totals(prices) {
            if t.day.as_str() >= cutoff.as_str()
                && source.map(|src| src == t.source).unwrap_or(true)
            {
                s.tokens += t.tokens;
                s.cost += t.cost;
                s.unpriced_tokens += t.unpriced_tokens;
            }
        }
        s
    }

    pub fn daily_totals(&self, prices: &PriceTable) -> Vec<DayTotal> {
        let mut out = Vec::new();
        for (day, rows) in &self.days {
            let mut by_source: HashMap<String, DayTotal> = HashMap::new();
            for (key, u) in rows {
                let (source, model) = key.split_once('|').unwrap_or((key.as_str(), "unknown"));
                let t = by_source
                    .entry(source.to_string())
                    .or_insert_with(|| DayTotal {
                        day: day.clone(),
                        source: source.to_string(),
                        tokens: 0,
                        cost: 0.0,
                        unpriced_tokens: 0,
                    });
                t.tokens += u.total();
                if let Some(c) = prices.cost(u, model) {
                    t.cost += c;
                } else {
                    t.unpriced_tokens += u.total();
                }
            }
            out.extend(by_source.into_values());
        }
        out.sort_by(|a, b| (&a.day, &a.source).cmp(&(&b.day, &b.source)));
        out
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct UsageSummary {
    pub tokens: i64,
    pub cost: f64,
    pub unpriced_tokens: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DayTotal {
    pub day: String,
    pub source: String,
    pub tokens: i64,
    pub cost: f64,
    pub unpriced_tokens: i64,
}

pub struct LogScanner {
    pub sources: Vec<LogSource>,
    pub window_days: i64,
    pub initial_days: i64,
    pub tz_offset_secs: i32,
}

impl LogScanner {
    pub fn scan(&self, ledger: &mut UsageLedger, now: f64) {
        if ledger.since.is_none() {
            ledger.since = Some(match ledger.scanned_at {
                Some(t) => t - self.window_days as f64 * 86_400.0,
                None => now - self.initial_days as f64 * 86_400.0,
            });
        }
        let since = ledger.since.unwrap_or(now);
        let cutoff = since.max(now - self.window_days as f64 * 86_400.0);
        let mut seen_set: HashSet<u64> = ledger.seen.values().flatten().copied().collect();
        let mut considered: HashSet<String> = HashSet::new();
        for src in &self.sources {
            for root in &src.roots {
                if !root.is_dir() {
                    continue;
                }
                let mut files = Vec::new();
                collect_files(root, &src.file_suffix, &mut files, 0);
                for path in files {
                    let Ok(meta) = fs::metadata(&path) else {
                        continue;
                    };
                    if !meta.is_file() {
                        continue;
                    }
                    let Ok(modified) = meta.modified() else {
                        continue;
                    };
                    let mtime = modified
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs_f64())
                        .unwrap_or(0.0);
                    let key = path.to_string_lossy().to_string();
                    considered.insert(key.clone());
                    if mtime < cutoff {
                        continue;
                    }
                    let size = meta.len();
                    let mtime_ms = (mtime * 1000.0) as i64;
                    let mut mark = ledger.files.get(&key).cloned().unwrap_or(FileMark {
                        size: 0,
                        mtime_ms: 0,
                        offset: 0,
                        codex: None,
                    });
                    if mark.size == size && mark.mtime_ms == mtime_ms {
                        continue;
                    }
                    if size < mark.offset {
                        mark.offset = 0;
                        mark.codex = None;
                    }
                    if src.whole_file {
                        if let Some(events) = read_whole(&path, src) {
                            for e in events {
                                if e.date >= cutoff {
                                    ledger.add(&e, self.tz_offset_secs, &mut seen_set);
                                }
                            }
                        }
                        mark.offset = size;
                    } else {
                        let mut codex = mark.codex.clone().unwrap_or_default();
                        mark.offset = read_lines(&path, mark.offset, src, &mut codex, |e| {
                            if e.date >= cutoff {
                                ledger.add(e, self.tz_offset_secs, &mut seen_set);
                            }
                        });
                        if src.format == LogFormat::Codex {
                            mark.codex = Some(codex);
                        }
                    }
                    mark.size = size;
                    mark.mtime_ms = mtime_ms;
                    ledger.files.insert(key, mark);
                }
            }
        }
        ledger.files.retain(|k, _| considered.contains(k));
        ledger.prune(self.window_days.max(60), now, self.tz_offset_secs);
        ledger.scanned_at = Some(now);
    }
}

fn collect_files(dir: &Path, suffix: &str, out: &mut Vec<PathBuf>, depth: usize) {
    if depth > 8 || out.len() > 4_000 {
        return;
    }
    let Ok(rd) = fs::read_dir(dir) else { return };
    for ent in rd.flatten() {
        let name = ent.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') {
            continue;
        }
        let path = ent.path();
        let Ok(ft) = ent.file_type() else { continue };
        if ft.is_symlink() {
            continue;
        }
        if ft.is_dir() {
            collect_files(&path, suffix, out, depth + 1);
        } else if ft.is_file() && name.ends_with(suffix) {
            out.push(path);
        }
    }
}

fn read_whole(path: &Path, src: &LogSource) -> Option<Vec<UsageEvent>> {
    let data = fs::read(path).ok()?;
    if data.len() > 32 * 1024 * 1024 {
        return None;
    }
    let arr: Vec<serde_json::Value> = serde_json::from_slice(&data).ok()?;
    let task = path
        .parent()
        .and_then(|p| p.file_name())
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    Some(LogParsers::cline_task(&arr, &src.id, &task))
}

fn read_lines(
    path: &Path,
    start: u64,
    src: &LogSource,
    codex: &mut CodexState,
    mut emit: impl FnMut(&UsageEvent),
) -> u64 {
    let Ok(mut fh) = File::open(path) else {
        return start;
    };
    if fh.seek(SeekFrom::Start(start)).is_err() {
        return start;
    }
    let needles: Vec<&[u8]> = src.needles.iter().map(|s| s.as_bytes()).collect();
    let mut offset = start;
    let mut carry: Vec<u8> = Vec::new();
    let mut read_budget = 32 * 1024 * 1024u64;
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        if read_budget == 0 {
            break;
        }
        let n = match fh.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(_) => break,
        };
        let take = (n as u64).min(read_budget) as usize;
        carry.extend_from_slice(&buf[..take]);
        read_budget -= take as u64;
        let Some(last_nl) = carry.iter().rposition(|b| *b == b'\n') else {
            if take < n {
                break;
            }
            continue;
        };
        let complete_len = last_nl + 1;
        let complete = carry[..last_nl].to_vec();
        for line in matching_lines(&complete, &needles) {
            let Ok(obj) = serde_json::from_slice::<serde_json::Value>(line) else {
                continue;
            };
            let event = match src.format {
                LogFormat::Claude => LogParsers::claude(&obj),
                LogFormat::Codex => LogParsers::codex(&obj, codex),
                LogFormat::Gemini => LogParsers::gemini(&obj),
                LogFormat::Cline => None,
            };
            if let Some(e) = event {
                emit(&e);
            }
        }
        offset += complete_len as u64;
        let rest = carry[complete_len..].to_vec();
        carry = rest;
        if take < n {
            break;
        }
    }
    offset
}

pub fn matching_lines<'a>(buf: &'a [u8], needles: &[&[u8]]) -> Vec<&'a [u8]> {
    if needles.is_empty() {
        return split_lines(buf);
    }
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    let mut starts = HashSet::new();
    for needle in needles {
        if needle.is_empty() {
            continue;
        }
        let mut pos = 0;
        while pos < buf.len() {
            let Some(rel) = find_subslice(&buf[pos..], needle) else {
                break;
            };
            let at = pos + rel;
            let mut s = at;
            while s > 0 && buf[s - 1] != b'\n' {
                s -= 1;
            }
            let mut e = at;
            while e < buf.len() && buf[e] != b'\n' {
                e += 1;
            }
            if starts.insert(s) {
                ranges.push((s, e));
            }
            pos = e + 1;
        }
    }
    ranges.sort_unstable();
    ranges.into_iter().map(|(s, e)| &buf[s..e]).collect()
}

fn split_lines(buf: &[u8]) -> Vec<&[u8]> {
    buf.split(|b| *b == b'\n')
        .filter(|l| !l.is_empty())
        .collect()
}

fn find_subslice(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}
