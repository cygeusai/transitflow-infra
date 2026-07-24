import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Transit & Flow — tf-stripe-webhook v1
// Receives Stripe events (no Supabase JWT; authenticated by Stripe signature).
// On a successful payment: marks the rent_payments row succeeded and posts a lease_ledger payment
// entry exactly once (idempotent on external_ref = rent_payment_id).
// Deploy with: supabase functions deploy tf-stripe-webhook --no-verify-jwt

const enc = new TextEncoder();

async function verifyStripeSig(payload: string, sigHeader: string, secret: string): Promise<boolean> {
  try {
    const parts: Record<string, string> = {};
    for (const kv of sigHeader.split(",")) { const [k, v] = kv.split("="); if (k && v) (parts[k.trim()] ||= v.trim()); }
    const t = parts["t"]; const v1 = parts["v1"];
    if (!t || !v1) return false;
    const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${payload}`));
    const hex = [...new Uint8Array(mac)].map((x) => x.toString(16).padStart(2, "0")).join("");
    if (hex.length !== v1.length) return false;
    let diff = 0; for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ v1.charCodeAt(i);
    return diff === 0;
  } catch { return false; }
}

Deno.serve(async (req: Request) => {
  const json = (s: number, o: unknown) => new Response(JSON.stringify(o), { status: s, headers: { "Content-Type": "application/json" } });
  if (req.method === "GET") return json(200, { ok: true, service: "tf-stripe-webhook", version: 1 });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const payload = await req.text();
  const sig = req.headers.get("stripe-signature") ?? "";

  const { data: whSecret } = await sb.rpc("get_secret", { p_name: "stripe_webhook_secret" });
  if (!whSecret) return json(503, { error: "not_configured" });
  const ok = await verifyStripeSig(payload, sig, whSecret);
  if (!ok) return json(400, { error: "bad_signature" });

  let evt: any; try { evt = JSON.parse(payload); } catch { return json(400, { error: "invalid_json" }); }
  const type = evt?.type as string;
  const obj = evt?.data?.object ?? {};

  if (type !== "checkout.session.completed" && type !== "payment_intent.succeeded") {
    return json(200, { ok: true, ignored: type });
  }

  const rpId: string | null = obj?.metadata?.rent_payment_id ?? obj?.client_reference_id ?? null;
  const providerRef: string | null = obj?.id ?? null;

  let rp: any = null;
  if (rpId) {
    const { data } = await sb.from("rent_payments").select("*").eq("id", rpId).maybeSingle();
    rp = data;
  }
  if (!rp && providerRef) {
    const { data } = await sb.from("rent_payments").select("*").eq("provider_payment_id", providerRef).maybeSingle();
    rp = data;
  }
  if (!rp) return json(200, { ok: true, note: "no_matching_payment" });

  if (String(rp.status) === "succeeded") return json(200, { ok: true, already: true });

  const nowIso = new Date().toISOString();
  await sb.from("rent_payments").update({ status: "succeeded", paid_at: nowIso, provider_payment_id: rp.provider_payment_id ?? providerRef }).eq("id", rp.id);

  const { data: existingLed } = await sb.from("lease_ledger").select("id").eq("external_ref", rp.id).is("deleted_at", null).maybeSingle();
  if (!existingLed) {
    const { data: last } = await sb.from("lease_ledger")
      .select("running_balance").eq("lease_id", rp.lease_id).is("deleted_at", null)
      .order("txn_date", { ascending: false }).order("created_at", { ascending: false }).limit(1).maybeSingle();
    const prev = Number((last as any)?.running_balance ?? 0);
    const newBal = Math.round((prev - Number(rp.amount)) * 100) / 100;
    await sb.from("lease_ledger").insert({
      company_id: rp.company_id, lease_id: rp.lease_id, unit_id: rp.unit_id, owner_id: rp.owner_id,
      txn_type: "payment", category: "rent", amount: rp.amount, running_balance: newBal,
      memo: "Online rent payment (Stripe)", external_ref: rp.id, txn_date: nowIso.slice(0, 10), posted: true,
    });
  }

  return json(200, { ok: true, settled: rp.id });
});
