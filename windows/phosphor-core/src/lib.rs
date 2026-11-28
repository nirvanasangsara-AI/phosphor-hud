//! Rust port of the macOS `PhosphorCore` logic used by the Windows HUD.
//!
//! Forecast slopes, alert thresholds, log parsers, price lookup, and the JSON
//! config files follow the Swift sources. Golden fixtures under `fixtures/`
//! lock the numbers so the two builds agree.

pub mod alerts;
pub mod catalog;
pub mod collect;
pub mod config;
pub mod devstats;
pub mod forecast;
pub mod ledger;
pub mod parsers;
pub mod paths;
pub mod pricing;
pub mod quota;
pub mod timeutil;
pub mod token_refresh;

pub use alerts::{
    AlertEngine, AlertMemory, AlertSettings, BillingReading, QuotaReading, UsageAlert,
};
pub use forecast::{Forecast, ForecastKind, ForecastSample, QuotaForecast};
pub use parsers::{LogParsers, TokenUsage, UsageEvent};
pub use pricing::PriceTable;
