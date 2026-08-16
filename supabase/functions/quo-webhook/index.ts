import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Transit & Flow - Quo webhook v20
//
// v20: PATTERN O. THE FUNCTION ANSWERED BEFORE IT HAD READ THE REQUEST BODY.
//
//      Four return paths sat above the body read: the GET banner, the 405 for a non-POST, the 503
//      when the webhook token could not be read from the Vault, and the 401 for a bad token. Every
//      one of them wrote a response and returned while the client was still uploading. On this
//      platform that is not a harmless early exit. Measured here: when the response is written
//      before the body has been consumed and the client body is around 590,000 bytes, the body
//      still uploads IN FULL and the client then receives NO RESPONSE AT ALL, reproduced hanging at
//      12s, 25s, 40s and 60s. Bodies at or below roughly 580,000 bytes answer cleanly, so the
//      boundary is the socket and proxy buffer, not any documented platform size limit.
//
//      Nothing in a small-body smoke test can see this. A 2 KB POST passes every time, which is
//      exactly why the defect survived nineteen versions. The payload that hits it is a large
//      provider delivery (MMS metadata, a batched or replayed webhook), and because the caller never
//      gets an answer it retries, so the first casualty is a duplicate inbound message rather than a
//      visible error.
//
//      The fix is structural rather than per-site, because a per-site drain is one edit away from
//      being wrong again. The handler is now a plain function and Deno.serve wraps it, so every
//      return path in the function, including those four and the catch-all for an unhandled throw,
//      lands in one place that drains the request body before the response goes back. No early
//      return can answer a large body without consuming it, and a new one cannot be added by
//      accident.
//
//      Also in this pass: the Vault-read 503 now carries Retry-After, and a webhook token that
//      reads back empty is answered 503 rather than 401. A null is not an answer. A permanent 4xx
//      tells a healthy caller to stop retrying a condition that is ours to fix, and it points the
//      investigation at the caller's credentials instead of at our own secret store.
//
// v19: THE FUNCTION WAS CONFIRMING WRITES IT NEVER CHECKED.
//
//      supabase-js does not throw when a write fails. It returns { data, error }. Eleven consecutive
//      job and assignment writes in the dispatch-command block were issued as bare .update() calls
//      with { error } discarded, and every one of them was immediately followed by an SMS telling the
//      technician the state had changed:
//
//        "[ok] You got TF-1042!"         while the job stayed unassigned on the board
//        "[ok] ETA logged"               while dispatch still had no ETA
//        "[ok] Marked on-site"           while the job still showed en_route
//        "[cal] Flagged for reschedule"  while the job stayed live on today's schedule
//
//      That is the worst possible failure shape for a field business. Dispatch sees an idle job and
//      re-offers it while a technician is standing in the customer's driveway believing he is logged
//      in, and the customer gets two trucks or none. Two of those handlers also issued two writes that
//      must move together (the reschedule flag and its history row; the declined assignment and the
//      job's needs_reschedule flag), so a failure between them left the record permanently half-changed.
//
//      Every one of those sites now goes through the migration-255 server-side commands
//      (tf_dispatch_mark_dispatched / _set_eta / _mark_on_site / _request_reschedule /
//      _decline_assignment). Each takes a row lock, validates the transition instead of assuming it,
//      writes the job_status_history row that the ad-hoc updates never wrote at all, and returns a
//      jsonb result. This function now INSPECTS that result and only sends the confirming SMS when
//      the write actually landed. When it did not, the technician is told plainly that nothing
//      changed and to call dispatch, and dispatch is paged. Silence is not an option in either
//      direction: a technician who thinks he is assigned and a dispatcher who thinks nobody is are
//      the same incident seen from two ends.
//
//      Also fixed in this pass:
//        - The bare-YES/NO handler filtered candidate jobs against ["completed","closed","cancelled",
//          "invoiced","on_hold"]. There is no 'completed' value in the job_status enum, so that entry
//          matched nothing, and the list omitted work_complete, pending_signoff and signed_off. A bare
//          "YES" could therefore act on a job that was already finished and signed off. Replaced with
//          an explicit ALLOWLIST of pre-completion statuses, which also fails safe if the enum grows.
//        - Consent screening (tf_consent_inbound_keyword) discarded its error. An RPC failure left
//          kw null, and the message fell through into lead creation and AI routing: a customer texting
//          STOP became a sales lead. It now fails CLOSED. If the screen cannot run, the message is
//          logged, compliance is paged (throttled to one page per 15 minutes so a sustained outage does
//          not become a paging storm), and the function stops before any commercial workflow or send.
//        - sendSmsFrom ignored Quo's HTTP response and logged status 'sent' regardless, then discarded
//          the { error } on both communications inserts. A rejected send was recorded as delivered.
//          The response is now inspected, a rejection is written as status 'failed' with the HTTP
//          detail, and the provider message id is captured so delivery receipts can match the row.
//        - The final inbound communications insert is checked. An inbound customer message that never
//          reaches the inbox is invisible to every human in the company, so a failure pages dispatch
//          with the message text so somebody can act on it from the page itself.
//        - Attachment rows: 'saved' incremented even when the job_attachments insert failed, leaving a
//          file in storage that no job references and a text claiming it was filed. Now counted only
//          when the row lands.
//        - tf_claim_job, tf_decline_offer, tf_capture_rating_by_phone, the review_requests update, the
//          missed-call lead insert, the delivery-receipt update and the integration config read all
//          check their errors.
//
// v18: consent enforcement on the live two-way SMS path.
//      (1) Inbound capture - every inbound message is screened by tf_consent_inbound_keyword before
//          command parsing, lead creation or AI routing. A matched keyword (STOP/UNSUBSCRIBE/CANCEL/
//          END/QUIT/OPTOUT/REVOKE, START/UNSTOP/RESUME, HELP/INFO) writes the opt_outs and
//          consent_records ledger, is logged to the inbox, and returns. A STOP is a legal instruction,
//          not a sales inquiry, so it never manufactures a lead or pages dispatch. Matching is on the
//          entire trimmed message, so "please cancel my appointment" does not unsubscribe a customer.
//      (2) Outbound gate - every send now routes through tf_consent_gate before a byte reaches Quo,
//          including the missed-call text-back. The gate is fail-closed: an unreachable gate, an
//          unparseable destination or a standing opt-out all resolve to "do not send", and the refusal
//          is written to communications with status 'blocked_no_consent' so there is a durable record
//          that we declined rather than a silent absence. There is no bypass flag by design.
//      We deliberately do NOT auto-send the STOP/START/HELP confirmation here: the 10DLC carrier layer
//      emits it, and a second reply from us would be a duplicate to a number the carrier has already
//      blocked. The exact compliant wording is stored on the communications row for any caller that
//      owns the reply.
// v17: delivery/status receipts (message.delivered/sent/failed) update the existing row's status instead of
//      logging a duplicate outbound row (was double-listing every sent message in the customer thread).
// v16: bare yes/no tech replies. v15: ETA date-helper fix. v14: missed-call text-back (gated OFF).

const COMPANY_ID = "ff000000-0000-4000-b000-000000000001";
const QUO_BASE = "https://api.quo.com";
const ARRIVAL_WINDOW_HOURS = 2;
const LATE_PENALTY_PCT = 15;
const DISPATCH_PHONE = "(614) 333-8092";

// Statuses on which a bare "YES"/"NO" from a technician may still act. This is an ALLOWLIST, not a
// terminal-status blocklist: the previous blocklist named 'completed', which is not a value in the
// job_status enum and therefore matched nothing, while omitting work_complete, pending_signoff and
// signed_off. An allowlist also fails safe when the enum grows, since an unrecognized future status
// is simply not actionable and the technician is told to name the job explicitly.
const BARE_ACTIONABLE_STATUSES = new Set([
  "draft", "intake", "scheduled", "dispatched", "en_route", "on_site",
  "in_progress", "pending_estimate", "awaiting_approval",
]);

