# Transit & Flow, Gate 1 decision packet: lawful basis for customer messaging

**Prepared for** the owner and outside counsel · 19 August 2026
**Purpose** reduce the single remaining launch blocker to one reviewed signature
**This is not legal advice.** It is the factual record counsel needs, assembled so their time is spent deciding rather than discovering.

---

## Why this is the highest-value decision on the board

Everything else is unblocked. Inbound is asserted hourly, the pricebook is loaded and verified, the platform is green. What is still off is every outbound path that touches a customer, and it is off because the record cannot presently show a lawful basis for it.

The measurable cost, today:

| Held by this gate | Count |
|---|---|
| Leads never contacted | 109 (100% of all leads) |
| Consent records on file | 6 |
| Customers in the database | 3,161 (3,090 with a phone number) |
| Customer-reaching automations armed | 0 of 11 |

Every new front-door lead the platform now creates joins the same queue. The gate does not just hold old work, it holds all future work.

## What the system already does correctly, and what it refuses to do

The platform will not send a customer message without passing `tf_consent_gate`, which is bound to a registered page target and a purpose string. There is no bypass flag; an earlier assertion (A6) exists specifically to prove a purpose string cannot be invented to escape it. Every customer-reaching automation is registered with a measured blast radius and refuses to arm except through `tf_automation_arm` from an authenticated human session.

In other words: the technical control is already correct and conservative. What is missing is the documented basis it is enforcing.

## The three questions counsel needs to answer

**1. What is our lawful basis for transactional messaging to existing customers?**
These are service messages to people who contracted work: booking confirmations, technician ETAs, arrival notices, completion notices. Transactional service messages generally sit on a different footing from marketing. Counsel should confirm the basis and any state-specific overlay for Ohio.

**2. What is our basis for the 109 uncontacted leads?**
These people contacted us first, by text, by phone, or through the answering service. Counsel should confirm whether inbound contact constitutes sufficient basis for a reply and for follow-up, and how long that basis persists before it goes stale.

**3. What must the opt-out mechanism look like, and where is it recorded?**
The platform captures STOP keywords through `tf_consent_inbound_keyword` and refuses to process inbound SMS if that screening is unavailable. Counsel should confirm the wording, the honoring window, and the retention requirement.

## What must be recorded once counsel answers

A durable record, not a verbal decision, covering: the basis relied on for each message category (transactional, service follow-up, marketing), the date and author of the determination, the opt-out mechanism and honoring window, the retention period for consent and opt-out records, and who may change any of it.

Store it where a compliance reviewer can find it without asking anyone, and reference it from the automation registry so the arming decision points at its own justification.

## What happens the moment it is recorded

Wave 1 arming becomes available and the queue starts moving. The commands are in the launch runbook, they are guarded, they are logged, and they require your authenticated session. Nothing about this decision changes the technical posture. It changes whether the posture is allowed to be used.

## What I did not do, and why

I did not choose a basis, draft a policy, or set a retention period. Those are legal determinations with regulatory exposure attached, and picking one would give you a document that looks like diligence without being it. I also did not send a single customer message while assembling this. The platform's own consent gate is the reason that constraint held even under a broad grant of authority, which is the correct outcome.
