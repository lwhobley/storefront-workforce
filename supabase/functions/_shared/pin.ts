// PIN rules shared by sign-in, kiosk clock-in, and staff administration.
//
// Every person and kiosk signs in with a 6-digit PIN that the system assigns. PINs are
// never stored. pinFingerprint() keys the PIN with a secret key (HMAC-SHA256) and only
// the fingerprint is saved. Moving the key into a function secret (PIN_SECRET) keeps it
// out of the database entirely; see migration 0007.

const encoder = new TextEncoder();

export const PIN_LENGTH = 6;

// Failed attempts allowed before a lock, and how long the lock lasts. A device is one app
// install. An address is shared by everyone on the venue Wi-Fi, so its limit is higher.
export const DEVICE_MAX_FAILURES = 5;
export const ADDRESS_MAX_FAILURES = 40;
export const LOCK_MINUTES = 15;

// Kiosks see many people in a row; one mistyped PIN must not lock the line.
export const KIOSK_DEVICE_MAX_FAILURES = 25;

export function isWeakPin(pin: string): boolean {
  if (/^(\d)\1+$/.test(pin)) return true; // 000000, 111111
  const digits = [...pin].map(Number);
  const steps = digits.slice(1).map((d, i) => d - digits[i]);
  if (steps.every((s) => s === 1) || steps.every((s) => s === -1)) return true; // 123456, 654321
  if (/^(\d\d)\1\1$/.test(pin) || /^(\d\d\d)\1$/.test(pin)) return true; // 121212, 123123
  return false;
}

export function isValidPin(pin: unknown): pin is string {
  return typeof pin === "string" && /^[0-9]{6}$/.test(pin) && !isWeakPin(pin);
}

export function isValidDeviceId(id: unknown): id is string {
  return typeof id === "string" && /^[A-Za-z0-9-]{16,64}$/.test(id);
}

// A random PIN from the operating system's secure random source.
export function randomPin(): string {
  for (;;) {
    const buf = new Uint32Array(1);
    crypto.getRandomValues(buf);
    // Reject the top of the range so every PIN is equally likely.
    if (buf[0] >= 4_294_000_000) continue;
    const pin = String(buf[0] % 1_000_000).padStart(PIN_LENGTH, "0");
    if (!isWeakPin(pin)) return pin;
  }
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// The fingerprint key: the PIN_SECRET function secret when set, otherwise the key kept
// in the database's private schema (see migration 0007).
let cachedSecret: string | null = null;
export async function pinSecret(admin?: { rpc: (fn: string) => PromiseLike<{ data: unknown; error: unknown }> }): Promise<string> {
  const env = Deno.env.get("PIN_SECRET");
  if (env && env.length >= 32) return env;
  if (cachedSecret) return cachedSecret;
  if (!admin) throw new Error("PIN secret is not configured");
  const { data, error } = await admin.rpc("pin_hmac_secret");
  if (error || typeof data !== "string" || data.length < 32) throw new Error("PIN secret is not configured");
  cachedSecret = data;
  return data;
}

export async function pinFingerprint(pin: string, secret?: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret ?? await pinSecret()),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(`pin:${pin}`));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Lock keys for one attempt. The raw device id and address are never stored.
export async function lockKeys(deviceId: string, address: string | null) {
  return {
    device: `device:${await sha256Hex(`device:${deviceId}`)}`,
    address: address ? `ip:${await sha256Hex(`ip:${address}`)}` : null,
  };
}