function extFromType(t: string): string { if (t.includes("jpeg")||t.includes("jpg")) return "jpg"; if (t.includes("png")) return "png"; if (t.includes("webp")) return "webp"; if (t.includes("heic")) return "heic"; if (t.includes("heif")) return "heif"; if (t.includes("mp4")) return "mp4"; if (t.includes("quicktime")) return "mov"; if (t.includes("pdf")) return "pdf"; return "bin"; }
function kindFromType(t: string): string { if (t.startsWith("image/")) return "photo"; if (t.startsWith("video/")) return "video"; if (t.includes("pdf")) return "document"; return "other"; }
function etOffsetMinutes(date: Date): number { const dtf = new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hour12: false, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" }); const p: any = Object.fromEntries(dtf.formatToParts(date).map((x) => [x.type, x.value])); const asUTC = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second); return (asUTC - date.getTime()) / 60000; }
function etTodayParts() { const dtf = new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" }); const p: any = Object.fromEntries(dtf.formatToParts(new Date()).map((x) => [x.type, x.value])); return { y: +p.year, mo: +p.month, d: +p.day }; }
function etWallToUtc(y: number, mo: number, d: number, h: number, mi: number): Date { const guess = Date.UTC(y, mo - 1, d, h, mi); const off = etOffsetMinutes(new Date(guess)); return new Date(guess - off * 60000); }
function parseEta(text: string): string | null { const t = text.toLowerCase(); const dur = t.match(/(\d{1,3})\s*(min|mins|minute|minutes|hr|hrs|hour|hours)/); if (dur) { const n = parseInt(dur[1], 10); const mins = dur[2].startsWith("h") ? n * 60 : n; if (mins > 0 && mins <= 24 * 60) return new Date(Date.now() + mins * 60000).toISOString(); } const clk = t.match(/(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)/); if (clk) { let h = parseInt(clk[1], 10); const mi = clk[2] ? parseInt(clk[2], 10) : 0; const pm = clk[3].startsWith("p"); if (h === 12) h = pm ? 12 : 0; else if (pm) h += 12; if (h >= 0 && h < 24 && mi < 60) { const { y, mo, d } = etTodayParts(); let dt = etWallToUtc(y, mo, d, h, mi); if (dt.getTime() < Date.now() - 30 * 60000) dt = new Date(dt.getTime() + 24 * 3600000); return dt.toISOString(); } } return null; }
function etTime(iso: string | null | undefined): string { if (!iso) return "the agreed time"; try { return new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hour12: true, hour: "numeric", minute: "2-digit" }).format(new Date(iso)); } catch { return "the agreed time"; } }
const JOBTOK = "([A-Za-z]{2,6}-?[A-Za-z0-9-]{2,})";

// Hoisted to module scope in v20 so the Deno.serve wrapper at the bottom of this file can answer an
// unhandled throw with the same JSON shape every other return path uses. The optional third argument
// is additive: existing call sites are unchanged, and it exists so a retryable failure can carry
// Retry-After.
const json = (s: number, o: unknown, extraHeaders?: Record<string, string>) => new Response(JSON.stringify(o), { status: s, headers: { "Content-Type": "application/json", ...(extraHeaders ?? {}) } });

