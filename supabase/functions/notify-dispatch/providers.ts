// Delivery providers: Resend (email) and Firebase Cloud Messaging HTTP v1 (push). Each is configured only by its secrets; a missing secret means the channel is
// recorded as not_configured and nothing is sent.
import { type Claimed, emailContent, failure, type Result } from "./helpers.ts";

const TIMEOUT_MS = 15_000;

export type Env = (name: string) => string | undefined;

// ---- Email (Resend) --------------------------------------------------------------

export function resendConfig(env: Env) {
  const key = env("RESEND_API_KEY");
  const from = env("EMAIL_FROM");
  return key && from ? { key, from, appUrl: env("APP_URL") ?? null } : null;
}

export async function sendEmail(cfg: NonNullable<ReturnType<typeof resendConfig>>, n: Claimed): Promise<Result> {
  const content = emailContent(n, cfg.appUrl);
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${cfg.key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: cfg.from, to: [n.email.trim()], subject: content.subject, text: content.text, html: content.html }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (res.ok) {
      await res.body?.cancel();
      return "sent";
    }
    const body = await res.json().catch(() => ({})) as { message?: string };
    return failure(`Resend ${res.status}: ${body.message ?? res.statusText}`);
  } catch (e) {
    return failure(e);
  }
}

// ---- Push (Firebase Cloud Messaging HTTP v1) ----------------------------------------

type ServiceAccount = { client_email: string; private_key: string; token_uri?: string };

export function fcmConfig(env: Env) {
  const projectId = env("FCM_PROJECT_ID");
  const raw = env("FCM_SERVICE_ACCOUNT");
  if (!projectId || !raw) return null;
  try {
    const account = JSON.parse(raw) as ServiceAccount;
    if (!account.client_email || !account.private_key) return null;
    return { projectId, account, appUrl: env("APP_URL") ?? null };
  } catch {
    return null;
  }
}

function base64url(bytes: Uint8Array | string): string {
  const bin = typeof bytes === "string" ? bytes : String.fromCharCode(...bytes);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

let cachedToken: { value: string; expires: number } | null = null;

/** An OAuth access token for FCM, from the service account (signed JWT grant). */
async function fcmAccessToken(account: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expires > now + 60) return cachedToken.value;
  const tokenUri = account.token_uri ?? "https://oauth2.googleapis.com/token";
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: tokenUri,
    iat: now,
    exp: now + 3600,
  }));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(account.private_key.replace(/\\n/g, "\n")),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`)));
  const res = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${base64url(signature)}`,
    }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`FCM sign-in failed (${res.status})`);
  const body = await res.json() as { access_token: string; expires_in?: number };
  cachedToken = { value: body.access_token, expires: now + (body.expires_in ?? 3600) };
  return body.access_token;
}

/** Sends to every device the person has. Returns the result and tokens to forget. */
export async function sendPush(
  cfg: NonNullable<ReturnType<typeof fcmConfig>>,
  n: Claimed,
): Promise<{ results: Result[]; staleTokens: string[] }> {
  const staleTokens: string[] = [];
  let access: string;
  try {
    access = await fcmAccessToken(cfg.account);
  } catch (e) {
    return { results: [failure(e)], staleTokens };
  }
  const results: Result[] = [];
  for (const device of n.push_tokens) {
    const message = {
      token: device.token,
      notification: { title: n.title, body: n.body.slice(0, 500) },
      data: { notification_id: n.id, kind: n.kind, link: n.link || "/inbox" },
      android: { priority: n.urgent ? "high" : "normal" },
      apns: { headers: { "apns-priority": n.urgent ? "10" : "5" } },
      webpush: cfg.appUrl ? { fcm_options: { link: `${cfg.appUrl.replace(/\/+$/, "")}/#${n.link || "/inbox"}` } } : undefined,
    };
    try {
      const res = await fetch(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(cfg.projectId)}/messages:send`, {
        method: "POST",
        headers: { Authorization: `Bearer ${access}`, "Content-Type": "application/json" },
        body: JSON.stringify({ message }),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      if (res.ok) {
        await res.body?.cancel();
        results.push("sent");
        continue;
      }
      const body = await res.json().catch(() => ({})) as {
        error?: { status?: string; message?: string; details?: { errorCode?: string }[] };
      };
      const code = body.error?.details?.find((d) => d.errorCode)?.errorCode ?? body.error?.status ?? "";
      if (res.status === 404 || code === "UNREGISTERED" || code === "INVALID_ARGUMENT" && /token/i.test(body.error?.message ?? "")) {
        staleTokens.push(device.token);
      }
      results.push(failure(`FCM ${res.status}${code ? ` ${code}` : ""}`));
    } catch (e) {
      results.push(failure(e));
    }
  }
  return { results, staleTokens };
}
