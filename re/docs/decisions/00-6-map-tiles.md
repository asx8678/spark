# 0.6 — Map Tiles Source: PMTiles on R2 vs Hosted Provider

- **Status:** Accepted
- **Date:** 2026-06-08
- **Decision owner:** planning-agent (`planning-agent-41b0c2`)
- **Bead:** `super-i1h` (E0 Discovery — Open Decisions)
- **Affects:** E11 Maps (`super-x4l`, esp. `super-dex` 11.1), E6 Media/R2 (`super-w7z`)
- **Spec:** §8 (Maps), §16; R2 context §3.4

---

## Context

This is a greenfield real-estate listing platform targeting **Morocco**. Every listing
detail page shows a map of the property's location, and the results page shows a
clustered map of many listings. We must choose how to serve the map tiles.

Constraints and existing decisions that frame this choice:

- **Morocco coverage is the priority.** We need accurate streets, neighborhoods, and
  labels for the cities that matter (Casablanca, Rabat, Marrakech, Tangier, Fès,
  Agadir, Kénitra, Oujda, …).
- **Cost-sensitive, solo developer.** Tile providers bill per request/map-load; cost
  that scales with traffic is a real risk precisely when the product succeeds.
- **R2 is already in the architecture.** E6 (`super-w7z`) commits to **Cloudflare R2**
  for media because of its **$0 egress** and S3-compatible API; backups go to Hetzner
  Object Storage (EU).
- **MapLibre GL JS is already chosen** for the map UI (E11), rendered as **Astro 6**
  static-site islands (`client:visible`).
- **Self-host / own-your-data philosophy** runs through the stack: Phoenix + Oban
  backend, planned **self-hosted Nominatim** geocoding (11.4), Hetzner hosting.
- **PMTiles** is a serverless tile format: a single archive file on object storage,
  read by the client via HTTP **range requests** — no tile server to run. MapLibre GL
  JS supports it natively via the `pmtiles://` protocol. **Protomaps** publishes daily
  planet builds from OpenStreetMap and a `pmtiles extract` tool that pulls just a
  bounding-box/region out of the hosted planet file, plus open base map themes.

The roadmap (E11) was drafted assuming "tiles via PMTiles on R2." This record exists to
**rigorously validate that lean, quantify the trade-offs, and define an explicit escape
hatch** so we are not betting the product on a tile pipeline working perfectly.

---

## Options Considered

### Option A — PMTiles on Cloudflare R2 (serverless, self-sourced) ✅ chosen

A single **Morocco** vector basemap `.pmtiles` file (Protomaps schema, from
OpenStreetMap) hosted on R2, served over a Cloudflare-cached custom domain, rendered by
MapLibre GL JS with a forked Protomaps light theme.

- **Data quality (Morocco):** OpenStreetMap base — strong for Moroccan urban street
  networks, districts, and POIs; thinner in rural areas but more than adequate for
  "where is this property." Localized labels available via OSM `name:fr` / `name:ar`.
- **Cost:** storage ~$0.01/mo; **egress $0**; only cache-miss range GETs hit R2 as
  Class B operations (10M/mo free tier, then ~$0.36/M). A shared vector basemap caches
  extremely well at the edge. Effectively **flat and near-zero** at every traffic level
  (see cost table).
- **Maintenance:** one-time pipeline setup; periodic re-extract (monthly/quarterly) —
  basemaps rarely change. Can be a scheduled Oban job or CI step.
- **Styling:** full control via MapLibre style JSON; start from `protomaps-themes-base`.
- **Integration:** add `pmtiles` npm lib, register the protocol, point the style at
  `pmtiles://https://tiles.<domain>/morocco.pmtiles`. Genuinely simple on the client.
- **Gaps:** no satellite imagery; styling polish requires some upfront effort; you own
  the (small, infrequent) generation pipeline; R2 needs CORS + range + cache config.

### Option B — MapTiler (hosted, turnkey)

Cloud API with polished ready-made styles, global coverage, first-class MapLibre
support (MapTiler sponsors MapLibre), optional satellite, cloud style editor.

