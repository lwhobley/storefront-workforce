import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import {
  appLink,
  backoffMs,
  type Claimed,
  combinePush,
  emailContent,
  escapeHtml,
  isEmail,
  localMinutes,
  planDelivery,
  processBatch,
  quietUntil,
  safeTimeZone,
  settle,
  truncate,
  zonedInstant,
} from "./helpers.ts";

Deno.test("email addresses: real ones pass, sign-in placeholders do not", () => {
  assert(isEmail("ana@example.com"));
  assert(isEmail(" ana.reyes+work@example.co "));
  assertFalse(isEmail("employee-1234@pin.storefront.invalid"));
  assertFalse(isEmail("not an email"));
  assertFalse(isEmail(""));
  assertFalse(isEmail(null));
});

Deno.test("truncate keeps short text and cuts long text with an ellipsis", () => {
  assertEquals(truncate("short", 10), "short");
  assertEquals(truncate("abcdefghijk", 5), "abcd…");
});

Deno.test("email content escapes HTML and links into the app", () => {
  const c = emailContent({ title: "Policy <update>", body: "Read & sign", link: "/inbox", venue_name: "Arena", language: "en" },
    "https://app.example.com/");
  assertEquals(c.subject, "Policy <update>");
  assert(c.html.includes("Policy &lt;update&gt;"));
  assert(c.html.includes("Read &amp; sign"));
  assert(c.text.includes("https://app.example.com/#/inbox"));
  const es = emailContent({ title: "Aviso", body: "", link: "", venue_name: "Arena", language: "es" }, null);
  assert(es.text.includes("Recibe este correo"));
  assertFalse(es.text.includes("http"));
  assertEquals(escapeHtml(`"'`), "&quot;&#39;");
  assertEquals(appLink("https://a.dev", "schedule"), "https://a.dev/#/inbox");
});

Deno.test("local minutes follow the venue time zone", () => {
  // 03:30 UTC on Nov 20 is 9:30 PM the day before in Chicago (CST).
  assertEquals(localMinutes(new Date("2026-11-20T03:30:00Z"), "America/Chicago"), 21 * 60 + 30);
  // Summer: CDT is UTC-5.
  assertEquals(localMinutes(new Date("2026-07-01T03:30:00Z"), "America/Chicago"), 22 * 60 + 30);
});

Deno.test("quiet hours that cross midnight", () => {
  const tz = "America/Chicago";
  // 11:30 PM local: quiet until 7:00 AM, 7.5 hours later.
  const late = new Date("2026-11-20T05:30:00Z");
  assertEquals(quietUntil(late, tz, "23:00", "07:00")?.toISOString(), "2026-11-20T13:00:00.000Z");
  // 6:59 AM local: one minute left.
  assertEquals(quietUntil(new Date("2026-11-20T12:59:00Z"), tz, "23:00", "07:00")?.toISOString(), "2026-11-20T13:00:00.000Z");
  // 7:00 AM and noon: not quiet.
  assertEquals(quietUntil(new Date("2026-11-20T13:00:00Z"), tz, "23:00", "07:00"), null);
  assertEquals(quietUntil(new Date("2026-11-20T18:00:00Z"), tz, "23:00", "07:00"), null);
});

Deno.test("quiet hours within one day, and none set", () => {
  const tz = "America/Chicago";
  // 2:15 PM local inside 13:00-15:00.
  assertEquals(quietUntil(new Date("2026-11-20T20:15:00Z"), tz, "13:00", "15:00")?.toISOString(), "2026-11-20T21:00:00.000Z");
  assertEquals(quietUntil(new Date("2026-11-20T21:00:00Z"), tz, "13:00", "15:00"), null);
  assertEquals(quietUntil(new Date("2026-11-20T20:15:00Z"), tz, null, null), null);
  assertEquals(quietUntil(new Date("2026-11-20T20:15:00Z"), tz, "13:00", "13:00"), null);
  assertEquals(quietUntil(new Date("2026-11-20T20:15:00Z"), tz, "25:00", "13:00"), null);
});

