import assert from "node:assert/strict";
import test from "node:test";
import { expectedReset } from "./time.mjs";

const posted = new Date("2026-06-01T00:00:00Z");

test("PDT is UTC-7 and EDT is UTC-4", () => {
  assert.equal(expectedReset("Codex reset 07/01/2026 10:00 PDT", posted), "2026-07-01T17:00:00.000Z");
  assert.equal(expectedReset("Claude reset 07/01/2026 10:00 EDT", posted), "2026-07-01T14:00:00.000Z");
  assert.equal(expectedReset("Codex reset 01/15/2026 10:00 PST", posted), "2026-01-15T18:00:00.000Z");
  assert.equal(expectedReset("Claude reset 01/15/2026 10:00 EST", posted), "2026-01-15T15:00:00.000Z");
});

test("generic PT and ET follow the date", () => {
  assert.equal(expectedReset("reset 07/01/2026 10:00 PT", posted), "2026-07-01T17:00:00.000Z");
  assert.equal(expectedReset("reset 01/15/2026 10:00 PT", posted), "2026-01-15T18:00:00.000Z");
  assert.equal(expectedReset("reset 07/01/2026 10:00 ET", posted), "2026-07-01T14:00:00.000Z");
  assert.equal(expectedReset("reset 01/15/2026 10:00 ET", posted), "2026-01-15T15:00:00.000Z");
});

test("KST stays nine hours ahead of UTC", () => {
  assert.equal(expectedReset("until 12-11 07:00 KST", posted), "2026-12-10T22:00:00.000Z");
});
