//! API list prices from LiteLLM's public table. Nothing is guessed.
//! Ported from `Sources/PhosphorCore/Pricing.swift`.

use crate::parsers::TokenUsage;
use regex::Regex;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ModelPrice {
    pub input: f64,
    pub output: f64,
    pub cache_read: Option<f64>,
    pub cache_write: Option<f64>,
}

#[derive(Clone, Debug, Default)]
pub struct PriceTable {
    prices: HashMap<String, ModelPrice>,
}

impl PriceTable {
    pub const SOURCE_URL: &'static str =
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

    pub fn new() -> Self {
        Self::default()
    }

    pub fn from_litellm_json(data: &[u8]) -> Result<Self, String> {
        let root: Value = serde_json::from_slice(data).map_err(|e| e.to_string())?;
        let obj = root.as_object().ok_or("price table is not an object")?;
        let mut prices = HashMap::new();
        for (k, v) in obj {
            if k == "sample_spec" {
                continue;
            }
            let Some(d) = v.as_object() else { continue };
            let Some(i) = d.get("input_cost_per_token").and_then(Value::as_f64) else {
                continue;
            };
            let Some(o) = d.get("output_cost_per_token").and_then(Value::as_f64) else {
                continue;
            };
            prices.insert(
                k.to_lowercase(),
                ModelPrice {
                    input: i,
                    output: o,
                    cache_read: d.get("cache_read_input_token_cost").and_then(Value::as_f64),
                    cache_write: d
                        .get("cache_creation_input_token_cost")
                        .and_then(Value::as_f64),
                },
            );
        }
        Ok(Self { prices })
    }

    pub fn is_empty(&self) -> bool {
        self.prices.is_empty()
    }

    pub fn len(&self) -> usize {
        self.prices.len()
    }

    pub fn price_for(&self, model: &str) -> Option<ModelPrice> {
        for key in candidates(model) {
            if let Some(p) = self.prices.get(&key) {
                return Some(*p);
            }
        }
        self.suffix_match(model)
    }

    fn suffix_match(&self, model: &str) -> Option<ModelPrice> {
        let want = candidates(model)
            .into_iter()
            .next()
            .unwrap_or_else(|| model.to_lowercase());
        if want.is_empty() {
            return None;
        }
        let mut best: Option<(i32, ModelPrice)> = None;
        for (k, p) in &self.prices {
            let last = k.rsplit('/').next().unwrap_or(k.as_str());
            if !(last == want
                || k.ends_with(&format!(".{want}"))
                || k.ends_with(&format!("/{want}")))
            {
                continue;
            }
            let rank = if k == &want || k == &format!("openai/{want}") {
                0
            } else if k.starts_with("openai/")
                || k.starts_with("openai.")
                || k.starts_with("global.openai.")
            {
                1
            } else if k.starts_with("azure/eu/")
                || k.starts_with("azure/apac/")
                || k.starts_with("azure/us/")
            {
                8
            } else {
                4
            };
            if best.map(|(r, _)| rank < r).unwrap_or(true) {
                best = Some((rank, *p));
            }
        }
        best.map(|(_, p)| p)
    }

    pub fn cost(&self, u: &TokenUsage, model: &str) -> Option<f64> {
        if let Some(c) = u.logged_cost {
            return Some(c);
        }
        let p = self.price_for(model)?;
        Some(
            u.input as f64 * p.input
                + u.output as f64 * p.output
                + u.cache_read as f64 * p.cache_read.unwrap_or(p.input)
                + u.cache_write as f64 * p.cache_write.unwrap_or(p.input),
        )
    }
}

pub fn candidates(model: &str) -> Vec<String> {
    let mut m = model.to_lowercase();
    m = m.trim().to_string();
    let mut out = vec![m.clone()];
    if let Some(stripped) = strip_suffix_re(&m, bracket_re()) {
        m = stripped;
        out.push(m.clone());
    }
    if let Some(i) = m.rfind('/') {
        m = m[i + 1..].to_string();
        out.push(m.clone());
    }
    for re in [date8_re(), date_iso_re(), latest_re()] {
        if let Some(stripped) = strip_suffix_re(&m, re) {
            m = stripped;
            out.push(m.clone());
        }
    }
    out.push(format!("anthropic/{m}"));
    out.push(format!("openai/{m}"));
    out.push(format!("gemini/{m}"));
    let mut seen = std::collections::HashSet::new();
    out.retain(|s| seen.insert(s.clone()));
    out
}

fn strip_suffix_re(s: &str, re: &Regex) -> Option<String> {
    let m = re.find(s)?;
    if m.end() != s.len() {
        return None;
    }
    Some(s[..m.start()].to_string())
}

fn bracket_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\[[^\]]*\]$").unwrap())
}
fn date8_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[-@]\d{8}$").unwrap())
}
fn date_iso_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"-\d{4}-\d{2}-\d{2}$").unwrap())
}
fn latest_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"-latest$").unwrap())
}
