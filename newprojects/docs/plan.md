# Real Estate / Immo Platform — Full Implementation Plan

**Version:** 1.0 — June 2026
**Status:** Approved for decomposition into work packages
**Audience:** Planning agent + implementation team

---

## 0. Purpose of this document & instructions to the planning agent

This is the complete, self-contained implementation specification for a statically-rendered, SEO-first real-estate listing platform (Astro 6 on Cloudflare Workers) backed by an Elixir/Phoenix management application with co-located PostgreSQL on a Hetzner VPS.

**Instructions to the planning agent:**

1. Decompose **Section 16 (Work Breakdown)** into tickets. Phases must be executed in order; epics within a phase may run in parallel unless a dependency is listed.
2. Every task ID in §16 references the detailed specification sections (§3–§15). The spec sections are the source of truth for *how*; §16 defines *what* and *when*.
3. Items in **§17 Open Decisions** have stated defaults. Implement the default unless the product owner overrides it; do not block work on undecided items.
4. Treat **acceptance criteria** in §16 as the Definition of Done per task, in addition to the global DoD in §15.6.
5. Prefer vertical slices: each ticket should end in something testable/deployable, not a horizontal layer.
6. Do not re-litigate locked architectural decisions (§1.4). They are final for v1.

---

## 1. Product overview, requirements, locked decisions

### 1.1 What is being built

A property-listing platform ("programme neuf" / new developments, plus generic listings: apartments, land, houses, commercial, rentals) consisting of:

- A **public website**: prerendered static HTML served from Cloudflare's edge (Astro 6 → Workers Static Assets), optimized for SEO and Core Web Vitals, with interactive islands (search/filter, MapLibre maps).
- A **management application**: Phoenix (Elixir) on a Hetzner VPS — LiveView admin UI, versioned read-only JSON API, background jobs (Oban), payments, auth. Single source of truth.
- A **PostgreSQL database** co-located on the same VPS as Phoenix, accessed only via Ecto.
- **Cloudflare R2** for all public media (photos, floor plans, brochures, map tiles).

The codebase is **universal**: the same code can be deployed as different verticals (new-developments portal, land marketplace, rental site) and in different **render modes** (fully static, hybrid static+SSR, or fully dynamic/API-served) via configuration only.

### 1.2 Numbered product requirements (traceability)

| ID | Requirement |
|----|-------------|
| R1 | The static site is rebuilt on a **schedule** (default every 1 hour; configurable at runtime, e.g. 3 h) — **not** on every content change. |
| R2 | Content created **between builds** (e.g. a new apartment) must be visible immediately, served **dynamically from the Phoenix API** via SSR fallback, until the next scheduled build bakes it into static HTML. |
| R3 | When **existing published content is edited**, visitors must see the **fresh version from the API** immediately (the stale static file must be bypassed), and after the next scheduled build the page is served statically again. Unpublished content must immediately 404, not linger as a ghost static page. |
| R4 | Some deployments of this codebase will be served **entirely from the API** (no prerendering). Therefore all layouts, templates, description fields and data shapes must be **universal**: one view-model, one set of components, rendering identically from build-time data or request-time API data. Render mode is per-deployment configuration. |
| R5 | All images and public media are stored in and served from **Cloudflare R2** (edge-cached, first-party domain, on-the-fly resizing). |
| R6 | **PostgreSQL runs on the same Hetzner VPS as Phoenix** (co-located), with proper hardening and backups. |
| R7 | All communication between the Astro layer (build process, SSR Worker, browser islands) and Phoenix must use a **secure, least-privilege authentication scheme** with separately rotatable credentials per trust path. |
| R8 | SEO-first: unique metadata, JSON-LD structured data, sitemap, clean URLs, i18n with hreflang (FR default, AR with RTL, EN), excellent Core Web Vitals. |
| R9 | Polymorphic catalog: configurable `property_types` + JSONB attributes + admin-defined custom fields; new verticals are data + templates + theme, not schema rewrites. |
| R10 | Payments: B2B subscriptions for developers/agencies behind a provider-adapter (Stripe primary, CMI adapter for Morocco), hosted checkout only, idempotent webhooks. |

### 1.3 Non-goals (v1)

- No public visitor accounts (favorites/saved searches) — inquiry forms only. (Design leaves room; see §10.6.)
- No native mobile apps.
- No multi-tenant single-deployment (one deployment = one vertical/brand; multi-vertical = multiple deployments of the same code).
- No real-time collaborative editing in admin.

### 1.4 Locked architectural decisions

| # | Decision | Rationale |
|---|----------|-----------|
| A1 | Astro 6, `output: 'static'` baseline + selective SSR routes; official Cloudflare adapter | Build-time SEO surface; workerd dev/prod parity |
| A2 | Cloudflare **Workers Static Assets** (not Pages — maintenance mode) | Forward-looking; same edge CDN; Git builds + previews |
| A3 | Phoenix (LiveView admin + JSON API + Oban) as the only writer; single app | One source of truth, no second backend |
| A4 | PostgreSQL 17 co-located on the Phoenix VPS, localhost-only | R6; cheap, simple ops at this scale |
| A5 | Scheduled rebuilds via **Oban Cron** + freshness layer (Workers KV dirty markers + SSR fallback) | R1–R3; replaces the earlier "rebuild on publish" design |
| A6 | R2 with custom domain `media.<domain>` + Cloudflare Image Transformations; originals only, content-hashed keys | R5 |
| A7 | MapLibre GL JS + Protomaps **PMTiles on R2** (no tile server) | Serverless, fits CF frontend |
| A8 | `mix phx.gen.auth` + RBAC for staff; bearer tokens for machine paths; Cloudflare Tunnel for origin lockdown | R7 |
| A9 | OpenAPI contract (`open_api_spex` → `openapi-typescript`) shared by backend and frontend | R4; prevents drift between static and SSR paths |
| A10 | Monorepo: `/backend`, `/frontend`, `/infra`, `/docs` | Atomic cross-cutting changes, single CI |

---

## 2. System architecture

### 2.1 Components and planes

```mermaid
flowchart LR
    subgraph Browser["Visitor's browser"]
        HTML["Static HTML/CSS (zero-JS pages)"]
        ISL["Islands: search/filter, MapLibre"]
    end

    subgraph CF["Cloudflare edge"]
        WK["Worker (custom entry)\nfreshness routing + Astro SSR handler"]
        AST["Static Assets\n(astro build output)"]
        KV[("Workers KV\nFRESHNESS namespace")]
        R2[("R2: media.<domain>\nphotos, plans, PMTiles")]
        IMG["Image Transformations\n/cdn-cgi/image/*"]
    end

    subgraph CI["Build pipeline (Workers Builds or GH Actions)"]
        BUILD["astro build\nContent Layer loader → static pages\nemits /__build.json"]
    end

    subgraph VPS["Hetzner VPS (single box)"]
        TUN["cloudflared tunnel"]
        PHX["Phoenix\nLiveView admin · /api/v1 · webhooks"]
        OBAN["Oban\ncron rebuild · KV writes · geocode · email · payments"]
        PG[("PostgreSQL 17\nlocalhost only")]
    end

    Browser -->|GET pages| WK
    WK -->|fresh path| AST
    WK -->|stale/missing path: SSR| PHX
    WK <-->|dirty markers| KV
    Browser -->|search, bbox, inquiries| PHX
    Browser -->|images srcset| IMG --> R2
    OBAN -->|hourly: deploy hook| CI
    BUILD -->|GET /api/v1 (BUILD_TOKEN)| PHX
    BUILD --> AST
    OBAN -->|PUT dirty keys (CF API token)| KV
    PHX --> PG
    PHX -->|presigned uploads| R2
    TUN --- PHX
```

Three planes:

- **Build plane** (hourly): CI runs `astro build`; the Content Layer loader pulls all *published* content from `/api/v1` with `BUILD_TOKEN`; output (static pages + `/__build.json`) deploys atomically to Workers Static Assets.
- **Request plane**: the custom Worker entry decides per request — serve the static asset (state A) or render via Astro SSR against the Phoenix API with `RENDER_TOKEN` (states B/C). Browser islands call narrow public endpoints directly.
- **Admin plane**: staff manage content in LiveView; writes persist via Ecto; side-effects (KV dirty markers, geocoding, media derivatives, payment webhooks, the hourly rebuild) run in Oban.

### 2.2 Render modes (R4)

One environment variable controls how a deployment renders. Implemented with an Astro integration using the `astro:route:setup` hook to flip `route.prerender` at build time.

| `RENDER_MODE` | Behavior | Use case |
|---|---|---|
| `static` | All content routes prerendered; SSR only for the fallback catch-alls; freshness layer active | Default — flagship portal |
| `hybrid` | Landing/category/detail pages prerendered; explicitly-listed routes (e.g. `/search`, category indexes) always SSR with short edge cache | Large catalogs, very fresh index pages |
| `dynamic` | No prerendering; every route SSR against the API; no scheduled builds needed (deploy only on code change); aggressive edge caching with `s-maxage` + stale-while-revalidate | "Served only via API" deployments |

