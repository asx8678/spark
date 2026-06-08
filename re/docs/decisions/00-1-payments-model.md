# ADR 00.1 — Payments Model & Provider Strategy

- **Status:** Accepted (founder sign-off pending on legal-entity dependency — see Consequences)
- **Date:** 2026-06-08
- **Deciders:** planning-agent (delegated via orchestrator)
- **Bead:** `super-41a` — *0.1 Decide payments model* (epic E0 `super-0r0` — Discovery & Open Decisions)
- **Spec refs:** §10 (payments), §16 (decisions)
- **Drives:** E12 Payments Module (`super-dp9`): `12.1` adapter interface · `12.2` hosted checkout · `12.3` subscriptions + publish-gating · `12.4` webhooks · `12.5` rebuild-on-state-change

---

## Context

We are building a greenfield, **Morocco-first** real-estate listing platform (Phoenix admin/API + Astro static/hybrid frontend + rebuild pipeline), maintained by a **solo developer**. Before designing the E12 payments module we must decide two things:

1. **Who pays, and for what** — B2B subscriptions, consumer transactions, or a hybrid.
2. **Which payment providers** — Stripe, CMI, PayZone, or a combination.

This decision branches the entire payments module (adapter shape, billing model, publish-gating logic) and the legal/merchant-onboarding path, so it must be resolved before E1/E12 begin.

### Market reality (Morocco real estate)

The dominant Moroccan property portals — Mubawab, Avito, Sarouty, Yakeey, Agenz — operate on an **overwhelmingly B2B model**: agencies and developers pay to advertise (subscriptions / listing packs / featured boosts), while property-seekers browse for free and contact via inquiry form, phone, or WhatsApp. Consumer (seeker) willingness-to-pay for a search service is low, and the monetizable value is **agency lead generation**, not end-user features.

### Payment reality (Morocco)

| Provider | Domestic MAD cards | Onboarding (solo dev) | API / DX | Notes |
|---|---|---|---|---|
| **CMI** (Centre Monétique Interbancaire) | ✅ Native — the dominant domestic acquirer/gateway | Heavy: needs a registered Moroccan business + acquiring-bank *e-commerce* contract + CMI affiliation (weeks) | Dated hosted-redirect + hash-signature model (NestPay/EST lineage), French docs | Lowest fees at volume; the de-facto rail for Moroccan-issued cards |
| **PayZone** (MA PSP/aggregator) | ✅ Via CMI rails | Lighter: single contract, faster | More modern API/plugins | Good solo-dev on-ramp to MAD acceptance; abstracts CMI. (YouCan Pay is a similar alternative.) |
| **Stripe** | ⚠️ **No** — see below | N/A for a Moroccan entity | Best-in-class (Billing, Checkout, Customer Portal, dunning, invoices, tax) | Excellent for subscriptions, but structurally constrained in Morocco |

**The Stripe-in-Morocco constraint (critical):** Stripe does **not** support Morocco-domiciled businesses for payment acceptance, and **most Moroccan-issued debit cards are domestic-only** and cannot pay a foreign (Stripe US/EU) merchant. Using Stripe therefore requires (a) a **foreign legal entity** (e.g., Stripe Atlas US / an EU company) **and** (b) accepting that you still **cannot collect from local-card-only Moroccan agencies** through it. In other words, Stripe alone cannot bill your core customer base.

> ⚠️ This contradicts the current wording of the bead acceptance criteria — *"Primary provider chosen (**Stripe**) + Morocco fallback (CMI/PayZone)"* — which **inverts** the Morocco reality. See the Decision and Consequences sections.

---

## Options Considered

### A. Who pays?

| Option | Description | Fit |
|---|---|---|
| **A1. B2B subscriptions only** | Agencies/developers pay recurring plans to list; publishing gated on an active subscription. | ✅ Strong — matches the market and `12.3` publish-gating. |
| **A2. Consumer transactions only** | Property-seekers pay for premium features. | ❌ Weak — low willingness-to-pay; not how Moroccan portals monetize. |
| **A3. Hybrid (B2B subs + B2B one-off add-ons)** | Subscriptions plus *featured/boost* add-ons — still paid by **agencies**, not seekers. | ✅ Natural upsell on top of A1, post-launch. |

### B. Providers

