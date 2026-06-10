# Cloudflare setup runbook (P0-E2.1)

Execute plan §12.1. Owner task — requires Cloudflare account access.

## Prerequisites

- Cloudflare account with Workers paid plan (verify Workers Builds monthly quota vs ~720 builds — decision D3).
- Domain(s) on Cloudflare; nameservers delegated.
- GitHub repo connected for Workers Builds.

## 1. Zone and DNS

1. Add production zone for `<domain>` and staging zone for `<staging-domain>`.
2. Apply records from [docs/infra/dns-plan.md](../../docs/infra/dns-plan.md).
3. Create apex/`www` → Worker routes now; leave `api`, `admin`, `media` reserved.

## 2. Workers project

1. Dashboard → **Workers & Pages** → connect Git repository.
2. **Project name:** `immo-frontend`
3. **Root directory:** `newprojects/frontend`
4. **Build command:** `npm ci && npm run build`
5. **Deploy command:** `npx wrangler deploy --env staging` (or map branches in dashboard)
6. Enable **preview deployments** on pull requests.

Replace KV namespace placeholders in `frontend/wrangler.jsonc` after P0-E2.2.

## 3. Hello-world verification

```bash
curl -sS "https://<staging-domain>/__health"
curl -sSI "https://<staging-domain>/"
```

## 4. Acceptance (super-p0e2.1)

- [ ] Staging domain serves hello-world over HTTPS
- [ ] Workers project Git-connected; push builds; PR preview URL works
- [ ] DNS plan documented; Worker records live; tunnel/R2 records reserved
- [ ] Staging and production Worker environments exist
