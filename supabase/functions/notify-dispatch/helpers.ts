// Pure helpers for notify-dispatch: email text, quiet hours, the per-channel plan, and
// the batch loop (with the senders passed in). No network or environment access, so
// they are unit tested.
//
// Channels are push and email (in_app needs no delivery). There are no text messages.

export type Channel = "push" | "email";

/** A delivery result stored in notifications.sent, per channel. */
export type Result = "sent" | "not_configured" | "opted_out" | "no_contact" | `failed: ${string}`;

/** A temporary failure (rate limit, provider outage, network): send again after a backoff. */
export type Retry = `retry: ${string}`;

/** What one send attempt on a channel returns. */
export type Attempt = Result | Retry;

export type Prefs = {
  push: boolean;
  email: boolean;
  quiet_start: string | null;
  quiet_end: string | null;
};

/** One claimed notification, as claim_notification_batch() returns it. */
export type Claimed = {
  id: string;
  venue_id: string;
  user_id: string;
  kind: string;
  title: string;
  body: string;
  link: string;
  channels: string[];
  data: Record<string, unknown>;
  created_at: string;
  urgent: boolean;
  venue_name: string;
  time_zone: string;
  language: string;
  email: string;
  prefs: Prefs;
  push_tokens: { token: string; platform: string }[];
  /** The claim this batch holds; results are written back only while it still holds it. */
  claim: string;
  /** Which delivery attempt this is (1 on the first claim) and the most there will be. */
  attempt: number;
  max_attempts: number;
  /** Channels already finished on an earlier attempt; they are not sent again. */
  done: Record<string, Result>;
};

/** One row for record_notification_results(). */
export type Update = {
  id: string;
  claim: string;
  /** Final results per channel. */
  sent?: Record<string, Result>;
  /** Not final yet: send again at deliver_after (quiet hours, or a retry after a backoff). */
  deliver_after?: string;
  /** Set on a retry: the temporary failures, per channel. */
  retry?: Record<string, Retry>;
  /** Set on a retry: channels finished on this or an earlier attempt. */
  done?: Record<string, Result>;
};

export type Configured = { push: boolean; email: boolean };

export function isEmail(raw: string | null | undefined): boolean {
  if (!raw) return false;
  const s = raw.trim();
  // Sign-in accounts use placeholder addresses on a reserved domain; never mail them.
  if (/\.invalid$/i.test(s)) return false;
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s) && s.length <= 254;
}

/** Collapses whitespace and cuts to [limit] characters, ending with an ellipsis if cut. */
export function truncate(text: string, limit: number): string {
  const clean = text.replace(/\s+/g, " ").trim();
  if (clean.length <= limit) return clean;
  return clean.slice(0, limit - 1).trimEnd() + "…";
}

export function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/** In-app link on the web app (hash routing), or null without an app address. */
export function appLink(appUrl: string | null | undefined, link: string): string | null {
  if (!appUrl) return null;
  const base = appUrl.replace(/\/+$/, "");
  const path = link && link.startsWith("/") ? link : "/inbox";
  return `${base}/#${path}`;
}

export function emailContent(n: Pick<Claimed, "title" | "body" | "link" | "venue_name" | "language">, appUrl?: string | null) {
  const es = n.language === "es";
  const url = appLink(appUrl, n.link);
  const open = es ? "Abrir en la app" : "Open in the app";
  const footer = es
    ? `Recibe este correo de ${n.venue_name}. Puede cambiar sus avisos en la app, en Bandeja.`
    : `You get this email from ${n.venue_name}. Change your notifications in the app, under Inbox.`;
  const text = [n.body, url ? `${open}: ${url}` : "", footer].filter(Boolean).join("\n\n");
  const html = [
    `<div style="font-family:Arial,sans-serif;font-size:15px;line-height:1.5;color:#201e1d">`,
    `<h2 style="font-size:18px;margin:0 0 12px">${escapeHtml(n.title)}</h2>`,
    n.body ? `<p style="white-space:pre-wrap;margin:0 0 16px">${escapeHtml(n.body)}</p>` : "",
    url ? `<p><a href="${escapeHtml(url)}" style="color:#0088b0">${open}</a></p>` : "",
    `<p style="color:#605d5d;font-size:13px">${escapeHtml(footer)}</p>`,
    `</div>`,
  ].join("");
  return { subject: truncate(n.title, 150), text, html };
}

/** The venues.time_zone default. */
export const DEFAULT_TIME_ZONE = "America/Chicago";

function zoneWorks(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone });
    return true;
  } catch {
    return false;
  }
}

/** The venue's time zone, or the venue default (then UTC) when Intl does not know it. */
export function safeTimeZone(timeZone: string | null | undefined): string {
  if (timeZone && zoneWorks(timeZone)) return timeZone;
  return zoneWorks(DEFAULT_TIME_ZONE) ? DEFAULT_TIME_ZONE : "UTC";
}

