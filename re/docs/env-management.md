# Env & Secrets Management

How build-time, runtime, and CI secrets are stored, loaded, and rotated for the Immo platform.

## Secret taxonomy

| Tier | Examples | Lifetime |
|---|---|---|
| **Build-time** | Astro `astro:env` public vars, `CLOUDFLARE_DEPLOY_HOOK_URL` | Long-lived; rotate on compromise |
| **Runtime** | Phoenix `DATABASE_URL`, `SECRET_KEY_BASE`, R2/Turnstile credentials | Long-lived; rotate periodically |
| **CI** | GitHub Actions secrets | Long-lived; rotate on compromise |

## Where secrets live

### Astro build-time
Set via **Cloudflare encrypted env vars** (dashboard or `wrangler secret put`).
Astro exposes them through `astro:env` as typed vars.

### Phoenix runtime
Set in the **Hetzner VPS env file** or container env (Docker/systemd).
Load with Dotenv or your process manager's env injection.

### CI
Configure in **GitHub Actions secrets** (repository/organization settings).

## Rotation

- Rotate immediately if a value is exposed or a contributor leaves.
- For Phoenix, generate a new `SECRET_KEY_BASE` and invalidate old sessions if needed.
- For R2, create a new API key, update config, then revoke the old one.

## Local development

```bash
cp frontend/.env.example frontend/.env
cp backend/.env.example backend/.env
```

Fill in local values. Real secrets stay in encrypted infra stores, not committed.

## Security rules

- **Never commit `.env`**.
- Use least-privilege tokens (R2: object-only if possible).
- Rotate on compromise.
- Restrict who can read secrets in Cloudflare, GitHub, and VPS access.
