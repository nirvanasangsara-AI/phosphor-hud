/**
 * Phosphor reset-news feed.
 *
 * Cron (every 15 min) reads official X timelines, a keyword search for unverified posts,
 * and three public status RSS feeds. GET /feed.json serves the cached JSON.
 *
 * Secret: `npx wrangler secret put X_BEARER_TOKEN` (an X API v2 app-only bearer token).
 * The token is never written into the feed.
 */

interface Env {
  RESET_FEED: {
    get(key: string): Promise<string | null>;
    put(key: string, value: string): Promise<void>;
  };
  X_BEARER_TOKEN?: string;
}

type Kind = "official" | "rumor" | "status";

interface FeedItem {
  id: string;
  source: "x" | "status";
  handle: string;
  text: string;
  url: string;
  posted_at: string;
  kind: Kind;
  expected_reset_at: string | null;
  expires_at: string;
  confidence: number;
  official: boolean;
  product: string;
}

const ALLOW = [
  "thsottiaux", "OpenAIDevs", "romainhuet", "simpsoka", "ClaudeDevs", "claudeai",
  "bcherny", "bot", "mattyp", "cursor_ai", "SpaceXSI",
];
const AVOID = ["grok", "xai", "OpenAIStatus"];
const STATUS_FEEDS = [
  "https://status.openai.com/history.rss",
  "https://status.claude.com/history.rss",
  "https://status.x.ai/feed.xml",
];
const RELEVANT = /reset|rate[\s-]?limit|usage limit|limits reset|quota|free reset|capacity/i;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/feed.json") {
      return new Response("phosphor reset feed", { status: 200 });
    }
    let body = await env.RESET_FEED.get("feed");
    if (!body) {
      body = JSON.stringify(await build(env));
      await env.RESET_FEED.put("feed", body);
    }
    return new Response(body, {
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "public, max-age=60",
        "access-control-allow-origin": "*",
      },
    });
  },

  async scheduled(_controller: unknown, env: Env): Promise<void> {
    const body = JSON.stringify(await build(env));
    await env.RESET_FEED.put("feed", body);
  },
};

async function build(env: Env): Promise<{ generated_at: string; items: FeedItem[] }> {
  const now = new Date();
  const items: FeedItem[] = [];
  try {
    items.push(...await xItems(env, now));
  } catch (error) {
    console.log("x feed skipped", error instanceof Error ? error.message : error);
  }
  for (const feed of STATUS_FEEDS) {
    try {
      items.push(...await statusItems(feed, now));
    } catch (error) {
      console.log("status feed skipped", feed, error instanceof Error ? error.message : error);
    }
  }
  return { generated_at: now.toISOString(), items: dedupe(items, now) };
}

async function xItems(env: Env, now: Date): Promise<FeedItem[]> {
  const token = env.X_BEARER_TOKEN;
  if (!token) return [];
  const users = await xJSON(token, `/2/users/by?usernames=${ALLOW.join(",")}`) as {
    data?: { id: string; username: string }[];
  };
  const byId = new Map((users.data ?? []).map((user) => [user.id, user.username]));
  const out: FeedItem[] = [];
  for (const user of users.data ?? []) {
    const timeline = await xJSON(
      token,
      `/2/users/${user.id}/tweets?max_results=5&exclude=retweets,replies&tweet.fields=created_at`,
    ) as { data?: { id: string; text: string; created_at?: string }[] };
    for (const tweet of timeline.data ?? []) {
      if (!RELEVANT.test(tweet.text)) continue;
      out.push(tweetItem(tweet, user.username, "official", now));
    }
  }
  const query = [
    `(reset OR "rate limit" OR "usage limit" OR "limits reset")`,
    `(Codex OR "Claude Code" OR Cursor OR Claude OR Grok)`,
    `-is:retweet -is:reply`,
    ...AVOID.map((name) => `-from:${name}`),
    ...ALLOW.map((name) => `-from:${name}`),
  ].join(" ");
  const search = await xJSON(
    token,
    `/2/tweets/search/recent?max_results=10&tweet.fields=created_at,author_id&expansions=author_id&user.fields=username&query=${encodeURIComponent(query)}`,
  ) as {
    data?: { id: string; text: string; created_at?: string; author_id?: string }[];
    includes?: { users?: { id: string; username: string }[] };
  };
  const names = new Map(byId);
  for (const user of search.includes?.users ?? []) names.set(user.id, user.username);
  for (const tweet of search.data ?? []) {
    const handle = names.get(tweet.author_id ?? "") ?? "unknown";
    if (AVOID.some((name) => name.toLowerCase() === handle.toLowerCase())) continue;
    if (!RELEVANT.test(tweet.text)) continue;
    const official = ALLOW.some((name) => name.toLowerCase() === handle.toLowerCase());
    out.push(tweetItem(tweet, handle, official ? "official" : "rumor", now));
  }
  return out;
}