| Option | Description | Pros | Cons |
|---|---|---|---|
| **B1. Stripe primary + CMI/PayZone fallback** (as AC currently reads) | Lead with Stripe. | Best DX/billing tooling | ❌ Cannot bill Moroccan-card agencies; needs foreign entity |
| **B2. CMI/PayZone primary + Stripe secondary** | Domestic-first; Stripe for international. | ✅ Actually collects from local agencies | CMI onboarding lead time; weaker DX |
| **B3. Manual/offline invoicing first** | Bank-transfer (*virement*) invoices + admin publish toggle; automate later. | ✅ Zero integration risk; validates revenue fast | Manual ops overhead at scale |
| **B4. Single provider only** | Stripe-only or CMI-only. | Simplest to build | ❌ Brittle; misses either domestic or international customers |

---

## Decision

1. **Model — B2B subscription-led (A1), extensible to hybrid B2B add-ons (A3).**
   Agencies/developers pay recurring plans; **publishing is gated on an active subscription** (matches `12.3`). One-off **featured/boost** add-ons (still B2B) are a **post-launch** upsell. **No consumer/property-seeker payments at launch** — free browsing + inquiry forms (dovetails with decision `0.2` `super-lsv`).

2. **Providers — adapter pattern (`12.1`), domestic-first, phased:**
   - **v1 (launch): Manual/offline invoicing** as the first adapter implementation (B3). Issue an invoice, accept bank transfer (*virement*), admin marks the subscription paid → listings publish. Zero gateway-integration risk; validates willingness-to-pay with the first design-partner agencies. The "active subscription" gate is initially flipped by an admin and later by a gateway webhook — same model, swappable source of truth.
   - **v2 (automated domestic collection): PayZone** as the primary automated rail — fastest solo-dev path to **Moroccan-card / MAD** acceptance over CMI rails — with a **direct-CMI** integration as a fee-optimization once volume justifies the bank contract.
   - **v3 (international): Stripe** added as the **secondary** rail for diaspora / foreign-card customers and for its superior subscription/billing tooling — **contingent on a suitable foreign legal entity** existing.
   - **Cross-cutting:** everything sits behind the **payment adapter interface (`12.1`)**; **hosted checkout/redirect only (`12.2`)** to stay out of PCI scope; **webhooks signature-verified + idempotent via Oban (`12.4`)**; **subscription state changes enqueue rebuilds (`12.5`)**.

3. **Correction to the bead AC / E12 framing:** flip "Stripe primary + CMI/PayZone fallback" to **"domestic-first (CMI/PayZone) primary, Stripe secondary/international."** Stripe remains the *reference DX* and the international rail — not the primary collector.

---

## Rationale

- **Market fit:** Moroccan property portals monetize agencies, not seekers — B2B subscriptions is the proven model.
- **You must be able to collect:** your paying customers are Moroccan agencies using Moroccan-issued cards; only the CMI/PayZone rail accepts those. A Stripe-primary design would be unable to bill the core customer base.
- **Solo-dev pragmatism:** manual invoicing at launch removes all gateway-integration risk and validates revenue before you sink weeks into CMI onboarding. The adapter lets you upgrade rails without reworking the billing model.
- **PCI scope:** hosted checkout/redirect only — never touch raw card data.
- **Optionality:** the adapter + hosted-checkout choices keep provider swaps cheap and let Stripe slot in later for international customers without a rewrite.

---

## Consequences

**Positive**
- Validated revenue quickly; minimal launch integration risk.
- Correct domestic collection from day one of automation (v2).
- PCI-light; clean, swappable provider boundary.

**Negative / costs**
- Manual invoicing carries ops overhead as customers grow → mitigated by moving to PayZone (v2).
- CMI/bank *e-commerce* contract has a multi-week lead time.
- Deferring Stripe means building a **thin in-app subscription/invoice model** (per `12.3`) rather than leaning on Stripe Billing initially.
- Maintaining 2+ adapter implementations over time.

**Follow-ups / open items**
- ⛓️ **Legal-entity decision** (Moroccan SARL vs foreign/Stripe-Atlas) gates whether and when Stripe is usable — recommend tracking as its own decision/dependency.
- 🏦 **Start the CMI / acquiring-bank e-commerce contract paperwork early** (long lead time) if v2 is on the near roadmap.
- 📝 **Update E12** — revise `super-41a` AC and `12.1`/`12.3` descriptions to "domestic-first (CMI/PayZone) primary, Stripe secondary."
- 💵 **Define plan tiers & pricing** (separate product decision).
- 🧾 **MAD invoicing / VAT (TVA 20%) & receipt requirements** — confirm with an accountant before automated billing.

### Acceptance-criteria status

- [x] **Model chosen:** B2B subscription-led, extensible to hybrid B2B add-ons.
- [~] **Provider chosen:** domestic-first **CMI/PayZone primary**, **Stripe secondary/international**, behind the `12.1` adapter. *"Confirmed for the legal entity"* remains **pending the legal-entity decision**; provider onboarding confirmation is handed off to E12.
