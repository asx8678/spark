# ADR 0.4 — Catalog Scale & Rendering Strategy (Static vs Hybrid)

- **Status:** Accepted
- **Date:** 2026-06-08
- **Bead:** `super-fcu` (E0 Discovery & Open Decisions → `super-0r0`)
- **Decision owners:** Platform / architecture
- **Related epics:** E5 Read API · E7 Astro Frontend · E9 Rebuild Pipeline · E17 Scale (optional, on-demand/hybrid)
- **Spec references:** §1 Product overview · §2 Tech direction · §3 Information architecture · §7 Pages · §10 Data model · §12 Seed content

---

## Context

We are building the public frontend of **newprojects.ma** as an **Astro static site (SSG)** that consumes a read API (E5) backed by the Phoenix core (E2). Before committing to a rendering model we need to know **how big the catalog gets** at launch and over 2–3 years, and at what point pure SSG stops being practical and we must invest in **E17 (hybrid / on-demand rendering)**.

### What this product actually is (this drives the numbers)

Per spec §1, newprojects.ma is a **specialist portal for new-build / off-plan developments** — *not* a resale-listings marketplace. That single fact shrinks the catalog by an order of magnitude versus a generalist portal, for three structural reasons:

1. **The catalog unit is the _programme_ (development project), not the individual property.** One page per project: `/programme/:slug` (spec §3, §7.3). A resale portal generates a page per *unit for sale*; here, all the units of a development (T2 / T3 / villas) are rendered **as a table inside the one project page** (§7.3 "Lots & disponibilités"), not as separate URLs.
2. **Programmes are published by _promoteurs_ (developers), who each have a handful of active projects** — not hundreds. The seed (§12.2) lists developers with 5–21 *delivered* projects over their entire history; active programmes at any moment are far fewer.
3. **Search is an API-backed client island, not a pre-rendered matrix.** The filter bar (city / budget / type / Daam) + synced map (§7.2) run against a search API (Postgres FTS → Meilisearch/Typesense, §2) from a client island. We do **not** pre-render the combinatorial explosion of filter permutations, which is the classic way SSG page counts blow up.

### Page inventory (what SSG actually generates)

| Page type | Route | Static & SEO? | Multiplier |
|---|---|---|---|
| Project detail | `/programme/:slug` | ✅ yes | **1 per active+archived programme** (the dominant term) |
| City landing | `/ville/:city` | ✅ yes | 1 per city (~5 → ~20) |
| Developer public profile | `/promoteur/:slug` | ✅ yes | 1 per developer (~30 → ~150) |
| Article / journal | `/actualites/:slug` | ✅ yes | grows with editorial cadence |
| Listings / search shell | `/programmes` (+ pagination, +per-city) | ✅ shell only | small (pagination + per-city, **not** per-filter) |
| Static / legal / guides | `/`, VEFA & Daam guides, about… | ✅ yes | ~20 fixed |
| Favoris | client-side | n/a (client state) | 0 |
| **Developer & admin panel** | `/promoteur` (auth) | ❌ **excluded** | authenticated app (LiveView/SSR), never in the static SEO surface |

**i18n multiplier (E13):** FR is the base content language; EN is full content; **AR is chrome-only and falls back to FR for body content** (spec §11.3). So the realistic page multiplier is **~2× (FR + EN)**. We model a conservative **~3×** to cover the case where we also emit per-locale AR URLs for hreflang/SEO.

---

## Estimated page counts

### Scenario A — Spec-faithful (new-build specialist) — *expected*

Assumptions: launch with ~20–50 developers contributing a few active programmes each; the catalog grows as we onboard more developers and **retain delivered / sold-out programmes as static archive pages** (they keep ranking and capture demand).