Hard rule enforcing universality: **page templates and components never know the render mode.** They receive a typed view-model (§7.3) and nothing else. Any PR that branches template logic on `RENDER_MODE` or data source fails review.

---

## 3. Rendering & freshness model (core mechanism — R1, R2, R3)

This section replaces the earlier "rebuild on publish" design. The model is **scheduled rebuilds + a dynamic gap-filler** (DIY incremental static regeneration on Cloudflare).

### 3.1 The three page states

Every content URL (`/projects/*`, `/listings/*` (or per-type paths), `/developers/*`, localized variants) is in exactly one state:

| State | Condition | Served by | Mechanism |
|---|---|---|---|
| **A — built & current** | Static asset exists; no dirty marker newer than the build | Static Assets (CDN) | `env.ASSETS.fetch()` — ~99% of traffic, zero origin load |
| **B — new since last build** | No static asset exists (published after last build) | Astro SSR in the Worker | Asset miss → SSR catch-all route fetches the one record from Phoenix and renders the same template |
| **C — edited/unpublished since last build** | Static asset exists but a KV dirty marker is newer than `built_at` | Astro SSR in the Worker | Worker checks KV before assets; bypasses the stale file. Unpublished → API 404 → real 404 page |

After the next successful build, B and C pages collapse back to A automatically (the comparison `dirty_at > built_at` flips). No marker deletion is required for correctness; TTL handles cleanup.

### 3.2 Scheduled rebuild pipeline (Phoenix side)

**Trigger:** Oban Cron, interval from runtime env (changeable without redeploy):

```elixir
# config/runtime.exs
config :immo, Oban,
  repo: Immo.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {System.get_env("REBUILD_CRON", "0 * * * *"), Immo.Jobs.RebuildSite}
     ]}
  ],
  queues: [default: 10, rebuild: 1, media: 5, mailers: 5, payments: 5]
```

`Immo.Jobs.RebuildSite` (queue `rebuild`, `unique: [period: 300]`) algorithm:

1. **Load last successful build** from the `builds` table (`status = succeeded`, max `content_snapshot_at`).
2. **Skip-if-unchanged:** compute `max(updated_at)` across published `projects`, `listings`, `developers`, `property_types`, `media`. If ≤ last `content_snapshot_at` **and** no pending redirects, record a `builds` row with `status = skipped` and stop. (Quiet nights cost zero build minutes.)
3. **Re-arm dirty markers (self-healing):** for every record changed since last successful `content_snapshot_at`, recompute its public path set (§3.5) and re-PUT KV dirty keys. This guarantees that if a previous build *failed*, changed pages keep serving fresh SSR instead of stale statics.
4. **Trigger the build:** `POST` the Cloudflare **deploy hook** URL (secret). Insert `builds` row: `status = running`, `trigger = :cron`, `content_snapshot_at = now()`.
5. **Confirm completion:** schedule `Immo.Jobs.ConfirmBuild` (snooze/retry every 60 s, max 30 min) which polls `https://<site>/__build.json`. Success when `content_snapshot_at` in the file ≥ the value recorded in step 4 → mark `succeeded`, store `built_at`. Timeout → mark `failed` + alert (§14).
6. **Manual trigger:** admin "Rebuild now" button enqueues the same job with `trigger = :manual` (bypasses skip-if-unchanged).

**Build-minutes note:** hourly = ~720 builds/month. Verify the Workers Builds quota on the chosen Cloudflare plan during P0. Fallback (decision D3, §17): GitHub Actions runs `astro build && wrangler deploy`, triggered by Phoenix via GitHub API `workflow_dispatch` — same architecture, free minutes; `ConfirmBuild` polling is unchanged.

**Interval semantics:** once the freshness layer exists, the interval is a **cost knob, not a freshness knob** — visitors always see current data. It controls only (a) how long changed pages ride SSR (origin load on the VPS) and (b) build-minute spend. Default `0 * * * *`; relaxing to `0 */3 * * *` changes nothing user-visible.

### 3.3 `/__build.json` contract

Emitted by a tiny Astro integration on `astro:build:done` into the publish dir. Ground truth for "what data is baked into the current deployment".

```json
{
  "built_at": "2026-06-10T14:02:31Z",
  "content_snapshot_at": "2026-06-10T14:01:09Z",
  "git_sha": "ab12cd3",
  "render_mode": "static",
  "locales": ["fr", "ar", "en"]
}
```

- `content_snapshot_at` = max `updated_at` observed by the Content Layer loader across all collections during this build (loader records it; integration reads it from a shared module).
- Consumed by: the Worker (staleness comparison, memoized 60 s), `ConfirmBuild` (step 5 above), and the build-age monitor (§14).

### 3.4 Worker request routing (custom entry)

`run_worker_first` limits Worker invocation to content routes; CSS/JS/images/fonts stay pure-static (free, no Worker CPU).

```jsonc
// frontend/wrangler.jsonc (excerpt)
{
  "name": "immo-frontend",
  "main": "./dist/_worker.js/index.js",
  "compatibility_date": "2026-05-01",
  "assets": {
    "directory": "./dist",
    "binding": "ASSETS",
    "run_worker_first": [
      "/projects/*", "/listings/*", "/developers/*",
      "/fr/*", "/ar/*", "/en/*",
      "/__health"
    ]
  },
  "kv_namespaces": [
    { "binding": "FRESHNESS", "id": "<namespace-id>" }
  ]
}
```

Custom entry wraps Astro's generated SSR handler:

```ts
// frontend/src/worker/index.ts (conceptual)
import astroHandler from '../../dist/_worker.js/_astro-entry'; // adapter export — verify exact name in P4

let buildInfo: { builtAt: number } | null = null;
let buildInfoFetchedAt = 0;

async function getBuiltAt(env: Env): Promise<number> {
  if (!buildInfo || Date.now() - buildInfoFetchedAt > 60_000) {
    const res = await env.ASSETS.fetch('https://internal/__build.json');
    const j = res.ok ? await res.json() : { built_at: 0 };
    buildInfo = { builtAt: Date.parse(j.built_at) || 0 };
    buildInfoFetchedAt = Date.now();
  }
  return buildInfo.builtAt;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    const url = new URL(request.url);

    if (isContentPath(url.pathname)) {
      const [builtAt, dirtyAt] = await Promise.all([
        getBuiltAt(env),
        env.FRESHNESS.get(`path:${normalize(url.pathname)}`),
      ]);
      const stale = dirtyAt !== null && Number(dirtyAt) * 1000 > builtAt;

      if (!stale) {
        const asset = await env.ASSETS.fetch(request);
        if (asset.status !== 404) return asset;          // State A
      }
      try {
        return await astroHandler.fetch(request, env, ctx); // State B / C
      } catch (_) {
        const fallback = await env.ASSETS.fetch(request);   // stale beats error
        if (fallback.status !== 404) {
          const r = new Response(fallback.body, fallback);
          r.headers.set('x-immo-serving', 'stale-fallback');
          return r;
        }
        return new Response('Temporarily unavailable', { status: 503,
          headers: { 'retry-after': '120' } });
      }
    }
    // Non-content paths reaching the Worker (locale roots etc.): assets first, then SSR
    const asset = await env.ASSETS.fetch(request);
    return asset.status !== 404 ? asset : astroHandler.fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
```

**Route-precedence risk (must be validated in P4 first):** the prerendered `[slug].astro` pages and the SSR catch-all `[...slug].astro` share a path family. If the adapter's route matching on the pinned Astro/adapter versions is ambiguous, switch to the deterministic variant: SSR routes live under internal paths (`/_render/listings/[slug]`) and the Worker entry **rewrites** the request URL before delegating. Both variants are acceptable; pick once in P4-E1 and document.

**Cache headers emitted by SSR responses:** `cache-control: no-store` for state C (must reflect edits instantly), `cache-control: public, s-maxage=60, stale-while-revalidate=300` for state B (new content can tolerate 60 s edge cache to shield the VPS from hot-new-listing traffic). Plus `x-immo-serving: ssr-new | ssr-dirty | static` header for observability and e2e tests.

### 3.5 KV freshness contract (state C writes)