function claimed(over: Partial<Claimed> = {}): Claimed {
  return {
    id: "n1",
    venue_id: "v",
    user_id: "u",
    kind: "message",
    title: "Message from Marcus",
    body: "Restock cups",
    link: "/inbox",
    channels: ["in_app", "push", "email"],
    data: {},
    created_at: "2026-11-20T01:00:00Z",
    urgent: false,
    venue_name: "Arena",
    time_zone: "America/Chicago",
    language: "en",
    email: "ana@example.com",
    prefs: { push: true, email: true, quiet_start: null, quiet_end: null },
    push_tokens: [{ token: "t", platform: "android" }],
    claim: "c1",
    attempt: 1,
    max_attempts: 5,
    done: {},
    ...over,
  };
}

const all = { push: true, email: true };
const noon = new Date("2026-11-20T18:00:00Z");

Deno.test("plan: everything configured and reachable is sent", () => {
  const p = planDelivery(claimed(), all, noon);
  assertEquals(p.send, ["push", "email"]);
  assertEquals(p.results, {});
  assertEquals(p.deferUntil, null);
});

Deno.test("plan: opted out, not configured, and no contact are recorded, not sent", () => {
  const p = planDelivery(claimed({ email: "x@pin.storefront.invalid", push_tokens: [] }), all, noon);
  assertEquals(p.send, []);
  assertEquals(p.results, { push: "no_contact", email: "no_contact" });
  const off = planDelivery(claimed({ prefs: { push: false, email: false, quiet_start: null, quiet_end: null } }), all, noon);
  assertEquals(off.results, { push: "opted_out", email: "opted_out" });
  const q = planDelivery(claimed(), { push: false, email: false }, noon);
  assertEquals(q.results, { push: "not_configured", email: "not_configured" });
});

Deno.test("plan: there are no text messages", () => {
  const p = planDelivery(claimed({ channels: ["in_app", "push", "sms"] }), all, noon);
  assertEquals(p.send, ["push"]);
  assertEquals(p.results, { sms: "failed: unsupported channel" });
});

Deno.test("plan: quiet hours defer non-urgent sends, not urgent ones", () => {
  const prefs = { push: true, email: true, quiet_start: "23:00", quiet_end: "07:00" };
  const night = new Date("2026-11-20T06:00:00Z"); // midnight local
  assertEquals(planDelivery(claimed({ prefs }), all, night).deferUntil?.toISOString(), "2026-11-20T13:00:00.000Z");
  assertEquals(planDelivery(claimed({ prefs, urgent: true }), all, night).deferUntil, null);
  // Nothing to send: record now rather than wait.
  assertEquals(planDelivery(claimed({ prefs }), { push: false, email: false }, night).deferUntil, null);
});

Deno.test("push results combine across devices", () => {
  assertEquals(combinePush(["failed: FCM 404 UNREGISTERED", "sent"]), "sent");
  assertEquals(combinePush(["failed: FCM 500"]), "failed: FCM 500");
  assertEquals(combinePush([]), "no_contact");
});

Deno.test("an unknown time zone falls back to the venue default", () => {
  assertEquals(safeTimeZone("America/New_York"), "America/New_York");
  assertEquals(safeTimeZone("Central Time"), "America/Chicago");
  assertEquals(safeTimeZone(""), "America/Chicago");
  assertEquals(safeTimeZone(null), "America/Chicago");
  const at = new Date("2026-11-20T03:30:00Z");
  assertEquals(localMinutes(at, "Central Time"), localMinutes(at, "America/Chicago"));
  // Quiet hours still work, in the default zone, instead of throwing.
  const prefs = { push: true, email: true, quiet_start: "23:00", quiet_end: "07:00" };
  const night = new Date("2026-11-20T06:00:00Z");
  assertEquals(planDelivery(claimed({ prefs, time_zone: "Central Time" }), all, night).deferUntil?.toISOString(),
    "2026-11-20T13:00:00.000Z");
});

