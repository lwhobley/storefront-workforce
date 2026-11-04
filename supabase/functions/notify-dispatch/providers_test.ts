import { assert, assertEquals } from "jsr:@std/assert@1";
import type { Claimed } from "./helpers.ts";
import { fcmConfig, resendConfig, resetFcmTokenCache, sendEmail, sendPush } from "./providers.ts";

const n: Claimed = {
  id: "n1",
  venue_id: "v",
  user_id: "u",
  kind: "message",
  title: "Urgent from Marcus Bell",
  body: "Stand 101 needs a runner",
  link: "/inbox",
  channels: ["in_app", "push", "email"],
  data: {},
  created_at: "2026-11-20T01:00:00Z",
  urgent: true,
  venue_name: "Arena",
  time_zone: "America/Chicago",
  language: "en",
  email: "ana@example.com",
  prefs: { push: true, email: true, quiet_start: null, quiet_end: null },
  push_tokens: [{ token: "good", platform: "android" }, { token: "gone", platform: "ios" }],
  claim: "c1",
  attempt: 1,
  max_attempts: 5,
  done: {},
};

type Call = { url: string; init: RequestInit };

function mockFetch(respond: (url: string, init: RequestInit) => Response | Promise<Response>): { calls: Call[]; restore: () => void } {
  const original = globalThis.fetch;
  const calls: Call[] = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    calls.push({ url, init: init ?? {} });
    return Promise.resolve().then(() => respond(url, init ?? {}));
  }) as typeof fetch;
  return { calls, restore: () => globalThis.fetch = original };
}

Deno.test("providers are off without their secrets", () => {
  const none = () => undefined;
  assertEquals(resendConfig(none), null);
  assertEquals(fcmConfig(none), null);
  assertEquals(fcmConfig((k) => ({ FCM_PROJECT_ID: "p", FCM_SERVICE_ACCOUNT: "not json" } as Record<string, string>)[k]), null);
});

Deno.test("email goes to Resend", async () => {
  const m = mockFetch(() => Response.json({ id: "e1" }));
  try {
    const cfg = resendConfig((k) => ({ RESEND_API_KEY: "re_1", EMAIL_FROM: "Staff <staff@example.com>", APP_URL: "https://app.example.com" } as Record<string, string>)[k])!;
    assertEquals(await sendEmail(cfg, n), "sent");
    const body = JSON.parse(m.calls[0].init.body as string);
    assertEquals(body.to, ["ana@example.com"]);
    assertEquals(body.subject, "Urgent from Marcus Bell");
    assert(body.text.includes("https://app.example.com/#/inbox"));
    assertEquals((m.calls[0].init.headers as Record<string, string>)["Idempotency-Key"], "n1");
  } finally {
    m.restore();
  }
});

