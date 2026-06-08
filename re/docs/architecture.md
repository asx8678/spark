# Architecture Overview — NewProjects.ma

This document synthesizes the E0 architectural decisions into a coherent system view for the NewProjects.ma platform. It is intended for developers, operators, and technical stakeholders as a high-level orientation before diving into specific ADRs or code.

For detailed rationale, options considered, and consequences, see the ADRs in [`docs/decisions/`](decisions/).

---

## 1. System diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           USERS & VISITORS                              │
│                    (browsers, agencies, developers)                     │
└──────────────────────────┬──────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    CLOUDFLARE EDGE (Workers / Static Assets)            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Static Assets (Astro SSG)                                      │   │
│  │  - Public site: /fr/, /en/ (RTL-ready for future /ar/)         │   │
│  │  - SEO pages, project listings, city pages, articles            │   │
│  │  - Client islands: search, maps, inquiry forms, favorites       │   │
│  │  - Turnstile challenge on inquiry form submission               │   │
│  └───────────────────────────┬─────────────────────────────────────┘   │
│                              │ POST /api/inquiries                       │
│                              ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Cloudflare R2                                                  │   │
│  │  - Property media (images, videos)                              │   │
│  │  - PMTiles vector basemap (morocco.pmtiles)                      │   │
│  │  - Served via custom domain with CORS + range + cache rules     │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└──────────────────────────┬──────────────────────────────────────────────┘
                           │
                           │ API requests (inquiries, read API)
                           ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    HETZNER VPS (EU datacenters — Germany/Finland)       │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Phoenix / Elixir Application                                   │   │
│  │  ┌───────────────────────────────────────────────────────────┐ │   │
│  │  │  Public Read API (E5)                                     │ │   │
│  │  │  - Unauthenticated, rate-limited                          │ │   │
│  │  │  - Serves listing data to Astro build pipeline             │ │   │
│  │  │  - Inquiry intake endpoint (spam-hardened)                 │ │   │
│  │  └───────────────────────────────────────────────────────────┘ │   │
│  │  ┌───────────────────────────────────────────────────────────┐ │   │
│  │  │  Admin / Agency Panel (E4)                                │ │   │
│  │  │  - Phoenix LiveView, session-based auth                    │ │   │
│  │  │  - Programme CRUD, media upload, subscription management   │ │   │
│  │  └───────────────────────────────────────────────────────────┘ │   │
│  │  ┌───────────────────────────────────────────────────────────┐ │   │
│  │  │  Background Jobs (Oban)                                    │ │   │
│  │  │  - Rebuild pipeline triggers (content change → SSG rebuild)│ │   │
│  │  │  - Scheduled tasks (PMTiles re-extract, billing reminders) │ │   │
│  │  │  - Email / notification queues                              │ │   │
│  │  └───────────────────────────────────────────────────────────┘ │   │
│  └───────────────────────────┬─────────────────────────────────────┘   │
│                              │ localhost / private network               │
│                              ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  PostgreSQL (self-hosted, co-located → dedicated instance)       │   │
│  │  - Listings, developers, leads, subscriptions, users            │   │
│  │  - Postgres FTS for search (→ Meilisearch/Typesense planned)    │   │
│  │  - WAL archiving → Hetzner Object Storage (backups)             │   │
│  │  - pg_dump nightly + restore drills (RTO/RPO tracked)           │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Key architectural decisions

Each decision below is recorded in full as an ADR in [`docs/decisions/`](decisions/). This section summarizes the what and why for quick reference.

### 2.1 Static-first public frontend (Astro SSG)

**ADR:** [`00-4-catalog-scale.md`](decisions/00-4-catalog-scale.md)

The public site is built as a full **Astro static site (SSG)**. The catalog unit is the *programme* (development project), not individual property units — this keeps the page count manageable (~7k–11k pages at a 3-year horizon). Search, maps, and inquiry forms are client-side "islands" hitting the API; the authenticated admin panel is a separate LiveView app.

**Why:** best SEO, fastest TTFB, cheapest hosting, simplest security surface. Hybrid/on-demand rendering (E17) is triggered only if pages exceed ~50k or build time exceeds ~15 minutes.

**Key implication:** public read traffic never touches Postgres. The static site survives database blips.

### 2.2 B2B subscription-led revenue model

**ADR:** [`00-1-payments-model.md`](decisions/00-1-payments-model.md)

Monetization is **agency/developer subscriptions** — publishing is gated on an active subscription. No consumer payments at launch.

