import { fitBands, isBot } from "./fit.mjs"

const HOURS = { "7d": 168, "30d": 720 }

function hourStamp(date) {
  return date.toISOString().slice(0, 13).replace("T", "-")
}

function sampleHours(windowHours, fraction = 0.01) {
  const n = Math.max(1, Math.round(windowHours * fraction))
  const now = Date.now()
  const out = []
  for (let i = 0; i < n; i++) {
    const ago = Math.floor(((i + 0.5) / n) * windowHours)
    out.push(new Date(now - ago * 3600 * 1000))
  }
  return out
}

async function countHour(date) {
  const url = `https://data.gharchive.org/${hourStamp(date)}.json.gz`
  const res = await fetch(url)
  if (!res.ok) return new Map()
  const len = Number(res.headers.get("content-length") || 0)
  if (len > 20_000_000) return new Map()
  const stream = res.body.pipeThrough(new DecompressionStream("gzip"))
  const text = await new Response(stream).text()
  const counts = new Map()
  for (const line of text.split("\n")) {
    if (!line.includes("PullRequestEvent")) continue
    let ev
    try { ev = JSON.parse(line) } catch { continue }
    if (ev.type !== "PullRequestEvent") continue
    if (ev.payload?.action !== "opened") continue
    const login = ev.actor?.login
    if (!login || isBot(login, 0)) continue
    counts.set(login, (counts.get(login) || 0) + 1)
  }
  return counts
}

function merge(into, from) {
  for (const [k, v] of from) into.set(k, (into.get(k) || 0) + v)
}

async function searchTotal(sinceIsoDate) {
  const q = encodeURIComponent(`type:pr is:public created:>=${sinceIsoDate}`)
  const res = await fetch(`https://api.github.com/search/issues?q=${q}`, {
    headers: { "User-Agent": "phosphor-pr-rank", Accept: "application/vnd.github+json" },
  })
  if (!res.ok) return { total: null, capped: false }
  const body = await res.json()
  const total = body.total_count
  return { total, capped: total >= 1000 }
}

function sinceDate(hours) {
  return new Date(Date.now() - hours * 3600 * 1000).toISOString().slice(0, 10)
}

async function buildWindow(name) {
  const hours = HOURS[name]
  const picked = sampleHours(hours)
  const counts = new Map()
  let used = 0
  for (const hour of picked) {
    const part = await countHour(hour)
    if (part.size > 0) {
      merge(counts, part)
      used += 1
    }
  }
  const bands = fitBands(counts, used, hours)
  const search = await searchTotal(sinceDate(hours))
  if (!bands) return null
  return {
    hoursSampled: used,
    hoursInWindow: hours,
    githubSearchTotal: search.total,
    githubSearchCappedAt1000: search.capped,
    modelBands: bands,
  }
}

function tableFrom(seven) {
  const top20 = seven.modelBands.find((b) => b.topPercent === 20)
  const top10 = seven.modelBands.find((b) => b.topPercent === 10)
  const top5 = seven.modelBands.find((b) => b.topPercent === 5)
  if (!top20 || !top10 || !top5) return null
  const low = Math.min(top20.countLow, top10.countLow)
  const high = Math.max(top20.countHigh, top10.countHigh)
  return {
    window: "7d",
    builtAt: new Date().toISOString().slice(0, 10),
    bundled: false,
    source: "GH Archive PullRequestEvent opened, 1% of hours, scaled by the sampled-hour fraction. Lognormal and power-law-with-median-cutoff disagree as the low/high bounds. GitHub search total_count is recorded and is capped at 1000, so it is not the scale factor.",
    bands: [{ countLow: low, countHigh: high, topPercentLow: 10, topPercentHigh: 20 }],
    nextTier: { topPercent: 5, perWeekLow: top5.countLow, perWeekHigh: top5.countHigh },
    sample: { hoursSampled: seven.hoursSampled, githubSearchTotal: seven.githubSearchTotal, githubSearchCappedAt1000: seven.githubSearchCappedAt1000 },
  }
}

export default {
  async scheduled(_event, env) {
    const seven = await buildWindow("7d")
    const table = seven && tableFrom(seven)
    if (table) await env.PR_RANK.put("rank.json", JSON.stringify(table))
  },
  async fetch(request, env) {
    const url = new URL(request.url)
    if (url.pathname !== "/rank.json") return new Response("not found", { status: 404 })
    const body = await env.PR_RANK.get("rank.json")
    if (!body) return new Response("rank table not built", { status: 404 })
    return new Response(body, { headers: { "content-type": "application/json" } })
  },
}
