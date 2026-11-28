// Fits a public-PR author distribution from a GH Archive sample.
// Two models, reported as a range: a lognormal on the body, and a power law
// above the median. Bots are dropped before the fit. A sample under 100 authors
// returns null so the worker does not publish a guess.

export function isBot(login, weeklyCount) {
  const name = String(login || "").toLowerCase()
  if (name.endsWith("[bot]") || name.endsWith("-bot") || name.endsWith("_bot")) return true
  if (weeklyCount >= 1000) return true
  return false
}

export function scaleCounts(rawCounts, hoursSampled, hoursInWindow) {
  if (hoursSampled <= 0 || hoursInWindow <= 0) return []
  const scale = hoursInWindow / hoursSampled
  const out = []
  for (const [login, n] of rawCounts) {
    const scaled = n * scale
    if (isBot(login, scaled)) continue
    if (scaled > 0) out.push(scaled)
  }
  return out
}

function mean(xs) {
  return xs.reduce((a, b) => a + b, 0) / xs.length
}

function median(sorted) {
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

// Rational approximation of the standard normal inverse (Acklam).
function invNorm(p) {
  const a = [-3.969683028665376e1, 2.209460984245205e2, -2.759285104469687e2, 1.38357751867269e2, -3.066479806614716e1, 2.506628277459239]
  const b = [-5.447609879822406e1, 1.615858368580409e2, -1.556989798598866e2, 6.680131188771972e1, -1.328068155288572e1]
  const c = [-7.784894002430293e-3, -3.223964580411365e-1, -2.400758277161838, -2.549732539343734, 4.374664141464968, 2.938163982698783]
  const d = [7.784695709041462e-3, 3.224671290700398e-1, 2.445134137142996, 3.754408661907416]
  const plow = 0.02425
  const phigh = 1 - plow
  let q, r
  if (p < plow) {
    q = Math.sqrt(-2 * Math.log(p))
    return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
      ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
  }
  if (p > phigh) {
    q = Math.sqrt(-2 * Math.log(1 - p))
    return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
      ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
  }
  q = p - 0.5
  r = q * q
  return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
    (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
}

function lognormalQuantile(logs, topPercent) {
  const mu = mean(logs)
  const variance = mean(logs.map((x) => (x - mu) ** 2))
  const sigma = Math.sqrt(variance)
  if (!Number.isFinite(sigma) || sigma === 0) return null
  const p = 1 - topPercent / 100
  return Math.exp(mu + sigma * invNorm(p))
}

function powerLawQuantile(sorted, topPercent) {
  const xmin = Math.max(1, median(sorted))
  const tail = sorted.filter((x) => x >= xmin)
  if (tail.length < 30) return null
  const alpha = 1 + tail.length / tail.reduce((s, x) => s + Math.log(x / xmin), 0)
  if (!Number.isFinite(alpha) || alpha <= 1) return null
  const f = tail.length / sorted.length
  const t = topPercent / 100
  if (t >= f) return null
  return xmin / (t / f) ** (1 / (alpha - 1))
}

/** Percentile bands from the two fits. Null when the sample is too small to fit. */
export function fitBands(rawCounts, hoursSampled, hoursInWindow) {
  const counts = scaleCounts(rawCounts, hoursSampled, hoursInWindow).sort((a, b) => a - b)
  if (counts.length < 100) return null
  const logs = counts.map(Math.log)
  const tops = [20, 10, 5]
  const bands = []
  for (const top of tops) {
    const estimates = [lognormalQuantile(logs, top), powerLawQuantile(counts, top)].filter((n) => Number.isFinite(n) && n > 0)
    if (estimates.length === 0) continue
    const low = Math.max(1, Math.floor(Math.min(...estimates)))
    const high = Math.max(low, Math.ceil(Math.max(...estimates)))
    bands.push({ topPercent: top, countLow: low, countHigh: high })
  }
  if (bands.length === 0) return null
  return bands
}
