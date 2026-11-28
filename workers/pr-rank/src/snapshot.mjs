// Builds workers/pr-rank/snapshot/rank.json and Sources/PhosphorCore/PRRankSnapshot.json
// from the 2026-11-28 GH Archive fits (bots excluded, three 1% thinning calibrations).
//
// Top share for count N is the normalised weight of n >= N, over n = 1..10000.
// zipfexp: w(n) = n^(-a) * exp(-lam*n)
// lognorm: w(n) = exp(-(ln n - mu)^2 / (2 s^2)) / n
//
// The rank band is the min and max top share across the six 7-day fits.
// The next-tier week range is the lowest and highest N at which a fit's top share
// first falls to 5% or below.

import { writeFileSync } from "node:fs"

const NMAX = 10000
const fits7 = [
  { kind: "zipf", a: 1.7804638712003178, lam: 0.001785766645945684 },
  { kind: "logn", mu: 0.3209769641591783, s: 1.864100030838061 },
  { kind: "zipf", a: 1.7730532237591499, lam: 0.0015709712569020038 },
  { kind: "logn", mu: 0.4570720678157438, s: 1.8654932057382108 },
  { kind: "zipf", a: 1.7887188696880312, lam: 0.0020385517352983044 },
  { kind: "logn", mu: 0.17926485243462914, s: 1.8626149040108564 },
]

function weights(fit) {
  const w = new Array(NMAX)
  for (let n = 1; n <= NMAX; n++) {
    if (fit.kind === "zipf") w[n - 1] = n ** -fit.a * Math.exp(-fit.lam * n)
    else {
      const ln = Math.log(n)
      w[n - 1] = Math.exp(-((ln - fit.mu) ** 2) / (2 * fit.s * fit.s)) / n
    }
  }
  const z = w.reduce((a, b) => a + b, 0)
  return w.map((x) => x / z)
}

function topShare(w) {
  const share = new Array(NMAX + 1).fill(0)
  let acc = 0
  for (let n = NMAX; n >= 1; n--) {
    acc += w[n - 1]
    share[n] = acc
  }
  return share
}

const shares = fits7.map((fit) => topShare(weights(fit)))

function band(n) {
  const vals = shares.map((s) => s[n] * 100)
  return { low: Math.min(...vals), high: Math.max(...vals) }
}

const bands = []
for (let n = 1; n <= 1000; n++) {
  const b = band(n)
  bands.push({ countLow: n, countHigh: n, topPercentLow: b.low, topPercentHigh: b.high })
}

const crossings = shares.map((s) => {
  for (let n = 1; n <= 1000; n++) if (s[n] * 100 <= 5) return n
  return 1000
})

const table = {
  window: "7d",
  builtAt: "2026-11-28",
  bundled: true,
  source:
    "GH Archive PullRequestEvent opened, bots excluded, 1% thinning. Six 7-day fits dated 2026-11-28: zipfexp w(n)=n^(-a)*exp(-lam*n) and lognorm w(n)=exp(-(ln n-mu)^2/(2s^2))/n, normalised on n=1..10000. Top share is the weight of n>=N. Low/high is the min/max across the three calibrations p=0.01036, 0.009, and 0.012. The weekly worker replaces this file when it publishes.",
  bands,
  nextTier: {
    topPercent: 5,
    perWeekLow: Math.min(...crossings),
    perWeekHigh: Math.max(...crossings),
  },
}

const text = JSON.stringify(table)
writeFileSync(new URL("../snapshot/rank.json", import.meta.url), text)
writeFileSync(new URL("../../../Sources/PhosphorCore/PRRankSnapshot.json", import.meta.url), text)

const b11 = band(11)
const b20 = band(20)
const b25 = band(25)
console.log("N=11", b11.low.toFixed(2), b11.high.toFixed(2))
console.log("N=20", b20.low.toFixed(2), b20.high.toFixed(2))
console.log("N=25", b25.low.toFixed(2), b25.high.toFixed(2))
console.log("next 5%", Math.min(...crossings), Math.max(...crossings))
