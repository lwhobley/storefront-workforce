// Sends the push and email copies of notifications. (No text messages.)
//
// Every notification is in the app at once. Notifications whose channels include push
// or email are claimed here in batches (claim_notification_batch), sent through
// the configured providers, and each channel's result is written back to
// notifications.sent: "sent", "failed: ...", "not_configured", "opted_out", "no_contact"
// (or "expired" when it waited more than a day). Non-urgent notifications wait for the
// person's quiet hours to end. Email goes only to people who turned it on.
//
// Called by a scheduled job (every minute) with the x-cron-secret header. Not for users.
//
// Secrets (set with `supabase secrets set`); each provider is skipped when missing:
//   CRON_SECRET                                  required; the scheduled job sends it
//   RESEND_API_KEY, EMAIL_FROM                   email ("Arena Staffing <staff@example.com>")
//   FCM_PROJECT_ID, FCM_SERVICE_ACCOUNT          push (service account JSON)
//   APP_URL                                      optional; links in email and web push
import { corsHeaders, json } from "../_shared/http.ts";
import { serviceClient } from "../_shared/clients.ts";
import { type Claimed, combinePush, type Configured, planDelivery, type Result } from "./helpers.ts";
import { fcmConfig, resendConfig, sendEmail, sendPush } from "./providers.ts";

const BATCH = 50;
const MAX_BATCHES = 10;
const TIME_BUDGET_MS = 45_000;
const PARALLEL = 8;

function sameSecret(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function inParallel<T>(items: T[], limit: number, work: (item: T) => Promise<void>) {
  let next = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) await work(items[next++]);
  });
  await Promise.all(runners);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret) return json({ error: "CRON_SECRET is not set." }, 503);
  if (!sameSecret(req.headers.get("x-cron-secret") ?? "", cronSecret)) return json({ error: "Not allowed." }, 401);

  const env = (name: string) => Deno.env.get(name);
  const email = resendConfig(env);
  const push = fcmConfig(env);
  const configured: Configured = { email: email !== null, push: push !== null };

  const admin = serviceClient();
  const started = Date.now();
  const totals: Record<string, number> = { notifications: 0, deferred: 0 };
  const count = (key: string) => totals[key] = (totals[key] ?? 0) + 1;

  try {
    for (let batch = 0; batch < MAX_BATCHES && Date.now() - started < TIME_BUDGET_MS; batch++) {
      const { data, error } = await admin.rpc("claim_notification_batch", { p_limit: BATCH });
      if (error) throw error;
      const rows = (data ?? []) as Claimed[];
      if (rows.length === 0) break;

      const updates: { id: string; sent?: Record<string, Result>; deliver_after?: string }[] = [];
      const stale: string[] = [];
      await inParallel(rows, PARALLEL, async (n) => {
        totals.notifications++;
        const plan = planDelivery(n, configured, new Date());
        if (plan.deferUntil) {
          totals.deferred++;
          updates.push({ id: n.id, deliver_after: plan.deferUntil.toISOString() });
          return;
        }
        const sent: Record<string, Result> = {};
        for (const [channel, result] of Object.entries(plan.results)) if (result) sent[channel] = result;
        for (const channel of plan.send) {
          if (channel === "email" && email) sent.email = await sendEmail(email, n);
          if (channel === "push" && push) {
            const r = await sendPush(push, n);
            stale.push(...r.staleTokens);
            sent.push = combinePush(r.results);
          }
        }
        for (const [channel, result] of Object.entries(sent)) count(`${channel}:${result.startsWith("failed") ? "failed" : result}`);
        updates.push({ id: n.id, sent });
      });

      const { error: saveError } = await admin.rpc("record_notification_results", { p_results: updates });
      if (saveError) throw saveError;
      if (stale.length > 0) await admin.from("push_tokens").delete().in("token", stale);
      if (rows.length < BATCH) break;
    }
    return json({ configured, ...totals });
  } catch (error) {
    console.error("notify-dispatch failed", error);
    return json({ error: (error as Error).message ?? "Dispatch failed", ...totals }, 500);
  }
});
