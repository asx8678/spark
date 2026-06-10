# /api/v1 curl matrix

§6.3 / §10.1 / P1-E5.5 — the executable documentation of the
three trust paths the `/api/v1` read API exposes. Each
command targets the local dev server (`http://localhost:4000`)
and exercises the per-tier × per-state matrix the
`ImmoWeb.ApiSpec` describes. The same matrix is asserted
end-to-end by:

- `test/immo_web/controllers/api/api_pipeline_test.exs`
- `test/immo_web/controllers/api/render_controller_test.exs`
- `test/immo_web/controllers/api/build_controller_test.exs`
- `test/immo_web/controllers/api/public_pipeline_test.exs`

The OpenAPI contract lives at `priv/static/openapi.json`; a
spec drift (a controller change without a regenerated
spec) fails CI (`mix openapi.drift`).

## Setup

```sh
# Local dev: export the test tokens (use the values from
# config/test.exs or any non-empty strings ≥ 32 bytes).
export BUILD_TOKEN="$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-48)"
export RENDER_TOKEN="$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-48)"

# Boot the dev server.
mix phx.server
```

For dev with no real catalog rows, seed via
`priv/repo/seeds.exs` (P3) or the `mix ecto.setup` command.
The matrix below assumes at least one published developer,
project, listing, and property type.

## Build tier (§10.1 path 1)

The build tier is hit by the scheduled build's content
loaders and the build-time `redirects.json` export. The
token is `BUILD_TOKEN`.

### Success (200) — list endpoints

```sh
# Full publishable dump of projects.
curl -sS -H "Authorization: Bearer $BUILD_TOKEN" \
  "http://localhost:4000/api/v1/projects?limit=50"

# Cursor pagination — pass the opaque `next_cursor` back.
curl -sS -H "Authorization: Bearer $BUILD_TOKEN" \
  "http://localhost:4000/api/v1/projects?limit=50&cursor=$NEXT_CURSOR"

# Incremental sync — only records updated after `$SINCE_ISO`.
SINCE_ISO="2026-06-10T00:00:00Z"
curl -sS -H "Authorization: Bearer $BUILD_TOKEN" \
  "http://localhost:4000/api/v1/listings?since=$SINCE_ISO"

# Same shape for /developers and /property_types.
curl -sS -H "Authorization: Bearer $BUILD_TOKEN" \
  "http://localhost:4000/api/v1/developers"
curl -sS -H "Authorization: Bearer $BUILD_TOKEN" \
  "http://localhost:4000/api/v1/property_types"
```

### 304 (ETag match) — repeat fetch with `If-None-Match`

```sh
# 1. Capture the ETag.
ETAG=$(curl -sSI -H "Authorization: Bearer $BUILD_TOKEN" \
        "http://localhost:4000/api/v1/projects" \
      | awk -F': ' 'tolower($1) == "etag" { gsub(/\r/,"",$2); print $2 }')

# 2. Re-issue with If-None-Match → 304 + empty body.
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $BUILD_TOKEN" \
  -H "If-None-Match: $ETAG" \
  "http://localhost:4000/api/v1/projects"
# → 304
```

### Sitemap + redirects

```sh
curl -sS -H "Authorization: Bearer $BUILD_TOKEN" \
  "http://localhost:4000/api/v1/meta/sitemap"

curl -sS -H "Authorization: Bearer $BUILD_TOKEN" \
  "http://localhost:4000/api/v1/redirects"
```

### 401 — auth failures

```sh
# No token → 401 problem+json.
curl -sS -w '\n%{http_code}\n' \
  "http://localhost:4000/api/v1/projects"
# → 401, content-type: application/problem+json

# Render token on a build endpoint → 401 (§6.4 scope disjointness).
curl -sS -w '\n%{http_code}\n' \
  -H "Authorization: Bearer $RENDER_TOKEN" \
  "http://localhost:4000/api/v1/projects"
# → 401
```

## Render tier (§10.1 path 2)

The render tier is hit by the SSR Worker's single-record
lookups. The token is `RENDER_TOKEN`. The render tier is
**disjoint** from the build tier — a build token is rejected
on a render endpoint and vice versa (§6.4).

### Success (200)

```sh
curl -sS -H "Authorization: Bearer $RENDER_TOKEN" \
  "http://localhost:4000/api/v1/projects/le-jardin-de-casablanca"

curl -sS -H "Authorization: Bearer $RENDER_TOKEN" \
  "http://localhost:4000/api/v1/developers/immo-atlas"

curl -sS -H "Authorization: Bearer $RENDER_TOKEN" \
  "http://localhost:4000/api/v1/listings/apartment/apt-casa-001"
```

### 304 (ETag match)

```sh
ETAG=$(curl -sSI -H "Authorization: Bearer $RENDER_TOKEN" \
        "http://localhost:4000/api/v1/projects/le-jardin" \
      | awk -F': ' 'tolower($1) == "etag" { gsub(/\r/,"",$2); print $2 }')

curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $RENDER_TOKEN" \
  -H "If-None-Match: $ETAG" \
  "http://localhost:4000/api/v1/projects/le-jardin"
# → 304
```

