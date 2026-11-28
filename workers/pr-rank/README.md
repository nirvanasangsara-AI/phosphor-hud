# Public PR rank table

This worker builds `GET /rank.json` for Phosphor's individual rank line. It is not deployed by CI.

The app ships `snapshot/rank.json`, built by `node src/snapshot.mjs` from the 2026-11-28 fits. Every public count from 1 to 1000 has a rank. The weekly cron replaces that file in KV when a fresh sample is large enough to fit. Until the worker URL is set, Phosphor shows the snapshot.

## What a run does

Once a week the cron downloads about 1% of the GH Archive hours in the last 7 days (`https://data.gharchive.org/YYYY-MM-DD-H.json.gz`). It counts `PullRequestEvent` actions of `opened`, drops logins ending in `[bot]`, `-bot`, or `_bot`, and drops accounts whose scaled week is 1,000 pull requests or more. Author counts are scaled by `hours in the window / hours actually read`.

A lognormal and a power law with a median cutoff are fit to the scaled counts. The low and high bounds are where those two fits disagree. A sample of fewer than 100 human authors does not replace the table.

GitHub search `type:pr is:public created:>=DATE` is recorded next to the table. Its `total_count` stops at 1,000, so it is not used as the scale factor.

An hour file larger than 20 MB is skipped. One hour of the public archive is often larger than a Worker can hold, so a cron run may store nothing. The shipped snapshot stays in the app either way.

## Deploy

```bash
cd workers/pr-rank
npm test
npx wrangler kv namespace create PR_RANK
```

Paste the namespace id into `wrangler.toml` in place of `REPLACE_WITH_KV_NAMESPACE_ID`. Then:

```bash
npx wrangler deploy
```

Put the `https://<worker>/rank.json` URL in Phosphor's rank-table setting. When that URL is set and the fetch fails, the rank line is hidden. When the URL is empty, the app shows the dated snapshot.
