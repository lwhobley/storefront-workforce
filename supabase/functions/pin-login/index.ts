// PIN sign-in. Takes a 6-digit PIN and this install's device id. When the PIN matches an
// active account, returns a one-time token hash that the app exchanges for a session.
//
// Attempts are limited per device and per network address, not per account, because a
// PIN alone cannot be tied to an account until it matches. A correct PIN gives the
// attempts back. Locks clear on their own after LOCK_MINUTES.
//
// Deploy without JWT verification: a person signing in has no token yet.
import { clientAddress, corsHeaders, json } from "../_shared/http.ts";
import {
  ADDRESS_MAX_FAILURES,
  DEVICE_MAX_FAILURES,
  isValidDeviceId,
  isValidPin,
  LOCK_MINUTES,
  lockKeys,
  pinFingerprint,
  pinSecret,
} from "../_shared/pin.ts";
import { serviceClient, takeAttempts } from "../_shared/clients.ts";

const WRONG = "That PIN is not recognized.";
const LOCKED = `Too many incorrect PINs. Try again in ${LOCK_MINUTES} minutes.`;
const UNAVAILABLE = "Sign-in is unavailable. Try again.";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let body: { pin?: unknown; device_id?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Enter your PIN." }, 400);
  }
  if (typeof body.pin !== "string" || !/^[0-9]{6}$/.test(body.pin)) return json({ error: "Enter your 6-digit PIN." }, 400);
  if (!isValidDeviceId(body.device_id)) {
    return json({ error: "This device could not be identified. Update the app and try again." }, 400);
  }
  const pin = body.pin;
  const admin = serviceClient();
  const keys = await lockKeys(body.device_id, clientAddress(req));

  try {
    const allowed = await takeAttempts(admin, [
      { key: keys.device, max: DEVICE_MAX_FAILURES },
      ...(keys.address ? [{ key: keys.address, max: ADDRESS_MAX_FAILURES }] : []),
    ], LOCK_MINUTES);
    if (!allowed) return json({ error: LOCKED, code: "locked" }, 423);

    // Weak PINs are never issued, so they can be refused without a lookup.
    const match = isValidPin(pin)
      ? (await admin.from("user_pins").select("user_id").eq("pin_fingerprint", await pinFingerprint(pin, await pinSecret(admin))).maybeSingle())
      : { data: null, error: null };
    if (match.error) return json({ error: UNAVAILABLE }, 503);

    const userId = match.data?.user_id as string | undefined;
    const { count } = userId
      ? await admin.from("venue_memberships").select("venue_id", { count: "exact", head: true })
        .eq("user_id", userId).eq("status", "active")
      : { count: 0 };
    // A PIN for an account with no active venue counts as wrong, so the response does not
    // reveal that the PIN belongs to someone.
    if (!userId || !count) {
      await admin.from("audit_logs").insert({ action: "auth.pin_failed", entity: "auth" });
      return json({ error: WRONG }, 401);
    }

    await admin.rpc("login_release", { p_key: keys.device, p_clear: true });
    if (keys.address) await admin.rpc("login_release", { p_key: keys.address, p_clear: false });

    const { data: userData, error: userError } = await admin.auth.admin.getUserById(userId);
    const email = userData?.user?.email;
    if (userError || !email) return json({ error: UNAVAILABLE }, 503);

    const { data: link, error: linkError } = await admin.auth.admin.generateLink({ type: "magiclink", email });
    const tokenHash = link?.properties?.hashed_token;
    if (linkError || !tokenHash) return json({ error: UNAVAILABLE }, 503);

    await admin.from("audit_logs").insert({ action: "auth.signed_in", entity: "user", entity_id: userId });
    return json({ token_hash: tokenHash });
  } catch (error) {
    console.error("pin-login failed", error);
    return json({ error: UNAVAILABLE }, 503);
  }
});
