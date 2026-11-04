// Sign-in accounts for staff, managers, partner contacts, and kiosks.
//
//   create_login  makes an account, gives it roles, links it to a staff record, and
//                 returns a new system-assigned 6-digit PIN (shown once).
//   reset_pin     issues a new PIN for an account.
//   set_access    turns an account's access to the venue on or off.
//
// The caller's permission is checked as the caller first (manage_users, or manage_workers
// for plain employee logins). Only then does this function use full access.
import { corsHeaders, json } from "../_shared/http.ts";
import { pinFingerprint, pinSecret, randomPin } from "../_shared/pin.ts";
import { callerClient, serviceClient } from "../_shared/clients.ts";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SCOPE_TABLES: Record<string, string> = {
  level: "venue_levels",
  storefront: "storefronts",
  npo_group: "npo_groups",
  agency: "temp_agencies",
};

type RoleGrant = { role_code: string; scope_type?: string; scope_id?: string | null };
type Body = {
  action?: string;
  venue_id?: string;
  user_id?: string;
  worker_id?: string;
  display_name?: string;
  kind?: string;
  roles?: RoleGrant[];
  active?: boolean;
};

// Stores a new random PIN for the account, retrying if it collides with another person's.
async function assignPin(admin: SupabaseClient, userId: string): Promise<string> {
  for (let attempt = 0; attempt < 20; attempt++) {
    const pin = randomPin();
    const { error } = await admin.from("user_pins").upsert(
      { user_id: userId, pin_fingerprint: await pinFingerprint(pin, await pinSecret(admin)), updated_at: new Date().toISOString() },
      { onConflict: "user_id" },
    );
    if (!error) return pin;
    if (error.code !== "23505") throw error;
  }
  throw new Error("Could not find a free PIN");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "Sign in first." }, 401);

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Bad request" }, 400);
  }
  const venueId = body.venue_id ?? "";
  if (!UUID.test(venueId)) return json({ error: "Choose a venue." }, 400);

  const caller = callerClient(authHeader);
  const can = async (permission: string) => {
    const { data } = await caller.rpc("has_venue_permission", { p_venue: venueId, p_permission: permission });
    return data === true;
  };
  const canManageUsers = await can("manage_users");
  const roles = Array.isArray(body.roles) ? body.roles : [];
  const onlyEmployee = roles.length > 0 && roles.every((r) => r.role_code === "employee" && (r.scope_type ?? "venue") === "venue");
  if (!canManageUsers && !(onlyEmployee && body.action === "create_login" && await can("manage_workers"))) {
    if (!(body.action === "reset_pin" && await can("manage_workers"))) {
      return json({ error: "You do not have permission to manage sign-ins." }, 403);
    }
  }

  const admin = serviceClient();
  try {
    if (body.action === "create_login") {
      const kind = body.kind === "kiosk" ? "kiosk" : "person";
      const displayName = (body.display_name ?? "").trim();
      if (!displayName || displayName.length > 120) return json({ error: "Enter a name." }, 400);
      if (roles.length === 0) return json({ error: "Give at least one role." }, 400);

      // Validate roles and scopes before creating anything.
      for (const r of roles) {
        const scopeType = r.scope_type ?? "venue";
        const { data: role } = await admin.from("venue_roles").select("code").eq("venue_id", venueId).eq("code", r.role_code).maybeSingle();
        if (!role) return json({ error: `Unknown role ${r.role_code}.` }, 400);
        if (scopeType !== "venue") {
          const table = SCOPE_TABLES[scopeType];
          if (!table || !r.scope_id || !UUID.test(r.scope_id)) return json({ error: "Choose where the role applies." }, 400);
          const { data: scoped } = await admin.from(table).select("id").eq("id", r.scope_id).eq("venue_id", venueId).maybeSingle();
          if (!scoped) return json({ error: "That scope is not at this venue." }, 400);
        }
      }
      if (body.worker_id) {
        const { data: w } = await admin.from("workers").select("id, user_id").eq("id", body.worker_id).eq("venue_id", venueId).maybeSingle();
        if (!w) return json({ error: "Staff record not found." }, 404);
        if (w.user_id) return json({ error: "This person already has a sign-in. Reset their PIN instead." }, 409);
      }

      const { data: created, error: createError } = await admin.auth.admin.createUser({
        email: `${kind}-${crypto.randomUUID()}@pin.storefront.invalid`,
        email_confirm: true,
      });
      if (createError || !created.user) throw createError ?? new Error("Account not created");
      const userId = created.user.id;

      const steps = [
        admin.from("user_profiles").insert({ id: userId, display_name: displayName, kind }),
        admin.from("venue_memberships").insert({ venue_id: venueId, user_id: userId }),
      ];
      for (const step of steps) {
        const { error } = await step;
        if (error) {
          await admin.auth.admin.deleteUser(userId);
          throw error;
        }
      }
      const { error: roleError } = await admin.from("role_assignments").insert(roles.map((r) => ({
        venue_id: venueId,
        user_id: userId,
        role_code: r.role_code,
        scope_type: r.scope_type ?? "venue",
        scope_id: (r.scope_type ?? "venue") === "venue" ? null : r.scope_id,
      })));
      if (roleError) {
        await admin.auth.admin.deleteUser(userId);
        throw roleError;
      }
      if (body.worker_id) {
        await admin.from("workers").update({ user_id: userId }).eq("id", body.worker_id).eq("venue_id", venueId);
      }
      const pin = await assignPin(admin, userId);
      await admin.from("audit_logs").insert({
        venue_id: venueId, action: "user.created", entity: "user", entity_id: userId,
        actor_id: (await caller.auth.getUser()).data.user?.id ?? null,
        after: { display_name: displayName, kind, roles, worker_id: body.worker_id ?? null },
      });
      return json({ user_id: userId, pin });
    }

    if (body.action === "reset_pin" || body.action === "set_access") {
      const userId = body.user_id ?? "";
      if (!UUID.test(userId)) return json({ error: "Choose a person." }, 400);
      const { data: member } = await admin.from("venue_memberships").select("user_id").eq("venue_id", venueId).eq("user_id", userId).maybeSingle();
      if (!member) return json({ error: "That person is not at this venue." }, 404);
      const actor = (await caller.auth.getUser()).data.user?.id ?? null;

      if (body.action === "reset_pin") {
        const pin = await assignPin(admin, userId);
        await admin.from("audit_logs").insert({ venue_id: venueId, action: "user.pin_reset", entity: "user", entity_id: userId, actor_id: actor });
        return json({ pin });
      }
      const status = body.active === false ? "suspended" : "active";
      await admin.from("venue_memberships").update({ status }).eq("venue_id", venueId).eq("user_id", userId);
      return json({ status });
    }

    return json({ error: "Unknown action" }, 400);
  } catch (error) {
    console.error("staff-admin failed", error);
    const code = (error as { code?: string }).code;
    if (code === "23505") return json({ error: "That already exists." }, 409);
    return json({ error: "The request failed. Try again." }, 500);
  }
});
