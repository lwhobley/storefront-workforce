// Response helpers shared by the Edge Functions.

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// The caller's address as set by the platform, never a value the caller can choose.
// Cloudflare overwrites cf-connecting-ip; otherwise use the last X-Forwarded-For entry,
// which the platform appends, not the first, which the caller can send.
export function clientAddress(req: Request): string | null {
  const cloudflare = req.headers.get("cf-connecting-ip")?.trim();
  if (cloudflare) return cloudflare;
  const real = req.headers.get("x-real-ip")?.trim();
  if (real) return real;
  const forwarded = req.headers.get("x-forwarded-for")?.split(",").map((p) => p.trim()).filter(Boolean);
  return forwarded && forwarded.length > 0 ? forwarded[forwarded.length - 1] : null;
}
