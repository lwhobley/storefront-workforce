// Pure helpers for notify-dispatch: email text, quiet hours, and the per-channel plan.
// No network or environment access, so they are unit tested.
//
// Channels are push and email (in_app needs no delivery). There are no text messages.

export type Channel = "push" | "email";

/** A delivery result stored in notifications.sent, per channel. */
export type Result = "sent" | "not_configured" | "opted_out" | "no_contact" | `failed: ${string}`;

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

/** Minutes since local midnight in a time zone. */
export function localMinutes(at: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
    .formatToParts(at);
  const h = Number(parts.find((p) => p.type === "hour")?.value ?? 0);
  const m = Number(parts.find((p) => p.type === "minute")?.value ?? 0);
  return (h % 24) * 60 + m;
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
  const now = localMinutes(at, timeZone);
  const inside = s < e ? now >= s && now < e : now >= s || now < e;
  if (!inside) return null;
  const wait = (e - now + 1440) % 1440;
  const until = new Date(at.getTime() + wait * 60_000);
  until.setUTCSeconds(0, 0);
  return until;
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
    if (c === "in_app") continue;
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
    ? quietUntil(at, n.time_zone || "America/Chicago", n.prefs?.quiet_start ?? null, n.prefs?.quiet_end ?? null)
    : null;
  return { send, results, deferUntil };
}

/** Summarizes several device results into one channel result. */
export function combinePush(results: Result[]): Result {
  if (results.length === 0) return "no_contact";
  if (results.includes("sent")) return "sent";
  return results[0];
}

/** Short, single-line error text for the sent column. */
export function failure(reason: unknown): Result {
  const text = reason instanceof Error ? reason.message : String(reason);
  return `failed: ${truncate(text, 180)}`;
}