- Namespace: `FRESHNESS` (one per environment: prod/staging).
- Key format: `path:<normalized public path>` — e.g. `path:/fr/projects/casablanca/les-jardins-anfa`. Normalization: lowercase, no trailing slash, no query.
- Value: integer **unix seconds** of the change (`updated_at`).
- TTL: `FRESHNESS_TTL_SECONDS` = **2 × rebuild interval** (default 7200). TTL is cleanup only; correctness comes from the `dirty_at > built_at` comparison.
- Writer: `Immo.Edge.Freshness.mark_dirty(paths, ts)` → Cloudflare REST API (`PUT /accounts/:acct/storage/kv/namespaces/:ns/values/:key?expiration_ttl=:ttl`), called from Oban job `MarkPathsDirty` (retries, `max_attempts: 8`).
- **Path computation** (`Immo.Edge.Paths.for(record)`): a published listing yields its detail path **per locale**, its parent project's detail paths (project pages embed unit lists), and nothing else. A project yields its own paths per locale. A developer yields developer paths per locale. Category/index pages are *not* marked (see §3.6).
- **Trigger points** (in context functions, after successful Repo transaction):
  - update of a *published* record → `mark_dirty(paths(record), record.updated_at)`
  - unpublish / delete of a published record → same (SSR will get API 404 → renders 404 page with `no-store`)
  - publish of a *new* record → **no KV write needed** (state B works by asset miss) — but write it anyway for the project-parent paths, since the parent's static page now misses a unit.
  - slug change → mark old path dirty **and** insert a `redirects` row (§3.8).
- **KV eventual consistency (~60 s)** is accepted: an edit may serve the stale static at some edge for up to a minute. If product later demands stricter, the documented alternative is the Worker calling `GET /api/v1/internal/freshness?path=...` (§6.4) with a 30 s edge cache — stronger consistency, more origin traffic. Not in v1.

### 3.6 Index, category, and landing pages

A new listing's **detail page** is live instantly (state B), but static **index/category pages** won't show its card until the next build. Per-route policy:

| Route | Policy (default) |
|---|---|
| Home `/`, static landings | Static; ≤ interval lag accepted |
| Category/city indexes (`/projects/`, `/apartments/casablanca/`) | Static; ≤ interval lag accepted. If product wants instant: flip to SSR with `s-maxage=120` via the hybrid route list — config change only |
| `/search` results | Always client-side island against `/api/v1/search` — never stale, never indexed for content (page shell is static) |
| `sitemap.xml` | Build-time (`@astrojs/sitemap` + custom entries from §6.3 sitemap endpoint); ≤ interval lag accepted — Google tolerance is far above 1 h |
| RSS/Atom feed of new projects | Build-time |

### 3.7 Graceful degradation (VPS down)

- SSR attempt fails → serve the existing static asset even if marked dirty (**stale beats error**), tagged `x-immo-serving: stale-fallback`; only 503 when no asset exists (state B paths).
- Browser islands: search/map/inquiry calls get UI-level error states ("search temporarily unavailable") — static page content remains fully usable.
- This property — the public site survives a total Hetzner outage — is a primary reason the static layer exists. Protect it in code review: no SSR-only critical path for state-A pages.

### 3.8 Slugs & redirects

- Slugs are **immutable after first publish** in the admin UI by default; an admin-role override edits them.
- On slug change: write a row to `redirects` (old_path, new_path, 301), mark old path dirty in KV, and the SSR catch-all consults redirects (via API) to serve 301 immediately. At build time, redirects export into the static deployment (`_redirects`-equivalent: a generated `redirects.json` consumed by the Worker entry before asset lookup — single mechanism for both static and SSR).

### 3.9 Phasing of this mechanism (mirrors §16)

1. **P3:** scheduled builds + `builds` table + confirm/alerting. (Site freshness = interval; acceptable interim.)
2. **P4 step 1:** State B — SSR catch-alls on asset miss. Covers "new apartments visible immediately" with **zero KV machinery**.
3. **P4 step 2:** State C — KV dirty layer for edits/unpublish + stale-beats-error + redirects.

This ordering ships user value early and isolates the most complex piece (C) behind a working baseline.

---

## 4. Repository & project structure

Monorepo (A10):

```
immo/
├── backend/                      # Phoenix app (Elixir 1.18 / OTP 27, Phoenix 1.8)
│   ├── lib/immo/                 # contexts: Catalog, Media, CRM, Accounts, Billing, Edge
│   ├── lib/immo_web/             # LiveView admin, API controllers, plugs
│   ├── lib/immo/jobs/            # Oban workers (RebuildSite, ConfirmBuild, MarkPathsDirty, Geocode, ...)
│   ├── priv/repo/migrations/
│   ├── priv/static/openapi.json  # generated, committed (A9)
│   └── test/
├── frontend/                     # Astro 6
│   ├── src/pages/                # routes (§7.1)
│   ├── src/loaders/              # Content Layer loaders (§7.2)
│   ├── src/lib/                  # api.ts, mappers.ts, api-types.ts (generated), paths.ts, seo.ts
│   ├── src/components/           # shared UI (§7.4) — render-mode agnostic
│   ├── src/islands/              # SearchFilter, ListingMap, InquiryForm
│   ├── src/worker/index.ts       # custom Worker entry (§3.4)
│   ├── src/integrations/         # build-info.ts (/__build.json), render-mode.ts (§2.2)
│   ├── astro.config.mjs
│   └── wrangler.jsonc
├── infra/
│   ├── compose.yml               # Phoenix + Postgres + cloudflared (+ Caddy if no tunnel)
│   ├── cloudflared/config.yml
│   ├── pgbackrest/ | walg/
│   └── runbooks/                 # deploy, restore-drill, rotate-secrets, incident
├── docs/                         # this plan, ADRs, API docs
└── .github/workflows/            # ci.yml, backend-deploy.yml, frontend-build.yml (D3 fallback)
```

Conventions: Elixir — `mix format`, Credo strict, Dialyzer in CI. TypeScript — strict mode, ESLint, Prettier. Conventional commits. One ADR markdown file per locked decision change.

---

## 5. Data model (PostgreSQL, owned by Ecto)

All tables: `id uuid` (v7) PK, `inserted_at`/`updated_at` timestamptz. Citext extension for slugs/emails. Naming below = Ecto schema fields; planning agent maps 1:1 to migrations.

### 5.1 `developers`
| field | type | notes |
|---|---|---|
| name | string, required | |
| slug | citext, unique | immutable after publish (§3.8) |
| description | jsonb | i18n map `{"fr": "...", "ar": "...", "en": "..."}` |
| logo_media_id | uuid fk → media, nullable | |
| contact | jsonb | phone, email, website, address |
| seo | jsonb | i18n: title, meta_description, og fields; auto-fallback in frontend |
| published_at | timestamptz, nullable | null = draft |

### 5.2 `projects` (new developments — headline entity)
| field | type | notes |
|---|---|---|
| developer_id | fk, required | |
| title, slug | jsonb i18n / citext unique | |
| status | enum: `preselling \| under_construction \| delivered` | |
| description | jsonb i18n | |
| address, city, region, country | strings | country ISO-3166 alpha-2, default `MA` |
| lat, lng | float, nullable | filled by Geocode job; admin map-pin override |
| delivery_date | date, nullable | |
| amenities | jsonb | array of keys, rendered via i18n dictionary |
| seo | jsonb i18n | |
| featured | boolean default false | drives home-page ordering |
| published_at | timestamptz nullable | publishing gated by developer's active subscription (§11) |

Indexes: `(published_at)`, `(city, status)`, `(developer_id)`.

### 5.3 `property_types` (configurable categories — R9)
| field | type | notes |
|---|---|---|
| key | citext unique | `apartment`, `land`, `house`, `commercial`, `rental`, ... |
| label | jsonb i18n | |
| url_segment | jsonb i18n | e.g. fr `appartements`, drives routes `/{segment}/{city}/{slug}` |
| filter_config | jsonb | ordered facet list the search island renders: `[{key, kind: range\|select\|boolean, source: column\|attribute\|custom_field, unit, min, max, options}]` |
| schema_hints | jsonb | known attribute keys + types for admin form rendering & API validation |
| position | integer | |

### 5.4 `listings` (units / standalone items)
| field | type | notes |
|---|---|---|
| project_id | fk nullable | null = standalone (plot, resale, rental) |
| property_type_id | fk required | |
| title, slug | jsonb i18n / citext | slug unique **per property_type** |
| description | jsonb i18n | |
| price | numeric(14,2) nullable | |
| price_on_request | boolean default false | |
| currency | char(3) default `MAD` | ISO-4217 |
| status | enum: `available \| reserved \| sold \| rented \| hidden` | sold/rented stay published with badge (SEO value) unless hidden |
| address, city, region | strings | inherits project location when project_id set and fields blank |
| lat, lng | float nullable | |
| surface_m2 | numeric(10,2) nullable | universal enough to be a column (sorting/filtering) |
| attributes | jsonb | type-specific bag: bedrooms, bathrooms, floor, zoning, buildable_ratio, lease_term, ... validated against schema_hints + custom_fields |
| seo | jsonb i18n | |
| published_at | timestamptz nullable | |

Indexes: GIN on `attributes` (`jsonb_path_ops`), `(property_type_id, status, published_at)`, `(city)`, `(price)`, `(lat, lng)` btree pair (bbox queries: simple range predicates; PostGIS explicitly deferred — see D7), partial index `WHERE published_at IS NOT NULL`.

