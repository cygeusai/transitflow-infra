import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Transit & Flow — tf-rent-pay v1
// Tenant-initiated rent payment. Creates a Stripe Checkout Session for the caller's own lease balance.
// GATED: refuses unless integration_settings.stripe.config.rent_payments_enabled === true AND a
// stripe_secret_key secret is present. No money moves until the owner completes activation.

const COMPANY_ID = "ff000000-0000-4000-b000-000000000001";
const STRIPE_BASE = "https://api.stripe.com/v1";
const DEFAULT_ORIGIN = "https://goqtf.lovable.app";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS, GET",
};

Deno.serve(async (req: Request) => {
  const json = (s: number, o: unknown) => new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method === "GET") return json(200, { ok: true, service: "tf-rent-pay", version: 1 });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const authHeader = req.headers.get("authorization") ?? "";
  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authHeader } } });
  const { data: userData } = await userClient.auth.getUser();
  const userId = userData?.user?.id;
  if (!userId) return json(401, { error: "not_signed_in" });

  const { data: cfgRow } = await sb.from("integration_settings").select("config").eq("company_id", COMPANY_ID).eq("provider", "stripe").maybeSingle();
  if (cfgRow?.config?.rent_payments_enabled !== true) {
    return json(403, { error: "payments_not_enabled", note: "Online rent payments are not turned on yet." });
  }

  const { data: sk } = await sb.rpc("get_secret", { p_name: "stripe_secret_key" });
  if (!sk) return json(503, { error: "not_configured", note: "Stripe secret key is not set." });

  let b: any; try { b = await req.json(); } catch { return json(400, { error: "invalid_json" }); }
  const leaseId = String(b.lease_id ?? "");
  const originRaw = String(b.origin ?? DEFAULT_ORIGIN).replace(/\/$/, "");
  const origin = /^https?:\/\//.test(originRaw) ? originRaw : DEFAULT_ORIGIN;
  if (!leaseId) return json(422, { error: "lease_id_required" });

  const { data: tenantRow } = await sb.from("lease_tenants")
    .select("id").eq("lease_id", leaseId).eq("user_id", userId).is("deleted_at", null).maybeSingle();
  if (!tenantRow) return json(403, { error: "not_your_lease" });

  const { data: lease } = await sb.from("leases").select("id, company_id, unit_id").eq("id", leaseId).is("deleted_at", null).maybeSingle();
  if (!lease) return json(404, { error: "lease_not_found" });
  let ownerId: string | null = null;
  if (lease.unit_id) {
    const { data: unit } = await sb.from("property_units").select("owner_id").eq("id", lease.unit_id).maybeSingle();
    ownerId = (unit as any)?.owner_id ?? null;
  }

  let amountDollars = Number(b.amount);
  if (!(amountDollars > 0)) {
    const { data: led } = await sb.from("lease_ledger")
      .select("running_balance").eq("lease_id", leaseId).is("deleted_at", null)
      .order("txn_date", { ascending: false }).order("created_at", { ascending: false }).limit(1).maybeSingle();
    amountDollars = Number((led as any)?.running_balance ?? 0);
  }
  amountDollars = Math.round((Number(amountDollars) || 0) * 100) / 100;
  if (!(amountDollars > 0)) return json(400, { error: "no_balance_due" });
  const cents = Math.round(amountDollars * 100);

  const { data: rp, error: rpErr } = await sb.from("rent_payments").insert({
    company_id: lease.company_id, lease_id: leaseId, unit_id: lease.unit_id ?? null, owner_id: ownerId,
    amount: amountDollars, currency: "usd", status: "processing", provider: "stripe",
    memo: "Online rent payment (Stripe Checkout)", created_by: userId,
  }).select("id").single();
  if (rpErr) return json(500, { error: "could_not_stage_payment", detail: rpErr.message });

  const form = new URLSearchParams();
  form.set("mode", "payment");
  form.set("success_url", `${origin}/portal/tenant?payment=success`);
  form.set("cancel_url", `${origin}/portal/tenant?payment=cancelled`);
  form.set("client_reference_id", rp.id);
  form.set("line_items[0][quantity]", "1");
  form.set("line_items[0][price_data][currency]", "usd");
  form.set("line_items[0][price_data][unit_amount]", String(cents));
  form.set("line_items[0][price_data][product_data][name]", "Rent payment");
  form.set("metadata[rent_payment_id]", rp.id);
  form.set("metadata[lease_id]", leaseId);
  form.set("metadata[company_id]", lease.company_id);
  form.set("payment_intent_data[metadata][rent_payment_id]", rp.id);

  let session: any;
  try {
    const res = await fetch(`${STRIPE_BASE}/checkout/sessions`, {
      method: "POST",
      headers: { "Authorization": `Bearer ${sk}`, "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const text = await res.text();
    if (res.status < 200 || res.status >= 300) {
      await sb.from("rent_payments").update({ status: "failed", memo: "Stripe session error" }).eq("id", rp.id);
      return json(502, { error: "stripe_error", status: res.status, detail: text.slice(0, 400) });
    }
    session = JSON.parse(text);
  } catch (e) {
    await sb.from("rent_payments").update({ status: "failed" }).eq("id", rp.id);
    return json(502, { error: "stripe_unreachable", detail: String((e as Error).message).slice(0, 200) });
  }

  await sb.from("rent_payments").update({ provider_payment_id: session.id }).eq("id", rp.id);
  return json(200, { ok: true, url: session.url, rent_payment_id: rp.id, amount: amountDollars });
});