| Horizon | Active + archived programmes | Other pages (city + dev + articles + static + listing shells) | Base pages (FR) | **× ~2 (FR+EN)** | Conservative × ~3 (incl. AR URLs) |
|---|---:|---:|---:|---:|---:|
| **Launch (Y1)** | ~300 | ~90 | ~390 | **~800** | ~1,200 |
| **Year 2** | ~1,200 | ~260 | ~1,460 | **~2,900** | ~4,400 |
| **Year 3** | ~3,000 | ~555 | ~3,555 | **~7,100** | ~10,700 |

➡️ **Expected 3-year ceiling: ~7,000–11,000 pages.** Squarely inside Astro SSG's comfort zone.

### Scenario B — Aggressive / "behaves like a generalist portal" — *stress test*

Assumptions: model expands well beyond plan — e.g. resale is added, individual units become pages, or developer onboarding is 5–10× the plan. This is the orchestrator's "20–50 agencies × 50–500 listings" framing applied as a worst case.

| Horizon | Programmes / listings | + overhead | **× ~2** | × ~3 |
|---|---:|---:|---:|---:|
| **Launch** | ~3,000 | ~3,200 | **~6,400** | ~9,600 |
| **Year 3** | ~25,000 | ~27,000 | **~54,000** | ~81,000 |

➡️ **Aggressive 3-year ceiling: ~50,000–80,000 pages.** Still under the ~100k "pushing it" line and far under the ~500k "SSG impractical" line.

---

## When does Astro SSG become impractical?

Build time scales roughly linearly with page count, but the **practical** bottleneck is usually image processing, data fetching, and full-rebuild latency — not raw HTML rendering. Planning rules of thumb for content-rich pages (a few images each), assuming images are **not** all derived at build time:

| Page count | Verdict | Notes |
|---|---|---|
| **≤ 10k** | ✅ Trivial | Full build in a few minutes. Pure SSG is ideal. |
| **10k – 50k** | ✅ Fine | ~5–20 min builds. Want build caching / incremental builds + CDN image transforms. |
| **50k – 100k** | ⚠️ Pushing it | 20–60+ min builds; CI cost & content-publish latency start to hurt. Begin hybrid planning. |
| **100k – 500k** | 🔶 Painful for pure SSG | Strongly favor hybrid: static for high-value/SEO pages, on-demand SSR + cache for the long tail. |
| **500k+** | ❌ Impractical | Hybrid / on-demand (ISR-style) is mandatory. |

**Both expected (≤11k) and aggressive (≤80k) 3-year ceilings keep us in the green-to-amber band where Astro SSG remains the right tool.** The decision is therefore robust across the full plausible range — we do not need to bet on the catalog staying small.

---

## Options considered

1. **Full static (Astro SSG) now — _chosen._** Pre-render all public/SEO pages; serve from CDN. Search, simulator, lead form, favoris are client islands hitting the read API; the developer/admin panel is a separate authenticated app.
   - ➕ Best SEO + fastest TTFB (CDN edge); simplest ops & security surface; cheapest hosting; perfectly matches read-heavy, low-write-frequency content; supports schema.org `RealEstateListing` (§10.2). ➖ Build time grows with the catalog; needs a content-change → rebuild pipeline (E9).
2. **Hybrid / on-demand (SSR or ISR) from day one.** Render long-tail pages on demand, cache at the edge.
   - ➕ Build time decoupled from page count; instant publish. ➖ Premature: adds a server runtime, cache-invalidation logic, and cost/ops we don't need at ≤11k pages. Build complexity now to solve a problem we don't have yet. **Reserved as E17.**
3. **Full SSR (no static).** Render everything per request behind a cache.
   - ➕ No build step. ➖ Worst fit: higher latency/cost, larger attack surface, redundant for content that changes rarely; throws away SSG's biggest wins for this workload.

---

## Decision

**Adopt full static rendering (Astro SSG) for the public frontend now.** Defer hybrid/on-demand rendering (E17) until a concrete, measured threshold is crossed.

### E17 trigger — pursue hybrid/on-demand when **any one** of these holds

