# DNS plan (P0-E2.1)

Authoritative DNS layout per plan §12.1. Replace `<domain>` with the production apex (e.g. `example.ma`) and `<staging-domain>` with the staging host (e.g. `staging.example.ma` or a dedicated staging zone).

## Records — production (`<domain>`)

| Host | Type | Target | Proxied | Status | Notes |
|------|------|--------|---------|--------|-------|
| `@` (apex) | CNAME | Workers route for `immo-frontend-production` | Yes | **Create in P0-E2.1** | Apex → Worker (Workers Static Assets) |
| `www` | CNAME | same as apex Worker route | Yes | **Create in P0-E2.1** | Canonical public site |
| `api` | CNAME | `<tunnel-id>.cfargotunnel.com` | Yes | **Reserved — P0-E3.3** | Phoenix JSON API via Cloudflare Tunnel |
| `admin` | CNAME | `<tunnel-id>.cfargotunnel.com` | Yes | **Reserved — P0-E3.3** | LiveView admin via tunnel |
| `media` | CNAME | R2 custom domain target | Yes | **Reserved — P0-E2.2** | `media.<domain>` → R2 bucket |

## Records — staging (`<staging-domain>`)

| Host | Type | Target | Proxied | Status | Notes |
|------|------|--------|---------|--------|-------|
| `@` | CNAME | Workers route for `immo-frontend-staging` | Yes | **Create in P0-E2.1** | Staging Worker |
| `www` | CNAME | same as staging Worker route | Yes | **Create in P0-E2.1** | Optional alias |
| `api` | CNAME | `<staging-tunnel-id>.cfargotunnel.com` | Yes | **Reserved — P0-E3.3** | Staging Phoenix |
| `admin` | CNAME | `<staging-tunnel-id>.cfargotunnel.com` | Yes | **Reserved — P0-E3.3** | Staging admin |
| `media` | CNAME | R2 staging custom domain | Yes | **Reserved — P0-E2.2** | Staging media |

## Workers project (`immo-frontend`)

- **Build root:** monorepo `/frontend` (Git-connected Workers Builds).
- **Preview deployments:** enabled on pull requests (feeds Lighthouse CI — §12.3).
- **Environments:** `staging` and `production` wrangler envs (`frontend/wrangler.jsonc`).
- **Hello-world AC:** after first deploy, `https://<staging-domain>/__health` returns JSON `{"status":"ok",...}`.

## Verification checklist

1. `curl -sS https://<staging-domain>/__health | jq .status` → `"ok"`
2. `curl -sSI https://<staging-domain>/` → `200` over HTTPS
3. Push to `main` triggers a Workers Build
4. Open a PR → preview deployment URL appears
