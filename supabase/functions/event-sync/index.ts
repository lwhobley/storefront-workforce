// Pulls the event calendar from Premium Command into this venue's events.
//
// Premium Command is a separate Supabase project. This function signs in to it as a
// read-only sync account and reads its events table, then upserts them here through
// upsert_source_events(), which keeps call/doors times a manager changed and never
// deletes events. Re-running is safe.
//
// Secrets (set with `supabase secrets set`):
//   PC_SUPABASE_URL, PC_PUBLISHABLE_KEY   Premium Command project URL and publishable key
//   PC_SYNC_EMAIL, PC_SYNC_PASSWORD       the sync account in Premium Command
//   CRON_SECRET                           lets a scheduled job call this without a user
// Settings (event_sources.config): {"remote_venue_id": "<Premium Command venue id>"}
//
// Called by a manager (manage_events) with {"venue_id": "..."}, or by a scheduled job with
// the x-cron-secret header (syncs every active premium_command source).
import { corsHeaders, json } from "../_shared/http.ts";
import { callerClient, serviceClient } from "../_shared/clients.ts";

type SourceRow = { venue_id: string; config: { remote_venue_id?: string; days_back?: number } };

async function premiumCommandToken(): Promise<{ url: string; key: string; token: string }> {
  const url = Deno.env.get("PC_SUPABASE_URL");
  const key = Deno.env.get("PC_PUBLISHABLE_KEY");
  const email = Deno.env.get("PC_SYNC_EMAIL");
  const password = Deno.env.get("PC_SYNC_PASSWORD");
  if (!url || !key || !email || !password) throw new Error("Premium Command connection is not configured.");
  const res = await fetch(`${url}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: key, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  if (!res.ok) throw new Error(`Premium Command sign-in failed (${res.status}).`);
  const body = await res.json();
  return { url, key, token: body.access_token as string };
}

async function fetchEvents(conn: { url: string; key: string; token: string }, remoteVenueId: string, daysBack: number) {
  const since = new Date(Date.now() - daysBack * 86_400_000).toISOString();
  const params = new URLSearchParams({
    select: "id,name,event_type,status,service_start,service_end,guaranteed_guests",
    venue_id: `eq.${remoteVenueId}`,
    service_start: `gte.${since}`,
    order: "service_start.asc",
  });
  const res = await fetch(`${conn.url}/rest/v1/events?${params}`, {
    headers: { apikey: conn.key, Authorization: `Bearer ${conn.token}` },
  });
  if (!res.ok) throw new Error(`Premium Command events could not be read (${res.status}).`);
  const rows = await res.json() as Record<string, unknown>[];
  return rows.map((r) => ({
    external_id: r.id,
    name: r.name,
    event_type: r.event_type,
    start_time: r.service_start,
    end_time: r.service_end,
    status: r.status,
  }));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const admin = serviceClient();
  let sources: SourceRow[] = [];
  const cronSecret = Deno.env.get("CRON_SECRET");
  const fromCron = cronSecret && req.headers.get("x-cron-secret") === cronSecret;

  if (fromCron) {
    const { data } = await admin.from("event_sources").select("venue_id, config").eq("kind", "premium_command").eq("active", true);
    sources = (data ?? []) as SourceRow[];
  } else {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Sign in first." }, 401);
    let body: { venue_id?: string } = {};
    try {
      body = await req.json();
    } catch { /* empty body */ }
    const caller = callerClient(authHeader);
    const { data: allowed } = await caller.rpc("has_venue_permission", { p_venue: body.venue_id, p_permission: "manage_events" });
    if (allowed !== true) return json({ error: "You do not have permission to sync events." }, 403);
    const { data } = await admin.from("event_sources").select("venue_id, config")
      .eq("venue_id", body.venue_id).eq("kind", "premium_command").eq("active", true);
    sources = (data ?? []) as SourceRow[];
    if (sources.length === 0) return json({ error: "Premium Command is not connected for this venue." }, 404);
  }

  try {
    const conn = await premiumCommandToken();
    const results = [];
    for (const source of sources) {
      if (!source.config?.remote_venue_id) {
        results.push({ venue_id: source.venue_id, error: "remote_venue_id is not set" });
        continue;
      }
      const events = await fetchEvents(conn, source.config.remote_venue_id, source.config.days_back ?? 30);
      const { data, error } = await admin.rpc("upsert_source_events", {
        p_venue: source.venue_id,
        p_source: "premium_command",
        p_events: events,
      });
      results.push(error ? { venue_id: source.venue_id, error: error.message } : { venue_id: source.venue_id, ...data });
    }
    return json({ results });
  } catch (error) {
    console.error("event-sync failed", error);
    return json({ error: (error as Error).message }, 502);
  }
});
