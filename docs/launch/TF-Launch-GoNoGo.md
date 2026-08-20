# Transit & Flow, launch decision board

**Decided** 19 August 2026 · **Authority** delegated, acting as the assembled launch committee
**Decision: CONDITIONAL GO.** The platform is technically launch-ready today. Three items gate full customer-facing activation, all three are yours alone, and each has an exact command or action below. Nothing on the engineering side is in the critical path anymore.

---

## The decision, in one paragraph

Launch the system in its current posture now: every inbound channel is monitored, routed, asserted hourly, and paged to humans; every front-door contact becomes pipeline automatically; nothing texts a customer without a human behind it. Then activate outbound automation in waves as you personally clear the three gates. This sequencing launches the part that is provably safe today and holds the part whose risk is legal and reputational, which is exactly the division of labor the platform was built around.

## GREEN, verified this morning

Regression suite 21 of 21, zero critical failures, ~14 seconds hourly. Security advisors: zero errors. All 43 edge functions match the reviewed verify_jwt baseline (one posture drift found this morning was reviewed and the baseline corrected: tf-hcp-job-push is deliberately stricter now). All 44 cron jobs healthy, zero failed runs, notification queue fully drained, drain armed on all four tiers. Inbound is bulletproofed end to end: emergency intakes to #field-ops at critical, ordinary texts at normal, unmatched photos page within seconds, lost media now pages AND asks the customer to resend, and every unknown sender becomes a lead. That last chain was proven again this week the hard way: A21 caught a silent two-photo loss from 17 August that predecessor code would have swallowed forever. Found, fixed at the class level, sender recorded, board green.

## The three gates, all owner-only

**Gate 1, lawful basis for transactional messaging.** 6 consent records exist for 3,114 customers. Until a lawful basis is recorded, no outbound automation touches a customer, and 109 leads (100% never contacted) stay waiting. This is the single highest-leverage action in the company. Decide the basis with counsel, record it, and Wave 1 unlocks.

**Gate 2, arming.** From an authenticated internal-staff session, in this order, watching #field-ops between each:
```
select public.tf_automation_arm('missed_call_textback', true);   -- Wave 1a: recover missed callers
select public.tf_automation_arm('ai_booking', true);             -- Wave 1b: AI booking on inbound
select public.tf_automation_arm('appt_reminders', true);         -- Wave 2, after 48h clean
select public.tf_automation_arm('review_requests', true);        -- Wave 2
```
Every one is registry-bounded, blast-radius-measured, and refuses to arm by any other path. I cannot run these for you; the guard requires a human session by design.

**Gate 3, the pricebook.** Zero priced items exist for this company across 30 real trades. Until ops loads real prices, quoting automation has nothing true to say. I will not invent prices. One afternoon with your rate sheet closes this.

## Deferred by executive decision, with reasons

The ai-booking to Housecall Pro job-push wiring stays dark. tf-hcp-job-push is Shopify-scoped, carries a fresh idempotency-claim protocol another operator rebuilt three days ago after a regression, and HCP writes await your one controlled-write authorization. Wiring a vendor-writing path days before launch, across another operator's fresh repair, is risk without launch payoff. Revisit in week two.

Also noted for a coordination protocol: three times now, another operator's migrations have interleaved with mine on production within seconds to minutes. The ratchets caught the one that mattered. A shared migration calendar would make that luck unnecessary.

## The worklist economy, current state

17 stranded photos auto-filed to date. Residue 107, and its shape has flipped: the new arrivals are overwhelmingly known customers with NO job on record, led by one customer who sent 20 photos in two days documenting something substantial that nobody has booked. That is a sales call, not a filing problem. The updated worklist file accompanies this board.
