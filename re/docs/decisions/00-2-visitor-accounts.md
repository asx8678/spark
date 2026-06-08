# 0.2 — Public Visitor Accounts vs. Inquiry-Form-Only

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-06-08 |
| **Bead** | `super-lsv` (0.2) |
| **Epic** | E0 — Discovery & Open Decisions (`super-0r0`) |
| **Spec refs** | §9, §16 |
| **Related decisions** | 0.1 Payments model (`super-41a`, B2B subscriptions); 0.4 Catalog scale → static vs hybrid (`super-fcu`); 0.3 Locales & RTL (`super-fkf`) |
| **Affects** | E2 Phoenix Core (`super-umn`), E5 Read API (`super-epk`), E7 Astro Frontend (`super-rsq`) |
| **Deciders** | Project owner (solo developer); drafted by `planning-agent` on behalf of `orchestrator` |

---

## Context

Greenfield real-estate listing platform targeting the **Moroccan** market. Listing
supply comes from **agencies/professionals who pay to list** — decision **0.1**
points at a **B2B subscription** revenue model, so the property *seekers*
(visitors) are **free users, not the paying customer**.

The platform is built as a **static-first Astro public frontend** (E7) backed by a
**Phoenix core** (E2) exposing a **public Read API** (E5); the agency/admin surface
is a separate Phoenix LiveView app (E4). Catalog-scale decision **0.4** leans toward
a **static/hybrid** public site.

The open question (spec **§9/§16**): do public visitors get **authenticated
accounts** — enabling saved searches, favorites, and alerts — or do they only
interact through **inquiry/contact forms** with no persistent identity?

This decision is on the critical path because it **sets the public-auth scope** for
E2 and E5: building token-based public authentication is a large, security- and
compliance-sensitive subsystem, and we should only commit to it if it is justified.

### Key constraints

- **B2B model** — visitor accounts do not, by themselves, generate revenue.
- **Solo developer** — every auth feature is a permanent maintenance, security, and
  support liability.
- **Moroccan market behaviour** — property contact happens overwhelmingly via
  **WhatsApp and phone calls**; **email penetration/engagement is comparatively low**,
  which weakens classic email-based account and alert loops and makes transactional
  email deliverability harder.
- **Static-first architecture** — per-user authenticated rendering does not fit a
  static/CDN-served Astro site cleanly; it forces a dynamic/authenticated layer.
- **Data protection (Law 09-08 / CNDP)** — storing visitor credentials and profiles
  makes us a **data controller** with full obligations (consent, retention,
  data-subject rights) and meaningful breach exposure.

---

## Options Considered

### Option A — Full visitor accounts
Email + password (or magic link), email verification, password reset, sessions /
bearer tokens for the Astro→E5 API, **server-side favorites**, **saved searches**,
and a **saved-search alert engine** (email / WhatsApp / push).

- **Pros:** cross-device sync; proactive alerts are a genuine re-engagement /
  retention lever; richer first-party visitor data; matches the incumbent portal
  feature set.
- **Cons:** a **large net-new auth surface** entirely separate from agency auth;
  heavy security & compliance burden (credential storage, reset flows, rate-limiting,
  account-takeover and abuse handling); requires **reliable transactional email
  infrastructure** (deliverability is hard, especially Arabic content into Moroccan
  inboxes); the alert engine needs background jobs **and** a paid notification channel
  (SMS / WhatsApp BSP fees); **breaks the static-first model**; ongoing carry cost for
  a feature that **does not drive B2B revenue**. High build cost **and** high perpetual
  maintenance cost.

### Option B — Inquiry-form-only (no persistence)
Anonymous browsing; every listing has a contact/inquiry form plus prominent
**WhatsApp / click-to-call** CTAs. Submissions create a **lead** routed to the agency
(and optionally stored as a lead record). No login, no favorites, no saved searches.

- **Pros:** minimal build; **zero public-auth surface**; fits static Astro perfectly
  (a single POST endpoint); matches Moroccan contact behaviour; smallest compliance
  footprint; **directly serves the B2B value proposition** — deliver qualified leads
  to paying agencies.
- **Cons:** no engagement/retention hooks; visitors lose their shortlist on reload or
  navigation; no first-party visitor data; weaker stickiness than incumbents.

### Option C — Middle ground *(recommended)*
**Inquiry-form-only contact (Option B)** **plus** **anonymous, client-side favorites**
(stored in `localStorage`; no account, no PII) and a "recently viewed" list — with a
clean upgrade path to accounts later. **No saved-search alert engine at launch.**

- **Pros:** keeps the single highest-value engagement feature (**favorites**) at
  ~zero backend cost and **zero auth/compliance burden**; native to static Astro;
  market-aligned contact (WhatsApp/phone) with **server-captured leads** for analytics
  and reliability; smallest viable surface for a solo developer; preserves a low-risk
  path to full accounts.
- **Cons:** favorites **do not sync across devices** and can be lost if storage is
  cleared (acceptable for MVP); still **no proactive alerts** at launch (the one
  feature that genuinely requires accounts) — explicitly deferred.

> **Future auth modality:** if/when accounts are justified, prefer
> **phone-number / WhatsApp OTP** over email+password — better market fit, no password
> management — accepting per-OTP SMS/BSP cost and an anti-abuse plan.

