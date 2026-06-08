# NewProjects.ma

**Moroccan new-build & off-plan real-estate listing platform.**

NewProjects.ma helps buyers, investors, and MRE (Marocains Résidents à l'Étranger) discover new property developments across Morocco. The platform focuses on **programmes** — new-build projects from developers and promoteurs — rather than individual resale listings. Visitors browse project pages, explore locations on an interactive map, and contact agencies directly via WhatsApp or phone.

This is a **solo-developer, cost-conscious** project targeting the Moroccan market with a self-hosted stack where it makes sense and CDN/edge services where performance matters.

---

## What it is

- **A Morocco-first property portal** for new-build and off-plan developments (VEFA, Daam).
- **B2B subscription model:** agencies and developers pay to publish; visitors browse and inquire for free.
- **No public accounts at launch:** inquiry-form-only contact plus anonymous client-side favorites stored in `localStorage`.
- **Static-first public site** with a separate authenticated admin panel for agencies.

### Key features

- Browse programmes by city, developer, and budget
- Interactive map of listings (PMTiles vector basemap)
- Project detail pages with unit tables, availability, and media
- Direct contact via WhatsApp deep-link and click-to-call
- Multi-language support: French (primary) + English at launch; Arabic (RTL) as a fast-follow phase

---

## Tech stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| **Public frontend** | [Astro 6](https://astro.build/) (SSG) | Static site generation, i18n routing, SEO |
| **Frontend UI** | Tailwind CSS + MapLibre GL JS | Styling, RTL-ready logical properties, interactive maps |
| **Admin panel** | [Phoenix](https://www.phoenixframework.org/) (LiveView) | Authenticated agency dashboard |
| **Backend API** | Phoenix (Elixir) | Read API for the static frontend, lead intake, Oban jobs |
| **Database** | PostgreSQL (self-hosted on Hetzner) | Primary data store, Ecto + Oban |
| **Object storage** | Cloudflare R2 | Media uploads (images, videos) + PMTiles map tiles |
| **Maps** | MapLibre GL JS + PMTiles on R2 | Morocco vector basemap from Protomaps/OSM |
| **Hosting (frontend)** | Cloudflare Workers Static Assets | Edge hosting for the Astro build |
| **Hosting (backend)** | Hetzner VPS (EU datacenters) | Phoenix app, Postgres, background jobs |
| **Anti-bot** | Cloudflare Turnstile | Spam protection on inquiry forms |
| **CI/CD** | GitHub Actions + Cloudflare Git integration | Build, test, deploy pipeline |
| **Search** | Postgres FTS → Meilisearch / Typesense | Full-text and faceted search (planned) |

---

## Project structure

```
re/
├── frontend/                # Astro SSG app (public-facing site)
│                           # - Static pages, i18n (FR/EN), client islands
│                           # - MapLibre maps, inquiry forms, localStorage favorites
│                           # - Deployed to Cloudflare Workers Static Assets
│
├── backend/                 # Phoenix/Elixir app (API + admin)
│                           # - Public Read API for Astro frontend
│                           # - Phoenix LiveView admin panel (agencies)
│                           # - Oban background jobs (rebuilds, notifications)
│                           # - Self-hosted on Hetzner VPS
│
├── infra/                   # Infrastructure as code & deployment configs
│                           # - Terraform / Ansible playbooks
│                           # - Dockerfiles (app, DB, CI)
│                           # - CI/CD configs (GitHub Actions, Cloudflare)
│                           # - Hetzner provisioning scripts
│
├── docs/
│   ├── decisions/           # Architecture Decision Records (ADRs) — E0 outcomes
│   │   ├── 00-1-payments-model.md
│   │   ├── 00-2-visitor-accounts.md
│   │   ├── 00-3-locales-rtl.md
│   │   ├── 00-4-catalog-scale.md
│   │   ├── 00-5-db-ops.md
│   │   └── 00-6-map-tiles.md
│   │
│   ├── architecture.md      # System architecture overview & data flow
│   └── ...
│
├── README.md                # This file
└── .gitignore               # Git ignore rules
```

---

## Getting started

### Prerequisites

- **Node.js** ≥ 20.x (for Astro frontend)
- **Elixir** ≥ 1.16 + **Erlang/OTP** ≥ 26 (for Phoenix backend)
- **PostgreSQL** ≥ 15 (for local development; production is self-hosted on Hetzner)
- **Git** + **GitHub account**
- Accounts: **Cloudflare** (R2, Workers, Turnstile), **Hetzner** (VPS, Object Storage)

### 1. Clone the repo

```bash
git clone git@github.com:your-org/newprojects.ma.git re
cd re
```

### 2. Set up the frontend

```bash
cd frontend
npm install
cp .env.example .env   # configure Cloudflare R2, Turnstile, API URL
npm run dev            # starts Astro dev server at localhost:4321
```

### 3. Set up the backend

```bash
cd backend
mix setup              # installs deps, creates & migrates DB, seeds
mix phx.server         # starts Phoenix at localhost:4000
```

### 4. Infrastructure provisioning

See `infra/README.md` for Hetzner VPS provisioning, Postgres setup, and CI/CD configuration.

---

## Architecture decisions

All major architectural decisions are recorded as ADRs in [`docs/decisions/`](docs/decisions/).

| ADR | Decision |
|-----|----------|
| [`00-1-payments-model.md`](docs/decisions/00-1-payments-model.md) | B2B subscription-led; CMI/PayZone primary, Stripe secondary |
| [`00-2-visitor-accounts.md`](docs/decisions/00-2-visitor-accounts.md) | No public accounts at launch — inquiry-form-only + localStorage favorites |
| [`00-3-locales-rtl.md`](docs/decisions/00-3-locales-rtl.md) | FR+EN at launch; Arabic/RTL deferred but RTL-ready from day one |
| [`00-4-catalog-scale.md`](docs/decisions/00-4-catalog-scale.md) | Full-static Astro SSG; E17 hybrid trigger at >50K pages |
| [`00-5-db-ops.md`](docs/decisions/00-5-db-ops.md) | Self-host Postgres on Hetzner; Neon as escape hatch |
| [`00-6-map-tiles.md`](docs/decisions/00-6-map-tiles.md) | PMTiles on R2; MapLibre GL JS; MapTiler as escape hatch |

See [`docs/architecture.md`](docs/architecture.md) for the full system overview, data flow, and security boundaries.

---

## Development phases

| Phase | Focus | Status |
|-------|-------|--------|
| **E0** | Discovery & open decisions (ADRs) | ✅ Complete |
| **E1** | Foundation: accounts, repos, CI/CD skeleton | 🔄 Next |
| **E2–E7** | Backend core, data model, media, maps, frontend, rebuild pipeline | 📋 Planned |
| **E11–E17** | Maps, search, scale triggers, hybrid rendering | 📋 Planned |

---

## License

Proprietary — All rights reserved.

---

*Built for the Moroccan real-estate market. Solo-dev, self-hosted where it matters, edge-fast where it counts.*