- **Pros:** fastest path to a pretty map; zero tile-generation work; satellite available;
  managed freshness.
- **Cons:** **per-request billing that scales with traffic**; client-visible API key on a
  static frontend (needs domain restriction; abuse burns quota); external dependency and
  ToS exposure; free tier typically watermarked / non-commercial, so commercial use likely
  means a paid plan from launch. Adds a second map vendor on top of R2.

### Option C — Mapbox (hosted, premium) ❌ rejected

- **Pros:** best-in-class styles and tooling (Studio).
- **Cons:** **most expensive by a wide margin** at scale; **Mapbox GL JS v2+ is
  proprietary-licensed** and its terms favor Mapbox GL over our chosen MapLibre — a
  licensing/ergonomics mismatch. Overkill for listing-location maps.

### Option D — Raw OSM raster tiles (`tile.openstreetmap.org`) ❌ rejected

- The OSMF tile-usage policy **prohibits heavy/commercial/bulk use**. Not permissible for
  a commercial product at scale. (Acceptable only as a throwaway dev placeholder.)

### Option E — Self-hosted vector tile server (Martin/Tegola/TileServer GL + PostGIS) ❌ rejected

- Full control and free at the edge, but it **reintroduces a server to run, scale, and
  patch** — exactly the ops burden PMTiles removes. Not justified for a solo dev when the
  serverless PMTiles route gives ~the same result with no running service.

> Honorable mentions evaluated and set aside: **Stadia Maps** (a reasonable hosted
> fallback with a free tier, similar profile to MapTiler) and **Protomaps' own hosted
> offering** (we instead self-host the file on R2 we already pay for).

---

## Cost Comparison (order-of-magnitude estimates, not vendor quotes)

> ⚠️ Provider pricing changes; verify current rates before launch. Assumptions: ~15–20
> tile fetches per map view at the origin **worst case**, but a **shared vector basemap
> caches heavily** (browser + Cloudflare edge), so real R2 origin hits are a small
> fraction of that. "Daily map views" → ×30 for monthly.

| Daily map views | PMTiles on R2 (chosen) | MapTiler (hosted) | Mapbox (rejected) |
|---|---|---|---|
| **1,000** (~30K/mo) | **~$0** (within R2 free tier) | ~$0–$25/mo (free tier may need watermark; commercial → entry plan) | ~$0 (within free 50K loads) but locks in GL licensing |
| **10,000** (~300K/mo) | **~$0–$1/mo** (mostly free tier; egress $0) | ~$25–$95/mo (paid plan) | ~$1,000+/mo at rack rate |
| **100,000** (~3M/mo) | **<$5/mo** (storage ~$0.01 + cache-miss GETs; ~$18/mo only if caching were disabled) | ~$200–$900+/mo (scales ~linearly) | thousands/mo at rack rate |

**Structural takeaway:** PMTiles-on-R2 cost is **near-zero and flat**; hosted-provider
cost grows roughly **linearly with success**. The cost risk asymmetry is the decisive
factor for a cost-sensitive solo project.

---

## Decision

**Adopt Option A: serve map tiles as a self-hosted Morocco **PMTiles** vector basemap on
**Cloudflare R2**, rendered with **MapLibre GL JS**, styled from a forked Protomaps light
theme with localized (FR-default, AR where available) labels.**

Operational specifics:

1. Generate `morocco.pmtiles` via `pmtiles extract` against the Protomaps hosted planet
   build, scoped to a Morocco bounding box / region (downloads only the region, not the
   planet).
2. Host it on R2 under a `tiles/` prefix behind a Cloudflare custom domain with **CORS +
   HTTP range** enabled and **Cache Rules** in front so repeat tile fetches are edge-served.
3. Keep the tile-source URL behind **one config/env value** so the source can be swapped
   without code changes (see escape hatch).
4. Re-extract on a low-frequency schedule (monthly/quarterly) via Oban or CI.

