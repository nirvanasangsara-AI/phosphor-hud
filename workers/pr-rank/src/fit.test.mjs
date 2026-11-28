import test from "node:test"
import assert from "node:assert/strict"
import { isBot, scaleCounts, fitBands } from "./fit.mjs"

test("bots and thousand-a-week accounts are dropped", () => {
  const raw = new Map([
    ["ada", 2],
    ["dependabot[bot]", 50],
    ["renovate-bot", 3],
    ["flood", 20],
  ])
  const scaled = scaleCounts(raw, 2, 168)
  assert.equal(scaled.length, 1)
  assert.equal(scaled[0], 2 * (168 / 2))
})

test("a short sample does not invent a table", () => {
  assert.equal(fitBands(new Map([["ada", 1]]), 1, 168), null)
})

test("a large sample produces rising thresholds for tighter percentiles", () => {
  const raw = new Map()
  for (let i = 0; i < 400; i++) raw.set("dev" + i, 1 + (i % 17))
  const bands = fitBands(raw, 2, 168)
  assert.ok(bands)
  const byTop = Object.fromEntries(bands.map((b) => [b.topPercent, b]))
  assert.ok(byTop[5].countLow >= byTop[20].countLow)
  assert.ok(byTop[5].countHigh >= byTop[5].countLow)
})
