import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

// Client with full access. Use only after the caller has been authorized.
export function serviceClient(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// Client acting as the caller, so row level security and permission checks apply.
export function callerClient(authHeader: string): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// Reserves one sign-in attempt for each key before a PIN is checked. Parallel requests
// cannot get past the limit because each reservation is a locked row update.
export async function takeAttempts(
  admin: SupabaseClient,
  keys: { key: string; max: number }[],
  lockMinutes: number,
): Promise<boolean> {
  for (const { key, max } of keys) {
    const { data, error } = await admin.rpc("login_take_attempt", { p_key: key, p_max: max, p_lock_minutes: lockMinutes });
    if (error) throw error;
    if (data !== true) return false;
  }
  return true;
}