---

## Decision

Adopt **Option C**.

At launch the platform ships **inquiry-form-only contact** (prominent WhatsApp deep-link
+ click-to-call CTAs, backed by a server-captured lead) **plus anonymous client-side
favorites / recently-viewed**. **No public visitor accounts in the MVP.**

Full visitor accounts and the saved-search **alert engine** are **deferred** to a later,
**demand-gated** phase. If they are built, they will use **phone/WhatsApp-OTP**, not
email+password, and existing `localStorage` favorites will be migrated into the account
on sign-up.

---

## Rationale

1. **Follow the money.** The model is B2B; visitors are free. The launch priority is
   **reliable lead delivery to paying agencies**, not visitor-retention features.
2. **Protect the solo-dev maintenance budget.** Public authentication is among the
   highest-carry, highest-risk subsystems to own (security, compliance, support). Don't
   build it until it pays for itself.
3. **Market fit.** Moroccan seekers contact via WhatsApp/phone; email account-and-alert
   loops have weak fit and deliverability locally. **Client-side favorites capture the
   main UX win without any auth.**
4. **Architecture fit.** Static-first Astro + favorites-in-`localStorage` are a natural
   match. Accounts would force a dynamic/authenticated layer prematurely (cuts against
   decision 0.4's static lean).
5. **Compliance minimization.** No visitor credentials/profiles means we avoid full
   Law 09-08 controller obligations and breach exposure for that data. Anonymous
   favorites store **no server-side PII**; inquiry leads still involve PII but are
   minimal, purpose-limited, and far easier to govern.
6. **Optionality preserved.** A clean upgrade path (phone-OTP accounts; migrate
   favorites on sign-up) means we lose nothing but premature cost.

---

## Consequences

### Public-auth scope for E2 / E5 *(satisfies the acceptance criterion)*

- **E2 — Phoenix Core (`super-umn`):** **No public visitor identity/auth subsystem in
  the MVP.** Auth work is limited to the **agency/admin** side (E4 LiveView,
  session-based). No public user table, password storage, email verification, or reset
  flows. **Do** add a `leads`/`inquiries` context + schema and rate-limited intake.
- **E5 — Read API (`super-epk`):** Public read endpoints stay **unauthenticated**,
  cache-friendly, and **rate-limited** (suited to a static/CDN frontend). Add exactly
  **one public write endpoint** for inquiry submission, **spam-hardened** (rate limit +
  honeypot/CAPTCHA, strict validation). **No visitor bearer-token auth to build.**
  Favorites / recently-viewed need **no API** — they live entirely client-side.
- **E7 — Astro Frontend (`super-rsq`):** Build WhatsApp deep-link (`wa.me` with a
  pre-filled message including the listing reference) + click-to-call CTAs, an inquiry
  form posting to the E5 endpoint, and a `localStorage`-backed favorites / recently-viewed
  feature. No auth/session handling.

### Positive
- Drastically smaller attack surface and compliance footprint.
- Faster to launch; lower run cost (no transactional email or alert infrastructure).
- Architecture stays static-first; aligns with 0.1 (B2B) and 0.4 (static/hybrid).

### Negative / accepted trade-offs
- No cross-device favorites; favorites can be lost if local storage is cleared.
- **No proactive saved-search alerts at launch** — a real retention lever we forgo.
- Less first-party visitor data; a deliberate feature gap vs. incumbents on "save/alert".

### Data protection (Law 09-08 / CNDP)
- Inquiry forms collect PII (name, phone, message) → define **purpose, lawful basis,
  and a retention window**, surface a **privacy notice**, and confirm CNDP / Law 09-08
  obligations for lead data (file under E14 Security/DR). Anonymous favorites store **no
  server-side PII**; only add a cookie/consent banner if/when analytics are introduced.

### Follow-ups to file (bd)
- `leads`/`inquiries` schema + rate-limited intake endpoint (E2 / E5).
- WhatsApp deep-link + click-to-call CTA components; inquiry form (E7).
- `localStorage` favorites + recently-viewed (E7).
- Privacy notice + lead-retention policy + CNDP check (E14 / E13).

---

## Revisit triggers

Re-open this decision when **any** of the following holds:

- Measured demand for save/alert (e.g., high favorites usage and explicit user requests).
- A **consumer/transactional** revenue line emerges (changes who the "user" is — see 0.1).
- Cross-device continuity or push/WhatsApp alerts become a competitive necessity.

When triggered, prefer **phone/WhatsApp-OTP** accounts and migrate existing
`localStorage` favorites into the account at sign-up.

---

## Appendix — Competitive landscape *(verify before go-to-market)*

The major Moroccan portals (**Mubawab**, **Sarouty**, **Avito.ma**) generally **do**
offer accounts with favorites / saved searches / alerts, **while still allowing fully
anonymous browsing and direct contact** (phone / WhatsApp / inquiry form), with
contact-by-WhatsApp/phone being the dominant path. Under this decision we **match**
incumbents on anonymous browsing, direct contact, and (client-side) favorites, and we
**intentionally lag** on saved-search alerts at launch.

> No live web-research tool was available in the session that produced this record;
> treat specific competitor feature claims above as **general knowledge to verify**
> before relying on them for go-to-market positioning.