### 5.5 `custom_fields` (admin-defined, per type — R9)
| field | type |
|---|---|
| property_type_id | fk |
| key | citext, unique per type |
| label | jsonb i18n |
| field_type | enum: `string \| integer \| decimal \| boolean \| select \| multiselect \| date` |
| options | jsonb (for selects) |
| searchable | boolean (adds facet to filter_config at read time) |
| required | boolean |
| position | integer |

Values live inside `listings.attributes` under the field key — no EAV tables.

### 5.6 `media`
| field | type | notes |
|---|---|---|
| attachable_type / attachable_id | string + uuid | polymorphic: Project, Listing, Developer |
| kind | enum: `photo \| floorplan \| brochure \| document \| logo` | |
| r2_key | string | `media/{attachable_type}/{attachable_id}/{content_sha256}.{ext}` |
| content_type, byte_size, width, height | metadata | |
| blurhash | string nullable | LQIP, computed by Oban (§8) |
| alt | jsonb i18n | required for photos before publish (SEO/a11y gate) |
| position | integer | |

Index: `(attachable_type, attachable_id, position)`.

### 5.7 `inquiries` (leads)
listing_id fk nullable · project_id fk nullable · name · email · phone · message text · locale · consent boolean (GDPR/Law 09-08) · source string · status enum `new|contacted|closed` · handled_by_user_id fk nullable. Retention job purges closed inquiries after `INQUIRY_RETENTION_DAYS` (default 365).

### 5.8 `users` (staff — phx.gen.auth base)
phx.gen.auth columns + `role` enum `admin | manager | editor | developer_user` + `developer_id` fk nullable (required iff role = developer_user; scopes all queries to own projects).

### 5.9 `subscriptions` & `payments` (§11)
`subscriptions`: developer_id fk · plan enum `basic|featured|enterprise` · status enum `trialing|active|past_due|canceled` · provider enum `stripe|cmi|manual` · provider_subscription_id · current_period_start/end · cancel_at_period_end boolean.
`payments`: subscription_id fk · amount numeric(14,2) · currency · status enum `pending|succeeded|failed|refunded` · provider · provider_payment_id unique (idempotency) · invoice_url · paid_at · raw_event jsonb.

### 5.10 `builds` (§3.2)
status enum `queued|running|succeeded|failed|skipped` · trigger enum `cron|manual` · content_snapshot_at timestamptz · started_at · finished_at · built_at (from `/__build.json`) · error text · git_sha.

### 5.11 `redirects` (§3.8)
old_path citext unique · new_path · http_status int default 301 · reason.

### 5.12 `audit_log`
user_id · action · entity_type · entity_id · diff jsonb · at. Written by a thin context wrapper for all admin mutations. (Compliance + debugging "why did this page change".)

### 5.13 Publish-state rule (single definition)

"Published" = `published_at IS NOT NULL AND published_at <= now()` **and**, for projects/listings, the owning developer has an `active|trialing` subscription (when billing is enabled; feature-flag `BILLING_ENFORCED`). This predicate is implemented **once** as a composable Ecto query (`Catalog.published/1`) and used by: read API, sitemap endpoint, search, geo, and the skip-if-unchanged check. No second definition anywhere.

---

## 6. Phoenix backend specification

### 6.1 Contexts (bounded responsibilities)

| Context | Owns |
|---|---|
| `Immo.Catalog` | developers, projects, listings, property_types, custom_fields, redirects; the `published/1` query; publish/unpublish transitions |
| `Immo.Media` | media records, presigned R2 uploads, derivative jobs |
| `Immo.CRM` | inquiries, retention |
| `Immo.Accounts` | staff users, RBAC |
| `Immo.Billing` | subscriptions, payments, provider adapters, webhooks |
| `Immo.Edge` | builds, freshness (KV writes), path computation, deploy-hook client |

### 6.2 Admin (LiveView) feature list

- CRUD for all §5 entities with role gating (`on_mount` hooks): `admin` everything; `manager` catalog+CRM+billing-read; `editor` catalog only; `developer_user` own projects/listings only.
- Publish/unpublish with subscription-gate feedback; slug lock + admin override; i18n field tabs (fr/ar/en) with completeness indicators; per-locale SEO preview snippet (SERP-style).
- Media manager: drag-drop multi-upload via **presigned PUT direct to R2** (§8), reorder (position), alt-text enforcement before publish, floorplan/brochure kinds.
- Map pin: MapLibre mini-map in forms; geocode button (enqueues `Geocode`); manual drag-to-correct writes lat/lng.
- Custom-fields builder per property type (creates §5.5 rows; instantly reflected in admin listing forms and search facets).
- Inquiries inbox: status workflow, assignment, CSV export.
- Billing screens: subscription status per developer, payment history, manual "mark paid" (provider = manual) for offline CMI onboarding.
- Build dashboard: builds table, current `/__build.json` snapshot, **"Rebuild now"** button, last-failure alert banner, current `REBUILD_CRON` display.
- Audit log viewer (admin only).

### 6.3 Public read API — `/api/v1` (JSON; OpenAPI source of truth)

Auth tiers (full details §10): **build** = `BUILD_TOKEN` bearer; **render** = `RENDER_TOKEN` bearer; **public** = anonymous, CORS-allowlisted + rate-limited.

| Endpoint | Auth | Purpose / params |
|---|---|---|
| `GET /projects` | build | Full publishable dump. `cursor`, `limit≤100`, `since` (ISO ts → only records with `updated_at > since`; powers incremental loader sync) |
| `GET /projects/:slug` | render | Single record, all locales, embedded media + published listings summary. 404 if not published |
| `GET /listings` | build | Same pagination/`since` contract |
| `GET /listings/:type_key/:slug` | render | Single record |
| `GET /developers`, `GET /developers/:slug` | build / render | |
| `GET /property_types` | build | Includes `filter_config` (merged with searchable custom fields) and `url_segment` |
| `GET /meta/sitemap` | build | All public paths + `lastmod` + locale alternates — feeds sitemap + redirects export |
| `GET /redirects` | build | Active redirects for the build-time `redirects.json` |
| `GET /search` | public | `q` (websearch_to_tsquery over title/description/city), `type`, `city`, `price_min/max`, `surface_min/max`, `attrs[<key>]=...` (validated against filter_config), `sort` (price_asc/desc, newest), `page≤50`, `per_page≤24`. Returns card view-models |
| `GET /listings/geo` | public | `bbox=minLng,minLat,maxLng,maxLat` (max span guard), `type`, `limit≤500` → GeoJSON FeatureCollection (id, title, price, path, thumb) |
| `POST /inquiries` | public | Body + `turnstile_token` (verified server-side); 5/min/IP |
| `GET /internal/freshness?path=` | render | `{updated_at}` or 404 — documented KV alternative (§3.5); implemented, unused by default |

Response conventions: every record carries `id`, `slug`, `path` (canonical public path per locale — computed server-side by `Immo.Edge.Paths`, the **single** path authority shared with KV marking), `updated_at`, `published_at`, i18n maps as objects keyed by locale. List envelope: `{data: [], meta: {next_cursor, count}}`. **ETag** (strong, from `max(updated_at)+count` of the page) on all build/render GETs; honor `If-None-Match` → 304 (cheap hourly re-syncs). `Cache-Control: private, no-store` on public search (the page shell caches, results must not), `public, s-maxage=60` permissible on `geo`.

Errors: RFC 9457 problem+json. Versioning: breaking changes → `/api/v2`; additive fields are non-breaking by contract.

OpenAPI: `open_api_spex` specs on every controller; CI step `mix openapi.spec.json --spec ImmoWeb.ApiSpec -o priv/static/openapi.json`; spec drift (uncommitted diff) fails CI.

### 6.4 Auth plug (machine tokens)

```elixir
defmodule ImmoWeb.Plugs.BearerAuth do
  import Plug.Conn
  def init(scope), do: scope
  def call(conn, scope) do
    expected = token_for(scope) # :build | :render from runtime env
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- byte_size(expected) > 0,
         true <- Plug.Crypto.secure_compare(token, expected) do
      assign(conn, :api_scope, scope)
    else
      _ -> conn |> put_status(401) |> Phoenix.Controller.json(%{error: "unauthorized"}) |> halt()
    end
  end
end
```

Pipelines: `:api_build` (BearerAuth :build), `:api_render` (BearerAuth :render), `:api_public` (CORS + RateLimit + no auth). Render token additionally accepted on build-tier endpoints? **No** — scopes are disjoint; the SSR path never needs list dumps.

### 6.5 Oban jobs catalog