### 404 — unpublished or unknown

```sh
# Draft / future-published / billing-gated slug → 404
# (single source of truth: `Catalog.published/1`).
curl -sS -w '\n%{http_code}\n' \
  -H "Authorization: Bearer $RENDER_TOKEN" \
  "http://localhost:4000/api/v1/projects/draft-slug"
# → 404, content-type: application/problem+json
```

### 422 — semantically incomplete request

```sh
# /internal/freshness without a `path` query param → 422
# (NOT 404: the request is well-formed but semantically incomplete).
curl -sS -w '\n%{http_code}\n' \
  -H "Authorization: Bearer $RENDER_TOKEN" \
  "http://localhost:4000/api/v1/internal/freshness"
# → 422
```

### Freshness check (§3.5 / §6.3)

```sh
# Documented §3.5 KV-alternative. Returns `{data: {path, updated_at}}`
# for a published path, 404 otherwise. SSR Worker uses KV by
# default (§3.5); this endpoint is the documented escape hatch.
curl -sS -H "Authorization: Bearer $RENDER_TOKEN" \
  "http://localhost:4000/api/v1/internal/freshness?path=/projets/casablanca/le-jardin"
```

### 401 — auth failures

```sh
# No token → 401.
curl -sS -w '\n%{http_code}\n' \
  "http://localhost:4000/api/v1/projects/any-slug"
# → 401

# Build token on a render endpoint → 401 (scope disjointness).
curl -sS -w '\n%{http_code}\n' \
  -H "Authorization: Bearer $BUILD_TOKEN" \
  "http://localhost:4000/api/v1/projects/any-slug"
# → 401
```

## Public tier (§10.1 path 3)

Anonymous, CORS-exact-origin-allowlisted, Hammer-rate-limited
per bucket. Real endpoints (`/search`, `/listings/geo`,
`POST /inquiries`) land in P5-E1 / P1-E6.1; the smoke routes
below exercise the pipeline surface end-to-end.

### CORS preflight — allowlisted origin

```sh
# Set up the allowlist in config/dev.exs (or PUBLIC_ALLOWED_ORIGINS
# in prod). For dev, `http://localhost:4321` is the site origin.

# Preflight → 200 with the CORS allow headers.
curl -sSI -X OPTIONS \
  -H "Origin: http://localhost:4321" \
  -H "Access-Control-Request-Method: GET" \
  "http://localhost:4000/api/v1/__smoke/public/search"
# → access-control-allow-origin: http://localhost:4321
```

### CORS preflight — non-allowlisted origin

```sh
# Origin NOT in the allowlist → no `access-control-allow-*` headers.
curl -sSI -X OPTIONS \
  -H "Origin: http://evil.example" \
  -H "Access-Control-Request-Method: GET" \
  "http://localhost:4000/api/v1/__smoke/public/search"
# → no access-control-allow-origin (browser will reject)
```

### Actual GET — within rate limit

```sh
curl -sS \
  -H "Origin: http://localhost:4321" \
  "http://localhost:4000/api/v1/__smoke/public/search"
# → 200, cache-control: private, no-store
```

### 429 — rate limit exceeded

```sh
# Default §10.1 buckets: search 60/min/IP, geo 120/min/IP,
# inquiries 5/min/IP. Tune via :immo, :public_rate_limits.

# Hit the search bucket past its limit.
for i in $(seq 1 65); do
  curl -sS -o /dev/null -w '%{http_code}\n' \
    -H "Origin: http://localhost:4321" \
    "http://localhost:4000/api/v1/__smoke/public/search"
done | sort | uniq -c
# → ~60 200s, then 429s
```

## Spec regeneration (CI drift gate)

```sh
# Regenerate the spec after any controller change.
mix openapi.spec.json --spec ImmoWeb.ApiSpec priv/static/openapi.json

# CI gate: any uncommitted drift fails.
mix openapi.drift
```

## What ships in this epic

This doc covers the §16 P1-E5 acceptance criteria for the
three tiers × the per-state matrix. The actual endpoints
mounted in the router today:

| Path | Tier | Method | Controller action |
|---|---|---|---|
| `/api/v1/projects` | build | GET | `BuildController.projects` |
| `/api/v1/listings` | build | GET | `BuildController.listings` |
| `/api/v1/developers` | build | GET | `BuildController.developers` |
| `/api/v1/property_types` | build | GET | `BuildController.property_types` |
| `/api/v1/meta/sitemap` | build | GET | `BuildController.sitemap` |
| `/api/v1/redirects` | build | GET | `BuildController.redirects` |
| `/api/v1/projects/:slug` | render | GET | `RenderController.project` |
| `/api/v1/listings/:type_key/:slug` | render | GET | `RenderController.listing` |
| `/api/v1/developers/:slug` | render | GET | `RenderController.developer` |
| `/api/v1/internal/freshness` | render | GET | `RenderController.freshness` |

Public endpoints (`/api/v1/search`, `/api/v1/listings/geo`,
`POST /api/v1/inquiries`) land in P5-E1 / P1-E6.1 — this
epic ships the pipeline they mount on, not the endpoints
themselves.
