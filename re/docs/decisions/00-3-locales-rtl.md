# ADR 00-3 — Launch Locales & RTL Scope (FR / AR / EN)

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-06-08 |
| **Bead** | `super-fkf` — "0.3 Decide launch locales & RTL scope (FR / AR / EN)" |
| **Epic** | E0 — Discovery & Open Decisions (`super-0r0`) |
| **Deciders** | planning-agent (on behalf of orchestrator) |
| **Spec refs** | §7 (i18n), §16 (decisions) |
| **Affects** | E13 i18n (`super-bai5`), E7 Astro frontend (`super-rsq`), E3 data model (`super-qsp`) |

---

## Context

We are building a greenfield real-estate listing platform targeting **Morocco**, on
**Astro 6 (static output) + Tailwind CSS**, maintained by a **solo developer**. Before
building the i18n epic (E13) and the theme layer, we must fix two things:

1. **Which locales ship at launch.**
2. **Whether Arabic — and therefore RTL — is in launch scope or deferred.**

Relevant market and technical realities:

- **Morocco is multilingual.** Arabic and Amazigh are the official languages; **French**
  is the de-facto language of business, finance, legal/notarial work, and the
  property-buying middle/upper class. **English** is growing, especially among the
  diaspora (MRE — *Marocains Résidents à l'Étranger*) and international investors.
- **The real-estate sector specifically operates primarily in French and Arabic.** Supply
  side (agencies, developers, notaires) and the affluent demand side skew heavily French;
  Arabic broadens reach to the mass-market domestic audience.
- **Arabic is right-to-left (RTL).** This is the single largest scope multiplier in the
  frontend: mirrored layouts, icon/affordance direction, carousels, maps, form alignment,
  bidirectional text (Arabic prose mixed with Latin street names and prices), and a
  dedicated Arabic web-font stack. For a solo developer, **RTL roughly doubles the UI QA
  surface.**
- **French and English are LTR** and share a layout direction — a second LTR locale is
  cheap relative to RTL.
- **Tailwind has good RTL support** via logical properties (`ps-/pe-`, `ms-/me-`,
  `start-/end-`, `text-start/text-end`) that mirror automatically from the `dir`
  attribute. **Astro 6 has first-class i18n routing** built in.
- **URL/SEO permanence:** this is an SEO-first static site (E7). The URL scheme and the
  locale-awareness of the content data model are expensive to retrofit; the RTL *theme*
  and Arabic *translations* are additive.

The expensive, hard-to-reverse parts of i18n are the **routing scheme** and the
**locale-aware content data model** — not the rendering of Arabic glyphs. That insight
drives the decision below: lock the architecture now, defer the RTL/translation cost.

---

## Options Considered

### A) Locale scope at launch

| Option | Description | Pros | Cons |
|---|---|---|---|
| **A1. FR only** | Single language, no i18n routing at launch. | Minimum scope; single-locale QA; fastest. | Retrofitting i18n later is an SEO-risky URL change; data model becomes locale-aware retroactively (migration); loses high-value EN diaspora/investor segment. |
| **A2. FR + EN (LTR)** ✅ | Two LTR locales; AR/RTL deferred. | Forces correct i18n architecture from day one using a *cheap* LTR locale; captures MRE/international-investor segment (high value for property sales); RTL cost (the part that hurts) is deferred; proves the multi-locale plumbing so AR becomes additive. | ~2× content/translation pass (FR→EN); two-locale smoke testing. Manageable (LTR, and catalog content can fall back to source locale). |
| **A3. FR + AR + EN (full RTL day one)** | All three from launch. | Maximum reach at launch; one big i18n push. | RTL doubles QA; triples translation/maintenance; highest risk of a delayed, buggy launch for a solo dev. A polished bilingual launch beats a shaky trilingual one. |
| **A4. FR + AR (no EN)** | Primary domestic pair. | Covers the two dominant sector languages. | Pays the full RTL cost at launch *and* skips the cheap, high-value EN segment — worst trade for a solo dev. |

### B) i18n routing strategy

| Option | Description | Verdict |
|---|---|---|
| **B1. URL path prefix** (`/fr/`, `/en/`, later `/ar/`) — Astro native i18n. | Distinct indexable URL per locale. | ✅ **Chosen.** Best for SEO + `hreflang`, works perfectly with static output, simplest to reason about, industry standard. |
| **B2. Subdomain** (`fr.`, `en.`). | Per-locale host. | ❌ Extra DNS/cert/CDN ops for no benefit here. |
| **B3. ccTLD / domain per locale**. | Separate domains. | ❌ Heavyweight; only for distinct country targeting. Overkill. |
| **B4. Content negotiation / cookie (no URL distinction)**. | One URL, language by header/cookie. | ❌ Anti-pattern for an SEO-first static site — locales can't be indexed/linked/shared independently. |

### C) Default-locale prefixing (within B1)

| Option | URLs | Verdict |
|---|---|---|
| `prefixDefaultLocale: false` | FR at root `/`, others prefixed (`/en/`). | Cleaner FR URLs, but asymmetric; duplicate-content edge cases at root; brittle if the default ever changes. |
| **`prefixDefaultLocale: true`** ✅ | All locales prefixed (`/fr/`, `/en/`, later `/ar/`); root `/` redirects. | Symmetric, unambiguous `hreflang`, future-proof, no root-vs-prefixed duplication. Slightly less "clean" FR URLs — an acceptable trade for SEO robustness and URL permanence. |

---

## Decision

1. **Launch locales: French (`fr`) + English (`en`), both LTR.** French is the **primary /
   default** locale.

2. **Arabic (`ar`, RTL) is OUT of launch scope** — planned as a **fast-follow Phase 2**
   (the natural home is E13's `13.2 RTL theming`). To keep that follow-up additive rather
   than a refactor, we **build "RTL-ready" from day one** (see Consequences).

3. **Amazigh / Tamazight is out of scope** — negligible digital real-estate demand and
   niche Tifinagh-script tooling. May be revisited only on clear demand.

4. **Routing: URL path-prefix via Astro's native i18n, `prefixDefaultLocale: true`.** All
   active locales are explicitly prefixed (`/fr/`, `/en/`; `/ar/` reserved). The bare root
   `/` redirects to the default/negotiated locale. Per-page `hreflang` alternates plus an
   `x-default` are emitted.

5. **Locale codes:** short codes in URLs (`fr`, `en`, reserve `ar`); **BCP-47 with region
   where it helps SEO** in `hreflang` and `<html lang>` (`fr-MA`, `en`, later `ar-MA`),
   plus `x-default`.

Illustrative Astro config:

```js
// astro.config.mjs
export default defineConfig({
  i18n: {
    locales: ['fr', 'en'],          // add 'ar' in Phase 2
    defaultLocale: 'fr',
    routing: {
      prefixDefaultLocale: true,    // /fr/, /en/ (and later /ar/)
      redirectToDefaultLocale: true,
    },
  },
});
```

```html
<!-- driven by the active locale -->
<html lang="fr" dir="ltr"> … </html>   <!-- ar → lang="ar" dir="rtl" -->
```

---

## Rationale

- **French is non-negotiable** for Moroccan real-estate: it is the working language of the
  supply side and the affluent demand side.
- **English is nearly free and high-value.** It is LTR (no layout-doubling cost) and
  reaches the **diaspora (MRE) and international investors** — a disproportionately
  valuable segment for new-build and investment property. A second LTR locale also
  **forces the i18n architecture to be correct from launch** (routing, `hreflang`,
  locale-aware schema) without paying the RTL tax.
- **The costly part is RTL, not "another language."** Deferring **Arabic** removes the
  layout-mirroring + bidi + Arabic-typography QA burden from the critical launch path —
  exactly the multiplier a solo developer cannot absorb at launch — while leaving the
  broad-reach play available as a well-publicized Phase 2 ("now in Arabic").
- **The architecture is locked now, so AR is additive later.** The expensive-to-retrofit
  pieces — URL scheme and locale-aware content storage — are decided and built up front.
  Adding Arabic then becomes "register a locale + ship an RTL theme + translate + QA,"
  not "introduce i18n and do RTL at the same time."
- **Path-prefix routing on a static, SEO-first site** is the standard, lowest-risk choice;
  `prefixDefaultLocale: true` maximizes SEO/`hreflang` consistency and future-proofs the
  default.

---

## Consequences

### Positive
- Lean, achievable, **polished bilingual (FR/EN) launch** for a solo developer.
- Correct i18n foundation from day one; **Arabic is a clean additive phase**, not a rewrite.
- Captures the high-value MRE/international-investor audience at launch.
- Clear, indexable per-locale URLs with proper `hreflang`.

### Negative / costs accepted
- FR↔EN content must be authored/maintained for **UI + key SEO/landing pages**.
- Domestic Arabic-first mass-market users are **not served at launch** (mitigated by a
  committed Phase 2).
- A small amount of up-front "RTL-ready" discipline (see below) with no launch-day payoff —
  cheap insurance.

### RTL-ready discipline to adopt **now** (so Phase 2 is additive)
- **Use Tailwind logical properties everywhere from the first component:** `ps-/pe-`,
  `ms-/me-`, `start-/end-`, `text-start/text-end`, `rounded-s-/rounded-e-`, `border-s/-e`.
  **Avoid physical** `pl/pr`, `ml/mr`, `left/right`, `text-left/right`.
- **Drive `dir` off the active locale** on `<html>` (ltr for fr/en, rtl for ar).
- **Choose the Arabic web-font now** (e.g. *Noto Sans Arabic*, *Cairo*, or *IBM Plex Sans
  Arabic*) and gate its loading on `:lang(ar)` / `[lang="ar"]` so it adds **zero** payload
  at launch.
- **Plan for bidi**: format numbers/prices/dates via `Intl` per locale; isolate Latin runs
  inside Arabic (`<bdi>` / `unicode-bidi: isolate`) for prices, phones, street names.
- **Separate UI strings from catalog content:** UI/template strings are localized for all
  *active* locales; **catalog/listing content is stored locale-aware (JSONB / i18n
  columns) but falls back to the source locale** when a translation is absent — this keeps
  the solo-dev/agency content burden sane and is the same model AR will use later.

### Roadmap impact (bd)
- **E3 — Data Model (`super-qsp`)**: catalog content must be **locale-aware from day one**
  (JSONB / i18n columns), even though only FR/EN are populated initially. This is the one
  thing too expensive to retrofit, so it is a **launch constraint**.
- **E7 — Astro Frontend (`super-rsq`)**: configure Astro i18n routing at project setup and
  adopt the logical-CSS / `dir`-aware discipline above from the first component.
- **E13 — i18n (`super-bai5`)** splits across phases:
  - **Launch scope:** `13.1` routing + `hreflang` (FR/EN), the EN content path, and the
    locale-aware storage half of `13.3`.
  - **Fast-follow (Phase 2):** `13.2` RTL theming + Arabic translations, the AR portion of
    `13.3`, and AR-specific `13.4` localized SEO.
- **Suggested follow-up bead:** "Phase 2 — Add Arabic (RTL) locale" grouping `13.2` +
  AR translation + AR QA, scheduled after the FR/EN launch stabilizes.

### Acceptance criteria — satisfied
- ✅ **Launch locales fixed:** French + English (LTR), French primary.
- ✅ **RTL in/out of launch scope decided:** Arabic/RTL is **OUT** of launch scope
  (fast-follow Phase 2), with the codebase built **RTL-ready** so the addition is additive.