1. **Scale:** total generated pages **> ~50,000** (≈ >25k programmes × 2 locales); *or*
2. **Build time:** full production build **> ~15 min** in CI **and** incremental/cached builds can no longer hold it under that; *or*
3. **Freshness:** content publish → live latency **> ~10 min** becomes a business problem (e.g. developers expect near-instant publish of new programmes or price changes); *or*
4. **Cost/cadence:** rebuild frequency × CI minutes becomes uneconomic (e.g. developer edits trigger rebuild storms).

When triggered, migration is **incremental and low-risk**: Astro allows per-route `export const prerender = false`. Keep the high-value, stable, SEO-critical routes static (home, city pages, published project details, articles) and switch only the **volatile / long-tail / low-traffic** routes to on-demand SSR with edge caching. That selective switch *is* the scope of E17.

---

## Rationale

- **Content profile fits SSG perfectly:** read-heavy, write-infrequent. A programme's details and price change occasionally, not per second.
- **SEO is a first-class requirement** (§2, §10.2). SSG delivers the best crawlability, Core Web Vitals, and structured data with the least effort.
- **Dynamic behavior is already isolated** from the static surface: search (API-backed island), simulator (client compute), lead form (POST to an API endpoint), favoris (client/session), and the **authenticated developer/admin panel (separate SSR app)**. None of these require per-programme SSR.
- **The numbers leave large headroom.** Expected 3-year load (~7–11k pages) is ~5–7× below the "pushing it" line; even the aggressive stress case (~50–80k) stays below it. We are not betting the architecture on optimistic growth.
- **Hybrid is cheap to add later, expensive to over-build now.** Astro's per-route opt-out makes E17 a targeted, additive change rather than a rewrite — so deferring it carries little risk.

## Consequences

**Positive**
- Cheapest, simplest, most secure hosting (static assets on a CDN); excellent SEO and performance from day one.
- Clear, measurable tripwires (above) make the eventual hybrid decision data-driven, not guesswork.

**Requires / follow-ups**
- **E9 rebuild pipeline must support incremental & cached builds early**, and a **content-change → rebuild trigger** (webhook from Phoenix on publish). **Debounce/batch** rebuilds so a burst of developer edits doesn't cause a rebuild storm.
- **Offload image processing to a CDN / on-the-fly transform service** (e.g. Cloudflare Images, imgproxy, or the CDN's resize endpoint) rather than generating every derivative at build time. This is the single most effective lever for keeping build time flat as the catalog grows — see Media (E6).
- **Instrument build metrics from day one** — page count, build duration, publish-to-live latency, rebuild frequency/cost — so the E17 thresholds above can actually be observed.
- **Do not pre-render filter permutations.** The `/programmes` search stays an API-backed client island; only base + paginated + per-city listing shells are statically generated.
- **Retain delivered / sold-out programmes as static archive pages** for SEO; at E17, the oldest low-traffic archive routes are the natural first candidates to move to on-demand rendering.
- Revisit this ADR if the **product definition changes** (e.g. adding resale inventory or unit-level pages), since either would shift the catalog toward Scenario B much faster.

---

## Notes

- The catalog unit assumed throughout is the **programme/project** (spec §1, §3, §7.3). The orchestrator's "agency × listings" framing is captured as the **Scenario B stress test**; the recommendation holds under both.
- Bead `super-fcu` cites "Spec §5, §16"; the current 14-section build spec (`newprojects.ma-build-spec.md`) does not contain a §16, so this ADR cites the sections that actually govern scale and rendering (§1, §2, §3, §7, §10, §12). Flag for the orchestrator if a longer canonical spec exists.

## Acceptance criteria (bead `super-fcu`)

- [x] Rough page counts documented; rendering strategy (**full static now**) confirmed.
- [x] Threshold defined for when to trigger **E17** (4 tripwires above; any one).