**Why:** this is how Moroccan property portals work. Property seekers browse free; agencies pay for leads. Launch starts with **manual/offline invoicing** (bank transfer validation by admin) to remove gateway integration risk, then moves to **PayZone** (automated domestic collection) and optionally **Stripe** (international, contingent on a foreign legal entity).

### 2.3 No public visitor accounts

**ADR:** [`00-2-visitor-accounts.md`](decisions/00-2-visitor-accounts.md)

Visitors interact via **inquiry forms** (WhatsApp deep-link, click-to-call, server-captured leads) plus **anonymous localStorage favorites**. No login, no saved-search alerts at launch.

**Why:** visitors are not the paying customer. Public auth is high-maintenance, high-compliance-risk (Law 09-08 / CNDP), and breaks the static-first model. The Moroccan market already contacts via WhatsApp/phone — lean into that.

### 2.4 FR+EN at launch; Arabic (RTL) fast-follow

**ADR:** [`00-3-locales-rtl.md`](decisions/00-3-locales-rtl.md)

Launch locales are **French (primary) + English (LTR)**. Arabic is deferred to Phase 2 but the codebase is built **RTL-ready** from day one (Tailwind logical properties, `dir` driven by locale, Arabic font preloaded and gated).

**Why:** French is the business language of Moroccan real estate; English captures the MRE/investor segment cheaply. RTL roughly doubles the UI QA surface — defer it, but don't make it a retrofit.

### 2.5 Self-hosted Postgres on Hetzner

**ADR:** [`00-5-db-ops.md`](decisions/00-5-db-ops.md)

PostgreSQL runs **self-hosted on Hetzner**, co-located with the Phoenix app on the private network. **Neon** is the pre-approved escape hatch.

**Why:** the DB is small and low-QPS (public traffic is static/CDN). Co-location gives sub-millisecond latency for the admin panel, Oban polling, and rebuild pipeline. Backups go to **Hetzner Object Storage** (continuous WAL + nightly `pg_dump` + quarterly restore drills).

### 2.6 PMTiles vector tiles on Cloudflare R2

**ADR:** [`00-6-map-tiles.md`](decisions/00-6-map-tiles.md)

Map tiles are served as a **Morocco-scoped PMTiles** file (Protomaps/OSM basemap) hosted on **Cloudflare R2**, rendered by **MapLibre GL JS** as Astro `client:visible` islands.

**Why:** R2 egress is $0; the tile cost is near-zero and flat. Reuses the R2 bucket already committed to for media. MapTiler is the escape hatch if styling polish, satellite, or label quality becomes a blocker.

---

## 3. Data flow

### 3.1 Static build pipeline

```
Content change (admin publishes a programme)
        │
        ▼
Phoenix (Oban job / webhook)
        │
        ▼
Astro rebuild triggered (CI or webhook)
        │
        ▼
Astro SSG fetches from Phoenix Read API
        │
        ▼
Static HTML + assets deployed to Cloudflare Workers Static Assets
        │
        ▼
CDN edge caches; public visitors served instantly
```

- Content changes (new programme, price update) enqueue an **Oban job** in Postgres.
- The rebuild pipeline fetches fresh data from the **Read API** and regenerates static pages.
- Only the *shell* pages (listing index, paginated, per-city) are static; search filters run client-side against the API.
- Delivered/sold-out programmes are retained as **static archive pages** for SEO.

### 3.2 API for admin and leads

| Endpoint surface | Auth | Path | Notes |
|---|---|---|---|
| Admin panel (LiveView) | Session (agency users) | Phoenix SSR on Hetzner | Full CRUD, subscription management |
| Public Read API | None (rate-limited) | `/api/v1/...` | Serves Astro build + client islands |
| Inquiry submission | Turnstile challenge | `POST /api/inquiries` | Spam-hardened; creates a Lead record |
| Media upload | Session (agencies) | Direct to R2 (presigned) or via API | Stored in R2 under `media/` prefix |

**Inquiry flow:**
1. Visitor fills inquiry form on a static project page.
2. Turnstile challenge completes in the browser.
3. Form POSTs to `/api/inquiries` with Turnstile token.
4. Phoenix validates the token server-side, creates a `Lead` record in Postgres.
5. Lead is routed to the agency (email, dashboard notification, or future WhatsApp Business API).

### 3.3 Media upload path

```
Agency uploads image/video via admin panel
        │
        ▼
Phoenix validates session + file
        │
        ▼
File uploaded to Cloudflare R2 (media/ prefix)
        │
        ▼
CDN serves media with optimal caching
        │
        ▼
Astro pages reference R2 public URLs in <img>, <video>, schema.org
```

