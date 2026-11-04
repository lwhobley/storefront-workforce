// Clock-in kiosk. A shared tablet, signed in with a kiosk PIN, sends the PIN a person
// types plus the punch. This function matches the PIN to the person and records the punch
// for them.
//
//   action "identify": returns who the PIN belongs to and their position at today's event,
//                      so the kiosk can show the right buttons (clock in, break, clock out).
//   action "punch":    records the punch (and its photo). Also used to send punches the
//                      kiosk saved while offline; the punch id makes resending safe.
import { decodeBase64 } from "jsr:@std/encoding@1/base64";
import { clientAddress, corsHeaders, json } from "../_shared/http.ts";
import {
  ADDRESS_MAX_FAILURES,
  isValidDeviceId,
  isValidPin,
  KIOSK_DEVICE_MAX_FAILURES,
  LOCK_MINUTES,
  lockKeys,
  pinFingerprint,
  pinSecret,
} from "../_shared/pin.ts";
import { callerClient, serviceClient, takeAttempts } from "../_shared/clients.ts";

const WRONG = "That PIN is not recognized.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Body = {
  action?: string;
  pin?: unknown;
  device_id?: unknown;
  punch?: Record<string, unknown>;
  photo_base64?: unknown;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "This kiosk is not signed in." }, 401);

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Bad request" }, 400);
  }
  if (typeof body.pin !== "string" || !/^[0-9]{6}$/.test(body.pin)) return json({ error: "Enter your 6-digit PIN." }, 400);
  if (!isValidDeviceId(body.device_id)) return json({ error: "Unknown device." }, 400);

  const caller = callerClient(authHeader);
  const { data: me, error: meError } = await caller.auth.getUser();
  if (meError || !me.user) return json({ error: "This kiosk is not signed in." }, 401);
  const kioskUser = me.user.id;

  const admin = serviceClient();
  try {
    // The kiosk's venue is where its account holds kiosk_punch.
    const { data: kioskRoles } = await admin.from("role_assignments")
      .select("venue_id, venue_roles!inner(permissions)")
      .eq("user_id", kioskUser);
    const venueId = (kioskRoles ?? []).find((r) =>
      ((r.venue_roles as unknown as { permissions: string[] }).permissions ?? []).includes("kiosk_punch")
    )?.venue_id as string | undefined;
    if (!venueId) return json({ error: "This account is not a kiosk." }, 403);

    const keys = await lockKeys(body.device_id, clientAddress(req));
    const allowed = await takeAttempts(admin, [
      { key: keys.device, max: KIOSK_DEVICE_MAX_FAILURES },
      ...(keys.address ? [{ key: keys.address, max: ADDRESS_MAX_FAILURES }] : []),
    ], LOCK_MINUTES);
    if (!allowed) return json({ error: "Too many incorrect PINs. Ask a manager.", code: "locked" }, 423);

    if (!isValidPin(body.pin)) return json({ error: WRONG }, 401);
    const { data: pinRow } = await admin.from("user_pins").select("user_id")
      .eq("pin_fingerprint", await pinFingerprint(body.pin, await pinSecret(admin))).maybeSingle();
    const { data: worker } = pinRow
      ? await admin.from("workers").select("id, venue_id, first_name, preferred_name, last_name, photo_path, status, user_id")
        .eq("user_id", pinRow.user_id).eq("venue_id", venueId).maybeSingle()
      : { data: null };
    if (!worker || worker.status !== "active") return json({ error: WRONG }, 401);

    await admin.rpc("login_release", { p_key: keys.device, p_clear: false });
    const name = `${worker.preferred_name || worker.first_name} ${worker.last_name}`;

    if (body.action === "identify") {
      const now = Date.now();
      const { data: shifts } = await admin.from("shifts")
        .select("id, event_id, storefront_id, job_role_code, call_time, status, storefronts(code, name), events!inner(name, status, call_time, end_time)")
        .eq("worker_id", worker.id).in("status", ["assigned", "released"])
        .gte("call_time", new Date(now - 12 * 3600_000).toISOString())
        .lte("call_time", new Date(now + 12 * 3600_000).toISOString())
        .order("call_time").limit(1);
      const shift = shifts?.[0] ?? null;
      const { data: punches } = shift
        ? await admin.from("punches").select("id, kind, break_kind, occurred_at")
          .eq("worker_id", worker.id).eq("event_id", shift.event_id).neq("status", "voided").order("occurred_at")
        : { data: [] };
      return json({ worker: { id: worker.id, name, photo_path: worker.photo_path }, shift, punches: punches ?? [] });
    }

    if (body.action !== "punch" || !body.punch) return json({ error: "Bad request" }, 400);
    const punchId = String(body.punch.id ?? "");
    if (!UUID.test(punchId)) return json({ error: "Bad punch id" }, 400);

    let photoPath: string | null = null;
    if (typeof body.photo_base64 === "string" && body.photo_base64.length > 0) {
      if (body.photo_base64.length > 2_700_000) return json({ error: "Photo is too large." }, 413);
      photoPath = `${venueId}/${worker.id}/${punchId}.jpg`;
      const { error: uploadError } = await admin.storage.from("punch-photos")
        .upload(photoPath, decodeBase64(body.photo_base64), { contentType: "image/jpeg", upsert: true });
      if (uploadError) photoPath = null; // Keep the punch; a missing photo is visible to managers.
    }

    const { data: punch, error } = await admin.rpc("record_kiosk_punch", {
      p_kiosk_user: kioskUser,
      p_worker_user: worker.user_id,
      p_punch: { ...body.punch, device_id: body.device_id, photo_path: photoPath },
    });
    if (error) return json({ error: error.message }, 400);
    return json({ worker: { id: worker.id, name }, punch });
  } catch (error) {
    console.error("kiosk-punch failed", error);
    return json({ error: "The kiosk could not reach the server. Try again." }, 503);
  }
});