| Job | Queue | Trigger | Spec |
|---|---|---|---|
| `RebuildSite` | rebuild (concurrency 1) | Cron / manual | §3.2; unique 300 s |
| `ConfirmBuild` | rebuild | After RebuildSite | Poll `/__build.json`; snooze 60 s; 30 min timeout → failed + alert |
| `MarkPathsDirty` | default | Catalog publish-state/content transitions (§3.5) | PUT KV keys via CF API; max_attempts 8, backoff |
| `Geocode` | default | Address saved / button | Nominatim (`User-Agent` set, ≤1 rps) or provider (D6); writes lat/lng unless manually pinned |
| `MediaDerivatives` | media | After upload confirm | HEAD R2 object, store width/height/byte_size, compute blurhash (download once), validate content-type allowlist |
| `PaymentWebhookProcessor` | payments | Webhook controller | §11; idempotent on provider event id |
| `InquiryNotifier` | mailers | Inquiry insert | Swoosh email to assigned staff |
| `RetentionSweeper` | default | Daily cron | §5.7 purge |
| `BuildAgeMonitor` | default | Every 15 min cron | Alert if site `/__build.json.built_at` older than 2× interval (§14) |

### 6.6 Payment webhooks endpoint

`POST /webhooks/:provider` — verify signature (Stripe-Signature / CMI MAC) against raw body **before** parsing; insert raw event; enqueue `PaymentWebhookProcessor`; respond 200 fast. Replay-safe: unique index on `provider_payment_id` / event id.

---

## 7. Astro frontend specification

### 7.1 Routes

| Path (fr shown; localized via `url_segment` + i18n routing) | Mode (RENDER_MODE=static) | Source |
|---|---|---|
| `/` and locale roots | prerender | loader |
| `/projets/` index, `/projets/[city]/` | prerender | loader |
| `/projets/[city]/[slug]` | prerender (`getStaticPaths`) | loader |
| `/projets/[...fallback]` | SSR catch-all (state B/C) | render API |
| `/{type_segment}/[city]/[slug]` + `[...fallback]` | prerender + SSR catch-all | loader / render API |
| `/promoteurs/[slug]` + catch-all | prerender + SSR | loader / render API |
| `/recherche` | prerender shell; island does the work | public API |
| `/contact`, legal pages | prerender | content files |
| `sitemap.xml`, `robots.txt`, `rss.xml`, `/__build.json` | build artifacts | loader / integrations |
| 404 | prerendered page; SSR catch-alls render it on API 404 with `no-store` | |

`RENDER_MODE=dynamic`: the render-mode integration flips all content routes to `prerender = false`; catch-alls become the primary handlers; loaders are skipped (build has no token); SSR responses get `s-maxage=300, stale-while-revalidate=600`. `hybrid`: list in `HYBRID_SSR_ROUTES` env flips named index routes only.

### 7.2 Content Layer loaders (build time)

One generic loader factory `phoenixLoader({collection, endpoint})` used for projects, listings, developers, property_types:
- Paginates with `cursor`; passes `since = <stored high-water mark>` from the loader's persisted meta → **incremental syncs keep hourly builds fast as the catalog grows**.
- Sends `Authorization: Bearer ${BUILD_TOKEN}` (from `astro:env` server secret schema).
- Stores records by `id`; sets `digest` from `updated_at`; tracks global `max(updated_at)` in a shared module read by the build-info integration (§3.3).
- Failure policy: any non-2xx after 3 retries **fails the build** (a partial catalog must never deploy; the previous deployment simply stays live).

### 7.3 View-models & API client (the universality contract — R4)

- `src/lib/api-types.ts` — **generated** from `backend/priv/static/openapi.json` via `openapi-typescript`; regenerated in CI; drift fails the build.
- `src/lib/api.ts` — one fetch client (base URL, token injection, ETag support, retry, timeout 5 s SSR / 10 s build). Used by loaders **and** SSR routes **and** (token-free) islands.
- `src/lib/mappers.ts` — `toListingView(apiRecord, locale)`, `toProjectView(...)`: locale resolution with fallback chain (requested → fr → en → first available), price formatting, media URL building (§8), path building. **The only place** API shapes become view shapes.
- Templates/components consume **only** `*View` types. Test in CI: render `ListingPage` from a loader-sourced fixture and an SSR-sourced fixture → byte-identical HTML (modulo build hash).

### 7.4 Component inventory (all render-mode agnostic)

`BaseLayout` (head mgmt, hreflang, CSP-safe) · `Seo` (title/meta/OG/Twitter from `seo` i18n with auto-fallbacks) · `JsonLd` (§7.6) · `Media`/`Gallery` (§8) · `ListingCard` · `ProjectCard` · `PriceTag` (price_on_request aware) · `AttributesTable` (renders from property_type schema_hints + custom field labels — universal) · `Breadcrumbs` · `LocaleSwitcher` · `Pagination` · `InquiryForm` island wrapper · footer/nav from config.

Theme layer: design tokens (CSS custom properties) in `src/styles/tokens.css` + per-deployment override file selected by `THEME` env — re-skinning a vertical = tokens + logo + content, zero component edits (R9/§13 of original plan).

### 7.5 Islands

| Island | Hydration | Behavior |
|---|---|---|
| `SearchFilter` | `client:load` on `/recherche`, `client:visible` embeds | Renders facets **from `property_types.filter_config`** fetched at build (static prop) — new searchable custom field appears after next build with no code change. Calls `GET /api/v1/search`; URL-syncs state (shareable searches); debounced 300 ms |
| `ListingMap` | `client:visible` | Detail page: single marker from baked coords (zero fetch). Search page: clustered markers; `moveend` → `GET /listings/geo?bbox=`; abort stale requests |
| `InquiryForm` | `client:visible` | Turnstile widget; POST `/inquiries`; optimistic UI; honeypot field |

JS budget: ≤ 100 KB gzip total per detail page (MapLibre lazy-loaded only when map scrolls into view); enforced by Lighthouse CI (§15).

### 7.6 SEO implementation (R8)

- Per-page `<title>`/meta/canonical/OG/Twitter from entity `seo` with deterministic fallbacks (`{title} – {city} | {site}`); canonical always the prerendered URL (SSR fallback emits the same canonical).
- JSON-LD per detail page: `RealEstateListing` (or `Residence` for projects) + `Offer` (price, currency, availability mapped from status) + `Organization` (developer) + `BreadcrumbList`; `FAQPage` on landings where content exists. Emitted by `JsonLd` from the view-model → identical in static and SSR output.
- `@astrojs/sitemap` + custom serializer fed by `GET /meta/sitemap` (lastmod, hreflang alternates). `robots.txt` allows all, points to sitemap; SSR-internal paths (`/_render/*` if variant chosen) are `Disallow` + `X-Robots-Tag: noindex` defense-in-depth.
- i18n: Astro built-in i18n routing; `fr` default locale at root, `/ar/` (RTL: `dir="rtl"` on html, logical CSS properties throughout — lint rule), `/en/`; full hreflang cluster incl. `x-default`.
- CSP: `csp: true` in Astro config; nonce-compatible islands; report-only first 2 weeks, then enforce.
- Performance: explicit width/height on all images, `preconnect` to `media.<domain>` and `api.<domain>`, fonts self-hosted + `font-display: swap`, zero render-blocking third-party JS.

---

## 8. Media pipeline — R2 (R5)

- **Bucket:** `immo-media-prod` (+ staging). **Custom domain `media.<domain>`** (proxied) → first-party, edge-cached, no CORS for `<img>`.
- **Keys:** content-addressed `media/{attachable_type}/{attachable_id}/{sha256}.{ext}`; object metadata `cache-control: public, max-age=31536000, immutable`. Updates create new keys → **no purging ever**.
- **Upload flow:** LiveView admin requests `POST /admin/media/presign` → Phoenix returns presigned **PUT** URL (`ex_aws_s3`, 15 min expiry, content-type + max-size 25 MB constrained) → browser uploads **direct to R2** (bytes never transit the VPS) → confirm callback creates `media` row → `MediaDerivatives` job (§6.5) validates type allowlist (jpeg/png/webp/avif/pdf), records dimensions, computes blurhash.
- **Delivery:** one `Media.astro` component builds Cloudflare Image Transformation URLs: `https://media.<domain>/cdn-cgi/image/width={w},quality=82,format=auto/<key>`; emits `<img srcset>` at 400/800/1200/1600 w + `sizes`, explicit dimensions, lazy by default (`eager fetchpriority=high` for LCP hero), blurhash placeholder background. **Do not use Astro's build-time image pipeline for catalog media** — SSR-rendered pages can't, and R4 demands one path. Enable Image Transformations on the zone in P0; verify pricing tier fits expected volume.
- PDFs (brochures/floorplans-as-pdf): direct R2 links, `content-disposition: inline`.

---

## 9. Maps — MapLibre + PMTiles

- Basemap: Protomaps `.pmtiles` extract (Morocco + neighbors, ~zoom 14) stored in R2 (`tiles/basemap.pmtiles`); MapLibre + `pmtiles` protocol over HTTP range requests — no tile server. Quarterly refresh task. Style: start from Protomaps light style, brand-tint via theme tokens. R2 CORS rule allowing range GET from site origins.
- Fallback (D8): MapTiler hosted tiles if cartographic polish demands it — swap is a style-URL config change.
- Clustering on search map via MapLibre cluster source from the GeoJSON endpoint; marker click → card popover with `path` link.
- RTL labels: load `mapbox-gl-rtl-text` plugin for Arabic locale.