- Direct browser-to-R2 uploads via presigned URLs are the target pattern to avoid proxying large files through Phoenix.
- Images should be optimized before upload or transformed on-the-fly via CDN image transforms.
- Backups of media are not in scope at launch; R2's durability is relied upon.

### 3.4 Map tile flow

```
MapLibre GL JS (Astro client:visible island)
        │
        ▼
pmtiles:// protocol → HTTPS range request
        │
        ▼
Cloudflare edge (cache) → R2 morocco.pmtiles
        │
        ▼
Vector tiles rendered client-side
```

- The `morocco.pmtiles` file is generated offline via `pmtiles extract` against the Protomaps planet build.
- Cloudflare caches tile range requests at the edge; origin hits are rare for popular areas.
- The tile source URL is behind **one config value** so the source can be swapped without code changes (MapTiler escape hatch).

---

## 4. Security boundaries

### Public surface (Cloudflare)

| Component | Responsibility |
|-----------|---------------|
| Cloudflare Workers Static Assets | Serves static HTML/CSS/JS; WAF rules; DDoS protection |
| Turnstile | Challenges bot traffic on inquiry form submissions |
| Rate limiting | On the Read API and inquiry endpoint (Cloudflare + Phoenix) |

### Private surface (Hetzner)

| Component | Responsibility |
|-----------|---------------|
| Phoenix admin panel | Session-based auth; HTTPS only; behind Cloudflare proxy |
| PostgreSQL | Bound to private network only; TLS connections; no public exposure |
| R2 media + tiles | Public-read by design; uploads require auth or presigned tokens |
| Oban | Runs in the Phoenix app; job metadata in Postgres; no external queue |

### Key invariants

1. **Public traffic never reaches Postgres.** The Astro static site + CDN handles all public reads. A database outage does not take the public site down.
2. **No public visitor auth.** No passwords, no tokens, no sessions for visitors. The inquiry form is the only public write path, and it is Turnstile-gated.
3. **Secrets are centralized.** Environment variables are managed via a single secrets layer (CI + Hetzner env). DB connection strings, R2 credentials, and Turnstile keys live in one place per environment.
4. **Media is object-storage-native.** Files never live on the Hetzner filesystem long-term; they go straight to R2.
5. **Backups are portable.** Nightly `pg_dump` + WAL archiving means the Neon escape hatch is a restore away, not a migration project.

---

## 5. Operational model

### Environments

| Environment | Frontend | Backend / DB | Purpose |
|-------------|----------|--------------|---------|
| **Development** | Astro dev server (local) | Local Postgres | Feature development |
| **Staging** | Cloudflare preview deployment | Hetzner staging VPS | QA, client demos |
| **Production** | Cloudflare Workers Static Assets | Hetzner production VPS | Live site |

### CI/CD (planned)

- **GitHub Actions** for: lint, test, build frontend, build backend, deploy to Cloudflare (frontend) and Hetzner (backend).
- **Cloudflare Git integration** for preview deployments on PRs.
- **Rebuild triggers:** Phoenix enqueues Oban jobs on content changes; a CI webhook triggers an Astro rebuild.

### Monitoring (planned, E14)

- Phoenix LiveDashboard for admin/API health.
- Postgres metrics: connection pool, WAL lag, disk usage.
- Build pipeline metrics: page count, build duration, publish-to-live latency.
- Uptime: Cloudflare analytics + Hetzner server monitoring.

---

## 6. References

| Document | Description |
|----------|-------------|
| [`docs/decisions/00-1-payments-model.md`](decisions/00-1-payments-model.md) | B2B subscriptions, CMI/PayZone/Stripe strategy |
| [`docs/decisions/00-2-visitor-accounts.md`](decisions/00-2-visitor-accounts.md) | No public accounts; inquiry-form-only + localStorage favorites |
| [`docs/decisions/00-3-locales-rtl.md`](decisions/00-3-locales-rtl.md) | FR+EN launch; Arabic/RTL deferred but RTL-ready |
| [`docs/decisions/00-4-catalog-scale.md`](decisions/00-4-catalog-scale.md) | Astro SSG; hybrid trigger thresholds |
| [`docs/decisions/00-5-db-ops.md`](decisions/00-5-db-ops.md) | Self-host Postgres; Neon escape hatch |
| [`docs/decisions/00-6-map-tiles.md`](decisions/00-6-map-tiles.md) | PMTiles on R2; MapLibre; MapTiler escape hatch |
| `README.md` | Project overview, tech stack, getting started |
