//! Session-log parsers. Only usage fields are kept; message text is dropped.
//! Ported from `Sources/PhosphorCore/LogParsers.swift` and `TokenUsage.swift`.

use crate::timeutil::{json_f64, json_i64, parse_iso};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub logged_cost: Option<f64>,
}

impl TokenUsage {
    pub fn new(
        input: i64,
        output: i64,
        cache_read: i64,
        cache_write: i64,
        logged_cost: Option<f64>,
    ) -> Self {
        Self {
            input,
            output,
            cache_read,
            cache_write,
            logged_cost,
        }
    }

    pub fn total(&self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_write
    }

    pub fn is_zero(&self) -> bool {
        self.total() == 0 && self.logged_cost.unwrap_or(0.0) == 0.0
    }

    pub fn add(&mut self, other: &TokenUsage) {
        let cost = match (self.logged_cost, other.logged_cost) {
            (None, None) => None,
            (a, b) => Some(a.unwrap_or(0.0) + b.unwrap_or(0.0)),
        };
        self.input += other.input;
        self.output += other.output;
        self.cache_read += other.cache_read;
        self.cache_write += other.cache_write;
        self.logged_cost = cost;
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct UsageEvent {
    pub source: String,
    pub model: String,
    pub date: f64,
    pub usage: TokenUsage,
    pub dedupe_key: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexCounters {
    #[serde(default)]
    pub input: i64,
    #[serde(default)]
    pub cached: i64,
    #[serde(default)]
    pub cache_write: i64,
    #[serde(default)]
    pub output: i64,
}

impl CodexCounters {
    fn from_obj(d: &Value) -> Self {
        let obj = d.as_object();
        let get = |k: &str| obj.and_then(|o| o.get(k)).map(json_i64).unwrap_or(0);
        Self {
            input: get("input_tokens"),
            cached: get("cached_input_tokens"),
            cache_write: get("cache_write_input_tokens"),
            output: get("output_tokens"),
        }
    }

    fn minus(&self, other: &Self) -> Option<Self> {
        let r = Self {
            input: self.input - other.input,
            cached: self.cached - other.cached,
            cache_write: self.cache_write - other.cache_write,
            output: self.output - other.output,
        };
        if r.input < 0 || r.cached < 0 || r.cache_write < 0 || r.output < 0 {
            None
        } else {
            Some(r)
        }
    }

    fn usage(&self) -> TokenUsage {
        TokenUsage::new(
            (self.input - self.cached).max(0),
            self.output,
            self.cached,
            self.cache_write,
            None,
        )
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct CodexState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last: Option<CodexCounters>,
}

pub struct LogParsers;

impl LogParsers {
    pub fn claude(obj: &Value) -> Option<UsageEvent> {
        let msg = obj.get("message")?.as_object()?;
        let u = msg.get("usage")?;
        let ts = obj.get("timestamp")?.as_str()?;
        let date = parse_iso(ts)?;
        let model = msg
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        if model == "<synthetic>" {
            return None;
        }
        let usage = TokenUsage::new(
            json_i64(&u.get("input_tokens").cloned().unwrap_or(Value::Null)),
            json_i64(&u.get("output_tokens").cloned().unwrap_or(Value::Null)),
            json_i64(
                &u.get("cache_read_input_tokens")
                    .cloned()
                    .unwrap_or(Value::Null),
            ),
            json_i64(
                &u.get("cache_creation_input_tokens")
                    .cloned()
                    .unwrap_or(Value::Null),
            ),
            None,
        );
        if usage.is_zero() {
            return None;
        }
        let dedupe_key = msg.get("id").and_then(Value::as_str).map(|id| {
            let req = obj.get("requestId").and_then(Value::as_str).unwrap_or("");
            format!("claude:{id}:{req}")
        });
        Some(UsageEvent {
            source: "claude".into(),
            model: model.into(),
            date,
            usage,
            dedupe_key,
        })
    }

    pub fn codex(obj: &Value, state: &mut CodexState) -> Option<UsageEvent> {
        let type_ = obj.get("type")?.as_str()?;
        let payload = obj.get("payload")?;
        if type_ == "turn_context" {
            if let Some(m) = payload.get("model").and_then(Value::as_str) {
                state.model = Some(m.to_string());
            }
            return None;
        }
        if type_ != "event_msg"
            || payload.get("type").and_then(Value::as_str) != Some("token_count")
        {
            return None;
        }
        let info = payload.get("info")?.as_object()?;
        let total = info.get("total_token_usage")?;
        if total.is_null() {
            return None;
        }
        let ts = obj.get("timestamp")?.as_str()?;
        let date = parse_iso(ts)?;
        let now = CodexCounters::from_obj(total);
        let delta = if let Some(last) = &state.last {
            if let Some(d) = now.minus(last) {
                d
            } else if let Some(l) = info.get("last_token_usage") {
                CodexCounters::from_obj(l)
            } else {
                CodexCounters::default()
            }
        } else {
            now.clone()
        };
        state.last = Some(now);
        let usage = delta.usage();
        if usage.is_zero() {
            return None;
        }
        Some(UsageEvent {
            source: "codex".into(),
            model: state.model.clone().unwrap_or_else(|| "unknown".into()),
            date,
            usage,
            dedupe_key: None,
        })
    }

    pub fn gemini(obj: &Value) -> Option<UsageEvent> {
        if obj.get("type").and_then(Value::as_str) != Some("gemini") {
            return None;
        }
        let t = obj.get("tokens")?;
        let ts = obj.get("timestamp")?.as_str()?;
        let date = parse_iso(ts)?;
        let cached = json_i64(&t.get("cached").cloned().unwrap_or(Value::Null));
        let usage = TokenUsage::new(
            (json_i64(&t.get("input").cloned().unwrap_or(Value::Null)) - cached).max(0),
            json_i64(&t.get("output").cloned().unwrap_or(Value::Null))
                + json_i64(&t.get("thoughts").cloned().unwrap_or(Value::Null)),
            cached,
            0,
            None,
        );
        if usage.is_zero() {
            return None;
        }
        let dedupe_key = obj
            .get("id")
            .and_then(Value::as_str)
            .map(|id| format!("gemini:{id}"));
        Some(UsageEvent {
            source: "gemini".into(),
            model: obj
                .get("model")
                .and_then(Value::as_str)
                .unwrap_or("gemini")
                .into(),
            date,
            usage,
            dedupe_key,
        })
    }

    pub fn cline_task(messages: &[Value], source: &str, task_id: &str) -> Vec<UsageEvent> {
        let mut out = Vec::new();
        for m in messages {
            if m.get("say").and_then(Value::as_str) != Some("api_req_started") {
                continue;
            }
            let Some(text) = m.get("text").and_then(Value::as_str) else {
                continue;
            };
            let Some(ts) = m.get("ts").and_then(json_f64) else {
                continue;
            };
            let Ok(info) = serde_json::from_str::<Value>(text) else {
                continue;
            };
            let cost = info.get("cost").and_then(json_f64);
            let usage = TokenUsage::new(
                json_i64(&info.get("tokensIn").cloned().unwrap_or(Value::Null)),
                json_i64(&info.get("tokensOut").cloned().unwrap_or(Value::Null)),
                json_i64(&info.get("cacheReads").cloned().unwrap_or(Value::Null)),
                json_i64(&info.get("cacheWrites").cloned().unwrap_or(Value::Null)),
                cost,
            );
            if usage.is_zero() {
                continue;
            }
            out.push(UsageEvent {
                source: source.into(),
                model: info
                    .get("model")
                    .and_then(Value::as_str)
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| format!("{source} (logged cost)")),
                date: ts / 1000.0,
                usage,
                dedupe_key: Some(format!("{source}:{task_id}:{}", ts as i64)),
            });
        }
        out
    }
}

pub fn fnv64(s: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}