---

## 10. Authentication & security model (R7)

### 10.1 The five trust paths (separately rotatable credentials)

| # | Path | Credential | Storage | Scope |
|---|---|---|---|---|
| 1 | Build (CF Builds / GH Actions → Phoenix `/api/v1` build tier) | `BUILD_TOKEN` (≥ 32 random bytes, base64url) | Encrypted build env (`astro:env` server secret) | Read-only, published content + sitemap/redirects dumps |
| 2 | Worker SSR → Phoenix render tier | `RENDER_TOKEN` | **Worker secret** (`wrangler secret put`) — never in client bundle | Read-only, single-record lookups + freshness |
| 3 | Browser islands → Phoenix public tier | none (anonymous) | — | `/search`, `/listings/geo`, `POST /inquiries` only; CORS exact-origin allowlist; rate limits (search 60/min/IP, geo 120/min/IP, inquiries 5/min/IP via Hammer + Cloudflare WAF rules); Turnstile on inquiries |
| 4 | Phoenix → Cloudflare (deploy hook + KV writes) | Deploy-hook URL (secret) + CF API token **scoped to the single KV namespace, write-only** | VPS env / Coolify secrets | Trigger builds; PUT dirty keys |
| 5 | Staff → Phoenix admin | `phx.gen.auth` session (argon2), RBAC roles (§5.8) | HttpOnly Secure cookies | LiveView admin; optional Cloudflare Access in front of `/admin/*` as 2nd factor (D9) |

Rules: tokens compared with `Plug.Crypto.secure_compare` (§6.4); rotation runbook = add new token to env list (plugs accept a comma-separated set), deploy consumers, remove old — zero-downtime; rotate quarterly + on personnel change; all secrets in the §12.5 registry, never in code or logs (Logger filters `authorization`).

**Why token-protect a public-data read API:** the build-tier firehose (full paginated dumps) is a scraping target and an availability risk; keeping it off the anonymous surface limits abuse to the narrow, rate-limited public endpoints. Render-tier protection prevents cache-busting amplification attacks (attacker forcing SSR misses against arbitrary slugs would otherwise hammer the VPS — combined with the Worker only SSR-ing on genuine asset-miss or KV-dirty, exposure is minimal).

### 10.2 Origin lockdown (Hetzner)

- **Cloudflare Tunnel** (`cloudflared` container in compose): outbound-only connection; **no inbound ports open except SSH (key-only, non-standard port, fail2ban)**. `api.<domain>` and `admin.<domain>` (or `/admin` on api host) route through the tunnel. WebSockets (LiveView) work through the tunnel.
- Result: nobody can reach Phoenix except via Cloudflare → WAF, DDoS protection, and the rate limits actually bind. Alternative if tunnel is rejected: Authenticated Origin Pulls (mTLS) + firewall allowing only Cloudflare IP ranges (D10; tunnel is the default).
- Cloudflare WAF: managed ruleset on `api.*`; bot-fight on public endpoints; country-agnostic (Moroccan diaspora traffic from EU is expected).

### 10.3 Future visitor accounts (out of scope v1 — design note only)

If added: Phoenix sets `HttpOnly; Secure; SameSite=Lax; Domain=.<domain>` session cookie at login (API endpoint), islands call `api.<domain>` with `credentials: 'include'`, Origin-header check on all state-changing requests. **No JWTs in localStorage.** Static pages stay anonymous/cacheable; only island calls carry the cookie.

---

## 11. Payments module (R10)