**Escape hatch (explicit, to de-risk the bet):** Keep the MapLibre style/tile source
behind a single config value. If, during E11, any of these prove true —
(a) Protomaps styling costs too much dev time for the needed polish,
(b) a **satellite** view becomes a hard requirement, or
(c) Morocco **label quality** is inadequate —
then swap the **detail-page** map (low volume, wants polish) to **MapTiler** while keeping
**PMTiles for the high-volume results map**. This hybrid caps spend and changing the
source is a one-line config edit, not a rewrite.

---

## Rationale

- **Cost risk asymmetry.** R2's $0 egress + free-tier/low Class B ops + heavy edge-cache
  hit rate on a shared basemap make tile cost **near-zero and flat**. Hosted pricing grows
  with traffic — the worst time for a surprise bill.
- **Reuses infrastructure we already committed to.** R2 is in the stack for media (E6);
  adding a `tiles/` object means **one fewer vendor**, one billing relationship, one CORS
  story — not a new dependency.
- **Native fit with chosen tech.** MapLibre GL JS (already chosen, E11) speaks `pmtiles://`
  out of the box; an Astro `client:visible` island drops in cleanly.
- **Coverage is sufficient for the job.** Both candidates ultimately use OpenStreetMap;
  Morocco's urban OSM data is good, and listing maps need location context, not survey
  precision. Arabic/French labels are available from OSM tags.
- **Matches the platform philosophy.** Self-hosted Nominatim (11.4), Phoenix/Oban, Hetzner
  — "own your data, avoid per-request lock-in" is already the house style; PMTiles is the
  consistent choice.
- **Low, predictable maintenance.** Basemaps are near-static; a quarterly re-extract is a
  cheap scheduled job, not ongoing toil.
- **Honest about the gap, mitigated.** The two real downsides — styling polish and no
  satellite — are addressed by the escape hatch and by the fact that clean > flashy for a
  listing map. We are not over-committing.

---

## Consequences

**Positive**

- Map tile cost effectively removed from the platform's variable-cost model.
- No new vendor, no client-visible API key to police, no per-request quota to fear.
- Full styling control; consistent ops story with the existing R2/Cloudflare setup.

**Negative / costs we accept**

- We own a (small, infrequent) **tile-generation pipeline** — setup + periodic re-extract.
- **Upfront styling effort** to fork/brand a Protomaps theme (vs. a ready-made hosted style).
- **No satellite imagery** by default (acceptable for listing-location maps; covered by the
  escape hatch if it becomes a requirement).
- R2 bucket needs correct **CORS + range + cache** configuration (one-time).

**Follow-ups to wire into the roadmap**

- **E11 / `super-dex` (11.1):** implement PMTiles-on-R2; mark the tile source as decided
  (= PMTiles). Document the `pmtiles extract` Morocco command.
- **New task (E11):** "Generate & host `morocco.pmtiles` + scheduled re-extract (Oban/CI)."
- **New task (E11):** "MapLibre style — fork Protomaps light theme, brand colors, FR/AR
  localized labels."
- **E6 / `super-w7z`:** add a `tiles/` prefix on R2 with CORS + HTTP range + Cloudflare
  Cache Rules for the tiles path.
- **Config:** keep the tile-source URL in one env/config value (preserves the escape hatch).
- **Cross-links:** label language depends on 0.3 (FR/AR/EN + RTL); geocoding quality is
  tracked separately in 11.4 (`super-ts6`) and is **out of scope** for this decision.

**Optimization worth noting (not blocking):** because detail pages are static (Astro) with
baked coordinates, a **pre-rendered static map image** for the detail page (zero client JS,
zero runtime tile cost, SEO-friendly) is a viable enhancement, reserving the interactive
PMTiles map for the results/clustering view. Recommended to evaluate during E11, not now.

---

## References

- Bead `super-i1h`; epic `super-0r0` (E0 Discovery).
- Related: `super-x4l` (E11 Maps), `super-dex` (11.1 tile source), `super-w7z` (E6 R2),
  `super-ts6` (11.4 geocoding).
- Protomaps (PMTiles format, planet builds, `pmtiles extract`, base themes).
- Cloudflare R2 pricing model ($0 egress; Class B operations; free tier).
- MapLibre GL JS `pmtiles://` protocol support.