Deno.test("quiet hours end at the local time across daylight-saving changes", () => {
  const tz = "America/Chicago";
  // Spring forward (Mar 8, 2026): 1:00 AM CST, quiet until 7:00 AM CDT, five real hours later.
  assertEquals(quietUntil(new Date("2026-03-08T07:00:00Z"), tz, "23:00", "07:00")?.toISOString(), "2026-03-08T12:00:00.000Z");
  // Fall back (Nov 1, 2026): 1:00 AM CDT, quiet until 7:00 AM CST, seven real hours later.
  assertEquals(quietUntil(new Date("2026-11-01T06:00:00Z"), tz, "23:00", "07:00")?.toISOString(), "2026-11-01T13:00:00.000Z");
  // An end inside the skipped hour (2:30 AM) is when the clocks reach it: 3:00 AM CDT.
  assertEquals(quietUntil(new Date("2026-03-08T07:30:00Z"), tz, "01:00", "02:30")?.toISOString(), "2026-03-08T08:00:00.000Z");
  // A repeated hour resolves to its first occurrence.
  assertEquals(zonedInstant(Date.UTC(2026, 10, 1, 1, 30), tz).toISOString(), "2026-11-01T06:30:00.000Z");
});

Deno.test("plan: channels finished on an earlier attempt are not sent again", () => {
  const p = planDelivery(claimed({ done: { push: "sent" } }), all, noon);
  assertEquals(p.send, ["email"]);
  assertEquals(p.results, {});
});

Deno.test("settle: temporary failures retry after a backoff, then give up", () => {
  const at = new Date("2026-11-20T18:00:00Z");
  const first = settle(claimed(), { push: "sent", email: "retry: Resend 503: busy" }, at);
  assertEquals(first.sent, undefined);
  assertEquals(first.claim, "c1");
  assertEquals(first.retry, { email: "retry: Resend 503: busy" });
  assertEquals(first.done, { push: "sent" });
  assertEquals(first.deliver_after, new Date(at.getTime() + backoffMs(1)).toISOString());
  assert(backoffMs(2) > backoffMs(1) && backoffMs(10) === 30 * 60_000);

  const last = settle(claimed({ attempt: 5, done: { push: "sent" } }), { email: "retry: Resend 503: busy" }, at);
  assertEquals(last.sent, { push: "sent", email: "failed: Resend 503: busy (gave up after 5 attempts)" });
  assertEquals(last.deliver_after, undefined);

  assertEquals(settle(claimed(), { push: "sent", email: "failed: Resend 422: bad" }, at).sent,
    { push: "sent", email: "failed: Resend 422: bad" });
});

Deno.test("push results prefer sent, then a retry", () => {
  assertEquals(combinePush(["retry: FCM 503", "sent"]), "sent");
  assertEquals(combinePush(["failed: FCM 404 UNREGISTERED", "retry: FCM 503"]), "retry: FCM 503");
});

Deno.test("batch: one row that throws is failed alone; the rest are still recorded", async () => {
  const rows = [claimed({ id: "a" }), claimed({ id: "boom" }), claimed({ id: "c" }), claimed({ id: "busy" })];
  const { updates, counts } = await processBatch(rows, all, {
    email: (n) => {
      if (n.id === "boom") return Promise.reject(new Error("unexpected"));
      return Promise.resolve(n.id === "busy" ? "retry: Resend 429: slow down" : "sent");
    },
    push: () => Promise.resolve({ results: ["sent"], staleTokens: [] }),
  }, () => noon, 2);
  const byId = Object.fromEntries(updates.map((u) => [u.id, u]));
  assertEquals(updates.length, 4);
  assertEquals(byId.a.sent, { push: "sent", email: "sent" });
  assertEquals(byId.c.sent, { push: "sent", email: "sent" });
  assertEquals(byId.boom.sent, { push: "failed: unexpected", email: "failed: unexpected" });
  assertEquals(byId.busy.retry, { email: "retry: Resend 429: slow down" });
  assertEquals(byId.busy.done, { push: "sent" });
  assert(updates.every((u) => u.claim === "c1"));
  assertEquals(counts.errors, 1);
  assertEquals(counts.retry, 1);
  assertEquals(counts.notifications, 4);
});