- **Model:** B2B — developers/agencies subscribe to publish (plans: basic / featured / enterprise). `BILLING_ENFORCED=false` at launch until first paying customers (publish gate inert but code path tested).
- **Adapter behaviour:** `Immo.Billing.Provider` callbacks: `create_checkout_session/2`, `cancel/1`, `verify_webhook/2`, `normalize_event/1`. Implementations: `Stripe` (stripity_stripe; Billing + hosted Checkout; confirm MA entity availability in P6 — else operate Stripe via EU entity or rely on CMI), `CMI` (Morocco's interbank gateway: hosted payment page, MAC-signature verification, **manual/invoice mode first** since CMI recurring billing requires bank-side setup), `Manual` (admin marks paid — day-one onboarding path).
- **Flow:** admin (or future self-serve portal) → `create_checkout_session` → redirect to hosted page (PCI SAQ-A; raw card data never touches the stack) → provider webhook → §6.6 verify + enqueue → `PaymentWebhookProcessor` updates subscription/payment idempotently → if publish-affecting (activation/expiry) → `MarkPathsDirty` for the developer's content + rely on next cron build (no immediate rebuild needed — freshness layer covers it).
- Dunning: `past_due` grace `GRACE_DAYS=7` → auto-unpublish via daily sweep → KV dirty marks → pages 404/hidden within a minute.

---

## 12. Infrastructure & deployment

### 12.1 Cloudflare setup (P0 checklist)

Zone + DNS (`www`/apex → Worker; `api`, `admin` → Tunnel; `media` → R2 custom domain) · Workers project, Git-connected builds, preview deployments on PRs · deploy hook created, URL into backend secrets · KV namespaces `FRESHNESS` prod+staging · R2 buckets + custom domain + CORS (range GET for PMTiles) · Image Transformations enabled · WAF + rate-limit rules (§10.1/10.2) · Turnstile site keys · **verify Workers Builds monthly quota vs ~720 builds (D3)**.

### 12.2 Hetzner VPS (single box — R6)

- Size: **CPX31** (4 vCPU/8 GB) launch; CPX41 if geocoding/media jobs contend. Ubuntu 24.04 LTS, unattended-upgrades.
- Runtime: Docker Compose managed by **Coolify** (D11; gives push-deploys, env/secret management, TLS for Coolify UI itself): services `phoenix` (Elixir release image), `postgres:17` (volume; `listen_addresses='localhost'` — published on 127.0.0.1 only, never 0.0.0.0), `cloudflared`.
- Postgres co-location hardening: unix-socket/localhost connections only; `scram-sha-256`; Ecto pool size 15; `shared_buffers=2GB`, `effective_cache_size=4GB`, `work_mem=32MB` starting points; pg_stat_statements on.
- **Backups:** pgBackRest sidecar — nightly full + WAL archiving (RPO ≤ 5 min) → **Hetzner Object Storage** bucket (EU; D12); retention 14 d incremental / 90 d weekly; **monthly scripted restore drill** into a scratch container with checksum verification (runbook + calendar task). `DATABASE_URL` env-driven so Postgres can move to its own VPS later with a one-line change.
- Email: Swoosh + Resend (or SES) — inquiry notifications, auth mails, build-failure alerts.
- Single-box SPOF accepted **knowingly**: an outage degrades freshness only (static keeps serving; SSR fallback degrades per §3.7). Document in runbooks; revisit HA only on revenue.

### 12.3 CI/CD

- **CI (all PRs):** backend — format check, Credo, Dialyzer, `mix test`, OpenAPI drift check; frontend — types-codegen drift check, ESLint, `tsc`, Vitest, build smoke (`RENDER_MODE=static` and `=dynamic` both must build), Lighthouse CI on preview (budgets §15.5).
- **Backend deploy:** GH Actions builds release image → Coolify webhook deploys; migrations run on boot (`Ecto.Migrator` release task); zero-downtime via Coolify rolling restart.
- **Frontend deploy:** code pushes → Cloudflare Git build; content rebuilds → deploy hook (§3.2). Staging env: separate Worker + staging Phoenix + staging KV/R2, `REBUILD_CRON=@daily`.

### 12.4 Environment variable & secret registry (authoritative)

| Name | Where | Secret | Purpose |
|---|---|---|---|
| `DATABASE_URL` | VPS | yes | Postgres (localhost) |
| `SECRET_KEY_BASE`, `PHX_HOST` | VPS | yes/no | Phoenix |
| `BUILD_TOKEN` / `RENDER_TOKEN` | VPS + CF build env / VPS + Worker secret | yes | §10.1 paths 1–2 |
| `DEPLOY_HOOK_URL` | VPS | yes | §3.2 |
| `CF_ACCOUNT_ID`, `CF_KV_NAMESPACE_ID`, `CF_KV_API_TOKEN` | VPS | last yes | KV dirty writes |
| `REBUILD_CRON` | VPS | no | default `0 * * * *` (R1; 3 h = `0 */3 * * *`) |
| `FRESHNESS_TTL_SECONDS` | VPS | no | default 7200 = 2× interval |
| `PUBLIC_SITE_URL` | VPS + build | no | ConfirmBuild polling, canonical URLs |
| `R2_*` (endpoint, bucket, access key/secret) | VPS | yes | presigned uploads |
| `MEDIA_BASE_URL` | build + Worker | no | `https://media.<domain>` |
| `API_BASE_URL` | build + Worker + public island const | no | `https://api.<domain>` |
| `RENDER_MODE`, `HYBRID_SSR_ROUTES`, `THEME`, `LOCALES` | build | no | §2.2, §7.4 |
| `TURNSTILE_SITE_KEY` / `TURNSTILE_SECRET` | build / VPS | no/yes | inquiries |
| `STRIPE_SECRET`, `STRIPE_WEBHOOK_SECRET`, `CMI_*` | VPS | yes | §11 |
| `BILLING_ENFORCED`, `GRACE_DAYS`, `INQUIRY_RETENTION_DAYS` | VPS | no | flags |
| `SENTRY_DSN` (backend+frontend), `RESEND_API_KEY` | VPS / build | yes | ops |

Rule: adding an env var without updating this table fails review.

---

## 13. Security checklist (release gate, P8)

Tunnel up, zero inbound ports except SSH · all five trust paths use distinct credentials; rotation drill executed once · CSP enforced (after report-only soak) + HSTS preload + X-Content-Type-Options + Referrer-Policy strict-origin-when-cross-origin · CORS exact origins, no wildcard · rate limits verified by load test · Turnstile verified server-side; honeypot live · upload allowlist + size caps + presign expiry 15 min · webhook signature verification with raw body; replay-safe · Ecto changeset validation on every write; no raw SQL with interpolation · LiveView CSRF; admin session idle timeout 24 h; argon2 · audit_log on all admin mutations · Logger redaction (authorization, tokens, card-adjacent fields) · dependency audit (mix hex.audit, npm audit) in CI · backups encrypted at rest (object-storage SSE) + restore drill passed · privacy: consent flag stored, retention sweeps on, data stays EU/MA (Hetzner EU, R2 EU jurisdiction setting), privacy policy + Law 09-08/GDPR notice pages.

## 14. Observability & operations

- **Errors:** Sentry — Elixir SDK (Phoenix+Oban) and browser/Worker SDK (islands + SSR), release-tagged with `git_sha` from `/__build.json`.
- **Metrics/health:** Phoenix LiveDashboard (admin-gated) + `GET /healthz` (DB ping) for uptime checks (UptimeRobot/BetterStack) on `api` and on site `/__health` (Worker liveness).
- **The alert that matters most:** `BuildAgeMonitor` (§6.5) — if `built_at` age > 2× interval ⇒ build pipeline silently broken; page someone. (Failure mode: dirty TTLs eventually expire → stale statics return with no error signal anywhere. This monitor is the guard.)
- Also alert on: build `failed` status, Oban job retries exhausted, webhook signature failures spike, VPS disk > 80%, backup job failure.
- Dashboards: builds history (admin), `x-immo-serving` header sampled via Workers analytics → ratio of static/ssr-new/ssr-dirty/stale-fallback (SSR share should hover near zero between publishes; a sustained rise = freshness bug or scraping).
- Runbooks (in `/infra/runbooks/`): deploy, rollback (Worker versions + Coolify), restore drill, secret rotation, "site serving stale" triage, VPS-down comms.

## 15. Testing strategy

1. **Backend (ExUnit):** context unit tests; `published/1` predicate matrix (incl. billing gate); API controller tests per tier incl. 401s, ETag/304, cursor/`since` pagination; path-computation property tests (`Edge.Paths` is correctness-critical — KV keys and API `path` fields must always agree); Oban job tests with mocked CF/provider HTTP (Bypass/Req.Test); webhook signature + idempotency tests.
2. **Contract:** OpenAPI validity + drift gate; frontend types regenerated and diff-checked; (optional P8) schemathesis fuzz against staging.
3. **Frontend (Vitest):** mappers (locale fallback chains, price/edge cases), path builders, SEO/JSON-LD serializers; the **dual-source render test** (§7.3 — loader fixture vs SSR fixture ⇒ identical HTML).
4. **E2E (Playwright vs staging):** the freshness state machine —
   - publish new listing → page 200 via SSR (`x-immo-serving: ssr-new`) within 2 min, correct JSON-LD;
   - edit published listing → page reflects edit (`ssr-dirty`) within 2 min;
   - trigger manual rebuild → both pages flip to `static` and content correct;
   - unpublish → 404 within 2 min; after rebuild still 404; old URL after slug change → 301.
   Plus: search island facets from a custom field; map bbox query; inquiry submit (Turnstile test keys); AR pages render RTL.
5. **Performance:** Lighthouse CI budgets — LCP < 2.5 s (4G), CLS < 0.1, INP < 200 ms, ≤ 100 KB JS gz on detail pages, ≤ 60 KB on landings. k6 smoke on `/search` and `geo` (200 rps sustained, p95 < 300 ms with rate limits relaxed in staging).
6. **Global Definition of Done:** code formatted/linted; tests for the change; CI green; docs/env-registry updated; security-relevant changes get a checklist review; deployed to staging and verified.

---

## 16. Work breakdown — phases → epics → tasks

Notation: `P<phase>-E<epic>-T<task>`. Size: S ≤ 1 day, M ≤ 3 days, L ≤ 1 week (single engineer, indicative only). "AC" = acceptance criteria (additive to global DoD §15.6). Phases sequential; epics inside a phase parallel unless "Deps" says otherwise.

### P0 — Foundations (everything else depends on this)
**P0-E1 Repo & CI skeleton** — monorepo per §4; CI pipelines per §12.3 (lint/test/build gates wired even while trivial). *T1* scaffold + tooling (M) · *T2* CI workflows incl. OpenAPI-drift + types-drift placeholders (M). AC: PR to main runs all gates green.
**P0-E2 Cloudflare account setup** — §12.1 checklist executed; staging+prod resources; **D3 quota verdict documented**. (M) AC: deploy hook tested manually; KV/R2 reachable; hello-world Worker serves on staging domain.
**P0-E3 VPS provisioning** — §12.2: Coolify, compose (postgres+cloudflared+placeholder app), tunnel live, SSH hardened, pgBackRest configured against Hetzner Object Storage. (L) AC: `api.<staging-domain>` reaches a stub through the tunnel; nightly backup object appears; restore drill script exists and passes against the empty DB.
**P0-E4 Secrets registry instantiated** — §12.4 vars created in all stores; rotation runbook drafted. (S)

### P1 — Backend core
**P1-E1 Phoenix app + auth/RBAC** — phx.gen.auth, roles, `on_mount` gating, seed admin. (M) AC: role matrix integration-tested.
**P1-E2 Schema & contexts** — all §5 migrations; Catalog/Media/CRM contexts; `published/1`; audit_log wrapper; seeds with realistic fixtures (≥3 types, ≥40 listings, ar/fr content). (L) AC: §15.1 predicate matrix green; GIN/partial indexes verified with EXPLAIN on seed data.
**P1-E3 Admin CRUD** — §6.2 minus media/builds/billing screens. (L) Deps: E1, E2. AC: editor can take a project from draft→published incl. i18n tabs; developer_user sees only own data.
**P1-E4 Media pipeline** — §8 presign endpoint, direct-to-R2 upload UI, confirm callback, `MediaDerivatives`, alt-text publish gate. (L) Deps: E2. AC: 10-photo drag-drop lands in R2 with hashed keys; blurhash + dimensions populated; oversized/forbidden type rejected client- and server-side.
**P1-E5 Read API v1 + OpenAPI** — §6.3 build/render/public tiers, BearerAuth plug, ETag, cursor/`since`, rate limiting, CORS; spec generated and CI-gated. (L) Deps: E2. AC: §15.1 API tests green; `curl` matrix per tier documented; 304 on repeat ETag fetch.
**P1-E6 Inquiries + email** — public endpoint with Turnstile + Hammer, admin inbox, `InquiryNotifier`, retention sweep. (M) Deps: E2, E5.

### P2 — Frontend static MVP
**P2-E1 Astro scaffold + theme tokens** — config (CSP, i18n fr/ar/en, `astro:env` schema), tokens + RTL logical-properties lint, BaseLayout/Seo. (M)
**P2-E2 API client + view-models** — §7.3: codegen wiring, `api.ts`, `mappers.ts`, dual-source fixtures + render-equality test. (M) Deps: P1-E5. AC: types-drift CI gate live; equality test green.
**P2-E3 Content loaders** — §7.2 factory incl. `since` high-water mark + fail-on-partial. (M) Deps: E2. AC: second consecutive build fetches only deltas (verified via API logs).
**P2-E4 Pages & components** — §7.1 prerendered routes, §7.4 components, AttributesTable from schema_hints/custom_fields. (L) Deps: E2, E3. AC: seed catalog renders all locales; ar pages RTL-correct.
**P2-E5 SEO pack** — §7.6 meta/JSON-LD/sitemap/robots/RSS/hreflang. (M) Deps: E4. AC: Rich-results test passes for listing+project fixtures; sitemap lists all published paths with lastmod.
**P2-E6 Media component** — §8 `Media.astro` with CF transformations + blurhash. (M) Deps: E4, P1-E4. AC: hero is LCP element with explicit dims; srcset 4 widths; AVIF served to supporting UAs.
**P2-E7 Build info + first CF deploy** — `/__build.json` integration, render-mode integration (`static` only for now), wrangler config, Git-build to staging. (M) Deps: E1–E6. AC: staging serves full static site; `/__build.json` fields correct.

### P3 — Scheduled rebuild pipeline (R1)
**P3-E1 builds table + RebuildSite/ConfirmBuild** — §3.2 incl. skip-if-unchanged + uniqueness. (M) Deps: P2-E7. AC: cron fires hourly on staging; no-change run records `skipped` and triggers no CF build; change run goes `running→succeeded` with `built_at` captured.
**P3-E2 Admin build dashboard + Rebuild-now** — §6.2 build screen. (S) Deps: E1.
**P3-E3 BuildAgeMonitor + alerting** — §14 alert wired to email/Slack. (S) Deps: E1. AC: simulated hook outage alerts within 15 min of threshold.
**P3-E4 (conditional D3) GH-Actions build path** — workflow_dispatch trigger + `wrangler deploy`; only if quota verdict demands. (M)

### P4 — Freshness layer (R2, R3) — *the critical phase; sequential epics*
**P4-E1 Route-precedence spike (timeboxed 2 d)** — validate prerendered `[slug]` + SSR `[...slug]` coexistence on pinned versions; else adopt `/_render/*` rewrite variant; write ADR. AC: decision + working proof on staging for one route family.
**P4-E2 State B — SSR catch-alls** — §7.1 fallbacks using render-tier API; identical templates via view-models; correct 404/canonical/JSON-LD; `x-immo-serving` + cache headers per §3.4. (L) Deps: E1. AC: e2e "publish new → live ≤ 2 min" green **with zero KV usage**.
**P4-E3 Custom Worker entry** — §3.4 routing, `run_worker_first` globs, build-info memoization, stale-beats-error, 503 path, redirects.json consultation. (L) Deps: E2. AC: unit tests on routing matrix; asset 404 falls through to SSR; killing staging API yields stale-fallback header on built pages.
**P4-E4 State C — KV dirty layer** — `Edge.Paths` (shared authority + property tests), `Freshness.mark_dirty`, `MarkPathsDirty` triggers on edit/unpublish/publish-with-parent/slug-change, re-arm step in RebuildSite, TTL config. (L) Deps: E3. AC: e2e edit/unpublish/slug-301 scenarios of §15.4 green; after next build, headers flip to `static`.
**P4-E5 Freshness observability** — serving-mode analytics + dashboard note; runbook "site serving stale". (S) Deps: E4.

### P5 — Search & maps
**P5-E1 Search backend** — §6.3 `/search` (tsvector + trigram + attribute filters from filter_config incl. searchable custom fields), `/listings/geo` with bbox guard. (L) Deps: P1-E5. AC: k6 budget §15.5 met on staging hardware.
**P5-E2 SearchFilter island** — §7.5; facets from filter_config; URL state. (L) Deps: E1, P2. AC: adding a searchable custom field in admin surfaces a facet after next build with no code change.
**P5-E3 Map islands + PMTiles** — §9 basemap in R2, detail + clustered search maps, RTL plugin. (L) Deps: E1. AC: pan loads bbox results ≤ 500 ms p95 staging; JS budget holds (MapLibre lazy).
**P5-E4 Geocoding** — `Geocode` job + admin pin correction. (M) Deps: P1-E3.

### P6 — Payments (R10)
**P6-E1 Provider behaviour + Manual** — §11 adapter contract, Manual flow, BILLING_ENFORCED gate into `published/1` (flag off). (M)
**P6-E2 Stripe** — checkout sessions, webhooks (§6.6), processor idempotency, dunning sweep → unpublish → dirty marks. (L) Deps: E1, P4-E4. AC: Stripe CLI replayed events processed exactly once; expiry e2e hides content ≤ 2 min after sweep.
**P6-E3 CMI adapter** — hosted page + MAC verification, invoice/manual-recurring mode; sandbox-tested. (L) Deps: E1. AC: signature verification rejects tampered callbacks.
**P6-E4 Billing admin screens** — §6.2. (M) Deps: E1.

### P7 — i18n completion & polish
**P7-E1 AR/RTL audit** — full visual pass, mirrored layouts, Arabic typography. (M) · **P7-E2 Translation workflow** — completeness indicators, missing-locale fallbacks verified, hreflang audit vs sitemap. (M) · **P7-E3 Content & legal pages** — privacy (Law 09-08/GDPR), terms, about; consent text on inquiry. (S/M)

### P8 — Hardening & launch
**P8-E1 Security gate** — execute §13 checklist; CSP report-only→enforce; rotation drill; pen-test pass (at minimum ZAP baseline + manual auth checks). (L)
**P8-E2 Ops gate** — §14 monitors live in prod; restore drill on prod-sized data; runbooks reviewed; on-call/alert routing agreed. (M)
**P8-E3 Performance gate** — Lighthouse budgets on prod; CWV field data plan (CrUX/RUM via Sentry). (M)
**P8-E4 Launch** — DNS cutover, `REBUILD_CRON` confirmed, BILLING_ENFORCED decision, search-console submission, sitemap ping, 48 h hypercare with serving-mode dashboard watch. (M)

### P9 — Conditional / post-launch backlog
`dynamic`/`hybrid` mode production rollout for a second vertical (the integrations exist from P2-E7; this is config + theme + content) · visitor accounts (§10.3) · `/internal/freshness` consistency upgrade if KV lag ever bites · PostGIS upgrade (D7) · category-index SSR flip if product wants instant cards · Patroni/managed-PG migration on scale.

### Dependency spine (critical path)
P0-E2/E3 → P1-E2 → P1-E5 → P2-E2 → P2-E7 → P3-E1 → P4-E1 → P4-E2 → P4-E3 → P4-E4 → P8. Search/maps (P5) and payments (P6) hang off P1-E5 and can overlap P4 with a second engineer.

---

## 17. Open decisions — with defaults (implement default unless overridden)

| ID | Decision | Default | Override trigger |
|---|---|---|---|
| D1 | Rebuild interval | `0 * * * *` (1 h) | Build-minute cost or noise → `0 */3 * * *`; user-facing freshness is unaffected (§3.2) |
| D2 | Ship State C (KV layer) at launch? | **Yes** (P4-E4 before P8) | Timeline pressure → launch after P4-E2 only; accepted regression: *edits* lag ≤ interval (new content still instant); unpublish lag is the main risk — if deferred, add interim "unpublish triggers manual rebuild" stopgap |
| D3 | Build executor | Cloudflare Workers Builds via deploy hook | Quota < ~750/mo on chosen plan → GH Actions path (P3-E4) |
| D4 | Category/index freshness | Static, ≤ interval lag | Product demands instant cards → hybrid SSR list (config) |
| D5 | Languages at launch | fr + ar (+ en) | Drop en if content capacity short |
| D6 | Geocoder | Self-hosted-friendly Nominatim w/ rate cap | Volume/quality issues → LocationIQ/Geoapify key |
| D7 | Geo queries | lat/lng btree ranges | Radius/polygon search demanded → PostGIS migration ticket |
| D8 | Basemap | PMTiles on R2 | Cartography polish demanded → MapTiler style URL |
| D9 | Cloudflare Access on `/admin` | Off | Enable after launch (recommended) |
| D10 | Origin lockdown | Tunnel | Org rejects tunnel → AOP + IP allowlist |
| D11 | Deploy orchestration | Coolify | Team prefers minimal → Kamal (runbooks change only) |
| D12 | Backup target | Hetzner Object Storage (EU) | Single-vendor preference → R2 (jurisdiction check first) |
| D13 | Billing live at launch | `BILLING_ENFORCED=false` | First paying developer onboarded |

## 18. Risk register (top items)

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Route precedence (prerender + catch-all) flaky on pinned versions | M | H (blocks P4) | P4-E1 timeboxed spike with rewrite-variant fallback already specified |
| Build pipeline silently broken → stale site after TTLs lapse | M | H | BuildAgeMonitor + ConfirmBuild + skipped/failed states (§14) — alert, don't discover |
| KV eventual consistency confuses editors ("I saved but see old page") | M | L | Admin "view live" link adds cache-bust note; doc the ≤ 60 s window; §3.5 alternative on standby |
| VPS single box dies | L | M | Static site keeps serving (§3.7); restore drill ≤ RTO 4 h; runbook |
| Hourly builds exceed CF quota mid-month | M | M | D3 verdict in P0; GH Actions fallback pre-specified |
| Stripe unavailable for MA entity | M | M | CMI + Manual adapters are first-class (P6-E1/E3), not afterthoughts |
| Scraping of catalog via public endpoints | M | L | Tiered tokens keep firehose private; WAF + rate limits; monitor serving-mode ratio |
| RTL/Arabic regressions | M | M | Logical-properties lint + P7-E1 dedicated audit + e2e RTL check |

---

*End of plan. Sections §3–§15 are normative; §16 is the decomposition input; §17 defaults apply absent explicit override.*