function tweetItem(
  tweet: { id: string; text: string; created_at?: string },
  handle: string,
  kind: Kind,
  now: Date,
): FeedItem {
  const posted = tweet.created_at ?? now.toISOString();
  const expected = expectedReset(tweet.text, new Date(posted));
  const product = productOf(tweet.text);
  return {
    id: `x:${tweet.id}`,
    source: "x",
    handle,
    text: tweet.text.replace(/\s+/g, " ").trim(),
    url: `https://x.com/${handle}/status/${tweet.id}`,
    posted_at: posted,
    kind,
    expected_reset_at: expected,
    expires_at: expires(posted, expected, kind),
    confidence: kind === "official" ? 0.9 : 0.35,
    official: kind === "official",
    product,
  };
}

async function statusItems(feedURL: string, now: Date): Promise<FeedItem[]> {
  const response = await fetch(feedURL, { headers: { "user-agent": "PhosphorResetFeed" } });
  if (!response.ok) return [];
  const xml = await response.text();
  const host = new URL(feedURL).host;
  const product = host.includes("openai") ? "codex" : host.includes("claude") ? "claude" : "grok";
  const handle = product === "codex" ? "OpenAI" : product === "claude" ? "Claude" : "xAI";
  const blocks = xml.split(/<item\b/i).slice(1);
  const parsed: FeedItem[] = [];
  for (const block of blocks.slice(0, 8)) {
    const title = plain(tag(block, "title"));
    const link = tag(block, "link") || feedURL;
    const guid = tag(block, "guid") || link;
    const posted = tag(block, "pubDate") || now.toISOString();
    if (!title) continue;
    const postedISO = new Date(posted).toISOString();
    parsed.push({
      id: `status:${guid}`,
      source: "status",
      handle,
      text: title,
      url: link,
      posted_at: Number.isNaN(Date.parse(posted)) ? now.toISOString() : postedISO,
      kind: "status",
      expected_reset_at: expectedReset(title, new Date(postedISO)),
      expires_at: expires(postedISO, null, "status"),
      confidence: 1,
      official: true,
      product,
    });
  }
  const relevant = parsed.filter((item) => RELEVANT.test(item.text) || /elevated|outage|degraded|error/i.test(item.text));
  return relevant.length > 0 ? relevant : parsed.slice(0, 1);
}

function dedupe(items: FeedItem[], now: Date): FeedItem[] {
  const byID = new Map<string, FeedItem>();
  for (const item of items) {
    if (Date.parse(item.expires_at) <= now.getTime()) continue;
    const existing = byID.get(item.id);
    if (existing && existing.official && !item.official) continue;
    byID.set(item.id, item);
  }
  return [...byID.values()].sort((a, b) => {
    if (a.official !== b.official) return a.official ? -1 : 1;
    return Date.parse(b.posted_at) - Date.parse(a.posted_at);
  });
}

function expires(posted: string, expected: string | null, kind: Kind): string {
  const base = expected ? Date.parse(expected) : Date.parse(posted);
  const hours = expected ? 6 : kind === "rumor" ? 36 : kind === "status" ? 48 : 72;
  return new Date(base + hours * 3_600_000).toISOString();
}

function expectedReset(text: string, posted: Date): string | null {
  const match = text.match(/(\d{1,2})[\/\-.](\d{1,2})(?:[\/\-.](\d{2,4}))?[^\d]{0,12}(\d{1,2}):(\d{2})\s*(KST|UTC|GMT|PT|PST|PDT|ET|EST|EDT)?/i);
  if (!match) return null;
  let month = Number(match[1]);
  let day = Number(match[2]);
  let year = match[3] ? Number(match[3]) : posted.getUTCFullYear();
  if (month > 12 && day <= 12) {
    const swap = month;
    month = day;
    day = swap;
  }
  if (year < 100) year += 2000;
  const zone = (match[6] || "UTC").toUpperCase();
  const offset = zone.startsWith("K") ? 9 : zone.startsWith("P") ? -8 : zone.startsWith("E") ? -5 : 0;
  const utc = Date.UTC(year, month - 1, day, Number(match[4]) - offset, Number(match[5]));
  if (Number.isNaN(utc)) return null;
  return new Date(utc).toISOString();
}

function productOf(text: string): string {
  if (/codex/i.test(text)) return "codex";
  if (/claude/i.test(text)) return "claude";
  if (/cursor/i.test(text)) return "cursor";
  if (/grok/i.test(text)) return "grok";
  return "limit";
}

function tag(block: string, name: string): string {
  const match = block.match(new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`, "i"));
  if (!match) return "";
  return match[1].replace(/^\s*<!\[CDATA\[/, "").replace(/\]\]>\s*$/, "").trim();
}

function plain(value: string): string {
  return value.replace(/<[^>]+>/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/\s+/g, " ").trim();
}

async function xJSON(token: string, path: string): Promise<unknown> {
  const response = await fetch(`https://api.x.com${path}`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!response.ok) throw new Error(`x ${response.status} ${path.split("?")[0]}`);
  return response.json();
}