/** Local wall-clock time at [at] in the zone, as if it were UTC (milliseconds, whole seconds). */
function wallClock(at: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(at);
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? 0);
  return Date.UTC(get("year"), get("month") - 1, get("day"), get("hour") % 24, get("minute"), get("second"));
}

/** The zone's offset from UTC at [at], in milliseconds. */
function offsetAt(at: number, timeZone: string): number {
  const whole = Math.floor(at / 1000) * 1000;
  return wallClock(new Date(whole), timeZone) - whole;
}

/**
 * The first instant whose local wall-clock time in the zone is [wall] (a local time written
 * as if UTC). When the clocks skip that time (spring forward), the instant they skip to.
 */
export function zonedInstant(wall: number, timeZone: string): Date {
  const guess = wall - offsetAt(wall, timeZone);
  // Offsets a few hours either side cover a daylight-saving change near the target.
  const candidates = [...new Set([guess - 3 * 3_600_000, guess, guess + 3 * 3_600_000].map((t) => wall - offsetAt(t, timeZone)))]
    .sort((a, b) => a - b);
  const exact = candidates.find((t) => wallClock(new Date(t), timeZone) === wall);
  if (exact !== undefined) return new Date(exact);
  // In a gap: the earliest instant at or after the wall time.
  let lo = candidates[0];
  let hi = candidates[candidates.length - 1];
  if (wallClock(new Date(lo), timeZone) >= wall) return new Date(lo);
  while (hi - lo > 1000) {
    const mid = Math.floor((lo + hi) / 2000) * 1000;
    if (wallClock(new Date(mid), timeZone) >= wall) hi = mid;
    else lo = mid;
  }
  return new Date(hi);
}

/** Minutes since local midnight in a time zone. */
export function localMinutes(at: Date, timeZone: string): number {
  const wall = wallClock(at, safeTimeZone(timeZone));
  return Math.floor((wall % 86_400_000) / 60_000);
}

function parseHm(s: string | null | undefined): number | null {
  if (!s) return null;
  const m = /^(\d{1,2}):(\d{2})/.exec(s);
  if (!m) return null;
  const h = Number(m[1]);
  const min = Number(m[2]);
  if (h > 23 || min > 59) return null;
  return h * 60 + min;
}

/**
 * When [at] falls inside the person's quiet hours (venue local time, start inclusive,
 * end exclusive, may cross midnight), the instant the quiet hours end; otherwise null.
 */
export function quietUntil(at: Date, timeZone: string, start: string | null, end: string | null): Date | null {
  const s = parseHm(start);
  const e = parseHm(end);
  if (s === null || e === null || s === e) return null;
  const zone = safeTimeZone(timeZone);
  const wall = wallClock(at, zone);
  const now = Math.floor((wall % 86_400_000) / 60_000);
  const inside = s < e ? now >= s && now < e : now >= s || now < e;
  if (!inside) return null;
  // The end is later today, or tomorrow when the quiet hours cross midnight. Converted as
  // a local time, so a daylight-saving change overnight does not move it.
  const midnight = wall - (wall % 86_400_000);
  return zonedInstant(midnight + (now < e ? 0 : 1) * 86_400_000 + e * 60_000, zone);
}

export type Plan = {
  /** Channels to send now. */
  send: Channel[];
  /** Results decided without sending (opted out, not configured, no contact). */
  results: Partial<Record<string, Result>>;
  /** Set when everything to send should wait for quiet hours to end. */
  deferUntil: Date | null;
};

/** Decides, per channel, whether to send and why not. */
export function planDelivery(n: Claimed, configured: Configured, at: Date): Plan {
  const send: Channel[] = [];
  const results: Partial<Record<string, Result>> = {};
  for (const c of n.channels) {
    if (c === "in_app" || n.done?.[c]) continue;
    if (c !== "push" && c !== "email") {
      // Text messages are not used; anything else is unknown.
      results[c] = "failed: unsupported channel";
      continue;
    }
    if (n.prefs?.[c] === false) results[c] = "opted_out";
    else if (!configured[c]) results[c] = "not_configured";
    else if (c === "push" && (n.push_tokens ?? []).length === 0) results[c] = "no_contact";
    else if (c === "email" && !isEmail(n.email)) results[c] = "no_contact";
    else send.push(c);
  }
  const deferUntil = send.length > 0 && !n.urgent
    ? quietUntil(at, n.time_zone, n.prefs?.quiet_start ?? null, n.prefs?.quiet_end ?? null)
    : null;
  return { send, results, deferUntil };
}