async function handle(req: Request): Promise<Response> {
  if (req.method === "GET") return json(200, { ok: true, service: "quo-webhook", version: 23, consent_gate: "tf_consent_gate", consent_capture: "tf_consent_inbound_keyword", body_drain: "the handler is wrapped, so every return path drains the request body", dispatch_commands: "migration 255 (tf_dispatch_*)", inbound_paging: "tf_page_inbound_sms classifies the event key server side (m335); this function never names one" });
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const url = new URL(req.url);
  const { data: expected, error: tokErr } = await sb.rpc("get_secret", { p_name: "quo_webhook_token" });
  // A Vault read failure must not become an open door. No token, no entry.
  // Pattern E. A read that failed and a read that came back empty are both conditions on our side,
  // not a verdict on the caller's credentials, so both answer 503 with Retry-After. A 401 here would
  // tell a correctly configured caller that its token is wrong and to stop retrying.
  if (tokErr) { console.error("quo-webhook could not read quo_webhook_token:", tokErr.message); return json(503, { error: "auth_unavailable" }, { "Retry-After": "30" }); }
  if (!expected) { console.error("quo-webhook read quo_webhook_token as empty"); return json(503, { error: "auth_unavailable" }, { "Retry-After": "30" }); }
  if ((url.searchParams.get("token") ?? "") !== expected) return json(401, { error: "Unauthorized" });

  // ---- Paging helpers. tf_page_staff resolves recipients so the role list cannot drift. ----
  async function pageStaff(scope: string, eventKey: string, subject: string, msg: string, entityType: string | null, entityId: string | null) {
    try {
      const { error: pErr } = await sb.rpc("tf_page_staff", {
        p_company_id: COMPANY_ID, p_scope: scope, p_event_key: eventKey,
        p_subject: subject, p_body: msg,
        p_entity_type: entityType, p_entity_id: entityId,
      });
      if (pErr) console.error(`tf_page_staff (${eventKey}) failed:`, pErr.message);
    } catch (e) { console.error(`page ${eventKey} threw:`, String((e as Error).message)); }
  }
  // Throttle for pages that a sustained outage would otherwise repeat on every inbound message.
  // Fails OPEN: if the limiter itself is unreachable we would rather page twice than stay silent.
  async function pageAllowed(bucket: string, subject: string, limit: number, windowSec: number): Promise<boolean> {
    try {
      const { data, error } = await sb.rpc("tf_rate_limit_hit", { p_company_id: COMPANY_ID, p_bucket: bucket, p_subject: subject, p_limit: limit, p_window_seconds: windowSec });
      if (error) return true;
      return (data as any)?.allowed !== false;
    } catch { return true; }
  }

  let evt: any; try { evt = await req.json(); } catch { return json(400, { error: "Invalid JSON" }); }
  const type: string = evt?.type ?? evt?.event ?? "unknown";
  const data = evt?.data?.object ?? evt?.data ?? evt ?? {};
  if (!String(type).includes("message") && !String(type).includes("call")) return json(200, { ok: true, ignored: type });

  // Delivery/status receipts for messages WE sent: update status on the existing row, never create a duplicate.
  if (/message\.(delivered|sent|failed|undelivered)/i.test(String(type))) {
    const pmid = data.id ?? null;
    let updated = false;
    if (pmid) {
      const ns = /delivered/i.test(String(type)) ? "delivered" : /failed|undelivered/i.test(String(type)) ? "failed" : "sent";
      // The { error } here used to be discarded, so a receipt that never landed still answered ok.
      // A missed 'failed' receipt is the one that matters: it means a customer or technician never
      // got a message we believe we sent, and nothing in the thread would ever say so.
      const { error: rcErr } = await sb.from("communications").update({ status: ns, updated_at: new Date().toISOString() }).eq("company_id", COMPANY_ID).eq("provider_message_id", pmid);
      if (rcErr) {
        console.error("quo-webhook receipt update failed:", rcErr.message);
        if (ns === "failed" && await pageAllowed("quo_receipt_page", "receipt", 4, 900)) {
          await pageStaff("dispatch", "sms_receipt_not_recorded", "⚠️ An SMS delivery FAILURE could not be recorded",
            `Quo reported that message ${pmid} was not delivered, and writing that failure to the thread errored: ${rcErr.message}. The message still shows as sent in the inbox. Whoever was expecting that text did not get it.`, "communications", null);
        }
      } else { updated = true; }
      return json(rcErr ? 500 : 200, { ok: !rcErr, status_event: type, recorded: updated });
    }
    return json(200, { ok: true, status_event: type, recorded: false, reason: "no_provider_message_id" });
  }

  const fromNum: string = data.from ?? data.fromNumber ?? "";
  const toNum: string = Array.isArray(data.to) ? data.to[0] : (data.to ?? "");
  const body: string = String(data.body ?? data.text ?? data.content ?? "").slice(0, 2000);
  const msgId: string | null = data.id ?? null;
  const direction: string = (data.direction ?? "").includes("out") ? "outbound" : "inbound";
  const mediaRaw = data.media ?? data.attachments ?? [];
  const media: { url: string; type: string }[] = (Array.isArray(mediaRaw) ? mediaRaw : []).map((m: any) => ({ url: typeof m === "string" ? m : (m?.url ?? ""), type: (typeof m === "object" ? (m?.type ?? m?.contentType ?? "") : "") || "image/jpeg" })).filter((m) => m.url);

  const digits = String(fromNum).replace(/\D/g, "").slice(-10);
  const phonePat = digits.length === 10 ? `%${digits.slice(0,3)}%${digits.slice(3,6)}%${digits.slice(6)}%` : null;

  // A failed config read used to collapse silently to nulls, which turned every outbound send into a
  // quiet "not_configured" and disabled the AI line and the review link with no signal anywhere.
  const { data: cfgRow, error: cfgErr } = await sb.from("integration_settings").select("config").eq("company_id", COMPANY_ID).eq("provider", "openphone").maybeSingle();
  if (cfgErr) {
    console.error("quo-webhook could not read integration config:", cfgErr.message);
    if (await pageAllowed("quo_cfg_page", "openphone", 1, 900)) {
      await pageStaff("dispatch", "sms_config_unreadable", "⚠️ SMS configuration could not be read",
        `quo-webhook could not read the openphone integration settings row: ${cfgErr.message}. Until this clears, no outbound SMS can be sent from this function (no from-number), the AI line will not route, and review links will not go out. Inbound messages are still being logged.`, "integration_settings", null);
    }
  }
  const fromNumber = cfgRow?.config?.from_number ?? null;
  const reviewUrl = cfgRow?.config?.google_review_url ?? null;
  const aiBookingOn = cfgRow?.config?.automations?.ai_booking === true;
  const aiLine = cfgRow?.config?.ai_line_number ?? null;
  const { data: quoKey, error: quoKeyErr } = await sb.rpc("get_secret", { p_name: "quo_api_key" });
  if (quoKeyErr) console.error("quo-webhook could not read quo_api_key:", quoKeyErr.message);

  // ---- Consent keyword capture. Runs before command parsing, lead creation or any AI routing. ----
  // This is the first thing that happens to an inbound message because a compliance instruction
  // outranks every commercial workflow below it.
  if (direction === "inbound" && String(type).includes("message") && body && fromNum) {
    let kw: any = null; let kwFailure: string | null = null;
    try {
      const { data: kwData, error: kwRpcErr } = await sb.rpc("tf_consent_inbound_keyword", { p_contact: String(fromNum), p_body: body, p_channel: "sms", p_company_id: COMPANY_ID });
      if (kwRpcErr) kwFailure = kwRpcErr.message; else kw = kwData;
    } catch (e) { kwFailure = String((e as Error).message); }

    // FAIL CLOSED. The old code swallowed this error and fell through, so a customer texting STOP
    // during an outage became a sales lead, got paged to dispatch, and could be texted again. We
    // would rather hold a message for a human than answer one we were told to stop answering.
    if (kwFailure) {
      const { error: logErr } = await sb.from("communications").insert({
        company_id: COMPANY_ID, direction: "inbound", channel: "sms", provider: "quo",
        from_number: fromNum || null, to_number: toNum || null, body, status: "received",
        provider_message_id: msgId, conversation_id: data.conversationId ?? null,
        meta: { event_type: type, sender_kind: "unscreened", consent_check: "unavailable", consent_error: kwFailure.slice(0, 300), line: "main" },
      });
      if (logErr) console.error("quo-webhook could not log an unscreened inbound message:", logErr.message);
      if (await pageAllowed("quo_consent_page", "screen", 1, 900)) {
        await pageStaff("compliance", "consent_screen_unavailable", "🚨 Consent screening is DOWN, inbound SMS is being held",
          `tf_consent_inbound_keyword failed: ${kwFailure.slice(0, 300)}\n\nquo-webhook is refusing to process inbound SMS until this clears, because it cannot tell a STOP from a service request and must not answer someone who has opted out. Messages are still being written to the inbox${logErr ? ", EXCEPT this one, whose insert also failed: " + logErr.message : ""}. Work the inbox manually and call ${DISPATCH_PHONE} customers back by phone until this is fixed.\n\nHeld message from ${fromNum}: ${body.slice(0, 400)}`,
          "communications", null);
      }
      return json(503, { ok: false, error: "consent_check_unavailable", logged: !logErr, note: "Message held. No lead created, no AI routing, no outbound send." });
    }

    if (kw?.matched) {
      const { error: kwErr } = await sb.from("communications").insert({
        company_id: COMPANY_ID, direction: "inbound", channel: "sms", provider: "quo",
        from_number: fromNum || null, to_number: toNum || null, body, status: "received",
        provider_message_id: msgId, conversation_id: data.conversationId ?? null,
        meta: { event_type: type, sender_kind: "consent", consent_action: kw.action ?? null, consent_keyword: kw.keyword ?? null, compliance_reply: kw.reply ?? null, line: "main" },
      });
      // The ledger write (opt_outs / consent_records) is what makes the opt-out legally effective and
      // it already succeeded inside the RPC. This insert is the human-visible copy in the inbox, so a
      // failure is not a compliance breach, but it does mean nobody will see the customer's message.
      if (kwErr) {
        console.error("quo-webhook could not log a consent message:", kwErr.message);
        await pageStaff("compliance", "consent_message_not_logged", "⚠️ A consent message was recorded in the ledger but not in the inbox",
          `${fromNum} sent "${body.slice(0, 200)}" (action: ${kw.action ?? "unknown"}). The opt-out ledger was updated correctly, so the preference IS in force. Writing the copy to the message thread failed: ${kwErr.message}`, "communications", null);
      }
      return json(200, { ok: true, consent: { action: kw.action, keyword: kw.keyword }, logged: !kwErr, auto_replied: false, note: "Consent keyword handled by the ledger. No lead created, no dispatch page, no auto-reply (carrier emits it)." });
    }
  }

  // ---- Gated outbound. Nothing leaves this function without a consent decision. ----
  // Technician dispatch traffic and direct replies to a customer-initiated message are 'transactional';
  // the Google review ask is 'review_request'. Nothing on this path is marketing. A gate that cannot be
  // reached is a gate that says no: under-sending is recoverable, texting an opted-out number is not.
  async function sendSmsFrom(from: string | null, to: string, content: string, kind = "command_reply", purpose = "transactional") {
    try {
      if (!quoKey || !from || !to) return { sent: false, reason: "not_configured" };
      let dest = String(to);
      const { data: gate, error: gateErr } = await sb.rpc("tf_consent_gate", { p_contact: dest, p_channel: "sms", p_purpose: purpose, p_caller: "quo-webhook", p_body: content, p_company_id: COMPANY_ID });
      if (gateErr || !gate || (gate as any).allowed !== true) {
        const reason = gateErr ? `gate_unavailable: ${String(gateErr.message ?? "").slice(0, 160)}` : String((gate as any)?.reason ?? "blocked");
        const { error: blkErr } = await sb.from("communications").insert({ company_id: COMPANY_ID, direction: "outbound", channel: "sms", provider: "consent_gate", from_number: from, to_number: dest, body: content, status: "blocked_no_consent", error: reason, meta: { kind, purpose, consent_reason: (gate as any)?.reason ?? null, consent_audit_id: (gate as any)?.audit_id ?? null } });
        if (blkErr) console.error("quo-webhook could not record a blocked send:", blkErr.message);
        return { sent: false, reason };
      }
      if ((gate as any).contact) dest = String((gate as any).contact);

      // v18 fired this and never looked at the answer, then wrote status 'sent' unconditionally. A
      // 401 from an expired key, a 400 from a malformed number and a successful send were all
      // indistinguishable in the thread.
      const resp = await fetch(`${QUO_BASE}/v1/messages`, { method: "POST", headers: { "Authorization": quoKey as string, "Content-Type": "application/json" }, body: JSON.stringify({ from, to: [dest], content }) });
      if (!resp.ok) {
        const detail = await resp.text().then((t) => t.slice(0, 300)).catch(() => "");
        const { error: failErr } = await sb.from("communications").insert({ company_id: COMPANY_ID, direction: "outbound", channel: "sms", provider: "quo", from_number: from, to_number: dest, body: content, status: "failed", error: `quo_http_${resp.status}: ${detail}`, meta: { kind, purpose, consent_reason: (gate as any).reason ?? null } });
        if (failErr) console.error("quo-webhook could not record a failed send:", failErr.message);
        console.error(`quo send rejected: HTTP ${resp.status} ${detail}`);
        return { sent: false, reason: `quo_http_${resp.status}` };
      }
      // Capture the provider id so the delivery receipt above can find this row instead of updating
      // nothing. Without it every receipt is a no-op and the thread never shows a delivery failure.
      let providerId: string | null = null;
      try { const j: any = await resp.json(); providerId = j?.data?.id ?? j?.id ?? null; } catch { /* a body we cannot parse is not a failed send */ }
      const { error: okErr } = await sb.from("communications").insert({ company_id: COMPANY_ID, direction: "outbound", channel: "sms", provider: "quo", from_number: from, to_number: dest, body: content, status: "sent", provider_message_id: providerId, meta: { kind, purpose, consent_reason: (gate as any).reason ?? null } });
      if (okErr) console.error("quo-webhook sent an SMS it could not log:", okErr.message);
      return { sent: true, logged: !okErr };
    } catch (e) { console.error("quo send threw:", String((e as Error).message)); return { sent: false, reason: "send_error" }; }
  }
  async function sendSms(to: string, content: string, kind = "command_reply", purpose = "transactional") { return await sendSmsFrom(fromNumber, to, content, kind, purpose); }
  // Field traffic from technicians (claims, ETAs, arrivals) goes to the 'dispatch' audience.
  async function notifyOffice(subject: string, msg: string, jid: string | null) {
    await pageStaff("dispatch", "tech_update", subject, msg, jid ? "jobs" : null, jid);
  }
  // Inbound traffic that is NOT a technician command. This deliberately takes no
  // event key: tf_page_inbound_sms (m335) classifies the body server side and
  // chooses it. The old code hardcoded "tech_update" here, which routes to
  // audience 'suppressed' at severity 'low', so eight answering-service call
  // intakes, seven of them flagged "Emergency Y or N: Yes", were recorded in the
  // Hub and shown to nobody. Regression assertion A18 now walks this whole path.
  // The body is passed WHOLE. The 280 character slice this replaced cut the
  // intake off mid address, which is the part a dispatcher needs; the renderer,
  // not the transport, decides what a person finally sees.
  async function pageInboundSms(from: string | null, msg: string, jid: string | null) {
    try {
      const { error: pErr } = await sb.rpc("tf_page_inbound_sms", {
        p_company_id: COMPANY_ID,
        p_from: from ?? null,
        p_body: msg ?? null,
        p_entity_type: jid ? "jobs" : null,
        p_entity_id: jid ?? null,
      });
      if (pErr) console.error("tf_page_inbound_sms failed:", pErr.message);
    } catch (e) { console.error("page inbound_sms threw:", String((e as Error).message)); }
  }

  // ---- Server-side dispatch commands (migration 255). ----
  // Every one of these replaces a bare .update() whose { error } was discarded. The RPC takes a row
  // lock, validates the transition, writes job_status_history, and returns { ok, ... }. This wrapper
  // normalizes the three ways it can fail (transport error, thrown exception, non-object body) into
  // the same shape so no call site can accidentally treat a failure as a success.
  async function dispatchRpc(fn: string, args: Record<string, unknown>): Promise<any> {
    try {
      const { data: r, error } = await sb.rpc(fn, args);
      if (error) { console.error(`${fn} failed:`, error.message); return { ok: false, reason: "rpc_error", error: error.message }; }
      if (!r || typeof r !== "object") { console.error(`${fn} returned no result`); return { ok: false, reason: "rpc_empty" }; }
      return r;
    } catch (e) { console.error(`${fn} threw:`, String((e as Error).message)); return { ok: false, reason: "rpc_threw", error: String((e as Error).message) }; }
  }

  // The single most important behaviour change in v19: when a dispatch write does not land, the
  // technician is told the truth instead of a checkmark, and a human is paged. Getting no reply would
  // be almost as bad as a false one, because he would assume it worked.
  async function dispatchWriteFailed(action: string, jobNum: string | null, jid: string | null, r: any) {
    const detail = `${r?.reason ?? "unknown"}${r?.error ? ": " + String(r.error).slice(0, 300) : ""}`;
    console.error(`quo-webhook dispatch write failed (${action}) for ${jobNum ?? jid ?? "unknown job"}: ${detail}`);
    await sendSms(fromNum, `⚠️ We could NOT record that for ${jobNum ?? "your job"}. Nothing has changed on the board, so please don't assume it went through. Call dispatch at ${DISPATCH_PHONE} and we'll log it manually.`, "command_failed");
    await pageStaff("dispatch", "dispatch_command_not_recorded",
      `🚨 ${jobNum ?? "A job"}: technician's "${action}" did NOT save`,
      `${fromNum} texted a ${action} for ${jobNum ?? jid ?? "an unknown job"} and the write failed: ${detail}\n\nThe job board is UNCHANGED. The technician has been told to call ${DISPATCH_PHONE}. Update the job by hand and confirm with him directly. Do not assume he is en route or on site.\n\nOriginal message: ${body.slice(0, 300)}`,
      jid ? "jobs" : null, jid);
  }

  async function findJob(jn: string) {
    const { data, error } = await sb.from("jobs").select("id, job_number, customer_id, status, arrival_by, arrival_window_start, arrival_window_end").eq("company_id", COMPANY_ID).or(`job_number.ilike.${jn},legacy_job_number.ilike.${jn}`).is("deleted_at", null).limit(1);
    if (error) { console.error("findJob failed:", error.message); return null; }
    return data?.[0] ?? null;
  }
  async function findTech(): Promise<string | null> {
    if (!phonePat) return null;
    const { data, error } = await sb.from("technicians").select("id").eq("company_id", COMPANY_ID).is("deleted_at", null).ilike("phone", phonePat).limit(1);
    if (error) { console.error("findTech failed:", error.message); return null; }
    return data?.[0]?.id ?? null;
  }

  async function acceptOfferedJob(job: any, techId: string) {
    const { data: res, error: claimErr } = await sb.rpc("tf_claim_job", { p_job_id: job.id, p_technician_id: techId });
    if (claimErr) {
      await dispatchWriteFailed("job claim", job.job_number, job.id, { reason: "rpc_error", error: claimErr.message });
      return "write_failed";
    }
    const result = (res as any)?.result;
    if (result === "accepted") {
      // Propose the customer window end when we have one, otherwise a 2-hour commitment from now.
      // The RPC will keep any arrival commitment already made to the customer in preference to this,
      // and returns the value it actually stored, so the text below quotes reality rather than intent.
      const proposed: string = job.arrival_window_end ?? new Date(Date.now() + ARRIVAL_WINDOW_HOURS * 3600000).toISOString();
      const d = await dispatchRpc("tf_dispatch_mark_dispatched", { p_company_id: COMPANY_ID, p_job_id: job.id, p_arrival_by: proposed, p_technician_id: techId });
      if (d?.ok !== true) { await dispatchWriteFailed("job acceptance", job.job_number, job.id, d); return "write_failed"; }
      const arrivalBy: string | null = d.arrival_by ?? proposed;
      const windowText = (job.arrival_window_start && arrivalBy && arrivalBy === job.arrival_window_end)
        ? `the customer window ${etTime(job.arrival_window_start)}–${etTime(arrivalBy)}`
        : `within ${ARRIVAL_WINDOW_HOURS} hours (by ${etTime(arrivalBy)})`;
      await sendSms(fromNum, `✅ You got ${job.job_number}! Your pay if completed: $${Number((res as any).expected_pay ?? 0).toFixed(2)}. You MUST arrive in ${windowText}. Not on site by then without notice = ${LATE_PENALTY_PCT}% pay penalty. Reply \"ETA ${job.job_number} 45 min\" with your ETA, and \"ARRIVED ${job.job_number}\" when you're on site.`, "job_won");
      for (const loser of ((res as any).losers ?? [])) { if (loser && loser !== fromNum) await sendSms(loser, `Job ${job.job_number} has been filled. Thanks for the fast response, we'll send the next one.`, "job_filled"); }
      await notifyOffice(`🤝 ${job.job_number} accepted`, `Claimed via SMS. Arrival by ${etTime(arrivalBy)} (${LATE_PENALTY_PCT}% late penalty). Dispatched.`, job.id);
      return "accepted";
    } else if (result === "already_filled") { await sendSms(fromNum, `Sorry, ${job.job_number} was just filled by another tech. We'll send the next one.`, "job_filled"); return "already_filled"; }
    await sendSms(fromNum, `You're not on the offer list for ${job.job_number}. Contact dispatch.`); return "invalid";
  }

  // Confirm an assignment the technician already holds (bare YES on an accepted offer).
  async function confirmAssignedJob(job: any, techId: string) {
    const proposed: string = job.arrival_window_end ?? new Date(Date.now() + ARRIVAL_WINDOW_HOURS * 3600000).toISOString();
    const d = await dispatchRpc("tf_dispatch_mark_dispatched", { p_company_id: COMPANY_ID, p_job_id: job.id, p_arrival_by: proposed, p_technician_id: techId });
    if (d?.ok !== true) { await dispatchWriteFailed("assignment confirmation", job.job_number, job.id, d); return false; }
    const arrivalBy: string | null = d.arrival_by ?? proposed;
    const windowText = (job.arrival_window_start && arrivalBy && arrivalBy === job.arrival_window_end)
      ? `arrival window ${etTime(job.arrival_window_start)}–${etTime(arrivalBy)}`
      : `arrival by ${etTime(arrivalBy)}`;
    await sendSms(fromNum, `✅ Confirmed, you've got ${job.job_number}. ${windowText}. Reply \"ETA ${job.job_number} 45 min\" with your ETA, and \"ARRIVED ${job.job_number}\" when you're on site.`, "job_confirmed");
    await notifyOffice(`🤝 ${job.job_number} confirmed`, `Technician confirmed the assignment via SMS (YES).`, job.id);
    return true;
  }

  let command: any = null; let jobId: string | null = null; let jobNumber: string | null = null; let customerId: string | null = null; let senderKind = "unknown"; let aiHandled = false;

  // ---- Missed-call text-back (gated by config.automations.missed_call_textback) ----
  if (String(type).includes("call")) {
    const missedOn = cfgRow?.config?.automations?.missed_call_textback === true;
    const callDir = String(data.direction ?? data.callDirection ?? "").toLowerCase();
    const answeredAt = data.answeredAt ?? data.answered_at ?? null;
    const isInbound = callDir.includes("in") || (!callDir && String(data.from ?? "") !== String(fromNumber));
    const terminal = String(type).includes("completed") || String(type).includes("missed");
    const wasMissed = isInbound && terminal && !answeredAt;
    if (!missedOn || !wasMissed || !phonePat || !quoKey || !fromNumber) return json(200, { ok: true, call: type, acted: false });
    const since = new Date(Date.now() - 30 * 60000).toISOString();
    const { data: recent, error: recentErr } = await sb.from("communications").select("id").eq("company_id", COMPANY_ID).eq("to_number", fromNum).eq("meta->>kind", "missed_call_textback").gte("created_at", since).limit(1);
    // A failed dedupe read must not become a text loop. Treat "cannot tell" as "already texted".
    if (recentErr) { console.error("missed-call dedupe read failed:", recentErr.message); return json(500, { ok: false, call: type, acted: false, reason: "dedupe_unavailable" }); }
    if (recent?.length) return json(200, { ok: true, call: type, acted: false, reason: "recent_textback" });
    const callToDigits = String(toNum).replace(/\D/g, "").slice(-10);
    const useAiLine = !!aiLine && callToDigits && callToDigits === String(aiLine).replace(/\D/g, "").slice(-10);
    const sendFromNum = useAiLine ? aiLine : fromNumber;
    const text = "Hi, this is Transit & Flow. Sorry we missed your call! What can we help you with today? Reply here and we'll get you taken care of right away.";
    // Gated: a caller who has opted out of texts does not get an automated text back, even though
    // they just dialed us. The blocked attempt is still recorded, which also suppresses the 30-minute
    // retry above, so we do not re-litigate the same refusal on every subsequent missed call.
    const textback = await sendSmsFrom(sendFromNum, fromNum, text, "missed_call_textback", "transactional");
    let leadId2: string | null = null;
    const openFilter = "(won,lost,invalid,spam,duplicate,refunded,closed,appointment_scheduled,appointment_confirmed,job_created)";
    const { data: lrows, error: lreadErr } = await sb.from("leads").select("id").eq("company_id", COMPANY_ID).not("status", "in", openFilter).ilike("phone", phonePat).order("created_at", { ascending: false }).limit(1);
    if (lreadErr) console.error("missed-call lead lookup failed:", lreadErr.message);
    leadId2 = lrows?.[0]?.id ?? null;
    let leadCreateError: string | null = null;
    // Only attempt a create when the lookup actually succeeded. Creating on a failed read is how
    // duplicate leads get manufactured for the same caller.
    if (!leadId2 && !lreadErr) {
      const { data: src } = await sb.from("lead_sources").select("id").eq("company_id", COMPANY_ID).eq("key", "phone").limit(1);
      const { data: ins, error: insLeadErr } = await sb.from("leads").insert({ company_id: COMPANY_ID, source_id: src?.[0]?.id ?? null, status: "new", phone: fromNum, service_description: "Missed call, auto text-back", meta: { origin: "missed_call" } }).select("id").single();
      if (insLeadErr) { leadCreateError = insLeadErr.message; console.error("missed-call lead insert failed:", insLeadErr.message); }
      leadId2 = ins?.id ?? null;
    }
    if (leadId2 && aiBookingOn) {
      const { data: ws } = await sb.rpc("get_secret", { p_name: "tf_estimate_worker_secret" });
      if (ws) { try { await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/ai-booking`, { method: "POST", headers: { "Content-Type": "application/json", "x-worker-secret": ws as string }, body: JSON.stringify({ lead_id: leadId2 }) }); } catch { /* */ } }
    }
    // Recipients resolved by public.tf_page_staff, not by an inline roles.key filter.
    // The page now states what actually happened rather than asserting both actions succeeded.
    const lines = [
      `Missed call from ${fromNum}.`,
      textback.sent ? "Auto text-back sent." : `Auto text-back NOT sent (${textback.reason ?? "unknown"}). Call them back.`,
      leadId2 ? "A lead is on the board." : `NO LEAD WAS CREATED${leadCreateError ? " (" + leadCreateError.slice(0, 200) + ")" : ""}. This caller is not tracked anywhere. Add them by hand.`,
    ];
    await pageStaff("dispatch", "missed_call", `📞 Missed call from ${fromNum}`, lines.join(" "), leadId2 ? "leads" : null, leadId2);
    return json(200, { ok: true, call: type, missed_textback: textback.sent, blocked_reason: textback.sent ? null : (textback.reason ?? null), lead_id: leadId2, lead_created: !!leadId2 });
  }

  // ---- Dedicated AI line: qualification stays off the main team inbox ----
  const toDigits = String(toNum).replace(/\D/g, "").slice(-10);
  const aiDigits = String(aiLine ?? "").replace(/\D/g, "").slice(-10);
  if (direction === "inbound" && aiLine && toDigits && toDigits === aiDigits) {
    const { error: aiInsErr } = await sb.from("communications").insert({ company_id: COMPANY_ID, direction: "inbound", channel: "sms", provider: "quo", from_number: fromNum || null, to_number: toNum || null, body, status: "received", provider_message_id: msgId, conversation_id: data.conversationId ?? null, meta: { event_type: type, sender_kind: "lead", line: "ai" } });
    if (aiInsErr) {
      console.error("AI-line inbound insert failed:", aiInsErr.message);
      await pageStaff("dispatch", "inbound_sms_not_logged", `⚠️ An AI-line text from ${fromNum} was not saved`,
        `The message never reached the inbox (${aiInsErr.message}), so nobody will see it in the thread.\n\nFrom: ${fromNum}\nMessage: ${body.slice(0, 400)}`, "communications", null);
    }
    let routed = false;
    if (aiBookingOn && body && phonePat) {
      const openFilter = "(won,lost,invalid,spam,duplicate,refunded,closed,appointment_scheduled,appointment_confirmed,job_created)";
      const { data: lrows, error: lErr } = await sb.from("leads").select("id").eq("company_id", COMPANY_ID).not("status", "in", openFilter).ilike("phone", phonePat).order("created_at", { ascending: false }).limit(1);
      if (lErr) console.error("AI-line lead lookup failed:", lErr.message);
      const leadRowId = lrows?.[0]?.id ?? null;
      if (leadRowId) { const { data: ws } = await sb.rpc("get_secret", { p_name: "tf_estimate_worker_secret" }); if (ws) { try { const rr = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/ai-booking`, { method: "POST", headers: { "Content-Type": "application/json", "x-worker-secret": ws as string }, body: JSON.stringify({ lead_id: leadRowId }) }); routed = rr.ok; } catch { /* */ } } }
    }
    return json(200, { ok: true, ai_line: true, logged: !aiInsErr, routed });
  }

  if (direction === "inbound" && body) {
    const mAccept = body.match(new RegExp(`^\\s*(ACCEPT|CLAIM|TAKE|YES)\\s+${JOBTOK}`, "i"));
    const mDecline = body.match(new RegExp(`^\\s*(DECLINE|PASS)\\s+${JOBTOK}`, "i"));
    const mEta = body.match(new RegExp(`^\\s*ETA\\s+${JOBTOK}\\s+(.+)$`, "i"));
    const mArrived = body.match(new RegExp(`^\\s*(ARRIVED|HERE|ONSITE|ON-SITE)\\s+${JOBTOK}`, "i"));
    const mResc = body.match(new RegExp(`^\\s*(RESCHEDULE|RESCHED|MOVE)\\s+${JOBTOK}\\s*(.*)$`, "i"));
    const mBareYes = /^\s*(yes|yep|yeah|yup|y|confirm|confirmed|ok|okay|accept|accepted|will do|got it)\s*[.!]*\s*$/i.test(body);
    const mBareNo = /^\s*(no|nope|nah|n|decline|declined|pass|can'?t|cannot|cant)\s*[.!]*\s*$/i.test(body);

    if (mAccept) {
      const job = await findJob(mAccept[2]); const techId = await findTech();
      if (!job) { await sendSms(fromNum, `We couldn't find job ${mAccept[2]}.`); }
      else if (!techId) { await sendSms(fromNum, `Your number isn't linked to a technician profile yet. Contact dispatch and we'll get you set up.`); }
      else { jobId = job.id; jobNumber = job.job_number; senderKind = "technician"; const r = await acceptOfferedJob(job, techId); command = { type: r === "accepted" ? "accept" : (r === "already_filled" ? "accept_late" : (r === "write_failed" ? "accept_write_failed" : "accept_invalid")), job_number: job.job_number }; }
    } else if (mDecline) {
      const job = await findJob(mDecline[2]); const techId = await findTech();
      if (job && techId) {
        jobId = job.id; jobNumber = job.job_number; senderKind = "technician";
        const { error: decErr } = await sb.rpc("tf_decline_offer", { p_job_id: job.id, p_technician_id: techId });
        if (decErr) { command = { type: "decline_write_failed", job_number: job.job_number }; await dispatchWriteFailed("decline", job.job_number, job.id, { reason: "rpc_error", error: decErr.message }); }
        else { command = { type: "decline", job_number: job.job_number }; await sendSms(fromNum, `Got it, passed on ${job.job_number}. Thanks for the quick reply.`); }
      }
    } else if (mEta) {
      const job = await findJob(mEta[2]);
      if (job) {
        const iso = parseEta(mEta[3]);
        if (iso) {
          jobId = job.id; jobNumber = job.job_number; senderKind = "technician";
          const techId = await findTech();
          const d = await dispatchRpc("tf_dispatch_set_eta", { p_company_id: COMPANY_ID, p_job_id: job.id, p_eta: iso, p_technician_id: techId });
          if (d?.ok !== true) { command = { type: "eta_write_failed", job_number: job.job_number }; await dispatchWriteFailed("ETA", job.job_number, job.id, d); }
          else {
            command = { type: "eta", job_number: job.job_number };
            await sendSms(fromNum, `✅ ETA logged for ${job.job_number}: ${etTime(iso)}. Reminders stopped.`);
            await notifyOffice(`🚐 ETA set, ${job.job_number}`, `Technician ETA: ${etTime(iso)}.${d.status_changed ? " Job moved to en route." : ""}`, job.id);
          }
        }
        else { await sendSms(fromNum, `Couldn't read the ETA. Try \"ETA ${job.job_number} 45 min\" or \"ETA ${job.job_number} 3:15pm\".`); command = { type: "eta_unparsed" }; }
      }
    } else if (mArrived) {
      const job = await findJob(mArrived[2]);
      if (job) {
        jobId = job.id; jobNumber = job.job_number; senderKind = "technician";
        const techId = await findTech();
        const d = await dispatchRpc("tf_dispatch_mark_on_site", { p_company_id: COMPANY_ID, p_job_id: job.id, p_technician_id: techId });
        if (d?.ok !== true) { command = { type: "arrived_write_failed", job_number: job.job_number }; await dispatchWriteFailed("on-site arrival", job.job_number, job.id, d); }
        else {
          command = { type: "arrived", job_number: job.job_number };
          await sendSms(fromNum, `✅ Marked on-site for ${job.job_number}. Thanks, and have a great job!`);
          if (d.already_on_site !== true) await notifyOffice(`📍 On-site, ${job.job_number}`, `Technician marked arrival via SMS.`, job.id);
        }
      }
      else { await sendSms(fromNum, `We couldn't find job ${mArrived[2]}.`); }
    } else if (mResc) {
      const job = await findJob(mResc[2]);
      if (job) {
        const reason = (mResc[3] || "").trim().slice(0, 400);
        jobId = job.id; jobNumber = job.job_number; senderKind = "technician";
        const techId = await findTech();
        // The flag and its history row used to be two loose statements. They are one transaction now.
        const d = await dispatchRpc("tf_dispatch_request_reschedule", { p_company_id: COMPANY_ID, p_job_id: job.id, p_reason: reason || null, p_technician_id: techId });
        if (d?.ok !== true) { command = { type: "reschedule_write_failed", job_number: job.job_number }; await dispatchWriteFailed("reschedule request", job.job_number, job.id, d); }
        else {
          command = { type: "reschedule", job_number: job.job_number };
          await sendSms(fromNum, `📅 Got it, ${job.job_number} flagged for reschedule. Office notified.`);
          await notifyOffice(`⚠️ Reschedule needed, ${job.job_number}`, `Reason: ${d.reason ?? reason ?? "(none)"}. On hold, contact the customer to rebook.`, job.id);
        }
      }
    } else if (mBareYes || mBareNo) {
      const techId = await findTech();
      if (techId) {
        const { data: asgns, error: asgnErr } = await sb.from("dispatch_assignments").select("id, status, job_id, jobs!inner(id, job_number, status, arrival_by, arrival_window_start, arrival_window_end)").eq("company_id", COMPANY_ID).eq("technician_id", techId).is("deleted_at", null).in("status", ["offered", "accepted"]).order("created_at", { ascending: false }).limit(8);
        if (asgnErr) {
          // Do not tell a technician "you have no open job" because a read failed. That is how a job
          // gets silently dropped by both sides at once.
          console.error("bare yes/no assignment lookup failed:", asgnErr.message);
          senderKind = "technician"; command = { type: "bare_lookup_failed" };
          await sendSms(fromNum, `⚠️ We couldn't look up your assignments just now. Nothing has changed. Reply \"YES <job#>\" / \"NO <job#>\" or call dispatch at ${DISPATCH_PHONE}.`, "bare_lookup_failed");
          await pageStaff("dispatch", "dispatch_command_not_recorded", `🚨 Could not resolve a technician's "${mBareYes ? "YES" : "NO"}"`,
            `${fromNum} replied "${body.slice(0, 100)}" and the assignment lookup failed: ${asgnErr.message}. We do not know which job he meant and nothing was changed. Call him at ${fromNum}.`, null, null);
        } else {
          const pick: any = (asgns ?? []).find((a: any) => a.jobs && BARE_ACTIONABLE_STATUSES.has(String(a.jobs.status)));
          if (!pick) {
            senderKind = "technician"; command = { type: mBareYes ? "bare_yes_nojob" : "bare_no_nojob" };
            await sendSms(fromNum, `Thanks! We don't see an open job assigned to you right now, and dispatch will reach out if we need you. To act on a specific job, reply \"YES <job#>\" or \"NO <job#>\".`, "bare_no_open");
          } else {
            const job = pick.jobs; jobId = job.id; jobNumber = job.job_number; senderKind = "technician";
            if (mBareYes) {
              if (String(pick.status) === "offered") { const r = await acceptOfferedJob(job, techId); command = { type: r === "accepted" ? "accept" : (r === "already_filled" ? "accept_late" : (r === "write_failed" ? "accept_write_failed" : "accept_invalid")), job_number: job.job_number }; }
              else { const okc = await confirmAssignedJob(job, techId); command = { type: okc ? "confirm" : "confirm_write_failed", job_number: job.job_number }; }
            } else {
              let declined = false;
              if (String(pick.status) === "offered") {
                const { error: decErr } = await sb.rpc("tf_decline_offer", { p_job_id: job.id, p_technician_id: techId });
                if (decErr) await dispatchWriteFailed("decline", job.job_number, job.id, { reason: "rpc_error", error: decErr.message });
                else declined = true;
              } else {
                // Assignment status + the job's needs_reschedule flag used to be two loose updates.
                // One transaction now, and its result decides what the technician is told.
                const d = await dispatchRpc("tf_dispatch_decline_assignment", { p_company_id: COMPANY_ID, p_assignment_id: pick.id, p_reason: "Declined via SMS (NO)" });
                if (d?.ok !== true) await dispatchWriteFailed("decline", job.job_number, job.id, d);
                else declined = true;
              }
              command = { type: declined ? "decline" : "decline_write_failed", job_number: job.job_number };
              if (declined) {
                await sendSms(fromNum, `Got it, you're off ${job.job_number}. Thanks for the quick reply; dispatch will reassign.`, "job_declined");
                await notifyOffice(`⚠️ ${job.job_number} declined by tech`, `Technician declined via SMS (NO). Needs reassignment.`, job.id);
              }
            }
          }
        }
      }
    }
  }

  if (!jobId) { const jn = body.match(/\b((?:FNOL|HCP|TF|JOB)[A-Za-z0-9-]{2,})\b/i)?.[1]; if (jn) { const j = await findJob(jn); if (j) { jobId = j.id; jobNumber = j.job_number; customerId = j.customer_id; if (senderKind==="unknown") senderKind = "job_ref"; } } }
  if (direction === "inbound" && phonePat && !customerId && !command) { const { data: cust, error: custErr } = await sb.from("customers").select("id").eq("company_id", COMPANY_ID).is("deleted_at", null).ilike("phone", phonePat).limit(1); if (custErr) console.error("customer lookup failed:", custErr.message); if (cust?.length) { customerId = cust[0].id; if (senderKind === "unknown") senderKind = "customer"; if (!jobId) { const { data: j, error: jErr } = await sb.from("jobs").select("id, job_number").eq("company_id", COMPANY_ID).eq("customer_id", cust[0].id).is("deleted_at", null).not("status", "in", "(closed,cancelled,invoiced)").order("created_at", { ascending: false }).limit(1); if (jErr) console.error("open-job lookup failed:", jErr.message); if (j?.length) { jobId = j[0].id; jobNumber = j[0].job_number; } } } }

  // ---- Review gating: inbound 1-5 rating reply, matched to the pending review by phone ----
  if (direction === "inbound" && !command && /^[1-5]$/.test(body.trim())) {
    const rating = parseInt(body.trim(), 10);
    const { data: rr, error: rrErr } = await sb.rpc("tf_capture_rating_by_phone", { p_phone: fromNum, p_rating: rating });
    if (rrErr) {
      // A rating that is not captured is a detractor nobody calls back. Say something true to the
      // customer and put it in front of a human rather than dropping it.
      console.error("tf_capture_rating_by_phone failed:", rrErr.message);
      command = { type: "rating_write_failed", rating };
      senderKind = "customer";
      await pageStaff("dispatch", "rating_not_captured", `⭐ A ${rating}-star rating from ${fromNum} was NOT recorded`,
        `tf_capture_rating_by_phone failed: ${rrErr.message}. The customer replied "${rating}". ${rating <= 3 ? "This is a detractor and needs a call back today." : "Log it by hand and send the review link if appropriate."}`, null, null);
    } else if ((rr as any)?.ok) {
      command = { type: "rating", rating };
      senderKind = "customer";
      if (!jobId && (rr as any).job_id) { jobId = (rr as any).job_id; jobNumber = (rr as any).job_number; }
      const gurl = (rr as any).google_url ?? reviewUrl;
      if ((rr as any).is_promoter && gurl) {
        const sent = await sendSms(fromNum, `That's wonderful to hear, thank you! 🙌 If you have 30 seconds, a quick Google review would mean the world to us: ${gurl}`, "review_link", "review_request");
        // Only claim the link was sent if it was. Marking it sent after a blocked or failed send is
        // how a promoter never gets asked and the report still says we asked.
        if (sent.sent) {
          const { error: rqErr } = await sb.from("review_requests").update({ review_link_sent: true, updated_at: new Date().toISOString() }).eq("id", (rr as any).id);
          if (rqErr) console.error("review_requests update failed:", rqErr.message);
        }
      } else {
        await sendSms(fromNum, `Thank you for the honest feedback, and we're sorry we didn't hit the mark. A Transit & Flow manager will reach out personally to make it right.`, "review_recovery");
        await notifyOffice(`⭐ ${rating}-star rating, service recovery${jobNumber ? " ("+jobNumber+")" : ""}`, `Customer rated ${rating}/5. Please reach out to make it right.`, jobId);
      }
    }
  }

  let saved = 0;
  let unfiled = 0;
  // What to call the thing in the reply. Texted media is nearly always a photo of
  // the problem, and "file" reads like a helpdesk ticket.
  const allImages = media.length > 0 && media.every((m) => (m.type || "").startsWith("image/"));
  const mediaNoun = (n: number) => allImages ? (n === 1 ? "photo" : "photos") : (n === 1 ? "file" : "files");
  const mediaCount = (n: number) => n === 1 ? `your ${mediaNoun(1)}` : `your ${n} ${mediaNoun(n)}`;
  const mediaIt = (n: number) => n === 1 ? "it" : "them";
  const mediaIts = (n: number) => n === 1 ? "It's" : "They're";
  if (direction === "inbound" && media.length) {
    const folder = jobId ? `${COMPANY_ID}/${jobId}` : `${COMPANY_ID}/unfiled`;
    for (let i = 0; i < Math.min(media.length, 10); i++) {
      try {
        const resp = await fetch(media[i].url);
        if (!resp.ok) continue;
        const buf = new Uint8Array(await resp.arrayBuffer());
        if (buf.byteLength > 25 * 1024 * 1024) continue;
        const ctype = resp.headers.get("content-type") ?? media[i].type;
        const fname = `${new Date().toISOString().replace(/[:.]/g, "-")}-${i + 1}.${extFromType(ctype)}`;
        const path = `${folder}/${fname}`;
        const { error: upErr } = await sb.storage.from("job-photos").upload(path, buf, { contentType: ctype, upsert: false });
        if (upErr) { console.error("job-photo upload failed:", upErr.message); continue; }
        if (jobId) {
          // 'saved' used to increment here regardless of the insert result, so a failed row produced
          // a file in storage that no job references and a text telling the sender it was filed.
          const { error: attErr } = await sb.from("job_attachments").insert({ company_id: COMPANY_ID, job_id: jobId, kind: kindFromType(ctype), storage_path: path, file_name: fname, mime_type: ctype, file_size_bytes: buf.byteLength, caption: body ? body.slice(0, 300) : `Texted in via ${fromNum}`, taken_at: new Date().toISOString(), is_customer_visible: false });
          if (attErr) { console.error("job_attachments insert failed:", attErr.message); unfiled++; continue; }
          saved++;
        } else { unfiled++; }
      } catch (e) { console.error("media handling threw:", String((e as Error).message)); }
    }
    // The && jobId here was the bug. The COMMON unfiled case is the one where no
    // job could be matched at all, which is exactly when jobId is NULL, so this
    // page never fired for it. The files sat in {company}/unfiled/ and the only
    // recovery path was the customer replying with a job number. Both shapes now
    // page, because in both of them a customer is waiting and nothing points at
    // their files.
    if (unfiled > 0) {
      await pageStaff("dispatch", "job_photo_not_filed",
        `${unfiled} texted ${mediaNoun(unfiled)} from ${fromNum || "an unknown number"} ${unfiled === 1 ? "is" : "are"} not on a job`,
        jobId
          ? `${unfiled} ${mediaNoun(unfiled)} uploaded to storage but could not be attached to ${jobNumber ?? "the matched job"}, so they will not appear on it. Storage prefix: ${COMPANY_ID}/${jobId}/`
          : `${unfiled} ${mediaNoun(unfiled)} uploaded to storage but no job could be matched to the sender, so nothing references them. Storage prefix: ${COMPANY_ID}/unfiled/`,
        jobId ? "jobs" : null, jobId);
    }
  }

  const { error: insErr } = await sb.from("communications").insert({ company_id: COMPANY_ID, customer_id: customerId, job_id: jobId, direction, channel: "sms", provider: "quo", from_number: fromNum || null, to_number: toNum || null, body, status: direction === "inbound" ? "received" : "delivered", provider_message_id: msgId, conversation_id: data.conversationId ?? null, meta: { event_type: type, sender_kind: senderKind, media_count: media.length, media_saved: saved, media_unfiled: unfiled, job_number: jobNumber, command: command?.type ?? null, line: "main" } });
  if (insErr) {
    // An inbound message that never reaches the inbox is invisible to every human in the company.
    // The page carries the text itself so it can be acted on without recovering the row.
    console.error("quo-webhook inbound insert failed:", insErr.message);
    await pageStaff("dispatch", "inbound_sms_not_logged", `⚠️ A text from ${fromNum || "an unknown number"} was not saved to the inbox`,
      `The message could not be written to communications (${insErr.message}), so it will not appear in any thread.\n\nFrom: ${fromNum}\nTo: ${toNum}\n${jobNumber ? "Job: " + jobNumber + "\n" : ""}Message: ${body.slice(0, 500)}`,
      jobId ? "jobs" : null, jobId);
  }

  if (aiBookingOn && direction === "inbound" && !command && !media.length && body && (phonePat || customerId)) {
    const openFilter = "(won,lost,invalid,spam,duplicate,refunded,closed,appointment_scheduled,appointment_confirmed,job_created)";
    const orParts: string[] = [];
    if (customerId) orParts.push(`customer_id.eq.${customerId}`);
    if (phonePat) orParts.push(`phone.ilike.${phonePat}`);
    let leadRowId: string | null = null;
    if (orParts.length) { const { data: lrows, error: lErr } = await sb.from("leads").select("id").eq("company_id", COMPANY_ID).not("status", "in", openFilter).or(orParts.join(",")).order("created_at", { ascending: false }).limit(1); if (lErr) console.error("AI-routing lead lookup failed:", lErr.message); leadRowId = lrows?.[0]?.id ?? null; }
    if (leadRowId) {
      const { data: ws } = await sb.rpc("get_secret", { p_name: "tf_estimate_worker_secret" });
      if (ws) { try { const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/ai-booking`, { method: "POST", headers: { "Content-Type": "application/json", "x-worker-secret": ws as string }, body: JSON.stringify({ lead_id: leadRowId }) }); if (r.ok) aiHandled = true; } catch { /* */ } }
    }
  }

  if (direction === "inbound" && media.length && fromNum && !command) {
    // Three outcomes, three different truths, and NONE of them asks the customer
    // to look up an internal identifier. A person who has just photographed a
    // leak is not the right party to resolve our record keeping. Whenever we
    // could not file something, the reply ends by taking the job off them, and
    // the pageStaff call above is what makes that promise real rather than
    // reassuring noise.
    const n = (jobId && saved > 0) ? saved : media.length;
    const content = (jobId && saved > 0)
      ? `Transit & Flow: got ${mediaCount(n)}, thank you. ${mediaIts(n)} on your job now and your technician will see ${mediaIt(n)}.`
      : jobId
        ? `Transit & Flow: got ${mediaCount(n)}, thank you. We're adding ${mediaIt(n)} to your job and someone will confirm shortly, so there's nothing you need to do.`
        : `Transit & Flow: got ${mediaCount(n)}, thank you. Someone on our team is matching ${mediaIt(n)} to your job right now, so there's nothing you need to do.`;
    await sendSms(fromNum, content, "media_confirmation");
  }
  if (direction === "inbound" && !command && !media.length && !aiHandled) { await pageInboundSms(fromNum, body, jobId); }

  return json(200, { ok: true, logged: !insErr, command: command?.type ?? null, linked_job: !!jobId, media_saved: saved, media_unfiled: unfiled, ai_booking: aiHandled });
}

// Pattern O. Consume whatever the client is still sending so the socket can close cleanly. A reader's
// read() genuinely throws when the peer hangs up mid-upload, so this catch is real and not the
// supabase-js pseudo-catch that can never fire.
async function drainBody(req: Request): Promise<void> {
  try {
    if (req.bodyUsed) return;
    const reader = req.body?.getReader();
    if (!reader) return;
    for (;;) {
      const { done } = await reader.read();
      if (done) break;
    }
  } catch {
    // Client disconnected mid-upload, or the body was already consumed on another branch.
  }
}

Deno.serve(async (req: Request) => {
  let res: Response;
  try {
    res = await handle(req);
  } catch (e) {
    console.error(JSON.stringify({ fn: "quo-webhook", stage: "unhandled", message: String((e as Error)?.message ?? e) }));
    res = json(500, { error: "internal_error" });
  }
  // Pattern O. Every return path in handle() lands here, so no early return can answer a large
  // body before that body has been consumed.
  await drainBody(req);
  return res;
});