async function serviceAccount() {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----\n`;
  return { pair, account: JSON.stringify({ client_email: "fcm@p.iam.gserviceaccount.com", private_key: pem }) };
}

Deno.test("push signs in with the service account and drops unregistered devices", async () => {
  resetFcmTokenCache();
  const { pair, account } = await serviceAccount();

  const m = mockFetch((url, init) => {
    if (url.startsWith("https://oauth2.googleapis.com/token")) return Response.json({ access_token: "ya29", expires_in: 3600 });
    const msg = JSON.parse(init.body as string).message;
    if (msg.token === "gone") {
      return Response.json({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }, { status: 404 });
    }
    return Response.json({ name: "projects/p/messages/1" });
  });
  try {
    const cfg = fcmConfig((k) => ({ FCM_PROJECT_ID: "p", FCM_SERVICE_ACCOUNT: account } as Record<string, string>)[k])!;
    const r = await sendPush(cfg, n);
    assertEquals(r.results[0], "sent");
    assert(r.results[1].startsWith("failed: FCM 404"));
    assertEquals(r.staleTokens, ["gone"]);

    // The JWT grant is a valid RS256 signature by the service account key.
    const grant = new URLSearchParams(m.calls[0].init.body as URLSearchParams).get("assertion")!;
    const [h, c, s] = grant.split(".");
    const sig = Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (ch) => ch.charCodeAt(0));
    assert(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", pair.publicKey, sig, new TextEncoder().encode(`${h}.${c}`)));
    const claims = JSON.parse(atob(c.replace(/-/g, "+").replace(/_/g, "/")));
    assertEquals(claims.scope, "https://www.googleapis.com/auth/firebase.messaging");

    const send = m.calls[1];
    assertEquals(send.url, "https://fcm.googleapis.com/v1/projects/p/messages:send");
    assertEquals((send.init.headers as Record<string, string>).Authorization, "Bearer ya29");
    assertEquals(JSON.parse(send.init.body as string).message.android.priority, "high");
  } finally {
    m.restore();
  }
});

const emailCfg = resendConfig((k) => ({ RESEND_API_KEY: "re_1", EMAIL_FROM: "Staff <staff@example.com>" } as Record<string, string>)[k])!;

Deno.test("email: rate limits, outages and network errors are retried; bad requests are not", async () => {
  const cases: [() => Response | Promise<Response>, string][] = [
    [() => Response.json({ message: "Too many requests" }, { status: 429 }), "retry: Resend 429: Too many requests"],
    [() => Response.json({ message: "Internal error" }, { status: 503 }), "retry: Resend 503: Internal error"],
    [() => Response.json({ name: "concurrent_idempotent_requests", message: "in progress" }, { status: 409 }), "retry: Resend 409: in progress"],
    [() => Response.json({ message: "Invalid `to` field" }, { status: 422 }), "failed: Resend 422: Invalid `to` field"],
    [() => Promise.reject(new TypeError("connection reset")), "retry: connection reset"],
  ];
  for (const [respond, expected] of cases) {
    const m = mockFetch(respond);
    try {
      assertEquals(await sendEmail(emailCfg, n), expected);
    } finally {
      m.restore();
    }
  }
});

Deno.test("push: FCM rate limits, outages and network errors are retried", async () => {
  resetFcmTokenCache();
  const { account } = await serviceAccount();
  const cfg = fcmConfig((k) => ({ FCM_PROJECT_ID: "p", FCM_SERVICE_ACCOUNT: account } as Record<string, string>)[k])!;
  const m = mockFetch((url, init) => {
    if (url.startsWith("https://oauth2.googleapis.com/token")) return Response.json({ access_token: "ya29", expires_in: 3600 });
    const msg = JSON.parse(init.body as string).message;
    if (msg.token === "good") return Response.json({ error: { status: "UNAVAILABLE" } }, { status: 503 });
    if (msg.token === "limited") return Response.json({ error: { status: "RESOURCE_EXHAUSTED" } }, { status: 429 });
    if (msg.token === "bad") return Response.json({ error: { status: "PERMISSION_DENIED" } }, { status: 403 });
    return Promise.reject(new TypeError("network down"));
  });
  try {
    const r = await sendPush(cfg, { ...n, push_tokens: ["good", "limited", "bad", "offline"].map((token) => ({ token, platform: "android" })) });
    assertEquals(r.results, ["retry: FCM 503 UNAVAILABLE", "retry: FCM 429 RESOURCE_EXHAUSTED", "failed: FCM 403 PERMISSION_DENIED", "retry: network down"]);
    assertEquals(r.staleTokens, []);
  } finally {
    m.restore();
  }
});

Deno.test("push: a sign-in outage is retried; a rejected sign-in is final", async () => {
  const { account } = await serviceAccount();
  const cfg = fcmConfig((k) => ({ FCM_PROJECT_ID: "p", FCM_SERVICE_ACCOUNT: account } as Record<string, string>)[k])!;
  for (const [respond, expected] of [
    [() => new Response("unavailable", { status: 503 }), "retry: FCM sign-in failed (503)"],
    [() => Promise.reject(new TypeError("dns error")), "retry: FCM sign-in failed: dns error"],
    [() => Response.json({ error: "invalid_grant" }, { status: 400 }), "failed: FCM sign-in failed (400)"],
  ] as [() => Response | Promise<Response>, string][]) {
    resetFcmTokenCache();
    const m = mockFetch(respond);
    try {
      const r = await sendPush(cfg, n);
      assertEquals(r.results, [expected]);
      assertEquals(m.calls.length, 1);
    } finally {
      m.restore();
    }
  }
});