/**
 * Summarizes several device results into one channel result: sent when any device got
 * it (so a retry never repeats it), else a retry when any failure was temporary.
 */
export function combinePush(results: Attempt[]): Attempt {
  if (results.length === 0) return "no_contact";
  if (results.includes("sent")) return "sent";
  return results.find(isRetry) ?? results[0];
}

function reasonText(reason: unknown): string {
  return truncate(reason instanceof Error ? reason.message : String(reason), 180);
}

/** Short, single-line error text for the sent column. */
export function failure(reason: unknown): Result {
  return `failed: ${reasonText(reason)}`;
}

/** A temporary failure, to send again after a backoff. */
export function retry(reason: unknown): Retry {
  return `retry: ${reasonText(reason)}`;
}

export function isRetry(a: Attempt): a is Retry {
  return a.startsWith("retry: ");
}

/** Wait before attempt [attempt] + 1: 2, 4, 8, 16 minutes, at most 30. */
export function backoffMs(attempt: number): number {
  return Math.min(2 ** Math.max(1, attempt), 30) * 60_000;
}

/**
 * The row to record after an attempt. Temporary failures are sent again after a
 * backoff (channels already done are kept and not repeated); on the last attempt they
 * become final failures.
 */
export function settle(n: Claimed, sent: Record<string, Attempt>, at: Date): Update {
  const done: Record<string, Result> = { ...(n.done ?? {}) };
  const retries: Record<string, Retry> = {};
  for (const [channel, result] of Object.entries(sent)) {
    if (isRetry(result)) retries[channel] = result;
    else done[channel] = result;
  }
  if (Object.keys(retries).length === 0) return { id: n.id, claim: n.claim, sent: done };
  if (n.attempt >= n.max_attempts) {
    for (const [channel, r] of Object.entries(retries)) {
      done[channel] = `failed: ${r.slice("retry: ".length)} (gave up after ${n.attempt} attempts)`;
    }
    return { id: n.id, claim: n.claim, sent: done };
  }
  return {
    id: n.id,
    claim: n.claim,
    retry: retries,
    done,
    deliver_after: new Date(at.getTime() + backoffMs(n.attempt)).toISOString(),
  };
}

/** Final failures for every channel still to deliver (the row could not be processed). */
export function failAll(n: Claimed, reason: unknown): Update {
  const sent: Record<string, Result> = { ...(n.done ?? {}) };
  for (const c of n.channels ?? []) if (c !== "in_app" && !sent[c]) sent[c] = failure(reason);
  return { id: n.id, claim: n.claim, sent };
}

/** Runs [work] over [items], at most [limit] at a time. */
export async function inParallel<T>(items: T[], limit: number, work: (item: T) => Promise<void>) {
  let next = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) await work(items[next++]);
  });
  await Promise.all(runners);
}

export type Senders = {
  email?: (n: Claimed) => Promise<Attempt>;
  push?: (n: Claimed) => Promise<{ results: Attempt[]; staleTokens: string[] }>;
};

/**
 * Plans and sends one claimed batch. Every row gets an update, even when sending it
 * throws: that row is recorded as failed and the rest are still recorded.
 */
export async function processBatch(
  rows: Claimed[],
  configured: Configured,
  senders: Senders,
  now: () => Date,
  parallel = 8,
): Promise<{ updates: Update[]; stale: string[]; counts: Record<string, number> }> {
  const updates: Update[] = [];
  const stale: string[] = [];
  const counts: Record<string, number> = { notifications: 0, deferred: 0 };
  const count = (key: string) => counts[key] = (counts[key] ?? 0) + 1;

  await inParallel(rows, parallel, async (n) => {
    counts.notifications++;
    try {
      const plan = planDelivery(n, configured, now());
      if (plan.deferUntil) {
        counts.deferred++;
        updates.push({ id: n.id, claim: n.claim, deliver_after: plan.deferUntil.toISOString() });
        return;
      }
      const sent: Record<string, Attempt> = {};
      for (const [channel, result] of Object.entries(plan.results)) if (result) sent[channel] = result;
      for (const channel of plan.send) {
        if (channel === "email" && senders.email) sent.email = await senders.email(n);
        if (channel === "push" && senders.push) {
          const r = await senders.push(n);
          stale.push(...r.staleTokens);
          sent.push = combinePush(r.results);
        }
      }
      const update = settle(n, sent, now());
      if (update.retry) count("retry");
      for (const [channel, result] of Object.entries(sent)) {
        count(`${channel}:${result.startsWith("failed") ? "failed" : isRetry(result) ? "retry" : result}`);
      }
      updates.push(update);
    } catch (e) {
      console.error("notify-dispatch: notification failed", n.id, e);
      count("errors");
      updates.push(failAll(n, e));
    }
  });
  return { updates, stale, counts };
}
