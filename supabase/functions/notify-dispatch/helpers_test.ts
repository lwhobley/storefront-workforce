import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import {
  appLink,
  type Claimed,
  combinePush,
  emailContent,
  escapeHtml,
  isEmail,
  localMinutes,
  planDelivery,
  quietUntil,
  truncate,
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
